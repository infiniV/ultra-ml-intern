# 8 mistakes (+ 1 cardinal sin) you will make without this skill

Distilled from `huggingface/ml-intern/agent/prompts/system_prompt_v3.yaml`. Each mistake is one the ml-intern team observed Claude making in real ML tasks.

## 1. Hallucinated imports

**Symptom:** `ImportError: cannot import name 'SFTTrainerConfig' from 'trl'`. Or `AttributeError: trackio has no attribute 'log'`.

**Cause:** Your training-data memory of TRL/Transformers/PEFT/Trackio APIs is from before the latest renames.

**Fix:** Read a current example before importing. One quick check:

```bash
# Get current TRL trainer exports:
curl -s https://raw.githubusercontent.com/huggingface/trl/main/trl/__init__.py | grep -E '^\s*"' | head -40

# Get current SFTConfig fields:
curl -s https://raw.githubusercontent.com/huggingface/trl/main/trl/trainer/sft_config.py | grep -E "^\s+\w+:\s+" | head -40

# Confirm Trackio API:
curl -s https://raw.githubusercontent.com/huggingface/trackio/main/trackio/__init__.py
```

## 2. Wrong trainer arguments

**Symptom:** `TypeError: __init__() got an unexpected keyword argument 'lr_scheduler'`.

**Cause:** Argument was renamed (`lr_scheduler` → `lr_scheduler_type`) or removed in a newer release.

**Fix:** Fetch the actual config file from the trainer's source. Don't trust your memory. Don't trust StackOverflow answers older than 6 months.

## 3. Wrong dataset format

**Symptom:** `KeyError: 'messages'` 30 seconds into training. Or worse: training "succeeds" but the model learned nothing because columns were wrong.

**Cause:** Assumed columns instead of inspecting the dataset.

**Fix:** Always run `scripts/inspect_dataset.sh <dataset_id>` first. Confirm columns match the training method (see `references/dataset-formats.md`).

## 4. Default 30m timeout kills jobs

**Symptom:** Job exits with status `timeout` after 1800 seconds. Logs show training was healthy and would have finished in 2 hours.

**Cause:** `hf jobs run` default `--timeout` is 30 minutes. Training takes hours.

**Fix:** Always pass `--timeout` explicitly. Minimum 2h for any real training run. See sizing in `references/hardware-sizing.md`.

```bash
hf jobs run --flavor a100-large --timeout 7200 ...
# 7200 = 2h. Or pass "2h" as a string.
```

## 5. Lost models (the worst one)

**Symptom:** Job completed successfully. You go to load the model. It's not on the Hub. The job's filesystem is gone. The model is gone.

**Cause:** Forgot `push_to_hub=True` and `hub_model_id="..."` in the trainer config. HF Jobs filesystems are **ephemeral** — deleted when the job ends.

**Fix:** Pre-flight checklist. **Every** training script must have:

```python
training_args = SFTConfig(
    output_dir="model",
    push_to_hub=True,
    hub_model_id="<your-username>/<model-name>",
    hub_strategy="checkpoint",  # push every checkpoint, not just final
    # ...
)
trainer.train()
trainer.push_to_hub()  # belt and suspenders
```

`hub_strategy="checkpoint"` saves you when the job hits its timeout — at least the latest checkpoint is on Hub.

## 6. Batch submission failures

**Symptom:** Submitted 8 ablation jobs. All 8 failed. Same error in each.

**Cause:** Submitted them all at once before verifying that the *first* one starts training successfully. The bug is in the shared script, not in the per-config args.

**Fix:** Submit one job. Wait 2 minutes. Run `hf jobs logs <id>` and confirm you see actual training step logs (not just dataset loading). **Then** submit the rest.

```bash
# Smoke test:
hf jobs run --flavor a10g-large --timeout 1800 ... -- python smoke_train.py
# Confirm logs show "step 10, loss=..."
# Then loop:
for lr in 1e-5 5e-5 1e-4; do
    hf jobs run ... -- python train.py --lr $lr
done
```

## 7. Silent dataset substitution

**Symptom:** User asked for fine-tuning on dataset A. You couldn't load A. You silently substituted B. The user trusts the result, deploys it, finds out months later.

**Cause:** When the requested resource fails, the path of least resistance is to find an alternative. Don't.

**Fix:** Tell the user. State exactly which dataset failed, why, and what alternatives exist. Let them pick.

```
Could not load `requested/dataset` — repository returned 404.

Alternatives:
- `similar/dataset` (1.2M rows, comparable schema, 2024)
- `another/option` (500k rows, smaller but cleaner)

Which would you like to use?
```

## 8. Hardcoded missing packages

**Symptom:** Job fails immediately: `ImportError: flash_attn`. Or `RuntimeError: CUDA out of memory` because you didn't install bitsandbytes for QLoRA.

**Cause:** HF Jobs uses a base UV image (`ghcr.io/astral-sh/uv:python3.12-bookworm`). It has Python and uv. **It does not have flash-attn, bitsandbytes, deepspeed, or any ML package** until you install them.

**Fix:** Install in your job script:

```bash
hf jobs run --flavor a100-large \
  -- bash -c '
    uv pip install --system "torch==2.4" "transformers" "trl" "peft" "accelerate" \
                   "datasets" "trackio" "bitsandbytes" "flash-attn --no-build-isolation"
    python train.py
  '
```

For `flash-attn`, always pass `--no-build-isolation` — without it, the build fails because torch isn't visible during the build step.

---

## Cardinal sin: scope-changing fixes

When something fails — especially OOM — your instinct will be to make the failure go away by changing what the user asked for. **Don't.**

| Bad fix | Why it's wrong | Correct fix |
|---|---|---|
| OOM → switch SFT to LoRA | LoRA learns differently. The user wanted full SFT. | Reduce per-device batch + bump grad accum. Upgrade GPU. |
| OOM → reduce `max_length` 2048→512 | Silently truncates 80% of training data. The model now learns to handle short inputs only. | Same as above. |
| OOM → disable Trackio "to save memory" | Trackio uses ~50 MB. Real culprit is elsewhere. Now you can't see training. | Find the real culprit (probably activations). Enable `gradient_checkpointing`. |
| Trainer fails → silently switch base model | User asked for base model X, gets Y. Different capability profile. | Surface the failure. Ask user. |
| Dataset fails to load → switch dataset | Mistake #7 above. | Surface and ask. |

**Rule:** Fix errors with the **minimal change that preserves the user's original task**. If the original genuinely cannot work, explain why and ask. Never silently change training method, sequence length, dataset, or base model.

## Other reliability traps (from ml-intern source)

These come from `agent/utils/reliability_checks.py` and the v2 system prompt:

- **No model save** in the script body → check `trainer.save_model()` or `push_to_hub=True` exists.
- **Logging hidden in tqdm** → always `disable_tqdm=True, logging_strategy="steps", logging_first_step=True` so loss prints as plain text greppable lines.
- **No eval split** → set `eval_strategy="steps"` and `eval_steps=...` so you have validation curves, not just train loss.
- **Missing `seed`** → set `seed=42` in TrainingArguments for reproducibility across runs.
- **`bf16=True` on T4** → T4 has no bf16 support. Use `fp16=True` instead, or upgrade to A10G/A100.
- **`flash_attention_2` without flash-attn installed** → either install it or switch to `attn_implementation="sdpa"` (fast and built into PyTorch).
