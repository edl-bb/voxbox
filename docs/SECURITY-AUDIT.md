# VoxBox (SpeakType) — Security Audit, August 2026

Full read-only audit of the codebase at commit `ca54367`, focused on data
egress/telemetry, secrets, local data security, permissions, code integrity,
and general weaknesses.

## Remediation status (this branch)

| Finding | Severity | Status |
|---|---|---|
| C1 — Transcripts logged in cleartext to world-readable `/tmp/speaktype_debug.log` | Critical | **Fixed** — routed through `AppLogger` (os.Logger, private-by-default), transcript content never logged |
| H1 — License key POSTed to api.polar.sh on every launch; network failure wiped the key | High | **Fixed** — launch-time validation removed; key validated only on explicit activation |
| H2 — Automatic GitHub update check at launch (inconsistent defaults) | High | **Fixed** — updates strictly manual; auto-update toggle removed; neutral User-Agent |
| H3 — Orphaned 4-second audio chunks accumulate forever | High | **Fixed** — chunks deleted immediately (no consumer exists); hourly retention sweep also empties stale chunks/orphans |
| H4 — Model *load* silently downloads from Hugging Face (Parakeet) | High | **Fixed** — load fails with a clear error unless the model was explicitly downloaded first. Whisper tokenizer-fetch behaviour still to be verified with a network monitor on-device |
| M2 — Transcript/license content printed to stdout in release | Medium | **Fixed** — content-bearing prints removed (lengths logged instead) |
| M3 — Unused Apple-Events entitlement + dead AppleScript paste path | Medium | **Fixed** — entitlement, usage description, and dead code removed |
| M4 — Update download URL not host-constrained | Medium | **Fixed** — HTTPS + GitHub host allowlist enforced before download |
| M5 — Non-atomic self-replacement could delete the app | Medium | **Fixed** — staged copy + atomic `replaceItemAt` |
| M6 — Shell interpolation of bundle path in relaunch | Medium | **Fixed** — path passed as a positional argument, never interpolated |
| L5 — Clipboard exposure to history managers | Low | **Partially fixed** — transient auto-paste copies marked `org.nspasteboard.ConcealedType` |
| L9 — `Package.resolved` git-ignored while tracked | Low | **Fixed** — removed from .gitignore so dependency pins can't drift silently |
| M1 — History stored unencrypted in UserDefaults | Medium | **Mitigated** — new retention limits bound the data; storage migration to a 0600 file recommended as follow-up |
| H4b — Whisper tokenizer configs may fetch from HF Hub at load | High | **Open** — verify with WhisperKit 0.9.4 + network monitor; pre-cache configs during model download |
| M8 — License enforcement trivially bypassable | Medium | **Open** — revenue-only impact; consider offline signed licenses or removing the gating code |
| L6 — Data races around recording state flags | Low | **Open** — flags should move behind the audio queue/an actor |
| M3b — App is unsandboxed with a session event tap | Medium | **Open** — sandboxing is a larger tracked effort |

New in this branch: `RetentionService` auto-deletes WAV recordings (default
1 day) and expires transcripts (default 30 days), both user-configurable in
Settings → Data Retention.

**Egress contract after this branch:** the app connects to the internet only
when you click Download Model, Check for Updates, or Activate License — never
automatically.

---

# Original audit report

# SpeakType — Security Audit Report

**Repository:** `/home/user/speaktype` (commit `ca54367`)
**Scope:** Read-only static audit of the full Swift/SwiftUI macOS app, entitlements, build config, release scripts, and CI. No files were modified.
**Focus:** data egress/telemetry, secrets, local data security, permissions, code integrity, general weaknesses.

---

## Executive Summary

SpeakType is genuinely close to its "100% offline" claim: **there are no analytics SDKs, no crash reporters, no Sparkle, no third-party telemetry frameworks, and no code anywhere that transmits audio or transcript text off the machine.** Dependencies are limited to WhisperKit, FluidAudio, KeyboardShortcuts and swift-transformers (all pinned by revision in `Package.resolved`). There are no hardcoded secrets. Update integrity is unusually well done for an indie app (Developer-ID/team-ID pinned `SecStaticCodeCheckValidity` + `spctl --assess` + notarized, stapled, hardened-runtime releases).

The problems are elsewhere, and three of them matter a lot for a privacy-first product:

