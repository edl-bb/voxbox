# Transcript cleanup review — October 2026

Why cleanup felt slow, unstable and inaccurate, what changed, and how to measure it from now on. Sources: a read of 91 History takes (kept local, never committed), the new cleanup eval (`evals/cleanup/`), and independent read-only reviews by Codex and Cursor. Findings all three agreed on come first.

Example sentences below are invented to show each failure pattern.

## What the History showed

The takes were mostly Apple Speech, cleaned on Apple Intelligence with the 1.3 (v2) prompts. Most were requests to colleagues or to AI agents. The failures were consistent:

| Pattern | Invented example of the failure |
|---|---|
| Answering or re-voicing the request | "Can you also put together a checklist…" → "You can also put together a checklist…" |
| Point of view flipped | "when I add up the line items, I get…" → "when you add up the line items, you get…" |
| Meaning inverted or summarised | "we don't need to send it back… it can just go straight to print" → "It needs another round." |
| Prompt example pasted into a cut-off take | "…the thing that would really help is if we" → "…if we remember to peek at the quote." |
| Contractions expanded, voice formalised | "Yeah, there's…" → "Yes, there is…"; "I'll" → "I will" |
| Lists made out of prose | a sentence naming five tools became five bullets |
| Lowercase after the instant filler strip | "Yes. Uh, it's booked…" → "Yes. it's booked…" |
| Misheard names left wrong, or "fixed" wrongly | "0 bills" (Xero), a two-word product name left split, a product name replaced with "it" |

## Stability and latency

| # | Finding | Found by | Status |
|---|---|---|---|
| 1 | No response-token cap: a small model could generate until the 4,096-token context filled (61 s, then an error, in the eval; 37 s for Llama 1B in the macOS 27 eval). | Codex, Cursor, eval | **Fixed**: cap of ~3× the take (`AppleIntelligenceCleanupEngine.responseTokenLimit`). |
| 2 | No deadline on a model call: if the model service hangs, the take waits indefinitely before paste. | Codex | **Added as a safety net**: `CleanupDeadline` abandons a call after 6 s + 0.08 s/word (max 60 s), off the main actor; the take ships the instant pass. The long waits first seen in the eval turned out to be the Mac sleeping during unattended runs, not the model, so this is protection, not a measured fix. |
| 3 | One pooled `LanguageModelSession` could serve two requests at once (actor reentrancy), and one would clear the other's history mid-generation. | Codex, Cursor | **Fixed**: sessions are leased; an overlapping request gets a one-off session. |
| 4 | macOS 26 cannot clear session history, so a reused session carries every earlier take until it overflows, and earlier dictations leak into later edits. | Codex, Cursor | **Fixed**: sessions are pooled on macOS 27 only. On 27 reuse is safe and faster (probe: ~570 ms vs ~920 ms per take). |
| 5 | Prewarm never matched the session a take used (onboarding warmed Basic with Markdown off; real takes are Light/Polish with Markdown on and en-AU). | Codex, Cursor, me | **Fixed**: `TranscriptCleanupPipeline.prewarm(plan:)` runs when recording starts, with the take's exact instructions. |
| 6 | A veto cost a full Basic model call that changed no words. | Cursor | **Fixed**: Polish → Light → instant pass; no Basic rung after a veto. |
| 7 | A broken local model was retried, and failed over to Apple, at every rung. | Codex | **Fixed**: after one fallback the rest of the ladder runs on Apple Intelligence. |
| 8 | Ten "hundred"s in a row overflowed `Int` in the guardrail's number tokenizer: a crash. | Codex | **Fixed**: checked arithmetic in the guardrail and `SpokenNumbers`. |
| 9 | Auto-paste always waited 500 ms after activating the target. | Codex | **Changed**: waits until the target is frontmost (usually immediate), then 60 ms. **Test in Electron apps.** |
| 10 | MLX refusals were treated as Apple's content filter, which skips the Apple fallback. | Cursor | **Fixed**. |
| 11 | Stop → paste is serial: capture shutdown, final decode, then cleanup. | Codex, Cursor | Not changed. Next step: overlap file finalisation with cleanup. |
| 12 | Guardrail alignment is O(n×m) on the main actor. | Codex | Not changed; takes are short enough today. |
| 13 | Partially downloaded MLX weights can count as installed. | Cursor | Not changed. |

## Accuracy

