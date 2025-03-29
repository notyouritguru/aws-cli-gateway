import Foundation

enum Constants {
    // MARK: - App Information
    static let appName = "AWS SSO Gateway"
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    // MARK: - File Paths & Extensions
    enum Paths {
        static let awsConfigDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws")
        static let awsConfigFile = awsConfigDirectory
            .appendingPathComponent("config")
        static let awsCredentialsFile = awsConfigDirectory
            .appendingPathComponent("credentials")
        static let awsCliCacheDirectory = awsConfigDirectory
            .appendingPathComponent("cli/cache")

        // Fix: Use appName directly instead of Constants.appName
        static let appSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(appName)

        static let profilesStore = appSupportDirectory?
            .appendingPathComponent("profiles.json")
    }

    // MARK: - Notifications
    enum Notifications {
        static let sessionMonitoringStarted = "com.awssso.gateway.sessionMonitoringStarted"
        static let sessionMonitoringStopped = "com.awssso.gateway.sessionMonitoringStopped"
        static let sessionTimeUpdated = "com.awssso.gateway.sessionTimeUpdated"
        static let sessionWarning = "com.awssso.gateway.sessionWarning"
        static let sessionExpired = "com.awssso.gateway.sessionExpired"
        static let sessionRenewed = "com.awssso.gateway.sessionRenewed"
        static let profilesUpdated = "com.awssso.gateway.profilesUpdated"
        static let profileConnected = "com.awssso.gateway.profileConnected"
        static let profilesUpdatedAlt = "ProfilesUpdated"
    }

    // MARK: - Notification Keys
    enum NotificationKeys {
        // Profile related
        static let profileName = "profileName"
        static let profile = "profile"

        // Session related
        static let timeRemaining = "timeRemaining"
        static let threshold = "threshold"
        static let expirationDate = "expirationDate"

        // Status related
        static let status = "status"
        static let error = "error"
    }

    // MARK: - UI Constants
    enum UI {
        // Window Sizes
        static let addProfileWindow = NSSize(width: 400, height: 300)
        static let settingsWindow = NSSize(width: 400, height: 300)
        static let profilesWindow = NSSize(width: 500, height: 400)

        // Colors and Styling
        static let cornerRadius: CGFloat = 8.0
        static let standardPadding: CGFloat = 16.0
        static let smallPadding: CGFloat = 8.0

        // Animation Durations
        static let standardAnimation = 0.3
        static let quickAnimation = 0.15

        // Menu Item Heights
        static let menuItemHeight: CGFloat = 22.0
        static let menuSeparatorHeight: CGFloat = 8.0
    }

    // MARK: - AWS CLI Commands
    enum Commands {
        static let ssoLogin = "aws sso login --profile"
        static let configList = "aws configure list"
        static let getCallerIdentity = "aws sts get-caller-identity"
        static let ssoLogout = "aws sso logout"

        // Command Timeouts (in seconds)
        static let defaultTimeout: TimeInterval = 30
        static let loginTimeout: TimeInterval = 120
    }

    // MARK: - Session Monitoring
    enum Session {
        // Check intervals
        static let checkInterval: TimeInterval = 60 // 1 minute

        // Warning thresholds (in seconds)
        static let warningThresholds: [TimeInterval] = [
            3600,  // 1 hour
            1800,  // 30 minutes
            600,   // 10 minutes
            300,   // 5 minutes
            60     // 1 minute
        ]

        // Session states
        static let noActiveSession = "No Active Session"
        static let sessionExpired = "Session Expired"
        static let sessionActive = "Session Active"
    }

    // MARK: - Error Messages
    enum ErrorMessages {
        static let profileValidation = "Please ensure all fields are filled correctly"
        static let awsCliNotFound = "AWS CLI is not installed. Please install it to use this application"
        static let ssoLoginFailed = "SSO login failed. Please try again"
        static let configurationError = "Error reading AWS configuration"
        static let profileCreationError = "Failed to create AWS profile"
        static let sessionExpired = "AWS SSO session has expired"
        static let commandTimeout = "Command execution timed out"
        static let invalidProfile = "Invalid profile configuration"
        static let networkError = "Network connection error"
        static let permissionError = "Permission denied"
    }

    // MARK: - UserDefaults Keys
    enum UserDefaultsKeys {
        static let lastUsedProfile = "lastUsedProfile"
        static let launchAtLogin = "launchAtLogin"
        static let showSessionTimer = "showSessionTimer"
        static let notificationsEnabled = "notificationsEnabled"
        static let autoRenewSession = "autoRenewSession"
    }

    // MARK: - AWS Output Formats
    struct AWS {
        static let outputFormats = [
            "json",
            "yaml",
            "text",
            "table"
        ]
    }
    
    struct Constants {

        struct Notifications {
            static let profilesUpdated = "ProfilesUpdated"
            // Other notification constants...
        }
    }
}
