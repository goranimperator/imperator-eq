import AudioToolbox
import CoreAudio
import Foundation

// Shared state between audio thread and main thread
// Float reads/writes are atomic on Apple Silicon
private final class RenderContext {
    var ioUnit: AudioUnit
    var eqUnit: AudioUnit
    var volume: Float = 1.0
    var balance: Float = 0.0
    var vizLevels = [Float](repeating: 0, count: 128)
    var vizReady = false

    init(ioUnit: AudioUnit, eqUnit: AudioUnit) {
        self.ioUnit = ioUnit
        self.eqUnit = eqUnit
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

@MainActor
final class AudioEngine: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0.0, count: 128)
    @Published var isRunning = false
    @Published var availableOutputDevices: [OutputDevice] = []
    @Published var activeOutputUID: String?

    private var ioUnit: AudioUnit?
    private var eqUnit: AudioUnit?
    private var context: RenderContext?
    private var contextRetained: Unmanaged<RenderContext>?
    private var aggregateDeviceID: AudioDeviceID = 0
    private var realOutputDeviceID: AudioDeviceID?
    private var blackHoleDeviceID: AudioDeviceID?
    private var vizTimer: Timer?
    private var defaultOutputListenerInstalled = false
    private nonisolated(unsafe) var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var manualOutputUID: String?
    private var deviceListListenerInstalled = false
    private nonisolated(unsafe) var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    private let blackHoleUID = "BlackHole2ch_UID"
    private let aggregateUID = "ImperatorEQ_Aggregate"
    private let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private weak var store: EQStore?

    // MARK: - Public API

    func refreshOutputDevices() {
        let knownUIDs: Set<String> = [blackHoleUID, aggregateUID]
        var devices: [OutputDevice] = []
        for deviceID in getAllDeviceIDs() {
            guard let uid = getDeviceUID(deviceID) else { continue }
            if knownUIDs.contains(uid) { continue }
            guard getOutputChannelCount(deviceID) > 0 else { continue }
            let transport = getDeviceTransportType(deviceID)
            // Skip monitors
            if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort { continue }
            let name = getDeviceName(deviceID) ?? "Unknown"
            devices.append(OutputDevice(id: deviceID, uid: uid, name: name))
        }
        availableOutputDevices = devices
    }

    func selectOutputDevice(uid: String) {
        guard let store, uid != activeOutputUID else { return }
        NSLog("Manual device switch to %@", uid as NSString)
        stop()
        // Temporarily override preferred by setting the UID before start
        manualOutputUID = uid
        start(store: store)
        manualOutputUID = nil
    }

    func setup(store: EQStore) {
        self.store = store

        if findDeviceByUID(blackHoleUID) == nil {
            NSLog("BlackHole not found, attempting install")
            DriverInstaller.installIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let store = self.store, store.isEnabled else { return }
                self.start(store: store)
            }
            return
        }

