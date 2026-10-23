import Combine
import Foundation

/// A user-authored cleanup ruleset for the on-device AI pass. Unlike the
/// built-in intensities, a custom ruleset is sent to the model verbatim —
/// no hidden preamble, no change-ratio governor — and carries its own
/// sampling temperature.
nonisolated struct CustomCleanupRuleset: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var instructions: String
    var temperature: Double = CustomCleanupRuleset.defaultTemperature

    /// FoundationModels accepts higher, but past ~1.0 a cleanup pass starts
    /// inventing text — cap the slider there.
    nonisolated static let temperatureRange: ClosedRange<Double> = 0.0...1.0
    nonisolated static let defaultTemperature = 0.0

    /// A ruleset with no instructions would silence the model entirely.
    nonisolated var isUsable: Bool {
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension CustomCleanupRuleset: nonisolated Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.instructions == rhs.instructions
            && lhs.temperature == rhs.temperature
    }
}

/// Owns the user's custom cleanup rulesets (creation, edits, the active
/// pick) and persists them as JSON in UserDefaults. Capped at
/// `maximumRulesets`; the cap is enforced here, not in the UI.
final class CustomRulesetStore: ObservableObject {
    static let shared = CustomRulesetStore()

    nonisolated static let rulesetsKey = "customCleanupRulesets"
    nonisolated static let activeIDKey = "activeCustomCleanupRulesetID"
    nonisolated static let maximumRulesets = 5
    nonisolated static let temperatureRange = CustomCleanupRuleset.temperatureRange
    nonisolated static let defaultTemperature = CustomCleanupRuleset.defaultTemperature

    @Published private(set) var rulesets: [CustomCleanupRuleset]
    @Published var activeRulesetID: UUID? {
        didSet { persistActiveID() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rulesets = Self.loadRulesets(from: defaults)
        self.activeRulesetID = Self.loadActiveID(from: defaults)
        // Heal a dangling active pointer (deleted ruleset, corrupted store).
        if let id = activeRulesetID, !rulesets.contains(where: { $0.id == id }) {
            activeRulesetID = rulesets.first?.id
        }
    }

    var canAddRuleset: Bool { rulesets.count < Self.maximumRulesets }

    var activeRuleset: CustomCleanupRuleset? {
        guard let id = activeRulesetID else { return nil }
        return rulesets.first { $0.id == id }
    }

    /// The ruleset the formatter should run: the active pick if it has
    /// instructions, otherwise nil so the caller can fall back.
    var usableActiveRuleset: CustomCleanupRuleset? {
        guard let ruleset = activeRuleset, ruleset.isUsable else { return nil }
        return ruleset
    }

    @discardableResult
    func addRuleset(name: String = "") -> CustomCleanupRuleset? {
        guard canAddRuleset else { return nil }
        let fallbackName = "Ruleset \(rulesets.count + 1)"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleset = CustomCleanupRuleset(
            name: trimmed.isEmpty ? fallbackName : trimmed,
            instructions: "")
        rulesets.append(ruleset)
        if activeRulesetID == nil { activeRulesetID = ruleset.id }
        persistRulesets()
        return ruleset
    }

    func update(_ ruleset: CustomCleanupRuleset) {
        guard let index = rulesets.firstIndex(where: { $0.id == ruleset.id }) else { return }
        var next = ruleset
        next.temperature = DoubleClamp.clamp(next.temperature, to: Self.temperatureRange)
        rulesets[index] = next
        persistRulesets()
    }

    func delete(id: UUID) {
        rulesets.removeAll { $0.id == id }
        if activeRulesetID == id { activeRulesetID = rulesets.first?.id }
        persistRulesets()
    }

    /// Reorders a single ruleset using `Array.move(fromOffsets:toOffset:)`
    /// semantics: `destinationIndex` is the insertion index in the current
    /// array, before the move. Persists. Does not change `activeRulesetID`.
    func move(from sourceIndex: Int, to destinationIndex: Int) {
        move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
    }

    /// Applies a drag-reorder described by item IDs: `ids` land immediately
    /// before `beforeID`, or at the end when `beforeID` is nil. Unknown IDs
    /// are ignored. Persists. Does not change `activeRulesetID`.
    func moveRulesets(ids: [UUID], before beforeID: UUID?) {
        let offsets = IndexSet(ids.compactMap { id in rulesets.firstIndex { $0.id == id } })
        guard !offsets.isEmpty else { return }
        let destination: Int
        if let beforeID, let idx = rulesets.firstIndex(where: { $0.id == beforeID }) {
            destination = idx
        } else {
            destination = rulesets.count
        }
        move(fromOffsets: offsets, toOffset: destination)
    }

    private func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty,
            source.allSatisfy({ rulesets.indices.contains($0) }),
            destination >= 0, destination <= rulesets.count
        else { return }
        let moving = source.sorted().map { rulesets[$0] }
        var next = rulesets
        for index in source.sorted(by: >) {
            next.remove(at: index)
        }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: destination - removedBeforeDestination)
        rulesets = next
        persistRulesets()
    }

    // MARK: - Persistence

    private static func loadRulesets(from defaults: UserDefaults) -> [CustomCleanupRuleset] {
        guard let data = defaults.data(forKey: rulesetsKey),
            let decoded = try? JSONDecoder().decode([CustomCleanupRuleset].self, from: data)
        else { return [] }
        return Array(decoded.prefix(maximumRulesets))
    }

    private static func loadActiveID(from defaults: UserDefaults) -> UUID? {
        guard let raw = defaults.string(forKey: activeIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    private func persistRulesets() {
        guard let data = try? JSONEncoder().encode(rulesets) else { return }
        defaults.set(data, forKey: Self.rulesetsKey)
    }

    private func persistActiveID() {
        if let id = activeRulesetID {
            defaults.set(id.uuidString, forKey: Self.activeIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeIDKey)
        }
    }
}

enum DoubleClamp {
    nonisolated static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
}
