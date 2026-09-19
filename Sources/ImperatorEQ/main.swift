import AppKit

// A brandbook gate rather than a feature: it builds the About panel, measures
// it, and exits. Nothing else in the app runs.
if CommandLine.arguments.contains("--about-check") {
    exit(MainActor.assumeIsolated { AboutCheck.run() })
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
