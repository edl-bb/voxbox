# Validation Report — ticket 10
Verdict: FAIL

Reviewer is not the implementer of 01–09. No production code was changed except a reverted mutation probe on `CleanupSessionPool.Key`. Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a), SDK 27.0. Branch `feat/macos-27-custom-llm` is at `4b52a7c` (same commit as `main`); **all 01–09 work is uncommitted** in this working tree. `handoff/STATUS.md` still says tickets are not started and is stale.

Do not merge.

## Gate

| Row | Command | Evidence | Result |
|---|---|---|---|
| A. Fresh worktree | `git status`; `git log main..HEAD` | No reviewer worktree. Review ran in the implementer’s dirty tree. `main..HEAD` is empty. | FAIL |
| A. macOS 26 deployment | `rg MACOSX_DEPLOYMENT_TARGET VoxBox.xcodeproj/project.pbxproj`; `git diff main -- VoxBox.xcodeproj/project.pbxproj` | Four settings still `MACOSX_DEPLOYMENT_TARGET = 26.0`. Diff adds `MLXFoundationModels` + `MLXLLM` only; no deployment-target hunks. | PASS |
| A. Unrelated files | `git status --porcelain`; `git diff --stat main` | First-party Swift listed below. Also: `project.pbxproj`, `Package.resolved` (mlx-swift / mlx-swift-lm pins from ticket 02), `docs/macos-27-custom-llm/**`, `docs/byo-llm-post-processing.md` (+2 lines). No weights, no licence files. | PASS |
| A. Secrets / weights | `git status --porcelain`; `ls "~/Library/Application Support/VoxBox/postprocessing-models"` | No `safetensors` / keys in git. On-disk Llama 3.2 1B weights exist; Qwen 3 1.7B / Llama 3B / Qwen 4B dirs absent. None of those files are in the repo. | PASS |
| A. No PCC / network LLM | `rg PrivateCloudComputeLanguageModel --glob '*.swift'` | Zero matches. Factory/engines use `LanguageModelSession` + `MLXLanguageModel` / `SystemLanguageModel`. Linked products: `MLXFoundationModels`, `MLXLLM` only (no `MLXHuggingFace`). | PASS |
| B. Cumulative non-live suite | see command block below | 117 passed / 1 failed. The only failure is `FoundationModelsMLXCleanupEngineTests.testLiveQwenLightCleanupProducesNonEmptyOutput` (env-block). All listed T1 classes green, including `CleanupSessionPoolTests` after the mutation was reverted. xcresult: `/tmp/voxbox-t10-dd/Logs/Test/Test-voxbox-2026.09.16_20-57-28-+1000.xcresult`. Exit 65 because of the live test. | PASS (T1) / env-block (T2 Qwen) |
| B. Assertions exist | read Test Gate classes | Factory, catalog, pool key, ruleset `move`, history delete/copy, preparing flag, tokenizer/template tests all assert behaviour. No `XCTAssertTrue(true)` / `XCTSkip` on these gate tests. Live Qwen uses `XCTFail` with an env-block message, not skip. | PASS |
| B. Mutation probe (T1 ticket 04) | see mutation command below | Broke `CleanupSessionPool.Key` by appending `userPrompt` to `instructionFingerprint`. `CleanupSessionPoolTests` went **TEST FAILED**: `testTwoTakesWithTheSameInstructionsShareAKeyAndPoolEntry`, `testUserPromptIsTheRespondInputAndIsNotFingerprinted`. Reverted. Same class then passed in the suite run. xcresult: `/tmp/voxbox-t10-dd/Logs/Test/Test-voxbox-2026.09.16_20-54-45-+1000.xcresult`. | PASS |
| B. Red-green git history | `git log --oneline main..HEAD` | Empty. No `test:` then impl commits. Tickets claim red-green in Answers; there is no git evidence. Auto-fail: tests authored with no reconstructable red phase. | FAIL |
| C. Ticket 03 catalog gate | read `OSCapabilities.swift`, `PostProcessingModel.offered`, picker copy; `PostProcessingModelTests` + `CleanupEngineFactoryTests` | `customCleanupModels` is `#available(macOS 27, *)` unless `testOverride` is set. `offered` / `downloadableModelsEnabled` / `selectedModel` / picker copy all read it. Coming-soon copy is behind `if !OSCapabilities.customCleanupModels`. `testOverride=false` parks the catalog (tests passed on this 27 host). | PASS |
| C. Ticket 03/05 factory routing | read `CleanupEngineFactory`; `testFactoryReturnsFoundationModelsMLXWhenGateOnAndDownloaded` passed | `.appleSystem` → `AppleIntelligenceCleanupEngine`. `.mlx` not downloaded → Apple Intelligence. `.mlx` downloaded + gate off → `MLXCleanupEngine` stub. `.mlx` downloaded + gate on + macOS 27 → `FoundationModelsMLXCleanupEngine`. Factory also requires `#available(macOS 27, *)` because the type is `@available(macOS 27, *)`; on production 27 that matches `OSCapabilities.customCleanupModels`. | PASS |
| C. Ticket 04 session pool | `CleanupSessionPoolTests` (5/5 after revert); read `AppleIntelligenceCleanupEngine` + `TranscriptCleanupPreview.prewarm` | Key is `(variant, instructionFingerprint, temperature)`. Apple Intelligence and MLX `respond` go through `CleanupSessionPool.shared`. Preview `prewarm()` uses the pool. Cold-start timing / Instruments not re-observed. | PASS (T1) |
| C. Ticket 05 live Qwen | `testLiveQwenLightCleanupProducesNonEmptyOutput` | Failed: weights missing at `/Users/edlittle/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-1.7b-4bit`. T1 availability/fallback tests passed. Display name is the catalog name in those tests. | env-block (not PASS) |
| C. Ticket 06 preparing accessory | `CleanupModelPreparationTests` (6/6) | Accessory is non-empty while `preparingVariant` matches the selected MLX row; empty for Apple Intelligence. T4 “Use on a downloaded model shows Preparing…” not hands-on (would need Qwen or Llama selected in the app). Ticket 06 T4 checkbox is still open. | PASS (T1) / T4 not observed |
| C. Ticket 07 History swipe | `HistorySwipeActionsTests` (3/3); read `historyCardSwipeActions` | Delete + Copy behind `#available(macOS 27, *)`. T1 covers pending-delete and copy-of-shown-transcript. T4 swipe on a History card not repeated in the running app. | PASS (T1) / T4 not observed |
| C. Ticket 08 ruleset reorder | `CustomRulesetTests.testMoveFromIndexPersistsOrderAcrossStoreReload` passed | Drag order persists across store reload. `#available(macOS 27, *)` on the list. T4 drag-in-UI not repeated. | PASS (T1) |
| C. Ticket 09 eval report | read `docs/macos-27-custom-llm/eval-report.md` | Report checked in. Apple Intelligence: 12/12 ran, leftover fillers 0, freeze strings survived. Llama 3.2 1B: live (weights on disk); several Guardrail vetoes / example parroting. Qwen 1.7B / Llama 3B / Qwen 4B env-blocked. Prompts **not** edited (`git diff main -- voxbox/Services/Cleanup/CleanupPromptSet.swift` is empty), matching the report’s “keep compiled prompts”. | PASS (report) / Qwen rows env-block |
| C. Ticket 10 README e2e | not run | Qwen 3 1.7B is not downloaded, so “download Qwen, Light cleanup take, strip names Qwen, switch back to Apple Intelligence” was not observed. `testOverride = false` catalog-hidden path is covered by T1. | env-block (not PASS) |
| D. Frozen primitives | read `CleanupEngine`, `OSCapabilities`, `CleanupSessionPool.Key`, factory | Protocol unchanged. Pool key matches CONTRACTS. No `PrivateCloudComputeLanguageModel`. Deployment still 26.0. Menu-bar `TimelineView` not reintroduced (`MenuBarIconView.swift` unchanged vs main). | PASS |
| D. Prompt files | `git diff main -- voxbox/Services/Cleanup/CleanupPromptSet.swift` | Unchanged. | PASS |
| E. Downloads user-initiated | read manager / downloader | No implicit catalog fetch. Spike’s `#huggingFaceLanguageModel` was not used. Existing Hugging Face download URLs only. | PASS |
| E. Aikido | `aikido_scan_paths` on 30 first-party Swift files added/edited by this effort | `{"issues":[],"scanned_files":30}` | PASS |

