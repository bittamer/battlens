import Darwin
import Foundation

struct DashboardOptions {
    let refreshInterval: TimeInterval
    let days: Int
    let sessionLimit: Int
}

final class TerminalDashboard {
    private let store: BattLensStore
    private let options: DashboardOptions
    private var selectedView: DashboardView = .dashboard
    private var selectedSessionIndex = 0
    private var expandedSession = false
    private var currentDays: Int
    private var statusMessage = "Ready"
    private var lastRenderAt = Date.distantPast
    private var cachedFrame: DashboardFrame?
    private var shouldQuit = false
    private var useColor: Bool {
        ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    init(store: BattLensStore, options: DashboardOptions) {
        self.store = store
        self.options = options
        self.currentDays = options.days
    }

    func run() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw BattLensError.message("The dashboard needs an interactive terminal.")
        }

        let terminal = RawTerminal()
        try terminal.enter()
        defer {
            terminal.leave()
        }

        try reload()
        redraw()

        while !shouldQuit {
            let wait = max(0.05, min(0.25, options.refreshInterval - Date().timeIntervalSince(lastRenderAt)))
            if let key = terminal.readKey(timeout: wait) {
                try handle(key: key)
                redraw()
                continue
            }

            if Date().timeIntervalSince(lastRenderAt) >= options.refreshInterval {
                try reload()
                redraw()
            }
        }
    }

    private func reload() throws {
        let now = Date()
        let data = BattLensReportData(
            samples: try store.loadSamples(),
            awakeSpans: try store.loadAwakeSpans(),
            state: try store.loadState(),
            now: now
        )
        let liveSample = try? BatteryReader.readSnapshot(now: now)
        cachedFrame = DashboardFrame(data: data, liveSample: liveSample, loadedAt: now)
        clampSelection()
        lastRenderAt = now
    }

    private func redraw() {
        guard let cachedFrame else {
            return
        }

        let size = TerminalSize.current()
        let renderer = DashboardRenderer(
            frame: cachedFrame,
            selectedView: selectedView,
            selectedSessionIndex: selectedSessionIndex,
            expandedSession: expandedSession,
            days: currentDays,
            sessionLimit: options.sessionLimit,
            refreshInterval: options.refreshInterval,
            statusMessage: statusMessage,
            useColor: useColor,
            size: size
        )
        writeTerminalString(renderer.render())
    }

    private func handle(key: DashboardKey) throws {
        switch key {
        case .character("q"), .character("Q"), .controlC:
            shouldQuit = true
        case .character("r"), .character("R"):
            try reload()
            statusMessage = "Refreshed at \(Formatters.shortDateTime.string(from: Date()))"
        case .character("s"), .character("S"):
            let sample = try BatteryReader.readSnapshot()
            try store.appendSample(sample)
            try reload()
            statusMessage = "Snapshot logged: \(String(format: "%.1f%%", sample.level))"
        case .character("t"), .character("T"):
            cycleDays()
            try reload()
            statusMessage = "Range set to \(rangeLabel)"
        case .character("i"), .character("I"):
            try installAgent()
        case .character("u"), .character("U"):
            try LaunchAgentManager.uninstall()
            try reload()
            statusMessage = "Launch agent removed"
        case .left, .character("<"), .character("h"), .character("H"):
            selectedView = selectedView.previous
            expandedSession = false
            clampSelection()
        case .right, .character(">"), .character("l"), .character("L"):
            selectedView = selectedView.next
            expandedSession = false
            clampSelection()
        case .up:
            selectedSessionIndex = max(0, selectedSessionIndex - 1)
        case .down:
            selectedSessionIndex = min(max(0, sessionItems.count - 1), selectedSessionIndex + 1)
        case .enter:
            if selectedView == .sessions {
                expandedSession.toggle()
            }
        default:
            break
        }
    }

    private func installAgent() throws {
        let interval = max(1, Int(options.refreshInterval.rounded()))
        let executablePath = resolvedExecutablePath()
        try LaunchAgentManager.install(store: store, executablePath: executablePath, interval: interval)
        try reload()
        statusMessage = "Launch agent installed"
    }

    private func resolvedExecutablePath() -> String {
        let rawPath = CommandLine.arguments.first ?? "battlens"
        if rawPath.hasPrefix("/") {
            return rawPath
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(rawPath)
            .standardized
            .path
    }

    private var sessionItems: [DashboardSessionItem] {
        guard let cachedFrame else {
            return []
        }

        let discharges = cachedFrame.data.dischargeSessions.map(DashboardSessionItem.discharge)
        let charges = cachedFrame.data.chargingSessions.map(DashboardSessionItem.charge)
        return (discharges + charges).sorted { $0.start > $1.start }
    }

    private func clampSelection() {
        selectedSessionIndex = min(max(0, selectedSessionIndex), max(0, sessionItems.count - 1))
    }

    private func cycleDays() {
        let ranges = [1, 7, 30, 0]
        let currentIndex = ranges.firstIndex(of: currentDays) ?? 1
        currentDays = ranges[(currentIndex + 1) % ranges.count]
    }

    private var rangeLabel: String {
        currentDays == 0 ? "all" : "\(currentDays)d"
    }
}

