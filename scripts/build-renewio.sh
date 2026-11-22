#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Keep Resources script in sync with scripts/
cp "$ROOT/scripts/renewio.sh" "$ROOT/Renewio/Resources/renewio.sh"
chmod +x "$ROOT/scripts/renewio.sh" "$ROOT/Renewio/Resources/renewio.sh"

DERIVED="${RENEWIO_DERIVED:-$ROOT/build}"
mkdir -p "$DERIVED"
xcodebuild \
  -project "$ROOT/Renewio/Renewio.xcodeproj" \
  -scheme Renewio \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$(find "$DERIVED/Build/Products" -name 'Renewio.app' -type d | head -1)"
echo "Built: $APP"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/Renewio.app"
cp -R "$APP" "$ROOT/dist/Renewio.app"
chmod +x "$ROOT/dist/Renewio.app/Contents/Resources/renewio.sh"
echo "Copied to $ROOT/dist/Renewio.app"
