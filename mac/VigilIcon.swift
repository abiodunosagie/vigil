/// The SF Symbol for Vigil's state, shared by the menu bar icon and the panel header.
enum VigilIcon {
    static func symbol(holding: Bool, phase: SessionWatcher.Phase) -> String {
        guard holding else { return "moon.zzz" }
        if case .working = phase { return "cup.and.saucer.fill" }
        return "cup.and.saucer"
    }
}
