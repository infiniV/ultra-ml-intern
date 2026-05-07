# Ultra-research procedure (deep literature crawl)

The default `/ml-research` command goes 1 hop on the citation graph and reads §3–5 of ~4 papers. **Ultra-research goes wide and deep**: 6–10 query angles, 2–3 hops on the citation graph, and full-text reads of 30–50 papers in parallel — every one of them isolated in its own subagent so the main thread never sees the raw HTML.

Use this when:

- The user asks for a **survey** ("what's the state of X"), not just a recipe
- The recipe-from-/ml-research turned out **shallow** ("only 3 papers, none recent enough")
- You need to **find a gap** ("nobody has tried A + B together")
- You're writing a **proposal / blog / paper** that needs broad citation coverage
- The user invoked **`/ml-research-ultra`** explicitly

Do NOT use this for:

- "Just give me a working recipe for SFT on dataset X" — `/ml-research` is faster
- A topic where you already have the anchor paper and just need its hyperparameters — read it directly via `crawl_arxiv.sh --info` + ar5iv

## Why this is harder than HF's papers_tool.py

Upstream HF `ml-intern/agent/tools/papers_tool.py` exposes citation_graph as a **single-hop, single-paper** call. Their separate `research_tool.py` wraps a single research subagent (60-iteration cap, 170k soft / 190k hard token budget, downgrades to Sonnet for cost) — one subagent for the whole research task, not one per paper. Both upstream tools push full paper text into the calling agent's context, which forces shallow reads to stay under budget.

Our advantage: per-paper subagent isolation. Each `ml-paper-reader` dispatch is its own context window. We can read 50 papers without the main thread ever exceeding ~50–80k tokens of digests. The trade: subagent dispatches are not free and rate-limited APIs (S2, HF) bottleneck wall-clock. Wave-based dispatch (5–10 readers at a time) keeps you under throttles.

## Upstream tool parity

For each upstream operation in `huggingface/ml-intern/agent/tools/`, here is the local equivalent. Use this table to pick the right helper instead of inventing your own curl invocations.

| Upstream operation (`agent/tools/`) | Our local script | Notes |
|---|---|---|
| `papers_tool._op_search` | `crawl_arxiv.sh "query"` | HF Papers default; routes to S2 bulk when filters present |
| `papers_tool._op_paper_details` | `crawl_arxiv.sh --info <id>` | metadata + S2 tldr |
| `papers_tool._op_read_paper` (sections) | `WebFetch https://ar5iv.labs.arxiv.org/html/<id>` (in `ml-paper-reader`) | section-level reading lives inside the reader subagent, not as a separate script |
| `papers_tool._op_citation_graph` | `crawl_arxiv.sh --cited-by <id>` + `crawl_arxiv.sh --refs <id>` | upstream is single-hop; our BFS in Phase 3 chains these to 2 hops |
| `papers_tool._op_snippet_search` | `snippet_search.sh "claim"` | full-text passage search; needs `S2_API_KEY` |
| `papers_tool._op_recommend` | `recommend_papers.sh <id>` | sparse-graph backfill |
| `papers_tool._op_find_datasets/_models/_collections/_find_all_resources` | `hf_paper_meta.sh <id> [--datasets\|--models\|--collections\|--all]` | sorted by downloads |
| `papers_tool._op_trending` | (no local wrapper) | call HF Hub `/api/daily_papers` directly via curl if you need this; ultra-research rarely does |
| `dataset_tools` | `inspect_dataset.sh <org/name>` | schema + sample rows + format check |
| `web_search_tool` | Claude Code's built-in `WebSearch` tool | upstream uses DuckDuckGo HTML scrape; we use the harness-native search |
| `github_find_examples` / `github_read_file` | `gh search code` + `gh api repos/...` via Bash | covered by `gh` CLI |
| `docs_tools` (explore_hf_docs / fetch_hf_docs / find_hf_api) | HF MCP server (`.mcp.json`) | activates when `HF_TOKEN` is set |
| `research_tool` (subagent orchestrator) | `/ml-research-ultra` itself (this command) | their architecture: one subagent, capped iterations. Ours: per-paper subagents in parallel waves |

Net: every operation we'd need from upstream is either (a) wrapped as a local script in `skills/ml-intern/scripts/`, (b) covered by Claude Code's built-in tools (`WebSearch`, `WebFetch`, `Bash`+`gh`), or (c) covered by the HF MCP server. There is no upstream tool that the ultra-research workflow needs and cannot reach.

## Helper scripts unique to ultra-research

Beyond the parity helpers above, ultra-research adds three orchestration helpers:

