# 08 — Drag-to-reorder custom rulesets on macOS 27

**What to build:** On macOS 27, the custom ruleset list on the Cleanup page can be dragged into a new order, and that order persists. On macOS 26 the list still compiles and keeps tap-to-select / edit / delete.

**Blocked by:** None — can start immediately.

**Status:** resolved

**Parallel with:** 01, 02, 07, and later tickets except 10

**Pre-read:** [CONTRACTS.md](../CONTRACTS.md) ownership for 08. WWDC26 SwiftUI: `.reorderable()` on `ForEach` and `.reorderContainer(for:)` on the stack.

## Agent brief

**Current behavior:** Custom rulesets render in a `VStack` `ForEach`. Order is whatever the store serializes. No drag reorder.

**Desired behavior:**

- Behind `#available(macOS 27, *)`, the ruleset stack is a reorder container. Applying `ReorderDifference` updates the store and persists.
- Active ruleset identity does not change because of a reorder.
- macOS 26: no reorder API; existing buttons remain.
- Still capped at the existing maximum ruleset count.

**Key interfaces:** `CustomRulesetStore`, ruleset identifiers, persistence of the ordered array.

**Out of scope:** History, engines, picker, changing what Custom sends to the model.

## Parallel-safety

Owns custom ruleset store order and the ruleset manager list.

## Test Gate

- [x] T1: applying a move from index i to j persists; a new store instance loaded from the same defaults sees that order.
- [x] T1: active ruleset id is unchanged after reorder.
- [x] App builds with deployment 26.0.

**Build order — red→green:** Write persist-order tests against today’s store (red if there is no `move` API). Then implement move + UI.

## Answer

Store API (tests and UI share one persist path):

- `CustomRulesetStore.move(from:to:)` — index move with `Array.move(fromOffsets:toOffset:)` semantics (`to` is the insertion index before the move). Used by T1.
- `CustomRulesetStore.moveRulesets(ids:before:)` — ID-based apply for `ReorderDifference` (`.before(id)` / `.end` → `before: nil`). Both call a private `move(fromOffsets:toOffset:)` that writes the ordered JSON and does **not** touch `activeRulesetID`.

UI: `#available(macOS 27, *)` puts `.reorderable()` on the `ForEach` and `.reorderContainer(for: CustomCleanupRuleset.self)` on the `VStack`. macOS 26 keeps New / Edit / Delete with no reorder modifiers. Cap remains `CustomRulesetStore.maximumRulesets` (5).

T1 (`voxboxTests/CustomRulesetTests`): `testMoveFromIndexPersistsOrderAcrossStoreReload`, `testReorderDoesNotChangeActiveRulesetID`. Full suite **TEST SUCCEEDED** (14 cases) via:

```
xcodebuild test -scheme voxbox -destination 'platform=macOS' -only-testing:voxboxTests/CustomRulesetTests CODE_SIGNING_ALLOWED=YES
```

(run against HEAD’s package graph in a separate DerivedData; the integration branch’s in-progress MLX package from ticket 02 currently fails `encuda` / Metal toolchain before voxbox compiles.)

T4: on this macOS 27 Mac, open Cleanup → Custom → drag a ruleset row; order should stick after relaunch; the selected radio should stay on the same ruleset.
