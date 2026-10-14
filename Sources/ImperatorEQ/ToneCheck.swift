import AudioToolbox
import Foundation

/// `ImperatorEQ --tone-check` proves the CONTROLS knobs change the sound. No audio
/// device and no permission are involved, so it runs from a terminal and plays
/// nothing.
///
/// - Bass, Mid, Treble: sine tones rendered offline through the EQ unit exactly
///   as a pipeline configures it, each knob at -10, 0 and +10, gain read at
///   60 Hz, 1 kHz and 10 kHz. At +-10 a knob moves its own frequency by 9 to 13
///   dB in the right direction and the other two by under 3 dB; at 0 nothing
///   moves more than 0.1 dB.
/// - Warmth: a 1 kHz sine through `Warmth.process` at 0, 5 and 10. At 0 the
///   signal is untouched; at 10 a -6 dBFS tone gets 2 to 10 % harmonic distortion
///   while its level moves under 0.5 dB, and a -20 dBFS tone stays under 2 %.
///   Its DC blocker leaves a 32 Hz tone within 0.1 dB at 44.1, 96 and 192 kHz,
///   and after ten seconds of silence its state is exactly 0, not subnormal.
/// - Limiter: a stereo 1 kHz sine through `Limiter.process`, driven the way the
///   app drives it from the knob (`EQSettings.limiterDrive`). At 0 it is untouched;
///   at 5 a -20 dBFS tone comes out 6 dB louder and clean; at 10 a -6 dBFS tone
///   comes out louder with no sample above the -0.2 dBFS ceiling.
/// - Gain: the output factor the knob gives at +-10 is +-12 dB.
/// - Mono: a tone on the left only comes out at half level on both sides.
///
/// Prints `TONE_CHECK_OK` when every case passes.
enum ToneCheck {
    private static let sampleRate: Float64 = 48_000
    private static let probes: [(name: String, frequency: Double)] = [("60 Hz", 60), ("1 kHz", 1000), ("10 kHz", 10_000)]
    private static let knobs = ["Bass", "Mid", "Treble"]

