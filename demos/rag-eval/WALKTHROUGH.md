# Walkthrough — retrieval A/B

**8–10 minutes.** The strongest single demo here, because the result is one
nobody predicts.

## In plain English

Ask a chatbot a question about your own documents and something has to find
the right page before the model can answer. This demo tries three different
ways of doing that finding, over the same set of documents, and counts how
often each one lands on the right page. Two of the three turn out to be
equally accurate, and one of those two is about ten times faster. The point
is less which one wins than that nobody in the room could have told you
without measuring it.

## Before you start

Open the UI at the **workspace-scoped** URL:

```
https://<data-science-gateway>/mlflow/#/experiments/1?workspace=rag-eval
```

Keep `?workspace=rag-eval`. The bare path lands in a different workspace
with an empty experiment list, which looks exactly like nothing ever ran.

Have a terminal ready with the repo checked out.

Two controls in the MLflow sidebar are worth finding before the room is
watching: the workspace pill at the top left, which should read **rag-eval**,
and the **GenAI** | **Model training** toggle below it. Every step here uses
**Model training**.

## 1. Pose the question (30s, no screen)

**Tell** — Hand the room the decision before you hand them any evidence. A
guess said out loud is what makes the measurement land when it arrives.

**Show** — Nothing on screen for this one. Put the question to the room and
wait:

> "We run RAG here. The corpus lives in OpenSearch. We also deployed Milvus,
> a dedicated vector database. Which should we retrieve from?"

> **Plain English:** RAG is the pattern where a chatbot searches your own
> documents and answers from what it finds, rather than from what it picked
> up in training. That search step is called retrieval, and OpenSearch and
> Milvus are two candidates for doing it.

Let someone guess.

**Tell** — Most people say Milvus — it's purpose-built. Nobody
actually knows. The distance between the confident answer and the measured one
is what the rest of the demo is for.

## 2. Explain the experiment in three sentences

**Tell** — Still nothing on screen. The room has to believe the measurement
before it will believe the result, so the method comes before any numbers.

**Show** — Say these three sentences, in this order:

> "OpenRAG has 168 chunks of documentation indexed. I had a model write 40
> questions, each answerable by exactly one chunk I already know the ID of.
> Then I asked three different search engines to find that chunk, and
> counted how often each one did."

> **Plain English:** the documents are cut into 168 short passages, or chunks,
> because a search hands back a passage rather than a whole file. Writing each
> question from a chunk you can name gives you a marking scheme — one right
> answer per question, checkable without a human.

Then the fairness point, which is what makes the result mean anything:

> "Milvus got OpenSearch's own vectors, not new ones. Same embeddings, same
> distance metric. The only thing that differs is the engine."

> **Plain English:** an embedding turns a passage into a list of numbers that
> stands for its meaning, so two ways of saying the same thing end up with
> similar numbers. Loading Milvus with OpenSearch's existing lists means both
> engines hunt for the same neighbours, so anything that differs is the engine
> and not the maths.

**Tell** — With the embeddings, the distance metric and the corpus all held
constant, the engine is the only thing left varying. That is what earns this
the right to be called a like-for-like comparison.

## 3. Provenance (1 min)

**Tell** — Before any result, show where the numbers came from. It is one
screen, and it is the one that buys you the benefit of the doubt for
everything after it.

**Show** — Sidebar toggle **Model training** → **Runs** → open the run named
`retriever-sweep`, the parent that the twelve child runs sit under →
**Params**:

```
corpus_chunks 168    embed_model bge-small-en-v1.5
chunk_size    1000   chunk_overlap 200
metric        L2     seed 1337
```

**Tell** — Leave it on screen for a beat. `seed 1337` is the line you come
back to in step 6.

> "Not 'we ran an experiment' — here is exactly what was true when we ran
> it. Same seed, same corpus, reproducible in six months."

## 4. The top_k insight (2 min)

**Tell** — Twelve runs go on one chart: three retrievers, four `top_k`
settings each. The first thing it shows is not the thing the room argued
about in step 1.

**Show** — Sidebar toggle **Model training** → **Runs**, then:

1. Tick the checkbox on each of the **12 child runs**.
2. Leave the `retriever-sweep` parent row **unticked** — it has no
   `retriever`/`top_k`.
3. Press **Compare**. The page should be headed **Comparing 12 runs from 1
   experiment**. If it reads 13, the parent came along — go back and untick it.
4. In **Visualizations**, select the **Parallel Coordinates Plot** tab.
5. Under the chart, press **Clear All** to empty both dropdowns.
6. **Parameters:** add the chips `retriever` and `top_k`.
7. **Metrics:** add the chip `hit_rate`.

