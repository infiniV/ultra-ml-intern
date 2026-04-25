#!/usr/bin/env bash
# snippet_search.sh — full-text passage search across 12M+ papers via Semantic Scholar.
#
# When you need a specific claim ("does dataset X outperform Y for task Z?",
# "what learning rate did GRPO follow-ups use?"), this returns the exact
# paper passages, not just titles. Mirrors huggingface/ml-intern's
# `hf_papers operation=snippet_search`.
#
# Usage:
#   snippet_search.sh "<query>" [--limit N] [--field "Computer Science"] \
#                               [--min-cites N] [--date-from YYYY-MM-DD] [--date-to YYYY-MM-DD]
#
# Output: JSON-line records — { snippet, section, paper, year, cites, arxiv, s2_id }.
#
# Auth: set S2_API_KEY env var for higher rate limits (free at semanticscholar.org/api).

set -euo pipefail

if ! command -v jq >/dev/null; then
    echo "Error: jq is required." >&2
    exit 1
fi

BASE="https://api.semanticscholar.org/graph/v1/snippet/search"
UA="ml-intern-skill/0.1"

QUERY=""
LIMIT=10
FIELD=""
MIN_CITES=""
DATE_FROM=""
DATE_TO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)      LIMIT="$2";       shift 2 ;;
        --field)      FIELD="$2";       shift 2 ;;
        --min-cites)  MIN_CITES="$2";   shift 2 ;;
        --date-from)  DATE_FROM="$2";   shift 2 ;;
        --date-to)    DATE_TO="$2";     shift 2 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown flag: $1" >&2; exit 1 ;;
        *)  QUERY="${QUERY:+$QUERY }$1"; shift ;;
    esac
done

if [[ -z "$QUERY" ]]; then
    echo "Usage: $0 \"<query>\" [--limit N] [--field FIELD] [--min-cites N] [--date-from YYYY-MM-DD] [--date-to YYYY-MM-DD]" >&2
    exit 1
fi

Q=$(printf %s "$QUERY" | jq -sRr @uri)
URL="$BASE?query=$Q&limit=$LIMIT"
[[ -n "$FIELD" ]]     && URL="$URL&fieldsOfStudy=$(printf %s "$FIELD" | jq -sRr @uri)"
[[ -n "$MIN_CITES" ]] && URL="$URL&minCitationCount=$MIN_CITES"
if [[ -n "$DATE_FROM" || -n "$DATE_TO" ]]; then
    URL="$URL&publicationDateOrYear=${DATE_FROM:-}:${DATE_TO:-}"
fi

AUTH=()
[[ -n "${S2_API_KEY:-}" ]] && AUTH=(-H "x-api-key: $S2_API_KEY")

# Capture body + status separately so we can give a meaningful 429 message
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT
HTTP_CODE=$(curl -sSL -o "$BODY_FILE" -w '%{http_code}' \
    -H "User-Agent: $UA" "${AUTH[@]}" "$URL" || echo 000)

case "$HTTP_CODE" in
    200)
        jq -r '.data[]? | {
            snippet: (.snippet.text // ""),
            section: (.snippet.snippetKind // ""),
            paper:   (.paper.title // ""),
            year:    .paper.year,
            cites:   .paper.citationCount,
            arxiv:   .paper.externalIds.ArXiv,
            s2_id:   .paper.corpusId
          } | tojson' < "$BODY_FILE"
        ;;
    429)
        echo "ERROR: Semantic Scholar rate-limited the snippet endpoint (HTTP 429)." >&2
        echo "       The /snippet/search endpoint throttles aggressively for anonymous calls." >&2
        echo "       Set S2_API_KEY (free at https://www.semanticscholar.org/product/api) to bypass." >&2
        exit 3
        ;;
    *)
        echo "ERROR: Semantic Scholar request failed (HTTP $HTTP_CODE)." >&2
        echo "URL: $URL" >&2
        head -c 500 "$BODY_FILE" >&2; echo >&2
        exit 2
        ;;
esac
