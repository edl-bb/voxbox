#!/bin/bash
# deploy-release.sh — Push a locally-built release to GitHub.
# Usage: ./scripts/deploy-release.sh [version]
#
# Run AFTER create-release.sh has succeeded.
# If no version is given, reads from dist/.release-version written by create-release.sh.
# GitHub release notes come from the matching CHANGELOG.md section (what the
# in-app update sheet shows). Git log is only used if that section is missing.
# Re-deploying an existing tag replaces the DMG, rewrites the GitHub notes from
# the current CHANGELOG.md, and moves the tag to HEAD so the source zip matches.

set -e

source "$(dirname "$0")/lib/common.sh"

echo "🚀 VoxBox Release Deployer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Resolve version ────────────────────────────────────────────────────────────
if [ -n "$1" ]; then
  VERSION="$1"
else
  if [ ! -f "dist/.release-version" ]; then
    echo "❌ No version specified and dist/.release-version not found."
    echo "   Run ./scripts/create-release.sh first, or pass the version explicitly:"
    echo "   ./scripts/deploy-release.sh 1.2.3"
    exit 1
  fi
  VERSION=$(cat dist/.release-version)
fi

echo "📦 Deploying v${VERSION}"

# ── Resolve DMG path ───────────────────────────────────────────────────────────
if [ -f "dist/.release-dmg" ]; then
  DMG_PATH=$(cat dist/.release-dmg)
else
  # Fall back to the conventional name
  DMG_PATH="dist/VoxBox-${VERSION}.dmg"
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "❌ DMG not found at: ${DMG_PATH}"
  echo "   Run ./scripts/create-release.sh first."
  exit 1
fi

echo "💿 DMG     : ${DMG_PATH}"
echo "🏷️  Tag     : v${VERSION}"
echo ""

# Always address the tag by full ref. A release branch with the same name
# (e.g. branch v1.2.0 + tag v1.2.0) makes a bare "v1.2.0" refspec ambiguous.
TAG_REF="refs/tags/v${VERSION}"

# ── Verify tag exists locally ──────────────────────────────────────────────────
if ! git rev-parse "$TAG_REF" &>/dev/null; then
  echo "❌ Local tag v${VERSION} not found."
  echo "   Run ./scripts/create-release.sh to create the release commit and tag first."
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "❌ GitHub CLI (gh) not installed. Install with: brew install gh"
  exit 1
fi

RECYCLE=0
if gh release view "v${VERSION}" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
  RECYCLE=1
fi

# ── Push commits + tag ────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔼 Pushing commits and tag to GitHub..."
git push origin HEAD

if [ "$RECYCLE" = 1 ]; then
  TAG_SHA=$(git rev-parse "$TAG_REF")
  HEAD_SHA=$(git rev-parse HEAD)
  if [ "$TAG_SHA" != "$HEAD_SHA" ]; then
    echo "📌 Moving tag v${VERSION} to HEAD (${HEAD_SHA:0:7})"
    echo "   so GitHub's source zip matches this build"
    git tag -f "v${VERSION}" HEAD
    git push --force origin "$TAG_REF"
  else
    git push origin "$TAG_REF"
  fi
else
  git push origin "$TAG_REF"
fi
echo "✅ Pushed"

# ── Create GitHub Release with DMG ────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$RECYCLE" = 1 ]; then
  echo "♻️  Recycle v${VERSION}: DMG, notes, and source zip..."
else
  echo "📤 Creating GitHub Release and uploading DMG..."
fi

# Prefer CHANGELOG.md for this version (that is what the in-app update sheet shows).
# Recycle uses the working-tree file so post-tag changelog edits ship with the
# GitHub notes. First publish still prefers the tagged snapshot.
NOTES=""
if [ "$RECYCLE" = 1 ]; then
  NOTES="$(changelog_github_notes "$VERSION" "$CHANGELOG")"
  if [ -z "$NOTES" ]; then
    echo "❌ CHANGELOG.md has no notes for v${VERSION}."
    echo "   Recycle refuses to publish without release notes."
    exit 1
  fi
else
  CHANGELOG_TMP=$(mktemp)
  if changelog_file_for_tag "$VERSION" "$CHANGELOG_TMP"; then
    NOTES="$(changelog_github_notes "$VERSION" "$CHANGELOG_TMP")"
  fi
  rm -f "$CHANGELOG_TMP"
fi

if [ -n "$NOTES" ]; then
  echo "📝 Release notes (from CHANGELOG.md):"
  echo "$NOTES"
  echo ""
else
  echo "⚠️  No CHANGELOG notes for v${VERSION}; falling back to git log."
  PREV_TAG=$(git tag --sort=-version:refname | grep -v "v${VERSION}" | head -1)
  if [ -n "$PREV_TAG" ]; then
    # Cap the auto-generated git-log list only. Changelog notes are the full
    # markdown section, including nested lists.
    MAX_NOTE_LINES="${CHANGELOG_MAX_NOTE_LINES}"
    ALL_NOTES=$(git log "${PREV_TAG}..${TAG_REF}" \
      --pretty=format:"- %s" \
      | grep -v "^- release:" \
      | grep -v "^- update build" \
      | grep -v "^- docs:" \
      | grep -v "^- chore:" \
      | grep -v "^- Merge ")
    NOTES=$(printf '%s\n' "$ALL_NOTES" | head -n "$MAX_NOTE_LINES")
    if [ "$(printf '%s\n' "$ALL_NOTES" | wc -l)" -gt "$MAX_NOTE_LINES" ]; then
      NOTES="${NOTES}
- …and more — see the full changelog: https://github.com/${GITHUB_REPO}/compare/${PREV_TAG}...v${VERSION}"
    fi
  else
    NOTES="Initial release"
  fi
fi

NOTES_FILE=$(mktemp)
printf '%s\n' "$NOTES" > "$NOTES_FILE"

if [ "$RECYCLE" = 1 ]; then
  echo "💿 Replacing DMG..."
  gh release upload "v${VERSION}" "$DMG_PATH" --clobber --repo "$GITHUB_REPO"
  echo "📝 Updating GitHub release notes from CHANGELOG.md..."
  gh release edit "v${VERSION}" \
    --repo "$GITHUB_REPO" \
    --title "VoxBox v${VERSION}" \
    --notes-file "$NOTES_FILE" \
    --target "$(git rev-parse HEAD)"
elif [ -z "$NOTES" ]; then
  gh release create "v${VERSION}" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "VoxBox v${VERSION}" \
    --generate-notes \
    --latest
else
  gh release create "v${VERSION}" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "VoxBox v${VERSION}" \
    --notes-file "$NOTES_FILE" \
    --latest
fi
rm -f "$NOTES_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉  v${VERSION} is live!"
echo "    https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Clean up marker files
rm -f dist/.release-version dist/.release-dmg
