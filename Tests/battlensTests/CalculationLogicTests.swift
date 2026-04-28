import Foundation
import IOKit.ps
import Testing
@testable import battlens

@Test
func closedSessionEndsAtLastBatterySampleAndUsesRecordedChargeLevels() throws {
    let start = Date(timeIntervalSince1970: 0)
    let lastBattery = Date(timeIntervalSince1970: 3_600)
    let pluggedIn = Date(timeIntervalSince1970: 5_400)

    let samples = [
        BatterySample(
            timestamp: start,
            level: 100.0,
            currentCapacity: 6_000,
            maxCapacity: 6_000,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 300
        ),
        BatterySample(
            timestamp: lastBattery,
            level: 90.0,
            currentCapacity: 5_397,
            maxCapacity: 6_000,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 240
        ),
        BatterySample(
            timestamp: pluggedIn,
            level: 95.0,
            currentCapacity: 5_700,
            maxCapacity: 6_000,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 60
        )
    ]

    let sessions = SessionAnalyzer.sessions(
        from: samples,
        awakeSpans: [AwakeSpan(start: start, end: pluggedIn)]
    )

    #expect(sessions.count == 1)

    let session = try #require(sessions.first)
    #expect(session.end == lastBattery)
    #expect(abs(session.awakeDuration - 3_600) < 0.001)
    #expect(abs(session.consumedPercent - 10.0) < 0.001)
    #expect(abs((session.estimatedFullChargeAwakeRuntime ?? 0) - ((3_600 / 10.0) * 100)) < 0.001)
}

@Test
func batteryReaderRejectsMissingCapacityInsteadOfRecordingZeroPercent() {
    let description: [String: Any] = [
        kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
        kIOPSMaxCapacityKey as String: 100,
        kIOPSIsChargingKey as String: false,
        kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String
    ]

    var didThrow = false

    do {
        _ = try BatteryReader.sample(from: description, now: Date(timeIntervalSince1970: 0))
    } catch {
        didThrow = true
        #expect(error.localizedDescription.contains("Current Capacity"))
    }

    #expect(didThrow)
}

@Test
func sessionsMergeOverlappingAwakeSpansBeforeSumming() throws {
    let start = Date(timeIntervalSince1970: 0)
    let lastBattery = Date(timeIntervalSince1970: 300)
    let pluggedIn = Date(timeIntervalSince1970: 360)

    let samples = [
        BatterySample(
            timestamp: start,
            level: 80.0,
            currentCapacity: 4_800,
            maxCapacity: 6_000,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 180
        ),
        BatterySample(
            timestamp: lastBattery,
            level: 75.0,
            currentCapacity: 4_500,
            maxCapacity: 6_000,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 165
        ),
        BatterySample(
            timestamp: pluggedIn,
            level: 75.0,
            currentCapacity: 4_500,
            maxCapacity: 6_000,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 45
        )
    ]
    let overlappingAwakeSpans = [
        AwakeSpan(start: start, end: Date(timeIntervalSince1970: 200)),
        AwakeSpan(start: Date(timeIntervalSince1970: 100), end: lastBattery)
    ]

    let sessions = SessionAnalyzer.sessions(from: samples, awakeSpans: overlappingAwakeSpans)
    let session = try #require(sessions.first)

    #expect(abs(session.awakeDuration - 300) < 0.001)
}

