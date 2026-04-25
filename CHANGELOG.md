# Changelog

All notable changes to this plugin are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

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
