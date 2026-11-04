#!/usr/bin/env bash
#
# release.sh -- build a notarized, Developer ID signed Copy.app DMG plus a
# Sparkle update enclosure for a tagged release.
#
# Usage: Scripts/release.sh <version> [--dry-run]
#   <version>   marketing version, e.g. 0.1.0 (no leading "v")
#   --dry-run   stop once the DMG is built and signed, before notarizing,
#               stapling, building the Sparkle enclosure, or printing the
#               publish command. Everything up to and including the DMG is
#               still built for real with the Developer ID identity; only
#               notarization and anything after it is skipped.
#
# Pipeline: xcodegen generate -> archive (Developer ID, manual signing) ->
# export -> re-sign every embedded framework/xpc/helper inside-out with a
# secure timestamp -> build + sign the DMG -> notarize the DMG -> staple the
# DMG and the .app -> build the Sparkle zip enclosure and sign it -> print an
# appcast <item> snippet (and refresh docs/appcast.xml) -> print (but do not
# run) the `gh release create` command, since publishing is a human step.
#
# Requires locally:
#   - Xcode + xcodegen
#   - A "Developer ID Application" signing identity for team P7V47BUA2B
#   - A notarytool keychain profile (see COPY_NOTARY_PROFILE below)
#   - Sparkle's sign_update binary, resolved automatically from DerivedData
#
# Env vars:
#   COPY_NOTARY_PROFILE     notarytool keychain profile name (default: copy-notary),
#                           used when the API-key env vars below are not all set
#   NOTARY_API_KEY_PATH     path to an App Store Connect API .p8 key
#   NOTARY_API_KEY_ID       the API key's key ID
#   NOTARY_API_ISSUER_ID    the API key's issuer ID
#                           when all three of the above are set, notarization uses
#                           the App Store Connect API key instead of a keychain
#                           profile (this is how CI notarizes, since it has no
#                           interactive keychain profile to draw on)
#   SPARKLE_ED_KEY_FILE     path to the Sparkle EdDSA private key; when unset,
#                           sign_update reads the key from the `copy` keychain
#                           account instead
set -euo pipefail