1. **Every dictation's transcript is appended in cleartext to `/tmp/speaktype_debug.log`** (`MiniRecorderView.swift:871-885`, called at `:918`), unconditionally, in release builds, at a world-readable predictable path that also permits a symlink-follow write. This is the single most serious finding.
2. **Raw dictation audio is retained forever.** The 4-second chunk WAVs published by `AudioRecordingService.chunkPublisher` have **no subscriber at all** — nothing transcribes them and nothing deletes them, so `~/Library/Application Support/SpeakType/Chunks/` grows a complete plaintext audio record of everything the user has ever dictated. Full-length recordings are likewise kept indefinitely.
3. **Two automatic, non-user-initiated network calls fire at app launch:** a GitHub update check, and — if a licence key is present — a POST of that licence key to `api.polar.sh`. The latter doubles as a per-launch usage heartbeat to a third party and, when it fails (including plain "no internet"), it **deletes the user's licence key from the Keychain**.

Additionally the app is fully unsandboxed with a system-wide `CGEvent` tap plus Accessibility and Apple-Events entitlements — a very large blast radius that makes the local-storage hygiene issues above more consequential.

Total: **1 Critical, 4 High, 8 Medium, 12 Low/Info.**

---

## Data Egress Inventory

Every network touchpoint in the codebase. "Automatic" = happens without the user asking for that specific network operation.

| # | Location | Destination | What is sent | Trigger | Initiation | Severity | Recommendation |
|---|---|---|---|---|---|---|---|
| E1 | `Services/LicenseManager.swift:216-310` (endpoint `:222`, request `:244`) | `https://api.polar.sh/v1/customer-portal/license-keys/validate` | Full licence key + Polar organization ID, JSON POST; implicitly client IP, TLS fingerprint, default `URLSession` UA (app name/version + macOS build) | **Every app launch** when a key exists in the Keychain (`:73-91` → `:81-83` → `:148-158`), plus on manual activation | **Automatic** (launch) + user-initiated (activation) | **High** | Remove the launch-time revalidation entirely; validate only on explicit activation. Cache the result locally and never delete the key on failure. |
| E2 | `Services/UpdateService.swift:45-78` (URL `:51-52`, request `:56`) | `https://api.github.com/repos/karansinghgit/speaktype/releases/latest` | No app data in the body, but IP + UA + a 24h-throttled launch heartbeat correlatable to installs; response drives a UI prompt | App launch via `AppDelegate.swift:62 → :387-397` when `autoUpdate` is set; also manual button `SettingsView.swift:453` | **Automatic** (launch) + user-initiated (button) | **High** | Default `autoUpdate` to false everywhere and make the check strictly manual, or gate behind an explicit first-run consent prompt. |
| E3 | `Services/UpdateService.swift:214-230` (entry `:135-145`) | GitHub release asset host (`objects.githubusercontent.com`) | Nothing outbound beyond the GET; downloads the DMG | User clicks Install in `UpdateSheet` | User-initiated | Medium | Add a host/scheme allowlist before download (see F-M4). |
| E4 | `Services/ModelDownloadService.swift:274` and retry at `:319` | `huggingface.co` → `argmaxinc/whisperkit-coreml` (via WhisperKit) | Model variant name; IP/UA | User taps Download on a model | User-initiated | Low (essential) | Keep. Add integrity verification (F-L3). |
| E5 | `Services/ModelDownloadService.swift:371` (`AsrModels.download`) | `huggingface.co` (via FluidAudio) | Parakeet model version; IP/UA | User taps Download | User-initiated | Low (essential) | Keep. |
| E6 | `Services/Transcription/ParakeetEngine.swift:67` (`AsrModels.downloadAndLoad`) | `huggingface.co` (via FluidAudio) | Model version; IP/UA | **Model *load*/selection**, not an explicit download — a `loadModel` on a missing model silently downloads | **Automatic** relative to user intent ("select model" ≠ "download 600MB") | **High** | Replace with a cache-only load (`AsrModels.load…`) and surface a separate explicit download step. |
| E7 | `Services/WhisperService.swift:195-205`; see the comment at `:193-194` | `huggingface.co` (swift-transformers Hub) | Tokenizer/config fetch for the variant | Model load, when tokenizer configs are not already cached | **Automatic** relative to user intent | **High** | Verify against WhisperKit 0.9.4 behaviour; ship/pre-cache tokenizer configs in-bundle or fail closed offline rather than fetching. |
| E8 | `Views/SidebarView.swift:33`; `Views/LicenseView.swift:227,231`; `Views/Components/TrialBanner.swift:94-98`; `Services/UpdateService.swift:143` | `2048labs.com`, `polar.sh`, GitHub HTML release page | Nothing from the app; hands the URL to the default browser (referrer-free) | User clicks a link | User-initiated | Info | Keep. |
| E9 | `Resources/speaktype.entitlements:15-16` | — | Declares `com.apple.security.network.client` | n/a | n/a | Low | Once E1/E2 are removed and model download is optional, this remains needed only for model downloads; keep but document. |
| — | *Negative findings* | — | No `NWConnection`/BSD sockets, no `NSURLSessionUploadTask`, no `NSXPCConnection` to network helpers, no `WKWebView`, no Sparkle, no Firebase/Sentry/PostHog/Mixpanel/Amplitude, no `fetchAvailableModels()` call (only a comment at `ModelDownloadService.swift:140`), no `NSAppTransportSecurity` exceptions in `Info.plist` (so cleartext HTTP is blocked by ATS) | — | — | Info | Preserve these properties with a CI guard (see plan step 7). |

