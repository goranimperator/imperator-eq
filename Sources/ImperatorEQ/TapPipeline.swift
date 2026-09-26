import AudioToolbox
import CoreAudio
import Foundation

/// What the pipeline applies. Plain values so they can cross threads.
struct EQSettings: Sendable, Equatable {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = frequencies.count

    /// Gain per band in dB, one entry per frequency above.
    var gains: [Float]
    /// Linear output gain, 0...2, where 1 is the level the apps play at.
    var volume: Float
    /// -1 is full left, 1 full right.
    var balance: Float

    static let flat = EQSettings(gains: Array(repeating: 0, count: bandCount), volume: 1, balance: 0)
}

/// Numbers the IO thread publishes for the watchdog and the engine check.
///
/// Lives in C memory. The IO thread writes it with plain stores and other
/// threads read it without a lock: every field is an aligned word, which arm64
/// and x86_64 both store in one piece, so a reader sees the old value or the
/// new one and never half of each. A stale value is harmless for what these
/// feed. A lock here would put the real-time thread behind whoever held it.
struct RenderStats {
    var callbacks: UInt64 = 0
    /// Cycles that skipped the EQ and copied the tap straight through, because
    /// the EQ failed or the cycle was larger than the scratch buffers.
    var passThroughs: UInt64 = 0
    /// Cycles that arrived without a tap buffer or an output buffer.
    var missingBuffers: UInt64 = 0
    /// Smoothed RMS of the tap and of what was written, first channel.
    var inputLevel: Float = 0
    var outputLevel: Float = 0
    var lastCallbackHostTime: UInt64 = 0
    var maxCallbackGapHostTicks: UInt64 = 0
    /// Output presentation time minus input capture time for the last cycle,
    /// in frames: what this pipeline adds between an app and the speaker.
    var latencyFrames: Float64 = 0
}

/// Written by the engine's queue, read by the IO thread every cycle.
struct RenderParams {
    var volume: Float = 1
    var balance: Float = 0
}

enum PipelineError: Error, CustomStringConvertible {
    case noOutputDevice
    case ownProcessUnknown
    case tap(OSStatus)
    case tapFormat(String)
    case aggregate(OSStatus)
    case streamLayout(String)
    case audioUnit(String, OSStatus)
    case io(String, OSStatus)

    var description: String {
        switch self {
        case .noOutputDevice: return "no default output device"
        case .ownProcessUnknown: return "the HAL has no process object for this app, so it cannot be excluded from the tap"
        case .tap(let s): return "AudioHardwareCreateProcessTap failed: \(s)"
        case .tapFormat(let why): return "unusable tap format: \(why)"
        case .aggregate(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)"
        case .streamLayout(let why): return "unexpected aggregate stream layout: \(why)"
        case .audioUnit(let step, let s): return "EQ audio unit, \(step): \(s)"
        case .io(let step, let s): return "IO, \(step): \(s)"
        }
    }
}

/// One running path: a process tap on the default output device, read through
/// a private aggregate device whose only sub-device is that same output, with
/// an IOProc that runs the tap through `AUNBandEQ` and writes the result back
/// to the device.
///
/// ```
/// apps -> [tap on output stream 0, muted while read] -> aggregate input
///      -> IOProc: AUNBandEQ, volume, balance -> aggregate output -> device
/// ```
///
/// Design decisions, each one load-bearing:
///
/// - **A device tap, not a global one.** `excludingProcesses:deviceUID:stream:`
///   captures only what apps are already sending to this device. A global tap
///   would also take audio an app deliberately sends to another device, mute it
///   there, and play it here.
/// - **`mutedWhenTapped`.** The apps are silenced only while this pipeline reads
///   the tap. If the app stops or dies, the apps are audible again at once.
/// - **This process is excluded**, or the pipeline would tap its own output and
///   feed back. Failing to find its own process object is a hard error.
/// - **Private tap and private aggregate.** Nothing is visible to other
///   processes, and coreaudiod removes both when this process exits, cleanly or
///   not, so a crash leaves nothing behind.
/// - **No `tapautostart`.** With it, `AudioDeviceStart` waits until an app plays
///   something, and on the main thread that freezes the menu bar item.
///
/// Every function here talks to coreaudiod and can block, so the pipeline is
/// built, changed and torn down only on the engine's queue, never on the main
/// thread.
final class TapPipeline {
    /// Larger than any cycle the HAL asks for at the buffer sizes used here;
    /// a larger cycle is passed through unprocessed rather than dropped.
    static let maxFrames = 4096

