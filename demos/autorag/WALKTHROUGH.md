# Walkthrough — AutoRAG

**8 minutes, plus run time.** The closing demo, and it only works as a
closer: it lands because the audience has already watched [demo 1](../rag-eval/)
do the same thing by hand.

## In plain English

In demo 1 we picked one question — which search engine finds the right
document — and answered it by writing a script that tried twelve
combinations. But that was one knob out of many. How should documents be
cut up? Which model turns them into numbers? Which model writes the answer?
Each is a choice, and together they multiply into more combinations than
anyone will test by hand.

AutoRAG does that search for you. You give it documents and a set of
questions with known answers, it tries a batch of configurations, and it
hands back a ranked table of which worked best.

## Before you start

Have **demo 1's results open in another tab**. The contrast is the demo.

Prerequisites come with the platform — `deploy_demos` and `demos_autorag`
are both on by default. If this is a cluster where they were skipped:

```bash
ansible-playbook site.yml --tags demos
```

Check before you present: the Pipeline Server should be Ready, and the
`rag-eval` project should list two Connections.

**Open the finished run and confirm the leaderboard renders, before the
audience is in the room.** A run started before the artifact endpoint was
fixed will show *"Unable to fetch RAG patterns"* forever — the endpoint is
recorded per artifact when the artifact is written, so the fix does not
reach backwards. On this cluster the good run is
`autorag-artifact-endpoint`; `autorag-dim-fix` and anything older will
show the error no matter what.

## 1. The callback (1 min)

**Tell** — Return to demo 1's scatter plot for a moment.

> "This took a script, a Job, and an afternoon of my time. It answered one
> question: which retriever. There are at least four more questions like it,
> and they interact — the best chunk size for one embedding model is not the
> best for another."

**Show** — Sidebar **Gen AI studio** → **AutoRAG**.

**Tell** — "Same idea, except the platform runs the search."

## 2. What it needs (1 min)

**Tell** — Worth naming, because it is less than people expect.

**Show** — Walk the Create-run form top to bottom without filling it in yet.

**Tell** —
> "Documents and a benchmark in object storage. A RAG stack to test
> against. That is it. And the RAG stack is one we already have — the Gen AI
> playground is a Llama-stack server, with Milvus and our models already
> registered, so AutoRAG reads the available models straight off it."

## 3. Create the run (3 min)

**Show** —
1. **Create run**, name it
2. **Open GenAI Stack connection** → the Llama-stack connection
3. **S3 connection** → `AutoRAG data (documents + benchmark)`
4. **Select file or folder** → **Browse bucket** → `input_data`
5. **Evaluation dataset** → **S3** → `benchmark_data.json`
6. **Vector I/O provider** → `milvus (remote Milvus)`
7. **Optimization metric** → `Overall score`
8. **Model configuration → Edit** → drop the two `sentence-transformers/…`
   embedding models, keep `endpoint-1/bge-small-en-v1.5`. Skipping this
   fails the run several minutes in; see the last note below.
9. Leave **Run preset** at its default
10. **Create run**

**Tell** —
> "Note what I did not have to do: pick the models. It pre-filled six
> generation and three embedding models, because the Llama-stack connection
> advertises them. Those are the same endpoints the earlier demos used."

## 4. While it runs (2 min)

**Tell** — Be honest that this is not a live-watch demo.

> "This explores eight RAG patterns across those models. It takes a while,
> which is the point — it is doing work you would otherwise do by hand over
> days."

**Show** — The run detail page, and the pipeline graph.

**Tell** —
> "It is a Kubeflow pipeline like any other. Load the documents, extract
> text, build the search space, optimise, evaluate, publish. Nothing about
> it is a black box; you can open any step."

## 5. The leaderboard (3 min, on a finished run) — THE PAYOFF

Do not create a run and wait. Have a finished one open in a tab and switch
to it. On this cluster that is **`autorag-artifact-endpoint`**.

**Show** — the run's results page, and the ranked table.

**Tell** — read the top and the bottom, nothing in between.

> "Eight configurations, ranked. The top one scores 0.82. The bottom one
> scores 0.52 — and look at what makes it different."

**Show** — point at the **search mode** column: seven say `hybrid`, one
says `vector`.

**Tell** —
> "That is the only pure-vector configuration in the set, and it is last by
> twenty-seven points. Everything else varies chunk size, overlap, reranker,
> generation model — and lands within five points of each other. On this
> corpus, none of those mattered much. One thing did."

**Show** — now the **context correctness** column: `0.41` on that row,
`0.64`–`0.88` on the others.

**Tell** — this is the sentence to land.
> "And this tells us *why*. Context correctness is whether the right
> passage was retrieved at all. Vector-only retrieval is what failed. The
> answer scores fall as a consequence — the model is not worse, it is being
> handed worse context. That distinction is the difference between
> replacing your model and fixing your retriever, and it is the kind of
> thing you cannot tell from one aggregate number."

**Tell** — close on what you are holding.
> "Each row carries the config that produced it, plus indexing and
> inference notebooks. The output is not a number, it is the thing you
> deploy."

### If you want one more beat

It replicates. A six-pattern run earlier the same day put its single
vector-only configuration last at 0.55 while every hybrid one scored
0.80–0.84. Two runs, different pattern counts, same answer.

## Say these before anyone else does

**It is Developer Preview.** No production SLA, and the interface may
change. Say it before someone reads it off the badge.

**The sample corpus is Red Hat's, not yours.** It demonstrates the
mechanism. A real run needs your documents and — the harder part — a
benchmark of questions with known answers. Writing that benchmark is the
actual work, and AutoRAG does not do it for you.

**One of the default generation models is the local T4** at roughly 30
tok/s, while the other five are MaaS endpoints. If the run drags, that is
usually why.

**Two of the three default embedding models cannot be fetched here.** They
are `sentence-transformers` paths, and the pod cannot download them — a
run that keeps them fails in Search Space Preparation. If you create a run
live, drop them under *Model configuration → Edit* and keep
`endpoint-1/bge-small-en-v1.5`. This is why step 3 says to leave the
defaults alone only for the walk-through of the form; a run you actually
submit needs this edit.
