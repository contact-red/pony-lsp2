#!/usr/bin/env python3
"""Extract the inline Pony sources from ponyc's unit tests.

Each TEST_F block in test/libponyc/*.cc holds a Pony program and a macro
saying whether ponyc accepts or rejects it. This writes each one out as a
package directory and prints a manifest of what verdict is expected.

Usage: extract_corpus.py <ponyc-checkout> <output-dir> [suite...]
"""

import os
import re
import sys

# The macros that state a verdict, and what they expect.
ACCEPT = {"TEST_COMPILE"}
REJECT = {
    "TEST_ERROR",
    "TEST_ERRORS_1",
    "TEST_ERRORS_2",
    "TEST_ERRORS_3",
    "TEST_ERROR_WITH_NOTE",
}

# A block using any of these needs more than one source file, a replaced
# builtin, or an AST comparison; none of that is a plain accept/reject.
SKIP_CALLS = re.compile(
    r"\b(add_package|add_package_path|set_builtin|test_equiv|TEST_EQUIV|"
    r"default_package_name|test_compile_resume|TEST_COMPILE_RESUME)\b"
)

STRING_PIECE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def unescape(text):
    return (
        text.replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace('\\"', '"')
        .replace("\\\\", "\\")
    )


def blocks(text):
    """Yield (test_name, body) for each TEST_F in a file."""
    for m in re.finditer(r"TEST_F\(\s*\w+\s*,\s*(\w+)\s*\)\s*\{", text):
        depth = 1
        i = m.end()

        while i < len(text) and depth > 0:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1

        yield m.group(1), text[m.end() : i - 1]


def sources(body):
    """The `const char* name = "..." ...;` definitions in a block."""
    out = {}

    for m in re.finditer(r'const\s+char\*\s+(\w+)\s*=\s*((?:\s*"(?:[^"\\]|\\.)*")+)\s*;', body):
        pieces = STRING_PIECE.findall(m.group(2))
        out[m.group(1)] = unescape("".join(pieces))

    return out


def verdict(body):
    """The expected verdict, the source variable, and ponyc's first message."""
    for m in re.finditer(r"\b(TEST_\w+)\s*\(\s*(\w+)([^;]*)", body):
        macro, var, rest = m.group(1), m.group(2), m.group(3)

        if macro in ACCEPT:
            return "accept", var, ""

        if macro in REJECT:
            msgs = STRING_PIECE.findall(rest)
            return "reject", var, unescape(msgs[0]) if msgs else ""

    return None, None, ""


def pass_of(text, macro):
    """The compiler pass a file's macro runs to."""
    m = re.search(
        r"#define\s+%s\(src\)\s+DO\(test_compile\(src,\s*\"(\w+)\"\)\)" % macro, text
    )
    return m.group(1) if m else "?"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    ponyc, out_dir = sys.argv[1], sys.argv[2]
    suites = sys.argv[3:]
    test_dir = os.path.join(ponyc, "test", "libponyc")
    manifest = []
    skipped = 0

    for name in sorted(os.listdir(test_dir)):
        if not name.endswith(".cc"):
            continue

        suite = name[:-3]

        if suites and suite not in suites:
            continue

        text = open(os.path.join(test_dir, name), encoding="utf8").read()
        suite_pass = pass_of(text, "TEST_COMPILE")

        for test, body in blocks(text):
            if SKIP_CALLS.search(body):
                skipped += 1
                continue

            expect, var, message = verdict(body)

            if expect is None:
                continue

            srcs = sources(body)

            if var not in srcs:
                skipped += 1
                continue

            case = os.path.join(out_dir, suite, test)
            os.makedirs(case, exist_ok=True)

            with open(os.path.join(case, "main.pony"), "w", encoding="utf8") as f:
                f.write(srcs[var])

            manifest.append((suite, test, expect, suite_pass, case, message))

    with open(os.path.join(out_dir, "manifest.tsv"), "w", encoding="utf8") as f:
        for row in manifest:
            f.write("\t".join(row) + "\n")

    print(f"{len(manifest)} cases extracted, {skipped} skipped as not a plain verdict")
    return 0


if __name__ == "__main__":
    sys.exit(main())
