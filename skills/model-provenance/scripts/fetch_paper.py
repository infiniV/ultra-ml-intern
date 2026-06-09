#!/usr/bin/env python3
"""Download a paper PDF and write a metadata sidecar.

Resolves arXiv IDs / URLs (and arbitrary PDF URLs) to a local PDF plus a
`<stem>.metadata.json` containing title, authors, abstract, categories, the
canonical arXiv URL and a ready-to-paste BibTeX entry. arXiv metadata comes
from the public arXiv Atom API (no key). For non-arXiv PDF URLs the PDF is
still downloaded and a minimal sidecar is written from whatever is known.

Usage:
    fetch_paper.py <arxiv-id|arxiv-url|pdf-url> --out <papers-dir> [--name <slug>]

Examples:
    fetch_paper.py 2304.07193 --out research/models/dinov2/papers
    fetch_paper.py https://arxiv.org/abs/2508.10104 --out papers
    fetch_paper.py https://example.com/paper.pdf --out papers --name some-paper

Exit codes: 0 ok, 2 bad args, 3 network/parse error.
"""
import argparse
import json
import re
import sys
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from pathlib import Path

ARXIV_API = "http://export.arxiv.org/api/query?id_list="
UA = "model-provenance-skill/1.0 (research archival)"


def _get(url: str, accept: str | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if accept:
        req.add_header("Accept", accept)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def parse_arxiv_id(s: str) -> str | None:
    """Extract a bare arXiv id from an id, /abs/ url, or /pdf/ url."""
    s = s.strip()
    m = re.search(r"arxiv\.org/(?:abs|pdf)/([0-9]{4}\.[0-9]{4,5}(?:v\d+)?)", s)
    if m:
        return m.group(1)
    if re.fullmatch(r"[0-9]{4}\.[0-9]{4,5}(?:v\d+)?", s):
        return s
    # old-style ids e.g. cs/0501001
    m = re.search(r"arxiv\.org/(?:abs|pdf)/([a-z\-]+/[0-9]{7})", s)
    if m:
        return m.group(1)
    if re.fullmatch(r"[a-z\-]+/[0-9]{7}", s):
        return s
    return None


def slugify(text: str, maxlen: int = 60) -> str:
    text = re.sub(r"[^\w\s-]", "", text.lower()).strip()
    text = re.sub(r"[\s_-]+", "-", text)
    return text[:maxlen].strip("-") or "paper"


def arxiv_metadata(arxiv_id: str) -> dict:
    ns = {"a": "http://www.w3.org/2005/Atom"}
    raw = _get(ARXIV_API + arxiv_id)
    root = ET.fromstring(raw)
    entry = root.find("a:entry", ns)
    if entry is None or entry.find("a:title", ns) is None:
        raise RuntimeError(f"arXiv returned no entry for {arxiv_id}")

    def text(tag):
        el = entry.find(f"a:{tag}", ns)
        return (el.text or "").strip() if el is not None else ""

    title = re.sub(r"\s+", " ", text("title"))
    summary = re.sub(r"\s+", " ", text("summary"))
    authors = [
        (a.find("a:name", ns).text or "").strip()
        for a in entry.findall("a:author", ns)
        if a.find("a:name", ns) is not None
    ]
    published = text("published")[:10]
    cats = [c.get("term") for c in entry.findall("a:category", ns) if c.get("term")]
    canonical_id = arxiv_id.split("v")[0]
    year = published[:4] or "????"
    first_last = authors[0].split()[-1].lower() if authors else "anon"
    bibkey = f"{first_last}{year}{slugify(title).split('-')[0]}"
    bibtex = (
        f"@article{{{bibkey},\n"
        f"  title   = {{{title}}},\n"
        f"  author  = {{{' and '.join(authors)}}},\n"
        f"  journal = {{arXiv preprint arXiv:{canonical_id}}},\n"
        f"  year    = {{{year}}},\n"
        f"  url     = {{https://arxiv.org/abs/{canonical_id}}}\n"
        f"}}"
    )
    return {
        "source": "arxiv",
        "arxiv_id": arxiv_id,
        "title": title,
        "authors": authors,
        "abstract": summary,
        "published": published,
        "categories": cats,
        "abs_url": f"https://arxiv.org/abs/{arxiv_id}",
        "pdf_url": f"https://arxiv.org/pdf/{arxiv_id}.pdf",
        "bibtex": bibtex,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", help="arXiv id/url or direct PDF url")
    ap.add_argument("--out", required=True, help="papers output directory")
    ap.add_argument("--name", help="override output file stem")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    arxiv_id = parse_arxiv_id(args.source)
    try:
        if arxiv_id:
            meta = arxiv_metadata(arxiv_id)
            stem = args.name or slugify(meta["title"])
            pdf_bytes = _get(meta["pdf_url"], accept="application/pdf")
        else:
            if not args.source.lower().startswith(("http://", "https://")):
                print(f"error: not an arXiv id and not a URL: {args.source}", file=sys.stderr)
                return 2
            stem = args.name or slugify(Path(args.source).stem)
            pdf_bytes = _get(args.source, accept="application/pdf")
            meta = {
                "source": "url",
                "title": stem,
                "authors": [],
                "abstract": "",
                "pdf_url": args.source,
                "bibtex": "",
            }
    except (urllib.error.URLError, RuntimeError, ET.ParseError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 3

    if not pdf_bytes.startswith(b"%PDF"):
        print("warning: downloaded bytes are not a PDF (saving anyway)", file=sys.stderr)

    pdf_path = out / f"{stem}.pdf"
    meta_path = out / f"{stem}.metadata.json"
    pdf_path.write_bytes(pdf_bytes)
    meta["local_pdf"] = pdf_path.name
    meta["bytes"] = len(pdf_bytes)
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False))

    print(f"saved: {pdf_path}  ({len(pdf_bytes):,} bytes)")
    print(f"meta:  {meta_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
