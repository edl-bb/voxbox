# Spike log — MLXLanguageModel + WhisperKit

Ticket 02. Run on 2026-09-16.

**Env:** macOS 27.0 (26A428), Xcode 27.0 (27A266a), macOS 27.0 SDK, Apple Swift 6.4 (swiftlang-6.4.0.34.1). `MACOSX_DEPLOYMENT_TARGET` stayed **26.0**. Metal Toolchain 27A266a was not installed at the start of this machine’s Xcode 27 setup; `xcodebuild -downloadComponent MetalToolchain` was required before Cmlx’s `.metal` files would compile.

**SPM landed:** yes. `mlx-swift-lm` @ `c6446cf7bfb7cea76408013b614d4b2c530eaa03` (main; tag `3.31.4` has no `MLXFoundationModels`) plus a **root pin** of `mlx-swift` @ `2bebe4e9ad127758ebcd76c6ad45a1740d0d2852` (unreleased main, Linux-only CudaBuild). Linked products on the `voxbox` target: `MLXFoundationModels`, `MLXLLM`. WhisperKit stayed **0.9.4**.

## Answers required

### 1. Does a debug build against the macOS 27 SDK succeed with `MLXFoundationModels` linked next to WhisperKit 0.9.4?

**Yes — after pinning mlx-swift to main.** A naïve add of `mlx-swift-lm` (which resolves mlx-swift **0.31.6**) is red. The same graph with mlx-swift main overriding 0.31.6 is green.

Green command:

```bash
xcodebuild -project VoxBox.xcodeproj -scheme voxbox -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/voxbox-spike-dd2 \
  -skipPackagePluginValidation -skipMacroValidation \
  build
```

Resolved graph (excerpt):

```
mlx-swift-lm:  https://github.com/ml-explore/mlx-swift-lm @ c6446cf
mlx-swift:     https://github.com/ml-explore/mlx-swift @ 2bebe4e
whisperkit:    https://github.com/argmaxinc/WhisperKit @ 0.9.4
swift-argument-parser @ 1.3.0
swift-transformers @ 0.1.8
```

Result: `** BUILD SUCCEEDED **` (exit 0). Deployment target still 26.0.

Red command (mlx-swift-lm only → mlx-swift 0.31.6), after `-skipPackagePluginValidation` so the plugin was actually compiled:

```bash
xcodebuild -project VoxBox.xcodeproj -scheme voxbox -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/voxbox-spike-dd \
  -skipPackagePluginValidation -skipMacroValidation \
  build
```

Without the skip flag, Xcode 27 stops earlier:

```
Validate plug-in “CudaBuild” in package “mlx-swift”
error: Plugin CudaBuild must be enabled before it can be used
```

With the skip flag, 0.31.6 still fails compiling `encuda` against WhisperKit’s exact `swift-argument-parser` 1.3.0 pin (Swift 6 `#MutableGlobalVariable`):

```
/tmp/.../mlx-swift/Source/Encuda/encuda.swift:5:16: error: static property 'configuration' is not concurrency-safe because non-'Sendable' type 'CommandConfiguration' may have shared mutable state [#MutableGlobalVariable]
struct Encuda: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Compile.self, Link.self]
    )
}
ArgumentParser.CommandConfiguration:1:15: note: struct 'CommandConfiguration' does not conform to the 'Sendable' protocol
```

Same diagnostic in `encuda-compile.swift:6` and `encuda-link.swift:6`. This is the September 2026 `feat/mlx-cleanup-runtime` blocker, reproduced on the 27 SDK.

`3.31.4` is the latest mlx-swift-lm **tag** and does **not** ship `MLXFoundationModels`. That product exists only on `main` (this spike pinned `c6446cf`). mlx-swift’s latest **tag** is still `0.31.6`; the Linux `#if os(Linux)` gate around `CudaBuild` / `encuda` is on **untagged main**.

### 2. If not, what unblocks it while keeping deployment 26?

Chosen way out (landed): **pin mlx-swift to main**, where `Package.swift` only registers `CudaBuild`/`encuda`/`swift-argument-parser` inside `#if os(Linux)`. On macOS the plugin is not in the graph, so WhisperKit’s 1.3.0 pin is irrelevant. mlx-swift-lm’s constraint is `.upToNextMinor(from: "0.31.6")` (`>= 0.31.6, < 0.32.0`); a **root** Xcode package pin of mlx-swift at a git revision overrides that. Confirmed by `swift package resolve` in a throwaway graph that also depended on WhisperKit 0.9.4 exactly.