private struct DashboardFrame {
    let data: BattLensReportData
    let liveSample: BatterySample?
    let loadedAt: Date

    var displaySample: BatterySample? {
        liveSample ?? data.latestSample
    }
}

private enum DashboardView: String, CaseIterable {
    case dashboard = "Dashboard"
    case history = "History"
    case sessions = "Sessions"
    case agent = "Agent"
    case raw = "Raw"

    var next: DashboardView {
        let views = Self.allCases
        let index = views.firstIndex(of: self) ?? 0
        return views[(index + 1) % views.count]
    }

    var previous: DashboardView {
        let views = Self.allCases
        let index = views.firstIndex(of: self) ?? 0
        return views[(index + views.count - 1) % views.count]
    }
}

private enum DashboardSessionItem {
    case discharge(ChargeSession)
    case charge(ChargingSession)

    var start: Date {
        switch self {
        case .discharge(let session):
            return session.start
        case .charge(let session):
            return session.start
        }
    }
}

private struct DashboardRenderer {
    let frame: DashboardFrame
    let selectedView: DashboardView
    let selectedSessionIndex: Int
    let expandedSession: Bool
    let days: Int
    let sessionLimit: Int
    let refreshInterval: TimeInterval
    let statusMessage: String
    let useColor: Bool
    let size: TerminalSize

    func render() -> String {
        let width = max(50, Int(size.columns) - 1)
        let height = max(18, Int(size.rows))
        let bodyHeight = max(1, height - 5)
        var lines: [String] = []

        lines.append(header(width: width))
        lines.append(tabs(width: width))
        lines.append(separator(width: width))
        lines.append(contentsOf: body(width: width).prefix(bodyHeight))

        while lines.count < height - 1 {
            lines.append("")
        }

        lines.append(footer(width: width))

        return "\u{001B}[H\u{001B}[2J" + lines.prefix(height).map { fitANSI($0, to: width) }.joined(separator: "\r\n")
    }

    private func body(width: Int) -> [String] {
        switch selectedView {
        case .dashboard:
            return renderDashboard(width: width)
        case .history:
            return renderHistory(width: width)
        case .sessions:
            return renderSessions(width: width)
        case .agent:
            return renderAgent(width: width)
        case .raw:
            return renderRaw(width: width)
        }
    }

    private func header(width: Int) -> String {
        let title = styled("BattLens", .accent, bold: true)
        let sampleText: String

        if let sample = frame.displaySample {
            sampleText = "\(String(format: "%.1f%%", sample.level)) \(sample.powerFlowState.statusText)"
        } else {
            sampleText = "no samples"
        }

        let right = "live \(Formatters.timestamp.string(from: frame.loadedAt))"
        let middle = "  \(sampleText)  refresh \(Int(refreshInterval))s"
        return fitANSI(title + styled(middle, .muted), to: max(0, width - visibleLength(right) - 1)) + styled(right, .muted)
    }

