import Foundation
import WidgetKit

/// Writes the widget's snapshot when it changes and asks WidgetKit to redraw.
@MainActor
final class WidgetPublisher {
    /// Rewritten at least this often even when nothing changed, so the widget can tell a
    /// running Vigil from one that crashed (see `WidgetSnapshot.isCurrent`).
    static let heartbeat: TimeInterval = 5 * 60
    private var last: WidgetSnapshot?

    func publish(_ snapshot: WidgetSnapshot) {
        if let last, last.sameContent(as: snapshot),
           snapshot.updatedAt.timeIntervalSince(last.updatedAt) < Self.heartbeat { return }
        last = snapshot
        snapshot.write()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func publishStopped() {
        publish(WidgetSnapshot(holding: false, phase: "Vigil is not running", holdingSince: nil, active: 0,
                               sessions: [], todayTasks: last?.todayTasks ?? 0, todayWorking: last?.todayWorking ?? 0,
                               updatedAt: Date(), stopped: true))
    }
}
