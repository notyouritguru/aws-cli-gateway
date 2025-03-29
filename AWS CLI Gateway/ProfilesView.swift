import SwiftUI

struct ProfilesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [AWSProfile] = []
    @State private var selectedProfile: AWSProfile?
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
                    ProfileRow(profile: profile, isSelected: selectedProfile?.name == profile.name)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            connectToProfile(profile)
                        }
                        .contextMenu {
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
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(Constants.Notifications.profilesUpdated)
            )
        ) { _ in
            loadProfiles()
        }
    }
    
    private func loadProfiles() {
        profiles = ConfigManager.shared.getProfiles()
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
                    NotificationCenter.default.post(
                        name: Notification.Name(Constants.Notifications.profileConnected),
                        object: nil,
                        userInfo: [Constants.NotificationKeys.profile: profile]
                    )
                    SessionManager.shared.startMonitoring(for: profile.name)
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
        ConfigManager.shared.deleteProfile(profile.name)
        loadProfiles()
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.profilesUpdated),
            object: nil
        )
    }
}

struct ProfileRow: View {
    let profile: AWSProfile
    let isSelected: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(profile.name)
                    .font(.headline)
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
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ProfilesView()
}
