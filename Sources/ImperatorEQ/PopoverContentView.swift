import SwiftUI
import ServiceManagement

struct PopoverContentView: View {
    @EnvironmentObject var store: EQStore
    @EnvironmentObject var engine: AudioEngine
    let quitAction: () -> Void
    let dismissAction: () -> Void

    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            VStack(spacing: 16) {
                engineNotice
                OutputDeviceView()
                volumeSection
                balanceSection
                eqSection
                PresetManagerView()
            }
            .padding(16)
            Divider()
            footerView
        }
        .frame(width: PopoverContentView.width)
        // No scroll view and no height cap: the panel is exactly as tall as
        // what is in it, so expanding a section grows the window instead of
        // scrolling inside a fixed box.
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColors.popoverBackground)
    }

    /// Drawn once. The header is rebuilt on every state change and the glyph
    /// never varies.
    private static let headerIcon = StatusItemIcon.make(size: 16)

    private var headerView: some View {
        HStack(alignment: .center, spacing: 8) {
            // Brandbook 16.1 keeps the sigil out of the header; this is the
            // app's own icon, the same glyph the menu bar item draws.
            Image(nsImage: PopoverContentView.headerIcon)
                .renderingMode(.template)
                .foregroundStyle(.primary)

            Text("Imperator EQ")
                .font(.headline)

            Spacer()

            Toggle("", isOn: $store.isEnabled)
                .brandSwitch()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Shown only when the switch is on but the EQ is not processing, so the
    /// switch never claims something the engine is not doing. Nothing shows
    /// while starting: that takes a fraction of a second.
    ///
    /// Text is `.primary` and `.secondary`, not brand red: red measures 1.73:1
    /// on this panel, below the 4.5:1 caption text needs. The action is a
    /// system bordered button, the brandbook 7.11 action, because a resting
    /// HoverButton measures 3.35:1.
    @ViewBuilder
    private var engineNotice: some View {
        switch engine.state {
        case .waitingForAccess:
            // The settings button too: the prompt shows once, and access that
            // is reset while the app runs has no prompt on screen.
            notice(title: "Waiting for your permission",
                   body: "Allow Imperator EQ in the macOS prompt, or in Privacy Settings if no prompt "
                       + "is showing. The EQ starts as soon as you do.",
                   opensSettings: true)
        case .accessDenied:
            notice(title: "System audio access is off",
                   body: "Imperator EQ needs it to hear what your Mac plays. It records nothing, "
                       + "and your sound plays as normal until you turn it on.",
                   opensSettings: true)
        case .failed(let deviceName):
            notice(title: "The EQ can\u{2019}t run on \(deviceName)",
                   body: "Your sound plays as normal on it. Choose another output to use the EQ.",
                   opensSettings: false)
        case .off, .starting, .running:
            EmptyView()
        }
    }

    private func notice(title: String, body: String, opensSettings: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if opensSettings {
                Button("Open Privacy Settings") { engine.openAccessSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("EQUALIZER")

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
        sliderSection("VOLUME BOOST", value: "\(Int(store.volume * 100))%", $store.volume, in: 0...2) {
            Image(systemName: "speaker.fill")
        } trailing: {
            Image(systemName: "speaker.wave.3.fill")
        }
    }

    private var balanceSection: some View {
        sliderSection("BALANCE", value: balanceLabel, $store.balance, in: -1...1) {
            Text("L")
        } trailing: {
            Text("R")
        }
    }

    /// A title with its value on the right, over a slider with a small label
    /// at each end: volume and balance.
    private func sliderSection<Leading: View, Trailing: View>(
        _ title: String, value: String, _ binding: Binding<Float>, in range: ClosedRange<Float>,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title)
                Spacer()
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                leading()
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                EQSlider(value: binding, range: range, snapToCenter: true)

                trailing()
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

    private var footerView: some View {
        HStack(spacing: 12) {
            LaunchAtLoginToggle()

            Spacer()

            // The panel sits at the pop-up menu level, above ordinary windows,
            // so it closes first or the About panel would open behind it.
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

    var body: some View {
        HStack(spacing: 6) {
            Text("Open at Login")
                .font(.caption)
                .foregroundStyle(.primary)
            Toggle("", isOn: $isEnabled)
                .brandSwitch()
                .onChange(of: isEnabled) { _, newValue in
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
        .hoverDimmed()
    }
}

struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .hoverDimmed()
    }
}

// MARK: - Shared pieces of the panel

/// The small title each section of the panel starts with.
struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// A section title that opens and closes the rows under it.
struct CollapsibleHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack {
                SectionTitle(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The dot that marks the active output or preset.
struct ActiveDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? AppColors.brand : Color.gray.opacity(0.3))
            .frame(width: 8, height: 8)
    }
}

/// Full opacity under the pointer, 45% at rest.
private struct HoverDimmed: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .opacity(isHovered ? 1.0 : 0.45)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Brandbook 7.2's switch: the system switch scaled to 0.55, brand tint, no
    /// label, and no frame, since a frame would only add invisible padding.
    func brandSwitch() -> some View {
        toggleStyle(.switch)
            .scaleEffect(0.55)
            .tint(AppColors.brand)
            .labelsHidden()
    }

    func hoverDimmed() -> some View {
        modifier(HoverDimmed())
    }

    /// A row in the output or preset list: its padding, the brand wash under
    /// the pointer, and a tap anywhere on it.
    func listRow(isHovered: Binding<Bool>, onTap: @escaping () -> Void) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered.wrappedValue ? AppColors.brand.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { isHovered.wrappedValue = $0 }
    }
}
