#!/usr/bin/env bash
# detect_compute.sh — single source of truth for the compute-mode decision.
#
# Outputs a JSON object with:
#   {
#     "platform": "linux" | "darwin" | "other",
#     "has_local_gpu": bool,
#     "gpus": [{"name": str, "vram_gb": int, "backend": "cuda"|"rocm"|"mps"}],
#     "cuda_available": bool,
#     "rocm_available": bool,
#     "mps_available": bool,            # Apple Silicon
#     "torch_installed": bool,
#     "disk_free_gb": int,              # free GB at $HF_HOME (or ~/.cache/huggingface)
#     "hf_auth_ok": bool,
#     "hf_user": str|null,
#     "hf_token_scope": "read"|"write"|"unknown"|null,
#     "resource_warnings": [str],       # e.g. ["low_vram_6gb", "low_disk_4gb"]
#     "compute_mode_recommendation": "local"|"jobs"|"ask_user"|"none"
#   }
#
# Thresholds: low_vram is < 8 GB; low_disk is < 30 GB free.
# When local would be picked but resources are tight AND HF Jobs is viable,
# the recommendation escalates to "ask_user" so the user can choose.
#
# The recommendation field encodes the 4-way decision:
#   local GPU + hf auth → "ask_user"
#   local GPU only      → "local"
#   hf auth only        → "jobs"
#   neither             → "none"
#
# Usage:
#   detect_compute.sh                # JSON to stdout
#   detect_compute.sh --human        # human-readable summary
#   detect_compute.sh --field gpus   # extract one field with jq

set -euo pipefail

MODE="json"
FIELD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --human|-H) MODE="human"; shift ;;
        --field|-f) FIELD="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── platform ──────────────────────────────────────────────────────────────────
case "$(uname -s)" in
    Linux*)   PLATFORM="linux" ;;
    Darwin*)  PLATFORM="darwin" ;;
    *)        PLATFORM="other" ;;
esac

# ── GPU detection: NVIDIA via nvidia-smi ──────────────────────────────────────
GPUS_JSON="[]"
CUDA_AVAILABLE="false"
ROCM_AVAILABLE="false"
MPS_AVAILABLE="false"

