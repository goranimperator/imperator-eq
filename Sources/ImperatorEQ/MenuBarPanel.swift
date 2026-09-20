import AppKit
import SwiftUI

/// The menu bar panel, drawn by the app rather than by `NSPopover`.
///
/// `NSPopover` draws its own frame and gives no way to set the radius, and
/// neither of the two frames it draws is the one macOS uses in the menu bar. On
/// macOS 27 a binary stamped `sdk 27.0` gets a 26.25 pt squircle, and one
/// stamped `sdk 14.0` gets a 9.5 pt circular corner. The system's own menu bar
/// panel is neither: Control Centre's Wi-Fi panel, captured with
/// `screencapture -o -l` and fitted on its bottom corner, measures 17.50 pt at
/// 309 x 290 drawn points. A plain titled window measures 17.25 by the same
/// method, so a menu bar panel is a window corner rather than a popover one.
///
/// Drawing the surface here is the only way to land on that number.
final class MenuBarPanel: NSPanel {
    /// Set so the panel *draws* the corner macOS draws.
    ///
    /// The target is Control Centre's Wi-Fi panel on macOS 27: captured with
    /// `screencapture -o -l` and fitted on its bottom corner, it measures 35.0
    /// device pixels, 17.50 pt, rms 0.38. A plain titled window measures 17.25
    /// by the same method, so a menu bar panel is a window corner rather than a
    /// popover one: `NSPopover` draws 26.25 pt from a binary stamped
    /// `sdk 27.0` and 9.5 pt from one stamped `sdk 14.0`, and neither is this.
    ///
    /// 18.25 rather than 17.5 because `NSVisualEffectView` blends its edge, so
    /// the drawn corner measures about 0.75 pt tighter than the radius asked
    /// for. Measured both ways on this app's own panel: at 17.5 it drew 16.75,
    /// at 18.25 it draws 17.50, which is the Wi-Fi panel exactly.
    ///
    /// Circular, not `.continuous`. The Wi-Fi panel fits a circle at n=2.2.
    static let cornerRadius: CGFloat = 18.25
    /// Gap between the menu bar and the panel's top edge.
    private static let menuBarGap: CGFloat = 2

    private let host: NSHostingView<AnyView>
    private let container = NSVisualEffectView()
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// The menu bar button this panel hangs off, so a click on it is left to the
    /// button's own action instead of being treated as a click outside.
    private weak var anchor: NSStatusBarButton?
    /// Called when the panel closes itself, so the owner can drop its reference
    /// to the monitors and keep the menu bar button's pressed state honest.
    var onClose: (() -> Void)?

    /// The height the panel opens at, when the app computes it itself.
    ///
    /// SwiftUI's fitting size is right for most content and a point short for
    /// some: a list whose rows are laid out by hand knows its own height, and a
    /// panel that opens a point short opens clipped. Left unset, the fitting
    /// size decides.
    var contentHeight: (() -> CGFloat)?

    /// Asked before an outside click closes the panel.
    ///
    /// A panel that owns a window of its own has to be able to say so. The
    /// clock's colour wheel is an `NSColorPanel`, a separate window: every
    /// click in it is a click outside this panel, and closing on it would leave
    /// the wheel pointing at a dead binding and drop the colour.
    var shouldCloseOnOutsideClick: () -> Bool = { true }

    init<Content: View>(content: Content, width: CGFloat) {
        host = NSHostingView(rootView: AnyView(content))
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)

        // Brandbook 20.3, minus the always-on-top behaviour: this panel is
        // transient, so it closes on the first click elsewhere rather than
        // living above other apps.
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false

        // The surface is the system's own popover material, not a colour copied
        // out of a screenshot: `NSVisualEffectView` with `.popover` blends what
        // is behind the panel exactly the way AppKit does for a real one, and it
        // tracks appearance and accessibility settings for free. The SwiftUI
        // content then lays brandbook 6.1's `.black.opacity(0.15)` over it.
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        // No arrow, and therefore no mask path to build: macOS 27 does not put
        // one on its own menu bar panels. Control Centre's Wi-Fi panel is a
        // plain rounded rectangle under the item, so this is a layer corner on
        // the effect view and nothing more.
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .circular
        container.layer?.masksToBounds = true

        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    var isShown: Bool { isVisible }

    /// Show under the menu bar button, with the arrow pointing at it.
    func show(from button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchor = button

        let height = contentHeight?() ?? host.fittingSize.height
        setContentSize(NSSize(width: frame.width, height: height))

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = buttonFrame.midX - frame.width / 2
        // Keep the whole panel on screen when the item sits near an edge, the
        // way the system's own panels slide rather than hang off.
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - frame.width - 8)
        }
        setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - Self.menuBarGap))

        // No animation, on purpose. macOS 27 puts its own menu bar panels up
        // and takes them down instantly: Control Centre's Wi-Fi panel appears
        // fully formed under the item. A fade or a scale here would be the one
        // thing marking these apps as not part of the system.
        orderFrontRegardless()
        startMonitoring()
    }

    func close(_ sender: Any? = nil) {
        stopMonitoring()
        orderOut(nil)
        onClose?()
    }

    private func startMonitoring() {
        stopMonitoring()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            guard self.shouldCloseOnOutsideClick() else { return }
            let pointer = NSEvent.mouseLocation
            // The status item's own click is the toggle. Closing here too would
            // race the button's action, which then reopens what it just closed.
            if let window = self.anchor?.window,
               window.frame.contains(pointer) { return }
            // A global monitor is meant to see only other applications, but the
            // first click into an inactive accessory app reaches it as well, so
            // it arrives before the control under the cursor gets it and closes
            // the panel out from under the click. Outside is decided by where
            // the pointer is, not by which monitor saw the event.
            if self.frame.contains(pointer) { return }
            self.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.close()
            return nil
        }
    }

    private func stopMonitoring() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    // A borderless panel refuses key status by default, which would leave the
    // SwiftUI content unable to take the Escape key or drive its controls.
    override var canBecomeKey: Bool { true }

    deinit { stopMonitoring() }
}
