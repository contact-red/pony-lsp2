#!/bin/sh
# The pins against ponyc itself: for every Error line a fixture's
# .expected pins, if ponyc emits that message anywhere for the
# fixture, it must emit it at the pinned position — the column
# oracle's rule applied to the probe suite. A pin recorded from a
# wrong rendering is otherwise indistinguishable from a right one.
# Recorded divergences live in parity_exceptions.tsv, one fixture
# per row with the reason.
set -eu
here="$(dirname "$0")"
ponyc="$1"
roots="$(cd "$2" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
checked=0
for exp in "$here"/*.expected; do
  name=$(basename "$exp" .expected)
  if cut -f1 "$here/parity_exceptions.tsv" 2>/dev/null | \
    grep -qxF "$name"
  then
    continue
  fi
  dir=$(cd "$here/$name" && pwd)
  ( cd "$dir" && "$ponyc" -b x -o "$tmp/out" --path="$roots" . \
    2>&1 || true ) | \
    sed -e "s|$dir/||g" -e "s|$roots|\$ROOTS|g" \
    > "$tmp/pony"
  sed -e 's|^\$DIR/||' -e "s|^    \\\$DIR/.*||" "$exp" | \
    grep -E '^[^ ]+:[0-9]+:[0-9]+: ' > "$tmp/pin" || true
  if ! awk -F': ' '
    NR == FNR {
      split($0, parts, ": ")
      pos = parts[1]
      msg = substr($0, length(pos) + 3)
      seen[msg] = seen[msg] SUBSEP pos SUBSEP
      next
    }
    {
      split($0, parts, ": ")
      pos = parts[1]
      msg = substr($0, length(pos) + 3)
      if ((msg in seen) && \
        index(seen[msg], SUBSEP pos SUBSEP) == 0)
      {
        print "  pinned " pos " but ponyc places \"" msg "\" at:" \
          seen[msg]
        bad = 1
      }
    }
    END { exit bad }
  ' "$tmp/pony" "$tmp/pin"
  then
    echo "PARITY FAIL: $name"
    fails=$((fails+1))
  fi
  checked=$((checked+1))
done
if [ "$fails" != 0 ]; then
  echo "probe parity: $fails of $checked pinned fixtures disagree"
  exit 1
fi
echo "probe parity: $checked pinned fixtures agree with ponyc"
