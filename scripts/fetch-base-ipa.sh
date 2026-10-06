#!/bin/bash
#
# Resolve and validate the unsigned base IPA for the Filza-27 packaging pipeline.
#
# Why this exists: the workflow used to curl one hard-coded release URL. When that
# release/tag is renamed, deleted or re-published, the CI dies at step one with a
# bare `curl: (56) 404`. This script resolves the asset from the GitHub API
# instead, falls back to the pinned URL, and validates the download *before* the
# expensive build so a bad base fails fast with an actionable message.
#
# Usage:
#   scripts/fetch-base-ipa.sh <output.ipa> [<url>]
#   scripts/fetch-base-ipa.sh --print-url [<url>]        # resolve only, no download
#
# Resolution order:
#   1. <url> argument
#   2. $BASE_IPA_URL
#   3. newest non-draft GitHub release of $BASE_IPA_REPO (default NightVibes33/Filza-27)
#      with an asset ending in .ipa
#   4. $PINNED_BASE_IPA (last-resort fallback)
#
# Environment:
#   BASE_IPA_REPO         repo to query            (default NightVibes33/Filza-27)
#   EXPECTED_BUNDLE_ID    bundle id the base must have
#                         (default com.apple.mobile.MobileHouseArrest, matching
#                          build_release_ipa.sh)
#   BASE_IPA_UNSIGN=1     strip _CodeSignature / embedded.mobileprovision in place
#                         if the downloaded base turns out to be signed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_IPA_REPO="${BASE_IPA_REPO:-NightVibes33/Filza-27}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.apple.mobile.MobileHouseArrest}"
EXPECTED_MINIMUM_OS="${EXPECTED_MINIMUM_OS:-17.0}"
BASE_IPA_UNSIGN="${BASE_IPA_UNSIGN:-0}"

PRINT_ONLY=0
if [ "${1:-}" = "--print-url" ]; then
  PRINT_ONLY=1
  shift
fi

# The runners ship python3; some local hosts only expose `python`. Probe rather
# than assume, so the resolver fails with a clear reason instead of a 404-ish
# "could not resolve" message.
if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1 && python -c 'pass' >/dev/null 2>&1; then
  PYTHON=python
else
  echo "no usable python interpreter (tried python3, python)" >&2
  exit 69
fi

OUTPUT="${1:-}"
EXPLICIT_URL="${2:-${BASE_IPA_URL:-}}"

resolve_from_github() {
  "$PYTHON" - "$BASE_IPA_REPO" <<'PY'
import json, sys, urllib.request

repo = sys.argv[1]
url = f"https://api.github.com/repos/{repo}/releases?per_page=30"
request = urllib.request.Request(url, headers={
    "User-Agent": "fetch-base-ipa",
    "Accept": "application/vnd.github+json",
})
try:
    releases = json.load(urllib.request.urlopen(request, timeout=30))
except Exception as error:  # noqa: BLE001 - reported by the caller
    print(f"github api error: {error}", file=sys.stderr)
    sys.exit(4)

if not isinstance(releases, list):
    print("github api returned an unexpected payload", file=sys.stderr)
    sys.exit(4)

# Newest first: the API already orders by creation date descending.
for release in releases:
    if release.get("draft"):
        continue
    for asset in release.get("assets") or []:
        name = (asset.get("name") or "").lower()
        if name.endswith(".ipa") and asset.get("state") == "uploaded":
            sys.stderr.write(
                f"resolved from release {release.get('tag_name')}: {asset.get('name')}\n")
            print(asset["browser_download_url"])
            digest = asset.get("digest") or ""
            print(f"sha256={digest.replace('sha256:', '')}")
            sys.exit(0)
sys.exit(3)
PY
}

URL=""
EXPECTED_SHA256="${BASE_IPA_SHA256:-}"
SOURCE=""
if [ -n "$EXPLICIT_URL" ]; then
  URL="$EXPLICIT_URL"; SOURCE="caller"
else
  if RESOLVED="$(resolve_from_github 2>/tmp/fetch-base-ipa-api.log)"; then
    URL="$(printf '%s\n' "$RESOLVED" | sed -n '1p')"
    API_SHA="$(printf '%s\n' "$RESOLVED" | sed -n '2p' | sed 's/^sha256=//')"
    if [ -z "$EXPECTED_SHA256" ] && [ -n "$API_SHA" ]; then
      EXPECTED_SHA256="$API_SHA"
    fi
    SOURCE="github-api"
    cat /tmp/fetch-base-ipa-api.log >&2 || true
  else
    cat /tmp/fetch-base-ipa-api.log >&2 || true
    if [ -n "${PINNED_BASE_IPA:-}" ]; then
      URL="$PINNED_BASE_IPA"; SOURCE="pinned-fallback"
    fi
  fi
fi

