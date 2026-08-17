#!/bin/bash
# common.sh — Shared configuration and helpers for VoxBox scripts.
#
# Source it from any script in scripts/:
#     source "$(dirname "$0")/lib/common.sh"
#
# Update project-wide settings (signing identity, bundle IDs, repo) HERE — in
# one place — instead of editing each script.

# ── Identity & signing ────────────────────────────────────────────────────────
APP_BUNDLE_ID="dev.edlittle.VoxBox"
DEV_BUNDLE_ID="dev.edlittle.VoxBox.dev"
LEGACY_BUNDLE_ID="dev.cubbei.voxbox"
APPLE_ID="${APPLE_ID:-email@example.com}" # set to the Apple ID of the signing developer account
APPLE_TEAM_ID="${APPLE_TEAM_ID:-team-id-here}"
NOTARY_PROFILE="AC_PASSWORD"          # xcrun notarytool --keychain-profile name
SIGN_IDENTITY="Developer ID Application"

# ── Project layout ────────────────────────────────────────────────────────────
SCHEME="voxbox"
PROJECT_FILE="voxbox.xcodeproj/project.pbxproj"
CHANGELOG="CHANGELOG.md"
GITHUB_REPO="edl-bb/VoxBox"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Fail unless run from the repository root.
require_repo_root() {
  if [ ! -f "$PROJECT_FILE" ]; then
    echo "❌ Error: Must run from project root"
    exit 1
  fi
}

# Fail if the working tree has uncommitted changes.
require_clean_tree() {
  if ! git diff-index --quiet HEAD --; then
    echo "❌ Error: You have uncommitted changes"
    echo ""
    git status --short
    exit 1
  fi
}

# Echo the current MARKETING_VERSION from the Xcode project.
current_version() {
  perl -ne 'print $1 and exit if /MARKETING_VERSION = ([^;]+);/' "$PROJECT_FILE"
}

# Resolve the version to release, echoing it.
#   resolve_version "1.2.3"  → validates and echoes 1.2.3
#   resolve_version ""       → auto-bumps the patch of the current version
resolve_version() {
  local requested="$1"
  if [ -z "$requested" ]; then
    local current major minor patch
    current="$(current_version)"
    major="$(echo "$current" | cut -d. -f1)"
    minor="$(echo "$current" | cut -d. -f2)"
    patch="$(echo "$current" | cut -d. -f3)"
    echo "${major}.${minor}.$((patch + 1))"
  else
    if ! [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "❌ Error: Version must be semver (e.g., 1.2.3)" >&2
      exit 1
    fi
    echo "$requested"
  fi
}

# Ensure notarization credentials exist in the keychain, prompting once for an
# app-specific password if the profile is missing.
ensure_notary_credentials() {
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    return 0
  fi

  echo "❌ Keychain profile '$NOTARY_PROFILE' not found"
  echo ""
  echo "You need an app-specific password for notarization."
  echo "  1. Go to: https://appleid.apple.com"
  echo "  2. Sign in with: $APPLE_ID"
  echo "  3. Security → App-Specific Passwords → Generate"
  echo ""
  read -rp "Enter app-specific password: " -s APP_PASSWORD
  echo ""
  [ -z "$APP_PASSWORD" ] && { echo "❌ Password required"; exit 1; }

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APP_PASSWORD"
  echo ""
  echo "✅ Credentials stored. Continuing..."
  echo ""
}

# Changelog helpers used by create-release.sh and deploy-release.sh.
# shellcheck source=changelog.sh
source "$(dirname "${BASH_SOURCE[0]}")/changelog.sh"
