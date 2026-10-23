#!/bin/zsh
# Build and run the transcript cleanup eval on Apple Intelligence.
#
#   scripts/cleanup-eval.sh                                   # synthetic cases, v2 vs v3
#   scripts/cleanup-eval.sh --cases evals/cleanup/history-gold.local.json --prompts v3
#   scripts/cleanup-eval.sh --help
#
# Compiles the app's real cleanup sources with swiftc (Command Line Tools are
# enough; no Xcode project build), so prompt edits in
# voxbox/Services/Cleanup/CleanupPromptSet.swift are picked up on the next run.
# Results land in evals/cleanup/runs/ (gitignored).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

OUT="${CLEANUP_EVAL_BUILD:-build/cleanup-eval}"
mkdir -p "$OUT"

SOURCES=(
  voxbox/Services/Cleanup/*.swift
  voxbox/Services/TranscriptFormatterService.swift
  voxbox/Services/CleanupEngine.swift
  voxbox/Services/AppleIntelligenceCleanupEngine.swift
  voxbox/Services/CleanupSessionPool.swift
  voxbox/Models/CustomCleanupRuleset.swift
  voxbox/Models/PostProcessingModel.swift
  voxbox/Models/DeviceCapability.swift
  voxbox/Utilities/AustralianEnglishSpelling.swift
  voxbox/Utilities/AutoEdit.swift
  voxbox/Utilities/AppLogger.swift
  voxbox/Utilities/SmartTrailingPunctuation.swift
  voxbox/Support/OSCapabilities.swift
  evals/cleanup/harness/*.swift
)

# Mirrors the app target: Swift 5 mode, MainActor default isolation,
# approachable concurrency.
FLAGS=(
  -O -parse-as-library -swift-version 5
  -default-isolation MainActor
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature MemberImportVisibility
  -target "arm64-apple-macosx26.0"
  -module-name voxbox
)

newest_source=$(ls -t $SOURCES | head -1)
if [[ ! -x "$OUT/cleanup-eval" || "$newest_source" -nt "$OUT/cleanup-eval" ]]; then
  echo "Building cleanup-eval…" >&2
  swiftc $FLAGS $SOURCES -o "$OUT/cleanup-eval"
fi

# caffeinate: an unattended run otherwise spans maintenance sleeps, which
# show up as multi-minute "stalls" in the latency columns.
exec /usr/bin/caffeinate -i "$OUT/cleanup-eval" "$@"
