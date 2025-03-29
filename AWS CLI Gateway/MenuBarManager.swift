import SwiftUI
import Cocoa

class ProfileButton: NSButton {
    var profile: AWSProfile?
}

class MenuBarManager {
    static let shared = MenuBarManager()
    
    // MARK: - Menubar & Menu
    private var statusItem: NSStatusItem?
    private var mainMenu: NSMenu!
    
    // Menu items
    private var connectionsMenuItem: NSMenuItem!
    private var sessionMenuItem: NSMenuItem!
    private var renewMenuItem: NSMenuItem!
    private var disconnectMenuItem: NSMenuItem!
    
    // The active profile name
    private var activeProfile: String? {
        didSet {
            Task { @MainActor in
                if let profile = activeProfile {
                    SessionManager.shared.startMonitoring(for: profile)
                } else {
                    SessionManager.shared.cleanDisconnect()
                }
                buildMenu()
            }
        }
    }
    
    private init() {}
    
    // MARK: - Setup
    
    func setup() {
        Task { @MainActor in
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            
            if let button = statusItem?.button {
                button.image = NSImage(named: "cloud-lock")
                button.image?.isTemplate = true
            }
            
            mainMenu = NSMenu()
            statusItem?.menu = mainMenu
            
            setupNotifications()
            
            buildMenu()
            
            SessionManager.shared.onSessionUpdate = { [weak self] timeString in
                DispatchQueue.main.async {
                    self?.sessionMenuItem?.title = timeString
                }
            }
        }
    }
    
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        statusItem = nil
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProfilesUpdated),
            name: Notification.Name(Constants.Notifications.profilesUpdated),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProfileConnected(_:)),
            name: Notification.Name(Constants.Notifications.profileConnected),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionExpired),
            name: Notification.Name(Constants.Notifications.sessionExpired),
            object: nil
        )
    }
    
    // MARK: - Build the Dropdown
    
    @MainActor
    @objc private func buildMenu() {
        let currentSessionTime = sessionMenuItem?.title ?? "Session: --:--:--"
        mainMenu.removeAllItems()
        
        let connectionsSubMenu = NSMenu()
        let profiles = ConfigManager.shared.getProfiles()
        
        if profiles.isEmpty {
            let noProfilesItem = NSMenuItem(title: "No Profiles Available", action: nil, keyEquivalent: "")
            connectionsSubMenu.addItem(noProfilesItem)
        } else {
            for profile in profiles {
                let itemView = NSView(frame: NSRect(x: 0, y: 0, width: 175, height: Constants.UI.menuItemHeight))
                
                // Use the profile's displayName property which already handles the default case
                let profileButton = ProfileButton(frame: NSRect(x: 10, y: 0, width: 125, height: Constants.UI.menuItemHeight))
                profileButton.title = profile.displayName
                profileButton.target = self
                profileButton.action = #selector(connectToProfile(_:))
                profileButton.bezelStyle = .inline
                profileButton.isBordered = false
                profileButton.setButtonType(.momentaryPushIn)
                profileButton.profile = profile
                profileButton.alignment = .left
                if profile.name == activeProfile {
                    profileButton.state = .on
                }
                
                // Add a "Default" indicator if this is the default profile
                let defaultButton = ProfileButton(frame: NSRect(x: 130, y: 0, width: 20, height: Constants.UI.menuItemHeight))
                defaultButton.image = profile.isDefault ?
                                     NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Default") :
                                     NSImage(systemSymbolName: "star", accessibilityDescription: "Set as Default")
                defaultButton.bezelStyle = .inline
                defaultButton.isBordered = false
                defaultButton.target = self
                defaultButton.action = #selector(setDefaultProfile(_:))
                defaultButton.profile = profile
                
                let deleteButton = ProfileButton(frame: NSRect(x: 150, y: 0, width: 20, height: Constants.UI.menuItemHeight))
                deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
                deleteButton.bezelStyle = .inline
                deleteButton.isBordered = false
                deleteButton.target = self
                deleteButton.action = #selector(deleteProfile(_:))
                deleteButton.profile = profile
                
                itemView.addSubview(profileButton)
                itemView.addSubview(defaultButton)
                itemView.addSubview(deleteButton)
                
                let menuItem = NSMenuItem()
                menuItem.view = itemView
                connectionsSubMenu.addItem(menuItem)
            }
        }
        
        connectionsMenuItem = NSMenuItem(title: "Connections", action: nil, keyEquivalent: "")
        connectionsMenuItem.submenu = connectionsSubMenu
        mainMenu.addItem(connectionsMenuItem)
        
        if activeProfile != nil {
            mainMenu.addItem(NSMenuItem.separator())
            
            renewMenuItem = NSMenuItem(title: "Renew Session", action: #selector(renewSession), keyEquivalent: "")
            renewMenuItem.target = self
            mainMenu.addItem(renewMenuItem)
            
            disconnectMenuItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectProfile), keyEquivalent: "")
            disconnectMenuItem.target = self
            mainMenu.addItem(disconnectMenuItem)
            
            let menuItem = NSMenuItem()
            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
            containerView.wantsLayer = true
            containerView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.2).cgColor

            let customView = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
            customView.stringValue = currentSessionTime
            customView.isEditable = false
            customView.isBordered = false
            customView.backgroundColor = .clear
            customView.textColor = NSColor.white
            customView.alignment = .center
            customView.font = NSFont.boldSystemFont(ofSize: 16)
            customView.cell?.isScrollable = false
            customView.cell?.wraps = false
            customView.cell?.lineBreakMode = .byClipping

            customView.setContentHuggingPriority(.defaultHigh, for: .vertical)
            customView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
            customView.centerTextVertically()

            containerView.addSubview(customView)
            menuItem.view = containerView
            sessionMenuItem = menuItem
            mainMenu.addItem(sessionMenuItem)

            SessionManager.shared.onSessionUpdate = { [weak self] timeString in
                DispatchQueue.main.async {
                    if let container = self?.sessionMenuItem?.view,
                       let textField = container.subviews.first as? NSTextField {
                        textField.stringValue = timeString
                    }
                }
            }
            
            mainMenu.addItem(NSMenuItem.separator())
        }
        
        let addProfileItem = NSMenuItem(title: "Add Profile...", action: #selector(showAddProfile), keyEquivalent: "n")
        addProfileItem.target = self
        mainMenu.addItem(addProfileItem)
        
        let clearCacheItem = NSMenuItem(title: "Clear Cache", action: #selector(clearCache), keyEquivalent: "")
        clearCacheItem.target = self
        mainMenu.addItem(clearCacheItem)
        
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    
    // MARK: - Actions
    
    @MainActor
    @objc private func connectToProfile(_ sender: ProfileButton) {
        guard let profile = sender.profile else { return }
        
        Task {
            do {
                // Check if this is an IAM profile that needs SSO login first
                if let iamProfile = profile as? IAMProfile {
                    // First check if we need to login to the source profile
                    let sourceProfileName = iamProfile.sourceProfile
                    let _ = iamProfile.ssoSession
                    
                    // Get the source profile
                    let profiles = ConfigManager.shared.getProfiles()
                    if let sourceProfile = profiles.first(where: { $0.name == sourceProfileName }) as? SSOProfile {
                        // Try to login to the source profile first
                        _ = try await CommandRunner.shared.runCommand("aws", args: [
                            "sso", "login", "--profile", sourceProfile.name
                        ])
                    }
                } else if profile is SSOProfile {
                    // For regular SSO profiles, just login directly
                    _ = try await CommandRunner.shared.runCommand("aws", args: [
                        "sso", "login", "--profile", profile.name
                    ])
                }
                
                // Now verify the profile works by getting caller identity
                _ = try await CommandRunner.shared.runCommand("aws", args: [
                    "sts", "get-caller-identity", "--profile", profile.name
                ])
                
                try await Task.sleep(nanoseconds: 200_000_000)
                
                activeProfile = profile.name
                
                NotificationCenter.default.post(
                    name: Notification.Name(Constants.Notifications.profileConnected),
                    object: nil,
                    userInfo: [Constants.NotificationKeys.profile: profile]
                )
            } catch {
                showError("Login Failed", message: error.localizedDescription)
            }
        }
    }
    
    @MainActor
    @objc private func setDefaultProfile(_ sender: ProfileButton) {
        guard let profile = sender.profile else { return }
        
        if profile.isDefault {
            return
        }
        
        do {
            try ConfigManager.shared.setDefaultProfile(profile.name)
            buildMenu()
        } catch {
            showError("Error Setting Default Profile", message: error.localizedDescription)
        }
    }
    
    @MainActor
    @objc private func deleteProfile(_ sender: ProfileButton) {
        guard let profile = sender.profile else { return }
        
        let alert = NSAlert()
        alert.messageText = "Delete Profile"
        alert.informativeText = "Are you sure you want to delete the profile '\(profile.name)'? This cannot be undone."
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Delete")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if profile.name == activeProfile {
                Task {
                    do {
                        _ = try await CommandRunner.shared.runCommand("aws", args: [
                            "sso", "logout", "--profile", profile.name
                        ])
                    } catch {
                        // Ignore logout errors during deletion
                    }
                    ConfigManager.shared.clearCache()
                    activeProfile = nil
                }
            }
            
            ConfigManager.shared.deleteProfile(profile.name)
            buildMenu()
            
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.profilesUpdated),
                object: nil
            )
        }
    }
    
    @MainActor
    @objc private func renewSession() {
        Task {
            do {
                try await SessionManager.shared.renewSession()
            } catch {
                showError("Session Renewal Failed", message: error.localizedDescription)
            }
        }
    }
    
    @MainActor
    @objc private func disconnectProfile() {
        guard let profile = activeProfile else { return }
        Task {
            do {
                SessionManager.shared.cleanDisconnect()
                _ = try await CommandRunner.shared.runCommand("aws", args: [
                    "sso", "logout", "--profile", profile])
                
                ConfigManager.shared.clearCache()
                self.activeProfile = nil
            } catch {
                ConfigManager.shared.clearCache()
                SessionManager.shared.cleanDisconnect()
                self.activeProfile = nil
                await MainActor.run {
                    showError("Logout Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    @MainActor
    @objc private func showAddProfile() {
        WindowManager.shared.showAddProfileWindow()
    }
    
    @MainActor
    @objc private func clearCache() {
        SessionManager.shared.cleanDisconnect()
        ConfigManager.shared.clearCache()
        activeProfile = nil
    }
    
    // MARK: - Notification Handlers
    
    @MainActor
    @objc private func handleProfilesUpdated() {
        buildMenu()
    }
    
    @MainActor
    @objc private func handleProfileConnected(_ notification: Notification) {
        if let profile = notification.userInfo?[Constants.NotificationKeys.profile] as? AWSProfile {
            activeProfile = profile.name
        }
    }
    
    @MainActor
    @objc private func handleSessionExpired() {
        showError("Session Expired", message: "Your session has expired. Please reconnect.")
        activeProfile = nil
    }
    
    // MARK: - Helpers
    
    @MainActor
    private func showError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension NSTextField {
    func centerTextVertically() {
        let height = bounds.height
        let frame = NSRect(x: 0, y: (height - 17) / 2, width: bounds.width, height: 17)
        self.frame = frame
    }
}
