# Changelog

All notable changes to this plugin are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

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
