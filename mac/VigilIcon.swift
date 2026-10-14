/// The SF Symbol for each phase, shared by the menu bar icon and the panel header.
enum VigilIcon {
    static func symbol(for phase: SessionWatcher.Phase) -> String {
        switch phase {
        case .working: "cup.and.saucer.fill"
        case .finishing: "cup.and.saucer"
        case .idle: "moon.zzz"
        }
    }
}
