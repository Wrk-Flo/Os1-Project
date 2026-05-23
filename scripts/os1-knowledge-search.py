#!/usr/bin/env python3
"""
os1-knowledge-search.py — query the local knowledge-base ingested by
os1-knowledge-ingest.py.

Embeds the query via Ollama nomic-embed-text, loads all chunk vectors
from the SQLite store, computes cosine similarity, returns top-K.

Usage:
    os1-knowledge-search.py --query "what did we decide about X" [--top-k 5]
                            [--format json|md|plain] [--db PATH]
                            [--min-score 0.3]

Stdin form (for pipelines):
    echo "what did we decide about X" | os1-knowledge-search.py --query -

Designed to be called from Eden's server/integrations.mjs as a child
process when the voice agent invokes runCapability(action=knowledge_search).
"""

import argparse
import json
import os
import sqlite3
import sys
import urllib.request
from pathlib import Path

import numpy as np

OLLAMA_URL = "http://127.0.0.1:11434/api/embeddings"
EMBED_MODEL = "nomic-embed-text"
DEFAULT_DB = os.path.expanduser("~/Library/Application Support/OS1/knowledge/store.db")


def embed_query(text):
    payload = json.dumps({"model": EMBED_MODEL, "prompt": text}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        d = json.load(resp)
    e = d.get("embedding")
    if not e:
        raise RuntimeError("ollama returned empty embedding")
    return np.array(e, dtype=np.float32)


def search(db_path, query_vec, top_k, min_score):
    if not Path(db_path).exists():
        return []
    con = sqlite3.connect(db_path)
    rows = con.execute(
        "SELECT source_path, source_mtime, chunk_idx, text, vector FROM chunks"
    ).fetchall()
    if not rows:
        return []
    # Build matrix
    M = np.stack([np.frombuffer(r[4], dtype=np.float32) for r in rows])
    # Cosine sim
    qn = query_vec / (np.linalg.norm(query_vec) + 1e-12)
    Mn = M / (np.linalg.norm(M, axis=1, keepdims=True) + 1e-12)
    scores = Mn @ qn
    # Top-K
    idx = np.argsort(-scores)[: top_k * 3]  # extra for min-score filter
    results = []
    for i in idx:
        s = float(scores[i])
        if s < min_score:
            continue
        sp, mt, ci, txt, _ = rows[i]
        results.append(
            {
                "score": round(s, 4),
                "source_path": sp,
                "source_mtime": mt,
                "chunk_idx": ci,
                "text": txt,
            }
        )
        if len(results) >= top_k:
            break
    return results


def render(results, fmt):
    if fmt == "json":
        return json.dumps({"ok": True, "results": results}, indent=2)
    if fmt == "md":
        if not results:
            return "_no results_"
        lines = []
        for r in results:
            base = os.path.basename(r["source_path"])
            lines.append(f"### {base} (score {r['score']})")
            lines.append(f"_source: `{r['source_path']}` chunk {r['chunk_idx']}_")
            lines.append("")
            txt = r["text"]
            if len(txt) > 600:
                txt = txt[:600] + "…"
            lines.append(txt)
            lines.append("")
        return "\n".join(lines)
    # plain
    return "\n".join(
        f"{r['score']:.3f}  {os.path.basename(r['source_path'])}#{r['chunk_idx']}: {r['text'][:120]}"
        for r in results
    )


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--query", required=True, help='search query, or "-" to read from stdin')
    p.add_argument("--top-k", type=int, default=5)
    p.add_argument("--format", choices=["json", "md", "plain"], default="json")
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--min-score", type=float, default=0.3)
    args = p.parse_args(argv)

    if args.query == "-":
        args.query = sys.stdin.read().strip()
    if not args.query:
        print(json.dumps({"ok": False, "error": "empty_query"}))
        return 2

    try:
        qv = embed_query(args.query)
    except Exception as e:
        print(json.dumps({"ok": False, "error": "embed_failed", "detail": str(e)[:200]}))
        return 1

    try:
        results = search(args.db, qv, args.top_k, args.min_score)
    except Exception as e:
        print(json.dumps({"ok": False, "error": "search_failed", "detail": str(e)[:200]}))
        return 1

    print(render(results, args.format))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
