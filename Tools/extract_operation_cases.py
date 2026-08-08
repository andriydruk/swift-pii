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

**Pipelines.** A list of results built from keyword arguments, passed through a
function, with assertions about the survivors:

    arr = [RecognizerResult(start=0, end=5, score=0.1, entity_type="x", ...), ...]
    results = EntityRecognizer.remove_duplicates(arr)
    assert len(results) == 1
    assert results[0].score == 0.5

That last shape is the point of the other two. `remove_duplicates` is what the
span predicates *feed*, and its behaviour is not obvious from theirs: it dedupes
on equality, sorts by a key that omits the entity type, drops zero scores, and
then removes anything contained in a survivor of the same type. Upstream's
`list(set(...))` also makes its tie order depend on `PYTHONHASHSEED`, so these
tables are the part of its behaviour that *is* pinned down.

Both forms carry parametrize rows, so one test yields as many cases as it has
rows -- and, importantly, tests with *no* parametrize decorator are harvested too.
Those were never in the skipped count because they are not tables, so this pulls
in coverage the 44 does not even mention.

What it still cannot reach is recorded in `skipped` with reasons: anything whose
subject is a pytest fixture (`recognizer._sanitize_value(text)` needs the
recognizer's constructor arguments), and anything asserting on exception text or
log output.

`skipped` means **not covered anywhere**, not "not covered by this tool". The
first version conflated the two and listed four tables that `extract_fixtures.py`
already harvests, which made the gap look larger than it is — the same failure as
describing the remainder as infrastructure, pointing the other way. So this reads
the recognizer corpus and reports those separately under `covered_elsewhere`. An
artifact that overstates a gap is no more use than one that understates it.

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

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_RECOGNIZER_CASES = os.path.join(
    HERE, "..", "Tests", "PresidioConformance", "Fixtures", "recognizer_cases.json"
)


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


def keyword_result(call: ast.Call):
    """`RecognizerResult(start=…, end=…, score=…, entity_type=…)`.

    `analysis_explanation` is ignored: it is metadata, and this port excludes it
    from equality and hashing for the same reason upstream does.
    """
    fields = {}
    for keyword in call.keywords:
        if keyword.arg in ("start", "end", "score", "entity_type"):
            if not is_literal(keyword.value):
                raise KeyError(f"non-literal {keyword.arg}")
            fields[keyword.arg] = literal(keyword.value)
    if set(fields) != {"start", "end", "score", "entity_type"}:
        raise KeyError("incomplete RecognizerResult")
    return fields


def pipeline_case(fn: ast.FunctionDef):
    """`arr = [...]` → `results = f(arr)` → assertions about `results`."""
    inputs, produced_by, output = None, None, None
    for node in fn.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        target, value = node.targets[0], node.value
        if not isinstance(target, ast.Name):
            continue
        if isinstance(value, ast.List):
            rows = []
            for element in value.elts:
                if not (isinstance(element, ast.Call)
                        and getattr(element.func, "id", None) == "RecognizerResult"):
                    raise KeyError("list element is not a RecognizerResult")
                rows.append(keyword_result(element))
            inputs = (target.id, rows)
        elif isinstance(value, ast.Call):
            name = dotted(value.func)
            if (
                name and inputs and len(value.args) == 1
                and isinstance(value.args[0], ast.Name)
                and value.args[0].id == inputs[0]
            ):
                produced_by, output = name, target.id

    if inputs is None or output is None:
        raise KeyError("not a pipeline")

    count, fields = None, []
    for node in fn.body:
        if not isinstance(node, ast.Assert):
            continue
        test = node.test
        if not (isinstance(test, ast.Compare) and len(test.ops) == 1
                and isinstance(test.ops[0], ast.Eq)):
            raise KeyError("non-equality assertion about the output")
        left, right = test.left, test.comparators[0]
        if not is_literal(right):
            raise KeyError("non-literal expectation")
        expected = literal(right)

        # `len(results) == N`
        if (isinstance(left, ast.Call) and getattr(left.func, "id", None) == "len"
                and len(left.args) == 1
                and getattr(left.args[0], "id", None) == output):
            count = expected
            continue
        # `results[0].score == 0.5`
        if (isinstance(left, ast.Attribute)
                and isinstance(left.value, ast.Subscript)
                and getattr(left.value.value, "id", None) == output
                and is_literal(left.value.slice)):
            fields.append({
                "index": literal(left.value.slice),
                "field": left.attr,
                "value": expected,
            })
            continue
        raise KeyError("unsupported assertion about the output")

    if count is None:
        raise KeyError("no length assertion")
    return produced_by, inputs[1], count, fields


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


def already_harvested(corpus_path: str) -> set:
    """`(file, test)` pairs `extract_fixtures.py` already covers."""
    if not os.path.exists(corpus_path):
        return set()
    with open(corpus_path, encoding="utf-8") as handle:
        corpus = json.load(handle)
    return {
        (table.get("file"), table.get("test")) for table in corpus.get("tables", [])
    }


def harvest(root: str, covered: set):
    predicates, functions, pipelines = [], [], []
    skipped, elsewhere = [], []

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

            def record_gap(reason: str):
                entry = {"file": relative, "test": fn.name, "reason": reason}
                if (relative, fn.name) in covered:
                    entry["reason"] = f"{reason}; harvested by extract_fixtures.py"
                    elsewhere.append(entry)
                else:
                    skipped.append(entry)

            if fixtures:
                record_gap(f"needs the {fixtures[0]!r} fixture")
                continue

            # A pipeline is tried first: its body also contains assignments and
            # asserts, so the predicate reader would reject it for the wrong
            # reason and hide what it actually is.
            try:
                function, inputs, count, fields = pipeline_case(fn)
            except KeyError as error:
                pipeline_failure = str(error)
            else:
                pipelines.append({
                    "file": relative, "test": fn.name, "function": function,
                    "input": inputs, "expected_count": count,
                    "expected_fields": fields,
                })
                continue

            rows = table[1] if table else [[]]
            test, positive = final_assert(fn)
            if test is None:
                record_gap("no assertion")
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
                # `pipeline_failure` says why the richer reader declined, which
                # is usually the more informative of the two.
                record_gap(
                    f"unsupported shape: {failure}"
                    if pipeline_failure == "'not a pipeline'"
                    else f"unsupported shape: {failure} / {pipeline_failure}"
                )
            elif results:
                predicates.extend(produced)
            else:
                functions.extend(produced)

    return predicates, functions, pipelines, skipped, elsewhere


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--presidio", required=True, help="upstream Presidio checkout")
    ap.add_argument("--out", required=True)
    ap.add_argument(
        "--recognizer-cases",
        default=DEFAULT_RECOGNIZER_CASES,
        help="the other extractor's artifact, read to tell 'not covered here' "
             "from 'not covered anywhere'",
    )
    args = ap.parse_args()

    covered = already_harvested(args.recognizer_cases)
    if not covered:
        print(
            f"warning: {args.recognizer_cases} not found or empty; every gap "
            f"will be reported as uncovered",
            file=sys.stderr,
        )
    predicates, functions, pipelines, skipped, elsewhere = harvest(
        args.presidio, covered
    )

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
            "pipelines": len(pipelines),
            "skipped": len(skipped),
            "covered_elsewhere": len(elsewhere),
        },
        "predicates": predicates,
        "functions": functions,
        "pipelines": pipelines,
        "skipped": skipped,
        "covered_elsewhere": elsewhere,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
        handle.write("\n")

    print(f"wrote {args.out}")
    print(f"  {len(predicates)} predicate cases, {len(functions)} function cases, "
          f"{len(pipelines)} pipeline cases")
    print(f"  {len(elsewhere)} covered by extract_fixtures.py, {len(skipped)} not "
          f"covered anywhere:")
    for entry in skipped:
        print(f"    - {entry['file'].split('/')[-1]}::{entry.get('test', '?')}: "
              f"{entry['reason']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
