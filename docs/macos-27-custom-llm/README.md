# macOS 27 custom cleanup models — master plan

> Orchestrator: read this, then [CONTRACTS.md](CONTRACTS.md), then [VALIDATION.md](VALIDATION.md), then the frontier tickets under [issues/](issues/). Implementers read CONTRACTS + their ticket only. Reviewers read VALIDATION + CONTRACTS + the diff.

Tickets live here (not `.scratch/`) so git worktrees used by parallel sub-agents receive the briefs.

Related research: [../byo-llm-post-processing.md](../byo-llm-post-processing.md). Glossary: [../../CONTEXT.md](../../CONTEXT.md) (Transcript cleanup, Preview, Guardrail, Step-down).

## Context & purpose

VoxBox 1.2 shipped a catalog of downloadable cleanup models (Llama 3.2 1B/3B, Qwen 3 1.7B/4B) behind a `CleanupEngine` seam. 1.3 parked the rows: the mlx-swift runtime spike does not compile next to WhisperKit 0.9.4. Cleanup on macOS 26 is Apple Intelligence only.

macOS 27 opens Foundation Models through a public `LanguageModel` protocol. Apple’s open-source `MLXLanguageModel` can back the same `LanguageModelSession` API we already call. This effort unparks the catalog **on macOS 27 only**, keeps macOS 26 on today’s code, and adopts a few 27-only UI and session-lifecycle practices.

**Outcome:** one binary, deployment target 26.0, SDK 27. On 26 the picker and factory behave as 1.3. On 27 a downloaded catalog model runs transcript cleanup on-device through `LanguageModelSession`.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Isolation | Worktree per ticket off the integration head. Merge only on a green Validation Report. |
| Deployment | `MACOSX_DEPLOYMENT_TARGET` stays 26.0. Branch at runtime with `#available(macOS 27, *)`. |
| Custom models | `MLXLanguageModel` + `LanguageModelSession`. Do not revive the mlx-swift tokenizer spike as a macOS 26 engine. |
| Privacy | On-device only. No Private Cloud Compute, Claude, Gemini, or other network LLMs. |
| Catalog | Keep the four 4-bit MLX models already listed on `PostProcessingModel.catalog`. RAM gates stay. |
| Session lifecycle | One live session per (variant, instruction fingerprint, temperature). `prewarm` before first respond. Invalidate on switch or delete. Never append prior takes onto the transcript. |
| Testing | Red-green on each ticket. Scripted engines for pipeline tests (already the seam). Hosted Foundation Models tests skip when the model or weights are absent — they fail loudly with the reason, they are not mocked. |
| Prompt text | Do not rewrite Light cleanup / Polish instructions unless ticket 09’s eval report says they regress on the 27 system model. |

## Stack & versions

| Area | Target | Gotcha |
|---|---|---|
| Xcode / macOS SDK | 27 | Ticket 02 must prove this before the MLX engine ticket starts |
| App deployment | macOS 26.0 | New types marked `@available(macOS 27, *)` |
| WhisperKit | 0.9.4 today | Pins `swift-argument-parser` 1.3.0; mlx-swift `encuda` previously failed against that pin |
| MLX bridge | `MLXFoundationModels` / `MLXLanguageModel` | Open-sourced for 27; confirm local-directory load vs Hugging Face `modelID` in ticket 02 |
| Foundation Models | SystemLanguageModel on 26 and 27 | Apple documents the on-device model **changes** on 27 — ticket 09 re-evals prompts |

## Repository layout (ownership)

See [CONTRACTS.md](CONTRACTS.md) for the frozen types and the per-ticket file-ownership table. Rule: a ticket **adds new files** or edits **only the files it owns**. Concurrent tickets never share a file.

## Orchestration protocol

Agents: **orchestrator** (this chat or a dispatching agent) + **implementer** (one sub-agent per unblocked ticket, own worktree) + **independent reviewer** (fresh context, never the implementer).

