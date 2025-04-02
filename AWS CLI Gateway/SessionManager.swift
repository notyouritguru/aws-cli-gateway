import Foundation
import CommonCrypto

class SessionManager {
    static let shared = SessionManager()

    // MARK: - Properties
    private var sessionTimer: Timer?
    private var activeProfile: String?
    private var expiryDate: Date?
    private var isCleanDisconnect: Bool = false
    private static var findingCredentials = false
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring: Bool = false

    // Store a mapping of profile names to their last known cache files
    // Make it persistent across app launches

    // 1. First, update the profileCacheFileMap property to use thread-safe access:
    private let profileCacheFileMapLock = NSLock()
    private var _profileCacheFileMap: [String: String] = [:]
    private var profileCacheFileMap: [String: String] {
        get {
            profileCacheFileMapLock.lock()
            defer { profileCacheFileMapLock.unlock() }
            return _profileCacheFileMap
        }
        set {
            profileCacheFileMapLock.lock()
            _profileCacheFileMap = newValue
            // Save to UserDefaults on background thread to avoid blocking UI
            DispatchQueue.global(qos: .background).async {
                UserDefaults.standard.set(newValue, forKey: "profile_cache_file_map")
            }
            profileCacheFileMapLock.unlock()
        }
    }

    // Callback for UI updates
    var onSessionUpdate: ((String) -> Void)?

    private init() {
        // Load saved mappings from UserDefaults
        if let savedMap = UserDefaults.standard.dictionary(forKey: "profile_cache_file_map") as? [String: String] {
            profileCacheFileMap = savedMap
            print("SessionManager: Loaded \(savedMap.count) cached profile mappings")
        } else {
            profileCacheFileMap = [:]
        }
    }
    
    // REPLACE the existing generateCacheFileHash method with this version
    private func generateCacheFileHash(profile: SSOProfile) -> String {
        // Get the session name for this profile
        let sessionName = ConfigManager.shared.getSSOSessionName(for: profile.name)

        if let sessionName = sessionName {
            print("SessionManager: Using session name '\(sessionName)' for hash generation")

            // Create a components dict with sessionName instead of startUrl
            let components: [String: String] = [
                "accountId": profile.accountId,
                "roleName": profile.roleName,
                "sessionName": sessionName
            ]

            // Create JSON string with alphabetically sorted keys
            guard let jsonData = try? JSONSerialization.data(withJSONObject: components, options: [.sortedKeys]) else {
                print("SessionManager: Failed to create JSON for hash generation")
                return ""
            }

            let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
            print("SessionManager: JSON for hash: \(jsonString)")

            // Generate SHA-1 hash
            let data = Data(jsonString.utf8)
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes {
                _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
            }

            // Convert to hex string
            let hashString = digest.map { String(format: "%02x", $0) }.joined()
            print("SessionManager: Generated hash: \(hashString)")
            return hashString
        } else {
            // Fallback to the old method using startUrl
            print("SessionManager: No session name found, using startUrl for hash")
            return generateLegacyCacheFileHash(
                roleName: profile.roleName,
                accountId: profile.accountId,
                startUrl: profile.startUrl
            )
        }
    }

    // Keep the original method for fallback
    private func generateLegacyCacheFileHash(roleName: String, accountId: String, startUrl: String) -> String {
        // This is based on your existing method
        let components: [String: String] = [
            "accountId": accountId,
            "roleName": roleName,
            "startUrl": startUrl
        ]

        // Sort keys and create a JSON string
        guard let jsonData = try? JSONSerialization.data(withJSONObject: components, options: [.sortedKeys]) else {
            print("SessionManager: Failed to create JSON for hash generation")
            return ""
        }

        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

        // Generate SHA-1 hash
        let data = Data(jsonString.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }

        // Convert to hex string
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        return hashString
    }

    // MARK: - Public Interface

