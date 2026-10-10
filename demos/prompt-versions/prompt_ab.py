"""Prompt engineering with evidence instead of vibes.

Three versions of the same RAG answering prompt are registered in MLflow's
Prompt Registry, an agent loads one BY VERSION rather than having it
hardcoded, and all three are evaluated against the same questions with the
same judges. The output is a ranking: this prompt is better than that one,
by this much, on these criteria.

That is the whole argument. Prompts normally change by someone editing a
string in a source file, with no record of what the previous one was or
whether the change helped. Here the prompt is a registry artifact with a
version, the agent references it by URI, and the evaluation says which
version to ship.

Fills four of MLflow's GenAI sections that are otherwise empty: Prompts,
Datasets, Evaluation runs and Traces.
"""

from __future__ import annotations

import os
import random
import time

import mlflow
import mlflow.genai
import requests
import urllib3

from usage import record_usage
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

PROMPT_NAME = os.environ.get("PROMPT_NAME", "openrag-rag-answer")
N_QUESTIONS = int(os.environ.get("N_QUESTIONS", "10"))
TOP_K = int(os.environ.get("TOP_K", "5"))
SEED = int(os.environ.get("SEED", "1337"))


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


# Three strategies, deliberately different in kind rather than in wording,
# so the comparison says something about approach and not about synonyms.
# MLflow prompt templates use {{double braces}}.
VARIANTS = [
    ("terse: no guidance beyond the task",
     "Context:\n{{context}}\n\nQuestion: {{question}}\nAnswer:"),

    ("grounded: forbid invention, allow refusal",
     "Answer the question using ONLY the context below. If the context does "
     "not contain the answer, reply exactly: I don't know.\n\n"
     "CONTEXT:\n{{context}}\n\nQUESTION: {{question}}\n\nANSWER:"),

    ("grounded + cite: same, but attribute the claim",
     "You answer questions about technical documentation.\n\n"
     "Rules:\n"
     "1. Use ONLY the context below.\n"
     "2. If the context does not contain the answer, reply exactly: I don't know.\n"
     "3. Be concise - two sentences at most.\n"
     "4. End with the document title you used, in square brackets.\n\n"
     "CONTEXT:\n{{context}}\n\nQUESTION: {{question}}\n\nANSWER:"),
]


def os_post(path, payload):
    r = requests.post(f"{OS_URL}{path}", auth=(OS_USER, OS_PASS), verify=False,
                      json=payload, timeout=120)
    r.raise_for_status()
    return r.json()


def llm(prompt, max_tokens=400):
    r = requests.post(
        f"{LITELLM_URL}/v1/chat/completions",
        headers={"Authorization": f"Bearer {LITELLM_KEY}"},
        json={"model": GEN_MODEL, "messages": [{"role": "user", "content": prompt}],
              "temperature": 0.2, "max_tokens": max_tokens,
              "chat_template_kwargs": {"enable_thinking": False}},
        verify=False, timeout=180)
    r.raise_for_status()
    body = r.json()
    c = body["choices"][0]
    # LiteLLM returns a usage block on every response. Recording it on the
    # active span is what makes MLflow's Token usage and Tokens per trace
    # panels show anything; discarding it is why they read zero.
    record_usage(body.get("usage") or {}, r.headers)
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


@mlflow.trace(span_type="RETRIEVER")
def retrieve(question: str, k: int = TOP_K):
    body = {"size": k,
            "query": {"knn": {VECTOR_FIELD: {"vector": embed_one(question), "k": k}}},
            "_source": ["text", "filename"]}
    hits = os_post(f"/{OS_INDEX}/_search", body)["hits"]["hits"]
    return [{"text": h["_source"]["text"], "filename": h["_source"].get("filename", "")}
            for h in hits]


def make_agent(prompt_version):
    """An agent bound to one registered prompt version.

    The prompt is not in this file. It is fetched from the registry by URI,
    which is the point: changing the prompt is a registry operation with a
    version and a commit message, not an edit to source.
    """
    @mlflow.trace(span_type="LLM")
    def generate(question: str, context: str) -> str:
        return llm(prompt_version.format(context=context, question=question))

    @mlflow.trace(name="rag_agent")
    def agent(question: str) -> str:
        chunks = retrieve(question)
        context = "\n\n---\n\n".join(
            f"[{c['filename']}]\n{c['text'][:1200]}" for c in chunks)
        return generate(question, context)

    return agent


