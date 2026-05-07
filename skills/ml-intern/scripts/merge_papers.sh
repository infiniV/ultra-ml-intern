#!/usr/bin/env bash
# merge_papers.sh — dedupe + overlap-count JSONL paper records from multiple
# crawl_arxiv.sh / recommend_papers.sh runs.
#
# Each input record is one JSON object per line, with at least an `arxiv`
# field (as produced by crawl_arxiv.sh and recommend_papers.sh). Records
# without `arxiv` are dropped (most likely papers without an arXiv ID).
#
# Output: one JSONL record per unique arxiv ID, with an added `overlap_count`
# field counting how many input records mentioned that arxiv. Sorted by
# overlap_count desc, then citations desc — so the "hub" papers (those
# surfaced by multiple search angles or both sides of the citation graph)
# float to the top.
#
# Usage:
#   cat layer0_*.jsonl layer1_*.jsonl | merge_papers.sh
#   merge_papers.sh layer0.jsonl layer1.jsonl
#   merge_papers.sh --min-overlap 3 layer0.jsonl layer1.jsonl
#   merge_papers.sh --top 30 layer0.jsonl layer1.jsonl
#
# Flags:
#   --min-overlap N   keep only records with overlap_count >= N
#   --top N           keep only the top N records after sorting
#   --ids-only        emit just the arxiv IDs, one per line
#
# Exit codes: 0 on success; 1 on bad args; 2 if jq missing.

set -euo pipefail

if ! command -v jq >/dev/null; then
    echo "Error: jq is required." >&2
    exit 2
fi

MIN_OVERLAP=1
TOP=""
IDS_ONLY=0
FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --min-overlap)
            MIN_OVERLAP="$2"
            shift 2
            ;;
        --top)
            TOP="$2"
            shift 2
            ;;
        --ids-only)
            IDS_ONLY=1
            shift
            ;;
        --)
            shift
            FILES+=("$@")
            break
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    INPUT=$(cat)
else
    INPUT=$(cat "${FILES[@]}")
fi

# Empty input is fine — emit nothing.
if [[ -z "${INPUT// }" ]]; then
    exit 0
fi

MERGED=$(printf '%s\n' "$INPUT" \
    | jq -c 'select(.arxiv != null and .arxiv != "")' \
    | jq -s --argjson min "$MIN_OVERLAP" '
        group_by(.arxiv)
        | map(
            (.[0]) + { overlap_count: length }
          )
        | map(select(.overlap_count >= $min))
        | sort_by(-(.overlap_count // 0), -(.cites // 0))
        | .[]
      ' \
    | jq -c .)

if [[ -n "$TOP" ]]; then
    MERGED=$(printf '%s\n' "$MERGED" | head -n "$TOP")
fi

if [[ "$IDS_ONLY" -eq 1 ]]; then
    printf '%s\n' "$MERGED" | jq -r '.arxiv'
else
    printf '%s\n' "$MERGED"
fi
