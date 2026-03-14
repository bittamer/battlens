import Darwin
import Foundation

enum Formatters {
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter
    }()
}

struct ReportRenderer {
    let samples: [BatterySample]
    let awakeSpans: [AwakeSpan]
    let state: TrackerState?
    let useColor: Bool
    let now: Date

    func render(days: Int, sessionLimit: Int) -> String {
        let recentSamples = samples.sorted { $0.timestamp < $1.timestamp }
        let spans = mergedAwakeSpans()
        let sessions = SessionAnalyzer.sessions(from: recentSamples, awakeSpans: spans)
            .filter { $0.consumedPercent >= 3 || $0.awakeDuration >= 900 }

        var lines: [String] = []

        lines.append(style("BattLens", .accent, bold: true))
        lines.append(style("Battery history and awake-time tracking for macOS", .muted))
        lines.append("")

        if let latest = recentSamples.last {
            let timeLeft = latest.timeRemainingMinutes.map(formatDuration(minutes:)) ?? "n/a"
            lines.append("Now: \(style(String(format: "%.1f%%", latest.level), levelColor(for: latest.level), bold: true))  \(latest.powerSource)  remaining \(timeLeft)")
            lines.append("Latest sample: \(Formatters.timestamp.string(from: latest.timestamp))")
        } else {
            lines.append("No samples recorded yet. Run `battlens track` or `battlens snapshot` to start logging.")
        }

        lines.append("Data dir: \(style(storePath(), .muted))")
        lines.append("")

        lines.append(sectionTitle("Battery Trend"))
        lines.append(contentsOf: renderBatteryGraph(days: days))
        lines.append("")

        lines.append(sectionTitle("Awake Time"))
        lines.append(contentsOf: renderAwakeBars(days: days))
        lines.append("")

        lines.append(sectionTitle("Single-Charge Sessions"))
        lines.append(contentsOf: renderSessions(sessions: sessions, limit: sessionLimit))

        return lines.joined(separator: "\n")
    }

    private func mergedAwakeSpans() -> [AwakeSpan] {
        var spans = awakeSpans.sorted { $0.start < $1.start }

        if let state, state.isFresh, let activeAwakeStart = state.activeAwakeStart {
            spans.append(AwakeSpan(start: activeAwakeStart, end: now))
        }

        return spans
    }

    private func renderBatteryGraph(days: Int) -> [String] {
        guard !samples.isEmpty else {
            return [style("No battery history yet.", .muted)]
        }

        let chartWidth = max(28, min(72, terminalWidth() - 10))
        let chartHeight = 9
        let end = now
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end.addingTimeInterval(-Double(days) * 86_400)
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        let samplesBeforeEnd = sortedSamples.filter { $0.timestamp <= end }
        let hasSamplesInWindow = samplesBeforeEnd.contains { $0.timestamp >= start }

        guard hasSamplesInWindow else {
            return [style("No samples in the selected window.", .muted)]
        }

        var windowedSamples = samplesBeforeEnd.filter { $0.timestamp >= start }
        if let priorSample = samplesBeforeEnd.last(where: { $0.timestamp < start }) {
            windowedSamples.insert(priorSample, at: 0)
        }

        let levels = bucketedBatteryLevels(samples: windowedSamples, start: start, end: end, buckets: chartWidth)
        let minLevelValue = levels.min() ?? 0
        let maxLevelValue = levels.max() ?? 0
        let minLevel = Int(minLevelValue.rounded())
        let maxLevel = Int(maxLevelValue.rounded())
        let averageLevel = Int((levels.reduce(0, +) / Double(max(levels.count, 1))).rounded())
        let visibleRange = max(maxLevelValue - minLevelValue, 8)
        let padding = max(3, visibleRange * 0.18)
        let chartMin = max(0, floor((minLevelValue - padding) / 5) * 5)
        let chartMax = min(100, ceil((maxLevelValue + padding) / 5) * 5)
        let scale = max(chartMax - chartMin, 1)
        let guideRowIndexes = [0, 2, 4, 6, 8]
        var guideRows: [Int: String] = [:]

        for row in guideRowIndexes {
            let ratio = Double(row) / Double(chartHeight - 1)
            let value = Int((chartMax - (ratio * scale)).rounded())
            guideRows[row] = String(format: "%4d%%", value)
        }

        let plotRows = levels.map {
            Int((((chartMax - max(chartMin, min($0, chartMax))) / scale) * Double(chartHeight - 1)).rounded())
        }

        var lines: [String] = []
        lines.append(style("Range \(minLevel)% - \(maxLevel)%   Avg \(averageLevel)%   View \(Int(chartMin))% - \(Int(chartMax))%   Samples \(max(windowedSamples.count - 1, 1))", .muted))

        for row in 0..<chartHeight {
            let label = guideRows[row] ?? "    "
            var line = label + style(" │ ", .muted)

            for (index, level) in levels.enumerated() {
                let pointRow = plotRows[index]

                if row == pointRow {
                    let marker = index == levels.count - 1 ? "◆" : "●"
                    line += style(marker, levelColor(for: level), bold: true)
                    continue
                }

                if row > pointRow {
                    let depth = row - pointRow
                    let fill: String
                    let color: ANSIColor

                    switch depth {
                    case 1:
                        fill = "▓"
                        color = levelColor(for: level)
                    case 2:
                        fill = "▒"
                        color = .accent
                    default:
                        fill = "░"
                        color = .muted
                    }

                    line += style(fill, color)
                    continue
                }

                line += guideRows[row] != nil ? style("┈", .muted) : " "
            }

            lines.append(line)
        }

        lines.append("     " + style(" └" + String(repeating: "─", count: chartWidth) + "┘", .muted))
        lines.append("       " + styledAxisLabels(width: chartWidth, start: Formatters.shortDateTime.string(from: start), middle: Formatters.dayLabel.string(from: start.addingTimeInterval(end.timeIntervalSince(start) / 2)), end: Formatters.shortDateTime.string(from: end)))

        return lines
    }

