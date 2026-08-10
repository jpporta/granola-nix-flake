#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/granola"
CACHE_DIR="$PROJECT_DIR/.cache"
MACOS_VERSION=""
DMG_PATH=""
DOWNLOAD_LATEST=0
DISPLAY_AUDIO_COMPAT=1

SEVENZIP_VERSION="2501"
SEVENZIP_ARCHIVE="7z${SEVENZIP_VERSION}-linux-x64.tar.xz"
SEVENZIP_URL="https://www.7-zip.org/a/$SEVENZIP_ARCHIVE"
SEVENZIP_SHA256="4ca3b7c6f2f67866b92622818b58233dc70367be2f36b498eb0bdeaaa44b53f4"
GRANOLA_DOWNLOAD_URL="https://api.granola.ai/v1/download-latest"

usage() {
  printf '%s\n' \
    "Build Granola's official macOS Electron payload for a Linux runtime while" \
    "exposing a macOS product identity to Granola's renderer and backend." \
    "" \
    "Usage:" \
    "  ./build.sh [options] /path/to/Granola.dmg" \
    "  ./build.sh [options] --download-latest" \
    "" \
    "Options:" \
    "  --output DIR                   Build destination (default: build/granola)" \
    "  --cache-dir DIR                Download cache (default: .cache)" \
    "  --macos-version VERSION        Identity version (default: installer SDK)" \
    "  --no-display-audio-compat      Keep Granola's audio-only display request" \
    "  --download-latest              Fetch the current official Granola DMG" \
    "  -h, --help                     Show this help"
}

# Build Granola's official macOS Electron payload for a Linux runtime while
# exposing a macOS product identity to Granola's renderer and backend.
#
# Usage:
#   ./build.sh [options] /path/to/Granola.dmg
#   ./build.sh [options] --download-latest
#
# Options:
#   --output DIR                   Build destination (default: build/granola)
#   --cache-dir DIR                Download cache (default: .cache)
#   --macos-version VERSION        Identity version (default: installer SDK)
#   --no-display-audio-compat      Keep Granola's audio-only display request
#   --download-latest              Fetch the current official Granola DMG
#   -h, --help                     Show this help

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

note() {
  printf '    %s\n' "$*"
}

download() {
  local url="$1"
  local destination="$2"
  local partial="${destination}.part"
  mkdir -p "$(dirname "$destination")"
  curl --fail --location --retry 3 --retry-delay 1 \
    --output "$partial" "$url"
  mv "$partial" "$destination"
}

plist_string() {
  local key="$1"
  local plist="$2"
  sed -n "/<key>${key}<\/key>/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;q}" "$plist"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || die "--output requires a directory"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a directory"
      CACHE_DIR="$2"
      shift 2
      ;;
    --macos-version)
      [[ $# -ge 2 ]] || die "--macos-version requires a version"
      MACOS_VERSION="$2"
      shift 2
      ;;
    --no-display-audio-compat)
      DISPLAY_AUDIO_COMPAT=0
      shift
      ;;
    --download-latest)
      DOWNLOAD_LATEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$DMG_PATH" ]] || die "only one DMG may be supplied"
      DMG_PATH="$1"
      shift
      ;;
  esac
done

[[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
if [[ "$DOWNLOAD_LATEST" -eq 1 && -n "$DMG_PATH" ]]; then
  die "choose either a DMG path or --download-latest"
fi
if [[ "$DOWNLOAD_LATEST" -eq 0 && -z "$DMG_PATH" ]]; then
  die "supply the official Granola DMG or use --download-latest"
fi

for command_name in curl tar node npm python3 make sha256sum jq realpath file nproc; do
  command -v "$command_name" >/dev/null || die "missing prerequisite: $command_name"
done
if ! node -e '
const [major, minor, patch] = process.versions.node.split(".").map(Number);
const atLeast = (wantedMinor, wantedPatch) =>
  minor > wantedMinor || (minor === wantedMinor && patch >= wantedPatch);
const supported =
  (major === 22 && atLeast(22, 2)) ||
  (major === 24 && atLeast(15, 0)) ||
  major >= 26;
process.exit(supported ? 0 : 1);
'; then
  die "Node.js 22.22.2+, 24.15.0+, or 26+ is required by the locked node-gyp"
fi

case "$(uname -m)" in
  x86_64|amd64) ELECTRON_ARCH="x64" ;;
  *) die "this release supports x86-64 Linux only" ;;
