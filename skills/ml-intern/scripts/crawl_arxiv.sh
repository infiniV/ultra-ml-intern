#!/usr/bin/env bash
# crawl_arxiv.sh — search arXiv via Semantic Scholar; or list papers that cite a given arxiv ID.
#
# Usage:
#   crawl_arxiv.sh "search query"                    # title/keyword search
#   crawl_arxiv.sh --cited-by 2402.03300 [--limit N] # papers citing this one
#   crawl_arxiv.sh --refs    2402.03300 [--limit N] # papers this one cites
#   crawl_arxiv.sh --info    2402.03300              # paper metadata
#
# All output is JSON-line records with: title, year, citations, arxiv_id, abstract (truncated).

set -euo pipefail

if ! command -v jq >/dev/null; then
    echo "Error: jq is required." >&2
    exit 1
fi

BASE="https://api.semanticscholar.org/graph/v1"
LIMIT=20
MODE="search"
ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cited-by) MODE="cited-by"; ARG="$2"; shift 2 ;;
        --refs)     MODE="refs";     ARG="$2"; shift 2 ;;
        --info)     MODE="info";     ARG="$2"; shift 2 ;;
        --limit)    LIMIT="$2";              shift 2 ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)  if [[ "$MODE" == "search" && -z "$ARG" ]]; then ARG="$1"; shift
            else echo "Unknown arg: $1" >&2; exit 1
            fi ;;
    esac
done

if [[ -z "$ARG" ]]; then
    echo "Usage: $0 \"<query>\" | --cited-by <arxiv_id> | --refs <arxiv_id> | --info <arxiv_id>" >&2
    exit 1
fi

# Polite UA — Semantic Scholar requests it
UA="ml-intern-skill/0.1"

case "$MODE" in
    search)
        # URL-encode the query (jq -sRr @uri is portable)
        Q=$(printf %s "$ARG" | jq -sRr @uri)
        curl -fsSL -H "User-Agent: $UA" \
            "$BASE/paper/search?query=$Q&limit=$LIMIT&fields=title,year,citationCount,abstract,externalIds" \
            | jq -r '.data[] | {
                title,
                year,
                citations: .citationCount,
                arxiv: .externalIds.ArXiv,
                abstract: (.abstract // "" | .[0:200])
              } | tojson'
        ;;
    cited-by)
        curl -fsSL -H "User-Agent: $UA" \
            "$BASE/paper/arXiv:$ARG/citations?limit=$LIMIT&fields=title,year,citationCount,abstract,externalIds" \
            | jq -r '.data[].citingPaper | {
                title,
                year,
                citations: .citationCount,
                arxiv: .externalIds.ArXiv,
                abstract: (.abstract // "" | .[0:200])
              } | tojson'
        ;;
    refs)
        curl -fsSL -H "User-Agent: $UA" \
            "$BASE/paper/arXiv:$ARG/references?limit=$LIMIT&fields=title,year,citationCount,abstract,externalIds" \
            | jq -r '.data[].citedPaper | {
                title,
                year,
                citations: .citationCount,
                arxiv: .externalIds.ArXiv,
                abstract: (.abstract // "" | .[0:200])
              } | tojson'
        ;;
    info)
        curl -fsSL -H "User-Agent: $UA" \
            "$BASE/paper/arXiv:$ARG?fields=title,year,authors,citationCount,abstract,externalIds,venue,openAccessPdf" \
            | jq '{
                title,
                year,
                venue,
                citations: .citationCount,
                arxiv: .externalIds.ArXiv,
                pdf: .openAccessPdf.url,
                authors: [.authors[].name],
                abstract
              }'
        ;;
esac
