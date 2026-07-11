# Paper crawl + citation graph procedure

Replicates `huggingface/ml-intern/agent/tools/papers_tool.py` (citation_graph, snippet_search, recommend, find_datasets/models/collections) using only `WebFetch` + `Bash curl` + the arXiv, Semantic Scholar, and Hugging Face Papers APIs. Free; no API keys required for basic queries (set `S2_API_KEY` for higher S2 rate limits, free at semanticscholar.org/api).

## Start from the literature, not from docs

Default approach: deep literature crawl. **Don't** start from TRL examples or HF docs and back into a method. Start from papers — papers contain the *results*, and results tell you what actually works. Then back the recipe up with working code.

The crawl pattern:

1. **Find the anchor paper(s)** for the task domain (highest-cited, most recent, or both).
2. **Crawl the citation graph DOWNSTREAM** — papers that cite the anchor are the ones that built on it, improved it, or applied it to new domains.
3. **Read methodology sections (3, 4, 5)** of the most promising downstream papers via the arXiv HTML version (`arxiv.org/html/<id>`, ar5iv as fallback). Extract: dataset (name + size + filtering), training method + config (optimizer, lr, schedule, epochs, batch), and the result those choices produced (benchmark scores).
4. **Attribute results to recipes.** Every finding must link a RESULT to the RECIPE that produced it. *"Dataset X + method Y + lr Z → score W on benchmark V"* is useful. *"They used SFT"* is not.
5. **Validate datasets** via `inspect_dataset.sh` — verify they exist on HF Hub and the column format matches the training method (SFT needs `messages`/`text`; DPO needs `prompt`/`chosen`/`rejected`; GRPO needs `prompt`).
6. **Find code** via `gh search code` / TRL examples / paper's official repo, only after the recipe is locked.

## Available scripts

| Script | Purpose |
|---|---|
| `crawl_arxiv.sh "query"` | ML-tuned search via HF Papers (default) |
| `crawl_arxiv.sh "query" --min-cites N --date-from YYYY-MM-DD --field "Computer Science" --sort citationCount:desc` | Filtered search via Semantic Scholar bulk endpoint (multi-word queries are phrase-quoted automatically; `--loose` disables) |
| `crawl_arxiv.sh --cited-by <id>` | Downstream citers — includes `influential` flag and `intents` (e.g. `["methodology","extension"]`) |
| `crawl_arxiv.sh --refs <id>` | References (papers this one cited) — same influence/intents fields |
| `crawl_arxiv.sh --info <id>` | Paper metadata + S2 `tldr` |
| `snippet_search.sh "<query>"` | **Full-text passage search across 12M+ papers.** Use to find specific claims (e.g. "what learning rate did GRPO follow-ups use?") |
| `recommend_papers.sh <id>` | S2 recommendations — useful when the citation graph is sparse |
| `hf_paper_meta.sh <id>` | Paper + linked Hub artifacts (datasets/models/collections) |
| `hf_paper_meta.sh <id> --datasets` | Linked datasets, sorted by downloads |
| `hf_paper_meta.sh <id> --models` | Linked models, sorted by downloads |
| `hf_paper_meta.sh <id> --collections` | Collections featuring the paper |
| `hf_paper_meta.sh <id> --all` | Combined view (compact) |

## Endpoints under the hood

| Endpoint | Used by |
|---|---|
| `huggingface.co/api/papers/search` | unfiltered search (ML-tuned) |
| `api.semanticscholar.org/graph/v1/paper/search/bulk` | filtered search |
| `api.semanticscholar.org/graph/v1/paper/arXiv:<id>` | metadata + tldr |
| `api.semanticscholar.org/graph/v1/paper/arXiv:<id>/citations` | downstream citers |
| `api.semanticscholar.org/graph/v1/paper/arXiv:<id>/references` | references |
| `api.semanticscholar.org/graph/v1/snippet/search` | full-text passage search |
| `api.semanticscholar.org/recommendations/v1/papers/forpaper/arXiv:<id>` | recommendations |
| `huggingface.co/api/datasets?filter=arxiv:<id>` | linked datasets |
| `huggingface.co/api/models?filter=arxiv:<id>` | linked models |
| `huggingface.co/api/collections?paper=<id>` | collections |
| `arxiv.org/html/<id>` (fallback: `ar5iv.labs.arxiv.org/html/<id>`) | section-level paper reading via WebFetch |

## Step 1: Find the anchor — two lanes, not one

If the user gave you an arxiv ID, skip to Step 2. Otherwise search BOTH lanes:

```bash
# Classic lane: the highest-cited paper that defined the approach
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh \
  "<topic>" --min-cites 20 --sort citationCount:desc --limit 5

# Frontier lane: newest work with any traction (last ~12 months)
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh \
  "<topic>" --date-from <12mo-ago> --min-cites 5 --sort publicationDate:desc --limit 10
```

The classic lane alone anchors you to a paper whose recipe is 1–2 years stale — the highest-cited GRPO paper will forever be DeepSeekMath, but the current best recipe lives in its recent citers. The anchor is the classic-lane winner; the frontier lane is your SOTA-check set for Step 3. (HF Papers default search returns `upvotes` instead of citations — treat upvotes as a trending signal, not a quality ranking.)