if [ -z "$URL" ]; then
  echo "could not resolve a base IPA:" >&2
  echo "  * no url argument and no BASE_IPA_URL is set" >&2
  echo "  * $BASE_IPA_REPO has no non-draft release with a .ipa asset" >&2
  echo "  * no PINNED_BASE_IPA fallback is configured" >&2
  echo "  fix: pass the URL explicitly, e.g. base_ipa_url=<your unsigned Filza IPA>" >&2
  exit 66
fi

echo "base IPA source : $SOURCE"
echo "base IPA URL    : $URL"

if [ "$PRINT_ONLY" = "1" ]; then
  exit 0
fi

[ -n "$OUTPUT" ] || { echo "usage: $0 <output.ipa> [<url>]" >&2; exit 64; }

curl -fL --retry 3 --retry-delay 5 -o "$OUTPUT" "$URL"
[ -s "$OUTPUT" ] || { echo "downloaded base IPA is empty" >&2; exit 66; }

# When the URL came from the GitHub API, its published digest is enforced, so a
# truncated or swapped artifact is caught here instead of inside the build.
# The hash is computed with the interpreter on purpose: MSYS/Git-Bash sha256sum
# prefixes the digest with a "\" binary-mode marker, which would fail the
# comparison on an otherwise perfect download.
EXPECTED_SHA256="${EXPECTED_SHA256:-}"
actual_sha256() {
  "$PYTHON" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

if [ -n "$EXPECTED_SHA256" ]; then
  ACTUAL_SHA="$(actual_sha256 "$OUTPUT")"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA256" ]; then
    echo "base IPA sha256 mismatch" >&2
    echo "  expected $EXPECTED_SHA256" >&2
    echo "  actual   $ACTUAL_SHA" >&2
    exit 67
  fi
  echo "sha256 verified : $ACTUAL_SHA"
fi

# --- validate before the long build ----------------------------------------
"$PYTHON" - "$OUTPUT" "$EXPECTED_BUNDLE_ID" "$EXPECTED_MINIMUM_OS" "$BASE_IPA_UNSIGN" <<'PY'
import hashlib
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
expected_bundle = sys.argv[2]
expected_min_os = sys.argv[3]
unsign = sys.argv[4] == "1"

if not zipfile.is_zipfile(ipa):
    sys.exit(f"base IPA is not a zip archive: {ipa}")

with zipfile.ZipFile(ipa) as archive:
    names = archive.namelist()
    apps = sorted({name.split("Payload/", 1)[1].split("/", 1)[0]
                   for name in names
                   if name.startswith("Payload/") and "/" in name[len("Payload/"):]})
    if len(apps) != 1:
        sys.exit(f"expected exactly one app under Payload/, found {apps}")

    app_prefix = f"Payload/{apps[0]}"
    info_entry = f"{app_prefix}/Info.plist"
    if info_entry not in names:
        sys.exit(f"base IPA has no {info_entry}")

    info = plistlib.loads(archive.read(info_entry))
    bundle_id = info.get("CFBundleIdentifier")
    minimum_os = info.get("MinimumOSVersion")

    signed = any(name.startswith(f"{app_prefix}/_CodeSignature/") for name in names)
    provisioned = f"{app_prefix}/embedded.mobileprovision" in names

print(f"app bundle      : {apps[0]}")
print(f"bundle id       : {bundle_id}")
print(f"minimum OS      : {minimum_os}")
print(f"signed          : {'yes' if signed else 'no'}"
      f"{' (embedded.mobileprovision present)' if provisioned else ''}")

if bundle_id != expected_bundle:
    sys.exit(f"base IPA bundle id is {bundle_id!r}, expected {expected_bundle!r} "
             "(build_release_ipa.sh injects into the MobileHouseArrest shell)")

if not signed and not provisioned:
    print("base IPA is unsigned: OK")
    sys.exit(0)

if not unsign:
    sys.exit("base IPA is signed; re-run with BASE_IPA_UNSIGN=1 to strip the signature, "
             "or pass an unsigned base IPA via base_ipa_url")

# Strip the signature in place so codesign -d fails on the staged app, which is
# what build_release_ipa.sh requires from an unsigned base.
import tempfile
staging = Path(tempfile.mkdtemp(prefix="base-ipa-unsign-"))
with zipfile.ZipFile(ipa) as archive:
    archive.extractall(staging)
app_dir = staging / app_prefix
shutil.rmtree(app_dir / "_CodeSignature", ignore_errors=True)
(app_dir / "embedded.mobileprovision").unlink(missing_ok=True)

rebuilt = ipa.with_suffix(".unsigned.ipa")
with zipfile.ZipFile(rebuilt, "w", zipfile.ZIP_DEFLATED) as out:
    for path in sorted((staging / "Payload").rglob("*")):
        if path.is_file():
            out.write(path, str(path.relative_to(staging)))
shutil.rmtree(staging, ignore_errors=True)
rebuilt.replace(ipa)
print("signature stripped: base IPA is now unsigned")
PY

echo "sha256          : $(actual_sha256 "$OUTPUT")"
ls -l "$OUTPUT"
