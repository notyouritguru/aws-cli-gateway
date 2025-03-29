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

                    // Update the connected profile in ProfileHistoryManager
                    ProfileHistoryManager.shared.setConnectedProfile(profile)
                } else {
                    SessionManager.shared.cleanDisconnect()

                    // Clear the connected profile in ProfileHistoryManager
                    ProfileHistoryManager.shared.clearConnectedProfile()
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
                    if let container = self?.sessionMenuItem?.view,
                       let textField = container.subviews.first as? NSTextField {
                        textField.stringValue = timeString
                    }
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

                // Create star button instead of the checkmark
                let starButton = ProfileButton(frame: NSRect(x: 0, y: 0, width: 16, height: Constants.UI.menuItemHeight))
                starButton.profile = profile
                starButton.target = self
                starButton.action = #selector(toggleProfileConnection(_:))
                starButton.bezelStyle = .inline
                starButton.isBordered = false

                // Set appropriate star icon based on connection state
                if profile.name == activeProfile {
                    starButton.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Connected")
                    if let img = starButton.image {
                        starButton.image = tintImage(img, with: .systemYellow)
                    }
                } else {
                    starButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Not Connected")
                    if let img = starButton.image {
                        starButton.image = tintImage(img, with: .secondaryLabelColor)
                    }
                }

                // Use the profile's displayName property which already handles the default case
                let profileButton = ProfileButton(frame: NSRect(x: 20, y: 0, width: 115, height: Constants.UI.menuItemHeight))
                profileButton.title = profile.displayName
                profileButton.target = self
                profileButton.action = #selector(showProfileDetails(_:))
                profileButton.bezelStyle = .inline
                profileButton.isBordered = false
                profileButton.setButtonType(.momentaryPushIn)
                profileButton.profile = profile
                profileButton.alignment = .left

                // Reposition the delete button to the far right
                let deleteButton = ProfileButton(frame: NSRect(x: 155, y: 0, width: 20, height: Constants.UI.menuItemHeight))
                deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
                deleteButton.bezelStyle = .inline
                deleteButton.isBordered = false
                deleteButton.target = self
                deleteButton.action = #selector(deleteProfile(_:))
                deleteButton.profile = profile

                itemView.addSubview(starButton)
                itemView.addSubview(profileButton)
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
            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 50))
            containerView.wantsLayer = true
            containerView.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.2).cgColor

            let customView = NSTextField(frame: NSRect(x: 0, y: 0, width: 175, height: 50))
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

        // Add the terminal command installation option
        let installCLIItem = NSMenuItem(title: "Install Terminal Command", action: #selector(installCLI), keyEquivalent: "")
        installCLIItem.target = self
        mainMenu.addItem(installCLIItem)

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Add this new method to handle star button clicks
    @MainActor
    @objc private func toggleProfileConnection(_ sender: ProfileButton) {
        guard let profile = sender.profile else { return }

        if profile.name == activeProfile {
            // If it's already the active profile, do nothing
            return
        } else {
            // Just mark this profile as connected in ProfileHistoryManager
            ProfileHistoryManager.shared.setConnectedProfile(profile.name)

            // This is critical - we need to update activeProfile to trigger the didSet
            // which will start SessionManager monitoring
            self.activeProfile = profile.name

            // Update SessionManager directly to ensure it starts monitoring
            SessionManager.shared.startMonitoring(for: profile.name)

            // Post notification so other components can update
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.profileConnected),
                object: nil,
                userInfo: [Constants.NotificationKeys.profile: profile]
            )
        }
    }

    // Add this method to show profile details
    @MainActor
    @objc private func showProfileDetails(_ sender: ProfileButton) {
        // For now, just connect to the profile when clicking its name
        connectToProfile(sender)
    }

    // Helper method to tint NSImage
    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let tintedImage = image.copy() as! NSImage
        tintedImage.lockFocus()

        color.set()

        let imageRect = NSRect(origin: .zero, size: tintedImage.size)
        imageRect.fill(using: .sourceAtop)

        tintedImage.unlockFocus()
        return tintedImage
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

                // Set this profile as the active profile
                activeProfile = profile.name

                // Also mark it as connected in the ProfileHistoryManager
                if let profileId = ProfileHistoryManager.shared.getIdForProfile(profile.name) {
                    ProfileHistoryManager.shared.setConnectedProfileById(profileId)
                } else {
                    // If we don't have an ID yet, set it by name
                    ProfileHistoryManager.shared.setConnectedProfile(profile.name)
                }

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
    @objc private func deleteProfile(_ sender: ProfileButton) {
        guard let profile = sender.profile else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Profile"
        alert.informativeText = "Are you sure you want to delete the profile '\(profile.displayName)'? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if profile.name == activeProfile {
                // If the active profile is being deleted, disconnect first
                Task {
                    do {
                        SessionManager.shared.cleanDisconnect()
                        // Attempt to properly logout via AWS CLI
                        _ = try await CommandRunner.shared.runCommand("aws", args: [
                            "sso", "logout", "--profile", profile.name])
                    } catch {
                        // If logout fails, still continue with deletion
                        print("Logout failed during profile deletion: \(error.localizedDescription)")
                    }

                    // Clear the connected profile status
                    ProfileHistoryManager.shared.clearConnectedProfile()

                    ConfigManager.shared.clearCache()
                    self.activeProfile = nil
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

                // Clear the connected profile
                ProfileHistoryManager.shared.clearConnectedProfile()

                ConfigManager.shared.clearCache()
                self.activeProfile = nil
            } catch {
                ConfigManager.shared.clearCache()
                SessionManager.shared.cleanDisconnect()

                // Still clear the connected profile even if logout fails
                ProfileHistoryManager.shared.clearConnectedProfile()

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

        // Clear the connected profile
        ProfileHistoryManager.shared.clearConnectedProfile()

        activeProfile = nil
    }

    @MainActor
    @objc private func installCLI() {
        // Show a confirmation dialog first
        let confirmAlert = NSAlert()
        confirmAlert.messageText = "Install Terminal Command"
        confirmAlert.informativeText = "This will install the 'gateway' command to /usr/local/bin. Continue?"
        confirmAlert.alertStyle = .informational
        confirmAlert.addButton(withTitle: "Install")
        confirmAlert.addButton(withTitle: "Cancel")

        let response = confirmAlert.runModal()
        if response == .alertSecondButtonReturn {
            return // User canceled
        }

        // Perform installation directly without accessing AppDelegate
        installGatewayCommand()
    }

    private func installGatewayCommand() {
        do {
            // Create a simplified gateway script with better formatting
            let scriptContent = """
    #!/bin/bash

    # Configuration
    PROFILE_HISTORY="$HOME/Library/Application Support/AWS CLI Gateway/profile_history.json"
    AWS_CONFIG="$HOME/.aws/config"
    AWS_CMD="/usr/local/bin/aws"

    # Debug function - call this when troubleshooting
    function debug_info() {
        echo "=== DEBUG INFO ==="
        echo "Script version: 1.2.0"
        echo "Profile history path: $PROFILE_HISTORY"
        echo "Profile history exists: $([ -f "$PROFILE_HISTORY" ] && echo "Yes" || echo "No")"
        if [ -f "$PROFILE_HISTORY" ]; then
            echo "Profile history content:"
            cat "$PROFILE_HISTORY" 2>/dev/null || echo "File not readable"
        fi
        echo "AWS config path: $AWS_CONFIG"
        echo "AWS config exists: $([ -f "$AWS_CONFIG" ] && echo "Yes" || echo "No")"
        echo "AWS CLI path: $AWS_CMD"
        echo "AWS CLI exists: $([ -x "$AWS_CMD" ] && echo "Yes" || echo "No")"
        echo "==================="
    }

    # Ensure required files exist
    function check_requirements() {
        if [ ! -f "$PROFILE_HISTORY" ]; then
            echo "Error: Profile history file not found at: $PROFILE_HISTORY"
            echo "Please run AWS CLI Gateway app first."
            exit 1
        fi

        if [ ! -f "$AWS_CONFIG" ]; then
            echo "Error: AWS config file not found at $AWS_CONFIG"
            exit 1
        fi

        if [ ! -x "$AWS_CMD" ]; then
            echo "Error: AWS CLI not found at $AWS_CMD"
            exit 1
        fi
    }

    # Get active profile using Python for proper JSON parsing
    function get_active_profile() {
        # Use Python to properly parse the JSON and extract the connected profile
        PROFILE=$(python3 -c "
    import json, sys
    try:
        with open('$PROFILE_HISTORY', 'r') as f:
            data = json.load(f)

        # First try to find connected profile
        connected_profile = None
        for profile in data:
            if profile.get('isConnected', False) == True:
                connected_profile = profile.get('originalName')
                break

        # If no connected profile, try default
        if not connected_profile:
            for profile in data:
                if profile.get('isDefault', False) == True:
                    connected_profile = profile.get('originalName')
                    break

        # Last resort - first profile
        if not connected_profile and data:
            connected_profile = data[0].get('originalName')

        if connected_profile:
            print(connected_profile)
        else:
            sys.stderr.write('Error: No profiles found in $PROFILE_HISTORY\\n')
            sys.exit(1)
    except Exception as e:
        sys.stderr.write(f'Error reading profile: {str(e)}\\n')
        sys.exit(1)
    ")

        echo "$PROFILE"
    }

    # List all profiles of a specific type
    function list_profiles() {
        local TYPE=$1

        echo "Available $TYPE profiles:"
        echo "------------------------"

        if [ "$TYPE" == "sso" ]; then
            grep -B 1 -A 10 '\\[profile' "$AWS_CONFIG" | 
            grep -v 'role_arn' | 
            grep -A 1 'sso_' | 
            grep '\\[profile' | 
            sed 's/\\[profile \\(.*\\)\\]/\\1/'
        elif [ "$TYPE" == "role" ] || [ "$TYPE" == "iam" ]; then
            grep -B 1 -A 10 '\\[profile' "$AWS_CONFIG" | 
            grep -B 1 'role_arn' | 
            grep '\\[profile' | 
            sed 's/\\[profile \\(.*\\)\\]/\\1/'
        else
            grep '\\[profile' "$AWS_CONFIG" | 
            sed 's/\\[profile \\(.*\\)\\]/\\1/'
        fi
    }

    # Show help message
    function show_help() {
        echo "AWS CLI Gateway - Command Line Interface"
        echo ""
        echo "USAGE:"
        echo "  gateway [COMMAND] [ARGS...]"
        echo ""
        echo "COMMANDS:"
        echo "  list sso                  List all SSO profiles"
        echo "  list role                 List all IAM role profiles" 
        echo "  list                      List all profiles"
        echo "  debug                     Show debug information"
        echo "  help                      Show this help message"
        echo ""
        echo "EXAMPLES:"
        echo "  gateway s3 ls             Run 'aws s3 ls' with current profile"
        echo "  gateway list sso          List all SSO profiles"
        echo ""
        echo "Any command not recognized as a gateway command will be passed to the AWS CLI"
        echo "with the current profile automatically added."
    }

    # Main execution
    check_requirements

    # Process commands
    case "$1" in
        "list")
            if [ "$2" == "sso" ] || [ "$2" == "role" ] || [ "$2" == "iam" ]; then
                list_profiles "$2"
            else
                list_profiles "all"
            fi
            ;;
        "help")
            show_help
            ;;
        "debug")
            debug_info
            ;;
        "")
            show_help
            ;;
        *)
            # Not a gateway command, pass to AWS CLI
            PROFILE=$(get_active_profile)
            echo "Using profile: $PROFILE" >&2

            # Check if --profile is already specified
            if [[ "$*" == *"--profile"* ]]; then
                $AWS_CMD "$@" 
            else
                $AWS_CMD "$@" --profile "$PROFILE"
            fi
            ;;
    esac

    """

                // Create a temporary file for the script
                let tempDirectory = FileManager.default.temporaryDirectory
                let scriptPath = tempDirectory.appendingPathComponent("gateway-script.sh")

                // Write script content to the temporary file
                try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)

                let destinationPath = "/usr/local/bin/gateway"

                // Create the AppleScript with proper quoting
                let script = """
                do shell script "mkdir -p /usr/local/bin && cp '\(scriptPath.path)' '\(destinationPath)' && chmod +x '\(destinationPath)'" with administrator privileges
                """

                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", script]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                task.standardOutput = outputPipe
                task.standardError = errorPipe

                try task.run()
                task.waitUntilExit()

                if task.terminationStatus != 0 {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "MenuBarManager", code: Int(task.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Installation failed: \(errorOutput)"])
                }

                // Show success feedback
                let alert = NSAlert()
                alert.messageText = "Terminal Command Installation"
                alert.informativeText = "The 'gateway' command has been installed. You can now use it in Terminal with commands like 'gateway s3 ls'."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                // Show error feedback
                let alert = NSAlert()
                alert.messageText = "Installation Failed"
                alert.informativeText = "Failed to install the gateway command: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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

            // Mark this profile as connected
            ProfileHistoryManager.shared.setConnectedProfile(profile.name)
        }
    }

    @MainActor
    @objc private func handleSessionExpired() {
        showError("Session Expired", message: "Your session has expired. Please reconnect.")

        // Clear the connected profile
        ProfileHistoryManager.shared.clearConnectedProfile()

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
