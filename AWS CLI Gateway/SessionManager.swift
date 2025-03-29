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

    // MARK: - Public Interface

    @MainActor
    func startMonitoring(for profileName: String) {
        self.activeProfile = profileName
        print("SessionManager: Starting monitoring for profile: \(profileName)")

        // Clear any existing timers
        sessionTimer?.invalidate()

        // Update UI immediately to indicate we're working on it
        self.onSessionUpdate?("Session: Connecting...")

        // Find the matching credentials file
        Task {
            // First try the content-based approach
            if let cacheFilename = await findMatchingCacheFile(forProfile: profileName) {
                print("SessionManager: Found matching cache file: \(cacheFilename)")
                profileCacheFileMap[profileName] = cacheFilename

                if let ssoToken = try? await readCredentialsFromCacheFile(cacheFilename) {
                    print("SessionManager: Found valid credentials in matched file, expires at: \(ssoToken.expiresAt)")
                    self.expiryDate = ssoToken.expiresAt
                    startSessionTimer()
                    return
                }
            }

            // If that didn't work, try the legacy approach
            if let ssoToken = try? await findCLICredentialsForProfile(profileName) {
                print("SessionManager: Found credentials with legacy approach, expires at: \(ssoToken.expiresAt)")
                self.expiryDate = ssoToken.expiresAt
                startSessionTimer()
                return
            }

            // If still no credentials, try to create them by running a command
            print("SessionManager: No credentials found, attempting to refresh...")
            do {
                _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])

                // Try again after refreshing
                if let cacheFilename = await findMatchingCacheFile(forProfile: profileName) {
                    profileCacheFileMap[profileName] = cacheFilename
                    if let ssoToken = try? await readCredentialsFromCacheFile(cacheFilename) {
                        print("SessionManager: Found credentials after refresh, expires at: \(ssoToken.expiresAt)")
                        self.expiryDate = ssoToken.expiresAt
                        startSessionTimer()
                        return
                    }
                }

                // Final fallback - try legacy approach one more time
                if let ssoToken = try? await findCLICredentialsForProfile(profileName) {
                    print("SessionManager: Found credentials after refresh (legacy), expires at: \(ssoToken.expiresAt)")
                    self.expiryDate = ssoToken.expiresAt
                    startSessionTimer()
                    return
                }

                self.expiryDate = nil
                self.onSessionUpdate?("Session: Not authenticated")
            } catch {
                print("SessionManager: Failed to refresh credentials: \(error)")
                self.expiryDate = nil
                self.onSessionUpdate?("Session: Auth failed")
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

        // For SSO profiles, create a distinctive identifier
        var profileIdentifier: String? = nil
        if let ssoProfile = profile as? SSOProfile {
            profileIdentifier = createProfileIdentifier(for: ssoProfile)
        }

        do {
            // Get all JSON files in the cache directory
            let cacheFiles = try FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }

            print("SessionManager: Examining \(cacheFiles.count) cache files")

            // For each file, try to read it and check for identifiers
            for file in cacheFiles {
                if let data = try? Data(contentsOf: file),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // For SSO profiles - STRICT matching
                    if let ssoProfile = profile as? SSOProfile, let _ = profileIdentifier {
                        // Check role ARN - must contain exact account ID and role name
                        if let roleArn = json["RoleArn"] as? String {
                            let exactRolePattern = "arn:aws:iam::\(ssoProfile.accountId):role/\(ssoProfile.roleName)"
                            if roleArn == exactRolePattern {
                                print("SessionManager: Found exact matching SSO profile by role ARN: \(file.lastPathComponent)")
                                return file.lastPathComponent
                            }
                        }

                        // Check StartUrl - must be exact match
                        if let startUrl = json["StartUrl"] as? String, startUrl == ssoProfile.startUrl {
                            // Additionally verify region if available
                            if let region = json["Region"] as? String, region == ssoProfile.region {
                                print("SessionManager: Found exact matching SSO profile by URL and region: \(file.lastPathComponent)")
                                return file.lastPathComponent
                            }
                        }

                        // Check for exact profile name in ConfigFile
                        if let configFile = json["ConfigFile"] as? String,
                           configFile.contains("[profile \(profileName)]") {
                            print("SessionManager: Found exact profile name match in config: \(file.lastPathComponent)")
                            return file.lastPathComponent
                        }

                        // Fallback - check if file contains our unique identifier components
                        let fileContents = String(data: data, encoding: .utf8) ?? ""
                        if fileContents.contains(ssoProfile.accountId) &&
                           fileContents.contains(ssoProfile.roleName) &&
                           fileContents.contains(ssoProfile.region) {
                            print("SessionManager: Found matching SSO profile by multiple identifiers: \(file.lastPathComponent)")
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
        defer { SessionManager.findingCredentials = false
        }
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        // Check if we have a known mapping for this profile
        if let knownCacheFile = profileCacheFileMap[profileName] {
            let cacheFilePath = cliCachePath.appendingPathComponent(knownCacheFile)
            print("SessionManager: Trying known cache file for \(profileName): \(knownCacheFile)")

            if FileManager.default.fileExists(atPath: cacheFilePath.path) {
                // Try to read and parse this file
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

                    // Try to decode as SSO first
                    if let ssoCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) {
                        let expiresAt = ssoCredentials.credentials.expiration
                        print("SessionManager: Found SSO credentials for \(profileName) in known file, expires: \(expiresAt)")

                        if expiresAt > Date() {
                            return SSOToken(expiresAt: expiresAt)
                        } else {
                            print("SessionManager: Known credentials for \(profileName) are expired")
                            // Remove from mapping since it's expired
                            profileCacheFileMap.removeValue(forKey: profileName)
                        }
                    }
                    // Then try IAM role format
                    else if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data) {
                        let expiresAt = iamCredentials.credentials.expiration
                        print("SessionManager: Found IAM credentials for \(profileName) in known file, expires: \(expiresAt)")

                        if expiresAt > Date() {
                            return SSOToken(expiresAt: expiresAt)
                        } else {
                            print("SessionManager: Known credentials for \(profileName) are expired")
                            // Remove from mapping since it's expired
                            profileCacheFileMap.removeValue(forKey: profileName)
                        }
                    }
                } catch {
                    print("SessionManager: Error reading known cache file: \(error)")
                    // Remove from mapping since it's invalid
                    profileCacheFileMap.removeValue(forKey: profileName)
                }
            }
        }

        // If we don't have a cached mapping, or it didn't work, try to determine it
        // by examining all files in the cache directory
        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: nil) else {
            print("SessionManager: Cannot read CLI cache directory")
            return nil
        }

        print("SessionManager: Found \(cacheFiles.count) files in CLI cache")

        // Get a list of all profiles for reference
        _ = ConfigManager.shared.getProfiles()

        // Sort by last modification time (newest first)
        var sortedFiles: [(URL, Date)] = []
        for file in cacheFiles.filter({ $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attributes[.modificationDate] as? Date {
                sortedFiles.append((file, modDate))
            }
        }

        // Sort by modification date (newest first)
        sortedFiles.sort { $0.1 > $1.1 }

        // If we're looking for an IAM role profile
        if let profile = ConfigManager.shared.getProfile(profileName), let iamProfile = profile as? IAMProfile {
            let roleArn = iamProfile.roleArn
            print("SessionManager: Looking for IAM role profile with ARN: \(roleArn)")

            // Check all files
            for (file, _) in sortedFiles {
                do {
                    let data = try Data(contentsOf: file)
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

                    // For IAM roles, check if the file contains the assumed role ARN
                    if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data) {
                        let arnInFile = iamCredentials.assumedRoleUser.arn

                        if arnInFile.contains(roleArn) ||
                           (roleArn.contains(":role/") && arnInFile.contains(":assumed-role/")) {
                            print("SessionManager: Found matching role credentials in \(file.lastPathComponent)")

                            // Save this mapping for future use
                            profileCacheFileMap[profileName] = file.lastPathComponent

                            // Return token if not expired
                            if iamCredentials.credentials.expiration > Date() {
                                return SSOToken(expiresAt: iamCredentials.credentials.expiration)
                            }
                        }
                    }
                } catch {
                    print("SessionManager: Error parsing \(file.lastPathComponent): \(error)")
                }
            }
        }

        // For SSO profiles, try the most recently updated file first,
        // then fall back to any valid credential in order of recency
        for (file, _) in sortedFiles {
            do {
                let data = try Data(contentsOf: file)
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
                if let ssoCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) {
                    print("SessionManager: Found SSO credentials in \(file.lastPathComponent), expires: \(ssoCredentials.credentials.expiration)")

                    // If this is the first valid file and we're looking for the active profile
                    if profileName == activeProfile && !profileCacheFileMap.values.contains(file.lastPathComponent) {
                        // Map this file to the current profile if it's not already mapped
                        profileCacheFileMap[profileName] = file.lastPathComponent
                        print("SessionManager: Mapped \(profileName) to cache file \(file.lastPathComponent)")
                    }

                    // Return token if not expired
                    if ssoCredentials.credentials.expiration > Date() {
                        return SSOToken(expiresAt: ssoCredentials.credentials.expiration)
                    }
                }
                // Try IAM format
                else if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data) {
                    print("SessionManager: Found IAM credentials in \(file.lastPathComponent), expires: \(iamCredentials.credentials.expiration)")

                    // Similar mapping logic for IAM credentials
                    if profileName == activeProfile && !profileCacheFileMap.values.contains(file.lastPathComponent) {
                        profileCacheFileMap[profileName] = file.lastPathComponent
                        print("SessionManager: Mapped \(profileName) to cache file \(file.lastPathComponent)")
                    }

                    // Return token if not expired
                    if iamCredentials.credentials.expiration > Date() {
                        return SSOToken(expiresAt: iamCredentials.credentials.expiration)
                    }
                }
            } catch {
                print("SessionManager: Error parsing \(file.lastPathComponent): \(error)")
            }
        }

        print("SessionManager: No valid credentials found in CLI cache for \(profileName)")
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
        isCleanDisconnect = true
        sessionTimer?.invalidate()
        sessionTimer = nil
        activeProfile = nil
        expiryDate = nil

        // Reset UI without posting notifications
        DispatchQueue.main.async { [weak self] in
            self?.onSessionUpdate?("Session: --:--:--")
        }
    }

    func stopMonitoring() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        activeProfile = nil
        expiryDate = nil

        // Reset UI
        DispatchQueue.main.async { [weak self] in
            self?.onSessionUpdate?("Session: --:--:--")
        }

        if !isCleanDisconnect {
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionMonitoringStopped),
                object: nil
            )
        }
        isCleanDisconnect = false
    }

    func renewSession() async throws {
        guard let profile = activeProfile else {
            throw SessionError.noActiveProfile
        }

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
        // Invalidate any existing timer
        sessionTimer?.invalidate()

        // IMPORTANT: We need to be on the main thread when starting UI timers
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Create a new timer that fires every second
            self.sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkSessionStatus()
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
        guard !isCleanDisconnect else { return }

        // Only refresh expiration time occasionally, not every check
        let now = Date()
        if expiryRefreshTime == nil || now.timeIntervalSince(expiryRefreshTime!) > 60 {
            expiryRefreshTime = now

            // Re-check the expiration time
            if let profileName = activeProfile {
                Task {
                    if let cacheFilename = profileCacheFileMap[profileName],
                       let token = try? await readCredentialsFromCacheFile(cacheFilename) {
                        await MainActor.run {
                            if expiryDate != token.expiresAt {
                                expiryDate = token.expiresAt
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
        DispatchQueue.main.async { [weak self] in
            self?.onSessionUpdate?(timeString)
        }

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
