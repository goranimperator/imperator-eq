import SwiftUI
import ServiceManagement

struct PopoverContentView: View {
    @EnvironmentObject var store: EQStore
    let quitAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    volumeSection
                    balanceSection
                    eqSection
                    visualizationToggle
                    if store.showVisualization {
                        VisualizationView()
                    }
                    presetSection
                }
                .padding(16)
            }
            Divider()
            footerView
        }
        .frame(width: 380)
        .background(.black.opacity(0.15))
    }

    private var headerView: some View {
        HStack {
            if let nsImage = SigilIcon.headerImage(size: 14) {
                Image(nsImage: nsImage)
            }
            Text("Imperator EQ")
                .font(.headline)

            Spacer()

            Toggle("", isOn: $store.isEnabled)
                .toggleStyle(.switch)
                .tint(Color(red: 0xA0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0))
                .labelsHidden()
                .scaleEffect(0.55)
                .frame(width: 36, height: 20)
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

    private var visualizationToggle: some View {
        HStack {
            Text("Audio Visualization")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: $store.showVisualization)
                .toggleStyle(.switch)
                .tint(Color(red: 0xA0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0))
                .labelsHidden()
                .scaleEffect(0.55)
                .frame(width: 36, height: 20)
        }
    }

    private var presetSection: some View {
        PresetManagerView()
    }

    private var footerView: some View {
        HStack {
            LaunchAtLoginToggle()

            Spacer()

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
    @State private var isEnabled = true
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Open at Login")
                .font(.caption)
                .foregroundStyle(.primary)
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .tint(Color(red: 0xA0 / 255.0, green: 0x18 / 255.0, blue: 0x18 / 255.0))
                .labelsHidden()
                .scaleEffect(0.55)
                .frame(width: 36, height: 20)
        }
        .opacity(isHovered ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear {
            if SMAppService.mainApp.status != .enabled {
                do {
                    try SMAppService.mainApp.register()
                    isEnabled = true
                } catch {
                    isEnabled = false
                }
            }
        }
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
