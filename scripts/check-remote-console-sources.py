#!/usr/bin/env python3
"""Source-level checks for the FilzaRemote console module.

These catch error classes that only the iOS compiler would otherwise surface late
in a 20-minute CI run:

1. C / Objective-C keywords used as identifiers. `BOOL inline = ...;` produced
   "expected identifier or '('" plus a second, confusing downstream error.
2. A block capturing an `NSError **` / `NSString **` out-parameter, which Theos
   promotes to an error via -Wblock-capture-autoreleasing.

Usage: python3 scripts/check-remote-console-sources.py [repo-root]
Exit code 1 lists every problem found.
"""
from __future__ import annotations

import pathlib
import re
import sys

FILES = [
    "FilzaRemoteConsole.m",
    "FilzaRemoteConsoleAPI.m",
    "FilzaRemoteConsoleFileOps.m",
    "FilzaRemoteConsolePreferences.m",
    "FilzaRemoteConsole.h",
    "FilzaRemoteConsoleInternal.h",
]

C_KEYWORDS = {
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
    "int", "long", "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
    "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary",
    "bool", "true", "false", "class", "template", "new", "delete", "this",
    "namespace", "operator", "private", "public", "protected", "virtual",
}

TYPE_TOKENS = (
    "BOOL", "int", "long", "short", "char", "float", "double", "unsigned",
    "signed", "void", "id", "Class", "SEL", "IMP", "size_t", "ssize_t",
    "unichar", "NSInteger", "NSUInteger", "CGFloat", "NSRange",
    "NSString", "NSMutableString", "NSData", "NSMutableData", "NSArray",
    "NSMutableArray", "NSDictionary", "NSMutableDictionary", "NSError",
    "NSNumber", "NSDate", "NSURL", "NSFileHandle", "NSTimeZone", "NSCalendar",
    "NSDateComponents", "NSBundle", "NSUserDefaults", "NSFileManager",
    "UIWindow", "UIViewController", "UIAlertController", "UISwitch",
    "UITableViewCell", "UIPasteboard", "UIScene", "GCDWebServer",
    "GCDWebServerResponse", "GCDWebServerRequest", "GCDWebServerDataResponse",
    "GCDWebServerFileResponse", "GCDWebServerStreamedResponse",
    "dispatch_queue_t", "dispatch_semaphore_t", "uint8_t", "uint16_t",
    "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t",
    "uintptr_t", "NSStringEncoding", "NSComparisonResult", "JSONValue",
)

MODIFIERS = ("static", "const", "extern", "__block", "__weak", "__strong",
             "__unsafe_unretained", "__autoreleasing", "volatile")

# Words that, when captured as the "name", mean the regex split a multi-word type
# (`unsigned long long x`, `(unsigned long)y`) rather than found an identifier.
TYPE_WORDS = {
    "long", "short", "int", "char", "float", "double", "signed", "unsigned",
    "void", "const", "volatile", "static", "extern", "struct", "union", "enum",
    "BOOL", "id", "Class", "SEL", "IMP",
}

DECLARATION = re.compile(
    r"(?:^|[;{(\s,])(?P<mods>(?:" + "|".join(MODIFIERS) + r")\s+)*"
    r"(?P<type>" + "|".join(sorted(TYPE_TOKENS, key=len, reverse=True)) + r")"
    r"\s*(?P<stars>\*{0,2})\s*"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?P<after>[=;,)\]])",
    re.MULTILINE,
)

BLOCK_START = re.compile(r"\^\s*[\{\(]")
OUT_PARAM = re.compile(r"\bNSError\s*\*\s*\*|\bNSString\s*\*\s*\*")

# A line that is only an opening brace, preceded by something that looks like a
# function signature, inside another function body, is a nested function
# definition (a GNU extension clang rejects in C mode).
SIGNATURE_LINE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\s*\([^;{}]*\)\s*$")
CONTROL_KEYWORDS = ("if", "for", "while", "switch", "else", "do", "@", "^",
                    "dispatch_", "sizeof", "return")


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def mask_comments_and_strings(text: str) -> str:
    """Blanks comments and string literals so they cannot produce false hits."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j == -1 else j + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def check_file(path: pathlib.Path) -> list[str]:
    problems: list[str] = []
    raw = path.read_text(encoding="utf-8-sig", errors="replace")
    text = mask_comments_and_strings(raw)

    for match in DECLARATION.finditer(text):
        name = match.group("name")
        if name in TYPE_WORDS:
            continue
        if name in C_KEYWORDS:
            problems.append(
                f"{path.name}:{line_of(text, match.start('name'))}: "
                f"C keyword '{name}' used as an identifier"
            )

    # Blocks that reference an out-parameter of the enclosing function.
    for match in OUT_PARAM.finditer(text):
        # The out-parameter appears in the signature, so the function body starts
        # *after* it. A ';' before the brace means this is only a prototype.
        open_index = text.find("{", match.end())
        if open_index == -1 or ";" in text[match.end():open_index]:
            continue
        depth = 0
        end = open_index
        for index in range(open_index, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index
                    break
        body = text[open_index:end + 1]
        if BLOCK_START.search(body):
            problems.append(
                f"{path.name}:{line_of(text, match.start())}: out-parameter near a "
                f"block literal; a block capturing NSError**/NSString** fails "
                f"-Wblock-capture-autoreleasing (use a static helper instead)"
            )

    # Nested function definitions.
    depth = 0
    previous_code_line = ""
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped == "{" and depth > 0:
            signature = previous_code_line.strip()
            if (SIGNATURE_LINE.search(signature)
                    and not signature.startswith(CONTROL_KEYWORDS)
                    and "^" not in signature
                    and "@" not in signature):
                problems.append(
                    f"{path.name}:{number}: nested function definition "
                    f"('{signature[:60]}'); move it to file scope"
                )
        if stripped:
            if not stripped.startswith(("//", "/*", "*")):
                previous_code_line = stripped
        depth += line.count("{") - line.count("}")
        if depth < 0:
            depth = 0
    return problems


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    missing = [name for name in FILES if not (root / name).exists()]
    if missing:
        print(f"check-remote-console-sources: missing files: {', '.join(missing)}")
        return 1

    problems: list[str] = []
    for name in FILES:
        problems.extend(check_file(root / name))

    if problems:
        print("check-remote-console-sources: problems found")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"check-remote-console-sources: OK ({len(FILES)} files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
