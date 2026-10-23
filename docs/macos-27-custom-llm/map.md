# Map — macOS 27 custom cleanup models

## Notes

Frontier = tickets whose blockers are all `resolved`, status is `ready-for-agent`, and nobody has `claimed` them. Orchestrator dispatches those in parallel, one worktree each.

Work the critical path (02 → 05) with at least as much urgency as the independent UI tickets (07, 08).

## Decisions so far

- One binary, deployment 26, SDK 27, runtime `#available(macOS 27, *)`.
- Custom cleanup models use `MLXLanguageModel` + `LanguageModelSession`, not the parked mlx-swift tokenizer spike.
- On-device only: no Private Cloud Compute or partner cloud LLMs.
- Tickets live under `docs/macos-27-custom-llm/issues/` so worktrees see them (`.scratch/` is gitignored).

## Fog

- Whether `MLXFoundationModels` compiles next to WhisperKit 0.9.4 (ticket 02).
- Whether `MLXLanguageModel` loads from a local Application Support directory or only via Hugging Face `modelID` (ticket 02).
- Whether Light cleanup / Polish instructions still land on the 27 system model (ticket 09).

## Frontier (start here)

All implementation tickets 01–09 are resolved. Review: [10](issues/10-review-and-integrate.md) (bounce-back addressed: Llama 1B live PASS).
