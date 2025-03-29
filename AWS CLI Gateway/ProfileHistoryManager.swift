import Foundation

/// Manages the history of profile names and their mappings
class ProfileHistoryManager {
    static let shared = ProfileHistoryManager()

    // File path for storing profile history
    private let historyFile: URL

    // Optimization for disk writes
    private var isDirty = false
    private var saveDebounceTimer: Timer?
    private let saveDebounceInterval: TimeInterval = 2.0 // Only save at most once every 2 seconds
    private var forceNextSave = false // For critical updates like connection status

    // Track all profiles with their original names
    private var profiles: [ProfileInfo] = []

    // Model for profile info
    struct ProfileInfo: Codable {
        let originalName: String
        let id: String
        var linkedToId: String?  // ID of a profile this one depends on
        var profileType: ProfileType  // Type of profile (SSO or IAM)
        var isConnected: Bool = false

        init(
            originalName: String,
            id: String = UUID().uuidString,
            linkedToId: String? = nil,
            profileType: ProfileType = .sso,
            isConnected: Bool = false
        ) {
            self.originalName = originalName
            self.id = id
            self.linkedToId = linkedToId
            self.profileType = profileType
            self.isConnected = isConnected
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

    /// Sets a profile as the connected profile (currently active)
    func setConnectedProfile(_ profileName: String) {
        // Reset all profiles to disconnected
        for i in 0..<profiles.count {
            profiles[i].isConnected = false
        }

        // Find and mark the new connected profile
        if let index = profiles.firstIndex(where: { $0.originalName == profileName }) {
            profiles[index].isConnected = true
        } else if let index = profiles.firstIndex(where: { $0.id == profileName }) {
            // If provided an ID instead of a name
            profiles[index].isConnected = true
        } else {
            // If profile doesn't exist yet, do nothing (this shouldn't happen normally)
            print("Warning: Tried to set non-existent profile \(profileName) as connected")
        }

        // Connection status changes are critical - save immediately
        saveProfiles(immediate: true)
    }

    /// Sets a profile as the connected profile by ID
    func setConnectedProfileById(_ id: String) {
        // Reset all profiles to disconnected
        for i in 0..<profiles.count {
            profiles[i].isConnected = false
        }

        // Find and mark the new connected profile
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].isConnected = true
            // Connection status changes are critical - save immediately
            saveProfiles(immediate: true)
        }
    }

    /// Clears the connected status from all profiles
    func clearConnectedProfile() {
        // Reset all profiles to disconnected
        for i in 0..<profiles.count {
            profiles[i].isConnected = false
        }
        // Connection status changes are critical - save immediately
        saveProfiles(immediate: true)
    }

    /// Gets the currently connected profile
    func getConnectedProfile() -> ProfileInfo? {
        return profiles.first(where: { $0.isConnected })
    }

    /// Gets the original name for the connected profile
    func getConnectedProfileOriginalName() -> String? {
        return profiles.first(where: { $0.isConnected })?.originalName
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
        // This ensures we can properly restore profile names if they become active later

        saveProfiles()
    }

    /// Removes a profile from tracking
    func removeProfile(_ profileName: String) {
        if let index = profiles.firstIndex(where: { $0.originalName == profileName }) {
            profiles.remove(at: index)
            saveProfiles()
        }
    }

    /// Get profile ID by name
    func getIdForProfile(_ profileName: String) -> String? {
        return profiles.first(where: { $0.originalName == profileName })?.id
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

        return sourceProfile.originalName
    }

    func getProfileInfo(withId id: String) -> ProfileInfo? {
        return profiles.first(where: { $0.id == id })
    }

    func getAllProfiles() -> [ProfileInfo] {
        return profiles
    }

    /// Forces any pending changes to be saved immediately
    func persistChanges() {
        forceSave()
    }

    // MARK: - Private Methods

    private func saveProfiles(immediate: Bool = false) {
        // Mark as dirty
        isDirty = true

        if immediate {
            // If immediate save is requested, cancel any pending timer and save now
            forceNextSave = true
            saveDebounceTimer?.invalidate()
            forceSave()
            return
        }

        // Otherwise use the debounce approach
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            self?.forceSave()
        }
    }

    private func forceSave() {
        guard isDirty else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(profiles)
            try data.write(to: historyFile)
            isDirty = false
            forceNextSave = false
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

            // Try to decode with the current format
            do {
                // First try decoding with the current format
                profiles = try decoder.decode([ProfileInfo].self, from: data)
            } catch {
                // If that fails, try to decode with older formats and migrate

                // Define a struct that includes the isDefault property for migration
                struct OldProfileInfo: Codable {
                    let originalName: String
                    let isDefault: Bool
                    let id: String?
                    var linkedToId: String?
                    var profileType: ProfileType?
                    var isConnected: Bool?
                }

                do {
                    let oldProfiles = try decoder.decode([OldProfileInfo].self, from: data)

                    // Migrate old format to new format
                    profiles = oldProfiles.map { old in
                        ProfileInfo(
                            originalName: old.originalName,
                            id: old.id ?? UUID().uuidString,
                            linkedToId: old.linkedToId,
                            profileType: old.profileType ?? .sso,
                            isConnected: old.isConnected ?? false
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
