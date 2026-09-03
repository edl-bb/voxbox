import SwiftUI

/// On-device AI cleanup, as it appears on the AI Models page: the enable
/// toggle (mirrored from Settings — same key), the effort picker including
/// Custom, and the custom-ruleset manager. Configuration for custom rulesets
/// lives here, not in Settings.
struct TranscriptCleanupAISection: View {
    @AppStorage(TranscriptFormatterService.enabledKey)
    private var formatWithOnDeviceAI: Bool = false
    @AppStorage(TranscriptFormatterService.intensityKey)
    private var formattingIntensityRaw: Int = FormattingIntensity.lightCleanup.rawValue
    @AppStorage(TranscriptFormatterService.markdownFormattingKey)
    private var markdownFormatting: Bool = true

    @ObservedObject private var store = CustomRulesetStore.shared
    @State private var editingRuleset: CustomCleanupRuleset?

    private var intensity: FormattingIntensity {
        FormattingIntensity(rawValue: formattingIntensityRaw) ?? .lightCleanup
    }

    var body: some View {
        SettingsSection {
            SettingsSectionHeader(
                icon: "sparkles",
                title: "On-device AI",
                subtitle: "Clean up transcripts with Apple Intelligence, on your Mac"
            ) {
                Toggle("", isOn: $formatWithOnDeviceAI)
                    .labelsHidden()
                    .disabled(!TranscriptFormatterService.isCleanupAvailable)
            }

            if !TranscriptFormatterService.isCleanupAvailable {
                Text("No cleanup model is available on this Mac right now.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            } else if formatWithOnDeviceAI {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Effort")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Picker("", selection: $formattingIntensityRaw) {
                            ForEach(FormattingIntensity.allCases) { level in
                                Text(level.displayName).tag(level.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(intensity.summary)
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if intensity == .custom {
                        rulesetManager
                    } else {
                        HStack {
                            Text("Markdown formatting")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Toggle("", isOn: $markdownFormatting)
                                .labelsHidden()
                        }
                        Text("Adds bold, italic, bullet points, and numbered lists where they fit.")
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                    }
                }
                .padding(.top, 2)
            } else {
                Text("Off — transcripts get instant rule-based cleanup only.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .sheet(item: $editingRuleset) { ruleset in
            RulesetEditorSheet(ruleset: ruleset) { updated in
                store.update(updated)
            }
        }
    }

    // MARK: - Ruleset manager

    private var rulesetManager: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your rulesets")
                    .font(Typography.uiBold(12)).tracking(0.4)
                    .foregroundStyle(Color.textSecondary)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    if let created = store.addRuleset() {
                        store.activeRulesetID = created.id
                        editingRuleset = created
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New ruleset").font(Typography.uiBold(12))
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(Color.textPrimary.opacity(0.06)))
                    .foregroundStyle(Color.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(!store.canAddRuleset)
                .help(
                    store.canAddRuleset
                        ? "Create a new cleanup ruleset"
                        : "Limit of \(CustomRulesetStore.maximumRulesets) rulesets reached")
            }

            if store.rulesets.isEmpty {
                Text("No rulesets yet. Create up to \(CustomRulesetStore.maximumRulesets) — each is a set of cleanup instructions in your own words, sent to the model exactly as written, with its own temperature and no guardrails.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.rulesets) { ruleset in
                        RulesetRow(
                            ruleset: ruleset,
                            isActive: store.activeRulesetID == ruleset.id,
                            onSelect: { store.activeRulesetID = ruleset.id },
                            onEdit: { editingRuleset = ruleset },
                            onDelete: { store.delete(id: ruleset.id) }
                        )
                    }
                }

                if let active = store.activeRuleset, !active.isUsable {
                    Label(
                        "“\(active.name)” has no instructions yet — Light cleanup runs until you add some.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.accentWarning)
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Ruleset row

private struct RulesetRow: View {
    let ruleset: CustomCleanupRuleset
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isActive ? Color.brandAccent : Color.textMuted)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ruleset.name)
                            .font(Typography.uiBold(13))
                            .foregroundStyle(Color.textPrimary)
                        Text(previewLine)
                            .font(Typography.ui(11))
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text(String(format: "temp %.2f", ruleset.temperature))
                .font(Typography.uiMedium(11))
                .foregroundStyle(Color.textMuted)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .padding(6)
                    .background(Circle().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
            }
            .buttonStyle(.plain)
            .help("Edit ruleset")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .padding(6)
                    .background(Circle().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
            }
            .buttonStyle(.plain)
            .help("Delete ruleset")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.brandAccentSoft : Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActive ? Color.brandAccent.opacity(0.4) : Color.border.opacity(0.6),
                    lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }

    private var previewLine: String {
        let trimmed = ruleset.instructions
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No instructions yet" : trimmed
    }
}

// MARK: - Editor sheet

private struct RulesetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var instructions: String
    @State private var temperature: Double
    @State private var showTestPanel = false

    private let rulesetID: UUID
    private let onSave: (CustomCleanupRuleset) -> Void

    init(ruleset: CustomCleanupRuleset, onSave: @escaping (CustomCleanupRuleset) -> Void) {
        self.rulesetID = ruleset.id
        self.onSave = onSave
        _name = State(initialValue: ruleset.name)
        _instructions = State(initialValue: ruleset.instructions)
        _temperature = State(initialValue: ruleset.temperature)
    }

    /// The ruleset as it stands in the sheet, saved or not. The test panel
    /// always runs this, so what you read is what Save would store.
    private var draftRuleset: CustomCleanupRuleset {
        CustomCleanupRuleset(id: rulesetID, name: name, instructions: instructions, temperature: temperature)
    }

    var body: some View {
        ScrollView {
            editor
                .padding(24)
        }
        .frame(width: 560)
        .frame(maxHeight: 680)
        .background(Color.bgApp)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit ruleset")
                .font(Typography.sectionTitle)
                .foregroundStyle(Color.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("NAME")
                    .font(Typography.uiBold(10)).tracking(1)
                    .foregroundStyle(Color.textMuted)
                TextField("Ruleset name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.ui(13))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("INSTRUCTIONS")
                    .font(Typography.uiBold(10)).tracking(1)
                    .foregroundStyle(Color.textMuted)
                TextEditor(text: $instructions)
                    .font(Typography.ui(13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.bgCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.border, lineWidth: 1)
                    )
                Text("Sent to the model exactly as written — no hidden instructions are added and no change limit is applied. Tell it what to clean up, what to leave alone, and how the output should read.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TEMPERATURE")
                        .font(Typography.uiBold(10)).tracking(1)
                        .foregroundStyle(Color.textMuted)
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .font(Typography.uiMedium(12))
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                }
                Slider(value: $temperature, in: CustomRulesetStore.temperatureRange, step: 0.05)
                Text("0 keeps edits deterministic and predictable; higher values give the model more freedom to reword.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }

            DisclosureGroup(isExpanded: $showTestPanel) {
                RulesetTestPanel(draft: draftRuleset)
                    .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Text("TEST THIS RULESET")
                        .font(Typography.uiBold(10)).tracking(1)
                        .foregroundStyle(Color.textMuted)
                    Text("Uses your unsaved edits")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(
                        CustomCleanupRuleset(
                            id: rulesetID,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Untitled ruleset" : name,
                            instructions: instructions,
                            temperature: temperature))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

#Preview {
    TranscriptCleanupAISection()
        .padding()
        .frame(width: 700)
        .background(Color.bgApp)
}
