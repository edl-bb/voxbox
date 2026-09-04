# Changelog

Changes and release notes for VoxBox.

## [1.3.0] - Unreleased
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
- Fixed the previous clipboard being pasted instead of the transcript. After an auto-paste or the end-of-take replace in apps VoxBox types into, the old clipboard was restored 350 ms after Cmd+V. Electron composers such as Claude and Superhuman can read the pasteboard later than that, especially right after a long backspace burst, so they pasted the old image and the typed text was already gone. VoxBox now restores the clipboard only once the field visibly contains the pasted text, or after about three seconds when the field cannot be read.
- Improved on-device transcript cleanup.
    - Light cleanup no longer trips the guardrail for doing what it was asked. The guardrail now charges nothing for dropping fillers, false starts and repeats, half price for grammar and near-spelling fixes, and full price only for real wording changes. Short takes get an absolute allowance so a nine-word dictation can still lose its ums.
    - When a level does change too much, VoxBox steps down (Polish → Light → Basic) instead of pasting the raw transcript.
    - Rewritten prompts for Basic, Light and Polish with explicit sentence-case and punctuation rules. Basic no longer receives the Markdown stage, so it cannot add bold or headings to a dictation it was told not to change.
    - A deterministic post-pass tidies model output: leaked labels and "Here is the cleaned text" wrappers are stripped, doubled punctuation is collapsed, ALL CAPS and Title Case the speaker never dictated are reverted, and emails, URLs and numbers must survive or the pass is rejected.
    - Australian English spelling is applied after the model as well as before, so the model cannot re-Americanise.
    - Light cleanup and Polish now write spoken numbers as numerals ("twelve thousand five hundred dollars" → $12,500, "twenty percent" → 20%, "two pm" → 2pm). This is done deterministically after the model, so it happens even when the model ignores the instruction. Lone small numbers ("one of the reasons") and ambiguous runs ("twenty twenty six") are left as spoken.
    - Light cleanup and Polish also strip the unambiguous fillers deterministically after the model: um/uh-family words, "you know", "I mean", "sort of", "kind of" set off by commas, and back-to-back repeats ("I'm, I'm gonna", "the the"). Context-dependent words like "like" and "basically" stay the model's call.
    - Short takes are no longer left alone. Under the model's minimum length, Light cleanup and Polish still run the instant filler and numeral pass, so "um, yeah, send it" comes out clean without waiting on the model. Takes of a dozen content words or fewer are not governed by the edit budget at all, since two fillers out of six words is not a rewrite; emails, URLs and numbers stay protected, and empty or refused output is still rejected. Longer takes get a higher absolute edit allowance (Light 4, Polish 7).
    - Light and Polish prompts are rewritten as explicit must-do lists with a worked example each, which is what got the Apple model to actually fix "there" → "their" and "peak" → "peek" at Polish.
    - Auto Edit keeps paragraph breaks, never leaves an orphan comma, and only capitalises the word after a filler it removed from the start of a sentence.
    - History keeps the raw transcript alongside the cleaned one, so custom rulesets can be tested against what was actually said.
- Onboarding now covers the two choices new users tripped on.
    - A recording step asks whether you want to hold the hotkey while you talk or press it to toggle, with the copy naming your actual hotkey. Skip keeps the default.
    - A cleanup step runs one dictation through every level (Off, Basic, Light cleanup, Polish, Custom) on your Mac and shows the results side by side, so you choose by reading rather than guessing. Switch between three built-in dictations or paste your own. Custom creates a "My ruleset" and opens the editor after setup.
    - Progress dots on every step, and Settings › General gains "Replay the setup guide" so you can step through it again with your current choices preselected.
- New Cleanup page in the sidebar. The level (Off, Basic, Light cleanup, Polish, Custom), Markdown, instant filler removal, the stray-period rule and your custom rulesets now live in one place, with a preview that re-runs on a sample or your last take as you change the level. Settings › Transcript Cleanup links there, and the LLM Instructions tab has left AI Models.
- The recorder pill shows what it knows and what it is still deciding. While streaming into apps VoxBox types into, locked words are plain and words the engine may still revise are dimmed, next to a short slice of the live waveform.
- History detail gets a Cleaned / As spoken switch for takes recorded on 1.3 or later.
- Custom rulesets can be tested before saving. The ruleset editor gains a "Test this ruleset" panel that runs your unsaved instructions and temperature over a built-in dictation or one of your five most recent transcripts (the raw take when History kept it), shows the result with timing and how much changed, and can run Basic, Light cleanup or Polish alongside for comparison. Nothing is written to History.
- Downloadable cleanup models (Llama 3.2, Qwen 3) are parked until macOS 27. In 1.2.0 the picker offered them but every cleanup still ran on Apple Intelligence; the picker now shows only Apple Intelligence and says so. Any saved choice of a downloaded model resolves to Apple Intelligence. They return with macOS 27's native on-device model support.

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