# 01 — Prefactor: split cleanup engines

**What to build:** The Apple Intelligence engine, the parked MLX stub, the `CleanupEngine` protocol, and the factory each live as their own type/file so later tickets can own them without colliding. Behaviour of transcript cleanup is unchanged: same Preview, same Guardrail, same step-down.

**Blocked by:** None — can start immediately.

**Status:** resolved

**Parallel with:** 02, 07, 08

**Pre-read:** [CONTRACTS.md](../CONTRACTS.md) §2 ownership for ticket 01.

## Agent brief

**Current behavior:** Protocol, Apple Intelligence engine, factory, and MLX stub share one compilation unit. Any later ticket that fills in MLX or adds a session pool would edit the same file as the OS-gate ticket.

**Desired behavior:** Three (or four) separate types with the same public names and the same factory routing as today. Existing pipeline tests that inject `ScriptedCleanupEngine` stay green. Selecting Apple Intelligence still cleans up. The MLX stub still throws and the picker still hides downloadable rows.

**Key interfaces:** `CleanupEngine`, `AppleIntelligenceCleanupEngine`, `MLXCleanupEngine`, `CleanupEngineFactory.engine(for:manager:)`.

**Out of scope:** OS version branching, SPM, session reuse, picker copy, prompt text.

## Parallel-safety

Owns the current combined engine source and the files it splits into. Must not change catalog, picker, or package references.

## Test Gate

- [x] T1: existing `TranscriptCleanupPipelineTests` and formatter tests that use `ScriptedCleanupEngine` or `AppleIntelligenceCleanupEngine.generationOptions` still pass.
- [x] T1: factory still returns Apple Intelligence for `.appleSystem` and the stub for a downloaded `.mlx` variant (downloaded can be simulated the same way today’s tests do).
- [x] App scheme builds with deployment target 26.0.

**Build order — red→green:** If the split is purely mechanical, add a T1 that instantiates each engine type through the factory before moving files, prove it fails if a type is missing, then split. Do not change production behaviour in the same commit as a test-only commit unless the red is a new characterization test.

## Answer

Mechanical split only. `CleanupEngine` + `CleanupEngineError` + `CleanupEngineFactory` stay in `voxbox/Services/CleanupEngine.swift`. `AppleIntelligenceCleanupEngine` (including `generationOptions` and `systemModel`) moved to `voxbox/Services/AppleIntelligenceCleanupEngine.swift`. `MLXCleanupEngine.swift` untouched. Factory routing unchanged.

`CleanupEngineFactoryTests` covers `.appleSystem` → `AppleIntelligenceCleanupEngine`, `.mlx` when not downloaded → `AppleIntelligenceCleanupEngine`, and constructing `MLXCleanupEngine` against a temp directory (`isAvailable == true`, `cleanup` throws `runtimeUnavailable`). The factory’s downloaded-MLX branch is unchanged source; `PostProcessingModelManager` is `final` with disk-size `isDownloaded`, so that branch was not driven through the manager without writing ~60% of a catalog model’s bytes.

Required tests: **TEST SUCCEEDED** (CleanupEngineFactoryTests 4, TranscriptCleanupPipelineTests 23, TranscriptFormatterServiceTests 21). Isolated copy used HEAD project files because the shared checkout also had ticket 08 red `move` tests. Aikido `aikido_full_scan` on the three Swift files: no issues.
