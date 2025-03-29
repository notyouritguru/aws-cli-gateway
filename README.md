<details><summary>Thinking</summary>Let me analyze the current README and prepare an update for version 0.2.0 that includes all the new features we've discussed, particularly:

1. The new terminal integration with the 'gateway' command
2. The removal of "Make Default" in favor of the connected profile approach
3. The improved session management with fixes for circular dependencies
4. Better error handling

I'll preserve the existing structure while adding the new features.</details>

# AWS CLI Gateway

<p align="center">
    <img src="AWS CLI Gateway/Assets.xcassets/AppIcon.appiconset/aws-cli-512.png">
</p>

## Overview

A menu bar macOS application that simplifies the management of AWS profiles and sessions, with a focus on AWS SSO.

## What's New in Version 0.2.0

- **Terminal Integration**: The new ```gateway``` command lets you run AWS CLI commands using your connected profile <br> without specifying ```--profile``` every time
- **Connected Profile**: Simplified workflow that automatically uses your connected profile in terminal commands
- **Enhanced Session Management**: Improved session tracking and renewal with more stable performance
- **Debug Tools**: Added diagnostic features to help troubleshoot profile and session issues

## Features

AWS CLI Gateway offers a comprehensive set of features to streamline your AWS profile management:

1. **AWS Profile Management**
   - **SSO Profiles**: Create and manage AWS Single Sign-On profiles with support for permission sets
   - **IAM Role Profiles**: Configure profiles that assume IAM roles from source profiles
   - **Connected Profile**: Simply click the star next to any profile to connect to it

2. **Session Management**
   - **Session Monitoring**: Track remaining time of active AWS SSO sessions
   - **Visual Indicators**: Color-coded status indicators show session state at a glance
   - **Automatic Session Renewal**: Renew sessions before they expire
   - **Session Expiration Handling**: Clear notifications when sessions expire

3. **Menu Bar Integration**
   - **Quick Access**: Connect to profiles directly from your macOS menu bar
   - **Session Timer**: View remaining session time without opening the main app
   - **Status Indicators**: See session status with visual cues

4. **Terminal Integration**
   - **Gateway Command**: Use the ```gateway``` command to run AWS CLI commands with your connected profile
   - **Profile Listing**: Easily list available profiles with ```gateway list``` or specific profile types with ```gateway list sso```
   - **Seamless Experience**: Work with the same profile in both GUI and terminal without manual switching

## Installation

This app is open source and not signed with an Apple Developer ID.

### Option 1: Download the Application

1. Download the ```.zip``` file from the Release Page2. Move the application to your Applications folder
3. When launching for the first time, macOS will show a security warning
4. Go to **System Settings > Privacy & Security** and click **Open Anyway**
5. Confirm by clicking **Open** in the dialog that appears

### Option 2: Build from Source

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/aws-cli-gateway.git
   cd aws-cli-gateway
   ```

2. Open the project in Xcode:
   ```
   open AWS_CLI_Gateway.xcodeproj
   ```

3. Build the application:
   - Select **Product > Archive** from the menu
   - When the Archive window appears, select **Distribute App**
   - Choose **Custom** and click **Next**
   - Select **Copy App** and choose a destination folder
   - Click **Export**

4. Move the exported ```.app``` file to your Applications folder

## Terminal Integration

To install the ```gateway``` command:

1. Click on the AWS CLI Gateway menu bar icon
2. Select **Install Terminal Command**
3. Provide your administrator password when prompted

Once installed, you can use commands like:

```bash
# Run AWS commands with your connected profile
gateway s3 ls
gateway ec2 describe-instances

# List available profiles
gateway list
gateway list sso
gateway list role

# Get help
gateway help

# Display debug information
gateway debug
```

The ```gateway``` command automatically uses whichever profile is currently connected in the AWS CLI Gateway app.

## Screenshots

<img src="screenshots/Menu Bar.png" width= 75%>

<img src="screenshots/Session Timer.png" width= 75%>

<img src="screenshots/Terminal.png" width= 75%>

<img src="screenshots/Permission Sets.png" width= 75%>

<img src="screenshots/IAM Roles.png" width= 75%>

## Requirements

- macOS 12 (Monterey) or later
- AWS CLI (v2) must be installed and configured
- AWS SSO must be configured for your organization
- Python 3 (pre-installed on macOS) for terminal integration

## Usage

1. Launch AWS CLI Gateway
2. Click "Add Profile" to set up your first AWS profile
3. Connect to your profile by clicking the star icon next to it
4. Run AWS CLI commands in terminal using the ```gateway``` command

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Future Features

- **Multiple connected profiles**: Support for connecting to multiple profiles simultaneously
- **Profile grouping**: Organize profiles by account, region, or custom groups
- **Enhanced terminal integration**: More powerful terminal commands and profile management
