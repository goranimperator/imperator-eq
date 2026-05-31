import SwiftUI

struct PresetManagerView: View {
    @EnvironmentObject var store: EQStore

    @State private var isExpanded = false
    @State private var showSaveSheet = false
    @State private var newPresetName = ""
    @State private var editingPreset: EQPreset?
    @State private var draggingPresetId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack {
                    Text("PRESETS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        HoverButton(action: { showSaveSheet = true }) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10))
                                Text("Save")
                                    .font(.caption)
                            }
                        }
                    }

                    if store.presets.isEmpty {
                        Text("No saved presets")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(store.presets) { preset in
                                PresetRowView(
                                    preset: preset,
                                    isActive: store.activePresetId == preset.id,
                                    isDefault: preset.isDefault,
                                    isDragTarget: draggingPresetId != nil && draggingPresetId != preset.id && !preset.isDefault,
                                    onApply: { store.applyPreset(preset) },
                                    onUpdate: { store.updatePreset(preset) },
                                    onDelete: { store.deletePreset(preset) },
                                    onRename: { editingPreset = preset }
                                )
                                .onDrag {
                                    draggingPresetId = preset.id
                                    return NSItemProvider(object: preset.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: PresetDropDelegate(
                                    targetId: preset.id,
                                    store: store,
                                    draggingId: $draggingPresetId
                                ))
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .clipped()
        .sheet(isPresented: $showSaveSheet) {
            savePresetSheet
        }
        .sheet(item: $editingPreset) { preset in
            renamePresetSheet(preset)
        }
    }

    private var nameIsDuplicate: Bool {
        !newPresetName.isEmpty && store.presetNameExists(newPresetName)
    }

    private var savePresetSheet: some View {
        VStack(spacing: 12) {
            Text("Save Preset")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                if nameIsDuplicate {
                    Text("A preset with this name already exists. Please choose a different name.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 200, alignment: .leading)
                }
            }

            HStack {
                Button("Cancel") {
                    newPresetName = ""
                    showSaveSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    if !newPresetName.isEmpty && !nameIsDuplicate {
                        store.savePreset(name: newPresetName)
                        newPresetName = ""
                        showSaveSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.isEmpty || nameIsDuplicate)
            }
        }
        .padding(20)
    }

    private func renamePresetSheet(_ preset: EQPreset) -> some View {
        RenamePresetSheet(preset: preset, store: store, editingPreset: $editingPreset)
    }
}

struct RenamePresetSheet: View {
    let preset: EQPreset
    let store: EQStore
    @Binding var editingPreset: EQPreset?
    @State private var name: String = ""

    private var nameIsDuplicate: Bool {
        !name.isEmpty && name.lowercased() != preset.name.lowercased() && store.presetNameExists(name)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Rename Preset")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                if nameIsDuplicate {
                    Text("A preset with this name already exists. Please choose a different name.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 200, alignment: .leading)
                }
            }

            HStack {
                Button("Cancel") {
                    editingPreset = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    guard !name.isEmpty, !nameIsDuplicate,
                          let index = store.presets.firstIndex(where: { $0.id == preset.id }) else { return }
                    store.presets[index].name = name
                    store.persistPresets()
                    editingPreset = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || nameIsDuplicate)
            }
        }
        .padding(20)
        .onAppear { name = preset.name }
    }
}

struct PresetDropDelegate: DropDelegate {
    let targetId: UUID
    let store: EQStore
    @Binding var draggingId: UUID?

    func performDrop(info: DropInfo) -> Bool {
        guard let fromId = draggingId else { return false }
        store.movePreset(fromId: fromId, toId: targetId)
        draggingId = nil
        return true
    }

    func dropEntered(info: DropInfo) {}

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}
}

struct PresetRowView: View {
    let preset: EQPreset
    let isActive: Bool
    let isDefault: Bool
    var isDragTarget: Bool = false
    let onApply: () -> Void
    let onUpdate: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    @State private var isHovered = false
    @State private var showConfirmDelete = false

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Theme.brand : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(preset.name)
                    .font(.system(.body, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
            }

            Spacer()

            if isHovered && !isDefault {
                HStack(spacing: 8) {
                    HoverButton(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                    }

                    HoverButton(action: onUpdate) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10))
                    }

                    HoverButton(action: { showConfirmDelete = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onApply)
        .onHover { isHovered = $0 }
        .alert("Delete preset?", isPresented: $showConfirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Delete \"\(preset.name)\"? This cannot be undone.")
        }
    }
}
