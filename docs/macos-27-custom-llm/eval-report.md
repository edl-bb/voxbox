# Cleanup eval — macOS 27

Ticket 09. Live Preview through `TranscriptCleanupPreview` / `TranscriptCleanupPipeline` with compiled Light cleanup and Polish. Auto Edit off, markdown off, step-down off (Preview single rung).

- **Host:** macOS 27.0.0
- **Apple Intelligence:** available
- **Llama 3.2 1B Instruct:** live (weights at `~/Library/Application Support/VoxBox/postprocessing-models/mlx-llama-3.2-1b-instruct-4bit`)
- **Compiled prompts:** `CleanupPromptSet.compiled` (no DEBUG overlay) — **not edited**
- **Date:** 2026-09-16T10:49:15Z

## Summary

| Model | Intensity | Fixture | Leftover fillers | Guardrail veto / step-down | Freeze (email / URL / number) | Empty / preamble | Refusal | Status |
|---|---|---|---|---|---|---|---|---|
| Apple Intelligence | Light cleanup | follow-up | 0 | accepted · accepted | email ✓ URL – number – | empty no / preamble no | no | ran (3694 ms) |
| Apple Intelligence | Polish | follow-up | 0 | accepted · accepted | email ✓ URL – number – | empty no / preamble no | no | ran (1732 ms) |
| Apple Intelligence | Light cleanup | note-to-self | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (1355 ms) |
| Apple Intelligence | Polish | note-to-self | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (1397 ms) |
| Apple Intelligence | Light cleanup | team-update | 0 | accepted · accepted | email – URL ✓ number ✓ | empty no / preamble no | no | ran (1540 ms) |
| Apple Intelligence | Polish | team-update | 0 | accepted · accepted | email – URL ✓ number ✓ | empty no / preamble no | no | ran (1771 ms) |
| Apple Intelligence | Light cleanup | filler-heavy | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (731 ms) |
| Apple Intelligence | Polish | filler-heavy | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (850 ms) |
| Apple Intelligence | Light cleanup | freeze-strings | 0 | accepted · accepted | email ✓ URL ✓ number ✓ | empty no / preamble no | no | ran (1089 ms) |
| Apple Intelligence | Polish | freeze-strings | 0 | accepted · accepted | email ✓ URL ✓ number ✓ | empty no / preamble no | no | ran (1147 ms) |
| Apple Intelligence | Light cleanup | short-take | 0 | accepted · not governed | email – URL – number – | empty no / preamble no | no | ran (450 ms) |
| Apple Intelligence | Polish | short-take | 0 | accepted · not governed | email – URL – number – | empty no / preamble no | no | ran (507 ms) |
| Llama 3.2 1B Instruct | Light cleanup | follow-up | 0 | accepted · accepted | email ✓ URL – number – | empty no / preamble no | no | ran (4738 ms) |
| Llama 3.2 1B Instruct | Polish | follow-up | 0 | veto · change ratio 29.60 over budget 0.50 | email ✓ URL – number – | empty no / preamble no | no | ran (37095 ms) |
| Llama 3.2 1B Instruct | Light cleanup | note-to-self | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (776 ms) |
| Llama 3.2 1B Instruct | Polish | note-to-self | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (814 ms) |
| Llama 3.2 1B Instruct | Light cleanup | team-update | 0 | veto · protected token altered (26 chars) | email – URL ✗ number ✓ | empty no / preamble no | no | ran (812 ms) |
| Llama 3.2 1B Instruct | Polish | team-update | 1 | accepted · accepted | email – URL ✓ number ✓ | empty no / preamble no | no | ran (1150 ms) |
| Llama 3.2 1B Instruct | Light cleanup | filler-heavy | 0 | accepted · accepted | email – URL – number – | empty no / preamble no | no | ran (408 ms) |
| Llama 3.2 1B Instruct | Polish | filler-heavy | 0 | veto · change ratio 1.16 over budget 0.50 | email – URL – number – | empty no / preamble no | no | ran (545 ms) |
| Llama 3.2 1B Instruct | Light cleanup | freeze-strings | 0 | veto · protected token altered (16 chars) | email ✗ URL ✗ number ✓ | empty no / preamble no | no | ran (422 ms) |
| Llama 3.2 1B Instruct | Polish | freeze-strings | 0 | accepted · accepted | email ✓ URL ✓ number ✓ | empty no / preamble no | no | ran (641 ms) |
| Llama 3.2 1B Instruct | Light cleanup | short-take | 0 | accepted · not governed | email – URL – number – | empty no / preamble no | no | ran (407 ms) |
| Llama 3.2 1B Instruct | Polish | short-take | 0 | accepted · not governed | email – URL – number – | empty no / preamble no | no | ran (382 ms) |
| Qwen 3 1.7B | Light cleanup | follow-up | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Polish | follow-up | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Light cleanup | note-to-self | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Polish | note-to-self | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Light cleanup | team-update | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Polish | team-update | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Light cleanup | filler-heavy | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Polish | filler-heavy | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Light cleanup | freeze-strings | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Polish | freeze-strings | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Light cleanup | short-take | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 1.7B | Polish | short-take | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Light cleanup | follow-up | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Polish | follow-up | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Light cleanup | note-to-self | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Polish | note-to-self | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Light cleanup | team-update | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Polish | team-update | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Light cleanup | filler-heavy | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Polish | filler-heavy | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Light cleanup | freeze-strings | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Polish | freeze-strings | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Light cleanup | short-take | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Llama 3.2 3B Instruct | Polish | short-take | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Light cleanup | follow-up | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Polish | follow-up | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Light cleanup | note-to-self | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Polish | note-to-self | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Light cleanup | team-update | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Polish | team-update | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Light cleanup | filler-heavy | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Polish | filler-heavy | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Light cleanup | freeze-strings | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Polish | freeze-strings | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Light cleanup | short-take | – | – · env-blocked | email – URL – number – | – | – | env-blocked |
| Qwen 3 4B | Polish | short-take | – | – · env-blocked | email – URL – number – | – | – | env-blocked |

