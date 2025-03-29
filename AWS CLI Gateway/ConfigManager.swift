import Foundation

protocol AWSProfile {
    var name: String { get }
    var region: String { get }
    var isDefault: Bool { get }
    var displayName: String { get }
}

extension SSOProfile: AWSProfile {
    var isDefault: Bool {
        name == "default"
    }
    
    var displayName: String {
        if isDefault {
            return ProfileHistoryManager.shared.getDefaultProfileOriginalName() ?? name
        }
        return name
    }
}

extension IAMProfile: AWSProfile {
    var isDefault: Bool {
        name == "default"
    }
    
    var displayName: String {
        if isDefault {
            return ProfileHistoryManager.shared.getDefaultProfileOriginalName() ?? name
        }
        return name
    }
}

class ConfigManager {
    static let shared = ConfigManager()
    
    private let awsDirectory: URL
    private let configFile: URL
    private let cacheDirectory: URL
    private var defaultProfileOriginalName: String?
    
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
    
    // MARK: - Default Profile Management
    func setDefaultProfile(_ profileName: String) throws {
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else {
            throw ConfigError.fileReadError
        }
        
        // Get all profiles to work with
        let profiles = getProfiles()
        guard let targetProfile = profiles.first(where: { $0.name == profileName }) else {
            throw ConfigError.invalidProfile
        }
        
        // Parse the AWS config file to find all blocks
        let lines = content.components(separatedBy: .newlines)
        var blocks: [String: [String]] = [:]
        var currentBlockHeader: String? = nil
        var currentBlockContent: [String] = []
        
        // First pass: collect all blocks with their content
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Save previous block if exists
                if let header = currentBlockHeader, !currentBlockContent.isEmpty {
                    blocks[header] = currentBlockContent
                }
                
                // Start new block
                currentBlockHeader = trimmed
                currentBlockContent = []
            } else if !trimmed.isEmpty, let _ = currentBlockHeader {
                // Add line to current block
                currentBlockContent.append(line)
            }
        }
        
        // Save the last block
        if let header = currentBlockHeader, !currentBlockContent.isEmpty {
            blocks[header] = currentBlockContent
        }
        
        // Find the target profile block and default block
        let targetProfileHeader = "[profile \(profileName)]"
        let defaultHeader = "[default]"
        
        // Get content for target profile and default (if exists)
        let targetContent = blocks[targetProfileHeader] ?? []
        let defaultContent = blocks[defaultHeader] ?? []
        
        // Extract the ID from targetContent if it exists
        var targetProfileId: String? = nil
        for line in targetContent {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("id = ") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    targetProfileId = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        // Extract the ID from defaultContent if it exists
        var defaultProfileId: String? = nil
        for line in defaultContent {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("id = ") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    defaultProfileId = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        // For IAM profiles, preserve the sso-session block
        var ssoSessionHeader: String? = nil
        var ssoSessionContent: [String]? = nil
        
        if targetProfile is IAMProfile {
            // Find the associated SSO session for the IAM profile
            if let iamProfile = targetProfile as? IAMProfile {
                ssoSessionHeader = "[sso-session \(iamProfile.ssoSession)]"
                ssoSessionContent = blocks[ssoSessionHeader ?? ""] ?? []
            }
        }
        
        // Check if the current default is an IAM profile
        let isCurrentDefaultIAM = defaultProfileId != nil &&
                                  ProfileHistoryManager.shared.getProfileInfo(withId: defaultProfileId ?? "")?.profileType == .iam
        
        // If the current default is an IAM profile, restore relationship
        if isCurrentDefaultIAM, let defaultId = defaultProfileId,
           let previousDefaultInfo = ProfileHistoryManager.shared.getProfileInfo(withId: defaultId),
           let linkedToId = previousDefaultInfo.linkedToId,
           let linkedToName = ProfileHistoryManager.shared.getProfileNameById(linkedToId) {
            
            // Previous default was an IAM profile, restore its source_profile relationship
            let previousDefaultName = previousDefaultInfo.originalName
            let previousDefaultHeader = "[profile \(previousDefaultName)]"
            
            // Create or update the profile block for the previous default
            var previousDefaultContent: [String] = []
            
            // Copy content from default, but update source_profile
            for line in defaultContent {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                if trimmed.hasPrefix("source_profile = ") {
                    // If the linked profile is becoming the new default, use "default"
                    if linkedToId == targetProfileId {
                        previousDefaultContent.append("source_profile = default")
                    } else {
                        // Otherwise use the linked profile's name
                        previousDefaultContent.append("source_profile = \(linkedToName)")
                    }
                } else {
                    previousDefaultContent.append(line)
                }
            }
            
            // Remove any existing profile with this name to avoid duplicates
            blocks.removeValue(forKey: previousDefaultHeader)
            
            // Update the blocks with the restored profile
            blocks[previousDefaultHeader] = previousDefaultContent
        }
        
        // Update relationships for the new default profile
        updateRelationshipsForDefault(profileName: profileName, profileId: targetProfileId, blocks: &blocks)
        
        // Build new config content
        var newContent = ""
        
        // Update the profile history to mark this profile as default
        if let targetId = targetProfileId {
            ProfileHistoryManager.shared.setDefaultProfileById(targetId)
        } else {
            ProfileHistoryManager.shared.setDefaultProfile(profileName)
        }
        
        // First add the default (which will be the target profile's content)
        // Use the updated content from blocks
        let updatedTargetContent = blocks[targetProfileHeader] ?? targetContent
        
        newContent += defaultHeader + "\n"
        for line in updatedTargetContent {
            newContent += line + "\n"
        }
        newContent += "\n"
        
        // If there was a default profile, rename it
        if !defaultContent.isEmpty && profileName != "default" {
            // Get the original default profile name from history if available
            let previousDefaultName: String
            if let defaultId = defaultProfileId,
               let originalName = ProfileHistoryManager.shared.getProfileNameById(defaultId) {
                 previousDefaultName = originalName
            } else {
                // Fallback
                previousDefaultName = ProfileHistoryManager.shared.getDefaultProfileOriginalName() ?? (profileName + "-previous")
            }
            
            // Only add this profile if it's not the one becoming default
            if previousDefaultName != profileName {
                // Remove any existing profile with this name to avoid duplicates
                blocks.removeValue(forKey: "[profile \(previousDefaultName)]")
                
                newContent += "[profile \(previousDefaultName)]" + "\n"
                for line in defaultContent {
                    newContent += line + "\n"
                }
                newContent += "\n"
            }
        }
        
        // Add all other blocks except previously handled
        for (header, content) in blocks {
            // Skip empty blocks and the blocks we've already handled
            if header != defaultHeader && header != targetProfileHeader && header != ssoSessionHeader && !content.isEmpty {
                newContent += header + "\n"
                for line in content {
                    newContent += line + "\n"
                }
                newContent += "\n"
            }
        }
        
        // If there is a SSO session block, add it to the end
        if let header = ssoSessionHeader, let content = ssoSessionContent {
            newContent += header + "\n"
            for line in content {
                newContent += line + "\n"
            }
            newContent += "\n"
        }
        
        // Write the updated content
        do {
            try newContent.write(to: configFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        } catch {
            throw ConfigError.fileWriteError
        }
        
        updateIAMProfileSourceReferences()
        
        // Sync profiles with history after changes
        syncProfilesWithHistory()
        
        // Notify observers that profiles have been updated
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.profilesUpdated),
            object: nil
        )
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
        let sourceProfileId: String?
        if profile.sourceProfile == "default" {
            sourceProfileId = ProfileHistoryManager.shared.getDefaultProfileId()
        } else {
            sourceProfileId = ProfileHistoryManager.shared.getIdForProfile(profile.sourceProfile)
        }

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
        
        // Find the default profile info
        let _ = allProfileInfos.first(where: { $0.isDefault })
        
        // Find all IAM profiles that might need updating
        let iamProfileInfos = allProfileInfos.filter { $0.profileType == .iam }
        
        var updatedContent = content
        
        // For each IAM profile
        for iamProfile in iamProfileInfos {
            guard let linkedToId = iamProfile.linkedToId,
                  let linkedProfile = allProfileInfos.first(where: { $0.id == linkedToId }) else {
                continue
            }
            
            // Determine if this profile should reference "default" or the original name
            let shouldUseDefault = linkedProfile.isDefault
            let correctSourceProfile = shouldUseDefault ? "default" : linkedProfile.originalName
            
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
                                with: "source_profile = \(correctSourceProfile)"
                            )
                            
                            // Replace the entire block in the content
                            updatedContent = updatedContent.replacingCharacters(
                                in: blockRange,
                                with: updatedBlock
                            )
                            
                            print("Updated IAM profile \(iamProfile.originalName) to use source_profile = \(correctSourceProfile)")
                        } else {
                            // If source_profile line doesn't exist, add it
                            let updatedBlock = profileBlock.trimmingCharacters(in: .whitespacesAndNewlines) +
                                              "\nsource_profile = \(correctSourceProfile)\n"
                            
                            updatedContent = updatedContent.replacingCharacters(
                                in: blockRange,
                                with: updatedBlock
                            )
                            
                            print("Added source_profile = \(correctSourceProfile) to IAM profile \(iamProfile.originalName)")
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
    
    private func updateRelationshipsForDefault(
        profileName: String,
        profileId: String?,
        blocks: inout [String: [String]]
    ) {
        // Identify the profile ID of the new default profile
        let newDefaultId = profileId ?? ProfileHistoryManager.shared.getIdForProfile(profileName)
        
        // Update profile_history.json to mark the new profile as default
        if let id = newDefaultId {
            ProfileHistoryManager.shared.setDefaultProfileById(id)
        } else {
            ProfileHistoryManager.shared.setDefaultProfile(profileName)
        }
        
        // Get all profiles from history after updating the default
        let allProfileInfos = ProfileHistoryManager.shared.getAllProfiles()
        
        // Find all IAM profiles
        let iamProfileInfos = allProfileInfos.filter { $0.profileType == .iam }
        
        // Process each IAM profile
        for iamProfileInfo in iamProfileInfos {
            // Skip if no linked profile
            guard let linkedToId = iamProfileInfo.linkedToId else { continue }
            
            // Find the linked profile info
            guard let linkedProfileInfo = allProfileInfos.first(where: { $0.id == linkedToId }) else { continue }
            
            // Find this IAM profile in the blocks
            let profileHeader = "[profile \(iamProfileInfo.originalName)]"
            let profileContent = blocks[profileHeader] ?? []
            
            // Skip if profile doesn't exist in blocks
            if profileContent.isEmpty { continue }
            
            // Create updated content with correct source_profile and sso_session
            var updatedContent: [String] = []
            var sourceProfileUpdated = false
            var ssoSessionUpdated = false
            
            for line in profileContent {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                if trimmed.hasPrefix("source_profile = ") {
                    // If linked profile is default, use "default", otherwise use the original name
                    if linkedProfileInfo.isDefault {
                        updatedContent.append("source_profile = default")
                    } else {
                        updatedContent.append("source_profile = \(linkedProfileInfo.originalName)")
                    }
                    sourceProfileUpdated = true
                } else if trimmed.hasPrefix("sso_session = ") {
                    // Always use the original name for sso_session, never "default"
                    updatedContent.append("sso_session = \(linkedProfileInfo.originalName)")
                    ssoSessionUpdated = true
                } else {
                    updatedContent.append(line)
                }
            }
            
            // If source_profile wasn't found, add it
            if !sourceProfileUpdated {
                if linkedProfileInfo.isDefault {
                    updatedContent.append("source_profile = default")
                } else {
                    updatedContent.append("source_profile = \(linkedProfileInfo.originalName)")
                }
            }
            
            // If sso_session wasn't found, add it
            if !ssoSessionUpdated {
                updatedContent.append("sso_session = \(linkedProfileInfo.originalName)")
            }
            
            // Update the block with the new content
            blocks[profileHeader] = updatedContent
            
            // Debug output
            print("Updated IAM profile \(iamProfileInfo.originalName):")
            print("  Linked to: \(linkedProfileInfo.originalName) (isDefault: \(linkedProfileInfo.isDefault))")
            print("  Updated source_profile to: \(linkedProfileInfo.isDefault ? "default" : linkedProfileInfo.originalName)")
        }
        
        // Debug output of all blocks after updates
        print("All blocks after updates:")
        for (header, content) in blocks {
            print("\(header):")
            for line in content {
                print("  \(line)")
            }
        }
        
        // Update profile_history.json to mark the new profile as default
        if let newDefaultId = profileId ?? ProfileHistoryManager.shared.getIdForProfile(profileName) {
            ProfileHistoryManager.shared.setDefaultProfileById(newDefaultId)
        } else {
            ProfileHistoryManager.shared.setDefaultProfile(profileName)
        }
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
