# `hf jobs run` cheatsheet

The HF Jobs API is the cloud compute backend. ml-intern wraps it with `agent/tools/jobs_tool.py`. From Claude Code, use it directly via `Bash` and the `huggingface_hub[cli]` package (which provides the `hf` CLI).

## One-time setup (per machine)

```bash
# Install the CLI (only if not already installed):
pip install -U "huggingface_hub[cli]"

# Authenticate — this caches the token in ~/.cache/huggingface/token:
hf auth login
# OR set HF_TOKEN in environment.

# Verify:
hf auth whoami
```

## Anatomy of an `hf jobs run` invocation

```bash
hf jobs run \
  --flavor a100-large \
  --timeout 7200 \
  --secrets HF_TOKEN \
  --image ghcr.io/astral-sh/uv:python3.12-bookworm \
  -- \
  bash -c '
    set -e
    uv pip install --system "torch" "transformers>=4.45" "trl" "peft" "accelerate" \
                   "datasets" "trackio" "bitsandbytes"
    python train.py
  '
```

Breakdown:

| Flag | What |
|---|---|
| `--flavor` | Hardware (see `references/hardware-sizing.md`) |
| `--timeout` | Hard kill after N seconds (or `"2h"`/`"30m"`). **Default 30m kills training.** |
| `--secrets HF_TOKEN` | Injects your local `HF_TOKEN` into the job env. Required for private datasets/models and for `push_to_hub`. |
| `--image` | Base Docker image. Default UV image is fine for most. For pre-built CUDA stacks use `nvidia/cuda:12.4.1-runtime-ubuntu22.04` and install Python yourself. |
| `--namespace` | Org/user the job runs under. Defaults to your auth. Use for billing org accounts. |
| `--detach` / `-d` | Don't stream logs; return immediately with a job ID. |
| `--env KEY=VAL` | Extra env vars (non-secret). |
| `-- <command>` | Everything after `--` is the actual command. |

## Streaming logs

```bash
# Follow logs of running job:
hf jobs logs -f <job_id>

# Get last 200 lines of finished job:
hf jobs logs --tail 200 <job_id>

# List your recent jobs:
hf jobs ps
hf jobs ps --all   # include finished/failed
```

## Cancel / kill

```bash
hf jobs cancel <job_id>
```

## Inspect

```bash
hf jobs inspect <job_id>     # full metadata
```

## Scheduled jobs

For sweeps + recurring eval:

```bash
hf jobs scheduled run --cron "0 2 * * *" --flavor a10g-small \
  -- python eval.py
hf jobs scheduled ps
hf jobs scheduled delete <id>
hf jobs scheduled suspend <id>
hf jobs scheduled resume <id>
```

## The "good job" template

```bash
hf jobs run \
  --flavor a100-large \
  --timeout 14400 \
  --secrets HF_TOKEN \
  -- \
  bash -c '
    set -euxo pipefail
    uv pip install --system \
      "torch==2.5.1" \
      "transformers>=4.46" \
      "trl>=0.13" \
      "peft>=0.13" \
      "accelerate>=1.1" \
      "datasets>=3.0" \
      "trackio>=0.0.5" \
      "bitsandbytes>=0.44"
    python -u train.py 2>&1 | tee -a training.log
  '
```

Notes:

- `set -euxo pipefail` makes the job fail loudly on any error
- Pin major versions so the same job is reproducible weeks later
- `python -u` for unbuffered stdout (logs stream in real time)
- `tee` lets you also `push_to_hub` the log file as an artifact

## Pre-flight (run before you submit)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/preflight_check.sh path/to/train.py
```

This script checks for the most common script-level bugs:

- `push_to_hub=True` is set
- `hub_model_id="..."` is non-empty
- `disable_tqdm=True` so loss is greppable
- A trainer is actually instantiated and trained (not just defined)
- `flash-attn` install matches `attn_implementation="flash_attention_2"` if used

## Cost estimation

Before submitting an expensive job, estimate cost:

```
total_cost ≈ (timeout_hours × hourly_rate × num_jobs)
```

For a 6-hour 7B SFT on `a100-large`: ~6 × $5 = $30 per job. A 24-job hyperparameter sweep is $720. Make the smoke test pass first.

## Common job failures and how to read them

| `hf jobs logs` shows... | Likely cause |
|---|---|
| `ImportError: flash_attn` | Forgot `--no-build-isolation` for flash-attn install, or didn't install it |
| `OSError: ... not a valid model identifier` | `hub_model_id` collision — model already exists under a different namespace |
| `CUDA out of memory` 30s in | Effective batch too large; see OOM recovery in `common-mistakes.md` |
| `CUDA OOM` during eval | Eval batch larger than train batch; set `per_device_eval_batch_size` smaller |
| Job exits at exactly the timeout, no error | You hit `--timeout` — extend it |
| `RuntimeError: NCCL` | Multi-GPU sync issue. Set `NCCL_DEBUG=INFO` env var to see what's wrong |
| `KeyError: 'messages'` | Dataset format mismatch; see `dataset-formats.md` |
| Training runs but loss stays at random init | Forgot to apply chat template, or `assistant_only_loss` not configured for SFT |
