# Retrieval A/B, tracked in MLflow

Measures which retriever finds the right chunk in the corpus OpenRAG has
already ingested — OpenSearch BM25, OpenSearch kNN, or Milvus kNN — and logs
every combination to RHOAI's MLflow.

The comparison is like-for-like on purpose. Milvus is loaded with the *same*
vectors OpenSearch already holds (`chunk_embedding_rhoai_bge_small_en_v1_5`,
384-dim, from bge-small via LiteLLM) and the Milvus metric is derived from the
`space_type` on the OpenSearch mapping. So the only variable is the engine.

## Running it

```bash
oc -n rag-eval delete job rag-eval --ignore-not-found
oc apply -f demos/rag-eval/job.yaml
oc -n rag-eval logs -f job/rag-eval
```

About 100 seconds: ~40s installing dependencies, ~37s generating questions,
~15s for the sweep itself.

The Job expects a namespace prepared like this:

```bash
oc create ns rag-eval
oc create sa rag-eval -n rag-eval
oc create rolebinding rag-eval-admin --clusterrole=admin \
  --serviceaccount=rag-eval:rag-eval -n rag-eval
oc create secret generic rag-eval-creds -n rag-eval \
  --from-literal=OPENSEARCH_PASSWORD="$(oc get secret opensearch-admin -n opensearch -o jsonpath='{.data.password}' | base64 -d)" \
  --from-literal=LITELLM_KEY="$(oc get secret litellm-proxy-credentials -n litellm -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)"
oc create configmap rag-eval-script -n rag-eval --from-file=rag_eval.py=demos/rag-eval/rag_eval.py
```

Re-create the ConfigMap after editing the script; the Job reads it at start.

## Talking to RHOAI's MLflow

Not stock MLflow, and the differences are not guessable. The server runs with
`--app-name=kubernetes-auth --enable-workspaces --workspace-store-uri=kubernetes://`,
which means:

- **Auth is a Kubernetes bearer token.** Any valid token; authorization is
  then checked against the namespace.
- **Every request needs a workspace**, via the `X-MLFLOW-WORKSPACE` header.
  Without it the API returns `400 INVALID_PARAMETER_VALUE: Workspace context
  is required for this request.`
- **A workspace is a namespace, 1:1.** `rag-eval` is a workspace because the
  Job runs in a namespace of that name. Not every namespace qualifies —
  `redhat-ods-applications` is not one.
- **The workspaces API is `3.0`** while everything else is `2.0`:
  `GET /mlflow/api/3.0/mlflow/workspaces` lists them.
- **There is no Route.** The service is `mlflow.redhat-ods-applications.svc:8443`,
  serving under a `/mlflow` prefix with a service-serving certificate. The UI
  is published separately, through the RHOAI gateway.

For the Python client that reduces to four environment variables, which is
what `job.yaml` sets:

```
MLFLOW_TRACKING_URI=https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow
MLFLOW_TRACKING_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
MLFLOW_WORKSPACE=rag-eval
MLFLOW_TRACKING_INSECURE_TLS=true
```

From a laptop, swap the URI for `oc port-forward -n redhat-ods-applications
svc/mlflow 18443:8443` and use `oc whoami -t` as the token.

### Viewing the results

```
https://<data-science-gateway-host>/mlflow/#/experiments/<id>?workspace=rag-eval
```

Keep `?workspace=` on the URL. Open the bare path and you land in whichever
workspace the UI defaults to, the experiment list is empty, and it looks like
nothing ever ran.

## Two things to say out loud about the numbers

**BM25 scores a better MRR than either kNN retriever.** The questions are
generated from each chunk's own wording, so the ground truth structurally
flatters lexical matching. The honest fix is a human-labelled question set;
until then, read the BM25 column with that bias in mind.

**The Milvus latency win is partly protocol.** Milvus is gRPC; OpenSearch here
is HTTPS with authentication across three replicas. The gap is real but it is
not purely an indexing difference.

## Why thinking is disabled

`chat()` sends `chat_template_kwargs: {"enable_thinking": false}`, and that is
required rather than a preference. The serving runtime runs
`--reasoning-parser=qwen3`, which puts the model's chain of thought in
`reasoning_content` and the answer in `content`. Left on, a 4B model spends the
whole token budget thinking: the first run produced `finish_reason: "length"`
and `content: None` for all 40 questions and reported "0 usable" with no error.
Off, the same prompt answers in 7 tokens.
