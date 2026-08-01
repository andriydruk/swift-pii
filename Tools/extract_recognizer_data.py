#!/usr/bin/env python3
"""Extract the bulk data the last few recognizers need.

Five recognizers were blocked not on arithmetic but on data: a public suffix
list, India's RTO district tables, and a handful of alphabets and prefix sets.
This lifts all of it into JSON so the Swift side stays code-free.

The Public Suffix List is punycoded here rather than in Swift. The list stores
IDN suffixes in Unicode (`рф`), but the addresses being validated carry them in
A-label form (`xn--p1ai`), so 459 rules would otherwise never match. Doing the
conversion in Python keeps IDNA out of the Swift package entirely.

Usage:
    python3 Tools/extract_recognizer_data.py \\
        --presidio <checkout> --psl /tmp/public_suffix_list.dat \\
        --out Sources/PresidioRecognizers/Resources/recognizer_data.json
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import sys

INDIA = os.path.join(
    "presidio-analyzer", "presidio_analyzer", "predefined_recognizers",
    "country_specific", "india", "in_vehicle_registration_recognizer.py",
)


def class_constants(path: str, class_name: str) -> dict:
    """Class attributes of `class_name`, evaluated in source order.

    Handles three shapes beyond plain literals, all of which appear in the
    India recognizer and all of which `literal_eval` alone would miss:

      * `x |= y` at class scope. `two_factor_registration_prefix` starts as an
        empty set and is built up by five such unions — read naively it looks
        empty, which would make the entire district-map branch unreachable.
      * dict values that are *references* to other attributes, as in
        `state_rto_district_map`.
      * sets, which are emitted sorted so the output is deterministic.
    """
    tree = ast.parse(open(path, encoding="utf-8").read())
    raw: dict = {}

    for node in ast.walk(tree):
        if not isinstance(node, ast.ClassDef) or node.name != class_name:
            continue
        for statement in node.body:
            if isinstance(statement, ast.Assign):
                for target in statement.targets:
                    if not isinstance(target, ast.Name):
                        continue
                    value_node = statement.value
                    # `frozenset({...})` / `set({...})` are Calls, which
                    # literal_eval rejects. Unwrap to the literal inside.
                    if (isinstance(value_node, ast.Call)
                            and isinstance(value_node.func, ast.Name)
                            and value_node.func.id in ("frozenset", "set")
                            and value_node.args):
                        value_node = value_node.args[0]
                    try:
                        raw[target.id] = ast.literal_eval(value_node)
                    except (ValueError, SyntaxError):
                        # A dict of references, e.g. {"AN": in_vehicle_dist_an}.
                        if isinstance(value_node, ast.Dict):
                            refs = {}
                            for key, value in zip(
                                value_node.keys, value_node.values
                            ):
                                if isinstance(key, ast.Constant) and isinstance(value, ast.Name):
                                    refs[key.value] = ("__ref__", value.id)
                            if refs:
                                raw[target.id] = refs
            elif isinstance(statement, ast.AugAssign):
                if (isinstance(statement.target, ast.Name)
                        and isinstance(statement.op, ast.BitOr)
                        and isinstance(statement.value, ast.Name)):
                    left = raw.get(statement.target.id, set())
                    right = raw.get(statement.value.id, set())
                    raw[statement.target.id] = set(left) | set(right)

    def normalize(value):
        if isinstance(value, (set, frozenset)):
            return sorted(value)
        if isinstance(value, tuple):
            return list(value)
        if isinstance(value, dict):
            out = {}
            for key, item in value.items():
                if isinstance(item, tuple) and len(item) == 2 and item[0] == "__ref__":
                    out[key] = normalize(raw.get(item[1], []))
                else:
                    out[key] = normalize(item)
            return out
        return value

    return {key: normalize(value) for key, value in raw.items()}


def parse_psl(path: str) -> dict:
    """Split the PSL into normal, wildcard and exception rules, all punycoded."""
    normal: list[str] = []
    wildcard: list[str] = []
    exception: list[str] = []

    def punycode(rule: str) -> str | None:
        labels = []
        for label in rule.split("."):
            if any(ord(c) > 127 for c in label):
                try:
                    labels.append(label.encode("idna").decode())
                except Exception:  # noqa: BLE001
                    return None
            else:
                labels.append(label)
        return ".".join(labels)

    with open(path, encoding="utf-8") as fh:
        for line in fh:
            rule = line.strip()
            if not rule or rule.startswith("//"):
                continue
            if rule.startswith("!"):
                converted = punycode(rule[1:])
                if converted:
                    exception.append(converted)
            elif rule.startswith("*."):
                converted = punycode(rule[2:])
                if converted:
                    wildcard.append(converted)
            else:
                converted = punycode(rule)
                if converted:
                    normal.append(converted)
    return {
        "normal": sorted(set(normal)),
        "wildcard": sorted(set(wildcard)),
        "exception": sorted(set(exception)),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--presidio", required=True)
    ap.add_argument("--psl", required=True, help="public_suffix_list.dat")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    india_path = os.path.join(args.presidio, INDIA)
    if not os.path.isfile(india_path):
        print(f"error: {india_path} not found", file=sys.stderr)
        return 2

    india = class_constants(india_path, "InVehicleRegistrationRecognizer")
    state_map = india.get("state_rto_district_map", {})
    india_out = {
        "state_rto_district_map": state_map,
        "diplomatic_codes": india.get("in_vehicle_diplomatic_codes", []),
        "foreign_mission_codes": india.get("in_vehicle_foreign_mission_codes", []),
        "two_factor_registration_prefix": india.get("two_factor_registration_prefix", []),
    }

    def recognizer_path(*parts: str) -> str:
        return os.path.join(
            args.presidio, "presidio-analyzer", "presidio_analyzer",
            "predefined_recognizers", "country_specific", *parts,
        )

    payload = {
        "schema_version": 1,
        "public_suffix_list": parse_psl(args.psl),
        "india_vehicle": india_out,
        "sg_uen": class_constants(
            recognizer_path("singapore", "sg_uen_recognizer.py"), "SgUenRecognizer"
        ),
        "za_company": class_constants(
            recognizer_path("south_africa", "za_company_registration_recognizer.py"),
            "ZaCompanyRegistrationRecognizer",
        ),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
        fh.write("\n")

    psl = payload["public_suffix_list"]
    print(f"wrote {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"  PSL: {len(psl['normal'])} normal, {len(psl['wildcard'])} wildcard, "
          f"{len(psl['exception'])} exception")
    india_prefixes = payload["india_vehicle"]["two_factor_registration_prefix"]
    print(f"  India RTO states: {len(state_map)}, "
          f"registration prefixes: {len(india_prefixes)}")
    print(f"  SgUen constants: {len(payload['sg_uen'])}")
    print(f"  ZaCompany constants: {len(payload['za_company'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
