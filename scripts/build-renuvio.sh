#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Keep Resources script in sync with scripts/
cp "$ROOT/scripts/renew-nuvio.sh" "$ROOT/ReNuvio/Resources/renew-nuvio.sh"
chmod +x "$ROOT/scripts/renew-nuvio.sh" "$ROOT/ReNuvio/Resources/renew-nuvio.sh"

DERIVED="${RENUVIO_DERIVED:-$ROOT/build}"
mkdir -p "$DERIVED"
xcodebuild \
  -project "$ROOT/ReNuvio/ReNuvio.xcodeproj" \
  -scheme ReNuvio \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$(find "$DERIVED/Build/Products" -name 'ReNuvio.app' -type d | head -1)"
echo "Built: $APP"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/ReNuvio.app"
cp -R "$APP" "$ROOT/dist/ReNuvio.app"
chmod +x "$ROOT/dist/ReNuvio.app/Contents/Resources/renew-nuvio.sh"
echo "Copied to $ROOT/dist/ReNuvio.app"
