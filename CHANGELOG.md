# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]
- Rebrand: the app is now **VoxBox** by **Cubbei Studios** (formerly SpeakType by 2048 Labs). The bundle identifier is unchanged for update/permission continuity.
- English (Australia) spoken-language option: transcribes as English and converts American spellings (color, organize, center) to Australian ones (colour, organise, centre), fully offline.
- Copy transcript to clipboard: completed transcripts now stay on the clipboard after dictation (default on, Settings → General).
- Data retention: recorded WAV files auto-delete after a configurable period (default 1 day) while transcripts are kept; transcripts themselves expire after a configurable period (default 30 days). Statistics are always preserved.
- Custom key-combination hotkey (e.g. ⌘D): record any combination in Settings → Shortcuts instead of a single modifier key, avoiding collisions with other apps.
- Quick dictionary corrections: fix a misheard word from a transcript's detail view — the rule is saved to the Dictionary, the transcript is rewritten, and the corrected text is recopied to the clipboard. Adding a rule in the Dictionary tab also retro-applies it to your most recent transcript.
- Privacy/egress hardening (see docs/SECURITY-AUDIT.md): removed the launch-time license validation call (which could also wipe a stored license when offline), removed the automatic update check at launch (updates are strictly manual), model loading can no longer silently download from Hugging Face, transcripts are no longer written to /tmp or printed to the console, temp audio chunks are deleted immediately, update downloads are restricted to trusted GitHub hosts, app self-replacement is atomic, the relaunch step no longer interpolates paths into a shell, transient auto-paste clipboard entries are marked concealed for clipboard managers, and the unused Apple-Events entitlement was dropped.
- Smart trailing punctuation: when a dictation is just an email address, URL, number, or single word, the sentence-final period the model adds is stripped so the text pastes clean. Default-on toggle in Settings → General → Transcript Cleanup.
- Recorder pill position: new setting under General lets the user pin the floating recorder to any of the 9 on-screen positions (4 corners, 3 mid-edges, top/bottom center). Default is bottom center.

## [1.3.0] - 2026-07-10
- 

## [1.2.3] - 2026-07-03
- 

## [1.2.2] - 2026-07-03
- 

## [1.2.1] - 2026-07-03
- 

## [1.2.0] - 2026-07-03
- 

## [1.1.0] - 2026-06-28
- 

## [1.0.29] - 2026-03-24
- 

## [1.0.28] - 2026-03-22
- 

## [1.0.27] - 2026-03-22
- 

## [1.0.25] - 2026-03-21
- 

## [1.0.24] - 2026-03-12
- 

## [1.0.23] - 2026-02-27
- 

## [1.0.22] - 2026-02-27
- 

## [1.0.21] - 2026-02-17
- 

## [1.0.20] - 2026-02-17
- 

## [1.0.19] - 2026-02-16
- 

## [1.0.18] - 2026-02-16
- 

## [1.0.17] - 2026-02-16
- 

## [1.0.16] - 2026-02-15
- 

## [1.0.15] - 2026-02-15
- 

## [1.0.14] - 2026-02-15
- 

## [1.0.13] - 2026-02-15
- 

## [1.0.12] - 2026-02-15
- 

## [1.0.11] - 2026-02-15
- 

## [1.0.10] - 2026-02-14
- 

## [1.0.7] - 2026-02-03
- 

## [1.0.6] - 2026-02-03
- 

## [1.0.5] - 2026-01-27
- 