| # | Finding | Status |
|---|---|---|
| 1 | Prompts never said the dictation is text to edit rather than a message to answer. | v3 wraps it in `<dictation>` tags and says so. |
| 2 | Full-sentence examples leaked into output; even a name from an example ("Mike") leaked in v3's first draft. | v3 examples are short phrases with no names. New **instruction echo** veto: five or more words copied from the instructions that the speaker never said. |
| 3 | Light's "add breaks where the speech pauses" contradicted the shared style stage's "not where the speaker paused". | v3 resolves it: Light joins a fragment only when it cannot stand alone; Polish punctuates from meaning. |
| 4 | Polish summarised and rewrote for style. | v3 Polish fixes misheard words, punctuation and grammar only, and keeps asides and qualifiers. Retention floor raised to 0.85, so a Polish pass that drops a clause steps down to Light. |
| 5 | The model converted units and times for an en-AU speaker (pounds → kilos, 2pm → 14:00) despite instructions. | Guardrail now protects unit families and 12-hour times. |
| 6 | The model never produced a list when asked, and v2 listed prose. | The model writes no Markdown. `CleanupPostPass.formatSpokenLists` lays out lists the speaker numbers ("first… second…") when Markdown is on. |
| 7 | Light sometimes ended a question with a full stop. | `restoreQuestionMarks` puts it back when the words before it are unchanged. |
| 8 | "12,500 dollars" stayed as words after the model wrote digits; "two pounds of apples" became "£2". | `SpokenNumbers` attaches currency and percent words to digits, and treats "pounds of" as weight. |
| 9 | A take starting "Remember:" was deleted as a leaked prompt suffix. | The preamble strip skips any strip the dictation itself would trigger. |
| 10 | Pause flattening for Polish lowercased names ("Call. Sam" → "call sam"). | It lowercases only common words or words the speaker also used in lowercase. |
| 11 | Self-corrections ("Tuesday, no, sorry, Wednesday") usually keep both versions: the model drops the cue words and keeps both, and the filler strip then removed ", I mean," as a filler. | **Fixed for unambiguous cases**: `SpokenRepairs` resolves them before the model at Light and Polish (English or auto only). It acts only on a clear cue with a matching anchor or same-kind span (weekday, time, number, name…), on back-to-back restarts, and on "scratch that"; anything less certain is left to the model. See *Self-corrections* below. |
| 12 | "I like it, it looks…" lost a word: the filler strip treated any word repeated across a comma as a restart. | **Fixed**: across a comma only words that cannot end a clause (we, the, to…) collapse. |
| 14 | Polish comma-spliced real sentences ("…yesterday, can you send…", "…the tracker, I meant to say…") and dropped "Also". Since 1.3 Polish removed every pause-led full stop before the model, including true sentence ends, and lowercased "Can"/"Also", so the model rebuilt every boundary itself. | **Fixed for v3**: Polish keeps the engine's full stops (`flattensPolishPauses` stays on for v2 and the legacy set only); its punctuation rule now says to join only fragments and never comma-join two sentences. See *Polish punctuation* below. |
| 15 | Polish dropped the currency from an amount ("I think it was 12,500"). | **Fixed**: the guardrail treats currency as a protected unit (presence, so "three dollars fifty cents" → "$3.50" passes); a pass that loses it steps down to Light. |
| 16 | Polish kept spoken scaffolding: "So hi Jack", "Also I meant to say, the second slide…". | **Fixed**: Polish's rung gets, and is judged against, the dictation without a discourse opener or self-narration before a comma (`CleanupPostPass.dropSpokenScaffolding`); the same pass runs on Polish output as a backstop. The comma guards "I meant to say yes" and "the thing is broken". New set: `cases-scaffolding.json` (Cursor-written, 29 cases). |
| 17 | Prompt examples were copied into takes: Polish wrote "break the news" over "chase that" and "shoot me a message" (from its "brake the news" example); Llama 1B returned "we were going". | **Fixed**: no quoted rewrite examples left in v3 Light or Polish. |
| 18 | Polish wrote "17:00" for "5pm" and once "version ๔"; the guardrail vetoed, costing a second model call. | **Fixed**: the tidy step restores dictated 12-hour times and plain digits before the guardrail looks. |
| 19 | The model dropped "dollars" from a spoken amount; with the currency guard both Polish and Light were vetoed and the instant pass shipped, still labelled "Polish". | **Fixed**: Light and Polish render spoken numbers before the model ("$12,500"), and previews label the level that actually produced the text, with a note when a level was rejected. |
| 13 | Light deletes "actually" and "I mean it" as fillers. | "I mean it" fixed with a prompt example. "actually" is still dropped; telling the model to keep it made it drop more on History takes, so the line was removed. Open. |

## Self-corrections