    private func renderAwakeBars(days: Int) -> [String] {
        let spans = mergedAwakeSpans()
        guard !spans.isEmpty else {
            return [style("No awake-time spans yet. Start the tracker to capture sleep/wake boundaries.", .muted)]
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let starts = (0..<days).compactMap { calendar.date(byAdding: .day, value: -((days - 1) - $0), to: todayStart) }
        let values = starts.map { startOfDay -> (Date, TimeInterval) in
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86_400)
            return (startOfDay, SessionAnalyzer.overlapDuration(of: spans, within: startOfDay..<endOfDay))
        }

        let maxDuration = max(values.map(\.1).max() ?? 0, 1)
        let barWidth = 26

        return values.map { dayStart, duration in
            let ratio = duration / maxDuration
            let count = Int((ratio * Double(barWidth)).rounded())
            let bar = String(repeating: "█", count: max(0, count))
            let faded = String(repeating: "░", count: max(0, barWidth - count))
            return "\(Formatters.dayLabel.string(from: dayStart).padding(toLength: 6, withPad: " ", startingAt: 0))  \(formatDuration(duration).padding(toLength: 7, withPad: " ", startingAt: 0))  \(style(bar, .accent))\(style(faded, .muted))"
        }
    }

    private func renderSessions(sessions: [ChargeSession], limit: Int) -> [String] {
        guard !sessions.isEmpty else {
            return [style("No unplugged sessions yet. Once you use the Mac on battery, BattLens will estimate single-charge runtime here.", .muted)]
        }

        var lines: [String] = []
        lines.append("Start         Awake    Elapsed  Drop    Full-charge estimate")

        for session in sessions.suffix(limit).reversed() {
            let estimate = session.estimatedFullChargeAwakeRuntime.map(formatDuration) ?? "n/a"
            let dropText = String(format: "-%.0f%%", session.consumedPercent)
            let row = [
                Formatters.shortDateTime.string(from: session.start).padding(toLength: 13, withPad: " ", startingAt: 0),
                formatDuration(session.awakeDuration).padding(toLength: 8, withPad: " ", startingAt: 0),
                formatDuration(session.elapsedDuration).padding(toLength: 8, withPad: " ", startingAt: 0),
                dropText.padding(toLength: 7, withPad: " ", startingAt: 0),
                estimate + (session.isOngoing ? "  live" : "")
            ].joined(separator: "  ")
            lines.append(row)
        }

        if let current = sessions.last, current.isOngoing, current.consumedPercent >= 1 {
            let estimate = current.estimatedFullChargeAwakeRuntime.map(formatDuration) ?? "n/a"
            lines.append("")
            lines.append("Current run: \(formatDuration(current.awakeDuration)) awake across \(Int(current.consumedPercent.rounded()))% drop, projecting roughly \(estimate) on a full charge.")
        }

        return lines
    }

    private func storePath() -> String {
        (try? BattLensStore.defaultRootURL().path) ?? "unknown"
    }

    private func sectionTitle(_ title: String) -> String {
        style(title, .plain, bold: true)
    }

    private func style(_ text: String, _ color: ANSIColor, bold: Bool = false) -> String {
        guard useColor else {
            return text
        }

        return color.wrap(text, bold: bold)
    }

    private func levelColor(for level: Double) -> ANSIColor {
        switch level {
        case ..<20:
            return .danger
        case ..<45:
            return .warning
        default:
            return .good
        }
    }

