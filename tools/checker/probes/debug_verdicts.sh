#!/bin/sh
# The ifdef-debug ordering assertions compile out of a release
# build. This runs every fixture through a debug build in one batch
# and checks each verdict still matches expected.tsv — a tripped
# assertion aborts the run before its verdict, so a crash cannot
# pass. The full rendering and CLI checks stay with run.sh against
# the release build; this gate exists only to evaluate the
# assertions.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
checker="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
roots="$(cd "$2" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cut -f1 "$here/expected.tsv" | sed "s|^|$here/|" > "$tmp/cases"
"$checker" --batch="$tmp/cases" --path="$roots" > "$tmp/verdicts"
fails=0
while IFS="	" read -r name want _; do
  got=$(awk -F"	" -v d="$here/$name" '$1 == d {print $2}' \
    "$tmp/verdicts")
  if [ "$got" != "$want" ]; then
    echo "DEBUG PROBE FAIL: $name expected $want got '$got'"
    fails=$((fails+1))
  fi
done < "$here/expected.tsv"
if [ "$fails" != 0 ]; then
  echo "debug probes: $fails fixtures disagree"
  exit 1
fi
echo "debug probes: all verdicts hold with assertions live"
