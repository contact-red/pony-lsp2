#!/bin/sh
# The checker's probe fixtures. Each directory is a package;
# expected.tsv holds its verdict and, for a rejection, a substring the
# diagnostics must carry, so a fixture rejected for the wrong reason is
# a failure, not an agreement.
set -eu
# Comparisons that pin file order against sort order must not drift
# with the ambient locale.
LC_ALL=C
export LC_ALL
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
# An orphaned pin — a .expected whose fixture was renamed or removed —
# would otherwise never be opened again.
for exp in "$here"/*.expected; do
  base=$(basename "$exp" .expected)
  if ! [ -d "$here/$base" ]; then
    echo "PROBE FAIL: $exp has no fixture directory"
    fails=$((fails+1))
  fi
done
if [ "$dirs" != "$rows" ]; then
  echo "PROBE FAIL: fixture directories and expected.tsv disagree"
  echo "$dirs" > "$tmp/dirs"; echo "$rows" > "$tmp/rows"
  diff "$tmp/dirs" "$tmp/rows" || true
  exit 1
fi
# Walks of expected.tsv in file order are compared against walks of
# the directories in sorted order; the file must stay sorted for
# those comparisons to line up.
if [ "$(cut -f1 "$here/expected.tsv")" != "$rows" ]; then
  echo "PROBE FAIL: expected.tsv is not sorted by fixture name"
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
  elif [ "$want" = ok ] && [ -n "$substring" ]; then
    # A substring on an ok row is never read; flag it instead of
    # silently ignoring it.
    echo "PROBE FAIL: $name is ok but carries a substring"
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
    # The paths land in sed patterns, so regex metacharacters and the
    # delimiter must be literal.
    dir_re=$(printf '%s' "$dir" | sed 's/[][\.*^$|&]/\\&/g')
    roots_re=$(printf '%s' "$roots" | sed 's/[][\.*^$|&]/\\&/g')
    if ! sed -e "s|$dir_re|\$DIR|g" -e "s|$roots_re|\$ROOTS|g" \
      "$tmp/err" | diff -q - "$here/$name.expected" >/dev/null
    then
      echo "PROBE FAIL: $name rendering differs from $name.expected"
      sed -e "s|$dir_re|\$DIR|g" -e "s|$roots_re|\$ROOTS|g" \
        "$tmp/err" | diff - "$here/$name.expected" | head -10
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
cli_want=1 cli_check --path --files "$here/clean_minimal"
code=0
"$checker" "$here/clean_minimal" --errors >/dev/null 2>"$tmp/err" || code=$?
if [ "$code" != 1 ] || ! grep -q -- "--errors needs --batch" "$tmp/err"
then
  echo "PROBE FAIL: single-mode --errors expected exit 1 with its message"
  fails=$((fails+1))
fi
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
"$checker" "$here/clean_minimal" --path="$roots" --files \
  >/dev/null 2>"$tmp/err" || code=$?
if [ "$code" != 0 ] || ! grep -q "^Opening " "$tmp/err"; then
  echo "PROBE FAIL: --files expected exit 0 with Opening lines"
  fails=$((fails+1))
fi
# A batch case list naming one fixture twice: --files reports each
# file once, because the second load is served from the cache, and
# batch mode without --errors writes nothing to stderr at all.
printf '%s\n%s\n' "$here/clean_minimal" "$here/clean_minimal" \
  > "$tmp/twice"
code=0
"$checker" --batch="$tmp/twice" --path="$roots" --files \
  >/dev/null 2>"$tmp/err" || code=$?
opened=$(grep -c "^Opening " "$tmp/err" || true)
sources=$(find "$here/clean_minimal" "$roots/builtin" -name '*.pony' \
  | grep -c "")
if [ "$code" != 0 ] || [ "$opened" != "$sources" ]; then
  echo "PROBE FAIL: batch --files expected $sources Opening lines," \
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
printf '%s\t%s\n' "$here/clean_minimal" "x" > "$tmp/tabbed"
code=0
"$checker" --batch="$tmp/tabbed" --path="$roots" >"$tmp/bout" 2>"$tmp/err" \
  || code=$?
if [ "$code" != 1 ] || [ -s "$tmp/bout" ] || \
  ! grep -q "batch list holds a control character" "$tmp/err"
then
  echo "PROBE FAIL: tabbed batch line expected exit 1 before any verdict"
  fails=$((fails+1))
fi
printf '%s\n%s\t%s\n' "$here/clean_minimal" "$here/clean_minimal" "x" \
  > "$tmp/late_tab"
code=0
"$checker" --batch="$tmp/late_tab" --path="$roots" >"$tmp/bout" 2>"$tmp/err" \
  || code=$?
if [ "$code" != 1 ] || [ -s "$tmp/bout" ] || \
  ! grep -q "batch list holds a control character on line 2" "$tmp/err"
then
  echo "PROBE FAIL: control character after a good line expected exit 1"
  echo "  before any verdict, naming line 2"
  fails=$((fails+1))
fi
printf '%s\177x\n' "$here/clean_minimal" > "$tmp/del_list"
code=0
"$checker" --batch="$tmp/del_list" --path="$roots" >"$tmp/bout" 2>"$tmp/err" \
  || code=$?
if [ "$code" != 1 ] || [ -s "$tmp/bout" ] || \
  ! grep -q "batch list holds a control character" "$tmp/err"
then
  echo "PROBE FAIL: DEL in a batch line expected exit 1"
  fails=$((fails+1))
fi
printf '%s\r%s\n' "$here/clean_minimal" "x" > "$tmp/mid_cr"
code=0
"$checker" --batch="$tmp/mid_cr" --path="$roots" >"$tmp/bout" 2>"$tmp/err" \
  || code=$?
if [ "$code" != 1 ] || [ -s "$tmp/bout" ] || \
  ! grep -q "batch list holds a control character" "$tmp/err"
then
  echo "PROBE FAIL: mid-line carriage return expected exit 1"
  fails=$((fails+1))
fi
printf '%s\r\n' "$here/clean_minimal" > "$tmp/crlf_list"
code=0
"$checker" --batch="$tmp/crlf_list" --path="$roots" >/dev/null 2>&1 \
  || code=$?
if [ "$code" != 0 ]; then
  echo "PROBE FAIL: CRLF batch list expected exit 0 got $code"
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
# boundaries — each failing case's block directly under its own
# `<case>:` heading. The expectation is reconstructed whole, heading
# placement included.
( cd "$here" && "$checker" --batch="$tmp/cases" --path="$roots" \
  --errors ) >/dev/null 2>"$tmp/batch_err" || {
    echo "PROBE FAIL: batch --errors run did not exit 0"
    fails=$((fails+1))
  }
: > "$tmp/single_err"
while IFS="	" read -r name want _; do
  ( cd "$here" && "$checker" "$name" --path="$roots" ) \
    >/dev/null 2>"$tmp/one_err" || true
  if [ "$want" != ok ]; then
    printf '%s:\n' "$name" >> "$tmp/single_err"
    cat "$tmp/one_err" >> "$tmp/single_err"
  fi
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
