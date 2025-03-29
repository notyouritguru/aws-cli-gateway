import SwiftUI

struct SessionCountdownView: View {
    // Start with a default value before notifications arrive
    @State private var timeRemaining: TimeInterval = 0
    @State private var sessionStatus: SessionStatus = .unknown
    @State private var connectedProfile: String? = nil
    @State private var isRenewing: Bool = false

    enum SessionStatus {
        case active
        case expired
        case notAuthenticated
        case unknown
    }

    var body: some View {
        HStack(spacing: 5) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.leading, 4)

            // Profile and timer
            VStack(alignment: .leading, spacing: 1) {
                if let profileName = connectedProfile {
                    Text(profileName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)
                } else {
                    Text(statusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)
                }

                if sessionStatus == .active && timeRemaining > 0 {
                    Text(formatTime(timeRemaining))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Refresh button
            if sessionStatus == .expired || sessionStatus == .notAuthenticated {
                Button(action: {
                    renewSession()
                }) {
                    Image(systemName: isRenewing ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isRenewing)
            }
        }
        .frame(height: sessionStatus == .active ? 26 : 20)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .onAppear {
            // Get initial profile
            updateConnectedProfile()

            // Set up observer to get the active profile on changes
            NotificationCenter.default.addObserver(
                forName: Notification.Name(Constants.Notifications.profilesUpdated),
                object: nil,
                queue: .main
            ) { _ in
                updateConnectedProfile()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(Constants.Notifications.sessionTimeUpdated)
            )
        ) { notification in
            if let remaining = notification.userInfo?[Constants.NotificationKeys.timeRemaining] as? TimeInterval {
                self.timeRemaining = remaining
                self.sessionStatus = .active
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(Constants.Notifications.sessionExpired)
            )
        ) { _ in
            self.sessionStatus = .expired
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(Constants.Notifications.sessionMonitoringStopped)
            )
        ) { _ in
            self.sessionStatus = .notAuthenticated
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name(Constants.Notifications.sessionRenewed)
            )
        ) { _ in
            self.isRenewing = false
            // Session status will be updated by the time notification
        }
    }

    private var statusColor: Color {
        switch sessionStatus {
        case .active:
            return Color.green
        case .expired:
            return Color.orange
        case .notAuthenticated, .unknown:
            return Color.gray
        }
    }

    private var statusText: String {
        switch sessionStatus {
        case .active:
            return "Session Active"
        case .expired:
            return "Session Expired"
        case .notAuthenticated:
            return "Not Authenticated"
        case .unknown:
            return "No Profile Selected"
        }
    }

    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "Session: %02d:%02d:%02d", hours, minutes, seconds)
    }

    private func updateConnectedProfile() {
        if let profileInfo = ProfileHistoryManager.shared.getConnectedProfile() {
            self.connectedProfile = profileInfo.originalName

            // Start monitoring for this profile 
            SessionManager.shared.startMonitoring(for: profileInfo.originalName)
        } else {
            self.connectedProfile = nil
            self.sessionStatus = .notAuthenticated
        }
    }


    private func renewSession() {
        guard connectedProfile != nil else { return }

        isRenewing = true

        Task {
            do {
                try await SessionManager.shared.renewSession()
            } catch {
                // Handle error by reverting UI state
                DispatchQueue.main.async {
                    self.isRenewing = false
                }
            }
        }
    }
}
