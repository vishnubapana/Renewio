#!/usr/bin/env bash
# Renewio renew pipeline — Apple-native CLI only.
# Emits structured lines for the menu bar app:
#   [STAGE] name|human label
#   [INFO] message
#   [ERROR] stage|human message
#   [RESULT] ok|version|deviceName|detail
set -euo pipefail

REPO="${GITHUB_REPO:-bobsupra/NuvioTVOS}"
PLATFORM="${RENEWIO_PLATFORM:-tvos}"
SUPPORT_DIR="${RENEWIO_SUPPORT_DIR:-$HOME/Library/Application Support/Renewio}"
WORK_DIR="$SUPPORT_DIR/work"
LOG_DIR="${RENEWIO_LOG_DIR:-$HOME/Library/Logs/Renewio}"
CONFIG_PATH="${RENEWIO_CONFIG:-$SUPPORT_DIR/config.json}"

# Migrate folders from the previous ReNuvio product name when present.
migrate_renuvio_dir() {
  local legacy="$1"
  local modern="$2"
  [[ -d "$legacy" ]] || return 0
  if [[ ! -e "$modern" ]]; then
    mv "$legacy" "$modern"
    return 0
  fi
  # Merge missing children into the modern path, then drop the legacy folder.
  local child
  for child in "$legacy"/* "$legacy"/.[!.]* "$legacy"/..?*; do
    [[ -e "$child" ]] || continue
    local base
    base="$(basename "$child")"
    if [[ ! -e "$modern/$base" ]]; then
      mv "$child" "$modern/$base"
    fi
  done
  rm -rf "$legacy"
}
migrate_renuvio_dir "$HOME/Library/Application Support/ReNuvio" "$SUPPORT_DIR"
migrate_renuvio_dir "$HOME/Library/Logs/ReNuvio" "$LOG_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Prefer sibling Resources when running from the app bundle.
if [[ -d "$SCRIPT_DIR/ProvisioningStub/ProvisioningStub.xcodeproj" ]]; then
  STUB_ROOT="$SCRIPT_DIR/ProvisioningStub"
elif [[ -d "$SCRIPT_DIR/../Renewio/Resources/ProvisioningStub/ProvisioningStub.xcodeproj" ]]; then
  STUB_ROOT="$(cd "$SCRIPT_DIR/../Renewio/Resources/ProvisioningStub" && pwd)"
elif [[ -d "$SCRIPT_DIR/ProvisioningStub.xcodeproj" ]]; then
  STUB_ROOT="$SCRIPT_DIR"
else
  STUB_ROOT=""
fi

TEAM_ID="${RENEWIO_TEAM_ID:-}"
BUNDLE_ID="${RENEWIO_BUNDLE_ID:-}"
DEVICE_ID="${RENEWIO_DEVICE_ID:-}"
DEVICE_NAME="${RENEWIO_DEVICE_NAME:-}"
SELECTED_IPA="${RENEWIO_IPA:-}"
SELECTED_TAG="${RENEWIO_TAG:-}"
MAX_CACHED_IPAS="${RENEWIO_MAX_CACHED_IPAS:-3}"
DRY_RUN=0
SKIP_INSTALL=0
NO_CONFIG_WRITE=0

usage() {
  cat <<'EOF'
Usage: renewio.sh [options]

Options:
  --team-id ID          Apple Development Team ID
  --bundle-id ID        Product bundle identifier to install as
  --device-id ID        Device identifier for devicectl
  --device-name NAME    Human-readable device name
  --repo OWNER/NAME     GitHub repository for IPA releases (default: bobsupra/NuvioTVOS)
  --platform PLATFORM   tvos|ios (default: tvos)
  --ipa FILE            Use a specific cached IPA filename/path instead of fetching latest
  --tag TAG             Install a specific GitHub release tag (uses cache if already downloaded)
  --config PATH         Config JSON (default: ~/Library/Application Support/Renewio/config.json)
  --no-config-write     Do not update config.json after success (app owns v2 schema)
  --dry-run             Resolve release + check device; do not download/sign/install
  --skip-install        Download + sign only
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team-id) TEAM_ID="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --device-id) DEVICE_ID="$2"; shift 2 ;;
    --device-name) DEVICE_NAME="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --ipa) SELECTED_IPA="$2"; shift 2 ;;
    --tag) SELECTED_TAG="$2"; shift 2 ;;
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --no-config-write) NO_CONFIG_WRITE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] args|Unknown argument: $1"; exit 2 ;;
  esac
done

PLATFORM="$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')"
case "$PLATFORM" in
  tvos|tv) PLATFORM="tvos" ;;
  ios|iphone|ipad|ipados) PLATFORM="ios" ;;
  *) echo "[ERROR] args|Unknown platform: $PLATFORM (use tvos or ios)"; exit 2 ;;
esac

REPO_FOLDER="$(echo "$REPO" | tr '/ ' '__-')"
DOWNLOAD_DIR="$SUPPORT_DIR/downloads/$REPO_FOLDER"
# Migrate legacy flat downloads for the default Nuvio repo.
if [[ "$REPO" == "bobsupra/NuvioTVOS" && -d "$SUPPORT_DIR/downloads" ]]; then
  mkdir -p "$DOWNLOAD_DIR"
  shopt -s nullglob
  for f in "$SUPPORT_DIR/downloads"/*.ipa; do
    base="$(basename "$f")"
    if [[ ! -f "$DOWNLOAD_DIR/$base" ]]; then
      mv "$f" "$DOWNLOAD_DIR/$base" 2>/dev/null || cp "$f" "$DOWNLOAD_DIR/$base" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
fi

mkdir -p "$DOWNLOAD_DIR" "$WORK_DIR" "$LOG_DIR"

if [[ "$PLATFORM" == "ios" ]]; then
  STUB_SCHEME="ProvisioningStubIOS"
  STUB_PRODUCT="ProvisioningStubIOS.app"
  XCODE_DESTINATION="generic/platform=iOS"
  SDK_TOKEN="iphoneos"
  DEVICE_KIND="device"
else
  STUB_SCHEME="ProvisioningStub"
  STUB_PRODUCT="ProvisioningStub.app"
  XCODE_DESTINATION="generic/platform=tvOS"
  SDK_TOKEN="appletvos"
  DEVICE_KIND="Apple TV"
fi
LOG_FILE="$LOG_DIR/renew.log"
STATUS_FILE="$SUPPORT_DIR/last-status.txt"

# Agent/UI stdout pipes can close during long quiet stretches (xcodebuild).
# Ignore SIGPIPE so a closed stdout does not abort the install mid-flight.
trap '' PIPE

# Prefer a full PATH when launched from the menu bar app.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

# Avoid `exec > >(tee …)` — that also SIGPIPEs around long child commands.
emit() {
  local line="$*"
  printf '%s\n' "$line" >>"$LOG_FILE" || true
  # Always persist the latest structured line for the UI, even if stdout is gone.
  case "$line" in
    \[STAGE\]*|\[ERROR\]*|\[RESULT\]*)
      printf '%s\n' "$line" >"$STATUS_FILE" || true
      ;;
  esac
  # stdout + stderr so MenuBar Process pipes still see progress when open.
  printf '%s\n' "$line" || true
  printf '%s\n' "$line" >&2 || true
}

stage() {
  local id="$1"
  local label="$2"
  CURRENT_STAGE="$id"
  emit "[STAGE] ${id}|${label}"
}

info() {
  emit "[INFO] $*"
}

fail() {
  local message="$1"
  local stage_id="${CURRENT_STAGE:-unknown}"
  emit "[ERROR] ${stage_id}|${message}"
  exit 1
}

json_get() {
  # json_get <file> <python-ish key path using jq>
  local file="$1"
  local query="$2"
  if [[ ! -f "$file" ]]; then
    echo ""
    return 0
  fi
  jq -r "$query // empty" "$file" 2>/dev/null || true
}

load_config() {
  if [[ -f "$CONFIG_PATH" ]]; then
    # Use if/fi (not `[[ ]] &&`) so a false test does not make this function
    # return 1 under `set -e` and abort the whole renew run.
    if [[ -z "$TEAM_ID" ]]; then TEAM_ID="$(json_get "$CONFIG_PATH" '.teamID')"; fi
    if [[ -z "$BUNDLE_ID" ]]; then BUNDLE_ID="$(json_get "$CONFIG_PATH" '.bundleID')"; fi
    if [[ -z "$DEVICE_ID" ]]; then DEVICE_ID="$(json_get "$CONFIG_PATH" '.deviceID')"; fi
    if [[ -z "$DEVICE_NAME" ]]; then DEVICE_NAME="$(json_get "$CONFIG_PATH" '.deviceName')"; fi
  fi
  return 0
}

require_tools() {
  local missing=()
  for t in curl jq unzip xcodebuild security plutil codesign xcrun python3; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required tools: ${missing[*]}. Install Xcode command-line tools and try again."
  fi
  if ! xcodebuild -showsdks 2>/dev/null | grep -q "$SDK_TOKEN"; then
    if [[ "$PLATFORM" == "ios" ]]; then
      fail "iOS SDK not found. Open Xcode once, install the iOS platform, then retry."
    else
      fail "tvOS SDK not found. Open Xcode once, install additional components / tvOS platform, then retry."
    fi
  fi
  if [[ -z "$STUB_ROOT" || ! -d "$STUB_ROOT/ProvisioningStub.xcodeproj" ]]; then
    fail "ProvisioningStub.xcodeproj not found next to the renew script."
  fi
}

humanize_device_error() {
  local raw="$1"
  if echo "$raw" | grep -qiE 'timed out|CoreDeviceService'; then
    echo "Could not talk to Apple's device service. Make sure Xcode is installed and try again in a few seconds."
  elif echo "$raw" | grep -qiE 'not found|No devices|empty'; then
    echo "${DEVICE_KIND} not found. Pair it in Xcode → Window → Devices and Simulators, keep it awake, then update credentials in Renewio."
  elif echo "$raw" | grep -qiE 'offline|unavailable|not connected'; then
    echo "${DEVICE_KIND} is offline or asleep. Wake it, confirm it is paired in Xcode, then retry."
  else
    echo "${DEVICE_KIND} check failed: ${raw}"
  fi
}

check_device() {
  stage "device" "Checking ${DEVICE_KIND}"
  [[ -n "$DEVICE_ID" ]] || fail "No ${DEVICE_KIND} selected. Open Settings and choose a paired device."

  local json_out="$WORK_DIR/devices.json"
  local err_out="$WORK_DIR/devices.err"
  set +e
  xcrun devicectl list devices --json-output "$json_out" >"$WORK_DIR/devices.txt" 2>"$err_out"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    fail "$(humanize_device_error "$(cat "$err_out" 2>/dev/null; cat "$WORK_DIR/devices.txt" 2>/dev/null)")"
  fi

  local match
  match="$(python3 - <<PY
import json, sys
path = r'''$json_out'''
needle = r'''$DEVICE_ID'''
with open(path) as f:
    data = json.load(f)
devices = data.get("result", {}).get("devices") or data.get("devices") or []
for d in devices:
    props = d.get("deviceProperties") or {}
    hw = d.get("hardwareProperties") or {}
    conn = d.get("connectionProperties") or {}
    # Newer schema nests under properties
    nested = d.get("properties") or {}
    identifiers = [
        d.get("identifier"),
        d.get("coreDeviceID"),
        props.get("identifier"),
        hw.get("udid"),
        hw.get("ecid"),
        nested.get("hardware", {}).get("udid") if isinstance(nested.get("hardware"), dict) else None,
        nested.get("device", {}).get("name") if isinstance(nested.get("device"), dict) else None,
        props.get("name"),
        d.get("name"),
    ]
    names = [
        props.get("name"),
        d.get("name"),
        nested.get("device", {}).get("name") if isinstance(nested.get("device"), dict) else None,
    ]
    blob = " ".join(str(x) for x in identifiers + names if x)
    if needle and (needle in blob or any(str(x) == needle for x in identifiers if x)):
        name = next((n for n in names if n), needle)
        # Prefer a concrete install identifier
        udid = hw.get("udid") or props.get("identifier") or d.get("identifier") or needle
        nested_conn = nested.get("connection") if isinstance(nested.get("connection"), dict) else {}
        pairing = conn.get("pairingState") or nested_conn.get("pairingState") or ""
        tunnel = conn.get("tunnelState") or nested_conn.get("state") or nested_conn.get("tunnelState") or ""
        # Prefer pairing for readiness; idle wireless tunnels often look "disconnected".
        state = pairing or tunnel or "unknown"
        if pairing.lower() == "paired" and tunnel.lower() in ("disconnected", ""):
            state = "paired"
        print(f"{udid}\t{name}\t{state}")
        sys.exit(0)
print("")
sys.exit(1)
PY
)" || true

  if [[ -z "$match" ]]; then
    fail "${DEVICE_KIND} '${DEVICE_NAME:-$DEVICE_ID}' is not in Xcode's device list. Pair it in Xcode → Devices and Simulators, then update Settings."
  fi

  local resolved_id resolved_name resolved_state
  IFS=$'\t' read -r resolved_id resolved_name resolved_state <<<"$match"
  DEVICE_ID="$resolved_id"
  DEVICE_NAME="${DEVICE_NAME:-$resolved_name}"
  info "Found ${DEVICE_KIND} '${DEVICE_NAME}' (${DEVICE_ID}), list_state=${resolved_state}"

  # Idle wireless Apple TVs often report tunnelState=disconnected in `list devices`
  # even when paired. Probe details to wake the CoreDevice tunnel before install.
  local details_err="$WORK_DIR/device-details.err"
  local details_json="$WORK_DIR/device-details.json"
  set +e
  xcrun devicectl device info details \
    --device "$DEVICE_ID" \
    --json-output "$details_json" \
    >"$WORK_DIR/device-details.txt" 2>"$details_err"
  local details_rc=$?
  set -e

  local live_state=""
  if [[ $details_rc -eq 0 && -f "$details_json" ]]; then
    live_state="$(python3 - <<PY
import json
from pathlib import Path
data = json.loads(Path(r'''$details_json''').read_text())
device = data.get("result") or data
conn = (device.get("connectionProperties") or {})
nested = ((device.get("properties") or {}).get("connection") or {})
state = nested.get("state") or conn.get("tunnelState") or conn.get("pairingState") or "unknown"
print(state)
PY
)"
    info "Device tunnel state after probe: ${live_state}"
  else
    info "Could not probe device details yet: $(tr '\n' ' ' < "$details_err" 2>/dev/null | cut -c1-200)"
  fi

  # Only hard-fail when clearly unpaired/unavailable. "disconnected" on the list
  # is normal for a sleeping wireless tunnel and is recovered by the probe above.
  if echo "${live_state:-$resolved_state}" | grep -qiE 'unpaired|unavailable|offline'; then
    fail "${DEVICE_KIND} '${DEVICE_NAME}' is ${live_state:-$resolved_state}. Wake it, confirm it is paired in Xcode, then retry."
  fi

  if [[ $details_rc -ne 0 ]]; then
    fail "${DEVICE_KIND} '${DEVICE_NAME}' is paired but not reachable right now. Wake the device, keep it nearby/on the same network, then retry. Details: $(tr '\n' ' ' < "$details_err" 2>/dev/null | cut -c1-220)"
  fi
}

fetch_release() {
  stage "release" "Fetching latest release"
  local api="https://api.github.com/repos/${REPO}/releases?per_page=20"
  local json="$WORK_DIR/releases.json"
  local http
  set +e
  http=$(curl -sS -L -o "$json" -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: Renewio" \
    "$api")
  local rc=$?
  set -e
  if [[ $rc -ne 0 || "$http" != "200" ]]; then
    fail "Could not reach GitHub releases (HTTP ${http:-n/a}). Check your network and try again."
  fi

  python3 - <<'PY' "$json" "$WORK_DIR/asset.tsv" "$SELECTED_TAG"
import json, sys, re
path, out, wanted_tag = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    releases = json.load(f)
chosen = None
asset = None
for rel in releases:
    if wanted_tag and (rel.get("tag_name") or "") != wanted_tag:
        continue
    assets = rel.get("assets") or []
    unsigned = [a for a in assets if a.get("name", "").lower().endswith(".ipa") and "unsigned" in a.get("name", "").lower()]
    ipas = unsigned or [a for a in assets if a.get("name", "").lower().endswith(".ipa")]
    if not ipas:
        continue
    # Prefer unsigned
    ipas.sort(key=lambda a: (0 if "unsigned" in a["name"].lower() else 1, a["name"]))
    chosen, asset = rel, ipas[0]
    break
if not chosen:
    print("NO_ASSET", file=sys.stderr)
    sys.exit(1)
tag = chosen.get("tag_name") or ""
name = asset["name"]
url = asset["browser_download_url"]
size = asset.get("size") or 0
# Derive a friendly version
m = re.search(r"(\d+\.\d+\.\d+)", name) or re.search(r"(\d+\.\d+\.\d+)", tag)
version = m.group(1) if m else tag
with open(out, "w") as f:
    f.write(f"{tag}\t{version}\t{name}\t{url}\t{size}\n")
print(f"{tag} / {version} / {name}")
PY

  IFS=$'\t' read -r RELEASE_TAG RELEASE_VERSION ASSET_NAME ASSET_URL ASSET_SIZE < "$WORK_DIR/asset.tsv"
  info "Latest release: ${RELEASE_TAG} (${ASSET_NAME})"
}

use_cached_ipa() {
  stage "release" "Using cached version"
  if [[ "$SELECTED_IPA" == */* ]]; then
    IPA_PATH="$SELECTED_IPA"
  else
    IPA_PATH="$DOWNLOAD_DIR/$SELECTED_IPA"
  fi
  [[ -f "$IPA_PATH" ]] || fail "Cached IPA not found: ${SELECTED_IPA}"
  ASSET_NAME="$(basename "$IPA_PATH")"
  RELEASE_VERSION="$(python3 - <<'PY' "$ASSET_NAME"