        if store.isEnabled {
            start(store: store)
        }
    }

    func start(store: EQStore) {
        guard !isRunning else { return }

        guard let bhDeviceID = findDeviceByUID(blackHoleUID) else {
            NSLog("BlackHole 2ch not found")
            return
        }
        blackHoleDeviceID = bhDeviceID

        // Determine output device: manual > BT > built-in > fallback
        let realID: AudioDeviceID
        if let uid = manualOutputUID, let found = findDeviceByUID(uid), getOutputChannelCount(found) > 0 {
            realID = found
        } else if let preferred = findPreferredOutputDevice() {
            realID = preferred
        } else if let cd = getDefaultOutputDevice(), getDeviceUID(cd) != blackHoleUID, getDeviceUID(cd) != aggregateUID {
            realID = cd
        } else {
            NSLog("No real output device found")
            return
        }
        activeOutputUID = getDeviceUID(realID)
        realOutputDeviceID = realID
        NSLog("BlackHole=%d, Output=%d", bhDeviceID, realID)

        // Match sample rates
        let outputRate = getDeviceSampleRate(realID)
        let bhRate = getDeviceSampleRate(bhDeviceID)
        if outputRate > 0 && bhRate != outputRate {
            setDeviceSampleRate(bhDeviceID, sampleRate: outputRate)
            NSLog("Matched BlackHole rate to %.0f", outputRate)
            usleep(100_000)
        }
        let sampleRate = outputRate > 0 ? outputRate : 44100

        // Clean up leftover aggregate
        if let existing = findDeviceByUID(aggregateUID) {
            AudioHardwareDestroyAggregateDevice(existing)
        }

        let realUID = getDeviceUID(realID) ?? ""
        guard !realUID.isEmpty else { return }

        // Create aggregate: real output FIRST (its output channels map to 0-1)
        let aggID = createAggregateDevice(outputUID: realUID, inputUID: blackHoleUID)
        guard aggID != 0 else {
            NSLog("Failed to create aggregate device")
            return
        }
        aggregateDeviceID = aggID
        NSLog("Aggregate=%d, outputUID=%@, inputUID=%@", aggID, realUID as NSString, blackHoleUID as NSString)
        NSLog("Aggregate output channels: %d", getOutputChannelCount(aggID))

        // Create AUHAL
        var ioDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let ioComp = AudioComponentFindNext(nil, &ioDesc) else { return }
        var ioRef: AudioUnit?
        guard AudioComponentInstanceNew(ioComp, &ioRef) == noErr, let ioU = ioRef else { return }

        // Enable input on element 1
        var enableIn: UInt32 = 1
        AudioUnitSetProperty(ioU, kAudioOutputUnitProperty_EnableIO,
                              kAudioUnitScope_Input, 1, &enableIn, 4)

        // Set aggregate device
        var devID = aggID
        AudioUnitSetProperty(ioU, kAudioOutputUnitProperty_CurrentDevice,
                              kAudioUnitScope_Global, 0, &devID,
                              UInt32(MemoryLayout<AudioDeviceID>.size))

        // Non-interleaved float stereo format
        var streamFmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(ioU, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Output, 1, &streamFmt, fmtSize)
        AudioUnitSetProperty(ioU, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &streamFmt, fmtSize)

        // Create N-Band EQ
        var eqDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let eqComp = AudioComponentFindNext(nil, &eqDesc) else {
            AudioComponentInstanceDispose(ioU)
            return
        }
        var eqRef: AudioUnit?
        guard AudioComponentInstanceNew(eqComp, &eqRef) == noErr, let eqU = eqRef else {
            AudioComponentInstanceDispose(ioU)
            return
        }

        // Set EQ format
        AudioUnitSetProperty(eqU, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &streamFmt, fmtSize)
        AudioUnitSetProperty(eqU, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Output, 0, &streamFmt, fmtSize)

        // Set number of EQ bands
        var numBands: UInt32 = 10
        AudioUnitSetProperty(eqU, 2200, // kAUNBandEQProperty_NumberOfBands
                              kAudioUnitScope_Global, 0, &numBands, 4)

        // Create render context
        let ctx = RenderContext(ioUnit: ioU, eqUnit: eqU)
        ctx.volume = store.volume
        ctx.balance = store.balance
        self.context = ctx
        let retained = Unmanaged.passRetained(ctx)
        self.contextRetained = retained
        let refCon = retained.toOpaque()

        // EQ input callback: pulls audio from AUHAL input (BlackHole)
        var eqInputCB = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inFrames, ioData) -> OSStatus in
                let ctx = Unmanaged<RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
                return AudioUnitRender(ctx.ioUnit, ioActionFlags, inTimeStamp, 1, inFrames, ioData!)
            },
            inputProcRefCon: refCon
        )
        AudioUnitSetProperty(eqU, kAudioUnitProperty_SetRenderCallback,
                              kAudioUnitScope_Input, 0, &eqInputCB,
                              UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // Output callback: pulls from EQ, applies volume/balance, captures viz
        var outputCB = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inFrames, ioData) -> OSStatus in
                let ctx = Unmanaged<RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()

                // Pull processed audio from EQ
                let status = AudioUnitRender(ctx.eqUnit, ioActionFlags, inTimeStamp, 0, inFrames, ioData!)
                guard status == noErr else { return status }

                let bufs = UnsafeMutableAudioBufferListPointer(ioData!)
                let frames = Int(inFrames)
                let volume = ctx.volume
                let balance = ctx.balance
                // Boost compensates for signal level loss through BlackHole routing
                let boost: Float = 1.5
                let leftGain = volume * min(1.0, 1.0 - balance) * boost
                let rightGain = volume * min(1.0, 1.0 + balance) * boost

                // Apply volume + balance
                if bufs.count >= 1, let left = bufs[0].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frames { left[i] *= leftGain }
                }
                if bufs.count >= 2, let right = bufs[1].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frames { right[i] *= rightGain }
                }

                // Capture visualization (mix L+R)
                if bufs.count >= 1, let left = bufs[0].mData?.assumingMemoryBound(to: Float.self) {
                    let bandCount = 128
                    let bandSize = max(1, frames / bandCount)
                    for b in 0..<bandCount {
                        let start = b * bandSize
                        let end = min(start + bandSize, frames)
                        guard end > start else { ctx.vizLevels[b] = 0; continue }
                        var sum: Float = 0
                        for j in start..<end { sum += abs(left[j]) }
                        let avg = sum / Float(end - start)
                        ctx.vizLevels[b] = min(avg * 9.4, 1.0)
                    }
                    ctx.vizReady = true
                }

                return noErr
            },
            inputProcRefCon: refCon
        )
        AudioUnitSetProperty(ioU, kAudioUnitProperty_SetRenderCallback,
                              kAudioUnitScope_Input, 0, &outputCB,
                              UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // Initialize units
        var s = AudioUnitInitialize(eqU)
        NSLog("EQ init: %d", s)
        s = AudioUnitInitialize(ioU)
        NSLog("AUHAL init: %d", s)

        // Debug: check actual format on AUHAL output
        var actualFmt = AudioStreamBasicDescription()
        var actualSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(ioU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &actualFmt, &actualSize)
        NSLog("AUHAL output format: %.0fHz, %d ch, %d bits", actualFmt.mSampleRate, actualFmt.mChannelsPerFrame, actualFmt.mBitsPerChannel)

        // Configure EQ bands AFTER init (init resets parameters)
        for i in 0..<10 {
            let idx = AudioUnitParameterID(i)
            AudioUnitSetParameter(eqU, 2000 + idx, kAudioUnitScope_Global, 0, 0, 0) // FilterType: parametric
            AudioUnitSetParameter(eqU, 3000 + idx, kAudioUnitScope_Global, 0, eqFrequencies[i], 0)
            AudioUnitSetParameter(eqU, 5000 + idx, kAudioUnitScope_Global, 0, 1.0, 0) // Bandwidth
            AudioUnitSetParameter(eqU, 4000 + idx, kAudioUnitScope_Global, 0, store.bands[i].gain, 0)
            AudioUnitSetParameter(eqU, 1000 + idx, kAudioUnitScope_Global, 0, store.isEnabled ? 0 : 1, 0)
        }

        // Start
        s = AudioOutputUnitStart(ioU)
        NSLog("AUHAL start: %d", s)

        self.ioUnit = ioU
        self.eqUnit = eqU

        // Route system audio to BlackHole
        setDefaultOutputDevice(bhDeviceID)
        NSLog("System output → BlackHole")

        isRunning = true
        installDeviceListener()
        installDeviceListListener()
        startVizTimer()
        refreshOutputDevices()
        NSLog("Engine running")
    }

    func stop() {
        vizTimer?.invalidate()
        vizTimer = nil
        removeDeviceListener()
        removeDeviceListListener()

        if let ioU = ioUnit {
            AudioOutputUnitStop(ioU)
            AudioUnitUninitialize(ioU)
            AudioComponentInstanceDispose(ioU)
        }
        if let eqU = eqUnit {
            AudioUnitUninitialize(eqU)
            AudioComponentInstanceDispose(eqU)
        }
        ioUnit = nil
        eqUnit = nil

        // Release context
        contextRetained?.release()
        contextRetained = nil
        context = nil

        destroyAggregateDevice()
        restoreOriginalOutput()

        isRunning = false
        levels = Array(repeating: 0, count: 128)
        NSLog("Engine stopped")
    }

    func toggleEnabled(_ enabled: Bool) {
        guard let store else { return }
        if enabled {
            if !isRunning {
                start(store: store)
            } else {
                updateEnabled(true)
                updateEQ(bands: store.bands)
            }
        } else {
            if isRunning {
                updateEnabled(false)
            }
        }
    }

    func updateEQ(bands: [EQBand]) {
        guard let eqU = eqUnit else { return }
        for (i, band) in bands.enumerated() where i < 10 {
            AudioUnitSetParameter(eqU, 4000 + AudioUnitParameterID(i),
                                   kAudioUnitScope_Global, 0, band.gain, 0)
        }
    }

    func updateVolume(_ volume: Float) {
        context?.volume = volume
    }

    func updateBalance(_ balance: Float) {
        context?.balance = balance
    }

    func updateEnabled(_ enabled: Bool) {
        guard let eqU = eqUnit else { return }
        for i in 0..<10 {
            AudioUnitSetParameter(eqU, 1000 + AudioUnitParameterID(i),
                                   kAudioUnitScope_Global, 0, enabled ? 0 : 1, 0)
        }
    }

    // MARK: - Visualization

    private func startVizTimer() {
        vizTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let ctx = self.context, ctx.vizReady else { return }
                self.levels = ctx.vizLevels
                ctx.vizReady = false
            }
        }
    }

    // MARK: - Device Change Monitoring

    private func installDeviceListener() {
        guard !defaultOutputListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDeviceChange() }
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        defaultOutputListenerInstalled = true
    }

    private func removeDeviceListener() {
        guard defaultOutputListenerInstalled, let block = defaultOutputListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        defaultOutputListenerBlock = nil
        defaultOutputListenerInstalled = false
    }

    private func installDeviceListListener() {
        guard !deviceListListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Debounce: devices can fire multiple notifications on connect/disconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.handleDeviceListChange()
            }
        }
        deviceListListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        deviceListListenerInstalled = true
    }

    private func removeDeviceListListener() {
        guard deviceListListenerInstalled, let block = deviceListListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        deviceListListenerBlock = nil
        deviceListListenerInstalled = false
    }

    private func handleDeviceListChange() {
        guard isRunning, let store else { return }

        refreshOutputDevices()

        guard let preferred = findPreferredOutputDevice() else { return }
        let preferredUID = getDeviceUID(preferred)

        // No change needed if same device
        if preferredUID == activeOutputUID { return }

        let name = getDeviceName(preferred) ?? "Unknown"
        NSLog("Auto-switching output: %@ → %@", (activeOutputUID ?? "?") as NSString, name as NSString)

        stop()
        start(store: store)
    }

    private func handleDeviceChange() {
        guard isRunning else { return }
        guard let bhID = blackHoleDeviceID else { return }
        guard let newDefault = getDefaultOutputDevice() else { return }
        let newUID = getDeviceUID(newDefault)

        if newUID != blackHoleUID {
            // Something changed default away from BlackHole (monitor plugged in, etc.)
            // Just reclaim it — our aggregate and engine are still valid
            NSLog("Default changed to %@, reclaiming BlackHole", (newUID ?? "?") as NSString)
            setDefaultOutputDevice(bhID)
        }
    }

    // MARK: - Aggregate Device

    private func createAggregateDevice(outputUID: String, inputUID: String) -> AudioDeviceID {
        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Imperator EQ",
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
                [kAudioSubDeviceUIDKey as String: inputUID],
            ],
            kAudioAggregateDeviceMasterSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
        ]
        var deviceID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &deviceID)
        if status != noErr {
            NSLog("CreateAggregateDevice: %d", status)
            return 0
        }
        return deviceID
    }

    private func destroyAggregateDevice() {
        guard aggregateDeviceID != 0 else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = 0
    }

    private func restoreOriginalOutput() {
        if let realID = realOutputDeviceID {
            setDefaultOutputDevice(realID)
            NSLog("Restored output to real device")
        }
    }

    // MARK: - CoreAudio Helpers

    private func findPreferredOutputDevice() -> AudioDeviceID? {
        let knownUIDs: Set<String> = [blackHoleUID, aggregateUID]
        var builtIn: AudioDeviceID?
        var bluetooth: AudioDeviceID?
        var fallback: AudioDeviceID?

        for deviceID in getAllDeviceIDs() {
            guard let uid = getDeviceUID(deviceID), !knownUIDs.contains(uid) else { continue }
            guard getOutputChannelCount(deviceID) > 0 else { continue }

            let transport = getDeviceTransportType(deviceID)
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                if bluetooth == nil { bluetooth = deviceID }
            case kAudioDeviceTransportTypeBuiltIn:
                if builtIn == nil { builtIn = deviceID }
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
                break // Ignore monitors and AirPlay
            default:
                if fallback == nil { fallback = deviceID } // USB DAC, etc.
            }
        }

        let chosen = bluetooth ?? builtIn ?? fallback
        if let chosen {
            let name = getDeviceName(chosen) ?? "Unknown"
            let transport = getDeviceTransportType(chosen)
            NSLog("Preferred output: %@ (transport=0x%08X)", name as NSString, transport)
        }
        return chosen
    }

    private func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transportType)
        return transportType
    }

    private func getAllDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
        ) == noErr else { return [] }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &name) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }

    private func getOutputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &bufSize) == noErr,
              bufSize > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bufSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &bufSize, bufferList) == noErr else { return 0 }
        return (0..<Int(bufferList.pointee.mNumberBuffers)).reduce(0) { total, i in
            total + Int(UnsafeMutableAudioBufferListPointer(bufferList)[i].mNumberChannels)
        }
    }

    private func findDeviceByUID(_ targetUID: String) -> AudioDeviceID? {
        for deviceID in getAllDeviceIDs() {
            if getDeviceUID(deviceID) == targetUID { return deviceID }
        }
        return nil
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var uid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &uid) == noErr else { return nil }
        return uid?.takeUnretainedValue() as String?
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr ? deviceID : nil
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sysAddr, 0, nil, size, &id)
    }

    private func getDeviceSampleRate(_ deviceID: AudioDeviceID) -> Float64 {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    private func setDeviceSampleRate(_ deviceID: AudioDeviceID, sampleRate: Float64) {
        var rate = sampleRate
        let size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &rate)
    }
}
