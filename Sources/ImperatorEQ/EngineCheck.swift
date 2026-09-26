import CoreAudio
import Foundation

/// `ImperatorEQ --engine-check --report <path> [options]` runs the real
/// `TapPipeline` headless and writes what it measured as JSON. It records no
/// audio, only levels, counters and timing.
///
/// It has to run as the app, launched with `open -n`, because macOS grants
/// System Audio Recording to the app and attributes a process started from a
/// terminal to the terminal. The app itself must not be running at the same
/// time: two taps on one device means two copies of the sound.
///
/// Modes:
/// - `measure` (default): start/stop cycles to catch leaks, then three phases
///   once a tone arrives: flat EQ, 1 kHz boosted 12 dB, and a tail after the
///   tone has stopped. An outside script plays the tone and judges the report.
/// - `soak`: flat EQ for `--seconds`, one row a second, to catch IO that stops
///   or input that goes silent over time.
enum EngineCheck {
    private struct Options {
        var report = ""
        var mode = "measure"
        var cycles = 5
        var phaseSeconds = 4.0
        var seconds = 60.0
        var buffer = AudioEngine.bufferFrames

        init(_ args: [String]) {
            var i = 0
            func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
            while i < args.count {
                switch args[i] {
                case "--report": report = next() ?? ""
                case "--mode": mode = next() ?? mode
                case "--cycles": cycles = Int(next() ?? "") ?? cycles
                case "--phase-seconds": phaseSeconds = Double(next() ?? "") ?? phaseSeconds
                case "--seconds": seconds = Double(next() ?? "") ?? seconds
                case "--buffer": buffer = UInt32(next() ?? "") ?? buffer
                default: break
                }
                i += 1
            }
        }
    }

    static func run(_ arguments: [String]) -> Int32 {
        let options = Options(arguments)
        guard !options.report.isEmpty else {
            print("usage: --engine-check --report <path> [--mode measure|soak] [--cycles n] "
                  + "[--phase-seconds s] [--seconds s] [--buffer frames]")
            return 64
        }
        var report: [String: Any] = ["mode": options.mode]
        let access = SystemAudioAccess.status()
        report["access"] = String(describing: access)
        report["ownProcessObject"] = CoreAudioDevices.processObject(for: getpid()).map { Int($0) } ?? -1

        // A tap without access reads silence; nothing below would mean anything.
        guard access == .authorized else {
            write(report, to: options.report)
            return 3
        }

        report["baseline"] = counts()
        do {
            if options.mode == "soak" {
                try soak(options, into: &report)
            } else {
                try cycles(options, into: &report)
                try measure(options, into: &report)
            }
        } catch {
            report["error"] = String(describing: error)
            report["final"] = settledCounts(baseline: report["baseline"] as? [String: Int] ?? [:])
            write(report, to: options.report)
            return 1
        }
        report["final"] = settledCounts(baseline: report["baseline"] as? [String: Int] ?? [:])
        write(report, to: options.report)
        return 0
    }

    /// Counts once the HAL has had up to two seconds to drop destroyed objects.
    private static func settledCounts(baseline: [String: Int]) -> [String: Any] {
        let start = Date()
        while counts() != baseline, Date().timeIntervalSince(start) < 2 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        var result: [String: Any] = counts()
        result["settledAfter"] = counts() == baseline ? Date().timeIntervalSince(start) : -1
        return result
    }

    /// Taps and aggregates this process can see. Both are private, so after a
    /// stop anything above the baseline is a leak.
    private static func counts() -> [String: Int] {
        let taps = CoreAudioDevices.objectIDs(CoreAudioDevices.system, kAudioHardwarePropertyTapList).count
        let aggregates = CoreAudioDevices.allDevices.filter {
            CoreAudioDevices.uid($0)?.hasPrefix(AudioEngine.aggregateUIDPrefix) == true
        }.count
        return ["taps": taps, "aggregates": aggregates]
    }

    private static func cycles(_ options: Options, into report: inout [String: Any]) throws {
        var rows: [[String: Any]] = []
        for _ in 0..<options.cycles {
            let pipeline = try TapPipeline.start(settings: .flat, bufferFrames: options.buffer)
            Thread.sleep(forTimeInterval: 0.3)
            let callbacks = pipeline.stats.callbacks
            let statuses = pipeline.stop()
            var row: [String: Any] = ["callbacks": Int(callbacks),
                                      "statuses": statuses.mapValues { Int($0) }]
            for (key, value) in counts() { row["\(key)AfterStop"] = value }
            // The HAL drops destroyed objects from its lists asynchronously, so
            // "gone right after stop" and "gone at all" are different claims.
            // Wait up to two seconds for the counts to settle and record how
            // long that took.
            let baseline = report["baseline"] as? [String: Int] ?? [:]
            let settleStart = Date()
            while counts() != baseline, Date().timeIntervalSince(settleStart) < 2 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            row["settledAfter"] = counts() == baseline ? Date().timeIntervalSince(settleStart) : -1
            for (key, value) in counts() { row["\(key)Settled"] = value }
            rows.append(row)
        }
        report["cycles"] = rows
    }

