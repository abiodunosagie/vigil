import AppKit
import SwiftUI

/// The panel under the menu bar icon: what Vigil is doing, the open sessions, today, the
/// quick switches, Settings and Quit.
struct PanelView: View {
    @ObservedObject var watcher: SessionWatcher
    @ObservedObject var settings: VigilSettings
    @ObservedObject var login: LoginSwitch
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            sessions
            todayLine
            Divider()
            manualHold
            Toggle("Keep screen on too", isOn: $settings.keepScreenOn)
                .toggleStyle(.switch).controlSize(.small)
            Toggle("Mute sounds", isOn: $settings.muted)
                .toggleStyle(.switch).controlSize(.small)
            Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                .toggleStyle(.switch).controlSize(.small)
            if let loginError = login.error {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Divider()
            Button("Settings…", action: openSettings)
                .buttonStyle(.link)
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Text("Quit Vigil").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: VigilIcon.symbol(holding: watcher.isHolding, phase: watcher.phase))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                // Only this line ticks every second, so the rest of the panel is not redrawn.
                if let since = watcher.holdingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Awake for \(Self.duration(context.date.timeIntervalSince(since)))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private var title: String {
        if watcher.batteryBlocked { return "Battery low, letting go" }
        switch watcher.phase {
        case .working: return "Keeping your Mac awake"
        case .finishing: return "Claude just finished"
        case .idle: return watcher.manualUntil != nil ? "Holding on your request" : "Mac can sleep"
        }
    }

    private var subtitle: String {
        if watcher.batteryBlocked { return "Below \(settings.batteryFloor)% on battery. Plug in to hold." }
        switch watcher.phase {
        case .working:
            let count = watcher.activeCount
            return count == 1 ? "A Claude session is on a task." : "\(count) Claude sessions are on tasks."
        case .finishing(let until):
            return "Normal sleep resumes at \(until.formatted(date: .omitted, time: .shortened))."
        case .idle:
            if let until = watcher.manualUntil {
                return until == .distantFuture ? "Until you turn it off." : "Until \(until.formatted(date: .omitted, time: .shortened))."
            }
            return "Sleeping on your usual settings."
        }
    }

    private var accent: Color {
        if watcher.batteryBlocked { return .red }
        return watcher.isHolding ? .orange : .secondary
    }

    // MARK: sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if watcher.rows.isEmpty {
                Text("No Claude sessions open.").foregroundStyle(.secondary)
            } else {
                ForEach(watcher.rows) { row in
                    HStack(spacing: 8) {
                        Circle().fill(Self.color(for: row.activity)).frame(width: 7, height: 7)
                        Text(row.project).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(SessionWatcher.activityLabel(row.activity)), \(row.since.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if let problem = watcher.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    private var todayLine: some View {
        let today = watcher.today
        let longest = today.longest.flatMap(\.duration).map { ", longest \(Format.length($0))" } ?? ""
        let text = today.tasks == 0
            ? "Today: no finished tasks yet."
            : "Today: \(today.tasks) task\(today.tasks == 1 ? "" : "s"), \(Format.length(today.working)) working\(longest)."
        return Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: manual hold

    @ViewBuilder
    private var manualHold: some View {
        if watcher.manualUntil != nil {
            Button("End manual hold") { watcher.endManualHold() }
        } else {
            Menu("Keep awake without Claude") {
                Button("For 30 minutes") { watcher.holdManually(for: 30 * 60) }
                Button("For 1 hour") { watcher.holdManually(for: 60 * 60) }
                Button("For 2 hours") { watcher.holdManually(for: 2 * 60 * 60) }
                Button("For 4 hours") { watcher.holdManually(for: 4 * 60 * 60) }
                Divider()
                Button("Until I turn it off") { watcher.holdManually(for: nil) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: helpers

    private static func color(for activity: Activity) -> Color {
        switch activity {
        case .working: .orange
        case .waiting: .blue
        case .background: .purple
        case .idle, .stale: .secondary
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
