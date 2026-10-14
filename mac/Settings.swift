import Combine
import Foundation
import Security

/// Every choice the user can make, kept in UserDefaults. Each key and its default live once,
/// in `Key`.
@MainActor
final class VigilSettings: ObservableObject {
    static let shared = VigilSettings()
    private let defaults: UserDefaults

    enum Key: String, CaseIterable {
        case keepScreenOn, graceSeconds, trackBackground, lidClosed, batteryGuard, batteryFloor
        case muted, finishedSound, waitingSound, allDoneSound, quietHours, quietFrom, quietTo
        case phoneAlerts, ntfyTopic

        var defaultValue: Any? {
            switch self {
            case .keepScreenOn, .lidClosed, .muted, .quietHours, .phoneAlerts: false
            case .trackBackground, .batteryGuard: true
            case .graceSeconds: 60
            case .batteryFloor: 20
            case .finishedSound: "Glass"
            case .waitingSound: "Ping"
            case .allDoneSound: "Hero"
            case .quietFrom: 22
            case .quietTo: 7
            // Made on first use, never a fixed default.
            case .ntfyTopic: nil
            }
        }
    }

    // MARK: sleep

    /// Also keep the screen on (no dimming, no lock) while Vigil holds the Mac.
    @Published var keepScreenOn: Bool { didSet { save(keepScreenOn, .keepScreenOn) } }
    /// How long the Mac stays held after the last session finishes, in seconds.
    @Published var graceSeconds: Int { didSet { save(graceSeconds, .graceSeconds) } }
    /// Keep the Mac held while a command Claude started is still running after its turn.
    @Published var trackBackground: Bool { didSet { save(trackBackground, .trackBackground) } }
    /// Keep the Mac running with the lid closed while held (needs the lid helper).
    @Published var lidClosed: Bool { didSet { save(lidClosed, .lidClosed) } }
    /// On battery, let go of every hold below this charge.
    @Published var batteryGuard: Bool { didSet { save(batteryGuard, .batteryGuard) } }
    @Published var batteryFloor: Int { didSet { save(batteryFloor, .batteryFloor) } }

    // MARK: alerts

    @Published var muted: Bool { didSet { save(muted, .muted) } }
    @Published var finishedSound: String { didSet { save(finishedSound, .finishedSound) } }
    @Published var waitingSound: String { didSet { save(waitingSound, .waitingSound) } }
    @Published var allDoneSound: String { didSet { save(allDoneSound, .allDoneSound) } }
    /// No sounds between these hours (banners still show).
    @Published var quietHours: Bool { didSet { save(quietHours, .quietHours) } }
    @Published var quietFrom: Int { didSet { save(quietFrom, .quietFrom) } }
    @Published var quietTo: Int { didSet { save(quietTo, .quietTo) } }

    // MARK: phone

    /// Send the same alerts to a phone through ntfy.
    @Published var phoneAlerts: Bool { didSet { save(phoneAlerts, .phoneAlerts) } }
    /// The ntfy topic. Anyone who knows it can read the alerts, so it is long and random.
    @Published private(set) var ntfyTopic: String

    static let graceChoices = [60, 5 * 60, 15 * 60, 30 * 60]
    /// The sounds offered in Settings; build-app.sh copies these plus `warningSound`.
    static let soundChoices = ["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "Pop", "Tink"]
    /// The battery notice's sound, not user selectable.
    static let warningSound = "Basso"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Key.allCases.compactMap { key in
            key.defaultValue.map { (key.rawValue, $0) }
        }))
        keepScreenOn = defaults.bool(forKey: Key.keepScreenOn.rawValue)
        graceSeconds = defaults.integer(forKey: Key.graceSeconds.rawValue)
        trackBackground = defaults.bool(forKey: Key.trackBackground.rawValue)
        lidClosed = defaults.bool(forKey: Key.lidClosed.rawValue)
        batteryGuard = defaults.bool(forKey: Key.batteryGuard.rawValue)
        batteryFloor = defaults.integer(forKey: Key.batteryFloor.rawValue)
        muted = defaults.bool(forKey: Key.muted.rawValue)
        // register(defaults:) guarantees a value for every key with a default.
        finishedSound = defaults.string(forKey: Key.finishedSound.rawValue) ?? ""
        waitingSound = defaults.string(forKey: Key.waitingSound.rawValue) ?? ""
        allDoneSound = defaults.string(forKey: Key.allDoneSound.rawValue) ?? ""
        quietHours = defaults.bool(forKey: Key.quietHours.rawValue)
        quietFrom = defaults.integer(forKey: Key.quietFrom.rawValue)
        quietTo = defaults.integer(forKey: Key.quietTo.rawValue)
        phoneAlerts = defaults.bool(forKey: Key.phoneAlerts.rawValue)
        if let topic = defaults.string(forKey: Key.ntfyTopic.rawValue), !topic.isEmpty {
            ntfyTopic = topic
        } else {
            ntfyTopic = Self.newTopic()
            defaults.set(ntfyTopic, forKey: Key.ntfyTopic.rawValue)
        }
    }

    /// A fresh topic, for when the old one may have leaked.
    func renewTopic() {
        ntfyTopic = Self.newTopic()
        defaults.set(ntfyTopic, forKey: Key.ntfyTopic.rawValue)
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

    /// "vigil-" plus 24 characters from a 36 letter alphabet (about 124 bits). Bytes past the
    /// largest multiple of 36 are skipped, so every character is equally likely.
    nonisolated static func newTopic() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let limit = UInt8(256 / alphabet.count * alphabet.count)
        var out = ""
        while out.count < 24 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { continue }
            if byte < limit { out.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return "vigil-" + out
    }

    private func save(_ value: Any, _ key: Key) { defaults.set(value, forKey: key.rawValue) }
}
