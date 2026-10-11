# AutoRAG — the platform doing demo 1 for you

[rag-eval](../rag-eval/) hand-rolled a sweep: three retrievers by four
`top_k` values, twelve combinations, one script. AutoRAG does the same kind
of search automatically over a far larger space — chunking strategy,
embedding model, generation model, retrieval parameters — and ranks the
results on a leaderboard.

It is Developer Preview, and it runs as the **Documents RAG Optimization
Pipeline** on Kubeflow Pipelines, using IBM's ai4rag optimisation engine
against a Llama-stack RAG server.

That makes it the natural closing demo: *"we measured one axis by hand;
here is the platform measuring all of them."*

## Setup

The prerequisites are an Ansible role, on by default:

```bash
ansible-playbook site.yml --tags demos
```

`deploy_demos` and `demos_autorag` in `group_vars/all.yml` both gate it.
The role creates the Pipeline Server and its artifact bucket, a data
bucket, both Connections, the NetworkPolicy the pipeline needs, and seeds
Red Hat's published sample corpus — the Summit 2026 session catalogue, four
markdown files and a 13-question benchmark.

A `setup.sh` did this first. It is gone: it predated the NetworkPolicy and
the second set of client keys, so running it today produces an AutoRAG that
fails several minutes into a run. The YAML in this directory is kept as a
readable record of the shape — the role builds those same objects, from
values it reads back off the cluster rather than substituting with `sed`.

Then, in the dashboard: **Gen AI studio → AutoRAG → Create run**.

## What was already here, and what was not

Worth knowing before you try this on another cluster, because the gap is
smaller than the prerequisites list suggests:

| Needed | On this cluster |
|---|---|
| Kubeflow Pipelines + Pipeline Server | **missing** — this is what the role adds |
| autorag-ui | already deployed by RHOAI |
| Llama-stack RAG server | already — the Gen AI playground *is* one |
| Vector store | already — Milvus |
| Chat + embedding models | already — via LiteLLM |
| Object storage | already — NooBaa |

The Llama-stack one is the pleasant surprise. The upstream guide has you
deploy a Llama-stack server; you do not need to. The Gen AI playground
serves the llama-stack API on `:8321` with Milvus registered as a vector
store and the LiteLLM models as inference providers, so AutoRAG enumerates
the available models straight off that connection.

## What it took to get a run to finish

Nine things broke, and none of them said what was wrong. This is the list
so the next person recognises the symptom rather than rediscovering the
cause. The first six and the ninth are fixed in the demos role, the
seventh in the openrag role; the eighth is the one to read if you are
rebuilding this cluster.

**1. TLS to NooBaa's *Service*.** Nothing in the cluster trusts the
service-CA certificate that `s3.openshift-storage.svc` presents. The KFP
*launcher* — the thing that moves artifacts between steps — fails with
`Error reading CA bundle file, open /etc/ssl/certs/ca-certificates.crt: no
such file or directory`, then `failed to download input artifact`.
Separately the pipeline components read the data bucket with boto3, which
rejects the same certificate with `CERTIFICATE_VERIFY_FAILED`.
`apiServer.cABundle` fixes neither — that bundle reaches the API server,
not the launcher.

The data bucket is plain `http` on port 80 for that reason, which is
pod-to-pod traffic to a NooBaa Service. The *artifact* store is not: it
uses NooBaa's Route over https, for the reason in finding 9. Read that
one before concluding this cluster cannot do TLS to NooBaa — it can,
against the Route, whose certificate comes from the ingress router rather
than the service CA.

**2. A NetworkPolicy that hangs instead of refusing.** The Llama-stack
server carries an operator-managed policy admitting only its own namespace,
`redhat-ods-applications` and ingress. From the demos namespace
`client.models.list()` — a 9ms call when allowed — surfaces minutes later
as `ogx_client.APITimeoutError: Request timed out`. It reads like a slow
model, not a blocked packet. The fix is a *companion* policy in the model
namespace: the ogx-operator owns its own and reverts edits, but
NetworkPolicies are additive.

