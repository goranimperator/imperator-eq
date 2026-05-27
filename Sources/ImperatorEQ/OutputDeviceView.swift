import SwiftUI

struct OutputDeviceView: View {
    @EnvironmentObject var engine: AudioEngine

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Text("OUTPUT DEVICE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !isExpanded, let name = activeDeviceName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(engine.availableOutputDevices) { device in
                        DeviceRowView(
                            name: device.name,
                            isActive: device.uid == engine.activeOutputUID,
                            onSelect: { engine.selectOutputDevice(uid: device.uid) }
                        )
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var activeDeviceName: String? {
        engine.availableOutputDevices.first { $0.uid == engine.activeOutputUID }?.name
    }
}

struct DeviceRowView: View {
    let name: String
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Theme.brand : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(.body, weight: isActive ? .medium : .regular))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
