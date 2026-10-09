# OCP Day-2 Ansible Playbook

Ansible playbook for configuring an existing OpenShift 4.22+ cluster with operators, a GPU worker node, Service Mesh, ODF storage, Quay registry, and model serving via OpenShift AI 3.5.

This playbook does **not** create the cluster from scratch. It assumes you already have an OpenShift cluster running on AWS and are authenticated via `oc login`.

## What gets installed

### Operators (13 subscriptions)

| Operator | Namespace | Channel |
|----------|-----------|---------|
| Node Feature Discovery | openshift-nfd | stable |
| Red Hat OpenShift AI | redhat-ods-operator | stable-3.5 |
| NVIDIA GPU Operator | nvidia-gpu-operator | v26.7 |
| Red Hat Connectivity Link | openshift-operators | stable |
| Cluster Observability | openshift-observability-operator | stable |
| OpenShift Pipelines | openshift-operators | latest |
| Red Hat Quay | quay-enterprise | stable-3.18 |
| Web Terminal | openshift-operators | fast |
| OpenShift GitOps | openshift-gitops-operator | latest |
| Network Observability | openshift-operators | stable |
| Service Mesh 3 (Sail) | openshift-operators | stable |
| Kiali (OSSM) | openshift-operators | stable |
| Zero Trust Workload Identity Manager | zero-trust-workload-identity-manager | stable-v1 |

Three more operators are subscribed by the roles that need them rather than
up front, because each is only installed when its feature is enabled: ODF
(`odf`), Dev Spaces (`devspaces`) and Loki (`network_observability`, when
`netobserv_enable_loki` is true).

### Service Mesh 3

Deploys the full Istio service mesh stack:
- IstioCNI and Istio control plane in `istio-system`
- Kiali with OpenShift auth, integrated with Thanos Querier for Prometheus metrics
- OSSMConsole for OpenShift console integration
- PodMonitor and ServiceMonitor for Istio metrics scraping via user workload monitoring

### Network Observability

Deploys FlowCollector with an eBPF agent for network traffic visibility directly in the OpenShift console.

Flow records are stored in a LokiStack backed by NooBaa object storage, so the
console's **Traffic flows** table — the per-connection records, which is
usually the point of asking — is populated rather than empty. The bucket is
claimed with an ObjectBucketClaim, which means ODF has to be up first; the
role checks for the `ObjectBucketClaim` CRD by name and fails with that
explanation rather than dying thirty tasks later on a missing API. Backing it
with NooBaa rather than a cloud bucket also keeps it working on a
disconnected cluster.

Set `netobserv_enable_loki=false` to keep the FlowCollector without flow
records (topology still renders, from Prometheus metrics).

### GPU Worker

Creates GPU MachineSets by auto-discovering the cluster's AMI, security groups, and region from existing worker MachineSets. Supports multiple instance types with configurable replica counts (use `replicas: 0` for scale-up-ready MachineSets). Creates a dedicated `gpu` MachineConfigPool so GPU nodes get their own update rollout cycle, separate from regular workers.

### ODF (OpenShift Data Foundation)

Deploys ODF with Ceph storage on all non-GPU worker nodes using dynamically provisioned gp3 EBS volumes (512Gi per OSD by default, `odf_storage_size`). Automatically excludes GPU nodes via label filtering. Device set count scales with the number of eligible workers. NooBaa is left alone to bootstrap and choose its own default backing store —
the role creates the StorageCluster and then only watches. Earlier revisions
patched `manualDefaultBackingStore`, created a sized pv-pool BackingStore and
repointed the default BucketClass while NooBaa was still coming up; that is
gone, along with a workaround for what turned out not to be a bug. ODF 4.22
is CNPG-native, so `noobaa-db-pg-0` never starts at all and its absence is
expected. Provides `ocs-storagecluster-ceph-rbd`, `ocs-storagecluster-cephfs`, and NooBaa storage classes.

### OpenShift AI 3.5

Configures DSCInitialization, DataScienceCluster (v2 API), and OdhDashboardConfig with:
- KServe (Standard deployment mode) with external endpoints and bearer token auth
- OGX (GenAI Studio playground), AI Gateway, and MCP Lifecycle Operator
- Model registry, hardware profiles with GPU accelerator
- Auto-discovers cluster apps domain for GenAI Studio `clusterDomains` config
- OpenShift MCP Server deployment with cluster-wide read-only access

### Model Serving

Deploys one model, chosen with `model_preset`, using the pre-installed RHOAI
vLLM CUDA ServingRuntime on a GPU node. One name sets the image, the GPU
count, the context length and the resource limits together:

| Preset | Source | GPUs | Weights | Context | Native max | Instance needed |
|--------|--------|------|---------|---------|------------|-----------------|
| `qwen3-4b` | modelcar, bf16 | 1 | 8 GB | 32k | 40k | any GPU node |
| `qwen3-8b` | modelcar, bf16 | 1 | 16 GB | 40k | 40k | 48 GB card |
| `qwen3-14b` | modelcar, bf16 | 1 | 29 GB | 40k | 40k | 48 GB card |
| `qwen3.8-27b` | modelcar, bf16 | 4 | 56 GB | 256k | 256k | `g6e.12xlarge` |
| `qwen3.8-27b-fp8` | Hugging Face | 1 | 31 GB | 64k | 256k | 48 GB card + `hf_token` |

Context is sized per model against two separate ceilings, and set to what the
pair will actually carry rather than to a round number.

