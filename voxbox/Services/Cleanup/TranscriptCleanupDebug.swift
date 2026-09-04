import Foundation

/// DEBUG overlay for the compiled prompt set. Release builds never read
/// these keys, never show the Settings editor, and never write fixtures.
nonisolated enum TranscriptCleanupDebug {
    static let prefix = "formatTranscriptDebug."

    enum Field: String, CaseIterable {
        case role, basic, light, polish, style, australianSpelling, markdown, outputOnly, wrapTemplate
        case suffixBasic, suffixLight, suffixPolish
        case budgetBasic, budgetLight, budgetPolish
        case pureFillers, deletableFillers

        var key: String { TranscriptCleanupDebug.prefix + rawValue }

        var title: String {
            switch self {
            case .role: return "Role"
            case .basic: return "Basic instructions"
            case .light: return "Light cleanup instructions"
            case .polish: return "Polish instructions"
            case .style: return "Style rules"
            case .australianSpelling: return "Australian spelling stage"
            case .markdown: return "Markdown stage"
            case .outputOnly: return "Output-only stage"
            case .wrapTemplate: return "Wrap template ({{transcript}})"
            case .suffixBasic: return "Basic repeat suffix"
            case .suffixLight: return "Light repeat suffix"
            case .suffixPolish: return "Polish repeat suffix"
            case .budgetBasic: return "Basic budget (ratio, free edits, retention)"
            case .budgetLight: return "Light budget (ratio, free edits, retention)"
            case .budgetPolish: return "Polish budget (ratio, free edits, retention)"
            case .pureFillers: return "Pure fillers (comma-separated)"
            case .deletableFillers: return "Deletable fillers (comma-separated)"
            }
        }
    }

    static func resetOverlay(defaults: UserDefaults = .standard) {
        for field in Field.allCases {
            defaults.removeObject(forKey: field.key)
        }
    }

    static func overlayValue(_ field: Field, defaults: UserDefaults = .standard) -> String? {
        #if DEBUG
            guard let value = defaults.string(forKey: field.key) else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        #else
            return nil
        #endif
    }

    static func setOverlay(_ value: String?, for field: Field, defaults: UserDefaults = .standard) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: field.key)
        } else {
            defaults.removeObject(forKey: field.key)
        }
    }

    /// Compiled text of a field, so the tuner can show and diff it.
    static func compiledValue(_ field: Field, in set: CleanupPromptSet = .compiled) -> String {
        switch field {
        case .role: return set.role
        case .basic: return set.basic
        case .light: return set.light
        case .polish: return set.polish
        case .style: return set.style
        case .australianSpelling: return set.australianSpelling
        case .markdown: return set.markdown
        case .outputOnly: return set.outputOnly
        case .wrapTemplate: return set.wrapTemplate
        case .suffixBasic: return set.repeatSuffixes[.formatting] ?? ""
        case .suffixLight: return set.repeatSuffixes[.lightCleanup] ?? ""
        case .suffixPolish: return set.repeatSuffixes[.polish] ?? ""
        case .budgetBasic: return budgetText(set.budgets[.formatting])
        case .budgetLight: return budgetText(set.budgets[.lightCleanup])
        case .budgetPolish: return budgetText(set.budgets[.polish])
        case .pureFillers: return set.fillerLexicon.pureTokensText
        case .deletableFillers: return set.fillerLexicon.deletableTokensText
        }
    }

    static func overlay(on compiled: CleanupPromptSet, defaults: UserDefaults = .standard) -> CleanupPromptSet {
        #if DEBUG
            var set = compiled
            func text(_ field: Field, _ apply: (String) -> Void) {
                if let value = overlayValue(field, defaults: defaults) { apply(value) }
            }
            text(.role) { set.role = $0 }
            text(.basic) { set.basic = $0 }
            text(.light) { set.light = $0 }
            text(.polish) { set.polish = $0 }
            text(.style) { set.style = $0 }
            text(.australianSpelling) { set.australianSpelling = $0 }
            text(.markdown) { set.markdown = $0 }
            text(.outputOnly) { set.outputOnly = $0 }
            text(.wrapTemplate) { if $0.contains(CleanupPromptSet.transcriptPlaceholder) { set.wrapTemplate = $0 } }
            text(.suffixBasic) { set.repeatSuffixes[.formatting] = $0 }
            text(.suffixLight) { set.repeatSuffixes[.lightCleanup] = $0 }
            text(.suffixPolish) { set.repeatSuffixes[.polish] = $0 }
            text(.budgetBasic) { if let b = parseBudget($0) { set.budgets[.formatting] = b } }
            text(.budgetLight) { if let b = parseBudget($0) { set.budgets[.lightCleanup] = b } }
            text(.budgetPolish) { if let b = parseBudget($0) { set.budgets[.polish] = b } }
            text(.pureFillers) { set.fillerLexicon.pureTokens = parseTokens($0) }
            text(.deletableFillers) { set.fillerLexicon.deletableTokens = parseTokens($0) }
            return set
        #else
            return compiled
        #endif
    }

    static var hasOverlay: Bool {
        Field.allCases.contains { overlayValue($0) != nil }
    }

    // MARK: - Parsing

    static func budgetText(_ budget: GuardrailBudget?) -> String {
        guard let budget else { return "" }
        return "\(String(format: "%.2f", budget.maxCostRatio)), \(budget.minFreeEdits), \(String(format: "%.2f", budget.minRetention))"
    }

    static func parseBudget(_ text: String) -> GuardrailBudget? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let ratio = Double(parts[0]), let free = Int(parts[1]),
            let retention = Double(parts[2])
        else { return nil }
        return GuardrailBudget(
            maxCostRatio: min(max(ratio, 0), 5), minFreeEdits: max(free, 0),
            minRetention: min(max(retention, 0), 1))
    }

    static func parseTokens(_ text: String) -> Set<String> {
        Set(
            text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })
    }
}
