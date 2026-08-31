#!/bin/sh
# The checker's own probe fixtures: the shapes its reviews demonstrated,
# kept as cases so a regression in one is a named failure. Each directory
# is a package; expected.tsv holds its verdict.
set -e
here="$(dirname "$0")"
checker="$1"; roots="$2"
fails=0
while IFS="	" read -r name want; do
  "$checker" "$here/$name" --path="$roots" >/dev/null 2>&1 && got=ok || got=fail
  if [ "$got" != "$want" ]; then
    echo "PROBE FAIL: $name expected $want got $got"
    fails=$((fails+1))
  fi
done < "$here/expected.tsv"
[ "$fails" -eq 0 ] && echo "probes: all pass"
exit "$fails"
