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

import importlib.util
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
    # activation must be enforced, not assumed: the shipped failure mode is "the
    # file manager is visible instead of the chat surface"
    "TMShellAssertRootSchedule",
    "TMShellWatchdogTick",
    "TMShellApplicationDidFinishLaunchingOptions",
    "TMShellInstallDidFinishLaunchingHook",
    # a shell build must be armed by construction rather than by a metadata file,
    # and it must leave a readable trace where the device can actually be checked
    "FILZA_CHAT_SHELL_FORCE",
    "chat-shell-forced-by-build",
    "TryMaskCardShell-Status.txt",
    "TMShellWriteStatus",
    "TMShellDefaultConfig",
    # the device is not inspectable from here, so crashes have to be delivered and
    # the page must be able to pull the same evidence
    "TMShellReportPreviousCrash",
    "TMShellCrashArtifacts",
    "TMShellOwnContainerUUID",
    "TMShellDiagnosticsPayload",
    "TryMaskCardUploadArtifact",
    "TMShellUploadProbe",
    "shell-hello.txt",
    # the firewall is opt-in and scoped to Filza's classes; dropping system or
    # WebKit presentations is how you break a framework, not how you hide a UI
    "TMShellIsFilzaController",
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


def strip_objc_for_scan(text: str) -> str:
    """Drop comments and literals, keeping line structure intact."""
    out = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        pair = text[index:index + 2]
        if pair == "/*":
            end = text.find("*/", index + 2)
            if end == -1:
                index = length
            else:
                out.append("\n" * text.count("\n", index, end))
                index = end + 2
            continue
        if pair == "//":
            end = text.find("\n", index)
            index = length if end == -1 else end
            continue
        if char in ('"', "'"):
            quote = char
            out.append(" ")
            index += 1
            while index < length:
                if text[index] == "\\":
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                if text[index] == "\n":
                    out.append("\n")
                index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


# Apple renamed WKWebView's UI-delegate property to `UIDelegate` in the iOS 26
# SDK (iPhoneOS26.2.sdk WKWebView.h:98). A direct property reference only
# compiles against one SDK spelling, so both setters must be resolved at runtime.
DRIFT_SENSITIVE_PROPERTIES = (".uiDelegate", ".UIDelegate")

# symbol -> header that must be imported by any file using it.
REQUIRED_IMPORTS = {
    "objc_msgSend": "objc/message.h",
    "class_getInstanceMethod": "objc/runtime.h",
    "method_setImplementation": "objc/runtime.h",
    "class_replaceMethod": "objc/runtime.h",
    "class_addMethod": "objc/runtime.h",
    "object_getClass": "objc/runtime.h",
    "CC_SHA256": "CommonCrypto/CommonDigest.h",
}


