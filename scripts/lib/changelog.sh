#!/bin/bash
# changelog.sh — Extract and promote CHANGELOG.md sections for releases.
#
# Sourced from common.sh. Functions take an explicit file path so tests can
# point at a fixture; callers default to $CHANGELOG.

CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
GITHUB_REPO="${GITHUB_REPO:-edl-bb/VoxBox}"
CHANGELOG_MAX_NOTE_LINES="${CHANGELOG_MAX_NOTE_LINES:-20}"

# Print the body of "## [VERSION]" (heading excluded) through the next H2.
changelog_section() {
  local version="$1"
  local file="${2:-$CHANGELOG}"
  awk -v ver="$version" '
    BEGIN { needle = "## [" ver "]" }
    !found {
      if (index($0, needle) == 1) {
        rest = substr($0, length(needle) + 1)
        if (rest == "" || rest ~ /^[[:space:]]/) { found = 1 }
      }
      next
    }
    /^## \[/ { exit }
    { print }
  ' "$file"
}

# Print the body of "## [Unreleased]" through the next H2.
changelog_unreleased_section() {
  local file="${1:-$CHANGELOG}"
  awk '
    !found {
      if ($0 ~ /^## \[Unreleased\]([ [:space:]]|$)/) { found = 1 }
      next
    }
    /^## \[/ { exit }
    { print }
  ' "$file"
}

# Turn a changelog section into GitHub release notes, keeping markdown
# (list markers, nested indents, ### headings). Drop only the SpeakType
# footer, horizontal rules, and trailing whitespace.
changelog_format_notes() {
  sed -E \
    -e 's/\r$//' \
    -e 's/[[:space:]]+$//' \
    -e '/^[[:space:]]*_/d' \
    -e '/^---+$/d' \
  | perl -0777 -pe 's/\s+\z/\n/'
}

# True when notes have content besides empty list markers or blank lines.
changelog_notes_are_substantive() {
  local stripped
  stripped="$(printf '%s\n' "$1" | sed -E \
    -e 's/^[[:space:]]*[-*][[:space:]]*//' \
    -e 's/^#+[[:space:]]+//' \
    -e '/^[[:space:]]*$/d')"
  [ -n "$stripped" ]
}

changelog_notes() {
  local version="$1"
  local file="${2:-$CHANGELOG}"
  changelog_section "$version" "$file" | changelog_format_notes
}

changelog_unreleased_notes() {
  local file="${1:-$CHANGELOG}"
  changelog_unreleased_section "$file" | changelog_format_notes
}

changelog_has_notes() {
  changelog_notes_are_substantive "$(changelog_notes "$1" "${2:-$CHANGELOG}")"
}

changelog_has_unreleased_notes() {
  changelog_notes_are_substantive "$(changelog_unreleased_notes "${1:-$CHANGELOG}")"
}

# Move Unreleased items under a new dated version heading. No-op if the
# version section already exists.
changelog_promote_unreleased() {
  local version="$1"
  local release_date="$2"
  local file="${3:-$CHANGELOG}"
  CHANGELOG_VERSION="$version" CHANGELOG_DATE="$release_date" perl -0pi -e '
    unless ($_ =~ /^## \[\Q$ENV{CHANGELOG_VERSION}\E\]/m) {
      s/(^## \[Unreleased\][^\n]*\n)(.*?)(?=^## \[|\z)/$1 . "\n## [$ENV{CHANGELOG_VERSION}] - $ENV{CHANGELOG_DATE}\n" . $2/mseg;
    }
  ' "$file"
}

# Notes ready for `gh release create --notes`. The full version section is
# included so nested markdown lists are not truncated.
changelog_github_notes() {
  local version="$1"
  local file="${2:-$CHANGELOG}"
  changelog_notes "$version" "$file"
}

# Prefer the changelog as of the git tag so deploy notes match what was built.
changelog_file_for_tag() {
  local version="$1"
  local dest="$2"
  if git cat-file -e "v${version}:CHANGELOG.md" 2>/dev/null; then
    git show "v${version}:CHANGELOG.md" > "$dest"
    return 0
  fi
  if [ -f "$CHANGELOG" ]; then
    cat "$CHANGELOG" > "$dest"
    return 0
  fi
  return 1
}

changelog_print_missing_notes_help() {
  local version="$1"
  local keep_version="$2"
  local today
  today="$(date +%Y-%m-%d)"
  echo "❌ CHANGELOG.md has no notes for ${version}."
  echo ""
  if [ "$keep_version" = 1 ]; then
    echo "   --current does not edit the changelog. Add a section, commit it,"
    echo "   then re-run ./scripts/create-release.sh --current:"
  else
    echo "   Add a section before releasing:"
  fi
  echo ""
  echo "   ## [${version}] - ${today}"
  echo "   - User-facing change."
  echo ""
  if [ "$keep_version" != 1 ]; then
    echo "   Or list the changes under ## [Unreleased] and this script will"
    echo "   move them into the ${version} section."
    echo ""
  fi
}

# Validate (and on a version bump, maybe promote Unreleased). Echoes status.
# Returns 0 when the version has notes; 1 otherwise.
changelog_prepare_for_release() {
  local version="$1"
  local keep_version="$2"
  local file="${3:-$CHANGELOG}"

  if [ ! -f "$file" ]; then
    echo "❌ ${file} not found."
    changelog_print_missing_notes_help "$version" "$keep_version"
    return 1
  fi

  if changelog_has_notes "$version" "$file"; then
    echo "📝 Using CHANGELOG notes for v${version}"
    return 0
  fi

  if [ "$keep_version" = 1 ]; then
    changelog_print_missing_notes_help "$version" "$keep_version"
    return 1
  fi

  if changelog_has_unreleased_notes "$file"; then
    local release_date
    release_date="$(date +%Y-%m-%d)"
    echo "📝 Moving Unreleased notes into [${version}] - ${release_date}"
    changelog_promote_unreleased "$version" "$release_date" "$file"
    if changelog_has_notes "$version" "$file"; then
      return 0
    fi
  fi

  changelog_print_missing_notes_help "$version" "$keep_version"
  return 1
}