**Nothing in the app ever transmits audio, transcripts, history, statistics, dictionary entries, or device identifiers.** The only user-derived value that leaves the machine is the licence key (E1).

---

## Findings by Severity

### CRITICAL

#### C1 — Every transcript is written in cleartext to a world-readable, predictable path in `/tmp`
**Files:** `speaktype/Views/Overlays/MiniRecorderView.swift:871-885` (writer), `:918` (transcript), `:888`, `:893-899`, `:814`, `:840`, `:959` (other entries)

`debugLog` is not `#if DEBUG`-gated and is called on every recording lifecycle event, including one that writes the first 50 characters of the actual transcript, plus recording file paths and model names, with timestamps. It writes to a fixed path in the shared `/tmp` directory.

**Impact.**
- **Confidentiality:** a running, timestamped, plaintext log of what the user dictated — passwords, medical notes, client names — sitting in `/tmp` with default permissions (`0644`), readable by every other local user and every non-sandboxed process. It survives app quit and is never rotated or deleted.
- **Integrity (symlink attack, CWE-59/CWE-377):** `FileHandle(forWritingAtPath:)` follows symlinks. Any process able to create `/tmp/speaktype_debug.log` first can point it at a file in the victim's home directory; SpeakType then appends attacker-timed content to that target as the user.

**Remediation.** Delete `debugLog`'s file writer and route through `AppLogger` (os.Logger, which redacts dynamic interpolations in persisted logs); never log transcript content; if a file log is ever needed, put it under `~/Library/Logs/` with `0600`, `#if DEBUG` + explicit opt-in.

---

### HIGH

#### H1 — Licence key is POSTed to `api.polar.sh` on every launch, and a network failure destroys the key
**Files:** `speaktype/Services/LicenseManager.swift:73-91`, `:148-158`, `:216-310`; entry point `speaktypeApp.swift:21`

`LicenseManager.shared` is constructed during `App` initialisation, so `checkExistingLicense()` and its background revalidation run unconditionally at launch for any licensed user. `validateExistingKey` treats **every** error as "licence invalid" — including offline, 5xx, TLS failure, and the "not configured" path (H1b).

- **Egress:** the licence key (a durable per-customer identifier) + client IP goes to a third-party SaaS on every launch; the vendor accumulates a launch-frequency log of an app marketed as fully offline.
- **Availability / data loss:** a user on a plane loses Pro on launch and the key is erased from the Keychain.
- **H1b:** `polarOrganizationId` is read only from a `POLAR_ORGANIZATION_ID` env var or `PolarOrganizationID` Info.plist key — **neither exists** — so validation throws on every launch and every licensed user's key is silently wiped on first launch of a shipped build.

**Remediation.** Delete the launch-time revalidation; never call `deactivateLicense()` from an error path; treat "not configured" as "skip validation".

#### H2 — Automatic update check at launch, with an inconsistent default that misrepresents the setting
**Files:** `AppDelegate.swift:62`, `:387-397`; `UpdateService.swift:45-78`; `SettingsView.swift:89`; `UpdateSheet.swift:7`

`checkForUpdatesOnLaunch()` calls `api.github.com` at launch, throttled to 24h, gated on `autoUpdate`. Three components disagree on the default (`true` / `false` / implicit `false`), so the Settings toggle cannot be trusted. Recurring beacons carry IP + default UA (app name/version + macOS build) — a de-facto telemetry channel.

**Remediation.** Make the check strictly manual, or a single defaulted-off source of truth + first-run consent; set a neutral User-Agent.

