#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCMB"
EXECUTABLE_NAME="CodexCreditMenuBar"
BUNDLE_ID="com.codex.creditmenubar"
APP_VERSION="0.3.30"
APP_BUILD="47"
DEPLOYMENT_TARGET="10.15"
ARM64_DEPLOYMENT_TARGET="11.0"
ARM64_TRIPLE="arm64-apple-macosx$ARM64_DEPLOYMENT_TARGET"
X86_64_TRIPLE="x86_64-apple-macosx$DEPLOYMENT_TARGET"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SWIFTPM="$ROOT_DIR/Scripts/swiftpm.sh"
PRODUCTS_DIR="$ROOT_DIR/Products"
RELEASE_DIR="$PRODUCTS_DIR/Release"
FINAL_APP_PATH=""
FINAL_DMG_PATH=""
ICON_TOOL="$ROOT_DIR/Tools/MakeAppIcon.swift"
SHARE_GUIDE="$ROOT_DIR/SHARE_README.md"
SPARKLE_ARTIFACT_ROOT="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK_SOURCE="$SPARKLE_ARTIFACT_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_PUBLIC_KEY_FILE="$ROOT_DIR/Configuration/SparklePublicKey.txt"
SPARKLE_FEED_URL="https://raw.githubusercontent.com/armsone/CCMB/main/appcast.xml"
DMG_GUIDE_NAME="설치 및 사용 안내.md"
BUILD_ROOT="$ROOT_DIR/.build/distribution"
ARM64_SCRATCH="$BUILD_ROOT/arm64"
X86_64_SCRATCH="$BUILD_ROOT/x86_64"
PACKAGE_LOCK_PATH="$RELEASE_DIR/.package.lock"

PACKAGE_WORK_DIR=""
APP_PATH=""
STAGING_DIR=""
DMG_PATH=""
NOTARY_ZIP=""
APP_NOTARY_RESULT=""
DMG_NOTARY_RESULT=""
BACKUP_APP_PATH=""
BACKUP_DMG_PATH=""
HAD_FINAL_APP=false
HAD_FINAL_DMG=false
APP_PUBLISHED=false
DMG_PUBLISHED=false
PUBLISH_COMMITTED=false
PACKAGE_LOCK_HELD=false

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARIZE=false
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

usage() {
  printf 'Usage: %s [--notarize]\n' "$(basename "$0")"
  printf '\n'
  printf 'Environment:\n'
  printf '  CODESIGN_IDENTITY               Developer ID Application identity. Defaults to ad-hoc "-".\n'
  printf '  NOTARY_PROFILE                  xcrun notarytool keychain profile name.\n'
}

while (($#)); do
  case "$1" in
    --notarize)
      NOTARIZE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ "$NOTARIZE" == true ]]; then
  FINAL_APP_PATH="$RELEASE_DIR/$APP_NAME.app"
  FINAL_DMG_PATH="$PRODUCTS_DIR/$APP_NAME.dmg"
else
  FINAL_APP_PATH="$RELEASE_DIR/$APP_NAME-local.app"
  FINAL_DMG_PATH="$PRODUCTS_DIR/$APP_NAME-local.dmg"
fi

if [[ "$NOTARIZE" == true && "$CODESIGN_IDENTITY" == "-" ]]; then
  printf 'error: --notarize requires CODESIGN_IDENTITY="Developer ID Application: ..."\n' >&2
  exit 64
fi

