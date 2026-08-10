#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-}"
APP_DIR="${2:-$PROJECT_DIR/build/granola}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APPLICATIONS_DIR/granola-linux-macos.desktop"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "$ACTION" in
  install)
    APP_DIR="$(realpath -m "$APP_DIR")"
    [[ -x "$APP_DIR/run-granola" ]] || die "build not found at $APP_DIR"
    [[ -f "$APP_DIR/.granola-linux-macos-build" ]] \
      || die "unrecognized build directory: $APP_DIR"
    [[ "$APP_DIR" != *$'\n'* && "$APP_DIR" != *'"'* ]] \
      || die "application path contains unsupported desktop-entry characters"
    mkdir -p "$APPLICATIONS_DIR"
    TEMP_FILE="$(mktemp "$APPLICATIONS_DIR/.granola-linux-macos.XXXXXX")"
    trap 'rm -f -- "$TEMP_FILE"' EXIT
    cat >"$TEMP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Granola (Linux, macOS identity)
Comment=Unofficial Linux compatibility build for Granola
Exec="$APP_DIR/run-granola" %U
Icon=$APP_DIR/granola-app-icon.png
Terminal=false
StartupWMClass=granola
MimeType=x-scheme-handler/granola;
X-Granola-Linux-MacOS-Identity=true
EOF
    chmod 0644 "$TEMP_FILE"
    mv "$TEMP_FILE" "$DESKTOP_FILE"
    command -v desktop-file-validate >/dev/null \
      && desktop-file-validate "$DESKTOP_FILE"
    command -v update-desktop-database >/dev/null \
      && update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    command -v xdg-mime >/dev/null \
      && xdg-mime default "$(basename "$DESKTOP_FILE")" \
        x-scheme-handler/granola >/dev/null 2>&1 || true
    printf 'Installed desktop entry: %s\n' "$DESKTOP_FILE"
    ;;
  uninstall)
    if [[ -f "$DESKTOP_FILE" ]]; then
      rm -- "$DESKTOP_FILE"
      printf 'Removed desktop entry: %s\n' "$DESKTOP_FILE"
    else
      printf 'Desktop entry is already absent: %s\n' "$DESKTOP_FILE"
    fi
    command -v update-desktop-database >/dev/null \
      && update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
    ;;
  *)
    printf 'Usage: %s install [build-directory]\n' "$0" >&2
    printf '       %s uninstall\n' "$0" >&2
    exit 2
    ;;
esac
