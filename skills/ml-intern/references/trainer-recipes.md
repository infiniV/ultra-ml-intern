# Canonical trainer recipes

Reference templates for the most common TRL trainers. Always **verify against current TRL source** before using — APIs evolve fast.

```bash
# Verify what's current:
curl -s https://raw.githubusercontent.com/huggingface/trl/main/trl/__init__.py | head -50
```

## SFT (SFTTrainer)

```python
from datasets import load_dataset
from transformers import AutoTokenizer
from trl import SFTConfig, SFTTrainer

model_id = "Qwen/Qwen3-7B-Instruct"
dataset = load_dataset("trl-internal-testing/zen", split="train")
tokenizer = AutoTokenizer.from_pretrained(model_id)

args = SFTConfig(
    output_dir="model",
    num_train_epochs=3,
    per_device_train_batch_size=4,
    gradient_accumulation_steps=4,           # effective batch 16
    gradient_checkpointing=True,
    learning_rate=2e-5,
    lr_scheduler_type="cosine",
    warmup_ratio=0.03,
    bf16=True,                                # A10G+ / A100 / L40S; use fp16 on T4
    max_seq_length=2048,
    logging_steps=10,
    logging_strategy="steps",
    logging_first_step=True,
    disable_tqdm=True,                        # so loss is greppable in hf jobs logs
    save_strategy="steps",
    save_steps=200,
    save_total_limit=3,
    eval_strategy="steps",
    eval_steps=200,
    seed=42,
    push_to_hub=True,
    hub_model_id="my-username/qwen3-7b-sft",
    hub_strategy="checkpoint",                # uploads every checkpoint
    report_to=["trackio"],
    attn_implementation="sdpa",               # safe default; flash_attention_2 needs flash-attn install
)

trainer = SFTTrainer(
    model=model_id,
    args=args,
    train_dataset=dataset,
    tokenizer=tokenizer,
    # SFTTrainer auto-detects messages/text/prompt+completion
)
trainer.train()
trainer.save_model()
trainer.push_to_hub()
```

## DPO (DPOTrainer)

```python
from trl import DPOConfig, DPOTrainer

# Dataset must have: prompt, chosen, rejected
dataset = load_dataset("trl-lib/ultrafeedback_binarized", split="train")

args = DPOConfig(
    output_dir="dpo-model",
    num_train_epochs=1,
    per_device_train_batch_size=2,
    gradient_accumulation_steps=8,
    gradient_checkpointing=True,
    learning_rate=5e-7,                       # DPO uses much smaller LR than SFT
    beta=0.1,                                 # KL strength; 0.1 is standard
    loss_type="sigmoid",                      # vs "ipo", "kto"
    max_length=2048,
    max_prompt_length=1024,
    bf16=True,
    logging_steps=10,
    disable_tqdm=True,
    push_to_hub=True,
    hub_model_id="my-username/qwen3-7b-dpo",
    report_to=["trackio"],
)

trainer = DPOTrainer(
    model="my-username/qwen3-7b-sft",         # start from SFT model
    ref_model=None,                            # auto-creates ref from base
    args=args,
    train_dataset=dataset,
    tokenizer=tokenizer,
)
trainer.train()
```

DPO common pitfalls:
- LR > 1e-6 → catastrophic forgetting
- Forgot to start from an SFT model → DPO needs the model to already follow instructions
- `chosen == rejected` rows in the dataset → loss collapses to 0

## GRPO (GRPOTrainer)

```python
from trl import GRPOConfig, GRPOTrainer
import re

# Dataset needs only "prompt" (and any extra fields used by reward fn)
dataset = load_dataset("trl-lib/tldr", split="train").select(range(1000))

# Define reward(s):
def correctness_reward(completions, **kwargs):
    answers = kwargs["answer"]                # column from dataset
    rewards = []
    for comp, ans in zip(completions, answers):
        # Extract final answer from generation, score against ground truth
        match = re.search(r"\\boxed\{([^}]+)\}", comp[0]["content"])
        rewards.append(1.0 if match and match.group(1).strip() == ans else 0.0)
    return rewards

args = GRPOConfig(
    output_dir="grpo-model",
    num_generations=8,                        # group size
    max_prompt_length=512,
    max_completion_length=1024,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=8,
    learning_rate=1e-6,
    beta=0.04,                                # KL penalty
    temperature=0.7,
    bf16=True,
    logging_steps=1,                          # GRPO is slow per step; log every step
    disable_tqdm=True,
    push_to_hub=True,
    hub_model_id="my-username/qwen3-7b-grpo",
    report_to=["trackio"],
)

trainer = GRPOTrainer(
    model="my-username/qwen3-7b-sft",
    args=args,
    reward_funcs=[correctness_reward],
    train_dataset=dataset,
    tokenizer=tokenizer,
)
trainer.train()
```

