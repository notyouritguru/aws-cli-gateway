import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure AWS directory permissions are correct at startup
        ConfigManager.shared.ensureDirectoryPermissions()
        
        // Sync profiles with history
        ConfigManager.shared.syncProfilesWithHistory()
        
        _ = ProfileHistoryManager.shared
        
        setupNotifications()
        setupSessionObservers()
        MenuBarManager.shared.setup()
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("Notification authorization granted")
            }
        }
        
        ConfigManager.shared.updateIAMProfileSourceReferences()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Force save profile history before terminating
        ProfileHistoryManager.shared.persistChanges()
    }
    
    // MARK: - Setup
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }
    
    private func setupSessionObservers() {
        // For logs or other custom handling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionExpired),
            name: NSNotification.Name(Constants.Notifications.sessionExpired),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionTimeUpdate(_:)),
            name: NSNotification.Name(Constants.Notifications.sessionTimeUpdated),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProfileConnected(_:)),
            name: NSNotification.Name(Constants.Notifications.profileConnected),
            object: nil
        )
    }
    
    // MARK: - Notification Handlers
    
    @objc private func handleSessionExpired() {
        showAlert(Constants.ErrorMessages.sessionExpired, info: "Your session has expired. Please reconnect.")
    }
    
    @objc private func handleSessionTimeUpdate(_ notification: Notification) {
        guard let remaining = notification.userInfo?[Constants.NotificationKeys.timeRemaining] as? TimeInterval else { return }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        print("AppDelegate sees session time updated: \(hours):\(minutes):\(seconds)")
    }
    
    @objc private func handleProfileConnected(_ notification: Notification) {
        if let profile = notification.userInfo?[Constants.NotificationKeys.profile] as? SSOProfile {
            print("AppDelegate sees profile connected: \(profile.name)")
        }
    }
    
    // MARK: - Helpers
    
    private func showAlert(_ title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
