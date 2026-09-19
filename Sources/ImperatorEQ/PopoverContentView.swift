import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let imperatorPopoverResize = Notification.Name("imperatorPopoverResize")
}

struct PopoverContentView: View {
    @EnvironmentObject var store: EQStore
    @EnvironmentObject var engine: AudioEngine
    let quitAction: () -> Void
    let dismissAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    outputDeviceSection
                    volumeSection
                    balanceSection
                    eqSection
                    presetSection
                }
                .padding(16)
            }
            Divider()
            footerView
        }
        .frame(width: 340)
        .background(.black.opacity(0.15))
        .onChange(of: store.presetsExpanded) { _ in postResizeNotification() }
        .onChange(of: store.outputDevicesExpanded) { _ in postResizeNotification() }
    }

    private func postResizeNotification() {
        var extra: CGFloat = 0
        if store.presetsExpanded {
            extra += CGFloat(store.presets.count) * 28 + 40
        }
        if store.outputDevicesExpanded {
            extra += CGFloat(engine.availableOutputDevices.count) * 28 + 8
        }
        NotificationCenter.default.post(name: .imperatorPopoverResize, object: nil, userInfo: ["extra": extra])
    }

    /// Drawn once. The header is rebuilt on every state change and the glyph
    /// never varies.
    private static let headerIcon = StatusItemIcon.make(size: 16)

    private var headerView: some View {
        HStack(alignment: .center, spacing: 6) {
            // Brandbook 16.1 keeps the sigil out of the header; this is the
            // app's own icon, the same glyph the menu bar item draws.
            Image(nsImage: PopoverContentView.headerIcon)
                .renderingMode(.template)
                .foregroundStyle(.primary)

            Text("Imperator EQ")
                .font(.headline)

            Spacer()

            Toggle("", isOn: $store.isEnabled)
                .toggleStyle(.switch)
                .scaleEffect(0.55)
                .tint(AppColors.brand)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EQUALIZER")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                HoverButton(action: { store.resetBands() }) {
                    Text("Reset")
                        .font(.caption)
                }
            }

            EQBandsView(bands: $store.bands, isEnabled: store.isEnabled)
                .frame(height: 180)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VOLUME BOOST")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(store.volume * 100))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                EQSlider(value: $store.volume, range: 0...2, snapToCenter: true)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            }
        }
    }

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BALANCE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(balanceLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Text("L")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                EQSlider(value: $store.balance, range: -1...1, centerNotch: true, snapToCenter: true)

                Text("R")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            }
        }
    }

    private var balanceLabel: String {
        if abs(store.balance) < 0.05 {
            return "Center"
        } else if store.balance < 0 {
            return "L \(Int(abs(store.balance) * 100))%"
        } else {
            return "R \(Int(store.balance * 100))%"
        }
    }

    private var presetSection: some View {
        PresetManagerView()
    }

    private var outputDeviceSection: some View {
        OutputDeviceView()
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            LaunchAtLoginToggle()

            Spacer()

            // The popover is .transient, so a click inside it does not close
            // it. Without the dismiss the About panel opens behind the popover.
            HoverButton {
                dismissAction()
                AboutPanel.show()
            } label: {
                Text("About")
                    .font(.caption)
            }
            .help("About Imperator EQ")

            HoverButton(action: quitAction) {
                Text("Quit")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Open at Login")
                .font(.caption)
                .foregroundStyle(.primary)
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .scaleEffect(0.55)
                .tint(AppColors.brand)
                .labelsHidden()
                // The two-parameter onChange is macOS 14, and this app still
                // deploys to 13, so the deprecated one-parameter form stays.
                .onChange(of: isEnabled) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        isEnabled = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .opacity(isHovered ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .opacity(isHovered ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
