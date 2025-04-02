import Foundation

class ScriptManager {
    static let shared = ScriptManager()

    private init() {}

    // MARK: - Gateway Command Installation

    func installGatewayCommand() throws -> String {
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
            throw NSError(domain: "ScriptManager", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Installation failed: \(errorOutput)"])
        }

        return "The 'gateway' command has been installed. You can now use it in Terminal with commands like 'gateway s3 ls'."
    }

    // MARK: - Other Script Utilities

    func clearAWSCache() throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let cacheDir = "\(homeDir)/.aws/cli/cache"

        // Delete cache directory
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "rm -rf '\(cacheDir)'"]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ScriptManager", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Cache clearing failed: \(errorOutput)"])
        }

        return "AWS CLI cache has been cleared successfully."
    }
}
