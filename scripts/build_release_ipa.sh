#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "usage: $0 <base-unsigned.ipa> <output.ipa> [MCMIdentifiers.plist]" >&2
  exit 64
fi

BASE_IPA="${1:A}"
OUTPUT_IPA="${2:A}"
CATALOG="${3:-}"
if [[ -n "$CATALOG" ]]; then
  CATALOG="${CATALOG:A}"
fi

REPO_ROOT="${0:A:h:h}"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

[[ -f "$BASE_IPA" ]] || { echo "base IPA not found: $BASE_IPA" >&2; exit 66; }
if [[ -n "$CATALOG" ]]; then
  [[ -f "$CATALOG" ]] || { echo "catalog not found: $CATALOG" >&2; exit 66; }
  plutil -lint "$CATALOG" >/dev/null
  plutil -extract AppData xml1 -o /dev/null "$CATALOG"
fi

cd "$REPO_ROOT"
make clean
make package FINALPACKAGE=1

DYLIB="$REPO_ROOT/.theos/obj/FilzaApplySandboxExt.dylib"
[[ -f "$DYLIB" ]] || { echo "built dylib not found: $DYLIB" >&2; exit 70; }

# Keep the standalone release path identical to the verified Actions package:
# stage v2.4 runtime files plus the exact pre-v2.4 YouTubeKit JS resources that
# SignatureSolver resolves from Bundle.main.
bash "$REPO_ROOT/scripts/stage-byetunes-resources.sh" "$REPO_ROOT/.theos/byetunes-resources"

# 89ce7db stopped staging the retired pre-v2.4 YouTubeKit JavaScript in
# stage-byetunes-resources.sh, but the release IPA still has to carry it (see
# 5b85ac8): SignatureSolver resolves these from Bundle.main at runtime. Take them
# from the pinned YouTubeKit tree, which FilzaYouTubeKitBootstrap.mk already
# staged during `make package` above.
STAGED_RESOURCES="$REPO_ROOT/.theos/byetunes-resources"
YTK_RESOURCES="$REPO_ROOT/ThirdParty/byetunes-youtubekit/Generated/Resources"
# An array, not a string: this script runs under zsh, which does not split
# unquoted parameter expansions into words.
COPIED_FROM_YTK=()
for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  [[ -s "$STAGED_RESOURCES/$resource" ]] && continue
  if [[ ! -s "$YTK_RESOURCES/$resource" ]]; then
    echo "staging the pinned pre-v2.4 YouTubeKit resources" >&2
    bash "$REPO_ROOT/scripts/stage-byetunes-youtubekit.sh" >/dev/null
  fi
  [[ -s "$YTK_RESOURCES/$resource" ]] || {
    echo "pinned YouTubeKit resource unavailable: $resource" >&2
    exit 70
  }
  cp "$YTK_RESOURCES/$resource" "$STAGED_RESOURCES/$resource"
  COPIED_FROM_YTK+=("$resource")
