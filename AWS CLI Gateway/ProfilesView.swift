import SwiftUI

struct ProfilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [AWSProfile] = []
    @State private var selectedProfile: AWSProfile?
    @State private var connectedProfileId: String? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8)
            } else {
                List(profiles, id: \.name) { profile in
                    ProfileRow(
                        profile: profile,
                        isSelected: selectedProfile?.name == profile.name,
                        isConnected: isProfileConnected(profile),
                        onToggleConnection: {
                            toggleConnection(profile)
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Now tap just selects the profile but doesn't connect
                        selectedProfile = profile
                    }
                    .contextMenu {
                        // Context menu options remain the same
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(profile.name, forType: .string)
                        } label: {
                            Label("Copy Profile Name", systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deleteProfile(profile)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .frame(minHeight: 200)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            HStack {
                Button("Add Profile") {
                    WindowManager.shared.showAddProfileWindow()
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(width: 400)
        .onAppear {
            loadProfiles()
            updateConnectedProfile()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(Constants.Notifications.profilesUpdated)
            )
        ) { _ in
            loadProfiles()
            updateConnectedProfile()
        }
    }
    
    private func toggleConnection(_ profile: AWSProfile) {
        // Check if this profile is already connected
        let isAlreadyConnected = isProfileConnected(profile)

        if isAlreadyConnected {
            // Disconnect this profile
            ProfileHistoryManager.shared.clearConnectedProfile()
            SessionManager.shared.stopMonitoring()
        } else {
            // Connect to this profile (reuse your existing connect logic)
            isLoading = true
            errorMessage = nil
            selectedProfile = profile

            Task {
                do {
                    if profile is SSOProfile {
                        // Login to SSO
                        let loginArgs = ["sso", "login", "--profile", profile.name]
                        _ = try await CommandRunner.shared.runCommand("aws", args: loginArgs)
                    }

                    // Verify with STS
                    let verifyArgs = ["sts", "get-caller-identity", "--profile", profile.name]
                    _ = try await CommandRunner.shared.runCommand("aws", args: verifyArgs)

                    await MainActor.run {
                        // Use the correct method signature - only profile name without withId
                        ProfileHistoryManager.shared.setConnectedProfile(profile.name)

                        // Post notification
                        NotificationCenter.default.post(
                            name: Notification.Name(Constants.Notifications.profileConnected),
                            object: nil,
                            userInfo: [Constants.NotificationKeys.profile: profile]
                        )

                        // Start session monitoring
                        SessionManager.shared.startMonitoring(for: profile.name)

                        // Update UI status
                        updateConnectedProfile()
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = Constants.ErrorMessages.ssoLoginFailed
                    }
                }

                await MainActor.run {
                    isLoading = false
                }
            }
        }

        // Update UI
        updateConnectedProfile()

        // Post notification for other components
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.profilesUpdated),
            object: nil
        )
    }

    private func loadProfiles() {
        profiles = ConfigManager.shared.getProfiles()
    }

    private func updateConnectedProfile() {
        if let connectedProfile = ProfileHistoryManager.shared.getConnectedProfile() {
            connectedProfileId = connectedProfile.id
        } else {
            connectedProfileId = nil
        }
    }

    private func isProfileConnected(_ profile: AWSProfile) -> Bool {
        if let connectedProfile = ProfileHistoryManager.shared.getConnectedProfile() {
            return connectedProfile.originalName == profile.name
        }
        return false
    }

    private func connectToProfile(_ profile: AWSProfile) {
        isLoading = true
        errorMessage = nil
        selectedProfile = profile

        Task {
            do {
                if profile is SSOProfile {
                    // Login to SSO
                    let loginArgs = ["sso", "login", "--profile", profile.name]
                    _ = try await CommandRunner.shared.runCommand("aws", args: loginArgs)
                }

                // Verify with STS for both profile types
                let verifyArgs = ["sts", "get-caller-identity", "--profile", profile.name]
                _ = try await CommandRunner.shared.runCommand("aws", args: verifyArgs)

                await MainActor.run {
                    // Set as connected profile in ProfileHistoryManager
                    ProfileHistoryManager.shared.setConnectedProfile(profile.name)

                    // Post notification for other components
                    NotificationCenter.default.post(
                        name: Notification.Name(Constants.Notifications.profileConnected),
                        object: nil,
                        userInfo: [Constants.NotificationKeys.profile: profile]
                    )

                    // Start session monitoring for this profile
                    SessionManager.shared.startMonitoring(for: profile.name)

                    // Update UI status
                    updateConnectedProfile()

                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = Constants.ErrorMessages.ssoLoginFailed
                    selectedProfile = nil
                }
            }

            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func deleteProfile(_ profile: AWSProfile) {
        // Check if this is the currently connected profile
        let isConnected = isProfileConnected(profile)

        // Delete the profile
        ConfigManager.shared.deleteProfile(profile.name)

        // If it was connected, stop session monitoring
        if isConnected {
            SessionManager.shared.stopMonitoring()
            // Clear connected profile
            ProfileHistoryManager.shared.clearConnectedProfile()
        }

        // Reload profiles and notify
        loadProfiles()
        updateConnectedProfile()

        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.profilesUpdated),
            object: nil
        )
    }
}

struct ProfileRow: View {
    let profile: AWSProfile
    let isSelected: Bool
    let isConnected: Bool
    let onToggleConnection: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .font(.headline)

                    if isConnected {
                        Text("(Connected)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                if let ssoProfile = profile as? SSOProfile {
                    Text("\(ssoProfile.accountId) - \(ssoProfile.roleName)")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else if let iamProfile = profile as? IAMProfile {
                    Text("IAM Role - \(iamProfile.roleArn)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // Replace checkmark with star button
            Button(action: onToggleConnection) {
                Image(systemName: isConnected ? "star.fill" : "star")
                    .foregroundColor(isConnected ? .yellow : .gray)
                    .font(.system(size: 16))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
        .background(isConnected ? Color.green.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}


#Preview {
    ProfilesView()
}
