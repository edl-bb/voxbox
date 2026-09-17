# VALIDATION — orchestrator and reviewer rules

Trust nothing claimed in the implementer’s summary. Verify directly. Merge only on a written Validation Report.

## 1. Separation of duties

- Implementer ≠ reviewer. Reviewer starts a **fresh context** with: this file, CONTRACTS.md, the ticket, and the diff against the integration head.
- Reviewer must not “quietly fix” the diff. Fail the report and bounce to the implementer.
- Orchestrator merges; reviewer does not push.

## 2. Cardinal rules

- **Trust nothing.** Re-run the Test Gate. Do not accept “tests passed on my machine” without the command output.
- **Clean-room.** Review in a worktree that is not the implementer’s.
- **Evidence.** Every gate row in the report has a command and a result.
- **Live / prove-it.** For tickets 05 and 09, observe real model output or a documented env-block (missing SDK, missing weights). Env-block is not a PASS.
- **Adversarial.** Mutation probe: break one assertion’s production path and confirm the test goes red, then revert.
- **Parallel-safety.** Diff touches only the ticket’s Owns / May add columns in CONTRACTS.md.
- **No partial credit.** One failed gate row fails the ticket.
- **Red-green history.** There is a `test:` commit that was legitimately red, then an impl commit that turns it green. If the work is a single commit, the reviewer reconstructs by temporarily reverting impl and re-running.

## 3. Reviewer checklist

**A. Build integrity**

- Fresh worktree from the ticket branch
- App still builds for macOS 26 deployment
- No unrelated files in the diff
- No secrets, licence keys, or model weights committed

**B. Test authenticity**

- Every Test Gate row has a test or a recorded T4 procedure
- Assertions exist (no empty tests, no `XCTAssertTrue(true)`)
- Live gates do not inject `ScriptedCleanupEngine` or stub Foundation Models
- Mutation probe on one T1 test
- Re-run the ticket’s tests twice

**C. Direct observation**

- Ticket 03: `OSCapabilities.customCleanupModels` is true under `#available(macOS 27, *)` and false otherwise; offered catalog matches
- Ticket 04: two cleanups with the same variant/instructions do not each pay full cold start (log, duration, or Instruments)
- Ticket 05: Preview of a fixture through the downloaded model returns text; display name is the catalog name; Apple Intelligence still runs when that model is selected on 26 (`testOverride = false`) or when weights are missing
- Ticket 06: selecting a just-downloaded model shows preparing until prewarm finishes
- Ticket 07: swipe reveals Delete (and Copy if the ticket added it) on a History card
- Ticket 08: drag order persists across launch
- Ticket 09: eval report exists and names leftover-filler / Guardrail / freeze-string results per model

**D. Diff / contract audit**

- Frozen primitives unchanged except by the ticket that ships them
- No PCC / network LLM types
- Deployment target still 26.0
- Prompt files unchanged unless 09’s report required it

**E. Security**

- Downloads still user-initiated
- No new network endpoints except Hugging Face (already used by the parked downloader) or none if 02 chose `modelID` download through MLX
- Aikido scan on first-party Swift the ticket added or edited

## 4. Auto-fail

- Mocking Foundation Models inside a live gate
- `XCTSkip` / `xfail` on a gate-covered test to go green
- Editing a file owned by a concurrent or frozen ticket
- Shipping `PrivateCloudComputeLanguageModel` or any cloud LLM
- Reviving the mlx-swift tokenizer/chat-template engine as the macOS 26 path
- Committing weights or secrets
- Tests authored after the implementation with no red phase
- A “red” that was only a missing import
- Menu bar `TimelineView` reintroduced

## 5. Per-ticket direct checks

| Ticket | Hands-on check |
|---|---|
| 01 | App builds; existing formatter/pipeline tests green; three engine types still exist as separate types |
| 02 | Written spike answer: links or does not, local-path vs modelID, WhisperKit pin resolution. If a package landed, a 27 SDK debug build succeeds |
| 03 | Unit tests for offered catalog on/off; picker copy no longer promises “coming with macOS 27” when the OS gate is on |
| 04 | Prewarm called from the existing onboarding/preview site; invalidate on model switch |
| 05 | Hosted Preview through downloaded Qwen 3 1.7B (or documented env-block); fallback to Apple Intelligence when weights missing |
| 06 | Accessory is non-empty while preparing; empty when Apple Intelligence is selected |
| 07 | Swipe on History card; 26 build still compiles (API behind `#available`) |
| 08 | Reorder persisted; 26 build still compiles |
| 09 | Report checked in; any prompt change is cited from the report |
| 10 | Cumulative suite + e2e scenario in README “End-to-end verification” |

## 6. Validation Report (required merge artifact)

Append to the ticket (or `handoff/P<nn>-report.md`):

```
# Validation Report — ticket <NN>
Verdict: PASS | FAIL

## Gate
| Row | Command | Evidence | Result |
|---|---|---|---|

## Authenticity
- Red-green history:
- Mutation probe:
- Parallel-safety (files vs CONTRACTS):
- Aikido:

## Env-blocked (not PASS)
| Test | Why | Unblock |

## Bounce-back
<none, or exact gaps for the implementer>
```

## 7. Merge gate + post-merge regression

Orchestrator merges only on Verdict PASS. After merge: run the voxboxTests suite that does not need the 27 SDK, plus any newly unblocked live tests. Tickets 01–09 remain green; do not weaken them.

## 8. Bounce-back

After two failed reviews on the same ticket, stop and escalate to the human with the reports. Do not loosen a gate.
