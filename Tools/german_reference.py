#!/usr/bin/env python3
"""Generate the German differential corpora from `de_core_news_sm`.

Same method as the English ones: give spaCy the raw text, record what it
produced, and let the Swift side try to reproduce it from the same input. What
is compared is tokens with offsets and NORMs, fine-grained tags, coarse POS,
lemmas, and entity spans.

The corpus has two halves, for two different reasons.

**Harvested from spaCy's own German test suite.** Those files are where the
tokenizer's edge cases already live -- guillemets, `»Was ist mit mir
geschehen?«`, 40-character compounds, hyphenated Kraftfahrzeug-
Haftpflichtversicherung -- and the people who wrote them knew which cases were
sharp. Extracted by AST rather than regex so it survives reformatting.

**Written for this port.** German prose containing the things a PII pipeline
actually meets: names with titles, cities, companies with legal forms, dates in
German order, ordinals, currency with comma decimals, abbreviations that end in
a period without ending a sentence. The tokenizer treats `z.B.` and `Dr.` as
exceptions, and getting that wrong shifts every offset after it.

The text is an *input*, not an assertion: it does not need to be interesting
German, it needs to be German that both implementations see identically.

    python3 Tools/german_reference.py \\
        --python <venv python with spacy + de_core_news_sm> \\
        --out Tests/PresidioConformance/Fixtures/de_gold.json
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys

# --- The written half -------------------------------------------------------
# Kept here rather than in a data file so that regenerating the corpus is one
# command, and so the reason each group exists can be written next to it.

PROSE = [
    # Names, titles, and the abbreviation-period problem.
    "Dr. Anna Müller arbeitet seit 2019 bei der Siemens AG in München.",
    "Herr Schmidt und Frau Dr. Weber haben den Vertrag am 3. März unterschrieben.",
    "Prof. Dr. Hans-Jürgen Schäfer lehrt an der Universität Heidelberg.",
    "Der Patient, Herr Klaus Böhm, wurde am 14.02.1978 in Dresden geboren.",
    "Frau Özdemir leitet die Abteilung seit dem 1. Januar.",
    "Sehr geehrte Frau Dr. Krüger, vielen Dank für Ihre Nachricht vom 12. Mai.",
    # Organisations and legal forms.
    "Die Deutsche Bahn AG betreibt den Fernverkehr zwischen Hamburg und Berlin.",
    "Die Müller & Söhne GmbH & Co. KG hat ihren Sitz in Stuttgart.",
    "Volkswagen, BMW und Daimler sind in Wolfsburg, München bzw. Stuttgart ansässig.",
    "Das Bundesamt für Sicherheit in der Informationstechnik warnt vor der Lücke.",
    # Places.
    "Von Köln nach Düsseldorf fährt man etwa 40 Minuten.",
    "Die Zugspitze liegt an der Grenze zwischen Bayern und Tirol.",
    "Er zog von Leipzig über Frankfurt am Main nach Zürich.",
    "Das Treffen findet in Sankt Augustin bei Bonn statt.",
    # Contact details, which is what the recognizers are for.
    "Sie erreichen mich unter anna.mueller@example.de oder +49 30 901820.",
    "Meine Telefonnummer lautet 089 12345678, mobil 0170 1234567.",
    "Die Rechnung geht an buchhaltung@beispiel-firma.de.",
    "Bitte überweisen Sie auf DE89 3704 0044 0532 0130 00.",
    "Die Steuer-ID lautet 65929970489 und die Steuernummer 181/815/08155.",
    "Der Server ist unter 192.168.0.14 erreichbar, die Doku unter https://intern.example.de/hilfe.",
    # Dates, numbers, currency, ordinals -- all tokenizer-sensitive.
    "Am 31.12.2023 um 23:59 Uhr endete die Frist.",
    "Der Betrag von 1.234,56 EUR wurde am 5. Juni gebucht.",
    "Im 3. Quartal stieg der Umsatz um 12,5 Prozent.",
    "Die Sitzung dauerte von 9.30 bis 17.00 Uhr.",
    "Er wurde am 2. Oktober 1990 geboren, also kurz vor der Wiedervereinigung.",
    # Abbreviations that do not end a sentence.
    "Das gilt z.B. für Verträge, die vor 2020 geschlossen wurden.",
    "Bitte bringen Sie Ihren Ausweis, Ihre Karte usw. mit.",
    "Die Adresse lautet Hauptstr. 12, 10115 Berlin.",
    "Vgl. dazu Nr. 4 der Anlage bzw. § 12 Abs. 3 BGB.",
    "Die Lieferung erfolgt ca. 3 Werktage nach Zahlungseingang.",
    # Compounds, umlauts, ß, hyphenation.
    "Die Rindfleischetikettierungsüberwachungsaufgabenübertragungsgesetz-Debatte war lang.",
    "Der Straßenbahnhaltestellenfahrplan hängt am Bahnhof.",
    "Die Kraftfahrzeug-Haftpflichtversicherung ist gesetzlich vorgeschrieben.",
    "Größere Maßnahmen müssen schriftlich beschlossen werden.",
    "Süß-sauer schmeckt die Soße überraschend gut.",
    # Quotation styles German actually uses.
    "»Wer hat das entschieden?«, fragte sie.",
    "„Das war nicht abgesprochen“, sagte der Abteilungsleiter.",
    'Er nannte es ein "Missverständnis" und ging.',
    # Sentence shapes that stress the sentence-independent tokenizer.
    "Und dann? Nichts.",
    "Ja!!! Wirklich???",
    "Er sagte: Das ist erledigt.",
    "(Siehe Anhang.) Weitere Angaben folgen.",
    "E-Mail, Telefon o. Ä. sind anzugeben.",
]


CHILD = r"""
import json, sys
import spacy