usage() {
  echo "Usage: $0 <version> [--dry-run]" >&2
  echo "  <version>   marketing version, e.g. 0.1.0" >&2
  echo "  --dry-run   stop after the DMG is built and signed, before notarizing" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

VERSION="$1"
shift
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      usage
      ;;
  esac
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 0.1.0 (got: $VERSION)" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="Copy"
PROJECT="Copy.xcodeproj"
TEAM_ID="P7V47BUA2B"
SIGN_IDENTITY="Developer ID Application"
: "${COPY_PROVISIONING_PROFILE:?Set COPY_PROVISIONING_PROFILE to the Developer ID provisioning profile UUID}"
NOTARY_PROFILE="${COPY_NOTARY_PROFILE:-copy-notary}"
GITHUB_REPO="tarikbc/Copy"

BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Copy.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/Copy.app"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/exportOptions.plist"
DMG_PATH="$BUILD_DIR/Copy-${VERSION}.dmg"
SPARKLE_ZIP_PATH="$BUILD_DIR/Copy-${VERSION}.zip"
APPCAST_PATH="$ROOT_DIR/docs/appcast.xml"

step() {
  echo ""
  echo "==> $*"
}

step "1/9 Regenerating the Xcode project (xcodegen generate)"
xcodegen generate

# The tag drives $VERSION, but the bundle's version comes from project.yml via
# xcodegen. If they disagree, everything still builds and publishes: the appcast
# advertises the tag's version while the app inside carries project.yml's. Sparkle
# compares CFBundleVersion, so a build number that didn't increase means the
# update is silently never offered -- the same invisible failure mode as the
# v0.1.3 appcast bug, and just as hard to spot after the fact. Fail loudly here
# instead, right after generate has written the plist.
PLIST_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Copy/Info.plist")"
if [[ "$PLIST_SHORT_VERSION" != "$VERSION" ]]; then
  echo "error: version mismatch -- releasing $VERSION but project.yml builds $PLIST_SHORT_VERSION." >&2
  echo "       Bump CFBundleShortVersionString (and CFBundleVersion) in project.yml to $VERSION," >&2
  echo "       commit that to main, and re-tag. See RELEASING.md." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

step "2/9 Archiving Copy.app (Release, Developer ID signing) -> $ARCHIVE_PATH"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$COPY_PROVISIONING_PROFILE" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

step "3/9 Writing $EXPORT_OPTIONS_PLIST"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.tarikbc.Copy</key>
        <string>${COPY_PROVISIONING_PROFILE}</string>
    </dict>
    <key>signingCertificate</key>
    <string>${SIGN_IDENTITY}</string>
</dict>
</plist>
PLIST

step "4/9 Exporting the archive -> $APP_PATH"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: export did not produce $APP_PATH" >&2
  exit 1
fi

step "4.5/9 Verifying the Sparkle public key is not the placeholder"
SPARKLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$SPARKLE_PUBLIC_KEY" || "$SPARKLE_PUBLIC_KEY" == "PLACEHOLDER_REPLACE_AT_KEYGEN" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "WARNING: SUPublicEDKey is still the placeholder (or empty)." >&2
    echo "         This dry-run DMG is fine for a pipeline check, but a real release built this" >&2
    echo "         way would permanently break Sparkle auto-updates for every install." >&2
  else
    echo "error: SUPublicEDKey is still the placeholder (or empty) in $APP_PATH/Contents/Info.plist." >&2
    echo "       Shipping this build would permanently break Sparkle auto-updates for every install:" >&2
    echo "       once users are on a build with the real key, they could never trust an update signed" >&2
    echo "       with a different key again." >&2
    echo "       Generate real Sparkle EdDSA keys first -- see Scripts/sparkle-keys-README.md -- then re-run." >&2
    exit 1
  fi
fi

# Notarization gotcha (learned the hard way on CamLoop): every embedded
# framework, XPC service, and helper .app must carry its own Developer ID
# signature with a secure timestamp, or notarization rejects the submission
# even though the outer app looks correctly signed. `codesign --deep` does
# not reliably propagate `--timestamp` to nested code, so we sign inside-out
# explicitly: deepest nested bundles/executables first (Sparkle's XPCServices,
# Updater.app, and the bare Autoupdate binary), then the frameworks that
# contain them, then the app last.
step "5/9 Re-signing embedded frameworks/helpers inside-out (hardened runtime + secure timestamp)"

sign_one() {
  local path="$1"
  echo "    codesign: $path"
  codesign --force --sign "$SIGN_IDENTITY" \
    --preserve-metadata=entitlements --options runtime --timestamp \
    "$path"
}

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
if [[ -d "$FRAMEWORKS_DIR" ]]; then
  # Every `find` below writes its NUL-delimited results to a temp file via a plain
  # redirect (a simple command) rather than a pipe or process substitution feeding a
  # `while read` loop -- a pipeline/process-substitution's exit status is invisible to
  # `set -e` (the reading loop still exits 0 even if `find` itself failed partway
  # through), which would let a partial listing silently under-sign the bundle. A
  # redirect's exit status is `find`'s own, so `set -e` aborts the script if it fails.
  nested_list_file="$(mktemp)"

  # Find every nested .framework/.xpc/.app plus bare Mach-O executables
  # (e.g. Sparkle's Autoupdate helper, which isn't wrapped in a bundle),
  # then sign deepest-path-first so containers are signed after their
  # contents. `-mindepth 2` excludes the top-level frameworks themselves
  # (e.g. Frameworks/Sparkle.framework) -- those are handled once, below,
  # by the top-level framework loop, so including them here would sign
  # them twice.
  nested_paths=()
  find "$FRAMEWORKS_DIR" -mindepth 2 \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) -print0 > "$nested_list_file"
  while IFS= read -r -d '' path; do
    nested_paths+=("$path")
  done < "$nested_list_file"

  # Bare executables directly inside a framework's version directory
  # (not part of a .framework/.xpc/.app match above) also need their own
  # signature -- e.g. Sparkle.framework/Versions/B/Autoupdate.
  find "$FRAMEWORKS_DIR" -type f -perm -u+x -print0 > "$nested_list_file"
  while IFS= read -r -d '' path; do
    if [[ -x "$path" && ! -d "$path" ]]; then
      nested_paths+=("$path")
    fi
  done < "$nested_list_file"

  rm -f "$nested_list_file"

  # Sort deepest-first by path segment count so nested bundles/executables
  # are signed before the frameworks/apps that contain them. Done as a plain
  # bash insertion sort (the list is a handful of Sparkle helpers) rather
  # than piping through `sort`/`cut`, since their NUL-delimited (-z) modes
  # are GNU-only and unavailable in macOS's BSD toolset.
  if [[ ${#nested_paths[@]} -gt 0 ]]; then
    depth_of() {
      local slashes="${1//[^\/]/}"
      echo "${#slashes}"
    }
    sorted_paths=("${nested_paths[@]}")
    count=${#sorted_paths[@]}
    for ((i = 1; i < count; i++)); do
      current="${sorted_paths[i]}"
      current_depth=$(depth_of "$current")
      j=$((i - 1))
      while (( j >= 0 )) && (( $(depth_of "${sorted_paths[j]}") < current_depth )); do
        sorted_paths[j + 1]="${sorted_paths[j]}"
        j=$((j - 1))
      done
      sorted_paths[j + 1]="$current"
    done
    for path in "${sorted_paths[@]}"; do
      sign_one "$path"
    done
  fi

  # Finally sign each top-level framework itself (e.g. Sparkle.framework),
  # now that everything nested inside it already carries its own signature.
  top_level_list_file="$(mktemp)"
  find "$FRAMEWORKS_DIR" -maxdepth 1 -name "*.framework" -print0 > "$top_level_list_file"
  while IFS= read -r -d '' framework; do
    sign_one "$framework"
  done < "$top_level_list_file"
  rm -f "$top_level_list_file"
fi

step "6/9 Signing Copy.app (top-level, last)"
sign_one "$APP_PATH"

echo ""
echo "    Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

step "7/9 Building the DMG -> $DMG_PATH"
# A branded DMG (background art + laid-out icons) via dmgbuild, which writes the
# window layout straight into the volume's .DS_Store with no Finder/AppleScript
# automation, so it works on headless CI runners (unlike create-dmg). The
# background art is the committed Scripts/dmg-background.png, regenerated by hand
# with Scripts/make-dmg-background.swift when the design changes.
DMG_BACKGROUND="$ROOT_DIR/Scripts/dmg-background.png"
DMG_SETTINGS_SRC="$ROOT_DIR/Scripts/dmg_settings.py"
DMG_SETTINGS="$BUILD_DIR/dmg_settings.py"
DMG_VENV="$BUILD_DIR/dmgvenv"

echo "    Ensuring dmgbuild is available (venv)..."
if [[ ! -x "$DMG_VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$DMG_VENV"
  "$DMG_VENV/bin/pip" install --quiet --disable-pip-version-check dmgbuild
fi

echo "    Laying out the DMG with dmgbuild..."
# `#` is the sed delimiter here because the substituted paths contain `/`.
sed -e "s#APP_PATH_PLACEHOLDER#$APP_PATH#" \
    -e "s#BACKGROUND_PLACEHOLDER#$DMG_BACKGROUND#" \
    "$DMG_SETTINGS_SRC" > "$DMG_SETTINGS"
rm -f "$DMG_PATH"
"$DMG_VENV/bin/dmgbuild" -s "$DMG_SETTINGS" "Copy" "$DMG_PATH"

echo ""
echo "    Signing the DMG..."
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "==> --dry-run: stopping before notarization."
  echo "    Built and signed: $DMG_PATH"
  echo "    What would happen next (real run, no --dry-run):"
  if [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" ]]; then
    echo "      8/9 xcrun notarytool submit \"$DMG_PATH\" --key \"\$NOTARY_API_KEY_PATH\" --key-id \"\$NOTARY_API_KEY_ID\" --issuer \"\$NOTARY_API_ISSUER_ID\" --wait"
  else
    echo "      8/9 xcrun notarytool submit \"$DMG_PATH\" --keychain-profile \"$NOTARY_PROFILE\" --wait"
  fi
  echo "          then: xcrun stapler staple \"$DMG_PATH\" && xcrun stapler staple \"$APP_PATH\""
  echo "      9/9 ditto -c -k --keepParent \"$APP_PATH\" \"$SPARKLE_ZIP_PATH\""
  echo "          then: sign_update \"$SPARKLE_ZIP_PATH\" (Sparkle EdDSA signature)"
  echo "          then: print an appcast <item> snippet, refresh $APPCAST_PATH"
  echo "          then: print (not run) the gh release create command"
  exit 0
fi

step "8/9 Notarizing and stapling"
# CI has no interactive keychain profile to draw on, so it sets these three
# App Store Connect API key env vars instead; locally they are unset and we
# fall back to the keychain profile set up via `xcrun notarytool store-credentials`.
if [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" ]]; then
  echo "    Submitting $DMG_PATH to notarytool (App Store Connect API key)..."
  xcrun notarytool submit "$DMG_PATH" \
    --key "$NOTARY_API_KEY_PATH" \
    --key-id "$NOTARY_API_KEY_ID" \
    --issuer "$NOTARY_API_ISSUER_ID" \
    --wait
else
  echo "    Submitting $DMG_PATH to notarytool (profile: $NOTARY_PROFILE)..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo ""
echo "    Stapling the DMG..."
xcrun stapler staple "$DMG_PATH"

# The notarization submission covers every signed binary inside the DMG,
# including Copy.app itself, so the same ticket can also be stapled directly
# to the exported .app. Stapling the app (not just the DMG) means the copy
# that Sparkle unzips and relaunches on update passes Gatekeeper's assessment
# offline, without depending on a live connection to Apple's servers.
echo "    Stapling Copy.app..."
xcrun stapler staple "$APP_PATH"

step "9/9 Building the Sparkle enclosure and appcast snippet"
rm -f "$SPARKLE_ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$SPARKLE_ZIP_PATH"

SIGN_UPDATE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -path '*sparkle*' -print -quit 2>/dev/null)"
if [[ -z "$SIGN_UPDATE_BIN" ]]; then
  echo "error: could not find Sparkle's sign_update binary under DerivedData." >&2
  echo "       Build the app at least once via Xcode/xcodebuild so SPM resolves Sparkle, then re-run." >&2
  exit 1
fi

# Sign with Copy's dedicated EdDSA key. In CI, SPARKLE_ED_KEY_FILE points at the
# private key written from the SPARKLE_PRIVATE_KEY secret; locally it is unset
# and we read Copy's key from the `copy` keychain account (kept separate from
# other apps' Sparkle keys on the same machine).
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  echo "    Signing $SPARKLE_ZIP_PATH with $SIGN_UPDATE_BIN (key file)"
  SIGN_UPDATE_OUTPUT="$("$SIGN_UPDATE_BIN" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$SPARKLE_ZIP_PATH")"
else
  echo "    Signing $SPARKLE_ZIP_PATH with $SIGN_UPDATE_BIN (keychain account: copy)"
  SIGN_UPDATE_OUTPUT="$("$SIGN_UPDATE_BIN" --account copy "$SPARKLE_ZIP_PATH")"
fi
echo "    $SIGN_UPDATE_OUTPUT"

ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN_UPDATE_OUTPUT")"
ENCLOSURE_LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIGN_UPDATE_OUTPUT")"

if [[ -z "$ED_SIGNATURE" || -z "$ENCLOSURE_LENGTH" ]]; then
  echo "warning: could not parse edSignature/length from sign_update output; check it above and fill the appcast by hand." >&2
  ED_SIGNATURE="${ED_SIGNATURE:-FILL_ME_IN}"
  ENCLOSURE_LENGTH="${ENCLOSURE_LENGTH:-FILL_ME_IN}"
fi

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")"
PUB_DATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
# The Sparkle enclosure MUST be the .zip we just signed with sign_update, NOT the
# .dmg. sign_update's edSignature/length are computed over the zip; pointing the
# enclosure at the dmg makes Sparkle validate the zip's signature against the dmg's
# bytes and fail with "The update is improperly signed." The dmg stays the human
# download link on the website (docs/index.html), not the auto-update enclosure.
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/Copy-${VERSION}.zip"

APPCAST_ITEM="$(cat <<ITEM
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                sparkle:edSignature="${ED_SIGNATURE}"
                length="${ENCLOSURE_LENGTH}"
                type="application/octet-stream"
            />
        </item>
ITEM
)"

echo ""
echo "    Appcast <item> snippet:"
echo "$APPCAST_ITEM"

if [[ ! -f "$APPCAST_PATH" ]]; then
  echo ""
  echo "    $APPCAST_PATH does not exist yet; creating a new appcast skeleton."
  mkdir -p "$(dirname "$APPCAST_PATH")"
  cat > "$APPCAST_PATH" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Copy</title>
        <link>https://tarikbc.github.io/Copy/appcast.xml</link>
        <description>Copy release notes and updates</description>
        <language>en</language>
${APPCAST_ITEM}
    </channel>
</rss>
APPCAST
else
  echo ""
  echo "    Inserting the new <item> into the existing $APPCAST_PATH"
  # Insert the new item right after the opening <channel> tag so the newest
  # release sorts first, matching Sparkle's convention of newest-item-first.
  #
  # The snippet is multi-line, so it's read from a file inside awk (via getline)
  # rather than passed with `-v item=...`: BSD awk (what the macOS CI runner
  # uses) rejects a literal newline in a `-v` assignment with "awk: newline in
  # string", which silently broke this step. Reading from a file is portable
  # across both BSD and GNU awk.
  APPCAST_ITEM_FILE="$(mktemp)"
  printf '%s\n' "$APPCAST_ITEM" > "$APPCAST_ITEM_FILE"
  APPCAST_TMP="$(mktemp)"
  awk -v itemfile="$APPCAST_ITEM_FILE" '
    { print }
    /<channel>/ && !inserted {
      while ((getline line < itemfile) > 0) print line
      close(itemfile)
      inserted = 1
    }
  ' "$APPCAST_PATH" > "$APPCAST_TMP"
  mv "$APPCAST_TMP" "$APPCAST_PATH"
  rm -f "$APPCAST_ITEM_FILE"
fi

step "Done. Publish command (run this yourself once you are ready -- it is not run for you):"
echo "gh release create \"v${VERSION}\" \"$DMG_PATH\" \"$SPARKLE_ZIP_PATH\" --title \"Copy ${VERSION}\" --notes-file CHANGELOG.md"
echo ""
echo "Artifacts:"
echo "  $DMG_PATH"
echo "  $SPARKLE_ZIP_PATH"
echo "  $APPCAST_PATH"