The first is `max_position_embeddings` from the model's own `config.json` —
the "native max" column. Going past it needs rope scaling, and vLLM refuses
to start without it. The dense Qwen3 models stop at 40960; `qwen3.8-27b` is
natively 262144, so it needs no rescaling to serve a quarter-million tokens.

The second is KV cache: vLLM will not start unless the cache holds one whole
`max_model_len` sequence, so context trades directly against VRAM at
`2 x full_attention_layers x kv_heads x head_dim x bytes` per token. Note
**full-attention** layers. `qwen3.8-27b` is a hybrid — only 16 of its 64
layers are attention at all (`full_attention_interval: 4`), and the other 48
are gated DeltaNet, whose state is a fixed ~148 MB per sequence however long
that sequence runs. So it costs 64 KB per token, not the 256 KB that counting
all 64 layers suggests, and a full 256k sequence is 16 GiB rather than 64.
Correcting that is what let these numbers go up. The flip side is that the
per-sequence state, not the cache, is what bounds concurrency: at vLLM's
default of 256 sequences it alone would want 37 GiB, so both 27B presets pin
`max_num_seqs` (128 on four cards, 16 on one).

Only `qwen3-4b` sits below its native length, and the card is why: the default
`g4dn.4xlarge` has a 16 GB T4, and 7.5 GiB of weights plus 4.5 GiB of KV at
32k is all of it. On a 48 GB card it will take 40960.

The run prints the whole budget before it creates anything — weights, KV at
the chosen context, and per-sequence state — against each instance you asked
for, so an over-ambitious context shows up as `DOES NOT FIT` rather than as a
pod that never becomes ready.

To push a dense model past 40960, Qwen document YaRN to 131072:

```bash
./run.sh -e model_max_model_len=131072 \
  -e '{"model_rope_override": {"rope_scaling": {"rope_type": "yarn",
       "factor": 4.0, "original_max_position_embeddings": 32768}}}'
```

Static YaRN applies at every length, so it costs some accuracy on short
prompts too — Qwen suggest enabling it only when long inputs are genuinely
expected. Neither 27B preset needs it.

**Tool-call and reasoning parsers are per-model, and a mismatch is silent.**
The dense Qwen3 models emit Hermes JSON inside `<tool_call>`; Qwen3.8 emits
Qwen's XML form, `<tool_call><function=name>`. Parse the second with `hermes`
and vLLM finds no tool call, returns `finish_reason: "stop"`, and leaves the
unparsed markup in `content` — so a caller that was waiting on a tool result
simply hangs, with nothing in any log to say why. This was seen in the Gen AI
playground against the MCP server: the model called `pods_top`, and the
answer never came. `qwen3_xml` fixes it. `--reasoning-parser=qwen3` is set
alongside so `</think>` stops leaking into `content`.

The modelcar catalog has no FP8 Qwen, so that preset pulls from Hugging Face
through KServe's `hf://` storage initializer and needs `hf_token`. Selecting
it without one fails before anything is created rather than after a 28 GB
download returns 401.

`--tensor-parallel-size` follows the preset's GPU count, so the four-GPU
preset actually shards rather than trying to load 55 GB onto one card.

The 27B presets are named `qwen38-27b-selfhosted` and
`qwen38-27b-fp8-selfhosted`, with the readable form in
`openshift.io/display-name`. A dot is not valid in a DNS-1123 object name,
and plain `qwen38-27b` would collide with the model the MaaS endpoint serves
through LiteLLM — the AI asset endpoint drops a remote model when an
InferenceService claims the same name or display name, so the remote one
would have vanished from the picker.

The InferenceService is configured with:
- External endpoint via `networking.kserve.io/visibility: exposed`
- Bearer token auth via `security.opendatahub.io/enable-auth`
- GenAI Studio integration via `opendatahub.io/genai-asset` label
- `Recreate` deployment strategy to avoid GPU contention during rollouts
- RBAC (ClusterRole + RoleBinding) for ServiceAccount-based token access
- Tool/function calling via `--enable-auto-tool-choice` and `--tool-call-parser=hermes`

### GenAI Studio Playground (OGX)

Prepares the pgvector resources for the GenAI Studio playground provisioner:
- **pgvector PostgreSQL** — vector database for RAG (PVC-backed, with `vector` extension installed, init script, NetworkPolicy, and `gen-ai.opendatahub.io/pgvector` labels for provisioner compatibility)
- The OGXServer and Llama Stack config are created by the GenAI Studio provisioner when you click "Configure" in the playground UI

### LiteLLM Proxy

Deploys a LiteLLM proxy with PostgreSQL backend for unified OpenAI-compatible API access:
- **PostgreSQL** — persistent storage for API keys, teams, budgets, and usage logs
- **LiteLLM proxy** — routes requests to multiple LLM backends via a single endpoint
- **The cluster's own model** — whichever `model_preset` deployed, proxied from its InferenceService
- **Azure GPT-4** — via Azure AD client credentials with reusable credential stored in LiteLLM DB
- **Admin user** — `proxy_admin` role created via API for UI access
- **AI Asset Endpoint** — registers Azure model in GenAI Studio via `gen-ai-aa-custom-model-endpoints` ConfigMap with virtual key
- Exposed via OpenShift Route with edge TLS
- Credentials (master key, UI password) auto-generated and persisted in cluster secrets

### Bookinfo Demo

Deploys the Istio Bookinfo sample application with sidecar injection, all four microservices (productpage, details, ratings, reviews v1/v2/v3), Gateway, VirtualService, and a Route at `bookinfo.<apps-domain>`.

### Operations Dashboard

A self-service operations dashboard built with Flask and deployed via OpenShift BuildConfig from this repo's `dashboard/` directory. Exposed at `dashboard.<apps-domain>`.

