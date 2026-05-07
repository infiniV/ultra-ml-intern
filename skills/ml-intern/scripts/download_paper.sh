#!/usr/bin/env bash
# download_paper.sh — fetch arXiv PDF and/or ar5iv HTML to a local archive.
#
# Useful for /ml-research-ultra runs where the user wants offline copies
# of every paper read during the run ("for the record"). Skip-if-exists
# makes it cache-friendly across re-runs.
#
# Usage:
#   download_paper.sh <arxiv_id>                              # both formats, ./papers/
#   download_paper.sh <arxiv_id> --format pdf                 # pdf only
#   download_paper.sh <arxiv_id> --format html                # html only
#   download_paper.sh <arxiv_id> --dir ~/research/grpo        # custom dir
#   download_paper.sh <arxiv_id> --no-skip                    # always re-fetch
#   echo "2402.03300" | download_paper.sh                     # stdin (one id per line)
#   download_paper.sh --batch ids.txt                          # batch from file
#
# Compose with merge_papers.sh:
#   merge_papers.sh layer*.jsonl --ids-only | download_paper.sh --dir ./papers
#
# Output: one line per paper with status — `OK <path>`, `SKIP <path> (exists)`,
# or `FAIL <id> (<reason>)`. Exit code 0 if every requested format for every
# id succeeded or was skipped; 1 if any failed.
#
# Polite: 1s sleep between batch entries to spare arXiv / ar5iv. Strictly
# validates arxiv ids against the new (YYMM.NNNNN[vN]) and old (subject/
# YYMMNNN[vN]) id grammars — rejects path-traversal and shell metacharacters.

set -euo pipefail

usage() { sed -n '2,26p' "$0" | sed 's/^# \?//'; }

FORMAT="both"
DIR="./papers"
SKIP_EXISTING=1
BATCH_FILE=""
IDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        --format)       FORMAT="$2"; shift 2 ;;
        --dir)          DIR="$2"; shift 2 ;;
        --no-skip)      SKIP_EXISTING=0; shift ;;
        --batch)        BATCH_FILE="$2"; shift 2 ;;
        --)             shift; IDS+=("$@"); break ;;
        -*)             echo "Unknown flag: $1" >&2; exit 1 ;;
        *)              IDS+=("$1"); shift ;;
    esac
done

case "$FORMAT" in
    pdf|html|both) ;;
    *) echo "Error: --format must be pdf | html | both (got: $FORMAT)" >&2; exit 1 ;;
esac

# Gather ids: positional args, then --batch file, then stdin if nothing given.
if [[ -n "$BATCH_FILE" ]]; then
    while IFS= read -r line; do
        line="${line//$'\r'/}"
        line="${line## }"
        line="${line%% }"
        [[ -n "$line" && ! "$line" =~ ^# ]] && IDS+=("$line")
    done < "$BATCH_FILE"
fi

if [[ ${#IDS[@]} -eq 0 ]]; then
    if [[ -t 0 ]]; then
        echo "Error: no arxiv ids given (positional, --batch, or stdin)." >&2
        usage >&2
        exit 1
    fi
    while IFS= read -r line; do
        line="${line//$'\r'/}"
        line="${line## }"
        line="${line%% }"
        [[ -n "$line" && ! "$line" =~ ^# ]] && IDS+=("$line")
    done
fi

mkdir -p "$DIR"

UA="ml-intern-skill/0.1 (research archive)"
FAIL_COUNT=0
FIRST=1

fetch_one() {
    local url="$1" dest="$2" id="$3" kind="$4"
    if [[ "$SKIP_EXISTING" -eq 1 && -s "$dest" ]]; then
        printf 'SKIP %s (exists)\n' "$dest"
        return 0
    fi
    if curl -fsSL --max-time 60 -A "$UA" -o "$dest" "$url"; then
        printf 'OK %s\n' "$dest"
        return 0
    else
        rm -f "$dest"
        printf 'FAIL %s (%s fetch failed)\n' "$id" "$kind"
        return 1
    fi
}

for ID in "${IDS[@]}"; do
    # Strict arxiv id grammar — rejects path-traversal and shell metachars.
    # New format: YYMM.NNNNN[vN]            e.g., 2402.03300, 2402.03300v2
    # Old format: subject[.XX]/YYMMNNN[vN]   e.g., cs/0301012, math.GT/0309001v1
    if ! [[ "$ID" =~ ^([0-9]{4}\.[0-9]{4,5}(v[0-9]+)?|[a-z-]+(\.[A-Z]{2})?/[0-9]{7}(v[0-9]+)?)$ ]]; then
        printf 'FAIL %s (invalid arxiv id format)\n' "$ID"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    # Polite delay between papers (skip on first iteration).
    if [[ $FIRST -eq 0 ]]; then sleep 1; fi
    FIRST=0

    if [[ "$FORMAT" == "pdf" || "$FORMAT" == "both" ]]; then
        fetch_one \
            "https://arxiv.org/pdf/${ID}.pdf" \
            "${DIR}/${ID}.pdf" \
            "$ID" "pdf" \
            || FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [[ "$FORMAT" == "html" || "$FORMAT" == "both" ]]; then
        fetch_one \
            "https://ar5iv.labs.arxiv.org/html/${ID}" \
            "${DIR}/${ID}.html" \
            "$ID" "html" \
            || FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "Done with $FAIL_COUNT failure(s)." >&2
    exit 1
fi