    static func run() -> Int32 {
        var failures = 0
        for (knob, name) in knobs.enumerated() {
            for step in [-10, 0, 10] {
                var settings = EQSettings.flat
                settings.tone[knob] = Float(step) * EQSettings.toneDecibelsPerStep
                var line = "\(name) \(step > 0 ? "+" : "")\(step):"
                for (probe, (label, frequency)) in probes.enumerated() {
                    guard let gain = measure(settings, frequency: frequency) else {
                        print("\(line) render failed")
                        return 1
                    }
                    line += String(format: "  %@ %+6.2f dB", label, gain)
                    let ok: Bool
                    if step == 0 {
                        ok = abs(gain) < 0.1
                    } else if probe == knob {
                        ok = (9...13).contains(abs(gain)) && (gain > 0) == (step > 0)
                    } else {
                        ok = abs(gain) < 3
                    }
                    if !ok { failures += 1; line += " FAIL" }
                }
                print(line)
            }
        }
        failures += checkWarmth()
        failures += checkWarmthLowEnd()
        failures += checkWarmthSilence()
        failures += checkLimiter()
        failures += checkGain()
        failures += checkMono()
        print(failures == 0 ? "TONE_CHECK_OK" : "TONE_CHECK_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Output level over input level for a steady sine, after the filters settle.
    private static func measure(_ settings: EQSettings, frequency: Double) -> Double? {
        guard let unit = try? TapPipeline.makeEQ(sampleRate: sampleRate, channels: 1) else { return nil }
        defer {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        let source = Sine(frequency: frequency, sampleRate: sampleRate)
        let sourceRef = Unmanaged.passRetained(source)
        defer { sourceRef.release() }
        var callback = AURenderCallbackStruct(inputProc: sineCallback, inputProcRefCon: sourceRef.toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr else { return nil }
        TapPipeline.configureBands(unit, sampleRate: sampleRate)
        TapPipeline.applyGains(settings, to: unit)

        let frames = 512
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        var sum = 0.0
        var count = 0
        let blocks = Int(sampleRate) / frames   // one second
        for block in 0..<blocks {
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(buffer))
            var flags = AudioUnitRenderActionFlags()
            guard AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), list.unsafeMutablePointer) == noErr else { return nil }
            time.mSampleTime += Float64(frames)
            // The second half: well past any filter settling.
            if block >= blocks / 2 {
                for i in 0..<frames { sum += Double(buffer[i] * buffer[i]) }
                count += frames
            }
        }
        let outRMS = (sum / Double(count)).squareRoot()
        return 20 * log10(outRMS / (Sine.amplitude / 2.0.squareRoot()))
    }

    private static func checkWarmth() -> Int {
        var failures = 0
        let frames = Int(sampleRate)
        for (amount, amplitude) in [(Float(0), Float(0.5)), (0.5, 0.5), (1, 0.5), (1, 0.1)] {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer { buffer.deallocate() }
            let state = UnsafeMutablePointer<Float>.allocate(capacity: 2)
            defer { state.deallocate() }
            state.initialize(repeating: 0, count: 2)
            let step = 2 * Float.pi * 1000 / Float(sampleRate)
            for i in 0..<frames { buffer[i] = amplitude * sinf(step * Float(i)) }
            let inRMS = amplitude / Float(2).squareRoot()
            // In blocks, as the render does.
            var offset = 0
            while offset < frames {
                let n = min(256, frames - offset)
                Warmth.process(buffer + offset, frames: n, amount: amount,
                               blocker: Warmth.blockerCoefficient(sampleRate: sampleRate), state: state)
                offset += n
            }
            // The second half, past the DC blocker settling.
            let half = UnsafeMutablePointer(buffer + frames / 2)
            let count = frames / 2
            var sum: Float = 0
            for i in 0..<count { sum += half[i] * half[i] }
            let level = 20 * log10(Double((sum / Float(count)).squareRoot() / inRMS))
            let fundamental = goertzel(half, count: count, frequency: 1000)
            let harmonics = (2...5).map { goertzel(half, count: count, frequency: 1000 * Double($0)) }
            let thd = harmonics.map { $0 * $0 }.reduce(0, +).squareRoot() / fundamental * 100
            let ok: Bool
            if amount == 0 {
                ok = abs(level) < 0.01 && thd < 0.01
            } else if amount == 1 && amplitude == 0.5 {
                ok = (2...10).contains(thd) && abs(level) < 0.5
            } else if amount == 1 {
                ok = thd < 2 && abs(level) < 0.5
            } else {
                ok = thd < 10 && abs(level) < 0.5
            }
            if !ok { failures += 1 }
            print(String(format: "Warmth %2.0f, tone %.0f dBFS:  level %+5.2f dB  THD %5.2f %%%@",
                         amount * 10, 20 * log10(Double(amplitude)), level, thd, ok ? "" : " FAIL"))
        }
        return failures
    }

    /// Warmth runs the whole signal through its DC blocker, so the blocker must
    /// not cut the lowest band at any output rate.
    private static func checkWarmthLowEnd() -> Int {
        var failures = 0
        let amplitude: Float = 0.1
        for rate in [44_100.0, 96_000.0, 192_000.0] {
            let frames = Int(rate)
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer { buffer.deallocate() }
            let state = UnsafeMutablePointer<Float>.allocate(capacity: 2)
            defer { state.deallocate() }
            state.initialize(repeating: 0, count: 2)
            let step = 2 * Float.pi * 32 / Float(rate)
            for i in 0..<frames { buffer[i] = amplitude * sinf(step * Float(i)) }
            let blocker = Warmth.blockerCoefficient(sampleRate: rate)
            var offset = 0
            while offset < frames {
                let n = min(256, frames - offset)
                Warmth.process(buffer + offset, frames: n, amount: 1, blocker: blocker, state: state)
                offset += n
            }
            // Half a second: 16 whole periods, so the fundamental falls on a bin.
            let fundamental = goertzel(buffer + frames / 2, count: frames / 2, frequency: 32, sampleRate: rate)
            let level = 20 * log10(fundamental / Double(amplitude))
            let ok = abs(level) < 0.1
            if !ok { failures += 1 }
            print(String(format: "Warmth 10, 32 Hz at %.1f kHz:  level %+5.2f dB%@", rate / 1000, level,
                         ok ? "" : " FAIL"))
        }
        return failures
    }

    /// A tone, then ten seconds of digital silence: the blocker's state must end
    /// at exactly 0, not stuck in the subnormal range.
    private static func checkWarmthSilence() -> Int {
        let block = 256
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { buffer.deallocate() }
        let state = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        defer { state.deallocate() }
        state.initialize(repeating: 0, count: 2)
        let blocker = Warmth.blockerCoefficient(sampleRate: sampleRate)
        let step = 2 * Float.pi * 1000 / Float(sampleRate)
        var frame = 0
        for _ in 0..<(Int(sampleRate) / 2 / block) {
            for i in 0..<block { buffer[i] = 0.5 * sinf(step * Float(frame + i)) }
            frame += block
            Warmth.process(buffer, frames: block, amount: 1, blocker: blocker, state: state)
        }
        for _ in 0..<(Int(sampleRate) * 10 / block) {
            buffer.update(repeating: 0, count: block)
            Warmth.process(buffer, frames: block, amount: 1, blocker: blocker, state: state)
        }
        let ok = state[0] == 0 && state[1] == 0
        print("Warmth 10, after 10 s of silence: blocker state", ok ? "0" : "\(state[1]) FAIL")
        return ok ? 0 : 1
    }

    private static func checkLimiter() -> Int {
        var failures = 0
        let frames = Int(sampleRate)
        let release = Limiter.releaseCoefficient(sampleRate: sampleRate)
        for (knob, amplitude) in [(Float(0), Float(0.5)), (5, 0.1), (10, 0.5)] {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 2 * frames)
            defer { samples.deallocate() }
            let step = 2 * Float.pi * 1000 / Float(sampleRate)
            for i in 0..<frames {
                samples[2 * i] = amplitude * sinf(step * Float(i))
                samples[2 * i + 1] = samples[2 * i]
            }
            let envelope = UnsafeMutablePointer<Float>.allocate(capacity: 1)
            defer { envelope.deallocate() }
            envelope.initialize(to: 1)
            var controls = ControlValues()
            controls.limiter = knob
            let drive = EQSettings(bands: [], balance: 0, controls: controls, mono: false).limiterDrive
            var offset = 0
            while offset < frames {
                let n = min(256, frames - offset)
                Limiter.process(samples + 2 * offset, frames: n, channels: 2, drive: drive,
                                envelope: envelope, release: release)
                offset += n
            }
            var peak: Float = 0
            var sum: Float = 0
            for i in frames / 2..<frames {
                peak = max(peak, abs(samples[2 * i]))
                sum += samples[2 * i] * samples[2 * i]
            }
            let rms = (sum / Float(frames / 2)).squareRoot()
            let level = 20 * log10(Double(rms / (amplitude / Float(2).squareRoot())))
            let ok: Bool
            switch knob {
            case 0: ok = abs(level) < 0.01
            case 5: ok = abs(level - 6) < 0.05 && peak <= Limiter.ceiling
            default: ok = level > 4 && peak <= Limiter.ceiling + 1e-4
            }
            if !ok { failures += 1 }
            print(String(format: "Limiter %2.0f, tone %.0f dBFS:  level %+5.2f dB  peak %.3f (ceiling %.3f)%@",
                         knob, 20 * log10(Double(amplitude)), level, peak, Limiter.ceiling, ok ? "" : " FAIL"))
        }
        return failures
    }

