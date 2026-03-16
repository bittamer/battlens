import Foundation
import IOKit.ps

struct BatterySample: Codable {
    let timestamp: Date
    let level: Double
    let currentCapacity: Int
    let maxCapacity: Int
    let isCharging: Bool
    let powerSource: String
    let timeRemainingMinutes: Int?

    private var normalizedPowerSource: String {
        powerSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var powerSourceState: PowerSourceState {
        let normalizedACPower = (kIOPSACPowerValue as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBatteryPower = (kIOPSBatteryPowerValue as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedOfflinePower = "off line"

        if normalizedPowerSource == normalizedBatteryPower || normalizedPowerSource.contains("battery") {
            return .battery
        }

        if normalizedPowerSource == normalizedACPower || normalizedPowerSource.contains("ac") {
            return .ac
        }

        if normalizedPowerSource == normalizedOfflinePower || normalizedPowerSource.contains("offline") || normalizedPowerSource.contains("off line") {
            return .offline
        }

        return .unknown
    }

    var isOnBattery: Bool {
        powerSourceState == .battery
    }

    var displayedTimeRemainingMinutes: Int? {
        guard let timeRemainingMinutes, timeRemainingMinutes >= 0 else {
            return nil
        }

        return (isCharging || isOnBattery) ? timeRemainingMinutes : nil
    }

    var powerFlowState: PowerFlowState {
        if isCharging {
            return .charging
        }

        switch powerSourceState {
        case .battery:
            return .discharging
        case .ac:
            return .pluggedInIdle
        case .offline, .unknown:
            return .unknown
        }
    }
}

enum PowerSourceState: Equatable {
    case battery
    case ac
    case offline
    case unknown
}

enum PowerFlowState: Equatable {
    case discharging
    case charging
    case pluggedInIdle
    case unknown

    var statusText: String {
        switch self {
        case .discharging:
            return "on battery"
        case .charging:
            return "charging"
        case .pluggedInIdle:
            return "plugged in"
        case .unknown:
            return "unknown"
        }
    }
}

struct AwakeSpan: Codable {
    let start: Date
    let end: Date

    var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
}

struct TrackerState: Codable {
    var activeAwakeStart: Date?
    var lastSampleAt: Date?
    var sampleInterval: TimeInterval
    var trackerPID: Int32
    var updatedAt: Date

    var isFresh: Bool {
        isFresh(at: Date())
    }

    func isFresh(at now: Date) -> Bool {
        guard let lastSampleAt else {
            return false
        }

        let maxAge = max(sampleInterval * 2.5, 300)
        return now.timeIntervalSince(lastSampleAt) <= maxAge
    }

    func activeAwakeSpan(now: Date, trackerIsRunning: Bool) -> AwakeSpan? {
        guard let activeAwakeStart else {
            return nil
        }

        let boundedEnd: Date
        if trackerIsRunning && isFresh(at: now) {
            boundedEnd = now
        } else if let lastSampleAt, lastSampleAt > activeAwakeStart {
            boundedEnd = min(now, lastSampleAt)
        } else if updatedAt > activeAwakeStart {
            boundedEnd = min(now, updatedAt)
        } else {
            return nil
        }

        guard boundedEnd > activeAwakeStart else {
            return nil
        }

        return AwakeSpan(start: activeAwakeStart, end: boundedEnd)
    }
}

struct ChargeSession {
    let start: Date
    let end: Date
    let startLevel: Double
    let endLevel: Double
    let awakeDuration: TimeInterval
    let isOngoing: Bool

    var elapsedDuration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    var consumedPercent: Double {
        max(0, startLevel - endLevel)
    }

    var estimatedFullChargeAwakeRuntime: TimeInterval? {
        guard consumedPercent >= 1, awakeDuration > 0 else {
            return nil
        }

        return awakeDuration / consumedPercent * 100
    }
}

struct ChargingSession {
    let start: Date
    let end: Date
    let startLevel: Double
    let endLevel: Double
    let awakeDuration: TimeInterval
    let isOngoing: Bool

    var elapsedDuration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    var gainedPercent: Double {
        max(0, endLevel - startLevel)
    }

    var averageRatePercentPerHour: Double? {
        guard gainedPercent > 0, elapsedDuration > 0 else {
            return nil
        }

        return gainedPercent / elapsedDuration * 3600
    }

    var estimatedTimeToFull: TimeInterval? {
        guard gainedPercent >= 1, elapsedDuration > 0 else {
            return nil
        }

        let remainingPercent = max(0, 100 - min(endLevel, 100))
        return elapsedDuration / gainedPercent * remainingPercent
    }

    var estimatedZeroToFullDuration: TimeInterval? {
        guard gainedPercent >= 1, elapsedDuration > 0 else {
            return nil
        }

        return elapsedDuration / gainedPercent * 100
    }
}

enum BattLensError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
