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

Deploys ODF with Ceph storage on all non-GPU worker nodes using dynamically provisioned gp3 EBS volumes (1Ti per OSD). Automatically excludes GPU nodes via label filtering. Device set count scales with the number of eligible workers. Configures NooBaa with PV-pool backing store for object storage. Provides `ocs-storagecluster-ceph-rbd`, `ocs-storagecluster-cephfs`, and NooBaa storage classes.

### OpenShift AI 3.5

Configures DSCInitialization, DataScienceCluster (v2 API), and OdhDashboardConfig with:
- KServe (Standard deployment mode) with external endpoints and bearer token auth
- OGX (GenAI Studio playground), AI Gateway, and MCP Lifecycle Operator
- Model registry, hardware profiles with GPU accelerator
- Auto-discovers cluster apps domain for GenAI Studio `clusterDomains` config
- OpenShift MCP Server deployment with cluster-wide read-only access

### Model Serving

Deploys Qwen3-4B (`quay.io/redhat-ai-services/modelcar-catalog:qwen3-4b`) using the pre-installed RHOAI vLLM CUDA ServingRuntime on a GPU node. The InferenceService is configured with:
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
- **Qwen3-4B** — proxied from the cluster's InferenceService
- **Azure GPT-4** — via Azure AD client credentials with reusable credential stored in LiteLLM DB
- **Admin user** — `proxy_admin` role created via API for UI access
- **AI Asset Endpoint** — registers Azure model in GenAI Studio via `gen-ai-aa-custom-model-endpoints` ConfigMap with virtual key
- Exposed via OpenShift Route with edge TLS
- Credentials (master key, UI password) auto-generated and persisted in cluster secrets

### Bookinfo Demo

Deploys the Istio Bookinfo sample application with sidecar injection, all four microservices (productpage, details, ratings, reviews v1/v2/v3), Gateway, VirtualService, and a Route at `bookinfo.<apps-domain>`.

### Operations Dashboard

A self-service operations dashboard built with Flask and deployed via OpenShift BuildConfig from this repo's `dashboard/` directory. Exposed at `dashboard.<apps-domain>`. Password-protected via cluster Secret. Features:
- **Sidebar navigation** — Dashboard, Platform Admin, AI, Health, Access, Help, and Logout
- **Login page** — session-based authentication with password stored in Kubernetes Secret
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

Needs `helm` on the control host — the only role that does. Enable with
`deploy_openrag=true`.

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

## Prerequisites

- An existing OpenShift 4.22+ cluster on AWS
- `oc` CLI authenticated (`oc login`)
- Python 3.x

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

## Configuration

All variables are in `group_vars/all.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `ocp_context` | (empty) | Kube context from `oc config current-context` |
| `gpu_machinesets` | `[{instance_type: g4dn.4xlarge, replicas: 1}]` | List of GPU MachineSets to create (instance type + replica count) |
| `gpu_availability_zone` | `us-east-2a` | AZ for GPU MachineSets |
| `gpu_volume_size` | `120` | Root volume size (GB) for GPU workers |
| `model_namespace` | `qwen3-4b` | Namespace for the model deployment |
| `model_name` | `qwen3-4b` | InferenceService name |
| `model_image` | `quay.io/redhat-ai-services/modelcar-catalog:qwen3-4b` | Modelcar OCI image |
| `model_max_model_len` | `32768` | vLLM max model context length (must fit GPU VRAM) |
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
    ├── verify/                 # Asserts the deployment; collects every failure
    └── summary/                # Prints URLs, credentials and total run time
```

## Idempotency

The playbook is fully idempotent. Running it multiple times against the same cluster is safe and will only apply changes where needed.
