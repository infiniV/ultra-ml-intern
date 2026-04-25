# Dataset audit procedure

Before training on any dataset — even a "well-known" one — audit it. This is the single highest-ROI activity in ML engineering.

> *"Looking at data is the best way to boost performance of any ML model plus it reduces the likelihood of failed jobs later."* — ml-intern system prompt

## What to check (the audit checklist)

1. **Schema** — column names, types
2. **Splits** — `train` / `validation` / `test` row counts
3. **Sample rows** — print 5–10 random rows from each split
4. **Distributions** — for label/categorical columns, value frequencies
5. **Anomalies** — class imbalance, missing values, duplicates, weird formats, outliers
6. **Format match** — do columns match your training method? (see `dataset-formats.md`)

## Tools (in order of preference)

### 1. `scripts/inspect_dataset.sh` (no Python deps)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/inspect_dataset.sh trl-internal-testing/zen
```

Wraps the **datasets-server REST API** (https://datasets-server.huggingface.co/). Gives you schema + splits + sample rows without installing `datasets` or downloading anything.

### 2. HF MCP server (if installed)

If you've enabled the Hugging Face MCP power-up, ask the assistant to use the dataset search / info tool. Returns the same data with richer formatting.

### 3. The `dataset-auditor` subagent (for deep audits)

```
Agent(subagent_type=dataset-auditor, prompt="Audit dataset trl-internal-testing/zen for SFT training")
```

Produces a structured report in <800 words with anomalies flagged.

### 4. Python (when REST endpoints can't compute what you need)

```python
from datasets import load_dataset
ds = load_dataset("trl-internal-testing/zen")
print(ds)
print(ds["train"].features)
print(ds["train"].shuffle(seed=42).select(range(5))[:])
```

Only use this if (1)–(3) can't answer the question. Loading a multi-GB dataset just to peek at columns is wasteful — datasets-server already has the metadata.

## Patterns to flag

### Class imbalance

Print value counts of label columns. If you see >90% of one class, the model will collapse to predicting it. Fix: weighted sampling, focal loss, or rebalance the dataset.

```bash
# Datasets-server statistics endpoint:
curl -s "https://datasets-server.huggingface.co/statistics?dataset=<id>&config=<config>&split=train" | jq '.statistics'
```

### Duplicates

For instruction datasets, duplicates inflate loss on common patterns and bias the model. Check with:

```python
ds_train = ds["train"].to_pandas()
print(f"Total: {len(ds_train)}, Unique: {ds_train['prompt'].nunique()}")
```

A unique-rate <90% is suspicious for instruction data.

### Empty / null cells

```python
print(ds["train"].to_pandas().isna().sum())
```

A `null` in the `chosen` column of a DPO dataset will silently break training.

### Format inconsistency

For conversational data, sample 20 rows and verify every `messages` array has at least one user + one assistant turn. ML datasets with broken conversation structure are surprisingly common.

```python
def is_valid_conv(row):
    msgs = row["messages"]
    roles = [m["role"] for m in msgs]
    return "user" in roles and "assistant" in roles

bad = ds["train"].filter(lambda x: not is_valid_conv(x))
print(f"Invalid rows: {len(bad)} / {len(ds['train'])}")
```

### Length distribution

If you set `max_seq_length=2048`, what fraction of examples gets truncated?

```python
import numpy as np
lengths = [len(tokenizer.apply_chat_template(x["messages"])) for x in ds["train"].select(range(1000))]
print(f"p50: {np.percentile(lengths, 50)}, p95: {np.percentile(lengths, 95)}, p99: {np.percentile(lengths, 99)}")
```

If p95 > `max_seq_length`, you're discarding context. Either bump `max_seq_length` (if VRAM allows) or filter long examples.

### Tokenizer mismatch

Did the dataset get tokenized with a different tokenizer than your model's? Check by re-tokenizing a sample with your model's tokenizer and comparing token counts to any pre-tokenized fields.

## Audit report template

When asked to audit, structure the output like this:

```
Dataset: <id>
URL: https://huggingface.co/datasets/<id>

Schema:
  - column1 (string)
  - column2 (int64)
  - ...

Splits:
  - train: 12,345 rows
  - validation: 1,000 rows

Recommended training method: SFT (matches "messages" column)

Sample rows:
  [show 3 rows in compact form]

Anomalies found:
  - 2.3% rows have empty assistant messages
  - p99 conversation length is 4096 tokens — will truncate at max_seq_length=2048
  - "messages" array sometimes ends mid-turn (no final assistant response)

Recommendations:
  - Filter empty assistant rows: ds.filter(lambda x: x["messages"][-1]["content"].strip() != "")
  - Consider max_seq_length=4096 (a100-large fits this)
```

## When NOT to audit

- The user is just asking a conceptual question, not actually training
- You've already audited this exact dataset earlier in the same session and nothing has changed
- The dataset is created on-the-fly by your script (audit the *source* dataset instead)

For everything else: audit first, train second.