**Authentication — `dashboard_auth_mode`, default `oauth-proxy`.** You sign in
with your OpenShift identity; the app's own password login is turned off. The
integration is one line of behaviour: the app's `login_required` decorator
passes straight through when `DASHBOARD_PASSWORD` is empty, so the role blanks
it and the proxy becomes the only login rather than a second one stacked in
front. No shared password then exists, and the summary stops printing one.

Set `dashboard_auth_mode=password` for the old behaviour — the app's own login
page with a generated password. That is also the rollback if SSO misbehaves:

```bash
./run.sh --tags dashboard -e dashboard_auth_mode=password
```

In `oauth-proxy` mode the Service publishes **only** the proxy's HTTPS port, so
neither Route can reach the app directly; the certificate comes from
`service-ca` and the Routes reencrypt. Access is gated on a SubjectAccessReview
for **`patch` on MachineSets** (`dashboard_oauth_sar`) rather than a softer
"can you read this Service" check — this dashboard scales MachineSets, deletes
Machines, shifts mesh traffic and can shut the cluster down, and the proxy
should not hand anyone authority they do not already hold.

Three things that are easy to get wrong and are handled in the role: **both**
Routes need their own `oauth-redirectreference` annotation (miss the
custom-domain one and its login silently never completes); the annotation goes
on the **`default`** ServiceAccount, because the role already binds all four of
the dashboard's ClusterRoles to it; and the session secret is generated once
and read back, since regenerating it would invalidate every live session.

Caveats worth knowing. An unauthenticated request returns **403 with the
sign-in page in the body** — that is oauth-proxy's normal behaviour, not a
fault. The app still listens on 8080 inside the pod, so it is reachable by pod
IP from within the cluster; a NetworkPolicy is the next step if that matters.
And `/logout` hits the proxy's `/oauth/sign_out`, which ends the session with
*this dashboard* but not with the cluster — the OpenShift SSO cookie survives,
so signing back in usually will not re-prompt. A full logout would need a POST
to the OAuth server's `/logout`, which answers 405 to a redirect's GET.

Features:
- **Sidebar navigation** — Dashboard, Platform Admin, AI, Health, Access, Help, and Logout
- **Traffic generator** — burst mode (fixed request count) or sustained mode (continuous for up to 60 minutes) with configurable concurrency (1–50 threads)
- **Traffic shifting** — route traffic across Reviews v1/v2/v3 by percentage for canary deployment demos
- **Fault injection** — inject delays or HTTP errors into the ratings service to test resilience
- **Circuit breaker** — limit connections to the reviews service to demonstrate cascading failure prevention
- **Request timeout & retries** — set timeouts and auto-retries on the reviews service
- **Platform Admin** — view and scale worker/GPU MachineSets, node status, cluster shutdown (separate page)
- **Resiliency testing** — select one or two worker nodes and **Stop** them (powers the EC2 instance off so the node goes NotReady), **Start** them again, or **Destroy & Rebuild** (deletes the Machine so its MachineSet provisions a replacement). Control-plane nodes are refused
- **AI Assistant** — summarization and chat with models served via LiteLLM, MCP server discovery and tool use for live cluster interaction (separate page)
- **Floating task log** — pinned bottom-right panel with live progress, toast notifications for all actions
- **Access page** — every URL and generated credential for the cluster, the same set the `summary` role prints. Passwords are masked, with show/copy per row. It reads a single Secret, `ops-dashboard-summary`, published by the `summary` role; a `resourceNames`-scoped Role grants the dashboard `get` on that one object, so it gains no ability to read secrets generally. Re-run `./run.sh --tags summary` after rotating anything
- **Help page** — built-in guide with demo scenarios for each feature
- Links to Gatus health monitor

### External DNS (Cloudflare) — optional, off by default

Watches OpenShift Routes and publishes matching records to a Cloudflare zone (`kubernetes.day`), so any Route whose host falls in that zone gets a DNS record without manual Cloudflare edits.

This role is **disabled by default** and runs **last** in the playbook, after every Route it might publish already exists. Enable it explicitly:

```bash
ansible-playbook site.yml --tags external-dns \
  -e deploy_external_dns=true \
  -e cloudflare_api_token="<token>"
```

> **Why not the Red Hat External DNS Operator?** That operator only supports AWS, GCP, Azure, BlueCat and Infoblox — its `ExternalDNS` CRD has no Cloudflare provider. This role therefore deploys upstream ExternalDNS directly, which does support Cloudflare.

Records are owned via a TXT registry keyed to the cluster's infrastructure name, so ExternalDNS only ever modifies records it created. The API token is **never stored in the repo** — Ansible writes it to the `cloudflare-credentials` Secret in the `external-dns` namespace (see [Cloudflare API token](#cloudflare-api-token)).

### Dev Spaces

Installs the Red Hat OpenShift Dev Spaces operator and a `CheCluster` instance in `openshift-devspaces`. Opening this repository as a workspace picks up the root [`devfile.yaml`](../devfile.yaml), which on each workspace start:

- installs the **Claude Code CLI** (`@anthropic-ai/claude-code`) into `~/.npm-global`
- installs Ansible and the Kubernetes Python client

The **Kubernetes extension** (`ms-kubernetes-tools.vscode-kubernetes-tools`), plus the YAML and Ansible extensions, are recommended via `.vscode/extensions.json` and installed by the workspace editor.

When `deploy_external_dns` is true, a second Route `devspaces28.kubernetes.day` is created alongside the apps-domain URL.

