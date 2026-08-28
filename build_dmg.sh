#!/usr/bin/env bash
set -euo pipefail

APP_NAME="WatermarkFactory"
SCHEME="WatermarkFactory"
CONFIG="Release"
DIST_DIR="dist"
DERIVED_DATA="build/DerivedData"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/watermarkfactory.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" build

APP_PATH="$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" -showBuildSettings | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = /{dir=$2} END{print dir}')/$APP_NAME.app"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST_DIR/$APP_NAME.dmg"
echo "$DIST_DIR/$APP_NAME.dmg"
