import Foundation
import IOKit.ps

enum BatteryReader {
    static func readSnapshot(now: Date = Date()) throws -> BatterySample {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as Array
        var validationErrors: [String] = []

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any]
            else {
                continue
            }

            do {
                if let sample = try sample(from: description, now: now) {
                    return sample
                }
            } catch {
                validationErrors.append(error.localizedDescription)
            }
        }

        if let error = validationErrors.first {
            throw BattLensError.message(error)
        }

        throw BattLensError.message("No internal battery was found on this Mac.")
    }

    static func sample(from description: [String: Any], now: Date = Date()) throws -> BatterySample? {
        let type = try requiredString(kIOPSTypeKey as String, in: description)
        guard type == kIOPSInternalBatteryType else {
            return nil
        }

        let currentCapacity = try requiredInt(kIOPSCurrentCapacityKey as String, in: description)
        let maxCapacity = try requiredInt(kIOPSMaxCapacityKey as String, in: description)
        let isCharging = try requiredBool(kIOPSIsChargingKey as String, in: description)
        let powerSource = try requiredString(kIOPSPowerSourceStateKey as String, in: description)

        guard maxCapacity > 0 else {
            throw BattLensError.message("Battery sample reported an invalid Max Capacity value: \(maxCapacity).")
        }

        guard currentCapacity >= 0, currentCapacity <= maxCapacity else {
            throw BattLensError.message(
                "Battery sample reported an out-of-range Current Capacity value: \(currentCapacity) for Max Capacity \(maxCapacity)."
            )
        }

        let timeToEmpty = try optionalInt(kIOPSTimeToEmptyKey as String, in: description)
        let timeToFull = try optionalInt(kIOPSTimeToFullChargeKey as String, in: description)
        let powerSourceState = powerSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isOnBattery = powerSourceState == (kIOPSBatteryPowerValue as String).lowercased()
            || powerSourceState.contains("battery")
        let timeRemaining: Int?

        if isCharging {
            timeRemaining = timeToFull
        } else if isOnBattery {
            timeRemaining = timeToEmpty
        } else {
            timeRemaining = nil
        }

        let level = (Double(currentCapacity) / Double(maxCapacity)) * 100

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

    private static func requiredString(_ key: String, in description: [String: Any]) throws -> String {
        guard let rawValue = description[key] else {
            throw BattLensError.message("Battery sample was missing \(key).")
        }

        guard let value = rawValue as? String, !value.isEmpty else {
            throw BattLensError.message("Battery sample had an invalid \(key) value.")
        }

        return value
    }

    private static func requiredInt(_ key: String, in description: [String: Any]) throws -> Int {
        guard let rawValue = description[key] else {
            throw BattLensError.message("Battery sample was missing \(key).")
        }

        if let value = rawValue as? Int {
            return value
        }

        if let value = rawValue as? NSNumber {
            return value.intValue
        }

        throw BattLensError.message("Battery sample had an invalid \(key) value.")
    }

    private static func optionalInt(_ key: String, in description: [String: Any]) throws -> Int? {
        guard let rawValue = description[key] else {
            return nil
        }

        if let value = rawValue as? Int {
            return value
        }

        if let value = rawValue as? NSNumber {
            return value.intValue
        }

        throw BattLensError.message("Battery sample had an invalid \(key) value.")
    }

    private static func requiredBool(_ key: String, in description: [String: Any]) throws -> Bool {
        guard let rawValue = description[key] else {
            throw BattLensError.message("Battery sample was missing \(key).")
        }

        if let value = rawValue as? Bool {
            return value
        }

        if let value = rawValue as? NSNumber {
            return value.boolValue
        }

        throw BattLensError.message("Battery sample had an invalid \(key) value.")
    }
}
