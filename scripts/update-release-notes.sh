#!/bin/bash
# update-release-notes.sh — Rewrite GitHub release notes from CHANGELOG.md
# Usage: ./scripts/update-release-notes.sh [--dry-run] [version ...]
#
# Updates every published GitHub release that has a matching section in the
# current CHANGELOG.md (the same notes deploy-release.sh publishes, which is
# what the in-app update sheet shows). Pass versions (1.1.0 or v1.1.0) to
# limit the set. --dry-run prints the notes without calling GitHub.

set -e

source "$(dirname "$0")/lib/common.sh"

echo "🚀 VoxBox Release Notes Updater"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

require_repo_root

DRY_RUN=0
REQUESTED=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*)
      echo "❌ Unknown option: $arg"
      echo "   Usage: ./scripts/update-release-notes.sh [--dry-run] [version ...]"
      exit 1
      ;;
    *) REQUESTED+=("${arg#v}") ;;
  esac
done

if [ ! -f "$CHANGELOG" ]; then
  echo "❌ ${CHANGELOG} not found."
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "❌ GitHub CLI (gh) not installed. Install with: brew install gh"
  exit 1
fi

# Published (non-draft) tags on GitHub, newest first.
# Bash 3.2 (macOS /bin/bash) has no mapfile.
GH_TAGS=()
while IFS= read -r tag; do
  [ -n "$tag" ] && GH_TAGS+=("$tag")
done < <(
  gh release list --repo "$GITHUB_REPO" --limit 100 \
    --json tagName,isDraft \
    --jq '.[] | select(.isDraft|not) | .tagName'
)

if [ "${#GH_TAGS[@]}" -eq 0 ]; then
  echo "❌ No published GitHub releases found on ${GITHUB_REPO}."
  exit 1
fi

if [ "${#REQUESTED[@]}" -eq 0 ]; then
  TARGETS=()
  for tag in "${GH_TAGS[@]}"; do
    TARGETS+=("${tag#v}")
  done
else
  TARGETS=("${REQUESTED[@]}")
fi

gh_has_tag() {
  local want="$1"
  local tag
  for tag in "${GH_TAGS[@]}"; do
    if [ "$tag" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

UPDATED=0
SKIPPED=0
UNCHANGED=0
FAILED=0

for version in "${TARGETS[@]}"; do
  tag="v${version}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📦 ${tag}"

  if ! gh_has_tag "$tag"; then
    echo "   ⚠️  No published GitHub release — skipped"
    SKIPPED=$((SKIPPED + 1))
    echo ""
    continue
  fi

  NOTES="$(changelog_github_notes "$version" "$CHANGELOG")"
  if [ -z "$NOTES" ]; then
    echo "   ⚠️  No notes in ${CHANGELOG} — skipped"
    SKIPPED=$((SKIPPED + 1))
    echo ""
    continue
  fi

  echo "$NOTES" | sed 's/^/   /'
  echo ""

  NOTES_FILE=$(mktemp)
  printf '%s\n' "$NOTES" > "$NOTES_FILE"

  CURRENT="$(gh release view "$tag" --repo "$GITHUB_REPO" --json body --jq .body 2>/dev/null || true)"
  CURRENT_NORM=$(printf '%s\n' "$CURRENT" | sed -e 's/[[:space:]]*$//' -e '/^$/d')
  NOTES_NORM=$(printf '%s\n' "$NOTES" | sed -e 's/[[:space:]]*$//' -e '/^$/d')

  if [ "$CURRENT_NORM" = "$NOTES_NORM" ]; then
    echo "   ✅ Already matches CHANGELOG.md"
    UNCHANGED=$((UNCHANGED + 1))
    rm -f "$NOTES_FILE"
    echo ""
    continue
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "   (dry-run — not writing to GitHub)"
    UPDATED=$((UPDATED + 1))
    rm -f "$NOTES_FILE"
    echo ""
    continue
  fi

  if gh release edit "$tag" --repo "$GITHUB_REPO" --notes-file "$NOTES_FILE"; then
    echo "   ✅ Updated https://github.com/${GITHUB_REPO}/releases/tag/${tag}"
    UPDATED=$((UPDATED + 1))
  else
    echo "   ❌ Failed to update ${tag}"
    FAILED=$((FAILED + 1))
  fi
  rm -f "$NOTES_FILE"
  echo ""
done

# Changelog sections with no GitHub release — useful when 1.0.0/1.0.1 exist
# only as history.
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
while IFS= read -r listed; do
  if ! gh_has_tag "v${listed}"; then
    echo "ℹ️  CHANGELOG has [${listed}] but GitHub has no v${listed} release"
  fi
done < <(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$CHANGELOG")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry-run complete."
else
  echo "Done."
fi
echo "   Updated   : ${UPDATED}"
echo "   Unchanged : ${UNCHANGED}"
echo "   Skipped   : ${SKIPPED}"
echo "   Failed    : ${FAILED}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