**3. An empty API key is worse than a wrong one.** The client sends
whatever it is given as a bearer token, and an empty value dies inside
httpx before any request leaves the pod: `LocalProtocolError: Illegal
header value b'Bearer '`, surfacing as `APIConnectionError`. The key is the
placeholder `not-required` — the endpoint answers unauthenticated
in-cluster, but the field must be non-empty.

**4. The connection carries two spellings of the same two values.**
`connections.yaml` shipped only `LLAMA_STACK_CLIENT_*` — the names upstream
documents — and the Create-run form accepted it. The pipeline never reads
those keys: every component that talks to the stack mounts
`OGX_CLIENT_BASE_URL` and `OGX_CLIENT_API_KEY` by those exact names
(`secretAsEnv`, `optional: false`). Both pairs are set so the form and the
run agree.

**5. The connection annotation also has two spellings.** The AutoRAG UI
filters its *Open GenAI Stack connection* dropdown on
`opendatahub.io/connection-type`, while the rest of the dashboard uses
`...-type-ref`. Setting only `-ref` makes the dropdown report *"There are
no secrets in the selected namespace"* against a working connection.

**6. Embedding models that cannot be fetched.** Two of the three defaults
are `sentence-transformers/...` paths rather than LiteLLM-served ones, and
the pod cannot download them. Use `endpoint-1/bge-small-en-v1.5`, which is
served through LiteLLM.

**7. The embedding batch limit.** This is the one that outlasted all the
others. AutoRAG indexes the whole corpus in a single embeddings call — 289
chunks for this one — and Hugging Face TEI caps a request at **32 inputs by
default**. The 413 is relayed by LiteLLM and arrives three layers up as:

```
PreSelectorError: Foundation models pre-selection has failed. None of the
given models has been successfully evaluated.
IndexingError: Unable to embed and upload documents to vector store
```

Nothing in that mentions a batch size; it reads like a broken vector store.
The openrag role now passes `--max-client-batch-size` (see
`openrag_embedding_max_batch`, 2048). It is a validation limit only — TEI
still splits the work internally — and it costs nothing: 289 inputs embed
in 1.7s, 1024 in 6.1s.

**8. An embedding model registered at the wrong width.** The last one, and
the worst-behaved. Llama-stack does not ask a model how wide its vectors
are — it reads `embedding_dimension` from the model's registered metadata,
and where that key is absent it assumes **128**. bge-small is 384. Nothing
complains: the model lists, `/v1/embeddings` answers, search-space
preparation passes. The first *write* to a real vector store then fails,
in the optimisation step, with

```
BadRequestError: 400 - 'Embedding at index 0 has dimension 384, expected 128'
```

The litellm role now measures each embedding model — one request to
`/v1/embeddings`, count the floats that come back — and publishes the
result. Measured rather than tabulated: a lookup keyed by model name is
wrong the first time someone fronts a model that is not in it, and wrong
in exactly this silent way. A model whose dimension cannot be measured is
left unpublished rather than published at a guess.

**9. A results page that cannot reach the results.** The run succeeds, every
step is green, and the leaderboard reports:

```
Unable to fetch RAG patterns
```

with `Patterns evaluated —` and `Winning pattern —`. Nothing is logged,
anywhere, because the failing request never reaches the cluster.

The DSPA has **one** object-storage endpoint and it is used for two jobs
that pull in opposite directions: the pipeline pods read and write
artifacts through it, and the API server builds the **presigned download
URLs it hands your browser** from it. Point it at `s3.openshift-storage.svc`
and the second job is impossible — no laptop resolves an in-cluster Service
name. The leaderboard is sitting in the bucket the whole time.

The role now reads NooBaa's own `s3` Route and uses that, over https. The
Route is terminated by the ingress router and presents the cluster's
ingress certificate, which is publicly trusted, so unlike the Service it
needs no CA bundle on either side — the launcher moves artifacts over it
quite happily. Verified by fetching a presigned URL from a laptop with
full certificate verification: 200, 7294 bytes, real content, where the
Service endpoint gave a bare connection failure.

