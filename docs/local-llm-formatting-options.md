# Local LLM for transcript formatting — options assessment

Goal: a very small, fully offline model that cleans up a finished transcript —
paragraph breaks, spacing, punctuation consistency, light de-filler — without
gigabytes of weights or heavy RAM use, keeping the zero-egress guarantee.

## Recommended path: Apple Foundation Models framework (macOS 26+)

- Apple's on-device foundation model (~3B, quantised) ships **with the OS** —
  zero download, zero disk cost to the app, no network, Swift-native API
  (`import FoundationModels`), and it's optimised for exactly this class of
  task (rewriting, formatting, summarising short text).
- RAM/latency: runs on the Neural Engine; a one-paragraph cleanup is
  sub-second on Apple Silicon and memory is managed by the system.
- Constraints: requires macOS 26 (app currently targets 13.0+), so it must be
  a capability gate (`if #available(macOS 26, *)` + model availability check),
  with the feature hidden on older systems.
- This is the lowest-effort, lowest-footprint option and the only one with no
  model-distribution question at all.

## Fallback for older macOS: bundled tiny model via llama.cpp or MLX

If cleanup must work on macOS 13–15:

- **Model candidates (instruction-tuned, quantised Q4, on-disk size):**
  - Qwen3-0.6B (~0.5 GB) — surprisingly capable at mechanical reformat tasks
  - Gemma 3 1B (~0.8 GB) — strong quality/size ratio
  - SmolLM2-360M (~0.3 GB) — smallest useful; fine for spacing/paragraphing
  - Qwen3-1.7B (~1.2 GB) — the ceiling before "lots of gigabytes"
- **Runtime:** llama.cpp (Metal) via SwiftLlama or a thin C wrapper, or MLX
  via `mlx-swift`. Both are offline, MIT/Apache-licensed, and add ~10–20 MB
  of code. Peak RAM ≈ model size + ~0.5 GB scratch; a 0.6B Q4 model runs in
  well under 1.5 GB and streams ~50–100 tok/s on M-series.
- Distribute the model like the Whisper models: explicit user-initiated
  download in Settings → AI Models (never bundled in the DMG, never fetched
  implicitly), same integrity rules as the audit recommends.

## Design guardrails regardless of engine

- Constrain the prompt to *mechanical* edits ("fix spacing/paragraphs/casing;
  do not change words") and diff-check the output: if the token-level change
  ratio exceeds a threshold, fall back to the raw transcript. Small models
  occasionally rewrite meaning; the guardrail makes that harmless.
- Keep it opt-in (a "Format with on-device AI" toggle next to Auto Edit),
  default off, and run it after dictionary rules so user corrections win.
- Latency budget: only run on transcripts > ~1 sentence; for short dictations
  the existing SmartTrailingPunctuation/Auto Edit path is already right.

## Not recommended

- Anything served over an API (OpenAI, Anthropic, etc.) — violates the
  zero-egress requirement.
- 7B+ local models (Llama, Mistral) — multi-GB downloads and multi-GB RAM for
  marginal gains on a formatting task.