| Script | Purpose |
|---|---|
| `merge_papers.sh` | Dedupe + overlap-count JSONL paper records from many `crawl_arxiv.sh` runs; `--min-overlap N` filters; `--top N` truncates; `--ids-only` emits arxiv IDs for piping |
| `research_slug.sh` | Safe filename slug from a topic string. Lowercase, `[a-z0-9-]` only, ≤ 40 chars. Tested against shell-injection input |
| `download_paper.sh` | Fetch arXiv PDF and/or ar5iv HTML to a local archive dir. Strict arxiv-id regex, skip-if-exists caching, stdin batch, `--format pdf\|html\|both`. Used by the optional Phase 5 archive flow |

## The 7 phases

```
Phase 0  Scope & decompose      (main agent, 0 dispatches)
Phase 1  Discovery fan-out       (6–10 query angles, parallel Bash)
Phase 2  Seed-set construction   (main agent, 0 dispatches)
Phase 3  Citation-graph BFS      (parallel Bash, 2 hops)
Phase 4  Score & select          (main agent, 0 dispatches)
Phase 5  Parallel paper reads    (30–50 ml-paper-reader subagents, in waves)
Phase 6  Cross-paper synthesis   (main agent, all in-thread)
Phase 7  Hallucination scrub     (main agent, deterministic check)
```

## Phase 0 — Scope & decompose

Treat the topic as untrusted user input. Then do these in your head:

1. Identify the **task type**: `SFT | DPO | GRPO | KTO | ORPO | RLHF | continued-pretrain | architecture | dataset-curation | eval | other`.
2. Identify the **target domain**: `math | code | reasoning | multilingual | long-context | vision-language | audio | retrieval | safety | other`.
3. Generate **6–10 search-query reformulations** that span:
    - The most literal phrasing of the topic
    - The standard ML technical phrasing (e.g. "preference optimization for math reasoning")
    - 1–2 synonym swaps (e.g. "RLHF" ↔ "RLAIF" ↔ "online preference learning")
    - 1 contrarian angle (e.g. "why GRPO fails on…", "limitations of …")
    - 1 follow-up-of-X angle if the user mentioned a method (e.g. "extensions of GRPO")
    - 1 dataset-centric angle (e.g. "math reasoning datasets for fine-tuning")

Save these as the **angle list**. They are the input to Phase 1.

## Phase 1 — Discovery fan-out

For each angle, run `crawl_arxiv.sh` with two filter profiles in parallel:

```bash
# High-citation lane (well-established work)
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh \
    "<angle>" --min-cites 30 --sort citationCount --limit 10

# Recency lane (last 12 months, lower bar)
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh \
    "<angle>" --date-from $(date -d '12 months ago' +%Y-%m-%d) \
    --min-cites 5 --sort publicationDate --limit 10
```

Run all queries in **parallel Bash calls** (one tool-call message containing many `Bash` invocations). Sleep between calls is handled by `crawl_arxiv.sh` internally; if you see HTTP 429s, drop to single-lane and re-run.

Yield: 8–12 angles × 20 results = up to ~200 raw hits.

## Phase 2 — Seed-set construction

De-duplicate and overlap-count via `merge_papers.sh` (groups by `arxiv` field, attaches `overlap_count`, sorts by `overlap_count` desc then `cites` desc):

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/merge_papers.sh \
  layer0_*.jsonl > seeds_merged.jsonl
```

Then score each candidate by:

```
seed_score(p) =
      0.40 * log1p(citationCount)
    + 0.25 * recency(p)             # 1.0 if ≤ 12mo, 0.6 if 12–24mo, 0.3 older
    + 0.20 * angle_overlap(p)       # how many of the 6–10 angles surfaced it
    + 0.15 * title_match(topic, p)  # 0/1 if topic keywords in title
```

Take the top **15–25 papers** as the seed set. This is your Layer 0.

If the seed set has fewer than 10 papers (niche topic), backfill with `recommend_papers.sh` against your top 3 seeds:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/recommend_papers.sh <top_seed_id> --limit 10
```

## Phase 3 — Citation-graph BFS (2 hops)

