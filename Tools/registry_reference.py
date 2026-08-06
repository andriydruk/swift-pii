#!/usr/bin/env python3
"""Dump which recognizers upstream's registry loads, per language.

The registry is where "does this library support Spanish?" is actually decided,
and it is decided by a rule that is easy to get wrong: an entry in
`default_recognizers.yaml` that omits `supported_languages` is not English-only,
it is built **once per requested language**. Eleven of upstream's entries omit
it -- e-mail, IP, URL, IBAN, phone, credit-card-adjacent ones -- so reading that
key as "defaults to en" silently strips every language-agnostic recognizer from
every non-English engine.

This produces the differential corpus for that, exactly like the other
reference generators: run upstream's own loader and record what came out.

The NLP recognizer is deliberately excluded. Upstream's
`load_predefined_recognizers` appends it via `add_nlp_recognizer`; this port
adds `SpacyRecognizer` separately and explicitly, so including it here would
compare two different decisions.

    python3 Tools/registry_reference.py \\
        --python .venv/bin/python \\
        --out Tests/PresidioConformance/Fixtures/registry_gold.json
"""

import argparse
import json
import subprocess
import sys

# The languages this port targets. Upstream ships recognizers for only a few of
# them; the rest are here precisely to record that fact, because "zero
# country-specific recognizers" is a real answer that should be visible in a
# fixture rather than discovered later.
LANGUAGES = ["en", "ru", "de", "fr", "it", "ja", "uk", "es", "pt", "zh"]

SCRIPT = r"""
import json, sys
from presidio_analyzer.recognizer_registry.recognizers_loader_utils import (
    RecognizerConfigurationLoader, RecognizerListLoader,
)
import presidio_analyzer

languages = json.loads(sys.argv[1])
out = {"presidio_version": getattr(presidio_analyzer, "__version__", "unknown"),
       "languages": {}}

for language in languages:
    configuration = RecognizerConfigurationLoader.get(
        registry_configuration={"supported_languages": [language]}
    )
    recognizers = RecognizerListLoader.get(**configuration)
    rows = []
    for rec in recognizers:
        rows.append({
            "name": rec.name,
            "class": type(rec).__name__,
            "language": rec.supported_language,
            "entities": sorted(rec.supported_entities),
        })
    rows.sort(key=lambda r: (r["name"], r["language"]))
    out["languages"][language] = rows

json.dump(out, sys.stdout, indent=1, sort_keys=True, ensure_ascii=False)
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", required=True, help="interpreter with presidio-analyzer")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    proc = subprocess.run(
        [args.python, "-c", SCRIPT, json.dumps(LANGUAGES)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        return proc.returncode

    data = json.loads(proc.stdout)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True, ensure_ascii=False)
        fh.write("\n")

    for language, rows in sorted(data["languages"].items()):
        print(f"{language}: {len(rows)} recognizers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