esac

CC_BIN=""
CXX_BIN=""
for compiler_version in 15 14 13 12 11; do
  if command -v "g++-$compiler_version" >/dev/null \
    && command -v "gcc-$compiler_version" >/dev/null; then
    CXX_BIN="g++-$compiler_version"
    CC_BIN="gcc-$compiler_version"
    break
  fi
done
if [[ -z "$CXX_BIN" ]] && command -v g++ >/dev/null && command -v gcc >/dev/null; then
  compiler_major="$(g++ -dumpversion | cut -d. -f1)"
  if [[ "$compiler_major" =~ ^[0-9]+$ ]] && (( compiler_major >= 11 )); then
    CXX_BIN="g++"
    CC_BIN="gcc"
  fi
fi
[[ -n "$CXX_BIN" ]] || die "GCC/G++ 11 or newer is required"

OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
CACHE_DIR="$(realpath -m "$CACHE_DIR")"
case "$OUTPUT_DIR" in
  /|"$HOME"|"$PROJECT_DIR") die "refusing unsafe output directory: $OUTPUT_DIR" ;;
esac
mkdir -p "$CACHE_DIR" "$(dirname "$OUTPUT_DIR")"

if [[ "$DOWNLOAD_LATEST" -eq 1 ]]; then
  DMG_PATH="$CACHE_DIR/Granola-latest.dmg"
  step "Downloading the official Granola installer"
  download "$GRANOLA_DOWNLOAD_URL" "$DMG_PATH"
fi
DMG_PATH="$(realpath -m "$DMG_PATH")"
[[ -f "$DMG_PATH" ]] || die "DMG not found: $DMG_PATH"

if [[ -n "${GRANOLA_7ZZ:-}" ]]; then
  SEVENZZ="$GRANOLA_7ZZ"
elif command -v 7zz >/dev/null; then
  SEVENZZ="$(command -v 7zz)"
else
  SEVENZIP_TARBALL="$CACHE_DIR/$SEVENZIP_ARCHIVE"
  SEVENZZ="$CACHE_DIR/7zz"
  if [[ ! -f "$SEVENZIP_TARBALL" ]]; then
    step "Downloading the pinned 7-Zip extractor"
    download "$SEVENZIP_URL" "$SEVENZIP_TARBALL"
  fi
  actual_7zip_hash="$(sha256sum "$SEVENZIP_TARBALL" | cut -d' ' -f1)"
  [[ "$actual_7zip_hash" == "$SEVENZIP_SHA256" ]] \
    || die "7-Zip checksum mismatch"
  if [[ ! -x "$SEVENZZ" ]]; then
    tar xf "$SEVENZIP_TARBALL" -C "$CACHE_DIR" 7zz
    chmod 0755 "$SEVENZZ"
  fi
fi
[[ -x "$SEVENZZ" ]] || die "7zz is not executable: $SEVENZZ"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/granola-linux-macos.XXXXXXXX")"
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

step "Inspecting the official DMG"
DMG_METADATA="$WORK_DIR/metadata"
mkdir -p "$DMG_METADATA"
"$SEVENZZ" e "$DMG_PATH" \
  'Granola/Granola.app/Contents/Info.plist' \
  -o"$DMG_METADATA/app" -y >/dev/null \
  || die "cannot read Granola's Info.plist"
"$SEVENZZ" e "$DMG_PATH" \
  'Granola/Granola.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist' \
  -o"$DMG_METADATA/electron" -y >/dev/null \
  || die "cannot read Granola's Electron metadata"