> **Sign-in uses the apps-domain URL.** Dev Spaces ties its OAuth redirects to `status.cheURL`, so logging in via the custom hostname redirects back to `devspaces.<apps-domain>`. To make the custom name the canonical one instead, set `spec.networking.hostname` on the `CheCluster` — that moves the URL rather than adding a second one.

### Zero Trust Workload Identity Manager (SPIFFE/SPIRE)

Red Hat's SPIRE distribution, giving workloads short-lived cryptographic identities (SVIDs) instead of long-lived secrets. The role creates four cluster-scoped CRs, all named `cluster`, in `zero-trust-workload-identity-manager`:

| CR | What it runs |
|----|--------------|
| `ZeroTrustWorkloadIdentityManager` | holds `trustDomain` / `clusterName`; owns the three below |
| `SpireServer` | `spire-server` StatefulSet — the CA that issues SVIDs |
| `SpireAgent` | DaemonSet attesting workloads on every node |
| `SpiffeCSIDriver` | DaemonSet delivering SVIDs via an ephemeral CSI volume |
| `SpireOIDCDiscoveryProvider` | publishes JWKS at `oidc-discovery.<apps-domain>` |

Defaults live in `roles/ztwim/defaults/main.yml`. Set `deploy_ztwim: false` to skip it.

The trust domain defaults to the cluster's apps domain, so SPIFFE IDs look like `spiffe://apps.ocp.<id>.sandbox<n>.opentlc.com/ns/<namespace>/sa/<serviceaccount>`.

> **`trustDomain` is immutable.** So are `clusterName`, `bundleConfigMap` and the `persistence` block. The webhook rejects edits, so changing any of them means deleting the `ZeroTrustWorkloadIdentityManager` CR — which cascades to every operand via owner references — and re-running. Decide before the first run.

Verify the OIDC endpoint:

```bash
curl -s https://oidc-discovery.$(oc get ingress.config/cluster -o jsonpath='{.spec.domain}')/.well-known/openid-configuration | jq .issuer
```

That `issuer` must match `ztwim_jwt_issuer` exactly, or relying parties reject the JWT-SVIDs.

To hand a workload an identity, create a `ClusterSPIFFEID` selecting its ServiceAccount, then mount the CSI volume:

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: my-app
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  workloadSelectorTemplates:
    - "k8s:ns:my-namespace"
```

> **sqlite3 is the default datastore**, on a 2Gi PVC from the cluster default StorageClass. That matches the operator's own default and is fine for a demo, but production should set `ztwim_datastore_type: postgres` with an external database.

### Gatus

Deploys [Gatus](https://github.com/TwiN/gatus) health monitoring, exposed at `gatus.<apps-domain>`. Monitors Bookinfo, Kiali, the Operations Dashboard, the OpenShift Console and Dev Spaces. When `deploy_external_dns` is true it also monitors the public `*.kubernetes.day` hostnames.

> **Gatus has no Kubernetes service discovery.** Every endpoint is declared explicitly in the `gatus_core_endpoints` list in `roles/gatus/tasks/main.yml` — a new Route is *not* picked up automatically. Add it to that list and re-run `--tags gatus`.

### Quay Registry

Deploys Red Hat Quay backed by ODF managed object storage (NooBaa). Falls back to S3 config when ODF is unavailable.

### OpenRAG — optional, off by default

Deploys [OpenRAG](https://github.com/langflow-ai/openrag) and its dependencies:
a three-node OpenSearch cluster, docling-serve for document conversion,
text-embeddings-inference serving `BAAI/bge-small-en-v1.5` on CPU, Langflow,
Postgres, and the OpenRAG chart itself.

Needs `helm` and `git` on the control host — `helm` is shared with the
Milvus role, `git` is needed by this one alone, to check the chart out.
Both are asserted in `site.yml`'s `pre_tasks` before the run touches the
cluster. Enable with `deploy_openrag=true`.

Chat and embeddings both go through LiteLLM rather than straight to a model,
so OpenRAG, the Gen AI playground and the Ops Dashboard all serve the same
model list. The role reads the LiteLLM key from the cluster rather than
inheriting it, which is what makes `--tags openrag` runnable on its own.

Two deployment-specific details worth knowing, because neither is obvious
from the upstream project:

- **Langflow gets its own Route.** The "Edit in Langflow" buttons open the
  flow editor in a new tab, and upstream resolves that link through
  `LANGFLOW_PUBLIC_URL` before falling back to `same-host:7860` — a port
  nothing serves behind the OpenShift router. The chart's ingress block
  renders only its frontend and backend hosts, so the Route is created
  directly and the variable set to match. `openrag_expose_langflow=false`
  keeps Langflow in-cluster.
- **`openrag-backend` is made resolvable from the OpenSearch namespace.**
  OpenRAG authenticates per-user reads to OpenSearch with a JWT, and
  OpenSearch validates it by fetching OpenRAG's JWKS from
  `http://openrag-backend:8000/...` — a docker-compose hostname baked into
  the OpenSearch image. A bare service name resolves only within its own
  namespace, so without an ExternalName service pointing at the real one,
  the Knowledge page returns 401 and OpenRAG reports it as "OpenSearch
  rejected the credential", which is misleading: ingestion works, because
  that path uses basic auth.

### Milvus — optional, off by default