if command -v nvidia-smi >/dev/null 2>&1; then
    # Query: name, total memory in MiB. Format: csv, no header, no units.
    if raw=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null) && [[ -n "$raw" ]]; then
        CUDA_AVAILABLE="true"
        GPUS_JSON=$(echo "$raw" | awk -F', ' '
            BEGIN { print "[" }
            NR > 1 { print "," }
            {
                name = $1
                vram_mib = $2
                vram_gb = int((vram_mib + 512) / 1024)   # round to nearest GB
                gsub(/"/, "\\\"", name)
                printf "{\"name\":\"%s\",\"vram_gb\":%d,\"backend\":\"cuda\"}", name, vram_gb
            }
            END { print "]" }')
    fi
fi

# ── GPU detection: AMD via rocm-smi (only if no NVIDIA) ───────────────────────
if [[ "$CUDA_AVAILABLE" == "false" ]] && command -v rocm-smi >/dev/null 2>&1; then
    if raw=$(rocm-smi --showproductname --showmeminfo vram --csv 2>/dev/null) && [[ -n "$raw" ]]; then
        ROCM_AVAILABLE="true"
        # rocm-smi CSV format varies; treat as best-effort
        GPUS_JSON='[{"name":"AMD GPU (rocm-smi detected)","vram_gb":0,"backend":"rocm"}]'
    fi
fi

# ── GPU detection: Apple Silicon MPS ──────────────────────────────────────────
if [[ "$PLATFORM" == "darwin" ]] && [[ "$CUDA_AVAILABLE" == "false" ]]; then
    # Apple Silicon? Check arch.
    if [[ "$(uname -m)" == "arm64" ]]; then
        MPS_AVAILABLE="true"
        # Get total system RAM as a proxy for unified memory
        if ram_bytes=$(sysctl -n hw.memsize 2>/dev/null); then
            ram_gb=$((ram_bytes / 1024 / 1024 / 1024))
            GPUS_JSON=$(printf '[{"name":"Apple Silicon (unified memory)","vram_gb":%d,"backend":"mps"}]' "$ram_gb")
        fi
    fi
fi

HAS_LOCAL_GPU="false"
[[ "$CUDA_AVAILABLE" == "true" ]] && HAS_LOCAL_GPU="true"
[[ "$ROCM_AVAILABLE" == "true" ]] && HAS_LOCAL_GPU="true"
[[ "$MPS_AVAILABLE" == "true" ]] && HAS_LOCAL_GPU="true"

# ── PyTorch sanity probe ──────────────────────────────────────────────────────
TORCH_INSTALLED="false"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import torch" >/dev/null 2>&1; then
        TORCH_INSTALLED="true"
    fi
fi

# ── HF auth ───────────────────────────────────────────────────────────────────
HF_AUTH_OK="false"
HF_USER="null"
HF_TOKEN_SCOPE="null"

# Check for token: env var, then cli, then cached file
HF_TOKEN_FOUND=""
if [[ -n "${HF_TOKEN:-}" ]]; then
    HF_TOKEN_FOUND="$HF_TOKEN"
elif [[ -f "$HOME/.cache/huggingface/token" ]]; then
    HF_TOKEN_FOUND=$(cat "$HOME/.cache/huggingface/token" 2>/dev/null || true)
fi

if [[ -n "$HF_TOKEN_FOUND" ]]; then
    # whoami-v2 returns user info + token role (read/write/fineGrained)
    if whoami_resp=$(curl -fsSL -H "Authorization: Bearer $HF_TOKEN_FOUND" \
                     https://huggingface.co/api/whoami-v2 2>/dev/null); then
        HF_AUTH_OK="true"
        if command -v jq >/dev/null; then
            user=$(echo "$whoami_resp" | jq -r '.name // .fullname // null')
            scope=$(echo "$whoami_resp" | jq -r '.auth.accessToken.role // "unknown"')
            [[ "$user" != "null" ]] && HF_USER="\"$user\""
            HF_TOKEN_SCOPE="\"$scope\""
        fi
    fi
fi

# ── Disk space (free GB at HF cache root) ────────────────────────────────────
DISK_FREE_GB=0
DISK_PATH="${HF_HOME:-$HOME/.cache/huggingface}"
check_path="$DISK_PATH"
while [[ ! -e "$check_path" && "$check_path" != "/" ]]; do
    check_path=$(dirname "$check_path")
done
if df_out=$(df -BG "$check_path" 2>/dev/null | tail -1); then
    DISK_FREE_GB=$(echo "$df_out" | awk '{ s = $4; gsub("G","",s); print s+0 }')
fi

# ── Resource warnings ────────────────────────────────────────────────────────
warn_arr=()
MIN_VRAM_GB=0
if [[ "$HAS_LOCAL_GPU" == "true" ]] && command -v jq >/dev/null; then
    MIN_VRAM_GB=$(echo "$GPUS_JSON" | jq '[.[].vram_gb] | min // 0' 2>/dev/null || echo 0)
fi
if (( MIN_VRAM_GB > 0 && MIN_VRAM_GB < 8 )); then
    warn_arr+=("\"low_vram_${MIN_VRAM_GB}gb\"")
fi
if (( DISK_FREE_GB > 0 && DISK_FREE_GB < 30 )); then
    warn_arr+=("\"low_disk_${DISK_FREE_GB}gb\"")
fi
if (( ${#warn_arr[@]} > 0 )); then
    WARNINGS_JSON="[$(IFS=,; echo "${warn_arr[*]}")]"
else
    WARNINGS_JSON="[]"
fi

# ── Decision ──────────────────────────────────────────────────────────────────
if   [[ "$HAS_LOCAL_GPU" == "true" && "$HF_AUTH_OK" == "true" ]]; then RECOMMENDATION="ask_user"
elif [[ "$HAS_LOCAL_GPU" == "true" ]];                               then RECOMMENDATION="local"
elif [[ "$HF_AUTH_OK"   == "true" ]];                                then RECOMMENDATION="jobs"
else                                                                      RECOMMENDATION="none"
fi

# If local would be picked but resources are tight and Jobs is also viable,
# escalate to ask_user so the architect surfaces the trade-off.
if [[ "$RECOMMENDATION" == "local" && "$WARNINGS_JSON" != "[]" && "$HF_AUTH_OK" == "true" ]]; then
    RECOMMENDATION="ask_user"
fi

# ── Emit JSON ─────────────────────────────────────────────────────────────────
JSON=$(cat <<EOF
{
  "platform": "$PLATFORM",
  "has_local_gpu": $HAS_LOCAL_GPU,
  "gpus": $GPUS_JSON,
  "cuda_available": $CUDA_AVAILABLE,
  "rocm_available": $ROCM_AVAILABLE,
  "mps_available": $MPS_AVAILABLE,
  "torch_installed": $TORCH_INSTALLED,
  "disk_free_gb": $DISK_FREE_GB,
  "hf_auth_ok": $HF_AUTH_OK,
  "hf_user": $HF_USER,
  "hf_token_scope": $HF_TOKEN_SCOPE,
  "resource_warnings": $WARNINGS_JSON,
  "compute_mode_recommendation": "$RECOMMENDATION"
}
EOF
)

# Pretty-print if jq available
if command -v jq >/dev/null; then
    JSON=$(echo "$JSON" | jq .)
fi

# ── Output mode ───────────────────────────────────────────────────────────────
if [[ -n "$FIELD" ]]; then
    if command -v jq >/dev/null; then
        echo "$JSON" | jq -r ".$FIELD"
    else
        echo "$JSON"
    fi
elif [[ "$MODE" == "human" ]]; then
    echo "Platform: $PLATFORM"
    echo "Local GPU: $HAS_LOCAL_GPU"
    if [[ "$HAS_LOCAL_GPU" == "true" ]] && command -v jq >/dev/null; then
        echo "$JSON" | jq -r '.gpus[] | "  - \(.name) (\(.vram_gb)GB, \(.backend))"'
    fi
    echo "PyTorch: $TORCH_INSTALLED"
    echo "Disk free at $check_path: ${DISK_FREE_GB}GB"
    echo "HF auth: $HF_AUTH_OK${HF_USER:+ ($(echo "$HF_USER" | tr -d '"'))}"
    if [[ "$WARNINGS_JSON" != "[]" ]]; then
        echo "Warnings: $WARNINGS_JSON"
    fi
    echo "Recommendation: $RECOMMENDATION"
else
    echo "$JSON"
fi
