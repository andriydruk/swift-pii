#!/usr/bin/env python3
"""Record what Python's `re` does with inline flag groups.

Inline flags were the one piece of regex syntax this engine parsed and then
silently ignored, so the expectations here are taken from Python rather than
written by hand — a hand-written expectation would only record what I believed,
which is exactly what was wrong.

Two behaviours are worth pinning:

* `(?i)` is **global**. Python applies it to the entire pattern no matter where
  it appears, so `\\b(?i)abc` is case-insensitive including the `\\b` before it.
  Presidio's `ItDriverLicenseRecognizer` has its group at position 2 and relies
  on this. (3.11 deprecated the non-leading form and 3.12 rejects it; the
  patterns this port must read predate that.)
* `(?i:...)` and `(?-i:...)` are **scoped**, and the negated form has to narrow
  a pattern compiled case-insensitively — which is the case a single "ignore
  case?" boolean could not express.

    python3 Tools/inline_flag_reference.py \\
        --out Tests/PresidioConformance/Fixtures/inline_flag_cases.json
"""

import argparse
import json
import re
import sys
import warnings

# (pattern, default flags applied by the caller, texts)
#
# The default-flag column matters: Presidio compiles every pattern with
# IGNORECASE|MULTILINE|DOTALL, so the interesting cases are the ones where an
# inline group has to *disagree* with that.
CASES = [
    # Global, leading and non-leading.
    (r"(?i)abc", 0, ["abc", "ABC", "AbC", "xabc"]),
    (r"\b(?i)abc", 0, ["abc", "ABC", "x abc"]),
    (r"a(?i)bc", 0, ["abc", "aBC", "ABC"]),
    (r"(?i)[a-z]+", 0, ["ABC", "abc", "AbC"]),
    # Scoped.
    (r"(?i:abc)def", 0, ["abcdef", "ABCdef", "abcDEF", "ABCDEF"]),
    (r"abc(?i:def)", 0, ["abcdef", "abcDEF", "ABCdef"]),
    (r"(?i:a)(?i:b)c", 0, ["abc", "ABc", "ABC"]),
    # Scoped negation against a case-insensitive default -- the case that
    # cannot be expressed by widening alone.
    (r"(?-i:abc)", re.IGNORECASE, ["abc", "ABC"]),
    (r"(?-i:abc)def", re.IGNORECASE, ["abcdef", "abcDEF", "ABCdef"]),
    (r"x(?-i:Y)z", re.IGNORECASE, ["xYz", "XYZ", "xyz", "XYz"]),
    # dotAll, set and cleared.
    (r"(?s)a.b", 0, ["a\nb", "axb"]),
    (r"(?s:a.b)", 0, ["a\nb", "axb"]),
    (r"(?-s:a.b)", re.DOTALL, ["a\nb", "axb"]),
    (r"a(?-s:.)b", re.DOTALL, ["a\nb", "axb"]),
    # Multiline, global only.
    (r"(?m)^b", 0, ["a\nb", "b"]),
    # Combined, and the Unicode flag that is a no-op in Python 3.
    (r"(?iu)Saint-Louis", 0, ["Saint-Louis", "saint-louis", "SAINT-LOUIS"]),
    (r"(?is)a.B", 0, ["a\nb", "A\nB", "axb"]),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    out = []
    with warnings.catch_warnings():
        # The non-leading global form is deprecated, not broken; that is the
        # behaviour being recorded.
        warnings.simplefilter("ignore", DeprecationWarning)
        for pattern, flags, texts in CASES:
            compiled = re.compile(pattern, flags)
            out.append({
                "pattern": pattern,
                "ignore_case": bool(flags & re.IGNORECASE),
                "dot_all": bool(flags & re.DOTALL),
                "multiline": bool(flags & re.MULTILINE),
                "texts": [
                    {"text": text,
                     "spans": [[m.start(), m.end()] for m in compiled.finditer(text)]}
                    for text in texts
                ],
            })

    payload = {"python_version": sys.version.split()[0], "cases": out}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    total = sum(len(c["texts"]) for c in out)
    print(f"wrote {args.out}: {len(out)} patterns, {total} texts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