Other ways (not used):

| Option | Verdict |
|---|---|
| Isolate the MLX product so CudaBuild is not in the app target | **Does not help.** 0.31.6 attaches `CudaBuild` to `Cmlx`, which `MLX` → `MLXFoundationModels` always pulls. SPM still builds the plugin. The `FoundationModelsIntegration` trait only empties `MLXLanguageModel`; it does not drop mlx-swift. |
| WhisperKit 1.x / unpin argument-parser | Would also work. WhisperKit 0.9.4 pins `swift-argument-parser` **exact** `1.3.0`. Current WhisperKit `main` uses `from: "1.3.0"` and the library target no longer depends on ArgumentParser (only the CLI does). That is a product upgrade, not required once mlx-swift is pinned to main. |
| Wait for tagged mlx-swift 0.32 + mlx-swift-lm bump | Cleaner long-term. Ticket 05 can drop the root mlx-swift pin when that ships. |

Ticket 05 must keep linking **`MLXLLM` as well as `MLXFoundationModels`**. `MLXFoundationModels` does not depend on `MLXLLM`; without the LLM module, `loadModelContainer` throws `noModelFactoryAvailable`.

Do **not** link `MLXHuggingFace` until WhisperKit unpins `swift-transformers` 0.1.8. The Hugging Face macros want `swift-transformers` ≥ 1.3.0 and `swift-huggingface` ≥ 0.9.0.

GUI / CI: with the main pin there is no CudaBuild on macOS, so the Xcode “enable plugin” prompt should not appear. The green app build still passed `-skipPackagePluginValidation -skipMacroValidation` as belt-and-suspenders.

### 3. Local Application Support directory vs Hugging Face `modelID`?

**Use the local Application Support directory.** `#huggingFaceLanguageModel` is the convenience path and would download itself into HubCache — that fights our existing `PostProcessingModelManager` downloader and would pull `swift-transformers` 1.3.0.

Catalog Hugging Face repos already on `PostProcessingModel` map 1:1 onto `LLMRegistry` entries (extra EOS tokens included):

| Catalog `huggingFaceRepo` | `LLMRegistry` | `extraEOSTokens` |
|---|---|---|
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | `llama3_2_1B_4bit` | `<\|eot_id\|>` |
| `mlx-community/Qwen3-1.7B-4bit` | `qwen3_1_7b_4bit` | `<\|im_end\|>` |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | `llama3_2_3B_4bit` | `<\|eot_id\|>` |
| `mlx-community/Qwen3-4B-4bit` | `qwen3_4b_4bit` | `<\|im_end\|>` |

Weights live at `PostProcessingModelManager.storageDir(for: variant)`. Availability checks look for `config.json` under `weightsLocation(modelID)`.

Citation — `MLXLanguageModel` designated init (`Libraries/MLXFoundationModels/MLXLanguageModel.swift`):

```swift
public init(
    configuration: ModelConfiguration,
    capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration],
    configurationResolver: any ModelConfigurationResolver = DefaultConfigurationResolver(),
    weightsLocation: @Sendable @escaping (String) -> URL,
    load: @escaping ContainerLoader
)
```

Local load API (`Libraries/MLXLMCommon/ModelFactory.swift`) — no `Downloader`, no Hub:

```swift
public func loadModelContainer(
    from directory: URL,
    using tokenizerLoader: any TokenizerLoader
) async throws -> sending ModelContainer
```

Throwaway that **compiled** (xcodebuild scheme `MLXSpikeMainPin`, macOS 26.0 deployment, macOS 27 SDK, WhisperKit 0.9.4 + mlx-swift main in the same graph):

