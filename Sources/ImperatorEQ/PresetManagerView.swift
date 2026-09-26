import SwiftUI

struct PresetManagerView: View {
    @EnvironmentObject var store: EQStore

    @State private var showSaveSheet = false
    @State private var editingPreset: EQPreset?
    @State private var draggingPresetId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleHeader(title: "PRESETS", isExpanded: $store.presetsExpanded)

            if store.presetsExpanded {
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

                    // Never empty: the built-in presets cannot be deleted.
                    VStack(spacing: 4) {
                        ForEach(store.presets) { preset in
                            PresetRowView(
                                preset: preset,
                                isActive: store.activePresetId == preset.id,
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
                .padding(.top, 8)
            }
        }
        .clipped()
        .sheet(isPresented: $showSaveSheet) {
            PresetNameSheet(title: "Save Preset", isTaken: store.presetNameExists) { name in
                store.savePreset(name: name)
                showSaveSheet = false
            } onCancel: {
                showSaveSheet = false
            }
        }
        .sheet(item: $editingPreset) { preset in
            // Keeping its own name, in another case, is not a clash.
            PresetNameSheet(title: "Rename Preset", name: preset.name,
                            isTaken: { $0.lowercased() != preset.name.lowercased() && store.presetNameExists($0) }) { name in
                store.renamePreset(preset, to: name)
                editingPreset = nil
            } onCancel: {
                editingPreset = nil
            }
        }
    }
}

/// Asks for a preset name, for both saving and renaming.
struct PresetNameSheet: View {
    let title: String
    let isTaken: (String) -> Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(title: String, name: String = "", isTaken: @escaping (String) -> Bool,
         onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.isTaken = isTaken
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: name)
    }

    private var nameIsDuplicate: Bool {
        !name.isEmpty && isTaken(name)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
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
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    guard !name.isEmpty, !nameIsDuplicate else { return }
                    onSave(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || nameIsDuplicate)
            }
        }
        .padding(20)
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

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct PresetRowView: View {
    let preset: EQPreset
    let isActive: Bool
    let onApply: () -> Void
    let onUpdate: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    @State private var isHovered = false
    @State private var showConfirmDelete = false

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ActiveDot(isActive: isActive)
                Text(preset.name)
                    .font(.system(size: 10, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
            }

            Spacer()

            if isHovered && !preset.isDefault {
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
        .listRow(isHovered: $isHovered, onTap: onApply)
        .alert("Delete preset?", isPresented: $showConfirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Delete \"\(preset.name)\"? This cannot be undone.")
        }
    }
}