if [[ "$NOTARIZE" == true && "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  printf 'error: --notarize requires a Developer ID Application identity, not %s\n' "$CODESIGN_IDENTITY" >&2
  exit 64
fi

if [[ ! -f "$SHARE_GUIDE" ]]; then
  printf 'error: distribution guide is missing: %s\n' "$SHARE_GUIDE" >&2
  exit 66
fi

notary_args=()
if [[ "$NOTARIZE" == true ]]; then
  AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"
  if ! grep -F -- "$CODESIGN_IDENTITY" <<< "$AVAILABLE_IDENTITIES" >/dev/null; then
    printf 'error: codesigning identity is not available in the current keychain: %s\n' "$CODESIGN_IDENTITY" >&2
    exit 69
  fi

  if ! GATEKEEPER_STATUS="$(spctl --status 2>&1)"; then
    if [[ "$GATEKEEPER_STATUS" != *"assessments disabled"* ]]; then
      printf 'error: unable to read Gatekeeper assessment status.\n' >&2
      printf 'Current output: %s\n' "$GATEKEEPER_STATUS" >&2
      exit 69
    fi
  fi
  if [[ "$GATEKEEPER_STATUS" != *"assessments enabled"* ]]; then
    printf 'error: Gatekeeper assessments must be enabled for a fail-closed distribution check.\n' >&2
    printf 'Current status: %s\n' "$GATEKEEPER_STATUS" >&2
    exit 69
  fi

  if [[ -z "$NOTARY_PROFILE" ]]; then
    printf 'error: notarization requires NOTARY_PROFILE so credentials never appear in process arguments.\n' >&2
    exit 64
  fi
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
fi

require_products_path() {
  local target="$1"

  case "$target" in
    "$PRODUCTS_DIR"/*) ;;
    *)
      printf 'error: refusing to modify path outside Products: %s\n' "$target" >&2
      exit 1
      ;;
  esac
}

package_lock_identity() {
  local lock_path="$1"

  if [[ -e "$lock_path" || -L "$lock_path" ]]; then
    stat -f '%d:%i:%HT' "$lock_path"
  else
    printf 'missing\n'
  fi
}

read_package_lock_pid() {
  local lock_path="$1"
  local pid_path="$lock_path"
  local owner_pid=""

  if [[ -d "$lock_path" && ! -L "$lock_path" ]]; then
    pid_path="$lock_path/pid"
  fi
  if [[ -f "$pid_path" && ! -L "$pid_path" ]]; then
    if ! IFS= read -r owner_pid < "$pid_path"; then
      owner_pid=""
    fi
  fi
  printf '%s\n' "$owner_pid"
}

is_live_packaging_pid() {
  local owner_pid="$1"
  local owner_command

  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  ((owner_pid > 1)) || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 1

  if ! owner_command="$(ps -p "$owner_pid" -o command= 2>/dev/null)"; then
    return 0
  fi
  if [[ -z "$owner_command" || "$owner_command" == *"package-macos.sh"* ]]; then
    return 0
  fi
  return 1
}

remove_stale_package_lock() {
  require_products_path "$PACKAGE_LOCK_PATH"
  if [[ -d "$PACKAGE_LOCK_PATH" && ! -L "$PACKAGE_LOCK_PATH" ]]; then
    rm -rf "$PACKAGE_LOCK_PATH"
  else
    rm -f "$PACKAGE_LOCK_PATH"
  fi
}

try_acquire_package_lock() {
  if /usr/bin/shlock -f "$PACKAGE_LOCK_PATH" -p "$$"; then
    PACKAGE_LOCK_HELD=true
    return 0
  fi
  return 1
}

acquire_package_lock() {
  local observed_identity
  local current_identity
  local owner_pid

  require_products_path "$PACKAGE_LOCK_PATH"
  if try_acquire_package_lock; then
    return
  fi

  observed_identity="$(package_lock_identity "$PACKAGE_LOCK_PATH")"
  owner_pid="$(read_package_lock_pid "$PACKAGE_LOCK_PATH")"
  if is_live_packaging_pid "$owner_pid"; then
    printf 'error: another packaging process is running (PID %s, lock: %s).\n' "$owner_pid" "$PACKAGE_LOCK_PATH" >&2
    exit 73
  fi

  # Give a just-created legacy directory lock one brief chance to publish its PID.
  sleep 1
  current_identity="$(package_lock_identity "$PACKAGE_LOCK_PATH")"
  owner_pid="$(read_package_lock_pid "$PACKAGE_LOCK_PATH")"
  if is_live_packaging_pid "$owner_pid"; then
    printf 'error: another packaging process is running (PID %s, lock: %s).\n' "$owner_pid" "$PACKAGE_LOCK_PATH" >&2
    exit 73
  fi

  if [[ "$current_identity" == "$observed_identity" && "$current_identity" != "missing" ]]; then
    printf 'Removing stale package lock: %s\n' "$PACKAGE_LOCK_PATH" >&2
    remove_stale_package_lock
  fi

  if try_acquire_package_lock; then
    return
  fi

  owner_pid="$(read_package_lock_pid "$PACKAGE_LOCK_PATH")"
  if is_live_packaging_pid "$owner_pid"; then
    printf 'error: another packaging process won the package lock (PID %s, lock: %s).\n' "$owner_pid" "$PACKAGE_LOCK_PATH" >&2
  else
    printf 'error: unable to acquire package lock after one stale-lock recovery attempt: %s\n' "$PACKAGE_LOCK_PATH" >&2
  fi
  exit 73
}

cleanup_package_workspace() {
  local exit_status=$?
  local rollback_ok=true

  set +e
  if [[ "$PUBLISH_COMMITTED" != true ]]; then
    if [[ "$APP_PUBLISHED" == true ]]; then
      require_products_path "$FINAL_APP_PATH"
      rm -rf "$FINAL_APP_PATH"
    fi
    if [[ "$HAD_FINAL_APP" == true && ( -e "$BACKUP_APP_PATH" || -L "$BACKUP_APP_PATH" ) ]]; then
      if ! mv "$BACKUP_APP_PATH" "$FINAL_APP_PATH"; then
        printf 'error: could not restore previous app from %s\n' "$BACKUP_APP_PATH" >&2
        rollback_ok=false
      fi
    fi

    if [[ "$DMG_PUBLISHED" == true ]]; then
      require_products_path "$FINAL_DMG_PATH"
      rm -f "$FINAL_DMG_PATH"
    fi
    if [[ "$HAD_FINAL_DMG" == true && ( -e "$BACKUP_DMG_PATH" || -L "$BACKUP_DMG_PATH" ) ]]; then
      if ! mv "$BACKUP_DMG_PATH" "$FINAL_DMG_PATH"; then
        printf 'error: could not restore previous DMG from %s\n' "$BACKUP_DMG_PATH" >&2
        rollback_ok=false
      fi
    fi
  fi

  if [[ -n "$PACKAGE_WORK_DIR" && -d "$PACKAGE_WORK_DIR" ]]; then
    require_products_path "$PACKAGE_WORK_DIR"
    if [[ "$rollback_ok" == true ]]; then
      rm -rf "$PACKAGE_WORK_DIR"
    else
      printf 'error: retained package workspace for recovery: %s\n' "$PACKAGE_WORK_DIR" >&2
    fi
  fi

  if [[ "$PACKAGE_LOCK_HELD" == true ]]; then
    require_products_path "$PACKAGE_LOCK_PATH"
    if [[ "$(read_package_lock_pid "$PACKAGE_LOCK_PATH")" == "$$" ]]; then
      if ! rm -f "$PACKAGE_LOCK_PATH"; then
        printf 'error: could not remove package lock: %s\n' "$PACKAGE_LOCK_PATH" >&2
      fi
    else
      printf 'error: package lock ownership changed; refusing to remove it: %s\n' "$PACKAGE_LOCK_PATH" >&2
    fi
  fi

  exit "$exit_status"
}

publish_artifacts() {
  require_products_path "$FINAL_APP_PATH"
  require_products_path "$FINAL_DMG_PATH"
  require_products_path "$APP_PATH"
  require_products_path "$DMG_PATH"

  if [[ -e "$FINAL_APP_PATH" || -L "$FINAL_APP_PATH" ]]; then
    HAD_FINAL_APP=true
    mv "$FINAL_APP_PATH" "$BACKUP_APP_PATH"
  fi
  APP_PUBLISHED=true
  mv "$APP_PATH" "$FINAL_APP_PATH"

  if [[ -e "$FINAL_DMG_PATH" || -L "$FINAL_DMG_PATH" ]]; then
    HAD_FINAL_DMG=true
    mv "$FINAL_DMG_PATH" "$BACKUP_DMG_PATH"
  fi
  DMG_PUBLISHED=true
  mv "$DMG_PATH" "$FINAL_DMG_PATH"
  PUBLISH_COMMITTED=true
}

notarize_and_require_accepted() {
  local artifact="$1"
  local result_path="$2"
  local status

  xcrun notarytool submit "$artifact" "${notary_args[@]}" --wait --output-format json > "$result_path"
  status="$(plutil -extract status raw -o - "$result_path")"
  if [[ "$status" != "Accepted" ]]; then
    printf 'error: Apple notarization did not accept %s (status: %s).\n' "$artifact" "$status" >&2
    plutil -p "$result_path" >&2
    exit 1
  fi
}

verify_developer_id_app_signature() {
  local target="$1"
  local details

  details="$(codesign -dvvv "$target" 2>&1)"
  printf '%s\n' "$details"

  if [[ "$details" != *"Authority=Developer ID Application:"* ]]; then
    printf 'error: app is not signed with a Developer ID Application certificate: %s\n' "$target" >&2
    exit 1
  fi
  if [[ "$details" != *"(runtime)"* ]]; then
    printf 'error: hardened runtime is missing from the app signature: %s\n' "$target" >&2
    exit 1
  fi
  if [[ "$details" != *"Timestamp="* ]]; then
    printf 'error: secure timestamp is missing from the app signature: %s\n' "$target" >&2
    exit 1
  fi
}

verify_developer_id_dmg_signature() {
  local target="$1"
  local details

  details="$(codesign -dvvv "$target" 2>&1)"
  printf '%s\n' "$details"

  if [[ "$details" != *"Authority=Developer ID Application:"* ]]; then
    printf 'error: DMG is not signed with a Developer ID Application certificate: %s\n' "$target" >&2
    exit 1
  fi
  if [[ "$details" != *"Timestamp="* ]]; then
    printf 'error: secure timestamp is missing from the DMG signature: %s\n' "$target" >&2
    exit 1
  fi
}

sign_sparkle_framework() {
  local framework="$1"
  local sign_args=(--force --options runtime --sign "$CODESIGN_IDENTITY")

  if [[ "$NOTARIZE" == true ]]; then
    sign_args+=(--timestamp)
  fi

  codesign "${sign_args[@]}" "$framework/Versions/B/Autoupdate"
  codesign "${sign_args[@]}" "$framework/Versions/B/Updater.app"
  codesign "${sign_args[@]}" "$framework"
}

mkdir -p "$RELEASE_DIR"
trap cleanup_package_workspace EXIT
acquire_package_lock

"$SWIFTPM" package --package-path "$ROOT_DIR" resolve
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  printf 'error: Sparkle framework is missing after dependency resolution: %s\n' "$SPARKLE_FRAMEWORK_SOURCE" >&2
  exit 66
fi
if [[ ! -f "$SPARKLE_PUBLIC_KEY_FILE" ]]; then
  printf 'error: Sparkle public key is missing: %s\n' "$SPARKLE_PUBLIC_KEY_FILE" >&2
  exit 66
fi
SPARKLE_PUBLIC_ED_KEY="$(tr -d '\r\n' < "$SPARKLE_PUBLIC_KEY_FILE")"
if [[ ! "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  printf 'error: Sparkle public key is not a valid base64 Ed25519 public key.\n' >&2
  exit 65
fi

printf 'Building arm64 release binary (%s)...\n' "$ARM64_TRIPLE"
"$SWIFTPM" build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$ARM64_SCRATCH" \
  --triple "$ARM64_TRIPLE" \
  -c release \
  --product "$EXECUTABLE_NAME"
ARM64_BIN_DIR="$("$SWIFTPM" build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$ARM64_SCRATCH" \
  --triple "$ARM64_TRIPLE" \
  -c release \
  --show-bin-path)"

printf 'Building x86_64 release binary (%s)...\n' "$X86_64_TRIPLE"
"$SWIFTPM" build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$X86_64_SCRATCH" \
  --triple "$X86_64_TRIPLE" \
  -c release \
  --product "$EXECUTABLE_NAME"
X86_64_BIN_DIR="$("$SWIFTPM" build \
  --package-path "$ROOT_DIR" \
  --scratch-path "$X86_64_SCRATCH" \
  --triple "$X86_64_TRIPLE" \
  -c release \
  --show-bin-path)"

printf 'Creating app bundle...\n'
PACKAGE_WORK_DIR="$(mktemp -d "$RELEASE_DIR/.package.XXXXXX")"
require_products_path "$PACKAGE_WORK_DIR"
APP_PATH="$PACKAGE_WORK_DIR/$APP_NAME.app"
STAGING_DIR="$PACKAGE_WORK_DIR/dmg-staging"
DMG_PATH="$PACKAGE_WORK_DIR/$APP_NAME.dmg"
NOTARY_ZIP="$PACKAGE_WORK_DIR/$APP_NAME-notary.zip"
APP_NOTARY_RESULT="$PACKAGE_WORK_DIR/$APP_NAME-app-notary-result.json"
DMG_NOTARY_RESULT="$PACKAGE_WORK_DIR/$APP_NAME-dmg-notary-result.json"
BACKUP_APP_PATH="$PACKAGE_WORK_DIR/previous-$APP_NAME.app"
BACKUP_DMG_PATH="$PACKAGE_WORK_DIR/previous-$APP_NAME.dmg"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"

if [[ ! -f "$ICON_TOOL" ]]; then
  printf 'error: icon generator is missing: %s\n' "$ICON_TOOL" >&2
  exit 1
fi
printf 'Generating app icon...\n'
swift "$ICON_TOOL" "$APP_PATH/Contents/Resources/$EXECUTABLE_NAME.icns"
if [[ ! -f "$APP_PATH/Contents/Resources/$EXECUTABLE_NAME.icns" ]]; then
  printf 'error: icon generation failed.\n' >&2
  exit 1
fi

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
lipo -create \
  "$ARM64_BIN_DIR/$EXECUTABLE_NAME" \
  "$X86_64_BIN_DIR/$EXECUTABLE_NAME" \
  -output "$APP_EXECUTABLE"
chmod 755 "$APP_EXECUTABLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_EXECUTABLE"

SPARKLE_FRAMEWORK_DEST="$APP_PATH/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK_DEST"
rm -rf "$SPARKLE_FRAMEWORK_DEST/Versions/B/XPCServices" "$SPARKLE_FRAMEWORK_DEST/XPCServices"

UNIVERSAL_ARCHS="$(lipo -archs "$APP_EXECUTABLE")"
if [[ " $UNIVERSAL_ARCHS " != *" arm64 "* || " $UNIVERSAL_ARCHS " != *" x86_64 "* ]]; then
  printf 'error: universal binary verification failed; expected arm64 and x86_64, got: %s\n' "$UNIVERSAL_ARCHS" >&2
  exit 1
fi
printf 'Universal executable architectures: %s\n' "$UNIVERSAL_ARCHS"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$EXECUTABLE_NAME.icns</string>
  <key>CFBundleIconName</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>21600</integer>
</dict>
</plist>
PLIST
plutil -lint "$APP_PATH/Contents/Info.plist"

printf 'Signing app with identity: %s\n' "$CODESIGN_IDENTITY"
sign_sparkle_framework "$SPARKLE_FRAMEWORK_DEST"
if [[ "$NOTARIZE" == true ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_PATH"
  verify_developer_id_app_signature "$APP_PATH"
else
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

if [[ "$NOTARIZE" == true ]]; then
  printf 'Submitting app for notarization...\n'
  ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
  notarize_and_require_accepted "$NOTARY_ZIP" "$APP_NOTARY_RESULT"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  codesign --verify --deep --strict --verbose=4 "$APP_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
fi

printf 'Creating DMG...\n'
mkdir -p "$STAGING_DIR"
STAGED_APP_PATH="$STAGING_DIR/$APP_NAME.app"
ditto "$APP_PATH" "$STAGED_APP_PATH"
codesign --verify --deep --strict --verbose=4 "$STAGED_APP_PATH"
if [[ "$NOTARIZE" == true ]]; then
  xcrun stapler validate "$STAGED_APP_PATH"
fi
ditto "$SHARE_GUIDE" "$STAGING_DIR/$DMG_GUIDE_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$NOTARIZE" == true ]]; then
  printf 'Signing DMG...\n'
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
  verify_developer_id_dmg_signature "$DMG_PATH"
  codesign --verify --strict --verbose=4 "$DMG_PATH"
fi

if [[ "$NOTARIZE" == true ]]; then
  printf 'Submitting DMG for notarization...\n'
  notarize_and_require_accepted "$DMG_PATH" "$DMG_NOTARY_RESULT"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

printf 'Verifying distribution artifacts...\n'
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
if [[ "$NOTARIZE" == true ]]; then
  verify_developer_id_app_signature "$APP_PATH"
  verify_developer_id_dmg_signature "$DMG_PATH"
  codesign --verify --strict --verbose=4 "$DMG_PATH"
  xcrun stapler validate "$APP_PATH"
  xcrun stapler validate "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
  spctl --assess --type execute --verbose=4 "$APP_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

publish_artifacts

printf '\nCreated app: %s\n' "$FINAL_APP_PATH"
printf 'Created DMG: %s\n' "$FINAL_DMG_PATH"
if [[ "$NOTARIZE" == true ]]; then
  printf 'Distribution artifact passed Developer ID, notarization, stapling, codesign, and Gatekeeper checks.\n'
elif [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  printf 'WARNING: LOCAL TEST ARTIFACT ONLY. The app is ad-hoc signed and the DMG is not notarized.\n' >&2
  printf 'WARNING: Do not distribute this DMG to another Mac. Use Developer ID signing with --notarize.\n' >&2
else
  printf 'WARNING: LOCAL TEST ARTIFACT ONLY. The app is signed but the DMG is not notarized.\n' >&2
  printf 'WARNING: Do not distribute this DMG to another Mac. Use Developer ID signing with --notarize.\n' >&2
fi
