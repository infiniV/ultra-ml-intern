#!/usr/bin/env python3
"""Capture a Hub checkpoint's metadata (never its weights) for the archive.

Given an HF model repo id, writes the files that define the *usage contract*
of the released checkpoint -- the ones papers routinely disagree with:
`config.json`, `preprocessor_config.json`, `tokenizer_config.json` (incl. the
chat template), `generation_config.json`, the model card `README.md` -- plus
`info.json` with the pinned revision sha, license, gated status, and the full
weight-file inventory (names + sizes only; weights are never downloaded).

Usage:
    fetch_hub_meta.py <org/model-id> --out <hub-dir> [--revision <sha|branch>]

Example:
    fetch_hub_meta.py facebook/dinov2-base \
        --out ~/.claude/model-provenance/dinov2/hub

Output tree: <hub-dir>/<org>__<name>/{info.json, README.md, config.json, ...}

Gated repos (401/403 on file fetch) are handled: info.json is still written
with "gated" set, and the misses are listed so the caller can record them in
SOURCES.md rather than treating the run as failed.

Exit codes: 0 ok, 2 bad args, 3 the repo id itself could not be resolved.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

UA = "model-provenance-skill/1.0 (research archival)"
API = "https://huggingface.co/api/models/"

# Small text files that define the checkpoint's usage contract. Weights,
# tensors, and anything not on this list are never fetched.
CONTRACT_FILES = [
    "README.md",
    "config.json",
    "preprocessor_config.json",
    "processor_config.json",
    "tokenizer_config.json",
    "generation_config.json",
    "chat_template.jinja",
    "chat_template.json",
    "special_tokens_map.json",
]


def _get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("repo_id", help="HF model repo id, e.g. facebook/dinov2-base")
    ap.add_argument("--out", required=True, help="hub/ output directory")
    ap.add_argument("--revision", default="main", help="branch or sha (default main)")
    args = ap.parse_args()

    if "/" not in args.repo_id:
        print(f"error: expected org/name repo id, got: {args.repo_id}", file=sys.stderr)
        return 2

    try:
        raw = _get(f"{API}{args.repo_id}?blobs=true")
        api = json.loads(raw)
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"error: cannot resolve {args.repo_id}: {e}", file=sys.stderr)
        return 3

    siblings = [
        {"file": s.get("rfilename"), "bytes": s.get("size")}
        for s in api.get("siblings", [])
    ]
    info = {
        "repo_id": api.get("id", args.repo_id),
        "revision_sha": api.get("sha"),
        "last_modified": api.get("lastModified"),
        "license": (api.get("cardData") or {}).get("license"),
        "gated": api.get("gated", False),
        "library_name": api.get("library_name"),
        "pipeline_tag": api.get("pipeline_tag"),
        "downloads": api.get("downloads"),
        "likes": api.get("likes"),
        "linked_arxiv": [t[6:] for t in api.get("tags", []) if t.startswith("arxiv:")],
        "files": siblings,
    }

    dest = Path(args.out).expanduser() / args.repo_id.replace("/", "__")
    dest.mkdir(parents=True, exist_ok=True)

    present = {s["file"] for s in siblings}
    fetched, missed = [], []
    for fname in CONTRACT_FILES:
        if fname not in present:
            continue
        url = f"https://huggingface.co/{args.repo_id}/resolve/{args.revision}/{fname}"
        try:
            (dest / fname).write_bytes(_get(url))
            fetched.append(fname)
        except urllib.error.HTTPError as e:
            missed.append(f"{fname} (HTTP {e.code})")
        except urllib.error.URLError as e:
            missed.append(f"{fname} ({e.reason})")

    info["contract_files_fetched"] = fetched
    info["contract_files_missed"] = missed
    (dest / "info.json").write_text(json.dumps(info, indent=2, ensure_ascii=False))

    print(f"saved: {dest}  (revision {info['revision_sha']})")
    print(f"  fetched: {', '.join(fetched) or 'none'}")
    if missed:
        gate = " -- repo is gated; record the miss in SOURCES.md" if info["gated"] else ""
        print(f"  missed:  {', '.join(missed)}{gate}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
