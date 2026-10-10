"""Trace a RAG pipeline and judge its answers, in MLflow.

Demo #1 measured retrieval: does the right chunk come back? This measures the
thing a user actually experiences: given that chunk, is the answer any good?

Two MLflow features, one pipeline:

  Tracing   - every question produces a trace with a RETRIEVER span and an LLM
              span, so the retrieved context and the generated answer are
              inspectable per request rather than aggregated away.
  Judging   - mlflow.genai.evaluate scores each answer with LLM judges:
              Correctness against the chunk the question was written from,
              RelevanceToQuery, and a Guidelines scorer for groundedness.

The judge is an LLM reached through LiteLLM, which is also what serves the
model under test. Deliberately a *different* model from the one generating
(granite judging a different generator), because a model grading its own
output is the first thing anyone in the room will object to.
"""

from __future__ import annotations

import os
import random
import time

import mlflow
import requests
import urllib3
from mlflow.genai.scorers import Correctness, Guidelines, RelevanceToQuery

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

OS_URL = os.environ["OPENSEARCH_URL"]
OS_USER = os.environ.get("OPENSEARCH_USER", "admin")
OS_PASS = os.environ["OPENSEARCH_PASSWORD"]
OS_INDEX = os.environ.get("OPENSEARCH_INDEX", "documents")
VECTOR_FIELD = "chunk_embedding_rhoai_bge_small_en_v1_5"

LITELLM_URL = os.environ["LITELLM_URL"].rstrip("/")
LITELLM_KEY = os.environ["LITELLM_KEY"]
GEN_MODEL = os.environ.get("GEN_MODEL", "granite-3-2-8b-instruct")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "bge-small-en-v1.5")

N_QUESTIONS = int(os.environ.get("N_QUESTIONS", "12"))
TOP_K = int(os.environ.get("TOP_K", "5"))
SEED = int(os.environ.get("SEED", "1337"))


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def os_post(path, payload):
    r = requests.post(f"{OS_URL}{path}", auth=(OS_USER, OS_PASS), verify=False,
                      json=payload, timeout=120)
    r.raise_for_status()
    return r.json()


def llm(prompt, model=None, max_tokens=400):
    """Chat through LiteLLM.

    enable_thinking=false matters for Qwen models served with
    --reasoning-parser=qwen3, which otherwise spend the whole budget in
    reasoning_content and return content=None. Harmless for other models,
    which ignore the kwarg.
    """
    r = requests.post(
        f"{LITELLM_URL}/v1/chat/completions",
        headers={"Authorization": f"Bearer {LITELLM_KEY}"},
        json={"model": model or GEN_MODEL,
              "messages": [{"role": "user", "content": prompt}],
              "temperature": 0.2, "max_tokens": max_tokens,
              "chat_template_kwargs": {"enable_thinking": False}},
        verify=False, timeout=180)
    r.raise_for_status()
    c = r.json()["choices"][0]
    out = (c["message"].get("content") or "").strip()
    if not out:
        raise RuntimeError(f"empty content (finish_reason={c.get('finish_reason')})")
    return out


def embed_one(text):
    r = requests.post(f"{LITELLM_URL}/v1/embeddings",
                      headers={"Authorization": f"Bearer {LITELLM_KEY}"},
                      json={"model": EMBED_MODEL, "input": [text]},
                      verify=False, timeout=120)
    r.raise_for_status()
    return r.json()["data"][0]["embedding"]


# --- the traced pipeline ----------------------------------------------------
# These decorators are the whole of the tracing integration. Each call becomes
# a span; the nesting is inferred from the call stack.

@mlflow.trace(span_type="RETRIEVER")
def retrieve(question: str, k: int = TOP_K):
    vec = embed_one(question)
    body = {"size": k, "query": {"knn": {VECTOR_FIELD: {"vector": vec, "k": k}}},
            "_source": ["text", "filename"]}
    hits = os_post(f"/{OS_INDEX}/_search", body)["hits"]["hits"]
    return [{"id": h["_id"], "text": h["_source"]["text"],
             "filename": h["_source"].get("filename", "")} for h in hits]


