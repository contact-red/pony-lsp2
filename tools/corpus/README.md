# Agreement with ponyc's verdicts

ponyc's unit tests are a corpus of Pony programs each paired with the verdict
ponyc is asserted to reach. `extract_corpus.py` writes each one out as a
package directory with a manifest saying whether ponyc accepts or rejects it,
so a checker can be run over the same programs and compared.

`extract_corpus.py` and `corpus_report.py` are ponyq's, unmodified. They read
ponyc's tests and compare verdict files, and neither mentions Rust or Pony, so
the port is the step between them: a checker that takes a package and exits 0
or non-zero.

## Running it

    make corpus-cases   # extract the cases and the manifest
    make pass-reach     # what a checker can reach without method bodies

`corpus_report.py` compares a verdict file against the manifest. Nothing here
produces one yet, because the checker it would run does not exist.

## What the extraction leaves out

A `TEST_F` that needs more than one source file, replaces `builtin`, or
compares ASTs is not a plain verdict on one program, so it is skipped. 1,416
cases come out and 183 are skipped.

## Reading agreement

Agreement counts both verdicts, so a checker that finds nothing wrong agrees
with every case ponyc accepts. On this corpus that is 46.1% before any rule is
written, and any agreement figure has to be read against it -- including
ponyq's 49.5%.

## What a checker can reach without bodies

`pass_reach.py` answers this from ponyc rather than from a checker that does
not exist yet. Signature checking is everything at or before ponyc's `traits`
pass and body checking is `expr`, so a case ponyc rejects with `--pass=traits`
is one a signature-only checker could reject, and a case that survives is one
it could not.

Cases whose own suite stops before `traits` are excluded. ponyc never runs
those passes for them, so the comparison would be against something ponyc does
not do.

The headline numbers here — a 54.3% ceiling against a 46.1% floor — are
what this script computes at its `--pass=traits` cut. That cut also runs ponyc
passes a signature-only checker does not contain, so it overstates such a
checker's ceiling; `SEMANTIC_DESIGN.md`'s first-slice section carries the
per-slice numbers derived from the per-case split.

The three cases ponyc accepts but errors on at `traits` are the measurement's
own noise. Each is a program whose suite targets an earlier pass, so running
further reaches an error the test never asked about.