Non-live suite command (this reviewer, once after revert):

```
cd /Users/edlittle/Dev/bb-projects/voxbox
xcodebuild test -scheme voxbox -destination 'platform=macOS' \
  -derivedDataPath /tmp/voxbox-t10-dd \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:voxboxTests/CleanupEngineFactoryTests \
  -only-testing:voxboxTests/PostProcessingModelTests \
  -only-testing:voxboxTests/CleanupSessionPoolTests \
  -only-testing:voxboxTests/CustomRulesetTests \
  -only-testing:voxboxTests/HistorySwipeActionsTests \
  -only-testing:voxboxTests/CleanupModelPreparationTests \
  -only-testing:voxboxTests/TranscriptCleanupPipelineTests \
  -only-testing:voxboxTests/TranscriptFormatterServiceTests \
  -only-testing:voxboxTests/LocalBPETokenizerTests \
  -only-testing:voxboxTests/ChatTemplateRendererTests \
  -only-testing:voxboxTests/FoundationModelsMLXCleanupEngineTests
```

## Authenticity

- Red-green history: **FAIL.** `git log main..HEAD` is empty. The whole effort is uncommitted. Per-ticket Answers claim a red phase; that cannot be reconstructed from git. Mutation probe is the only independent proof that a T1 assertion is live.
- Mutation probe: **PASS.** Production path broken, tests went red, change reverted. Command:

