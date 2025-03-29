import SwiftUI

class ContentViewModel: NSObject, ObservableObject {
    @Published var currentProfile: String?
    @Published var sessionTimeRemaining: String?
    @Published var sessionStatus: String = Constants.Session.noActiveSession
    
    override init() {
        super.init()
        setupObservers()
    }
    
    // MARK: - Public Methods
    
    @MainActor
    func renewSession() {
        Task {
            do {
                try await SessionManager.shared.renewSession()
            } catch {
                handleError(error)
            }
        }
    }
    
    func showAddProfileWindow() {
        // Instead of creating the NSWindow ourselves, unify with WindowManager
        WindowManager.shared.showAddProfileWindow()
    }
    
    // MARK: - Private Methods
    
    private func setupObservers() {
        // Profile notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProfileConnected(_:)),
            name: Notification.Name(Constants.Notifications.profileConnected),
            object: nil
        )
        
        // Session notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionTimeUpdate(_:)),
            name: Notification.Name(Constants.Notifications.sessionTimeUpdated),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionMonitoringStarted(_:)),
            name: Notification.Name(Constants.Notifications.sessionMonitoringStarted),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionMonitoringStopped),
            name: Notification.Name(Constants.Notifications.sessionMonitoringStopped),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionExpired),
            name: Notification.Name(Constants.Notifications.sessionExpired),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionRenewed),
            name: Notification.Name(Constants.Notifications.sessionRenewed),
            object: nil
        )
    }
    
    // MARK: - Notification Handlers
    
    @objc private func handleProfileConnected(_ notification: Notification) {
        Task { @MainActor in
            if let profile = notification.userInfo?[Constants.NotificationKeys.profile] as? SSOProfile {
                currentProfile = profile.name
                sessionStatus = Constants.Session.sessionActive
            }
        }
    }
    
    @objc private func handleSessionTimeUpdate(_ notification: Notification) {
        Task { @MainActor in
            guard let timeRemaining = notification.userInfo?[Constants.NotificationKeys.timeRemaining] as? TimeInterval else {
                return
            }
            let hours = Int(timeRemaining) / 3600
            let minutes = (Int(timeRemaining) % 3600) / 60
            let seconds = Int(timeRemaining) % 60
            sessionTimeRemaining = String(format: "%02d:%02d:%02d remaining", hours, minutes, seconds)
            sessionStatus = Constants.Session.sessionActive
        }
    }
    
    @objc private func handleSessionMonitoringStarted(_ notification: Notification) {
        Task { @MainActor in
            if let profileName = notification.userInfo?[Constants.NotificationKeys.profileName] as? String {
                currentProfile = profileName
                sessionStatus = Constants.Session.sessionActive
            }
        }
    }
    
    @objc private func handleSessionMonitoringStopped() {
        Task { @MainActor in
            currentProfile = nil
            sessionTimeRemaining = nil
            sessionStatus = Constants.Session.noActiveSession
        }
    }
    
    @objc private func handleSessionExpired() {
        Task { @MainActor in
            currentProfile = nil
            sessionTimeRemaining = nil
            sessionStatus = Constants.Session.sessionExpired
        }
    }
    
    @objc private func handleSessionRenewed() {
        Task { @MainActor in
            sessionStatus = Constants.Session.sessionActive
        }
    }
    
    // MARK: - Error Handling
    
    private func handleError(_ error: Error) {
        Task { @MainActor in
            if let sessionError = error as? SessionError {
                switch sessionError {
                case .noActiveProfile:
                    sessionStatus = Constants.Session.noActiveSession
                case .renewalFailed:
                    sessionStatus = Constants.Session.sessionExpired
                }
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension ContentViewModel {
    static var preview: ContentViewModel {
        let viewModel = ContentViewModel()
        viewModel.currentProfile = "Development"
        viewModel.sessionTimeRemaining = "01:30:00 remaining"
        viewModel.sessionStatus = Constants.Session.sessionActive
        return viewModel
    }
}
#endif