import re, sys
name = sys.argv[1]
m = re.search(r"(\d+\.\d+\.\d+)", name)
print(m.group(1) if m else name.removesuffix(".ipa"))
PY
)"
  RELEASE_TAG="cached-${RELEASE_VERSION}"
  touch "$IPA_PATH" 2>/dev/null || true
  stage "download" "Using cached ${ASSET_NAME}"
  info "Selected cached IPA: ${ASSET_NAME} (v${RELEASE_VERSION})"
}

prune_cached_ipas() {
  python3 - <<'PY' "$DOWNLOAD_DIR" "$MAX_CACHED_IPAS" "${IPA_PATH:-}"
import pathlib, sys
download_dir = pathlib.Path(sys.argv[1])
keep = max(1, int(sys.argv[2]))
protected = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
ipas = sorted(
    [p for p in download_dir.glob("*.ipa") if p.is_file()],
    key=lambda p: p.stat().st_mtime,
    reverse=True,
)
kept = 0
for p in ipas:
    if protected and p.resolve() == protected:
        kept += 1
        continue
    if kept < keep:
        kept += 1
        continue
    try:
        p.unlink()
    except OSError:
        pass
PY
}

download_ipa() {
  stage "download" "Downloading IPA"
  IPA_PATH="$DOWNLOAD_DIR/$ASSET_NAME"
  if [[ -f "$IPA_PATH" ]]; then
    local have
    have=$(stat -f%z "$IPA_PATH" 2>/dev/null || echo 0)
    if [[ "$have" == "$ASSET_SIZE" && "$ASSET_SIZE" != "0" ]]; then
      info "Using cached ${ASSET_NAME}"
      touch "$IPA_PATH" 2>/dev/null || true
      prune_cached_ipas
      return 0
    fi
  fi
  info "Downloading ${ASSET_NAME} (${ASSET_SIZE} bytes)"
  local tmp="$IPA_PATH.partial"
  if ! curl -sS -L --fail -o "$tmp" \
      -H "User-Agent: Renewio" \
      -H "Accept: application/octet-stream" \
      "$ASSET_URL"; then
    rm -f "$tmp"
    fail "Download failed for ${ASSET_NAME}. Check your network and retry."
  fi
  mv -f "$tmp" "$IPA_PATH"
  prune_cached_ipas
}

