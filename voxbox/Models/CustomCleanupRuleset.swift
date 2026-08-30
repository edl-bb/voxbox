import Foundation
import SwiftUI

/// A user-authored cleanup ruleset for the on-device AI pass. Unlike the
/// built-in intensities, a custom ruleset is sent to the model verbatim —
/// no hidden preamble, no change-ratio governor — and carries its own
/// sampling temperature.
struct CustomCleanupRuleset: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var instructions: String
    var temperature: Double = CustomRulesetStore.defaultTemperature

    /// A ruleset with no instructions would silence the model entirely.
    var isUsable: Bool {
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Owns the user's custom cleanup rulesets (creation, edits, the active
/// pick) and persists them as JSON in UserDefaults. Capped at
/// `maximumRulesets`; the cap is enforced here, not in the UI.
final class CustomRulesetStore: ObservableObject {
    static let shared = CustomRulesetStore()

    static let rulesetsKey = "customCleanupRulesets"
    static let activeIDKey = "activeCustomCleanupRulesetID"
    static let maximumRulesets = 5
    /// FoundationModels accepts higher, but past ~1.0 a cleanup pass starts
    /// inventing text — cap the slider there.
    static let temperatureRange: ClosedRange<Double> = 0.0...1.0
    static let defaultTemperature = 0.0

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
        next.temperature = next.temperature.clamped(to: Self.temperatureRange)
        rulesets[index] = next
        persistRulesets()
    }

    func delete(id: UUID) {
        rulesets.removeAll { $0.id == id }
        if activeRulesetID == id { activeRulesetID = rulesets.first?.id }
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

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
