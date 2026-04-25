# Hardware sizing (HF Jobs + local)

For HF Jobs flavor names, see [Flavor table](#flavor-table) below. For local GPU sizing, see [Local hardware](#local-hardware).

Source for HF Jobs flavors: `huggingface/ml-intern/agent/tools/jobs_tool.py:31-58`. The flavor names below are the exact strings HF Jobs accepts.

## Flavor table

| Flavor | vCPU | RAM | GPU VRAM | Best for |
|---|---|---|---|---|
| `cpu-basic` | 2 | 16 GB | — | Lightweight scripts, dataset prep |
| `cpu-upgrade` | 8 | 32 GB | — | Heavier dataset prep, eval-only |
| `t4-small` | 4 | 15 GB | 16 GB (T4) | <1B model smoke tests |
| `t4-medium` | 8 | 30 GB | 16 GB (T4) | <1B model training |
| `a10g-small` | 4 | 15 GB | **24 GB** (A10G) | Inference, small fine-tunes |
| `a10g-large` | 12 | 46 GB | **24 GB** (A10G) | Same VRAM as `a10g-small` — more CPU/RAM |
| `a10g-largex2` | 24 | 92 GB | 48 GB (2×A10G) | 1–3B SFT |
| `a10g-largex4` | 48 | 184 GB | 96 GB (4×A10G) | 7B QLoRA |
| `a100-large` | 12 | 142 GB | 80 GB (A100) | 7–13B full SFT |
| `a100x4` | 48 | 568 GB | 320 GB (4×A100) | 30B SFT, 70B QLoRA |
| `a100x8` | 96 | 1136 GB | 640 GB (8×A100) | 70B SFT |
| `l4x1` | 8 | 30 GB | 24 GB (L4) | Inference, small fine-tunes |
| `l4x4` | 48 | 186 GB | 96 GB (4×L4) | 7B inference, eval at scale |
| `l40sx1` | 8 | 62 GB | 48 GB (L40S) | 7B SFT, fast inference |
| `l40sx4` | 48 | 382 GB | 192 GB (4×L40S) | 13B SFT, 30B QLoRA |
| `l40sx8` | 192 | 1534 GB | 384 GB (8×L40S) | 30B+ SFT alternative to A100x8 |
| `inf2x6` | — | — | — | Inferentia2 — specialized inference only |

## Default sizing rules

| Model parameters | Default flavor | Effective batch tip |
|---|---|---|
| < 1B | `t4-medium` or `a10g-small` | per_device 8–16, no grad accum |
| 1–3B | `a10g-largex2` | per_device 4, grad accum 4 |
| 7–13B | `a100-large` | per_device 1–2, grad accum 16+ |
| 30B+ | `l40sx4` or `a100x4` | DeepSpeed ZeRO-3, per_device 1, grad accum 32 |
| 70B+ | `a100x8` | DeepSpeed ZeRO-3 + offload, FSDP, per_device 1 |

## Method-aware sizing

QLoRA fits a much larger model than full SFT on the same VRAM. Rough rule:

| Hardware | Full SFT | LoRA | QLoRA (4-bit) |
|---|---|---|---|
| 24 GB (A10G/L4) | up to 1B | up to 3B | up to 7B |
| 48 GB (L40S/2×A10G) | up to 3B | up to 7B | up to 13B |
| 80 GB (A100) | up to 8B | up to 13B | up to 34B |
| 320 GB (4×A100) | up to 30B | up to 70B | up to 175B |

Numbers assume 2k context, bf16, no activation checkpointing. With `gradient_checkpointing=True` you can roughly 1.5× the model size at the cost of ~30% throughput.

## Common gotchas

- **`a10g-small` and `a10g-large` have the SAME 24GB GPU.** They differ only in vCPU/RAM. Don't pick `a10g-large` thinking it has more VRAM.
- **A10G ≠ A100.** A10G is 24 GB Ampere; A100 is 40/80 GB Ampere with much higher bandwidth. They're not interchangeable for large models.
- **L40S beats A10G per dollar** for many 7B fine-tunes. Check pricing on https://huggingface.co/pricing#spaces.
- **Multi-GPU defaults to DDP**, not FSDP/ZeRO. For >13B models you need `accelerate` or `deepspeed` in your script with the right plugin.

## Timeout sizing

`hf jobs run --timeout` accepts seconds, or a string like `"2h"`. Default is 30 minutes — **not enough for any training run**.

| Job type | Minimum timeout |
|---|---|
| Smoke test (<100 steps) | 30 min |
| <1B SFT, 1 epoch on small data | 2 h |
| 7B SFT, 1 epoch on 100k examples | 6 h |
| 7B GRPO, 500 steps | 8 h |
| 13B SFT, 1 epoch on 100k | 12 h |
| Anything 30B+ | 24 h+ |

When in doubt, set the timeout 2× your time estimate. A timeout-killed job is total loss; an over-budgeted job is just slightly more expensive.

## Cost reasoning (rough order of magnitude)

Per-hour rates change — always check https://huggingface.co/pricing. Order of magnitude (April 2026):

- T4 small: ~$0.50/h
- A10G large: ~$1.50/h
- A100 80GB: ~$5/h
- 8×A100: ~$40/h

A 70B SFT for 24h on 8×A100 is ≈$1000. Make the smoke test pass first.

## Local hardware

If `detect_compute.sh` reports a local GPU, prefer local training when the model fits — see `local-mode.md` for the full procedure.

| Local GPU | VRAM | Full SFT (bf16, ctx=2048) | With QLoRA + grad checkpoint |
|---|---|---|---|
| RTX 3060 6GB / 8GB Laptop | 6–8 GB | ≤350M | up to 3B |
| RTX 3070 / 4070 | 12 GB | ≤500M | up to 7B (tight) |
| RTX 3080 / 4080 | 16 GB | ≤700M | up to 7B |
| RTX 3090 / 4090 | 24 GB | up to 1B | up to 7B |
| 2× RTX 3090 / 4090 | 48 GB | up to 3B | up to 13B |
| A6000 / 6000 Ada | 48 GB | up to 3B | up to 13B |
| H100 PCIe / SXM | 80 GB | up to 8B | up to 34B |
| Apple M1/M2 16GB | ~10 GB usable (MPS) | ≤350M | up to 1B (slow) |
| Apple M2/M3 Max 96GB | ~64 GB usable (MPS) | up to 7B (slow) | up to 30B (very slow) |

### Local-vs-Jobs decision

| Question | If yes |
|---|---|
| Does the model fit my local VRAM? | local |
| Will the run take >12h? | Jobs (don't tie up your machine) |
| Do I need multi-GPU and have only one? | Jobs |
| Am I iterating (3+ runs)? | local (no submission queue) |
| Is the dataset gated and HF-token-required? | Jobs (HF_TOKEN auto-injected into job env) |
| Am I billing-blocked on Jobs? | local |

Run `${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/detect_compute.sh` to get an automated recommendation (`local` / `jobs` / `ask_user` / `none`).

### Hybrid pattern (when both available)

Smoke locally → scale on Jobs. Same upstream "sandbox-first" rule, with local as the sandbox:

```
local: python train.py --max-steps 50      ← catches 95% of bugs in 5 min, free
Jobs:  hf jobs run --flavor a100-large …   ← only after local smoke passes
```