refresh_signing() {
  stage "provision" "Refreshing signing profile"
  [[ -n "$TEAM_ID" ]] || fail "No Team ID configured. Open Setup / Update Credentials and set your Xcode Team ID."
  [[ -n "$BUNDLE_ID" ]] || fail "No Bundle ID configured. Open Setup / Update Credentials."

  # Ensure a development identity exists or will be created by xcodebuild.
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|iPhone Developer|Apple Distribution' || true)"
  if [[ -z "$identities" ]]; then
    info "No development certificate in Keychain yet — xcodebuild will try to create one via your Xcode Apple ID."
  fi

  local derived="$WORK_DIR/DerivedData"
  rm -rf "$derived"
  mkdir -p "$derived"

  local build_log="$WORK_DIR/xcodebuild.log"
  set +e
  /usr/bin/xcodebuild \
    -project "$STUB_ROOT/ProvisioningStub.xcodeproj" \
    -scheme "$STUB_SCHEME" \
    -configuration Debug \
    -destination "$XCODE_DESTINATION" \
    -derivedDataPath "$derived" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build >"$build_log" 2>&1
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    local hint
    if grep -qiE 'No Account|not signed in|Session expired|Authentication|401|403' "$build_log"; then
      hint="Xcode is not signed in (or the session expired). Open Xcode → Settings → Accounts, sign in with your Apple ID, then update Settings."
    elif grep -qiE 'Too many|maximum number|3 apps|App ID limit|10 App' "$build_log"; then
      hint="Apple Personal Team limit reached (max 3 apps / 10 App IDs). Remove an unused App ID in Xcode → Settings → Accounts → Manage Certificates / Devices, or pick a different Bundle ID."
    elif grep -qiE 'device|UDID|register' "$build_log"; then
      hint="Could not register the ${DEVICE_KIND} with your team. Pair it in Xcode Devices and Simulators, keep it awake, then retry."
    elif grep -qiE 'team|DEVELOPMENT_TEAM|not found' "$build_log"; then
      hint="Team ID '${TEAM_ID}' was rejected. Confirm it in Xcode → Settings → Accounts (Personal Team), then update Settings."
    else
      hint="Signing refresh failed. See the log for details. Common fix: open Xcode, sign in, pair your ${DEVICE_KIND}, then retry."
    fi
    tail -n 40 "$build_log" | sed 's/^/[INFO] xcodebuild: /' || true
    fail "$hint"
  fi

  STUB_APP="$(find "$derived" -type d -name "$STUB_PRODUCT" -print -quit 2>/dev/null || true)"
  [[ -n "$STUB_APP" && -d "$STUB_APP" ]] || fail "Stub app was not produced by xcodebuild. Check Xcode signing setup."

  STUB_PROVISION="$STUB_APP/embedded.mobileprovision"
  [[ -f "$STUB_PROVISION" ]] || fail "No embedded.mobileprovision in stub app. Ensure automatic signing works for Team ${TEAM_ID}."

  # Extract signing identity from codesign of the stub.
  SIGN_IDENTITY="$(codesign -dv --verbose=4 "$STUB_APP" 2>&1 | awk -F'= ' '/Authority=Apple Development|Authority=iPhone Developer/{print $2; exit}')"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|iPhone Developer/{print $2; exit}')"
  fi
  [[ -n "$SIGN_IDENTITY" ]] || fail "Could not find an Apple Development signing identity after the stub build."

  # Entitlements from the stub (already matched to the profile).
  ENTITLEMENTS_PATH="$WORK_DIR/entitlements.plist"
  rm -f "$ENTITLEMENTS_PATH"
  # Leading colon tells codesign to write the extracted entitlements to this path.
  codesign -d --entitlements ":$ENTITLEMENTS_PATH" "$STUB_APP" 2>/dev/null || true
  if [[ ! -s "$ENTITLEMENTS_PATH" ]]; then
    # Fallback: build a minimal entitlement set from the provision.
    security cms -D -i "$STUB_PROVISION" > "$WORK_DIR/profile.plist" 2>/dev/null \
      || fail "Could not decode the provisioning profile."
    python3 - <<PY
import plistlib, pathlib
prof = plistlib.loads(pathlib.Path(r'''$WORK_DIR/profile.plist''').read_bytes())
ents = prof.get("Entitlements") or {}
# Keep only safe keys for a free Personal Team install.
keep = {}
for k in ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"):
    if k in ents:
        keep[k] = ents[k]
pathlib.Path(r'''$ENTITLEMENTS_PATH''').write_bytes(plistlib.dumps(keep))
PY
  fi

  info "Using identity: ${SIGN_IDENTITY}"
  info "Provisioning profile ready for ${BUNDLE_ID}"
}