    private static func checkMono() -> Int {
        let frames = 512
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        for i in 0..<frames { left[i] = 0.5 * sinf(Float(i) * 0.1); right[i] = 0 }
        let original = (0..<frames).map { left[$0] }
        Mono.process(left: left, right: right, frames: frames)
        let ok = (0..<frames).allSatisfy { abs(left[$0] - original[$0] / 2) < 1e-6 && left[$0] == right[$0] }
        print("Mono: left-only tone ->", ok ? "half level on both sides" : "WRONG FAIL")
        return ok ? 0 : 1
    }

    private static func checkGain() -> Int {
        var failures = 0
        for step in [-10, 0, 10] {
            var controls = ControlValues()
            controls.gain = Float(step)
            let settings = EQSettings(bands: [], balance: 0, controls: controls, mono: false)
            let db = 20 * log10(Double(settings.outputGain))
            let ok = abs(db - Double(step) * 1.2) < 0.01
            if !ok { failures += 1 }
            print(String(format: "Gain %+3d: output %+6.2f dB%@", step, db, ok ? "" : " FAIL"))
        }
        return failures
    }

    /// Amplitude of one frequency in a block (Goertzel), scaled to a sine's peak.
    private static func goertzel(_ x: UnsafeMutablePointer<Float>, count: Int, frequency: Double,
                                 sampleRate: Double = ToneCheck.sampleRate) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<count {
            let s0 = Double(x[i]) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return 2 * power.squareRoot() / Double(count)
    }

    private final class Sine {
        static let amplitude = 0.1
        let step: Double
        var phase = 0.0
        init(frequency: Double, sampleRate: Double) { step = 2 * .pi * frequency / sampleRate }
    }

    private static let sineCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
        guard let ioData else { return kAudio_ParamError }
        let sine = Unmanaged<Sine>.fromOpaque(refCon).takeUnretainedValue()
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
        for i in 0..<Int(frames) {
            data[i] = Float(Sine.amplitude * sin(sine.phase))
            sine.phase += sine.step
        }
        list[0].mDataByteSize = frames * 4
        return noErr
    }
}
