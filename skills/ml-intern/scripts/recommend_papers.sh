#!/usr/bin/env bash
# recommend_papers.sh — find papers similar to a given paper via Semantic Scholar.
#
# Useful when the citation graph is sparse (recent paper, niche topic) — S2's
# recommender catches related work that hasn't yet cited each other.
#
# Usage:
#   recommend_papers.sh <arxiv_id> [--limit N]
#
# Output: JSON-line records — { title, year, cites, arxiv, abstract }.
#
# Auth: set S2_API_KEY env var for higher rate limits.

set -euo pipefail

if ! command -v jq >/dev/null; then
    echo "Error: jq is required." >&2
    exit 1
fi

case "${1:-}" in
    -h|--help|"") sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

ARXIV="$1"
shift
LIMIT=10
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)   LIMIT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)         echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ARXIV" ]]; then
    echo "Usage: $0 <arxiv_id> [--limit N]" >&2
    exit 1
fi

UA="ml-intern-skill/0.1"
AUTH=()
[[ -n "${S2_API_KEY:-}" ]] && AUTH=(-H "x-api-key: $S2_API_KEY")

URL="https://api.semanticscholar.org/recommendations/v1/papers/forpaper/arXiv:$ARXIV?limit=$LIMIT&fields=title,year,citationCount,abstract,externalIds"

curl -fsSL -H "User-Agent: $UA" "${AUTH[@]}" "$URL" \
    | jq -r '.recommendedPapers[]? | {
        title,
        year,
        cites:    .citationCount,
        arxiv:    .externalIds.ArXiv,
        abstract: (.abstract // "" | .[0:200])
      } | tojson'
