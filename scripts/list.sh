#!/usr/bin/env bash
# Every session file on disk, one per line: tier, size, mtime, path.
# Pure filesystem — no db, no import needed. This is the "list" half of list/import.
set -euo pipefail
ROOT="${1:-$HOME/.claude/projects}"
SORT="${2:-mtime}"

[ -d "$ROOT" ] || { echo "no such dir: $ROOT" >&2; exit 1; }

# Sort key -> (column, sort flags) for the emitted TSV: 1=tier 2=size 3=mtime 4=path.
# A closed case, same reason the db-backed list uses an enum: unknown keys are rejected,
# never passed through. (No SQL here — this half is pure filesystem — but the same rule
# keeps `just list sort=…` and `just sessions sort=…` behaving alike.)
case "$SORT" in
  tier)  KEY=1; FLAGS="" ;;
  size)  KEY=2; FLAGS="nr" ;;   # biggest first
  mtime) KEY=3; FLAGS="r" ;;    # newest first (default)
  path)  KEY=4; FLAGS="" ;;
  *) echo "unknown sort: $SORT (want: tier|size|mtime|path)" >&2; exit 2 ;;
esac

emit() {
  local tier="$1"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # %z size, %Sm mtime — BSD stat (macOS). GNU stat would need -c '%s %y'.
    stat -f "$tier	%z	%Sm	%N" -t '%Y-%m-%d %H:%M' "$f"
  done
}

{
  find "$ROOT" -maxdepth 2 -name '*.jsonl' | emit "session"
  find "$ROOT" -path '*/subagents/*.jsonl' -not -path '*/subagents/workflows/*' | emit "subagent"
  find "$ROOT" -path '*/subagents/workflows/*.jsonl' -not -name 'journal.jsonl' | emit "workflow"
} | sort -t"$(printf '\t')" -k"${KEY},${KEY}${FLAGS}" | awk -F'\t' -v sorted="$SORT" '
  BEGIN { printf "%-9s %10s  %-16s  %s   (sorted by %s)\n", "TIER", "BYTES", "MODIFIED", "PATH", sorted }
  { printf "%-9s %10s  %-16s  %s\n", $1, $2, $3, $4 }
'