texts = json.loads(sys.argv[1])
model = sys.argv[2]

nlp = spacy.load(model)

cases = []
for text in texts:
    doc = nlp(text)
    cases.append({
        "text": text,
        "tokens": [
            {"text": t.text, "offset": t.idx, "norm": t.norm_,
             "tag": t.tag_, "pos": t.pos_, "lemma": t.lemma_}
            for t in doc
        ],
        "entities": [
            {"label": e.label_, "start": e.start_char, "end": e.end_char,
             "text": e.text}
            for e in doc.ents
        ],
    })

meta = nlp.meta
json.dump({
    "model": f"{meta['lang']}_{meta['name']}-{meta['version']}",
    "spacy_version": spacy.__version__,
    "cases": cases,
}, sys.stdout, ensure_ascii=False)
"""


def harvest_spacy_tests(python: str) -> list[str]:
    """Pull every string literal out of spaCy's German language tests.

    By AST, so a reformat or a new parametrize case is picked up without
    touching this script. Literals that are obviously not German text -- import
    fragments, single characters, fixture names -- are dropped by length.
    """
    finder = (
        "import os, spacy.tests.lang.de as m; "
        "print(os.path.dirname(m.__file__))"
    )
    proc = subprocess.run([python, "-c", finder], capture_output=True, text=True)
    if proc.returncode != 0:
        print("WARN: spaCy German tests not found; skipping harvest", file=sys.stderr)
        return []

    directory = proc.stdout.strip()
    texts: list[str] = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".py"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as fh:
            try:
                tree = ast.parse(fh.read())
            except SyntaxError:
                continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                value = node.value.strip()
                # Docstrings and fixture identifiers are not corpus material.
                if len(value) < 4 or "\n" in value and len(value) < 40:
                    continue
                if value.isidentifier():
                    continue
                texts.append(value)
    return texts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True, help="interpreter with spacy + the model")
    ap.add_argument("--model", default="de_core_news_sm")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    harvested = harvest_spacy_tests(args.python)
    # Deduplicate while keeping order, so the corpus is stable across runs.
    seen: set[str] = set()
    texts: list[str] = []
    for text in PROSE + harvested:
        if text not in seen:
            seen.add(text)
            texts.append(text)

    proc = subprocess.run(
        [args.python, "-c", CHILD, json.dumps(texts), args.model],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        return proc.returncode

    payload = json.loads(proc.stdout)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    tokens = sum(len(c["tokens"]) for c in payload["cases"])
    entities = sum(len(c["entities"]) for c in payload["cases"])
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  model      {payload['model']} (spaCy {payload['spacy_version']})")
    print(f"  texts      {len(payload['cases'])} "
          f"({len(PROSE)} written, {len(texts) - len(PROSE)} harvested)")
    print(f"  tokens     {tokens}")
    print(f"  entities   {entities}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
