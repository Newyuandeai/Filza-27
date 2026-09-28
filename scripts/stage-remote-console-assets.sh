#!/usr/bin/env bash
#
# stage-remote-console-assets.sh
#
# Assembles Resources/FilzaRemoteWeb/FilzaRemoteWeb.bundle from the console
# source tree (Resources/FilzaRemoteWeb/src) so that build_release_ipa.sh can
# copy it into Payload/*.app next to Filza3105.bundle and MondEmbedded.bundle.
#
# Contract: docs/API.md — the bundle is what the FilzaRemoteConsole dylib module
# serves from GCDWebServer. Assets are plain files (no build step, no npm).
#
# Usage: bash scripts/stage-remote-console-assets.sh [--check]
#   --check   verify an existing bundle without rewriting it (used by CI)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/Resources/FilzaRemoteWeb/src"
BUNDLE="$REPO_ROOT/Resources/FilzaRemoteWeb/FilzaRemoteWeb.bundle"
PLIST="$BUNDLE/Info.plist"

CHECK_ONLY=0
for argument in "$@"; do
  case "$argument" in
    --check) CHECK_ONLY=1 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

fail() { echo "remote console staging: $*" >&2; exit 70; }
require_file() { [[ -s "$1" ]] || fail "missing or empty: ${1#$REPO_ROOT/}"; }

# The console must be present as source; it is authored as plain ES modules.
[[ -d "$SRC" ]] || fail "missing console source directory: ${SRC#$REPO_ROOT/}"
for required in index.html css/app.css js/app.js js/api.js js/util.js js/ui.js js/browser.js js/preview.js js/transfers.js manifest.webmanifest; do
  require_file "$SRC/$required"
done

# Product-specific assertions: these files are what the browser actually loads,
# so a rename that forgets one of them must fail the build rather than 404 later.
grep -Fq 'id="sprite-mount"' "$SRC/index.html" || fail "index.html no longer provides the icon sprite mount point"
grep -Fq './assets/images/filetype-icon-sprite.svg' "$SRC/js/ui.js" || fail "ui.js does not load the icon sprite"
grep -Fq '/api/v1/upload' "$SRC/js/api.js" || fail "api.js does not implement the resumable upload endpoint"
grep -Fq 'X-Filza-Token' "$SRC/js/api.js" || fail "api.js does not send the pairing token header"
grep -Fq '/api/v1/events' "$SRC/js/api.js" || fail "api.js does not open the SSE stream"
grep -Fq '#pair=' "$SRC/js/app.js" || fail "app.js no longer supports pairing-link auto login"

if [[ "$CHECK_ONLY" == "1" ]]; then
  [[ -d "$BUNDLE" ]] || fail "bundle not staged: ${BUNDLE#$REPO_ROOT/}"
  require_file "$PLIST"
  require_file "$BUNDLE/index.html"
  require_file "$BUNDLE/css/app.css"
  require_file "$BUNDLE/js/app.js"
  require_file "$BUNDLE/assets/images/filetype-icon-sprite.svg"
  echo "remote console bundle OK: ${BUNDLE#$REPO_ROOT/}"
  exit 0
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp -R "$SRC/." "$BUNDLE/"

# The bundle the dylib resolves through -[NSBundle pathForResource:ofType:].
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>com.filzaremote.webconsole</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FilzaRemoteWeb</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.0.0</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>FilzaRemoteAPIContract</key>
	<string>docs/API.md</string>
</dict>
</plist>
PLIST

# Keep the bundle free of anything the console should not ship.
find "$BUNDLE" -name '.DS_Store' -delete 2>/dev/null || true
find "$BUNDLE" -name '*.map' -delete 2>/dev/null || true

require_file "$PLIST"
require_file "$BUNDLE/index.html"
require_file "$BUNDLE/assets/images/filetype-icon-sprite.svg"

echo "remote console bundle staged: ${BUNDLE#$REPO_ROOT/}"
echo "  files: $(find "$BUNDLE" -type f | wc -l | tr -d ' ')"
echo "  bytes: $(find "$BUNDLE" -type f -exec cat {} + | wc -c | tr -d ' ')"
