import SwiftUI
import AppKit

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

// NSPopUpButton wrapper with delete button
struct NativePopUpButton: NSViewRepresentable {
    @Binding var selection: String
    var options: [String]
    var onDelete: ((String) -> Void)?
    var onAddNew: (() -> Void)?
    var addNewText: String = "Add new permission set..."

    func makeNSView(context: Context) -> NSView {
        // Container view to hold both popup button and delete button
        let container = NSView()

        // Create the popup button
        let popUpButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 25), pullsDown: false)
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectionChanged(_:))
        popUpButton.bezelStyle = .texturedSquare
        popUpButton.font = NSFont.systemFont(ofSize: 13)
        popUpButton.tag = 100 // Tag to identify in the container

        // Create delete button (hidden initially)
        let deleteButton = NSButton(frame: NSRect(x: 225, y: 0, width: 25, height: 25))
        deleteButton.bezelStyle = .texturedSquare
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.isBordered = true
        deleteButton.target = context.coordinator
        deleteButton.action = #selector(Coordinator.deleteSelectedOption(_:))
        deleteButton.tag = 101 // Tag to identify in the container
        deleteButton.isHidden = true // Hidden initially

        container.addSubview(popUpButton)
        container.addSubview(deleteButton)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Get the popup button from the container
        guard let popUpButton = container.viewWithTag(100) as? NSPopUpButton,
              let deleteButton = container.viewWithTag(101) as? NSButton else {
            return
        }

        // Clear existing items
        popUpButton.removeAllItems()

        // Add options as regular menu items
        for option in options {
            popUpButton.addItem(withTitle: option)
        }

        // Add "Add new..." option if needed
        if onAddNew != nil {
            popUpButton.menu?.addItem(NSMenuItem.separator())
            let addItem = NSMenuItem(title: addNewText, action: #selector(Coordinator.addNewOption(_:)), keyEquivalent: "")
            addItem.target = context.coordinator
            popUpButton.menu?.addItem(addItem)
        }

        // Set selected item
        if let index = options.firstIndex(of: selection) {
            popUpButton.selectItem(at: index)

            // Show delete button if selection isn't the placeholder and we have a delete handler
            deleteButton.isHidden = (selection == "-----" || onDelete == nil)
        } else if !options.isEmpty {
            popUpButton.selectItem(at: 0)
            deleteButton.isHidden = true

            // Update binding if selection is invalid
            if !options.contains(selection) {
                DispatchQueue.main.async {
                    selection = options[0]
                }
            }
        }

        // Update coordinator with current state
        context.coordinator.options = options
        context.coordinator.container = container
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: NativePopUpButton
        var options: [String] = []
        weak var container: NSView?

        init(_ parent: NativePopUpButton) {
            self.parent = parent
            self.options = parent.options
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let deleteButton = container?.viewWithTag(101) as? NSButton,
                  sender.indexOfSelectedItem >= 0 else { return }

            let selectedOption = sender.titleOfSelectedItem ?? ""

            // Update binding
            DispatchQueue.main.async {
                self.parent.selection = selectedOption

                // Update delete button visibility
                deleteButton.isHidden = (selectedOption == "-----" || self.parent.onDelete == nil)
            }
        }

        @objc func deleteSelectedOption(_ sender: NSButton) {
            guard let popUpButton = container?.viewWithTag(100) as? NSPopUpButton,
                  let selectedOption = popUpButton.titleOfSelectedItem,
                  selectedOption != "-----" else {
                return
            }

            // Show confirmation alert
            let alert = NSAlert()
            alert.messageText = "Delete Item"
            alert.informativeText = "Are you sure you want to delete \(selectedOption)?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")

            if let window = container?.window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn {
                        DispatchQueue.main.async {
                            self.parent.onDelete?(selectedOption)
                        }
                    }
                }
            } else {
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    DispatchQueue.main.async {
                        self.parent.onDelete?(selectedOption)
                    }
                }
            }
        }

        @objc func addNewOption(_ sender: NSMenuItem) {
            DispatchQueue.main.async {
                self.parent.onAddNew?()
            }
        }
    }
}

