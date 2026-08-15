# Release Process

VoxBox releases run in **two steps**:

1. **Build** (`make create-release`) — bump version, build, sign, notarize, and produce a signed DMG in `dist/`. Nothing leaves your machine.
2. **Deploy** (`make deploy-release`) — push the release commit + tag and upload the DMG to GitHub.

This split lets you build and test the DMG locally before publishing. Shared
settings (signing identity, Apple ID, team ID, bundle IDs, repo) live in one
place: `scripts/lib/common.sh`.

## Release Criteria
Use your judgment, but a release is usually warranted when:
- A user-visible feature or UX improvement lands
- A bugfix affects multiple users or a core flow
- Performance or stability improvements are measurable

## Prerequisites

### One-Time Setup

**1. Code Signing Certificate**

Verify you have a Developer ID Application certificate:
```bash
security find-identity -v -p codesigning
# Should show: "Developer ID Application: ..."
```

**2. App-Specific Password**

Get from [appleid.apple.com](https://appleid.apple.com) → Security → App-Specific Passwords

**Note:** The release script will prompt for this on first run and store it in Keychain.

**3. GitHub CLI** (optional)

```bash
brew install gh
gh auth login
```

---

## Creating a Release

### Step 1 — Build (`make create-release`)

```bash
make create-release            # auto-bump patch (e.g. 1.0.2 → 1.0.3)
make create-release VERSION=2.0.0   # or specify the version
make create-release-current    # keep MARKETING_VERSION already in the project
```

**What happens:**

1. ✅ **Checks for uncommitted changes** — fails if you have uncommitted work
2. ✅ **Resolves the version** — auto-bumps patch, uses `VERSION=`, or (`create-release-current`) reads the version already in the Xcode project
3. ✅ **Updates the Xcode project** — MARKETING_VERSION and CURRENT_PROJECT_VERSION (skipped by `create-release-current`)
4. ✅ **Updates CHANGELOG** with the release date (skipped by `create-release-current`)
5. ✅ **Commits + tags locally** (not pushed yet). `create-release-current` only tags HEAD if `v<version>` is missing.
6. ✅ **Builds and signs the app** (Release config, Developer ID)
7. ✅ **Creates and signs the DMG** in `dist/`
8. ✅ **Notarizes with Apple** (~2-5 minutes) and **staples** the ticket

The DMG path and version are written to `dist/.release-version` / `dist/.release-dmg`
so step 2 can pick them up automatically. Inspect/test the DMG before deploying.

### Step 2 — Deploy (`make deploy-release`)

```bash
make deploy-release                  # reads version from dist/.release-version
make deploy-release VERSION=2.0.0    # or pass it explicitly
```

Pushes the release commit + tag and creates the GitHub Release with the DMG
attached (release notes generated from the commit log).

**Total time: ~6-8 minutes**

> You can also call the scripts directly: `./scripts/create-release.sh [version]`
> then `./scripts/deploy-release.sh [version]`.

---

## Verification

After the release, verify on a **different Mac**:

```bash
# Download and open the DMG
# Drag VoxBox.app to Applications
# Double-click to open - should NOT show Gatekeeper warning

# Verify signature
codesign -dv --verbose=4 /Applications/VoxBox.app

# Verify notarization
spctl -a -vv /Applications/VoxBox.app
# Should show: accepted, source=Notarized Developer ID
```

## Troubleshooting

### Authentication Error (401)
```
Error: HTTP status code: 401. Unable to authenticate.
```

**Fix:** Regenerate your app-specific password and re-run the keychain setup:
```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "your-apple-id@example.com" \
  --team-id "PCV4UMSRZX" \
  --password "NEW_PASSWORD_HERE"
```

### Notarization Rejected

Check the submission logs:
```bash
xcrun notarytool history --keychain-profile "AC_PASSWORD"
# Get the submission ID, then:
xcrun notarytool log <submission-id> --keychain-profile "AC_PASSWORD"
```

Common issues:
- Missing Hardened Runtime entitlement
- Invalid code signature
- Unsigned frameworks/libraries

See [CODESIGNING.md](CODESIGNING.md) for detailed troubleshooting.

### Build Errors

If Xcode build fails:
1. Clean build folder: `xcodebuild clean -scheme voxbox`
2. Verify certificate is valid: `security find-identity -v -p codesigning`
3. Check Xcode version: `xcodebuild -version`

## Notes

- **DMG files are NOT committed to git** - they're large and shouldn't be version-controlled
- **GitHub Actions workflow is disabled** - all release work happens locally
- **Notarization typically takes 2-5 minutes** - Apple's servers process the app
- **The DMG is stapled** - notarization ticket embedded, works offline
