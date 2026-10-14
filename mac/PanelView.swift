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
        VStack(alignment: .leading, spacing: 8) {
            if watcher.rows.isEmpty {
                Text("No Claude sessions open.").foregroundStyle(.secondary)
            } else {
                ForEach(watcher.rows) { row in
                    sessionRow(row)
                }
            }
            // Only this row ticks every second, so the rest of the panel is not redrawn.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    Text("Keeping awake for").foregroundStyle(.secondary)
                    Spacer()
                    Text(watcher.holdingSince.map { Self.duration(context.date.timeIntervalSince($0)) } ?? "Not holding")
                        .monospacedDigit()
                }
            }
            if let problem = watcher.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    private func sessionRow(_ row: SessionWatcher.Row) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Self.color(for: row.activity))
                .frame(width: 7, height: 7)
            Text(row.project).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(Self.label(for: row.activity)), \(row.since.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private static func label(for activity: Activity) -> String {
        switch activity {
        case .working: "working since"
        case .waiting: "waiting since"
        case .idle: "idle since"
        case .stale: "quiet since"
        }
    }

    private static func color(for activity: Activity) -> Color {
        switch activity {
        case .working: .orange
        case .waiting: .blue
        case .idle, .stale: .secondary
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
            watcher.activeCount == 1 ? "A Claude session is on a task." : "\(watcher.activeCount) Claude sessions are on tasks."
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
