import Foundation
import Testing
@testable import battlens

@Test
func loadSamplesRecoversValidRecordsFromCorruptedLines() throws {
    let (store, rootURL) = try makeTemporaryStore()
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    let first = sample(level: 10, timestamp: 1)
    let second = sample(level: 20, timestamp: 2)
    let truncated = sample(level: 30, timestamp: 3)
    let fourth = sample(level: 40, timestamp: 4)

    var payload = Data()
    payload.append(try encode(first))
    payload.append(try encode(second))
    payload.append(0x0A)

    let truncatedRecord = try encode(truncated)
    payload.append(truncatedRecord.dropLast())
    payload.append(0x0A)

    payload.append(try encode(fourth))
    payload.append(0x0A)

    try payload.write(to: store.samplesURL, options: .atomic)

    let loaded = try store.loadSamples()

    #expect(loaded.map(\.level) == [10, 20, 40])
    #expect(loaded.map(\.timestamp) == [
        first.timestamp,
        second.timestamp,
        fourth.timestamp
    ])
}

@Test
func appendSampleStartsFreshLineAfterPartialRecordAtEOF() throws {
    let (store, rootURL) = try makeTemporaryStore()
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    try Data("{\"timestamp\":1710000000000".utf8).write(to: store.samplesURL, options: .atomic)

    let appended = sample(level: 55, timestamp: 5)
    try store.appendSample(appended)

    let loaded = try store.loadSamples()

    #expect(loaded.count == 1)

    let recovered = try #require(loaded.first)
    #expect(recovered.timestamp == appended.timestamp)
    #expect(recovered.level == appended.level)
    #expect(recovered.currentCapacity == appended.currentCapacity)
}

private func makeTemporaryStore() throws -> (BattLensStore, URL) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("battlens-tests-\(UUID().uuidString)", isDirectory: true)
    let store = try BattLensStore(rootURL: rootURL)
    return (store, rootURL)
}

private func sample(level: Double, timestamp: TimeInterval) -> BatterySample {
    BatterySample(
        timestamp: Date(timeIntervalSince1970: timestamp),
        level: level,
        currentCapacity: Int(level),
        maxCapacity: 100,
        isCharging: false,
        powerSource: "Battery Power",
        timeRemainingMinutes: 120
    )
}

private func encode(_ sample: BatterySample) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(sample)
}