GRPO is **much slower** than SFT/DPO because it generates `num_generations` completions per step. Budget 5–10× the wall-clock vs equivalent SFT.

## QLoRA (any trainer + PEFT + bitsandbytes)

```python
from peft import LoraConfig
from transformers import BitsAndBytesConfig
import torch

bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.bfloat16,
    bnb_4bit_use_double_quant=True,
)

peft_config = LoraConfig(
    r=64,                                     # rank — 16 is min, 64 is "luxurious"
    lora_alpha=128,                           # typically 2× r
    lora_dropout=0.05,
    target_modules=[
        "q_proj", "k_proj", "v_proj", "o_proj",
        "gate_proj", "up_proj", "down_proj",
    ],
    task_type="CAUSAL_LM",
)

# Then pass to SFTTrainer/DPOTrainer:
trainer = SFTTrainer(
    model=model_id,
    args=args,
    train_dataset=dataset,
    tokenizer=tokenizer,
    peft_config=peft_config,                  # ← LoRA applied automatically
    model_init_kwargs={"quantization_config": bnb_config},  # ← 4-bit loading
)
```

Tips:
- For QLoRA: `max_seq_length=2048` fits 7B in 24GB; `max_seq_length=4096` needs 48GB.
- `target_modules` for LLaMA/Qwen architecture — check the model's config for other archs.
- After QLoRA training, merge with `model.merge_and_unload()` and push the merged model (smaller download for users).

## KTO (KTOTrainer)

```python
from trl import KTOConfig, KTOTrainer

# Dataset: prompt, completion, label (bool)
args = KTOConfig(
    output_dir="kto-model",
    learning_rate=5e-6,
    desirable_weight=1.0,
    undesirable_weight=1.0,
    beta=0.1,
    max_length=2048,
    bf16=True,
    push_to_hub=True,
    hub_model_id="my-username/qwen3-7b-kto",
    report_to=["trackio"],
)
trainer = KTOTrainer(model="...", args=args, train_dataset=dataset, tokenizer=tokenizer)
trainer.train()
```

## ORPO (ORPOTrainer)

Same dataset format as DPO, single-stage (combines SFT + preference).

```python
from trl import ORPOConfig, ORPOTrainer

args = ORPOConfig(
    output_dir="orpo-model",
    learning_rate=8e-6,
    beta=0.1,
    max_length=2048,
    bf16=True,
    push_to_hub=True,
    hub_model_id="my-username/qwen3-7b-orpo",
    report_to=["trackio"],
)
trainer = ORPOTrainer(model="<base>", args=args, train_dataset=dataset, tokenizer=tokenizer)
trainer.train()
```

ORPO benefits: no separate SFT stage needed; works from a base (non-instruct) model directly.

## Reward modeling (RewardTrainer)

```python
from trl import RewardConfig, RewardTrainer

args = RewardConfig(
    output_dir="reward-model",
    num_train_epochs=1,
    learning_rate=2e-5,
    per_device_train_batch_size=4,
    max_length=2048,
    bf16=True,
    push_to_hub=True,
    hub_model_id="my-username/qwen3-7b-rm",
    report_to=["trackio"],
)
trainer = RewardTrainer(model="<base>", args=args, train_dataset=dataset, tokenizer=tokenizer)
trainer.train()
```

The dataset has `chosen` and `rejected` (full text), and the model has a regression head.

## Cross-method common settings

These belong in **every** training script:

```python
disable_tqdm=True,
logging_strategy="steps",
logging_first_step=True,
seed=42,
push_to_hub=True,
hub_model_id="<user>/<name>",
hub_strategy="checkpoint",
report_to=["trackio"],
```

## When to deviate from these recipes

These are **starting points**, not production configs. Once you have a smoke run working:

- Tune LR by sweep (try 0.5×, 1×, 2× the recipe LR)
- Tune effective batch size by GPU memory utilization
- For long-context tasks: bump `max_length` and re-do hardware sizing
- For very small datasets (<1k examples): use higher LR and fewer epochs
- For very large datasets (>1M examples): single epoch is usually enough
