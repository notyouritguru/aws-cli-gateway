import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    
    var body: some View {
        VStack(alignment: .leading, spacing: Constants.UI.standardPadding) {
            headerSection
            
            if let currentProfile = viewModel.currentProfile {
                activeProfileSection(profileName: currentProfile)
            } else {
                noProfileSection
            }
            
            statusSection
            
            Spacer()
        }
        .padding(Constants.UI.standardPadding)
        .frame(
            width: Constants.UI.profilesWindow.width,
            height: Constants.UI.profilesWindow.height
        )
    }
    
    // MARK: - View Components
    
    private var headerSection: some View {
        Text(Constants.appName)
            .font(.title)
            .bold()
    }
    
    private func activeProfileSection(profileName: String) -> some View {
        VStack(alignment: .leading, spacing: Constants.UI.smallPadding) {
            Text("Connected to profile: \(profileName)")
                .font(.headline)
            
            if let timeRemaining = viewModel.sessionTimeRemaining {
                Text(timeRemaining)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Button("Renew Session") {
                viewModel.renewSession()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.sessionStatus == Constants.Session.sessionExpired)
        }
    }
    
    private var noProfileSection: some View {
        VStack(alignment: .leading, spacing: Constants.UI.smallPadding) {
            Text("No profile connected")
                .font(.headline)
            
            Button("Add Profile") {
                viewModel.showAddProfileWindow()
            }
            .buttonStyle(.bordered)
        }
    }
    
    private var statusSection: some View {
        StatusIndicator(status: viewModel.sessionStatus)
            .padding(.top, Constants.UI.smallPadding)
    }
    struct ContentView_Previews: PreviewProvider {
        static var previews: some View {
            ContentView()
        }
    }
}
