#!/usr/bin/env bash
# Renewio renew pipeline — Apple-native CLI only.
# Emits structured lines for the menu bar app:
#   [STAGE] name|human label
#   [PROGRESS] stage|percent|downloadedBytes|totalBytes
#   [INFO] message
#   [ERROR] stage|human message
#   [RESULT] ok|version|deviceName|detail|expiresAtISO
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
APP_NAME="${RENEWIO_APP_NAME:-}"
SELECTED_IPA="${RENEWIO_IPA:-}"
SELECTED_TAG="${RENEWIO_TAG:-}"
MAX_CACHED_IPAS="${RENEWIO_MAX_CACHED_IPAS:-3}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
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
  --app-name NAME       Human-readable app name for logs/results
  --repo OWNER/NAME     GitHub repository for IPA releases (default: bobsupra/NuvioTVOS)
  --platform PLATFORM   tvos|ios (default: tvos)
  --ipa FILE            Use a specific local/cached IPA filename/path instead of fetching latest
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
    --app-name) APP_NAME="$2"; shift 2 ;;
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

REPO_FOLDER="$(echo "${REPO:-local}" | tr '/ ' '__-')"
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
PROFILE_EXPIRES_AT=""

# Rotate renew.log if it grows past 2 MB.
rotate_log_if_needed() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size="$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
  if [[ "$size" -gt 2097152 ]]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}
rotate_log_if_needed

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

# Drop bulky extract/build dirs; keep small JSON/logs for debugging.
cleanup_work_scratch() {
  local d
  for d in PayloadExtract DerivedData DerivedData2; do
    rm -rf "${WORK_DIR:?}/$d"
  done
}

fail() {
  local message="$1"
  local stage_id="${CURRENT_STAGE:-unknown}"
  cleanup_work_scratch
  emit "[ERROR] ${stage_id}|${message}"
  exit 1
}

json_get() {
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
    echo "${DEVICE_KIND} not found. Pair it in Xcode → Window → Devices and Simulators, keep it awake, then update Settings in Renewio."
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
  match="$(python3 - "$json_out" "$DEVICE_ID" <<'PY'
import json, sys
path, needle = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
devices = data.get("result", {}).get("devices") or data.get("devices") or []
for d in devices:
    props = d.get("deviceProperties") or {}
    hw = d.get("hardwareProperties") or {}
    conn = d.get("connectionProperties") or {}
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
        udid = hw.get("udid") or props.get("identifier") or d.get("identifier") or needle
        nested_conn = nested.get("connection") if isinstance(nested.get("connection"), dict) else {}
        pairing = conn.get("pairingState") or nested_conn.get("pairingState") or ""
        tunnel = conn.get("tunnelState") or nested_conn.get("state") or nested_conn.get("tunnelState") or ""
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
    live_state="$(python3 - "$details_json" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
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

  if echo "${live_state:-$resolved_state}" | grep -qiE 'unpaired|unavailable|offline'; then
    fail "${DEVICE_KIND} '${DEVICE_NAME}' is ${live_state:-$resolved_state}. Wake it, confirm it is paired in Xcode, then retry."
  fi

  if [[ $details_rc -ne 0 ]]; then
    fail "${DEVICE_KIND} '${DEVICE_NAME}' is paired but not reachable right now. Wake the device, keep it nearby/on the same network, then retry. Details: $(tr '\n' ' ' < "$details_err" 2>/dev/null | cut -c1-220)"
  fi
}