@Test
func dischargeSessionsSplitAcrossSleepBoundaries() throws {
    let start = Date(timeIntervalSince1970: 0)
    let beforeSleep = Date(timeIntervalSince1970: 3_600)
    let afterWake = Date(timeIntervalSince1970: 10_800)
    let beforeCharge = Date(timeIntervalSince1970: 14_400)
    let pluggedIn = Date(timeIntervalSince1970: 15_000)

    let samples = [
        BatterySample(
            timestamp: start,
            level: 100.0,
            currentCapacity: 100,
            maxCapacity: 100,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 300
        ),
        BatterySample(
            timestamp: beforeSleep,
            level: 90.0,
            currentCapacity: 90,
            maxCapacity: 100,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 240
        ),
        BatterySample(
            timestamp: afterWake,
            level: 80.0,
            currentCapacity: 80,
            maxCapacity: 100,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 180
        ),
        BatterySample(
            timestamp: beforeCharge,
            level: 70.0,
            currentCapacity: 70,
            maxCapacity: 100,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 150
        ),
        BatterySample(
            timestamp: pluggedIn,
            level: 71.0,
            currentCapacity: 71,
            maxCapacity: 100,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 90
        )
    ]

    let sessions = SessionAnalyzer.sessions(
        from: samples,
        awakeSpans: [
            AwakeSpan(start: start, end: beforeSleep),
            AwakeSpan(start: afterWake, end: beforeCharge)
        ]
    )

    #expect(sessions.count == 2)

    let first = try #require(sessions.first)
    let second = try #require(sessions.last)

    #expect(first.start == start)
    #expect(first.end == beforeSleep)
    #expect(abs(first.consumedPercent - 10.0) < 0.001)
    #expect(abs(first.awakeDuration - 3_600) < 0.001)

    #expect(second.start == afterWake)
    #expect(second.end == beforeCharge)
    #expect(abs(second.consumedPercent - 10.0) < 0.001)
    #expect(abs(second.awakeDuration - 3_600) < 0.001)
}

@Test
func activeAwakeSpanFallsBackToLastSampleWhenTrackerIsNotRunning() throws {
    let state = TrackerState(
        activeAwakeStart: Date(timeIntervalSince1970: 0),
        lastSampleAt: Date(timeIntervalSince1970: 600),
        sampleInterval: 300,
        trackerPID: 42,
        updatedAt: Date(timeIntervalSince1970: 600)
    )

    let span = try #require(
        state.activeAwakeSpan(
            now: Date(timeIntervalSince1970: 1_200),
            trackerIsRunning: false
        )
    )

    #expect(span.start == Date(timeIntervalSince1970: 0))
    #expect(span.end == Date(timeIntervalSince1970: 600))
}

@Test
func sparseSnapshotOnlyDischargeHistoryDoesNotProduceSyntheticSessions() {
    let start = Date(timeIntervalSince1970: 0)
    let later = Date(timeIntervalSince1970: 7_200)
    let pluggedIn = Date(timeIntervalSince1970: 10_800)

    let sessions = SessionAnalyzer.sessions(
        from: [
            BatterySample(
                timestamp: start,
                level: 100.0,
                currentCapacity: 100,
                maxCapacity: 100,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 300
            ),
            BatterySample(
                timestamp: later,
                level: 70.0,
                currentCapacity: 70,
                maxCapacity: 100,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 120
            ),
            BatterySample(
                timestamp: pluggedIn,
                level: 72.0,
                currentCapacity: 72,
                maxCapacity: 100,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 60
            )
        ],
        awakeSpans: []
    )

    #expect(sessions.isEmpty)
}

@Test
func displayedTimeRemainingIsHiddenForIdleACSamples() {
    let sample = BatterySample(
        timestamp: Date(timeIntervalSince1970: 0),
        level: 100.0,
        currentCapacity: 6_000,
        maxCapacity: 6_000,
        isCharging: false,
        powerSource: "AC Power",
        timeRemainingMinutes: 240
    )

    #expect(sample.displayedTimeRemainingMinutes == nil)
}

@Test
func unknownAndOfflinePowerSourcesAreNotTreatedAsBattery() {
    let unknown = BatterySample(
        timestamp: Date(timeIntervalSince1970: 0),
        level: 50.0,
        currentCapacity: 50,
        maxCapacity: 100,
        isCharging: false,
        powerSource: "Unknown",
        timeRemainingMinutes: 240
    )
    let offline = BatterySample(
        timestamp: Date(timeIntervalSince1970: 0),
        level: 50.0,
        currentCapacity: 50,
        maxCapacity: 100,
        isCharging: false,
        powerSource: "Off Line",
        timeRemainingMinutes: 240
    )

    #expect(!unknown.isOnBattery)
    #expect(unknown.powerFlowState == .unknown)
    #expect(unknown.displayedTimeRemainingMinutes == nil)

    #expect(!offline.isOnBattery)
    #expect(offline.powerFlowState == .unknown)
    #expect(offline.displayedTimeRemainingMinutes == nil)
}