Two things to know. The endpoint is recorded per artifact **when the
artifact is created**, so fixing it does not repair old runs — their
download URLs keep the old host forever, and only runs started afterwards
display. And if the cluster has no `s3` Route the role falls back to the
Service and says so, because runs still work; only the results page
suffers.

### Where that setting actually lives on this cluster

Worth knowing, because the obvious place is not the effective one.

The Gen AI BFF normally generates the playground's `llama-stack-config`
from the `gen-ai-aa-*` ConfigMaps. It unmarshals them into typed Go
structs and silently discards any key it has no field for — which is why
the Milvus provider's `token` cannot be set that way, and why the
playground used to crash-loop. The fix was
`OGXServer.spec.overrideConfig`, pointing the server at a
`llama-stack-config` ConfigMap the BFF does not own.

The consequence: on this cluster `gen-ai-aa-*` is no longer read.
Everything the playground actually uses — provider credentials, registered
models, embedding dimensions — comes from that one override ConfigMap. It
is durable (`ConfigGenerated: False / "Declarative config generation is
not active"` in the OGXServer status is the operator confirming it is
standing back), but it is **hand-maintained and not in Ansible**. A rebuilt
cluster will not have it, and the AutoRAG demo will fail on model
enumeration until it is recreated.

Two other things to recognise in that status:

- `DeploymentReady: False — duplicate entries for key [name="VLLM_API_TOKEN_2"]`.
  The operator overwrites `spec.workload.overrides.env`, forcing every
  `VLLM_API_TOKEN_n` to the literal `fake`; an appended second entry to
  beat it makes the typed patch invalid, so the Deployment stops
  reconciling. It is why the override config carries literal credentials
  instead of `${env.VLLM_API_TOKEN_n}` references.
- `Failed` as the overall phase is therefore expected here, and the
  playground serves fine in that state.

## Reading a run

Defaults on this cluster select **6 foundation and 3 embedding models**,
`Better quality` preset, 8 RAG patterns, `overall_score`.

`qwen3-4b` is in the generation set and is the local T4 at roughly 30 tok/s
while the other five are MaaS endpoints — if a run drags, drop it under
*Model configuration → Edit*.

For the embedding set, keep `endpoint-1/bge-small-en-v1.5` and drop the two
`sentence-transformers/...` entries, per finding 6 above.

### What a finished run actually said

The first run to complete on sandbox3508, 2026-10-11. Six patterns, 42
minutes wall clock, `overall_score`:

| Pattern | Score | Search | Chunks | Generation model |
|---|---|---|---|---|
| 4 | **0.8357** | hybrid | 10 | qwen36-35b-a3b |
| 6 | 0.8256 | hybrid | 3 | granite-3-2-8b-instruct |
| 1 | 0.8219 | hybrid | 3 | granite-3-2-8b-instruct |
| 5 | 0.8184 | hybrid | 3 | qwen36-35b-a3b |
| 3 | 0.8011 | hybrid | 3 | granite-3-2-8b-instruct |
| 2 | 0.5499 | **vector** | 3 | granite-3-2-8b-instruct |

**That bottom row is the demo.** Pattern 2 is the only pure-vector
configuration in the set and the only one below 0.80 — not by a little, by
28 points. Everything else differs in chunking, reranking and model, and
lands within 3.5 points of the winner. On this corpus the choice that
mattered was not which model or how big the chunks; it was *vector search
alone versus vector plus keyword*.

That pairs well with [rag-eval](../rag-eval/), which found OpenSearch kNN
and Milvus retrieving near-identically. Taken together: which vector store
you pick barely moves the needle, and whether you use one *on its own*
moves it enormously. Neither is obvious, and nobody believes either from
an argument.

Expect 429s from the MaaS endpoints during the generation phase. The
client backs off and retries — the run above hit them repeatedly and still
finished. It is rate limiting on a shared endpoint, not a fault.

## Cleaning up

```bash
oc -n rag-eval delete dspa dspa
oc -n rag-eval delete obc pipeline-artifacts autorag-data
oc -n rag-eval delete secret llama-stack-conn
oc -n qwen3-4b delete networkpolicy allow-demos-to-llama-stack
```

Deleting the OBCs takes the buckets, their credentials and the S3
connection with them.
