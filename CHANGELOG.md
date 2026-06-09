# Changelog

All notable changes to this plugin are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-06-09

### Added — model-provenance skill

- **`model-provenance` skill** — given a specific model (e.g. DINOv3, SAM 2, Whisper), finds the *canonical* training/inference code and papers, verifies which repo is official (not a fork or lookalike), and archives everything to `research/models/<slug>/`: full clones in `code/`, extracted train/model/inference files in `key_code/`, paper PDFs + metadata sidecars in `papers/`, a provenance ledger in `SOURCES.md`, and a synthesis report in `notes.md`. Cloned code is archived, never executed.
- **`scripts/fetch_paper.py`** — resolves an arXiv id, `/abs/` or `/pdf/` URL, or direct PDF URL to a local PDF plus a `*.metadata.json` sidecar (title, authors, abstract, categories, bibtex) via the public arXiv API. No key required.
- **`scripts/extract_key_code.py`** — heuristically locates and copies the high-signal files from a cloned repo (training loop, model definition, inference/predict entrypoints, loss, dataset, config) by filename and content signal, into a flat `key_code/` tree with a categorized `MANIFEST.md`.
- **`references/discovery.md`** — search fan-out (web, GitHub, Hugging Face, arXiv, Papers-with-Code) and a weighted canonical-repo verification rubric, plus common traps (name collisions, abandoned mirrors, weights-only HF repos, version drift).

### Why

The `ml-intern` skill's core principle is "ground every decision in current code and papers, not training-time memory." `model-provenance` makes that durable for a specific model: it builds a local source-of-truth archive and registers a mandatory-read memory so future coding against that model reads the real implementation instead of a plausible-but-possibly-wrong recollection of its API and training recipe.

## [0.3.0] - 2026-05-07

### Added — deep literature crawl

- **`/ml-research-ultra` slash command** — driven by the main agent across 7 phases: 6–10 query-angle fan-out, 15–25 paper seed-set, 2-hop citation-graph BFS, score-and-select, parallel paper reads (waves of 5–10 subagents), cross-paper synthesis, hallucination scrub. Designed for surveys, gap-finding, and proposal-grade citation coverage — not for "give me a recipe to start training", which is still `/ml-research`'s job.
- **`ml-paper-reader` subagent** — single-paper deep reader. Reads abstract + §method + §experiments + §results + §limitations + §future-work of one paper via ar5iv HTML and returns a ≤ 1000-word structured digest where every factual line outside `Relevance to topic` is a verbatim quote with a `(§x.y)` section reference. Each invocation isolates 50k+ tokens of paper HTML from the main thread, which is what makes 30–50 full-paper reads fit in a 200k context window.
- **`skills/ml-intern/references/ultra-research.md`** — methodology reference: `seed_score` and `read_score` formulas, BFS heuristics with 429 mitigation, six synthesis lenses (recipe consensus, recipe contradictions, gaps in the matrix, open problems, shared limitations, Hub artifact health), the anti-hallucination scrub protocol, and a token-budget table showing where the ~3M tokens of paper HTML stay (in subagents, not main thread).

### Why

Upstream `huggingface/ml-intern/agent/tools/papers_tool.py` exposes `citation_graph` as a single-hop, single-paper call. Their separate `research_tool.py` wraps a single research subagent (60 iterations, 200k context budget, downgrades to Sonnet for cost). Both push full paper text into the calling agent's context, which forces shallow reads to stay under budget. `/ml-research-ultra` uses *per-paper* subagent isolation to invert that constraint: paper HTML lives only inside paper-reader subagents, while the main thread sees only ~80k tokens of digests across 30–50 papers. The extra capacity is spent on synthesis (cross-paper matrix, gap analysis) — the part you can't get by reading one paper carefully.

### Helper scripts added

- **`scripts/research_slug.sh`** — safe filename slug from a topic string. Lowercase, `[a-z0-9-]` only, ≤ 40 chars, falls back to `topic` for empty input. Tested against shell-injection input. Used by Phase 8 of `/ml-research-ultra`.
- **`scripts/merge_papers.sh`** — dedupe + overlap-count JSONL paper records from multiple `crawl_arxiv.sh` runs. Group-by `arxiv` field, attach `overlap_count`, sort by overlap desc then citations desc. Flags: `--min-overlap N`, `--top N`, `--ids-only`. Used by Phases 2 and 3 to surface "hub" papers (those that appear ≥3 times across BFS expansion).
- **`scripts/download_paper.sh`** — fetch arXiv PDF and/or ar5iv HTML to a local archive dir. Strict arxiv-id grammar (rejects path-traversal and shell metacharacters), skip-if-exists caching, stdin batch, `--format pdf|html|both`, `--dir`, `--batch <file>`. Used by the optional Phase 5 archive flow when the user opts in during Phase 0.

### Upstream-tool parity table

`skills/ml-intern/references/ultra-research.md` now includes a parity table mapping every operation in `huggingface/ml-intern/agent/tools/` to its local equivalent (or to a built-in Claude Code tool / the HF MCP server). Closes the question of "are we missing any upstream capability" — net answer: every operation needed by the ultra-research workflow is reachable, with `_op_trending` the only missing wrapper (rarely used; falls back to direct `/api/daily_papers` curl if needed).

