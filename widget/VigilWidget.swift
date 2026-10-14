import SwiftUI
import WidgetKit

/// The desktop widget: whether Vigil holds the Mac, for how long, the open sessions and today.
/// It reads the snapshot the app writes; the app asks WidgetKit to reload on every change.
struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: context.isPreview ? .placeholder : WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads on every change. If it dies, the second entry turns the widget to
        // "not running" exactly when the snapshot goes out of date.
        let snapshot = WidgetSnapshot.read()
        var entries = [Entry(date: .now, snapshot: snapshot)]
        if let snapshot, !snapshot.stopped {
            entries.append(Entry(date: snapshot.updatedAt.addingTimeInterval(WidgetSnapshot.maxAge), snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct VigilWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.isCurrent(at: entry.date) {
                if family == .systemSmall { small(snapshot) } else { medium(snapshot) }
            } else {
                // No snapshot, or one from a Vigil that quit or crashed: never show a stale hold.
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "moon.zzz").font(.title2)
                    Text("Vigil is not running").font(.headline)
                    Text("Open Vigil to start").font(.caption).opacity(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.24), Color(red: 0.05, green: 0.04, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
        }
        .foregroundStyle(.white)
    }

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: s.holding ? "cup.and.saucer.fill" : "moon.zzz")
                .font(.title2)
                .foregroundStyle(s.holding ? Color.orange : Color.white.opacity(0.6))
            Spacer(minLength: 0)
            Text(s.phase).font(.headline).lineLimit(2)
            if s.active > 0 {
                Text(s.active == 1 ? "1 session" : "\(s.active) sessions").font(.caption).opacity(0.7)
            }
            if s.holding, let since = s.holdingSince {
                Text(since, style: .timer).font(.caption.monospacedDigit()).opacity(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            small(s).frame(width: 120)
            VStack(alignment: .leading, spacing: 5) {
                if s.sessions.isEmpty {
                    Text("No Claude sessions open").font(.caption).opacity(0.7)
                } else {
                    ForEach(Array(s.sessions.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Circle().fill(item.activity.tint).frame(width: 6, height: 6)
                            Text(item.project).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(item.activity.label).font(.caption2).opacity(0.6).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(todayText(s)).font(.caption2).opacity(0.6)
            }
        }
    }

    private func todayText(_ s: WidgetSnapshot) -> String {
        Format.today(tasks: s.todayTasks, working: s.todayWorking, longest: nil)
    }
}

@main
struct VigilWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VigilWidget", provider: Provider()) { entry in
            VigilWidgetView(entry: entry)
        }
        .configurationDisplayName("Vigil")
        .description("Whether your Mac is held awake for Claude, the open sessions, and today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
