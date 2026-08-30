# Bring-your-own LLM for transcript post-processing — research

Question: can VoxBox let users download and run their own preferred local LLM
for the cleanup pass, instead of (or alongside) Apple's built-in system model?

Short answer: **yes — MLX Swift is the right vehicle**, and the new custom
rulesets feature already gives us the prompt/temperature plumbing. This doc
records the options and a recommended path. (Researched Aug 2026.)

## Where we are today

The cleanup pass (`TranscriptFormatterService`) uses Apple FoundationModels —
the ~3B system model that ships with macOS 26. Zero download, zero network,
but fixed: FoundationModels on macOS 26 cannot load third-party weights (the
only extension point is LoRA-style adapters behind a special entitlement).

Notable: at WWDC 2026 Apple opened FoundationModels via a public
`LanguageModel` protocol on macOS 27 (in beta, ships fall 2026). Apple is
open-sourcing an `MLXLanguageModel` implementation, so once we can require
macOS 27, a user-chosen MLX model can back the exact same
`LanguageModelSession` API we already call. That makes the near-term
architecture decision easy: keep everything flowing through one seam.

## Options considered

| Option | Verdict |
|---|---|
| **MLX Swift** (`mlx-swift` + `mlx-swift-lm`, both MIT, Apple-maintained) | **Recommended.** Fastest on Apple Silicon for small models; downloads models from Hugging Face by repo ID with progress callbacks (same pattern as our WhisperKit/FluidAudio downloads); `ChatSession` API is a near drop-in for `LanguageModelSession`. Apple Silicon only. |
| **llama.cpp** (via SwiftLlama / LLM.swift / Kuzco wrappers) | Widest model compatibility (GGUF, Intel Macs) but slower than MLX on Apple Silicon and the Swift wrappers are small one-maintainer projects. Only worth it if we ever want "point at any GGUF file". |
| **Ollama** (HTTP to localhost:11434) | Zero inference code and users manage their own models, but requires a separately installed, running app — poor first-run UX. Worth offering later as an optional auto-detected backend, not the primary path. |
| **FoundationModels adapters** | Not user-downloadable models; entitlement-gated training pipeline. Skip. |

## Recommended approach

1. Introduce a small `TranscriptPostProcessor` protocol seam in
   `TranscriptFormatterService` (instructions + input + temperature → text).
   The FoundationModels session becomes one implementation.
2. Add MLX as a second implementation via SPM: `ml-explore/mlx-swift` and
   `ml-explore/mlx-swift-lm`. Reuse `ModelDownloadService` patterns (progress
   UI, disk validation, delete) for cleanup models; storage under the same
   App Support root.
3. Surface it in AI Models → Cleanup AI as a "Cleanup model" picker: Apple
   system model (default, zero download) plus a short curated download menu.
4. When macOS 27 is our floor, swap the MLX implementation to Apple's
   `MLXLanguageModel` behind the same seam and delete most of the glue.

### Starter model menu (4-bit MLX community builds)

| Model | Disk | RAM in use | Why |
|---|---|---|---|
| Llama 3.2 1B Instruct | ~0.7 GB | ~1.5 GB | Fastest; fine for punctuation/format-only |
| Qwen 3 1.7B | ~1.0 GB | ~2 GB | Best quality-per-byte; Apache-2.0 |
| Llama 3.2 3B Instruct | ~1.8 GB | ~3 GB | Strong instruction following; good default |
| Qwen 3 4B | ~2.3 GB | ~4 GB | Quality tier; gate on ≥16 GB RAM |

Cleanup is instruction-following, not reasoning, so 1B–4B is the sweet spot.
Gate 3B+ models on ≥16 GB physical RAM (reuse `DeviceCapability`). Qwen's
Apache-2.0 license is the cleanest to promote by default; Llama and Gemma
carry their own community licenses.

Effort estimate: ~1–2 days for load/generate behind the seam, a few more for
the download/manage UI (mostly reusing existing model-management components).

Verify exact file sizes on the `mlx-community` Hugging Face model cards
before shipping the download menu — the sizes above are approximate.
