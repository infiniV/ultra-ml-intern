#!/usr/bin/env bash
# hf_paper_meta.sh — pull HF Papers metadata (linked Hub models, datasets, Spaces).
# HF Papers curates papers with their associated artifacts on the Hub.
#
# Usage:
#   hf_paper_meta.sh <arxiv_id>                  # full metadata (paper + summary + Hub artifacts)
#   hf_paper_meta.sh <arxiv_id> --datasets       # linked datasets (id + downloads + likes)
#   hf_paper_meta.sh <arxiv_id> --models         # linked models    (id + downloads + likes)
#   hf_paper_meta.sh <arxiv_id> --collections    # collections featuring the paper
#   hf_paper_meta.sh <arxiv_id> --all            # datasets + models + collections (compact)
#
# Examples:
#   hf_paper_meta.sh 2402.03300
#   hf_paper_meta.sh 2402.03300 --datasets

set -euo pipefail

case "${1:-}" in
    -h|--help|"") sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

ARXIV="$1"
shift
MODE="full"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --datasets)    MODE="datasets";    shift ;;
        --models)      MODE="models";      shift ;;
        --collections) MODE="collections"; shift ;;
        --all)         MODE="all";         shift ;;
        -h|--help)
            sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$ARXIV" ]]; then
    echo "Usage: $0 <arxiv_id> [--datasets|--models|--collections|--all]" >&2
    exit 1
fi

if ! command -v jq >/dev/null; then
    echo "Error: jq is required." >&2
    exit 1
fi

AUTH=()
if [[ -n "${HF_TOKEN:-}" ]]; then
    AUTH=(-H "Authorization: Bearer $HF_TOKEN")
fi

PAPER_URL="https://huggingface.co/api/papers/$ARXIV"
DATASETS_URL="https://huggingface.co/api/datasets?filter=arxiv:$ARXIV&sort=downloads&direction=-1&limit=50"
MODELS_URL="https://huggingface.co/api/models?filter=arxiv:$ARXIV&sort=downloads&direction=-1&limit=50"
COLLECTIONS_URL="https://huggingface.co/api/collections?paper=$ARXIV&limit=20"

case "$MODE" in
    full)
        JSON=$(curl -fsSL "${AUTH[@]}" "$PAPER_URL" 2>/dev/null) || {
            echo "ERROR: paper not found on HF Papers (or it's not yet indexed)." >&2
            echo "Try: curl -v '$PAPER_URL'" >&2
            exit 2
        }
        echo "=== HF Paper: $ARXIV ==="
        echo "URL: https://huggingface.co/papers/$ARXIV"
        echo
        # Combine paper metadata + linked artifact counts (cheap parallel fetches)
        DATASETS=$(curl -fsSL "${AUTH[@]}" "$DATASETS_URL" 2>/dev/null || echo '[]')
        MODELS=$(curl -fsSL   "${AUTH[@]}" "$MODELS_URL"   2>/dev/null || echo '[]')
        COLLS=$(curl -fsSL    "${AUTH[@]}" "$COLLECTIONS_URL" 2>/dev/null || echo '[]')
        jq -n --argjson p "$JSON" --argjson d "$DATASETS" --argjson m "$MODELS" --argjson c "$COLLS" '{
            title:        $p.title,
            summary:      ($p.summary // "" | .[0:500]),
            upvotes:      $p.upvotes,
            submitted_at: $p.publishedAt,
            github:       $p.githubRepo,
            authors:      [$p.authors[]?.name],
            datasets:     [$d[]?.id],
            models:       [$m[]?.id],
            collections:  [$c[]?.slug]
        }'
        ;;
    datasets)
        curl -fsSL "${AUTH[@]}" "$DATASETS_URL" \
            | jq -r '.[]? | {
                id,
                url: ("https://huggingface.co/datasets/" + .id),
                downloads: .downloads,
                likes: .likes,
                updated: .lastModified
              } | tojson'
        ;;
    models)
        curl -fsSL "${AUTH[@]}" "$MODELS_URL" \
            | jq -r '.[]? | {
                id,
                url: ("https://huggingface.co/" + .id),
                downloads: .downloads,
                likes: .likes,
                updated: .lastModified
              } | tojson'
        ;;
    collections)
        curl -fsSL "${AUTH[@]}" "$COLLECTIONS_URL" \
            | jq -r '.[]? | {
                slug,
                title,
                owner: .owner.name,
                upvotes: .upvotes,
                url: ("https://huggingface.co/collections/" + .slug)
              } | tojson'
        ;;
    all)
        DATASETS=$(curl -fsSL "${AUTH[@]}" "$DATASETS_URL" 2>/dev/null || echo '[]')
        MODELS=$(curl -fsSL   "${AUTH[@]}" "$MODELS_URL"   2>/dev/null || echo '[]')
        COLLS=$(curl -fsSL    "${AUTH[@]}" "$COLLECTIONS_URL" 2>/dev/null || echo '[]')
        jq -n --arg id "$ARXIV" --argjson d "$DATASETS" --argjson m "$MODELS" --argjson c "$COLLS" '{
            paper: ("https://huggingface.co/papers/" + $id),
            datasets:    [$d[]? | {id, downloads, likes}],
            models:      [$m[]? | {id, downloads, likes}],
            collections: [$c[]? | {slug, title}]
        }'
        ;;
esac
