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

`corpus_report.py` compares a verdict file against the manifest. Nothing here
produces one yet, because the checker it would run does not exist.

## What the extraction leaves out

A `TEST_F` that needs more than one source file, replaces `builtin`, or
compares ASTs is not a plain verdict on one program, so it is skipped. A case
that survives extraction but where standalone ponyc disagrees with the
verdict its own test asserts -- the known shape redeclares a builtin name,
which the unit-test harness tolerates and a standalone compile does not -- is
detected by `pass_reach.py` and excluded from every number as invalid.

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
