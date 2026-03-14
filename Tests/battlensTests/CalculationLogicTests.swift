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
