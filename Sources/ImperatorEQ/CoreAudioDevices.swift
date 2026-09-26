import CoreAudio
import Foundation

/// Typed wrappers over the AudioObject property API, shared by the engine and
/// the output device list.
///
/// These are plain property reads and writes. None of them starts IO, so none
/// of them waits on a permission decision, and they are safe on the main
/// thread. Anything that creates a tap, an aggregate device or an IOProc lives
/// in `TapPipeline` and runs on the engine's own queue.
enum CoreAudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size property read straight into its type: `UInt32`, `Float64`,
    /// `AudioStreamBasicDescription`.
    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                          as _: T.Type = T.self) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer -> T? in
            guard let pointer = buffer.baseAddress,
                  AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr,
                  size == MemoryLayout<T>.size else { return nil }
            return pointer.pointee
        }
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope: scope)
        var value = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// A CFString property. The HAL returns these at +1, so the value is taken
    /// retained; taking it unretained leaks one string per call.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    static var allDevices: [AudioDeviceID] { objectIDs(system, kAudioHardwarePropertyDevices) }

    static func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    static func name(_ device: AudioDeviceID) -> String? { string(device, kAudioObjectPropertyName) }

    static func streams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope)
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func streamFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        value(stream, kAudioStreamPropertyVirtualFormat)
    }

    /// Channels in the device's first stream in `scope`, the stream a device
    /// tap is taken from.
    static func firstStreamChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int? {
        streams(device, scope: scope).first.flatMap(streamFormat).map { Int($0.mChannelsPerFrame) }
    }

    static func isHidden(_ device: AudioDeviceID) -> Bool {
        (value(device, kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) != 0
    }

    /// Whether the device may be the default output, which is what the output
    /// list offers. `systemSounds` asks the same for alerts and sound effects.
    static func canBeDefaultOutput(_ device: AudioDeviceID, systemSounds: Bool = false) -> Bool {
        let selector = systemSounds ? kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
                                    : kAudioDevicePropertyDeviceCanBeDefaultDevice
        return (value(device, selector, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self) ?? 0) != 0
    }

    static var defaultOutputDevice: AudioDeviceID? {
        let id = value(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioDeviceID.self)
        return id == AudioDeviceID(kAudioObjectUnknown) ? nil : id
    }

    /// Makes `device` the default output the way macOS's own output pickers do.
    /// With Sound settings playing sound effects through the selected output
    /// device, they move the alert device along; the HAL does not do that by
    /// itself, so it is done here too.
    @discardableResult
    static func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        guard set(system, kAudioHardwarePropertyDefaultOutputDevice, device) else { return false }
        if alertsFollowDefaultOutput, canBeDefaultOutput(device, systemSounds: true) {
            set(system, kAudioHardwarePropertyDefaultSystemOutputDevice, device)
        }
        return true
    }

    /// "Play sound effects through: Selected sound output device", stored per
    /// host. A Mac where it was never changed has no value, which is that same
    /// default.
    private static var alertsFollowDefaultOutput: Bool {
        let value = CFPreferencesCopyValue("AlertsUseMainDevice" as CFString, "com.apple.soundpref" as CFString,
                                           kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return (value as? NSNumber)?.boolValue ?? true
    }

    /// Lets the Mac idle-sleep while this process runs IO. Without it coreaudiod
    /// holds a sleep assertion for as long as the EQ is on, silence included, so
    /// a MacBook left idle never sleeps. It covers this process only: an app that
    /// is playing keeps its own assertion, and the Mac stays awake while it plays.
    static func allowIdleSleepDuringIO() {
        if !set(system, kAudioHardwarePropertySleepingIsAllowed, UInt32(1)) {
            engineLog.error("could not allow idle sleep during IO")
        }
    }

    /// The HAL's process object for a PID, or nil when the HAL does not know the
    /// process. The lookup returns `kAudioObjectUnknown` rather than an error for
    /// an unknown PID, so that value is mapped to nil here: excluding
    /// `kAudioObjectUnknown` from a tap excludes nothing.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object)
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }
}

/// A HAL property listener that can be removed again.
///
/// The block API matches a remove call to its add call by block pointer, and
/// Swift wraps a closure in a new block at every call, so removing with the same
/// closure removes nothing: measured, five add and remove rounds left five blocks
/// firing on one change. The function-pointer API matches on the function and
/// its context pointer, which stay the same, so this uses that one.
///
/// Listens from `init` until `cancel()`, and keeps itself alive in between.
final class PropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private let addresses: [AudioObjectPropertyAddress]
    fileprivate let queue: DispatchQueue
    fileprivate let handler: @Sendable () -> Void
    private var context: Unmanaged<PropertyListener>?

    /// `handler` runs on `queue` after any of `addresses` changes on `object`.
    init(object: AudioObjectID, addresses: [AudioObjectPropertyAddress], queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.addresses = addresses
        self.queue = queue
        self.handler = handler
        let context = Unmanaged.passRetained(self)
        self.context = context
        for var addr in addresses {
            AudioObjectAddPropertyListener(object, &addr, propertyListenerProc, context.toOpaque())
        }
    }

    /// Call on `queue`. A notification the HAL is delivering on its own thread
    /// at this moment still needs the context, so it is freed a second later
    /// rather than at once.
    func cancel() {
        guard let context else { return }
        self.context = nil
        for var addr in addresses {
            AudioObjectRemovePropertyListener(object, &addr, propertyListenerProc, context.toOpaque())
        }
        queue.asyncAfter(deadline: .now() + 1) { context.release() }
    }
}

private let propertyListenerProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let listener = Unmanaged<PropertyListener>.fromOpaque(clientData).takeUnretainedValue()
    listener.queue.async(execute: listener.handler)
    return noErr
}
