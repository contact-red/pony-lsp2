# What is recorded here, and where

The reuse, import-clash and invalid-provides rules in
`tools/checker` were each pinned by a probe matrix against ponyc
0.69.1-ef4abd8c0 before implementation, and the probes were kept;
the earlier layers (legality, names) are evidenced by the corpus,
the standard-library gate and the two oracles. A project that needs
to know what that ponyc does in some corner can usually look the
answer up here instead of re-deriving it. This file is the index.

## Pinned ponyc semantics

Each entry names the docstring or comment that records the fact and
the fixtures that pin it executably.

- **Case folding.** `_Fold` in `tools/checker/reuse.pony`: a
  type-shaped name folds upper, a value-shaped one lower, matching
  ponyc's `name_without_case`; the multi-underscore difference can
  only lose a collision. Fixtures: `clash_case_*`,
  `name_*_case_*`, `reuse_*_case_*` in `tools/checker/probes/`.
- **Scope shapes.** `_OpensScope` in
  `upstream/tools/lib/ponylang/pony_analysis/_project.pony`
  accounts for every member of ponyc's `SCOPE()` grammar set three
  ways — a direct kind, coverage through `NdSeq`, and five
  desugar-derived kinds — and `_local_end` in the same file records
  the known gaps: ponyc's scope-free `rawseq` positions (call
  arguments, array elements, conditions, iterators), that a
  `with`-element initialiser's local ends at the `with` rather than
  beside it where ponyc's sugar moves it, and that two elements'
  initialisers declaring one name are not compared at all. Issue
  #12 carries the full gap list with the `scope_call` ordering
  constraint a fix must model. Pinned by `tests/_scope_tests.pony`
  and the `reuse_with_*` probes.
- **Blame order under desugars.** An object literal's fields and a
  lambda's captures are prepended, methods and the synthesized
  `create` are appended, `with` prepends one local per element with
  each element's ids in written order, and the previous use is what
  ponyc's symbol table held at the insert — the first insert of a
  folded name wins. Recorded in `_object_rules`' and `_clashes`'
  comments in `reuse.pony`; pinned by the `reuse_object_*`,
  `reuse_capture_*` and `reuse_with_*` probes.
- **Parameter-name legality.** ponyc's `check_id_param` is
  reachable only through `check_method`, so an FFI declaration's
  parameters are unchecked — `_method_params` in
  `tools/checker/legality.pony`. Its `NdLambdaParam` branch records
  the lambda case: ponyc substitutes a `_` parameter from an
  antecedent type before the check runs, which this checker cannot
  see, so `_` is accepted whatever the annotation and a typed `_`
  with no antecedent is an accepted fail-open miss (ponyc rejects
  it). Fixtures: `param_*`, `lambda_dontcare_*`.
- **Import clash.** `_package_clash` in `tools/checker/loader.pony`
  records the scope chain (earlier opens, own entities, importable
  builtin names) and that ponyc stops the compile at the first
  clashing `use` where the checker reports every file's first.
  Fixtures: `clash_*`.
- **Invalid provides.** `tools/checker/provides.pony`: the nominal
  and intersect rules for entities and object literals, with the
  qualified-name and enclosing-type-parameter fail-opens named in
  its docstrings. Fixtures: `provides_*`.
- **Diagnostic staging.** `_Pass` and `_rungs` in `loader.pony`:
  families are tagged with their ponyc pass; a failing family
  suppresses later passes, one pass's families report together, and
  the private-type checks fail no pass. The staging paragraph in
  `tools/checker/README.md` is the prose form. Fixtures: the
  `*_suppresses_*` and `*_keeps_*` families.

## The probe corpus

`tools/checker/probes/` holds 285 fixture packages. `expected.tsv`
gives each a verdict and, for a rejection, a message substring; 126
carry a full-rendering `.expected` pin with positions, Info lines
and carets. A fixture named `*_failopen_ok` is a recorded
divergence: ponyc rejects it and the checker accepts it. `run.sh`
runs the suite (`make checker-probes`); `parity.sh`
(`make probe-parity`) checks every pinned Error line against a dev
ponyc — a message both tools emit must sit at the pinned position —
with the divergent fixtures listed in `parity_exceptions.tsv`;
`debug_verdicts.sh` (`make checker-probes-debug`) runs the suite
against a debug build so the ordering assertions are evaluated.

## Recorded divergences from ponyc

- The checker reports a pass's whole families where ponyc's
  traversal can stop at its first finding —
  `tools/checker/README.md` and `Program.diagnostics` in
  `loader.pony`.
- Alias-reuse Info lines are omitted (ponyc's are positionless) —
  `CheckReuse.alias_clash`.
- The five `*_failopen_ok` fixtures, each a shape ponyc rejects and
  the checker accepts: a repeated import of one directory, a typed
  `_` lambda parameter with no antecedent, an alias in a provides
  clause resolving to a class, a type parameter shadowing a later
  entity, and one `with` name declared in two elements'
  initialisers.
- Agreed corpus rejections whose reason deliberately differs from
  ponyc's — `tools/corpus/message_exceptions.tsv`, one reason per
  row (a test-builtin environment mismatch, and the tolerant parser
  recovering where ponyc abandons the enclosing construct).
- Pin-level divergences — `probes/parity_exceptions.tsv`.
- The renderer strips the `\r` from an echoed CRLF source line
  where ponyc keeps it — undecided, listed in PR #11's parked
  items.

## The instruments

The scripts in `tools/corpus/` extract ponyc's own test suite into
runnable cases (`extract_corpus.py`), record the earliest pass at
which ponyc rejects each (`pass_reach.py`), score agreement
(`corpus_report.py`, `make checker-corpus`), and compare shared
messages' wording and positions against ponyc (`message_oracle.py`,
`column_oracle.py`). `make checker-stdlib` requires zero
diagnostics over ponyc's standard library; `make test` runs the
repo suites, the probes, the debug-assertion pass and the stdlib
gate. Every target that touches ponyc reads `PONYC_ROOT`
(default `$HOME/projects/ponylang/ponyc`).

## Design record

`SEMANTIC_DESIGN.md` is the design sketch with per-slice results.
Discussion #10 holds the accepted name-model design, not yet built,
which will replace the model in `tools/checker/names.pony` and
supersede the resolver descriptions in the documents its body
lists. Merged PRs #11, #14 and #15 carry the decision trail; #11's
description lists the parked questions as they stood then — rung
granularity and representation were settled by #14, and the
parameter-check attachment by #15. Issues #12 (scope spans) and #13
(probe-runner consolidation) are the filed follow-ups.

## Asking a new question

Check the divergence records above first. Then probe: write a
minimal package, run the pinned ponyc and the checker on it, and
compare.

    make checker    # builds ./build/checker
    mkdir -p /tmp/probe && cat > /tmp/probe/main.pony <<'PONY'
    actor Main
      new create(env: Env) => None
    PONY
    ponyc -b probe -o /tmp/probe --path <ponyc>/packages /tmp/probe
    ./build/checker /tmp/probe --path=<ponyc>/packages

The three rule families above were built probe-first, and a probe
is still the cheapest way to settle a new question; where a fact
cannot show in output — PR #14 records one — it rests on reading
the named ponyc source instead.
