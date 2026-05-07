![ultra-ml-intern banner](https://raw.githubusercontent.com/infiniV/ultra-ml-intern/main/assets/social-preview.png)

# ultra-ml-intern: ML engineering intern for Claude Code

> ultra-instinct ML engineering intern for Claude Code. Reads papers, audits datasets, ships SFT/DPO/LoRA runs to Hugging Face.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Plugin-orange)](https://docs.claude.com/en/docs/claude-code/plugins)
[![Built on](https://img.shields.io/badge/built%20on-huggingface%2Fml--intern-yellow)](https://github.com/huggingface/ml-intern)

`ultra-ml-intern` is a Claude Code plugin that gives Claude the workflow of an ML engineering intern. It researches ML papers, audits Hugging Face datasets, designs fine-tuning recipes (SFT, DPO, GRPO, LoRA, QLoRA, RLHF), and submits training jobs to HF Jobs with Trackio monitoring.

The procedural knowledge comes from [huggingface/ml-intern](https://github.com/huggingface/ml-intern), HF's standalone Python harness around the Claude API. This repo wires the same intelligence into Claude Code, Anthropic's official agentic harness for Claude. Same model, a more capable loop, and you bring your own Claude (Max subscription or API key) instead of paying for a second harness on top.

Works in any Claude Code surface: terminal CLI, IDE extensions, and the web app.

## Install

```bash
# In any Claude Code session:
/plugin marketplace add infiniV/ultra-ml-intern
/plugin install ml-intern@ultra-ml-intern
```

Restart Claude Code, then verify with `/plugin` and `/agents`. The slash commands (`/ml-intern`, `/ml-research`, …) keep their short names; the `ultra-` prefix is just the package wrapper.

What you get:

- 1 skill: `ml-intern` (the workflow)
- 6 slash commands: `/ml-intern`, `/ml-research`, `/ml-research-ultra`, `/ml-audit`, `/ml-preflight`, `/ml-train`
- 4 subagents: `ml-paper-researcher`, `ml-paper-reader`, `dataset-auditor`, `training-job-architect`
- 1 MCP server: Hugging Face (activates when `HF_TOKEN` is set)

## Quickstart

```
> "fine-tune Qwen3-0.5B for math reasoning"
```

The skill activates automatically and walks the [6-step research-driven workflow](skills/ml-intern/references/workflow.md):

1. Find the landmark paper for the task
2. Crawl the citation graph for recent SOTA
3. Read methodology sections (3, 4, 5) and extract the recipe
4. Validate the dataset and base model exist on Hub
5. Write a training script grounded in current TRL APIs
6. Pre-flight check → smoke test → full `hf jobs run` with Trackio monitoring

## What it does

| You ask | It does |
|---|---|
| "fine-tune X for Y" | Full pipeline: literature review → dataset audit → training-job design → smoke test → full run |
| "what's the best recipe for X" | Dispatches the `ml-paper-researcher` subagent; returns recipe + citations |
| "do a deep literature review on X" | Runs `/ml-research-ultra`: 6–10 query angles, 2-hop citation BFS, 30–50 papers read in parallel `ml-paper-reader` subagents, gap-finding synthesis, optional local PDF/HTML archive |
| "audit dataset Y" | Dispatches the `dataset-auditor`; returns schema, anomalies, GO/NO-GO verdict |
| "preflight train.py" | Catches missing `push_to_hub`, default 30m timeout, bf16 on T4, missing flash-attn install, before you spend cluster hours |
| "submit hf jobs run" | Walks pre-flight → cost estimate → smoke test → full submission → Trackio dashboard URL |

## Commands

| Command | What it does |
|---|---|
| `/ml-intern` | The full pipeline: research → audit → train → ship |
| `/ml-research` | Literature review only: landmark paper, citation graph, extracted recipe |
| `/ml-research-ultra` | Deep crawl: 6–10 query angles, 2-hop citation BFS, 30–50 full-paper reads in parallel subagents, gap-finding synthesis |
| `/ml-audit` | Dataset audit only: schema, samples, anomalies, training-method recommendation |
| `/ml-preflight` | Sanity-check a training script before submission |
| `/ml-train` | Submit a training job. Local-first when a GPU is available, HF Jobs when not |

## Subagents

| Subagent | Role |
|---|---|
| `ml-paper-researcher` | Crawls arXiv + cites the landmark paper, extracts the methodology section into a recipe |
| `ml-paper-reader` | Single-paper deep reader. Returns ~1k-word digest with verbatim quotes + §refs. Designed for parallel fan-out from `/ml-research-ultra` |
| `dataset-auditor` | Inspects HF datasets: schema, sample rows, distribution checks, anomaly flagging |
| `training-job-architect` | Writes the TRL/Transformers training script + the `hf jobs run` command sized to your hardware |

## Training recipes supported

The plugin recognizes and writes scripts for:

- SFT (Supervised Fine-Tuning) for single-turn and multi-turn chat
- DPO (Direct Preference Optimization) on pairwise preference data
- GRPO (Group Relative Policy Optimization) for reasoning tasks, DeepSeek-style
- LoRA and QLoRA for parameter-efficient fine-tuning, including 4-bit quantization
- RLHF with the full reward-model plus PPO pipeline
- Continued pretraining for domain adaptation on raw text

All grounded in the current TRL API. The `ml-paper-researcher` reads the actual library source, not its training data, before writing imports.

## Hardware sizing built in

The plugin knows the HF Jobs flavors (`t4-small` through `a100x8`) and picks one to fit your model:

| Model size | Default flavor |
|---|---|
| 1–3B | `a10g-largex2` (48 GB) |
| 7–13B | `a100-large` (80 GB) |
| 30B+ | `l40sx4` or `a100x4` |
| 70B+ | `a100x8` |

Full chart in [`references/hardware-sizing.md`](skills/ml-intern/references/hardware-sizing.md).

## Mistakes it prevents

The 8 expensive errors from `huggingface/ml-intern`'s system prompt, encoded here as procedural rules:

1. Hallucinated TRL/Transformers imports → plugin reads the current source first
2. Wrong trainer arguments → fetches the actual config docs before writing
3. Wrong dataset format → `inspect_dataset.sh` runs first
4. Default 30m timeout kills the job → minimum 2h enforced
5. Lost models (no `push_to_hub=True`) → preflight refuses without it
6. Batch submission failures → smoke-test one job first
7. Silent dataset substitution → surfaces the failure and asks the user
8. Hardcoded missing packages (flash-attn, etc.) → preflight catches it

One more rule worth calling out: no scope-changing fixes. OOM doesn't mean silently rewriting SFT into LoRA. It means a proper batch and grad-accum reduction.

## Requirements

- Claude Code (any surface: terminal, IDE, web)
- Your own Claude access (Max subscription or API key) for the model itself
- Bash + standard Unix tools
- For HF Jobs submission: a Hugging Face account with billing enabled
- Optional: `HF_TOKEN` exported for the bundled MCP server

```bash
export HF_TOKEN="$(hf auth print-token)"  # or paste from https://huggingface.co/settings/tokens
```

The MCP server adds Hub doc semantic search and community Gradio Space tools. The plugin works without it. It falls back to `WebFetch` and the bundled helpers: `inspect_dataset.sh`, `crawl_arxiv.sh`, `hf_paper_meta.sh`, `recommend_papers.sh`, `snippet_search.sh`, plus the ultra-research orchestration helpers `merge_papers.sh` (dedupe + overlap counting), `research_slug.sh` (safe filename slug), and `download_paper.sh` (local PDF/HTML archive).

## Relationship to huggingface/ml-intern

Both projects use the same model, Claude. What differs is the harness around it.

The upstream is a standalone Python project: roughly 50k lines of agent loop, plan tool, paper and dataset tools, jobs tool, and a hand-built system prompt. It calls the Claude API directly. It shipped first and the procedural knowledge in this repo is theirs.

Claude Code is Anthropic's official agentic harness for Claude. The agent loop, the planner (`TodoWrite`), subagent dispatch, MCP plumbing, and the editor surface are already there and tested. This plugin wires the procedural knowledge from the upstream into those primitives, so Claude runs the same workflow without a parallel harness sitting on top of the API.

In practice: same Claude model, a more capable surrounding loop, no extra billing layer (your Claude Max subscription or API key is enough), and the workflow runs anywhere Claude Code already runs.

If you want the standalone Python tool, use the upstream. If you already work in Claude Code, use this.

## Uninstall

```
/plugin uninstall ml-intern@ultra-ml-intern
/plugin marketplace remove ultra-ml-intern
```

## Contributing

Issues and PRs welcome at https://github.com/infiniV/ultra-ml-intern.

CI runs:
- `shellcheck` on every script in `skills/ml-intern/scripts/`
- `bash -n` syntax check on the same
- JSON schema validation on `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`

## Credits

- Upstream: [`huggingface/ml-intern`](https://github.com/huggingface/ml-intern) by the Hugging Face team. The procedural knowledge is theirs.
- Plugin format reference: [`obra/superpowers`](https://github.com/obra/superpowers).
- Plugin skeleton mirrors [`infiniV/claude-code-audio-notify`](https://github.com/infiniV/claude-code-audio-notify).

## License

[MIT](LICENSE)