resign_app() {
  stage "sign" "Signing app"
  local extract="$WORK_DIR/PayloadExtract"
  rm -rf "$extract"
  mkdir -p "$extract"
  unzip -q -o "$IPA_PATH" -d "$extract"
  APP_PATH="$(find "$extract/Payload" -maxdepth 1 -name '*.app' -type d | head -1 || true)"
  [[ -n "$APP_PATH" ]] || fail "IPA did not contain a Payload/*.app bundle."

  # Drop Top Shelf extension — free Personal Team profiles are for the main app only.
  if [[ -d "$APP_PATH/PlugIns" ]]; then
    info "Removing PlugIns (Top Shelf) so a single app provisioning profile can be used."
    rm -rf "$APP_PATH/PlugIns"
  fi

  # Patch Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_PATH/Info.plist" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$APP_PATH/Info.plist"
  if /usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers" "$APP_PATH/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Delete :BGTaskSchedulerPermittedIdentifiers" "$APP_PATH/Info.plist" || true
  fi

  # Clear old signature + provision
  rm -rf "$APP_PATH/_CodeSignature"
  rm -f "$APP_PATH/embedded.mobileprovision"
  cp "$STUB_PROVISION" "$APP_PATH/embedded.mobileprovision"

  # Sign nested Mach-O frameworks inside-out.
  while IFS= read -r -d '' fw; do
    rm -rf "$fw/_CodeSignature"
    if ! codesign -f -s "$SIGN_IDENTITY" --timestamp=none "$fw" 2>"$WORK_DIR/codesign.err"; then
      fail "Failed to sign framework $(basename "$fw"): $(tr '\n' ' ' < "$WORK_DIR/codesign.err")"
    fi
  done < <(find "$APP_PATH/Frameworks" -maxdepth 1 -name '*.framework' -print0 2>/dev/null || true)

  while IFS= read -r -d '' dylib; do
    if ! codesign -f -s "$SIGN_IDENTITY" --timestamp=none "$dylib" 2>"$WORK_DIR/codesign.err"; then
      fail "Failed to sign $(basename "$dylib"): $(tr '\n' ' ' < "$WORK_DIR/codesign.err")"
    fi
  done < <(find "$APP_PATH" -name '*.dylib' -print0 2>/dev/null || true)

  # Sign the app with stub entitlements.
  if ! codesign -f -s "$SIGN_IDENTITY" \
      --entitlements "$ENTITLEMENTS_PATH" \
      --timestamp=none \
      --generate-entitlement-der \
      "$APP_PATH" 2>"$WORK_DIR/codesign.err"; then
    fail "Failed to sign NuvioTV.app: $(tr '\n' ' ' < "$WORK_DIR/codesign.err")"
  fi

  if ! codesign --verify --deep --strict "$APP_PATH" 2>"$WORK_DIR/codesign.err"; then
    fail "Signature verification failed: $(tr '\n' ' ' < "$WORK_DIR/codesign.err")"
  fi

  info "Signed ${APP_PATH}"
}