    private func tabs(width: Int) -> String {
        let rendered = DashboardView.allCases.map { view in
            if view == selectedView {
                return styled(" \(view.rawValue) ", .plain, bold: true)
            }

            return styled(" \(view.rawValue) ", .muted)
        }.joined(separator: " ")

        return fitANSI(rendered, to: width)
    }

    private func separator(width: Int) -> String {
        styled(String(repeating: "─", count: width), .muted)
    }

    private func renderDashboard(width: Int) -> [String] {
        var lines: [String] = []
        let sample = frame.displaySample
        let data = frame.data
        let availableBodyRows = max(10, Int(size.rows) - 7)
        let showSessions = availableBodyRows >= 24
        let chartWidth = width
        let summaryWidth = width
        let chartHeight = showSessions ? 7 : 5
        let todayAwake = formatDuration(data.awakeDuration(on: Calendar.current.startOfDay(for: data.now)))
        let fullChargeEstimate = data.fullChargeAwakeEstimate().map(formatDuration) ?? "n/a"
        let summaryContent = currentStatusLines(sample: sample) + ["", "Awake today  \(todayAwake)", "Full charge  \(fullChargeEstimate)"]

        let chart = panel(
            title: "Battery \(rangeLabel)",
            width: chartWidth,
            content: batteryChart(width: chartWidth - 4, height: chartHeight)
        )

        let summary = panel(
            title: "Now",
            width: summaryWidth,
            content: summaryContent
        )

        lines.append(contentsOf: chart)
        lines.append("")
        lines.append(contentsOf: summary)

        if showSessions {
            lines.append("")
            lines.append(contentsOf: panel(title: "Recent Sessions", width: width, content: compactSessionLines(limit: min(sessionLimit, 5), width: width - 4)))
        }
        return lines
    }

    private func renderHistory(width: Int) -> [String] {
        let availableRows = max(10, Int(size.rows) - 5)
        let requestedAwakeRows = days == 0 ? 7 : min(days, 7)
        let awakeRows = max(2, min(requestedAwakeRows, availableRows / 2))
        let chartHeight = max(3, min(5, availableRows - awakeRows - 5))
        var lines = panel(
            title: "Battery Trend \(rangeLabel)",
            width: width,
            content: batteryChart(width: width - 4, height: chartHeight)
        )

        lines.append("")
        lines.append(contentsOf: panel(title: "Awake Time", width: width, content: awakeBars(width: width - 4, limit: awakeRows)))
        return lines
    }

    private func renderSessions(width: Int) -> [String] {
        let items = allSessionItems()
        guard !items.isEmpty else {
            return panel(title: "Sessions", width: width, content: ["No charge or discharge sessions yet."])
        }

        var content: [String] = []
        content.append(fitPlain("Type        Start         Awake    Change  Estimate", to: width - 4))
        for (index, item) in items.prefix(max(sessionLimit, selectedSessionIndex + 1)).enumerated() {
            let selected = index == selectedSessionIndex
            let line = sessionLine(item, width: width - 6)
            content.append((selected ? styled("› ", .accent, bold: true) : "  ") + (selected ? styled(line, .plain, bold: true) : line))
        }

        if expandedSession, items.indices.contains(selectedSessionIndex) {
            content.append("")
            content.append(contentsOf: detailLines(for: items[selectedSessionIndex], width: width - 4))
        }

        return panel(title: "Sessions", width: width, content: content)
    }

    private func renderAgent(width: Int) -> [String] {
        var content: [String] = []

        if let state = frame.data.state {
            let running = processIsRunning(state.trackerPID)
            content.append("Tracker      \(running ? styled("running", .good, bold: true) : styled("stale", .warning, bold: true))")
            content.append("PID          \(state.trackerPID)")
            content.append("Interval     \(Int(state.sampleInterval))s")
            if let lastSampleAt = state.lastSampleAt {
                content.append("Last sample  \(Formatters.timestamp.string(from: lastSampleAt))")
            }
            if let activeAwakeStart = state.activeAwakeStart {
                content.append("Awake since  \(Formatters.timestamp.string(from: activeAwakeStart))")
            }
        } else {
            content.append("Tracker      \(styled("not running", .muted))")
        }

        content.append("")
        content.append("Data dir     \(fitPlain(storePath(), to: max(10, width - 17)))")
        content.append("Samples      \(frame.data.samples.count)")
        content.append("Awake spans  \(frame.data.awakeSpans.count)")
        content.append("")
        content.append("i install launch agent   u uninstall launch agent   s snapshot")

        return panel(title: "Agent", width: width, content: content)
    }

