#!/usr/bin/env python3
"""Extract the lexical tables the context enhancer needs from spaCy.

`NlpArtifacts.set_keywords` filters lemmas by `is_stopword` and `is_punct`,
both of which are spaCy vocabulary attributes rather than anything Presidio
defines. Two facts, both verified against the loaded model rather than assumed:

- `is_stop` is membership in `spacy.lang.<lang>.stop_words.STOP_WORDS`, matched
  case-insensitively. All 326 entries were confirmed to round-trip through
  `nlp.vocab[w].is_stop`.
- `is_punct` is "every character is in Unicode category P*". Checked against
  the vocabulary over the ASCII punctuation and symbol range with no
  mismatches -- note this makes `$`, `+`, `<`, `=`, `>`, `^`, `|`, `~`
  *not* punctuation, since those are category S.

Only the stopword list is emitted; the punctuation rule is a rule, so it is
implemented directly rather than tabulated.

The language is a parameter. Stop words are the half of context scoring nobody
notices until they are missing: `LexicalTables.isStopWord` answered `false` for
every language but English, so a German context word that happens to be a stop
word was silently counted as evidence.

Usage:
    python3 Tools/extract_nlp_tables.py --python <venv python> \\
        --lang de --model de_core_news_sm \\
        --out Sources/PresidioEngine/Resources/de_lexical.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

CHILD = r'''
import importlib, json, sys, unicodedata
import spacy

model, lang = sys.argv[1], sys.argv[2]
STOP_WORDS = importlib.import_module(f"spacy.lang.{lang}.stop_words").STOP_WORDS

nlp = spacy.load(model)

# Confirm the two rules rather than trusting them.
unflagged = [w for w in STOP_WORDS if not nlp.vocab[w].is_stop]
probes = list("-.,:;!?()[]{}'\"/\\@#$%&*+<=>^_`|~") + ["--", "...", "->", "a.", "3"]
punct_mismatch = [
    p for p in probes
    if nlp.vocab[p].is_punct != all(unicodedata.category(c).startswith("P") for c in p)
]
case_mismatch = [
    w for w in list(STOP_WORDS)[:200]
    if nlp.vocab[w.upper()].is_stop != nlp.vocab[w].is_stop
]

json.dump({
    "spacy_version": spacy.__version__,
    "model": model,
    "language": lang,
    "stop_words": sorted(STOP_WORDS),
    "checks": {
        "stopwords_not_flagged": sorted(unflagged),
        "is_punct_rule_mismatches": sorted(punct_mismatch),
        "stopword_case_mismatches": sorted(case_mismatch),
    },
}, sys.stdout, ensure_ascii=False)
'''


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True)
    ap.add_argument("--model", default="en_core_web_lg")
    ap.add_argument("--lang", default="en", help="spaCy language code")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run(
        [args.python, "-c", CHILD, args.model, args.lang],
        capture_output=True, text=True
    )
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        return 2

    payload = json.loads(proc.stdout)
    checks = payload["checks"]
    # A failed check means the rule this port implements is wrong, so it must
    # stop the extraction rather than quietly shipping a bad table.
    for name, failures in checks.items():
        if failures:
            print(f"error: {name}: {failures[:10]}", file=sys.stderr)
            return 3

    payload["schema_version"] = 1
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  spaCy {payload['spacy_version']} / {payload['model']}")
    print(f"  {len(payload['stop_words'])} stop words; all rule checks clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