@mlflow.trace(span_type="LLM")
def generate(question: str, context: list) -> str:
    joined = "\n\n---\n\n".join(c["text"][:1200] for c in context)
    prompt = (
        "Answer the question using ONLY the context below. If the context does "
        "not contain the answer, say exactly: I don't know.\n\n"
        f"CONTEXT:\n{joined}\n\nQUESTION: {question}\n\nANSWER:"
    )
    return llm(prompt)


@mlflow.trace(name="rag_pipeline")
def rag(question: str) -> str:
    return generate(question, retrieve(question))


# --- question set -----------------------------------------------------------

QGEN = """Below is an extract from a technical document.

Write ONE specific question that this extract answers, and that could not be
answered from a generic document on the same topic. Reply with the question
only, no preamble.

EXTRACT:
{text}"""


def build_dataset():
    """Questions with the chunk they came from as the expected answer."""
    body = {"size": 1000, "query": {"match_all": {}}, "_source": ["text"]}
    hits = os_post(f"/{OS_INDEX}/_search", body)["hits"]["hits"]
    chunks = [{"id": h["_id"], "text": h["_source"]["text"].strip()}
              for h in hits if (h["_source"].get("text") or "").strip()]
    pool = [c for c in chunks if len(c["text"]) >= 400] or chunks
    random.seed(SEED)
    sample = random.sample(pool, min(N_QUESTIONS, len(pool)))
    log(f"corpus {len(chunks)} chunks; sampling {len(sample)}")

    data = []
    for n, c in enumerate(sample, 1):
        try:
            q = llm(QGEN.format(text=c["text"][:2000]), max_tokens=120)
        except Exception as exc:
            log(f"  q{n} generation failed: {exc}")
            continue
        q = q.strip().strip('"').split("\n")[0].strip()
        if len(q) < 15:
            continue
        data.append({
            "inputs": {"question": q},
            # The chunk the question was written from is, by construction, the
            # text that answers it - so it is the reference the Correctness
            # judge grades against.
            "expectations": {"expected_response": c["text"][:1500]},
        })
    log(f"dataset: {len(data)} questions")
    return data


def main():
    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "openrag-answer-quality"))

    data = build_dataset()
    if not data:
        raise SystemExit("no questions generated")

    judge = os.environ.get("MLFLOW_GENAI_JUDGE_DEFAULT_MODEL", f"openai:/{GEN_MODEL}")
    log(f"judge model: {judge}")

    scorers = [
        Correctness(model=judge),
        RelevanceToQuery(model=judge),
        # Groundedness, which is the failure mode that actually matters in RAG:
        # a fluent answer invented from nothing scores well on everything else.
        Guidelines(
            name="grounded",
            guidelines=(
                "The response must be supported by the retrieved context. If the "
                "context does not contain the answer, the response must say it "
                "does not know rather than inventing one."
            ),
            model=judge,
        ),
    ]

    with mlflow.start_run(run_name="rag-answer-quality") as run:
        mlflow.log_params({
            "gen_model": GEN_MODEL, "judge_model": judge, "embed_model": EMBED_MODEL,
            "top_k": TOP_K, "questions": len(data), "seed": SEED,
        })
        log("evaluating (each question: 1 retrieval, 1 generation, 3 judge calls)")
        result = mlflow.genai.evaluate(data=data, scorers=scorers, predict_fn=rag)
        log(f"run {run.info.run_id}")

    print("\n=== JUDGE SCORES " + "=" * 50)
    metrics = getattr(result, "metrics", {}) or {}
    for k in sorted(metrics):
        print(f"  {k:<52} {metrics[k]}")
    if not metrics:
        print("  (no aggregate metrics returned; see the Evaluation runs tab)")


if __name__ == "__main__":
    main()
