# Trackio monitoring

Trackio is HF's open-source experiment tracker (alternative to Weights & Biases). ml-intern wires it into every training run and exposes the dashboard URL to the user.

## Why Trackio (vs WandB)

- **Free, open-source.** No quota concerns.
- **Native Hub integration.** Logs are stored in an HF Space; the dashboard is just a Space URL.
- **Falls back gracefully.** If the user has WandB configured, you can use either.

## Minimum integration

```python
import trackio

# At the start of training:
trackio.init(
    project="my-finetune-experiment",
    name=f"sft-7b-lr5e5-{time.strftime('%Y%m%d-%H%M%S')}",
    space_id="<username>/<space-name>",  # auto-created if missing
    config={
        "model": "Qwen/Qwen3-7B-Instruct",
        "dataset": "trl-internal-testing/zen",
        "method": "SFT",
        "lr": 5e-5,
        "batch_size": 16,
    },
)

# TRL trainers respect HF_HOME / report_to settings.
# Easiest path is to add Trackio as a callback OR set:
training_args = SFTConfig(
    ...,
    report_to=["trackio"],  # if your TRL version supports it
)

trainer.train()
trackio.finish()
```

## API parameter caveats

Trackio is young and parameter names have churned. **Verify** before you write:

```bash
curl -s https://raw.githubusercontent.com/huggingface/trackio/main/trackio/__init__.py
curl -s https://raw.githubusercontent.com/huggingface/trackio/main/trackio/space.py | head -100
```

Common bugs:
- `run_name=` (does not exist) vs `name=` (correct)
- `space=` (old) vs `space_id=` (current as of 0.0.5)
- Forgetting `trackio.finish()` → space shows "running" forever

## Getting the dashboard URL

After `trackio.init`, the URL is `https://huggingface.co/spaces/<space_id>`. Print it from the script:

```python
print(f"DASHBOARD_URL: https://huggingface.co/spaces/{space_id}")
```

In `hf jobs logs`, grep for `DASHBOARD_URL:` to pull it back to the user.

`scripts/get_trackio_url.sh <job_id>` does this automatically.

## Logging during training

```python
# Inside a custom callback or training loop:
trackio.log({
    "train/loss": loss.item(),
    "train/learning_rate": current_lr,
    "train/grad_norm": grad_norm,
})

# Periodic eval:
trackio.log({
    "eval/loss": eval_loss,
    "eval/accuracy": eval_accuracy,
})
```

## Hyperparameter sweeps

Trackio doesn't have native sweep orchestration like WandB. Use a wrapper script:

```python
# sweep.py
import subprocess
configs = [
    {"lr": 1e-5}, {"lr": 5e-5}, {"lr": 1e-4},
    {"lr": 5e-4}, {"lr": 1e-3},
]
for cfg in configs:
    subprocess.run([
        "hf", "jobs", "run",
        "--flavor", "a100-large", "--timeout", "7200",
        "--secrets", "HF_TOKEN",
        "--", "python", "train.py",
        f"--lr={cfg['lr']}",
        f"--run-name=sweep-lr-{cfg['lr']}",
    ])
```

Each job logs to the same Trackio Space; the dashboard groups them by run name.

## When NOT to use Trackio

- Single-step debugging — overkill, just use print
- The user explicitly prefers WandB — use `report_to=["wandb"]` instead
- Air-gapped environments — Trackio writes to an HF Space, which needs internet

## Wiring it into the pre-flight checklist

The pre-flight check at `scripts/preflight_check.sh` looks for one of:

- `import trackio` AND `trackio.init(`
- `report_to=["trackio"]` in TrainingArguments

If neither is present, the check warns. If the user explicitly opts out (e.g. comment `# no-monitoring: small smoke test`), skip the warning.

## Caveats observed in production

These are real things that bit us during smoke-testing. Surface them to the user when wiring Trackio.

### 1. Dashboard URL doesn't appear at the start of training

When `report_to=["trackio"]` is used, the dashboard is published as a Hugging Face **Static Space** that gets deployed mid-training, not in the first ~10 lines of the `trainer.train()` output. Don't tell the user "look for the URL right after training starts." Tell them "the Trackio Space URL appears in the logs once the first checkpoint is uploaded — usually a minute or two in."

A reliable way to surface it: print the expected Space URL yourself before training:

```python
print(f"DASHBOARD_URL: https://huggingface.co/spaces/{hf_user}/<your-trackio-space-name>")
```

Then `scripts/get_trackio_url.sh` greps for `DASHBOARD_URL:` regardless of whether transformers' callback has emitted it yet.

### 2. `TRACKIO_PROJECT` env var is not honored by `transformers.integrations.TrackioCallback`

In `transformers <= 5.6.x`, the built-in `TrackioCallback` ignores `os.environ["TRACKIO_PROJECT"]` and uses a hardcoded default project name (`"huggingface"`). If the user wants a custom project, do **not** rely on the env var. Two reliable options:

```python
# Option A — call trackio.init explicitly before the trainer
import trackio
trackio.init(project="ml-intern-smoke-test", name=run_name, space_id=f"{hf_user}/ml-intern-trackio")

# Then keep report_to=["trackio"] in the Config so the trainer logs into the same project.
```

```python
# Option B — set TrainingArguments.run_name (which TrackioCallback does honor)
args = SFTConfig(
    ...,
    run_name="ml-intern-smoke-test",
    report_to=["trackio"],
)
```

### 3. Exit code 1 does NOT necessarily mean training failed

When Trackio is wired in, its post-run log upload runs **after** `trainer.train()` returns. If that upload fails (most common cause: disk filled up during training), the training process exits 1 even though the model and the final checkpoint were already pushed to Hub successfully.

When a TRL training script with Trackio exits non-zero:

1. **Check the Hub model first**, before assuming training failed:
   ```bash
   hf repo info <user>/<model> 2>/dev/null && echo "model is on Hub — training likely succeeded"
   ```
2. Then look at the tail of `training.log` for the final loss to confirm the loss curve completed.
3. If the model is on Hub and the loss completed, treat the run as a success and report the Trackio upload error as a separate, recoverable issue (rerun `trackio sync` or just discard the local Trackio data).

The architect agent encodes this in the "Mistakes it prevents" list, but it's worth restating in the post-run summary the user actually sees.