@Test
func chargingSessionUsesPluggedInIdleSampleAsCompletionBoundary() throws {
    let start = Date(timeIntervalSince1970: 0)
    let lastCharging = Date(timeIntervalSince1970: 1_800)
    let chargeComplete = Date(timeIntervalSince1970: 2_400)

    let samples = [
        BatterySample(
            timestamp: start,
            level: 20.0,
            currentCapacity: 1_200,
            maxCapacity: 6_000,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 180
        ),
        BatterySample(
            timestamp: lastCharging,
            level: 50.0,
            currentCapacity: 3_000,
            maxCapacity: 6_000,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 90
        ),
        BatterySample(
            timestamp: chargeComplete,
            level: 80.0,
            currentCapacity: 4_800,
            maxCapacity: 6_000,
            isCharging: false,
            powerSource: "AC Power",
            timeRemainingMinutes: nil
        )
    ]

    let sessions = SessionAnalyzer.chargingSessions(
        from: samples,
        awakeSpans: [AwakeSpan(start: start, end: chargeComplete)]
    )

    let session = try #require(sessions.first)
    #expect(session.end == chargeComplete)
    #expect(abs(session.gainedPercent - 60) < 0.001)
    #expect(abs((session.estimatedTimeToFull ?? 0) - 800) < 0.001)
}

@Test
func chargingSessionFallsBackToLastChargingSampleWhenUnplugged() throws {
    let start = Date(timeIntervalSince1970: 0)
    let lastCharging = Date(timeIntervalSince1970: 900)
    let unplugged = Date(timeIntervalSince1970: 1_200)

    let samples = [
        BatterySample(
            timestamp: start,
            level: 30.0,
            currentCapacity: 1_800,
            maxCapacity: 6_000,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 120
        ),
        BatterySample(
            timestamp: lastCharging,
            level: 45.0,
            currentCapacity: 2_700,
            maxCapacity: 6_000,
            isCharging: true,
            powerSource: "AC Power",
            timeRemainingMinutes: 95
        ),
        BatterySample(
            timestamp: unplugged,
            level: 44.0,
            currentCapacity: 2_640,
            maxCapacity: 6_000,
            isCharging: false,
            powerSource: "Battery Power",
            timeRemainingMinutes: 150
        )
    ]

    let sessions = SessionAnalyzer.chargingSessions(
        from: samples,
        awakeSpans: [AwakeSpan(start: start, end: unplugged)]
    )

    let session = try #require(sessions.first)
    #expect(session.end == lastCharging)
    #expect(abs(session.gainedPercent - 15) < 0.001)
}

@Test
func sparseSnapshotOnlyChargingHistoryDoesNotProduceSyntheticSessions() {
    let start = Date(timeIntervalSince1970: 0)
    let later = Date(timeIntervalSince1970: 7_200)
    let complete = Date(timeIntervalSince1970: 7_800)

    let sessions = SessionAnalyzer.chargingSessions(
        from: [
            BatterySample(
                timestamp: start,
                level: 20.0,
                currentCapacity: 20,
                maxCapacity: 100,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 180
            ),
            BatterySample(
                timestamp: later,
                level: 80.0,
                currentCapacity: 80,
                maxCapacity: 100,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 45
            ),
            BatterySample(
                timestamp: complete,
                level: 81.0,
                currentCapacity: 81,
                maxCapacity: 100,
                isCharging: false,
                powerSource: "AC Power",
                timeRemainingMinutes: nil
            )
        ],
        awakeSpans: []
    )

    #expect(sessions.isEmpty)
}

