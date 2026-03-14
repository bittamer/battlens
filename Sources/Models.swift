import Foundation

struct BatterySample: Codable {
    let timestamp: Date
    let level: Double
    let currentCapacity: Int
    let maxCapacity: Int
    let isCharging: Bool
    let powerSource: String
    let timeRemainingMinutes: Int?

    var isOnBattery: Bool {
        let normalized = powerSource.lowercased()
        return normalized.contains("battery") || (!isCharging && !normalized.contains("ac"))
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
        guard let lastSampleAt else {
            return false
        }

        let maxAge = max(sampleInterval * 2.5, 300)
        return Date().timeIntervalSince(lastSampleAt) <= maxAge
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

enum BattLensError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
