import AppKit
import CoreAudio
import Foundation
import os

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// What the engine is doing, for the panel.
enum EngineState: Equatable {
    /// The switch is off. Apps play straight to the device, untouched.
    case off
    /// The switch is on and macOS is showing the permission prompt.
    case waitingForAccess
    /// The switch is on, but System Audio Recording is off for this app.
    case accessDenied
    case starting
    case running
    /// The switch is on, but the current output cannot carry the EQ. Audio
    /// plays as normal.
    case failed(deviceName: String)
}

let engineLog = Logger(subsystem: "com.goranimperator.ImperatorEQ", category: "engine")

extension EQSettings {
    init(bands: [EQBand], volume: Float, balance: Float) {
        self.init(gains: bands.map(\.gain), volume: volume, balance: balance)
    }
}

extension EQStore {
    var eqSettings: EQSettings { EQSettings(bands: bands, volume: volume, balance: balance) }
}

/// The main-thread face of the audio engine: published state for the panel,
/// the output device list, the permission state, and the system events that
/// decide when the engine has to be rebuilt.
///
/// It decides what should happen and never talks to coreaudiod itself beyond
/// plain property reads. Building and tearing down the tap happens in
/// `EngineController`, on its own queue.
@MainActor
final class AudioEngine: ObservableObject {
    /// Prefix of this app's private aggregate devices. The HAL shows a private
    /// aggregate to the process that made it, so the device list filters it.
    nonisolated static let aggregateUIDPrefix = "com.goranimperator.ImperatorEQ.aggregate."

    /// Frames per IO cycle, which sets most of the delay the EQ adds between an
    /// app and the speaker. Measured with `--engine-check` on the built-in
    /// speakers at 44.1 kHz, as output presentation time minus tap capture
    /// time: 256 frames adds 15.6 ms, 512 adds 27.2 ms. Both ran without a
    /// single late cycle and gave identical EQ results, so the lower one wins.
    /// The HAL clamps this to what the output allows, Bluetooth included.
    nonisolated static let bufferFrames: UInt32 = 256

    @Published private(set) var state: EngineState = .off
    @Published private(set) var availableOutputDevices: [OutputDevice] = []
    /// The system's default output, which is where the EQ plays.
    @Published private(set) var activeOutputUID: String?

    private let controller = EngineController()
    private weak var store: EQStore?
    private var access = SystemAudioAccess.Status.unknown
    private var askedForAccess = false
    private var lastOutcome = EngineOutcome.stopped
    private var accessTimer: Timer?
    private var deviceRefreshScheduled = false
    /// The system listeners live as long as the app.
    private var systemListeners: [PropertyListener] = []

    func setup(store: EQStore) {
        self.store = store
        controller.onOutcome = { [weak self] outcome in
            Task { @MainActor in self?.handle(outcome) }
        }
        CoreAudioDevices.allowIdleSleepDuringIO()
        installSystemListeners()
        refreshOutputDevices()
        _ = refreshAccess()
        reconcile()
    }

    /// Brings the engine in line with the switch, the permission and the
    /// current default output. Safe to call as often as anything changes:
    /// requests are coalesced on the engine queue, and the last one wins.
    func reconcile(forceRebuild: Bool = false) {
        guard let store else { return }
        let permitted = access == .authorized || access == .unknown
        if store.isEnabled && access == .notDetermined { requestAccessOnce() }
        controller.submit(EngineRequest(run: store.isEnabled && permitted, forceRebuild: forceRebuild),
                          settings: store.eqSettings)
        updateState()
        updateAccessTimer()
    }

    /// EQ, volume or balance changed. Applied to the running pipeline in place.
    func settingsChanged(_ settings: EQSettings) {
        controller.update(settings)
    }

    /// Makes `uid` the system's default output. The engine follows the default,
    /// so this is the same choice the Sound menu makes.
    func selectOutputDevice(uid: String) {
        guard let device = availableOutputDevices.first(where: { $0.uid == uid }) else { return }
        engineLog.notice("output selected: \(device.name, privacy: .public)")
        controller.setDefaultOutput(device.id)
    }

    /// The panel just opened: a switch flipped in System Settings should show
    /// without waiting for the timer.
    func panelOpened() {
        if refreshAccess() { reconcile() }
        refreshOutputDevices()
    }

    func openAccessSettings() {
        NSWorkspace.shared.open(SystemAudioAccess.settingsURL)
    }

