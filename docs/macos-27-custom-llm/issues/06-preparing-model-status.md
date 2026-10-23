# 06 — Preparing-model status on the cleanup picker and Cleanup strip

**What to build:** After a user taps Use on a just-downloaded cleanup model (or launches with one selected), the catalog row and the Cleanup page strip show that the model is preparing until prewarm finishes. Apple Intelligence never shows that state. Failures surface with the existing download-error treatment, not a hung spinner.

**Blocked by:** 03, 05

**Status:** implemented

**Parallel with:** 07, 08, 09

**Pre-read:** [CONTRACTS.md](../CONTRACTS.md) accessory hook.

## Agent brief

**Current behavior:** `CleanupModelStatusAccessory` is `EmptyView`. First take after selecting Qwen/Llama can stall with no explanation while weights load.

**Desired behavior:**

- Replace only `CleanupModelStatusAccessory`. Drive it from pool/engine preparing state (a published flag or similar on the model manager or pool).
- Visible while `prewarm` / one-token warmup is in flight for the selected downloadable variant.
- Not visible for Apple Intelligence, for rows that are not selected, or once preparing finishes.
- Cleanup strip uses the same accessory so the two surfaces cannot disagree.

**Key interfaces:** `CleanupModelStatusAccessory`, preparing state on the pool or `PostProcessingModelManager`.

**Out of scope:** Download progress (already exists). Factory. Prompt text. History.

## Parallel-safety

Owns the accessory type and the Cleanup strip accessory slot if 03 left a placeholder. Prefer not to restyle the whole row. Must not edit engines’ cleanup math.

## Test Gate

- [x] T1: accessory/view model is preparing when the selected downloaded variant is warming, idle otherwise.
- [x] T1: selecting Apple Intelligence clears preparing.
- [ ] T4 note: after Use on a downloaded model, the row shows preparing then returns to Selected.

**Build order — red→green:** Tests for the preparing flag against today’s always-idle accessory (red). Then implement.

## Answer

`PostProcessingModelManager.preparingVariant` is the single source of truth. `selectedVariant` didSet (and init / successful re-download of the selected variant) turns it on, then `await makeLanguageModel().preload()` followed by `engine.prewarm(lightCleanup)` so JIT starts; a `defer` always clears the flag so `session.prewarm()` returning immediately cannot hang the spinner. Failures write `downloadError`. Apple Intelligence never prepares. Catalog row and Cleanup strip both use `CleanupModelStatusAccessory(model:)`, which observes `.shared`. `deleteModel` and leaving a variant call `CleanupSessionPool.shared.invalidate(variant:)`. T1 uses `beginPreparingForTesting` / `endPreparingForTesting` (no live weights). **TEST SUCCEEDED** (`CleanupModelPreparationTests` 6). Aikido `aikido_full_scan`: no issues.
