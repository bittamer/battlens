import Foundation

final class BattLensStore {
    let rootURL: URL
    let samplesURL: URL
    let awakeSpansURL: URL
    let stateURL: URL
    let logsURL: URL

    init(rootURL: URL? = nil) throws {
        let resolvedRoot = try rootURL ?? Self.defaultRootURL()
        self.rootURL = resolvedRoot
        self.samplesURL = resolvedRoot.appendingPathComponent("battery-samples.ndjson")
        self.awakeSpansURL = resolvedRoot.appendingPathComponent("awake-spans.ndjson")
        self.stateURL = resolvedRoot.appendingPathComponent("tracker-state.json")
        self.logsURL = resolvedRoot.appendingPathComponent("logs", isDirectory: true)

        try FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true, attributes: nil)
    }

    static func defaultRootURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["BATTLENS_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BattLensError.message("Could not resolve Application Support directory.")
        }

        return baseURL.appendingPathComponent("battlens", isDirectory: true)
    }

    func appendSample(_ sample: BatterySample) throws {
        try append(sample, to: samplesURL)
    }

    func appendAwakeSpan(_ span: AwakeSpan) throws {
        guard span.duration > 0 else {
            return
        }

        try append(span, to: awakeSpansURL)
    }

    func loadSamples() throws -> [BatterySample] {
        try loadCollection(from: samplesURL)
    }

    func loadAwakeSpans() throws -> [AwakeSpan] {
        try loadCollection(from: awakeSpansURL)
    }

    func loadState() throws -> TrackerState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: stateURL)
        return try Self.decoder.decode(TrackerState.self, from: data)
    }

    func saveState(_ state: TrackerState) throws {
        let data = try Self.encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    func clearState() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: stateURL)
    }

    private func append<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encoder.encode(value)
        let lineBreak = Data([0x0A])

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: lineBreak)
    }

    private func loadCollection<T: Decodable>(from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            return []
        }

        return try content
            .split(whereSeparator: \.isNewline)
            .map { try Self.decoder.decode(T.self, from: Data($0.utf8)) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
