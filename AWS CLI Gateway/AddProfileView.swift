import SwiftUI

struct AddProfileView: View {
    let onClose: () -> Void

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Profile")
                .font(.headline)
                .padding(.top, 15)

            TabView(selection: $selectedTab) {
                SSOProfileTab(onClose: onClose)
                    .tabItem {
                        Label("SSO Profile", systemImage: "person.badge.key")
                    }
                    .tag(0)

                IAMRoleTab(onClose: onClose)
                    .tabItem {
                        Label("IAM Role", systemImage: "key")
                    }
                    .tag(1)
            }
            .frame(height: 230)
        }
        .frame(width: 400)
        .padding(.bottom, 15)
    }
}

// MARK: - SSO Profile Tab
struct SSOProfileTab: View {
    let onClose: () -> Void

    @State private var region = "-----"
    @State private var startUrl = ""
    @State private var accountId = ""
    @State private var selectedPermissionSet = "-----"
    @State private var output = "json"
    @State private var errorMessage: String?
    @State private var showAddPermissionSetSheet = false

    private let regions = SSOProfile.commonRegions

    var body: some View {
        Form {
            Picker("Permission Set", selection: $selectedPermissionSet) {
                ForEach(PermissionSetManager.shared.getPermissionSets(), id: \.displayName) { permissionSet in
                    Text(permissionSet.displayName).tag(permissionSet.displayName)
                }
                Divider()
                Text("Add new permission set...").tag("add_new")
            }
            .onChange(of: selectedPermissionSet) { oldValue, newValue in
                if newValue == "add_new" {
                    showAddPermissionSetSheet = true
                    // Reset selection to prevent issues when sheet is dismissed
                    DispatchQueue.main.async {
                        selectedPermissionSet = "-----"
                    }
                }
            }

            Picker("Region", selection: $region) {
                ForEach(regions, id: \.self) { region in
                    Text(region).tag(region)
                }
            }

            TextField("Start URL", text: $startUrl)
                .textFieldStyle(.roundedBorder)

            TextField("Account ID", text: $accountId)
                .textFieldStyle(.roundedBorder)

            Picker("Output", selection: $output) {
                ForEach(Constants.AWS.outputFormats, id: \.self) { format in
                    Text(format).tag(format)
                }
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    onClose()
                }

                Spacer()

                Button("Save") {
                    saveProfile()
                }
                .disabled(!isValid)
            }
        }
        .padding()
        .sheet(isPresented: $showAddPermissionSetSheet) {
            AddPermissionSetView {
                // Refresh permission sets when sheet is dismissed
                selectedPermissionSet = "-----"
            }
        }
    }

    private var isValid: Bool {
        !startUrl.isEmpty &&
        !accountId.isEmpty &&
        region != "-----" &&
        selectedPermissionSet != "-----" &&
        selectedPermissionSet != "add_new"
    }

    private func saveProfile() {
        guard let permissionSet = PermissionSetManager.shared.getPermissionSets().first(where: { $0.displayName == selectedPermissionSet }) else {
            errorMessage = "Invalid permission set selection"
            return
        }

        let profile = SSOProfile(
            name: permissionSet.displayName, // Use permission set name as profile name
            startUrl: startUrl,
            region: region,
            accountId: accountId,
            roleName: permissionSet.permissionSetName,
            output: output
        )

        if !profile.validate() {
            errorMessage = Constants.ErrorMessages.profileValidation
            return
        }

        do {
            try ConfigManager.shared.saveProfile(profile)
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.profilesUpdated),
                object: nil
            )
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - IAM Role Tab
struct IAMRoleTab: View {
    let onClose: () -> Void

    @State private var sourceProfile = "-----"
    @State private var selectedRole = "-----"
    @State private var output = "json"
    @State private var errorMessage: String?
    @State private var showAddRoleSheet = false
    @State private var roleToDelete: String?
    @State private var showDeleteConfirmation = false

    @State private var availableProfiles: [String] = []
    @State private var availableRoles: [Role] = []

