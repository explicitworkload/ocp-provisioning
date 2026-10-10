"""Retrieval A/B for the OpenRAG corpus, tracked in MLflow.

Answers one question with evidence: for the documents OpenRAG has already
ingested, which retriever finds the right chunk - OpenSearch BM25, OpenSearch
kNN, or Milvus kNN - and at what top_k.

The comparison is deliberately like-for-like. Milvus is loaded with the *same*
vectors OpenSearch already holds (`chunk_embedding_rhoai_bge_small_en_v1_5`,
384-dim, produced by bge-small through LiteLLM), rather than re-embedding. So
the only variables are the index and the search, not the embedding model -
which is what makes the result mean anything.

Ground truth is synthetic and self-labelling: for a sample of chunks, the chat
model writes one question answerable only from that chunk, and the chunk it was
written from is the relevant document. Standard practice for bootstrapping RAG
eval when no labelled set exists. Its weakness is worth stating out loud - the
question is generated from the chunk's own wording, so it flatters lexical
retrieval (BM25) slightly. Read the BM25 column with that in mind.
"""

from __future__ import annotations

import json
import math
import os
import random
import sys
import time

import numpy as np
import requests
import urllib3
from pymilvus import MilvusClient, DataType

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

OS_URL = os.environ["OPENSEARCH_URL"]
OS_USER = os.environ.get("OPENSEARCH_USER", "admin")
OS_PASS = os.environ["OPENSEARCH_PASSWORD"]
OS_INDEX = os.environ.get("OPENSEARCH_INDEX", "documents")

LITELLM_URL = os.environ["LITELLM_URL"].rstrip("/")
LITELLM_KEY = os.environ["LITELLM_KEY"]
CHAT_MODEL = os.environ.get("CHAT_MODEL", "qwen3-4b")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "bge-small-en-v1.5")

MILVUS_URI = os.environ.get("MILVUS_URI", "http://milvus-milvus.milvus.svc.cluster.local:19530")
MILVUS_COLLECTION = os.environ.get("MILVUS_COLLECTION", "rag_eval_chunks")

VECTOR_FIELD = os.environ.get("VECTOR_FIELD", "chunk_embedding_rhoai_bge_small_en_v1_5")
N_QUESTIONS = int(os.environ.get("N_QUESTIONS", "40"))
TOP_KS = [int(k) for k in os.environ.get("TOP_KS", "1,3,5,10").split(",")]
SEED = int(os.environ.get("SEED", "1337"))

SPACE_TO_METRIC = {"cosinesimil": "COSINE", "l2": "L2", "innerproduct": "IP"}


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# --- OpenSearch -------------------------------------------------------------

def os_request(method: str, path: str, payload=None):
    r = requests.request(
        method, f"{OS_URL}{path}", auth=(OS_USER, OS_PASS), verify=False,
        json=payload, timeout=120,
    )
    r.raise_for_status()
    return r.json()


def fetch_corpus():
    """Every chunk, with its text and the vector OpenRAG already computed."""
    mapping = os_request("GET", f"/{OS_INDEX}/_mapping")
    props = mapping[OS_INDEX]["mappings"]["properties"]
    space = props[VECTOR_FIELD].get("method", {}).get("space_type", "cosinesimil")
    metric = SPACE_TO_METRIC.get(space, "COSINE")
    log(f"vector field {VECTOR_FIELD}, space_type={space} -> Milvus metric {metric}")

    body = {"size": 1000, "query": {"match_all": {}},
            "_source": ["text", VECTOR_FIELD, "filename", "document_id"]}
    hits = os_request("POST", f"/{OS_INDEX}/_search", body)["hits"]["hits"]
    chunks = []
    for h in hits:
        src = h["_source"]
        vec = src.get(VECTOR_FIELD)
        text = (src.get("text") or "").strip()
        if vec and text:
            chunks.append({"id": h["_id"], "text": text, "vec": vec,
                           "filename": src.get("filename", "")})
    log(f"corpus: {len(chunks)} chunks with both text and a {len(chunks[0]['vec'])}-dim vector")
    return chunks, metric


def search_bm25(query: str, k: int):
    body = {"size": k, "query": {"match": {"text": query}}, "_source": False}
    return [h["_id"] for h in os_request("POST", f"/{OS_INDEX}/_search", body)["hits"]["hits"]]