fetch_release() {
  stage "release" "Fetching latest release"
  local api="https://api.github.com/repos/${REPO}/releases?per_page=30"
  local json="$WORK_DIR/releases.json"
  local http
  local curl_headers=(-H "Accept: application/vnd.github+json" -H "User-Agent: Renewio")
  if [[ -n "$GITHUB_TOKEN" ]]; then
    curl_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  set +e
  http=$(curl -sS -L -o "$json" -w "%{http_code}" "${curl_headers[@]}" "$api")
  local rc=$?
  set -e
  if [[ $rc -ne 0 || "$http" != "200" ]]; then
    if [[ "$http" == "403" || "$http" == "429" ]]; then
      fail "GitHub API rate limit reached (HTTP ${http}). Add a GitHub token in Settings or try again later."
    elif [[ "$http" == "404" ]]; then
      fail "GitHub repository '${REPO}' not found (HTTP 404). If it is private, add a GitHub token in Settings."
    else
      fail "Could not reach GitHub releases (HTTP ${http:-n/a}). Check your network and try again."
    fi
  fi

  set +e
  python3 - "$json" "$WORK_DIR/asset.tsv" "$SELECTED_TAG" <<'PY' 2>"$WORK_DIR/release_err.txt"
import json, sys, re
from datetime import datetime, timezone, timedelta

path, out, wanted_tag = sys.argv[1], sys.argv[2], sys.argv[3]
MIN_AGE_DAYS = 14

def parse_github_date(raw):
    if not raw:
        return None
    text = str(raw).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None

def age_days(rel, now):
    dt = parse_github_date(rel.get("published_at") or rel.get("created_at"))
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (now - dt).total_seconds() / 86400.0

def is_old_enough(rel, now):
    days = age_days(rel, now)
    if days is None:
        return False
    return days >= MIN_AGE_DAYS

def pick_ipa(rel):
    assets = rel.get("assets") or []
    unsigned = [
        a for a in assets
        if a.get("name", "").lower().endswith(".ipa") and "unsigned" in a.get("name", "").lower()
    ]
    ipas = unsigned or [a for a in assets if a.get("name", "").lower().endswith(".ipa")]
    if not ipas:
        return None
    ipas.sort(key=lambda a: (0 if "unsigned" in a["name"].lower() else 1, a["name"]))
    return ipas[0]

with open(path) as f:
    releases = json.load(f)

now = datetime.now(timezone.utc)
chosen = None
asset = None

if wanted_tag:
    # Explicit pin: allow newer-than-14-day releases (user opted in).
    for rel in releases:
        if (rel.get("tag_name") or "") != wanted_tag:
            continue
        ipa = pick_ipa(rel)
        if not ipa:
            continue
        chosen, asset = rel, ipa
        break
else:
    # Auto / latest: only IPA releases that meet the 14-day age floor.
    for rel in releases:
        ipa = pick_ipa(rel)
        if not ipa:
            continue
        if not is_old_enough(rel, now):
            continue
        chosen, asset = rel, ipa
        break

if not chosen:
    if wanted_tag:
        print(
            f"No .ipa asset found for GitHub release tag '{wanted_tag}'.",
            file=sys.stderr,
        )
    else:
        print(
            f"No GitHub release with an .ipa is at least {MIN_AGE_DAYS} days old. "
            "Wait for the newest release to age in, or pin a specific tag in Settings.",
            file=sys.stderr,
        )
    sys.exit(1)

tag = chosen.get("tag_name") or ""
name = asset["name"]
# Use API asset URL when authenticated so private repo assets download cleanly.
api_url = asset.get("url") or ""
browser_url = asset["browser_download_url"]
size = asset.get("size") or 0
m = re.search(r"(\d+\.\d+\.\d+)", name) or re.search(r"(\d+\.\d+\.\d+)", tag)
version = m.group(1) if m else tag
with open(out, "w") as f:
    f.write(f"{tag}\t{version}\t{name}\t{browser_url}\t{api_url}\t{size}\n")
print(f"{tag} / {version} / {name}")
PY
  local py_rc=$?
  set -e
  if [[ $py_rc -ne 0 ]]; then
    local err_msg
    err_msg="$(tr '\n' ' ' <"$WORK_DIR/release_err.txt" 2>/dev/null | sed 's/[[:space:]]*$//')"
    if [[ -n "$err_msg" ]]; then
      fail "$err_msg"
    fi
    fail "Could not resolve a GitHub release IPA."
  fi

  IFS=$'\t' read -r RELEASE_TAG RELEASE_VERSION ASSET_NAME ASSET_URL ASSET_API_URL ASSET_SIZE < "$WORK_DIR/asset.tsv"
  info "Latest release: ${RELEASE_TAG} (${ASSET_NAME})"
}

