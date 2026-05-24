import CoreAudio
import AudioToolbox

enum SystemAudio {
    static func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    static func getVolume() -> Float {
        guard let deviceID = getDefaultOutputDeviceID() else { return 1.0 }

        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    static func setVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDeviceID() else { return }

        var vol = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
    }

    static func getBalance() -> Float {
        guard let deviceID = getDefaultOutputDeviceID() else { return 0.0 }

        var balanceLeft: Float32 = 1.0
        var balanceRight: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)

        var addressLeft = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )

        var addressRight = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 2
        )

        AudioObjectGetPropertyData(deviceID, &addressLeft, 0, nil, &size, &balanceLeft)
        AudioObjectGetPropertyData(deviceID, &addressRight, 0, nil, &size, &balanceRight)

        if balanceLeft >= balanceRight {
            return balanceRight > 0 ? -(1.0 - balanceRight / balanceLeft) : -1.0
        } else {
            return balanceLeft > 0 ? (1.0 - balanceLeft / balanceRight) : 1.0
        }
    }

    static func setBalance(_ balance: Float) {
        guard let deviceID = getDefaultOutputDeviceID() else { return }

        let clamped = max(-1, min(1, balance))
        var leftVol: Float32 = clamped < 0 ? 1.0 : 1.0 - clamped
        var rightVol: Float32 = clamped > 0 ? 1.0 : 1.0 + clamped

        let size = UInt32(MemoryLayout<Float32>.size)

        var addressLeft = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )

        var addressRight = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 2
        )

        AudioObjectSetPropertyData(deviceID, &addressLeft, 0, nil, size, &leftVol)
        AudioObjectSetPropertyData(deviceID, &addressRight, 0, nil, size, &rightVol)
    }
}
