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

    init(id: UUID = UUID(), name: String, bands: [EQBand], volume: Float = 1.0, balance: Float = 0.0) {
        self.id = id
        self.name = name
        self.bands = bands
        self.volume = volume
        self.balance = balance
    }
}

@MainActor
final class EQStore: ObservableObject {
    static let defaultFrequencies = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    @Published var bands: [EQBand]
    @Published var volume: Float = 1.0
    @Published var balance: Float = 0.0
    @Published var isEnabled: Bool = true
    @Published var showVisualization: Bool = true
    @Published var presets: [EQPreset] = []
    @Published var activePresetId: UUID?

    private let presetsURL: URL

    init() {
        bands = Self.defaultFrequencies.map { EQBand(frequency: $0) }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ImperatorEQ")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        presetsURL = appDir.appendingPathComponent("presets.json")

        loadPresets()
    }

    func resetBands() {
        for i in bands.indices {
            bands[i].gain = 0.0
        }
        activePresetId = nil
    }

    func savePreset(name: String) {
        let preset = EQPreset(name: name, bands: bands, volume: volume, balance: balance)
        presets.append(preset)
        activePresetId = preset.id
        persistPresets()
    }

    func updatePreset(_ preset: EQPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = EQPreset(id: preset.id, name: preset.name, bands: bands, volume: volume, balance: balance)
        persistPresets()
    }

    func deletePreset(_ preset: EQPreset) {
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