```
# Probe (reverted immediately after): in
# voxbox/Services/CleanupSessionPool.swift Key.init(request:variant:),
# instructionFingerprint became request.instructions + request.userPrompt
xcodebuild test -scheme voxbox -destination 'platform=macOS' \
  -derivedDataPath /tmp/voxbox-t10-dd \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:voxboxTests/CleanupSessionPoolTests
# ** TEST FAILED **
# CleanupSessionPoolTests.testTwoTakesWithTheSameInstructionsShareAKeyAndPoolEntry
# CleanupSessionPoolTests.testUserPromptIsTheRespondInputAndIsNotFingerprinted
# Revert: instructionFingerprint: request.instructions  (confirmed in file after revert)
```

- Parallel-safety (files vs CONTRACTS): **PASS with sequential-exception notes.** Ticket 10 owns none of the feature files. Sequential tickets were allowed to edit after blockers merged. Ownership vs the table (best-effort):

  **Production Swift vs `main` (modified):**
  - `voxbox/Models/CustomCleanupRuleset.swift` — 08
  - `voxbox/Models/PostProcessingModel.swift` — 03 (05 also added `extraEOSTokens`)
  - `voxbox/Services/Cleanup/TranscriptCleanupPreview.swift` — 04 prewarm
  - `voxbox/Services/CleanupEngine.swift` — 01 split, 03 factory routing
  - `voxbox/Services/PostProcessingModelManager.swift` — 03 gate + 06 preparing
  - `voxbox/Views/Screens/Cleanup/CleanupPageView.swift` — 03 copy + 06 accessory slot
  - `voxbox/Views/Screens/History/HistoryView.swift` — 07
  - `voxbox/Views/Screens/Settings/CleanupRulesetsSection.swift` — 08
  - `voxbox/Views/Screens/Settings/PostProcessingModelsView.swift` — 03

  **Production Swift vs `main` (untracked / added):**
  - `voxbox/Services/AppleIntelligenceCleanupEngine.swift` — 01 (04 wired pool)
  - `voxbox/Services/CleanupSessionPool.swift` — 04
  - `voxbox/Services/FoundationModelsMLXCleanupEngine.swift` — 03 stub, 05 body
  - `voxbox/Support/OSCapabilities.swift` — 03
  - `voxbox/Views/Components/CleanupModelStatusAccessory.swift` — 03 hook, 06 body
  - `voxbox/Services/Cleanup/MLX/{CatalogTokenizerLoader,ChatTemplateRenderer,LocalBPETokenizer,LocalModelFamily,LocalModelTokenizer}.swift` — 05 (CONTRACTS “May add: nothing else”; required by spike tokenizer gap; sequential exception, not a bounce-back)

  **Tests added/modified:** `CleanupEngineFactoryTests`, `PostProcessingModelTests`, `CleanupSessionPoolTests`, `CustomRulesetTests`, `HistorySwipeActionsTests`, `CleanupModelPreparationTests`, `TranscriptCleanupPipelineTests`, `ChatTemplateRendererTests`, `LocalBPETokenizerTests`, `FoundationModelsMLXCleanupEngineTests`, `CleanupEvalMacOS27Tests`.

  Frozen after ship: factory still only in `CleanupEngine.swift`; 05 did not rewrite routing. `MLXCleanupEngine.swift` untouched (26 parked stub). Tokenizer types are not used as a macOS 26 engine.

