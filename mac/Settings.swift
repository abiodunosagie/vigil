import Combine
import Foundation
import Security

/// Every choice the user can make, kept in UserDefaults.
@MainActor
final class VigilSettings: ObservableObject {
    static let shared = VigilSettings()
    private let defaults = UserDefaults.standard

    // MARK: sleep

    /// Also keep the screen on (no dimming, no lock) while Vigil holds the Mac.
    @Published var keepScreenOn: Bool { didSet { save(keepScreenOn, "keepScreenOn") } }
    /// How long the Mac stays held after the last session finishes, in seconds.
    @Published var graceSeconds: Int { didSet { save(graceSeconds, "graceSeconds") } }
    /// Keep the Mac held while a command Claude started is still running after its turn.
    @Published var trackBackground: Bool { didSet { save(trackBackground, "trackBackground") } }
    /// Keep the Mac running with the lid closed while held (needs the lid helper).
    @Published var lidClosed: Bool { didSet { save(lidClosed, "lidClosed") } }
    /// On battery, let go of every hold below this charge.
    @Published var batteryGuard: Bool { didSet { save(batteryGuard, "batteryGuard") } }
    @Published var batteryFloor: Int { didSet { save(batteryFloor, "batteryFloor") } }

    // MARK: alerts

    @Published var muted: Bool { didSet { save(muted, "muted") } }
    @Published var finishedSound: String { didSet { save(finishedSound, "finishedSound") } }
    @Published var waitingSound: String { didSet { save(waitingSound, "waitingSound") } }
    @Published var allDoneSound: String { didSet { save(allDoneSound, "allDoneSound") } }
    /// No sounds between these hours (banners still show).
    @Published var quietHours: Bool { didSet { save(quietHours, "quietHours") } }
    @Published var quietFrom: Int { didSet { save(quietFrom, "quietFrom") } }
    @Published var quietTo: Int { didSet { save(quietTo, "quietTo") } }

    // MARK: phone

    /// Send the same alerts to a phone through ntfy.
    @Published var phoneAlerts: Bool { didSet { save(phoneAlerts, "phoneAlerts") } }
    /// The ntfy topic. Anyone who knows it can read the alerts, so it is long and random.
    @Published private(set) var ntfyTopic: String

    static let graceChoices = [60, 5 * 60, 15 * 60, 30 * 60]
    static let soundChoices = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "Pop", "Tink"]

    private init() {
        defaults.register(defaults: [
            "keepScreenOn": false, "graceSeconds": 60, "trackBackground": true, "lidClosed": false,
            "batteryGuard": true, "batteryFloor": 20,
            "muted": false, "finishedSound": "Glass", "waitingSound": "Ping", "allDoneSound": "Hero",
            "quietHours": false, "quietFrom": 22, "quietTo": 7, "phoneAlerts": false,
        ])
        keepScreenOn = defaults.bool(forKey: "keepScreenOn")
        graceSeconds = defaults.integer(forKey: "graceSeconds")
        trackBackground = defaults.bool(forKey: "trackBackground")
        lidClosed = defaults.bool(forKey: "lidClosed")
        batteryGuard = defaults.bool(forKey: "batteryGuard")
        batteryFloor = defaults.integer(forKey: "batteryFloor")
        muted = defaults.bool(forKey: "muted")
        finishedSound = defaults.string(forKey: "finishedSound") ?? "Glass"
        waitingSound = defaults.string(forKey: "waitingSound") ?? "Ping"
        allDoneSound = defaults.string(forKey: "allDoneSound") ?? "Hero"
        quietHours = defaults.bool(forKey: "quietHours")
        quietFrom = defaults.integer(forKey: "quietFrom")
        quietTo = defaults.integer(forKey: "quietTo")
        phoneAlerts = defaults.bool(forKey: "phoneAlerts")
        if let topic = defaults.string(forKey: "ntfyTopic"), !topic.isEmpty {
            ntfyTopic = topic
        } else {
            ntfyTopic = Self.newTopic()
            defaults.set(ntfyTopic, forKey: "ntfyTopic")
        }
    }

    /// A fresh topic, for when the old one may have leaked.
    func renewTopic() {
        ntfyTopic = Self.newTopic()
        defaults.set(ntfyTopic, forKey: "ntfyTopic")
    }

    var ntfyURL: URL { URL(string: "https://ntfy.sh/\(ntfyTopic)")! }

    /// Whether sounds are off right now, by the mute switch or quiet hours.
    func soundsOff(at date: Date = Date()) -> Bool {
        muted || (quietHours && Self.isQuiet(hour: Calendar.current.component(.hour, from: date), from: quietFrom, to: quietTo))
    }

    /// Quiet from `from` up to (not including) `to`, wrapping past midnight.
    nonisolated static func isQuiet(hour: Int, from: Int, to: Int) -> Bool {
        if from == to { return false }
        return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }

    private static func newTopic() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "vigil-" + String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
