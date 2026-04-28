import Foundation

struct BattLensReportData {
    let samples: [BatterySample]
    let awakeSpans: [AwakeSpan]
    let state: TrackerState?
    let now: Date
    let mergedAwakeSpans: [AwakeSpan]
    let dischargeSessions: [ChargeSession]
    let chargingSessions: [ChargingSession]

    init(samples: [BatterySample], awakeSpans: [AwakeSpan], state: TrackerState?, now: Date) {
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        var activeSpans = awakeSpans

        if let state, let activeSpan = state.activeAwakeSpan(now: now, trackerIsRunning: processIsRunning(state.trackerPID)) {
            activeSpans.append(activeSpan)
        }

        let mergedSpans = SessionAnalyzer.mergeAwakeSpans(activeSpans)
        let dischargeSessions = SessionAnalyzer.sessions(from: sortedSamples, awakeSpans: mergedSpans)
            .filter { $0.consumedPercent >= 3 || $0.awakeDuration >= 900 }
        let chargingSessions = SessionAnalyzer.chargingSessions(from: sortedSamples, awakeSpans: mergedSpans)
            .filter { $0.gainedPercent >= 3 || $0.elapsedDuration >= 900 || $0.isOngoing }

        self.samples = sortedSamples
        self.awakeSpans = awakeSpans
        self.state = state
        self.now = now
        self.mergedAwakeSpans = mergedSpans
        self.dischargeSessions = dischargeSessions
        self.chargingSessions = chargingSessions
    }

    var latestSample: BatterySample? {
        samples.last
    }

    func awakeDuration(on dayStart: Date, calendar: Calendar = .current) -> TimeInterval {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return SessionAnalyzer.overlapDuration(of: mergedAwakeSpans, within: dayStart..<endOfDay)
    }

    func awakeDurations(days: Int, calendar: Calendar = .current) -> [(Date, TimeInterval)] {
        guard days > 0 else {
            return []
        }

        let todayStart = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            let dayOffset = -((days - 1) - offset)
            guard let start = calendar.date(byAdding: .day, value: dayOffset, to: todayStart) else {
                return nil
            }

            return (start, awakeDuration(on: start, calendar: calendar))
        }
    }

    func averageDischargeRatePercentPerHour() -> Double? {
        let measurableSessions = dischargeSessions.filter { $0.consumedPercent >= 1 && $0.awakeDuration > 0 }
        let totalConsumed = measurableSessions.reduce(0) { $0 + $1.consumedPercent }
        let totalAwake = measurableSessions.reduce(0) { $0 + $1.awakeDuration }

        guard totalConsumed > 0, totalAwake > 0 else {
            return nil
        }

        return totalConsumed / totalAwake * 3600
    }

    func fullChargeAwakeEstimate() -> TimeInterval? {
        let measurableSessions = dischargeSessions.filter { $0.consumedPercent >= 1 && $0.awakeDuration > 0 }
        let totalConsumed = measurableSessions.reduce(0) { $0 + $1.consumedPercent }
        let totalAwake = measurableSessions.reduce(0) { $0 + $1.awakeDuration }

        guard totalConsumed > 0, totalAwake > 0 else {
            return nil
        }

        return totalAwake / totalConsumed * 100
    }

    func averageChargingRatePercentPerHour() -> Double? {
        let measurableSessions = chargingSessions.filter { $0.gainedPercent >= 1 && $0.elapsedDuration > 0 }
        let totalGain = measurableSessions.reduce(0) { $0 + $1.gainedPercent }
        let totalElapsed = measurableSessions.reduce(0) { $0 + $1.elapsedDuration }

        guard totalGain > 0, totalElapsed > 0 else {
            return nil
        }

        return totalGain / totalElapsed * 3600
    }
}
