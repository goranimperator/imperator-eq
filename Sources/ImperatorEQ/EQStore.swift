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

/// The CONTROLS knobs, in knob steps: Bass, Mid, Treble and Gain run -10...10
/// with 0 flat, Warmth and Limiter 0...10 with 0 off.
struct ControlValues: Codable, Equatable {
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var warmth: Float = 0
    var limiter: Float = 0
    var gain: Float = 0

    init() {}

    /// Every key optional, so state and presets saved before a knob existed
    /// still load, with that knob at 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bass = try c.decodeIfPresent(Float.self, forKey: .bass) ?? 0
        mid = try c.decodeIfPresent(Float.self, forKey: .mid) ?? 0
        treble = try c.decodeIfPresent(Float.self, forKey: .treble) ?? 0
        warmth = try c.decodeIfPresent(Float.self, forKey: .warmth) ?? 0
        limiter = try c.decodeIfPresent(Float.self, forKey: .limiter) ?? 0
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 0
    }

    /// The removed Volume Boost (a factor, 0...2) as Gain knob steps, so a
    /// saved boost keeps its level: 200 % is +6 dB, Gain +5. Gain cannot go
    /// below -12 dB, so anything under 25 % lands on -10, the quietest it has;
    /// 0 %, which played silence, too.
    static func gainSteps(fromVolume volume: Float) -> Float {
        let steps = (20 * log10(max(volume, 1e-6)) / EQSettings.toneDecibelsPerStep).rounded()
        return min(max(steps, -10), 10)
    }
}

struct EQPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bands: [EQBand]
    var balance: Float
    var isDefault: Bool
    /// Nil in presets saved before the CONTROLS knobs existed, and in the
    /// built-in ones: applying those leaves the knobs where they are.
    var controls: ControlValues?
    /// Nil (built-in and older presets) means stereo, the default.
    var isMono: Bool?

    init(id: UUID = UUID(), name: String, bands: [EQBand], balance: Float = 0.0,
         isDefault: Bool = false, controls: ControlValues? = nil, isMono: Bool? = nil) {
        self.id = id
        self.name = name
        self.bands = bands
        self.balance = balance
        self.isDefault = isDefault
        self.controls = controls
        self.isMono = isMono
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bands, balance, isDefault, controls, isMono
        /// The removed Volume Boost.
        case volume
    }

    // Decodes presets saved without isDefault or controls. A preset saved with
    // a Volume Boost gets it back as Gain, at the same level, the knobs it did
    // not have at 0; one at 100 % keeps no controls, as before.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bands = try container.decode([EQBand].self, forKey: .bands)
        balance = try container.decode(Float.self, forKey: .balance)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        controls = try container.decodeIfPresent(ControlValues.self, forKey: .controls)
        isMono = try container.decodeIfPresent(Bool.self, forKey: .isMono)
        if controls == nil, let volume = try container.decodeIfPresent(Float.self, forKey: .volume), volume != 1 {
            var migrated = ControlValues()
            migrated.gain = ControlValues.gainSteps(fromVolume: volume)
            controls = migrated
        }
    }

    // Writes volume 1 next to the rest: 1.1.1 requires the key and would move
    // every preset aside as unreadable after a downgrade.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bands, forKey: .bands)
        try container.encode(balance, forKey: .balance)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(controls, forKey: .controls)
        try container.encodeIfPresent(isMono, forKey: .isMono)
        try container.encode(Float(1), forKey: .volume)
    }
}

@MainActor
final class EQStore: ObservableObject {
    /// Band labels, made from the frequencies the engine runs: 32 ... 500, 1K ... 16K.
    static let defaultFrequencies = EQSettings.frequencies.map { $0 >= 1000 ? "\(Int($0 / 1000))K" : "\(Int($0))" }

    @Published var bands: [EQBand]
    @Published var balance: Float = 0.0
    @Published var isEnabled: Bool = true
    @Published var controls = ControlValues()
    @Published var isMono = false
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

    /// Every band flat. The active preset stays, so its Update offers to save this.
    func resetBands() {
        for i in bands.indices {
            bands[i].gain = 0.0
        }
    }

    /// The CONTROLS section back to neutral: every knob at 0 and balance in the
    /// middle. The active preset stays, so its Update pill offers to save this.
    func resetControls() {
        controls = ControlValues()
        balance = 0
    }

    func presetNameExists(_ name: String) -> Bool {
        presets.contains { $0.name.lowercased() == name.lowercased() }
    }

    func savePreset(name: String) {
        let preset = EQPreset(name: name, bands: bands, balance: balance, controls: controls, isMono: isMono)
        presets.insert(preset, at: 0)
        activePresetId = preset.id
        persistPresets()
    }

    func updatePreset(_ preset: EQPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = EQPreset(id: preset.id, name: preset.name, bands: bands, balance: balance,
                                  controls: controls, isMono: isMono)
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

    var activePreset: EQPreset? {
        presets.first { $0.id == activePresetId }
    }

    /// Whether the sound has moved away from what `preset` holds: bands,
    /// balance, stereo/mono and the knobs. A preset saved before the knobs
    /// existed is compared with the knobs as they were when it was applied.
    func differs(from preset: EQPreset) -> Bool {
        !bands.lazy.map(\.gain).elementsEqual(preset.bands.lazy.map(\.gain))
            || balance != preset.balance
            || isMono != (preset.isMono ?? false)
            || controls != (preset.controls ?? controlsWhenApplied)
    }

    /// The knobs right after the active preset was applied. Saved with the
    /// state, so a change made before a relaunch still shows after it.
    private var controlsWhenApplied = ControlValues()

    /// Back to what the active preset holds, dropping every change since. A
    /// preset saved before the knobs existed gets the knobs it was applied with.
    func revertToActivePreset() {
        guard let preset = activePreset else { return }
        let baseline = controlsWhenApplied
        applyPreset(preset)
        if preset.controls == nil {
            controls = baseline
            controlsWhenApplied = baseline
        }
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
        balance = preset.balance
        if let presetControls = preset.controls { controls = presetControls }
        // Stereo unless the preset was saved in mono.
        isMono = preset.isMono ?? false
        controlsWhenApplied = controls
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
        /// The removed Volume Boost: read once and moved into Gain (see
        /// loadState), and written as 1 because 1.1.1 requires the key and
        /// would reset the whole state after a downgrade.
        var volume: Float?
        var balance: Float
        var isEnabled: Bool
        var isMono: Bool?
        var activePresetId: UUID?
        var controls: ControlValues?
        var controlsWhenApplied: ControlValues?
    }

    func saveState() {
        let state = SavedState(
            bands: bands,
            volume: 1,
            balance: balance,
            isEnabled: isEnabled,
            isMono: isMono,
            activePresetId: activePresetId,
            controls: controls,
            controlsWhenApplied: controlsWhenApplied
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        bands = state.bands
        balance = state.balance
        isEnabled = state.isEnabled
        isMono = state.isMono ?? false
        activePresetId = state.activePresetId
        if let savedControls = state.controls { controls = savedControls }
        // Volume Boost was removed in favour of the Gain knob. A saved boost
        // becomes the same level on Gain once; the next save writes 1, which
        // is never migrated again.
        if let legacy = state.volume, legacy != 1, controls.gain == 0 {
            controls.gain = ControlValues.gainSteps(fromVolume: legacy)
        }
        controlsWhenApplied = state.controlsWhenApplied ?? controls
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
