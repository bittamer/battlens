import Darwin
import Foundation

struct ParsedArguments {
    let command: String?
    let options: [String: String]
    let flags: Set<String>

    init(arguments: [String]) throws {
        command = arguments.first

        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw BattLensError.message("Unexpected argument: \(argument)")
            }

            let name = String(argument.dropFirst(2))
            let nextIndex = index + 1
            if nextIndex < arguments.count, !arguments[nextIndex].hasPrefix("--") {
                let value = arguments[nextIndex]
                options[name] = value
                index += 2
            } else {
                flags.insert(name)
                index += 1
            }
        }

        self.options = options
        self.flags = flags
    }

    func int(_ key: String, default defaultValue: Int) throws -> Int {
        guard let rawValue = options[key] else {
            return defaultValue
        }

        guard let value = Int(rawValue) else {
            throw BattLensError.message("Option --\(key) expects an integer.")
        }

        return value
    }

    func string(_ key: String) -> String? {
        options[key]
    }

    func hasFlag(_ key: String) -> Bool {
        flags.contains(key)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let parsed = try ParsedArguments(arguments: arguments)
    let store = try BattLensStore()

    switch parsed.command {
    case nil, "help", "--help":
        printHelp()

    case "where":
        print(store.rootURL.path)

    case "snapshot":
        let snapshot = try BatteryReader.readSnapshot()
        try store.appendSample(snapshot)
        print("Logged \(String(format: "%.1f%%", snapshot.level)) at \(Formatters.timestamp.string(from: snapshot.timestamp)) (\(snapshot.powerSource)).")

    case "track":
        let interval = try parsed.int("interval", default: 300)
        guard interval > 0 else {
            throw BattLensError.message("Option --interval must be greater than 0.")
        }

        let duration = parsed.string("duration").flatMap(TimeInterval.init)
        if let duration, duration <= 0 {
            throw BattLensError.message("Option --duration must be greater than 0.")
        }

        let verbose = parsed.hasFlag("verbose")
        let service = TrackerService(store: store, interval: TimeInterval(interval), duration: duration, verbose: verbose)
        try service.run()

    case "report":
        let days = try parsed.int("days", default: 7)
        let sessionLimit = try parsed.int("sessions", default: 6)
        guard days > 0 else {
            throw BattLensError.message("Option --days must be greater than 0.")
        }

        guard sessionLimit > 0 else {
            throw BattLensError.message("Option --sessions must be greater than 0.")
        }

        let plain = parsed.hasFlag("plain") || ProcessInfo.processInfo.environment["NO_COLOR"] != nil || isatty(STDOUT_FILENO) == 0
        let renderer = ReportRenderer(
            samples: try store.loadSamples(),
            awakeSpans: try store.loadAwakeSpans(),
            state: try store.loadState(),
            useColor: !plain,
            now: Date()
        )
        print(renderer.render(days: days, sessionLimit: sessionLimit))

    case "install-agent":
        let interval = try parsed.int("interval", default: 300)
        guard interval > 0 else {
            throw BattLensError.message("Option --interval must be greater than 0.")
        }

        let executablePath = parsed.string("executable") ?? URL(fileURLWithPath: CommandLine.arguments[0]).path
        try LaunchAgentManager.install(store: store, executablePath: executablePath, interval: interval)
        print("Installed launch agent at \(try LaunchAgentManager.plistURL().path)")

    case "uninstall-agent":
        try LaunchAgentManager.uninstall()
        print("Removed BattLens launch agent.")

    default:
        throw BattLensError.message("Unknown command: \(parsed.command ?? "")")
    }
} catch {
    fputs("battlens: \(error.localizedDescription)\n", stderr)
    printHelp(to: stderr)
    exit(1)
}

func printHelp(to stream: UnsafeMutablePointer<FILE> = stdout) {
    let text = """
    battlens

    A macOS CLI that logs battery level and laptop awake time over time.

    Commands:
      help                      Show this help text
      where                     Print the data directory
      snapshot                  Record a single battery sample now
      track                     Run the tracker in the foreground
      report                    Render charts and single-charge estimates
      install-agent             Install a per-user launchd agent
      uninstall-agent           Remove the launchd agent

    Key options:
      battlens track --interval 300 --verbose
      battlens track --interval 60 --duration 180
      battlens report --days 7 --sessions 8
      battlens install-agent --interval 300 --executable /path/to/battlens

    Environment:
      BATTLENS_DATA_DIR         Override the default data directory
    """

    fputs(text + "\n", stream)
}
