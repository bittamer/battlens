import Foundation
import IOKit.ps

enum BatteryReader {
    static func readSnapshot(now: Date = Date()) throws -> BatterySample {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as Array

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                continue
            }

            let type = description[kIOPSTypeKey as String] as? String ?? ""
            guard type == kIOPSInternalBatteryType else {
                continue
            }

            let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int ?? 0
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let powerSource = description[kIOPSPowerSourceStateKey as String] as? String ?? "Unknown"
            let timeToEmpty = description[kIOPSTimeToEmptyKey as String] as? Int
            let timeToFull = description[kIOPSTimeToFullChargeKey as String] as? Int
            let isOnBattery = powerSource == kIOPSBatteryPowerValue || powerSource.lowercased().contains("battery")
            let timeRemaining: Int?

            if isCharging {
                timeRemaining = timeToFull
            } else if isOnBattery {
                timeRemaining = timeToEmpty
            } else {
                timeRemaining = nil
            }
            let rawLevel = maxCapacity > 0 ? (Double(currentCapacity) / Double(maxCapacity)) * 100 : 0
            let level = (rawLevel * 10).rounded() / 10

            return BatterySample(
                timestamp: now,
                level: level,
                currentCapacity: currentCapacity,
                maxCapacity: maxCapacity,
                isCharging: isCharging,
                powerSource: powerSource,
                timeRemainingMinutes: timeRemaining
            )
        }

        throw BattLensError.message("No internal battery was found on this Mac.")
    }
}
