# Walkthrough — workbenches

Not a scripted demo so much as the interactive surface to fall back to when
someone asks "but can I just try it?".

## In plain English

Every other demo here runs start to finish on its own and prints a result.
This one is the opposite: a desk to sit down at, in the browser, and poke at
the same data by hand. It is what you open when someone stops watching the
slides and wants to type something themselves. Two are set up — a small one
for looking at results, and a bigger one with a graphics card attached for
the heavier work of training a model — and most of what follows is about why
that difference is worth the trouble.

Two exist, both in the `rag-eval` project under **Workbenches**:

**Show** — RHOAI dashboard, left nav **Projects** → **rag-eval** → the
**Workbenches** tab. Both are listed there, and a running one is opened from
that same tab.

| Name | Image | Hardware | For |
|---|---|---|---|
| RAG Eval Workbench (CPU) | Data Science, Python 3.12 | CPU, plain worker | exploring the demos interactively |
| RAG Eval GPU Workbench (L40S) | PyTorch + CUDA, Python 3.12 | 1× L40S, 45 GiB | fine-tuning |

Both have `MLFLOW_TRACKING_URI`, `MLFLOW_TRACKING_INSECURE_TLS` and
`MLFLOW_WORKSPACE` pre-set, so the first cell can be:

```python
import mlflow
mlflow.search_runs(experiment_names=["openrag-retrieval-ab"])
```

...with no URL copied out of a README. The CPU one also has
`OPENSEARCH_URL` and `LITELLM_URL`.

> **Plain English:** a workbench opens in the browser as a Jupyter notebook —
> a page split into cells, where you type a few lines into a cell, run it, and
> the answer appears underneath. Pre-set means the notebook already knows the
> addresses of the other services, so nobody has to go and find them first.

## If you do show it live

There is no script to follow here, so there is only one thing worth doing in
front of people, and it is short.

**Tell** — "Everything else tonight ran as a job and printed a result. This
is the same data with a keyboard in front of it."

**Show** —
1. Left nav **Projects** → **rag-eval** → **Workbenches**. Open **RAG Eval
   Workbench (CPU)**.
2. In the notebook, run the two-line cell above as the first cell.
3. `Actions → Stop` on that workbench's row once you are finished.

**Tell** — the runs came back without anyone typing a tracking URL, because
the environment variables are already in the pod. That is the whole of what
this surface proves; the rest of this file is why there are two of them and
why you stop them.

## Points worth making

**Why CPU and GPU separately.** Browsing MLflow runs and querying a corpus
needs no accelerator. Taking a 45 GiB card out of the pool to read a
dataframe is waste, and a workbench holds its GPU the whole time it is
running — idle or not.

> **Plain English:** the 45 GiB is memory on the graphics card itself, and the
> card goes to one workbench at a time. An open workbench with nothing running
> in it is a hire car sitting on the drive with the meter going.

**Why the GPU one is pinned to the L40S.** Ada Lovelace, so bf16 and Flash
Attention 2 both work. The T4s are Turing with 15 GiB: fp16 only, no FA2,
and most fine-tuning recipes assume otherwise. The nodeSelector is there to
stop the scheduler quietly making a worse choice.

> **Plain English:** bf16 and fp16 are two ways of writing numbers in half the
> usual space so a model fits in a smaller card; the newer L40S does both, the
> older T4 only fp16, and published recipes tend to assume bf16 — Flash
> Attention 2 is a speed-up in the same bracket, newer cards only. The
> nodeSelector is the line that says "put me on an L40S", because left to
> itself the scheduler takes whichever GPU happens to be free.

**Why the CPU one has node anti-affinity.** The obvious assumption — that
the `nvidia.com/gpu` taint keeps non-GPU pods off GPU nodes — is false on
this cluster. The gpu_worker role creates the MachineSets with **no taints**,
so GPU nodes accept ordinary workloads; this pod landed on a T4 box the
first time. It doesn't consume a GPU, but it competes for CPU and memory on
the most expensive nodes available.

> **Plain English:** a taint is a "keep out unless invited" sign on a machine,
> and anti-affinity is the pod's own "don't put me there" rule. The GPU
> machines here were built without the sign, so the CPU workbench has to
> refuse them itself.

**Stop them when you're done.** `Actions → Stop` in the dashboard. The PVC
and its contents survive; the GPU is released.

**Show** — left nav **Projects** → **rag-eval** → **Workbenches**, then
`Actions → Stop` on the row for the workbench you are finished with.

> **Plain English:** the PVC is the workbench's own disk. Stopping it hands
> the hardware back but keeps the files, so everything is where you left it
> next time it starts.

## The honest caveat

Everything else under `demos/` is a Job: reproducible, in git, one command.
A workbench is the opposite — its contents live on a PVC and are nobody's
source of truth. Good for exploring and demonstrating, bad as the place
real work accumulates.

> **Plain English:** the other demos are recipes anyone can run again and get
> the same result. A workbench is a scratch pad — fine for showing someone
> around, the wrong place to leave work you would miss.
