//
//  BatteryStatusViewModel.swift
//  Command Space
//
//  Battery level and power source (read from IOKit on demand).
//

import Foundation
import IOKit.ps

@MainActor
final class BatteryStatusViewModel {
    static let shared = BatteryStatusViewModel()
    private init() {}

    /// 0–100, or 0 on a Mac without a battery.
    var levelBattery: Float { Float(read()?.level ?? 0) }
    var isPluggedIn: Bool { read()?.plugged ?? true }

    private func read() -> (level: Int, plugged: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = description[kIOPSPowerSourceStateKey] as? String
            return (max > 0 ? current * 100 / max : current, state == kIOPSACPowerValue)
        }
        return nil
    }
}
