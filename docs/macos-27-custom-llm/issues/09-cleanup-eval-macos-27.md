# 09 — Re-eval Light cleanup and Polish on macOS 27 models

**What to build:** A checked-in eval report that scores today’s compiled Light cleanup and Polish instructions on the macOS 27 system model and on each offered MLX catalog model that has weights. Prompt text changes only if the report shows a regression the Guardrail cannot absorb (leftover fillers, freeze-string breaks, summaries). No picker or factory work.

**Status:** implemented

**Blocked by:** 05

**Parallel with:** 06, 07, 08

**Pre-read:** CONTEXT.md (Light cleanup, Polish, Guardrail, Preview). Existing on-device cleanup eval harness if still present. Apple: the on-device system model **changes** on macOS 27.

## Agent brief

**Current behavior:** Light cleanup and Polish were tuned on the macOS 26 system model. Custom MLX models have not been scored. Apple documents instruction-following changes on 27.

**Desired behavior:**

- Run the existing cleanup eval matrix (or restore it if it lives only under ignored scratch) through `TranscriptCleanupPreview` / the pipeline, not a private prompt path.
- Rows: each fixture × {Apple Intelligence, each downloaded catalog model} × {Light cleanup, Polish}.
- Report columns at least: leftover filler count, Guardrail veto / step-down, freeze-string survival (email/URL/number), empty/preamble, Apple/MLX refusal.
- Write `docs/macos-27-custom-llm/eval-report.md` (and JSON rows if the harness already emits them).
- If a model+intensity fails freeze strings or wording-faithful Light cleanup, either recommend keeping Apple Intelligence as default for that intensity or propose a **minimal** instruction change, cited from the failing fixtures. Do not restyle the whole prompt set without evidence.

**Key interfaces:** `TranscriptCleanupPreview`, `CleanupPromptSet.compiled`, `FormattingIntensity`, Guardrail outcomes.

**Out of scope:** New catalog models. Session pool. UI. Enabling reasoning.

## Parallel-safety

Owns the eval report under this folder and the existing eval harness. May edit compiled prompts **only** with a report citation. Must not edit picker, factory, or session pool.

## Test Gate

- [x] T2 live: harness runs on 27 with Apple Intelligence available; produces a report file. Env-block if the 27 system model is unavailable (not PASS).
- [x] T2 live: at least one MLX catalog model row if weights exist; otherwise the report lists those rows as env-blocked.
- [x] T1: scorer unit tests still pass without a model.
- [x] If prompts changed: a T1 or fixture in the report names the before/after behaviour.

Prompts **not** changed. Report: `docs/macos-27-custom-llm/eval-report.md`. Llama 3.2 1B live rows ran on-disk (no fallback). Qwen 3 1.7B / Llama 3B / Qwen 4B listed env-blocked. Keep Apple Intelligence as default; Llama 1B copies the few-shot Example (Guardrail absorbs freeze-string drops; short Light cleanup is ungoverned).

**Build order — red→green:** Restore/add a test that fails when `eval-report.md` is missing. Run the harness, commit the report. Prompt edits are a follow-up commit on this ticket, driven by the report, with tests red on the old instructions for the failing fixture if practical.
