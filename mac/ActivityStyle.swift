import SwiftUI

/// The dot colour for each session state, shared by the panel and the widget.
extension Activity {
    var tint: Color {
        switch self {
        case .working: .orange
        case .waiting: .blue
        case .background: .purple
        case .idle, .stale: .gray
        }
    }
}