## Outputs

### Apple Intelligence · Light cleanup · follow-up

- Engine: Apple Intelligence
- Landed: Light cleanup
- Cost 6.0 · retention 0.95

```
Hi Jack, I am following up on the thing we talked about yesterday. Please send the updated deck to jules@testco.com by Thursday, and put the revised total, I think it was $12,500, into the tracker. I meant to say the second slide still has the old logo so legal should probably see it for review before it goes out.
```

### Apple Intelligence · Polish · follow-up

- Engine: Apple Intelligence
- Landed: Polish
- Cost 5.0 · retention 0.90

```
Hi Jack, just following up on the thing we talked about yesterday. Can you send the updated deck to jules@testco.com by Thursday? Put the revised total, $12,500, into the tracker. I meant to say the second slide still has the old logo, so legal should probably see it for their review before it goes out.
```

### Apple Intelligence · Light cleanup · note-to-self

- Engine: Apple Intelligence
- Landed: Light cleanup
- Cost 2.5 · retention 0.94

```
Note to self: book the car in for a service next week, probably Tuesday, and remember to peak at the quote from the other garage first because I think they were $200 cheaper. Call mum back, she rang twice, and I still haven't sorted the birthday thing.
```

### Apple Intelligence · Polish · note-to-self

- Engine: Apple Intelligence
- Landed: Polish
- Cost 3.0 · retention 0.94

```
Note to self: book the car in for a service sometime next week, probably Tuesday, and remember to peek at the quote from the other garage first because I think they were $200 cheaper. Call mum back; she rang twice. I still haven't sorted the birthday thing.
```

### Apple Intelligence · Light cleanup · team-update

- Engine: Apple Intelligence
- Landed: Light cleanup
- Cost 3.5 · retention 0.93