use_cached_ipa() {
  stage "release" "Using local IPA"
  if [[ "$SELECTED_IPA" == */* ]]; then
    IPA_PATH="$SELECTED_IPA"
  else
    IPA_PATH="$DOWNLOAD_DIR/$SELECTED_IPA"
  fi
  [[ -f "$IPA_PATH" ]] || fail "IPA file not found: ${SELECTED_IPA}"
  ASSET_NAME="$(basename "$IPA_PATH")"
  RELEASE_VERSION="$(python3 - "$ASSET_NAME" <<'PY'
import re, sys
name = sys.argv[1]
m = re.search(r"(\d+\.\d+\.\d+)", name)
print(m.group(1) if m else name.removesuffix(".ipa"))
PY
)"
  RELEASE_TAG="local-${RELEASE_VERSION}"
  touch "$IPA_PATH" 2>/dev/null || true
  stage "download" "Using ${ASSET_NAME}"
  info "Selected local IPA: ${ASSET_NAME} (v${RELEASE_VERSION})"
}

prune_cached_ipas() {
  python3 - "$DOWNLOAD_DIR" "$MAX_CACHED_IPAS" "${IPA_PATH:-}" <<'PY'
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
  rm -f "$tmp"

  local download_url="$ASSET_URL"
  local curl_headers=(-H "User-Agent: Renewio" -H "Accept: application/octet-stream")
  if [[ -n "$GITHUB_TOKEN" && -n "${ASSET_API_URL:-}" ]]; then
    download_url="$ASSET_API_URL"
    curl_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl -sS -L --fail -o "$tmp" "${curl_headers[@]}" "$download_url" &
  local curl_pid=$!

  if [[ "${ASSET_SIZE:-0}" -gt 0 ]]; then
    while kill -0 "$curl_pid" 2>/dev/null; do
      if [[ -f "$tmp" ]]; then
        local cur_bytes
        cur_bytes="$(stat -f%z "$tmp" 2>/dev/null || echo 0)"
        local pct=$(( cur_bytes * 100 / ASSET_SIZE ))
        if [[ "$pct" -gt 100 ]]; then pct=100; fi
        emit "[PROGRESS] download|${pct}|${cur_bytes}|${ASSET_SIZE}"
      fi
      sleep 0.35
    done
  fi

  if ! wait "$curl_pid"; then
    rm -f "$tmp"
    fail "Download failed for ${ASSET_NAME}. Check your network and retry."
  fi
  if [[ "${ASSET_SIZE:-0}" -gt 0 ]]; then
    emit "[PROGRESS] download|100|${ASSET_SIZE}|${ASSET_SIZE}"
  fi
  mv -f "$tmp" "$IPA_PATH"
  prune_cached_ipas
}

refresh_signing() {
  stage "provision" "Refreshing signing profile"
  [[ -n "$TEAM_ID" ]] || fail "No Team ID configured. Open Settings and set your Xcode Team ID."
  [[ -n "$BUNDLE_ID" ]] || fail "No Bundle ID configured. Open Settings."

  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|iPhone Developer|Apple Distribution' || true)"
  if [[ -z "$identities" ]]; then
    info "No development certificate in Keychain yet — xcodebuild will try to create one via your Xcode Apple ID."
  fi

  local derived="$WORK_DIR/DerivedData"
  rm -rf "$derived"
  mkdir -p "$derived"

  # Prefer the concrete paired device so Apple registers it on first use.
  # generic/platform=* fails with "team has no devices" until that happens.
  local destination="$XCODE_DESTINATION"
  if [[ -n "$DEVICE_ID" ]]; then
    destination="id=${DEVICE_ID}"
  fi

  local build_log="$WORK_DIR/xcodebuild.log"
  set +e
  /usr/bin/xcodebuild \
    -project "$STUB_ROOT/ProvisioningStub.xcodeproj" \
    -scheme "$STUB_SCHEME" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build >"$build_log" 2>&1
  rc=$?

  # Fall back to generic destination if the device-specific one is flaky.
  if [[ $rc -ne 0 && -n "$DEVICE_ID" && "$destination" != "$XCODE_DESTINATION" ]]; then
    info "Device-specific provisioning failed; retrying with ${XCODE_DESTINATION}."
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
  fi
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

  # Decode provisioning profile to read the real ExpirationDate (7 days for free, 365 days for paid).
  local profile_plist="$WORK_DIR/profile.plist"
  if security cms -D -i "$STUB_PROVISION" > "$profile_plist" 2>/dev/null; then
    PROFILE_EXPIRES_AT="$(python3 - "$profile_plist" <<'PY'
import datetime, pathlib, plistlib, sys
try:
    prof = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
    exp = prof.get("ExpirationDate")
    if isinstance(exp, datetime.datetime):
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=datetime.timezone.utc)
        print(exp.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
except Exception:
    pass
PY
)" || true
    if [[ -n "$PROFILE_EXPIRES_AT" ]]; then
      info "Profile expires at: ${PROFILE_EXPIRES_AT}"
    fi
  fi

  SIGN_IDENTITY="$(codesign -dv --verbose=4 "$STUB_APP" 2>&1 | awk -F'= ' '/Authority=Apple Development|Authority=iPhone Developer/{print $2; exit}')"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|iPhone Developer/{print $2; exit}')"
  fi
  [[ -n "$SIGN_IDENTITY" ]] || fail "Could not find an Apple Development signing identity after the stub build."

  ENTITLEMENTS_PATH="$WORK_DIR/entitlements.plist"
  rm -f "$ENTITLEMENTS_PATH"
  codesign -d --entitlements ":$ENTITLEMENTS_PATH" "$STUB_APP" 2>/dev/null || true
  if [[ ! -s "$ENTITLEMENTS_PATH" ]]; then
    [[ -s "$profile_plist" ]] || security cms -D -i "$STUB_PROVISION" > "$profile_plist" 2>/dev/null \
      || fail "Could not decode the provisioning profile."
    python3 - "$profile_plist" "$ENTITLEMENTS_PATH" <<'PY'
import plistlib, pathlib, sys
prof = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
ents = prof.get("Entitlements") or {}
keep = {}
for k in ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "keychain-access-groups"):
    if k in ents:
        keep[k] = ents[k]
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(keep))
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

  if [[ -d "$APP_PATH/PlugIns" ]]; then
    info "Removing PlugIns so a single app provisioning profile can be used."
    rm -rf "$APP_PATH/PlugIns"
  fi

  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$APP_PATH/Info.plist" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "$APP_PATH/Info.plist"
  if /usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers" "$APP_PATH/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Delete :BGTaskSchedulerPermittedIdentifiers" "$APP_PATH/Info.plist" || true
  fi

  rm -rf "$APP_PATH/_CodeSignature"
  rm -f "$APP_PATH/embedded.mobileprovision"
  cp "$STUB_PROVISION" "$APP_PATH/embedded.mobileprovision"

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

  local app_bundle_name
  app_bundle_name="$(basename "$APP_PATH")"
  if ! codesign -f -s "$SIGN_IDENTITY" \
      --entitlements "$ENTITLEMENTS_PATH" \
      --timestamp=none \
      --generate-entitlement-der \
      "$APP_PATH" 2>"$WORK_DIR/codesign.err"; then
    fail "Failed to sign ${app_bundle_name}: $(tr '\n' ' ' < "$WORK_DIR/codesign.err")"
  fi

  if ! codesign --verify --deep --strict "$APP_PATH" 2>"$WORK_DIR/codesign.err"; then
    fail "Signature verification failed: $(tr '\n' ' ' < "$WORK_DIR/codesign.err")"
  fi

  info "Signed ${APP_PATH}"
}

install_app() {
  stage "install" "Installing on ${DEVICE_NAME:-$DEVICE_KIND}"
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
      fail "Install failed because ${DEVICE_NAME:-$DEVICE_KIND} became unreachable. Wake it, keep it on the network, then retry."
    elif echo "$combined" | grep -qiE 'provision|sign|validat|profile|entitlement'; then
      fail "Install rejected due to signing/profile mismatch. Confirm your Team ID in Settings and ensure ${DEVICE_NAME:-$DEVICE_KIND} is registered to your team, then retry."
    elif echo "$combined" | grep -qiE 'disk|space|full'; then
      fail "${DEVICE_NAME:-$DEVICE_KIND} is out of storage. Free some space, then retry."
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
  python3 - "$CONFIG_PATH" "$TEAM_ID" "$BUNDLE_ID" "$DEVICE_ID" "$DEVICE_NAME" "$RELEASE_VERSION" "$RELEASE_TAG" "$now" "$ASSET_NAME" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
team_id, bundle_id, device_id, device_name, version, tag, now, asset_name = sys.argv[2:10]
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        data = {}
if int(data.get("schemaVersion") or 0) >= 2 or data.get("installs"):
    print("skip-v2-config")
else:
    data.update({
        "teamID": team_id,
        "bundleID": bundle_id,
        "deviceID": device_id,
        "deviceName": device_name,
        "lastInstalledVersion": version,
        "lastInstalledTag": tag,
        "lastInstalledAt": now,
        "lastAssetName": asset_name,
    })
    path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

main() {
  CURRENT_STAGE="init"
  require_tools
  load_config

  [[ -n "$TEAM_ID" ]] || fail "Team ID missing. Complete Settings first."
  [[ -n "$BUNDLE_ID" ]] || fail "Bundle ID missing. Complete Settings first."
  [[ -n "$DEVICE_ID" ]] || fail "Device not selected. Complete Settings first."

  check_device

  if [[ -n "$SELECTED_IPA" ]]; then
    use_cached_ipa
    if [[ "$DRY_RUN" == "1" ]]; then
      emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|dry-run ready (${ASSET_NAME})|"
      exit 0
    fi
  else
    fetch_release

    if [[ "$DRY_RUN" == "1" ]]; then
      emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|dry-run ready (${ASSET_NAME})|"
      exit 0
    fi

    download_ipa
  fi

  refresh_signing
  resign_app

  if [[ "$SKIP_INSTALL" == "1" ]]; then
    cleanup_work_scratch
    emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|signed only (install skipped)|${PROFILE_EXPIRES_AT}"
    exit 0
  fi

  install_app
  write_success_state
  cleanup_work_scratch
  local display_app="${APP_NAME:-$(basename "${APP_PATH:-App}" .app)}"
  emit "[RESULT] ok|${RELEASE_VERSION}|${DEVICE_NAME}|${display_app} ${RELEASE_VERSION} installed on ${DEVICE_NAME}.|${PROFILE_EXPIRES_AT}"
}

main "$@"
