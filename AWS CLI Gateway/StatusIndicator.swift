import SwiftUI

struct StatusIndicator: View {
    let status: String
    
    var body: some View {
        HStack(spacing: Constants.UI.smallPadding) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(status)
                .font(.caption)
                .foregroundColor(statusColor)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case Constants.Session.sessionActive:
            return .green
        case Constants.Session.sessionExpired:
            return .red
        default:
            return .secondary
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        StatusIndicator(status: Constants.Session.sessionActive)
        StatusIndicator(status: Constants.Session.sessionExpired)
        StatusIndicator(status: Constants.Session.noActiveSession)
    }
    .padding()
}