**Tell**

> **Plain English:** a parallel-coordinates chart draws one line per run,
> threading left to right through the settings that run used and ending at
> the score it got. The twelve lines are three search methods, each tried at
> four settings.

> "Follow the lines that land at 0.95 — they all come through top_k 10.
> The ones dropping to 0.65 come through top_k 1. The biggest lever isn't
> which engine you picked, it's how many results you let it return."

> **Plain English:** `top_k` is how many results the search is allowed to hand
> back — at 1 it has to be right first time, at 10 the correct chunk only has
> to appear somewhere in the ten. Hit rate is the share of the 40 questions
> where it did appear.

The setting nobody in the room was arguing about is the one doing the work.

## 5. The punchline (2 min)

**Tell** — Same twelve runs, different chart, and this one answers the
question you asked in step 1.

Use scatter here, not parallel coordinates — identical runs draw *on top of
each other* in parallel coordinates, so the thing you're claiming is
invisible. In scatter it's two points at identical height, far apart
horizontally.

**Show** — Stay on the compare page. Switch to **Scatter Plot**:
`ms_per_query` on x, `hit_rate` on y.

1. In **Visualizations**, select the **Scatter Plot** tab.
2. **Metrics:** add the chip `ms_per_query`, keeping `hit_rate`.
3. Put `ms_per_query` on the x axis and `hit_rate` on the y axis, using the
   axis controls that sit with the chart. Their exact labels are not recorded
   here, so find them on the screen rather than from this page.
4. Point at the two points sitting at the same height, far apart
   horizontally.

**Tell**

> "OpenSearch kNN and Milvus kNN are identical on every quality metric —
> same hit rate, same MRR, same nDCG. Same vectors, same metric, and on this
> corpus they return the same neighbours. **This is not a quality decision.**
> It's 3ms versus 33ms. And you only know that because it was measured."

> **Plain English:** MRR and nDCG both measure how near the top of the list
> the right chunk came, not merely whether it was in there at all. kNN means
> "find the nearest numbers" — both engines are searching the same numbers,
> and here they came back with the same chunks in the same order.

**Do not claim the match is guaranteed.** Both engines use *approximate*
nearest-neighbour indexes (HNSW), built with different parameters — Milvus at
`M=16, efConstruction=200`, OpenSearch with its own. Two approximate indexes
are not obliged to agree on ordering. Identical scores across all four `top_k`
values on a 168-chunk corpus is a measured result, and a striking one, but it
is not a law, and it may not hold at a million chunks. If someone who knows
HNSW challenges this, agreeing with them is the correct answer — and the
finding is unchanged either way: on this corpus, the engine is not what
decides quality.

## 6. Live re-run (2 min)

**Tell** — Nothing so far shows the result is stable. Change the seed — that
asks a real question ("is this stable, or an artefact of which 40 chunks I
sampled?"):

**Show** — In the terminal:

```bash
oc -n rag-eval delete job rag-eval
sed 's/value: "1337"/value: "7"/' demos/rag-eval/job.yaml | oc apply -f -
```

Talk through the architecture for ~90 seconds, then refresh the browser on
the MLflow run list.

**Tell** — 13 new runs appear: the twelve children and their parent, on a
question set drawn with a different seed.

> "If the numbers hold across seeds, that's credibility. If they move,
> that's a more interesting finding than the original result."

## Say these before anyone else does

**BM25 has the better MRR (0.838 vs 0.769).** The questions were generated
from each chunk's own wording, which structurally flatters keyword matching.
Raise it yourself — if you don't, someone will, and it'll look like you
missed it. It sets up the honest next step: a human-labelled question set.

> **Plain English:** BM25 is keyword matching — it scores a chunk on the words
> it shares with the question. The questions were written from each chunk's
> own wording, so they reuse its words, which is the one thing keyword
> matching is best at; that is a flaw in the marking scheme rather than a win
> for BM25.

**The 10× latency gap is partly protocol.** Milvus is gRPC; OpenSearch here
is HTTPS with auth across three replicas.

> **Plain English:** gRPC and HTTPS are two different ways for programs to
> talk to each other over a network. Part of the speed difference is that
> plumbing rather than the search itself.

**Nothing reaches 1.00.** Two of 40 questions are missed by every retriever,
most likely generated too vaguely to identify their source.

## If something breaks

| Symptom | Cause |
|---|---|
| Empty experiment list | Wrong workspace — check `?workspace=rag-eval` |
| Job fails "0 usable questions" | Chat model returning empty content; see the README on `enable_thinking` |
| Job can't reach the model | `GEN_MODEL` points at the GPU model and the node is down — use a MaaS model |