def check_objc_hygiene(repo: Path, problems: list) -> None:
    """Catch the cheap-to-find, expensive-to-hit ObjC mistakes before compiling."""
    for name in ("TryMaskCardShell.m", "PersistStoreHarvester.m"):
        path = repo / name
        if not path.is_file():
            continue
        raw = path.read_text(encoding="utf-8")
        source = strip_objc_for_scan(raw)
        lines = source.splitlines()

        # 1. SDK-drift sensitive property assignments
        for prop in DRIFT_SENSITIVE_PROPERTIES:
            if re.search(re.escape(prop) + r"\s*=", source):
                problems.append(
                    f"{name}: assigns {prop} directly; that spelling is SDK-specific "
                    "(use the runtime UI-delegate attach helper)")

        # 2. runtime/Crypto symbols must have their declaring header imported
        imported = set(re.findall(r'#(?:import|include)\s+[<"]([^">]+)[">]', raw))
        for symbol, header in REQUIRED_IMPORTS.items():
            if re.search(r"\b" + re.escape(symbol) + r"\b", source) and header not in imported:
                problems.append(f"{name}: uses {symbol} without importing {header}")

        # 3. static functions and globals must be defined before their first use
        definitions = {}
        for index, line in enumerate(lines, 1):
            match = re.match(
                r"\s*static\s+[A-Za-z_][A-Za-z0-9_ \t*<>:,]*?\**\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(",
                line)
            if match and match.group(1) not in ("if", "while", "for", "switch", "return",
                                                "sizeof"):
                definitions.setdefault(match.group(1), index)
            elif re.match(r"\s*static\s+[A-Za-z_][A-Za-z0-9_ \t*<>:,]*?\**\s*([gk][A-Z][A-Za-z0-9_]*)\s*[=;]",
                          line):
                definitions.setdefault(re.match(
                    r"\s*static\s+[A-Za-z_][A-Za-z0-9_ \t*<>:,]*?\**\s*([gk][A-Z][A-Za-z0-9_]*)\s*[=;]",
                    line).group(1), index)

        for symbol, defined_at in definitions.items():
            for index, line in enumerate(lines, 1):
                if index == defined_at:
                    continue
                if re.search(r"\b" + re.escape(symbol) + r"\b", line):
                    if index < defined_at:
                        problems.append(
                            f"{name}:{index} uses {symbol} before its definition at line "
                            f"{defined_at}")
                    break

        # 4. `error:&variable` requires an NSError*: this tree builds with
        #    -Wno-incompatible-pointer-types, so passing an NSString* there stays
        #    silent until someone touches .localizedDescription on it.
        declarations = {}
        for index, line in enumerate(lines, 1):
            declaration = re.match(
                r"\s*(?:__block\s+|const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\**\s*"
                r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:=[^;]*)?;", line)
            if declaration:
                declarations[declaration.group(2)] = (index, declaration.group(1))
        for index, line in enumerate(lines, 1):
            for match in re.finditer(r"error\s*:\s*&\s*([A-Za-z_][A-Za-z0-9_]*)", line):
                variable = match.group(1)
                declared = declarations.get(variable)
                if not declared:
                    continue
                if declared[1] == "NSError":
                    continue
                problems.append(
                    f"{name}:{index} passes {variable} (declared as {declared[1]} * at line "
                    f"{declared[0]}) to an NSError** parameter; this tree disables "
                    "-Wincompatible-pointer-types so it would only fail later")

        # 5. This SDK defines IMP as the strictly typed `void (*)(void)`
        #    (OBJC_OLD_DISPATCH_PROTOTYPES == 0), so calling one directly with real
        #    arguments is an arity error ("expected 0, have N"). Every call site
        #    must cast to an explicit function-pointer type first.
        for imp_var in set(re.findall(r"static\s+IMP\s+([A-Za-z_][A-Za-z0-9_]*)\s*=", source)):
            for index, line in enumerate(lines, 1):
                for match in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(imp_var) + r"\s*\(",
                                         line):
                    if line[:match.start()].rstrip().endswith(")"):
                        continue  # already cast: ((ret (*)(args))var)(...)
                    problems.append(
                        f"{name}:{index} calls {imp_var}() without a cast; IMP is "
                        "void(*)(void) in this SDK, so the call must be cast to an "
                        "explicit function-pointer type")


def strip_shell_comments(text: str) -> str:
    """Return shell code with full-line and whitespace-prefixed inline comments removed."""
    kept = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        marker = re.search(r"\s#", line)
        if marker:
            line = line[:marker.start()]
        kept.append(line)
    return "\n".join(kept)


