import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

private let ioMessageCanSystemSleep: natural_t = 0xE0000270
private let ioMessageSystemWillSleep: natural_t = 0xE0000280
private let ioMessageSystemHasPoweredOn: natural_t = 0xE0000300

final class SystemPowerObserver {
    private let onSleep: () -> Void
    private let onWake: () -> Void
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() throws {
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        rootPort = IORegisterForSystemPower(
            selfPointer,
            &notifyPort,
            { refCon, _, messageType, messageArgument in
                guard let refCon else {
                    return
                }

                let observer = Unmanaged<SystemPowerObserver>.fromOpaque(refCon).takeUnretainedValue()
                observer.handle(messageType: messageType, messageArgument: messageArgument)
            },
            &notifier
        )

        guard rootPort != 0 else {
            throw BattLensError.message("Failed to register for macOS power notifications.")
        }

        guard let notifyPort else {
            throw BattLensError.message("Failed to create macOS power notification port.")
        }

        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        }

        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }

        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }

        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }

    private func handle(messageType: natural_t, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCanSystemSleep:
            allowPowerChange(messageArgument)
        case ioMessageSystemWillSleep:
            onSleep()
            allowPowerChange(messageArgument)
        case ioMessageSystemHasPoweredOn:
            onWake()
        default:
            break
        }
    }

    private func allowPowerChange(_ messageArgument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: messageArgument)
        IOAllowPowerChange(rootPort, Int(token))
    }
}

final class TrackerService: @unchecked Sendable {
    private let store: BattLensStore
    private let interval: TimeInterval
    private let duration: TimeInterval?
    private let verbose: Bool
    private var powerObserver: SystemPowerObserver?
    private var sampleTimer: Timer?
    private var durationTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var awakeStartedAt: Date?
    private var isStopping = false

    init(store: BattLensStore, interval: TimeInterval, duration: TimeInterval?, verbose: Bool) {
        self.store = store
        self.interval = interval
        self.duration = duration
        self.verbose = verbose
    }

    func run() throws {
        let now = Date()
        awakeStartedAt = now
        try sample(at: now)
        try persistState(at: now)

        powerObserver = SystemPowerObserver(
            onSleep: { [weak self] in self?.handleSleep() },
            onWake: { [weak self] in self?.handleWake() }
        )
        try powerObserver?.start()

        installSampleTimer()
        installDurationTimer()
        installSignalHandlers()

        if verbose {
            print("Tracking to \(store.rootURL.path)")
        }

        RunLoop.current.run()
    }

    private func handleSleep() {
        let now = Date()

        do {
            try sample(at: now)
            try closeAwakeSpan(at: now)
            try persistState(at: now)
            if verbose {
                print("[\(Formatters.timestamp.string(from: now))] system sleeping")
            }
        } catch {
            fputs("battlens: \(error.localizedDescription)\n", stderr)
        }
    }

    private func handleWake() {
        let now = Date()

        do {
            awakeStartedAt = now
            try sample(at: now)
            try persistState(at: now)
            if verbose {
                print("[\(Formatters.timestamp.string(from: now))] system woke")
            }
        } catch {
            fputs("battlens: \(error.localizedDescription)\n", stderr)
        }
    }

    private func installSampleTimer() {
        sampleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            do {
                let now = Date()
                try self.sample(at: now)
                try self.persistState(at: now)
            } catch {
                fputs("battlens: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func installDurationTimer() {
        guard let duration else {
            return
        }

        durationTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.shutdown(reason: "duration reached")
        }
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for signalValue in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: DispatchQueue.main)
            source.setEventHandler { [weak self] in
                self?.shutdown(reason: "signal")
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown(reason: String) {
        guard !isStopping else {
            return
        }

        isStopping = true
        let now = Date()

        do {
            try sample(at: now)
            try closeAwakeSpan(at: now)
            try store.clearState()
        } catch {
            fputs("battlens: \(error.localizedDescription)\n", stderr)
        }

        if verbose {
            print("[\(Formatters.timestamp.string(from: now))] stopping (\(reason))")
        }

        sampleTimer?.invalidate()
        sampleTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        powerObserver?.stop()
        powerObserver = nil
        CFRunLoopStop(CFRunLoopGetMain())
        exit(EXIT_SUCCESS)
    }

    private func sample(at date: Date) throws {
        let snapshot = try BatteryReader.readSnapshot(now: date)
        try store.appendSample(snapshot)
    }

    private func closeAwakeSpan(at end: Date) throws {
        guard let awakeStartedAt else {
            return
        }

        try store.appendAwakeSpan(AwakeSpan(start: awakeStartedAt, end: end))
        self.awakeStartedAt = nil
    }

    private func persistState(at date: Date) throws {
        let state = TrackerState(
            activeAwakeStart: awakeStartedAt,
            lastSampleAt: date,
            sampleInterval: interval,
            trackerPID: getpid(),
            updatedAt: date
        )
        try store.saveState(state)
    }
}