@Test
func reportShowsChargingStatusAndChargingSection() {
    let start = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 1_200)
    let renderer = ReportRenderer(
        samples: [
            BatterySample(
                timestamp: start,
                level: 40.0,
                currentCapacity: 2_400,
                maxCapacity: 6_000,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 90
            ),
            BatterySample(
                timestamp: now,
                level: 55.0,
                currentCapacity: 3_300,
                maxCapacity: 6_000,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 45
            )
        ],
        awakeSpans: [AwakeSpan(start: start, end: now)],
        state: nil,
        useColor: false,
        now: now
    )

    let report = renderer.render(days: 1, sessionLimit: 5)

    #expect(report.contains("Charging Sessions"))
    #expect(report.contains("to full 45m"))
    #expect(report.contains("Current charge:"))
}

@Test
func reportShowsAggregateDischargeEstimateAcrossSessions() {
    let firstStart = Date(timeIntervalSince1970: 0)
    let firstEnd = Date(timeIntervalSince1970: 3_600)
    let firstCharge = Date(timeIntervalSince1970: 4_200)
    let secondStart = Date(timeIntervalSince1970: 7_200)
    let secondEnd = Date(timeIntervalSince1970: 10_800)
    let secondCharge = Date(timeIntervalSince1970: 11_400)

    let renderer = ReportRenderer(
        samples: [
            BatterySample(
                timestamp: firstStart,
                level: 100.0,
                currentCapacity: 6_000,
                maxCapacity: 6_000,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 300
            ),
            BatterySample(
                timestamp: firstEnd,
                level: 90.0,
                currentCapacity: 5_400,
                maxCapacity: 6_000,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 240
            ),
            BatterySample(
                timestamp: firstCharge,
                level: 92.0,
                currentCapacity: 5_520,
                maxCapacity: 6_000,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 90
            ),
            BatterySample(
                timestamp: secondStart,
                level: 80.0,
                currentCapacity: 4_800,
                maxCapacity: 6_000,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 220
            ),
            BatterySample(
                timestamp: secondEnd,
                level: 60.0,
                currentCapacity: 3_600,
                maxCapacity: 6_000,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 120
            ),
            BatterySample(
                timestamp: secondCharge,
                level: 61.0,
                currentCapacity: 3_660,
                maxCapacity: 6_000,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 75
            )
        ],
        awakeSpans: [
            AwakeSpan(start: firstStart, end: firstEnd),
            AwakeSpan(start: secondStart, end: secondEnd)
        ],
        state: nil,
        useColor: false,
        now: secondCharge
    )

    let report = renderer.render(days: 1, sessionLimit: 5)

    #expect(report.contains("Avg drain 15.0%/hr awake"))
    #expect(report.contains("Full-charge estimate 6h 40m"))
    #expect(report.contains("Sessions 2"))
}

@Test
func reportDataProvidesSharedDashboardCalculations() throws {
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 3_600)
    let pluggedIn = Date(timeIntervalSince1970: 3_900)

    let data = BattLensReportData(
        samples: [
            BatterySample(
                timestamp: start,
                level: 100.0,
                currentCapacity: 6_000,
                maxCapacity: 6_000,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 300
            ),
            BatterySample(
                timestamp: end,
                level: 90.0,
                currentCapacity: 5_400,
                maxCapacity: 6_000,
                isCharging: false,
                powerSource: "Battery Power",
                timeRemainingMinutes: 240
            ),
            BatterySample(
                timestamp: pluggedIn,
                level: 91.0,
                currentCapacity: 5_460,
                maxCapacity: 6_000,
                isCharging: true,
                powerSource: "AC Power",
                timeRemainingMinutes: 90
            )
        ],
        awakeSpans: [AwakeSpan(start: start, end: end)],
        state: nil,
        now: pluggedIn
    )

    #expect(data.latestSample?.timestamp == pluggedIn)
    #expect(data.dischargeSessions.count == 1)
    #expect(abs((data.averageDischargeRatePercentPerHour() ?? 0) - 10.0) < 0.001)
    #expect(abs((data.fullChargeAwakeEstimate() ?? 0) - 36_000) < 0.001)
    #expect(abs((data.awakeDurations(days: 1).first?.1 ?? 0) - 3_600) < 0.001)
}