    private func renderRaw(width: Int) -> [String] {
        var content: [String] = []
        content.append("Samples file  battery-samples.ndjson")
        content.append("Awake file    awake-spans.ndjson")
        content.append("State file    tracker-state.json")
        content.append("")
        content.append("Recent samples")

        for sample in frame.data.samples.suffix(8).reversed() {
            let line = "\(Formatters.timestamp.string(from: sample.timestamp))  \(String(format: "%5.1f%%", sample.level))  \(sample.powerFlowState.statusText)"
            content.append(fitPlain(line, to: width - 4))
        }

        if frame.data.samples.isEmpty {
            content.append("No samples recorded yet.")
        }

        return panel(title: "Raw Data", width: width, content: content)
    }

    private func currentStatusLines(sample: BatterySample?) -> [String] {
        guard let sample else {
            return ["No samples recorded yet.", "Press s to record one now."]
        }

        let level = styled(String(format: "%.1f%%", sample.level), levelColor(for: sample.level), bold: true)
        let timing: String

        switch sample.powerFlowState {
        case .discharging:
            timing = "remaining \(sample.displayedTimeRemainingMinutes.map(formatDuration(minutes:)) ?? "n/a")"
        case .charging:
            timing = "to full \(sample.displayedTimeRemainingMinutes.map(formatDuration(minutes:)) ?? "n/a")"
        case .pluggedInIdle:
            timing = "not charging"
        case .unknown:
            timing = "state unavailable"
        }

        return [
            "Level        \(level)",
            "Power        \(sample.powerSource)",
            "State        \(sample.powerFlowState.statusText)",
            "Time         \(timing)"
        ]
    }

    private func todayLines(data: BattLensReportData) -> [String] {
        let todayStart = Calendar.current.startOfDay(for: data.now)
        let awake = data.awakeDuration(on: todayStart)
        let drain = data.averageDischargeRatePercentPerHour().map { String(format: "%.1f%%/hr", $0) } ?? "n/a"
        let estimate = data.fullChargeAwakeEstimate().map(formatDuration) ?? "n/a"
        let chargePace = data.averageChargingRatePercentPerHour().map { String(format: "%.1f%%/hr", $0) } ?? "n/a"

        return [
            "Awake today  \(formatDuration(awake))",
            "Avg drain    \(drain)",
            "Full charge  \(estimate)",
            "Charge pace  \(chargePace)"
        ]
    }

    private func compactSessionLines(limit: Int, width: Int) -> [String] {
        let items = allSessionItems()
        guard !items.isEmpty else {
            return ["No sessions yet. Keep the tracker running through a charge or discharge cycle."]
        }

        return items.prefix(limit).map { item in
            sessionLine(item, width: width)
        }
    }

    private func allSessionItems() -> [DashboardSessionItem] {
        let discharges = frame.data.dischargeSessions.map(DashboardSessionItem.discharge)
        let charges = frame.data.chargingSessions.map(DashboardSessionItem.charge)
        return (discharges + charges).sorted { $0.start > $1.start }
    }

    private func sessionLine(_ item: DashboardSessionItem, width: Int) -> String {
        let line: String
        switch item {
        case .discharge(let session):
            let estimate = session.estimatedFullChargeAwakeRuntime.map(formatDuration) ?? "n/a"
            line = "Discharge   \(Formatters.shortDateTime.string(from: session.start))  \(formatDuration(session.awakeDuration).padding(toLength: 7, withPad: " ", startingAt: 0))  -\(Int(session.consumedPercent.rounded()))%    \(estimate)\(session.isOngoing ? " live" : "")"
        case .charge(let session):
            let estimate = session.estimatedTimeToFull.map(formatDuration) ?? (session.endLevel >= 99.5 ? "full" : "n/a")
            line = "Charging    \(Formatters.shortDateTime.string(from: session.start))  \(formatDuration(session.awakeDuration).padding(toLength: 7, withPad: " ", startingAt: 0))  +\(Int(session.gainedPercent.rounded()))%    \(estimate)\(session.isOngoing ? " live" : "")"
        }

        return fitPlain(line, to: width)
    }