QGEN = """Below is an extract from a technical document.

Write ONE specific question that this extract answers. Reply with the
question only, no preamble.

EXTRACT:
{text}"""


def build_questions():
    body = {"size": 1000, "query": {"match_all": {}}, "_source": ["text"]}
    hits = os_post(f"/{OS_INDEX}/_search", body)["hits"]["hits"]
    chunks = [{"id": h["_id"], "text": h["_source"]["text"].strip()}
              for h in hits if (h["_source"].get("text") or "").strip()]
    pool = [c for c in chunks if len(c["text"]) >= 400] or chunks
    random.seed(SEED)
    sample = random.sample(pool, min(N_QUESTIONS, len(pool)))

    data = []
    for c in sample:
        try:
            q = llm(QGEN.format(text=c["text"][:2000]), max_tokens=120)
        except Exception as exc:
            log(f"  question generation failed: {exc}")
            continue
        q = q.strip().strip('"').split("\n")[0].strip()
        if len(q) >= 15:
            data.append({"inputs": {"question": q},
                         "expectations": {"expected_response": c["text"][:1500]}})
    log(f"question set: {len(data)}")
    return data


def main():
    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "openrag-prompt-versions"))

    # --- register the three versions --------------------------------------
    versions = []
    for commit, template in VARIANTS:
        pv = mlflow.genai.register_prompt(
            name=PROMPT_NAME, template=template, commit_message=commit,
            tags={"task": "rag-answer", "corpus": "openrag-docs"})
        versions.append(pv)
        log(f"registered {PROMPT_NAME} v{pv.version}: {commit}")

    data = build_questions()
    if not data:
        raise SystemExit("no questions generated")

    # --- an evaluation dataset, so the question set is a first-class object
    # rather than something regenerated differently on every run ------------
    try:
        ds = mlflow.genai.create_dataset(
            name=f"openrag-qa-{SEED}",
            tags={"source": "openrag-docs", "generator": GEN_MODEL})
        ds.merge_records(data)
        log(f"dataset '{ds.name}' with {len(data)} records")
    except Exception as exc:
        # Not fatal - the comparison below is the demo; the Dataset entity
        # only makes the question set reusable.
        log(f"dataset registration skipped: {type(exc).__name__}: {exc}")

    judge = os.environ.get("MLFLOW_GENAI_JUDGE_DEFAULT_MODEL", f"openai:/{GEN_MODEL}")
    scorers = [
        Correctness(model=judge),
        RelevanceToQuery(model=judge),
        Guidelines(name="grounded",
                   guidelines=("The response must be supported by the retrieved "
                               "context. If the context does not contain the "
                               "answer, it must say it does not know."),
                   model=judge),
    ]

    results = []
    with mlflow.start_run(run_name="prompt-version-ab") as parent:
        mlflow.log_params({"prompt_name": PROMPT_NAME, "versions": len(versions),
                           "gen_model": GEN_MODEL, "judge_model": judge,
                           "questions": len(data), "top_k": TOP_K, "seed": SEED})
        for pv, (commit, _) in zip(versions, VARIANTS):
            log(f"evaluating v{pv.version} ({commit.split(':')[0]})")
            with mlflow.start_run(run_name=f"prompt-v{pv.version}", nested=True):
                mlflow.log_params({"prompt_version": pv.version,
                                   "prompt_uri": pv.uri, "strategy": commit})
                res = mlflow.genai.evaluate(data=data, scorers=scorers,
                                            predict_fn=make_agent(pv))
                m = {k: v for k, v in (getattr(res, "metrics", {}) or {}).items()}
                results.append({"version": pv.version, "strategy": commit, **m})
                for k, v in m.items():
                    log(f"    {k} = {v}")
        log(f"parent run {parent.info.run_id}")

    print("\n=== PROMPT VERSION COMPARISON " + "=" * 40)
    keys = sorted({k for r in results for k in r if k not in ("version", "strategy")})
    print(f"{'v':<4}{'strategy':<42}" + "".join(f"{k.split('/')[0][:14]:>16}" for k in keys))
    for r in results:
        row = f"{r['version']:<4}{r['strategy'][:40]:<42}"
        for k in keys:
            val = r.get(k)
            row += f"{val:>16.3f}" if isinstance(val, (int, float)) else f"{'-':>16}"
        print(row)


if __name__ == "__main__":
    main()
