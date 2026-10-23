# CONTRACTS — frozen primitives, parallel-safety, live testing

> Frozen after the ticket that introduces them. Need to change a frozen type? Add a new type. Do not widen a sibling ticket’s file.

Implementers: read this before your ticket. Reviewers: audit the diff against the ownership table.

## 1. Frozen primitives

### OSCapabilities (ticket 03 ships; then frozen)

```swift
enum OSCapabilities {
    /// Runtime: `#available(macOS 27, *)`. Replaces the compile-time
    /// `PostProcessingModel.downloadableModelsEnabled` boolean.
    static var customCleanupModels: Bool { get }
}
```

Every catalog/picker/factory branch reads this. Tests may inject an override **only** through a package-internal hook named `OSCapabilities.testOverride` (optional `Bool?`, nil in production).

### CleanupEngine (already ships; frozen)

```swift
protocol CleanupEngine {
    var isAvailable: Bool { get }
    var displayName: String { get }
    func cleanup(_ request: FormattingRequest) async throws -> String
}
```

The transcript cleanup pipeline, Preview, Guardrail, Post-pass, and step-down **do not change** in this effort except to consume a new engine.

### CleanupEngineFactory (ticket 03 ships the 26/27 branch; then frozen)

```swift
enum CleanupEngineFactory {
    static func engine(
        for model: PostProcessingModel,
        manager: PostProcessingModelManager = .shared
    ) -> CleanupEngine
}
```

Routing (locked):

- `.appleSystem` → `AppleIntelligenceCleanupEngine`
- `.mlx` and not downloaded → `AppleIntelligenceCleanupEngine` (never fail cleanup)
- `.mlx` and downloaded and `OSCapabilities.customCleanupModels == false` → existing stub engine (throws; UI never offers it)
- `.mlx` and downloaded and `OSCapabilities.customCleanupModels == true` → `FoundationModelsMLXCleanupEngine`

Ticket 03 may ship `FoundationModelsMLXCleanupEngine` as a throwing stub so the factory type-checks. Ticket 05 is the only later editor of that type.

### CleanupSessionPool (ticket 04 ships; then frozen)

Behaviour, not a required generic signature (macOS 26 has `LanguageModelSession` + `SystemLanguageModel`; the public `LanguageModel` protocol is 27):

- Key: `(variant, instructionFingerprint, temperature)`
- `prewarm` loads weights / warms the session before the first `respond`
- `respond` uses the cached session; does not append previous takes
- `invalidate(variant:)` drops sessions for that variant (model switch, delete, ruleset change that alters instructions)
- Apple Intelligence and MLX both go through the pool; they must not each invent a second cache

### Privacy (frozen)

Cleanup runs on-device. No `PrivateCloudComputeLanguageModel`, partner cloud packages, or HTTP LLM backends.

### Deployment (frozen)

`MACOSX_DEPLOYMENT_TARGET` remains 26.0. New 27-only types are `@available(macOS 27, *)`.

## 2. Parallel-safety — file ownership

A ticket may **add** files listed under “May add”. It may **edit** only “Owns”. It must not edit another ticket’s Owns column, even to “just wire it up” — use the hooks below.

| Ticket | Owns (edit) | May add | Must not touch |
|---|---|---|---|
| 01 | The current combined cleanup-engine source, split into protocol+factory / Apple engine / MLX stub | the new split files | catalog, picker, SPM |
| 02 | spike notes under this folder; Package.resolved / project package refs **only if the spike must land a compiling dependency** | spike log | engine product types, picker |
| 03 | `OSCapabilities`, `PostProcessingModel` offered/flag, factory routing, picker + Cleanup-strip **copy** that mentions macOS 27, tests for offered catalog | `OSCapabilities` source; throwing `FoundationModelsMLXCleanupEngine` stub; `CleanupModelStatusAccessory` empty hook | Apple engine body, session pool, History, rulesets, SPM unless 02 already landed it |
| 04 | Apple Intelligence engine, Preview `prewarm`, new pool type | `CleanupSessionPool` | factory routing, catalog, picker, MLX engine body |
| 05 | `FoundationModelsMLXCleanupEngine` body only | nothing else unless 02 required a package and 02 did not land it | factory, pool API, picker, prompts |
| 06 | `CleanupModelStatusAccessory`, Cleanup strip accessory slot | preparing-status view | factory, engines, History, rulesets |
| 07 | History list/cards | — | cleanup engines, catalog |
| 08 | custom ruleset store order + ruleset manager list | — | History, engines |
| 09 | eval fixtures/report under this folder or existing eval harness; compiled prompts **only if the report requires a change** | eval report | picker, factory, session pool |
| 10 | none (review + merge) | Validation Report, `handoff/STATUS.md` | feature scope |

### Hooks so later tickets do not edit earlier views

Ticket 03 inserts `CleanupModelStatusAccessory` on each cleanup-model row and on the Cleanup page strip, implemented as `EmptyView`. Ticket 06 replaces only that type.

Ticket 03’s factory names `FoundationModelsMLXCleanupEngine` for the 27 downloaded path. Ticket 05 fills it in. Factory source stays frozen after 03.

## 3. Operational rules

- Downloads stay user-initiated. Never fetch a cleanup model implicitly.
- Leftover 1.2 weights in Application Support count as downloaded on 27; they are ignored on 26 (rows hidden).
- First-load specialization may be slow; ticket 06 surfaces that. If `session.prewarm()` is a no-op for MLX, ticket 05 may do a one-token warmup after load, then reset so the warmup is not part of the next take’s transcript.
- Guardrail, Post-pass, and step-down stay in the pipeline. Custom rulesets still skip the Guardrail.

## 4. Testing

- **Red-green:** each ticket’s Test Gate is authored first. Red must be an assertion failure, not a missing symbol.
- **No mocks in live gates** (tickets 05, 09). `ScriptedCleanupEngine` remains valid for pipeline unit tests (ticket 01/03/04 T1).
- Hosted model tests: if `SystemLanguageModel` is unavailable or weights are missing, the test **fails with a message that names the missing env** (weights path, OS version). Do not `XCTSkip` a live gate to go green. Orchestrator records env-blocked reds on the exit contract.
- Exception: tickets 07–08 UI may use T1 for reorder persistence and T4 notes for swipe; they do not need a model.

### Env / machines

| Need | Unblocks |
|---|---|
| Xcode 27 + macOS 27 SDK | 02, 05 |
| A Mac running macOS 27 with Apple Intelligence available | 05 live gate, 09 |
| Disk for ~1 GB Qwen 3 1.7B 4-bit | 05 live gate, 09 MLX rows |
| A Mac running macOS 26 (or 27 with tests forcing `testOverride = false`) | 03 T1 is enough; T4 26 picker is best-effort |

## 5. Domain language

Use CONTEXT.md terms in tickets, tests, and UI copy: Transcript cleanup, Preview, Light cleanup, Polish, Guardrail, Step-down. User-facing copy still says “Apple Intelligence”, model names, and “Cleanup” — not “post-processing” or “LLM chain”.