done
if (( ${#COPIED_FROM_YTK[@]} )); then
  (
    cd "$STAGED_RESOURCES"
    shasum -a 256 "${COPIED_FROM_YTK[@]}" >> SHA256SUMS
    shasum -a 256 -c SHA256SUMS
  )
  echo "Staged pinned YouTubeKit JavaScript: ${COPIED_FROM_YTK[*]}"
fi

for resource in AppIconImage.png ByeTunes-Info.plist Config.plist meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  [[ -s "$REPO_ROOT/.theos/byetunes-resources/$resource" ]] || {
    echo "staged ByeTunes resource missing: $resource" >&2
    exit 70
  }
done

STAGE_ROOT="$(mktemp -d /tmp/FilzaSlop-release.XXXXXX)"
trap 'trash "$STAGE_ROOT"' EXIT
unzip -q "$BASE_IPA" -d "$STAGE_ROOT/stage"

APP="$(find "$STAGE_ROOT/stage/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "Payload app not found" >&2; exit 65; }

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist")"
[[ "$BUNDLE_ID" == "com.apple.mobile.MobileHouseArrest" ]] || {
  echo "unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 65
}

if codesign -d "$APP" >/dev/null 2>&1; then
  echo "base app is signed; use an unsigned base IPA" >&2
  exit 65
fi

cp "$DYLIB" "$APP/Frameworks/FilzaApplySandboxExt.dylib"
codesign --remove-signature "$APP/Frameworks/FilzaApplySandboxExt.dylib"
rm -f "$APP/Frameworks/FilzaMondModern.dylib"
plutil -replace MinimumOSVersion -string "17.0" "$APP/Info.plist"

# Upstream FilzaSlop strips Filza/SDK URL handlers from release IPAs so other
# apps cannot fingerprint this build through canOpenURL:. Keep the downstream
# runtime integrations intact and remove only the packaged URL declarations.
plutil -remove CFBundleURLTypes "$APP/Info.plist" 2>/dev/null || true
if plutil -extract CFBundleURLTypes json -o - "$APP/Info.plist" >/dev/null 2>&1; then
  echo "CFBundleURLTypes was not stripped from packaged Info.plist" >&2
  exit 70
fi

cp "$REPO_ROOT/.theos/byetunes-resources/AppIconImage.png" "$APP/AppIconImage.png"
cp "$REPO_ROOT/.theos/byetunes-resources/ByeTunes-Info.plist" "$APP/ByeTunes-Info.plist"
cp "$REPO_ROOT/.theos/byetunes-resources/Config.plist" "$APP/Config.plist"
cp "$REPO_ROOT/.theos/byetunes-resources/meriyah.umd.js" "$APP/meriyah.umd.js"
cp "$REPO_ROOT/.theos/byetunes-resources/astring.umd.js" "$APP/astring.umd.js"
cp "$REPO_ROOT/.theos/byetunes-resources/yt_ejs_helper.js" "$APP/yt_ejs_helper.js"

rm -rf "$APP/Filza3105.bundle"
cp -R "$REPO_ROOT/ThirdParty/3105/Resources/Filza3105.bundle" "$APP/Filza3105.bundle"
bash "$REPO_ROOT/scripts/merge-3105-app-metadata.sh" "$APP/Info.plist"

# Remote file viewer console (docs/API.md). The bundle is staged from
# Resources/FilzaRemoteWeb/src and served by FilzaRemoteConsole over the same
# GCDWebServer runtime that owns WebDAV — no extra listener is introduced here.
bash "$REPO_ROOT/scripts/stage-remote-console-assets.sh"
[[ -s "$REPO_ROOT/Resources/FilzaRemoteWeb/FilzaRemoteWeb.bundle/index.html" ]] || {
  echo "remote console staging did not produce index.html" >&2
  exit 73
}
rm -rf "$APP/FilzaRemoteWeb.bundle"
cp -R "$REPO_ROOT/Resources/FilzaRemoteWeb/FilzaRemoteWeb.bundle" "$APP/FilzaRemoteWeb.bundle"
[[ -s "$APP/FilzaRemoteWeb.bundle/index.html" ]] || {
  echo "remote console bundle was not copied into the app" >&2
  exit 74
}
[[ -s "$APP/FilzaRemoteWeb.bundle/assets/images/filetype-icon-sprite.svg" ]] || {
  echo "remote console icon sprite missing from the packaged bundle" >&2
  exit 75
}

# The WebDAV and SSH/SFTP runtimes bind to the LAN and optionally publish
# Bonjour services. Keep standalone/manual release packaging in exact parity
# with the verified modern Actions IPA so iOS can present Local Network
# permission and permit both advertised service types.
plutil -replace NSLocalNetworkUsageDescription -string \
  "Filza 27 uses your local network when you enable its WebDAV server, SSH/SFTP server or remote browser file console." \
  "$APP/Info.plist"
plutil -replace NSBonjourServices -json '["_http._tcp","_ssh._tcp"]' "$APP/Info.plist"

if [[ -n "$CATALOG" ]]; then
  cp "$CATALOG" "$APP/MCMIdentifiers.plist"
elif [[ -e "$APP/MCMIdentifiers.plist" ]]; then
  trash "$APP/MCMIdentifiers.plist"
fi

[[ "$(plutil -extract MinimumOSVersion raw -o - "$APP/Info.plist")" == "17.0" ]] || { echo "unexpected MinimumOSVersion" >&2; exit 70; }
[[ ! -e "$APP/Frameworks/FilzaMondModern.dylib" ]] || { echo "stale split Mond runtime present" >&2; exit 70; }

for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  [[ -s "$APP/$resource" ]] || { echo "YouTubeKit app resource missing: $resource" >&2; exit 70; }
done

NETWORK_DESCRIPTION="$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$APP/Info.plist")"
[[ "$NETWORK_DESCRIPTION" == *"WebDAV"* && "$NETWORK_DESCRIPTION" == *"SSH/SFTP"* ]] || {
  echo "local-network usage description missing WebDAV/SSH coverage" >&2
  exit 70
}
BONJOUR_JSON="$(plutil -extract NSBonjourServices json -o - "$APP/Info.plist")"
[[ "$BONJOUR_JSON" == *'"_http._tcp"'* && "$BONJOUR_JSON" == *'"_ssh._tcp"'* ]] || {
  echo "required Bonjour service declarations missing" >&2
  exit 70
}

# ---------------------------------------------------------------------------
# Chat-first shell (optional). FILZA_CHAT_SHELL=1 makes this IPA the chat client:
# the display name and URL scheme change, the file-manager advertising keys are
# stripped, the media-capture usage descriptions the chat surface needs are
# added, and TryMaskCardShell.plist arms the injected module at runtime. Every
# runtime backend (MCM root, kexploit, ZIP hooks, SSH/SFTP, WebDAV, remote
# console) is untouched - only Filza's own file manager UI stops being shown.
# Without this variable the packaging path is exactly the release path.
#   FILZA_CHAT_SHELL_URL                  chat home page
#   FILZA_CHAT_SHELL_DISPLAY_NAME         springboard name of the chat client
#   FILZA_CHAT_SHELL_SCHEME               custom URL entry scheme
#   FILZA_CHAT_SHELL_BUNDLE_ID            optional identifier override (explicit opt-in)
#   FILZA_CHAT_SHELL_ALLOW_HIDDEN_FILE_MANAGER=1  re-arm the stored on-device entry
# Contract and rollback: docs/CHAT_SHELL.md
# ---------------------------------------------------------------------------
if [[ "${FILZA_CHAT_SHELL:-0}" == "1" ]]; then
  SHELL_PLIST="$APP/TryMaskCardShell.plist"
  SHELL_URL="${FILZA_CHAT_SHELL_URL:-https://trymaskcard.com/}"
  SHELL_SCHEME="${FILZA_CHAT_SHELL_SCHEME:-trymaskcard}"
  SHELL_NAME="${FILZA_CHAT_SHELL_DISPLAY_NAME:-TryMaskCard}"
  export FILZA_CHAT_SHELL_URL="$SHELL_URL"
  export FILZA_CHAT_SHELL_SCHEME="$SHELL_SCHEME"
  export FILZA_CHAT_SHELL_DISPLAY_NAME="$SHELL_NAME"

  echo "packaging the chat-first shell: home=$SHELL_URL scheme=$SHELL_SCHEME name=$SHELL_NAME"
  python3 "$REPO_ROOT/scripts/merge-chat-shell-metadata.py" "$APP/Info.plist" \
      --shell-plist "$SHELL_PLIST" \
      --url "$SHELL_URL" --scheme "$SHELL_SCHEME" --display-name "$SHELL_NAME"

  [[ -s "$SHELL_PLIST" ]] || { echo "chat-shell plist was not produced" >&2; exit 76; }
  plutil -lint "$SHELL_PLIST" >/dev/null
  [[ "$(plutil -extract enabled raw -o - "$SHELL_PLIST")" == "true" ]] || {
    echo "chat-shell plist is not enabled" >&2
    exit 76
  }
  [[ "$(plutil -extract homeURL raw -o - "$SHELL_PLIST")" == "$SHELL_URL" ]] || {
    echo "chat-shell home URL was not applied" >&2
    exit 76
  }
  [[ "$(plutil -extract CFBundleDisplayName raw -o - "$APP/Info.plist")" == "$SHELL_NAME" ]] || {
    echo "chat-shell display name was not applied" >&2
    exit 76
  }
  # Pipe-free on purpose. `strings -a ... | grep -Fq` fails on macOS under
  # `set -o pipefail`: grep exits at the first match, strings then dies flushing
  # to the closed pipe ("failed to flush output"), and the pipeline status
  # becomes non-zero even though the symbol is present - the build reported a
  # missing chat-shell module for a dylib that contained it.
  URL_TYPES_XML="$(plutil -extract CFBundleURLTypes xml1 -o - "$APP/Info.plist")"
  case "$URL_TYPES_XML" in
    *"$SHELL_SCHEME"*) ;;
    *) echo "chat-shell URL scheme missing from Info.plist" >&2; exit 76 ;;
  esac

  # The shell module and its compiled-in default home page must be inside the
  # injected dylib that actually ships in Frameworks/. Class names and string
  # literals are checked because they survive the release strip; static function
  # symbols do not.
  #
  # The byte-level verifier at the end of this block is the authority; the strings
  # scan is only a faster, more readable pre-check, so a host without `strings`
  # (or one where it fails) degrades to the verifier instead of failing here.
  # It is also pipe-free on purpose: `strings -a ... | grep -Fq` breaks macOS
  # builds under `set -o pipefail`, because grep exits at the first match and
  # strings then dies flushing into the closed pipe. No EXIT trap is used here -
  # this script already owns one for the stage directory.
  SHELL_DYLIB="$APP/Frameworks/FilzaApplySandboxExt.dylib"
  SHELL_STRINGS="$(mktemp "${TMPDIR:-/tmp}/filza-shell-strings.XXXXXXXX")"

  if command -v strings >/dev/null 2>&1 && strings -a "$SHELL_DYLIB" > "$SHELL_STRINGS" 2>/dev/null; then
  # The last marker is the *compiled-in* forced-activation literal, which proves
  # this dylib boots the chat surface by construction; the home URL is the
  # compiled-in fallback in TryMaskCardShell.m, not the configured $SHELL_URL
  # (overriding --url does not change that literal).
  for marker in TMShellWebController TMShellFileManagerContainer chat-shell-forced-by-build https://trymaskcard.com/; do
      if ! grep -Fq "$marker" "$SHELL_STRINGS"; then
        rm -f "$SHELL_STRINGS"
        echo "injected dylib is missing the chat-shell marker: $marker" >&2
        exit 76
      fi
    done
    echo "injected dylib carries the chat-shell markers"
  else
    echo "strings unavailable or failed; the byte-level verifier below covers the same markers" >&2
  fi
  rm -f "$SHELL_STRINGS"

  python3 "$REPO_ROOT/scripts/merge-chat-shell-metadata.py" --verify-app "$APP" \
      --scheme "$SHELL_SCHEME" >/dev/null
  echo "chat-shell metadata verified in $APP"
fi

if [[ -e "$OUTPUT_IPA" ]]; then
  trash "$OUTPUT_IPA"
fi
(
  cd "$STAGE_ROOT/stage"
  zip -qry "$OUTPUT_IPA" Payload
)

unzip -tq "$OUTPUT_IPA"
for resource in meriyah.umd.js astring.umd.js yt_ejs_helper.js; do
  unzip -l "$OUTPUT_IPA" | grep -F "$resource" >/dev/null
 done

# Final end-to-end assertion on the artifact itself, not on the staging tree.
if [[ "${FILZA_CHAT_SHELL:-0}" == "1" ]]; then
  python3 "$REPO_ROOT/scripts/merge-chat-shell-metadata.py" --verify-ipa "$OUTPUT_IPA" \
      --scheme "${FILZA_CHAT_SHELL_SCHEME:-trymaskcard}"
  unzip -l "$OUTPUT_IPA" | grep -F 'TryMaskCardShell.plist' >/dev/null
fi

shasum -a 256 "$OUTPUT_IPA"
