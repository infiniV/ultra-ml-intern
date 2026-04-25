# Dataset format requirements by training method

Each TRL trainer expects specific columns. Mismatched columns → `KeyError` mid-training. Verify with `scripts/inspect_dataset.sh <dataset_id>` before writing your script.

## SFT (SFTTrainer)

Accepts any of three formats:

### Format A: conversational (`messages`)

```json
{"messages": [
  {"role": "system", "content": "You are a helpful assistant."},
  {"role": "user", "content": "What is 2+2?"},
  {"role": "assistant", "content": "4"}
]}
```

`SFTTrainer` auto-applies the model's chat template. **Preferred** for instruction tuning.

### Format B: completion (`text`)

```json
{"text": "Q: What is 2+2?\nA: 4"}
```

Single field, raw string. Use when you've already templated the data yourself or for continued pretraining.

### Format C: prompt + completion

```json
{"prompt": "Q: What is 2+2?\nA: ", "completion": "4"}
```

Loss is masked on prompt tokens, computed on completion tokens. Use when you want to train on completion-only loss with a non-chat-templated model.

## DPO (DPOTrainer)

```json
{
  "prompt": "What is 2+2?",
  "chosen": "4",
  "rejected": "5"
}
```

Or conversational:
```json
{
  "prompt": [{"role": "user", "content": "What is 2+2?"}],
  "chosen": [{"role": "assistant", "content": "4"}],
  "rejected": [{"role": "assistant", "content": "5"}]
}
```

Both `chosen` and `rejected` must be the model's response *only* (not include the prompt). Common bug: people concatenate prompt+chosen into one field — the loss math breaks silently.

## GRPO (GRPOTrainer)

```json
{"prompt": "Solve: x^2 = 4. What is x?"}
```

Just the prompt. The trainer generates `group_size` completions per prompt, scores them with a reward function you provide, and computes the GRPO loss. Reward functions are passed as Python callables, not in the dataset.

If your dataset has `answer` or `solution`, those are used by your reward function (your code reads them), not by the trainer directly.

## KTO (KTOTrainer)

```json
{
  "prompt": "What is 2+2?",
  "completion": "4",
  "label": true
}
```

`label: true` = desirable response, `label: false` = undesirable. KTO learns from binary signal (cheaper to collect than pairwise preferences).

## ORPO (ORPOTrainer)

Same format as DPO (`prompt`, `chosen`, `rejected`). Different loss — combines SFT loss + odds-ratio preference loss in one stage.

## Reward modeling (RewardTrainer)

```json
{
  "chosen": "<full chosen text>",
  "rejected": "<full rejected text>"
}
```

Or with `input_ids_chosen` / `attention_mask_chosen` / `input_ids_rejected` / `attention_mask_rejected` if pre-tokenized.

## PPO (PPOTrainer)

PPOTrainer expects pre-tokenized data via the `ppo_v2` dataloader. Check `huggingface/trl/examples/scripts/ppo/` for the current pattern — this API has changed multiple times.

## Verifying columns

```bash
# Quick column check via datasets-server REST (no Python needed):
scripts/inspect_dataset.sh trl-internal-testing/zen
# Or:
curl -s "https://datasets-server.huggingface.co/info?dataset=trl-internal-testing/zen" | jq '.dataset_info[].features'
```

## Common format mismatches

| Symptom | Likely cause | Fix |
|---|---|---|
| `KeyError: 'messages'` during SFT | Dataset has `text` only | Either use `dataset_text_field="text"` or convert with `dataset.map(...)` |
| `KeyError: 'chosen'` during DPO | Dataset uses `output_chosen` / non-standard names | `dataset.rename_columns({"output_chosen": "chosen", ...})` |
| Loss is suspiciously near zero from step 1 | DPO data has `chosen == rejected` (deduplication didn't run) | Filter `dataset.filter(lambda x: x["chosen"] != x["rejected"])` |
| GRPO never learns | Reward function returns constant or all-zero | Print rewards for first 10 batches to verify variance |
| SFT learns garbage | `messages` wasn't chat-templated, model ate raw JSON | Confirm chat template applied; check with `tokenizer.apply_chat_template(..., tokenize=False)` |

## Multi-turn conversations

For multi-turn SFT data, `messages` should contain the full conversation. SFTTrainer with `assistant_only_loss=True` (TRL ≥0.10) masks loss on user turns automatically — safest default for instruction tuning.

If your TRL version is older or doesn't support `assistant_only_loss`, you need to manually mask user tokens in a custom data collator. Use a current TRL where possible.
