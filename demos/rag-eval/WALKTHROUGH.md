# Walkthrough — retrieval A/B

**8–10 minutes.** The strongest single demo here, because the result is one
nobody predicts.

## Before you start

Open the UI at the **workspace-scoped** URL:

```
https://<data-science-gateway>/mlflow/#/experiments/1?workspace=rag-eval
```

Keep `?workspace=rag-eval`. The bare path lands in a different workspace
with an empty experiment list, which looks exactly like nothing ever ran.

Have a terminal ready with the repo checked out.

## 1. Pose the question (30s, no screen)

> "We run RAG here. The corpus lives in OpenSearch. We also deployed Milvus,
> a dedicated vector database. Which should we retrieve from?"

Let someone guess. Most people say Milvus — it's purpose-built. Nobody
actually knows.

## 2. Explain the experiment in three sentences

> "OpenRAG has 168 chunks of documentation indexed. I had a model write 40
> questions, each answerable by exactly one chunk I already know the ID of.
> Then I asked three different search engines to find that chunk, and
> counted how often each one did."

Then the fairness point, which is what makes the result mean anything:

> "Milvus got OpenSearch's own vectors, not new ones. Same embeddings, same
> distance metric. The only thing that differs is the engine."

## 3. Provenance (1 min)

Open the `retriever-sweep` parent run → **Params**:

```
corpus_chunks 168    embed_model bge-small-en-v1.5
chunk_size    1000   chunk_overlap 200
metric        L2     seed 1337
```

> "Not 'we ran an experiment' — here is exactly what was true when we ran
> it. Same seed, same corpus, reproducible in six months."

## 4. The top_k insight (2 min)

Experiment → select the **12 child runs** (not the parent, it has no
`retriever`/`top_k`) → **Compare** → **Parallel Coordinates**.

- Parameters: `retriever`, `top_k`
- Metrics: `hit_rate`

> "Follow the lines that land at 0.95 — they all come through top_k 10.
> The ones dropping to 0.65 come through top_k 1. The biggest lever isn't
> which engine you picked, it's how many results you let it return."

## 5. The punchline (2 min)

Switch to **Scatter Plot**: `ms_per_query` on x, `hit_rate` on y.

Use scatter here, not parallel coordinates — identical runs draw *on top of
each other* in parallel coordinates, so the thing you're claiming is
invisible. In scatter it's two points at identical height, far apart
horizontally.

> "OpenSearch kNN and Milvus kNN are identical on every quality metric —
> same hit rate, same MRR, same nDCG. Not a coincidence: same vectors, same
> metric, so the same neighbours. **This is not a quality decision.** It's
> 3ms versus 33ms. And you only know that because it was measured."

## 6. Live re-run (2 min)

Change the seed — that asks a real question ("is this stable, or an
artefact of which 40 chunks I sampled?"):

```bash
oc -n rag-eval delete job rag-eval
sed 's/value: "1337"/value: "7"/' demos/rag-eval/job.yaml | oc apply -f -
```

Talk through the architecture for ~90 seconds, refresh, 13 new runs appear.

> "If the numbers hold across seeds, that's credibility. If they move,
> that's a more interesting finding than the original result."

## Say these before anyone else does

**BM25 has the better MRR (0.838 vs 0.769).** The questions were generated
from each chunk's own wording, which structurally flatters keyword matching.
Raise it yourself — if you don't, someone will, and it'll look like you
missed it. It sets up the honest next step: a human-labelled question set.

**The 10× latency gap is partly protocol.** Milvus is gRPC; OpenSearch here
is HTTPS with auth across three replicas.

**Nothing reaches 1.00.** Two of 40 questions are missed by every retriever,
most likely generated too vaguely to identify their source.

## If something breaks

| Symptom | Cause |
|---|---|
| Empty experiment list | Wrong workspace — check `?workspace=rag-eval` |
| Job fails "0 usable questions" | Chat model returning empty content; see the README on `enable_thinking` |
| Job can't reach the model | `GEN_MODEL` points at the GPU model and the node is down — use a MaaS model |