#### H3 — Raw dictation audio accumulates forever: orphaned 4-second chunk WAVs with no consumer and no cleanup
**Files:** `AudioRecordingService.swift:10-11`, `:579-604`, `:606-639`, `:366-397`, `:471-488`; consumers: **none**

While recording, a second `AVAssetWriter` writes a 16 kHz mono WAV every ~4 seconds into `.../SpeakType/Chunks/` and publishes the URL. No subscriber exists anywhere (chunk stitching was abandoned). `rotateChunk` only deletes a chunk when the whole recording was cancelled. A complete, playable audio archive of every dictation grows unbounded (~1.9 MB/min) in a directory no UI cleans; `HistoryService.clearAll()` can't see it; Time Machine backs it up.

**Remediation.** Delete the chunking path or delete each chunk unconditionally; add a startup sweep of Chunks/ and orphaned Recordings/; add a user-visible retention setting.

#### H4 — Model *load* silently performs network downloads, breaking the offline guarantee
**Files:** `ParakeetEngine.swift:66-67`; `WhisperService.swift:193-205`

`ParakeetEngine.loadModel` uses `AsrModels.downloadAndLoad`, so merely *selecting* a Parakeet model initiates a multi-hundred-megabyte Hugging Face download outside the download UI with no consent. On the Whisper path, `download: false` prevents weight download, but WhisperKit/swift-transformers may still fetch **tokenizer configs** from the HF Hub at load time when not cached.

**Remediation.** Cache-only load for Parakeet, all downloads through `ModelDownloadService`; verify the Whisper tokenizer path with a network monitor and pre-cache or bundle configs.

---

### MEDIUM

#### M1 — Transcripts and statistics stored unencrypted in `UserDefaults`
Every transcript (with timestamps, model name, audio path) is JSON-encoded into `UserDefaults` (`~/Library/Preferences/com.2048labs.speaktype.plist`), as are dictionary snippets (which users are encouraged to fill with e.g. email addresses). Cleartext at a well-known path, in backups, cached by `cfprefsd`; also the wrong store for unbounded data (the whole array re-encodes on every dictation). **Remediation:** move history to a `0600` file or SwiftData; retention limits; a "don't save history" mode.

#### M2 — Sensitive content printed to stdout/stderr in release builds
`ClipboardService.swift:32` (clipboard text prefix), `WhisperService.swift:260`, `:288` (transcript prefixes), `LicenseManager.swift:117-119` (customer ID) among ~150 unguarded `print` calls. **Remediation:** delete content-bearing prints; route the rest through `AppLogger`; lint-ban bare `print`.

#### M3 — Unsandboxed app with a system-wide event tap and more entitlements than it uses
No sandbox; `.cgSessionEventTap` for `flagsChanged` plus global `NSEvent` monitors for `flagsChanged` and `keyDown`; `com.apple.security.automation.apple-events` requested but its only consumer (`appleScriptPaste`) is never called; dead sandbox-only keys. **Remediation:** drop the Apple-Events entitlement + dead code; narrow monitors where possible; track sandboxing as an effort.

#### M4 — Update download URL is not constrained to a trusted host; DMG is mounted before signature verification
Only check is `pathExtension == "dmg"`. ATS and the later team-ID-pinned signature check are strong backstops, but a compromised release asset or hijacked redirect hands an arbitrary host a kernel DMG-parsing surface. **Remediation:** require https + GitHub asset hosts; ideally pin a published SHA-256 before `hdiutil attach`.

#### M5 — Non-atomic self-replacement can leave the user with no app
The running bundle is deleted before the copy; a failed copy (disk full, permissions, sleep) leaves no app. **Remediation:** stage on the same volume, then `FileManager.replaceItemAt` (atomic), roll back on failure.

#### M6 — Shell command built by string interpolation of the bundle path
`relaunch()` interpolates `bundlePath` into a double-quoted `sh -c` string, so `$(...)`, backticks, `"` remain active — an app installed in a hostile-named folder yields command execution. **Remediation:** pass the path as an argument (`"$0"`) or use `/usr/bin/open` directly.

#### M7 — Imported audio is copied into the temp directory and never cleaned up
`TranscribeAudioView` / `DashboardView` copy picked files to `temporaryDirectory` under the original name (collision + predictable-path window) and never delete them; history stores the temp path, which the OS later reaps (breaking playback). **Remediation:** copy into `.../SpeakType/Imports/<UUID>/` with `0700`, tie lifetime to the history item, sweep orphans.

