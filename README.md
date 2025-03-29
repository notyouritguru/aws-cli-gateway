# AWS CLI Gateway

<p align="center">
    <img src="AWS CLI Gateway/Assets.xcassets/AppIcon.appiconset/aws-cli-512.png">
</p>

## Overview

A menu bar macOS application that simplifies the management of AWS profiles and sessions, with a focus on AWS SSO.

## Features

AWS CLI Gateway offers a comprehensive set of features to streamline your AWS profile management:

1. **AWS Profile Management**
   - **SSO Profiles**: Create and manage AWS Single Sign-On profiles with support for permission sets
   - **IAM Role Profiles**: Configure profiles that assume IAM roles from source profiles
   - **Default Profile**: Easily set and manage your default AWS profile

2. **Session Management**
   - **Session Monitoring**: Track remaining time of active AWS SSO sessions
   - **Visual Indicators**: Color-coded status indicators show session state at a glance
   - **Automatic Session Renewal**: Renew sessions before they expire
   - **Session Expiration Handling**: Clear notifications when sessions expire

3. **Menu Bar Integration**
   - **Quick Access**: Connect to profiles directly from your macOS menu bar
   - **Session Timer**: View remaining session time without opening the main app
   - **Status Indicators**: See session status with visual cues

## Installation

### Option 1: Download the Application

1. Download the ```.app``` file from the Releases page
2. Move the application to your Applications folder
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

## Screenshots

<img src="screenshots/Menu Bar.png">

<img src="screenshots/Permission Sets.png" width= 75%>

<img src="screenshots/IAM Roles.png" width= 75%>

## Requirements

- macOS 12 (Monterey) or later
- AWS CLI (v2) must be installed and configured
- AWS SSO must be configured for your organization

## Usage

1. Launch AWS CLI Gateway
2. Click "Add Profile" to set up your first AWS profile
3. Connect to your profile and enjoy simplified AWS access!

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