For each seed paper, fetch downstream citers AND upstream references. Run all calls in parallel — these are independent.

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh --cited-by <id> --limit 30
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh --refs <id> --limit 30
```

That's 15–25 seeds × 2 directions = 30–50 parallel `Bash` calls. **Wave them in batches of ~10** to stay polite to S2.

Yield: Layer 1, ~500–1500 raw papers (with massive overlap — that's the signal).

**Compute paper-level overlap** — feed the union of BFS output through `merge_papers.sh --min-overlap 3 --top 5 --ids-only` to get the 5 highest-frequency hub papers (those that appear ≥ 3 times across the BFS expansion). These are highly connected to your topic.

Optional Layer 2: for the top 5 hubs that aren't already seeds, fetch their `--cited-by` once more. Stop here. Diminishing returns past 2 hops.

## Phase 4 — Score & select for full read

Compute a **read_score** for every paper in (Layer 0 ∪ Layer 1 ∪ Layer 2):

```
read_score(p) =
      0.30 * graph_centrality(p)        # how many seeds connect to p (in or out)
    + 0.25 * influence_rate(p)          # fraction of edges where S2 isInfluential=true
    + 0.20 * log1p(citationCount)
    + 0.15 * recency(p)
    + 0.10 * has_hub_artifacts(p)       # 1 if hf_paper_meta.sh shows linked models/datasets