    var body: some View {
        Form {
            Picker("Assume Role", selection: $selectedRole) {
                ForEach(availableRoles, id: \.name) { role in
                    HStack {
                        Text(role.name).tag(role.name)
                        Spacer()
                        Button(action: {
                            roleToDelete = role.name
                            showDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
                Divider()
                Text("Add new role...").tag("add_new")
            }
            .onChange(of: selectedRole) { oldValue, newValue in
                if newValue == "add_new" {
                    showAddRoleSheet = true
                    // Reset selection to prevent issues when sheet is dismissed
                    DispatchQueue.main.async {
                        selectedRole = "-----"
                    }
                }
            }

            Picker("Source Profile", selection: $sourceProfile) {
                ForEach(availableProfiles, id: \.self) { profile in
                    Text(profile).tag(profile)
                }
            }

            Picker("Output", selection: $output) {
                ForEach(Constants.AWS.outputFormats, id: \.self) { format in
                    Text(format).tag(format)
                }
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    onClose()
                }

                Spacer()

                Button("Save") {
                    saveIAMProfile()
                }
                .disabled(!isValid)
            }
        }
        .padding()
        .onAppear {
            loadAvailableProfiles()
            loadAvailableRoles()
        }
        .sheet(isPresented: $showAddRoleSheet) {
            AddRoleView {
                loadAvailableRoles()
            }
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text("Delete Role"),
                message: Text("Are you sure you want to delete this role?"),
                primaryButton: .destructive(Text("Delete")) {
                    if let roleToDelete = roleToDelete {
                        RoleManager.shared.deleteRole(named: roleToDelete)
                        loadAvailableRoles()
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var isValid: Bool {
        sourceProfile != "-----" &&
        selectedRole != "-----" &&
        selectedRole != "add_new"
    }

    private func loadAvailableProfiles() {
        let profiles = ConfigManager.shared.getProfiles()
            .compactMap { $0 as? SSOProfile }

        var profileNames = ["-----"]

        for profile in profiles {
            let displayName: String
            if profile.name == "default" {
                displayName = ProfileHistoryManager.shared.getDefaultProfileOriginalName() ?? profile.name
            } else {
                displayName = profile.name
            }
            profileNames.append(displayName)
        }

        availableProfiles = profileNames
    }

    private func loadAvailableRoles() {
        availableRoles = RoleManager.shared.getRoles()
    }

    private func saveIAMProfile() {
        guard let role = availableRoles.first(where: { $0.name == selectedRole }) else {
            errorMessage = "Invalid role selection"
            return
        }

        // Get all profiles
        let allProfiles = ConfigManager.shared.getProfiles()

        let defaultProfileOriginalName = ProfileHistoryManager.shared.getDefaultProfileOriginalName()

        // Find the source profile
        let sourceProfileObject: SSOProfile?
        if sourceProfile == defaultProfileOriginalName {
            // If selected source is the default profile by its original name
            sourceProfileObject = allProfiles
                .first(where: { $0.name == "default" }) as? SSOProfile
        } else if sourceProfile == "default" {
            // If selected source is literally "default"
            sourceProfileObject = allProfiles
                .first(where: { $0.name == "default" }) as? SSOProfile
        } else {
            // Regular named profile
            sourceProfileObject = allProfiles
                .first(where: { $0.name == sourceProfile }) as? SSOProfile
        }

        guard let sourceProfileObject = sourceProfileObject else {
            errorMessage = "Could not find the source profile"
            return
        }

        // Determine the actual source profile name to use in the config
        let actualSourceProfileName = sourceProfileObject.name == "default" ? "default" : sourceProfileObject.name

        let ssoSessionName: String
        if sourceProfileObject.name == "default" {
            // For default profile, we need to find its sso_session from the config
            if allProfiles.first(where: { $0.name == "default" }) is SSOProfile {
                // Use the original profile name for the sso_session, never "default"
                ssoSessionName = defaultProfileOriginalName ?? ""
            } else {
                // Fallback to the original name if we can't find it
                ssoSessionName = defaultProfileOriginalName ?? sourceProfileObject.name
            }
        } else {
            // For regular profiles, use the profile name as the sso_session
            ssoSessionName = sourceProfileObject.name
        }

        // Create the IAM profile with explicit sso_session
        let iamProfile = IAMProfile(
            name: selectedRole, // Use role name as profile name
            sourceProfile: actualSourceProfileName,
            ssoSession: ssoSessionName,  // Use the actual SSO session name, never "default"
            roleArn: role.arn,
            region: sourceProfileObject.region,
            output: output
        )

        do {
            try ConfigManager.shared.saveIAMProfile(iamProfile)
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.profilesUpdated),
                object: nil
            )
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Add Role View
struct AddRoleView: View {
    let onDismiss: () -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var roleName = ""
    @State private var roleArn = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Text("Add New Role")
                .font(.headline)
                .padding()

            Form {
                TextField("Role Name", text: $roleName)
                    .textFieldStyle(.roundedBorder)

                TextField("Role ARN", text: $roleArn)
                    .textFieldStyle(.roundedBorder)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()

            HStack {
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }

                Spacer()

                Button("Save") {
                    saveRole()
                }
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 400, height: 250)
    }

    private var isValid: Bool {
        !roleName.isEmpty && !roleArn.isEmpty
    }

    private func saveRole() {
        let newRole = Role(name: roleName, arn: roleArn)
        RoleManager.shared.addRole(newRole)
        onDismiss()
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Add Permission Set View
struct AddPermissionSetView: View {
    let onDismiss: () -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var displayName = ""
    @State private var permissionSetName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Text("Add Permission Set")
                .font(.headline)
                .padding()

            Form {
                TextField("Display Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)

                TextField("Permission Set Name", text: $permissionSetName)
                    .textFieldStyle(.roundedBorder)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding()

            HStack {
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }

                Spacer()

                Button("Save") {
                    savePermissionSet()
                }
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 400, height: 250)
    }

    private var isValid: Bool {
        !displayName.isEmpty && !permissionSetName.isEmpty
    }

    private func savePermissionSet() {
        let newPermissionSet = PermissionSet(displayName: displayName, permissionSetName: permissionSetName)
        PermissionSetManager.shared.addPermissionSet(newPermissionSet)
        onDismiss()
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Preview Provider
struct AddProfileView_Previews: PreviewProvider {
    static var previews: some View {
        AddProfileView(onClose: {})
    }
}