// Simple native popup without delete button - for standard dropdowns
struct NativeDropdown: NSViewRepresentable {
    @Binding var selection: String
    var options: [String]

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectionChanged(_:))

        // Match the style of the other popups
        popUpButton.bezelStyle = .texturedSquare
        popUpButton.font = NSFont.systemFont(ofSize: 13)

        return popUpButton
    }

    func updateNSView(_ popUpButton: NSPopUpButton, context: Context) {
        // Clear existing items
        popUpButton.removeAllItems()

        // Add options
        for option in options {
            popUpButton.addItem(withTitle: option)
        }

        // Set selected item
        if let index = options.firstIndex(of: selection) {
            popUpButton.selectItem(at: index)
        } else if !options.isEmpty {
            popUpButton.selectItem(at: 0)
            if !options.contains(selection) {
                DispatchQueue.main.async {
                    selection = options[0]
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: NativeDropdown

        init(_ parent: NativeDropdown) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            if let selectedOption = sender.titleOfSelectedItem {
                DispatchQueue.main.async {
                    self.parent.selection = selectedOption
                }
            }
        }
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
    @State private var permissionSets: [PermissionSet] = []
    @State private var permissionSetToDelete: String?
    @State private var showDeleteConfirmation = false
    @FocusState private var focusedField: Field?

    enum Field {
        case startUrl, accountId
    }

    private let regions = SSOProfile.commonRegions

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 15) {
            GridRow {
                Text("Permission Set")
                    .gridColumnAlignment(.trailing)

                NativePopUpButton(
                    selection: $selectedPermissionSet,
                    options: ["-----"] + permissionSets.map { $0.displayName },
                    onDelete: { itemToDelete in
                        if itemToDelete != "-----" {
                            permissionSetToDelete = itemToDelete
                            showDeleteConfirmation = true
                        }
                    },
                    onAddNew: {
                        showAddPermissionSetSheet = true
                    },
                    addNewText: "Add new permission set..."
                )
                .frame(width: 250, height: 25)
            }

            GridRow {
                Text("Region")
                    .gridColumnAlignment(.trailing)

                NativeDropdown(
                    selection: $region,
                    options: regions
                )
                .frame(width: 250, height: 25)
            }

            GridRow {
                Text("Start URL")
                    .gridColumnAlignment(.trailing)

                TextField("", text: $startUrl)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .startUrl)
                    .frame(width: 250)
            }

            GridRow {
                Text("Account ID")
                    .gridColumnAlignment(.trailing)

                TextField("", text: $accountId)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .accountId)
                    .frame(width: 250)
            }

            GridRow {
                Text("Output")
                    .gridColumnAlignment(.trailing)

                NativeDropdown(
                    selection: $output,
                    options: Constants.AWS.outputFormats
                )
                .frame(width: 250, height: 25)
            }

            if let errorMessage = errorMessage {
                GridRow {
                    Text("")

                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            GridRow {
                Text("")

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
                .frame(width: 250)
            }
        }
        .padding()
        .onAppear {
            loadPermissionSets()
        }
        .sheet(isPresented: $showAddPermissionSetSheet, onDismiss: {
            loadPermissionSets()
        }) {
            AddPermissionSetView {
                loadPermissionSets()
            }
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text("Delete Permission Set"),
                message: Text("Are you sure you want to delete this permission set?"),
                primaryButton: .destructive(Text("Delete")) {
                    if let setToDelete = permissionSetToDelete {
                        PermissionSetManager.shared.deletePermissionSet(named: setToDelete)
                        loadPermissionSets()
                        if selectedPermissionSet == setToDelete {
                            selectedPermissionSet = "-----"
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var isValid: Bool {
        !startUrl.isEmpty &&
        !accountId.isEmpty &&
        region != "-----" &&
        selectedPermissionSet != "-----"
    }

    private func loadPermissionSets() {
        permissionSets = PermissionSetManager.shared.getPermissionSets()
    }

    private func saveProfile() {
        guard let permissionSet = permissionSets.first(where: { $0.displayName == selectedPermissionSet }) else {
            errorMessage = "Invalid permission set selection"
            return
        }

        let profile = SSOProfile(
            name: permissionSet.displayName,
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
        Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 15) {
            GridRow {
                Text("Assume Role")
                    .gridColumnAlignment(.trailing)

                NativePopUpButton(
                    selection: $selectedRole,
                    options: ["-----"] + availableRoles.map { $0.name },
                    onDelete: { itemToDelete in
                        if itemToDelete != "-----" {
                            roleToDelete = itemToDelete
                            showDeleteConfirmation = true
                        }
                    },
                    onAddNew: {
                        showAddRoleSheet = true
                    },
                    addNewText: "Add new role..."
                )
                .frame(width: 250, height: 25)
            }

            GridRow {
                Text("Source Profile")
                    .gridColumnAlignment(.trailing)

                NativeDropdown(
                    selection: $sourceProfile,
                    options: availableProfiles
                )
                .frame(width: 250, height: 25)
            }

            GridRow {
                Text("Output")
                    .gridColumnAlignment(.trailing)

                NativeDropdown(
                    selection: $output,
                    options: Constants.AWS.outputFormats
                )
                .frame(width: 250, height: 25)
            }

            if let errorMessage = errorMessage {
                GridRow {
                    Text("")

                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            GridRow {
                Text("")

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
                .frame(width: 250)
            }
        }
        .padding()
        .onAppear {
            loadAvailableProfiles()
            loadAvailableRoles()
        }
        .sheet(isPresented: $showAddRoleSheet, onDismiss: {
            loadAvailableRoles()
        }) {
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
                        if selectedRole == roleToDelete {
                            selectedRole = "-----"
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var isValid: Bool {
        sourceProfile != "-----" &&
        selectedRole != "-----"
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
    @FocusState private var focusedField: Field?

    enum Field {
        case roleName, roleArn
    }

    var body: some View {
        VStack {
            Text("Add New Role")
                .font(.headline)
                .padding()

            Form {
                TextField("Role Name", text: $roleName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .roleName)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            focusedField = .roleName
                        }
                    }

                TextField("Role ARN", text: $roleArn)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .roleArn)

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
    @FocusState private var focusedField: Field?

    enum Field {
        case displayName, permissionSetName
    }

    var body: some View {
        VStack {
            Text("Add Permission Set")
                .font(.headline)
                .padding()

            Form {
                TextField("Display Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .displayName)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            focusedField = .displayName
                        }
                    }

                TextField("Permission Set Name", text: $permissionSetName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .permissionSetName)

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
