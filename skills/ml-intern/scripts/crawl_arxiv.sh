#!/usr/bin/env bash
# crawl_arxiv.sh — search papers (HF Papers default, S2 bulk when filters); or
#                  walk the citation graph with influence flags + intents.
#
# Usage:
#   crawl_arxiv.sh "search query"                                    # ML-tuned search via HF Papers
#   crawl_arxiv.sh "query" --date-from 2024-01-01 --min-cites 10     # filtered → S2 bulk search
#   crawl_arxiv.sh "query" --field "Computer Science" --sort citationCount:desc
#   crawl_arxiv.sh --cited-by 2402.03300 [--limit N]                 # downstream citers (with influence + intents)
#   crawl_arxiv.sh --refs    2402.03300 [--limit N]                  # references (papers this one cites)
#   crawl_arxiv.sh --info    2402.03300                              # paper metadata
#
# Filters (search only): --date-from YYYY-MM-DD  --date-to YYYY-MM-DD
#                        --field "Computer Science"  --min-cites N
#                        --sort citationCount|publicationDate|paperId  (desc by default; use field:asc to flip)
#                        --loose  (disable automatic phrase-quoting of multi-word queries)
#
# Multi-word filtered queries are phrase-quoted automatically ("group relative
# policy optimization" matches the phrase, not any-keyword soup). Pass --loose
# for keyword matching, or use S2 boolean syntax yourself (quotes, |, +, -).
#
# Auth (optional): set S2_API_KEY env var for higher Semantic Scholar rate limits.
#
# All output is JSON-line records — fields vary by mode but always include arxiv where available.

set -euo pipefail

if ! command -v jq >/dev/null; then
    echo "Error: jq is required." >&2
    exit 1
fi

BASE="https://api.semanticscholar.org/graph/v1"
HF_API="https://huggingface.co/api"
LIMIT=20
MODE="search"
ARG=""
DATE_FROM=""
DATE_TO=""
FIELD=""
MIN_CITES=""
SORT=""
LOOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cited-by)  MODE="cited-by"; ARG="$2"; shift 2 ;;
        --refs)      MODE="refs";     ARG="$2"; shift 2 ;;
        --info)      MODE="info";     ARG="$2"; shift 2 ;;
        --limit)     LIMIT="$2";              shift 2 ;;
        --date-from) DATE_FROM="$2";          shift 2 ;;
        --date-to)   DATE_TO="$2";            shift 2 ;;
        --field)     FIELD="$2";              shift 2 ;;
        --min-cites) MIN_CITES="$2";          shift 2 ;;
        --sort)      SORT="$2";               shift 2 ;;
        --loose)     LOOSE=1;                 shift ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \?//'
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
AUTH=()
[[ -n "${S2_API_KEY:-}" ]] && AUTH=(-H "x-api-key: $S2_API_KEY")

# S2 bulk sort must be field:order — bare "citationCount" is an HTTP 400
[[ -n "$SORT" && "$SORT" != *:* ]] && SORT="${SORT}:desc"

case "$MODE" in
    search)
        if [[ -n "$DATE_FROM$DATE_TO$FIELD$MIN_CITES$SORT" ]]; then
            # Filtered search → Semantic Scholar bulk endpoint.
            # Bulk matches keywords anywhere unless phrase-quoted; multi-word
            # queries get quoted so a GRPO search doesn't return cardiology.
            QRAW="$ARG"
            if [[ $LOOSE -eq 0 && "$QRAW" == *" "* && "$QRAW" != *[\"\|\+\~\(]* ]]; then
                QRAW="\"$QRAW\""
            fi
            Q=$(printf %s "$QRAW" | jq -sRr @uri)
            URL="$BASE/paper/search/bulk?query=$Q&fields=title,year,citationCount,abstract,externalIds"
            [[ -n "$FIELD" ]]             && URL="$URL&fieldsOfStudy=$(printf %s "$FIELD" | jq -sRr @uri)"
            [[ -n "$MIN_CITES" ]]         && URL="$URL&minCitationCount=$MIN_CITES"
            [[ -n "$DATE_FROM$DATE_TO" ]] && URL="$URL&publicationDateOrYear=${DATE_FROM:-}:${DATE_TO:-}"
            [[ -n "$SORT" ]]              && URL="$URL&sort=$SORT"
            # Bulk ignores `limit` (returns up to 1000/page) — truncate locally
            curl -fsSL -H "User-Agent: $UA" "${AUTH[@]}" "$URL" \
                | jq -r --argjson lim "$LIMIT" '.data[:$lim][]? | {
                    title,
                    year,
                    citations: .citationCount,
                    arxiv: .externalIds.ArXiv,
                    abstract: (.abstract // "" | .[0:200])
                  } | tojson'
        else
            # Default search → HF Papers (ML-tuned, returns trending+relevance mix)
            Q=$(printf %s "$ARG" | jq -sRr @uri)
            curl -fsSL -H "User-Agent: $UA" \
                "$HF_API/papers/search?q=$Q&limit=$LIMIT" \
                | jq -r '.[]? | (.paper // .) | {
                    title,
                    year: ((.publishedAt // "")[0:4] | tonumber? // null),
                    upvotes,
                    citations: null,
                    arxiv: .id,
                    abstract: (.summary // "" | .[0:200])
                  } | tojson'
        fi
        ;;
    cited-by)
        curl -fsSL -H "User-Agent: $UA" "${AUTH[@]}" \
            "$BASE/paper/arXiv:$ARG/citations?limit=$LIMIT&fields=title,year,citationCount,abstract,externalIds,isInfluential,intents" \
            | jq -r '.data[]? | {
                title:       .citingPaper.title,
                year:        .citingPaper.year,
                citations:   .citingPaper.citationCount,
                arxiv:       .citingPaper.externalIds.ArXiv,
                abstract:    (.citingPaper.abstract // "" | .[0:200]),
                influential: .isInfluential,
                intents:     .intents
              } | tojson'
        ;;
    refs)
        curl -fsSL -H "User-Agent: $UA" "${AUTH[@]}" \
            "$BASE/paper/arXiv:$ARG/references?limit=$LIMIT&fields=title,year,citationCount,abstract,externalIds,isInfluential,intents" \
            | jq -r '.data[]? | {
                title:       .citedPaper.title,
                year:        .citedPaper.year,
                citations:   .citedPaper.citationCount,
                arxiv:       .citedPaper.externalIds.ArXiv,
                abstract:    (.citedPaper.abstract // "" | .[0:200]),
                influential: .isInfluential,
                intents:     .intents
              } | tojson'
        ;;
    info)
        curl -fsSL -H "User-Agent: $UA" "${AUTH[@]}" \
            "$BASE/paper/arXiv:$ARG?fields=title,year,authors,citationCount,abstract,externalIds,venue,openAccessPdf,tldr" \
            | jq '{
                title,
                year,
                venue,
                citations: .citationCount,
                arxiv: .externalIds.ArXiv,
                pdf: .openAccessPdf.url,
                tldr: .tldr.text,
                authors: [.authors[]?.name],
                abstract
              }'
        ;;
esac