    let outputDevice: AudioDeviceID
    let outputUID: String
    let outputName: String
    let sampleRate: Float64
    let channels: Int
    let bufferFrames: UInt32

    private let tapID: AudioObjectID
    private let aggregateID: AudioDeviceID
    private let eqUnit: AudioUnit
    private let context: RenderContext
    private let contextRef: Unmanaged<RenderContext>
    private var ioProcID: AudioDeviceIOProcID?

    var stats: RenderStats { context.stats.pointee }
    var aggregateDevice: AudioDeviceID { aggregateID }
    var tap: AudioObjectID { tapID }

    // MARK: - Build

    static func start(settings: EQSettings, bufferFrames requestedBuffer: UInt32) throws -> TapPipeline {
        guard let output = CoreAudioDevices.defaultOutputDevice,
              let outputUID = CoreAudioDevices.uid(output) else { throw PipelineError.noOutputDevice }
        let outputName = CoreAudioDevices.name(output) ?? outputUID

        guard let ownProcess = CoreAudioDevices.processObject(for: getpid()) else {
            throw PipelineError.ownProcessUnknown
        }

        // Everything created below is undone in reverse if a later step fails.
        var undo: [() -> Void] = []
        func unwind() { undo.reversed().forEach { $0() } }

        let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: outputUID, stream: 0)
        description.name = "Imperator EQ"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw PipelineError.tap(tapStatus)
        }
        undo.append { AudioHardwareDestroyProcessTap(tapID) }

        do {
            let format = try tapFormat(tapID)
            let channels = Int(format.mChannelsPerFrame)

            let aggregateID = try makeAggregate(outputUID: outputUID, tapUUID: description.uuid)
            undo.append { AudioHardwareDestroyAggregateDevice(aggregateID) }

            let tapBufferIndex = try tapInputIndex(aggregate: aggregateID, output: output, tapChannels: channels)

            CoreAudioDevices.set(aggregateID, kAudioDevicePropertyBufferFrameSize, requestedBuffer)
            let actualBuffer = CoreAudioDevices.value(aggregateID, kAudioDevicePropertyBufferFrameSize, as: UInt32.self)
                ?? requestedBuffer

            let eqChannels = min(channels, 2)
            let eqUnit = try makeEQ(sampleRate: format.mSampleRate, channels: eqChannels)
            undo.append {
                AudioUnitUninitialize(eqUnit)
                AudioComponentInstanceDispose(eqUnit)
            }

            let context = RenderContext(eqUnit: eqUnit, tapBufferIndex: tapBufferIndex, channels: channels,
                                        eqChannels: eqChannels, maxFrames: maxFrames)
            let contextRef = Unmanaged.passRetained(context)
            undo.append { contextRef.release() }

            // The EQ pulls its input from the context's scratch planes.
            var input = AURenderCallbackStruct(inputProc: eqInputCallback,
                                               inputProcRefCon: contextRef.toOpaque())
            let callbackStatus = AudioUnitSetProperty(eqUnit, kAudioUnitProperty_SetRenderCallback,
                                                      kAudioUnitScope_Input, 0, &input,
                                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard callbackStatus == noErr else { throw PipelineError.audioUnit("render callback", callbackStatus) }
            let initStatus = AudioUnitInitialize(eqUnit)
            guard initStatus == noErr else { throw PipelineError.audioUnit("initialize", initStatus) }
            // Initializing resets every parameter, so the bands go on after it.
            configureBands(eqUnit)

            let pipeline = TapPipeline(outputDevice: output, outputUID: outputUID, outputName: outputName,
                                       sampleRate: format.mSampleRate, channels: channels,
                                       bufferFrames: actualBuffer, tapID: tapID,
                                       aggregateID: aggregateID, eqUnit: eqUnit, context: context,
                                       contextRef: contextRef)
            pipeline.apply(settings)

            var procID: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcID(aggregateID, tapIOProc, contextRef.toOpaque(), &procID)
            guard procStatus == noErr, let procID else { throw PipelineError.io("create IOProc", procStatus) }
            undo.append { AudioDeviceDestroyIOProcID(aggregateID, procID) }

            try useOnlyTapInput(aggregate: aggregateID, procID: procID, tapBufferIndex: tapBufferIndex)

            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else { throw PipelineError.io("start", startStatus) }

            pipeline.ioProcID = procID
            return pipeline
        } catch {
            unwind()
            throw error
        }
    }

    private init(outputDevice: AudioDeviceID, outputUID: String, outputName: String, sampleRate: Float64,
                 channels: Int, bufferFrames: UInt32, tapID: AudioObjectID,
                 aggregateID: AudioDeviceID, eqUnit: AudioUnit, context: RenderContext,
                 contextRef: Unmanaged<RenderContext>) {
        self.outputDevice = outputDevice
        self.outputUID = outputUID
        self.outputName = outputName
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferFrames = bufferFrames
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.eqUnit = eqUnit
        self.context = context
        self.contextRef = contextRef
    }

    /// The tap delivers interleaved 32-bit float in the device stream's own
    /// channel count and rate. Anything else would need a converter this
    /// pipeline does not have, so it is refused rather than misread.
    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        guard let format = CoreAudioDevices.value(tap, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) else {
            throw PipelineError.tapFormat("the tap has no readable format")
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0,
              format.mSampleRate > 0 else {
            throw PipelineError.tapFormat("\(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel) bit, "
                                          + "flags 0x\(String(format.mFormatFlags, radix: 16))")
        }
        return format
    }

    private static func makeAggregate(outputUID: String, tapUUID: UUID) throws -> AudioDeviceID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Imperator EQ",
            kAudioAggregateDeviceUIDKey: "\(AudioEngine.aggregateUIDPrefix)\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                // The output device is the clock; the tap is resampled to it.
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else { throw PipelineError.aggregate(status) }
        return aggregate
    }

    /// The aggregate lists its sub-device's own input streams first and the
    /// tap's stream last. Measured on macOS 27 with the microphone added as a
    /// second sub-device: stream 0 was the 1-channel microphone, stream 1 the
    /// 2-channel tap. A headset's microphone therefore sits in front of the tap,
    /// and the tap is the stream after all of the output device's inputs.
    private static func tapInputIndex(aggregate: AudioDeviceID, output: AudioDeviceID,
                                      tapChannels: Int) throws -> Int {
        let deviceInputs = CoreAudioDevices.streams(output, scope: kAudioObjectPropertyScopeInput).count
        let aggregateInputs = CoreAudioDevices.streams(aggregate, scope: kAudioObjectPropertyScopeInput)
        guard aggregateInputs.count == deviceInputs + 1 else {
            throw PipelineError.streamLayout("\(aggregateInputs.count) input streams, expected \(deviceInputs + 1)")
        }
        let outputs = CoreAudioDevices.streams(aggregate, scope: kAudioObjectPropertyScopeOutput)
        guard let firstOutput = outputs.first else { throw PipelineError.streamLayout("no output stream") }

        // Output stream 0 is the device stream the tap was taken from, so the
        // two must agree on the channel count the render loop relies on.
        let format = CoreAudioDevices.streamFormat(firstOutput)
        guard let format, Int(format.mChannelsPerFrame) == tapChannels,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
            throw PipelineError.streamLayout("output stream 0 has \(format?.mChannelsPerFrame ?? 0) channels, "
                                             + "tap has \(tapChannels)")
        }
        return deviceInputs
    }

    /// Switches off every input stream except the tap. A disabled stream reaches
    /// the IOProc as a NULL buffer and is never started, so a headset's
    /// microphone stays closed: no microphone prompt, no orange indicator, and
    /// no Bluetooth headset dropped into its low-quality call profile.
    private static func useOnlyTapInput(aggregate: AudioDeviceID, procID: AudioDeviceIOProcID,
                                        tapBufferIndex: Int) throws {
        let count = CoreAudioDevices.streams(aggregate, scope: kAudioObjectPropertyScopeInput).count
        guard count > 1 else { return }   // the tap is the only input; nothing to switch off

        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let byteCount = flagsOffset + count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                   alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        let flags = (raw + flagsOffset).bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { flags[i] = i == tapBufferIndex ? 1 : 0 }

        var addr = CoreAudioDevices.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(byteCount), raw)
        guard status == noErr else { throw PipelineError.io("stream usage", status) }
    }

    private static func makeEQ(sampleRate: Float64, channels: Int) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                    componentSubType: kAudioUnitSubType_NBandEQ,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw PipelineError.audioUnit("find AUNBandEQ", -1)
        }
        var instance: AudioUnit?
        let newStatus = AudioComponentInstanceNew(component, &instance)
        guard newStatus == noErr, let unit = instance else { throw PipelineError.audioUnit("instantiate", newStatus) }

        func set<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ value: T,
                                     _ step: String) throws {
            var value = value
            let status = AudioUnitSetProperty(unit, property, scope, 0, &value, UInt32(MemoryLayout<T>.size))
            guard status == noErr else {
                AudioComponentInstanceDispose(unit)
                throw PipelineError.audioUnit(step, status)
            }
        }

        // Planar float, the format AUNBandEQ renders natively.
        let format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, format, "input format")
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, format, "output format")
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, UInt32(maxFrames), "max frames")
        try set(AudioUnitPropertyID(kAUNBandEQProperty_NumberOfBands), kAudioUnitScope_Global,
                UInt32(EQSettings.bandCount), "band count")
        return unit
    }

    private static func configureBands(_ unit: AudioUnit) {
        for (i, frequency) in EQSettings.frequencies.enumerated() {
            let band = AudioUnitParameterID(i)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_FilterType) + band,
                                  kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUNBandEQFilterType_Parametric), 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_Frequency) + band,
                                  kAudioUnitScope_Global, 0, frequency, 0)
            // One octave wide, the curve the sliders have always drawn.
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_Bandwidth) + band,
                                  kAudioUnitScope_Global, 0, 1.0, 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUNBandEQParam_BypassBand) + band,
                                  kAudioUnitScope_Global, 0, 0, 0)
        }
    }

    // MARK: - Run

    /// Parameter changes are safe while rendering: `AUNBandEQ` takes parameter
    /// writes from any thread, and volume and balance are single aligned words.
    func apply(_ settings: EQSettings) {
        for (i, gain) in settings.gains.prefix(EQSettings.bandCount).enumerated() {
            AudioUnitSetParameter(eqUnit, AudioUnitParameterID(kAUNBandEQParam_Gain) + AudioUnitParameterID(i),
                                  kAudioUnitScope_Global, 0, gain, 0)
        }
        context.params.pointee.volume = settings.volume
        context.params.pointee.balance = settings.balance
    }

    /// Stops IO first, so the IOProc is finished with the context before
    /// anything it reads is freed, then removes the aggregate and the tap. The
    /// tap going away is what unmutes the apps.
    @discardableResult
    func stop() -> [String: OSStatus] {
        guard let procID = ioProcID else { return [:] }
        ioProcID = nil
        var statuses: [String: OSStatus] = [:]
        statuses["stop"] = AudioDeviceStop(aggregateID, procID)
        statuses["destroyIOProc"] = AudioDeviceDestroyIOProcID(aggregateID, procID)
        statuses["destroyAggregate"] = AudioHardwareDestroyAggregateDevice(aggregateID)
        statuses["destroyTap"] = AudioHardwareDestroyProcessTap(tapID)
        AudioUnitUninitialize(eqUnit)
        AudioComponentInstanceDispose(eqUnit)
        contextRef.release()
        for (step, status) in statuses where status != noErr {
            engineLog.error("teardown \(step, privacy: .public) failed: \(status, privacy: .public)")
        }
        return statuses
    }

    deinit {
        assert(ioProcID == nil, "TapPipeline released while still running")
    }
}