```
Hey team, three things. First, the staging build is up at https://staging.voxbox.app, so have a play and log anything weird. Second, I am going to move the retro to Friday at 2pm, hopefully that is okay with everyone. Third, we need someone to own the release notes, so if you have capacity, shout.
```

### Apple Intelligence · Polish · team-update

- Engine: Apple Intelligence
- Landed: Polish
- Cost 1.5 · retention 0.98

```
Hey team, an update. Three things. First, the staging build is up at https://staging.voxbox.app. Have a play and log anything weird. Second, I’m going to move the retro to Friday at 2pm. Hopefully that’s okay with everyone. Third, we need someone to own the release notes. If you’ve got capacity, shout.
```

### Apple Intelligence · Light cleanup · filler-heavy

- Engine: Apple Intelligence
- Landed: Light cleanup
- Cost 0.0 · retention 1.00

```
I was thinking we should maybe ship it tomorrow, if that's okay.
```

### Apple Intelligence · Polish · filler-heavy

- Engine: Apple Intelligence
- Landed: Polish
- Cost 0.0 · retention 1.00

```
I was thinking we should maybe ship it tomorrow if that's okay.
```

### Apple Intelligence · Light cleanup · freeze-strings

- Engine: Apple Intelligence
- Landed: Light cleanup
- Cost 0.0 · retention 1.00

```
Email the recap to priya@voxbox.app and put the link https://notes.voxbox.app/q3 in the tracker. The invoice is $12,500.
```

### Apple Intelligence · Polish · freeze-strings

- Engine: Apple Intelligence
- Landed: Polish
- Cost 0.0 · retention 1.00

```
Email the recap to priya@voxbox.app and put the link https://notes.voxbox.app/q3 in the tracker. The invoice is $12,500.
```

### Apple Intelligence · Light cleanup · short-take

- Engine: Apple Intelligence
- Landed: Light cleanup
- Cost 1.0 · retention 1.00

```
Yes, call Sam.
```

### Apple Intelligence · Polish · short-take

- Engine: Apple Intelligence
- Landed: Polish
- Cost 0.0 · retention 1.00

```
Call Sam.
```

### Llama 3.2 1B Instruct · Light cleanup · follow-up

- Engine: Llama 3.2 1B Instruct
- Landed: Light cleanup
- Cost 12.5 · retention 0.97

```
I think we should ship it on Thursday, it was $200 cheaper.
Can you send the updated deck to jules@testco.com by Thursday, and put the revised total, I think it was $12,500, into the tracker.
Also I meant to say the second slide still has the old logo so legal should probably see it for review before it goes out.
```

### Llama 3.2 1B Instruct · Polish · follow-up

- Engine: Llama 3.2 1B Instruct
- Landed: raw
- Cost 2012.5 · retention 0.94

```
Um so hi Jack, just following up on, on the thing we talked about yesterday. Can you send the updated deck to jules@testco.com by like Thursday, and, um, put the revised total, I think it was twelve thousand five hundred dollars, into the tracker. Also I meant to say, the the second slide still has the old logo so legal should probably see it for there review before it goes out.
```

### Llama 3.2 1B Instruct · Light cleanup · note-to-self

- Engine: Llama 3.2 1B Instruct
- Landed: Light cleanup
- Cost 4.5 · retention 0.98

```
I think we should book the car in for a service sometime next week probably Tuesday and remember to peak at the quote from the other garage first because I think they were like $200 cheaper Oh call mum back she rang twice and I still haven't sorted the birthday thing
```

### Llama 3.2 1B Instruct · Polish · note-to-self

- Engine: Llama 3.2 1B Instruct
- Landed: Polish
- Cost 5.0 · retention 0.89

```
I'll note to self book car in for service sometime next week probably Tuesday and remember to peak at quote from other garage first because I think they were like $200 cheaper oh and call mum back she rang twice and I still haven't sorted birthday thing.
```

### Llama 3.2 1B Instruct · Light cleanup · team-update

