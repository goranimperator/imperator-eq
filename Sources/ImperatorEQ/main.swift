import AppKit

// Brandbook and engine gates rather than features: each runs, measures, and
// exits. Nothing else in the app starts.
if CommandLine.arguments.contains("--about-check") {
    exit(MainActor.assumeIsolated { AboutCheck.run() })
}
if CommandLine.arguments.contains("--engine-check") {
    exit(EngineCheck.run(CommandLine.arguments))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
