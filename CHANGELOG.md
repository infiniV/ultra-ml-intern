# Changelog

All notable changes to this plugin are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [0.6.0] - 2026-07-11

### Added — model-provenance: capture the checkpoint usage contract, not just the code

The archive grounded *how the model was built* but not *the contract for using
it* — and the released checkpoint routinely disagrees with the paper (input
resolution, normalization constants, chat template), which is where most
grounding failures actually happen.

- **New `hub/` archive directory + `scripts/fetch_hub_meta.py`.** Per official
  checkpoint, fetches metadata only, never weights: `config.json`,
  `preprocessor_config.json` / `tokenizer_config.json` (incl. chat template),
  `generation_config.json`, the model card, plus `info.json` with revision sha,
  license, gated status, linked arXiv ids, and the weight-file inventory
  (names + sizes). Gated repos degrade gracefully (info + model card still
  captured, misses reported for SOURCES.md). Live-tested against a non-gated
  vision model, a chat-template LLM, and a gated repo.
- **New required `notes.md` sections**: variant table (official checkpoint HF
  repo ids — the antidote to hallucinated ids), I/O contract (preprocessing +
  output semantics; hub config wins over the paper for inference), versions &
  license (min library version, gated status), reference benchmark numbers,
  and an optional capped Gotchas list cited to issue URLs.
- `hub/<checkpoint>/<file>` is now a citable source in notes.md; SOURCES.md
  records repo id + revision sha + license/gated per checkpoint; step 9
  verification checks hub coverage, config parseability, and the new sections;
  the mandatory-read memory now also points at `hub/`.
- Workflow renumbered: hub capture is step 6; SOURCES/notes 7, memory 8,
  verify 9.

## [0.5.1] - 2026-07-11

### Changed — model-provenance: sharper discovery, exact-revision pinning

- **Name-first GitHub search.** The documented `in:name,description,readme`
  query is noisy in practice (live test: a dinov3 search ranked timm and
  transformers.js above `facebookresearch/dinov3`, and surfaced dinov2) —
  discovery.md now starts with `in:name sort:stars` and only broadens if that
  comes up dry.
- **New rubric signal: reverse arXiv-to-HF lookup.**
  `huggingface.co/api/models?filter=arxiv:<id>` confirms the paper-to-org tie
  independent of GitHub search noise (verified live: DINOv2's paper id maps to
  `facebook/dinov2-*`).
- **Tag-aware clone pinning.** When the user names a specific revision
  (e.g. SAM 2.1), check `gh api repos/<o>/<r>/tags` and clone the matching tag
  instead of bare HEAD — HEAD of an active repo may already be past the
  revision asked for. Added to SKILL.md step 3 and the version-drift trap.

### Fixed — model-provenance docs

- Script docstring examples still showed the pre-0.4.1 per-project
  `research/models/...` paths; both now use `~/.claude/model-provenance/...`.
- Dropped discovery.md's table of contents (4 lines of nav for an 80-line file).
- Audit note: both scripts passed a fresh live/fixture regression
  (fetch_paper.py end-to-end against arXiv incl. `%PDF` + bibtex sidecar;
  extract_key_code.py category/skip/commit-pin fixture) — no code bugs found.

## [0.5.0] - 2026-07-11

### Fixed — research pipeline accuracy (found by live-API audit)

- `scripts/crawl_arxiv.sh` — three real bugs in the S2 bulk-search path:
  (a) **`--sort citationCount` was an HTTP 400** — S2 bulk requires `field:order`; bare field names are now normalized to `:desc` so every documented invocation works; (b) **`limit` was silently ignored** — the bulk endpoint returns up to 1000 records per page regardless of `limit`, flooding the caller with ~200 rows on a "top 10" query; results are now truncated client-side via jq; (c) **unquoted multi-word queries keyword-matched anything** (a GRPO search returned cardiology and fisheries papers) — multi-word queries are now phrase-quoted automatically, with `--loose` to opt out and pass-through for queries already using S2 boolean syntax.
- All research docs (`paper-crawl.md`, `ultra-research.md`, both agents, both commands) — replaced every `--sort citationCount` / `--sort publicationDate` example with the working `:desc` form.
- Paper reading order flipped to **native `arxiv.org/html` first, ar5iv fallback** — native HTML is canonical and current-revision; ar5iv is the pre-2024 fallback.
- `/ml-research-ultra` Phase 0 reader-model options — dropped stale "Sonnet 4.6 / Opus 4.7" names and removed the haiku option entirely.
- `/ml-research` — filename slug now computed via the tested `research_slug.sh` instead of prose instructions to hand-derive one.

### Changed — smarter SOTA-finding

- **Dual-lane anchor search** in `/ml-research` and `paper-crawl.md`: classic lane (top-cited) + frontier lane (last 12 months with traction). Citation counts structurally favor stale work — the highest-cited GRPO paper will forever be DeepSeekMath, but the current best recipe lives in its recent citers.
- **"SOTA is a timestamped claim"** rule threaded through researcher agent, paper-crawl, and ultra synthesis lens 1: a recipe is only current-best if no *later* paper in the read set beats it; the report states the as-of date. New mandatory `**SOTA status:**` line in the `ml-paper-researcher` output contract.
- **Cross-paper comparability rule**: absolute numbers across papers differ in harness/prompting/contamination; rank recipes by within-paper deltas over shared baselines. Ultra's contradiction lens now checks the mundane explanation before declaring a research question.