None of the 91 History takes had an explicit correction ("no, sorry"); they had a handful of restarts ("the the") and many "actually"/"rather" that are not corrections. So the pass is tuned for precision: an adversarial review (Cursor) traced cases such as "I called Priya, sorry, Tash is on the other line", and after a weak cue (sorry, no, actually, I mean) the replacement must now end its clause. Codex wrote the pass and its tests; Cursor wrote an independent case set (`evals/cleanup/cases-corrections.json`: 20 corrections and restarts, 16 traps) and reviewed the code.

| Correction set, v3 | Pass | WER |
|---|---|---|
| Light, model only (`--no-repairs`) | 42% | 0.139 |
| **Light, with `SpokenRepairs`** | **92%** | **0.019** |
| Polish, model only | 50% | 0.122 |
| **Polish, with `SpokenRepairs`** | **92%** | **0.035** |

Run alone, the pass resolves all 20 positives, leaves all 16 traps and the reviewer's examples untouched, changes 2 History takes (both genuine restarts) and takes under 1 ms per take. The remaining failures are the model dropping "actually" and one "level three" left in words. On the synthetic set Light passes 100% (WER 0.020) and Polish 85% (0.045); on History, Light 78% (0.033) and Polish 78% (0.098). Single-take differences between runs are model variance: one History take flips between runs with no change that touches it.

The Light prompt no longer quotes restart examples. Llama 3.2 1B returned the example itself ("we were going") as the cleaned text of an unrelated take; the guardrail caught it, but the catalog model never landed. With `SpokenRepairs` doing restarts and corrections, the examples were worth at most a case or two on Apple Intelligence, within run-to-run variance.

## Polish punctuation

Reported from the Cleanup page's Follow-up sample: Light kept the sentences, Polish ran them together. Cursor traced the path independently and ranked the same cause first. The three built-in samples are now eval cases (`sample-*`), and a `sentences` check fails when the sentence count drifts from the reference. `forbid` matches words only, so the comma-splice checks use `forbidText`.

| Polish, v3 | Synthetic: pass / WER | History: pass / WER |
|---|---|---|
| All pause breaks removed (1.3 behaviour) | 81% / 0.046 | 73% / 0.098 |
| Breaks removed only before a fragment | 86% / 0.042 | 73% / 0.097 |
| No breaks removed | 89% / 0.042 | 78% / 0.093 |
| **No breaks removed, new punctuation rule, list-aware "And" fold, currency guard** | **89% / 0.039** | **78% / 0.093** |

The post-pass that folds ". And/But/Because…" fragments into the previous sentence stays for Polish but never folds before a list word ("…everyone. And third, …"). Remaining Polish misses are the model dropping a qualifier or a clause ("shoot me a message", "at that point, just"), which the retention floor tolerates at a few words.

## Spoken scaffolding and latency

| Polish, v3 | Scaffolding set: pass / WER / stepped down / p90 | Synthetic | History |
|---|---|---|---|
| Before | 86% / 0.125 / 9 / 1.8 s | 89% / 0.039 | 78% / 0.093 |
| **After** | **79% / 0.034 / 0 / 1.0 s** | **94% / 0.028** | **78% / 0.086** |

The scaffolding set's pass rate counts its new hard checks; most remaining failures are Polish dropping a qualifier ("probably", "as I mentioned"), "so that" → "so", or "I guess" → "I reckon". Removing the quoted qualifiers from the prompt did not help (better on one set, worse on two), so they stay.

Latency, measured inside the Debug app: one model call on the 80-word Follow-up sample is 1.5–1.6 s at every level and the rest of the pipeline is a few milliseconds; the first call after launch is ~3.3 s while the model loads. Most 3-second previews came from a vetoed rung running a second call, which the fixes above remove.

## Hard, multi-model evals

Three sets of 60 invented takes, each transcript written by one model family and its references by another (see `evals/cleanup/README.md`), aimed at what breaks a 3B model: requests that tempt an answer, long rambles, technical tokens, numbers, corrections and lookalikes. Codex and Cursor (Claude Sonnet 5) analysed the failures independently and agreed on the main fixes; prompt and budget experiments moved pass rates by a point or less, so the gains are deterministic:

- direct questions get their question mark ("Can you…", "Why is…"), not after an unfinished sentence or an indirect question;
- repeat collapse never merges a capitalised double ("Wagga Wagga") or repeated digits;
- identifiers keep their colons (`db:migrate`); "twelve dollars fifty" → "$12.50"; "eleven fifty nine pm" → "11:59pm"; "zero point oh four" → "0.04";
- "scratch that" replaces a same-kind value and never deletes a request clause; corrections cover relative days, seconds and kilos;
- the guardrail also vetoes an output that drops a negation, changes who is speaking or addressed, or deletes a "without…/unless…" condition.