def search_knn(vector, k: int):
    body = {"size": k, "query": {"knn": {VECTOR_FIELD: {"vector": vector, "k": k}}},
            "_source": False}
    return [h["_id"] for h in os_request("POST", f"/{OS_INDEX}/_search", body)["hits"]["hits"]]


# --- LiteLLM ----------------------------------------------------------------

def chat(prompt: str) -> str:
    """Chat completion with Qwen3's thinking turned OFF.

    enable_thinking=false is not a tuning choice, it is required. The serving
    runtime runs --reasoning-parser=qwen3, which splits the model's chain of
    thought into `reasoning_content` and leaves the answer in `content`. Left
    on, a 4B model spends the whole token budget thinking: the first run of
    this script got finish_reason="length", content=None and
    reasoning_content full of deliberation for all 40 questions, and scored
    "0 usable" with no error anywhere. Off, the same prompt answers in 7
    tokens.
    """
    r = requests.post(
        f"{LITELLM_URL}/v1/chat/completions",
        headers={"Authorization": f"Bearer {LITELLM_KEY}"},
        json={"model": CHAT_MODEL, "messages": [{"role": "user", "content": prompt}],
              "temperature": 0.2, "max_tokens": 300,
              "chat_template_kwargs": {"enable_thinking": False}},
        verify=False, timeout=180,
    )
    r.raise_for_status()
    choice = r.json()["choices"][0]
    content = (choice["message"].get("content") or "").strip()
    if not content:
        # Say why, rather than returning "" and being filtered out silently.
        raise RuntimeError(
            f"empty content (finish_reason={choice.get('finish_reason')}); "
            "the model likely spent its budget on reasoning_content"
        )
    return content


def embed(texts):
    out = []
    for i in range(0, len(texts), 32):
        batch = texts[i:i + 32]
        r = requests.post(
            f"{LITELLM_URL}/v1/embeddings",
            headers={"Authorization": f"Bearer {LITELLM_KEY}"},
            json={"model": EMBED_MODEL, "input": batch},
            verify=False, timeout=180,
        )
        r.raise_for_status()
        data = sorted(r.json()["data"], key=lambda d: d["index"])
        out.extend(d["embedding"] for d in data)
    return out


QUESTION_PROMPT = """Below is an extract from a technical document.

Write ONE specific question that this extract answers, and that could not be
answered from a generic document on the same topic. Name the concrete thing the
extract is about. Do not mention "the extract" or "the document". Reply with the
question only, no preamble.

EXTRACT:
{text}"""


def build_questions(chunks):
    """One question per sampled chunk; the chunk it came from is the answer."""
    random.seed(SEED)
    # Very short chunks (nav furniture, headings) cannot support a specific
    # question, and generating from them only adds noise to the ground truth.
    usable = [c for c in chunks if len(c["text"]) >= 200] or chunks
    sample = random.sample(usable, min(N_QUESTIONS, len(usable)))
    log(f"sampling {len(sample)} of {len(usable)} chunks >=200 chars")
    qs = []
    for n, c in enumerate(sample, 1):
        try:
            q = chat(QUESTION_PROMPT.format(text=c["text"][:2000]))
        except Exception as exc:  # a flaky generation should not kill the sweep
            log(f"  question {n}: generation failed ({exc}); skipped")
            continue
        q = q.strip().strip('"').split("\n")[0].strip()
        if len(q) > 15:
            qs.append({"q": q, "gold": c["id"]})
        if n % 10 == 0:
            log(f"  generated {n}/{len(sample)}")
    log(f"question set: {len(qs)} usable")
    return qs


# --- Milvus -----------------------------------------------------------------

def load_milvus(chunks, metric: str):
    client = MilvusClient(uri=MILVUS_URI)
    dim = len(chunks[0]["vec"])
    if client.has_collection(MILVUS_COLLECTION):
        client.drop_collection(MILVUS_COLLECTION)
    schema = client.create_schema(auto_id=False, enable_dynamic_field=True)
    schema.add_field("pk", DataType.VARCHAR, is_primary=True, max_length=512)
    schema.add_field("vector", DataType.FLOAT_VECTOR, dim=dim)
    index = client.prepare_index_params()
    index.add_index(field_name="vector", index_type="HNSW", metric_type=metric,
                    params={"M": 16, "efConstruction": 200})
    client.create_collection(MILVUS_COLLECTION, schema=schema, index_params=index)
    client.insert(MILVUS_COLLECTION, [{"pk": c["id"], "vector": c["vec"]} for c in chunks])
    client.flush(MILVUS_COLLECTION)
    client.load_collection(MILVUS_COLLECTION)
    log(f"milvus: {len(chunks)} vectors in '{MILVUS_COLLECTION}' (HNSW/{metric})")
    return client


