import SwiftUI
import Combine

struct EQBand: Identifiable, Codable, Equatable {
    let id: UUID
    var frequency: String
    var gain: Float

    init(id: UUID = UUID(), frequency: String, gain: Float = 0.0) {
        self.id = id
        self.frequency = frequency
        self.gain = gain
    }
}

struct EQPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bands: [EQBand]
    var volume: Float
    var balance: Float
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, bands: [EQBand], volume: Float = 1.0, balance: Float = 0.0, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.bands = bands
        self.volume = volume
        self.balance = balance
        self.isDefault = isDefault
    }

    // Decode with backwards compatibility for presets saved without isDefault
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bands = try container.decode([EQBand].self, forKey: .bands)
        volume = try container.decode(Float.self, forKey: .volume)
        balance = try container.decode(Float.self, forKey: .balance)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

@MainActor
final class EQStore: ObservableObject {
    /// Band labels, made from the frequencies the engine runs: 32 ... 500, 1K ... 16K.
    static let defaultFrequencies = EQSettings.frequencies.map { $0 >= 1000 ? "\(Int($0 / 1000))K" : "\(Int($0))" }

    @Published var bands: [EQBand]
    @Published var volume: Float = 1.0
    @Published var balance: Float = 0.0
    @Published var isEnabled: Bool = true
    @Published var presets: [EQPreset] = []
    @Published var activePresetId: UUID?
    @Published var presetsExpanded: Bool = false
    @Published var outputDevicesExpanded: Bool = false

    private let presetsURL: URL
    private let stateURL: URL
    private var stateSaveCancellable: AnyCancellable?

    static let defaultPresets: [EQPreset] = [
        builtIn("Bass Boost", gains: [8, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
        builtIn("Treble Boost", gains: [0, 0, 0, 0, 0, 2, 4, 5, 6, 7]),
        builtIn("Electronic", gains: [8, 7, 4, 0, -2, -1, 2, 5, 6, 7]),
        builtIn("Rock", gains: [5, 4, 2, -1, -2, -1, 2, 4, 5, 6]),
        builtIn("Metal", gains: [7, 6, 3, -2, -4, -3, 2, 6, 8, 8]),
    ]

    /// One gain per band; `zip` stops at the shorter list, so a band added
    /// without a gain here is left out of the preset rather than crashing.
    private static func builtIn(_ name: String, gains: [Float]) -> EQPreset {
        EQPreset(name: name, bands: zip(defaultFrequencies, gains).map { EQBand(frequency: $0, gain: $1) },
                 isDefault: true)
    }

    init() {
        bands = Self.defaultFrequencies.map { EQBand(frequency: $0) }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ImperatorEQ")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        presetsURL = appDir.appendingPathComponent("presets.json")
        stateURL = appDir.appendingPathComponent("state.json")

        loadPresets()
        ensureDefaultPresets()
        loadState()
        setupAutoSave()
    }

    /// Saves a second after the last change of any kind, so a slider drag
    /// writes once, after it ends. Set up after loading, so loading saves nothing.
    private func setupAutoSave() {
        stateSaveCancellable = objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveState() }
    }

    func resetBands() {
        for i in bands.indices {
            bands[i].gain = 0.0
        }
        activePresetId = nil
    }

    func presetNameExists(_ name: String) -> Bool {
        presets.contains { $0.name.lowercased() == name.lowercased() }
    }

    func savePreset(name: String) {
        let preset = EQPreset(name: name, bands: bands, volume: volume, balance: balance)
        presets.insert(preset, at: 0)
        activePresetId = preset.id
        persistPresets()
    }

    func updatePreset(_ preset: EQPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = EQPreset(id: preset.id, name: preset.name, bands: bands, volume: volume, balance: balance)
        persistPresets()
    }

    func movePreset(fromId: UUID, toId: UUID) {
        guard fromId != toId,
              let fromIndex = presets.firstIndex(where: { $0.id == fromId }),
              let toIndex = presets.firstIndex(where: { $0.id == toId }),
              !presets[fromIndex].isDefault else { return }
        // Inserted at the target's old index: after it when moving down, since
        // the removal shifted it up one, and before it when moving up.
        let preset = presets.remove(at: fromIndex)
        presets.insert(preset, at: toIndex)
        persistPresets()
    }

    func renamePreset(_ preset: EQPreset, to name: String) {
        guard !preset.isDefault, let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index].name = name
        persistPresets()
    }

    func deletePreset(_ preset: EQPreset) {
        guard !preset.isDefault else { return }
        presets.removeAll { $0.id == preset.id }
        if activePresetId == preset.id {
            activePresetId = nil
        }
        persistPresets()
    }

    func applyPreset(_ preset: EQPreset) {
        bands = preset.bands
        volume = preset.volume
        balance = preset.balance
        activePresetId = preset.id
        saveState() // Persist immediately so active preset survives force-quit
    }

    private func ensureDefaultPresets() {
        // Remove old defaults that no longer exist
        let defaultNames = Set(Self.defaultPresets.map(\.name))
        presets.removeAll { $0.isDefault && !defaultNames.contains($0.name) }

        // Add missing defaults at the beginning
        let existingDefaultNames = Set(presets.filter(\.isDefault).map(\.name))
        let missing = Self.defaultPresets.filter { !existingDefaultNames.contains($0.name) }
        if !missing.isEmpty {
            let userPresets = presets.filter { !$0.isDefault }
            let currentDefaults = presets.filter(\.isDefault)
            // Maintain default preset order
            var orderedDefaults: [EQPreset] = []
            for dp in Self.defaultPresets {
                if let existing = currentDefaults.first(where: { $0.name == dp.name }) {
                    orderedDefaults.append(existing)
                } else {
                    orderedDefaults.append(dp)
                }
            }
            presets = orderedDefaults + userPresets
        }
        persistPresets()
    }

    // MARK: - State Persistence

    private struct SavedState: Codable {
        var bands: [EQBand]
        var volume: Float
        var balance: Float
        var isEnabled: Bool
        var activePresetId: UUID?
    }

    func saveState() {
        let state = SavedState(
            bands: bands,
            volume: volume,
            balance: balance,
            isEnabled: isEnabled,
            activePresetId: activePresetId
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        bands = state.bands
        volume = state.volume
        balance = state.balance
        isEnabled = state.isEnabled
        activePresetId = state.activePresetId
    }

    /// Atomic, so a write cut off by a full disk or a crash leaves the previous
    /// file instead of half of the new one.
    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: presetsURL, options: .atomic)
    }

    private func loadPresets() {
        guard let data = try? Data(contentsOf: presetsURL) else { return }
        do {
            presets = try JSONDecoder().decode([EQPreset].self, from: data)
        } catch {
            // The defaults are written over this path at every launch, so an
            // unreadable file is moved aside first rather than lost for good.
            let aside = presetsURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: presetsURL, to: aside)
        }
    }
}
