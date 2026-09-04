# Changelog

Changes and release notes for VoxBox.

## [1.2.0] - 2026-08-30
- **New Feature**: Choose your Post-processing Model: Post-processing defaults to the build-in Apple Intelligence model, but now you can choose from 4 other LLMs to clean up your transcripts. Choose from Apple Intelligence, Llama 3.2 1B/3B, Qwen 3 1.7B/4B
- **New feature**: Custom LLM cleanup rulesets
    - Create up to 5 of your own cleanup rulesets (name, instructions, temperature) under AI Models → Cleanup AI.
    - Pick "Custom" as the cleanup effort to run your active ruleset. Your instructions are sent to the model exactly as written — no hidden prompt and no change-ratio guardrail.
    - The On-device AI controls now also live on the AI Models page; the toggle in Settings is the same switch.
- AI Models page overhaul
    - AI Models page has been redesigned to facilitate the inclusion of custom Post-processing models, and the new Custom rulesets for Post-processing.
    - Removed the big recommendation banner.
    - Made models list more compact.
    - The "Currently using" strip now shows the active model's capabilities and your Mac's specs.
- Fixed the menu bar dropdown clipping at the bottom edge.
- Fixed the Play button on the dashboard's recent transcriptions — it now plays (and stops) the recording.

## [1.1.2] - 2026-08-25
- New feature: Send transcript to clipboard
    - You can now copy a transcript directly to the clipboard rather than automatically pasting it to the screen.
    - Changed the way VoxBox treats transcription delivery. Moved to a 3-step toggle in the new "Delivery" section in settings
    - Renamed original default behaviour to "auto-paste"
    - Moved "restore clipboard after paste" to new Delivery section.
- New feature: Generate markdown formatting using LLM post processor
    - Allow LLM post processor to format the output using markdown 
    - New toggle available in settings 
- Improved the reliability of the "polish" LLM setting
- Renamed lowest LLM post processing level from "Formatting" to "Basic" to improve clarity

## [1.1.1] - 2026-08-17
- Added in-app release notes
- Minor UI tweaks

## [1.1.0] - 2026-08-16
- App defaults to native included MacOS transcription model when starting fresh.
- Added support for live transcription streaming. Enable transcription streaming in Settings → Live streaming.
- Added support for streaming models and additional models.
- Improved software update checks.
- Added support for "Open at login" - new toggle available in Settings → General.
- Sidebar permission chips hide when microphone and Accessibility are both on.
- Stability and performance improvements
- Improvements for model download handling
- bugfix: fixed the issue where system theme wasn't respected

## [1.0.4] - 2026-08-15
- In-app Install Update verifies the downloaded app against the VoxBox signing team, so updates can complete after download.

## [1.0.3] - 2026-08-15
- Minor UI refresh.
- Optional daily update check in Settings → Updates, off by default. When on, VoxBox asks GitHub once a day at launch and prompts if a newer version is available. Manual Check for Updates is unchanged.

## [1.0.2] - 2026-08-15
- Added a copy last transcript to clipboard shortcut (default ⌃⌥C) under Settings → Shortcuts.
- Improvements to the post-transcription cleanup engine.
- Other system stability and performance improvements.

## [1.0.1] - 2026-08-15
- Onboarding is first-run only. Missing Accessibility no longer hides the dashboard.
- If transcript output no clear target, the transcript is copied to the clipboard instead.
- Permission status is visible in the sidebar.
- Models are scanned at launch so the first transcription does not cause an error.

## [1.0.0] - 2026-08-15
- First VoxBox release. 
- Bump minimum OS requirement to macOS 26. 
- Any existing SpeakType models migrate to VoxBox on first launch.
- Enhancements from SpeakType:
    - English (Australia) spelling conversion, offline.
    - Optional on-device AI cleanup: Formatting, Light cleanup, or Polish. Off by default.
    - Model download progress in the sidebar and menu bar, not only in AI Models.
    - Added option to copy transcript to clipboard after dictation (default off).
    - Add configurable audio and transcript raw file retention. Statistics are always kept.
    - Added custom key-combinations for invoke hotkey, and some extra single-modifier options.
    - Apply dictionary updates to the most recent transcript automatically. 
    - Improve smart cleanup with fixes for trailing punctuation for emails, URLs, numbers, and single words.
    - Recorder pill can be pinned to any of nine screen positions.

#### Security fix
- Utilise correct MacOS native logging rather than writing to `/tmp` & implement standard log protection
- Remove transcripts from system logs
- Remove all automatic outbound network activity by default, so app only reaches out to the internet once a user invokes a model download or a system update check.


_**Note:** For SpeakType's change history prior to VoxBox, refer to the [SpeakType Changelog](https://github.com/karansinghgit/speaktype/blob/main/CHANGELOG.md)._