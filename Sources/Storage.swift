import Darwin
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
        let record = try Self.encoder.encode(value)
        try Self.appendRecord(record, to: url)
    }

    private func loadCollection<T: Decodable>(from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return []
        }

        var recoveredRecords: [T] = []
        var discardedMalformedData = false

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let decodedLine = Self.decodeObjects(T.self, from: Data(line))
            recoveredRecords.append(contentsOf: decodedLine.records)
            discardedMalformedData = discardedMalformedData || decodedLine.discardedMalformedData
        }

        if recoveredRecords.isEmpty, discardedMalformedData {
            throw BattLensError.message("Stored data in \(url.lastPathComponent) is corrupted and no valid records could be recovered.")
        }

        return recoveredRecords
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

    private static func appendRecord(_ record: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )

        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        defer {
            close(descriptor)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        defer {
            flock(descriptor, LOCK_UN)
        }

        var payload = Data()
        payload.reserveCapacity(record.count + 2)

        if try fileNeedsLineBreakPrefix(descriptor: descriptor) {
            payload.append(0x0A)
        }

        payload.append(record)
        payload.append(0x0A)

        try writeAll(payload, to: descriptor)
    }

    private static func fileNeedsLineBreakPrefix(descriptor: Int32) throws -> Bool {
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard fileInfo.st_size > 0 else {
            return false
        }

        var lastByte: UInt8 = 0
        let bytesRead = pread(descriptor, &lastByte, 1, off_t(fileInfo.st_size - 1))
        guard bytesRead == 1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return lastByte != 0x0A
    }

    private static func writeAll(_ payload: Data, to descriptor: Int32) throws {
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesWritten = 0
            while bytesWritten < rawBuffer.count {
                let result = write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten
                )

                if result > 0 {
                    bytesWritten += result
                    continue
                }

                if result < 0, errno == EINTR {
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func decodeObjects<T: Decodable>(_ type: T.Type, from lineData: Data) -> DecodedLine<T> {
        let bytes = Array(lineData)
        guard !bytes.isEmpty else {
            return DecodedLine(records: [], discardedMalformedData: false)
        }

        var records: [T] = []
        var discardedMalformedData = false
        var objectStart: Int?
        var objectDepth = 0
        var isInsideString = false
        var isEscaping = false

        for (index, byte) in bytes.enumerated() {
            if let start = objectStart {
                if isInsideString {
                    if isEscaping {
                        isEscaping = false
                    } else if byte == 0x5C {
                        isEscaping = true
                    } else if byte == 0x22 {
                        isInsideString = false
                    }
                    continue
                }

                switch byte {
                case 0x22:
                    isInsideString = true
                case 0x7B:
                    objectDepth += 1
                case 0x7D:
                    objectDepth -= 1
                    if objectDepth == 0 {
                        let candidate = Data(bytes[start...index])
                        if let record = try? decoder.decode(T.self, from: candidate) {
                            records.append(record)
                        } else {
                            discardedMalformedData = true
                        }

                        objectStart = nil
                    }
                default:
                    break
                }
                continue
            }

            if isWhitespace(byte) {
                continue
            }

            guard byte == 0x7B else {
                discardedMalformedData = true
                continue
            }

            objectStart = index
            objectDepth = 1
            isInsideString = false
            isEscaping = false
        }

        if objectStart != nil {
            discardedMalformedData = true
        }

        return DecodedLine(records: records, discardedMalformedData: discardedMalformedData)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }
}

private struct DecodedLine<T> {
    let records: [T]
    let discardedMalformedData: Bool
}