```
Wave A (parallel, no blockers)
  01 prefactor     02 toolchain spike     07 History swipe     08 ruleset reorder

Wave B (after 01)
  03 OS gate              04 session pool for Apple Intelligence

Wave C (after 02 + 03 + 04)
  05 MLX LanguageModel engine

Wave D (after 03 + 05)
  06 preparing-model status

Wave E (after 05)
  09 cleanup eval on 27

Wave F (after 05, 06, 07, 08, 09)
  10 independent review and integrate
```

**Critical path:** 01 → 03 → 05 → 09 → 10, with 02 on the same path into 05.

Per-ticket lifecycle:

1. **Gate-in** — every blocker is `Status: resolved` and merged to the integration head.
2. **Claim** — set `Status: claimed` on the ticket file before work.
3. **Red** — author the Test Gate as failing tests; commit `test:` with a legitimate red (assertion, not import failure).
4. **Green** — implement in-session. Do not skip or mock gate rows.
5. **Review** — independent reviewer runs [VALIDATION.md](VALIDATION.md), writes a Validation Report.
6. **Merge** — orchestrator merges on PASS only, then re-runs the cumulative suite.
7. **Resolve** — set `Status: resolved`, append `## Answer` with the gist, update [map.md](map.md).

Two-stage definition of done: **implemented** (green in the implementer’s worktree) is not **validated** (reviewer report). Only validated tickets merge.

## Testing philosophy

| Type | Meaning here |
|---|---|
| T1 | Pure unit tests: catalog, factory routing, OSCapabilities, session-key identity, ruleset order persistence. No model. |
| T2 | Hosted XCTest against the real on-device model or a downloaded MLX model. Skip-as-fail with a reason if the model or weights are missing — no fake `CleanupEngine` inside the live gate. |
| T3 | Preview path: run `TranscriptCleanupPreview` on a fixture take and assert the outcome’s engine display name and that output is non-empty and guardrail-clean. |
| T4 | Manual / UI: picker visibility on 26 vs 27, swipe, reorder. Record steps in the ticket Answer; reviewer repeats on a 27 Mac when hardware allows. |

Pipeline tests that inject `ScriptedCleanupEngine` stay; they are not the live gate for tickets 05 and 09.

## Phase index

| # | Ticket | Depends | Parallel with | Owns |
|---|---|---|---|---|
| 01 | Prefactor: split cleanup engines | — | 02, 07, 08 | engine file split only |
| 02 | Spike: MLXLanguageModel links | — | 01, 07, 08 | SPM / spike notes; no product engine |
| 03 | OS gate + unpark catalog | 01 | 04, 07, 08 | OSCapabilities, factory, offered catalog |
| 04 | Session pool (Apple Intelligence) | 01 | 03, 07, 08 | session pool, Apple engine, preview prewarm |
| 05 | MLX cleanup engine | 02, 03, 04 | — | 27 MLX engine type only |
| 06 | Preparing-model status | 03, 05 | 07, 08, 09 | status accessory + strip |
| 07 | History swipe actions | — | all except 10 | History cards |
| 08 | Ruleset drag-to-reorder | — | all except 10 | ruleset list + store order |
| 09 | Cleanup eval on 27 | 05 | 06, 07, 08 | eval report; prompt edits only if report requires |
| 10 | Review and integrate | 05–09 | — | Validation Report, merge, STATUS |

## End-to-end verification (after 10)

On a macOS 27 Mac: download Qwen 3 1.7B, set Cleanup to Light cleanup, dictate a filler-heavy take, confirm the pasted text is wording-faithful and the Cleanup strip names Qwen. Switch back to Apple Intelligence; next take still works. On a macOS 26 Mac (or a 27 build with the 26 path forced in tests): downloadable rows stay hidden and cleanup uses Apple Intelligence.

## What we are not doing

Custom `LanguageModelExecutor` unless ticket 02 proves `MLXLanguageModel` cannot load the catalog. Core AI `.aimodel` conversion. Dynamic Profiles. Network LLMs. Bumping the deployment target to 27. `TimelineView` in the menu bar icon.