## [0.2.1] - 2026-04-25

### Fixed (smoke-test feedback)

- `scripts/preflight_check.sh` — `hub_model_id` regex now accepts variable references (`hub_model_id=HUB_MODEL_ID`) and f-strings, not just literal quoted strings. The previous version was a false positive on semantically valid scripts.
- `scripts/preflight_check.sh` — added a TRL 1.x API-drift section that FAILs on `overwrite_output_dir=` inside `(SFT|DPO|GRPO|KTO|ORPO|Reward)Config(...)` (removed in TRL 1.x) and WARNs when `attn_implementation=` is set without going through `model_init_kwargs` or `from_pretrained`.
- `scripts/detect_compute.sh` — added `disk_free_gb` and `resource_warnings` fields. Warns on `low_vram_<N>gb` (< 8 GB) and `low_disk_<N>gb` (< 30 GB free at `$HF_HOME`). When local would otherwise be picked but resources are tight and HF Jobs is also viable, the recommendation escalates to `ask_user`.
- `references/trainer-recipes.md` — the canonical SFT example moved `attn_implementation` out of the top-level `SFTConfig` kwargs and into `model_init_kwargs={"attn_implementation": "sdpa"}` (the TRL 1.x correct path).
- `references/trainer-recipes.md` — `hub_strategy="checkpoint"` comment corrected: pushes to a `last-checkpoint/` folder on `main`, not a separate branch.
- `references/trackio-monitoring.md` — added a "Caveats observed in production" section covering (a) the dashboard URL appearing mid-training as a Static Space, not in the first lines of `trainer.train()`; (b) `TRACKIO_PROJECT` env var being ignored by `transformers <= 5.6.x`'s `TrackioCallback` (use `args.run_name` or explicit `trackio.init(project=...)` instead); (c) exit code 1 not being a reliable signal of training failure when Trackio's post-run upload errors propagate (verify Hub model existence as the source of truth).
- `agents/training-job-architect.md` — Step 0 now mandates reading `resource_warnings` from `detect_compute.sh` and surfacing each one to the user before launching. Step 4's "always include" list dropped the misleading top-level `attn_implementation` entry and added explicit notes on TRL 1.x removals (`overwrite_output_dir`) and routing (`attn_implementation` via `model_init_kwargs`).

## [0.2.0] - 2026-04-25

### Added

- **Local training mode** — `scripts/detect_compute.sh` detects local NVIDIA / AMD / Apple-Silicon GPU + HF auth status and recommends `local` / `jobs` / `ask_user` / `none`. Architect and `/ml-train` branch on this; users with both options get asked which to use.
- **`references/local-mode.md`** — full procedure for per-project venv via `uv`, multi-GPU `accelerate launch`, long-run patterns (`tmux`/`screen`/`nohup`), MPS gotchas, push-to-Hub from local.
- **Local-hardware sizing** added to `references/hardware-sizing.md` — RTX 3060/3090/4090, A6000, H100, Apple-Silicon mappings; local-vs-Jobs decision table; hybrid pattern (smoke local, scale Jobs).
- **Compute-mode section in `SKILL.md`** — branches on the 4-way recommendation; warns when model doesn't fit local VRAM; never silently switches training method.

### Changed

- `commands/ml-train.md` — local-first flow with `--local` preflight; cost confirmation skipped for local mode.
- `commands/ml-intern.md` — orchestration mentions detect_compute as step 2.
- `agents/training-job-architect.md` — Step 0 is now `detect_compute.sh`; output template covers both modes; Step 6 emits local OR Jobs run command.
- `scripts/preflight_check.sh` — accepts `--local` flag; warns on `uv pip install --system` and `--secrets HF_TOKEN` in local-mode scripts (Jobs-only patterns).

## [0.1.0] - 2026-04-25

Initial release. Port of [huggingface/ml-intern](https://github.com/huggingface/ml-intern) to a Claude Code plugin.

### Added

- **Skill** (`skills/ml-intern/`) — 6-step research-driven ML workflow distilled from `ml-intern/agent/prompts/system_prompt_v3.yaml`
- **Slash commands** (`commands/`) — `/ml-intern`, `/ml-research`, `/ml-audit`, `/ml-preflight`, `/ml-train`
- **Subagents** (`agents/`) — `ml-paper-researcher`, `dataset-auditor`, `training-job-architect`
- **Helper scripts** (`skills/ml-intern/scripts/`) — `inspect_dataset.sh`, `crawl_arxiv.sh`, `hf_paper_meta.sh`, `preflight_check.sh`, `get_trackio_url.sh`
- **Reference docs** (`skills/ml-intern/references/`) — 10 procedural docs covering hardware sizing, dataset formats, common mistakes, paper crawls, trainer recipes, and headless-mode discipline
- **HF MCP server** declared in `.mcp.json` — enables Hub doc semantic search via `${HF_TOKEN}`
- **Security hardening** — explicit untrusted-input handling in slash commands; regex validation; quoted positional invocations only