    /// Called at quit. Bounded, because coreaudiod can be slow to answer and
    /// the process exiting removes the private tap and aggregate anyway.
    func shutdown() {
        controller.shutdown(timeout: 0.5)
    }

    // MARK: - State

    private func handle(_ outcome: EngineOutcome) {
        lastOutcome = outcome
        updateState()
    }

    /// Derived, not stored step by step: the switch and the permission decide
    /// first, and only then does the last result from the engine queue count.
    /// A late result from a request that has since been overtaken can then
    /// never show a state the switch no longer asks for.
    private func updateState() {
        guard let store, store.isEnabled else {
            state = .off
            return
        }
        switch access {
        case .notDetermined:
            state = .waitingForAccess
            return
        case .denied:
            state = .accessDenied
            return
        case .authorized, .unknown:
            break
        }
        switch lastOutcome {
        case .running: state = .running
        case .failed(let name): state = .failed(deviceName: name)
        case .stopped: state = .starting
        }
    }

    // MARK: - Permission

    /// Returns whether the status changed.
    private func refreshAccess() -> Bool {
        let current = SystemAudioAccess.status()
        guard current != access else { return false }
        engineLog.notice("system audio access: \(String(describing: current), privacy: .public)")
        access = current
        // An answer re-arms the request, so access reset to undecided while the
        // app runs (tccutil, or the app removed from the list) is asked again.
        if current != .notDetermined { askedForAccess = false }
        return true
    }

    /// One prompt per undecided spell. The system shows it once per app anyway,
    /// and a second request while it is up would queue behind it.
    private func requestAccessOnce() {
        guard !askedForAccess else { return }
        askedForAccess = true
        engineLog.notice("asking for system audio access")
        SystemAudioAccess.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                engineLog.notice("system audio access request answered: \(granted, privacy: .public)")
                _ = self.refreshAccess()
                self.reconcile()
            }
        }
    }

    /// Picks up a switch flipped in System Settings, and a revocation while
    /// running, which would otherwise leave the apps muted behind a tap that
    /// reads silence. Every 2 seconds while the switch is on, running or not:
    /// the check is one small call to tccd, and a revocation should not leave
    /// the Mac quiet for long. The timer does not exist while the switch is off.
    private func updateAccessTimer() {
        let wanted = store?.isEnabled == true && access != .unknown
        if wanted, accessTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.refreshAccess() else { return }
                    self.reconcile()
                }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            accessTimer = timer
        } else if !wanted, let timer = accessTimer {
            timer.invalidate()
            accessTimer = nil
        }
    }

    // MARK: - System events

    private func installSystemListeners() {
        listen(kAudioHardwarePropertyDefaultOutputDevice) { engine in
            engine.refreshActiveOutput()
            engine.reconcile()
        }
        listen(kAudioHardwarePropertyDevices) { engine in
            engine.scheduleDeviceRefresh()
        }
        // coreaudiod restarted: every object the pipeline held is gone.
        listen(kAudioHardwarePropertyServiceRestarted) { engine in
            engineLog.notice("coreaudiod restarted")
            engine.reconcile(forceRebuild: true)
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Devices come back over the first second or so after wake. One that
            // is not back yet fails the build, and the engine queue retries it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    engineLog.notice("woke from sleep")
                    self?.reconcile(forceRebuild: true)
                }
            }
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor (AudioEngine) -> Void) {
        let listener = PropertyListener(object: CoreAudioDevices.system, addresses: [CoreAudioDevices.address(selector)],
                                        queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        systemListeners.append(listener)
    }

    /// A device plugging in fires several notifications in a row.
    private func scheduleDeviceRefresh() {
        guard !deviceRefreshScheduled else { return }
        deviceRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.deviceRefreshScheduled = false
                self?.refreshOutputDevices()
            }
        }
    }

    private func refreshOutputDevices() {
        var devices: [OutputDevice] = []
        for id in CoreAudioDevices.allDevices {
            guard let uid = CoreAudioDevices.uid(id), !uid.hasPrefix(Self.aggregateUIDPrefix),
                  !CoreAudioDevices.isHidden(id), CoreAudioDevices.canBeDefaultOutput(id),
                  CoreAudioDevices.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 else { continue }
            devices.append(OutputDevice(id: id, uid: uid, name: CoreAudioDevices.name(id) ?? uid))
        }
        if devices != availableOutputDevices {
            availableOutputDevices = devices
            // A device that just arrived, or just finished arriving, may be the
            // one a failed start could not use yet. The list leaves out this
            // app's own aggregates, so a failing build cannot trigger itself.
            if case .failed = lastOutcome { reconcile() }
        }
        refreshActiveOutput()
    }

    private func refreshActiveOutput() {
        let uid = CoreAudioDevices.defaultOutputDevice.flatMap(CoreAudioDevices.uid)
        if uid != activeOutputUID { activeOutputUID = uid }
    }
}

