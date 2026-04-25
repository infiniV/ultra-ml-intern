# Paper crawl + citation graph procedure

Replicates `huggingface/ml-intern/agent/tools/papers_tool.py` (citation_graph, read_paper, snippet_search, find_datasets) using only `WebFetch` + `Bash curl` + the arXiv and Semantic Scholar APIs. Free, no API keys required for basic queries.

## When to crawl

- User asks "what's the best recipe for X" — find landmark + 3 follow-ups
- You're picking between two methods — find ablation studies
- You're stuck on a training problem — find papers that report the same problem and how they fixed it

## The endpoints you'll use

| Endpoint | Purpose | Auth |
|---|---|---|
| `https://api.semanticscholar.org/graph/v1/paper/search` | Title/keyword search | None (rate-limited) |
| `https://api.semanticscholar.org/graph/v1/paper/arXiv:<id>` | Paper metadata | None |
| `https://api.semanticscholar.org/graph/v1/paper/arXiv:<id>/citations` | Who cited this paper | None |
| `https://api.semanticscholar.org/graph/v1/paper/arXiv:<id>/references` | Who this paper cited | None |
| `https://export.arxiv.org/abs/<id>` | Abstract page | None |
| `https://arxiv.org/pdf/<id>` | Full PDF | None |
| `https://huggingface.co/api/papers/<arxiv_id>` | HF Papers metadata + Hub links | None for public, HF_TOKEN for private |

## Step 1: Find the landmark

If the user gave a paper, skip to Step 2. Otherwise:

```bash
# Semantic Scholar search:
curl -s "https://api.semanticscholar.org/graph/v1/paper/search?query=group+relative+policy+optimization&limit=10&fields=title,year,citationCount,externalIds" \
  | jq '.data[] | select(.year >= 2023) | {title, year, cites: .citationCount, arxiv: .externalIds.ArXiv}'
```

Pick the highest-cited paper from the most recent year that matches the topic. That's your landmark.

## Step 2: Read the methodology section

For the landmark, fetch the abstract first to confirm relevance:

```bash
curl -s "https://export.arxiv.org/abs/2402.03300" | grep -A 20 'class="abstract'
```

Then fetch the full paper. WebFetch on the arxiv abs page is cheaper than the PDF if the abs page has enough; for full methodology, hit the HTML version (`ar5iv.org`) which is much easier to parse than PDF:

```
https://ar5iv.labs.arxiv.org/html/2402.03300
```

Use `WebFetch` with a prompt like:

> "Extract sections 3 (Method) and 4 (Experiments) of this paper. I need: training objective, loss function, datasets used (with row counts if given), hyperparameters (lr, batch size, training duration, hardware), and the final benchmark numbers reported."

## Step 3: Crawl the citation graph

Find papers that cite the landmark — they're likely the SOTA improvements.

```bash
curl -s "https://api.semanticscholar.org/graph/v1/paper/arXiv:2402.03300/citations?fields=title,year,citationCount,abstract,externalIds&limit=50" \
  | jq '.data[].citingPaper | select(.year >= 2024) | select(.citationCount >= 5) | {title, year, cites: .citationCount, arxiv: .externalIds.ArXiv}'
```

Filter aggressively:
- `year >= <last_year>` (recent)
- `citationCount >= 5` (gained traction)
- Title keywords match the task

Top 5 results are your follow-up candidates.

## Step 4: Crawl 2 levels deep (when needed)

For state-of-the-art questions, repeat Step 3 on each follow-up. Stop when:

- You've found a paper with strong benchmark numbers and a public dataset/recipe
- You hit ~10 papers (any more and the marginal value drops)
- The task is a known-recent topic and follow-ups don't exist yet

## Step 5: Cross-reference HF Papers

HF Papers (https://huggingface.co/papers) curates papers with linked Hub artifacts (models + datasets + Spaces).

```bash
curl -s "https://huggingface.co/api/papers/2402.03300" | jq '{title, summary, models: [.models[]?.id], datasets: [.datasets[]?.id]}'
```

If a paper has linked Hub models/datasets, those are your starting points for implementation — they're known to work with current TRL.

## Step 6: Find working code examples

Once you have the recipe, find a current implementation:

```bash
# Search GitHub for code that uses the trainer:
gh search code --language=python "GRPOTrainer" --limit=10

# Or search TRL examples directly:
gh api repos/huggingface/trl/contents/examples/scripts --jq '.[] | .path' | grep -i grpo

# Or look at the paper's official repo (often linked in HF Papers):
gh search repos --owner=deepseek-ai grpo  # or whatever
```

## Output format

When the crawl is done, report back:

```
Landmark: GRPO (DeepSeek-Math, arxiv:2402.03300, 1247 cites)
URL: https://huggingface.co/papers/2402.03300

Recipe (§3.1, §4.2):
  - Base: SFT-tuned DeepSeek-Math-7B
  - Dataset: 12.5k MATH train problems
  - Group size: 64
  - LR: 1e-6
  - KL coef: 0.04
  - Reward: rule-based correctness
  - Hardware: 64×A100 80GB, 144h

Follow-ups (cited GRPO, ≥10 cites, 2024+):
  1. DeepSeek-V2 (arxiv:2405.04434) — scaled GRPO to MoE
  2. <next>
  3. <next>

Working examples:
  - https://github.com/huggingface/trl/blob/main/examples/scripts/grpo.py
  - https://huggingface.co/blog/<post>
```

## Subagent vs inline

Use the `ml-paper-researcher` subagent when:
- Crawl will produce >5k tokens of paper content
- Reading 5+ papers' methodology sections
- 2+ levels of citation graph

Inline when:
- You already have the arxiv ID and just need methodology
- One paper, ~1k tokens of summary needed

## Rate limits

Semantic Scholar is generous (~100 req/min for unauthenticated) but enforces it. If you hit a 429, wait 60 seconds. For heavy use, get a free API key at https://www.semanticscholar.org/product/api.

arXiv has no formal rate limit but be polite — `time.sleep(1)` between fetches is a good practice in scripts.
