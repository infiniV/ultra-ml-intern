# Local-mode training

Load this when `detect_compute.sh` says local is viable and the user wants to run on their own GPU instead of HF Jobs.

## When local is the right call

- Smoke tests + sweeps where iteration speed matters (no submission queue)
- Models that fit in your VRAM (see size table below)
- Anything you'd run more than 3 times — local amortizes
- Sensitive datasets you can't ship to HF Jobs
- You don't have HF Jobs billing set up

## When HF Jobs wins

- Model + optimizer state too big for local VRAM
- Training run >12h (you don't want your laptop on a flight)
- Multi-GPU training and you have one local GPU
- You need a specific GPU class (A100 80GB, L40S, etc.)

## Detect first

Always run this before deciding:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/detect_compute.sh --human
```

Output tells you GPU + VRAM, HF auth status, and a recommendation. If `recommendation == "ask_user"`, ask the user explicitly.

## Local sizing (matches `hardware-sizing.md`)

| Local GPU | VRAM | Comfortably fits (full SFT, bf16, ctx=2048) | With QLoRA + grad checkpoint |
|---|---|---|---|
| RTX 3060 6GB / 8GB | 6–8 GB | ≤350M | up to 3B |
| RTX 3090 / 4090 | 24 GB | up to 1B | up to 7B |
| RTX A6000 / 6000 Ada | 48 GB | up to 3B | up to 13B |
| 2× 4090 NVLink (48GB) | 48 GB | up to 3B | up to 13B |
| Mac M1/M2 Pro 16GB unified | ~10 GB usable | ≤350M (MPS) | up to 1B (MPS, slow) |
| Mac M2/M3 Max 96GB unified | ~64 GB usable | up to 7B (MPS) | up to 30B (MPS, very slow) |

If your model doesn't fit local, default to HF Jobs (or use a smaller model for prototyping).

## Per-project venv setup (recommended)

Reuse the user's existing `.venv` if present in CWD; otherwise create one with `uv`:

```bash
# Inside the project directory:
if [ -d .venv ]; then
    source .venv/bin/activate
else
    uv venv .venv --python 3.12
    source .venv/bin/activate
fi

uv pip install \
    "torch>=2.5" \
    "transformers>=4.46" \
    "trl>=0.13" \
    "peft>=0.13" \
    "accelerate>=1.1" \
    "datasets>=3.0" \
    "trackio>=0.0.5" \
    "huggingface_hub[cli]>=0.26"
```

For NVIDIA users, torch installs CUDA wheels automatically. For ROCm: append `--index-url https://download.pytorch.org/whl/rocm6.2`. For Apple Silicon: torch ≥2.5 has native MPS support.

**Always create or use a venv** — never `uv pip install --system` on a local dev machine. That's an HF Jobs pattern (the job container is throwaway).

## Single-GPU local training

```bash
python -u train.py 2>&1 | tee training.log
```

`-u` for unbuffered stdout (loss prints in real time). `tee` keeps a log file you can grep.

## Multi-GPU local (data-parallel)

```bash
accelerate launch --num_processes=2 --multi_gpu train.py
```

Or with deepspeed for ZeRO:

```bash
accelerate launch --config_file ds_config.yaml train.py
```

## Long runs without keeping the terminal open

```bash
# tmux (recommended — survives ssh disconnects, scrollback intact)
tmux new -s train
python -u train.py 2>&1 | tee training.log
# Ctrl-b d to detach, `tmux attach -t train` to come back

# Or screen
screen -S train
# Ctrl-a d to detach

# Or nohup (simplest, but no scrollback)
nohup python -u train.py > training.log 2>&1 &
```

Don't use `&` alone — your job dies when you close the terminal.

## Pushing to Hub from local

`push_to_hub=True` works identically to HF Jobs mode. Requirements:

1. `HF_TOKEN` env var or `hf auth login` cached token
2. **Write scope** on the token (read-only tokens fail at push)
3. `hub_model_id` set in `TrainingArguments`

Verify before training:

```bash
hf auth whoami
# Test write access without uploading bytes:
python3 -c "from huggingface_hub import HfApi; HfApi().create_repo('${USER}/auth-check', exist_ok=False); HfApi().delete_repo('${USER}/auth-check')"
```

If that succeeds, your training script's `push_to_hub` will work.

## Trackio in local mode

Identical to Jobs mode — Trackio writes to an HF Space regardless of where training runs:

```python
import trackio
trackio.init(
    project="my-experiment",
    space_id="<username>/trackio-myexperiment",
    config={...},
)
```

The Space gets created automatically on first run.

## Common local-only pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `CUDA out of memory` immediately | Effective batch too large for local VRAM | Lower `per_device_train_batch_size`, raise `gradient_accumulation_steps`, enable `gradient_checkpointing=True` |
| `RuntimeError: bf16 not supported` | Old GPU (e.g., GTX 1080, T4-equivalent consumer cards) | `fp16=True` instead, OR upgrade to bf16-capable GPU (RTX 30/40/50 series, A-series) |
| `flash-attn` fails to install | Missing CUDA toolkit / wrong torch version | `uv pip install "flash-attn --no-build-isolation"` requires `torch` already installed; or skip and use `attn_implementation="sdpa"` |
| Training is fast but loss never decreases | Wrong tokenizer chat template, or `assistant_only_loss` not configured | Verify with `tokenizer.apply_chat_template(..., tokenize=False)` printing what you expect |
| Job survives terminal close but stops at logout | systemd's `RemoveIPC` killing user processes | Use `tmux`/`screen`, or `loginctl enable-linger $USER` |
| MPS (Mac) training crashes mid-run | MPS still has gaps for some ops | Set `PYTORCH_ENABLE_MPS_FALLBACK=1` to fall back to CPU for unsupported ops; or use `device="cpu"` for that layer |

## Pre-flight in local mode

`preflight_check.sh` accepts `--local` to skip HF-Jobs-specific checks (e.g., bf16-on-T4 doesn't apply locally because there's no T4 flavor):

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/preflight_check.sh train.py --local
```

Still validates: `push_to_hub=True`, `hub_model_id`, `disable_tqdm`, eval strategy, Trackio init.

## Cost confirmation

**Skipped in local mode.** Local training is ~free (electricity). The architect agent will still surface estimated wall-clock and a smoke-test option, but no dollar figure.

## Hybrid pattern: local smoke, Jobs full run

Best practice when you have both: **smoke locally, scale on Jobs**.

```bash
# 1. Smoke locally (free, fast iteration):
python train.py --max-steps 50 --output-dir /tmp/smoke

# 2. Once smoke passes, run real training on big hardware:
hf jobs run --flavor a100-large --timeout 14400 \
    --secrets HF_TOKEN -- bash -c '... python train.py ...'
```

This is the pattern the upstream `huggingface/ml-intern` calls "sandbox-first development" — local IS your sandbox.
