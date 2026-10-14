import Foundation
import IOKit.ps

/// The internal battery, read from IOKit power sources.
enum Battery {
    struct Reading: Equatable {
        let percent: Int
        let onBattery: Bool
    }

    /// Nil on a Mac without a battery.
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return Reading(percent: current * 100 / max, onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }
}
