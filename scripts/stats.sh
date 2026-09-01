#!/usr/bin/env bash
# Real scale of the session corpus, split by the three file tiers.
# The tier split is the point: a walker that only globs <project>/*.jsonl sees the
# smallest tier and silently misses the rest (dig.py does exactly this today).
set -euo pipefail
ROOT="${1:-$HOME/.claude/projects}"

[ -d "$ROOT" ] || { echo "no such dir: $ROOT" >&2; exit 1; }

projects=$(find "$ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
tier1=$(find "$ROOT" -maxdepth 2 -name '*.jsonl' | wc -l | tr -d ' ')
tier2=$(find "$ROOT" -path '*/subagents/*.jsonl' -not -path '*/subagents/workflows/*' | wc -l | tr -d ' ')
tier3=$(find "$ROOT" -path '*/subagents/workflows/*.jsonl' -not -name 'journal.jsonl' | wc -l | tr -d ' ')
journals=$(find "$ROOT" -path '*/subagents/workflows/*' -name 'journal.jsonl' | wc -l | tr -d ' ')
total=$(find "$ROOT" -name '*.jsonl' | wc -l | tr -d ' ')
size=$(du -sh "$ROOT" 2>/dev/null | cut -f1)

printf '%s\n' "corpus: $ROOT"
printf '%s\n' "─────────────────────────────────────────────"
printf '%-34s %6s\n' "project directories"          "$projects"
printf '%-34s %6s\n' "tier 1  session .jsonl"       "$tier1"
printf '%-34s %6s\n' "tier 2  subagent .jsonl"      "$tier2"
printf '%-34s %6s\n' "tier 3  workflow agent .jsonl" "$tier3"
printf '%-34s %6s\n' "        workflow journal.jsonl" "$journals"
printf '%-34s %6s\n' "total .jsonl"                 "$total"
printf '%-34s %6s\n' "on disk"                      "$size"
printf '%s\n' "─────────────────────────────────────────────"
printf '%s\n' "a walker globbing only <project>/*.jsonl sees $tier1 of $total files."
