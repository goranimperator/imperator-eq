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
        setupPanel()
        setupAudioBindings()

        audioEngine.setup(store: eqStore)
    }

    func applicationWillTerminate(_ notification: Notification) {
        eqStore.saveState()
        audioEngine.shutdown()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = StatusItemIcon.make()
        button.toolTip = "Imperator EQ"
        button.action = #selector(togglePanel)
        button.target = self
    }

    private func setupPanel() {
        // applicationWillTerminate stops the engine on the way out.
        let quitAction = {
            NSApplication.shared.terminate(nil)
        }

        let dismissAction: () -> Void = { [weak self] in
            self?.closePanel()
        }

        // A MenuBarPanel rather than an NSPopover: see MenuBarPanel.swift.
        panel = MenuBarPanel(
            content: PopoverContentView(quitAction: quitAction, dismissAction: dismissAction)
                .environmentObject(eqStore)
                .environmentObject(audioEngine),
            width: PopoverContentView.width
        )
    }

    private func setupAudioBindings() {
        // @Published fires in willSet, while the store still holds the old
        // values, so the new ones come from the publishers and go straight to
        // the engine. No hop through RunLoop.main: its default mode does not
        // run while a slider is dragged, and the sound would change only on
        // mouse-up.
        Publishers.CombineLatest3(eqStore.$bands, eqStore.$volume, eqStore.$balance)
            .dropFirst()
            .sink { [weak self] bands, volume, balance in
                self?.audioEngine.settingsChanged(EQSettings(bands: bands, volume: volume, balance: balance))
            }
            .store(in: &cancellables)

        // reconcile() reads the store, so it waits for the change to land. The
        // main queue is served while a control tracks the mouse.
        eqStore.$isEnabled
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.audioEngine.reconcile() }
            .store(in: &cancellables)
    }

    @objc private func togglePanel() {
        if panel.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        audioEngine.panelOpened()
        panel.show(from: button)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePanel() {
        guard panel.isShown else { return }
        panel.close()
    }
}
