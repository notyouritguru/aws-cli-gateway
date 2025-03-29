import Foundation

/// Manages the history of profile names and their mappings
class ProfileHistoryManager {
    static let shared = ProfileHistoryManager()
    
    // File path for storing profile history
    private let historyFile: URL
    
    // Track all profiles with their original names and default status
    private var profiles: [ProfileInfo] = []
    
    // Model for profile info
    struct ProfileInfo: Codable {
        let originalName: String
        var isDefault: Bool
        let id: String
        var linkedToId: String?  // ID of a profile this one depends on
        var profileType: ProfileType  // Type of profile (SSO or IAM)
        
        init(
            originalName: String,
            isDefault: Bool = false,
            id: String = UUID().uuidString,
            linkedToId: String? = nil,
            profileType: ProfileType = .sso
        ) {
            self.originalName = originalName
            self.isDefault = isDefault
            self.id = id
            self.linkedToId = linkedToId
            self.profileType = profileType
        }
    }
    
    // Type of profile
    enum ProfileType: String, Codable {
        case sso
        case iam
    }
    
    private init() {
        // Get the app's Application Support directory
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupportDir.appendingPathComponent("AWS CLI Gateway")
        
        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        
        // Set up history file
        historyFile = appDir.appendingPathComponent("profile_history.json")
        
        // Load existing mappings
        loadProfiles()
    }
    
    // MARK: - Public Methods
    
    /// Adds a profile to be tracked if it doesn't exist
    func trackProfile(_ profileName: String, profileType: ProfileType = .sso) {
        if !profiles.contains(where: { $0.originalName == profileName }) {
            profiles.append(ProfileInfo(originalName: profileName, profileType: profileType))
            saveProfiles()
        }
    }
    
    /// Sets a profile as the default
    func setDefaultProfile(_ profileName: String) {
        // Reset all profiles to non-default
        for i in 0..<profiles.count {
            profiles[i].isDefault = false
        }
        
        // Find and mark the new default
        if let index = profiles.firstIndex(where: { $0.originalName == profileName }) {
            profiles[index].isDefault = true
        } else {
            // If profile doesn't exist yet, add it
            profiles.append(ProfileInfo(originalName: profileName, isDefault: true))
        }
        
        saveProfiles()
    }
    
    /// Gets the original name for the default profile
    func getDefaultProfileOriginalName() -> String? {
        return profiles.first(where: { $0.isDefault })?.originalName
    }
    
    /// Gets the ID of the default profile
    func getDefaultProfileId() -> String? {
        return profiles.first(where: { $0.isDefault })?.id
    }
    
    /// Syncs profiles with the current config file profiles
    func syncWithConfigProfiles(_ configProfiles: [String]) {
        // Add any new profiles from config
        for profileName in configProfiles {
            if !profiles.contains(where: { $0.originalName == profileName }) {
                profiles.append(ProfileInfo(originalName: profileName))
            }
        }
        
        // IMPORTANT: Keep all profiles in our history, even if they're not in the config anymore
        // This ensures we can properly restore profile names if they become default later
        
        saveProfiles()
    }
    
    /// Removes a profile from tracking
    func removeProfile(_ profileName: String) {
        // Only remove if it's not the default profile
        if let index = profiles.firstIndex(where: { $0.originalName == profileName && !$0.isDefault }) {
            profiles.remove(at: index)
            saveProfiles()
        }
    }
    
    /// Get profile ID by name
    func getIdForProfile(_ profileName: String) -> String? {
        return profiles.first(where: { $0.originalName == profileName })?.id
    }
    
    /// Set default profile by ID
    func setDefaultProfileById(_ id: String) {
        // Reset all profiles to non-default
        for i in 0..<profiles.count {
            profiles[i].isDefault = false
        }
        
        // Find and mark the new default
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].isDefault = true
            saveProfiles()
        }
    }
    
    /// Get profile name by ID
    func getProfileNameById(_ id: String) -> String? {
        return profiles.first(where: { $0.id == id })?.originalName
    }
    
    /// Track profile with ID
    func trackProfile(
        _ profileName: String,
        withId id: String,
        linkedToId: String? = nil,
        profileType: ProfileType = .sso
    ) {
        if let index = profiles.firstIndex(where: { $0.originalName == profileName }) {
            // Profile exists, update the linkedToId if provided
            if let linkedToId = linkedToId {
                profiles[index].linkedToId = linkedToId
                profiles[index].profileType = profileType
                saveProfiles()
            }
        } else {
            // New profile, add with the provided ID and link
            profiles.append(ProfileInfo(
                originalName: profileName,
                isDefault: false,
                id: id,
                linkedToId: linkedToId,
                profileType: profileType
            ))
            saveProfiles()
        }
    }
    
    /// Get all profiles that link to a specific profile ID
    func getProfilesLinkedTo(id: String) -> [ProfileInfo] {
        return profiles.filter { $0.linkedToId == id }
    }
    
    /// Get the source profile name for an IAM profile
    func getSourceProfileName(forIamProfile profileName: String) -> String? {
        guard let profileInfo = profiles.first(where: { $0.originalName == profileName && $0.profileType == .iam }),
              let linkedId = profileInfo.linkedToId,
              let sourceProfile = profiles.first(where: { $0.id == linkedId }) else {
            return nil
        }
        
        // If the linked profile is now the default, return "default"
        if sourceProfile.isDefault {
            return "default"
        }
        
        return sourceProfile.originalName
    }
    
    func getProfileInfo(withId id: String) -> ProfileInfo? {
        return profiles.first(where: { $0.id == id })
    }
    
    func getAllProfiles() -> [ProfileInfo] {
        return profiles
    }
    
    // MARK: - Private Methods
    
    private func saveProfiles() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(profiles)
            try data.write(to: historyFile)
            print("Saved profile history: \(profiles)")
        } catch {
            print("Error saving profile history: \(error)")
        }
    }
    
    private func loadProfiles() {
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            print("Profile history file does not exist yet")
            return
        }
        
        do {
            let data = try Data(contentsOf: historyFile)
            let decoder = JSONDecoder()
            
            // Try to decode with the new format first
            do {
                profiles = try decoder.decode([ProfileInfo].self, from: data)
            } catch {
                // If that fails, try to decode with the old format and migrate
                do {
                    struct OldProfileInfo: Codable {
                        let originalName: String
                        let isDefault: Bool
                    }
                    
                    let oldProfiles = try decoder.decode([OldProfileInfo].self, from: data)
                    
                    // Migrate old format to new format
                    profiles = oldProfiles.map { old in
                        ProfileInfo(
                            originalName: old.originalName,
                            isDefault: old.isDefault
                        )
                    }
                    
                    // Save in the new format
                    saveProfiles()
                } catch {
                    print("Error decoding profile history, starting fresh: \(error)")
                    profiles = []
                    saveProfiles()
                }
            }
            
            print("Loaded profiles: \(profiles)")
        } catch {
            print("Error loading profile history: \(error)")
            profiles = []
            saveProfiles()
        }
    }
}
