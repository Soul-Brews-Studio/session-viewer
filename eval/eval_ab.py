#!/usr/bin/env python3
"""A/B eval for remote vector spaces (bge-m3) against the labeled paraphrase set.

Mirrors Swift's semanticSearch/eval semantics LINE-FOR-LINE (Embed.swift:745-782,
Eval.swift:139-230), because a scorer that differs from the ranker users get measures
nothing: corpus-mean centering then dot; 60-char text-prefix dedupe keeping the best
chunk; fetch cap 400; session-collapsed ranking deduped in order; recall@k with
denominator min(k, |truth|); truth restricted to sessions embedded in the model under
test (the embeddedSessions ceiling).

Apple arms are NOT run here — Apple query vectors cannot leave the Swift Embedder, so
the apple control comes from `session-viewer eval --file <labeled-only file>` on the
same db. This file exists for spaces whose query embedder is reachable over HTTP.

Never writes to any database. Never touches queries.jsonl.
"""
import json, sqlite3, sys, urllib.request
from pathlib import Path
import numpy as np

LAB = Path(__file__).resolve().parent.parent
VEC_DB = LAB / ".data" / "sessions.chat.vec.db"
QUERIES = LAB / "eval" / "queries.jsonl"
OLLAMA = "http://localhost:11434/api/embed"
MODEL_DB = "bge-m3/multi/r1/1024"   # model string in event_vectors
MODEL_TAG = "bge-m3"                # ollama tag for query embedding
FETCH = 400                          # Eval.swift:204

# Thai paraphrases of the 13 labeled EN queries — same information need, same truth ids.
# The cross-lingual arm: bge-m3's single space vs apple's per-language split.
THAI = {
    "the interface became unresponsive and ate the processor": "หน้าจอค้างไม่ตอบสนอง แถมกิน CPU หนักมาก",
    "the binary died on its own without warning": "โปรแกรมตายไปเองเฉยๆ โดยไม่มีสัญญาณเตือนอะไรเลย",
    "matching words that have no spaces between them": "ค้นหาคำในข้อความที่เขียนติดกันไม่มีเว้นวรรค",
    "two threads touching the same file at once": "สองโปรเซสแย่งกันเขียนไฟล์เดียวกันพร้อมกัน",
    "turning sentences into lists of numbers": "แปลงประโยคให้กลายเป็นชุดตัวเลข",
    "running many helpers at the same time": "รันตัวช่วยหลายตัวขนานกันไปพร้อมกัน",
    "a virtual machine that would not start up": "เครื่องเสมือนบูตไม่ขึ้น สตาร์ทไม่ได้",
    "reading letters out of a scanned document": "อ่านตัวหนังสือออกจากเอกสารที่สแกนมา",
    "putting the site on the internet": "เอาเว็บไซต์ขึ้นออนไลน์ให้คนเข้าถึงได้",
    "checking the code still behaves after a change": "เช็กว่าแก้โค้ดไปแล้วของเดิมยังทำงานถูกอยู่ไหม",
    "saving work into version history": "บันทึกงานเก็บเข้าประวัติเวอร์ชัน",
    "talking to other assistants on the network": "คุยกับผู้ช่วยตัวอื่นข้ามเครือข่าย",
    "measuring how good the results are": "วัดว่าผลลัพธ์ที่ได้ออกมาดีแค่ไหน",
}

def load_labeled():
    rows = []
    for line in QUERIES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        r = json.loads(line)
        if r.get("mode") == "labeled":
            rows.append(r)
    return rows

def embed_queries(texts):
    req = urllib.request.Request(OLLAMA, json.dumps({"model": MODEL_TAG, "input": texts}).encode(),
                                 {"Content-Type": "application/json"})
    vecs = np.array(json.load(urllib.request.urlopen(req, timeout=120))["embeddings"], dtype=np.float32)
    # Loader L2-normalises corpus vectors before packing (Embed.swift:993-999); match it.
    return vecs / np.linalg.norm(vecs, axis=1, keepdims=True)