// MARK: - Engine queue

struct EngineRequest: Sendable {
    /// Whether a pipeline should be running.
    var run: Bool
    /// Tear down and build again even when nothing seems to have changed:
    /// after wake or a coreaudiod restart.
    var forceRebuild: Bool
}

enum EngineOutcome: Sendable {
    case stopped
    case running
    /// The reason is in the log, written where the failure happened.
    case failed(deviceName: String)
}

/// Owns the running pipeline. Everything that touches it runs on `queue`,
/// never on the main thread: creating a tap, an aggregate device or an IOProc
/// waits on coreaudiod, and a wait there on the main thread freezes the menu
/// bar item before it is ever drawn.
final class EngineController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.goranimperator.ImperatorEQ.engine", qos: .userInitiated)

    /// Set once, from the main thread, before the first request.
    var onOutcome: (@Sendable (EngineOutcome) -> Void)?

    /// Requests and settings cross from the main thread through this box. A
    /// burst of switch flips while a build is under way collapses into one
    /// pending request, and whatever runs next reads the newest settings.
    private struct Mailbox {
        var pending: EngineRequest?
        var draining = false
        var settings = EQSettings.flat
    }
    private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())

    // Engine-queue state.
    private var pipeline: TapPipeline?
    /// What the last request asked for; a retry runs only while this holds.
    private var wantsRun = false
    private var watchdog: DispatchSourceTimer?
    private var deviceListener: PropertyListener?
    private var lastCallbacks: UInt64 = 0
    private var stalledTicks = 0
    private var healthTicks = 0
    private var retry: DispatchWorkItem?
    private var failedAttempts = 0

    /// Seconds before each retry after a failed start or a stall. A device that
    /// has just appeared, or is coming back from sleep, often refuses the first
    /// build and takes one a moment later. After the last one the engine waits
    /// for the switch, the output or the device list to change.
    private static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    func submit(_ request: EngineRequest, settings: EQSettings) {
        let schedule = mailbox.withLock { box -> Bool in
            // A rebuild asked for after wake must survive being overtaken by a
            // plain request before the queue reads it.
            var merged = request
            merged.forceRebuild = request.forceRebuild || (box.pending?.forceRebuild ?? false)
            box.pending = merged
            box.settings = settings
            guard !box.draining else { return false }
            box.draining = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    func update(_ settings: EQSettings) {
        mailbox.withLock { $0.settings = settings }
        queue.async {
            let latest = self.mailbox.withLock { $0.settings }
            self.pipeline?.apply(latest)
        }
    }

    func setDefaultOutput(_ device: AudioDeviceID) {
        queue.async {
            if !CoreAudioDevices.setDefaultOutputDevice(device) {
                engineLog.error("could not set the default output to device \(device, privacy: .public)")
            }
        }
    }

    func shutdown(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.wantsRun = false
            self.cancelRetry()
            self.tearDown()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            engineLog.error("engine did not stop within \(timeout, privacy: .public)s; exiting anyway")
        }
    }

    private func drain() {
        while true {
            let request = mailbox.withLock { box -> EngineRequest? in
                let request = box.pending
                box.pending = nil
                if request == nil { box.draining = false }
                return request
            }
            guard let request else { return }
            reconcile(request)
        }
    }

    private func reconcile(_ request: EngineRequest) {
        // A request means the switch, the output or the device list changed:
        // news a retry in flight knows nothing about, so it starts a fresh round.
        wantsRun = request.run
        cancelRetry()
        failedAttempts = 0

        guard request.run else {
            tearDown()
            onOutcome?(.stopped)
            return
        }
        if let pipeline, !request.forceRebuild, pipeline.outputDevice == CoreAudioDevices.defaultOutputDevice {
            pipeline.apply(mailbox.withLock { $0.settings })
            onOutcome?(.running)
            return
        }
        build()
    }

    /// Replaces whatever runs with a pipeline on the current default output,
    /// with the newest settings.
    private func build() {
        tearDown()
        do {
            let started = try TapPipeline.start(settings: mailbox.withLock { $0.settings },
                                                bufferFrames: AudioEngine.bufferFrames)
            pipeline = started
            watch(started)
            engineLog.notice("""
                engine running on \(started.outputName, privacy: .public): \
                \(Int(started.sampleRate), privacy: .public) Hz, \(started.channels, privacy: .public) ch, \
                buffer \(started.bufferFrames, privacy: .public)
                """)
            onOutcome?(.running)
        } catch {
            let name = CoreAudioDevices.defaultOutputDevice.flatMap(CoreAudioDevices.name) ?? "this output"
            engineLog.error("engine failed on \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            failed(on: name)
        }
    }

    /// Reports the failure, which leaves the apps playing as normal, and
    /// schedules the next retry while the switch still asks for the EQ.
    private func failed(on deviceName: String) {
        onOutcome?(.failed(deviceName: deviceName))
        guard failedAttempts < Self.retryDelays.count else {
            engineLog.error("no more retries until the switch, the output or the device list changes")
            return
        }
        let delay = Self.retryDelays[failedAttempts]
        failedAttempts += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            guard self.wantsRun, self.pipeline == nil else { return }
            engineLog.notice("retrying the engine, attempt \(self.failedAttempts, privacy: .public)")
            self.build()
        }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func tearDown() {
        guard let pipeline else { return }
        watchdog?.cancel()
        watchdog = nil
        deviceListener?.cancel()
        deviceListener = nil
        pipeline.stop()
        self.pipeline = nil
        engineLog.notice("engine stopped")
    }

    // MARK: Watching the running pipeline

    private func watch(_ pipeline: TapPipeline) {
        lastCallbacks = 0
        stalledTicks = 0
        healthTicks = 0

        // The IOProc runs whenever the device runs, silence included, so a
        // callback count that stops moving means the IO stopped.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        watchdog = timer
        timer.resume()

        // A new sample rate or channel layout invalidates the tap's format,
        // and a device that goes away takes the pipeline with it. The HAL also
        // sends these when nothing that matters moved, including around this
        // pipeline's own aggregate, so the values are compared first: a rebuild
        // on every notification could rebuild itself in a loop.
        let addresses = [
            CoreAudioDevices.address(kAudioDevicePropertyNominalSampleRate),
            CoreAudioDevices.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput),
            CoreAudioDevices.address(kAudioDevicePropertyDeviceIsAlive),
        ]
        deviceListener = PropertyListener(object: pipeline.outputDevice, addresses: addresses,
                                          queue: queue) { [weak self, weak pipeline] in
            // Queued before this pipeline was replaced: about one that is gone.
            guard let self, let pipeline, self.pipeline === pipeline else { return }
            let device = pipeline.outputDevice
            let alive = (CoreAudioDevices.value(device, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) ?? 0) != 0
            let rate = CoreAudioDevices.value(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
            let channels = CoreAudioDevices.firstStreamChannels(device, scope: kAudioObjectPropertyScopeOutput) ?? 0
            guard !alive || rate != pipeline.sampleRate || channels != pipeline.channels else { return }
            engineLog.notice("""
                output changed underneath the engine: alive \(alive, privacy: .public), \
                \(Int(rate), privacy: .public) Hz, \(channels, privacy: .public) ch
                """)
            self.build()
        }
    }

    private func checkHealth() {
        guard let pipeline else { return }
        let stats = pipeline.stats
        if stats.callbacks != lastCallbacks {
            stalledTicks = 0
            // IO is moving, so the next failure starts a fresh round of retries.
            failedAttempts = 0
        } else {
            stalledTicks += 1
        }
        lastCallbacks = stats.callbacks
        if stalledTicks >= 2 {
            // Also a pipeline that never delivered a first cycle. It goes through
            // the same capped retries as a failed start instead of being rebuilt
            // every 4 s for good.
            engineLog.error("IO stalled for 4 s, rebuilding")
            let name = pipeline.outputName
            tearDown()
            failed(on: name)
            return
        }

        healthTicks += 1
        if healthTicks % 30 == 0 {   // once a minute
            engineLog.info("""
                health: \(stats.callbacks, privacy: .public) cycles, \
                in \(Self.decibels(stats.inputLevel), privacy: .public) dB, \
                out \(Self.decibels(stats.outputLevel), privacy: .public) dB, \
                pass-throughs \(stats.passThroughs, privacy: .public), missing \(stats.missingBuffers, privacy: .public)
                """)
        }
    }

    private static func decibels(_ level: Float) -> Int {
        level > 0 ? Int((20 * log10(level)).rounded()) : -200
    }
}
