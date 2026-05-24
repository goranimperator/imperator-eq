import SwiftUI

struct PresetManagerView: View {
    @EnvironmentObject var store: EQStore

    @State private var showSaveSheet = false
    @State private var newPresetName = ""
    @State private var editingPreset: EQPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PRESETS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

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
                            onApply: { store.applyPreset(preset) },
                            onUpdate: { store.updatePreset(preset) },
                            onDelete: { store.deletePreset(preset) },
                            onRename: { editingPreset = preset }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            savePresetSheet
        }
        .sheet(item: $editingPreset) { preset in
            renamePresetSheet(preset)
        }
    }

    private var savePresetSheet: some View {
        VStack(spacing: 12) {
            Text("Save Preset")
                .font(.headline)

            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack {
                Button("Cancel") {
                    newPresetName = ""
                    showSaveSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    if !newPresetName.isEmpty {
                        store.savePreset(name: newPresetName)
                        newPresetName = ""
                        showSaveSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.isEmpty)
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

    var body: some View {
        VStack(spacing: 12) {
            Text("Rename Preset")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            HStack {
                Button("Cancel") {
                    editingPreset = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    if !name.isEmpty, let index = store.presets.firstIndex(where: { $0.id == preset.id }) {
                        store.presets[index].name = name
                        editingPreset = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = preset.name }
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
            Button(action: onApply) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isActive ? Theme.brand : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(preset.name)
                        .font(.system(.body, weight: isActive ? .medium : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if isHovered {
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
        .onHover { isHovered = $0 }
        .alert("Delete preset?", isPresented: $showConfirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Delete \"\(preset.name)\"? This cannot be undone.")
        }
    }
}
