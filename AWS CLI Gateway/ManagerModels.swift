import Foundation

// Role Manager
struct Role: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let arn: String
}

class RoleManager {
    static let shared = RoleManager()
    private let fileManager = FileManager.default

    private var roles: [Role] = []

    private var configURL: URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let awsDirectoryURL = appSupportURL.appendingPathComponent("AWS CLI Gateway", isDirectory: true)

        if !fileManager.fileExists(atPath: awsDirectoryURL.path) {
            do {
                try fileManager.createDirectory(at: awsDirectoryURL, withIntermediateDirectories: true)
            } catch {
                print("Error creating directory: \(error)")
                return nil
            }
        }

        return awsDirectoryURL.appendingPathComponent("role_manager.json")
    }

    init() {
        loadRoles()

        // If no roles exist, populate with default roles
        if roles.isEmpty {
            populateDefaultRoles()
        }
    }

    func loadRoles() {
        guard let configURL = configURL,
              fileManager.fileExists(atPath: configURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            roles = try JSONDecoder().decode([Role].self, from: data)
        } catch {
            print("Error loading roles: \(error)")
        }
    }

    func saveRoles() {
        guard let configURL = configURL else { return }

        do {
            let data = try JSONEncoder().encode(roles)
            try data.write(to: configURL)
        } catch {
            print("Error saving roles: \(error)")
        }
    }

    func getRoles() -> [Role] {
        return roles
    }

    func addRole(_ role: Role) {
        if !roles.contains(where: { $0.name == role.name }) {
            roles.append(role)
            saveRoles()
        }
    }

    func deleteRole(named name: String) {
        print("Deleting role: \(name)")
        roles.removeAll(where: { $0.name == name })
        saveRoles()
        
        print("Roles after deletion: \(roles.map { $0.name })")
    }

    private func populateDefaultRoles() {
        roles = []
        saveRoles()
    }
}

// Permission Set Manager
struct PermissionSet: Codable, Identifiable, Equatable {
    var id: String { displayName }
    let displayName: String
    let permissionSetName: String
}

class PermissionSetManager {
    static let shared = PermissionSetManager()
    private let fileManager = FileManager.default

    private var permissionSets: [PermissionSet] = []

    private var configURL: URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let awsDirectoryURL = appSupportURL.appendingPathComponent("AWS CLI Gateway", isDirectory: true)

        if !fileManager.fileExists(atPath: awsDirectoryURL.path) {
            do {
                try fileManager.createDirectory(at: awsDirectoryURL, withIntermediateDirectories: true)
            } catch {
                print("Error creating directory: \(error)")
                return nil
            }
        }

        return awsDirectoryURL.appendingPathComponent("permission_set_manager.json")
    }

    init() {
        loadPermissionSets()

        // If no permission sets exist, populate with default ones
        if permissionSets.isEmpty {
            populateDefaultPermissionSets()
        }
    }

    func loadPermissionSets() {
        guard let configURL = configURL,
              fileManager.fileExists(atPath: configURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            permissionSets = try JSONDecoder().decode([PermissionSet].self, from: data)
        } catch {
            print("Error loading permission sets: \(error)")
        }
    }

    func savePermissionSets() {
        guard let configURL = configURL else { return }

        do {
            let data = try JSONEncoder().encode(permissionSets)
            try data.write(to: configURL)
        } catch {
            print("Error saving permission sets: \(error)")
        }
    }

    func getPermissionSets() -> [PermissionSet] {
        return permissionSets
    }

    func addPermissionSet(_ permissionSet: PermissionSet) {
        if !permissionSets.contains(where: { $0.displayName == permissionSet.displayName }) {
            permissionSets.append(permissionSet)
            savePermissionSets()
        }
    }

    func deletePermissionSet(named name: String) {
        print("Deleting permission set: \(name)")
        permissionSets.removeAll(where: { $0.displayName == name })
        savePermissionSets()

        print("Permission sets after deletion: \(permissionSets.map { $0.displayName })")
    }

    private func populateDefaultPermissionSets() {
        // Start with an empty array - no default permission sets
        permissionSets = []
        savePermissionSets()
    }

}
