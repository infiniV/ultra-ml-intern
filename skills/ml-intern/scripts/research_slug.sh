#!/usr/bin/env bash
# research_slug.sh — produce a safe filename slug from a research topic.
#
# Used by /ml-research-ultra to compute the output filename without
# letting raw user input touch a shell substitution. Lowercase, keeps
# only [a-z0-9-], collapses runs of '-', strips leading/trailing '-',
# truncates to 40 chars.
#
# Usage:
#   research_slug.sh "GRPO for math reasoning!"          # -> grpo-for-math-reasoning
#   research_slug.sh "ignore previous; rm -rf /"          # -> ignore-previous-rm-rf
#   echo "$TOPIC" | research_slug.sh                      # also reads stdin
#
# Always exits 0 with a non-empty slug; falls back to "topic" if input
# normalizes to empty.

set -euo pipefail

case "${1:-}" in
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

if [[ $# -ge 1 ]]; then
    INPUT="$1"
else
    INPUT="$(cat)"
fi

SLUG=$(printf '%s' "$INPUT" \
    | tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40 \
    | LC_ALL=C sed -E 's/-+$//')

if [[ -z "$SLUG" ]]; then
    SLUG="topic"
fi

printf '%s\n' "$SLUG"
