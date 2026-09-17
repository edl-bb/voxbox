# 02 — Spike: MLXLanguageModel links beside WhisperKit

**What to build:** A written answer, checked into this folder, that tells ticket 05 exactly how to depend on `MLXLanguageModel`. The product picker and engines do not change. If a dependency can land without breaking the 26 deployment build, land it; otherwise record the blocker and the way out.

**Blocked by:** None — can start immediately.

**Status:** resolved

**Parallel with:** 01, 07, 08

**Pre-read:** [../README.md](../README.md) Stack & versions; [../../byo-llm-post-processing.md](../../byo-llm-post-processing.md) Status (September 2026).

## Agent brief

**Current behavior:** Downloadable cleanup models are parked because mlx-swift 0.31.x’s `encuda` plugin failed to compile in Swift 6 against `swift-argument-parser` 1.3.0, which WhisperKit 0.9.4 pins. Apple now publishes `MLXLanguageModel` for the macOS 27 SDK (`import MLXFoundationModels`; `MLXLanguageModel(modelID:)`).

**Desired behavior:** The spike answer states, with commands and build log excerpts:

1. Whether a debug build against the macOS 27 SDK succeeds with `MLXFoundationModels` linked next to WhisperKit 0.9.4.
2. If not, which of these unblocks it: WhisperKit 1.x (or whatever unpins argument-parser), isolating the MLX product so the Cuda plugin is not in the app target, or another way that keeps deployment 26.
3. How to construct the model for our catalog: local Application Support directory (preferred, reuses the existing downloader) versus Hugging Face `modelID` (framework downloads itself).
4. Whether `session.prewarm()` actually loads weights for `MLXLanguageModel`, or ticket 05 must do a one-token warmup.

**Key interfaces:** `MLXLanguageModel`, `#huggingFaceLanguageModel` if that is the supported entry, `LanguageModelSession`.

**Out of scope:** Implementing `FoundationModelsMLXCleanupEngine`. Changing Light cleanup / Polish prompts. Custom `LanguageModelExecutor`. Network LLMs.

## Parallel-safety

May edit Package.resolved and the Xcode package refs **only** if the spike produces a compiling dependency that ticket 05 needs. Must not edit engine product types or picker UI. Write the answer as `docs/macos-27-custom-llm/SPIKE.md`.

## Test Gate

- [x] T1/build: either `xcodebuild` for the app scheme succeeds with the chosen dependency on the 27 SDK, or SPIKE.md records the exact compiler error and the chosen way out (and does not merge a red package).
- [x] SPIKE.md answers local-path vs `modelID` with a citation (header, sample, or a tiny throwaway snippet that compiled).
- [x] SPIKE.md answers whether `prewarm` is a no-op for MLX.

**Env:** Xcode 27 + macOS 27 SDK. If those are missing, leave this ticket claimed, keep SPIKE.md as env-blocked, and do not `XCTSkip` a green — the ticket stays unimplemented until the SDK exists.

**Build order — red→green:** Add the package on a spike branch; the first `xcodebuild` is the red. Only commit package files to the integration branch if the build is green.

## Answer

Naïve `mlx-swift-lm` → mlx-swift **0.31.6** is red next to WhisperKit 0.9.4 (`encuda` vs argument-parser 1.3.0 Sendable). Pinning **mlx-swift main** (`2bebe4e`, Linux-only CudaBuild) plus `mlx-swift-lm` main (`c6446cf`, the tag has no `MLXFoundationModels`) makes a 27-SDK debug `voxbox` build green at deployment 26.0. Landed those two package refs.

Ticket 05: local Application Support directory via `ModelConfiguration(directory:)` + `loadModelContainer(from:using:)`, not `#huggingFaceLanguageModel`. Link `MLXLLM` too. `session.prewarm()` loads weights and does the 1-token Metal warmup (fire-and-forget, not a no-op). See [SPIKE.md](../SPIKE.md).

