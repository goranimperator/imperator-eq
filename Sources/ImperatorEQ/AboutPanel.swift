import AppKit
import SwiftUI

/// Brandbook 10.2: a standalone NSPanel, not a sheet and not a second popover.
@MainActor
enum AboutPanel {
    /// Brandbook 10.2: 300 x 260.
    static let width: CGFloat = 300
    static let specifiedHeight: CGFloat = 260

    private static var panel: NSPanel?

    /// Builds the panel without showing it, so `--about-check` can measure the
    /// real thing rather than the constants it was built from.
    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: specifiedHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // An NSPanel hides itself when its app deactivates, and this is an
        // LSUIElement app that goes inactive on the first click elsewhere.
        // Left at the default the panel would vanish behind that click.
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = NSHostingController(rootView: AboutView())
        // Setting contentViewController resizes the window to the hosted view's
        // fitting size, and a SwiftUI view that has not laid out yet reports
        // zero, which would throw away the contentRect above. Lay it out first,
        // then take whichever is larger so the website line can never be
        // clipped.
        if let hosted = panel.contentViewController?.view {
            hosted.layoutSubtreeIfNeeded()
            panel.setContentSize(NSSize(width: width,
                                        height: max(specifiedHeight, hosted.fittingSize.height)))
        } else {
            panel.setContentSize(NSSize(width: width, height: specifiedHeight))
        }
        return panel
    }

    static func show() {
        if let existing = panel, existing.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = makePanel()
        panel.center()
        // Ordering front is not enough from an LSUIElement app: without the
        // activation the panel is created behind whatever the user was in.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

/// Brandbook 10.3, in its order: icon, name, version, copyright, website.
struct AboutView: View {
    @State private var isLinkHovered = false

    /// Read from the bundle, so the panel cannot claim a version the build
    /// does not carry.
    static func versionText(from bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (Build \(build))"
    }

    /// Brandbook 10.4: the end year is stamped at launch, because a plist
    /// cannot hold a value that moves.
    static func copyrightText(year: Int = Calendar.current.component(.year, from: Date())) -> String {
        "© 1986-\(year) Goran Imperator"
    }

    static let websiteURL = URL(string: "https://www.goranimperator.com")!

    static var iconImage: NSImage {
        if let named = NSImage(named: "AppIcon") { return named }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let fromFile = NSImage(contentsOf: url) {
            return fromFile
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: AboutView.iconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            Text("Imperator EQ")
                .font(.headline)

            Text(AboutView.versionText())
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(AboutView.copyrightText())
                .font(.caption)
                .foregroundStyle(.tertiary)

            // A Button rather than a Text with a tap gesture: a tap gesture is
            // reachable by the mouse alone, and this is the one link in the app.
            Button {
                NSWorkspace.shared.open(AboutView.websiteURL)
            } label: {
                Text("goranimperator.com")
                    .font(.caption)
                    .foregroundStyle(AppColors.brand)
                    .underline(isLinkHovered)
            }
            .buttonStyle(.plain)
            .onHover { isLinkHovered = $0 }
            .cursor(.pointingHand)
            .help("Open goranimperator.com")
        }
        .padding(24)
        // Width only. Pinning the height here makes the content report its
        // overflow instead of the spec, and the window grows to match.
        .frame(width: AboutPanel.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}
