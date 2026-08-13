#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGE_SCRIPT="$ROOT_DIR/Scripts/package-macos.sh"
SPARKLE_ROOT="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
APPCAST_PATH="$ROOT_DIR/appcast.xml"
PRODUCTS_DIR="$ROOT_DIR/Products"
RELEASE_NOTES_PATH="${1:-}"
DEVELOPER_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: BYOUNG KI HAN (T7B4EPLHPK)}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_PROFILE:-ccmb-notary}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-CCMB}"

APP_VERSION="$(sed -n 's/^APP_VERSION="\([^"]*\)"/\1/p' "$PACKAGE_SCRIPT")"
APP_BUILD="$(sed -n 's/^APP_BUILD="\([^"]*\)"/\1/p' "$PACKAGE_SCRIPT")"
TAG="v$APP_VERSION"
DMG_PATH="$PRODUCTS_DIR/CCMB.dmg"
VERSIONED_DMG_PATH="$PRODUCTS_DIR/CCMB-$APP_VERSION.dmg"
WORK_DIR=""

cleanup() {
  local status=$?
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ -z "$APP_VERSION" || -z "$APP_BUILD" ]]; then
  printf 'error: unable to read app version/build from %s\n' "$PACKAGE_SCRIPT" >&2
  exit 65
fi
if [[ -n "$RELEASE_NOTES_PATH" && ! -f "$RELEASE_NOTES_PATH" ]]; then
  printf 'error: release notes file does not exist: %s\n' "$RELEASE_NOTES_PATH" >&2
  exit 66
fi
if [[ "$(git -C "$ROOT_DIR" branch --show-current)" != "main" ]]; then
  printf 'error: releases must be published from main.\n' >&2
  exit 65
fi
if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
  printf 'error: tracked changes must be committed before publishing a release.\n' >&2
  exit 65
fi
if ! command -v gh >/dev/null; then
  printf 'error: GitHub CLI is required.\n' >&2
  exit 69
fi
gh auth status >/dev/null
if gh release view "$TAG" --repo armsone/CCMB >/dev/null 2>&1; then
  printf 'error: GitHub release already exists: %s\n' "$TAG" >&2
  exit 65
fi

CODESIGN_IDENTITY="$DEVELOPER_IDENTITY" \
NOTARY_PROFILE="$NOTARY_KEYCHAIN_PROFILE" \
  "$PACKAGE_SCRIPT" --notarize

xcrun stapler validate "$ROOT_DIR/Products/Release/CCMB.app"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$ROOT_DIR/Products/Release/CCMB.app"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

WORK_DIR="$(mktemp -d "$PRODUCTS_DIR/.release.XXXXXX")"
cp "$DMG_PATH" "$WORK_DIR/CCMB-$APP_VERSION.dmg"
if [[ -f "$APPCAST_PATH" ]]; then
  cp "$APPCAST_PATH" "$WORK_DIR/appcast.xml"
fi
if [[ -n "$RELEASE_NOTES_PATH" ]]; then
  cp "$RELEASE_NOTES_PATH" "$WORK_DIR/CCMB-$APP_VERSION.md"
else
  printf '# CCMB %s\n\n자동 업데이트와 안정성 개선을 포함합니다.\n' "$APP_VERSION" \
    > "$WORK_DIR/CCMB-$APP_VERSION.md"
fi

"$GENERATE_APPCAST" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "https://github.com/armsone/CCMB/releases/download/$TAG/" \
  --link "https://github.com/armsone/CCMB/releases/tag/$TAG" \
  --maximum-deltas 0 \
  --maximum-versions 3 \
  --embed-release-notes \
  -o appcast.xml \
  "$WORK_DIR"

cp "$WORK_DIR/CCMB-$APP_VERSION.dmg" "$VERSIONED_DMG_PATH"
cp "$WORK_DIR/appcast.xml" "$APPCAST_PATH"

gh release create "$TAG" "$VERSIONED_DMG_PATH" \
  --repo armsone/CCMB \
  --title "CCMB $APP_VERSION" \
  --notes-file "$WORK_DIR/CCMB-$APP_VERSION.md"

git -C "$ROOT_DIR" add appcast.xml
git -C "$ROOT_DIR" commit -m "Publish CCMB $APP_VERSION appcast"
git -C "$ROOT_DIR" push origin main

printf 'Published CCMB %s (%s): %s\n' "$APP_VERSION" "$APP_BUILD" \
  "https://github.com/armsone/CCMB/releases/tag/$TAG"
