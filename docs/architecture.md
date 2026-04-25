# Architecture: porting `huggingface/ml-intern` to Claude Code

This doc explains how the upstream `huggingface/ml-intern` Python project (a bespoke agent harness wrapping LiteLLM + Anthropic Claude) maps onto a Claude Code plugin. Useful if you're contributing to this plugin or trying to understand why certain decisions were made.

## What `ml-intern` is

[huggingface/ml-intern](https://github.com/huggingface/ml-intern) is Hugging Face's open-source autonomous ML engineer. Released April 2026. Architecture:

```
agent/
├── core/
│   ├── agent_loop.py          ← submission_loop, ContextManager, ToolRouter (max 300 iters)
│   ├── doom_loop.py           ← detects repeated tool patterns, injects corrective prompt
│   └── tools.py               ← built-in tool registry
├── prompts/
│   └── system_prompt_v3.yaml  ← THE workflow knowledge (165 lines)
├── tools/
│   ├── papers_tool.py         ← arXiv + HF Papers + citation graph
│   ├── dataset_tools.py       ← hf_inspect_dataset (datasets-server REST)
│   ├── docs_tools.py          ← HF doc semantic search
│   ├── jobs_tool.py           ← hf jobs run/ps/logs/inspect
│   ├── sandbox_tool.py        ← provisions HF Spaces as dev sandboxes
│   ├── research_tool.py       ← spawns parallel research subagents
│   └── plan_tool.py           ← TODO list (== Claude Code's TodoWrite)
└── main.py                    ← CLI entry point
backend/                       ← FastAPI server for the React UI
frontend/                      ← React UI built with Vercel AI SDK
configs/main_agent_config.json ← model: bedrock claude-opus-4-6, MCP: huggingface.co/mcp
```

## What ports cleanly

| Upstream | Plugin equivalent | Why it works |
|---|---|---|
| `agent_loop.py` | Claude Code's native agentic loop | Claude Code is a 300-iter loop already |
| `plan_tool.py` | `TodoWrite` | Direct equivalent, identical semantics |
| `local_tools.py` | `Read` / `Edit` / `Write` | Direct equivalent |
| Approval gates | Claude Code permission prompts | Direct equivalent (configurable per-tool) |
| HF doc search | HF MCP server (`.mcp.json`) | The official HF MCP at `huggingface.co/mcp` exposes these |
| `papers_tool.py` | `ml-paper-researcher` subagent + `scripts/crawl_arxiv.sh` | Subagent isolates 50k+ tokens; script wraps Semantic Scholar API |
| `dataset_tools.py` | `dataset-auditor` subagent + `scripts/inspect_dataset.sh` | Wraps `datasets-server.huggingface.co` REST |
| `jobs_tool.py` | `training-job-architect` subagent + `Bash hf jobs run` | The `hf` CLI from `huggingface_hub[cli]` does the same job |
| `system_prompt_v3.yaml` | `skills/ml-intern/SKILL.md` + `references/*.md` | The procedural knowledge, restructured for progressive disclosure |
| Multi-model switching (litellm) | Claude Code's `/model` | Built-in |
| Context auto-compaction at 170k | Claude Code's auto-compaction | Built-in |
| Headless mode (`ml-intern "..."`) | `claude -p "..."` | Direct equivalent |

## What doesn't port (and why we don't try)

| Upstream | Why we skip |
|---|---|
| FastAPI backend, React frontend | Claude Code IS the UI |
| Custom event streaming | Claude Code's transcript already streams |
| Session upload to `smolagents/ml-intern-sessions` | Privacy-sensitive; users can opt-in via their own logging |
| `DoomLoopDetector` | Claude's training largely handles repeated-pattern recovery; the system prompt rule reinforces it |
| HF Spaces sandbox provisioner | Local `Bash` is the default sandbox; users with HF subs can `hf jobs run --detach` for remote dev VMs |
| Bedrock/Opus 4.6 model pinning | Claude Code picks the model; user can override with `/model` |

## Files in this plugin

```
ml-intern/
├── .claude-plugin/
│   ├── plugin.json              ← name + version + author + license + keywords
│   └── marketplace.json         ← single-plugin marketplace (this repo IS the marketplace)
├── README.md                    ← marketplace-display README
├── LICENSE                      ← MIT
├── CHANGELOG.md                 ← Keep a Changelog format
├── .gitignore
├── .mcp.json                    ← declares HF MCP server (active when HF_TOKEN is set)
├── .github/workflows/ci.yml     ← shellcheck, bash -n, JSON manifest validation
├── skills/
│   └── ml-intern/
│       ├── SKILL.md             ← distilled from system_prompt_v3.yaml
│       ├── references/          ← 10 procedural reference docs
│       └── scripts/             ← 5 shell helpers (no Python deps)
├── commands/                    ← 5 slash commands (auto-discovered)
├── agents/                      ← 3 subagents (auto-discovered)
└── docs/
    └── architecture.md          ← this file
```

## Path conventions

Inside plugin files (commands, agents, skill, references), references to bundled scripts use:

```
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/<script>.sh
```

Claude Code's plugin runtime sets `CLAUDE_PLUGIN_ROOT` to the cached install dir (typically `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`). The `Bash` tool inherits this env.

This is the pattern used by `infiniV/claude-code-audio-notify` (see its `hooks/hooks.json`).

## Why "skill + plugin" instead of just one or the other

- **A skill alone** would not auto-register slash commands or subagents. Users would manually copy them.
- **A plugin alone** could ship without a skill, just commands. But the skill carries the procedural knowledge that the slash commands rely on. Without it, `/ml-intern` would be a thin wrapper that doesn't know the 6-step workflow.
- **Both together** (this plugin's design): the plugin loader auto-registers everything; the skill carries the workflow IP; commands and subagents reference both.

## Differences vs. `obra/superpowers`

`superpowers` is the closest reference plugin in scope. Differences:

| | `obra/superpowers` | `infiniV/ultra-ml-intern` |
|---|---|---|
| Domain | General software engineering (TDD, debugging, brainstorming) | ML engineering on HF ecosystem |
| Skill count | 30+ | 1 |
| Cross-platform | Codex / Cursor / Gemini / Copilot | Claude Code only |
| MCP server | none | HF MCP via `.mcp.json` |
| Marketplace | `anthropics/claude-plugins-official` | self-marketplace (this repo) |

