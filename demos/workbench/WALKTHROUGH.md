# Walkthrough — workbenches

Not a scripted demo so much as the interactive surface to fall back to when
someone asks "but can I just try it?".

Two exist, both in the `rag-eval` project under **Workbenches**:

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

## Points worth making

**Why CPU and GPU separately.** Browsing MLflow runs and querying a corpus
needs no accelerator. Taking a 45 GiB card out of the pool to read a
dataframe is waste, and a workbench holds its GPU the whole time it is
running — idle or not.

**Why the GPU one is pinned to the L40S.** Ada Lovelace, so bf16 and Flash
Attention 2 both work. The T4s are Turing with 15 GiB: fp16 only, no FA2,
and most fine-tuning recipes assume otherwise. The nodeSelector is there to
stop the scheduler quietly making a worse choice.

**Why the CPU one has node anti-affinity.** The obvious assumption — that
the `nvidia.com/gpu` taint keeps non-GPU pods off GPU nodes — is false on
this cluster. The gpu_worker role creates the MachineSets with **no taints**,
so GPU nodes accept ordinary workloads; this pod landed on a T4 box the
first time. It doesn't consume a GPU, but it competes for CPU and memory on
the most expensive nodes available.

**Stop them when you're done.** `Actions → Stop` in the dashboard. The PVC
and its contents survive; the GPU is released.

## The honest caveat

Everything else under `demos/` is a Job: reproducible, in git, one command.
A workbench is the opposite — its contents live on a PVC and are nobody's
source of truth. Good for exploring and demonstrating, bad as the place
real work accumulates.
