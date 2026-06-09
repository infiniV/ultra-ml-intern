#!/usr/bin/env python3
"""Locate and copy the high-signal training/inference files from a cloned repo.

Heuristically finds the files that actually matter for understanding how a model
is trained and run -- training loops, model/architecture definitions, inference /
demo / predict entrypoints, loss & dataset code, and configs -- then copies them
into a flat `key_code/` tree (mirroring repo paths) alongside a `MANIFEST.md`
that lists every captured file, its category, and why it was picked. Nothing is
executed; this only reads and copies text files.

Usage:
    extract_key_code.py <cloned-repo-dir> --out <key_code-dir> [--max-bytes N]

Example:
    extract_key_code.py research/models/dinov3/code/dinov3 \
        --out research/models/dinov3/key_code

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
    ("inference", r"(^|/)(infer|inference|predict|demo|run|generate|eval|evaluate|sample|test_time)[\w-]*\.py$",
     r"@torch\.no_grad|model\.eval\(\)|\.predict\(|def (infer|inference|predict|generate)\b"),
    ("loss", r"(^|/)(loss|losses|criterion|objective)[\w-]*\.py$", None),
    ("data", r"(^|/)(dataset|datasets|data|dataloader|augment|transform)[\w-]*\.py$",
     r"class \w*Dataset|DataLoader|__getitem__"),
    ("config", r"(^|/)(config|configs|default[\w-]*)\.(ya?ml|json|py)$|\.gin$", None),
    ("entry", r"(^|/)(main|__main__|cli|app)\.py$", None),
    ("readme", r"(^|/)README(\.md|\.rst|\.txt)?$", None),
    ("deps", r"(^|/)(requirements[\w-]*\.txt|environment\.ya?ml|pyproject\.toml|setup\.py|setup\.cfg|Pipfile)$", None),
]

SKIP_DIRS = {".git", "__pycache__", "node_modules", ".github", "tests", "test",
             "docs", "examples/notebooks", ".idea", ".vscode", "build", "dist"}
TEXT_EXT = {".py", ".yaml", ".yml", ".json", ".toml", ".cfg", ".txt", ".md",
            ".rst", ".gin", ".sh"}


def categorize(rel: str, content: str | None) -> str | None:
    for cat, name_rx, sig_rx in PATTERNS:
        if re.search(name_rx, rel, re.IGNORECASE):
            return cat
        if sig_rx and content and re.search(sig_rx, content):
            # content signal only promotes .py files to avoid false hits
            if rel.endswith(".py"):
                return cat
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo", help="path to a cloned repo")
    ap.add_argument("--out", required=True, help="key_code output directory")
    ap.add_argument("--max-bytes", type=int, default=400_000,
                    help="skip text files larger than this (default 400KB)")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        print(f"error: not a directory: {repo}", file=sys.stderr)
        return 2
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    captured: list[tuple[str, str]] = []  # (category, relpath)
    for path in sorted(repo.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(repo).as_posix()
        if any(part in SKIP_DIRS for part in path.relative_to(repo).parts[:-1]):
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
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, dest)
        captured.append((cat, rel))

    # Write manifest grouped by category, in PATTERNS order.
    order = [c for c, *_ in PATTERNS]
    lines = ["# Key code manifest", "",
             f"Source repo: `{repo.name}`  ", f"Files captured: {len(captured)}", ""]
    for cat in order:
        items = sorted(r for c, r in captured if c == cat)
        if not items:
            continue
        lines.append(f"## {cat} ({len(items)})")
        lines.extend(f"- `{r}`" for r in items)
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
