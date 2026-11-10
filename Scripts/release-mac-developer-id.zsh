#!/bin/zsh
# Builds Holdfast for Mac in Release, signs it with Developer ID, notarizes it
# and staples the ticket. Output: build/mac-release/Holdfast-<version>-<build>.zip
#
# Xcode's automatic signing cannot produce this build: Release uses the
# content-filter-provider-systemextension entitlement, which only Developer ID
# profiles carry. So the app is built unsigned and signed here, inside out.
#
# Needs, on this Mac:
#   - a "Developer ID Application" identity in the keychain
#   - Developer ID profiles for the app and the web filter (HOLDFAST_PROFILE_DIR)
#   - an App Store Connect API key for notarization (ASC_KEY_PATH, ASC_KEY_ID,
#     ASC_ISSUER_ID). Pass --skip-notarize to stop after signing.
set -euo pipefail

ROOT="${0:A:h:h}"
TEAM="7GXNZJMGPD"
APP_ID="com.GabrielPrice.ExecutiveDysfunction"
FILTER_ID="$APP_ID.WebFilter"
IDENTITY="${HOLDFAST_SIGN_IDENTITY:-Developer ID Application: Gabriel Price ($TEAM)}"
PROFILE_DIR="${HOLDFAST_PROFILE_DIR:-$HOME/.appstoreconnect/developer-id/profiles}"
APP_PROFILE="$PROFILE_DIR/Holdfast_Mac_Developer_ID.provisionprofile"
FILTER_PROFILE="$PROFILE_DIR/Holdfast_Mac_WebFilter_Developer_ID.provisionprofile"
DERIVED="${HOLDFAST_DERIVED_DATA:-$ROOT/build/mac-release/DerivedData}"
OUT="$ROOT/build/mac-release"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

for f in "$APP_PROFILE" "$FILTER_PROFILE"; do
  [[ -f "$f" ]] || { print -u2 "Missing provisioning profile: $f"; exit 1; }
done
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" \
  || { print -u2 "No signing identity named: $IDENTITY"; exit 1; }

print "==> Building the shared interface"
(cd "$ROOT/SharedUI" && npm run build)

print "==> Building Holdfast (Release, unsigned)"
xcodebuild -project "$ROOT/Holdfast.xcodeproj" -scheme HoldfastMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO build

APP="$DERIVED/Build/Products/Release/Holdfast.app"
FILTER="$APP/Contents/Library/SystemExtensions/$FILTER_ID.systemextension"
[[ -d "$APP" && -d "$FILTER" ]] || { print -u2 "Build products not found under $DERIVED"; exit 1; }

# Resolve the build-setting placeholders Xcode would have expanded, and add the
# two identifiers Xcode injects automatically.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
resolve_entitlements() {  # source, bundle id, destination
  sed -e "s/\$(AppIdentifierPrefix)/$TEAM./g" -e "s/\$(TeamIdentifierPrefix)/$TEAM./g" \
      -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$2/g" "$1" > "$3"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$2" \
      -c "Add :com.apple.developer.team-identifier string $TEAM" "$3"
  if grep -q '\$(' "$3"; then print -u2 "Unresolved placeholder in $1"; exit 1; fi
}
resolve_entitlements "$ROOT/Config/Mac.entitlements" "$APP_ID" "$WORK/app.entitlements"
resolve_entitlements "$ROOT/Config/MacWebFilterExtension.entitlements" "$FILTER_ID" "$WORK/filter.entitlements"

cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
cp "$FILTER_PROFILE" "$FILTER/Contents/embedded.provisionprofile"

SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
print "==> Signing with $IDENTITY"
# Inside out: nested code first, the app last.
find "$APP/Contents" -type f \( -name '*.dylib' -o -perm -111 \) \
  -not -path "$FILTER/*" -not -path "$APP/Contents/MacOS/Holdfast" | while read -r item; do
  file -b "$item" | grep -q 'Mach-O' && "${SIGN[@]}" "$item"
done
"${SIGN[@]}" --entitlements "$WORK/filter.entitlements" "$FILTER"
"${SIGN[@]}" --entitlements "$WORK/app.entitlements" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
ZIP="$OUT/Holdfast-$VERSION-$BUILD.zip"
mkdir -p "$OUT"; rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if (( SKIP_NOTARIZE )); then
  print "Signed, not notarized: $ZIP"; exit 0
fi

: "${ASC_KEY_PATH:?Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID to notarize}"
print "==> Notarizing"
xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP" || true

print "\nHoldfast $VERSION ($BUILD) is signed, notarized and stapled: $ZIP"