    @MainActor
    func startMonitoring(for profileName: String) {
        // Cancel any previous monitoring task first
        monitoringTask?.cancel()

        // Clear existing timer first
        sessionTimer?.invalidate()
        sessionTimer = nil

        // Reset state
        self.isCleanDisconnect = false
        self.isMonitoring = true
        self.activeProfile = profileName
        print("SessionManager: Starting monitoring for profile: \(profileName)")

        // Update UI immediately to indicate we're working on it
        self.onSessionUpdate?("Session: Connecting...")

        // Create a new task with proper cancellation support
        monitoringTask = Task { [weak self] in
            guard let self = self else { return }

            // Check for cancellation before proceeding
            if Task.isCancelled { return }

            // First try the content-based approach
            if let cacheFilename = await self.findMatchingCacheFile(forProfile: profileName) {
                // Check for cancellation
                if Task.isCancelled { return }

                print("SessionManager: Found matching cache file: \(cacheFilename)")
                self.profileCacheFileMap[profileName] = cacheFilename

                if let ssoToken = try? await self.readCredentialsFromCacheFile(cacheFilename) {
                    // Check for cancellation
                    if Task.isCancelled { return }

                    print("SessionManager: Found valid credentials in matched file, expires at: \(ssoToken.expiresAt)")
                    await MainActor.run {
                        if !Task.isCancelled && self.isMonitoring && self.activeProfile == profileName {
                            self.expiryDate = ssoToken.expiresAt
                            self.startSessionTimer()
                        }
                    }
                    return
                }
            }

            // Check for cancellation
            if Task.isCancelled { return }

            // If that didn't work, try the legacy approach
            if let ssoToken = try? await self.findCLICredentialsForProfile(profileName) {
                // Check for cancellation
                if Task.isCancelled { return }

                print("SessionManager: Found credentials with legacy approach, expires at: \(ssoToken.expiresAt)")
                await MainActor.run {
                    if !Task.isCancelled && self.isMonitoring && self.activeProfile == profileName {
                        self.expiryDate = ssoToken.expiresAt
                        self.startSessionTimer()
                    }
                }
                return
            }

            // Check for cancellation
            if Task.isCancelled { return }

            // If still no credentials, try to create them by running a command
            print("SessionManager: No credentials found, attempting to refresh...")
            do {
                _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])

                // Check for cancellation
                if Task.isCancelled { return }

                // Try again after refreshing
                if let cacheFilename = await self.findMatchingCacheFile(forProfile: profileName) {
                    // Check for cancellation
                    if Task.isCancelled { return }

                    self.profileCacheFileMap[profileName] = cacheFilename
                    if let ssoToken = try? await self.readCredentialsFromCacheFile(cacheFilename) {
                        // Check for cancellation
                        if Task.isCancelled { return }

                        print("SessionManager: Found credentials after refresh, expires at: \(ssoToken.expiresAt)")
                        await MainActor.run {
                            if !Task.isCancelled && self.isMonitoring && self.activeProfile == profileName {
                                self.expiryDate = ssoToken.expiresAt
                                self.startSessionTimer()
                            }
                        }
                        return
                    }
                }

                // Check for cancellation
                if Task.isCancelled { return }

                // Final fallback - try legacy approach one more time
                if let ssoToken = try? await self.findCLICredentialsForProfile(profileName) {
                    // Check for cancellation
                    if Task.isCancelled { return }

                    print("SessionManager: Found credentials after refresh (legacy), expires at: \(ssoToken.expiresAt)")
                    await MainActor.run {
                        if !Task.isCancelled && self.isMonitoring && self.activeProfile == profileName {
                            self.expiryDate = ssoToken.expiresAt
                            self.startSessionTimer()
                        }
                    }
                    return
                }

                // If we get here, no credentials were found
                await MainActor.run {
                    if !Task.isCancelled && self.isMonitoring && self.activeProfile == profileName {
                        self.expiryDate = nil
                        self.onSessionUpdate?("Session: Not authenticated")
                    }
                }
            } catch {
                // Only update if we're still monitoring the same profile
                await MainActor.run {
                    if !Task.isCancelled && self.isMonitoring && self.activeProfile == profileName {
                        print("SessionManager: Failed to refresh credentials: \(error)")
                        self.expiryDate = nil
                        self.onSessionUpdate?("Session: Auth failed")
                    }
                }
            }
        }
    }

    // MARK: - Improved Cache File Finding

    private func findMatchingCacheFile(forProfile profileName: String) async -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        // First check if we already have a valid mapping
        if let knownCacheFile = profileCacheFileMap[profileName],
           FileManager.default.fileExists(atPath: cliCachePath.appendingPathComponent(knownCacheFile).path),
           let token = try? await readCredentialsFromCacheFile(knownCacheFile),
           token.expiresAt > Date() {
            print("SessionManager: Using known valid mapping for \(profileName): \(knownCacheFile)")
            return knownCacheFile
        }

        print("SessionManager: Looking for cache file matching profile: \(profileName)")

        // Get profile details for comparison
        guard let profile = ConfigManager.shared.getProfile(profileName) else {
            print("SessionManager: Cannot find profile \(profileName) in config")
            return nil
        }

        // For SSO profiles, try to compute the exact hash first
        if let ssoProfile = profile as? SSOProfile {
            let expectedHash = generateCacheFileHash(
                profile: ssoProfile
            )

            if !expectedHash.isEmpty {
                let expectedFilename = "\(expectedHash).json"
                let expectedPath = cliCachePath.appendingPathComponent(expectedFilename)

                if FileManager.default.fileExists(atPath: expectedPath.path) {
                    print("SessionManager: Found exact hash match: \(expectedFilename)")

                    // Verify it has valid credentials before returning
                    if let token = try? await readCredentialsFromCacheFile(expectedFilename),
                       token.expiresAt > Date() {
                        // Store this mapping for future use
                        profileCacheFileMap[profileName] = expectedFilename
                        return expectedFilename
                    } else {
                        print("SessionManager: Hash match found but credentials are expired or invalid")
                    }
                } else {
                    print("SessionManager: Computed hash file \(expectedFilename) doesn't exist")
                }
            }
        }

        do {
            // Get all JSON files in the cache directory
            let cacheFiles = try FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }

            print("SessionManager: Examining \(cacheFiles.count) cache files")

            // For each file, try to read it and check for a strong match
            for file in cacheFiles {
                if let data = try? Data(contentsOf: file),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // For SSO profiles - STRICT matching
                    if let ssoProfile = profile as? SSOProfile {
                        // Check role ARN - must contain exact account ID and role name
                        if let roleArn = json["RoleArn"] as? String {
                            let roleArnPattern = "arn:aws:iam::\(ssoProfile.accountId):role/\(ssoProfile.roleName)"
                            if roleArn == roleArnPattern {
                                print("SessionManager: Found exact role ARN match in \(file.lastPathComponent)")
                                return file.lastPathComponent
                            }
                        }

                        // Look for account ID and role name in Credentials
                        if let credentialProcess = json["CredentialProcess"] as? String,
                           credentialProcess.contains(ssoProfile.accountId),
                           credentialProcess.contains(ssoProfile.roleName) {
                            print("SessionManager: Found matching SSO profile in credential process: \(file.lastPathComponent)")
                            return file.lastPathComponent
                        }

                        // Check for exact profile name in ConfigFile
                        if let configFile = json["ConfigFile"] as? String,
                           configFile.contains("[profile \(profileName)]") {
                            print("SessionManager: Found exact profile name match in ConfigFile: \(file.lastPathComponent)")
                            return file.lastPathComponent
                        }

                        // Check content for all three critical components
                        let fileContent = String(data: data, encoding: .utf8) ?? ""
                        if fileContent.contains(ssoProfile.accountId) &&
                           fileContent.contains(ssoProfile.roleName) &&
                           fileContent.contains(ssoProfile.startUrl) {
                            print("SessionManager: Found content match with all key components: \(file.lastPathComponent)")
                            return file.lastPathComponent
                        }
                    }

                    // IAM role profile matching remains similar
                    if let iamProfile = profile as? IAMProfile {
                        if let assumedRoleUser = json["assumedRoleUser"] as? [String: Any],
                           let arn = assumedRoleUser["arn"] as? String {

                            let roleArnParts = iamProfile.roleArn.split(separator: "/")
                            if let roleName = roleArnParts.last,
                               arn.contains(String(roleName)) {
                                print("SessionManager: Found matching IAM role profile: \(file.lastPathComponent)")
                                return file.lastPathComponent
                            }
                        }
                    }
                }
            }

            print("SessionManager: No definitive match found for \(profileName)")
            return nil

        } catch {
            print("SessionManager: Error searching cache files: \(error)")
            return nil
        }
    }
    
    // Read credentials from a specific cache file
    private func readCredentialsFromCacheFile(_ filename: String) async throws -> SSOToken? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")
        let cacheFilePath = cliCachePath.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: cacheFilePath.path) {
            print("SessionManager: Cache file no longer exists: \(filename)")
            return nil
        }

        do {
            let data = try Data(contentsOf: cacheFilePath)
            let decoder = JSONDecoder()

            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]

                if let date = formatter.date(from: dateString) {
                    return date
                }

                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
            }

            // Try SSO format first
            if let ssoCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) {
                let expiresAt = ssoCredentials.credentials.expiration
                print("SessionManager: Parsed SSO credentials, expires: \(expiresAt)")

                if expiresAt > Date() {
                    return SSOToken(expiresAt: expiresAt)
                } else {
                    print("SessionManager: SSO credentials are expired")
                    return nil
                }
            }
            // Then try IAM role format
            else if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data) {
                let expiresAt = iamCredentials.credentials.expiration
                print("SessionManager: Parsed IAM credentials, expires: \(expiresAt)")

                if expiresAt > Date() {
                    return SSOToken(expiresAt: expiresAt)
                } else {
                    print("SessionManager: IAM credentials are expired")
                    return nil
                }
            }

            print("SessionManager: Could not parse credentials from \(filename)")
            return nil
        } catch {
            print("SessionManager: Error reading cache file: \(error)")
            return nil
        }
    }

    // Find the most recently updated cache file - useful after running a command
    private func findMostRecentlyUpdatedCacheFile() async throws -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else {
            return nil
        }

        // Filter out non-JSON files and .DS_Store
        let jsonFiles = cacheFiles.filter { $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }

        // Get modification dates
        var filesWithDates: [(URL, Date)] = []
        for file in jsonFiles {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attributes[.modificationDate] as? Date {
                filesWithDates.append((file, modDate))
            }
        }

        // Sort by modification date (newest first)
        let sortedFiles = filesWithDates.sorted { $0.1 > $1.1 }

        // Return the most recently modified file name
        return sortedFiles.first?.0.lastPathComponent
    }

    // Method to find CLI credentials for a profile (legacy approach)
    private func findCLICredentialsForProfile(_ profileName: String) async throws -> SSOToken? {
        if SessionManager.findingCredentials {
            print("SessionManager: Avoiding recursive credential lookup")
            return nil
        }

        SessionManager.findingCredentials = true
        defer { SessionManager.findingCredentials = false }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        // Check for a known mapping first
        if let knownCacheFile = profileCacheFileMap[profileName] {
            let cacheFilePath = cliCachePath.appendingPathComponent(knownCacheFile)
            print("SessionManager: Trying known cache file for \(profileName): \(knownCacheFile)")

            if FileManager.default.fileExists(atPath: cacheFilePath.path),
               let token = try? await readCredentialsFromCacheFile(knownCacheFile),
               token.expiresAt > Date() {
                return token
            } else {
                // Known mapping is invalid, remove it
                profileCacheFileMap.removeValue(forKey: profileName)
            }
        }

        // Get profile details for strong matching
        guard let profile = ConfigManager.shared.getProfile(profileName) else {
            print("SessionManager: Cannot find profile details for \(profileName)")
            return nil
        }

        // For SSO profiles, try to compute the exact hash
        if let ssoProfile = profile as? SSOProfile {
            let expectedHash = generateCacheFileHash(
                profile: ssoProfile
            )

            if !expectedHash.isEmpty {
                let expectedFilename = "\(expectedHash).json"
                let expectedPath = cliCachePath.appendingPathComponent(expectedFilename)

                if FileManager.default.fileExists(atPath: expectedPath.path) {
                    print("SessionManager: Found exact hash match in legacy lookup: \(expectedFilename)")

                    if let token = try? await readCredentialsFromCacheFile(expectedFilename),
                       token.expiresAt > Date() {
                        profileCacheFileMap[profileName] = expectedFilename
                        return token
                    }
                }
            }
        }

        // Get all cache files sorted by modification time
        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            print("SessionManager: Cannot read CLI cache directory")
            return nil
        }

        // Build list of files with their modification dates
        var filesWithDates: [(URL, Date)] = []
        for file in cacheFiles.filter({ $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attributes[.modificationDate] as? Date {
                filesWithDates.append((file, modDate))
            }
        }

        // Sort by modification date (newest first)
        let sortedFiles = filesWithDates.sorted { $0.1 > $1.1 }
        print("SessionManager: Examining \(sortedFiles.count) sorted cache files")

        // IMPORTANT: We're removing the "use any valid credential" fallback!
        // Instead, we'll only match credentials that are likely for this profile

        for (file, _) in sortedFiles {
            do {
                let data = try Data(contentsOf: file)

                // For more precise matching, check file contents first
                if let ssoProfile = profile as? SSOProfile {
                    let fileContent = String(data: data, encoding: .utf8) ?? ""

                    // Only consider files that contain BOTH the account ID and role name
                    // This is a minimal bar to avoid using credentials from totally unrelated profiles
                    if !fileContent.contains(ssoProfile.accountId) || !fileContent.contains(ssoProfile.roleName) {
                        continue  // Skip this file if it doesn't contain both critical identifiers
                    }
                }

                // Now try to parse the file
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)

                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]

                    if let date = formatter.date(from: dateString) {
                        return date
                    }

                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
                }

                // Try SSO format
                if let ssoCredentials = try? decoder.decode(AWSCliCredentials.self, from: data),
                   ssoCredentials.credentials.expiration > Date() {

                    // Strong match for SSO profiles - additional verification
                    if let ssoProfile = profile as? SSOProfile,
                       let roleArn = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let roleArnStr = roleArn["RoleArn"] as? String {

                        let expectedArn = "arn:aws:iam::\(ssoProfile.accountId):role/\(ssoProfile.roleName)"
                        if roleArnStr == expectedArn {
                            print("SessionManager: Found exact ARN match in \(file.lastPathComponent)")
                            profileCacheFileMap[profileName] = file.lastPathComponent
                            return SSOToken(expiresAt: ssoCredentials.credentials.expiration)
                        }
                    } else {
                        // Still save this as a fallback, but with a warning
                        print("SessionManager: Using SSO credentials with partial match in \(file.lastPathComponent)")
                        profileCacheFileMap[profileName] = file.lastPathComponent
                        return SSOToken(expiresAt: ssoCredentials.credentials.expiration)
                    }
                }

                // Try IAM format with precise matching for IAM profiles
                if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data),
                   iamCredentials.credentials.expiration > Date() {

                    if let iamProfile = profile as? IAMProfile {
                        // For IAM profiles, check if the ARN contains the role name
                        let arn = iamCredentials.assumedRoleUser.arn
                        let roleArnParts = iamProfile.roleArn.split(separator: "/")

                        if let roleName = roleArnParts.last, arn.contains(String(roleName)) {
                            print("SessionManager: Found matching IAM role ARN in \(file.lastPathComponent)")
                            profileCacheFileMap[profileName] = file.lastPathComponent
                            return SSOToken(expiresAt: iamCredentials.credentials.expiration)
                        }
                    }
                }
            } catch {
                print("SessionManager: Error parsing \(file.lastPathComponent): \(error)")
            }
        }

        print("SessionManager: No valid credentials found for \(profileName)")
        return nil
    }

    // For AWS CLI SSO Credentials format
    struct AWSCliCredentials: Codable {
        let providerType: String
        let credentials: Credentials

        struct Credentials: Codable {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String
            let expiration: Date

            enum CodingKeys: String, CodingKey {
                case accessKeyId = "AccessKeyId"
                case secretAccessKey = "SecretAccessKey"
                case sessionToken = "SessionToken"
                case expiration = "Expiration"
            }
        }

        enum CodingKeys: String, CodingKey {
            case providerType = "ProviderType"
            case credentials = "Credentials"
        }
    }

    // IAM role credentials format struct
    private struct IAMRoleCredentials: Codable {
        let credentials: Credentials
        let assumedRoleUser: AssumedRoleUser

        struct Credentials: Codable {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String
            let expiration: Date

            enum CodingKeys: String, CodingKey {
                case accessKeyId = "AccessKeyId"
                case secretAccessKey = "SecretAccessKey"
                case sessionToken = "SessionToken"
                case expiration = "Expiration"
            }
        }

        struct AssumedRoleUser: Codable {
            let assumedRoleId: String
            let arn: String

            enum CodingKeys: String, CodingKey {
                case assumedRoleId = "AssumedRoleId"
                case arn = "Arn"
            }
        }

        enum CodingKeys: String, CodingKey {
            case credentials = "Credentials"
            case assumedRoleUser = "AssumedRoleUser"
        }
    }

    func cleanDisconnect() {
        // Set the flag first to prevent notifications
        isCleanDisconnect = true

        // Cancel any ongoing task immediately
        monitoringTask?.cancel()
        monitoringTask = nil

        // Stop monitoring flag
        isMonitoring = false

        // Clear timer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionTimer?.invalidate()
            self.sessionTimer = nil
            self.activeProfile = nil
            self.expiryDate = nil

            // Update UI
            self.onSessionUpdate?("Session: --:--:--")
        }
    }

    func stopMonitoring() {
        // Cancel any ongoing task
        monitoringTask?.cancel()
        monitoringTask = nil

        // Stop monitoring flag
        isMonitoring = false

        // Clear timer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionTimer?.invalidate()
            self.sessionTimer = nil
            self.activeProfile = nil
            self.expiryDate = nil

            // Reset UI
            self.onSessionUpdate?("Session: --:--:--")

            // Only post notification if not a clean disconnect
            if !self.isCleanDisconnect {
                NotificationCenter.default.post(
                    name: Notification.Name(Constants.Notifications.sessionMonitoringStopped),
                    object: nil
                )
            }
            self.isCleanDisconnect = false
        }
    }


    func renewSession() async throws {
        guard let profile = activeProfile else {
            throw SessionError.noActiveProfile
        }

        // Cancel existing monitoring task
        monitoringTask?.cancel()

        do {
            // 1) Logout old session
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "logout", "--profile", profile])

            // 2) Clear local cache
            ConfigManager.shared.clearCache()

            // 3) Clear the mapping for this profile
            profileCacheFileMap.removeValue(forKey: profile)

            // 4) Login again
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "login", "--profile", profile])

            // 5) Force creation of fresh credentials
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profile])

            // 6) Update expirationDate and restart the timer
            await MainActor.run { [weak self] in
                self?.startMonitoring(for: profile)
            }

            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionRenewed),
                object: nil
            )
        } catch {
            throw SessionError.renewalFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func startSessionTimer() {
        // Ensure we're on the main thread
        assert(Thread.isMainThread, "startSessionTimer must be called on the main thread")

        // Only start timer if we're in monitoring state
        guard isMonitoring else {
            print("SessionManager: Not starting timer - monitoring is off")
            return
        }

        // Invalidate any existing timer
        sessionTimer?.invalidate()
        sessionTimer = nil

        // Create a new timer that fires every second
        self.sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isMonitoring else { return }
            self.checkSessionStatus()
        }

        // Make sure timer continues to fire when scrolling
        RunLoop.current.add(self.sessionTimer!, forMode: .common)

        // Ensure UI is updated immediately with correct time format
        if let expiry = self.expiryDate {
            let remaining = expiry.timeIntervalSinceNow
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            let seconds = Int(remaining) % 60
            let timeString = String(format: "Session: %02d:%02d:%02d", hours, minutes, seconds)
            self.onSessionUpdate?(timeString)
        }

        // Run full status check after UI update
        self.checkSessionStatus()
    }
    
    private func createProfileIdentifier(for ssoProfile: SSOProfile) -> String {
        // Combine distinctive properties to create a unique identifier
        let identifierString = "\(ssoProfile.startUrl)_\(ssoProfile.accountId)_\(ssoProfile.roleName)_\(ssoProfile.region)"

        // Create a SHA256 hash of this string to get a consistent identifier
        let data = Data(identifierString.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }

        // Convert to hex string
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func handleExpiredSession() {
        guard !isCleanDisconnect else { return }  // Exit early if clean disconnect

        stopMonitoring()
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.sessionExpired),
            object: nil
        )
    }

    private var expiryRefreshTime: Date? = nil

    // Then modify your checkSessionStatus method
    private func checkSessionStatus() {
        // Only proceed if actively monitoring
        guard isMonitoring, !isCleanDisconnect else { return }

        // Only refresh expiration time occasionally, not every check
        let now = Date()
        if expiryRefreshTime == nil || now.timeIntervalSince(expiryRefreshTime!) > 60 {
            expiryRefreshTime = now

            // Re-check the expiration time
            if let profileName = activeProfile {
                Task { [weak self] in
                    guard let self = self, self.isMonitoring else { return }

                    if let cacheFilename = self.profileCacheFileMap[profileName],
                       let token = try? await self.readCredentialsFromCacheFile(cacheFilename) {
                        await MainActor.run {
                            if self.isMonitoring && self.expiryDate != token.expiresAt {
                                self.expiryDate = token.expiresAt
                                print("SessionManager: Updated expiration date to \(token.expiresAt)")
                            }
                        }
                    }
                }
            }
        }

        guard let expiration = expiryDate else {
            handleExpiredSession()
            return
        }

        let remaining = expiration.timeIntervalSinceNow
        if remaining <= 0 {
            handleExpiredSession()
            return
        }

        // Format time string
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        let timeString = String(format: "Session: %02d:%02d:%02d", hours, minutes, seconds)

        // Update UI through callback
        self.onSessionUpdate?(timeString)

        // Also post notification for other observers
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.sessionTimeUpdated),
            object: nil,
            userInfo: [Constants.NotificationKeys.timeRemaining: remaining]
        )

        // Check warning thresholds
        checkWarningThresholds(remaining)
    }
    
    private func checkWarningThresholds(_ remaining: TimeInterval) {
        guard !isCleanDisconnect else { return }  // Exit early if clean disconnect

        for threshold in Constants.Session.warningThresholds {
            if remaining <= threshold && remaining > threshold - 1 {
                NotificationCenter.default.post(
                    name: Notification.Name(Constants.Notifications.sessionWarning),
                    object: nil,
                    userInfo: [
                        Constants.NotificationKeys.timeRemaining: remaining,
                        Constants.NotificationKeys.threshold: threshold
                    ]
                )
            }
        }
    }
}

// MARK: - Errors
enum SessionError: LocalizedError {
    case noActiveProfile
    case renewalFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            return "No active profile selected"
        case .renewalFailed(let message):
            return "Session renewal failed: \(message)"
        }
    }
}
