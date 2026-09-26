import SwiftUI

struct OutputDeviceView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var store: EQStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleHeader(title: "OUTPUT DEVICE", isExpanded: $store.outputDevicesExpanded)

            if store.outputDevicesExpanded {
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
            }
        }
        .clipped()
    }
}

struct DeviceRowView: View {
    let name: String
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ActiveDot(isActive: isActive)
            Text(name)
                .font(.system(.body, weight: isActive ? .medium : .regular))
                .lineLimit(1)
            Spacer()
        }
        .listRow(isHovered: $isHovered, onTap: onSelect)
    }
}
