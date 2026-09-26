import Foundation

/// The permission macOS asks for before a process tap may read other apps'
/// audio: "System Audio Recording Only" under Privacy & Security, TCC service
/// `kTCCServiceAudioCapture`, explained to the user by the Info.plist key
/// `NSAudioCaptureUsageDescription`.
///
/// There is no public API to read or request it. The system prompts when a tap
/// is first read, and a denied tap reads silence. That is not enough here: a
/// tap that mutes the apps it captures and then reads silence would leave the
/// Mac mute. So the state is read through TCC's own preflight and request
/// calls, looked up at runtime. If they ever disappear the status is
/// `.unknown`, and the engine falls back to starting and letting the system
/// prompt, which is what every tap-based app without this lookup does.
enum SystemAudioAccess {
    enum Status: Equatable {
        case authorized
        case denied
        case notDetermined
        /// The TCC lookup is unavailable on this system.
        case unknown
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?,
                                                         @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFunction? = tcc
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFunction.self) }

    private static let request: RequestFunction? = tcc
        .flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFunction.self) }

    static func status() -> Status {
        guard let preflight else { return .unknown }
        // 0 granted, 1 denied, anything else not yet asked.
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt. The completion runs on an arbitrary queue.
    /// Without the TCC lookup there is nothing to ask through, and the
    /// completion reports false so the caller keeps its current state.
    static func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let request else {
            completion(false)
            return
        }
        request(service, nil) { granted in completion(granted) }
    }

    /// The System Settings pane that holds the switch.
    static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
