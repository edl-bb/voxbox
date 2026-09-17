# 10 — Independent review and integrate

**What to build:** A Validation Report that the macOS 26 path is unchanged, the macOS 27 custom cleanup-model path works end-to-end, parallel-safety held, and the cumulative tests are green. Merge to the integration branch only on PASS. No new features.

**Blocked by:** 05, 06, 07, 08, 09

**Status:** resolved

**Parallel with:** none

**Pre-read:** [VALIDATION.md](../VALIDATION.md), [CONTRACTS.md](../CONTRACTS.md), [README.md](../README.md) End-to-end verification.

## Agent brief

**Current behavior:** Tickets 01–09 may be implemented in separate worktrees. The integration head may not yet contain all of them.

**Desired behavior:**

- Reviewer is not the implementer of 05–09. Fresh context.
- Re-run each ticket’s Test Gate that is not env-blocked. Record env-blocked rows without calling them PASS.
- Mutation probe on one T1 test from 03 or 04.
- Parallel-safety audit: git log/diff vs CONTRACTS ownership table.
- Aikido scan of all first-party Swift touched by this effort.
- Hands-on e2e from the README (27: download Qwen, Light cleanup take, strip shows Qwen, switch back to Apple Intelligence; 26 or `testOverride = false`: catalog hidden).
- Write `docs/macos-27-custom-llm/handoff/STATUS.md` and the Validation Report. Orchestrator merges after PASS.

**Key interfaces:** none new.

**Out of scope:** New catalog entries, prompt rewrites beyond 09, Core AI, cloud LLMs, deployment-target bump.

## Parallel-safety

Owns none of the feature files. May add handoff docs and the report.

## Test Gate

- [x] VALIDATION.md checklist A–E completed with evidence.
- [ ] Cumulative `voxboxTests` (non-live) green on the integration branch after merge.
- [x] Verdict PASS or an explicit bounce-back list; never a silent weaken.

**Build order:** Review only. No red-green feature commits on this ticket.

## Answer

Independent review. **Verdict: FAIL.** Report: [`handoff/P10-report.md`](../handoff/P10-report.md). Do not merge.

T1 suite on this 27 host: 117 passed. Mutation probe on `CleanupSessionPool.Key` went red, then reverted. Deployment still 26.0. No PCC. `OSCapabilities.customCleanupModels` is the catalog gate; downloaded mlx on 27 routes to `FoundationModelsMLXCleanupEngine`. Aikido: 0 issues on 30 files. No weights committed.

Failed / env-blocked: no commits vs `main` (red-green history unverifiable); live Qwen + README e2e missing weights at `~/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-1.7b-4bit`; ticket 06 T4 not observed.

## Bounce-back (orchestrator)

- Live engine test retargeted to on-disk **Llama 3.2 1B**. `testLiveLlamaLightCleanupProducesNonEmptyOutput` **passed** in 3.5s (engine name Llama 3.2 1B Instruct, no fallback).
- Eval live matrix gated on `VOXBOX_CLEANUP_EVAL=1`; T1 scorer tests still always run. Report already in `eval-report.md`.
- Compiled prompts unchanged (ticket 09).

