# RAG answers — traced and judged

Demo #1 asked whether retrieval finds the right chunk. This asks the thing a
user actually experiences: given that chunk, is the answer any good?

Two MLflow features in one pipeline:

- **Tracing** — `@mlflow.trace` on `retrieve()` and `generate()`, so every
  question produces a trace with a RETRIEVER span and an LLM span. The
  retrieved context and the generated answer are inspectable per request
  instead of aggregated away. Populates the **Traces** tab.
- **Judging** — `mlflow.genai.evaluate` scores each answer with LLM judges.
  Populates **Evaluation runs**.

Three scorers:

| scorer | question it answers |
|---|---|
| `Correctness` | does the answer support the facts in the source chunk? |
| `RelevanceToQuery` | does it actually address what was asked? |
| `grounded` (`Guidelines`) | is it supported by the context, or invented? |

Groundedness is the one that matters in RAG. A fluent answer invented from
nothing scores well on everything else.

## Running it

```bash
oc -n rag-eval delete job rag-judge --ignore-not-found
oc create configmap rag-judge-script -n rag-eval \
  --from-file=rag_judge.py=demos/rag-judge/rag_judge.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f demos/rag-judge/job.yaml
oc -n rag-eval logs -f job/rag-judge
```

About 2.5 minutes for 12 questions. Each question costs one retrieval, one
generation and three judge calls, so cost scales at roughly 4× the question
count — raise `N_QUESTIONS` with that in mind.

Reuses the `rag-eval` namespace, ServiceAccount and credentials Secret from
[../rag-eval](../rag-eval). Set those up first.

## How the judge reaches a model

MLflow judges take `model="<provider>:/<name>"` and natively support
`openai`, `anthropic`, `bedrock` and `mistral`. LiteLLM is OpenAI-compatible,
so the `openai` provider pointed at LiteLLM works for anything LiteLLM
serves. The Job sets:

```
OPENAI_API_BASE / OPENAI_BASE_URL -> http://litellm.litellm.svc.cluster.local:4000/v1
OPENAI_API_KEY                    -> the LiteLLM master key
MLFLOW_GENAI_JUDGE_DEFAULT_MODEL  -> openai:/granite-3-2-8b-instruct
```

Note `mlflow`, not `mlflow-skinny` — the genai and scorer APIs are not in
skinny.

## Two deliberate choices

**The generator is a MaaS model, not the local GPU one.** `granite-3-2-8b-instruct`
is a remote endpoint behind LiteLLM, so this demo survives the GPU node being
unavailable — which it was, an hour before this was written. Set `GEN_MODEL`
to `qwen3-4b` to exercise the local model instead.

**Judge and generator should not be the same model.** A model grading its own
output is the first objection anyone will raise. They are the same here only
because granite is currently the most capable always-available endpoint;
point `MLFLOW_GENAI_JUDGE_DEFAULT_MODEL` at a different LiteLLM model
(`qwen38-27b`, `mistral-small`) and the demo is materially stronger.

## Reading the result

The first run scored `0.917` on all three scorers — that is 11 of 12, and the
identical figure across scorers suggests a single question failing all three
rather than three independent failures. Click into the **Evaluation runs**
tab, find the failing case, and open its trace: you can see exactly what was
retrieved and what the model did with it. That one example is a better demo
than the aggregate.
