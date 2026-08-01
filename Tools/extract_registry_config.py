#!/usr/bin/env python3
"""Extract Presidio's default recognizer registry configuration.

`AnalyzerEngine()` does not load every predefined recognizer. It loads the
ones listed in `presidio_analyzer/conf/default_recognizers.yaml`, and most of
the country-specific ones carry `enabled: false` -- 17 recognizers out of 88
in a default engine. Without this file a port that loads its whole catalogue
reports entities Presidio never would, which reads as a pile of false
positives rather than as a configuration difference.

The YAML is read with PyYAML here rather than parsed in Swift: the shipped
artifact is the resolved default configuration, so the package needs no YAML
dependency to reproduce Presidio's defaults. Loading a *user's* YAML at
runtime is a separate feature.

Usage:
    python3 Tools/extract_registry_config.py --presidio <checkout> \\
        --out Sources/PresidioEngine/Resources/registry_config.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys

CONF = os.path.join(
    "presidio-analyzer", "presidio_analyzer", "conf", "default_recognizers.yaml"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--presidio", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    try:
        import yaml
    except ImportError:
        print("error: PyYAML is required to read the upstream config", file=sys.stderr)
        return 2

    path = os.path.join(args.presidio, CONF)
    with open(path, encoding="utf-8") as fh:
        conf = yaml.safe_load(fh)

    entries = []
    for raw in conf.get("recognizers", []):
        # An entry may be a bare name string rather than a mapping.
        if isinstance(raw, str):
            entries.append({
                "name": raw, "class_name": raw, "type": "predefined",
                "enabled": True, "languages": [{"language": "en", "context": None}],
                "country_code": None, "score_thresholds": {},
            })
            continue

        name = raw.get("name")
        # `supported_languages` is either a list of language codes or a list of
        # mappings carrying a per-language context override.
        languages = []
        for entry in raw.get("supported_languages", ["en"]):
            if isinstance(entry, str):
                languages.append({"language": entry, "context": None})
            else:
                languages.append({
                    "language": entry.get("language"),
                    "context": entry.get("context"),
                })

        entries.append({
            "name": name,
            # `class_name` lets a config give a recognizer a display name that
            # differs from its class.
            "class_name": raw.get("class_name", name),
            # Upstream's `_split_recognizers`: an entry is *custom* unless it
            # says `type: predefined`. A bare string entry is predefined.
            "type": raw.get("type", "custom"),
            "enabled": bool(raw.get("enabled", True)),
            "languages": languages,
            "country_code": raw.get("country_code"),
            "score_thresholds": raw.get("score_thresholds") or {},
            "supported_entity": raw.get("supported_entity"),
            "supported_entities": raw.get("supported_entities"),
        })

    payload = {
        "schema_version": 1,
        "source": "presidio_analyzer/conf/default_recognizers.yaml",
        "supported_languages": conf.get("supported_languages", ["en"]),
        "global_regex_flags": conf.get("global_regex_flags"),
        "recognizers": entries,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    enabled = [e for e in entries if e["enabled"]]
    en_enabled = [
        e for e in enabled
        if any(lang["language"] == "en" for lang in e["languages"])
    ]
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  {len(entries)} entries, {len(enabled)} enabled, {len(en_enabled)} for 'en'")
    print(f"  global_regex_flags {payload['global_regex_flags']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
