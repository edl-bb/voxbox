# 07 — History swipe actions on macOS 27

**What to build:** On macOS 27, a History card in the existing scrolling stack supports swipe actions for Delete and Copy (the actions already offered on the card). On macOS 26 the cards stay as they are and the app still compiles.

**Blocked by:** None — can start immediately.

**Status:** resolved

**Parallel with:** 01, 02, 08, and later tickets except 10

**Pre-read:** [CONTRACTS.md](../CONTRACTS.md) ownership for 07. WWDC26 SwiftUI: swipe actions work outside `List` when the scroll container has `swipeActionsContainer()`.

## Agent brief

**Current behavior:** History is a `ScrollView` of cards, not a `List`. Copy/Play/Delete live on the card. Swipe actions do not work in that stack on macOS 26.

**Desired behavior:**

- Behind `#available(macOS 27, *)`, the History scroll container coordinates swipe actions. Trailing swipe includes Delete (destructive) and Copy of the shown transcript.
- Full-swipe Delete is allowed only if it asks the same confirmation the card’s Delete already uses (do not silently wipe a take).
- macOS 26: no swipe API calls; behaviour unchanged.
- Do not put `TimelineView` on the menu bar icon.

**Key interfaces:** History card, existing delete confirmation, copy-to-clipboard path already used by History quick actions.

**Out of scope:** Cleanup engines, catalog, `@Observable` rewrite of `HistoryService` unless it is required for swipe to compile. Clear All stays.

## Parallel-safety

Owns History list/cards only.

## Test Gate

- [x] T1: copy and delete helpers used by the swipe actions are the same ones the buttons use (no second delete path that skips confirmation).
- [x] App builds with deployment 26.0 (`#available` guards).
- [x] T4 note: on a 27 Mac, swiping a card reveals Delete and Copy; confirming Delete removes the row.

**Build order — red→green:** If there is no existing test that delete goes through confirmation, add one that fails if swipe would call `remove` directly. Then add swipe UI.

## Answer

Swipe is gated with `#available(macOS 27, *)` on two fileprivate View helpers in `HistoryView.swift`: `historySwipeActionsContainerIfAvailable()` calls `swipeActionsContainer()` on the History `ScrollView`, and `historyCardSwipeActions` adds trailing Delete (destructive, full-swipe) + Copy on each `HistoryCard`. Below 27 those modifiers return `self` with no swipe API calls.

Delete from the card button and from swipe both call `requestDelete` → `HistoryDeleteConfirmation.request`, which only parks `pendingItem` for the existing "Delete Transcript?" alert. `historyService.deleteItem` still runs only from that alert’s Delete button. Copy from the button and swipe both go through `copyShownTranscript` → `HistoryCardActions.copyText` (the shown transcript) → `copyToClipboard`. No `TimelineView` on the menu bar.

T1: `HistorySwipeActionsTests` — request parks the item and does not call `deleteItem`; dismiss leaves the take in History; copy uses the shown transcript, not raw.

T4 (27 Mac): open History with at least one take → trailing-swipe a card → Copy and Delete appear → Delete shows "Delete Transcript?" → confirm removes the row; Cancel leaves it.

```
xcodebuild test -scheme voxbox -destination 'platform=macOS' -only-testing:voxboxTests/HistorySwipeActionsTests CODE_SIGNING_ALLOWED=YES
```
**TEST SUCCEEDED** (3 tests).
