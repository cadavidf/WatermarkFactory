#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WatermarkFactory"
SCHEME="WatermarkFactory"
DIST_DIR="dist"
DERIVED_DATA="build/DerivedData"
ARCHIVE_PATH="build/$APP_NAME.xcarchive"
EXPORT_PATH="build/export"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/watermarkfactory.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

rm -rf "$DIST_DIR" "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$DIST_DIR"

# `xcodebuild build` (the old path here) targets a specific connected Mac
# destination, which pulls in dev-signing behavior — notably the
# get-task-allow debugging entitlement, which notarization rejects outright.
# `archive` + `-exportArchive` with method=developer-id is Apple's actual
# supported path for Developer ID distribution: no get-task-allow, a real
# secure timestamp, and every embedded binary (Sparkle's helper apps/XPC
# services included) gets properly re-signed with our identity as part of
# the export, not left with whatever signature it shipped with upstream.
echo "==> Archiving..."
xcodebuild -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" archive

echo "==> Exporting (Developer ID)..."
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist exportOptions.plist

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST_DIR/$APP_NAME.dmg"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "==> Notarizing..."
  xcrun notarytool submit "$DIST_DIR/$APP_NAME.dmg" --keychain-profile "automality-notary" --wait
  echo "==> Stapling notarization ticket..."
  xcrun stapler staple "$DIST_DIR/$APP_NAME.dmg"
else
  echo "==> Skipping notarization (no Developer ID cert found) — Gatekeeper will warn on download"
fi

echo "$DIST_DIR/$APP_NAME.dmg"