GRANOLA_VERSION="$(plist_string CFBundleShortVersionString "$DMG_METADATA/app/Info.plist")"
ELECTRON_VERSION="$(plist_string CFBundleVersion "$DMG_METADATA/electron/Info.plist")"
SDK_NAME="$(plist_string DTSDKName "$DMG_METADATA/app/Info.plist")"
[[ "$GRANOLA_VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] \
  || die "unexpected Granola version: ${GRANOLA_VERSION:-missing}"
[[ "$ELECTRON_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || die "unexpected Electron version: ${ELECTRON_VERSION:-missing}"
if [[ -z "$MACOS_VERSION" ]]; then
  MACOS_VERSION="${SDK_NAME#macosx}"
  [[ "$MACOS_VERSION" != "$SDK_NAME" && -n "$MACOS_VERSION" ]] \
    || MACOS_VERSION="15.5"
  [[ "$MACOS_VERSION" == *.*.* ]] || MACOS_VERSION="${MACOS_VERSION}.0"
fi
[[ "$MACOS_VERSION" =~ ^[0-9]{1,2}([.][0-9]{1,2}){1,2}$ ]] \
  || die "invalid macOS identity version: $MACOS_VERSION"

DMG_SHA256="$(sha256sum "$DMG_PATH" | cut -d' ' -f1)"
note "Granola $GRANOLA_VERSION"
note "Electron $ELECTRON_VERSION"
note "DMG SHA-256 $DMG_SHA256"
note "Renderer identity macOS $MACOS_VERSION"
note "Native runtime identity Linux"

ELECTRON_NAME="electron-v${ELECTRON_VERSION}-linux-${ELECTRON_ARCH}.zip"
ELECTRON_BASE_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}"
ELECTRON_ZIP="$CACHE_DIR/$ELECTRON_NAME"
ELECTRON_SUMS="$CACHE_DIR/electron-v${ELECTRON_VERSION}-SHASUMS256.txt"

step "Preparing the matching official Linux Electron runtime"
[[ -f "$ELECTRON_SUMS" ]] \
  || download "$ELECTRON_BASE_URL/SHASUMS256.txt" "$ELECTRON_SUMS"
[[ -f "$ELECTRON_ZIP" ]] \
  || download "$ELECTRON_BASE_URL/$ELECTRON_NAME" "$ELECTRON_ZIP"
expected_electron_hash="$(awk -v name="$ELECTRON_NAME" '$2 == "*" name {print $1}' "$ELECTRON_SUMS")"
[[ "$expected_electron_hash" =~ ^[0-9a-f]{64}$ ]] \
  || die "official Electron checksum entry not found for $ELECTRON_NAME"
actual_electron_hash="$(sha256sum "$ELECTRON_ZIP" | cut -d' ' -f1)"
[[ "$actual_electron_hash" == "$expected_electron_hash" ]] \
  || die "Electron checksum mismatch"
note "Electron SHA-256 verified"

STAGE_DIR="$WORK_DIR/stage"
APP_DIR="$STAGE_DIR/granola"
mkdir -p "$APP_DIR"
"$SEVENZZ" x "$ELECTRON_ZIP" -o"$APP_DIR" -y >/dev/null
chmod 0755 "$APP_DIR/electron"
rm -f "$APP_DIR/resources/default_app.asar"

step "Extracting Granola's application payload"
DMG_EXTRACT="$WORK_DIR/dmg"
RESOURCE_PATH='Granola/Granola.app/Contents/Resources'
"$SEVENZZ" x "$DMG_PATH" \
  "$RESOURCE_PATH/app.asar" \
  "$RESOURCE_PATH/app.asar.unpacked" \
  "$RESOURCE_PATH/icons" \
  -o"$DMG_EXTRACT" -y >/dev/null \
  || die "cannot extract Granola's application payload"
cp -a "$DMG_EXTRACT/$RESOURCE_PATH/app.asar" \
  "$DMG_EXTRACT/$RESOURCE_PATH/app.asar.unpacked" \
  "$DMG_EXTRACT/$RESOURCE_PATH/icons" \
  "$APP_DIR/resources/"
[[ -f "$APP_DIR/resources/icons/icon.png" ]] \
  || die "Granola icon was not found in the installer"
cp "$APP_DIR/resources/icons/icon.png" "$APP_DIR/granola-icon.png"

step "Applying the split macOS/Linux identity patch"
PATCH_ARGS=(
  "$APP_DIR/resources/app.asar"
  --macos-version "$MACOS_VERSION"
)
if [[ "$DISPLAY_AUDIO_COMPAT" -eq 0 ]]; then
  PATCH_ARGS+=(--no-display-audio-compat)
fi
python3 "$PROJECT_DIR/scripts/patch_asar.py" "${PATCH_ARGS[@]}"

step "Rebuilding Granola's encrypted SQLite module for Linux"
SQLITE_MODULE="$APP_DIR/resources/app.asar.unpacked/node_modules/better-sqlite3-multiple-ciphers"
[[ -f "$SQLITE_MODULE/package.json" ]] || die "Granola's SQLite module is missing"
SQLITE_VERSION="$(node -p "require('$SQLITE_MODULE/package.json').version")"
[[ "$SQLITE_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || die "unexpected SQLite module version: $SQLITE_VERSION"
SQLITE_INTEGRITY="$(jq -r --arg version "$SQLITE_VERSION" \
  '."better-sqlite3-multiple-ciphers"[$version] // empty' \
  "$PROJECT_DIR/locks/npm-sources.json")"
[[ -n "$SQLITE_INTEGRITY" ]] || die \
  "better-sqlite3-multiple-ciphers $SQLITE_VERSION is not reviewed in locks/npm-sources.json"

NPM_SOURCE_DIR="$CACHE_DIR/npm-sources"
mkdir -p "$NPM_SOURCE_DIR"
SQLITE_TARBALL="$NPM_SOURCE_DIR/better-sqlite3-multiple-ciphers-${SQLITE_VERSION}.tgz"
if [[ ! -f "$SQLITE_TARBALL" ]]; then
  PACK_DIR="$WORK_DIR/npm-pack"
  mkdir -p "$PACK_DIR"
  PACK_RESULT="$(npm_config_cache="$CACHE_DIR/npm" npm pack \
    "better-sqlite3-multiple-ciphers@$SQLITE_VERSION" \
    --ignore-scripts --json --pack-destination "$PACK_DIR")"
  PACK_INTEGRITY="$(jq -r '.[0].integrity // empty' <<<"$PACK_RESULT")"
  PACK_FILENAME="$(jq -r '.[0].filename // empty' <<<"$PACK_RESULT")"
  [[ "$PACK_INTEGRITY" == "$SQLITE_INTEGRITY" ]] \
    || die "npm returned an unexpected SQLite source integrity value"
  [[ -f "$PACK_DIR/$PACK_FILENAME" ]] || die "npm source tarball was not created"
  mv "$PACK_DIR/$PACK_FILENAME" "$SQLITE_TARBALL"
fi
python3 "$PROJECT_DIR/scripts/verify_sri.py" "$SQLITE_TARBALL" "$SQLITE_INTEGRITY"

STOCK_SOURCE="$WORK_DIR/sqlite-stock"
mkdir -p "$STOCK_SOURCE"
tar xzf "$SQLITE_TARBALL" -C "$STOCK_SOURCE" package/binding.gyp
cp "$STOCK_SOURCE/package/binding.gyp" "$SQLITE_MODULE/binding.gyp"

NODE_GYP_VERSION="$(jq -r '."node-gyp".version' "$PROJECT_DIR/locks/npm-sources.json")"
[[ "$NODE_GYP_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
  || die "invalid locked node-gyp version"
NODE_GYP_INTEGRITY="$(jq -r '."node-gyp".integrity // empty' \
  "$PROJECT_DIR/locks/npm-sources.json")"
[[ -n "$NODE_GYP_INTEGRITY" ]] || die "node-gyp integrity lock is missing"
NODE_GYP_TARBALL="$NPM_SOURCE_DIR/node-gyp-${NODE_GYP_VERSION}.tgz"
if [[ ! -f "$NODE_GYP_TARBALL" ]]; then
  NODE_GYP_PACK_DIR="$WORK_DIR/npm-pack-node-gyp"
  mkdir -p "$NODE_GYP_PACK_DIR"
  NODE_GYP_PACK_RESULT="$(npm_config_cache="$CACHE_DIR/npm" npm pack \
    "node-gyp@$NODE_GYP_VERSION" \
    --ignore-scripts --json --pack-destination "$NODE_GYP_PACK_DIR")"
  NODE_GYP_PACK_INTEGRITY="$(jq -r '.[0].integrity // empty' \
    <<<"$NODE_GYP_PACK_RESULT")"
  NODE_GYP_PACK_FILENAME="$(jq -r '.[0].filename // empty' \
    <<<"$NODE_GYP_PACK_RESULT")"
  [[ "$NODE_GYP_PACK_INTEGRITY" == "$NODE_GYP_INTEGRITY" ]] \
    || die "npm returned an unexpected node-gyp source integrity value"
  [[ -f "$NODE_GYP_PACK_DIR/$NODE_GYP_PACK_FILENAME" ]] \
    || die "node-gyp source tarball was not created"
  mv "$NODE_GYP_PACK_DIR/$NODE_GYP_PACK_FILENAME" "$NODE_GYP_TARBALL"
fi
python3 "$PROJECT_DIR/scripts/verify_sri.py" \
  "$NODE_GYP_TARBALL" "$NODE_GYP_INTEGRITY"

NATIVE_LOG="$WORK_DIR/native-build.log"
if ! (
  cd "$SQLITE_MODULE"
  CC="$CC_BIN" CXX="$CXX_BIN" \
    npm_config_cache="$CACHE_DIR/npm" \
    npm_config_devdir="$CACHE_DIR/node-gyp" \
    npm_config_ignore_scripts=true \
    npm exec --yes --package="$NODE_GYP_TARBALL" -- \
      node-gyp rebuild --release \
      --runtime=electron \
      --target="$ELECTRON_VERSION" \
      --arch="$ELECTRON_ARCH" \
      --dist-url=https://electronjs.org/headers \
      --jobs="$(nproc)"
) >"$NATIVE_LOG" 2>&1; then
  tail -n 60 "$NATIVE_LOG" >&2
  die "native SQLite build failed"
fi
file "$SQLITE_MODULE/build/Release/better_sqlite3.node" | grep -q 'ELF 64-bit' \
  || die "rebuilt SQLite module is not a 64-bit Linux ELF library"
note "Native SQLite module rebuilt with node-gyp $NODE_GYP_VERSION and $CXX_BIN"

cat >"$APP_DIR/run-granola" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\$APP_DIR/electron" \
  --ozone-platform-hint=auto \
  --enable-features=WebRTCPipeWireCapturer \
  "\$@"
EOF
chmod 0755 "$APP_DIR/run-granola"

cat >"$APP_DIR/.granola-linux-macos-build" <<EOF
granola_version=$GRANOLA_VERSION
electron_version=$ELECTRON_VERSION
macos_identity=$MACOS_VERSION
dmg_sha256=$DMG_SHA256
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

step "Smoke-testing the Linux native module"
SMOKE_DB="$WORK_DIR/granola-linux-macos-smoke.db"
ELECTRON_RUN_AS_NODE=1 \
NODE_PATH="$APP_DIR/resources/app.asar/node_modules" \
  "$APP_DIR/electron" -e "
const fs = require('node:fs');
const Database = require('$SQLITE_MODULE/lib/index.js');
const db = new Database('$SMOKE_DB');
db.pragma(\"cipher='sqlcipher'\");
db.pragma(\"key='granola-linux-macos-smoke-test'\");
db.exec('CREATE TABLE smoke(value INTEGER)');
let hookFired = false;
db.updateHook(() => { hookFired = true; });
db.prepare('INSERT INTO smoke VALUES (?)').run(42);
if (db.prepare('SELECT value FROM smoke').get().value !== 42) process.exit(2);
if (!hookFired) process.exit(3);
db.close();
const sqliteHeader = Buffer.from('SQLite format 3\\0');
if (fs.readFileSync('$SMOKE_DB').subarray(0, 16).equals(sqliteHeader)) process.exit(4);
const reopened = new Database('$SMOKE_DB');
reopened.pragma(\"cipher='sqlcipher'\");
reopened.pragma(\"key='granola-linux-macos-smoke-test'\");
if (reopened.prepare('SELECT value FROM smoke').get().value !== 42) process.exit(5);
reopened.close();
"
note "Encrypted SQLite and Granola's updateHook extension work"

if [[ -e "$OUTPUT_DIR" ]]; then
  [[ -f "$OUTPUT_DIR/.granola-linux-macos-build" ]] \
    || die "refusing to replace unrecognized output directory: $OUTPUT_DIR"
  BACKUP_DIR="${OUTPUT_DIR}.previous-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$OUTPUT_DIR" "$BACKUP_DIR"
  note "Previous build preserved at $BACKUP_DIR"
fi
mv "$APP_DIR" "$OUTPUT_DIR"

printf '\nBuilt Granola %s for Linux with macOS %s product identity.\n' \
  "$GRANOLA_VERSION" "$MACOS_VERSION"
printf 'Run: %s/run-granola\n' "$OUTPUT_DIR"
printf 'Desktop integration: %s/desktop.sh install %s\n' "$PROJECT_DIR" "$OUTPUT_DIR"
