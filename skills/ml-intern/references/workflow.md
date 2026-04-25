# The 6-step research-driven workflow

Load this when starting any non-trivial ML task — fine-tuning, post-training, building a recipe from scratch, or trying to reproduce a published result.

## Why this order

ML failures cluster into two buckets: (a) wrong recipe (wrong dataset / wrong method / wrong hyperparams) and (b) wrong code (deprecated API, wrong column name). Research first eliminates (a). Validation before training eliminates (b). The remaining ~5% of failures are real surprises worth iterating on.

## The loop

### 1. Find the landmark paper(s)

Start from what the user asked for and find the foundational paper(s).

- "Fine-tune for math reasoning" → GRPO (DeepSeek-Math, arxiv:2402.03300), STaR, RFT
- "Instruction tune" → InstructGPT, FLAN, Alpaca, Tulu
- "RLHF" → InstructGPT (2203.02155), DPO (2305.18290), GRPO
- "Vision-language" → LLaVA, BLIP-2, Flamingo, Idefics

If you don't know the landmark, run `scripts/crawl_arxiv.sh "<task description>"` or dispatch the `ml-paper-researcher` subagent.

### 2. Crawl the citation graph

The landmark paper is rarely the SOTA. The papers that *cite* it are. Find them.

```bash
# In a Bash call:
scripts/crawl_arxiv.sh --cited-by 2402.03300 --limit 20
```

Or use Semantic Scholar via WebFetch:
```
https://api.semanticscholar.org/graph/v1/paper/arXiv:2402.03300/citations?fields=title,year,citationCount,abstract&limit=30
```

Filter for: recent (last 12–18 months), high citation count, published at major venues (ICLR/NeurIPS/ICML/ACL/EMNLP/COLM), strong benchmark numbers in the abstract.

### 3. Read methodology, not abstracts

Sections 3, 4, 5 of an ML paper are where the recipe lives:

- **Section 3 (Method)**: training objective, loss formulation, algorithm
- **Section 4 (Experiments / Setup)**: dataset, preprocessing, hyperparameters, hardware, training duration
- **Section 5 (Results / Analysis)**: ablations — which components matter

Abstracts lie by omission. The abstract says "trained on diverse internet text" — section 4 says "filtered to 12B tokens with quality classifier X."

Skip the related-work section unless you need more papers.

### 4. Extract the recipe

Make a structured note. One row per finding. Cite the exact paper section.

```
Result          : 85.3% on MATH (DeepSeek-Math, §4.2)
Method          : GRPO over base SFT model
Dataset (SFT)   : 7.5M math problems (DeepSeek-Math, §3.1)
Dataset (GRPO)  : MATH train split (12.5k problems)
Reward          : Rule-based correctness on final answer
Hyperparams     : lr=1e-6, group_size=64, kl=0.04 (Table 3)
Training        : 144h on 64×A100 80GB (§4.3)
```

If a paper doesn't tell you a hyperparameter, look at its released code (`paperswithcode.com`, the paper's GitHub). If the code is gone, *don't* guess — find a different paper or ask the user.

### 5. Validate before writing code

- Does the dataset exist on Hub? `scripts/inspect_dataset.sh <dataset_id>` confirms columns + splits + row counts.
- Does the base model exist? `curl -s https://huggingface.co/api/models/<model_id> | jq` confirms it loads.
- Is the trainer's argument list current? Fetch the current `TRL` source for the trainer class — `curl -s https://raw.githubusercontent.com/huggingface/trl/main/trl/trainer/sft_config.py | head -200`.
- Does the dataset's column shape match the training method? See `references/dataset-formats.md`.

If any of these fail, **stop and tell the user** before writing code.

### 6. Implement with current API patterns

Find a *current* working example on GitHub before writing your own:

```bash
gh search code --language=python --filename=train.py "SFTTrainer" --limit=5
# or
gh search code --language=python "trainer = GRPOTrainer" --limit=5
```

Open one or two recent results, see the actual import paths and argument names. Then write your script.

Cross-check against `huggingface/trl/examples/scripts/` — that directory is kept current with the library.

## What this loop is not

- It is **not** a one-shot. Steps 1–5 may iterate (paper says X dataset is best, dataset doesn't exist, find the next-best paper).
- It is **not** optional. Skipping research → hallucinated imports → broken job → wasted 6h cluster run.
- It is **not** for trivial tasks. "What's the dtype of bf16?" → just answer it.

## When to call the research subagent vs. doing it inline

Inline (in main thread) when:
- You only need to verify ONE specific paper or recipe.
- You already know the arxiv ID and just need the methodology section.

Subagent (`Agent(subagent_type=ml-paper-researcher)`) when:
- The task requires reading 5+ papers (literature review).
- You need to crawl 2+ levels deep into citation graphs.
- The output will be 5k+ tokens of paper summaries.

The subagent returns a structured summary. The main thread stays clean for code.
