#!/usr/bin/env python3
"""Extract spaCy's reserved string-store symbols.

`StringStore` normally hashes a string with MurmurHash64A, but a fixed table of
457 symbols has small integer ids instead. Word shapes hit this immediately:
the shape of a single capital letter is "X", which is the UPOS symbol with id
101, not a hash. Getting it wrong silently mis-embeds every one-letter
capitalised token.

Others are ordinary English words -- the dependency labels include `case`,
`mark`, `conj`, `root`, `det` -- so any of them appearing as a token's NORM
would hash wrongly too.

Usage:
    python3 Tools/extract_symbols.py --python <venv python> \\
        --out Sources/PresidioNLP/Resources/spacy_symbols.json
"""

from __future__ import annotations

import argparse, json, os, subprocess, sys

CHILD = "import json,sys;from spacy.symbols import IDS;json.dump({k:int(v) for k,v in IDS.items()},sys.stdout)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run([args.python, "-c", CHILD], capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-2000:], file=sys.stderr)
        return 2

    symbols = json.loads(proc.stdout)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"schema_version": 1, "symbols": symbols}, fh, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {args.out}: {len(symbols)} symbols")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