def load_corpus():
    con = sqlite3.connect(f"file:{VEC_DB}?mode=ro", uri=True)
    rows = con.execute("SELECT session_id, vector, coalesce(text,'') FROM event_vectors WHERE model=?",
                       (MODEL_DB,)).fetchall()
    con.close()
    if not rows:
        sys.exit(f"no vectors for {MODEL_DB} in {VEC_DB}")
    sess = np.array([r[0] for r in rows], dtype=np.int64)
    vecs = np.vstack([np.frombuffer(r[1], dtype="<f4") for r in rows])
    keys = [r[2][:60] for r in rows]   # 60-char dedupe key, Embed.swift:775
    return sess, vecs, keys

def rank(qv, sess, centered, keys, mean):
    scores = centered @ (qv - mean)                       # center query, dot (Embed.swift:752-755)
    best = {}                                             # text-prefix dedupe, best chunk wins
    for i in np.argsort(-scores):
        k = keys[i]
        if k not in best:
            best[k] = (scores[i], int(sess[i]))
            if len(best) >= FETCH:                        # prefix(limit) with limit=fetch=400
                break
    ranked, seen = [], set()
    for _, sid in sorted(best.values(), key=lambda t: -t[0]):
        if sid not in seen:                               # session-dedupe preserving order (Eval.swift:150)
            seen.add(sid); ranked.append(sid)
    return ranked

def score(ranked, truth, k):
    top = ranked[:k]
    hit = sum(1 for s in top if s in truth)
    denom = min(k, len(truth))
    mrr = next((1.0 / (i + 1) for i, s in enumerate(ranked) if s in truth), 0.0)
    return (hit / denom if denom else 0.0), mrr

def run_arm(name, queries, truths, sess, vecs, keys):
    embedded = set(sess.tolist())
    mean = vecs.mean(axis=0)                              # corpusMean (Embed.swift:751)
    centered = vecs - mean
    qvs = embed_queries(queries)
    r10s, r50s, mrrs = [], [], []
    print(f"\n== {name} · {len(queries)} queries · corpus {len(sess)} vectors ==")
    for q, qv, truth_all in zip(queries, qvs, truths):
        truth = {t for t in truth_all if t in embedded}   # embeddedSessions ceiling
        if not truth:
            print(f"  SKIP (no truth embedded): {q[:50]}"); continue
        ranked = rank(qv, sess, centered, keys, mean)
        r10, mrr = score(ranked, truth, 10)
        r50, _ = score(ranked, truth, 50)
        r10s.append(r10); r50s.append(r50); mrrs.append(mrr)
        print(f"  @10={r10:5.0%} @50={r50:5.0%} mrr={mrr:.2f}  {q[:56]}")
    n = len(r10s)
    print(f"  MEAN: recall@10={sum(r10s)/n:.1%}  recall@50={sum(r50s)/n:.1%}  mrr={sum(mrrs)/n:.2f}  (n={n})")

def main():
    labeled = load_labeled()
    truths = [{int(i.split(":")[0]) for i in r["ids"]} for r in labeled]  # session collapse (Eval.swift:216)
    en = [r["query"] for r in labeled]
    missing = [q for q in en if q not in THAI]
    if missing:
        print(f"note: {len(missing)} queries lack a Thai paraphrase; TH arm skips them")
    th_pairs = [(THAI[q], t) for q, t in zip(en, truths) if q in THAI]
    sess, vecs, keys = load_corpus()
    run_arm("bge-m3 · EN paraphrase", en, truths, sess, vecs, keys)
    run_arm("bge-m3 · TH paraphrase (cross-lingual)", [q for q, _ in th_pairs],
            [t for _, t in th_pairs], sess, vecs, keys)

if __name__ == "__main__":
    main()
