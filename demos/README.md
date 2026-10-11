# Demos

Seven things this cluster can be shown doing, all built against a live
deployment and all deployed by Ansible with the rest of the platform. Every
one of them answers a question with evidence rather than asserting a
capability.

## In plain English

Most of these demos are about one idea: **when you build something with AI,
you are making choices you cannot eyeball.** Which search engine finds the
right document? Is the answer any good? Which wording of the instruction
works best? People normally settle those by argument, or by whoever is most
confident in the room.

MLflow is the tool that turns those arguments into measurements. It records
what you tried, what the conditions were, and what came out — so the answer
survives the meeting, and you can check it again in six months.

The demos below each pick one such question and answer it properly. Two of
them (4 and 5) are about a different thing: getting a trained model out of
somebody's laptop and onto the cluster where it can actually serve
requests.

They are Kubernetes Jobs rather than notebooks, deliberately: a Job is
reproducible, lives in git, and re-runs with one command. The two
workbenches exist for the interactive half of the story.

Each demo has two documents: a **README** explaining how it works and what
is easy to get wrong, and a **WALKTHROUGH** scripting how to present it.

| # | Demo | Shows | GPU | Runtime |
|---|------|-------|-----|---------|
| 1 | [rag-eval](rag-eval/) | Retrieval A/B: OpenSearch BM25 vs OpenSearch kNN vs Milvus, tracked in MLflow | no | ~100s |
| 2 | [rag-judge](rag-judge/) | Tracing + LLM judges scoring answer quality | no | ~2.5m |
| 3 | [prompt-versions](prompt-versions/) | Prompt Registry: three versions, evaluated head to head | no | ~4m |
| 4 | [tabular-mlops](tabular-mlops/) | Classic MLOps: sklearn grid, autolog, compare, register | no | ~2m |
| 5 | [model-serving](model-serving/) | The registry → KServe hop, with a live prediction | no | ~3m |
| 6 | [workbench](workbench/) | Interactive Jupyter, CPU and L40S GPU | optional | n/a |
| 7 | [autorag](autorag/) | AutoRAG: the platform running demo 1's sweep automatically, over a much larger space | no | run ~20-40m |

## Which to show

**If you have ten minutes:** demo 1, then demo 5. One measures something
nobody knew; the other completes a lifecycle people assume is harder than
it is.

**If the audience is LLM-focused:** 1 → 2 → 3. That is a coherent arc —
*does retrieval find the right thing, are the answers any good, and which
prompt should we ship* — and each builds on the last.

**If there are traditional data scientists in the room:** 4 → 5. No LLMs,
no GPU, and the registry-to-serving handoff is the part that makes it real.

**If you are closing a longer session:** finish on demo 7. It only works
after demo 1 — the point is the contrast between a sweep you wrote and a
sweep the platform runs.

**If you want one slide that justifies the platform:** demo 1's result
next to demo 7's. Demo 1: a dedicated vector database and a search engine
doing vectors on the side retrieve *identically* — the choice is latency,
not quality. Demo 7, sweeping eight configurations: the only one that used
vector search *on its own* scored 0.52 while every hybrid configuration
landed between 0.77 and 0.82, whatever the model or chunk size — and its
*context correctness* was 0.41 against their 0.64–0.88, so it is retrieval
that fails and the answers that suffer for it. A six-pattern run earlier
the same day said the same thing.

So: which vector store you buy barely matters, and whether you use it
alone matters enormously. Both are counterintuitive, both are measured,
and nobody believes either from an argument.

## Dependencies between them

```
tabular-mlops ──registers a model──▶ model-serving
rag-eval ──same corpus, same Q&A pattern──▶ rag-judge ──▶ prompt-versions
```

- **model-serving requires tabular-mlops** to have run; it serves what that
  demo registers.
- rag-eval, rag-judge and prompt-versions are independent of each other but
  all need OpenRAG deployed with an ingested corpus.
- The workbenches need nothing.

## Deploying them

They are a role, and it is on by default:

```bash
ansible-playbook site.yml --tags demos
```

The role prepares the shared `rag-eval` namespace once — labelled as a Data
Science Project, with the ServiceAccount and credentials Secret the Jobs
share — then applies each demo that is switched on. It checks that MLflow
is deployed first and stops with a usable message if it is not.

Switches in `group_vars/all.yml`, all `true`:

| Variable | Demo |
|---|---|
| `deploy_demos` | the lot |
| `demos_rag_eval` | 1 |
| `demos_rag_judge` | 2 |
| `demos_prompt_versions` | 3 |
| `demos_tabular` | 4 |
| `demos_model_serving` | 5 |
| `demos_workbenches` | 6 |
| `demos_autorag` | 7 |

`demos_run_jobs` (also `true`) decides whether the Jobs are *run* or merely
created. Leave it on: a demo that has never run shows empty panels, which
is worse than no demo at all — the experiments, traces, judges and
registered model only exist once something has executed. It costs roughly
ten minutes of build time and some MaaS tokens.

`demos_workbenches` is the one to think about. The L40S workbench holds its
card for as long as it runs, idle or not, so on a cluster with one spare
accelerator it blocks training jobs.

The per-demo directories keep their manifests and scripts, so each still
reads and runs on its own; the role is what is maintained.

On the cluster itself:

| Needed by | What |
|---|---|
| 1, 2, 3 | OpenRAG deployed (`deploy_openrag=true`) with an ingested corpus |
| 1 | Milvus deployed (`deploy_milvus=true`) |
| 1, 2, 3 | LiteLLM serving a chat model and `bge-small-en-v1.5` |
| 4, 5 | Nothing beyond MLflow and ODF |
| 7 | ODF for the buckets, Milvus, and the Gen AI playground as its Llama-stack server |
| all | RHOAI's MLflow — see [rag-eval/README.md](rag-eval/README.md#talking-to-rhoais-mlflow) |

## Two things that will bite you

**Keep `?workspace=<namespace>` on the MLflow UI URL.** Workspaces map 1:1
to namespaces. Open the bare path and you land in a different workspace with
an empty experiment list, which looks exactly like "nothing ever ran". This
is the single most likely way a live demo fails.

**Demos 1-3 generate with a MaaS model, not the cluster's own GPU model.**
That is deliberate. The GPU node went down twice while these were being
built, taking `qwen3-4b` with it. Set `GEN_MODEL=qwen3-4b` to exercise the
local model when you want to show it; leave it alone when you want the demo
to survive the hardware.

## Where the results live

```
MLflow UI   https://<data-science-gateway>/mlflow/#/experiments/<id>?workspace=rag-eval
RHOAI       https://<rhods-dashboard>/projects/rag-eval
```

| Experiment | From |
|---|---|
| `openrag-retrieval-ab` | demo 1 |
| `openrag-answer-quality` | demo 2 |
| `openrag-prompt-versions` | demo 3 |
| `breast-cancer-tabular` | demo 4 |

Plus a registered model (`breast-cancer-classifier`), a prompt
(`openrag-rag-answer`, three versions), and a served InferenceService
(`breast-cancer`).
