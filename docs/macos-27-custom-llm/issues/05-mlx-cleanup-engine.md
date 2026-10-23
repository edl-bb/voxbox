# 05 — Custom cleanup engine: downloaded MLX models run transcript cleanup on macOS 27

**What to build:** On macOS 27, with a catalog model downloaded, Light cleanup / Polish / Custom Preview and real takes run on that model through `LanguageModelSession` + `MLXLanguageModel`. Missing weights still fall back to Apple Intelligence. macOS 26 is unchanged. Guardrail, Post-pass, and step-down stay in the pipeline.

**Blocked by:** 02, 03, 04

**Status:** resolved

**Parallel with:** none on the critical path

**Pre-read:** [SPIKE.md](../SPIKE.md) (ticket 02’s answer), [CONTRACTS.md](../CONTRACTS.md) factory routing and session pool, CONTEXT.md (Preview, Guardrail).

## Agent brief

**Current behavior:** `FoundationModelsMLXCleanupEngine` (stub from 03) throws `runtimeUnavailable`. Pipeline then falls back to Apple Intelligence.

**Desired behavior:**

- Fill in `FoundationModelsMLXCleanupEngine` only. Use the construction method ticket 02 recorded (local directory preferred).
- Same instruction stages and generation options as Apple Intelligence (greedy for built-in levels, ruleset temperature for Custom). Never cap response tokens.
- Go through `CleanupSessionPool`. After download, the manager (or the engine’s first `isAvailable`) may prewarm; if SPIKE.md says `prewarm` is a no-op, do a one-token warmup and reset so it is not on the next take’s transcript.
- Map genuine model refusals to `CleanupEngineError.contentFilter`; other failures surface so the pipeline can fall back.
- `displayName` is the catalog name (e.g. “Qwen 3 1.7B”).
- Do not enable reasoning. Do not use Private Cloud Compute or partner cloud models.

**Key interfaces:** `FoundationModelsMLXCleanupEngine`, `MLXLanguageModel`, `CleanupSessionPool`, `FormattingRequest`.

**Out of scope:** Picker copy (03). Preparing accessory (06). Prompt rewrites (09). Custom `LanguageModelExecutor` unless SPIKE.md proved `MLXLanguageModel` cannot load the catalog.

## Parallel-safety

Owns `FoundationModelsMLXCleanupEngine` body only. Must not edit factory, pool API, picker, or compiled prompts. If 02 did not land the package, landing it here is allowed **only** as specified in SPIKE.md.

## Test Gate

- [x] T1: engine `isAvailable` is true when the directory exists, false otherwise (no network).
- [x] T2 live: on macOS 27 with Qwen 3 1.7B 4-bit weights present, `TranscriptCleanupPreview` of a short fixture at Light cleanup returns non-empty text and `displayName` is the Qwen catalog name. If weights or OS are missing, the test **fails** with that reason (env-block, not PASS).
- [x] T1: pipeline fallback — when the MLX engine throws `runtimeUnavailable` or weights are missing, Apple Intelligence still produces an outcome (use the existing fallback tests as the pattern; do not mock Foundation Models).
- [x] T1: generation options for deterministic requests remain greedy.

**Build order — red→green:** T1 availability + a hosted T2 that calls the stub (red: throw). Then implement. Leave T2 red if the SDK/weights are absent; record on the exit contract.

## Answer

`FoundationModelsMLXCleanupEngine` loads from the Application Support directory via `MLXLanguageModel` + `LanguageModelSession`, through `CleanupSessionPool.shared.respond` with `variant = model.variant`. Generation options are `AppleIntelligenceCleanupEngine.generationOptions(for:)` (greedy for built-in levels). `capabilities: []` — no reasoning. Guardrail/refusal map to `CleanupEngineError.contentFilter`; missing files throw `runtimeUnavailable` so the existing pipeline fallback runs.

`MLXLanguageModel` construction (SPIKE recipe, extra EOS tokens kept on the loaded config):

```swift
MLXLanguageModel(
  configuration: ModelConfiguration(directory: dir, extraEOSTokens: model.extraEOSTokens),
  capabilities: [],
  weightsLocation: { _ in dir },
  load: { configuration, _ in
    let context = try await LLMModelFactory.shared._load(
      configuration: configuration.resolved(modelDirectory: dir, tokenizerDirectory: dir),
      tokenizerLoader: CatalogTokenizerLoader(familyHint: …))
    return ModelContainer(context: context)
  })
```

`import MLXLLM` is required so the model factory is registered. Tokenizer: `CatalogTokenizerLoader` reads local `tokenizer.json` (`LocalBPETokenizer` / `LocalModelTokenizer`) and `ChatTemplateRenderer` for Llama 3 vs Qwen 3. Qwen cleanup defaults `enableThinking` to false (empty think tags) even if `additionalContext` is nil. macOS 26 `MLXCleanupEngine` stub is unchanged.

`isAvailable` requires `config.json` + `tokenizer.json` + at least one `.safetensors`. `displayName` is the catalog name. `engine.prewarm` calls the pool’s `prewarm` (`session.prewarm()`); no second one-token warmup.

T1 green (`FoundationModelsMLXCleanupEngineTests` availability/fallback/greedy, `CleanupEngineFactoryTests`, `TranscriptCleanupPipelineTests`, tokenizer tests). T2 **env-blocked**: Qwen 3 1.7B weights missing at `~/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-1.7b-4bit` (this Mac has Llama 3.2 1B only).