| v3, pass rate | Light before → after | Polish before → after |
|---|---|---|
| Hard (tuning) | 47% → 80% | 47% → 77% |
| Held-out (checked, then tuned) | 33% → 55% | 43% → 57% |
| **Validation (never tuned)** | **38% → 52%** (non-ambiguous 52% → 64%) | **33% → 48%** (45% → 67%) |

Synthetic, correction, scaffolding and History sets held or improved. The cost is more Polish step-downs (the meaning checks), each a second model call. What remains is mostly the model: sentence segmentation, contractions expanded, questions embedded mid-sentence, reworded clauses.

## Security pass (Codex, Daybreak Blue)

A read-only review of all branch changes with `gpt-daybreak-blue-latest`. No critical findings; regexes, logging, session isolation, `.gitignore` coverage and the shell scripts were clean. Fixed:

| Severity | Finding | Fix |
|---|---|---|
| High | Auto-paste sent Cmd+V even when the destination never came forward or the user switched apps meanwhile (the fixed 500 ms wait in 1.3 had the same gap). | Paste only if the remembered app is still frontmost; otherwise the transcript stays on the clipboard. |
| Medium | The guardrail's alignment is input × output words, unbounded. | Takes over 900 words skip the model (they overflow its 4,096-token context anyway) and get the instant pass. |
| Medium | A dictated `</dictation>` or multi-line About-you text could pose as instructions. | Tags in the dictation are neutralised; About-you is flattened to one line and labelled background, not instructions. |
| Low | The History export used default file permissions and followed symlinks. | Written 0600 with `O_NOFOLLOW`. |

## Speaker context (new)

Settings › About you (also an onboarding step) takes a short description and a list of names and terms. Light and Polish receive it as an instruction stage: swap only sound-alikes, never add terms. A deterministic pass then joins spoken pieces of a listed term ("type script" → TypeScript, "big query" → BigQuery) and fixes case for distinctive terms (GitHub, MCP). Plain words that are also terms ("front", "slack") are left to the model. Both fields are capped (500 characters, 60 terms) because every character is prompt on every take.

On the History gold set the context lifts vocabulary fixes, but the model still applies only some of them at Light. The deterministic pass covers the joinable cases.

## Results

`scripts/cleanup-eval.sh` on Apple Intelligence, macOS 27, step-down on, one warm-up per prompt set and level.

Synthetic set (39 cases, `evals/cleanup/cases.json`):

| Prompts | Level | Pass | WER | Contractions kept | p50 |
|---|---|---|---|---|---|
| v2 (1.3) | Light | 79% | 0.061 | 27/40 | 1.0 s |
| **v3** | Light | **91%** | **0.031** | 40/40 | 1.0 s |
| v2 (1.3) | Polish | 76% | 0.072 | 39/41 | 1.1 s |
| **v3** | Polish | **82%** | **0.063** | 41/41 | 1.1 s |

History gold set (37 of your takes with hand-written references; local only, so numbers only):

| Prompts | Level | Pass | WER | Contractions kept |
|---|---|---|---|---|
| v2 (1.3) | Light | 65% | 0.101 | 39/54 |
| **v3** | Light | **78%** | **0.030** | 54/54 |
| v2 (1.3) | Polish | 62% | 0.177 | 41/54 |
| **v3** | Polish | **81%** | **0.093** | 53/54 |

With speaker context on the 12 gold takes that have misheard names: v3 Light 75% pass with 7 of 18 vocabulary fixes, v3 Polish 75% with 8 of 20. The model still skips most vocabulary fixes at Light; the deterministic pass only covers joinable terms.

Latency note: early unattended runs showed calls of 20 s to 15 minutes. The power log shows the Mac in maintenance sleep at those times, so they are not model behaviour; `scripts/cleanup-eval.sh` now runs under `caffeinate -i`. Excluding them, p90 stayed under 3 s per take.

WER is word edits against the reference divided by its length. Pass means every hard check passed (kept phrases, dropped fillers, questions, point of view, no Markdown unless dictated, no echo, no answer). See `evals/cleanup/README.md`.

## Verification

Built and tested in Xcode 27.1: `voxboxTests` ran 452 tests, 444 passed, 7 skipped (live-model and environment tests), and 1 failed: `testSystemThemeReevaluatesAgainstMacAppearance`, which reads the global `AppleInterfaceStyle` through a suite-scoped `UserDefaults` and so fails whenever the Mac is in Dark Mode. Neither that test nor `AppTheme` changed on this branch. The Xcode run also caught two post-pass regressions the harness self-test missed (an echoed v3 role text survived the preamble strip, and pause flattening kept "Starts" capitalised), both fixed; flattening now asks `NLTagger` whether the word reads as a noun.

Not verified: the auto-paste wait change in Electron apps, and the Settings › About you section by hand.
