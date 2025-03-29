import Foundation

protocol AWSProfile {
    var name: String { get }
    var region: String { get }
    var displayName: String { get }
}

extension SSOProfile: AWSProfile {
    var displayName: String {
        return name
    }
}

extension IAMProfile: AWSProfile {
    var displayName: String {
        return name
    }
}

class ConfigManager {
    static let shared = ConfigManager()

    private let awsDirectory: URL
    private let configFile: URL
    private let cacheDirectory: URL

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.awsDirectory = homeDir.appendingPathComponent(".aws")
        self.configFile = awsDirectory.appendingPathComponent("config")
        self.cacheDirectory = awsDirectory.appendingPathComponent("cli/cache")
        ensureDirectoryPermissions()
    }

    // MARK: - Setup & Permissions

    func ensureDirectoryPermissions() {
        let fileManager = FileManager.default

        do {
            // Create .aws directory if it doesn't exist
            if !fileManager.fileExists(atPath: awsDirectory.path) {
                try fileManager.createDirectory(at: awsDirectory, withIntermediateDirectories: true, attributes: nil)
            }

            // Set permissions for .aws directory (700)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: awsDirectory.path)

            // Create and set permissions for config file (600)
            if !fileManager.fileExists(atPath: configFile.path) {
                try "".write(to: configFile, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)

            // Ensure cli/cache directory exists with proper permissions
            if !fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)

            // Recursively set permissions for all files and directories in .aws
            let enumerator = fileManager.enumerator(at: awsDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            while let url = enumerator?.nextObject() as? URL {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // Directories get 700
                        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                    } else {
                        // Files get 600
                        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                }
            }

        } catch {
            print("Error setting up AWS directory permissions: \(error)")
        }
    }

    func syncProfilesWithHistory() {
        // Get all profile names from the config file
        let profileNames = getProfiles().map { $0.name }

        // Remove "default" from the list
        let nonDefaultProfiles = profileNames.filter { $0 != "default" }

        // Sync with history manager
        ProfileHistoryManager.shared.syncWithConfigProfiles(nonDefaultProfiles)
    }

    // MARK: - Profile Management
    func getProfiles() -> [AWSProfile] {
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else {
            return []
        }

        var sessionBlocks: [String: [String: String]] = [:]
        var profileBlocks: [String: [String: String]] = [:]
        var profileIds: [String: String] = [:]

        var currentBlockName: String? = nil
        var currentBlockType: String? = nil
        var currentProperties: [String: String] = [:]

        func finishBlock() {
            guard let blockName = currentBlockName,
                  let blockType = currentBlockType else { return }
            if blockType == "sso-session" {
                sessionBlocks[blockName] = currentProperties
            } else if blockType == "profile" || blockType == "default" {
                profileBlocks[blockName] = currentProperties

                // Extract ID if it exists
                if let id = currentProperties["id"] {
                    profileIds[blockName] = id
                }
            }
            currentBlockName = nil
            currentBlockType = nil
            currentProperties.removeAll()
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                finishBlock()

                let inside = trimmed.dropFirst().dropLast()
                if inside == "default" {
                    currentBlockType = "default"
                    currentBlockName = "default"
                } else {
                    let parts = inside.split(separator: " ", maxSplits: 1).map { String($0) }
                    if parts.count == 2 {
                        currentBlockType = parts[0]
                        currentBlockName = parts[1]
                    }
                }
            } else if trimmed.contains("=") {
                let propertyParts = trimmed.components(separatedBy: "=")
                if propertyParts.count == 2 {
                    let key = propertyParts[0].trimmingCharacters(in: .whitespaces)
                    let val = propertyParts[1].trimmingCharacters(in: .whitespaces)
                    currentProperties[key] = val
                }
            }
        }

        finishBlock()

        var profiles: [AWSProfile] = []

        for (profileName, props) in profileBlocks {
            // Extract the ID for this profile
            let profileId = profileIds[profileName] ?? UUID().uuidString

            if let roleArn = props["role_arn"] {
                if let sourceProfile = props["source_profile"],
                   let ssoSession = props["sso_session"],
                   let region = props["region"] {
                    let iamProfile = IAMProfile(
                        name: profileName,
                        sourceProfile: sourceProfile,
                        ssoSession: ssoSession,
                        roleArn: roleArn,
                        region: region,
                        output: props["output"] ?? "json"
                    )
                    profiles.append(iamProfile)

                    // Track this profile with its ID
                    if profileName != "default" {
                        // Get the source profile's ID for relationship tracking
                        let sourceProfileId = profileIds[sourceProfile]

                        // Track this IAM profile with its source relationship
                        ProfileHistoryManager.shared.trackProfile(
                            profileName,
                            withId: profileId,
                            linkedToId: sourceProfileId,
                            profileType: .iam
                        )
                    }
                }
            } else {
                guard let sessionName = props["sso_session"],
                      let accountId = props["sso_account_id"],
                      let roleName = props["sso_role_name"] else {
                    continue
                }

                let sessionProps = sessionBlocks[sessionName] ?? [:]
                guard let startUrl = sessionProps["sso_start_url"],
                      let ssoRegion = sessionProps["sso_region"] else {
                    continue
                }

                let ssoProfile = SSOProfile(
                    name: profileName,
                    startUrl: startUrl,
                    region: ssoRegion,
                    accountId: accountId,
                    roleName: roleName,
                    output: props["output"] ?? "json"
                )
                profiles.append(ssoProfile)

                // Track this profile with its ID
                if profileName != "default" {
                    ProfileHistoryManager.shared.trackProfile(
                        profileName,
                        withId: profileId,
                        profileType: .sso
                    )
                }
            }
        }

        updateIAMProfileSourceReferences()

        return profiles
    }

    func saveProfile(_ profile: SSOProfile) throws {
        guard profile.validate() else {
            throw ConfigError.invalidProfile
        }

        let currentContent = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""

        let profileId = ProfileHistoryManager.shared.getIdForProfile(profile.name) ?? UUID().uuidString

        ProfileHistoryManager.shared.trackProfile(profile.name, withId: profileId)

        var newContent = removeBlock(named: profile.name, type: "sso-session", from: currentContent)
        newContent = removeBlock(named: profile.name, type: "profile", from: newContent)

        let newBlocks = """
        [sso-session \(profile.name)]
        sso_start_url = \(profile.startUrl)
        sso_region = \(profile.region)
        sso_registration_scopes = sso:account:access

        [profile \(profile.name)]
        sso_session = \(profile.name)
        sso_account_id = \(profile.accountId)
        sso_role_name = \(profile.roleName)
        region = \(profile.region)
        output = \(profile.output)
        id = \(profileId)

        """

        let finalContent = newContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + newBlocks

        do {
            try finalContent.write(to: configFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        } catch {
            throw ConfigError.fileWriteError
        }
    }


    func saveIAMProfile(_ profile: IAMProfile) throws {
        guard profile.validate() else {
            throw ConfigError.invalidProfile
        }

        let currentContent = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        let newContent = removeBlock(named: profile.name, type: "profile", from: currentContent)

        // Generate or retrieve ID for this profile
        let profileId = ProfileHistoryManager.shared.getIdForProfile(profile.name) ?? UUID().uuidString

        // Get the source profile's ID for relationship tracking
        let sourceProfileId = ProfileHistoryManager.shared.getIdForProfile(profile.sourceProfile)

        // Track this IAM profile with its source relationship
        ProfileHistoryManager.shared.trackProfile(
            profile.name,
            withId: profileId,
            linkedToId: sourceProfileId,
            profileType: .iam
        )

        // Use the sso_session value from the profile object
        let newBlock = """
        [profile \(profile.name)]
        source_profile = \(profile.sourceProfile)
        sso_session = \(profile.ssoSession)
        role_arn = \(profile.roleArn)
        region = \(profile.region)
        output = \(profile.output)
        id = \(profileId)

        """

        let finalContent = newContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + newBlock

        do {
            try finalContent.write(to: configFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        } catch {
            throw ConfigError.fileWriteError
        }

        updateIAMProfileSourceReferences()
    }


    func deleteProfile(_ profileName: String) {
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else { return }

        var newContent = removeBlock(named: profileName, type: "sso-session", from: content)
        newContent = removeBlock(named: profileName, type: "profile", from: newContent)

        try? newContent.write(to: configFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)

    }

    func clearCache() {
        do {
            // Check if the cache directory exists
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                // Remove all contents of the cache directory
                let cacheContents = try FileManager.default.contentsOfDirectory(
                    at: cacheDirectory,
                    includingPropertiesForKeys: nil,
                    options: []
                )

                for fileURL in cacheContents {
                    try FileManager.default.removeItem(at: fileURL)
                }

                print("Cleared AWS CLI cache")
            } else {
                // Create the cache directory if it doesn't exist
                try FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                print("Created AWS CLI cache directory")
            }
        } catch {
            print("Error clearing AWS CLI cache: \(error)")
        }
    }

    func fixAllProfileReferences() {
        updateIAMProfileSourceReferences()
        print("Fixed all IAM profile references")
    }

    func updateIAMProfileSourceReferences() {
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else { return }

        // Get all profile infos from history
        let allProfileInfos = ProfileHistoryManager.shared.getAllProfiles()

        // Find all IAM profiles that might need updating
        let iamProfileInfos = allProfileInfos.filter { $0.profileType == .iam }

        var updatedContent = content

        // For each IAM profile
        for iamProfile in iamProfileInfos {
            guard let linkedToId = iamProfile.linkedToId,
                  let linkedProfile = allProfileInfos.first(where: { $0.id == linkedToId }) else {
                continue
            }

            // Regex pattern to find this profile's block and source_profile line
            let profilePattern = "\\[profile \\s*\(iamProfile.originalName)\\s*\\](.*?)(?=\\[|$)"
            let sourceProfilePattern = "source_profile\\s*=\\s*[^\\n]+"

            // Find the profile block
            if let regex = try? NSRegularExpression(pattern: profilePattern, options: [.dotMatchesLineSeparators]) {
                let range = NSRange(updatedContent.startIndex..<updatedContent.endIndex, in: updatedContent)

                if let match = regex.firstMatch(in: updatedContent, options: [], range: range),
                   let blockRange = Range(match.range, in: updatedContent) {
                    let profileBlock = String(updatedContent[blockRange])

                    // Find and replace source_profile line
                    if let sourceRegex = try? NSRegularExpression(pattern: sourceProfilePattern, options: []) {
                        let sourceRange = NSRange(profileBlock.startIndex..<profileBlock.endIndex, in: profileBlock)

                        if let sourceMatch = sourceRegex.firstMatch(in: profileBlock, options: [], range: sourceRange),
                           let sourceMatchRange = Range(sourceMatch.range, in: profileBlock) {
                            // Create replacement block with updated source_profile
                            let updatedBlock = profileBlock.replacingCharacters(
                                in: sourceMatchRange,
                                with: "source_profile = \(linkedProfile.originalName)"
                            )

                            // Replace the entire block in the content
                            updatedContent = updatedContent.replacingCharacters(
                                in: blockRange,
                                with: updatedBlock
                            )

                            print("Updated IAM profile \(iamProfile.originalName) to use source_profile = \(linkedProfile.originalName)")
                        } else {
                            // If source_profile line doesn't exist, add it
                            let updatedBlock = profileBlock.trimmingCharacters(in: .whitespacesAndNewlines) +
                                              "\nsource_profile = \(linkedProfile.originalName)\n"

                            updatedContent = updatedContent.replacingCharacters(
                                in: blockRange,
                                with: updatedBlock
                            )

                            print("Added source_profile = \(linkedProfile.originalName) to IAM profile \(iamProfile.originalName)")
                        }
                    }
                }
            }
        }

        // Write the updated content back if changed
        if updatedContent != content {
            do {
                try updatedContent.write(to: configFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
                print("Successfully updated IAM profile source references in config file")
            } catch {
                print("Error writing updated config file: \(error)")
            }
        } else {
            print("No changes needed to IAM profile source references")
        }
    }
    
    // Gets the SSO Session info for a profile
    func getSSOSession(for profile: SSOProfile) -> (startUrl: String, region: String)? {
        // Use the existing configFile property instead of configFilePath
        do {
            let configContent = try String(contentsOf: configFile, encoding: .utf8)
            let lines = configContent.components(separatedBy: CharacterSet.newlines)

            // Find the profile section
            var inProfileSection = false
            var ssoSessionName: String?

            // First find the sso_session name
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: CharacterSet.whitespaces)

                if trimmedLine == "[profile \(profile.name)]" {
                    inProfileSection = true
                    continue
                } else if trimmedLine.hasPrefix("[") && inProfileSection {
                    inProfileSection = false
                    break
                }

                if inProfileSection && trimmedLine.hasPrefix("sso_session") {
                    let parts = trimmedLine.components(separatedBy: "=")
                    if parts.count > 1 {
                        ssoSessionName = parts[1].trimmingCharacters(in: CharacterSet.whitespaces)
                    }
                    break
                }
            }

            // Now find the SSO session details
            if let ssoSessionName = ssoSessionName {
                var startUrl: String?
                var region: String?
                var inSessionSection = false

                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: CharacterSet.whitespaces)

                    if trimmedLine == "[sso-session \(ssoSessionName)]" {
                        inSessionSection = true
                        continue
                    } else if trimmedLine.hasPrefix("[") && inSessionSection {
                        break
                    }

                    if inSessionSection {
                        if trimmedLine.hasPrefix("sso_start_url") {
                            let parts = trimmedLine.components(separatedBy: "=")
                            if parts.count > 1 {
                                startUrl = parts[1].trimmingCharacters(in: CharacterSet.whitespaces)
                            }
                        } else if trimmedLine.hasPrefix("sso_region") {
                            let parts = trimmedLine.components(separatedBy: "=")
                            if parts.count > 1 {
                                region = parts[1].trimmingCharacters(in: CharacterSet.whitespaces)
                            }
                        }

                        if startUrl != nil && region != nil {
                            return (startUrl: startUrl!, region: region!)
                        }
                    }
                }
            }

            // If no SSO session found and profile has startUrl & region, use those
            if !profile.startUrl.isEmpty && !profile.region.isEmpty {
                return (startUrl: profile.startUrl, region: profile.region)
            }

            return nil
        } catch {
            print("Error reading config file: \(error)")
            return nil
        }
    }
    
    func getProfile(_ profileName: String) -> AWSProfile? {
        let profiles = getProfiles()
        return profiles.first(where: { $0.name == profileName })
    }

    private func removeBlock(named blockName: String, type: String, from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var updated: [String] = []
        var skip = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[\(type) \(blockName)]") {
                skip = true
                continue
            }
            if skip && trimmed.hasPrefix("[") {
                skip = false
            }
            if !skip {
                updated.append(line)
            }
        }

        return updated.joined(separator: "\n")
    }

    func getSessionExpiration() -> Date? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sortedFiles = files.filter { $0.pathExtension == "json" }
            .sorted { f1, f2 in
                let d1 = (try? f1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? f2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }

        guard let latestFile = sortedFiles.first else { return nil }

        do {
            let data = try Data(contentsOf: latestFile)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let credentials = json?["Credentials"] as? [String: Any],
               let expirationString = credentials["Expiration"] as? String {
                let formatter = ISO8601DateFormatter()
                return formatter.date(from: expirationString)
            }
        } catch {
            print("Error reading cache file: \(error)")
        }
        return nil
    }
}

struct IAMProfile: Codable {
    let name: String
    let sourceProfile: String
    let ssoSession: String
    let roleArn: String
    let region: String
    let output: String

    init(
        name: String,
        sourceProfile: String,
        ssoSession: String,
        roleArn: String,
        region: String,
        output: String = "json"
    ) {
        self.name = name
        self.sourceProfile = sourceProfile
        self.ssoSession = ssoSession
        self.roleArn = roleArn
        self.region = region
        self.output = output
    }

    func validate() -> Bool {
        !name.isEmpty &&
        !sourceProfile.isEmpty &&
        !ssoSession.isEmpty &&
        !roleArn.isEmpty &&
        !region.isEmpty &&
        !output.isEmpty
    }
}

enum ConfigError: LocalizedError {
    case invalidProfile
    case fileWriteError
    case fileReadError

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "Invalid profile configuration"
        case .fileWriteError:
            return "Failed to write to AWS config file"
        case .fileReadError:
            return "Failed to read AWS config file"
        }
    }
}
