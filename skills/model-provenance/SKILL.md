---
name: model-provenance
description: >-
  Use when the user names a specific ML model (e.g. DINOv3, SAM 2, Whisper,
  Qwen2-VL) and wants its real/official code, training recipe, or papers
  found, verified, or archived locally for grounded coding. Triggers include
  "find the real code for this model", "harvest DINOv3", "store the model's
  code and papers locally", "archive the training/inference code", "set up a
  local source-of-truth / reference archive for a model", or any request that
  future coding against a model be grounded in its actual source instead of
  training-time memory.
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

**Always archive to the global root `~/.claude/model-provenance/<model-slug>/`,
never inside the current project.** The archive is a machine-wide source of
truth shared by every project (the memory in step 7 points other repos at this
absolute path), so it must not live under any one project's working dir and must
not be committed to a project's git history. Do **not** ask for or accept a
per-project location; if the user wants a copy in their project, symlink it
after the fact. Expand `~` to the real `$HOME` in every path you write down.
Slugify the exact variant: `DINOv3` → `dinov3`, `SAM 2` → `sam2`.

```
~/.claude/model-provenance/<model-slug>/
├── code/         # full git clones — canonical repo first, key community repos
├── key_code/     # extracted train loop, model def, inference; + MANIFEST.md
├── papers/       # <slug>.pdf + <slug>.metadata.json (title/authors/abstract/bibtex)
├── SOURCES.md    # provenance manifest: every repo+paper, commit pin, WHY canonical
└── notes.md      # synthesis: architecture, training recipe, hyperparams, how to run
```

**Reuse what's already there.** Before doing any network work, check whether
`~/.claude/model-provenance/<slug>/` already exists. If it does, treat the
existing archive as the starting point and only fill gaps — do not re-clone,
re-extract, or re-download artifacts that are already present and valid. Each
step below states its own skip condition. If the user explicitly asks to
refresh, delete the relevant subdir(s) first, then re-run those steps.

**Safety:** this skill archives code; it never executes cloned repos, installs
their dependencies, or runs their scripts. Reading and copying only.

## Workflow

Track these as todos. Steps 1–2 are high-judgment (do them inline / with an
agent); steps 3–6 are mechanical; steps 7–8 are required, not optional polish.

### 0. Check for an existing archive
```bash
ls -la ~/.claude/model-provenance/<slug>/ 2>/dev/null && \
  cat ~/.claude/model-provenance/<slug>/SOURCES.md 2>/dev/null
```
If the archive already exists and `SOURCES.md` covers the canonical repo + the
papers the user wants, this skill is mostly done: report what's there, run the
step 8 verification, and only re-enter the steps below for whatever is missing
or stale. A fresh archive starts at step 1.

### 1. Discover candidates
Confirm the exact model variant with the user if ambiguous (DINOv3 vs DINOv2).
Fan out searches across web, GitHub, Hugging Face, and arXiv.
See `references/discovery.md` for the exact queries and APIs. Collect a candidate
list of repos and papers — do not commit to one yet.

### 2. Verify the canonical source
Do not trust the top GitHub result. Score candidates with the verification
rubric in `references/discovery.md` (author-org match, paper→repo link, HF paper
page link, HF card, fork check). For non-obvious cases, dispatch a
subagent to cross-check author affiliations against repo ownership and report
which repo is official with evidence. Decide:
- the **canonical** repo (required), and
- optionally 0–2 **community** repos worth archiving (clearer impls), labeled as such.

### 3. Create the archive + clone
Create the folder layout, then clone into `code/` and **pin the commit**:
```bash
ROOT=~/.claude/model-provenance/<slug>
mkdir -p "$ROOT"/{code,key_code,papers}
# skip if already cloned (idempotent re-runs)
[ -d "$ROOT/code/<repo>" ] || git -C "$ROOT/code" clone --depth 1 <canonical-repo-url>
# record the exact commit for reproducibility
git -C "$ROOT/code/<repo>" rev-parse HEAD
```
Use `--depth 1` for speed unless the user wants full history. If the repo dir is
already present, keep it (note its pinned commit) rather than re-cloning.

### 4. Extract key code
`scripts/` paths below are relative to **this skill's directory** (the base
directory announced when the skill loads), not the project. For each cloned
repo, pull the high-signal train/inference/model/config files:
```bash
scripts/extract_key_code.py "$ROOT/code/<repo>" --out "$ROOT/key_code"
```
Skip a repo whose files are already under `key_code/` with a current
`MANIFEST.md` unless the clone changed. This writes `key_code/MANIFEST.md`
(including the source commit). Skim it; if
the training loop or model def is missing (unusual layout), locate it by hand
and copy it in. Config-heavy repos are capped at 50 files per category
(`--max-per-category`); overflow is listed in the manifest but not copied.

### 5. Download papers
For each paper (primary + method-defining predecessors — see discovery.md):
```bash
scripts/fetch_paper.py <arxiv-id-or-url> --out "$ROOT/papers"
```
Accepts an arXiv id (`2304.07193`), an `/abs/` or `/pdf/` URL, or a direct PDF
URL (`--name <slug>` to set the filename). Writes the PDF + a metadata sidecar
with bibtex. Skip any paper whose `.pdf` + `.metadata.json` already exist in
`papers/` and pass the step 8 `%PDF` check.

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

- `type: reference`, name `model-src-<slug>`. If this memory already exists,
  update it in place rather than creating a duplicate.
- Body must state the **absolute path** to the global archive (expand `~`, e.g.
  `/home/<user>/.claude/model-provenance/<slug>`) and an explicit rule:

  > **Before writing or reviewing any code involving `<model>`, you MUST read
  > `<abs-path>/notes.md` and the relevant files under `<abs-path>/key_code/`
  > first. Ground all APIs, layer names, and the training recipe in that archived
  > source — do not rely on memory for this model.**

- Link related models with `[[model-src-...]]` (e.g. DINOv3 → `[[model-src-dinov2]]`).
- Add the one-line pointer to `MEMORY.md`:
  `- [<model> source archive](model-src-<slug>.md) — MUST read before coding <model>`

This is what makes the archive *binding*: the pointer loads every session, and
the memory's recall makes reading the real code mandatory rather than optional.

### 8. Verify the archive  ← before reporting
Run these checks; fix anything that fails rather than reporting around it:
- every `papers/*.pdf` starts with `%PDF` (`head -c4`) and has a matching
  `.metadata.json` sidecar. If a PDF fails the check (HTML error page), delete
  it and re-fetch from an alternate source (arXiv `/pdf/` URL, the paper's
  project page); if it still fails, remove the junk file and record the miss
  in `SOURCES.md` instead;
- `key_code/` contains at least a model definition plus a train **or**
  inference file, and `MANIFEST.md`'s source commit matches the pin in
  `SOURCES.md`;
- `SOURCES.md` has a pinned commit and one-line canonical evidence for every
  repo in `code/`;
- the memory file exists and `MEMORY.md` contains its pointer line.

## Final report to the user
State where the archive lives, the canonical repo + pinned commit, what was
extracted, the papers saved, and that the mandatory-read memory is registered.
Flag anything uncertain (e.g. "could not find official training code; archived
the most-trusted community impl").
