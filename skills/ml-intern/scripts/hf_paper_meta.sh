#!/usr/bin/env bash
# hf_paper_meta.sh — pull HF Papers metadata (linked Hub models, datasets, Spaces).
# HF Papers curates papers with their associated artifacts on the Hub.
#
# Usage:
#   hf_paper_meta.sh <arxiv_id>
#
# Example:
#   hf_paper_meta.sh 2402.03300

set -euo pipefail

ARXIV="${1:-}"

if [[ -z "$ARXIV" ]]; then
    echo "Usage: $0 <arxiv_id>" >&2
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

URL="https://huggingface.co/api/papers/$ARXIV"
echo "=== HF Paper: $ARXIV ==="
echo "URL: https://huggingface.co/papers/$ARXIV"
echo

curl -fsSL "${AUTH[@]}" "$URL" 2>/dev/null | jq '{
    title: .title,
    summary: (.summary // "" | .[0:500]),
    upvotes: .upvotes,
    submitted_at: .publishedAt,
    authors: [.authors[]?.name],
    models:   [.models[]?.id],
    datasets: [.datasets[]?.id],
    spaces:   [.spaces[]?.id],
    collections: [.collections[]?.slug]
}' || {
    echo "ERROR: paper not found on HF Papers (or it's not yet indexed)." >&2
    echo "Try: curl -v '$URL'" >&2
    exit 2
}