A vector database with [Attu](https://github.com/zilliztech/attu) as its UI,
published to RHOAI's **Gen AI studio → AI asset endpoints → Vector stores**.
Enable with `deploy_milvus=true`; needs the `helm` CLI, like OpenRAG.

```bash
./run.sh --tags milvus -e deploy_milvus=true
```

Milvus is **in no operator catalog** on OpenShift — not certified, not
community, not Red Hat — so the operator comes from the upstream zilliztech
Helm chart (pinned, `milvus_operator_version`) and carries no Red Hat support
path. That is the trade for having it.

It runs in `standalone` mode: one Milvus pod plus one etcd. Cluster mode would
be rootcoord/proxy/querynode/datanode/indexnode as separate deployments, which
on a sandbox demonstrates an architecture rather than a database. Milvus 2.6
embeds its own WAL (woodpecker), so neither mode needs Pulsar or Kafka.

Object storage is the cluster's **NooBaa**, claimed with an
`ObjectBucketClaim`, rather than the MinIO the chart would otherwise deploy —
one less MinIO and one less SCC argument. The OBC writes
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` and Milvus reads
`accesskey`/`secretkey`, so the role copies them across. The S3 endpoint is
NooBaa's in-cluster HTTP port; see `milvus_s3_endpoint` for the TLS note.

**Three SCC bindings, each for a different reason.** None of these images were
built for OpenShift's restricted SCC:

| Workload | Needs | Why |
|---|---|---|
| operator | `nonroot-v2` | image asks for UID 65532, outside the namespace range |
| etcd | `nonroot-v2` | runs as UID 1001 with `fsGroup` 1001 |
| Milvus | `anyuid` | image declares no `USER`; `/milvus` is root-owned |

Only Milvus genuinely needs root, so it gets its own ServiceAccount and
everything else in the namespace stays non-root. The proper fix for that one
is a derived image doing `chgrp -R 0 /milvus && chmod -R g=u /milvus`, which
would run unmodified under `restricted-v2` — at the cost of a BuildConfig to
maintain across Milvus upgrades.

**Attu sits behind OpenShift's `oauth-proxy`** (`milvus_attu_auth`, on by
default). Attu has no authentication of its own and talks to Milvus with the
credentials Milvus has — none — so an open route would let anyone who found it
read and drop collections.

The proxy runs as a sidecar, the Service publishes only its HTTPS port so the
Route cannot reach Attu directly, the certificate comes from `service-ca` and
the Route reencrypts. The image is resolved from the cluster's own
`oauth-proxy` imagestream so it tracks the OpenShift version. Access is gated
on a SubjectAccessReview — as shipped, "can you `get` the `attu` Service in
its namespace", which admins pass and a random authenticated user does not;
widen or narrow it with `milvus_attu_oauth_sar`. Note that an unauthenticated
request returns **403 with the sign-in page in the body**, which is
oauth-proxy's normal behaviour rather than a misconfiguration.

Attu still listens on 3000 inside the pod, so it is reachable by pod IP from
within the cluster; a NetworkPolicy is the next step if that matters.

### Where Milvus keeps its data

Split, deliberately:

| Data | Where | ODF? |
|---|---|---|
| Segments (the bulk) | NooBaa bucket via `ObjectBucketClaim` | yes |
| etcd metadata | PVC, cluster default storage class | no — `gp3-csi`, AWS EBS |
| Milvus scratch | `emptyDir` | n/a, ephemeral |

The Milvus pod mounts no PVC at all. Only etcd has one, and its contents are
not incidental: collection schemas and segment indexes live there, so losing
it loses the database logically even though every segment is still in the
bucket. Set `milvus_etcd_storage_class: ocs-storagecluster-ceph-rbd` to put it
on ODF as well — but a storage class cannot be changed on an existing PVC, so
switching on a live cluster means deleting `data-milvus-etcd-0` and with it
every collection definition.

The vector store is registered under `gen-ai-aa-vector-stores`, which is one
of exactly three ConfigMap names the Gen AI BFF has compiled in. Note the
three do **not** share a schema: the MCP one is keyed by server name with a
JSON body, while this and the model endpoints are llama-stack shaped under a
single `config.yaml`. `vector_store_name` is what the tab displays —
`metadata.display_name` is read for models but not here, and without it the
row renders nameless. This registers the store with the dashboard; it is not
merged into the llama-stack distribution's own config, which still lists only
the built-in pgvector.

`milvus_embedding_model` and `milvus_embedding_dimension` must agree with each
other and with whatever writes the vectors — `bge-small-en-v1.5` is 384-wide.

### Why the OpenRAG chart is pinned

`openrag_git_version` is a release tag (`v0.8.0`), not `main`, and that matters
more than it looks.

The chart carries OpenRAG's starter flows, and **each flow embeds a snapshot of
its components' Python source**. The image carries the components that actually
execute. `LANGFLOW_ALLOW_CUSTOM_COMPONENTS=false`, so the server always runs its
own copy and ignores the flow's — which is the right security posture, but it
means the two must agree.

Track `main` and they drift, because `langflowai/openrag-langflow:latest` is
rebuilt far less often than the repo moves. Observed on sandbox3270: the chart's
flow was 8 days ahead of the image, so every run logged

> Custom components are disabled on this server … This run uses the server's
> component code instead of the code saved in the flow

and the newer code in the flow — a CJK normalisation fix for PDF text — never
ran at all.

**Do not fix this by clicking Update in the flow editor.** It rewrites the
node's type from `ext:openrag:<Class>@extra` to a bare `<Class>`, Langflow then
cannot resolve it to a bundled component, and the flow stops building entirely
with `custom components are not allowed`. A cosmetic warning becomes a dead
flow. Recovery is restoring the flow's previous `data` JSON.

At `v0.8.0` the chart's four starter flows embed code byte-identical to the
image's `custom_components/openrag/opensearch_multimodal.py`, so there is no
warning and no skew. When bumping, check the published image first and move the
tag and the image together — `opensearch_image_tag` is already on the same
release.

### Seeing what OpenRAG chunked

OpenRAG's Knowledge page lists documents. To see the *chunks* they were split
into, use OpenSearch Dashboards, which deploys with OpenRAG by default. Log
in as `admin` with the OpenSearch password the summary prints, then
**Discover** on the `documents` index.

To deploy it on a cluster that does not have it yet:

```bash
./run.sh --tags opensearch-dashboards -e deploy_openrag=true
```

Set `openrag_deploy_dashboards=false` to leave it out; it costs a Deployment
and 2 GB of limits. Note that the alternative to this UI is not "no UI" —
it is exposing OpenSearch's REST API on `:9200` through a Route and curling
the indices by hand, which publishes the admin API to do a job this already
does. Dashboards is the supported way in.

Each OpenSearch document *is* a chunk: `text`, `page`, `chunk_size`,
`chunk_overlap`, `filename`, the ACL fields OpenRAG enforces per user, and
the embedding vector. Note the mapping carries one vector field *per
embedding model* — `chunk_embedding` at 1536 dims alongside
`chunk_embedding_rhoai_bge_small_en_v1_5` at 384 — so which field is
populated tells you which model actually did the embedding.

Unlike Attu this needs no proxy in front: OpenSearch runs the security
plugin, so Dashboards serves its own login. Two things that will otherwise
cost an afternoon, both handled in the role: `OPENSEARCH_HOSTS` must be a
JSON **array** or it is silently ignored and Dashboards looks for
`localhost:9200`; and the pod must ask for `runAsUser: 1000` explicitly, or
OpenShift assigns an arbitrary UID that cannot execute the image's
entrypoint and it crash-loops on `Permission denied` with nothing naming SCC
as the cause.

The image tag must track the OpenSearch server's major line — both are
3.8.0 as shipped.

## Prerequisites

- An existing OpenShift 4.22+ cluster on AWS
- `oc` CLI authenticated (`oc login`)
- Python 3.x
- `helm` — only for the `openrag` and `milvus` roles
- `git` — only for the `openrag` role

The last two are asserted up front by `site.yml`, and only when the role
that needs them is enabled.

## Quick start

1. Set up a Python virtual environment and install dependencies:

   ```bash
   cd ansible
   python3 -m venv .venv
   source .venv/bin/activate
   pip install ansible kubernetes
   ```

2. Create your variables file. `group_vars/all.yml` is untracked, so it can
   hold a pull secret, an API key or an endpoint credential without a stray
   `git add -A` publishing it. The repo ships the template:

   ```bash
   cp group_vars/all.yml.sample group_vars/all.yml
   ```

   `run.sh` refuses to start without it, and `site.yml` asserts it as its
   first task, so a fresh clone fails with that instruction rather than
   running every variable off its role default.

   When you add or change a setting, mirror it into the sample — with the
   value left empty or an example. Nothing enforces that, and the sample is
   the only documentation of what these settings do.

3. Log in to your cluster:

   ```bash
   oc login https://api.<cluster>.<domain>:6443 -u admin -p <password>
   ```

4. Set your context in `group_vars/all.yml`:

   ```yaml
   ocp_context: "<your oc context>"
   ```

   Find it with `oc config current-context`. Leave it empty to follow
   whatever the current context is; the run prints the context, API URL,
   infrastructure name and node count before changing anything.

5. Run the playbook:

   ```bash
   ./run.sh
   ```

   With no arguments and a terminal attached, this asks which model to serve
   and which GPU instance to create, defaulting to whatever `all.yml` already
   says — press Enter twice to keep it. Your answers are written back into
   `group_vars/all.yml`, not just applied to that one run, so a later
   `./run.sh --tags litellm` reads the same values rather than wiring
   everything to a model the cluster does not have.

   The prompt is skipped whenever any argument is given, and when stdin is
   not a terminal, so partial runs and unattended runs are unaffected.

   Before anything is created, the run prints the target cluster and whether
   the model fits the instance:

   ```
   model   : Qwen3.8 27B (bf16, modelcar, 4 GPUs)  (55 GB weights, 4 GPUs, 32768 context)
   gpu     : g6e.12xlarge x1 - fits: 192 GB across 4 x L40S, model needs about 66 GB
   ```

   The model and the instance are chosen independently on purpose, so this
   reports rather than refuses: a combination that cannot work is called out
   and allowed to proceed, failing at model load rather than being blocked.

## Configuration

All variables are in `group_vars/all.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `ocp_context` | (empty) | Kube context from `oc config current-context` |
| `gpu_machinesets` | `[{instance_type: g4dn.4xlarge, replicas: 1}]` | List of GPU MachineSets to create (instance type + replica count) |
| `gpu_availability_zone` | `us-east-2a` | AZ for GPU MachineSets |
| `gpu_volume_size` | `120` | Root volume size (GB) for GPU workers |
| `model_preset` | `qwen3-4b` | Which model to serve. Sets image, GPU count, context length and limits together — see Model Serving above |
| `hf_token` | (empty) | Hugging Face token, needed only by `hf://` presets. Supply at run time or in the untracked `all.yml` |
| `model_namespace` | from preset | Namespace for the model deployment. Derived; override only to place it elsewhere |
| `model_name` | from preset | InferenceService name. Derived |
| `model_max_model_len` | from preset | vLLM max context length. Derived, and sized per model against both the native max and the KV cache |
| `model_max_num_seqs` | from preset | `--max-num-seqs`. Derived; `0` leaves it to vLLM, and only the hybrid 27B presets set it |
| `model_tool_call_parser` | from preset | `--tool-call-parser`. `hermes` for the dense Qwen3 models, `qwen3_xml` for the 3.8 pair |
| `model_reasoning_parser` | from preset | `--reasoning-parser`. `qwen3`; empty omits the flag |
| `deploy_milvus` | `false` | Deploy Milvus, Attu, and register the vector store with RHOAI. Needs `helm` |
| `milvus_operator_version` | `1.3.11` | Pinned milvus-operator chart release |
| `milvus_attu_image` | `zilliz/attu:v2.6.5` | Attu image, matched to the Milvus 2.6 line |
| `milvus_embedding_model` | `bge-small-en-v1.5` | Embedding model the vector store is registered against |
| `milvus_embedding_dimension` | `384` | Must match the embedding model's width |
| `milvus_attu_auth` | `true` | Put OpenShift `oauth-proxy` in front of Attu |
| `milvus_attu_oauth_sar` | `get` on the `attu` Service | SubjectAccessReview a user must pass to reach Attu |
| `milvus_attu_oauth_image` | (empty) | Empty resolves from the cluster's `oauth-proxy` imagestream |
| `milvus_etcd_storage_class` | (empty) | Empty uses the cluster default (`gp3-csi`, EBS). `ocs-storagecluster-ceph-rbd` puts etcd on ODF |
| `model_rope_override` | `{}` | Rope scaling passed through as `--hf-overrides`, to go past the native context. Off by default |
| `model_max_output_tokens` | `4096` | Max output tokens per generation request |
| `deploy_quay_registry` | `false` | Deploy QuayRegistry CR (ODF-backed or S3) |
| `console_plugins` | `[pipelines-console-plugin, gitops-plugin, kuadrant-console-plugin, odf-console, odf-client-console]` | Console plugins to enable |
| `litellm_master_key` | (random) | LiteLLM API master key (auto-generated, persisted in cluster secret) |
| `litellm_ui_password` | (random) | LiteLLM UI password (auto-generated, persisted in cluster secret) |
| `litellm_admin_email` | `admin@example.com` | Email for the LiteLLM proxy admin user |
| `dashboard_password` | (generated once) | Dashboard login password. Generated on first run and then reused from the `ops-dashboard-auth` Secret, so it does not rotate on every run. Override at runtime to pin it. |
| `litellm_azure_model_name` | `Mistral-Small-4-119B-2603` | Display name for the Azure GPT-4 model in LiteLLM |
| `external_dns_domain` | `kubernetes.day` | Cloudflare zone that ExternalDNS manages |
| `deploy_external_dns` | `false` | Opt-in switch — ExternalDNS only deploys when true |
| `external_dns_cloudflare_proxied` | `true` | Publish proxied (orange cloud) so Cloudflare terminates TLS |
| `cloudflare_api_token` | (empty) | Cloudflare token; if empty, an existing cluster Secret is used |
| `dashboard_custom_host` | `dashboard28.kubernetes.day` | Extra dashboard Route, created only when ExternalDNS is on |
| `devspaces_custom_host` | `devspaces28.kubernetes.day` | Extra Dev Spaces Route, created only when ExternalDNS is on |
| `dashboard_aws_access_key_id` | (empty) | AWS key for node Stop/Start (pass at runtime) |
| `dashboard_aws_secret_access_key` | (empty) | AWS secret for node Stop/Start (pass at runtime) |

## Dashboard password

The Operations Dashboard password is auto-generated on each Ansible run. To set a specific password at runtime:

```bash
ansible-playbook site.yml -e dashboard_password="your-password-here"
```

To retrieve the current password from the cluster:

```bash
oc get secret ops-dashboard-auth -n dashboard -o jsonpath='{.data.password}' | base64 -d
```

To overwrite the password on a running cluster:

```bash
oc create secret generic ops-dashboard-auth -n dashboard \
  --from-literal=password="new-password" \
  --from-literal=secret-key="$(oc get secret ops-dashboard-auth -n dashboard -o jsonpath='{.data.secret-key}' | base64 -d)" \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/ops-dashboard -n dashboard
```

## Cloudflare API token

ExternalDNS needs a Cloudflare API token with **Zone:Read** and **DNS:Edit** on the managed zone. Create it at Cloudflare → My Profile → API Tokens, then pass it at runtime — **do not commit it**:

```bash
ansible-playbook site.yml --tags external-dns \
  -e deploy_external_dns=true \
  -e cloudflare_api_token="<token>"
```

Ansible stores the token in the `cloudflare-credentials` Secret in the `external-dns` namespace and the deployment reads it from there — it is never written to disk in this repo.

Routes whose host falls inside `external_dns_domain` are published automatically. The dashboard's `dashboard28.kubernetes.day` Route is one of them.

### TLS and the Cloudflare proxy

The cluster's default wildcard certificate only covers `*.apps.<cluster>`, so it does not match `dashboard28.kubernetes.day`. Records are therefore published **proxied** (orange cloud, `external_dns_cloudflare_proxied: true`) — Cloudflare terminates TLS with its own certificate for the zone, so the browser sees a valid cert.

> **Set the zone's SSL/TLS mode to "Full".** Cloudflare still has to reach the origin, and the OpenShift router serves HTTPS with a certificate that does not match this hostname:
>
> | Mode | Result |
> |------|--------|
> | **Full** | ✅ Cloudflare connects over HTTPS without validating the origin cert — correct for this setup |
> | Full (strict) | ❌ Fails — the router's cert does not match `kubernetes.day` |
> | Flexible | ❌ Redirect loop — Cloudflare calls the origin over HTTP and the Route redirects back to HTTPS |

To publish a plain unproxied record instead (grey cloud, direct to the router, with a browser cert warning), set `external_dns_cloudflare_proxied: false`.

## Node resiliency testing

The dashboard's Platform page can simulate node failure:

| Action | Mechanism | Credentials needed |
|--------|-----------|--------------------|
| Destroy & Rebuild | Deletes the `Machine`; its MachineSet provisions a replacement | None — Kubernetes RBAC only |
| Stop / Start | `ec2:StopInstances` / `ec2:StartInstances` on the backing instance | AWS key (below) |

Destroy & Rebuild works out of the box. Stop/Start needs an AWS key with `ec2:DescribeInstances`, `ec2:StopInstances` and `ec2:StartInstances` — the cluster's own machine-api credential is **not** reused, since the standard OpenShift IAM policy grants run/terminate but not stop/start:

```bash
ansible-playbook site.yml --tags dashboard \
  -e dashboard_aws_access_key_id="$AWS_ACCESS_KEY" \
  -e dashboard_aws_secret_access_key="$AWS_SECRET_KEY"
```

Without it, Stop/Start returns a clear "credentials lack ec2:StopInstances" error and the rest of the dashboard is unaffected. Control-plane nodes are always refused, and at most two nodes can be targeted at once.

## Quay without ODF

Without ODF, Quay needs external object storage. To deploy a QuayRegistry, provide S3 credentials:

```yaml
deploy_quay_registry: true
quay_s3_bucket: "my-quay-bucket"
quay_s3_region: "us-east-2"
quay_s3_access_key: "<key>"
quay_s3_secret_key: "<secret>"
```

**Do not commit these values to the repository.** Pass them at runtime instead:

```bash
ansible-playbook site.yml \
  -e deploy_quay_registry=true \
  -e quay_s3_bucket=my-quay-bucket \
  -e quay_s3_region=us-east-2 \
  -e quay_s3_access_key="$AWS_ACCESS_KEY" \
  -e quay_s3_secret_key="$AWS_SECRET_KEY"
```

## Tags

Run specific roles with tags:

```bash
ansible-playbook site.yml --tags operators          # Operators only
ansible-playbook site.yml --tags service-mesh       # Service Mesh 3 + Kiali
ansible-playbook site.yml --tags network-observability  # Network Observability
ansible-playbook site.yml --tags gpu                # GPU MachineSet + NFD + NVIDIA
ansible-playbook site.yml --tags odf                # ODF storage
ansible-playbook site.yml --tags quay               # Quay registry
ansible-playbook site.yml --tags openshift-ai       # OpenShift AI config only
ansible-playbook site.yml --tags model-serving      # Model deployment only
ansible-playbook site.yml --tags console            # Console plugins only
ansible-playbook site.yml --tags litellm            # LiteLLM proxy only
ansible-playbook site.yml --tags bookinfo           # Bookinfo demo app
ansible-playbook site.yml --tags dashboard          # Operations dashboard
ansible-playbook site.yml --tags gatus              # Gatus health monitoring
ansible-playbook site.yml --tags external-dns       # External DNS + Cloudflare
ansible-playbook site.yml --tags devspaces          # OpenShift Dev Spaces
ansible-playbook site.yml --tags ztwim              # SPIFFE/SPIRE workload identity
ansible-playbook site.yml --tags milvus             # Milvus + Attu + vector store
```

## Playbook structure

```
ansible/
├── ansible.cfg
├── requirements.yml
├── run.sh
├── site.yml
├── inventory/hosts.yml
├── group_vars/all.yml.sample   # copy to all.yml (untracked)
└── roles/
    ├── operators/              # Namespaces, OperatorGroups, Subscriptions (13 operators)
    ├── service_mesh/           # Istio, IstioCNI, Kiali, OSSMConsole, monitoring
    ├── network_observability/  # FlowCollector (eBPF) + LokiStack on NooBaa
    ├── gpu_worker/             # GPU MachineSet (auto-discovers cluster config)
    ├── nfd/                    # NodeFeatureDiscovery instance
    ├── nvidia_gpu/             # NVIDIA ClusterPolicy
    ├── odf/                    # ODF StorageCluster with gp3 volumes + NooBaa
    ├── openshift_ai/           # DSCI, DSC, OdhDashboardConfig, MCP server
    ├── quay/                   # QuayRegistry (ODF-backed or S3 fallback)
    ├── console_plugins/        # Console plugin enablement
    ├── model_serving/          # RBAC, pgvector, OGXServer, ServingRuntime, InferenceService
    ├── litellm/                # LiteLLM proxy, PostgreSQL, reusable Azure credentials
    ├── bookinfo_demo/          # Istio Bookinfo sample app with sidecar injection
    ├── dashboard/              # Operations dashboard (BuildConfig from Git)
    ├── external_dns/           # Upstream ExternalDNS -> Cloudflare (opt-in)
    ├── devspaces/              # Dev Spaces operator + CheCluster
    ├── ztwim/                  # SPIFFE/SPIRE workload identity (server, agent, CSI, OIDC)
    ├── gatus/                  # Gatus health monitoring
    ├── openrag/                # OpenRAG, OpenSearch, docling, embeddings (opt-in)
    ├── milvus/                 # Milvus operator, standalone instance, Attu UI (opt-in)
    ├── verify/                 # Asserts the deployment; collects every failure
    └── summary/                # Prints URLs, credentials and total run time
```

## Idempotency

The playbook is fully idempotent. Running it multiple times against the same cluster is safe and will only apply changes where needed.
