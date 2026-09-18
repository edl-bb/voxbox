# 03 — OS gate: unpark downloadable cleanup models on macOS 27 only

**What to build:** A Mac on macOS 27 sees the Llama/Qwen cleanup catalog, can download and select them, and the factory routes a downloaded selection to `FoundationModelsMLXCleanupEngine` (a throwing stub until ticket 05). A Mac on macOS 26 keeps today’s parked UI and always cleans up with Apple Intelligence. Stored 1.2 `.mlx` selections still resolve to Apple Intelligence while the OS gate is off.

**Blocked by:** 01

**Status:** resolved

**Parallel with:** 04, 07, 08

**Pre-read:** [CONTRACTS.md](../CONTRACTS.md) OSCapabilities, factory routing, `CleanupModelStatusAccessory` hook.

## Agent brief

**Current behavior:** `PostProcessingModel.downloadableModelsEnabled` is a compile-time `false`. Picker and Cleanup strip say models arrive with macOS 27. Factory would construct the MLX stub if the flag were true, but the stub throws.

**Desired behavior:**

- `OSCapabilities.customCleanupModels` is the only gate. It is true iff `#available(macOS 27, *)`.
- `PostProcessingModel.offered` and `PostProcessingModelManager.selectedModel` read that gate, not a boolean constant.
- On 27, coming-soon copy is gone. On 26, coming-soon copy remains.
- Factory routing matches CONTRACTS.md. Ticket 03 adds `FoundationModelsMLXCleanupEngine` as `@available(macOS 27, *)` and throwing `runtimeUnavailable` so 05 can fill the body without touching the factory.
- Insert `CleanupModelStatusAccessory` on each catalog row and on the Cleanup strip, implemented as `EmptyView`.
- Tests inject `OSCapabilities.testOverride` so catalog-on vs catalog-off is asserted on any machine.

**Key interfaces:** `OSCapabilities.customCleanupModels`, `OSCapabilities.testOverride`, `PostProcessingModel.offered`, `CleanupEngineFactory.engine(for:manager:)`, `FoundationModelsMLXCleanupEngine` stub.

**Out of scope:** Real MLX inference (05). Session pool (04). Preparing spinner (06). Prompt text. SPM (02).

## Parallel-safety

Owns OSCapabilities, offered/flag, factory routing, picker + strip copy, catalog tests. May add the stub engine type and the empty accessory. Must not edit the Apple Intelligence engine body or History/rulesets.

## Test Gate

- [x] T1: `testOverride = false` → `offered` is only Apple Intelligence; a stored mlx variant resolves to Apple Intelligence.
- [x] T1: `testOverride = true` → `offered` is the full catalog; factory returns `FoundationModelsMLXCleanupEngine` for a downloaded mlx variant.
- [x] T1: `testOverride = true` and not downloaded → factory returns Apple Intelligence.
- [x] T1: existing “downloadable models are parked” test is rewritten against the override, not a hardcoded `false`.
- [x] T4 note in the Answer: on a 27 Mac the picker shows four downloadable rows; on 26 it does not.

**Build order — red→green:** Write the override tests against today’s constant (`false` makes the “gate on” cases red). Then replace the constant with `OSCapabilities`.

## Answer

`OSCapabilities.customCleanupModels` (`#available(macOS 27, *)`, overridable via `testOverride`) is the only catalog/factory gate. `downloadableModelsEnabled` is now a computed alias. Coming-soon copy is hidden when the gate is on. `CleanupModelStatusAccessory(model:)` is an empty hook on each picker row and the Cleanup strip. `FoundationModelsMLXCleanupEngine` is an `@available(macOS 27, *)` throwing stub (`runtimeUnavailable`); ticket 05 fills the body.

Factory routing:

| Selection | Gate | Downloaded | Engine |
|---|---|---|---|
| `.appleSystem` | — | — | `AppleIntelligenceCleanupEngine` |
| `.mlx` | — | no | `AppleIntelligenceCleanupEngine` |
| `.mlx` | off | yes | `MLXCleanupEngine` (parked stub) |
| `.mlx` | on | yes | `FoundationModelsMLXCleanupEngine` |

Required tests: **TEST SUCCEEDED** (`PostProcessingModelTests` 14, `CleanupEngineFactoryTests` 7). Hosted on macOS 27; `testOverride=false` still parks the catalog. The test target also compiles sibling `CleanupSessionPoolTests` (ticket 04), which did not compile in this checkout — the command used `EXCLUDED_SOURCE_FILE_NAMES=CleanupSessionPoolTests.swift` so 03’s suites could run. Aikido `aikido_full_scan` on added/edited Swift: no issues.

T4: on this macOS 27 Mac the picker offers Apple Intelligence plus four downloadable Llama/Qwen rows and the coming-soon copy is gone. `testOverride = false` restores the parked UI (Apple Intelligence only, coming-soon copy stays). On a 26 Mac the same parked UI is the production path.