    private func detailLines(for item: DashboardSessionItem, width: Int) -> [String] {
        switch item {
        case .discharge(let session):
            return [
                fitPlain("Start level \(String(format: "%.1f%%", session.startLevel))  End level \(String(format: "%.1f%%", session.endLevel))", to: width),
                fitPlain("Elapsed \(formatDuration(session.elapsedDuration))  Awake \(formatDuration(session.awakeDuration))  Drop \(String(format: "%.1f%%", session.consumedPercent))", to: width),
                fitPlain("Projected full-charge awake runtime \(session.estimatedFullChargeAwakeRuntime.map(formatDuration) ?? "n/a")", to: width)
            ]
        case .charge(let session):
            return [
                fitPlain("Start level \(String(format: "%.1f%%", session.startLevel))  End level \(String(format: "%.1f%%", session.endLevel))", to: width),
                fitPlain("Elapsed \(formatDuration(session.elapsedDuration))  Awake \(formatDuration(session.awakeDuration))  Gain \(String(format: "%.1f%%", session.gainedPercent))", to: width),
                fitPlain("Estimated time to full \(session.estimatedTimeToFull.map(formatDuration) ?? "n/a")", to: width)
            ]
        }
    }

    private func awakeBars(width: Int, limit: Int? = nil) -> [String] {
        let valueDays = days == 0 ? min(max(frame.data.samples.count, 1), 30) : days
        let values = Array(frame.data.awakeDurations(days: valueDays).suffix(limit ?? valueDays))
        guard !values.isEmpty, !frame.data.mergedAwakeSpans.isEmpty else {
            return ["No awake-time spans yet. Start the tracker to capture sleep/wake boundaries."]
        }

        let labelWidth = 7
        let durationWidth = 8
        let barWidth = max(8, width - labelWidth - durationWidth - 4)
        let maxDuration = max(values.map(\.1).max() ?? 0, 1)

        return values.map { dayStart, duration in
            let ratio = duration / maxDuration
            let count = Int((ratio * Double(barWidth)).rounded())
            let filled = styled(String(repeating: "█", count: max(0, count)), .accent)
            let empty = styled(String(repeating: "░", count: max(0, barWidth - count)), .muted)
            let label = Formatters.dayLabel.string(from: dayStart).padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            let value = formatDuration(duration).padding(toLength: durationWidth, withPad: " ", startingAt: 0)
            return "\(label) \(value) \(filled)\(empty)"
        }
    }

    private func batteryChart(width: Int, height: Int) -> [String] {
        let samples = frame.data.samples
        guard !samples.isEmpty else {
            return ["No battery history yet."]
        }

        let end = frame.data.now
        let start: Date
        if days == 0, let first = samples.first?.timestamp {
            start = first
        } else {
            start = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: end) ?? end.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        }

        let samplesBeforeEnd = samples.filter { $0.timestamp <= end }
        guard samplesBeforeEnd.contains(where: { $0.timestamp >= start }) else {
            return ["No samples in this range."]
        }

        var windowedSamples = samplesBeforeEnd.filter { $0.timestamp >= start }
        if let priorSample = samplesBeforeEnd.last(where: { $0.timestamp < start }) {
            windowedSamples.insert(priorSample, at: 0)
        }

        let plotWidth = max(12, width - 7)
        let levels = bucketedBatteryLevels(samples: windowedSamples, start: start, end: end, buckets: plotWidth)
        guard !levels.isEmpty else {
            return ["No samples in this range."]
        }