- Engine: Llama 3.2 1B Instruct
- Landed: raw
- Cost 28.0 · retention 0.71

```
Hey team, quick update. Um, three things. First, the staging build is up at https://staging.voxbox.app so, you know, have a play and log anything weird. Second, I'm, I'm going to move the retro to Friday at 2pm, hopefully that's okay with everyone. And third, basically we need someone to own the release notes, so if you've got capacity, uh, shout.
```

### Llama 3.2 1B Instruct · Polish · team-update

- Engine: Llama 3.2 1B Instruct
- Landed: Polish
- Cost 4.0 · retention 0.98

```
Hey team, quick update.
Three things.
First, the staging build is up at https://staging.voxbox.app so have a play and log anything weird.
Second, I'm going to move the retro to Friday at 2pm, hopefully that's okay with everyone.
Third, basically we need someone to own the release notes, so if you've got capacity, shout.

Remember to do this.
```

### Llama 3.2 1B Instruct · Light cleanup · filler-heavy

- Engine: Llama 3.2 1B Instruct
- Landed: Light cleanup
- Cost 2.0 · retention 0.85

```
I think we should ship it tomorrow if that's okay.
```

### Llama 3.2 1B Instruct · Polish · filler-heavy

- Engine: Llama 3.2 1B Instruct
- Landed: raw
- Cost 18.5 · retention 1.00

```
Um uh so I I was, um, thinking we should, uh, uh, maybe ship it, you know, I mean, basically tomorrow, um, if that's, uh, okay.
```

### Llama 3.2 1B Instruct · Light cleanup · freeze-strings

- Engine: Llama 3.2 1B Instruct
- Landed: raw
- Cost 21.0 · retention 0.52

```
Um so email the recap to priya@voxbox.app and, uh, put the link https://notes.voxbox.app/q3 in the tracker, the invoice is 12,500.
```

### Llama 3.2 1B Instruct · Polish · freeze-strings

- Engine: Llama 3.2 1B Instruct
- Landed: Polish
- Cost 3.0 · retention 1.00

```
I remember to email the recap to priya@voxbox.app and put the link https://notes.voxbox.app/q3 in the tracker, the invoice is 12,500.
```

### Llama 3.2 1B Instruct · Light cleanup · short-take

- Engine: Llama 3.2 1B Instruct
- Landed: Light cleanup
- Cost 10.5 · retention 1.00

```
I think we should ship it on Thursday, it was $200 cheaper.
```

### Llama 3.2 1B Instruct · Polish · short-take

- Engine: Llama 3.2 1B Instruct
- Landed: Polish
- Cost 2.5 · retention 1.00

```
I remember calling Sam.
```

## Env-blocked rows

- env-block: Llama 3.2 3B Instruct weights missing at /Users/edlittle/Library/Application Support/VoxBox/postprocessing-models/mlx-llama-3.2-3b-instruct-4bit
- env-block: Qwen 3 1.7B weights missing at /Users/edlittle/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-1.7b-4bit
- env-block: Qwen 3 4B weights missing at /Users/edlittle/Library/Application Support/VoxBox/postprocessing-models/mlx-qwen3-4b-4bit

## Findings

Scoring is on the model’s tidied attempt (post-pass, before a Preview veto ships raw). Preview ran with step-down off, Auto Edit off, compiled prompts, no markdown.

### Apple Intelligence (macOS 27 system model)

All 12 rows accepted. Leftover filler count 0. No empty output, preamble, or refusal. Freeze strings survived wherever the fixture had them (follow-up email; team-update URL and `2pm`; freeze-strings email + URL + `12,500`).

Light cleanup stays wording-faithful enough: `peak at the quote` is kept; fillers and repeats drop; spoken money becomes `$200` / `$12,500`. Polish is meaning-faithful: `peak` → `peek`, `there review` → `their review`, pause fragments join. Short take `Um yeah call Sam.` → Light `Yes, call Sam.` / Polish `Call Sam.`

