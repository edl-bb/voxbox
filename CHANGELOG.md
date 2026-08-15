# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

VoxBox versions start at 1.0.0. This is a fork of SpeakType; earlier SpeakType releases are not listed here.

## [1.0.3] - 2026-08-15
- UI accents follow the VoxBox logo (deep blue, violet, teal) instead of the old orange and purple.
- Optional daily update check in Settings → Updates, off by default. When on, VoxBox asks GitHub once a day at launch and prompts if a newer version is available. Manual Check for Updates is unchanged.

## [1.0.2] - 2026-08-15
- Copy last transcript shortcut (default ⌃⌥C) under Settings → Shortcuts, for when auto-paste misses the field.
- Filler-word strip now applies to every pasted transcript, including Parakeet.
- Transcript Cleanup settings copy clarified so filler strip, stray-period, and on-device AI are distinct.
- Recorder capture setup stays off the main thread so the pill can appear without blocking recording.

## [1.0.1] - 2026-08-15
- Onboarding is first-run only. Missing Accessibility no longer hides the dashboard.
- If auto-paste has no target, the transcript is copied and the pill says so.
- Permission status stays visible in the sidebar, menu bar, and Settings.
- Menu bar recording animation no longer freezes the app.
- Models are scanned at launch so the first hotkey does not race an empty download map.
- Bundle identifier is `com.cubbei.VoxBox`.

## [1.0.0] - 2026-08-15
- First VoxBox release. Requires macOS 26. Existing SpeakType models migrate on first launch.
- Licensing and trial code removed.
- V-wave app icon; menu bar icon animates while recording.
- Model download progress in the sidebar and menu bar, not only in AI Models.
- Optional on-device AI cleanup: Formatting, Light cleanup, or Polish. Off by default.
- English (Australia) spelling conversion, offline.
- Copy transcript to clipboard after dictation (default on).
- Configurable audio and transcript retention. Statistics are always kept.
- Custom key-combination hotkey, in addition to single-modifier options.
- Quick dictionary corrections from a transcript; new rules also update the latest item.
- Smart trailing punctuation for emails, URLs, numbers, and single words.
- Recorder pill can be pinned to any of nine screen positions.
- No network at launch, no silent model downloads, and transcripts stay out of logs and `/tmp`.
