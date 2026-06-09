---
name: model-provenance
description: >-
  Harvest the canonical training/inference code and papers for a specific ML
  model (e.g. DINOv3, SAM 2, Whisper, Qwen2-VL) and archive everything locally
  for accurate, grounded coding. Use when the user names a model and wants to
  find its real/official code, training recipe, or papers; wants to "store the
  model's code and papers locally", build a local reference archive for a model,
  or ensure future coding against a model is grounded in its actual source.
  Verifies which repo is canonical (not a fork/lookalike), clones it, extracts
  the key train/inference files, downloads paper PDFs with metadata, writes a
  synthesis report, and saves a persistent memory that mandates reading the
  archived code before writing code for that model. Triggers include "find the
  real code for this model", "archive the model's training/inference code and
  papers", "harvest DINOv3", "set up a local source-of-truth for a model".
---

# Model Provenance

Given a model name, produce a local, verified, self-contained archive of its
**actual** code and papers, then register a memory so all future work on that
model reads the real source instead of guessing.

## When NOT to use
- The user wants to *run/train* the model now → that's normal coding; this skill
  is about building the grounded reference archive first.
- A generic literature review with no specific model → use research/deep-research.

## Output layout (the "safe folder")

Default root is `research/models/<model-slug>/` under the current working dir
(ask only if the user implied a different location). Slugify the exact variant:
`DINOv3` → `dinov3`, `SAM 2` → `sam2`.

```
research/models/<model-slug>/
├── code/         # full git clones — canonical repo first, key community repos
├── key_code/     # extracted train loop, model def, inference; + MANIFEST.md
├── papers/       # <slug>.pdf + <slug>.metadata.json (title/authors/abstract/bibtex)
├── SOURCES.md    # provenance manifest: every repo+paper, commit pin, WHY canonical
└── notes.md      # synthesis: architecture, training recipe, hyperparams, how to run
```

**Safety:** this skill archives code; it never executes cloned repos, installs
their dependencies, or runs their scripts. Reading and copying only.

## Workflow

Track these as todos. Steps 1–2 are high-judgment (do them inline / with an
agent); steps 3–6 are mechanical.

### 1. Discover candidates
Confirm the exact model variant with the user if ambiguous (DINOv3 vs DINOv2).
Fan out searches across web, GitHub, Hugging Face, arXiv, and Papers-with-Code.
See `references/discovery.md` for the exact queries and APIs. Collect a candidate
list of repos and papers — do not commit to one yet.

### 2. Verify the canonical source
Do not trust the top GitHub result. Score candidates with the verification
rubric in `references/discovery.md` (author-org match, paper→repo link, PwC
"official" badge, HF card, fork check). For non-obvious cases, dispatch a
subagent to cross-check author affiliations against repo ownership and report
which repo is official with evidence. Decide:
- the **canonical** repo (required), and
- optionally 0–2 **community** repos worth archiving (clearer impls), labeled as such.

### 3. Create the archive + clone
Create the folder layout, then clone into `code/` and **pin the commit**:
```bash
mkdir -p research/models/<slug>/{code,key_code,papers}
git -C research/models/<slug>/code clone --depth 1 <canonical-repo-url>
# record the exact commit for reproducibility
git -C research/models/<slug>/code/<repo> rev-parse HEAD
```
Use `--depth 1` for speed unless the user wants full history.

### 4. Extract key code
For each cloned repo, pull the high-signal train/inference/model/config files:
```bash
scripts/extract_key_code.py research/models/<slug>/code/<repo> \
    --out research/models/<slug>/key_code
```
This writes `key_code/MANIFEST.md`. Skim it; if the training loop or model def is
missing (unusual layout), locate it by hand and copy it in.

### 5. Download papers
For each paper (primary + method-defining predecessors — see discovery.md):
```bash
scripts/fetch_paper.py <arxiv-id-or-url> --out research/models/<slug>/papers
```
Accepts an arXiv id (`2304.07193`), an `/abs/` or `/pdf/` URL, or a direct PDF
URL (`--name <slug>` to set the filename). Writes the PDF + a metadata sidecar
with bibtex.

### 6. Write SOURCES.md and notes.md
- **`SOURCES.md`** — the provenance ledger. For every repo: URL, pinned commit,
  canonical|community label, and the one-line evidence for why it's canonical.
  For every paper: title, arXiv id, local filename.
- **`notes.md`** — read `key_code/` and the paper abstracts and synthesize:
  architecture overview, the training recipe (objective, losses, key
  hyperparameters, data), and a concrete "how to run inference" section with
  cited file references (`key_code/...:line`). This is the doc future-you reads
  first. Keep claims grounded in the archived files — cite, don't invent.

### 7. Register the mandatory-read memory  ← required
So future sessions ground coding in the real source, write a memory file (see
the memory instructions in the system prompt) and index it in `MEMORY.md`:

- `type: reference`, name `model-src-<slug>`.
- Body must state the **absolute path** to the archive and an explicit rule:

  > **Before writing or reviewing any code involving `<model>`, you MUST read
  > `<abs-path>/notes.md` and the relevant files under `<abs-path>/key_code/`
  > first. Ground all APIs, layer names, and the training recipe in that archived
  > source — do not rely on memory for this model.**

- Link related models with `[[model-src-...]]` (e.g. DINOv3 → `[[model-src-dinov2]]`).
- Add the one-line pointer to `MEMORY.md`:
  `- [<model> source archive](model-src-<slug>.md) — MUST read before coding <model>`

This is what makes the archive *binding*: the pointer loads every session, and
the memory's recall makes reading the real code mandatory rather than optional.

## Final report to the user
State where the archive lives, the canonical repo + pinned commit, what was
extracted, the papers saved, and that the mandatory-read memory is registered.
Flag anything uncertain (e.g. "could not find official training code; archived
the most-trusted community impl").