Mild Light drift on follow-up (`just following up` → `I am following up`, `Can you send` → `Please send`) stayed inside the Guardrail budget (cost 6.0, retention 0.95). Not a regression that needs a prompt edit.

### Llama 3.2 1B Instruct (weights on disk, live)

Live run succeeded (engine name `Llama 3.2 1B Instruct`, no fallback to Apple Intelligence). The 1B model copies the few-shot **Example** from `CleanupPromptSet.compiled`:

Light example: `I think we should ship it on Thursday, it was $200 cheaper.`
Polish example: `Remember to peek at the quote. It was $200 cheaper, so legal should see it for their review.`

| Fixture × intensity | What happened | Guardrail |
|---|---|---|
| Light follow-up | Prepended the Light example, then some of the dictation. Email survived. | **Accepted** (cost 12.5) |
| Light note-to-self | Opened with `I think we should book the car…` (example template). | Accepted |
| Light team-update | Replaced the take with the example + two leftover sentences; **dropped the URL**. | **Veto** `protected token altered` — raw ships |
| Light freeze-strings | Output was the example with `$12,500` spliced in; **dropped email and URL**. | **Veto** `protected token altered` — raw ships |
| Light filler-heavy | `I think we should ship it tomorrow if that's okay.` (example, `Thursday` → `tomorrow`). | Accepted |
| Light short-take | **Replaced** `Um yeah call Sam.` with the Light example. Short take is not budget-governed. | **Accepted — Guardrail cannot absorb** |
| Polish follow-up | Looped `Put it in the tracker.` (~2k cost, 37 s). | **Veto** change-ratio — raw ships |
| Polish filler-heavy | Emitted the Polish example verbatim (`peek at the quote` / `their review`). | **Veto** change-ratio — raw ships |
| Polish freeze-strings | `I remember to email the recap…` (example opener). Freeze strings survived. | Accepted |
| Polish short-take | `I remember calling Sam.` (example opener). | Accepted (not governed) |
| Polish team-update | Keepable cleanup, but leftover **basically** and a trailer `Remember to do this.` | Accepted (1 leftover filler) |

Freeze-string breaks on Llama Light were absorbed: Preview ships the original dictation, so the email/URL/number still paste. Runaway Polish is also absorbed.

What Guardrail cannot absorb: **example parroting on short Light cleanup** (the whole paste is the prompt example), plus accepted Light follow-up/filler-heavy rewrites that stay under budget, and one leftover `basically` on Polish team-update.

### Other catalog models

Qwen 3 1.7B, Llama 3.2 3B Instruct, and Qwen 3 4B: **env-blocked** — no weights under `~/Library/Application Support/VoxBox/postprocessing-models/<variant>`. Not skipped to green.

## Verdict — keep compiled prompts

**Do not edit `CleanupPromptSet.compiled`.** Apple Intelligence on macOS 27 still lands Light cleanup (wording-faithful) and Polish (meaning-faithful) on these fixtures. A prompt change to stop Llama 1B copying the Example would retune the system model that is currently good.

**Keep Apple Intelligence as the default for Light cleanup and Polish.** Llama 3.2 1B Instruct is too small to follow the compiled instructions: it copies the few-shot example (cited: Light `short-take`, Light `freeze-strings`, Light `team-update`, Polish `filler-heavy`). Guardrail already catches the freeze-string drops and the 37 s Polish loop. The hole is ungoverned short takes.

If a later ticket retunes **only** for catalog 1B models (not this compiled set), the minimal instruction change would be: delete the `Example.` paragraph from `light` and `polish`, or add one line `Do not copy the example; edit only the dictation.` Cited fixtures: Light short-take (`Um yeah call Sam.` → `I think we should ship it on Thursday, it was $200 cheaper.`), Light freeze-strings (example + `$12,500`, email/URL dropped, vetoed), Polish filler-heavy (verbatim Polish example, vetoed).
