# Changelog

Changes and release notes for VoxBox.

## [1.3.0] - Unreleased
- **New**: Onboarding now asks how you want to record and how much cleanup you want.
    - A Recording page explains Hold to record and Toggle side by side and saves your pick (the same setting as Settings → Recording Mode and the recorder pill menu).
    - A Transcript cleanup page explains Off, Basic, Light cleanup, Polish and Custom, with a Preview button that runs a built-in sample dictation through all three built-in levels so you can compare them before choosing. Light cleanup is marked as recommended.
- **New**: Try cleanup on a sample before you dictate.
    - AI Models → LLM Instructions has a "Try it on a sample" panel under the effort picker. Pick one of three built-in dictations or one of your five most recent transcripts and run the current level on it.
    - The ruleset editor has the same panel, so a custom ruleset can be tested on real text while you write it, before saving.
    - History now keeps the engine text alongside the pasted text, so a ruleset is tested on what was actually said.
- Improved on-device cleanup quality and made Light cleanup trip the guardrail far less often.
    - Prompts rewritten: every level asks for sentence case (no title case, no ALL CAPS, no headings), single punctuation marks, and copies numbers, emails and URLs exactly. Basic no longer receives the Markdown stage, since it may not add characters.
    - The guardrail no longer charges for the edits Light cleanup is told to make: dropping um/uh, "you know", "sort of", filler "like", repeated words and false starts is free, contractions are compared expanded, and function-word or near-spelling fixes cost half. A retention floor still rejects summaries. Free deletions no longer count against that floor, which is what vetoed short chatty takes.
    - When a level is vetoed VoxBox steps down (Polish → Light → Basic) instead of pasting the raw text straight away.
    - A deterministic post-pass strips leaked labels, fixes doubled punctuation, undoes ALL-CAPS and Title Case runs the speaker did not dictate, and capitalises sentence and list-item starts. Emails and URLs are never touched.
- Fixed live streaming text getting stuck or jumping to the middle of the transcript.
    - Snapshot writes are now serialised and the newest one wins, so a write can never run inside another write.
    - In apps where accessibility writes are ignored (Slack, Notion, Superhuman, Cursor, web composers), VoxBox now types only committed words and never backspaces mid-take. Words still being revised show in the recorder pill.
    - Caret restore uses end-of-document instead of end-of-line, which is what caused text to land mid-paragraph once a take wrapped.
    - At the end of a take the cleaned transcript replaces the live text. In apps VoxBox writes through accessibility this is a verified in-place replace. In apps it types into, it removes exactly what it typed and pastes the cleaned transcript, so paragraph breaks arrive as soft breaks rather than a sent message. Only when the destination is no longer in front does the cleaned transcript go to the clipboard instead, with a message in the pill.
    - If the field or focus changes mid-take, live writing stops instead of writing into the wrong place.
    - Electron apps are detected from the app bundle, not just a list, so composers like Claude type correctly when text is already in the box. On web content VoxBox never moves the selection until a write has verified, which is what sent the caret to the start of the box.
    - Typed key events no longer inherit live modifier keys. Previously a held modifier could turn typed text into shortcuts (Cmd+Space opening Raycast, Cmd+A, sidebar toggles).
    - VoxBox no longer presses Cmd+Down before each burst in Electron apps, so dictating mid-text in Claude stays at the caret instead of jumping to the end. If an app is found to move the caret on its own, it can be listed explicitly.
    - WhisperKit streaming updates are delivered in order on one thread and skip updates with no text change.

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