// MARK: - Real-time render

/// State the IOProc reads. Allocated once per pipeline and never resized while
/// the IOProc can run.
private final class RenderContext {
    let eqUnit: AudioUnit
    /// Index of the tap's buffer in the IOProc's input list.
    let tapBufferIndex: Int
    /// Channels in the tap, which equal the channels of output stream 0.
    let channels: Int
    /// Channels the EQ processes: the first two, or one on a mono device.
    let eqChannels: Int
    let maxFrames: Int
    let eqIn: UnsafeMutablePointer<Float>
    let eqOut: UnsafeMutablePointer<Float>
    let eqOutList: UnsafeMutableAudioBufferListPointer
    let params: UnsafeMutablePointer<RenderParams>
    let stats: UnsafeMutablePointer<RenderStats>

    /// One-pole smoothing per cycle for the level meters.
    private static let levelSmoothing: Float = 0.2

    init(eqUnit: AudioUnit, tapBufferIndex: Int, channels: Int, eqChannels: Int, maxFrames: Int) {
        self.eqUnit = eqUnit
        self.tapBufferIndex = tapBufferIndex
        self.channels = channels
        self.eqChannels = eqChannels
        self.maxFrames = maxFrames
        eqIn = .allocate(capacity: eqChannels * maxFrames)
        eqIn.initialize(repeating: 0, count: eqChannels * maxFrames)
        eqOut = .allocate(capacity: eqChannels * maxFrames)
        eqOut.initialize(repeating: 0, count: eqChannels * maxFrames)
        eqOutList = AudioBufferList.allocate(maximumBuffers: eqChannels)
        for ch in 0..<eqChannels {
            eqOutList[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0,
                                        mData: UnsafeMutableRawPointer(eqOut + ch * maxFrames))
        }
        params = .allocate(capacity: 1)
        params.initialize(to: RenderParams())
        stats = .allocate(capacity: 1)
        stats.initialize(to: RenderStats())
    }

