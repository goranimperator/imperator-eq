import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var eqStore: EQStore!
    private var audioEngine: AudioEngine!
    private var cancellables = Set<AnyCancellable>()


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

        // The click-outside dismissal lives in MenuBarPanel now, which owns
        // the same monitor plus the exception for the status item's own click.
        // This one closed the panel on that click too and raced the toggle.
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
        let quitAction = { [weak self] in
            self?.audioEngine.stop()
            NSApplication.shared.terminate(nil)
        }

        let dismissAction: () -> Void = { [weak self] in
            self?.closePopover()
        }

        // A MenuBarPanel rather than an NSPopover. macOS 27 draws its own menu
        // bar panels as plain rounded rectangles: a 17.50 pt corner, no arrow
        // and no animation, measured off Control Centre's Wi-Fi panel. An
        // NSPopover draws none of that and exposes none of it for adjustment.
        panel = MenuBarPanel(
            content: PopoverContentView(quitAction: quitAction, dismissAction: dismissAction)
                .environmentObject(eqStore)
                .environmentObject(audioEngine),
            width: PopoverContentView.width
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
    }

    @objc private func togglePopover() {
        if panel.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        panel.show(from: button)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        guard panel.isShown else { return }
        panel.close()
    }
}