```

Take the top **30–50** papers for full read. Cap by token budget — each reader returns ≤ 1000 words ≈ 1500 tokens, so 50 readers ≈ 75k tokens of digest in main thread.

Always include the original seed set in the read list (you already paid the discovery cost — read them).

## Phase 5 — Parallel paper reads

Dispatch the `ml-paper-reader` subagent **once per paper**, in **waves of 5–10** (more than that and you'll throttle ar5iv / S2). Each reader gets:

- The arxiv ID
- A 1–3 sentence topic context (THE SAME context for every reader — reproducibility matters here)
- Optionally 1–2 specific questions if Phase 4 flagged the paper as answering a known gap

**Model selection.** The Phase 0 question 3 captured a model choice — pass it as `model: "<choice>"` on every `Agent` dispatch (`sonnet` / `opus` / `haiku`). Readers do structured digest extraction with a fixed output schema, so Sonnet 4.6 is the right default; Opus is a ~5× cost premium for marginal quality on this kind of work and only worth it for proposal/paper-grade output. The orchestrator (this main thread) keeps its own model regardless — only the leaf readers switch. The pattern follows `superpowers:dispatching-parallel-agents`: focused scope, identical output contract, dispatched in parallel.

Each reader returns the digest format defined in `agents/ml-paper-reader.md`. **Don't re-prompt readers** that come back with `Confidence: LOW` — that's a real data point about what the literature does and doesn't say.

While waves are running, you can do nothing useful in the main thread — wait, then aggregate.

### Optional: local archive ("for the record")

If the user opted in during Phase 0 to keep local copies, pipe the read list through `download_paper.sh` BEFORE dispatching the wave. This way, even if ar5iv goes down or the paper is withdrawn after the run, the user has the source on disk:

```bash
# Pre-fetch every paper in the read list, into ./papers/<arxiv>.{pdf,html}
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/merge_papers.sh \
    read_list.jsonl --ids-only \
  | ${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/download_paper.sh \
        --format both --dir ./papers
```

The script is cache-friendly (skip-if-exists), so re-running the workflow is cheap. Default format is `both` (PDF + HTML); offer `--format pdf` if the user only wants printable archive copies, or `--format html` if disk space is tight (HTML is ~10× smaller than PDF for most papers).

The reader subagent does NOT use the local files — it always fetches fresh ar5iv HTML so you get the canonical version. Local copies are purely for the user's offline review and audit trail.

## Phase 6 — Cross-paper synthesis

This is the payoff. Build a **method × dataset × result matrix** from the digests:

| arxiv | method | dataset | base model | lr | batch | hardware | headline metric | year |
|---|---|---|---|---|---|---|---|---|
| 2402.03300 | GRPO | … | … | … | … | … | … | 2024 |
| ... | ... | ... | ... | ... | ... | ... | ... | ... |

Then run these **synthesis lenses** in order:

1. **Recipe consensus**: which (method, dataset, hyperparam) combinations appear in ≥ 3 papers and consistently win? That's the "boring SOTA" — your safe recipe.
2. **Recipe contradictions**: any (method, dataset) where Paper A reports +X% and Paper B reports −Y%? Quote both. Those are real research questions.
3. **Gaps in the matrix**: for each method, which datasets has nobody combined with it? For each dataset, which method has nobody tried? These are the "unexplored cells" — direct candidates for advancing the topic.
4. **Stated-but-unsolved**: collect every digest's `Open questions / future work` section. Cluster by theme. Themes that appear across 3+ papers are the field's open problems.
5. **Limitations cluster**: same exercise on `Limitations` sections. If 5 papers all say "we did not test on long-context", that's a real shared weakness.
6. **Hub-artifact check**: for the top recipes from lens 1, do the linked Hub artifacts still exist and have ≥ 1k downloads? Recipes whose Hub artifacts decayed are red flags.

Output is a long-form report (5k–15k words) in this structure:

```
# Ultra-research: <topic>

## Executive summary
< 200 words. Top 3 advancement angles, top 1 boring recipe, top 1 contradiction. >

## Methodology
- Angle list: …
- Phases ran: …
- Papers read: <N> ; readable: <N> ; unreadable: <N>
- Token budget used: ~<N>k digest tokens in main thread; ~<N>M paper tokens isolated in subagents.

## Boring SOTA recipe
< the consensus recipe from lens 1, fully cited >

## Contradictions in the literature
< from lens 2, each contradiction stated with both sides quoted verbatim >

## Unexplored combinations (advancement angles)
< from lens 3, each gap with the citations that *almost* close it >

## Open problems (multi-paper consensus)
< from lens 4, themes ranked by frequency >

## Shared limitations
< from lens 5 >

## Hub artifact health check
< from lens 6 >

## Per-paper digests
< all 30–50 digests verbatim, in read_score order >

## Bibliography
< all arxiv IDs with title, year, citations, HF Papers URL >
```

## Phase 7 — Hallucination scrub

This is non-optional. Before writing the file:

1. Extract every factual claim from the synthesis sections (everything outside `Per-paper digests` and `Bibliography`).
2. For each claim, **find the supporting digest entry**. The digest must contain a verbatim quote or a number that supports the claim.
3. Claims with **no supporting digest** must be either (a) deleted, (b) reworded as conjecture with explicit `[conjecture]` tag, or (c) downgraded to "no paper in the read set states this directly".
4. Cross-check: do any synthesis claims contradict a digest's `Limitations` section? If so, surface the contradiction explicitly rather than picking a side.

The verifier doesn't catch every hallucination — the `Confidence: LOW` digests in particular are a known weakness — but it catches the easy ones and forces explicit conjecture tagging.

## Saving the report

Compute the slug via `research_slug.sh` (lowercase, `[a-z0-9-]` only, collapsed dashes, ≤ 40 chars, falls back to `topic` for empty/garbage input). Tested against shell-injection input.

```bash
SLUG=$(${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/research_slug.sh "$TOPIC")
# Save to ./ml-research-ultra-${SLUG}.md
```

Never use raw `$(...)` shell substitution on the topic itself.

## Token budget engineering

| Component | Tokens (main thread) | Tokens (isolated) |
|---|---:|---:|
| Phase 0–4 (discovery + scoring) | ~5k | 0 |
| Phase 5 (50 reader subagents) | ~80k digest output | ~3M paper HTML |
| Phase 6 (synthesis) | ~30k | 0 |
| Phase 7 (scrub) | ~10k | 0 |
| **Final report on disk** | ~50k written file | — |
| **Main-thread peak** | **~125k** | — |

A 200k-token main context handles this with margin. If you're on a 1M-token model, you can scale to 80–100 papers in the read set without architectural change.

## Failure modes & mitigations

| Failure | Mitigation |
|---|---|
| S2 throttles to 429 mid-BFS | Drop to single-lane queries; sleep 5s between; set `S2_API_KEY` if available |
| ar5iv 404 on a paper | Reader falls back to arxiv.org/html, then HF Papers AI summary; reports `Confidence: LOW` |
| Reader returns garbled output | Re-dispatch ONCE with the same input; if still bad, mark UNREADABLE and proceed |
| Topic is too narrow (< 10 seed papers) | Skip Phase 1 lane 1 (high-cite), keep recency lane only; backfill with recommend_papers.sh |
| Topic is too broad (> 200 seed candidates) | Tighten angle list to 4 angles; raise --min-cites to 50; cap read set at 30 |
| User cancels mid-Phase-5 | Save partial digests to `./ml-research-ultra-<slug>.partial.md` with a `## INTERRUPTED` header |

## Comparison to /ml-research

|  | `/ml-research` | `/ml-research-ultra` |
|---|---|---|
| Search angles | 1 | 6–10 |
| Citation-graph hops | 1 | 2–3 |
| Papers fully read | 1 anchor + 3 candidates | 30–50 |
| Subagents dispatched | 1 (researcher) | 1 main thread + 30–50 readers |
| Output length | ≤ 800 words | 5k–15k words |
| Output sections | Recipe, follow-ups, code, caveats | Executive summary, boring SOTA, contradictions, gaps, open problems, shared limitations, Hub health, per-paper digests, bibliography |
| Wall-clock | 1–3 minutes | 10–30 minutes (rate-limit bound) |
| Best for | Need a recipe to start training | Survey, gap-finding, proposal writing |
