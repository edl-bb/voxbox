# 04 — Session pool: prewarm and reuse Apple Intelligence cleanup

**What to build:** Transcript cleanup on Apple Intelligence reuses one `LanguageModelSession` per (variant, instruction fingerprint, temperature) instead of allocating a session per request. Onboarding/Preview prewarm goes through that pool. Switching cleanup model or deleting weights drops the cached session. Prior takes never sit on the transcript.

**Blocked by:** 01

**Status:** resolved

**Parallel with:** 03, 07, 08

**Pre-read:** [CONTRACTS.md](../CONTRACTS.md) CleanupSessionPool.

## Agent brief

**Current behavior:** `AppleIntelligenceCleanupEngine.cleanup` constructs a new `LanguageModelSession` every call. `TranscriptCleanupPreview.prewarm` builds a throwaway session and calls `prewarm()`, so the first real take still pays cold start.

**Desired behavior:**

- A `CleanupSessionPool` (actor or equivalent) is the only cache.
- Apple Intelligence engine asks the pool to respond. Instructions stay on the session; `respond(to:)` input is this take only.
- Preview prewarm uses the same key it will use for Light cleanup / Basic as today’s compiled instructions (fingerprint the instruction stages).
- `invalidate(variant:)` runs when the selected cleanup model changes and when a downloadable model is deleted (Apple Intelligence variant too, if instructions change via ruleset — fingerprint change naturally misses the old key).
- Duration or a log line makes reuse observable for the reviewer (second cleanup with the same key is not a full session construct).

**Key interfaces:** `CleanupSessionPool`, `AppleIntelligenceCleanupEngine`, `TranscriptCleanupPreview.prewarm`.

**Out of scope:** MLX engine (05). Factory routing (03). UI spinner (06). Reasoning / Dynamic Profiles.

## Parallel-safety

Owns Apple Intelligence engine, Preview prewarm, new pool type. Must not edit factory routing or catalog.

## Test Gate

- [x] T1: two requests with the same key hit one pool entry; a different temperature or instruction fingerprint is a different key.
- [x] T1: `invalidate(variant:)` removes keys for that variant; a later request creates a new entry.
- [x] T1: the respond path does not pass previous take text as instructions or as accumulated transcript (assert the `userPrompt` / input equals this request’s input).
- [x] Existing generation-options tests still pass (greedy vs temperature).

**Build order — red→green:** Write pool key/invalidate tests against a yet-missing type (legitimate red). Then implement the pool and switch the Apple engine to it.

## Answer

`CleanupSessionPool` is an actor with `shared`. Key is `(variant, instructionFingerprint, temperature)` — fingerprint is `request.instructions` (joined stages). `userPrompt` is not in the key.

API:

- `prewarm(key:makeSession:)` — get-or-create `LanguageModelSession`, then `session.prewarm()` (Apple’s API is sync fire-and-forget; the actor method is still `async`).
- `respond(request:variant:makeSession:)` — same get-or-create, `respond(to: respondInput(for:), options: AppleIntelligenceCleanupEngine.generationOptions(for:))`. `respondInput` is `request.userPrompt` only.
- `invalidate(variant:)` — drops every key for that variant.
- Testing: `entryCount`, `hasSession(for:)`, generic `session(for:makeSession:)` (identity without a live model).

`AppleIntelligenceCleanupEngine.cleanup` uses `CleanupSessionPool.shared` with `PostProcessingModel.appleSystemVariant`. `TranscriptCleanupPreview.prewarm` uses the same pool and today’s compiled Basic/`.formatting` stages at temperature 0.

After each respond, macOS 27 clears `session.transcript.history` so prior takes are not conversation history. On 26 the property is get-only; the session object is still reused.

**Manager invalidate was skipped.** Ticket 03 owns `PostProcessingModelManager.swift`. Call `await CleanupSessionPool.shared.invalidate(variant:)` from `deleteModel` / `selectedVariant` didSet in 03/05/06. A fingerprint change already misses the old key; leftover sessions sit until invalidate or process death.

Reuse is visible in Console (`CleanupSessionPool` category): `create` vs `reuse` on get-or-create, plus respond duration.

Required tests: **TEST SUCCEEDED** (CleanupSessionPoolTests 5, TranscriptFormatterServiceTests including greedy vs temperature). Aikido `aikido_full_scan` on the four Swift files: no issues.
