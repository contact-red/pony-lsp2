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


def macro_defs(text):
    """Each verdict macro's parameter names and embedded pass, from its
    #define.

    Three shapes exist in the suites. A one-argument define embeds the pass
    in its body (`#define TEST_ERROR(src) DO(test_error(src, "flatten"))`).
    A define whose second parameter is named `pass` takes it per call
    (`#define TEST_COMPILE(src, pass) ...`). Any other extra parameter is a
    message, never a pass -- `TEST_ERROR(src, err)` exists -- which is why
    the parameter *names* are read rather than the arity.
    """
    defs = {}
    for m in re.finditer(
        r"#define\s+(TEST_\w+)\s*\(([^)]*)\)((?:[^\n]*\\\n)*[^\n]*)",
        text,
    ):
        name = m.group(1)
        params = [x.strip() for x in m.group(2).split(",") if x.strip()]
        # The pass is the string literal handed to the test_* helper in the
        # body, wherever the continuation lines put it.
        body_pass = re.search(
            r"test_\w+\(src,\s*\"(\w+)\"", m.group(3)
        )
        defs[name] = (params, body_pass.group(1) if body_pass else None)
    return defs


def case_pass(macro, rest, defs):
    """The pass one macro invocation runs to, or "?" when unrecoverable."""
    params, embedded = defs.get(macro, ([], None))
    if len(params) >= 2 and params[1] == "pass":
        m = STRING_PIECE.search(rest)
        return m.group(1) if m else "?"
    return embedded or "?"


def fixtures(body):
    """The fixture packages a block builds and registers as magic paths.

    The shape is `write_fixture(var, names, contents)` with two parallel
    string arrays, then `package_add_magic_path("name", var, ...)`. The
    files are returned per magic name so the extractor can write them as
    a package directory beside the case's main.pony, where the bare
    locator resolves the way the magic path did in the harness.
    """
    arrays = {}
    for m in re.finditer(
        r"const\s+char\*\s+(\w+)\[\]\s*=\s*\{(.*?)\};", body, re.S
    ):
        entries = []
        piece = None
        for tok in re.finditer(r'"(?:[^"\\]|\\.)*"|,|NULL', m.group(2)):
            t = tok.group(0)
            if t == ",":
                if piece is not None:
                    entries.append(piece)
                    piece = None
            elif t == "NULL":
                piece = None
            else:
                piece = (piece or "") + unescape(t[1:-1])
        if piece is not None:
            entries.append(piece)
        arrays[m.group(1)] = entries

    out = {}
    if "names" in arrays and "contents" in arrays:
        files = list(zip(arrays["names"], arrays["contents"]))
        for m in re.finditer(
            r'package_add_magic_path\(\s*"((?:[^"\\]|\\.)*)"', body
        ):
            out[unescape(m.group(1))] = files
    return out


def verdict(body, defs):
    """The expected verdict, source variable, pass, and ponyc's message."""
    for m in re.finditer(r"\b(TEST_\w+)\s*\(\s*(\w+)([^;]*)", body):
        macro, var, rest = m.group(1), m.group(2), m.group(3)

        if macro in ACCEPT:
            return "accept", var, case_pass(macro, rest, defs), ""

        if macro in REJECT:
            params, _ = defs.get(macro, ([], None))
            msgs = STRING_PIECE.findall(rest)
            # When the define takes the pass per call it is the first
            # string; the expected message, if any, follows it.
            if len(params) >= 2 and params[1] == "pass":
                message = unescape(msgs[1]) if len(msgs) > 1 else ""
            else:
                message = unescape(msgs[0]) if msgs else ""
            return "reject", var, case_pass(macro, rest, defs), message

    return None, None, "?", ""


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
        defs = macro_defs(text)

        for test, body in blocks(text):
            if SKIP_CALLS.search(body):
                skipped += 1
                continue

            expect, var, case_target, message = verdict(body, defs)

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

            for magic, files in fixtures(body).items():
                pkg = os.path.join(case, magic)
                os.makedirs(pkg, exist_ok=True)
                for fname, content in files:
                    with open(os.path.join(pkg, fname), "w",
                              encoding="utf8") as f:
                        f.write(content)

            manifest.append((suite, test, expect, case_target, case, message))

    with open(os.path.join(out_dir, "manifest.tsv"), "w", encoding="utf8") as f:
        for row in manifest:
            f.write("\t".join(row) + "\n")

    print(f"{len(manifest)} cases extracted, {skipped} skipped as not a plain verdict")
    return 0


if __name__ == "__main__":
    sys.exit(main())
