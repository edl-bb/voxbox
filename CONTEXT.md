# VoxBox

Privacy-first on-device dictation for macOS. Speech is transcribed on the Mac; nothing is sent to a cloud speech API.

## Language

**Starter**:
The zero-download transcription model that lets someone dictate immediately.
_Avoid_: Recommended (when meaning the first-run default)

**Recommended**:
The catalog model the product pitches as the best speed, size, and accuracy fit.
_Avoid_: Starter; rating adjectives such as Excellent or Great

**Engine**:
A transcription backend that can run one or more models.
_Avoid_: Model (when meaning the backend)

**Model**:
A specific speech-to-text variant offered in the catalog — downloaded or installed as a system asset.
_Avoid_: Engine

**Catalog**:
The set of models VoxBox offers on the model page.

**Published benchmark**:
A speed, size, or accuracy number from a primary source — a paper, official model card, or first-party docs — not a timing measured on one Mac.
_Avoid_: Benchmark (unqualified); score (the hand-set 0–10 bars)

**Streaming decode**:
The engine emits text while audio is still being captured. On the model page the tick is **Streaming**.
_Avoid_: Live; After stop; Streaming (when meaning paste, the HUD, or live delivery)

**Batch decode**:
The engine returns text only after capture ends. On the model page the tick is **Batch**.
_Avoid_: After stop; block transcription; file-in (when speaking to the user); Live

**Live delivery**:
Putting decoded text into the target app, or the VoxBox HUD, before the take ends.
_Avoid_: Streaming; auto-paste (the one-shot Cmd+V at the end of a take)

**Stable token**:
A prefix the model has committed and will not rewrite.
_Avoid_: Partial; hypothesis

**Revisable text**:
A hypothesis that may still change (Apple’s volatile results; uncommitted streaming tokens).
_Avoid_: Final; stable token

**Streaming mode**:
An explicit user setting that asks for live delivery. If the current model can stream, it stays selected. Picking a Batch model turns streaming off and toasts that VoxBox reverted to batch. Turning the setting on while a Batch model is selected leaves it on and asks for a Streaming model on Settings.
_Avoid_: Streaming model (when meaning the setting)

**Copy transcription to clipboard**:
Copies only (no live write, no Cmd+V). Stream transcription is live delivery into the destination text area as tokens appear.
_Avoid_: Auto paste (when meaning clipboard-only copy)

**Stable-only typing**:
Live delivery into a keystroke-only target: only stable tokens are typed, nothing is deleted mid-take, and the revisable text stays in the HUD. At the end of the take the cleaned transcript replaces the typed text only when the field can be verified; otherwise the typed text stays and the cleaned transcript is copied to the clipboard.
_Avoid_: Append-only (in user-facing copy); live revise

**Coverage stage**:
A slice of target apps live delivery is validated against, in order: AppKit text, then browsers, then Electron. Browsers are confirmed. Electron composers (Cursor, Slack, Superhuman) need Chromium `AXManualAccessibility` and a frontmost app to find the focused `AXTextArea`; AX set is a no-op there, so live write types Unicode key events.
_Avoid_: App coverage (unqualified); future map (when meaning browsers or Electron)

**AppKit editable text**:
A focused `NSTextField`, `NSTextView`, or field editor that reports the live-write Accessibility attributes settable at runtime. Notes, Finder, Music, and the Messages composer (`messageBodyField`) are in this class. An empty field may report no `AXValue` yet and still be writable.
_Avoid_: Native Mac app (when meaning this class); AppKit (unqualified)

**Native Mac app**:
A first-party or AppKit-hosted application. Not enough for live write until the focused element is proven AppKit editable text.
_Avoid_: AppKit editable text

## Transcript cleanup

**Transcript cleanup**:
The post-decode chain that turns engine text into what gets pasted.
_Avoid_: Post-processing; LLM chain; formatting (when meaning the whole chain)

**Auto Edit**:
The optional deterministic strip of spoken um/uh-family fillers.
_Avoid_: Light cleanup; Polish; filler removal (unqualified)

**Basic**:
The on-device intensity that only changes capitals, punctuation, spacing, and breaks — never words.
_Avoid_: Formatting; Light cleanup; Polish; transcript cleanup (the whole chain)

**Light cleanup**:
The wording-faithful on-device intensity: drop fillers, false starts, and repeats; fix obvious grammar; keep the speaker's words otherwise.
_Avoid_: Polish; Basic; Auto Edit

**Polish**:
The meaning-faithful on-device intensity: may fix phonetic substitutions and smooth choppy dictation while keeping the speaker's message. Still drops fillers.
_Avoid_: Light cleanup; Basic

**Wording-faithful**:
Keeping the speaker's words, except fillers, false starts, repeats, and obvious grammar. The Light cleanup contract.
_Avoid_: Fidelity (unqualified); meaning-faithful

**Meaning-faithful**:
Keeping the speaker's message when wording may change. The Polish contract.
_Avoid_: Fidelity (unqualified); wording-faithful

**Guardrail**:
The change-ratio budget that discards on-device cleanup if the edit is too heavy, leaving the pre-model transcript.
_Avoid_: Guide rails; safety filter; Apple `guardrailViolation` / `refusal` (the system model's content filter)

**DEBUG tuner**:
A development-only in-app editor for cleanup instructions and guardrail budgets. Release builds use the compiled values.
_Avoid_: Transcript Cleanup (the production Settings section)
