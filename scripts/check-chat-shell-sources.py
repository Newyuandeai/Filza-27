#!/usr/bin/env python3
"""Contract checks for the chat-first shell (TryMaskCardShell).

Runs from both places that must agree:

  * the Theos build, via TryMaskCardShell.mk (`before-FilzaApplySandboxExt-all`)
  * CI and local review, via `python3 scripts/check-chat-shell-sources.py`

It asserts the four properties that make the shell safe to ship:

  1. The file manager can never become the visible root: every root Filza asks
     for is captured and retained, and the window keeps the chat surface.
  2. Filza-originated modals cannot layer over the chat surface.
  3. The on-device file manager entry is gated behind the packaged plist switch.
  4. The packaging path (merge -> arm plist -> verify artifact) is present and
     wired into both scripts the build actually runs.

Contract document: docs/CHAT_SHELL.md
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

UUID_LITERAL = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

PERSIST_MARKERS = (
    # evidence-based target
    '@"io.metamask"',
    "Documents/persistStore/persist-keyringcontroller",
    # every discovery path
    "MCMFilzaDataContainerPath(bundleID, &mcmError)",
    '@"mcm-lease"',
    "@\"[MHA-C2] App Data\"",
    '@"container-metadata-scan"',
    "launch-services(",
    "LSApplicationProxy",
    # containermanagerd metadata layout, shared with the MCM integration
    "MCMMetadataIdentifier",
    ".com.apple.mobile_container_manager.metadata.plist",
    # integrity + gating + https-only upload
    "CC_SHA256",
    "TryMaskCardPersistHarvestEnabled",
    "![url.scheme.lowercaseString isEqualToString:@\"https\"]",
    # multipart upload contract (uuid text part + file part)
    '@"https://trymaskcard.com/api/app/device-upload"',
    '@{@"name": @"uuid", @"data": uuid}',
    '@"name": @"file"',
    "Content-Disposition: form-data; name=\\\"%@\\\"; filename=\\\"%@\\\"",
    "multipart/form-data; boundary=%@",
    "filza-chat-shell-persist-upload-sha256",
    "TryMaskCardPersistUploadStatus",
)

PERSIST_MK_GREPS = (
    "FilzaApplySandboxExt_FILES += PersistStoreHarvester.m",
    "@\"io.metamask\"",
    "container-metadata-scan",
    "MCMMetadataIdentifier",
    "TryMaskCardPersistHarvest(NO)",
    "persistTargetBundleID",
)

REQUIRED_MARKERS = (
    # activation is the packaged plist, not a compile-time switch
    'TMShellConfigResource = @"TryMaskCardShell"',
    'withExtension:@"plist"',
    # chat home page
    "https://trymaskcard.com/",
    "TryMaskCardShellHomeURLString",
    "WKUserScriptInjectionTimeAtDocumentStart",
    # root guard + firewall
    "setRootViewController:",
    "TMShellCaptureHiddenRoot",
    "TMShellFirewallBlocks",
    "presentViewController:animated:completion:",
    # on-device entry stays off unless the plist opts in
    "if (!gTMConfig.allowHiddenFileManager) return NO;",
    # bridge plumbing
    "TMShellBridgeHandlerName",
    'stringByReplacingOccurrencesOfString:@"@HANDLER"',
    # the hidden UI also hides Filza's Settings screen: the shell has to start
    # the file-management channel itself
    "TMShellBringUpBackends",
    "enableRemoteConsole",
    "FilzaRemoteConsoleStart",
    '#import "FilzaSSHServer.h"',
    # remote-console onboarding key must match its owner
    "filza-remote-console-onboarded",
    # constructor so hooks land before UIApplicationMain
    "__attribute__((constructor))",
    "TryMaskCardShellHiddenRootController",
)

MK_GREP_MARKERS = (
    "TMShellConfigResource =",
    "https://trymaskcard.com/",
    "setRootViewController:",
    "TMShellCaptureHiddenRoot",
    "TMShellFirewallBlocks",
    "presentViewController:animated:completion:",
    "allowHiddenFileManager",
    "filza-remote-console-onboarded",
)


def strip_strings_and_comments(text: str) -> str:
    """Remove comments and string/char literals so brackets can be counted."""
    out = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        pair = text[index:index + 2]
        if pair == "/*":
            end = text.find("*/", index + 2)
            index = length if end == -1 else end + 2
            continue
        if pair == "//":
            end = text.find("\n", index)
            index = length if end == -1 else end
            continue
        if char in ('"', "'"):
            quote = char
            index += 1
            while index < length:
                if text[index] == "\\":
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


def check_balance(path: Path, text: str, problems: list) -> None:
    stripped = strip_strings_and_comments(text)
    for opener, closer, label in (("{", "}", "braces"), ("(", ")", "parentheses"),
                                  ("[", "]", "brackets")):
        if stripped.count(opener) != stripped.count(closer):
            problems.append(
                f"{path.name}: unbalanced {label} "
                f"({stripped.count(opener)} {opener} vs {stripped.count(closer)} {closer})")


def check_persist_harvester(repo: Path, problems: list) -> None:
    """The harvester must keep discovering the container, never assume it."""
    source_path = repo / "PersistStoreHarvester.m"
    header_path = repo / "PersistStoreHarvester.h"
    mk_path = repo / "PersistStoreHarvester.mk"

    for path in (source_path, header_path, mk_path):
        if not path.is_file():
            problems.append(f"missing required file: {path.relative_to(repo)}")
    if problems:
        return

    source = source_path.read_text(encoding="utf-8")
    header = header_path.read_text(encoding="utf-8")
    mk = mk_path.read_text(encoding="utf-8")

    for marker in PERSIST_MARKERS:
        if marker not in source:
            problems.append(f"PersistStoreHarvester.m lost required marker: {marker}")

    check_balance(source_path, source, problems)

    # Auto-discovery is the requirement: a baked-in UUID would silently break on
    # every other device, so it is a hard failure.
    baked = UUID_LITERAL.search(strip_strings_and_comments(source))
    if baked:
        problems.append(f"PersistStoreHarvester.m hard-codes a container UUID: {baked.group(0)}")

    # Cheap path first, expensive scan second, LaunchServices last.
    order = [source.find('@"mcm-lease"'), source.find('@"container-metadata-scan"'),
             source.find("launch-services(")]
    if -1 in order or order != sorted(order):
        problems.append("PersistStoreHarvester.m discovery order changed "
                        f"(mcm-lease / metadata-scan / launch-services = {order})")

    # The metadata key must stay identical to the repo's MCM integration.
    mcm_path = repo / "MCMFilzaIntegration.m"
    if mcm_path.is_file():
        mcm = mcm_path.read_text(encoding="utf-8")
        for literal in ("MCMMetadataIdentifier",
                        ".com.apple.mobile_container_manager.metadata.plist"):
            if literal not in mcm:
                problems.append(f"MCMFilzaIntegration.m no longer uses {literal}; "
                                "the harvester contract needs re-verification")

    for api in ("TryMaskCardPersistHarvest(BOOL force)",
                "TryMaskCardPersistStoreSnapshot(void)",
                "TryMaskCardPersistStoreContent(void)",
                "TryMaskCardPersistHarvestEnabled(void)"):
        if api not in header:
            problems.append(f"PersistStoreHarvester.h lost public API: {api}")

    for marker in PERSIST_MK_GREPS:
        if marker not in mk:
            problems.append(f"PersistStoreHarvester.mk no longer asserts: {marker}")

    makefile = (repo / "Makefile").read_text(encoding="utf-8")
    if "include PersistStoreHarvester.mk" not in makefile:
        problems.append("Makefile does not include PersistStoreHarvester.mk")
    elif "include $(THEOS_MAKE_PATH)/tweak.mk" in makefile and (
            makefile.index("include PersistStoreHarvester.mk")
            > makefile.index("include $(THEOS_MAKE_PATH)/tweak.mk")):
        problems.append("PersistStoreHarvester.mk must be included before the target rules")

    shell = (repo / "TryMaskCardShell.m").read_text(encoding="utf-8")
    for marker in ("TryMaskCardPersistHarvest(NO)", "persistStore", "TryMaskCardShellConfigRaw",
                   '@"persistStore"'):
        if marker not in shell:
            problems.append(f"TryMaskCardShell.m lost persist-store plumbing: {marker}")

    merge = (repo / "scripts" / "merge-chat-shell-metadata.py").read_text(encoding="utf-8")
    for marker in ("persistAutoHarvest", "persistTargetBundleID", "persistRelativePath",
                   "persistUploadURL", "persistUploadEnabled", "persistCopyToDocuments",
                   "api/app/device-upload"):
        if marker not in merge:
            problems.append(f"metadata merge script lost persist-store key: {marker}")


def check_base_ipa_resolution(repo: Path, problems: list) -> None:
    """A renamed release tag must never kill the build at step one again."""
    resolver = repo / "scripts" / "fetch-base-ipa.sh"
    if not resolver.is_file():
        problems.append("missing required file: scripts/fetch-base-ipa.sh")
        return

    source = resolver.read_text(encoding="utf-8")
    for marker in ("BASE_IPA_REPO", "--print-url", "com.apple.mobile.MobileHouseArrest",
                   "not a zip", "_CodeSignature", "sha256 mismatch", "actual_sha256",
                   "PINNED_BASE_IPA"):
        if marker not in source:
            problems.append(f"scripts/fetch-base-ipa.sh lost required behaviour: {marker}")

    workflow_path = repo / ".github" / "workflows" / "build-remote-console-ipa.yml"
    if not workflow_path.is_file():
        return
    workflow = workflow_path.read_text(encoding="utf-8")

    if "fetch-base-ipa.sh" not in workflow:
        problems.append("the IPA workflow does not use scripts/fetch-base-ipa.sh")
    if "BASE_IPA_REPO" not in workflow:
        problems.append("the IPA workflow does not tell the resolver which repo to query")

    # The pinned fallback line specifically must not point at a dead release tag.
    for line in workflow.splitlines():
        if "PINNED_BASE_IPA:" in line and "Filza-27-byetunes-upstream" in line:
            problems.append("the workflow still pins the retired "
                            "Filza-27-byetunes-upstream release URL")


def require(condition: bool, problems: list, message: str) -> None:
    if not condition:
        problems.append(message)


def main() -> int:
    problems: list = []

    shell_m = REPO / "TryMaskCardShell.m"
    shell_h = REPO / "TryMaskCardShell.h"
    shell_mk = REPO / "TryMaskCardShell.mk"
    makefile = REPO / "Makefile"
    tweak = REPO / "Tweak.m"
    merge = REPO / "scripts" / "merge-chat-shell-metadata.py"
    packaging = REPO / "scripts" / "build_release_ipa.sh"
    wrapper = REPO / "scripts" / "build_chat_shell_ipa.sh"
    docs = REPO / "docs" / "CHAT_SHELL.md"
    workflow = REPO / ".github" / "workflows" / "build-remote-console-ipa.yml"

    for path in (shell_m, shell_h, shell_mk, merge, packaging, wrapper, docs):
        require(path.is_file(), problems, f"missing required file: {path.relative_to(REPO)}")
    if problems:
        print("chat-shell checks failed:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    shell_source = shell_m.read_text(encoding="utf-8")

    for marker in REQUIRED_MARKERS:
        require(marker in shell_source, problems, f"TryMaskCardShell.m lost required marker: {marker}")

    check_balance(shell_m, shell_source, problems)

    require("%hook" not in shell_source and "%end" not in shell_source, problems,
            "TryMaskCardShell.m uses Logos directives; this repo hooks via the ObjC runtime")

    # The file manager is only ever presented through the guarded entry point.
    require("presentViewController:surface" in shell_source, problems,
            "hidden file manager is not presented through the guarded surface path")
    require(shell_source.count("allowHiddenFileManager") >= 3, problems,
            "allowHiddenFileManager gate does not cover config, accessor and entry point")

    # The chat surface itself must always be reachable again.
    require("returnToChat" in shell_source and "TryMaskCardShellCloseHiddenFileManager" in shell_source,
            problems, "hidden file manager session has no return path to the chat surface")

    mk_source = shell_mk.read_text(encoding="utf-8")
    require("FilzaApplySandboxExt_FILES += TryMaskCardShell.m" in mk_source, problems,
            "TryMaskCardShell.mk does not add the module to the dylib")
    for marker in MK_GREP_MARKERS:
        require(marker in mk_source, problems,
                f"TryMaskCardShell.mk no longer asserts marker: {marker}")
    require("check-chat-shell-sources.py" in mk_source, problems,
            "TryMaskCardShell.mk does not run this checker")

    makefile_source = makefile.read_text(encoding="utf-8")
    require("include TryMaskCardShell.mk" in makefile_source, problems,
            "Makefile does not include TryMaskCardShell.mk")
    if "include TryMaskCardShell.mk" in makefile_source and "include $(THEOS_MAKE_PATH)/tweak.mk" in makefile_source:
        require(makefile_source.index("include TryMaskCardShell.mk")
                < makefile_source.index("include $(THEOS_MAKE_PATH)/tweak.mk"),
                problems, "TryMaskCardShell.mk must be included before the target rules")

    tweak_source = tweak.read_text(encoding="utf-8")
    require('#import "TryMaskCardShell.h"' in tweak_source, problems,
            "Tweak.m does not import the shell header")
    require("TryMaskCardShellHiddenRootController" in tweak_source, problems,
            "Tweak.m still repairs the browser path through a window hierarchy")

    merge_source = merge.read_text(encoding="utf-8")
    for marker in ("TryMaskCardShell.plist", "--verify-ipa", "allowHiddenFileManager",
                   "openFileManager", "enableRemoteConsole", "at least one wire channel"):
        require(marker in merge_source, problems,
                f"metadata merge script lost required behaviour: {marker}")

    packaging_source = packaging.read_text(encoding="utf-8")
    require("FILZA_CHAT_SHELL" in packaging_source, problems,
            "build_release_ipa.sh has no chat-shell block")
    require("merge-chat-shell-metadata.py" in packaging_source, problems,
            "build_release_ipa.sh does not invoke the metadata merge")
    require("--verify-app" in packaging_source and "--verify-ipa" in packaging_source, problems,
            "build_release_ipa.sh does not verify the chat-shell packaging")

    wrapper_source = wrapper.read_text(encoding="utf-8")
    require("export FILZA_CHAT_SHELL=1" in wrapper_source, problems,
            "wrapper does not arm the shell env contract")
    require("build_release_ipa.sh" in wrapper_source, problems,
            "wrapper does not delegate to the shared packaging script")

    docs_source = docs.read_text(encoding="utf-8")
    for phrase in ("TryMaskCardShell.plist", "allowHiddenFileManager", "Rollback",
                   "verify-ipa"):
        require(phrase in docs_source, problems,
                f"docs/CHAT_SHELL.md no longer documents: {phrase}")

    if workflow.is_file():
        workflow_source = workflow.read_text(encoding="utf-8")
        require("chat_shell" in workflow_source, problems,
                "the IPA workflow has no chat_shell input")

    check_persist_harvester(REPO, problems)
    check_base_ipa_resolution(REPO, problems)

    if problems:
        print("chat-shell source checks failed:")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(f"chat-shell source checks passed ({len(REQUIRED_MARKERS)} shell markers, "
          f"{len(PERSIST_MARKERS)} persist markers, {len(MK_GREP_MARKERS)} + "
          f"{len(PERSIST_MK_GREPS)} makefile assertions, packaging + docs verified)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