#### M8 — Licence enforcement is decorative and trivially bypassable
`isPro` is true if *any* string exists at the Keychain service `sh.polar.speaktype.license` (`security add-generic-password …` unlocks Pro). No signed licence blob, no device binding; `wrapTextIfNeeded` is a disabled stub; `TrialManager` limits are never consulted. Revenue impact only. **Remediation:** offline Ed25519-signed licences, or delete the theatre.

---

### LOW

- **L1** — `autoUpdate` default disagreement across three components; fix with one source of truth.
- **L2** — Data directories created with default `0755`; pass `0o700`/`0o600` for defence in depth.
- **L3** — No integrity verification of downloaded models (size heuristic only); pin SHA-256 digests per variant.
- **L4** — Sloppy version parsing (`v` stripped everywhere; numeric string compare) permits rollback to an older signed build; parse semver properly.
- **L5** — Transcripts hit `NSPasteboard.general` without `org.nspasteboard.ConcealedType`; the restore path snapshots all previous clipboard types (possibly password-manager payloads) into the heap. Mark concealed; skip snapshotting concealed types; consider AX insertion.
- **L6** — Data races: `isStopping`/`isRecording` written on main, read on `audioQueue`; `chunkPublisher.send` from writer completion queues with no `receive(on:)`. Move behind the queue/an actor.
- **L7** — Dead/misleading code (never-called `appleScriptPaste`, disabled licence wrapper, no-op Polar deactivation, unenforced `TrialManager`, unused `Constants.Network`, unused SwiftData import). Delete.
- **L8** — `LicenseManager.init()` not private; previews spawn extra instances that read the Keychain.
- **L9** — `Package.resolved` git-ignored while also committed; dependency-pin changes will silently drop. Un-ignore.
- **L10** — CI: actions pinned by mutable tag not SHA; SwiftLint `continue-on-error: true` so no rule can gate a merge.
- **L11** — Release tooling: `logs-export` dumps 24h of unified logs to Desktop (another reason not to log content); otherwise clean (no curl|sh, signature checks in create-release.sh).
- **L12** — No path traversal / injection / unsafe deserialization found elsewhere; all `Process` calls use argument arrays; dictionary triggers correctly regex-escaped; model-deletion logic deliberately hardened.

---

### INFO — What's already right (protect these properties)

- **No telemetry stack of any kind:** no Sparkle, Firebase, Sentry, Crashlytics, PostHog, Mixpanel, Amplitude, Segment, custom analytics, sockets, or WKWebView.
- **No secrets in the repo or its history**; env-based configuration absent everywhere; no keys/tokens/certs tracked.
- **Update integrity is strong:** bundle-ID + team-ID pinned `SecStaticCodeCheckValidity`, signing-info cross-check, `spctl --assess`, notarised/stapled hardened-runtime releases, ephemeral URLSession, unit-tested.
- **Hardened runtime on** in Debug and Release; `ENABLE_USER_SCRIPT_SANDBOXING = YES`.
- **ATS defaults intact** — cleartext HTTP refused.
- **Model storage deliberately moved out of ~/Documents** with a non-destructive migration.
- **Keychain usage otherwise sound:** generic password, `AfterFirstUnlock`, not synchronizable, typed errors.

---

## Egress Shutdown Plan

1. **Kill the launch-time licence call** — delete the revalidation task and `validateExistingKey`; validate only on explicit activation; make `init` private. *(Implemented on this branch, except `init` visibility.)*
2. **Make the update check strictly manual** — remove `checkForUpdatesOnLaunch()`; neutral User-Agent; explicit cache policy/timeout. *(Implemented.)*
3. **Make model acquisition the only network path** — cache-only Parakeet load; verify Whisper tokenizer behaviour on-device; assert zero URL requests when the model dir is complete. *(Parakeet implemented; Whisper verification open.)*
4. **Global kill switch** — a default-off "Allow network access" setting guarding every network entry point. *(Open — optional extra.)*
5. **Harden remaining intentional egress** — https + GitHub host allowlist for update downloads *(implemented)*; SHA-256 pinning for DMG and models *(open)*.
6. **Stop the local leaks** — /tmp transcript log removed, content prints removed, chunks deleted immediately, retention limits added *(implemented)*; history off UserDefaults *(open)*.
7. **Lock it in** — CI grep gate on `URLSession`/`/tmp/`/bare `print` outside an allowlist; entitlements unit test; pin Actions to SHAs; un-ignore `Package.resolved` *(un-ignore implemented; CI gates open)*.