        let minLevelValue = levels.min() ?? 0
        let maxLevelValue = levels.max() ?? 0
        let visibleRange = max(maxLevelValue - minLevelValue, 8)
        let padding = max(3, visibleRange * 0.18)
        let chartMin = max(0, floor((minLevelValue - padding) / 5) * 5)
        let chartMax = min(100, ceil((maxLevelValue + padding) / 5) * 5)
        let scale = max(chartMax - chartMin, 1)
        let plotRows = levels.map {
            Int((((chartMax - max(chartMin, min($0, chartMax))) / scale) * Double(height - 1)).rounded())
        }

        var lines: [String] = []
        lines.append(styled("Range \(Int(minLevelValue.rounded()))%-\(Int(maxLevelValue.rounded()))%  Avg \(Int((levels.reduce(0, +) / Double(levels.count)).rounded()))%  Samples \(max(windowedSamples.count - 1, 1))", .muted))

        for row in 0..<height {
            let value = Int((chartMax - (Double(row) / Double(max(height - 1, 1)) * scale)).rounded())
            var line = String(format: "%4d%% │", value)
            for (index, level) in levels.enumerated() {
                let pointRow = plotRows[index]
                if row == pointRow {
                    line += styled(index == levels.count - 1 ? "◆" : "●", levelColor(for: level), bold: true)
                } else if row > pointRow {
                    line += styled(row - pointRow == 1 ? "▓" : "░", row - pointRow == 1 ? levelColor(for: level) : .muted)
                } else {
                    line += " "
                }
            }
            lines.append(line)
        }

        lines.append(styled("      └" + String(repeating: "─", count: plotWidth), .muted))
        return lines
    }

    private func panel(title: String, width: Int, content: [String]) -> [String] {
        let innerWidth = max(1, width - 4)
        let top = styled("┌ \(fitPlain(title, to: innerWidth)) ┐", .muted)
        let bottom = styled("└" + String(repeating: "─", count: width - 2) + "┘", .muted)
        let body = content.map { line in
            styled("│ ", .muted) + fitANSI(line, to: innerWidth) + styled(" │", .muted)
        }
        return [top] + body + [bottom]
    }

    private func footer(width: Int) -> String {
        let keys: String
        switch selectedView {
        case .dashboard, .history:
            keys = "q quit  r refresh  s snapshot  t range  </> views"
        case .sessions:
            keys = "up/down select  enter details  q quit  r refresh  </> views"
        case .agent:
            keys = "i install  u uninstall  s snapshot  q quit  </> views"
        case .raw:
            keys = "q quit  r refresh  s snapshot  </> views"
        }

        if width < visibleLength(keys) + 14 {
            return styled(fitPlain(keys, to: width), .accent)
        }

        let left = fitPlain(statusMessage, to: max(10, width - visibleLength(keys) - 2))
        return fitANSI(styled(left, .muted) + "  " + styled(keys, .accent), to: width)
    }

    private var rangeLabel: String {
        days == 0 ? "all" : "\(days)d"
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

    private func styled(_ text: String, _ color: ANSIColor, bold: Bool = false) -> String {
        guard useColor else {
            return text
        }

        return color.wrap(text, bold: bold)
    }

    private func storePath() -> String {
        (try? BattLensStore.defaultRootURL().path) ?? "unknown"
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
}

private enum DashboardKey: Equatable {
    case character(Character)
    case enter
    case escape
    case up
    case down
    case left
    case right
    case controlC
}

private final class RawTerminal {
    private var originalTermios = termios()
    private var originalFlags: Int32 = 0
    private var didEnter = false

    func enter() throws {
        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        originalFlags = fcntl(STDIN_FILENO, F_GETFL)
        var raw = originalTermios
        cfmakeraw(&raw)
        raw.c_oflag = originalTermios.c_oflag

        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags | O_NONBLOCK)
        didEnter = true
        writeString("\u{001B}[?1049h\u{001B}[?25l\u{001B}[H\u{001B}[2J")
    }

    func leave() {
        guard didEnter else {
            return
        }

        _ = tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags)
        writeString("\u{001B}[?25h\u{001B}[?1049l")
        didEnter = false
    }

    func readKey(timeout: TimeInterval) -> DashboardKey? {
        guard let byte = readByte(timeout: timeout) else {
            return nil
        }

        switch byte {
        case 3:
            return .controlC
        case 10, 13:
            return .enter
        case 27:
            return readEscapeSequence()
        default:
            guard let scalar = UnicodeScalar(Int(byte)) else {
                return nil
            }
            return .character(Character(scalar))
        }
    }

    private func readEscapeSequence() -> DashboardKey {
        guard let first = readByte(timeout: 0.02) else {
            return .escape
        }

        var bytes = [first]
        while let byte = readByte(timeout: 0.001), bytes.count < 3 {
            bytes.append(byte)
        }

        if bytes == [91, 65] {
            return .up
        }
        if bytes == [91, 66] {
            return .down
        }
        if bytes == [91, 67] {
            return .right
        }
        if bytes == [91, 68] {
            return .left
        }

        return .escape
    }

    private func readByte(timeout: TimeInterval) -> UInt8? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            var byte: UInt8 = 0
            let result = Darwin.read(STDIN_FILENO, &byte, 1)
            if result == 1 {
                return byte
            }

            if result < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                return nil
            }

            usleep(5_000)
        } while Date() < deadline

        return nil
    }

    private func writeString(_ string: String) {
        writeTerminalString(string)
    }
}

