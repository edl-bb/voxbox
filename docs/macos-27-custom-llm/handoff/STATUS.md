# macOS 27 custom cleanup models — build status

**How this was built:** tracer tickets 01–09 implemented on `feat/macos-27-custom-llm` by parallel sub-agents; independent reviewer ran VALIDATION.md (P10-report). Bounce-back: live engine test retargeted to on-disk Llama 3.2 1B (**TEST SUCCEEDED**, 3.5s); eval matrix gated on `VOXBOX_CLEANUP_EVAL=1`.

## Phase status

| Phase | Implemented | Green (unit) | Live-validated | Blocking env/infra |
|---|---|---|---|---|
| 01 Prefactor | ✅ | ✅ | n/a | — |
| 02 Spike | ✅ | ✅ build | ✅ mlx-swift main pin | Metal Toolchain (installed) |
| 03 OS gate | ✅ | ✅ | T1 on this 27 Mac | — |
| 04 Session pool | ✅ | ✅ | T1 + mutation probe | — |
| 05 MLX engine | ✅ | ✅ | ✅ Llama 3.2 1B Light cleanup | Qwen 1.7B / 3B / 4B weights not downloaded |
| 06 Preparing status | ✅ | ✅ | T1 | T4 in-app spinner not hands-on |
| 07 History swipe | ✅ | ✅ | T1 | T4 swipe in running app not hands-on |
| 08 Ruleset reorder | ✅ | ✅ | T1 | T4 drag in running app not hands-on |
| 09 Eval | ✅ | ✅ scorer | ✅ Apple Intelligence + Llama 1B | Other catalog models env-blocked |
| 10 Review | ✅ report | ✅ T1 117 | Llama live PASS; Qwen e2e env-block | Download Qwen to repeat README e2e with Qwen |

## Environment

No secrets. Hardware: macOS 27 SDK; Apple Intelligence; Llama 3.2 1B 4-bit on disk. Set `VOXBOX_CLEANUP_EVAL=1` to re-run the full eval matrix.

## Start-here for the next agent

Work is on `feat/macos-27-custom-llm`. Remaining optional: download Qwen 3 1.7B and repeat README e2e; hands-on T4 for swipe / reorder / preparing spinner.
