import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eqStore: EQStore!
    private var audioEngine: AudioEngine!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private let popoverHeight: CGFloat = 495

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.set(0, forKey: "AppleAccentColor")
        ProcessInfo.processInfo.setValue("Imperator EQ", forKey: "processName")

        eqStore = EQStore()
        audioEngine = AudioEngine()
        setupStatusItem()
        setupPopover()
        setupAudioBindings()

        audioEngine.setup(store: eqStore)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eqStore.saveState()
        audioEngine.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = StatusItemIcon.make()
        button.toolTip = "Imperator EQ"
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: popoverHeight)
        popover.behavior = .transient
        popover.animates = true

        let quitAction = { [weak self] in
            self?.audioEngine.stop()
            NSApplication.shared.terminate(nil)
        }

        let dismissAction: () -> Void = { [weak self] in
            self?.closePopover()
        }

        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(quitAction: quitAction, dismissAction: dismissAction)
                .environmentObject(eqStore)
                .environmentObject(audioEngine)
        )

    }

    private func setupAudioBindings() {
        eqStore.$bands
            .dropFirst()
            .sink { [weak self] bands in
                self?.audioEngine.updateEQ(bands: bands)
            }
            .store(in: &cancellables)

        eqStore.$volume
            .dropFirst()
            .sink { [weak self] volume in
                self?.audioEngine.updateVolume(volume)
            }
            .store(in: &cancellables)

        eqStore.$balance
            .dropFirst()
            .sink { [weak self] balance in
                self?.audioEngine.updateBalance(balance)
            }
            .store(in: &cancellables)

        eqStore.$isEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.audioEngine.toggleEnabled(enabled)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: .imperatorPopoverResize, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let extra = note.userInfo?["extra"] as? CGFloat else { return }
                self.popover.contentSize = NSSize(width: 340, height: self.popoverHeight + extra)
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}