private struct TerminalSize {
    let columns: UInt16
    let rows: UInt16

    static func current() -> TerminalSize {
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(UInt16.init),
           let rows = ProcessInfo.processInfo.environment["LINES"].flatMap(UInt16.init),
           columns > 0,
           rows > 0 {
            return TerminalSize(columns: columns, rows: rows)
        }

        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0, windowSize.ws_col > 0, windowSize.ws_row > 0 {
            return TerminalSize(columns: windowSize.ws_col, rows: windowSize.ws_row)
        }

        return TerminalSize(columns: 100, rows: 32)
    }
}

private func visibleLength(_ string: String) -> Int {
    var count = 0
    var iterator = string.unicodeScalars.makeIterator()

    while let scalar = iterator.next() {
        if scalar == "\u{001B}" {
            consumeANSISequence(from: &iterator)
            continue
        }

        count += 1
    }

    return count
}

private func padANSI(_ string: String, to width: Int) -> String {
    string + String(repeating: " ", count: max(0, width - visibleLength(string)))
}

private func fitANSI(_ string: String, to width: Int) -> String {
    if visibleLength(string) <= width {
        return padANSI(string, to: width)
    }

    return fitPlain(strippingANSI(from: string), to: width)
}

private func fitPlain(_ string: String, to width: Int) -> String {
    guard width > 0 else {
        return ""
    }

    if string.count <= width {
        return string.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    if width <= 3 {
        return String(string.prefix(width))
    }

    return String(string.prefix(width - 3)) + "..."
}

private func strippingANSI(from string: String) -> String {
    var result = ""
    var iterator = string.unicodeScalars.makeIterator()

    while let scalar = iterator.next() {
        if scalar == "\u{001B}" {
            consumeANSISequence(from: &iterator)
            continue
        }

        result.unicodeScalars.append(scalar)
    }

    return result
}

private func consumeANSISequence(from iterator: inout String.UnicodeScalarView.Iterator) {
    guard let first = iterator.next() else {
        return
    }

    if first == "[" {
        while let next = iterator.next() {
            if (64...126).contains(Int(next.value)) {
                break
            }
        }
        return
    }

    if first == "]" {
        while let next = iterator.next() {
            if next == "\u{0007}" {
                break
            }

            if next == "\u{001B}" {
                var lookahead = iterator
                if lookahead.next() == "\\" {
                    iterator = lookahead
                    break
                }
            }
        }
    }
}

private func writeTerminalString(_ string: String) {
    let data = Data(string.utf8)
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return
        }

        var bytesWritten = 0
        while bytesWritten < rawBuffer.count {
            let result = Darwin.write(
                STDOUT_FILENO,
                baseAddress.advanced(by: bytesWritten),
                rawBuffer.count - bytesWritten
            )

            if result > 0 {
                bytesWritten += result
                continue
            }

            if result < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(5_000)
                continue
            }

            return
        }
    }
}
