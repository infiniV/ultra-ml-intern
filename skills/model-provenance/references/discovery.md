# Discovery & canonical-source verification

How to find the *real* training/inference code and papers for a model, and how
to prove which repo is canonical rather than a fork, reimplementation, or
lookalike. Loaded during the discovery + verification steps.

## Search fan-out

Run these in parallel (WebSearch / WebFetch / `gh` / HF API). Collect candidates;
do not commit to one yet.

- **Web**: `"<model>" official code github`, `"<model>" paper arxiv`,
  `"<model>" training code`, `"<model>" inference example`.
- **GitHub API** (no auth needed for search, higher limits with `gh auth`):
  - Name-first, then broaden. `in:readme` matches any repo that merely
    *mentions* the model (timm outranks the real repo, and a dinov3 search
    surfaces dinov2), so start narrow:
    `gh api -X GET search/repositories -f q='<model> in:name sort:stars'`
  - Only if that comes up dry, widen to
    `-f q='<model> in:name,description,readme sort:stars'`.
  - Inspect top hits: owner, stars, `pushed_at`, whether README links the paper.
- **Hugging Face Hub** (models often point straight to the canonical repo):
  - Model card: `curl -s https://huggingface.co/api/models?search=<model>`
  - The card's `repository` / "Code" link and the org are strong canonical signals.
  - Papers: `https://huggingface.co/papers?q=<model>` and `.../papers/<arxiv-id>`.
- **arXiv**: `https://export.arxiv.org/api/query?search_query=all:<model>` —
  check the paper's first-page footnote/abstract for the authors' own code URL
  (the old Papers-with-Code "Code" tab on arXiv is gone).
- **HF paper page**: `https://huggingface.co/papers/<arxiv-id>` lists GitHub
  repos and HF models/datasets linked to the paper — a strong canonical lead.

> **Papers with Code is dead.** Meta sunset paperswithcode.com in July 2025;
> it now redirects to `huggingface.co/papers`. Its "official" badge no longer
> exists. For older models, the final PwC paper↔repo links survive as a static
> dump at `github.com/paperswithcode/paperswithcode-data` (not updated since).

## Canonical-repo verification rubric

Score each candidate; pick the highest. Record the reasoning in `SOURCES.md` —
never silently pick the top GitHub result.

| Signal | Weight | How to check |
|---|---|---|
| Org matches the paper's authors/lab | High | Paper affiliations vs repo owner (e.g. `facebookresearch`, `google-research`, `openai`). |
| Paper explicitly links this repo | High | arXiv abstract "Code" link, or paper's first-page footnote URL. |
| HF paper page links this repo | High | `huggingface.co/papers/<arxiv-id>` → linked GitHub repo, esp. when the HF org matches the lab. |
| Paper's HF models sit in the lab's org | High | Reverse lookup: `curl -s 'https://huggingface.co/api/models?filter=arxiv:<id>&limit=10'` — if the top linked models live under the authors' org (e.g. `facebook/dinov3-*`), the paper↔org tie is confirmed independent of GitHub search noise. |
| HF model card points here | Med | Card's repository/code link and org. |
| Stars / forks / recent commits | Med | Popularity ≠ canonical, but the official repo is usually well-starred and maintained. |
| README cross-references the paper + weights | Med | Official READMEs cite the bibtex and host/link checkpoints. |
| Not a fork | Med | `gh api repos/<owner>/<repo> --jq .fork` should be `false`; check `parent` if true. |

A community reimplementation can be worth archiving too (often clearer code) —
clone it **in addition** to the canonical repo and label it as such in
`SOURCES.md`. Never let it replace the official one.

## Paper resolution

- Prefer the arXiv id — `fetch_paper.py` resolves it to PDF + metadata + bibtex.
- Grab the **primary** paper and any directly-cited predecessor that defines the
  method (e.g. for DINOv3 also capture DINOv2 and the original DINO/iBOT papers
  if the recipe builds on them). Stopping rule: 1–3 predecessors max, only ones
  whose method the recipe directly reuses; when unsure, archive just the primary
  paper and note the lineage in `notes.md`.
- For conference-only papers with no arXiv, pass the direct PDF URL to
  `fetch_paper.py --name <slug>`; fill the metadata sidecar by hand if needed.

## Common traps

- **Name collisions**: many unrelated models share a name (e.g. "SAM", "BLIP",
  "Mistral" the model vs the company). Disambiguate by task/modality before
  searching.
- **Abandoned mirrors**: a high-star repo may be a frozen mirror; prefer the one
  with recent commits *and* author-org ownership.
- **Weights-only HF repos**: a HF model repo may host weights but no training
  code — follow its "code" link to the actual training repo.
- **Version drift**: DINOv3 ≠ DINOv2 ≠ DINO. Pin the exact model variant the user
  named and don't archive the wrong generation. Minor revisions (SAM 2 → SAM 2.1)
  usually live in the same repo — one archive, with the revision noted in
  `SOURCES.md`; a new *generation* (new paper + new repo) gets its own archive.
  When the user named a specific revision, check `gh api repos/<owner>/<repo>/tags`
  for a matching release tag and clone that tag (`git clone --depth 1 --branch <tag>`)
  instead of bare HEAD — HEAD of an active repo may already be past the revision
  they asked for.
