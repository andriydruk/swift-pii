# 0002 — Concurrency model, and validating the guard that checks it

Status: accepted (M5)

## Context

`AnalyzerEngine` is a `Sendable` struct, so nothing stops a caller building one
and sharing it across tasks — and they should, because construction costs ~20 ms
while `analyze` costs ~3 ms. That makes thread safety a property of every type
reachable from the engine, not an optional extra.

M4 added two NLP engine wrappers and marked them `@unchecked Sendable` without
auditing what they wrapped. That was wrong.

## What was actually shared

`SpacyTokenizer` has two kinds of mutable state:

1. A memoization cache (`[String: [(String, String?)]]`) written on every cache
   miss. Measured worth: **4.3×** on repeated text, so removing it was not an
   option.
2. Three derived special-case tables built with `lazy var`. Lazy initialization
   is *itself* a data race on a shared instance — two tasks can enter the
   initializer concurrently.

`NERModel`'s weights are `var`, but only because the msgpack decode assigns them
in a loop; they are written during `init` and read-only afterwards, and
inference allocates its scratch per call.

## Decision

- The cache stays, guarded by an `NSLock`. The critical sections are two
  dictionary operations; `tokenizeSpan` runs *outside* the lock, so two tasks
  may duplicate work for the same span rather than serializing on it. Measured
  cost on the warm path: none (0.098 s → 0.096 s over 312k tokens).
- The three lazy tables are built eagerly in `init`.
- Every remaining `@unchecked Sendable` carries its justification at the
  declaration. If it cannot be justified in a sentence, it is not safe.

## Validating the guard

ThreadSanitizer cannot load on this project's macOS dev host — Xcode's sanitizer
dylib fails the platform code-signature policy — so the race check runs as a
Linux CI job.

**The first version of that job was a placebo, and the only reason we know is
that we tried to break it.** The concurrency test computed its expected results
serially and then had eight tasks re-analyze the same five texts. That warmed
the cache, so the concurrent phase only ever *read* it and TSan saw nothing.

Verified by pushing a branch with the lock removed:

| harness | lock removed | TSan verdict |
|---|---|---|
| original (fixed corpus, warmed) | yes | **passed** — no race reported |
| current (novel text per task) | yes | **failed** — `Swift access race` in `SpacyTokenizer.emit` |
| current | no | passed |

The test now generates text no other task has seen, so cache writes and reads
collide. CI runs on `ci/**` branches specifically so this kind of check can be
repeated: a sanitizer job that has only ever seen correct code proves nothing
about whether it would catch the bug.

## What the job could not reach

The claim below used to read "any future addition of shared mutable state has a
test that will actually fail". That was true of the tokenizer and false of
everything behind it.

The job runs on Linux, in a container, with no spaCy model to download — so the
only engine it could construct was `TokenizerOnlyNlpEngine`. Eight of the ten
`@unchecked Sendable` types are on the model path (`NERModel`, `Tok2Vec`, the
tagger, the parser, both lemmatizers, `SpacyNER`, `SpacyNlpEngine`), and none of
them was ever loaded under the sanitizer. What stood behind those annotations was
a paragraph of reasoning at each declaration.

Bundling the model removed the obstacle: the weights are a package resource, so
they are present in that container with no download. A second suite now shares a
`SpacyNlpEngine` and a model-backed `AnalyzerEngine` across six tasks and runs
under the sanitizer with the rest.

It inherits the design above — novel text per task, and every result compared
against a second *concurrent* pass rather than a serially computed one. It has
**not** been re-verified by deliberately breaking something, because that needs a
sanitizer this host cannot load and the demonstration above was done on CI
against a pushed branch. The principle carries over; the demonstration does not,
and saying otherwise would repeat the mistake this ADR exists to record.

The suite is gated on the model resolving out of its resource bundle, so a
platform where that stops working skips rather than failing as though it were a
race — and CI greps for the measurement each test prints, because swift-testing
prints the suite name when it *skips* and a name grep would pass on one.

## Consequences

- One engine can be shared across tasks; that is the intended usage.
- `SpacyTokenizer`, `SpacyNER` and both NLP engine wrappers are `@unchecked
  Sendable` with audited justifications rather than assumed ones.
- Shared mutable state added to the tokenizer has a test that will actually fail,
  demonstrated. Shared mutable state added to the model path now has one too,
  by construction rather than by demonstration.