    deinit {
        eqIn.deallocate()
        eqOut.deallocate()
        free(eqOutList.unsafeMutablePointer)
        params.deallocate()
        stats.deallocate()
    }

    /// One IO cycle. No allocation, no locks, no Objective-C: this runs on the
    /// HAL's real-time thread. Whenever the EQ cannot run, the tap is copied
    /// through unprocessed, because the apps are muted while the tap is read and
    /// silence here would be silence on the speaker.
    func render(input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>,
                output: UnsafeMutablePointer<AudioBufferList>, outputTime: UnsafePointer<AudioTimeStamp>) {
        let now = mach_absolute_time()
        if stats.pointee.lastCallbackHostTime != 0 {
            let gap = now &- stats.pointee.lastCallbackHostTime
            if gap > stats.pointee.maxCallbackGapHostTicks { stats.pointee.maxCallbackGapHostTicks = gap }
        }
        stats.pointee.lastCallbackHostTime = now
        stats.pointee.callbacks &+= 1

        let outList = UnsafeMutableAudioBufferListPointer(output)
        // Every output stream starts silent. Stream 0 is overwritten below; any
        // other stream of the device has nothing of ours to play.
        for i in 0..<outList.count {
            if let data = outList[i].mData { memset(data, 0, Int(outList[i].mDataByteSize)) }
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard tapBufferIndex < inList.count, let tapRaw = inList[tapBufferIndex].mData,
              outList.count > 0, let outRaw = outList[0].mData else {
            stats.pointee.missingBuffers &+= 1
            return
        }
        let bytesPerFrame = channels * MemoryLayout<Float>.size
        let frames = min(Int(inList[tapBufferIndex].mDataByteSize), Int(outList[0].mDataByteSize)) / bytesPerFrame
        guard frames > 0 else { return }

        let tap = tapRaw.assumingMemoryBound(to: Float.self)
        let out = outRaw.assumingMemoryBound(to: Float.self)
        let samples = frames * channels

        if inputTime.pointee.mFlags.contains(.sampleTimeValid),
           outputTime.pointee.mFlags.contains(.sampleTimeValid) {
            stats.pointee.latencyFrames = outputTime.pointee.mSampleTime - inputTime.pointee.mSampleTime
        }

        let volume = params.pointee.volume
        let balance = params.pointee.balance
        // Balance moves a stereo pair; volume scales every channel.
        let leftGain = eqChannels == 2 ? volume * min(1, 1 - balance) : volume
        let rightGain = volume * min(1, 1 + balance)

        guard frames <= maxFrames else {
            copyThrough(tap: tap, out: out, frames: frames, leftGain: leftGain, rightGain: rightGain, volume: volume)
            stats.pointee.passThroughs &+= 1
            measure(tap: tap, out: out, samples: samples, frames: frames)
            return
        }

        // Deinterleave the channels the EQ takes into its input planes.
        for ch in 0..<eqChannels {
            let plane = eqIn + ch * maxFrames
            var source = tap + ch
            for f in 0..<frames {
                plane[f] = source.pointee
                source += channels
            }
        }

        for ch in 0..<eqChannels {
            eqOutList[ch].mData = UnsafeMutableRawPointer(eqOut + ch * maxFrames)
            eqOutList[ch].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        }
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(eqUnit, &flags, outputTime, 0, UInt32(frames), eqOutList.unsafeMutablePointer)
        guard status == noErr else {
            copyThrough(tap: tap, out: out, frames: frames, leftGain: leftGain, rightGain: rightGain, volume: volume)
            stats.pointee.passThroughs &+= 1
            measure(tap: tap, out: out, samples: samples, frames: frames)
            return
        }

        if eqChannels == 2 {
            let left = eqOut
            let right = eqOut + maxFrames
            var destination = out
            for f in 0..<frames {
                destination[0] = left[f] * leftGain
                destination[1] = right[f] * rightGain
                destination += channels
            }
        } else {
            var destination = out
            for f in 0..<frames {
                destination[0] = eqOut[f] * leftGain
                destination += channels
            }
        }

        // Channels past the two the EQ takes, on a multichannel device, pass
        // through at the same volume instead of going silent.
        for ch in eqChannels..<channels {
            copyChannel(ch, from: tap, to: out, frames: frames, gain: volume)
        }

        measure(tap: tap, out: out, samples: samples, frames: frames)
    }

    /// The tap straight to the output at the gains the EQ path applies, so a
    /// cycle that skips the EQ loses the tone shaping but keeps the volume and
    /// the balance: at volume 0 it stays silent.
    private func copyThrough(tap: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>, frames: Int,
                             leftGain: Float, rightGain: Float, volume: Float) {
        for ch in 0..<channels {
            let gain = ch == 0 ? leftGain : (ch == 1 && eqChannels == 2 ? rightGain : volume)
            copyChannel(ch, from: tap, to: out, frames: frames, gain: gain)
        }
    }

    private func copyChannel(_ ch: Int, from tap: UnsafeMutablePointer<Float>, to out: UnsafeMutablePointer<Float>,
                             frames: Int, gain: Float) {
        var source = tap + ch
        var destination = out + ch
        for _ in 0..<frames {
            destination.pointee = source.pointee * gain
            source += channels
            destination += channels
        }
    }

    private func measure(tap: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>,
                         samples: Int, frames: Int) {
        var inSum: Float = 0
        var outSum: Float = 0
        var i = 0
        while i < samples {
            inSum += tap[i] * tap[i]
            outSum += out[i] * out[i]
            i += channels
        }
        let inRMS = (inSum / Float(frames)).squareRoot()
        let outRMS = (outSum / Float(frames)).squareRoot()
        stats.pointee.inputLevel += Self.levelSmoothing * (inRMS - stats.pointee.inputLevel)
        stats.pointee.outputLevel += Self.levelSmoothing * (outRMS - stats.pointee.outputLevel)
    }
}

/// Feeds the EQ from the planes the IOProc just filled.
private let eqInputCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return kAudio_ParamError }
    let context = Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue()
    let list = UnsafeMutableAudioBufferListPointer(ioData)
    let bytes = Int(frames) * MemoryLayout<Float>.size
    for ch in 0..<min(list.count, context.eqChannels) {
        let plane = context.eqIn + ch * context.maxFrames
        if let destination = list[ch].mData {
            memcpy(destination, plane, bytes)
        } else {
            list[ch].mData = UnsafeMutableRawPointer(plane)
        }
        list[ch].mDataByteSize = UInt32(bytes)
    }
    return noErr
}

private let tapIOProc: AudioDeviceIOProc = { _, _, input, inputTime, output, outputTime, clientData in
    guard let clientData else { return noErr }
    Unmanaged<RenderContext>.fromOpaque(clientData).takeUnretainedValue()
        .render(input: input, inputTime: inputTime, output: output, outputTime: outputTime)
    return noErr
}
