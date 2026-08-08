#!/usr/bin/env python3
"""Record spaCy's dependency parse for the English NER corpus.

The port already reproduces spaCy's NER exactly *without* the parser. The
residual divergence is entirely sentence boundaries: spaCy refuses to open or
extend an entity when the next token starts a sentence, and those boundaries
come from the parser. So the parser is the last component between this port and
exact parity, and this is its differential corpus.

The texts are the same 2,000 the NER corpus uses, so a parser regression and an
NER regression are measured over identical input and can be attributed.

Recorded per text: `heads` as **absolute token indices**, `deps`, and
`sent_starts` as the token indices that begin a sentence. Heads and labels are
what the parser predicts; `sent_starts` is what NER actually consumes, and it is
derived from the heads rather than predicted directly -- it is the left edge of
every subtree whose root is its own head. Recording all three means a divergence
can be localised to the transitions, the deprojectivisation, or the edge
computation, instead of just "the boundaries are wrong".

Token texts and offsets are deliberately *not* recorded. The tokenizer corpus
already asserts them exhaustively over this same input, and repeating them here
quadrupled the file for no additional signal; a token-count mismatch is enough
to detect misalignment, and the tokenizer suite says what caused it.

    python3 Tools/parser_reference.py \\
        --python .venv/bin/python \\
        --out Tests/PresidioConformance/Fixtures/parser_gold_sm.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEXTS = os.path.join(
    HERE, "..", "Tests", "PresidioConformance", "Fixtures", "ner_gold_sm.json"
)

# Runs inside the venv that has spaCy, so it cannot import anything from here.
CHILD = r'''
import json
import sys

import spacy

texts = json.load(sys.stdin)
nlp = spacy.load("en_core_web_sm")

cases = []
for text in texts:
    doc = nlp(text)
    cases.append({
        "text": text,
        "heads": [token.head.i for token in doc],
        "deps": [token.dep_ for token in doc],
        "sent_starts": [token.i for token in doc if token.is_sent_start],
    })

meta = nlp.meta
json.dump(
    {
        "model": f"{meta['lang']}_{meta['name']}-{meta['version']}",
        "spacy_version": spacy.__version__,
        "cases": cases,
    },
    sys.stdout,
    ensure_ascii=False,
)
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--python",
        default=".venv/bin/python",
        help="interpreter with spacy and en_core_web_sm installed",
    )
    parser.add_argument(
        "--texts",
        default=DEFAULT_TEXTS,
        help="corpus to parse; the NER gold file, so both are measured on the same input",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    with open(args.texts, encoding="utf-8") as handle:
        texts = [case["text"] for case in json.load(handle)["cases"]]

    result = subprocess.run(
        [args.python, "-c", CHILD],
        input=json.dumps(texts),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        return result.returncode

    gold = json.loads(result.stdout)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(gold, handle, ensure_ascii=False)
        handle.write("\n")

    sentences = sum(len(case["sent_starts"]) for case in gold["cases"])
    tokens = sum(len(case["heads"]) for case in gold["cases"])
    print(
        f"{args.out}: {len(gold['cases'])} texts, {tokens} tokens, "
        f"{sentences} sentences, from {gold['model']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