### Removed — bloat

- `ultra-research.md` — deleted the "Why this is harder than HF's papers_tool.py" narrative and the 14-row upstream-tool parity table (~600 words of provenance trivia), replaced by a 4-line Architecture note.
- `/ml-research-ultra` — Phase 6 no longer duplicates (with drifted numbering) the synthesis-lens list from `ultra-research.md`; it now points at the single authoritative copy.
- `ml-paper-researcher` — dropped the "follow paper-crawl.md exactly" indirection; the agent is self-contained and reads the reference only for endpoint details.

## [0.4.2] - 2026-07-04

### Changed — model-provenance: keep the archive a pristine first-harvest reference

- **Archive is write-once at harvest; usage never pollutes it.** Added an explicit invariant: when a later session reads the archive to write code for an experiment, that experiment's working notes, results, or "what worked in exp-xx" observations must NOT be written back into `~/.claude/model-provenance/<slug>/`. The only permitted writes to an existing archive are filling a genuine gap in the original harvest or an explicit user-requested refresh. The mandatory-read memory now states the archive is a read-only reference.
- **Raised the bar on `notes.md` groundedness.** Every factual claim (hyperparameter, layer name, loss term, default, API signature) must carry a `key_code/<file>:<line>` or paper `§section` citation; no claims from memory and no false/aspirational claims; anything unverifiable goes under an explicit `## Unverified` heading instead of being mixed into the grounded sections; code/paper disagreements are cited both ways rather than silently resolved.
- **Step 8 verification** now spot-checks that `notes.md` claims are cited and that the cited lines say what's claimed, and confirms the archive holds no experiment/usage notes.

## [0.4.1] - 2026-06-10

### Changed — model-provenance archive location & idempotency

- **Archive is now global, not per-project.** Output root moved from `research/models/<slug>/` under the current working dir to a fixed machine-wide `~/.claude/model-provenance/<slug>/`. The skill no longer asks for or accepts a per-project path — the registered mandatory-read memory points every project at this one absolute path, so a single shared source-of-truth is the point. All workflow commands now use a `ROOT=~/.claude/model-provenance/<slug>` base.
- **Idempotent re-runs.** New step 0 checks for an existing archive and reports/verifies instead of redoing work; clone (step 3), key-code extraction (step 4), and paper download (step 5) each skip artifacts already present and valid; the memory step updates in place rather than duplicating. Explicit refresh = delete the relevant subdir first.

### Fixed — model-provenance skill

- `scripts/extract_key_code.py` — three capture bugs found via fixture testing:
  (a) the `examples/notebooks` skip entry never matched (skip check compares single path components) — replaced with a `SKIP_PREFIXES` path-prefix check plus a bare `notebooks` dir entry; (b) a content-signal match from an earlier category could beat a filename match from a later one, so a Lightning-style `model.py` containing `optimizer.step()` was filed under `train` — categorization is now two-pass, filename matches across all categories first; (c) files *inside* a `configs/` directory (the dominant real-repo layout, e.g. `configs/vitl16.yaml`) were never captured because the config pattern only matched files literally named `config.*`.
- `scripts/extract_key_code.py` — added `transcribe` to the inference filename pattern (Whisper's main entrypoint `whisper/transcribe.py` was missed in integration testing).
- `scripts/fetch_paper.py` and `references/discovery.md` — arXiv API over HTTPS instead of HTTP.
- `references/discovery.md` — **Papers with Code is dead** (Meta sunset it July 2025; redirects to `huggingface.co/papers`). Removed the PwC "official" badge from the verification rubric and search fan-out; replaced with the HF paper page (`huggingface.co/papers/<arxiv-id>`) repo links, and pointed at the static `paperswithcode-data` GitHub dump for historical models.

### Added — model-provenance skill

- `scripts/extract_key_code.py` — records the source commit in `MANIFEST.md` (read from `.git/HEAD`, no git execution) and caps capture at `--max-per-category` (default 50) files, listing overflow in the manifest instead of copying config explosions.
- `SKILL.md` — new step 8 "Verify the archive" (PDF magic-byte check with re-fetch remedy, key_code completeness, commit-pin consistency between `MANIFEST.md` and `SOURCES.md`, memory registration) before the final report.
- Gap fixes from subagent pressure-testing: `scripts/` paths declared relative to the skill directory; predecessor-paper stopping rule (1–3 max, primary-only when unsure); minor-revision rule (SAM 2.1 stays in the SAM 2 archive; new generation = new archive).

### Changed — model-provenance skill

- `SKILL.md` frontmatter description rewritten to triggering conditions only (was a full workflow summary, which per skill-authoring CSO guidance tempts agents to act on the description without reading the body). Verified with a 7-scenario trigger test.

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