```swift
import Foundation
import FoundationModels
import MLXFoundationModels
import MLXLLM
import MLXLMCommon

@available(macOS 27, *)
enum SpikeConstruct {
    static func model(from directory: URL) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(directory: directory),
            capabilities: [],
            weightsLocation: { _ in directory },
            load: { _, _ in
                try await loadModelContainer(
                    from: directory,
                    using: UnimplementedTokenizerLoader())
            })
    }

    static func session(from directory: URL) -> LanguageModelSession {
        let model = model(from: directory)
        let session = LanguageModelSession(model: model)
        session.prewarm()
        return session
    }
}

struct UnimplementedTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any Tokenizer {
        throw TokenizerError.missingChatTemplate
    }
}
```

Ticket 05 must replace `UnimplementedTokenizerLoader` with a real `TokenizerLoader` that reads `tokenizer.json` from that directory. `#huggingFaceTokenizerLoader()` is **not** available without swift-transformers 1.3.0. WhisperKit’s 0.1.8 `AutoTokenizer.from(modelFolder:)` can load from disk but has **no Jinja `applyChatTemplate`**; mlx-swift-lm’s `Tokenizer` protocol requires it. Carry the 1.2-era Llama 3 / Qwen 3 chat-template adapter, or wait for a WhisperKit upgrade that allows transformers 1.x.

`#huggingFaceLanguageModel(configuration:)` expands to HubCache `weightsLocation` + `#hubDownloader()` + `#huggingFaceTokenizerLoader()` (`Tests/MLXHuggingFaceMacrosTests/LanguageModelMacroTests.swift`). Do not use it for the catalog.

Cleanup does not need `.guidedGeneration` / `.toolCalling` / `.reasoning` / `.vision`. Pass `capabilities: []` unless ticket 05 later wants `@Generable`.

### 4. Is `session.prewarm()` a no-op for `MLXLanguageModel`?

**No.** It loads weights **and** runs the one-token Metal warmup. Ticket 05 does **not** need a second one-token generate after `prewarm()`.

`LanguageModelSession.prewarm()` is Apple’s synchronous fire-and-forget API. The MLX witness is `MLXLanguageModel.Executor.prewarm(model:transcript:)` (`Libraries/MLXFoundationModels/MLXLanguageModel.swift`). The authors warn that if the signature does not match the protocol **exactly**, “the framework's no-op default silently wins instead.” The checked-in witness matches.

That method `Task { try await model.warmUp() }` and returns immediately. Failures are logged (`subsystem: com.apple.FoundationModels-MLX`, category `Prewarm`), not thrown.

`warmUp()` (internal):

1. `loadContainer` — downloads if needed, otherwise loads weights into the process-global `ModelCache`.
2. Builds the xgrammar `GrammarTokenizer` (CPU).
3. Runs a 1-token generate inside `container.perform` so Metal shaders JIT before the first real `respond`.

Public `preload()` is **weights only** (awaitable, throws). First `respond` after `preload()` still pays Metal JIT. `session.prewarm()` is the one that amortizes JIT.

Ticket 06 (preparing status): `prewarm()` returning immediately does not mean the model is hot. Use `preload()` (await) and/or poll `MLXLanguageModel.availability` (`.downloading` vs `.available`). A warmup of an already-on-disk model is **not** reported as `.downloading`.

## Commands log

```text
$ sw_vers && xcodebuild -version && xcrun --sdk macosx --show-sdk-version
ProductVersion: 27.0
Xcode 27.0 / Build 27A266a
27.0

$ xcodebuild -downloadComponent MetalToolchain
Done downloading: Metal Toolchain 27A266a.
Status: installed
```

Red (0.31.6) and green (main pin) `xcodebuild` lines are in answers 1–2.

## Ticket 05 recipe

1. Depend on already-landed products `MLXFoundationModels` + `MLXLLM` (`@available(macOS 27, *)`).
2. `let dir = PostProcessingModelManager.storageDir(for: model.variant)`.
3. `MLXLanguageModel(configuration: ModelConfiguration(directory: dir), capabilities: [], weightsLocation: { _ in dir }, load: { _, _ in try await loadModelContainer(from: dir, using: loader) })`.
4. Copy `extraEOSTokens` from the matching `LLMRegistry` row onto the directory configuration if the factory does not already.
5. `LanguageModelSession(model:)` then `session.prewarm()`; do not invent a second warmup.
6. Do not add `MLXHuggingFace` / `#huggingFaceLanguageModel` while WhisperKit 0.9.4 pins transformers 0.1.8.
