#!/bin/sh
# The checker's probe fixtures. Each directory is a package;
# expected.tsv holds its verdict and, for a rejection, a substring the
# diagnostics must carry, so a fixture rejected for the wrong reason is
# a failure, not an agreement.
set -eu
here="$(dirname "$0")"
# Absolute paths, because the batch check below runs from the fixture
# directory.
checker="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
roots="$(cd "$2" && pwd)"
fails=0

# The fixture set and the expectation list must name each other exactly:
# a directory with no row would otherwise never run.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dirs=$(cd "$here" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | sort)
rows=$(cut -f1 "$here/expected.tsv" | sort)
if [ "$dirs" != "$rows" ]; then
  echo "PROBE FAIL: fixture directories and expected.tsv disagree"
  echo "$dirs" > "$tmp/dirs"; echo "$rows" > "$tmp/rows"
  diff "$tmp/dirs" "$tmp/rows" || true
  exit 1
fi

while IFS="	" read -r name want substring; do
  code=0
  "$checker" "$here/$name" --path="$roots" >/dev/null 2>"$tmp/err" || code=$?
  case "$code" in
    0) got=ok ;;
    255) got=fail ;;
    *) got="crash($code)" ;;
  esac
  # Single mode has two exit codes; a load-failed row expects the
  # rejection exit there and its own verdict in the batch pass below.
  single_want="$want"
  [ "$want" = load-failed ] && single_want=fail
  if [ "$got" != "$single_want" ]; then
    echo "PROBE FAIL: $name expected $single_want got $got"
    fails=$((fails+1))
  elif [ "$want" != ok ] && [ -z "$substring" ]; then
    # An empty substring matches anything, which would quietly turn the
    # row back into a bare verdict check.
    echo "PROBE FAIL: $name has no expected message substring"
    fails=$((fails+1))
  elif [ "$want" != ok ] && ! grep -qF "$substring" "$tmp/err"; then
    echo "PROBE FAIL: $name rejected without '$substring'"
    fails=$((fails+1))
  fi
  # A fixture with a .expected file pins its whole rendering: order,
  # positions, and carets, with the fixture path abstracted.
  if [ -f "$here/$name.expected" ]; then
    dir=$(cd "$here/$name" && pwd)
    if ! sed "s|$dir|\$DIR|g" "$tmp/err" | \
      diff -q - "$here/$name.expected" >/dev/null
    then
      echo "PROBE FAIL: $name rendering differs from $name.expected"
      sed "s|$dir|\$DIR|g" "$tmp/err" | \
        diff - "$here/$name.expected" | head -10
      fails=$((fails+1))
    fi
  fi
done < "$here/expected.tsv"

# The CLI contract: usage errors exit 1, distinct from both verdicts.
cli_check() {
  code=0
  "$checker" "$@" >/dev/null 2>&1 || code=$?
  if [ "$code" != "$cli_want" ]; then
    echo "PROBE FAIL: checker $* expected exit $cli_want got $code"
    fails=$((fails+1))
  fi
}
cli_want=0 cli_check --help
cli_want=1 cli_check --bogus-option
cli_want=1 cli_check "$here/clean_minimal" extra_positional
cli_want=1 cli_check --batch=/nonexistent-list "$here/clean_minimal"
cli_want=1 cli_check --path=
cli_want=1 cli_check --batch
cli_want=1 cli_check
cli_want=1 cli_check --path "" "$here/clean_minimal"
cli_want=1 cli_check --path --verbose "$here/clean_minimal"
cli_want=1 cli_check --path -h "$here/clean_minimal"
cli_want=1 cli_check --batch=
code=0
"$checker" --batch -h >/dev/null 2>"$tmp/err" || code=$?
if [ "$code" != 1 ] || ! grep -q -- "--batch needs a value" "$tmp/err"
then
  echo "PROBE FAIL: '--batch -h' expected exit 1 with its usage message"
  fails=$((fails+1))
fi
code=0
"$checker" "$here/clean_minimal" --path="$roots" --verbose \
  >/dev/null 2>"$tmp/err" || code=$?
if [ "$code" != 0 ] || ! grep -q "^Opening " "$tmp/err"; then
  echo "PROBE FAIL: --verbose expected exit 0 with Opening lines"
  fails=$((fails+1))