install_app() {
  stage "install" "Installing on Apple TV"
  local json_out="$WORK_DIR/install.json"
  local err_out="$WORK_DIR/install.err"
  set +e
  xcrun devicectl device install app \
    --device "$DEVICE_ID" \
    --json-output "$json_out" \
    "$APP_PATH" >"$WORK_DIR/install.txt" 2>"$err_out"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    local combined
    combined="$(cat "$err_out" 2>/dev/null; cat "$WORK_DIR/install.txt" 2>/dev/null; cat "$json_out" 2>/dev/null)"
    if echo "$combined" | grep -qiE 'offline|not connected|unavailable|sleep|timeout|Connection'; then
      fail "Install failed because the Apple TV became unreachable. Wake '${DEVICE_NAME}', keep it on the network, then retry."
    elif echo "$combined" | grep -qiE 'provision|sign|validat|profile|entitlement'; then
      fail "Install rejected due to signing/profile mismatch. Update Credentials, ensure the Apple TV is registered to your team, then retry."
    elif echo "$combined" | grep -qiE 'disk|space|full'; then
      fail "Apple TV is out of storage. Free some space, then retry."
    else
      fail "Install failed: $(echo "$combined" | tr '\n' ' ' | cut -c1-300)"
    fi
  fi
  info "Install completed"
}

