#!/usr/bin/env python3
"""Extract Presidio's recognizer definitions into data.

The port drives recognizers from JSON rather than transliterating 99 Python
classes into 99 Swift types. The LOC saving is secondary; the real payoff is
that tracking an upstream release becomes re-running this script instead of a
hand merge across 85 files.

Reads with ``ast`` only -- never imports Presidio.

Usage:
    python3 Tools/extract_patterns.py --presidio <checkout> \\
        --out Sources/PresidioRecognizers/Resources/recognizers.json
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys
from collections import Counter

RECOGNIZER_DIR = os.path.join(
    "presidio-analyzer", "presidio_analyzer", "predefined_recognizers"
)

# Regex constructs that behave differently between Python's `regex` module and
# ICU/PCRE2, or that a given backend cannot compile. Presence is recorded per
# pattern so the backend decision is driven by data rather than by recall.
FEATURE_PROBES = {
    "word_boundary": r"\b",
    "not_word_boundary": r"\B",
    "lookbehind_neg": "(?<!",
    "lookbehind_pos": "(?<=",
    "lookahead_neg": "(?!",
    "lookahead_pos": "(?=",
    "named_group": "(?P<",
    "atomic_group": "(?>",
    "inline_flags": "(?i",
    "unicode_property": r"\p{",
    "digit_class": r"\d",
    "word_class": r"\w",
    "space_class": r"\s",
    "anchor_start": "^",
    "anchor_end": "$",
}


def const_str(node: ast.AST, env: dict[str, str] | None = None) -> str | None:
    """Fold a node to a string, resolving class-level string constants.

    Several recognizers assemble their patterns from named parts rather than
    writing them out — UrlRecognizer concatenates a shared BASE_URL_REGEX,
    UsMbiRecognizer builds character classes with f-strings. Refusing to fold
    those left four recognizers unported for no reason other than how their
    source is spelled, so `env` carries the class-body string bindings and this
    resolves against it.

    Deliberately conservative: only string constants, names already bound in
    `env`, `+`, and f-strings whose every field folds. Anything else returns
    None and the recognizer is reported as needing a hand port, which is the
    same outcome as before.
    """
    env = env or {}
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return env.get(node.id)
    # `self.X` / `cls.X` inside a class body refer to the same bindings.
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        if node.value.id in ("self", "cls"):
            return env.get(node.attr)
        return None
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = const_str(node.left, env)
        right = const_str(node.right, env)
        return None if left is None or right is None else left + right
    if isinstance(node, ast.JoinedStr):
        parts = []
        for piece in node.values:
            if isinstance(piece, ast.Constant) and isinstance(piece.value, str):
                parts.append(piece.value)
            elif isinstance(piece, ast.FormattedValue):
                # A conversion or format spec would change the text; refuse
                # rather than guess.
                if piece.conversion not in (-1, None) or piece.format_spec is not None:
                    return None
                folded = const_str(piece.value, env)
                if folded is None:
                    return None
                parts.append(folded)
            else:
                return None
        return "".join(parts)
    return None


def string_env(cls: ast.ClassDef) -> dict[str, str]:
    """Class-level `NAME = <string>` bindings, in source order.

    Order matters: later constants are built from earlier ones, so each is
    folded against what is already bound.
    """
    env: dict[str, str] = {}
    for stmt in cls.body:
        targets = (
            stmt.targets if isinstance(stmt, ast.Assign)
            else [stmt.target] if isinstance(stmt, ast.AnnAssign) else []
        )
        folded = const_str(stmt.value, env) if getattr(stmt, "value", None) else None
        if folded is None:
            continue
        for t in targets:
            if isinstance(t, ast.Name):
                env[t.id] = folded
    return env


def const_num(node: ast.AST) -> float | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return float(node.value)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        inner = const_num(node.operand)
        return -inner if inner is not None else None
    return None


def pattern_features(rx: str) -> list[str]:
    return sorted(k for k, probe in FEATURE_PROBES.items() if probe in rx)


def extract_patterns(cls: ast.ClassDef) -> list[dict] | None:
    """Pull the PATTERNS class attribute, if it is a literal list."""
    env = string_env(cls)
    for stmt in cls.body:
        targets = (
            stmt.targets if isinstance(stmt, ast.Assign)
            else [stmt.target] if isinstance(stmt, ast.AnnAssign) else []
        )
        names = {t.id for t in targets if isinstance(t, ast.Name)}
        if "PATTERNS" not in names:
            continue
        value = stmt.value
        if not isinstance(value, (ast.List, ast.Tuple)):
            return None

        out = []
        for element in value.elts:
            if not isinstance(element, ast.Call):
                return None
            fn = element.func
            fname = fn.id if isinstance(fn, ast.Name) else getattr(fn, "attr", "")
            if fname != "Pattern":
                return None

            # Pattern(name, regex, score) positionally, or by keyword.
            args = {}
            for i, a in enumerate(element.args):
                args[("name", "regex", "score")[i] if i < 3 else f"arg{i}"] = a
            for kw in element.keywords:
                if kw.arg:
                    args[kw.arg] = kw.value

            name = const_str(args.get("name"), env) if "name" in args else None
            rx = const_str(args.get("regex"), env) if "regex" in args else None
            score = const_num(args.get("score")) if "score" in args else None
            if rx is None:
                return None  # computed pattern; needs a hand port

            out.append(
                {
                    "name": name,
                    "regex": rx,
                    "score": score if score is not None else 0.0,
                    "features": pattern_features(rx),
                }
            )
        return out
    return None


def extract_str_list(cls: ast.ClassDef, attr: str) -> list[str] | None:
    for stmt in cls.body:
        targets = (
            stmt.targets if isinstance(stmt, ast.Assign)
            else [stmt.target] if isinstance(stmt, ast.AnnAssign) else []
        )
        names = {t.id for t in targets if isinstance(t, ast.Name)}
        if attr not in names:
            continue
        try:
            value = ast.literal_eval(stmt.value)
        except (ValueError, SyntaxError):
            return None
        if isinstance(value, (list, tuple)) and all(isinstance(v, str) for v in value):
            return list(value)
        return None
    return None


def default_kwarg(cls: ast.ClassDef, kwarg: str) -> str | None:
    """Default value of an __init__ keyword, e.g. supported_entity."""
    for stmt in cls.body:
        if not isinstance(stmt, ast.FunctionDef) or stmt.name != "__init__":
            continue
        a = stmt.args
        names = [arg.arg for arg in a.args]
        defaults = a.defaults
        offset = len(names) - len(defaults)
        for i, name in enumerate(names):
            if name == kwarg and i >= offset:
                return const_str(defaults[i - offset])
        for arg, default in zip(a.kwonlyargs, a.kw_defaults):
            if arg.arg == kwarg and default is not None:
                return const_str(default)
    return None


RE_FLAG_NAMES = {"DOTALL", "MULTILINE", "IGNORECASE", "UNICODE", "VERBOSE", "S", "M", "I", "X"}

# PatternRecognizer's default (pattern_recognizer.py:59).
DEFAULT_FLAGS = {"DOTALL", "MULTILINE", "IGNORECASE"}


def collect_flag_names(node: ast.AST) -> set[str] | None:
    """Parse `re.DOTALL | re.MULTILINE` into {"DOTALL", "MULTILINE"}."""
    if isinstance(node, ast.Attribute) and node.attr in RE_FLAG_NAMES:
        return {node.attr}
    if isinstance(node, ast.Name) and node.id in RE_FLAG_NAMES:
        return {node.id}
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
        left = collect_flag_names(node.left)
        right = collect_flag_names(node.right)
        if left is None or right is None:
            return None
        return left | right
    return None


def regex_flags(cls: ast.ClassDef) -> tuple[set[str], bool]:
    """Effective regex flags, and whether the class overrides the default.

    IbanRecognizer is the one recognizer that drops IGNORECASE
    (iban_recognizer.py:77). Missing that makes its case-sensitive
    `[A-Z]{2}[0-9]{2}` match lowercase text that upstream would not detect --
    a silent false-positive source.
    """
    for stmt in cls.body:
        if not isinstance(stmt, ast.FunctionDef) or stmt.name != "__init__":
            continue
        a = stmt.args
        names = [arg.arg for arg in a.args]
        offset = len(names) - len(a.defaults)
        for i, name in enumerate(names):
            if name in ("regex_flags", "global_regex_flags") and i >= offset:
                found = collect_flag_names(a.defaults[i - offset])
                if found:
                    return found, found != DEFAULT_FLAGS
        # Also honour a literal passed straight to super().__init__.
        for node in ast.walk(stmt):
            if isinstance(node, ast.keyword) and node.arg == "global_regex_flags":
                found = collect_flag_names(node.value)
                if found:
                    return found, found != DEFAULT_FLAGS
    return set(DEFAULT_FLAGS), False


def own_methods(cls: ast.ClassDef) -> set[str]:
    return {s.name for s in cls.body if isinstance(s, ast.FunctionDef)}


def base_names(cls: ast.ClassDef) -> list[str]:
    out = []
    for b in cls.bases:
        if isinstance(b, ast.Name):
            out.append(b.id)
        elif isinstance(b, ast.Attribute):
            out.append(b.attr)
    return out


def resolve_method(
    class_name: str,
    method: str,
    methods_by_class: dict[str, set[str]],
    bases_by_class: dict[str, list[str]],
    _seen: set[str] | None = None,
) -> bool:
    """Does this class define `method`, directly or by inheritance?

    Presidio subclasses recognizers across files -- KrFrnRecognizer extends
    KrRrnRecognizer and inherits its validate_result while overriding only
    _validate_checksum. Checking a class's own body alone under-reports which
    recognizers need Swift-side logic, which would silently misclassify them as
    pure-pattern.
    """
    _seen = _seen or set()
    if class_name in _seen:
        return False
    _seen.add(class_name)
    if method in methods_by_class.get(class_name, set()):
        return True
    return any(
        resolve_method(base, method, methods_by_class, bases_by_class, _seen)
        for base in bases_by_class.get(class_name, [])
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--presidio", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    root = os.path.join(args.presidio, RECOGNIZER_DIR)
    if not os.path.isdir(root):
        print(f"error: {root} not found", file=sys.stderr)
        return 2

    commit = "unknown"
    try:
        commit = subprocess.run(
            ["git", "-C", args.presidio, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    # Pass 1: build the class graph so inherited methods resolve.
    methods_by_class: dict[str, set[str]] = {}
    bases_by_class: dict[str, list[str]] = {}
    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            if not fn.endswith(".py"):
                continue
            try:
                tree = ast.parse(open(os.path.join(dirpath, fn), encoding="utf-8").read())
            except SyntaxError:
                continue
            for node in ast.walk(tree):
                if isinstance(node, ast.ClassDef):
                    methods_by_class[node.name] = own_methods(node)
                    bases_by_class[node.name] = base_names(node)

    recognizers: list[dict] = []
    needs_hand_port: list[dict] = []

    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            if not fn.endswith(".py") or fn == "__init__.py":
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, args.presidio)
            try:
                tree = ast.parse(open(path, encoding="utf-8").read())
            except SyntaxError as exc:
                needs_hand_port.append({"file": rel, "reason": f"syntax: {exc}"})
                continue

            for node in tree.body:
                if not isinstance(node, ast.ClassDef):
                    continue
                bases = {
                    b.id if isinstance(b, ast.Name) else getattr(b, "attr", "")
                    for b in node.bases
                }

                patterns = extract_patterns(node)
                if patterns is None:
                    # Either not a pattern recognizer at all, or its PATTERNS
                    # are computed. Only the latter is interesting.
                    if "PatternRecognizer" in bases:
                        needs_hand_port.append(
                            {"file": rel, "class": node.name,
                             "reason": "PATTERNS not a literal list of Pattern(...)"}
                        )
                    continue

                flags, overrides = regex_flags(node)
                entry = {
                    "class": node.name,
                    "file": rel,
                    "bases": sorted(bases),
                    "entity": default_kwarg(node, "supported_entity"),
                    "language": default_kwarg(node, "supported_language") or "en",
                    "country": next(
                        (
                            const_str(s.value)
                            for s in node.body
                            if isinstance(s, ast.Assign)
                            and any(
                                isinstance(t, ast.Name) and t.id == "COUNTRY_CODE"
                                for t in s.targets
                            )
                        ),
                        None,
                    ),
                    "patterns": patterns,
                    "context": extract_str_list(node, "CONTEXT") or [],
                    "flags": sorted(flags),
                    "overrides_default_flags": overrides,
                    # Recognizers with these need Swift code beyond the data:
                    # a checksum validator or an invalidation rule.
                    "has_validate_result": resolve_method(
                        node.name, "validate_result", methods_by_class, bases_by_class
                    ),
                    "has_invalidate_result": resolve_method(
                        node.name, "invalidate_result", methods_by_class, bases_by_class
                    ),
                    "has_custom_analyze": resolve_method(
                        node.name, "analyze", methods_by_class, bases_by_class
                    ),
                }
                recognizers.append(entry)

    recognizers.sort(key=lambda r: r["class"])

    all_patterns = [p for r in recognizers for p in r["patterns"]]
    feature_counts = Counter(f for p in all_patterns for f in p["features"])
    needing_code = [
        r["class"] for r in recognizers
        if r["has_validate_result"] or r["has_invalidate_result"] or r["has_custom_analyze"]
    ]

    payload = {
        "schema_version": 1,
        "source": {"repo": "data-privacy-stack/presidio", "commit": commit},
        "stats": {
            "recognizers": len(recognizers),
            "patterns": len(all_patterns),
            "entities": len({r["entity"] for r in recognizers if r["entity"]}),
            "with_context": sum(1 for r in recognizers if r["context"]),
            "needing_swift_code": len(needing_code),
            "needs_hand_port": len(needs_hand_port),
            "override_flags": sum(1 for r in recognizers if r["overrides_default_flags"]),
        },
        "pattern_features": dict(feature_counts.most_common()),
        "recognizers": recognizers,
        "needs_hand_port": needs_hand_port,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    print(f"wrote {args.out}  ({os.path.getsize(args.out) / 1024:.0f} KB)")
    for k, v in payload["stats"].items():
        print(f"  {k:22s} {v}")
    print("  pattern features:")
    for feat, n in feature_counts.most_common():
        print(f"    {n:4d}  {feat}")
    if needs_hand_port:
        print("  needs hand port:")
        for item in needs_hand_port:
            print(f"    {item.get('class', '?')} ({item['file']}): {item['reason']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
