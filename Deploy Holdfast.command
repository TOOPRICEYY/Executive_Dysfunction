#!/bin/zsh
# Double-click this file in Finder, or run it from Terminal, to build and
# install Holdfast locally. It intentionally does not launch Holdfast or alter
# Network Extension enforcement state after installation.

set -euo pipefail

PROJECT_ROOT="${0:A:h}"
PROJECT_FILE="$PROJECT_ROOT/Holdfast.xcodeproj"
DERIVED_DATA_PATH="${HOLDFAST_DERIVED_DATA:-$PROJECT_ROOT/.build/Holdfast}"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Debug/Holdfast.app"
INSTALLED_APP="/Applications/Holdfast.app"

print "\n==> Preparing Holdfast"
cd "$PROJECT_ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  print -u2 "xcodegen is required but was not found. Install it, then run this command again."
  exit 1
fi

xcodegen generate

print "\n==> Building signed Debug app"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme HoldfastMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  print -u2 "Build completed but the app bundle was not found at: $BUILT_APP"
  exit 1
fi

# Refuse an invalid build before touching the user's installed copy.
codesign --verify --deep --strict "$BUILT_APP"

print "\n==> Installing into /Applications"
if [[ -w /Applications || -w "$INSTALLED_APP" ]]; then
  ditto "$BUILT_APP" "$INSTALLED_APP"
else
  print "Administrator permission is needed to write to /Applications."
  sudo ditto "$BUILT_APP" "$INSTALLED_APP"
fi

print "\n==> Verifying installed app"
codesign --verify --deep --strict "$INSTALLED_APP"
BUILD_NUMBER=$(defaults read "$INSTALLED_APP/Contents/Info" CFBundleVersion)

print "\nHoldfast build $BUILD_NUMBER is installed at: $INSTALLED_APP"
print "Holdfast was not launched and web enforcement was not changed."
