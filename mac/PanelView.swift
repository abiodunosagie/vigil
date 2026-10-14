import AppKit
import SwiftUI

/// The panel under the menu bar icon: what Vigil is doing, launch at login, and Quit.
struct PanelView: View {
    @ObservedObject var watcher: SessionWatcher
    @ObservedObject var login: LoginSwitch

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            details
            Divider()
            Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            if let loginError = login.error {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Vigil").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: VigilIcon.symbol(for: watcher.phase))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Claude sessions open", "\(watcher.openCount)")
            row("Working now", "\(watcher.workingCount)")
            // Only this row ticks every second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row("Keeping awake for", watcher.holdingSince.map { Self.duration(context.date.timeIntervalSince($0)) } ?? "Not holding")
            }
            if let problem = watcher.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var title: String {
        switch watcher.phase {
        case .working: "Keeping your Mac awake"
        case .finishing: "Claude just finished"
        case .idle: "Mac can sleep"
        }
    }

    private var subtitle: String {
        switch watcher.phase {
        case .working:
            "Claude is on a task."
        case .finishing(let until):
            "Normal sleep resumes at \(until.formatted(date: .omitted, time: .shortened))."
        case .idle:
            "Sleeping on your usual settings."
        }
    }

    private var accent: Color {
        switch watcher.phase {
        case .working: .orange
        case .finishing: .orange.opacity(0.7)
        case .idle: .secondary
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
