import SwiftUI

struct SessionCountdownView: View {
    @State private var timeRemaining: TimeInterval
    
    var body: some View {
        let hours = Int(timeRemaining) / 3600
        let minutes = (Int(timeRemaining) % 3600) / 60
        let seconds = Int(timeRemaining) % 60
        
        return Text(String(format: "Session: %02d:%02d:%02d", hours, minutes, seconds))
            .font(.caption)
            .padding(.horizontal)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notification.Name(Constants.Notifications.sessionTimeUpdated)
                )
            ) { notification in
                if let remaining = notification.userInfo?[Constants.NotificationKeys.timeRemaining] as? TimeInterval {
                    self.timeRemaining = remaining
                }
            }
    }
}