def search_milvus(client, vector, k: int):
    res = client.search(MILVUS_COLLECTION, data=[vector], limit=k,
                        anns_field="vector", output_fields=["pk"])
    return [hit["entity"]["pk"] for hit in res[0]]


# --- Scoring ----------------------------------------------------------------

def score(ranked_ids, gold: str):
    """Single relevant document, so IDCG is 1 and nDCG collapses to 1/log2(r+1)."""
    if gold not in ranked_ids:
        return 0.0, 0.0, 0.0
    rank = ranked_ids.index(gold) + 1
    return 1.0, 1.0 / rank, 1.0 / math.log2(rank + 1)


def main():
    import mlflow

    chunks, metric = fetch_corpus()
    if not chunks:
        sys.exit("no chunks with vectors - has OpenRAG ingested anything?")

    questions = build_questions(chunks)
    if not questions:
        sys.exit("no questions generated")

    log("embedding questions")
    qvecs = embed([q["q"] for q in questions])

    client = load_milvus(chunks, metric)

    retrievers = {
        "opensearch_bm25": lambda q, v, k: search_bm25(q, k),
        "opensearch_knn": lambda q, v, k: search_knn(v, k),
        "milvus_knn": lambda q, v, k: search_milvus(client, v, k),
    }

    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "openrag-retrieval-ab"))
    results = []
    with mlflow.start_run(run_name="retriever-sweep") as parent:
        mlflow.log_params({
            "corpus_chunks": len(chunks), "questions": len(questions),
            "embed_model": EMBED_MODEL, "chat_model": CHAT_MODEL,
            "metric": metric, "seed": SEED,
            "chunk_size": 1000, "chunk_overlap": 200,
        })
        for name, fn in retrievers.items():
            for k in TOP_KS:
                hits = mrrs = ndcgs = 0.0
                t0 = time.time()
                for q, v in zip(questions, qvecs):
                    try:
                        ids = fn(q["q"], v, k)
                    except Exception as exc:
                        log(f"  {name}@{k}: query failed ({exc})")
                        continue
                    h, m, n = score(ids, q["gold"])
                    hits += h; mrrs += m; ndcgs += n
                n_q = len(questions)
                row = {
                    "retriever": name, "top_k": k,
                    "hit_rate": hits / n_q, "mrr": mrrs / n_q, "ndcg": ndcgs / n_q,
                    "ms_per_query": (time.time() - t0) * 1000 / n_q,
                }
                results.append(row)
                with mlflow.start_run(run_name=f"{name}@{k}", nested=True):
                    mlflow.log_params({"retriever": name, "top_k": k})
                    mlflow.log_metrics({m: row[m] for m in
                                        ("hit_rate", "mrr", "ndcg", "ms_per_query")})
                log(f"  {name:<16} k={k:<3} hit={row['hit_rate']:.3f} "
                    f"mrr={row['mrr']:.3f} ndcg={row['ndcg']:.3f} "
                    f"{row['ms_per_query']:.0f}ms/q")

        # The headline comparison, logged on the parent so it is the first
        # thing visible rather than something to be reconstructed from children.
        for row in results:
            tag = f"{row['retriever']}_k{row['top_k']}"
            mlflow.log_metric(f"hit_rate_{tag}", row["hit_rate"])
        mlflow.log_dict({"results": results, "questions": questions[:10]},
                        "results.json")
        log(f"logged to MLflow run {parent.info.run_id}")

    print("\n=== RESULTS " + "=" * 58)
    print(f"{'retriever':<18}{'k':>4}{'hit_rate':>11}{'mrr':>9}{'ndcg':>9}{'ms/q':>9}")
    for r in sorted(results, key=lambda x: (-x["hit_rate"], x["ms_per_query"])):
        print(f"{r['retriever']:<18}{r['top_k']:>4}{r['hit_rate']:>11.3f}"
              f"{r['mrr']:>9.3f}{r['ndcg']:>9.3f}{r['ms_per_query']:>9.0f}")


if __name__ == "__main__":
    main()