- Aikido: **PASS.** `plugin-aikido-aikido-mcp` / `aikido_scan_paths`, 30 files, `issues: []`.

## Env-blocked (not PASS)

| Test | Why | Unblock |
|---|---|---|
| `FoundationModelsMLXCleanupEngineTests.testLiveQwenLightCleanupProducesNonEmptyOutput` | No `config.json` at `~/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-1.7b-4bit` (dir missing). Failed in 0.377s; not skipped. | User-initiated download of Qwen 3 1.7B 4-bit, then re-run that test. |
| README e2e (ticket 10) | Same missing Qwen weights; not executed. | Download Qwen, Cleanup = Light cleanup, dictate a filler-heavy take, confirm strip names Qwen, switch back to Apple Intelligence. |
| Ticket 09 Qwen 1.7B / Llama 3.2 3B / Qwen 4B eval rows | Already recorded in `eval-report.md` as env-blocked. Llama 3.2 1B **did** run live. | Download those catalog variants if those rows must PASS. |
| Ticket 06 T4 preparing spinner | Needs a just-downloaded / selected MLX model in the running app. | After Qwen (or Llama 1B) is selected outside XCTest, confirm “Preparing…” then idle. |

## Bounce-back

Do not merge. Do not loosen gates. Exact gaps:

1. **Commit the work.** `feat/macos-27-custom-llm` has no commits vs `main`. Ticket 10 cannot integrate an uncommitted tree. Red-green history is unverifiable (VALIDATION auto-fail: tests with no reconstructable red phase). Orchestrator: commit 01–09 before any merge; do not treat this report as merge-ready.
2. **Unblock Qwen 3 1.7B** at `~/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-1.7b-4bit`, re-run `testLiveQwenLightCleanupProducesNonEmptyOutput`, and perform the README e2e (Light cleanup take names Qwen on the strip; Apple Intelligence still works afterwards).
3. **Ticket 06 T4:** after Use on a downloaded model, the catalog row and Cleanup strip show preparing until prewarm finishes. Still unchecked on the ticket.
4. **Do not ship a PASS on live MLX until (2).** T1 routing/catalog/pool/tokenizer tests are green on this host; that is not a live-gate PASS.

Not bounce-backs (recorded, not blocking a later PASS by themselves): Llama 1B eval quality (example parroting) is documented; 09 correctly left `CleanupPromptSet.compiled` alone and kept Apple Intelligence as default. Tickets 06 and 09 are still `implemented` rather than independently `resolved`. `handoff/STATUS.md` is stale (reviewer was not allowed to update it).
