#!/usr/bin/env bash
# inspect_dataset.sh — schema + sample rows for an HF dataset, no Python deps.
# Wraps https://datasets-server.huggingface.co/ REST endpoints.
#
# Usage:
#   inspect_dataset.sh <dataset_id> [config] [split]
# Examples:
#   inspect_dataset.sh squad
#   inspect_dataset.sh trl-internal-testing/zen
#   inspect_dataset.sh allenai/tulu-3-sft-mixture default train

set -euo pipefail

DATASET="${1:-}"
CONFIG="${2:-}"
SPLIT="${3:-train}"

if [[ -z "$DATASET" ]]; then
    echo "Usage: $0 <dataset_id> [config] [split]" >&2
    echo "  dataset_id  e.g. squad, trl-internal-testing/zen" >&2
    exit 1
fi

if ! command -v jq >/dev/null; then
    echo "Error: jq is required. Install with: sudo pacman -S jq  /  apt install jq  /  brew install jq" >&2
    exit 1
fi

AUTH=()
if [[ -n "${HF_TOKEN:-}" ]]; then
    AUTH=(-H "Authorization: Bearer $HF_TOKEN")
fi

BASE="https://datasets-server.huggingface.co"

echo "=== Dataset: $DATASET ==="
echo "URL: https://huggingface.co/datasets/$DATASET"
echo

# --- Splits ---
echo "--- Splits ---"
splits_json=$(curl -fsSL "${AUTH[@]}" "$BASE/splits?dataset=$DATASET" 2>/dev/null) || {
    echo "ERROR: failed to fetch splits (dataset may not exist or is gated)" >&2
    echo "Try: curl -v '$BASE/splits?dataset=$DATASET'" >&2
    exit 2
}
echo "$splits_json" | jq -r '.splits[] | "  \(.config)/\(.split)"'
echo

# Pick first config if none given
if [[ -z "$CONFIG" ]]; then
    CONFIG=$(echo "$splits_json" | jq -r '.splits[0].config')
fi

echo "--- Schema (config=$CONFIG) ---"
info_json=$(curl -fsSL "${AUTH[@]}" "$BASE/info?dataset=$DATASET&config=$CONFIG" 2>/dev/null) || {
    echo "ERROR: failed to fetch info" >&2
    exit 2
}
_features_jq='
  to_entries[]
  | "  \(.key): " +
    ( .value
      | if type == "object" and has("dtype")     then .dtype
        elif type == "object" and has("_type")   then ._type
        elif type == "array"                     then "list[" + ((.[0] // {}) | tostring | .[0:80]) + (if length > 80 then "...]" else "]" end)
        else (tostring | .[0:120]) end )
'
( echo "$info_json" | jq -r ".dataset_info.features | $_features_jq" 2>/dev/null \
  || echo "$info_json" | jq -r ".dataset_info | (to_entries[0].value.features // {}) | $_features_jq" ) \
  || echo "  (could not parse features — try: curl -s '$BASE/info?dataset=$DATASET&config=$CONFIG' | jq)"
echo

# --- Sample rows ---
echo "--- First 3 rows (config=$CONFIG, split=$SPLIT) ---"
rows_json=$(curl -fsSL "${AUTH[@]}" "$BASE/first-rows?dataset=$DATASET&config=$CONFIG&split=$SPLIT" 2>/dev/null) || {
    echo "(could not fetch sample rows for $CONFIG/$SPLIT)"
    exit 0
}
echo "$rows_json" | jq -r '.rows[0:3] | .[] | "row \(.row_idx): \(.row | tostring | .[0:300])\(if (.row | tostring | length) > 300 then "..." else "" end)"'
echo

# --- Statistics (if available) ---
stats_json=$(curl -fsSL "${AUTH[@]}" "$BASE/statistics?dataset=$DATASET&config=$CONFIG&split=$SPLIT" 2>/dev/null) || stats_json=""
if [[ -n "$stats_json" ]]; then
    echo "--- Statistics ---"
    rows=$(echo "$stats_json" | jq -r '.num_examples // "?"')
    echo "  num_examples: $rows"
    echo "$stats_json" | jq -r '.statistics[]? | "  \(.column_name) (\(.column_type)): \(.column_statistics | tostring | .[0:200])"' 2>/dev/null || true
fi
