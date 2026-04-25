#!/usr/bin/env bash
# preflight_check.sh — sanity-check a training script before `hf jobs run`.
# Catches the most expensive recurring mistakes:
#   - Missing push_to_hub=True
#   - Missing hub_model_id
#   - Missing disable_tqdm (loss hidden in tqdm)
#   - Missing seed
#   - Missing eval_strategy
#   - flash_attention_2 without flash-attn install in script
#   - bf16=True on T4 hardware
#
# Usage:
#   preflight_check.sh path/to/train.py [--flavor a100-large]
#
# Exit code 0 if all checks pass, 1 if any FAIL, 2 if WARN-only.

set -euo pipefail

SCRIPT="${1:-}"
FLAVOR=""
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flavor) FLAVOR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$SCRIPT" || ! -f "$SCRIPT" ]]; then
    echo "Usage: $0 <path-to-training-script> [--flavor <hf-flavor>]" >&2
    exit 1
fi

FAIL=0
WARN=0

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    c_red()   { printf '\033[0;31m%s\033[0m' "$*"; }
    c_grn()   { printf '\033[0;32m%s\033[0m' "$*"; }
    c_yel()   { printf '\033[0;33m%s\033[0m' "$*"; }
else
    c_red()   { printf '%s' "$*"; }
    c_grn()   { printf '%s' "$*"; }
    c_yel()   { printf '%s' "$*"; }
fi

pass()  { echo "  $(c_grn PASS) $*"; }
fail()  { echo "  $(c_red FAIL) $*"; FAIL=$((FAIL+1)); }
warn()  { echo "  $(c_yel WARN) $*"; WARN=$((WARN+1)); }

echo "Pre-flight check: $SCRIPT"
echo

# --- Critical (FAIL) ---
echo "Critical checks:"

if grep -qE 'push_to_hub\s*=\s*True' "$SCRIPT"; then
    pass "push_to_hub=True is set"
else
    fail "push_to_hub=True is MISSING — model will be lost when job ends (FS is ephemeral)"
fi

if grep -qE 'hub_model_id\s*=\s*["'\''][^"'\'']+' "$SCRIPT"; then
    pass "hub_model_id is set"
else
    fail "hub_model_id is MISSING or empty — set hub_model_id=\"<user>/<name>\""
fi

if grep -qE 'trainer\.train\(' "$SCRIPT"; then
    pass "trainer.train() is called"
else
    fail "trainer.train() not found — script may only define configs without training"
fi

# --- Important (WARN) ---
echo
echo "Important checks:"

if grep -qE 'disable_tqdm\s*=\s*True' "$SCRIPT"; then
    pass "disable_tqdm=True (loss is greppable in logs)"
else
    warn "disable_tqdm not set — loss will be hidden in tqdm progress bars in hf jobs logs"
fi

if grep -qE 'logging_strategy\s*=\s*["'\'']steps' "$SCRIPT" \
   || grep -qE 'logging_steps\s*=' "$SCRIPT"; then
    pass "step-level logging configured"
else
    warn "no step-level logging — set logging_strategy=\"steps\" and logging_steps=10"
fi

if grep -qE 'logging_first_step\s*=\s*True' "$SCRIPT"; then
    pass "logging_first_step=True"
else
    warn "logging_first_step not set — recommend True so step 1 loss is visible"
fi

if grep -qE 'seed\s*=\s*[0-9]+' "$SCRIPT"; then
    pass "seed is set"
else
    warn "seed not set — recommend seed=42 for reproducibility"
fi

if grep -qE 'eval_strategy\s*=' "$SCRIPT" \
   || grep -qE 'evaluation_strategy\s*=' "$SCRIPT"; then
    pass "eval_strategy configured"
else
    warn "no eval_strategy — recommend eval_strategy=\"steps\" with eval_dataset"
fi

if grep -qE 'report_to\s*=\s*\[' "$SCRIPT" \
   || grep -qE 'trackio\.init' "$SCRIPT" \
   || grep -qE 'wandb\.init'   "$SCRIPT"; then
    pass "experiment tracking wired"
else
    warn "no Trackio/WandB init — recommend report_to=[\"trackio\"] in TrainingArguments"
fi

# --- Hardware / package mismatch (WARN) ---
echo
echo "Hardware / package consistency:"

if grep -qE 'attn_implementation\s*=\s*["'\'']flash_attention_2' "$SCRIPT"; then
    if grep -q 'flash-attn' "$SCRIPT" || grep -q 'flash_attn' "$SCRIPT"; then
        pass "flash_attention_2 used; flash-attn referenced (verify --no-build-isolation in install)"
    else
        warn "flash_attention_2 used but no flash-attn install seen in script — install with: uv pip install --system 'flash-attn --no-build-isolation'"
    fi
fi

if [[ "$FLAVOR" == "t4-"* ]]; then
    if grep -qE 'bf16\s*=\s*True' "$SCRIPT"; then
        fail "bf16=True on T4 hardware — T4 does NOT support bf16. Use fp16=True instead, or upgrade flavor."
    fi
fi

# --- Summary ---
echo
echo "----------------------------------------"
if [[ "$FAIL" -gt 0 ]]; then
    echo "$(c_red "FAIL: $FAIL critical issue(s)"), $(c_yel "$WARN warning(s)")"
    echo "Fix critical issues before submitting hf jobs run."
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo "$(c_grn "PASS"): $(c_yel "$WARN warning(s)") — consider fixing"
    exit 2
else
    echo "$(c_grn "PASS"): all checks passed"
    exit 0
fi