write_success_state() {
  if [[ "$NO_CONFIG_WRITE" == "1" ]]; then
    info "Skipping config.json write (--no-config-write); app owns install tracking."
    return 0
  fi
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$SUPPORT_DIR"
  # Legacy flat update only — used by CLI runs without the menu bar app.
  python3 - <<PY
import json, pathlib
path = pathlib.Path(r'''$CONFIG_PATH''')
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        data = {}
# Never clobber a v2 multi-app config from the shell helper.
if int(data.get("schemaVersion") or 0) >= 2 or data.get("installs"):
    print("skip-v2-config")
else:
    data.update({
        "teamID": r'''$TEAM_ID''',
        "bundleID": r'''$BUNDLE_ID''',
        "deviceID": r'''$DEVICE_ID''',
        "deviceName": r'''$DEVICE_NAME''',
        "lastInstalledVersion": r'''$RELEASE_VERSION''',
        "lastInstalledTag": r'''$RELEASE_TAG''',
        "lastInstalledAt": r'''$now''',
        "lastAssetName": r'''$ASSET_NAME''',
    })
    path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

main() {
  CURRENT_STAGE="init"
  require_tools
  load_config

  [[ -n "$TEAM_ID" ]] || fail "Team ID missing. Complete onboarding first."
  [[ -n "$BUNDLE_ID" ]] || fail "Bundle ID missing. Complete onboarding first."
  [[ -n "$DEVICE_ID" ]] || fail "Apple TV not selected. Complete onboarding first."

  check_device

  if [[ -n "$SELECTED_IPA" ]]; then
    use_cached_ipa
    if [[ "$DRY_RUN" == "1" ]]; then
      emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|dry-run ready (${ASSET_NAME})"
      exit 0
    fi
  else
    fetch_release

    if [[ "$DRY_RUN" == "1" ]]; then
      emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|dry-run ready (${ASSET_NAME})"
      exit 0
    fi

    download_ipa
  fi

  refresh_signing
  resign_app

  if [[ "$SKIP_INSTALL" == "1" ]]; then
    emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|signed only (install skipped)"
    exit 0
  fi

  install_app
  write_success_state
  emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|Nuvio TV ${RELEASE_VERSION} installed. Free profiles expire in about 7 days — click Renew again before then."
}

main "$@"
