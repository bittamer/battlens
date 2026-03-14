import Foundation

enum LaunchAgentManager {
    static let label = "com.battlens.agent"

    static func install(store: BattLensStore, executablePath: String, interval: Int) throws {
        let plistURL = try plistURL()
        let plist = try launchAgentPlist(store: store, executablePath: executablePath, interval: interval)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try data.write(to: plistURL, options: .atomic)

        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())", plistURL.path]
        try? bootout.run()
        bootout.waitUntilExit()

        try bootstrap.run()
        bootstrap.waitUntilExit()

        guard bootstrap.terminationStatus == 0 else {
            throw BattLensError.message("launchctl bootstrap failed with status \(bootstrap.terminationStatus).")
        }
    }

    static func uninstall() throws {
        let plistURL = try plistURL()
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return
        }

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())", plistURL.path]
        try? bootout.run()
        bootout.waitUntilExit()

        try FileManager.default.removeItem(at: plistURL)
    }

    static func plistURL() throws -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private static func launchAgentPlist(store: BattLensStore, executablePath: String, interval: Int) throws -> [String: Any] {
        var environment: [String: String] = [:]
        if let override = ProcessInfo.processInfo.environment["BATTLENS_DATA_DIR"], !override.isEmpty {
            environment["BATTLENS_DATA_DIR"] = override
        }

        return [
            "Label": label,
            "ProgramArguments": [
                executablePath,
                "track",
                "--interval",
                String(interval)
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "WorkingDirectory": store.rootURL.path,
            "StandardOutPath": store.logsURL.appendingPathComponent("agent.out.log").path,
            "StandardErrorPath": store.logsURL.appendingPathComponent("agent.err.log").path,
            "EnvironmentVariables": environment
        ]
    }
}