fi
# A batch case list naming one fixture twice: --verbose reports each
# file once, because the second load is served from the cache, and
# batch mode without --errors writes nothing to stderr at all.
printf '%s\n%s\n' "$here/clean_minimal" "$here/clean_minimal" \
  > "$tmp/twice"
code=0
"$checker" --batch="$tmp/twice" --path="$roots" --verbose \
  >/dev/null 2>"$tmp/err" || code=$?
opened=$(grep -c "^Opening " "$tmp/err" || true)
sources=$(find "$here/clean_minimal" "$roots/builtin" -name '*.pony' \
  | grep -c "")
if [ "$code" != 0 ] || [ "$opened" != "$sources" ]; then
  echo "PROBE FAIL: batch --verbose expected $sources Opening lines," \
    "one per file, got $opened"
  fails=$((fails+1))
fi
code=0
"$checker" --batch="$tmp/twice" --path="$roots" \
  >/dev/null 2>"$tmp/err" || code=$?
if [ "$code" != 0 ] || [ -s "$tmp/err" ]; then
  echo "PROBE FAIL: batch mode without --errors expected silent stderr"
  fails=$((fails+1))
fi
printf '%s\n' "$here/struct_behaviour_fail" > "$tmp/one_fail"
code=0
"$checker" --batch="$tmp/one_fail" --path="$roots" --errors \
  >"$tmp/bout" 2>"$tmp/err" || code=$?
if [ "$code" != 0 ] || \
  ! grep -q "struct behaviours are not allowed" "$tmp/err" || \
  ! grep -q "	fail$" "$tmp/bout"
then
  echo "PROBE FAIL: --errors expected the diagnostic on stderr and the"
  echo "  verdict on stdout"
  fails=$((fails+1))
fi
printf '%s\n%s\n' "$here/name_unresolved_fail" "$here/load_failed_root" \
  > "$tmp/err_cases"
code=0
"$checker" --batch="$tmp/err_cases" --path="$roots" --errors \
  >"$tmp/bout" 2>"$tmp/err" || code=$?
if [ "$code" != 0 ] || \
  ! grep -q "can't find declaration of 'nv'" "$tmp/err" || \
  ! grep -q "no Pony source files" "$tmp/err"
then
  echo "PROBE FAIL: --errors expected the name and load-failed"
  echo "  diagnostics on stderr"
  fails=$((fails+1))
fi
printf '%s\n' "$here/clean_minimal" > "$tmp/one_case"
code=0
"$checker" --batch "$tmp/one_case" --path="$roots" >/dev/null 2>&1 || code=$?
if [ "$code" != 0 ]; then
  echo "PROBE FAIL: --batch space form expected exit 0 got $code"
  fails=$((fails+1))
fi

# The batch driver must agree with the single runs, case by case.
( cd "$here" && printf '%s\n' $dirs ) > "$tmp/cases"
( cd "$here" && "$checker" --batch="$tmp/cases" --path="$roots" ) \
  > "$tmp/batch" 2>/dev/null || {
    echo "PROBE FAIL: batch run did not exit 0"
    fails=$((fails+1))
  }
while IFS="	" read -r name want _; do
  got=$(awk -F"	" -v n="$name" '$1 == n { print $2 }' "$tmp/batch")
  if [ "$got" != "$want" ]; then
    echo "PROBE FAIL: batch $name expected $want got '$got'"
    fails=$((fails+1))
  fi
done < "$here/expected.tsv"

# And its --errors rendering must be the single runs' renderings,
# concatenated in case order — across the 32-case and 256-item chunk
# boundaries.
( cd "$here" && "$checker" --batch="$tmp/cases" --path="$roots" \
  --errors ) >/dev/null 2>"$tmp/batch_err" || {
    echo "PROBE FAIL: batch --errors run did not exit 0"
    fails=$((fails+1))
  }
: > "$tmp/single_err"
while IFS="	" read -r name _ _; do
  ( cd "$here" && "$checker" "$name" --path="$roots" ) \
    >/dev/null 2>> "$tmp/single_err" || true
done < "$here/expected.tsv"
if ! diff -q "$tmp/batch_err" "$tmp/single_err" >/dev/null; then
  echo "PROBE FAIL: batch --errors rendering differs from the single runs"
  diff "$tmp/batch_err" "$tmp/single_err" | head -10
  fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then
  echo "probes: all pass"
else
  exit 1
fi
