#!/usr/bin/env python3
"""Extract Presidio's per-country IBAN format regexes.

`iban_patterns.py` is a pure data module -- it builds ~110 country regexes by
concatenating shared fragments (CC, CK, A2, N4 ...), so it cannot be read with
`ast.literal_eval`. It imports nothing, so it is executed in an isolated
namespace instead.

The country regexes are what turn a checksum-valid string into a
format-validated IBAN, and they are also what distinguishes `.valid` from
`.unknown` in `IbanRecognizer.validate_result` -- so they are behaviour, not
decoration.

Usage:
    python3 Tools/extract_iban.py --presidio <checkout> \\
        --out Sources/PresidioRecognizers/Resources/iban_countries.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys

PATTERNS_PATH = os.path.join(
    "presidio-analyzer", "presidio_analyzer", "predefined_recognizers",
    "generic", "iban_patterns.py",
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--presidio", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    path = os.path.join(args.presidio, PATTERNS_PATH)
    if not os.path.isfile(path):
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    with open(path, encoding="utf-8") as fh:
        source = fh.read()

    # The module has no imports and no side effects; executing it is the only
    # way to resolve the fragment concatenation.
    namespace: dict[str, object] = {}
    exec(compile(source, path, "exec"), namespace)  # noqa: S102

    table = namespace.get("regex_per_country")
    if not isinstance(table, dict):
        print("error: regex_per_country not found or not a dict", file=sys.stderr)
        return 2

    payload = {
        "schema_version": 1,
        "source": {"file": PATTERNS_PATH},
        "bos": namespace.get("BOS", "^"),
        "eos": namespace.get("EOS", "$"),
        "note": (
            "Country regex is wrapped in BOS/EOS and matched with "
            "DOTALL|MULTILINE (no IGNORECASE) against the sanitized IBAN."
        ),
        "countries": {k: v for k, v in sorted(table.items())},
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  countries {len(table)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
