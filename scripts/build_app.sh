#!/usr/bin/env bash
#
# Assemble (and sign) the "Fermix Messages.app" bundle around the fermix-messages binary.
#
# The bundle gives the helper a stable, path-independent TCC identity
# (CFBundleIdentifier = io.tezra.fermix.messages) plus the "Fermix Messages" name + icon
# shown in System Settings > Privacy & Security (Full Disk Access, Automation).
#
# Usage: build_app.sh <fermix-messages-binary> <out-dir> <version> [signing-identity]
#   The bundle is written to "<out-dir>/Fermix Messages.app".
#   signing-identity omitted / empty  -> ad-hoc sign (local smoke only; TCC works but the
#                                        grant and the keychain policy item do not persist
#                                        across a rebuild, and the policy item prompts)
#   signing-identity set              -> Developer-ID sign + hardened runtime + the
#                                        apple-events entitlement (release and dev_local)
set -euo pipefail

BIN="${1:?usage: build_app.sh <binary> <out-dir> <version> [identity]}"
OUT_DIR="${2:?usage: build_app.sh <binary> <out-dir> <version> [identity]}"
VERSION="${3:?usage: build_app.sh <binary> <out-dir> <version> [identity]}"
IDENTITY="${4:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$OUT_DIR/Fermix Messages.app"

[ -f "$BIN" ] || { echo "build_app.sh: binary not found: $BIN" >&2; exit 1; }
for f in Info.plist Fermix.icns fermix-messages.entitlements; do
  [ -f "$REPO_ROOT/bundle/$f" ] || { echo "build_app.sh: missing bundle/$f" >&2; exit 1; }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/fermix-messages"
chmod 0755 "$APP/Contents/MacOS/fermix-messages"
cp "$REPO_ROOT/bundle/Fermix.icns" "$APP/Contents/Resources/Fermix.icns"
sed "s/__VERSION__/${VERSION}/g" "$REPO_ROOT/bundle/Info.plist" > "$APP/Contents/Info.plist"

# One spelling of the identity and its options. Developer-ID (release) adds a secure
# timestamp; ad-hoc cannot timestamp. The apple-events entitlement rides on the
# executable under the hardened runtime either way. The signature covers
# Contents/_CodeSignature/CodeResources, which must be preserved on extraction
# (ditto, never plain tar).
ENT="$REPO_ROOT/bundle/fermix-messages.entitlements"
if [ -n "$IDENTITY" ]; then
  SIGN=(codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$IDENTITY")
else
  SIGN=(codesign --force --options runtime --entitlements "$ENT" --sign -)
fi
"${SIGN[@]}" "$APP/Contents/MacOS/fermix-messages"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP/Contents/MacOS/fermix-messages" 2>/dev/null | grep -q "apple-events" \
  || { echo "build_app.sh: apple-events entitlement missing after signing" >&2; exit 1; }

echo "built: $APP"
