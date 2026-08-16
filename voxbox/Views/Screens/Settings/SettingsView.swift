import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var onOpenDictionary: (() -> Void)?
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)

                // Tab bar
                HStack(spacing: 0) {
                    ForEach(SettingsTab.allCases) { tab in
                        SettingsTabButton(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            action: { selectedTab = tab }
                        )
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Tab content
            switch selectedTab {
            case .general:
                GeneralSettingsTab(onOpenDictionary: onOpenDictionary)
            case .audio:
                AudioSettingsTab()
            case .permissions:
                PermissionsSettingsTab()
            }
        }
        .background(Color.clear)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case audio = "Audio"
    case permissions = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "mic"
        case .permissions: return "shield"
        }
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                Text(tab.rawValue)
                    .font(Typography.bodyMedium)
            }
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.bgHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    var onOpenDictionary: (() -> Void)?
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("selectedHotkey") private var selectedHotkey: HotkeyOption = .fn
    @AppStorage("recordingMode") private var recordingMode: Int = 0  // 0: Hold to record, 1: Toggle
    @AppStorage("restoreClipboardAfterAutoPaste") private var restoreClipboardAfterAutoPaste =
        true
    @AppStorage(TranscriptClipboardPreference.defaultsKey)
    private var copyTranscriptToClipboard = TranscriptClipboardPreference.defaultEnabled
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("alwaysShowRecorderPill") private var alwaysShowRecorderPill: Bool = false
    @AppStorage(PillPosition.defaultsKey) private var recorderPillPosition: PillPosition = .defaultPosition
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    @AppStorage("recentTranscriptionLanguages") private var recentLanguagesString: String = ""
    @AppStorage(AutoEdit.defaultsKey) private var enableAutoEdit: Bool = false
    @AppStorage(SmartTrailingPunctuation.defaultsKey)
    private var smartTrailingPunctuation: Bool = true
    @AppStorage(TranscriptFormatterService.enabledKey)
    private var formatWithOnDeviceAI: Bool = false
    @AppStorage(TranscriptFormatterService.intensityKey)
    private var formattingIntensityRaw: Int = FormattingIntensity.lightCleanup.rawValue
    @AppStorage(RetentionService.audioRetentionKey)
    private var audioRetentionSeconds: Double = RetentionService.defaultAudioRetention
    @AppStorage(RetentionService.transcriptRetentionKey)
    private var transcriptRetentionSeconds: Double = RetentionService.defaultTranscriptRetention
    @AppStorage(UpdateService.autoUpdateDefaultsKey)
    private var checkForUpdatesDaily = false

    private var recentLanguageCodes: [String] {
        recentLanguagesString.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private func updateRecentLanguages(code: String) {
        guard code != "auto" else { return }
        var recents = recentLanguageCodes.filter { $0 != code }
        recents.insert(code, at: 0)
        recentLanguagesString = recents.prefix(5).joined(separator: ",")
    }

    @StateObject private var updateService = UpdateService.shared
    @State private var openAtLogin = false
    @State private var openAtLoginError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Appearance
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "paintpalette", title: "Appearance",
                        subtitle: "Choose your preferred theme")

                    HStack(spacing: 20) {
                        ForEach(AppTheme.allCases) { theme in
                            RadioButton(
                                title: theme.rawValue,
                                isSelected: appTheme == theme,
                                action: {
                                    appTheme = theme
                                    AppearanceController.shared.apply(theme)
                                }
                            )
                        }
                    }
                }

                // Shortcuts
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "command", title: "Shortcuts",
                        subtitle: "Recording and clipboard hotkeys"
                    )

                    VStack(spacing: 16) {
                        HStack {
                            Text("Primary Hotkey")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Menu {
                                ForEach(HotkeyOption.allCases) { option in
                                    Button(option.displayName) {
                                        selectedHotkey = option
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(selectedHotkey.displayName)
                                        .font(Typography.bodySmall)
                                        .foregroundStyle(Color.textPrimary)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.textPrimary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.bgHover)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .menuStyle(.borderlessButton)
                        }

                        if selectedHotkey == .custom {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Key combination")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                }

                                Text(
                                    "Record any combination (e.g. ⌘D or ⌃⌥Space). Combinations are much less likely to collide with other apps than a single modifier key."
                                )
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Recording Mode")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Picker("", selection: $recordingMode) {
                                    Text("Hold to record").tag(0)
                                    Text("Toggle").tag(1)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 180)
                            }

                            Text(
                                recordingMode == 0
                                    ? "Hold the hotkey down to record, release when done."
                                    : "Press the hotkey to start recording, press again to stop."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                            .padding(.top, 2)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Copy last transcript")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                KeyboardShortcuts.Recorder("", name: .copyLastTranscript)
                            }

                            Text(
                                "Puts the most recent transcript on the clipboard so you can paste it if auto-paste missed the field. Default is ⌃⌥C."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }

                    }
                }

                // General Behavior
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "macwindow", title: "General", subtitle: "App behavior settings"
                    )

                    VStack(spacing: 16) {
                        HStack {
                            Text("Show menu bar icon")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Toggle("", isOn: $showMenuBarIcon)
                                .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Open at login")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: openAtLoginBinding)
                                    .labelsHidden()
                            }

                            Text("Launch VoxBox when you log in to this Mac.")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)

                            if let openAtLoginError {
                                Text(openAtLoginError)
                                    .font(Typography.captionSmall)
                                    .foregroundStyle(Color.accentWarning)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Copy transcript to clipboard")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $copyTranscriptToClipboard)
                                    .labelsHidden()
                            }

                            Text(
                                "Every completed transcript stays on your clipboard after dictation, ready to paste again anywhere."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Restore clipboard after auto-paste")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $restoreClipboardAfterAutoPaste)
                                    .labelsHidden()
                                    .disabled(copyTranscriptToClipboard)
                            }

                            Text(
                                copyTranscriptToClipboard
                                    ? "Unavailable while “Copy transcript to clipboard” is on — the transcript is kept on the clipboard instead."
                                    : restoreClipboardAfterAutoPaste
                                        ? "After pasting into the active app, whatever was already on your clipboard is restored."
                                        : "After pasting into the active app, the transcript stays on your clipboard for manual pasting."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Always show recorder pill")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $alwaysShowRecorderPill)
                                    .labelsHidden()
                                    .onChange(of: alwaysShowRecorderPill) {
                                        NotificationCenter.default.post(
                                            name: .recorderIdleVisibilityChanged, object: nil)
                                    }
                            }

                            Text(
                                alwaysShowRecorderPill
                                    ? "The small floating recorder stays on screen even when you're not dictating."
                                    : "The floating recorder appears only while you're dictating and hides when idle."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Recorder pill position")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Menu {
                                    ForEach(PillPosition.allCases) { pos in
                                        Button(pos.displayName) {
                                            recorderPillPosition = pos
                                            NotificationCenter.default.post(
                                                name: .recorderPillPositionChanged, object: nil)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(recorderPillPosition.displayName)
                                            .font(Typography.bodySmall)
                                            .foregroundStyle(Color.textPrimary)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.textPrimary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color.bgHover)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .menuStyle(.borderlessButton)
                            }

                            Text(
                                "Where the floating recorder appears on screen. Visible while dictating, or always if “Always show recorder pill” is on."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }
                    }
                }

                // Transcript Cleanup
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "wand.and.stars",
                        title: "Transcript Cleanup",
                        subtitle: "Instant rules, then optional on-device AI"
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Remove filler words")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Toggle("", isOn: $enableAutoEdit)
                                .labelsHidden()
                        }

                        Text("Strips um, uh, and similar fillers. Instant — no AI.")
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)

                        HStack {
                            Text("Strip stray period")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Toggle("", isOn: $smartTrailingPunctuation)
                                .labelsHidden()
                        }

                        Text(
                            "If you dictate only an email, URL, number, or single word, drops the extra period the model adds. Sentences are left alone."
                        )
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("On-device AI")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $formatWithOnDeviceAI)
                                    .labelsHidden()
                                    .disabled(!TranscriptFormatterService.isModelAvailable)
                            }

                            if !TranscriptFormatterService.isModelAvailable {
                                Text(
                                    "Apple Intelligence isn’t available on this Mac right now."
                                )
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                            } else if formatWithOnDeviceAI {
                                Picker("", selection: $formattingIntensityRaw) {
                                    ForEach(FormattingIntensity.allCases) { level in
                                        Text(level.displayName).tag(level.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text(
                                    (FormattingIntensity(rawValue: formattingIntensityRaw)
                                        ?? .lightCleanup).summary
                                )
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textMuted)
                            }

                            Text(
                                "Optional. Runs on this Mac for longer dictations only. If the edit is too heavy, the original is kept."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }

                        Divider()

                        Button {
                            onOpenDictionary?()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "character.book.closed")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.textMuted)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Custom replacements & snippets")
                                        .font(Typography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                    Text(
                                        "Say “my email” to insert your address. Always on, every model."
                                    )
                                    .font(Typography.captionSmall)
                                    .foregroundStyle(Color.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.textMuted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpenDictionary == nil)
                    }
                }

                // Spoken Language
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "globe", title: "Spoken Language",
                        subtitle: "Hint for the language you are speaking")

                    HStack {
                        Text("Speech language")
                            .font(Typography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Menu {
                            Button("Auto-detect spoken language") { transcriptionLanguage = "auto" }
                            if !recentLanguageCodes.isEmpty {
                                Divider()
                                ForEach(recentLanguageCodes, id: \.self) { code in
                                    if let lang = Self.whisperLanguages.first(where: { $0.code == code }) {
                                        Button(lang.name) {
                                            transcriptionLanguage = code
                                            updateRecentLanguages(code: code)
                                        }
                                    }
                                }
                            }
                            Divider()
                            ForEach(Self.whisperLanguages, id: \.code) { lang in
                                Button(lang.name) {
                                    transcriptionLanguage = lang.code
                                    updateRecentLanguages(code: lang.code)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(displayName(for: transcriptionLanguage))
                                    .font(Typography.bodySmall)
                                    .foregroundStyle(Color.textPrimary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.textPrimary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.bgHover)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .menuStyle(.borderlessButton)
                    }

                }

                // Privacy & Data Retention
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "clock.arrow.circlepath", title: "Data Retention",
                        subtitle: "Auto-delete recordings and transcripts")

                    VStack(alignment: .leading, spacing: 14) {
                        retentionRow(
                            title: "Keep audio recordings for",
                            selection: $audioRetentionSeconds,
                            options: RetentionService.audioOptions
                        )

                        Text(
                            "Recorded WAV files are deleted automatically after this period. The text transcript is kept."
                        )
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)

                        Divider()

                        retentionRow(
                            title: "Keep transcripts for",
                            selection: $transcriptRetentionSeconds,
                            options: RetentionService.transcriptOptions
                        )

                        Text(
                            "Transcripts older than this are removed from History. Statistics (word counts and durations) are always kept — they contain no content."
                        )
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                    }
                }

                // Updates
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "arrow.down.circle", title: "Updates",
                        subtitle: "VoxBox \(AppVersion.currentVersion)")

                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Check for updates daily")
                                    .font(Typography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Toggle("", isOn: $checkForUpdatesDaily)
                                    .labelsHidden()
                            }

                            Text(
                                checkForUpdatesDaily
                                    ? "Once a day at launch, VoxBox asks GitHub if a newer version is available and prompts you if there is."
                                    : "Off by default. The app only checks GitHub when you tap the button below."
                            )
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                        }

                        Button(action: {
                            Task {
                                await updateService.checkForUpdates()
                            }
                        }) {
                            HStack(spacing: 6) {
                                switch updateService.manualCheckStatus {
                                case .idle:
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12))
                                    Text("Check for Updates")
                                        .font(Typography.labelMedium)
                                case .checking:
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                    Text("Checking...")
                                        .font(Typography.labelMedium)
                                case .upToDate:
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                    Text("Up to date")
                                        .font(Typography.labelMedium)
                                case .failed:
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 12))
                                    Text("Couldn’t check")
                                        .font(Typography.labelMedium)
                                }
                            }
                            .foregroundStyle(updateButtonForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.bgHover)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            updateService.manualCheckStatus == .checking
                                || updateService.manualCheckStatus == .upToDate
                        )
                        .animation(
                            .easeInOut(duration: 0.2),
                            value: updateService.manualCheckStatus
                        )
                    }
                }

            }
            .padding(24)
        }
        .onAppear {
            openAtLogin = LoginItemService.isEnabled
            openAtLoginError = nil
        }
    }

    private var updateButtonForeground: Color {
        switch updateService.manualCheckStatus {
        case .upToDate: return Color.accentSuccess
        case .failed: return Color.accentWarning
        case .idle, .checking: return Color.textPrimary
        }
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { openAtLogin },
            set: { newValue in
                do {
                    try LoginItemService.setEnabled(newValue)
                    openAtLogin = LoginItemService.isEnabled
                    openAtLoginError = nil
                } catch {
                    openAtLogin = LoginItemService.isEnabled
                    openAtLoginError = "Couldn’t update the login item."
                }
            }
        )
    }

    private func retentionRow(
        title: String,
        selection: Binding<Double>,
        options: [(label: String, seconds: TimeInterval)]
    ) -> some View {
        HStack {
            Text(title)
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Menu {
                ForEach(options, id: \.seconds) { option in
                    Button(option.label) {
                        selection.wrappedValue = option.seconds
                        // Apply the new window right away rather than at the
                        // next hourly sweep.
                        RetentionService.shared.purgeNow()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(RetentionService.label(for: selection.wrappedValue, in: options))
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.bgHover)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func displayName(for code: String) -> String {
        if code == "auto" { return "Auto-detect" }
        return Self.whisperLanguages.first(where: { $0.code == code })?.name ?? code
    }

    // All languages supported by Whisper, sorted alphabetically
    static let whisperLanguages: [(code: String, name: String)] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"),
        ("hy", "Armenian"), ("as", "Assamese"), ("az", "Azerbaijani"), ("ba", "Bashkir"),
        ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
        ("br", "Breton"), ("bg", "Bulgarian"), ("yue", "Cantonese"), ("ca", "Catalan"),
        ("zh", "Chinese"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"),
        ("nl", "Dutch"), ("en", "English"),
        (AustralianEnglishSpelling.languageCode, "English (Australia)"),
        ("et", "Estonian"), ("fo", "Faroese"),
        ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"),
        ("de", "German"), ("el", "Greek"), ("gu", "Gujarati"), ("ht", "Haitian Creole"),
        ("ha", "Hausa"), ("haw", "Hawaiian"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"),
        ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"),
        ("km", "Khmer"), ("ko", "Korean"), ("lo", "Lao"), ("la", "Latin"),
        ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"), ("lb", "Luxembourgish"),
        ("mk", "Macedonian"), ("mg", "Malagasy"), ("ms", "Malay"), ("ml", "Malayalam"),
        ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"), ("mn", "Mongolian"),
        ("my", "Myanmar"), ("ne", "Nepali"), ("no", "Norwegian"), ("nn", "Nynorsk"),
        ("oc", "Occitan"), ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"),
        ("pt", "Portuguese"), ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sa", "Sanskrit"), ("sr", "Serbian"), ("sn", "Shona"), ("sd", "Sindhi"),
        ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"),
        ("es", "Spanish"), ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"),
        ("tl", "Tagalog"), ("tg", "Tajik"), ("ta", "Tamil"), ("tt", "Tatar"),
        ("te", "Telugu"), ("th", "Thai"), ("bo", "Tibetan"), ("tr", "Turkish"),
        ("tk", "Turkmen"), ("uk", "Ukrainian"), ("ur", "Urdu"), ("uz", "Uzbek"),
        ("vi", "Vietnamese"), ("cy", "Welsh"), ("yi", "Yiddish"), ("yo", "Yoruba"),
    ]
}

// MARK: - Audio Settings Tab

struct AudioSettingsTab: View {
    @StateObject private var audioRecorder = AudioRecordingService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "mic", title: "Input Device", subtitle: "Select your microphone")

                    VStack(spacing: 12) {
                        if audioRecorder.availableDevices.isEmpty {
                            Text("No input devices found")
                                .font(Typography.bodyMedium)
                                .foregroundStyle(Color.textMuted)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(audioRecorder.availableDevices, id: \.uniqueID) { device in
                                DeviceRow(
                                    name: device.localizedName,
                                    isActive: audioRecorder.selectedDeviceId == device.uniqueID,
                                    isSelected: audioRecorder.selectedDeviceId == device.uniqueID
                                )
                                .onTapGesture {
                                    audioRecorder.selectedDeviceId = device.uniqueID
                                }
                            }
                        }
                    }

                    Button(action: { audioRecorder.fetchAvailableDevices() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                            Text("Refresh Devices")
                                .font(Typography.labelMedium)
                        }
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.bgHover)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(24)
        }
        .onAppear {
            audioRecorder.fetchAvailableDevices()
        }
    }
}

// MARK: - Permissions Settings Tab

struct PermissionsSettingsTab: View {
    @ObservedObject private var permissions = PermissionService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "shield", title: "App Permissions",
                        subtitle: "Required for recording and auto-paste")

                    VStack(spacing: 10) {
                        SettingsPermissionItem(
                            icon: "mic.fill",
                            color: Color.textSecondary,
                            title: "Microphone",
                            desc: permissions.isMicGranted
                                ? "On — VoxBox can hear you"
                                : "Off — recording will not work until this is enabled",
                            isGranted: permissions.isMicGranted,
                            action: {
                                if permissions.isMicGranted {
                                    permissions.manageMicrophone()
                                } else {
                                    permissions.requestMicrophone()
                                }
                            }
                        )

                        SettingsPermissionItem(
                            icon: "hand.raised.fill",
                            color: Color.textSecondary,
                            title: "Accessibility",
                            desc: permissions.isAccessibilityGranted
                                ? "On — transcripts paste into the focused app"
                                : "Off — transcripts are copied to the clipboard instead",
                            isGranted: permissions.isAccessibilityGranted,
                            action: {
                                if permissions.isAccessibilityGranted {
                                    permissions.manageAccessibility()
                                } else {
                                    permissions.requestAccessibility()
                                }
                            }
                        )
                    }
                }
            }
            .padding(24)
        }
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Supporting Components

struct SettingsSectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.textMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }

            Spacer()
        }
        .padding(.bottom, 16)
    }
}

struct SettingsSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .themedCard(padding: 24)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct RadioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentPrimary : Color.textMuted, lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(Color.accentPrimary)
                            .frame(width: 10, height: 10)
                    }
                }

                Text(title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsPermissionItem: View {
    let icon: String
    let color: Color
    let title: String
    let desc: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Color.textMuted)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(Color.bgHover)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                Text(desc)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }

            Spacer()

            Text(isGranted ? "On" : "Off")
                .font(Typography.labelSmall)
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill((isGranted ? Color.green : Color.orange).opacity(0.12))
                )

            Button(isGranted ? "Manage" : "Enable") {
                action()
            }
            .font(Typography.labelSmall)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.bgHover)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"

    var id: String { rawValue }
}
