#!/usr/bin/env python3
"""Harvest Presidio's recognizer tests into a language-neutral JSON corpus.

Presidio's recognizer suite is overwhelmingly data-driven: literal
``(text, expected_len, expected_positions, expected_score_ranges)`` tuples fed
to a recognizer with no NLP model in the loop. That makes it liftable into JSON
that a Swift test can consume directly, so the Swift port is validated against
upstream's own expectations rather than against tests we invented.

This reads the Python source with ``ast`` only -- it never imports Presidio, so
it runs without spaCy, models, or a Presidio install.

Usage:
    python3 Tools/extract_fixtures.py --presidio <path-to-presidio-checkout> \\
        --out Tests/Fixtures/recognizer_cases.json

Design notes:

* Unsupported parametrize shapes are *reported*, never silently dropped. A
  corpus that quietly covers less than you think is worse than a smaller one
  you can see.
* ``expected_len`` is preserved separately from the span list. Some upstream
  tables assert a length but only enumerate the first few positions, and the
  Python assertion's ``zip()`` silently ignores the surplus. The Swift runner
  needs to know which is authoritative.
* Offsets are Python code-point (Unicode scalar) offsets and are emitted
  unchanged. That is the wire contract; see Sources/PresidioCore/TextDocument.swift.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys
from collections import Counter
from typing import Any

# Score bounds used when a table asserts positions but not scores.
DEFAULT_SCORE_MIN = 0.0
DEFAULT_SCORE_MAX = 1.0

# Upstream writes "max" in a score-range slot to mean "the max_score fixture",
# which is 1.0 (EntityRecognizer.MAX_SCORE).
MAX_SCORE_SENTINEL = "max"


class Unsupported(Exception):
    """A parametrize table whose shape this extractor does not understand."""


# Bound on sequence repetition, so a hostile or mistyped `[x] * 10**9` in an
# upstream table cannot exhaust memory during extraction.
MAX_REPEAT = 10_000


def literal(node: ast.AST, consts: dict[str, Any] | None = None) -> Any:
    """Evaluate a parametrize table without executing anything.

    `ast.literal_eval` alone rejects three idioms that are common in Presidio's
    own tables and have nothing to do with running code:

    * a module-level constant (`_PATTERN_SCORE`), so the table reads as prose;
    * sequence repetition, `[(0.5, 0.8)] * 2`, to say "the same bounds twice";
    * sequence concatenation, `A + B`.

    Refusing those cost real coverage -- seven recognizer tables, three of them
    for recognizers with no other test at all. This stays a *pure* evaluator:
    names resolve only against `consts`, which itself holds only literals, and
    the operators are the two that build sequences.
    """
    consts = consts or {}
    try:
        return ast.literal_eval(node)
    except (ValueError, SyntaxError, TypeError, MemoryError, RecursionError):
        pass

    if isinstance(node, ast.Name):
        if node.id in consts:
            return consts[node.id]
        raise Unsupported(f"unknown name {node.id!r}")
    if isinstance(node, ast.List):
        return [literal(e, consts) for e in node.elts]
    if isinstance(node, ast.Tuple):
        return tuple(literal(e, consts) for e in node.elts)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return -literal(node.operand, consts)
    if isinstance(node, ast.JoinedStr):
        # An f-string with no placeholders is just a string; upstream has a
        # few, presumably left over from editing. One with placeholders is a
        # computation and is refused.
        parts = []
        for piece in node.values:
            if isinstance(piece, ast.Constant) and isinstance(piece.value, str):
                parts.append(piece.value)
            else:
                raise Unsupported("f-string with placeholders")
        return "".join(parts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Mult, ast.Add)):
        left = literal(node.left, consts)
        right = literal(node.right, consts)
        if isinstance(node.op, ast.Mult):
            for seq, count in ((left, right), (right, left)):
                if isinstance(seq, (list, tuple, str)) and isinstance(count, int):
                    if count * max(len(seq), 1) > MAX_REPEAT:
                        raise Unsupported("sequence repetition too large")
                    return seq * count
            if isinstance(left, (int, float)) and isinstance(right, (int, float)):
                return left * right
            raise Unsupported("unsupported operands for *")
        if type(left) is type(right) and isinstance(left, (list, tuple, str)):
            return left + right
        if isinstance(left, (int, float)) and isinstance(right, (int, float)):
            return left + right
        raise Unsupported("unsupported operands for +")

    raise Unsupported(f"non-literal {type(node).__name__}")


def module_constants(tree: ast.Module) -> dict[str, Any]:
    """Module-level `NAME = <literal>` bindings, in source order.

    Order matters: a later constant may be built from an earlier one.
    """
    consts: dict[str, Any] = {}
    for stmt in tree.body:
        if not isinstance(stmt, ast.Assign):
            continue
        try:
            value = literal(stmt.value, consts)
        except (Unsupported, ValueError, SyntaxError, TypeError):
            continue
        for target in stmt.targets:
            if isinstance(target, ast.Name):
                consts[target.id] = value
    return consts


def asserts_no_results(fn: ast.FunctionDef) -> bool:
    """True if the test body asserts that analysis produced nothing.

    A table with only a `text` column carries no expectation in its rows, so
    the expectation has to come from the body. `assert len(results) == 0` is
    unambiguous, and reading it is why this does not have to guess from the
    test's name.
    """
    for node in ast.walk(fn):
        if not isinstance(node, ast.Assert):
            continue
        test = node.test
        if not (isinstance(test, ast.Compare) and len(test.ops) == 1
                and isinstance(test.ops[0], ast.Eq)):
            continue
        left, right = test.left, test.comparators[0]
        if not (isinstance(left, ast.Call)
                and getattr(left.func, "id", "") == "len"):
            continue
        if isinstance(right, ast.Constant) and right.value == 0:
            return True
    return False


def find_fixture_return(tree: ast.Module, name: str) -> ast.AST | None:
    """Return the expression a zero-arg pytest fixture returns."""
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef) or node.name != name:
            continue
        for stmt in node.body:
            if isinstance(stmt, ast.Return) and stmt.value is not None:
                return stmt.value
    return None


def _class_from_expr(ret: ast.AST) -> str | None:
    # Typical: `return UsSsnRecognizer()` or `return UsSsnRecognizer(arg=...)`.
    if isinstance(ret, ast.Call):
        func = ret.func
        if isinstance(func, ast.Name):
            return func.id
        if isinstance(func, ast.Attribute):
            return func.attr
    if isinstance(ret, ast.Name):
        return ret.id
    return None


def recognizer_class_name(tree: ast.Module) -> str | None:
    """Name of the recognizer class the module's `recognizer` fixture builds.

    Falls back to any fixture that returns a `*Recognizer(...)` call, because
    several modules name their fixture something else (`strict_recognizer`,
    `cc_recognizer`) or define more than one.
    """
    ret = find_fixture_return(tree, "recognizer")
    if ret is not None:
        name = _class_from_expr(ret)
        if name:
            return name

    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef):
            continue
        is_fixture = any(
            (isinstance(d, ast.Attribute) and d.attr == "fixture")
            or (isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute)
                and d.func.attr == "fixture")
            or (isinstance(d, ast.Name) and d.id == "fixture")
            for d in node.decorator_list
        )
        if not is_fixture:
            continue
        for stmt in node.body:
            if isinstance(stmt, ast.Return) and stmt.value is not None:
                name = _class_from_expr(stmt.value)
                if name and name.endswith("Recognizer"):
                    return name
    return None


def entity_list(tree: ast.Module) -> list[str] | None:
    ret = find_fixture_return(tree, "entities")
    if ret is None:
        return None
    try:
        value = literal(ret)
    except (ValueError, SyntaxError):
        return None
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple)) and all(isinstance(v, str) for v in value):
        return list(value)
    return None


def parse_argnames_from_string(value: Any) -> list[str]:
    """Split a resolved `parametrize` argnames value into names.

    Shared with `extract_computed_fixtures.py`, which gets the value from an
    imported module rather than from the AST.
    """
    if isinstance(value, str):
        return [p.strip() for p in value.split(",") if p.strip()]
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value]
    return []


def parse_argnames(node: ast.AST) -> list[str] | None:
    """`"text, expected_len"` or `["text", "expected_len"]` -> list of names."""
    try:
        value = literal(node)
    except (ValueError, SyntaxError):
        return None
    return parse_argnames_from_string(value) or None


def norm_span_list(raw: Any) -> list[tuple[int, int]]:
    """Normalize a positions field into [(start, end), ...]."""
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        if len(raw) == 2 and all(isinstance(v, int) for v in raw):
            return [(raw[0], raw[1])]  # a bare (start, end)
        out = []
        for item in raw:
            if not isinstance(item, (list, tuple)) or len(item) != 2:
                raise Unsupported(f"position entry {item!r}")
            out.append((int(item[0]), int(item[1])))
        return out
    raise Unsupported(f"positions {raw!r}")


def norm_score_list(raw: Any, count: int) -> list[tuple[float, float]]:
    """Normalize a score field into [(min, max), ...] of length `count`."""
    def one(v: Any) -> tuple[float, float]:
        if isinstance(v, (list, tuple)) and len(v) == 2:
            lo, hi = v
            hi = DEFAULT_SCORE_MAX if hi == MAX_SCORE_SENTINEL else float(hi)
            lo = DEFAULT_SCORE_MIN if lo == MAX_SCORE_SENTINEL else float(lo)
            return (lo, hi)
        if isinstance(v, (int, float)):
            return (float(v), float(v))  # an exact score
        if v == MAX_SCORE_SENTINEL:
            return (DEFAULT_SCORE_MAX, DEFAULT_SCORE_MAX)
        raise Unsupported(f"score entry {v!r}")

    if raw is None:
        return [(DEFAULT_SCORE_MIN, DEFAULT_SCORE_MAX)] * count

    # A single (lo, hi) pair applying to every span.
    if (
        isinstance(raw, (list, tuple))
        and len(raw) == 2
        and all(isinstance(v, (int, float)) for v in raw)
        and count != 2
    ):
        return [one(raw)] * count

    if isinstance(raw, (list, tuple)):
        if len(raw) == 0:
            return []
        # A flat scalar list, one score per span.
        if all(isinstance(v, (int, float)) for v in raw) and len(raw) == count:
            return [one(v) for v in raw]
        return [one(v) for v in raw]

    if isinstance(raw, (int, float)):
        return [one(raw)] * count

    raise Unsupported(f"scores {raw!r}")


def build_cases(
    argnames: list[str],
    rows: list[Any],
    entities: list[str],
    exact_score: float | None = None,
    assert_empty: bool = False,
) -> list[dict[str, Any]]:
    """Turn one parametrize table into normalized cases."""
    idx = {name: i for i, name in enumerate(argnames)}

    # The text column is usually `text`, but plenty of tables name it after the
    # thing under test (`iban`, `number`, `gstin`, `id_number`). Fall back to
    # the first column that holds a string in every row.
    text_key = "text" if "text" in idx else None
    if text_key is None:
        for name in argnames:
            col = idx[name]
            values = []
            for row in rows:
                seq = row if isinstance(row, (list, tuple)) else (row,)
                if col >= len(seq):
                    values = []  # ragged table; not this column
                    break
                values.append(seq[col])
            if values and all(isinstance(v, str) for v in values):
                text_key = name
                break
    if text_key is None:
        raise Unsupported(f"no text column in {argnames}")

    len_key = next(
        (k for k in ("expected_len", "expected_length", "num_results") if k in idx), None
    )
    pos_key = next(
        (k for k in ("expected_positions", "expected_position", "expected_res",
                     "expected_spans", "start_end") if k in idx),
        None,
    )
    score_key = next(
        (k for k in ("expected_score_ranges", "expected_score_range",
                     "expected_scores", "expected_score") if k in idx),
        None,
    )
    entity_key = next(
        (k for k in ("expected_entity", "entity_type", "expected_entities") if k in idx),
        None,
    )

    # A single-column table of texts asserts its expectation in the body rather
    # than in the rows -- `assert len(results) == 0`. The caller has already
    # read that, so treat every row as a negative case.
    if assert_empty and len_key is None and pos_key is None:
        return [
            {
                "text": row if isinstance(row, str) else (
                    row[idx[text_key]] if isinstance(row, (list, tuple)) else row
                ),
                "expected_count": 0,
                "spans_enumerated": True,
                "expected": [],
            }
            for row in rows
        ]

    # A table with neither a length nor a positions column is not asserting
    # spans at all -- e.g. `test_sanitize_value` compares a helper's string
    # output. Treating it as a span table silently manufactures "expect 0
    # results" cases that contradict the real expectations.
    if len_key is None and pos_key is None:
        raise Unsupported(f"no length or position column in {argnames}")

    cases: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, (list, tuple)):
            row = (row,)
        if len(row) != len(argnames):
            raise Unsupported(f"row arity {len(row)} != {len(argnames)}")

        text = row[idx[text_key]]
        if not isinstance(text, str):
            raise Unsupported(f"non-str text {text!r}")

        expected_len = row[idx[len_key]] if len_key else None
        if expected_len is not None and not isinstance(expected_len, int):
            raise Unsupported(f"non-int expected_len {expected_len!r}")

        spans = norm_span_list(row[idx[pos_key]]) if pos_key else []
        if score_key is None and exact_score is not None:
            scores = [(exact_score, exact_score)] * len(spans)
        else:
            scores = norm_score_list(
                row[idx[score_key]] if score_key else None, len(spans)
            )
        if len(scores) < len(spans):
            scores += [(DEFAULT_SCORE_MIN, DEFAULT_SCORE_MAX)] * (len(spans) - len(scores))

        # `expected_len` is authoritative; the positions column is not.
        #
        # The Python assertion is `zip(results, expected_positions)`, which
        # iterates only as far as `results`. So a row like
        #     ("123456789012", 0, (0, 12), 0)
        # asserts that NOTHING is found -- the (0, 12) is vestigial and never
        # checked. Carrying it through would invert a negative test into a
        # positive one. Likewise, positions beyond `expected_len` are dead.
        if expected_len is not None:
            if expected_len == 0:
                spans, scores = [], []
            elif len(spans) > expected_len:
                spans = spans[:expected_len]
                scores = scores[:expected_len]

        entity = entities[0] if entities else None
        if entity_key:
            candidate = row[idx[entity_key]]
            if isinstance(candidate, str):
                entity = candidate

        expected = [
            {
                "start": s,
                "end": e,
                "entity": entity,
                "score_min": scores[i][0],
                "score_max": scores[i][1],
            }
            for i, (s, e) in enumerate(spans)
        ]

        cases.append(
            {
                "text": text,
                # Authoritative count. When spans are enumerated this equals
                # len(expected); when only a length was asserted, expected is [].
                "expected_count": expected_len if expected_len is not None else len(expected),
                "expected": expected,
                # True when every asserted result has a span to compare
                # against; False when upstream asserted a count but listed
                # fewer positions, in which case only the count is checkable.
                "spans_enumerated": expected_len is None or len(spans) == expected_len,
            }
        )
    return cases


def assertion_exact_score(fn: ast.FunctionDef) -> float | None:
    """Detect tables whose assertion pins an exact score rather than a range.

    Many tables have no score column because the test body calls
    ``assert_result(res, entity, start, end, max_score)`` -- an exact
    assertion against ``EntityRecognizer.MAX_SCORE`` (1.0). Without this,
    those cases would be extracted with a wide-open 0.0-1.0 range and would
    silently accept a wrong score. The 330-row IBAN table is the big one.
    """
    for node in ast.walk(fn):
        if not isinstance(node, ast.Call):
            continue
        name = node.func.id if isinstance(node.func, ast.Name) else (
            node.func.attr if isinstance(node.func, ast.Attribute) else ""
        )
        if name != "assert_result" or not node.args:
            continue
        last = node.args[-1]
        if isinstance(last, ast.Name) and last.id == "max_score":
            return DEFAULT_SCORE_MAX
        if isinstance(last, ast.Constant) and isinstance(last.value, (int, float)):
            return float(last.value)
    return None


def try_validator_cases(argnames: list[str], rows: list[Any]) -> list[dict] | None:
    """Detect a checksum-validator table and normalize it.

    Shape: two columns, `(candidate_string, expected)` where expected is the
    tri-state `validate_result` contract:

        True  -- checksum passes
        None  -- checksum fails but the structure is valid (keep at pattern score)
        False -- structural failure (drop the match)

    These test `validate_result` directly rather than `analyze`, so they cannot
    be run by the span-based runner -- but they are exactly the conformance
    corpus for the 55 hand-rolled checksum validators.
    """
    if len(argnames) != 2:
        return None
    cases = []
    for row in rows:
        if not isinstance(row, (list, tuple)) or len(row) != 2:
            return None
        candidate, expected = row
        # Upstream writes some checksum tables with integer candidates
        # (Aadhaar). The recognizer sees text either way, so normalize.
        if isinstance(candidate, int) and not isinstance(candidate, bool):
            candidate = str(candidate)
        if not isinstance(candidate, str):
            return None
        if not (expected is None or isinstance(expected, bool)):
            return None
        cases.append(
            {
                "input": candidate,
                # JSON has no tri-state, so encode it explicitly.
                "expected": ("valid" if expected is True
                             else "invalid" if expected is False
                             else "indeterminate"),
            }
        )
    return cases or None


RECOGNIZER_FIXTURE_HINTS = ("recognizer", "_recognizer", "validator")


def consumed_fixture(fn: ast.FunctionDef) -> str | None:
    """Which recognizer fixture this test takes as a parameter.

    Presidio builds the same class several ways in one file -- DeVatIdRecognizer
    has both `recognizer` (heuristic) and `strict_recognizer` (rejects on
    checksum failure), with different expectations. Without recording which one
    a table used, the strict table's rows get applied to the default recognizer
    and fail for the wrong reason.
    """
    names = [a.arg for a in fn.args.args]
    for name in names:
        if name == "recognizer":
            return name
    for name in names:
        if any(hint in name for hint in RECOGNIZER_FIXTURE_HINTS):
            return name
    return None


def git_commit(repo: str) -> str:
    """HEAD of the upstream checkout, so a corpus records what it came from."""
    try:
        return subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def extract_file(path: str, rel: str) -> tuple[list[dict], list[dict], list[dict]]:
    """Returns (recognizer_tables, validator_tables, problems) for one file."""
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    try:
        tree = ast.parse(src)
    except SyntaxError as exc:
        return [], [{"file": rel, "reason": f"syntax error: {exc}"}]

    recognizer = recognizer_class_name(tree)
    entities = entity_list(tree) or []
    consts = module_constants(tree)

    tables: list[dict] = []
    validators: list[dict] = []
    problems: list[dict] = []

    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef):
            continue
        for deco in node.decorator_list:
            if not isinstance(deco, ast.Call):
                continue
            fn = deco.func
            name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", "")
            if name != "parametrize" or len(deco.args) < 2:
                continue

            argnames = parse_argnames(deco.args[0])
            if not argnames:
                problems.append({"file": rel, "test": node.name,
                                 "reason": "unparseable argnames"})
                continue
            try:
                rows = literal(deco.args[1], consts)
            except (Unsupported, ValueError, SyntaxError, TypeError) as exc:
                problems.append({"file": rel, "test": node.name,
                                 "reason": f"non-literal argvalues: {exc}"})
                continue
            if not isinstance(rows, (list, tuple)):
                problems.append({"file": rel, "test": node.name,
                                 "reason": "argvalues not a sequence"})
                continue

            # A validator table looks nothing like a span table; check first.
            vcases = try_validator_cases(argnames, list(rows))
            if vcases is not None:
                validators.append(
                    {
                        "recognizer": recognizer,
                        "entities": entities,
                        "file": rel,
                        "test": node.name,
                        "argnames": argnames,
                        "cases": vcases,
                    }
                )
                continue

            try:
                cases = build_cases(
                    argnames, list(rows), entities, assertion_exact_score(node),
                    assert_empty=asserts_no_results(node)
                )
            except Unsupported as exc:
                problems.append({"file": rel, "test": node.name,
                                 "reason": f"unsupported shape: {exc}",
                                 "argnames": argnames, "rows": len(rows)})
                continue

            if not cases:
                continue

            tables.append(
                {
                    "recognizer": recognizer,
                    "entities": entities,
                    "file": rel,
                    "test": node.name,
                    "argnames": argnames,
                    "fixture": consumed_fixture(node) or "recognizer",
                    "cases": cases,
                }
            )
    return tables, validators, problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--presidio", required=True, help="path to a presidio checkout")
    ap.add_argument("--out", required=True, help="output JSON path")
    args = ap.parse_args()

    tests_dir = os.path.join(args.presidio, "presidio-analyzer", "tests")
    if not os.path.isdir(tests_dir):
        print(f"error: {tests_dir} not found", file=sys.stderr)
        return 2

    commit = git_commit(args.presidio)

    all_tables: list[dict] = []
    all_validators: list[dict] = []
    all_problems: list[dict] = []

    for fn in sorted(os.listdir(tests_dir)):
        if not (fn.startswith("test_") and fn.endswith(".py")):
            continue
        path = os.path.join(tests_dir, fn)
        rel = os.path.relpath(path, args.presidio)
        tables, validators, problems = extract_file(path, rel)
        all_tables.extend(tables)
        all_validators.extend(validators)
        all_problems.extend(problems)

    # Only keep tables we could attribute to a recognizer class -- an
    # unattributed case cannot be dispatched by the Swift runner.
    attributed = [t for t in all_tables if t["recognizer"]]
    unattributed = [t for t in all_tables if not t["recognizer"]]
    for t in unattributed:
        all_problems.append({"file": t["file"], "test": t["test"],
                             "reason": "no recognizer fixture",
                             "rows": len(t["cases"])})

    total_cases = sum(len(t["cases"]) for t in attributed)
    positive = sum(
        1 for t in attributed for c in t["cases"] if c["expected_count"] > 0
    )
    negative = total_cases - positive
    recognizers = sorted({t["recognizer"] for t in attributed})
    entities = sorted({e for t in attributed for e in t["entities"]})

    corpus = {
        "schema_version": 1,
        "source": {
            "repo": "data-privacy-stack/presidio",
            "commit": commit,
            "tests_dir": os.path.relpath(tests_dir, args.presidio),
        },
        "stats": {
            "tables": len(attributed),
            "cases": total_cases,
            "positive": positive,
            "negative": negative,
            "recognizers": len(recognizers),
            "entity_types": len(entities),
            "skipped": len(all_problems),
        },
        "recognizers": recognizers,
        "entity_types": entities,
        "tables": attributed,
        # Kept in the artifact on purpose: coverage you cannot see is coverage
        # you do not have.
        "skipped": all_problems,
    }

    def write(path: str, payload: dict) -> int:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=False)
            fh.write("\n")
        return os.path.getsize(path)

    size = write(args.out, corpus)

    # Validator tables go to a sibling file: they exercise `validate_result`
    # directly and need a different runner from the span-based cases.
    v_attributed = [t for t in all_validators if t["recognizer"]]
    v_cases = sum(len(t["cases"]) for t in v_attributed)
    v_path = os.path.join(os.path.dirname(os.path.abspath(args.out)),
                          "validator_cases.json")
    v_size = write(
        v_path,
        {
            "schema_version": 1,
            "source": corpus["source"],
            "stats": {
                "tables": len(v_attributed),
                "cases": v_cases,
                "recognizers": len({t["recognizer"] for t in v_attributed}),
            },
            "tables": v_attributed,
        },
    )

    print(f"wrote {args.out}  ({size / 1024:.0f} KB)")
    print(f"  tables      {len(attributed)}")
    print(f"  cases       {total_cases}  ({positive} positive / {negative} negative)")
    print(f"  recognizers {len(recognizers)}")
    print(f"  entities    {len(entities)}")
    print(f"  skipped     {len(all_problems)}")
    print(f"wrote {v_path}  ({v_size / 1024:.0f} KB)")
    print(f"  validator tables {len(v_attributed)}  cases {v_cases}")
    if all_problems:
        reasons = Counter(p["reason"].split(":")[0] for p in all_problems)
        for reason, n in reasons.most_common():
            print(f"    {n:4d}  {reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
