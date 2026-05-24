import AVFoundation
import CoreAudio

@MainActor
final class AudioEngine: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0.0, count: 32)
    @Published var isRunning = false

    private var engine: AVAudioEngine?
    private var eqNode: AVAudioUnitEQ?
    private var originalOutputDeviceID: AudioDeviceID?
    private var blackHoleDeviceID: AudioDeviceID?

    private let blackHoleUID = "BlackHole2ch_UID"
    private let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private weak var store: EQStore?

    func setup(store: EQStore) {
        self.store = store

        if findDeviceByUID(blackHoleUID) == nil {
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
            print("BlackHole 2ch not found")
            return
        }
        blackHoleDeviceID = bhDeviceID

        let currentDefault = getDefaultOutputDevice()
        if currentDefault != bhDeviceID {
            originalOutputDeviceID = currentDefault
        }
        guard let realOutputID = originalOutputDeviceID else { return }

        let engine = AVAudioEngine()

        let eq = AVAudioUnitEQ(numberOfBands: 10)
        self.eqNode = eq
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = eqFrequencies[i]
            band.bandwidth = 1.0
            band.gain = store.bands[i].gain
            band.bypass = !store.isEnabled
        }
        engine.attach(eq)

        if let inputAU = engine.inputNode.audioUnit {
            var devID = bhDeviceID
            AudioUnitSetProperty(inputAU,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &devID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        if let outputAU = engine.outputNode.audioUnit {
            var devID = realOutputID
            AudioUnitSetProperty(outputAU,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &devID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        engine.connect(engine.inputNode, to: eq, format: inputFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: inputFormat)

        engine.mainMixerNode.outputVolume = store.volume
        engine.mainMixerNode.pan = store.balance

        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            isRunning = true
            setDefaultOutputDevice(bhDeviceID)
        } catch {
            print("Audio engine start failed: \(error)")
            restoreOriginalOutput()
        }
    }

    func stop() {
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        eqNode = nil
        isRunning = false
        levels = Array(repeating: 0.0, count: 32)
        restoreOriginalOutput()
    }

    func toggleEnabled(_ enabled: Bool) {
        guard let store else { return }
        if enabled {
            if !isRunning {
                start(store: store)
            } else {
                updateEnabled(true)
            }
        } else {
            stop()
        }
    }

    func updateEQ(bands: [EQBand]) {
        guard let eq = eqNode else { return }
        for (i, band) in bands.enumerated() where i < eq.bands.count {
            eq.bands[i].gain = band.gain
        }
    }

    func updateVolume(_ volume: Float) {
        engine?.mainMixerNode.outputVolume = volume
    }

    func updateBalance(_ balance: Float) {
        engine?.mainMixerNode.pan = balance
    }

    func updateEnabled(_ enabled: Bool) {
        guard let eq = eqNode else { return }
        for band in eq.bands {
            band.bypass = !enabled
        }
    }

    private func restoreOriginalOutput() {
        if let original = originalOutputDeviceID {
            setDefaultOutputDevice(original)
            originalOutputDeviceID = nil
        }
    }

    // MARK: - CoreAudio Device Helpers

    private func findDeviceByUID(_ targetUID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize
        ) == noErr else { return nil }

        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            if getDeviceUID(deviceID) == targetUID {
                return deviceID
            }
        }
        return nil
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanagedUID: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &unmanagedUID) == noErr else {
            return nil
        }
        return unmanagedUID?.takeUnretainedValue() as String?
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        )

        var sysAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &sysAddress, 0, nil, size, &id
        )
    }

    // MARK: - Visualization

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        let bandCount = 32
        let bandSize = max(1, frameCount / bandCount)
        var newLevels = [Float](repeating: 0.0, count: bandCount)

        for i in 0..<bandCount {
            let start = i * bandSize
            let end = min(start + bandSize, frameCount)
            guard end > start else { continue }
            var sum: Float = 0
            for j in start..<end {
                sum += abs(data[j])
            }
            newLevels[i] = min(sum / Float(end - start) * 5.0, 1.0)
        }

        Task { @MainActor in
            self.levels = newLevels
        }
    }
}
