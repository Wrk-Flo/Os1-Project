#!/usr/bin/env python3
"""
os1-knowledge-ingest.py — local RAG knowledge-base ingester.

Walks a set of source roots (recent briefs, decisions log, notes folder),
chunks markdown/text content into ~400-token chunks with 50-token overlap,
embeds each chunk via the local Ollama `nomic-embed-text` model
(http://127.0.0.1:11434/api/embeddings), and stores the result in a
SQLite database at ~/Library/Application Support/OS1/knowledge/store.db.

Schema:
    chunks(id INTEGER PK, source_path TEXT, source_mtime REAL, chunk_idx INT,
           text TEXT, vector BLOB)
    -- vector is a numpy float32 array (768 dims) serialized via .tobytes()

Idempotent: a (source_path, source_mtime) pair that's already indexed
is skipped unless --reindex is set. Files newer than the last index
re-replace all chunks for that path.

Usage:
    os1-knowledge-ingest.py [--source-roots a,b,c] [--reindex] [--dry-run]
                            [--max-files N] [--db PATH] [--quiet]

Defaults:
    Source roots:
      ~/Library/Application Support/OS1/business-brief/runs/*/brief.md
      ~/Library/Application Support/OS1/business-brief/runs/*/summary.md
      /Users/mosestut/Os1 Project/coord/decisions.log.md
      ~/Documents/OS1 Notes/**/*.md
      ~/Documents/OS1 Notes/**/*.txt

This is intended for the OS1 + Eden voice-CoS stack on this Mac. The
search counterpart lives at scripts/os1-knowledge-search.py.
"""

import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.request
from glob import glob
from pathlib import Path

import numpy as np

OLLAMA_URL = "http://127.0.0.1:11434/api/embeddings"
EMBED_MODEL = "nomic-embed-text"
DEFAULT_DB = os.path.expanduser("~/Library/Application Support/OS1/knowledge/store.db")
DEFAULT_ROOTS = [
    os.path.expanduser("~/Library/Application Support/OS1/business-brief/runs/*/brief.md"),
    os.path.expanduser("~/Library/Application Support/OS1/business-brief/runs/*/summary.md"),
    "/Users/mosestut/Os1 Project/coord/decisions.log.md",
    os.path.expanduser("~/Documents/OS1 Notes/**/*.md"),
    os.path.expanduser("~/Documents/OS1 Notes/**/*.txt"),
]
CHUNK_TOKENS = 400
OVERLAP_TOKENS = 50
TOKENS_PER_CHAR = 0.25  # rough estimate; ~4 chars per token


def log(msg, quiet=False):
    if not quiet:
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] os1-knowledge-ingest: {msg}", file=sys.stderr)


def init_db(db_path):
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(db_path)
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_path TEXT NOT NULL,
            source_mtime REAL NOT NULL,
            chunk_idx INTEGER NOT NULL,
            text TEXT NOT NULL,
            vector BLOB NOT NULL
        )
        """
    )
    con.execute("CREATE INDEX IF NOT EXISTS idx_source ON chunks(source_path)")
    con.commit()
    return con


def expand_globs(roots):
    seen = set()
    out = []
    for r in roots:
        for p in glob(r, recursive=True):
            ap = os.path.abspath(p)
            if ap not in seen and os.path.isfile(ap):
                seen.add(ap)
                out.append(ap)
    return out


def chunk_text(text, chunk_chars, overlap_chars):
    if not text.strip():
        return []
    chunks = []
    i = 0
    while i < len(text):
        end = min(i + chunk_chars, len(text))
        snippet = text[i:end].strip()
        if snippet:
            chunks.append(snippet)
        if end >= len(text):
            break
        i = end - overlap_chars
        if i < 0:
            i = 0
    return chunks


def embed_one(text):
    payload = json.dumps({"model": EMBED_MODEL, "prompt": text}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        d = json.load(resp)
    e = d.get("embedding")
    if not e:
        raise RuntimeError("ollama returned empty embedding")
    return np.array(e, dtype=np.float32)


def ingest(args):
    quiet = args.quiet
    chunk_chars = int(CHUNK_TOKENS / TOKENS_PER_CHAR)
    overlap_chars = int(OVERLAP_TOKENS / TOKENS_PER_CHAR)

    roots = args.source_roots or DEFAULT_ROOTS
    files = expand_globs(roots)
    if args.max_files:
        files = files[: args.max_files]

    if args.dry_run:
        print(f"DRY RUN — would index {len(files)} file(s) from {len(roots)} root pattern(s).")
        total_chars = 0
        for f in files[:20]:
            sz = os.path.getsize(f)
            est_chunks = max(1, sz // chunk_chars)
            total_chars += sz
            print(f"  {f}  ({sz} bytes  ~{est_chunks} chunks)")
        if len(files) > 20:
            print(f"  ... and {len(files) - 20} more")
        print(f"Total bytes: {total_chars}  est. chunks: {total_chars // chunk_chars}")
        print("RESULT: dry-run-ok")
        return 0

    con = init_db(args.db)

    indexed = skipped = chunks_written = errors = 0
    for f in files:
        try:
            mtime = os.path.getmtime(f)
            existing = con.execute(
                "SELECT MAX(source_mtime), COUNT(*) FROM chunks WHERE source_path = ?",
                (f,),
            ).fetchone()
            old_mtime, old_count = existing if existing else (None, 0)
            if not args.reindex and old_mtime and old_count > 0 and mtime <= old_mtime + 0.5:
                log(f"SKIP {f} (mtime {mtime:.0f} <= indexed {old_mtime:.0f}, {old_count} chunks)", quiet)
                skipped += 1
                continue

            with open(f, encoding="utf-8", errors="replace") as fp:
                text = fp.read()
            chunks = chunk_text(text, chunk_chars, overlap_chars)
            if not chunks:
                log(f"SKIP {f} (empty)", quiet)
                skipped += 1
                continue

            # Replace any existing chunks for this path
            con.execute("DELETE FROM chunks WHERE source_path = ?", (f,))
            for idx, ch in enumerate(chunks):
                vec = embed_one(ch)
                con.execute(
                    "INSERT INTO chunks (source_path, source_mtime, chunk_idx, text, vector) VALUES (?, ?, ?, ?, ?)",
                    (f, mtime, idx, ch, vec.tobytes()),
                )
                chunks_written += 1
            con.commit()
            log(f"OK   {f} ({len(chunks)} chunks)", quiet)
            indexed += 1
        except Exception as e:
            log(f"WARN {f}: {e}", quiet)
            errors += 1

    total = con.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    log(f"done: indexed={indexed} skipped={skipped} chunks_written={chunks_written} errors={errors} total_in_db={total}", quiet)
    print(f"RESULT: ingest-ok db={args.db} indexed={indexed} skipped={skipped} chunks={chunks_written} total={total}")
    return 0 if errors == 0 else 1


def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source-roots", help="comma-separated glob patterns (overrides defaults)")
    p.add_argument("--reindex", action="store_true", help="re-embed every file regardless of mtime")
    p.add_argument("--dry-run", action="store_true", help="list candidate files; no embeddings, no writes")
    p.add_argument("--max-files", type=int, help="cap files indexed (smoke testing)")
    p.add_argument("--db", default=DEFAULT_DB, help="SQLite path (default %(default)s)")
    p.add_argument("--quiet", action="store_true", help="suppress per-file log lines")
    args = p.parse_args(argv)
    if args.source_roots:
        args.source_roots = [s.strip() for s in args.source_roots.split(",") if s.strip()]
    else:
        args.source_roots = None
    return ingest(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
