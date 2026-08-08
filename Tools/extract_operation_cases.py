#!/usr/bin/env python3
"""Harvest upstream tables that test a *function*, not a recognizer.

`extract_fixtures.py` understands one shape: a table of texts, with expected
match counts and positions. That covers 106 tables and misses a class it cannot
express -- unit tests of a value type or a static helper, where there is no text
column because there is no text.

Those went into the `skipped` list with the reason "unsupported shape", and the
parity doc summarised the whole list as "almost entirely infrastructure". Reading
it, that was an overstatement. About a third is real behaviour, and the largest
group is the span algebra on `RecognizerResult` -- `contains`, `equal_indices`,
`has_conflict`, ordering, equality and hashing -- which is what `remove_duplicates`
and the conflict resolver are built on. A divergence there would reorder or
silently drop results from every recognizer at once.

This tool handles two shapes, both statically, and refuses anything else rather
than guessing:

**Predicates.** Two values built from literals by a helper, then one boolean
assertion about the pair:

    first = create_recognizer_result("bla", 0.2, 2, 10)
    second = create_recognizer_result(entity_type, score, start, end)
    assert first.has_conflict(second)

**Pure functions.** A call whose arguments are literals or parameters, compared
against a literal or a parameter:

    assert EntityRecognizer.sanitize_value(input_text, params) == expected_output

Both forms carry parametrize rows, so one test yields as many cases as it has
rows -- and, importantly, tests with *no* parametrize decorator are harvested too.
Those were never in the skipped count because they are not tables, so this pulls
in coverage the 44 does not even mention.

What it still cannot reach, recorded in `skipped` with reasons: anything whose
subject is a pytest fixture (`recognizer._sanitize_value(text)` needs the
recognizer's constructor arguments), and anything asserting on exception text or
log output.

    python3 Tools/extract_operation_cases.py \\
        --presidio .upstream-presidio \\
        --out Tests/PresidioConformance/Fixtures/operation_cases.json
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import subprocess
import sys

# The files worth reading. Named rather than globbed: this tool is deliberately
# narrow, and a glob would quietly start reporting hundreds of "unsupported
# shape" entries from files that were never in scope.
FILES = [
    "presidio-analyzer/tests/test_recognizer_result.py",
    "presidio-analyzer/tests/test_entity_recognizer.py",
    "presidio-analyzer/tests/test_in_aadhaar_recognizer.py",
    "presidio-analyzer/tests/test_za_mobile_number_recognizer.py",
    "presidio-analyzer/tests/test_in_gstin_recognizer.py",
]

# Python spellings mapped onto names the Swift side can switch on. `__gt__` and
# `__hash__` are dunder calls in the tests because that is how the upstream
# author wrote the assertion; the operator forms `a > b` and `a == b` mean the
# same thing and both appear.
PREDICATES = {
    "contains": "contains",
    "contained_in": "contained_in",
    "equal_indices": "equal_indices",
    "has_conflict": "has_conflict",
    "intersects": "intersects",
    "__gt__": "greater_than",
}

CONSTRUCTORS = {"create_recognizer_result"}


def literal(node):
    """A literal, or `None` if the node is not one. Raises nothing."""
    try:
        return ast.literal_eval(node)
    except (ValueError, SyntaxError, TypeError):
        return None


def is_literal(node) -> bool:
    try:
        ast.literal_eval(node)
        return True
    except (ValueError, SyntaxError, TypeError):
        return False


def dotted(node) -> str | None:
    """`Class.method` from an attribute chain, or None."""
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return None
    parts.append(node.id)
    return ".".join(reversed(parts))


def parametrize_rows(fn: ast.FunctionDef, module_constants: dict):
    """`(names, rows)` from a parametrize decorator, or `None` if there is none.

    A row is always a tuple, even for a single parameter, so downstream code
    does not have to care which spelling the table used.
    """
    for decorator in fn.decorator_list:
        if not isinstance(decorator, ast.Call):
            continue
        if dotted(decorator.func) not in (
            "pytest.mark.parametrize", "mark.parametrize", "parametrize"
        ):
            continue
        if len(decorator.args) < 2:
            return None
        names = literal(decorator.args[0])
        if not isinstance(names, str):
            return None
        names = [part.strip() for part in names.split(",") if part.strip()]

        values = decorator.args[1]
        rows = literal(values)
        if rows is None and isinstance(values, ast.Name):
            # `@parametrize("a, b", some_module_level_list)`
            rows = module_constants.get(values.id)
        if rows is None:
            return None
        normalized = []
        for row in rows:
            if not isinstance(row, (list, tuple)):
                row = (row,)
            if len(row) != len(names):
                return None
            normalized.append(list(row))
        return names, normalized
    return None


def module_level_constants(tree: ast.Module) -> dict:
    out = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and is_literal(node.value):
                out[target.id] = literal(node.value)
    return out


def resolve(node, bindings: dict):
    """A literal, or the bound value of a parameter name. `KeyError` if neither."""
    if is_literal(node):
        return literal(node)
    if isinstance(node, ast.Name) and node.id in bindings:
        return bindings[node.id]
    raise KeyError(ast.dump(node))


def constructed_results(fn: ast.FunctionDef) -> dict:
    """Assignments of the form `name = create_recognizer_result(...)`."""
    out = {}
    for node in fn.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        target, value = node.targets[0], node.value
        if not isinstance(target, ast.Name) or not isinstance(value, ast.Call):
            continue
        if getattr(value.func, "id", None) in CONSTRUCTORS:
            out[target.id] = value.args
    return out


def final_assert(fn: ast.FunctionDef):
    """The last `assert` in the body, and whether it was negated."""
    for node in reversed(fn.body):
        if isinstance(node, ast.Assert):
            test = node.test
            if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
                return test.operand, False
            return test, True
    return None, None


def predicate_case(test, results, bindings, path, fn):
    """One `(op, first, second)` from an assertion over two built results."""
    def build(name):
        args = results[name]
        if len(args) != 4:
            raise KeyError("constructor arity")
        entity_type, score, start, end = (resolve(a, bindings) for a in args)
        return {
            "entity_type": entity_type, "score": score,
            "start": start, "end": end,
        }

    # `first.op(second)` / `first.__gt__(second)`
    if isinstance(test, ast.Call) and isinstance(test.func, ast.Attribute):
        subject = test.func.value
        if (
            isinstance(subject, ast.Name) and subject.id in results
            and test.func.attr in PREDICATES
            and len(test.args) == 1
            and isinstance(test.args[0], ast.Name)
            and test.args[0].id in results
        ):
            return PREDICATES[test.func.attr], build(subject.id), build(test.args[0].id)

    # `first == second`, `first != second`, `first > second`
    if isinstance(test, ast.Compare) and len(test.ops) == 1:
        left, right, op = test.left, test.comparators[0], test.ops[0]

        # `first.__hash__() == second.__hash__()`
        def hashed(node):
            return (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "__hash__"
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id in results
            )

        if hashed(left) and hashed(right):
            name = "hash_equal" if isinstance(op, ast.Eq) else "hash_equal"
            first = build(left.func.value.id)
            second = build(right.func.value.id)
            return (name, first, second) if isinstance(op, ast.Eq) else \
                   ("hash_not_equal", first, second)

        if (
            isinstance(left, ast.Name) and left.id in results
            and isinstance(right, ast.Name) and right.id in results
        ):
            if isinstance(op, ast.Eq):
                return "equal", build(left.id), build(right.id)
            if isinstance(op, ast.NotEq):
                return "not_equal", build(left.id), build(right.id)
            if isinstance(op, ast.Gt):
                return "greater_than", build(left.id), build(right.id)
    raise KeyError("unsupported assertion")


def function_case(test, bindings):
    """One `(function, args, expected)` from `assert f(...) == expected`."""
    if not (isinstance(test, ast.Compare) and len(test.ops) == 1
            and isinstance(test.ops[0], ast.Eq)):
        raise KeyError("not an equality assertion")
    call, expected_node = test.left, test.comparators[0]
    if not isinstance(call, ast.Call):
        raise KeyError("left side is not a call")
    name = dotted(call.func)
    if name is None:
        raise KeyError("callee is not a dotted name")
    args = [resolve(argument, bindings) for argument in call.args]
    return name, args, resolve(expected_node, bindings)


def harvest(root: str):
    predicates, functions, skipped = [], [], []

    for relative in FILES:
        path = os.path.join(root, relative)
        if not os.path.exists(path):
            skipped.append({"file": relative, "reason": "file not found upstream"})
            continue
        with open(path, encoding="utf-8") as handle:
            tree = ast.parse(handle.read())
        constants = module_level_constants(tree)

        for fn in tree.body:
            if not isinstance(fn, ast.FunctionDef) or not fn.name.startswith("test"):
                continue
            # A fixture argument means the subject is constructed elsewhere, so
            # its arguments are not in this file.
            fixtures = [
                a.arg for a in fn.args.args
                if a.arg in ("recognizer", "nlp_engine", "analyzer")
            ]
            table = parametrize_rows(fn, constants)
            names = table[0] if table else []
            if fixtures:
                skipped.append({
                    "file": relative, "test": fn.name,
                    "reason": f"needs the {fixtures[0]!r} fixture",
                })
                continue

            rows = table[1] if table else [[]]
            test, positive = final_assert(fn)
            if test is None:
                skipped.append({
                    "file": relative, "test": fn.name, "reason": "no assertion",
                })
                continue

            results = constructed_results(fn)
            produced, failure = [], None
            for row in rows:
                bindings = dict(zip(names, row))
                try:
                    if results:
                        op, first, second = predicate_case(
                            test, results, bindings, path, fn
                        )
                        # `not_equal` and `hash_not_equal` already carry the
                        # negation in the operator, so `assert` vs `assert not`
                        # would double it.
                        if op in ("not_equal", "hash_not_equal"):
                            op = op.replace("not_", "")
                            expected = not positive
                        else:
                            expected = positive
                        produced.append({
                            "file": relative, "test": fn.name, "op": op,
                            "first": first, "second": second, "expected": expected,
                        })
                    else:
                        function, args, expected = function_case(test, bindings)
                        produced.append({
                            "file": relative, "test": fn.name,
                            "function": function, "args": args, "expected": expected,
                        })
                except KeyError as error:
                    failure = str(error)
                    break
            if failure is not None:
                skipped.append({
                    "file": relative, "test": fn.name,
                    "reason": f"unsupported shape: {failure}",
                })
            elif results:
                predicates.extend(produced)
            else:
                functions.extend(produced)

    return predicates, functions, skipped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--presidio", required=True, help="upstream Presidio checkout")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    predicates, functions, skipped = harvest(args.presidio)

    commit = subprocess.run(
        ["git", "-C", args.presidio, "rev-parse", "HEAD"],
        capture_output=True, text=True,
    ).stdout.strip() or "unknown"

    payload = {
        "schema_version": 1,
        "source": {"commit": commit, "files": FILES},
        "stats": {
            "predicates": len(predicates),
            "functions": len(functions),
            "skipped": len(skipped),
        },
        "predicates": predicates,
        "functions": functions,
        "skipped": skipped,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
        handle.write("\n")

    print(f"wrote {args.out}")
    print(f"  {len(predicates)} predicate cases, {len(functions)} function cases, "
          f"{len(skipped)} skipped")
    for entry in skipped:
        print(f"    - {entry['file']}::{entry.get('test', '?')}: {entry['reason']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