    private static func measure(_ options: Options, into report: inout [String: Any]) throws {
        let pipeline = try TapPipeline.start(settings: .flat, bufferFrames: options.buffer)
        defer { pipeline.stop() }
        describe(pipeline, into: &report)

        // The outside script waits for this file before it starts the tone.
        FileManager.default.createFile(atPath: options.report + ".ready", contents: nil)

        // Phase clocks start when the tone reaches the tap, so launch time does
        // not matter. -60 dBFS is far above the silence floor of a tap.
        let waitStart = Date()
        while pipeline.stats.inputLevel < 0.001 {
            guard Date().timeIntervalSince(waitStart) < 20 else {
                report["toneDetectedAfter"] = NSNull()
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        report["toneDetectedAfter"] = Date().timeIntervalSince(waitStart)

        var boosted = EQSettings.flat
        boosted.gains[5] = 12   // 1 kHz
        var rows: [[String: Any]] = []
        let phases: [(name: String, settings: EQSettings, start: Double)] = [
            ("flat", .flat, 0),
            ("boost", boosted, options.phaseSeconds),
            // One second after the tone ends: whatever still arrives here
            // would have to be this app's own output coming back.
            ("tail", boosted, 2 * options.phaseSeconds + 1),
        ]
        let t0 = Date()
        for (index, phase) in phases.enumerated() {
            while Date().timeIntervalSince(t0) < phase.start { Thread.sleep(forTimeInterval: 0.01) }
            pipeline.apply(phase.settings)
            let end = index + 1 < phases.count ? phases[index + 1].start : phase.start + options.phaseSeconds
            while Date().timeIntervalSince(t0) < end {
                rows.append(row(pipeline, phase: phase.name))
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        report["rows"] = rows
    }

    private static func soak(_ options: Options, into report: inout [String: Any]) throws {
        let pipeline = try TapPipeline.start(settings: .flat, bufferFrames: options.buffer)
        defer { pipeline.stop() }
        describe(pipeline, into: &report)
        FileManager.default.createFile(atPath: options.report + ".ready", contents: nil)
        var rows: [[String: Any]] = []
        let t0 = Date()
        while Date().timeIntervalSince(t0) < options.seconds {
            rows.append(row(pipeline, phase: "soak"))
            Thread.sleep(forTimeInterval: 1)
        }
        report["rows"] = rows
    }

    private static func row(_ pipeline: TapPipeline, phase: String) -> [String: Any] {
        let stats = pipeline.stats
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let gapMs = Double(stats.maxCallbackGapHostTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e6
        return [
            "t": Date().timeIntervalSince1970,
            "phase": phase,
            "callbacks": Int(stats.callbacks),
            "in": Double(stats.inputLevel),
            "out": Double(stats.outputLevel),
            "passThroughs": Int(stats.passThroughs),
            "missing": Int(stats.missingBuffers),
            "maxGapMs": gapMs,
            "latencyFrames": stats.latencyFrames,
        ]
    }

    private static func describe(_ pipeline: TapPipeline, into report: inout [String: Any]) {
        report["pipeline"] = [
            "device": pipeline.outputName,
            "deviceUID": pipeline.outputUID,
            "sampleRate": pipeline.sampleRate,
            "channels": pipeline.channels,
            "bufferFrames": Int(pipeline.bufferFrames),
        ]

        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var addr = CoreAudioDevices.address(kAudioTapPropertyDescription)
        if AudioObjectGetPropertyData(pipeline.tap, &addr, 0, nil, &size, &description) == noErr,
           let tap = description?.takeUnretainedValue() {
            report["tap"] = [
                "muteBehavior": tap.muteBehavior.rawValue,
                "isPrivate": tap.isPrivate,
                "isExclusive": tap.isExclusive,
                "processes": tap.processes.map { Int($0) },
                "deviceUID": tap.deviceUID ?? NSNull(),
            ] as [String: Any]
        }

        func latency(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope) -> Int {
            CoreAudioDevices.value(object, selector, scope: scope, as: UInt32.self).map(Int.init) ?? -1
        }
        let aggregate = pipeline.aggregateDevice
        let inputs = CoreAudioDevices.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        let outputs = CoreAudioDevices.streams(aggregate, scope: kAudioObjectPropertyScopeOutput)
        report["latency"] = [
            "deviceOutputLatency": latency(pipeline.outputDevice, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
            "deviceOutputSafetyOffset": latency(pipeline.outputDevice, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
            "aggregateInputLatency": latency(aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
            "aggregateInputSafetyOffset": latency(aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
            "aggregateOutputLatency": latency(aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
            "aggregateOutputSafetyOffset": latency(aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
            "tapStreamLatency": inputs.last.map { latency($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? -1,
            "outputStreamLatency": outputs.first.map { latency($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? -1,
        ]
    }

    private static func write(_ report: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: report,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
