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
    static let defaultFrequencies = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    @Published var bands: [EQBand]
    @Published var volume: Float = 1.0
    @Published var balance: Float = 0.0
    @Published var isEnabled: Bool = true
    @Published var presets: [EQPreset] = []
    @Published var activePresetId: UUID?

    private let presetsURL: URL
    private let stateURL: URL
    private var stateSaveCancellable: AnyCancellable?

    static let defaultPresets: [EQPreset] = [
        EQPreset(name: "Bass Boost", bands: defaultFrequencies.enumerated().map { i, freq in
            EQBand(frequency: freq, gain: [8, 6, 4, 2, 0, 0, 0, 0, 0, 0][i])
        }, isDefault: true),
        EQPreset(name: "Treble Boost", bands: defaultFrequencies.enumerated().map { i, freq in
            EQBand(frequency: freq, gain: [0, 0, 0, 0, 0, 2, 4, 5, 6, 7][i])
        }, isDefault: true),
        EQPreset(name: "Electronic", bands: defaultFrequencies.enumerated().map { i, freq in
            EQBand(frequency: freq, gain: [8, 7, 4, 0, -2, -1, 2, 5, 6, 7][i])
        }, isDefault: true),
        EQPreset(name: "Rock", bands: defaultFrequencies.enumerated().map { i, freq in
            EQBand(frequency: freq, gain: [5, 4, 2, -1, -2, -1, 2, 4, 5, 6][i])
        }, isDefault: true),
        EQPreset(name: "Metal", bands: defaultFrequencies.enumerated().map { i, freq in
            EQBand(frequency: freq, gain: [7, 6, 3, -2, -4, -3, 2, 6, 8, 8][i])
        }, isDefault: true),
    ]

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

    private func setupAutoSave() {
        // Auto-save state on any change (debounced 1s to avoid thrashing during slider drags)
        stateSaveCancellable = Publishers.MergeMany(
            $bands.map { _ in () }.eraseToAnyPublisher(),
            $volume.map { _ in () }.eraseToAnyPublisher(),
            $balance.map { _ in () }.eraseToAnyPublisher(),
            $isEnabled.map { _ in () }.eraseToAnyPublisher(),
            $activePresetId.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5) // Skip initial values from init
        .debounce(for: .seconds(1), scheduler: RunLoop.main)
        .sink { [weak self] in self?.saveState() }
    }

    func resetBands() {
        for i in bands.indices {
            bands[i].gain = 0.0
        }
        activePresetId = nil
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
        let preset = presets.remove(at: fromIndex)
        let insertIndex = fromIndex < toIndex ? toIndex : toIndex
        presets.insert(preset, at: insertIndex)
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
        try? data.write(to: stateURL)
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

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: presetsURL)
    }

    private func loadPresets() {
        guard let data = try? Data(contentsOf: presetsURL),
              let loaded = try? JSONDecoder().decode([EQPreset].self, from: data) else { return }
        presets = loaded
    }
}
