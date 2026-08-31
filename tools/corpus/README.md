# Agreement with ponyc's verdicts

ponyc's unit tests are a corpus of Pony programs each paired with the verdict
ponyc is asserted to reach. `extract_corpus.py` writes each one out as a
package directory with a manifest saying whether ponyc accepts or rejects it,
so a checker can be run over the same programs and compared.

`extract_corpus.py` and `corpus_report.py` started as ponyq's scripts. Both
have since been extended here: the extractor records each case's own target
pass -- read from its verdict macro's define, or from the call site where the
suite passes it per invocation -- and the report refuses to score a verdict
file with cases missing, so a mid-batch crash fails loudly instead of
yielding an agreement rate over the surviving prefix. Neither mentions Rust
or Pony; the step between them is a checker that takes a package and exits 0
or non-zero.

## Running it

    make corpus-cases   # extract the cases and the manifest
    make pass-reach     # what a checker can reach without method bodies

`corpus_report.py` compares a verdict file against the manifest;
`make checker-corpus` produces one from `tools/checker` and scores it
against the instrument's valid universe. Two oracles go below the verdict.
`make message-oracle` requires an agreed rejection whose manifest row
carries ponyc's expected message to emit that message — a case
rejected for the wrong reason scores as agreement in the headline
rate, which is how ponyq shipped ninety-nine wrong rejections it never
noticed; deliberate divergences live in `message_exceptions.tsv` with
their reasons. `make column-oracle` requires that wherever the checker
and ponyc emit the same message, the line and column match, so a
diagnostic that drifts from ponyc's position fails a gate instead of
waiting for a reader to notice the caret.

## What the extraction leaves out

A `TEST_F` that replaces `builtin` or compares ASTs is not a plain verdict
on one program, so it is skipped. When a test builds a fixture package and
registers it as a magic path, the extractor writes that package out beside
the case's `main.pony`, where the bare locator resolves to it. A case that
survives extraction but where standalone ponyc disagrees with the verdict
its own test asserts -- the known shape redeclares a builtin name, which
the unit-test harness tolerates and a standalone compile does not -- is
detected by `pass_reach.py`, excluded from every number as invalid, and
recorded in `reach.tsv` as an invalid row so scoring can tell the
exclusion from a case the instrument never saw.

## Reading agreement

Agreement counts both verdicts, so a checker that finds nothing wrong agrees
with every case ponyc accepts. Nearly half of this corpus is accepts, so any
agreement figure has to be read against that floor -- `pass_reach.py` prints
it -- and what a checker is worth is the rejections it adds above it.

## The per-case instrument

`pass_reach.py` records, per case, what ponyc empirically does: an accept
case is compiled to its own target pass to confirm it really compiles; a
reject case is probed up ponyc's pass ladder to find the earliest pass that
errors on it, which is the layer of a checker that could reject it. The
records go to `reach.tsv` beside the manifest, so a later run diffs per case
instead of comparing aggregates, and a single case changing hands is a named
regression rather than a 0.1-point wobble.

The summary attributes each reachable rejection to the design's slices --
parse and syntax legality; name-level errors; the signature layer -- and
counts what needs bodies. It also reports which rejections ponyc decides via
its #1216 recursion-divergence guard, because `SEMANTIC_DESIGN.md` carries an
open decision on whether to match that guard's conservatism bug-for-bug, and
the count is what prices it.

An earlier version of this instrument stopped every case at `--pass=traits`
and excluded whole suites by their `TEST_COMPILE` define. That cut ran ponyc
passes a signature-only checker does not contain and dropped suites whose
pass was declared per call site, so its headline ceiling overstated the
slice; the per-case ladder replaces it.
