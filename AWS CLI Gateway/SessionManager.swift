import Foundation

class SessionManager {
    static let shared = SessionManager()
    
    // MARK: - Properties
    private var timer: Timer?
    private var currentProfile: String?
    private var expirationDate: Date?
    private var isCleanDisconnect: Bool = false
    
    // Callback for UI updates
    var onSessionUpdate: ((String) -> Void)?
    
    private init() {}
    
    // MARK: - Public Interface
    
    func startMonitoring(for profileName: String) {
        stopMonitoring()  // Stop any existing timers
        isCleanDisconnect = false
        currentProfile = profileName
        
        // 1) Look up the expiration in ~/.aws/cli/cache/ once
        if let expiration = ConfigManager.shared.getSessionExpiration() {
            expirationDate = expiration
        } else {
            // If no expiration, treat session as expired
            handleExpiredSession()
            return
        }
        
        // 2) Create timer on main thread
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(
                withTimeInterval: 1.0,
                repeats: true
            ) { [weak self] _ in
                self?.checkSessionStatus()
            }
            
            if let timer = self?.timer {
                RunLoop.main.add(timer, forMode: .common)
            }
            
            // 3) Initial check
            self?.checkSessionStatus()
        }
        
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.sessionMonitoringStarted),
            object: nil,
            userInfo: [Constants.NotificationKeys.profileName: profileName]
        )
    }
    
    func cleanDisconnect() {
        isCleanDisconnect = true
        timer?.invalidate()
        timer = nil
        currentProfile = nil
        expirationDate = nil
        
        // Reset UI without posting notifications
        DispatchQueue.main.async { [weak self] in
            self?.onSessionUpdate?("Session: --:--:--")
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        currentProfile = nil
        expirationDate = nil
        
        // Reset UI
        DispatchQueue.main.async { [weak self] in
            self?.onSessionUpdate?("Session: --:--:--")
        }
        
        if !isCleanDisconnect {
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionMonitoringStopped),
                object: nil
            )
        }
        isCleanDisconnect = false
    }
    
    func renewSession() async throws {
        guard let profile = currentProfile else {
            throw SessionError.noActiveProfile
        }
        
        do {
            // 1) Logout old session
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "logout", "--profile", profile])
            
            // 2) Clear local cache
            ConfigManager.shared.clearCache()
            
            // 3) Login again
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "login", "--profile", profile])
            
            // 4) Force creation of fresh credentials
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profile])
            
            // 5) Update expirationDate and restart the timer
            await MainActor.run { [weak self] in
                self?.startMonitoring(for: profile)
            }
            
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionRenewed),
                object: nil
            )
        } catch {
            throw SessionError.renewalFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Private Methods
    
    private func handleExpiredSession() {
        guard !isCleanDisconnect else { return }  // Exit early if clean disconnect
        
        stopMonitoring()
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.sessionExpired),
            object: nil
        )
    }
    
    private func checkSessionStatus() {
        guard !isCleanDisconnect else { return }  // Exit early if clean disconnect
        
        guard let expiration = expirationDate else {
            handleExpiredSession()
            return
        }
        
        let remaining = expiration.timeIntervalSinceNow
        if remaining <= 0 {
            handleExpiredSession()
            return
        }
        
        // Format time string
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        let timeString = String(format: "Session: %02d:%02d:%02d", hours, minutes, seconds)
        
        // Update UI through callback
        DispatchQueue.main.async { [weak self] in
            self?.onSessionUpdate?(timeString)
        }
        
        // Also post notification for other observers
        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.sessionTimeUpdated),
            object: nil,
            userInfo: [Constants.NotificationKeys.timeRemaining: remaining]
        )
        
        // Check warning thresholds
        checkWarningThresholds(remaining)
    }
    
    private func checkWarningThresholds(_ remaining: TimeInterval) {
        guard !isCleanDisconnect else { return }  // Exit early if clean disconnect
        
        for threshold in Constants.Session.warningThresholds {
            if remaining <= threshold && remaining > threshold - 1 {
                NotificationCenter.default.post(
                    name: Notification.Name(Constants.Notifications.sessionWarning),
                    object: nil,
                    userInfo: [
                        Constants.NotificationKeys.timeRemaining: remaining,
                        Constants.NotificationKeys.threshold: threshold
                    ]
                )
            }
        }
    }
}

// MARK: - Errors
enum SessionError: LocalizedError {
    case noActiveProfile
    case renewalFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            return "No active profile selected"
        case .renewalFailed(let message):
            return "Session renewal failed: \(message)"
        }
    }
}