    private func terminalWidth() -> Int {
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"], let value = Int(columns), value > 0 {
            return value
        }

        var windowSize = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0 ? max(40, Int(windowSize.ws_col)) : 80
    }

    private func bucketedBatteryLevels(samples: [BatterySample], start: Date, end: Date, buckets: Int) -> [Double] {
        guard end > start, buckets > 0, !samples.isEmpty else {
            return []
        }

        let totalDuration = end.timeIntervalSince(start)
        let bucketDuration = totalDuration / Double(buckets)
        var levels: [Double] = []
        var index = 0
        var lastLevel = samples.first?.level ?? 0

        while index < samples.count, samples[index].timestamp < start {
            lastLevel = samples[index].level
            index += 1
        }

        for bucket in 0..<buckets {
            let bucketEnd = start.addingTimeInterval(Double(bucket + 1) * bucketDuration)

            while index < samples.count, samples[index].timestamp <= bucketEnd {
                lastLevel = samples[index].level
                index += 1
            }

            levels.append(lastLevel)
        }

        return levels
    }

    private func styledAxisLabels(width: Int, start: String, middle: String, end: String) -> String {
        var characters = Array(repeating: " ", count: max(width + 2, 2))

        func place(_ label: String, at offset: Int) {
            guard !label.isEmpty else {
                return
            }

            let startIndex = max(0, min(offset, characters.count - label.count))
            for (index, character) in label.enumerated() {
                characters[startIndex + index] = String(character)
            }
        }

        place(start, at: 0)
        place(middle, at: max(0, (characters.count - middle.count) / 2))
        place(end, at: max(0, characters.count - end.count))

        return style(characters.joined(), .muted)
    }
}

enum ANSIColor {
    case plain
    case muted
    case accent
    case good
    case warning
    case danger

    func wrap(_ string: String, bold: Bool = false) -> String {
        let code: String

        switch self {
        case .plain:
            code = "39"
        case .muted:
            code = "90"
        case .accent:
            code = "36"
        case .good:
            code = "32"
        case .warning:
            code = "33"
        case .danger:
            code = "31"
        }

        let prefix = bold ? "\u{001B}[1;\(code)m" : "\u{001B}[\(code)m"
        return "\(prefix)\(string)\u{001B}[0m"
    }
}

enum SessionAnalyzer {
    static func sessions(from samples: [BatterySample], awakeSpans: [AwakeSpan]) -> [ChargeSession] {
        var sessions: [ChargeSession] = []
        var currentStartSample: BatterySample?
        var lastBatterySample: BatterySample?

        for sample in samples {
            if sample.isOnBattery {
                if currentStartSample == nil {
                    currentStartSample = sample
                }
                lastBatterySample = sample
                continue
            }

            if let startSample = currentStartSample, lastBatterySample != nil {
                sessions.append(makeSession(start: startSample, end: sample, awakeSpans: awakeSpans, ongoing: false))
            }

            currentStartSample = nil
            lastBatterySample = nil
        }

        if let startSample = currentStartSample, let lastBatterySample {
            sessions.append(makeSession(start: startSample, end: lastBatterySample, awakeSpans: awakeSpans, ongoing: true))
        }

        return sessions
    }

    static func overlapDuration(of spans: [AwakeSpan], within range: Range<Date>) -> TimeInterval {
        spans.reduce(0) { partialResult, span in
            partialResult + overlapDuration(of: span, within: range)
        }
    }

    private static func makeSession(start: BatterySample, end: BatterySample, awakeSpans: [AwakeSpan], ongoing: Bool) -> ChargeSession {
        let awake = overlapDuration(of: awakeSpans, within: start.timestamp..<end.timestamp)
        return ChargeSession(
            start: start.timestamp,
            end: end.timestamp,
            startLevel: start.level,
            endLevel: end.level,
            awakeDuration: awake,
            isOngoing: ongoing
        )
    }

    private static func overlapDuration(of span: AwakeSpan, within range: Range<Date>) -> TimeInterval {
        let start = max(span.start, range.lowerBound)
        let end = min(span.end, range.upperBound)
        return max(0, end.timeIntervalSince(start))
    }
}

func formatDuration(_ duration: TimeInterval) -> String {
    let totalMinutes = Int(duration / 60)
    if duration > 0, totalMinutes == 0 {
        return "<1m"
    }
    return formatDuration(minutes: totalMinutes)
}

func formatDuration(minutes: Int) -> String {
    guard minutes >= 0 else {
        return "n/a"
    }

    let hours = minutes / 60
    let leftoverMinutes = minutes % 60

    if hours == 0 {
        return "\(leftoverMinutes)m"
    }

    return "\(hours)h \(leftoverMinutes)m"
}