def check_verifier_marker_anchoring(repo: Path, problems: list) -> None:
    """Every byte marker the verifier demands must be anchored in the source.

    A string literal that only exists inside a configuration branch can be
    eliminated from the optimized dylib - with -DFILZA_CHAT_SHELL_FORCE=1 the
    non-forced branch is dead, and demanding a literal from it failed a build that
    was actually correct. So each marker must be either an Objective-C class name
    or an entry in the `used` marker table.
    """
    merge_path = repo / "scripts" / "merge-chat-shell-metadata.py"
    shell_path = repo / "TryMaskCardShell.m"
    if not merge_path.is_file() or not shell_path.is_file():
        return

    # Import the merge script and read its real tuple. Parsing the source text
    # instead silently missed every entry that is a constant name rather than a
    # literal - i.e. exactly the markers that matter most.
    try:
        spec = importlib.util.spec_from_file_location("chat_shell_metadata", merge_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        markers = list(module.DYLIB_MARKERS)
    except Exception as error:  # noqa: BLE001 - reported below
        problems.append(f"could not read DYLIB_MARKERS from the merge script: {error}")
        return

    shell_source = shell_path.read_text(encoding="utf-8")

    table = re.search(r"TMShellArtifactMarkers\[\]\s*=\s*\{(.*?)\}", shell_source, re.S)
    anchored = set(re.findall(r'"([^"]+)"', table.group(1))) if table else set()
    if not table:
        problems.append("TryMaskCardShell.m has no TMShellArtifactMarkers table")
    elif "__attribute__((used))" not in shell_source:
        problems.append("TMShellArtifactMarkers must carry __attribute__((used)) so the "
                        "optimiser cannot drop the markers")

    class_names = set(re.findall(r"@(?:interface|implementation)\s+([A-Za-z_][A-Za-z0-9_]*)",
                                 shell_source))

    for marker in markers:
        if marker in anchored or marker in class_names:
            continue
        # a plain literal that also happens to be a declared constant is not
        # enough: it must be in the used table or be a class name
        problems.append(
            f"verifier marker {marker!r} is not anchored in TryMaskCardShell.m "
            "(add it to TMShellArtifactMarkers or use a class name); an unanchored "
            "literal can be optimised out of a forced build")

    # The shell-side fast pre-check must look for the same set.
    packaging = (repo / "scripts" / "build_release_ipa.sh").read_text(encoding="utf-8")
    loop = re.search(r"for marker in(.*?); do", packaging, re.S)
    if not loop:
        problems.append("build_release_ipa.sh has no marker loop")
        return
    checked = set(re.findall(r"[A-Za-z0-9_.:\-/]+", loop.group(1)))
    for marker in markers:
        if marker not in checked:
            problems.append(f"build_release_ipa.sh does not pre-check verifier marker "
                            f"{marker!r}")


def iter_method_bodies(source: str):
    """Yield (header, body) for every Objective-C method implementation.

    Uses brace matching rather than a regex, because bodies contain nested blocks
    and the first match would otherwise be the wrong one.
    """
    lines = source.splitlines()
    index = 0
    while index < len(lines):
        if lines[index].lstrip().startswith(("- (", "+ (")):
            header = []
            while index < len(lines) and "{" not in lines[index]:
                header.append(lines[index])
                index += 1
            if index >= len(lines):
                return
            header.append(lines[index].split("{")[0])
            depth = 0
            body = []
            while index < len(lines):
                depth += lines[index].count("{") - lines[index].count("}")
                body.append(lines[index])
                index += 1
                if depth <= 0:
                    break
            yield " ".join(header).strip(), "\n".join(body)
            continue
        index += 1


def check_webview_delegate_contract(repo: Path, problems: list) -> None:
    """Keep the WebKit callbacks safe to be called with an unverifiable ABI.

    Two failure modes are prevented here:

    * A delegate method whose name matches a protocol method but whose signature
      differs is still invoked by WebKit; the mismatched call crashes the process
      on the first interaction (a tap on any page control). Only methods whose
      signature we can be sure about may be implemented.
    * WebKit deadlocks the web content process when a decision/completion handler
      is never called, so every implemented callback must invoke its handler on
      every path.
    """
    shell_path = repo / "TryMaskCardShell.m"
    if not shell_path.is_file():
        return
    raw = shell_path.read_text(encoding="utf-8")
    source = strip_objc_for_scan(raw)

    # 1. ABI-uncertain delegate methods must not come back.
    forbidden = {
        "decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction\n"
        "                        preferences:": "the three-argument policy variant takes a block "
                                                   "whose ABI cannot be verified here; WebKit calls it "
                                                   "on every interaction",
        "resumingFromByteRange:": "the download-failure variant's exact name and arity are not "
                                  "verifiable in this tree",
    }
    for needle, why in forbidden.items():
        if needle in raw:
            problems.append(f"TryMaskCardShell.m implements {needle.split(':')[0]} - {why}")

    # 2. Every *Handler: parameter must be invoked inside its own method body.
    for header, body in iter_method_bodies(source):
        if "Handler:" not in header:
            continue
        names = re.findall(r"\)\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", header)
        handler = names[-1] if names else None
        if handler and not re.search(r"\b" + re.escape(handler) + r"\s*\(", body):
            problems.append(
                f"TryMaskCardShell.m: the callback taking {handler} never calls it; WebKit "
                "hangs the web content process when a decision handler is skipped")

    # 3. The real page bridge must be exception-guarded: every page control that
    #    calls into native lands there. The weak proxy in front of it is a pure
    #    forwarder and needs no guard of its own.
    found_bridge = False
    for header, body in iter_method_bodies(source):
        if "didReceiveScriptMessage:" not in header:
            continue
        if "handleBridgeMessage" not in body:
            continue
        found_bridge = True
        if "@try" not in body:
            problems.append("the script message handler is not wrapped in @try; an uncaught "
                            "exception in a WebKit callback is a hard crash")
        if "self.target" in body:
            problems.append("the guarded message handler must not be the forwarding proxy")
    if not found_bridge:
        problems.append("TryMaskCardShell.m no longer routes script messages through "
                        "handleBridgeMessage")


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

    # The firewall must stay opt-in and name-scoped: an unconditional drop of
    # presentations on the chat surface also drops UIKit's and WebKit's own.
    require('raw[@"suppressFilzaModals"], NO' in shell_source, problems,
            "the Filza modal firewall must default to off (suppressFilzaModals = NO)")
    require("TMShellIsFilzaController(presented)" in shell_source, problems,
            "the firewall must be scoped to Filza's own controller classes")

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
    # A non-empty test here would force the chat surface into the plain build too,
    # because the workflow passes "0" rather than unsetting the variable.
    shell_mk_source = shell_mk.read_text(encoding="utf-8")
    require("ifeq ($(strip $(FILZA_CHAT_SHELL)),1)" in shell_mk_source, problems,
            "TryMaskCardShell.mk must gate -DFILZA_CHAT_SHELL_FORCE on exactly 1, "
            "not on a non-empty value")
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
    packaging_code = strip_shell_comments(packaging_source)
    require("FILZA_CHAT_SHELL" in packaging_source, problems,
            "build_release_ipa.sh has no chat-shell block")
    require("merge-chat-shell-metadata.py" in packaging_source, problems,
            "build_release_ipa.sh does not invoke the metadata merge")
    require("--verify-app" in packaging_source and "--verify-ipa" in packaging_source, problems,
            "build_release_ipa.sh does not verify the chat-shell packaging")

    # Platform hazards that each cost a real CI round trip on macOS. These look at
    # code only: the script documents the hazards in comments beside the fix.
    #  * `strings ... | grep -Fq` kills the pipeline under `set -o pipefail`,
    #    because grep exits at the first match and strings dies flushing;
    #  * `mktemp -t name` means "template" on GNU hosts and "prefix" on BSD, so
    #    the explicit-template form is the only portable one;
    #  * an EXIT trap inside this block would replace the one that already cleans
    #    up the staged Payload directory.
    if re.search(r"strings[^|\n]*\|\s*grep", packaging_code):
        problems.append("build_release_ipa.sh pipes strings into grep; that fails macOS "
                        "builds under pipefail (use a temp file or a case match)")
    if "strings unavailable or failed" not in packaging_source:
        problems.append("build_release_ipa.sh lost the strings-unavailable fallback")
    if re.search(r"mktemp\s+-t\s", packaging_code):
        problems.append("build_release_ipa.sh uses `mktemp -t`; its semantics differ "
                        "between BSD and GNU hosts")
    if "trap - EXIT" in packaging_code or 'trap \'rm -f "$SHELL_STRINGS"\'' in packaging_code:
        problems.append("build_release_ipa.sh's chat-shell block installs an EXIT trap, "
                        "which would drop the stage-directory cleanup")

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
    check_objc_hygiene(REPO, problems)
    check_verifier_marker_anchoring(REPO, problems)
    check_webview_delegate_contract(REPO, problems)

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
