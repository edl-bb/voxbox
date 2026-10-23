# Transcript cleanup eval

Scores the cleanup presets (Basic, Light cleanup, Polish) against reference outputs, on the real Apple Intelligence model, through the same `TranscriptCleanupPipeline` a take uses. Use it before and after any change to `CleanupPromptSet`, the post-pass or the guardrail.

```sh
scripts/cleanup-eval.sh                         # synthetic cases, prompt sets v2 vs v3
scripts/cleanup-eval.sh --prompts v3 --levels light --filter vocab
scripts/cleanup-eval.sh --cases evals/cleanup/cases-corrections.json --prompts v3 --no-repairs   # without the self-correction pass
scripts/cleanup-eval.sh --self-test             # model-free checks, seconds
scripts/cleanup-eval.sh --cases evals/cleanup/cases-hard.json --prompts v3 --prompt-file p.json   # try prompt text
scripts/cleanup-eval.sh --cases evals/cleanup/cases-hard.json --prompts v3 --budget polish=0.35,4,0.92
scripts/cleanup-eval.sh --probe-sessions 30     # pooled vs fresh session latency
scripts/cleanup-eval.sh --help
```

Needs only the Command Line Tools (Swift 6.4, macOS 27 SDK) and Apple Intelligence turned on. The script compiles the app's cleanup sources with `swiftc` next to a few shims in `harness/`, so a prompt edit is picked up on the next run. MLX catalog models are not in this build; they need the app target.

Each run writes `runs/<timestamp>-<label>/rows.json` and `report.md` (gitignored) and prints a summary table.

## Files

| File | In git | What |
|---|---|---|
| `cases.json` | yes | Synthetic cases. Invented people and companies only. |
| `cases-hard.json` | yes | 60 hard synthetic takes (tuning set): transcripts by GPT-5.6, Grok 4.7 and Gemini 3.7, references by a different model family each. Tags name the writer, referee and challenges; `ambiguous` marks debatable references. |
| `cases-holdout.json` | yes | 60 more (Claude Opus 5.5, Composer 2.5, Grok 4.6 writers), used to check that fixes generalise, then tuned on. |
| `cases-validation.json` | yes | 60 more (Gemini, GPT-5.2, Claude Sonnet 5 writers), never tuned on. Score a change here last. |
| `cases-scaffolding.json` | yes | Synthetic spoken scaffolding Polish should drop ("So hi…", "I meant to say,"), and traps where the same words carry meaning. |
| `cases-corrections.json` | yes | Synthetic self-corrections, restarts, and traps where "no", "sorry", "I mean", "actually" or "rather" are not corrections. |
| `history-gold.local.json` | **no** | Your own History takes with hand-written references. |
| `history.local.json` | **no** | Raw export from `scripts/export-history-for-evals.py`. |
| `runs/` | **no** | Outputs, which can contain dictation text. |

The repository is public. Never commit a real take, or text derived from one, and never paste one into a synthetic case. Write a new sentence that shows the same failure instead.

## Building a private gold set from History

```sh
python3 -I scripts/export-history-for-evals.py          # release app
python3 -I scripts/export-history-for-evals.py --dev    # VoxBox-Dev
```

That writes `history.local.json`. Copy takes into `history-gold.local.json` in the case format below, write the output you wanted at each level, then run:

```sh
scripts/cleanup-eval.sh --cases evals/cleanup/history-gold.local.json --context both
```

## Case format

```json
{
  "language": "en-AU",
  "contexts": { "sam": { "about": "…", "vocabulary": ["Xero", "Okta"] } },
  "cases": [{
    "id": "vocab-bills",
    "tags": ["vocabulary", "agent"],
    "raw": "Can you pull the 0 bills from the shared inbox…",
    "context": "sam",
    "markdown": false,
    "expected": { "light": "…", "polish": "…" },
    "keep": ["shared inbox"],
    "drop": ["um"],
    "forbid": ["via it"],
    "forbidText": [". it's"],
    "endsWith": "is if we",
    "fix": [{ "to": "Xero bills", "needsContext": true }]
  }]
}
```

A level is run only when the case has a reference for it. `context` names an entry in `contexts`; `--context off|on|both` decides whether the speaker context is sent.

## What is scored

| Column | Meaning |
|---|---|
| WER | Word edits to reach the reference ÷ reference words. Contractions count: "I'm" → "I am" is an edit. |
| Char sim | 1 − character edit distance, so punctuation and capitals count. |
| Pass | Every hard check below passed. |
| Fixes | Misheard words and vocabulary terms the level was expected to correct. |
| Contractions | Contractions in the reference that survived. |
| Stepped down | Rows that landed below the requested level (veto). |
| p50 / p90 ms | Whole pipeline time per take, after one untimed warm-up per prompt set and level. |

Hard checks: `keep` phrases survive; `drop` phrases and um/uh are gone (Light, Polish); Basic keeps every word; `forbid` phrases never appear; `endsWith`; question marks match the reference; first- and second-person counts match within one; no Markdown unless the reference has a list; no echo of the instructions; no "Here is…" or answer opener.

References are judgement calls. A WER of 0.05 on a long take is a few words; read `report.md` before deciding a prompt is worse.
