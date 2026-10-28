#!/bin/bash
# Fork build: ClipBoardLine with the fork's own identity (docs/fork/PLAN.md).
# Upstream's build-community.sh does the work; this file only sets the values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOCAL_IDENTITY="ClipBoardLine Local Signing (SelcukOzbilgi)"

if [ -z "${CLIPBOARDLINE_SIGN_IDENTITY:-}" ]; then
  # A stable identity keeps the Accessibility permission across rebuilds.
  # Self-signed shows as "not trusted"; codesign accepts it anyway.
  CLIPBOARDLINE_SIGN_IDENTITY=-
  if security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$LOCAL_IDENTITY\""; then
    # Probe first: without the keychain access step codesign waits on a dialog.
    PROBE="$(mktemp -d)"
    cp /usr/bin/true "$PROBE/probe"
    codesign --force --sign "$LOCAL_IDENTITY" "$PROBE/probe" 2>/dev/null &
    PID=$!
    for _ in $(seq 30); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null || true
      echo "codesign cannot use the local key yet; run scripts/fork-signing-setup.sh once." >&2
    elif wait "$PID"; then
      CLIPBOARDLINE_SIGN_IDENTITY="$LOCAL_IDENTITY"
    fi
    rm -rf "$PROBE"
  fi
  if [ "$CLIPBOARDLINE_SIGN_IDENTITY" = - ]; then
    echo "Signing ad-hoc; Accessibility permission will not survive rebuilds." >&2
  fi
fi

export CLIPBOARDLINE_SIGN_IDENTITY
export CLIPBOARDLINE_APP_NAME="ClipBoardLine"
export CLIPBOARDLINE_BUNDLE_ID="io.github.selcukozbilgi.clipboardline"
export CLIPBOARDLINE_STORAGE_FOLDER="ClipBoardLine/Screenshots"
export CLIPBOARDLINE_RECOVERY_SUITE="io.github.selcukozbilgi.clipboardline.recovery"
export CLIPBOARDLINE_LINK_PREVIEWS_DEFAULT=0
CLIPBOARDLINE_VERSION="$(python3 -c 'import json; print(json.load(open("release-version.json"))["version"])')"
CLIPBOARDLINE_BUILD_NUMBER="$(git rev-list --count HEAD)"
export CLIPBOARDLINE_VERSION CLIPBOARDLINE_BUILD_NUMBER
echo "Signing with: $CLIPBOARDLINE_SIGN_IDENTITY"
exec bash scripts/build-community.sh "$@"