## Step 2: Read the methodology sections

The S2 metadata + `tldr` tells you what they claim:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh --info 2402.03300
```

For the actual recipe, fetch sections 3, 4, 5 from the HTML version (much cleaner than PDF). Native arXiv HTML first (canonical, current revision), ar5iv as fallback for pre-2024 papers without native HTML:

```
https://arxiv.org/html/2402.03300          # primary
https://ar5iv.labs.arxiv.org/html/2402.03300   # fallback
```

Use `WebFetch` with a precise prompt:

> "From sections 3 (Method), 4 (Experiments), and 5 (Results) of this paper, extract: training objective and loss; datasets (with row counts and any filtering); hyperparameters (lr, batch, epochs/steps, schedule, optimizer); hardware and training duration; final benchmark numbers reported. Quote exact numbers; do not paraphrase."

Don't read the abstract only — abstracts lie by omission.

## Step 3: Crawl the citation graph DOWNSTREAM

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/crawl_arxiv.sh --cited-by 2402.03300 --limit 30
```

Output now includes `influential` (S2's "isInfluential" flag — paper materially uses the cited work) and `intents` (e.g. `["methodology", "extension"]`). Filter aggressively:

- `year >= last 18 months` — ML moves fast
- `citationCount >= 5` — gained traction
- `influential == true` — built directly on the anchor
- Title keywords match the task

Top 5 (merged with the frontier lane from Step 1) are your follow-up candidates.

**SOTA is a timestamped claim, not a property.** A paper's "state of the art" only means "best as of its submission date". Before recommending any recipe as current-best, check whether a candidate published *after* it reports better numbers on the same benchmark — that's exactly what this downstream crawl is for. If the anchor is >12 months old and no recent citer beats it, say so explicitly ("still unbeaten as of <date>") rather than assuming.

**Cross-paper numbers are rarely comparable.** Two papers reporting on the same benchmark typically differ in eval harness, prompting, sampling, and contamination controls. Rank recipes by *within-paper deltas over shared baselines* (Paper B beats its own reproduction of Paper A's method by +X) — not by comparing absolute numbers across papers. When you must compare across papers, flag it as approximate.

## Step 4: Hunt specific claims with snippet_search

When you need to know whether a specific approach has been tried (or what learning rate / dataset / loss someone used), search the *full text* of 12M+ papers:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/snippet_search.sh \
  "GRPO learning rate schedule for math reasoning" --limit 5

# Filtered — recent CS papers with traction:
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/snippet_search.sh \
  "GRPO group size ablation" \
  --field "Computer Science" --min-cites 10 --date-from 2024-06-01
```

This is the killer move when the citation graph is too noisy or you need a specific quantitative claim. Returns paper passages, not just titles.

> The S2 `/snippet/search` endpoint throttles aggressively for anonymous calls. If you see `HTTP 429`, set `S2_API_KEY`.

## Step 5: Fill graph gaps with recommendations

When the anchor is recent and the citation graph is sparse:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/recommend_papers.sh 2402.03300 --limit 10
```

Catches related work that hasn't yet cited each other — useful for niche topics.

## Step 6: Cross-reference HF Papers for Hub artifacts

Linked Hub models/datasets are gold — they're known to work with current TRL.

```bash
# Compact: paper + ids of linked artifacts
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/hf_paper_meta.sh 2402.03300

# Sorted by downloads — pick the most-used variant:
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/hf_paper_meta.sh 2402.03300 --models
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/hf_paper_meta.sh 2402.03300 --datasets

# Everything in one object:
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/hf_paper_meta.sh 2402.03300 --all
```

## Step 7: Validate and find working code

Validate the dataset matches your training method:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/ml-intern/scripts/inspect_dataset.sh <org/dataset> --split train --rows 3
```

Then find a current implementation:

```bash
gh search code --language=python "GRPOTrainer" --limit=10
gh api repos/huggingface/trl/contents/examples/scripts --jq '.[] | .path' | grep -i grpo
```

## When to stop crawling

- You have a paper with strong benchmark numbers, a verified-on-Hub dataset, and a working code example for the trainer
- You've hit ~10 papers (marginal value drops fast after this)
- 2 levels deep maximum on the citation graph

## Subagent vs inline

Use the `ml-paper-researcher` subagent when:

- Crawl will produce >5k tokens of paper content
- Reading 5+ papers' methodology sections
- 2+ levels of citation graph

Inline when:

- You already have the arxiv ID and just need methodology
- One paper, ~1k tokens of summary needed

## Output format

Always report results as recipes attributed to papers — see `ml-paper-researcher.md` for the exact format.

## Rate limits

- **HF Papers / Hub APIs**: very generous, no auth needed for public papers
- **Semantic Scholar `/graph/v1/*`**: ~100 req/min unauth'd; set `S2_API_KEY` for 1 req/s search + 10 req/s otherwise
- **Semantic Scholar `/snippet/search`**: hard-throttled for anonymous calls — `S2_API_KEY` is effectively required
- **arXiv / ar5iv**: no formal rate limit; be polite with `sleep 1` between fetches in scripts
