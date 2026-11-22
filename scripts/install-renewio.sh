#!/usr/bin/env bash
# Build Renewio.app, install to /Applications, and optionally make a shareable DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Renewio"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Renewio/Resources/Info.plist" 2>/dev/null || echo "1.0.0")"
DIST_APP="$ROOT/dist/${APP_NAME}.app"
INSTALL_APP="/Applications/${APP_NAME}.app"
DMG_PATH="$ROOT/dist/${APP_NAME}-${VERSION}.dmg"
MAKE_DMG=1
DO_INSTALL=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --no-dmg       Skip creating dist/${APP_NAME}-${VERSION}.dmg
  --no-install   Build/package only; do not copy to /Applications
  -h, --help     Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-dmg) MAKE_DMG=0; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

echo "==> Building ${APP_NAME}.app"
"$ROOT/scripts/build-renewio.sh"

[[ -d "$DIST_APP" ]] || { echo "Missing $DIST_APP"; exit 1; }

# Fresh ad-hoc sign so Gatekeeper is happier for local installs.
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$DIST_APP"
xattr -cr "$DIST_APP" 2>/dev/null || true

if [[ "$DO_INSTALL" == "1" ]]; then
  echo "==> Installing to ${INSTALL_APP}"
  pkill -x "$APP_NAME" 2>/dev/null || true
  pkill -x ReNuvio 2>/dev/null || true
  sleep 0.3
  if [[ -d "$INSTALL_APP" ]]; then
    rm -rf "$INSTALL_APP"
  fi
  # Remove the previous product name if still present.
  if [[ -d "/Applications/ReNuvio.app" ]]; then
    rm -rf "/Applications/ReNuvio.app"
    echo "Removed old /Applications/ReNuvio.app"
  fi
  cp -R "$DIST_APP" "$INSTALL_APP"
  codesign --force --deep --sign - "$INSTALL_APP"
  xattr -cr "$INSTALL_APP" 2>/dev/null || true
  echo "Installed: $INSTALL_APP"
fi

if [[ "$MAKE_DMG" == "1" ]]; then
  echo "==> Creating DMG"
  STAGE="$(mktemp -d)/dmg"
  mkdir -p "$STAGE"
  cp -R "$DIST_APP" "$STAGE/${APP_NAME}.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
  echo "DMG: $DMG_PATH"
fi

echo
echo "Done."
if [[ "$DO_INSTALL" == "1" ]]; then
  echo "Open from Applications, or:"
  echo "  open -a ${APP_NAME}"
fi
if [[ "$MAKE_DMG" == "1" ]]; then
  echo "Shareable installer image:"
  echo "  open \"$DMG_PATH\""
fi
