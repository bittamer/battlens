import Foundation
import Testing
@testable import battlens

@Test
func closedSessionEndsAtLastBatterySampleAndUsesPreciseChargeDrop() throws {
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
    #expect(abs(session.consumedPercent - 10.05) < 0.001)
    #expect(abs((session.estimatedFullChargeAwakeRuntime ?? 0) - ((3_600 / 10.05) * 100)) < 0.001)
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
