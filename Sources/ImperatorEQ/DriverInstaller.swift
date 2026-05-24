import Foundation

enum DriverInstaller {
    static let driverName = "BlackHole2ch.driver"
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath)
    }

    @discardableResult
    static func installIfNeeded() -> Bool {
        if isInstalled { return true }

        guard let sourcePath = driverSourcePath() else {
            print("BlackHole driver not found in app bundle")
            return false
        }

        let script = "do shell script \"cp -R '\(sourcePath)' '/Library/Audio/Plug-Ins/HAL/' && killall coreaudiod 2>/dev/null || true\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]

        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func driverSourcePath() -> String? {
        let bundle = Bundle.main
        let resourcesDir = bundle.bundlePath + "/Contents/Resources/" + driverName
        if FileManager.default.fileExists(atPath: resourcesDir) {
            return resourcesDir
        }
        return nil
    }
}
