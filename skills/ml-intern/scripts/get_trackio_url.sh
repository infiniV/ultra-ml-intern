#!/usr/bin/env bash
# get_trackio_url.sh — extract the Trackio dashboard URL from a job's logs.
# Looks for "DASHBOARD_URL: https://..." or any HF Spaces URL referencing trackio.
#
# Usage:
#   get_trackio_url.sh <job_id>
#   get_trackio_url.sh --file path/to/logs.txt

set -euo pipefail

if [[ "${1:-}" == "--file" ]]; then
    if [[ -z "${2:-}" || ! -f "${2}" ]]; then
        echo "Usage: $0 --file <log_file>" >&2
        exit 1
    fi
    LOGS=$(cat "$2")
elif [[ -n "${1:-}" ]]; then
    if ! command -v hf >/dev/null; then
        echo "Error: 'hf' CLI not found. Install: pip install -U 'huggingface_hub[cli]'" >&2
        exit 1
    fi
    LOGS=$(hf jobs logs --tail 500 "$1" 2>&1)
else
    echo "Usage: $0 <job_id> | --file <log_file>" >&2
    exit 1
fi

# Try several patterns:
URL=$(echo "$LOGS" | grep -oE 'DASHBOARD_URL: *https?://[^ ]+' | head -1 | sed 's/^DASHBOARD_URL: *//') || true
if [[ -z "$URL" ]]; then
    URL=$(echo "$LOGS" | grep -oE 'https?://huggingface\.co/spaces/[^ ]+trackio[^ ]*' | head -1) || true
fi
if [[ -z "$URL" ]]; then
    URL=$(echo "$LOGS" | grep -oE 'https?://[^ ]+\.hf\.space[^ ]*' | head -1) || true
fi

if [[ -n "$URL" ]]; then
    echo "$URL"
else
    echo "No Trackio dashboard URL found in logs." >&2
    exit 2
fi
