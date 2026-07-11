#!/usr/bin/env python3
"""Locate and copy the high-signal training/inference files from a cloned repo.

Heuristically finds the files that actually matter for understanding how a model
is trained and run -- training loops, model/architecture definitions, inference /
demo / predict entrypoints, loss & dataset code, and configs -- then copies them
into a flat `key_code/` tree (mirroring repo paths) alongside a `MANIFEST.md`
that lists every captured file, its category, and why it was picked. Nothing is
executed; this only reads and copies text files.

Usage:
    extract_key_code.py <cloned-repo-dir> --out <key_code-dir>
                        [--max-bytes N] [--max-per-category N]

Example:
    extract_key_code.py ~/.claude/model-provenance/dinov3/code/dinov3 \
        --out ~/.claude/model-provenance/dinov3/key_code

Categories are matched by filename and by lightweight content signals (e.g. a
file containing `def training_step` or `optimizer.step()` counts as training even
if its name is generic). Tune the PATTERNS table below for a given ecosystem.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

# (category, filename_regex, content_signal_regex_or_None)
PATTERNS = [
    ("train", r"(^|/)(train|trainer|pretrain|finetune|fit)[\w-]*\.py$",
     r"optimizer\.step|loss\.backward|training_step|def train\b|accelerator\.|\.fit\("),
    ("model", r"(^|/)(model|models|modeling|architecture|backbone|network|net|vit|encoder|decoder)[\w-]*\.py$",
     r"class \w+\((nn\.Module|tf\.keras|torch\.nn|Module)\)|def forward\("),
    ("inference", r"(^|/)(infer|inference|predict|transcribe|demo|run|generate|eval|evaluate|sample|test_time)[\w-]*\.py$",
     r"@torch\.no_grad|model\.eval\(\)|\.predict\(|def (infer|inference|predict|generate)\b"),
    ("loss", r"(^|/)(loss|losses|criterion|objective)[\w-]*\.py$", None),
    ("data", r"(^|/)(dataset|datasets|data|dataloader|augment|transform)[\w-]*\.py$",
     r"class \w*Dataset|DataLoader|__getitem__"),
    ("config", r"(^|/)(config|configs|default[\w-]*)\.(ya?ml|json|py)$|\.gin$"
               r"|(^|/)configs?/.+\.(ya?ml|json|py)$", None),
    ("entry", r"(^|/)(main|__main__|cli|app)\.py$", None),
    ("readme", r"(^|/)README(\.md|\.rst|\.txt)?$", None),
    ("deps", r"(^|/)(requirements[\w-]*\.txt|environment\.ya?ml|pyproject\.toml|setup\.py|setup\.cfg|Pipfile)$", None),
]

SKIP_DIRS = {".git", "__pycache__", "node_modules", ".github", "tests", "test",
             "docs", "notebooks", ".idea", ".vscode", "build", "dist"}
# multi-component prefixes, matched against the file's repo-relative posix path
SKIP_PREFIXES = ("examples/notebooks/",)
TEXT_EXT = {".py", ".yaml", ".yml", ".json", ".toml", ".cfg", ".txt", ".md",
            ".rst", ".gin", ".sh"}


def categorize(rel: str, content: str | None) -> str | None:
    # Filename matches win over content signals across ALL categories: a
    # model.py that happens to contain optimizer.step() (e.g. a Lightning
    # module) is still a model file, not a training loop.
    for cat, name_rx, _ in PATTERNS:
        if re.search(name_rx, rel, re.IGNORECASE):
            return cat
    for cat, _, sig_rx in PATTERNS:
        # content signal only promotes .py files to avoid false hits
        if sig_rx and content and rel.endswith(".py") and re.search(sig_rx, content):
            return cat
    return None


def repo_commit(repo: Path) -> str | None:
    """Best-effort HEAD sha by reading .git files (no git execution)."""
    head = repo / ".git" / "HEAD"
    try:
        ref = head.read_text().strip()
        if not ref.startswith("ref: "):
            return ref or None
        ref = ref[5:]
        ref_file = repo / ".git" / ref
        if ref_file.is_file():
            return ref_file.read_text().strip()
        packed = repo / ".git" / "packed-refs"
        for line in packed.read_text().splitlines():
            if line.endswith(" " + ref):
                return line.split(" ", 1)[0]
    except OSError:
        pass
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo", help="path to a cloned repo")
    ap.add_argument("--out", required=True, help="key_code output directory")
    ap.add_argument("--max-bytes", type=int, default=400_000,
                    help="skip text files larger than this (default 400KB)")
    ap.add_argument("--max-per-category", type=int, default=50,
                    help="cap captured files per category (default 50); "
                         "overflow is listed in MANIFEST.md but not copied")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        print(f"error: not a directory: {repo}", file=sys.stderr)
        return 2
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    matched: dict[str, list[str]] = {}  # category -> sorted relpaths
    for path in sorted(repo.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(repo).as_posix()
        if any(part in SKIP_DIRS for part in path.relative_to(repo).parts[:-1]):
            continue
        if rel.startswith(SKIP_PREFIXES):
            continue
        if path.suffix.lower() not in TEXT_EXT:
            continue
        try:
            if path.stat().st_size > args.max_bytes:
                continue
            content = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        cat = categorize(rel, content)
        if not cat:
            continue
        matched.setdefault(cat, []).append(rel)

    captured: list[tuple[str, str]] = []  # (category, relpath)
    skipped: dict[str, list[str]] = {}    # category -> over-cap relpaths
    for cat, rels in matched.items():
        kept, over = rels[:args.max_per_category], rels[args.max_per_category:]
        if over:
            skipped[cat] = over
            print(f"warning: {cat}: capped at {args.max_per_category} files, "
                  f"{len(over)} more listed in MANIFEST.md but not copied",
                  file=sys.stderr)
        for rel in kept:
            dest = out / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(repo / rel, dest)
            captured.append((cat, rel))

    # Write manifest grouped by category, in PATTERNS order.
    order = [c for c, *_ in PATTERNS]
    commit = repo_commit(repo)
    lines = ["# Key code manifest", "",
             f"Source repo: `{repo.name}`  ",
             f"Source commit: `{commit or 'unknown'}`  ",
             f"Files captured: {len(captured)}", ""]
    for cat in order:
        items = sorted(r for c, r in captured if c == cat)
        if not items:
            continue
        lines.append(f"## {cat} ({len(items)})")
        lines.extend(f"- `{r}`" for r in items)
        if cat in skipped:
            lines.append(f"- …and {len(skipped[cat])} more matched but not "
                         f"copied (over --max-per-category):")
            lines.extend(f"  - `{r}` (not copied)" for r in skipped[cat])
        lines.append("")
    (out / "MANIFEST.md").write_text("\n".join(lines))

    print(f"captured {len(captured)} files -> {out}")
    for cat in order:
        n = sum(1 for c, _ in captured if c == cat)
        if n:
            print(f"  {cat:10s} {n}")
    if not captured:
        print("  (no matches -- check repo path or tune PATTERNS)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
