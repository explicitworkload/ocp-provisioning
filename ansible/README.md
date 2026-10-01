# OCP Day-2 Ansible Playbook

Ansible playbook for configuring an existing OpenShift 4.22+ cluster with operators, a GPU worker node, Service Mesh, ODF storage, Quay registry, and model serving via OpenShift AI 3.5.

This playbook does **not** create the cluster from scratch. It assumes you already have an OpenShift cluster running on AWS and are authenticated via `oc login`.

## What gets installed

### Operators (12 subscriptions)

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

### Service Mesh 3

Deploys the full Istio service mesh stack:
- IstioCNI and Istio control plane in `istio-system`
- Kiali with OpenShift auth, integrated with Thanos Querier for Prometheus metrics
- OSSMConsole for OpenShift console integration
- PodMonitor and ServiceMonitor for Istio metrics scraping via user workload monitoring

### Network Observability

Deploys FlowCollector with eBPF agent for network traffic visibility directly in the OpenShift console.

### GPU Worker

Creates GPU MachineSets by auto-discovering the cluster's AMI, security groups, and region from existing worker MachineSets. Supports multiple instance types with configurable replica counts (use `replicas: 0` for scale-up-ready MachineSets).

### ODF (OpenShift Data Foundation)

Deploys ODF with Ceph storage on existing worker nodes using dynamically provisioned gp3 EBS volumes (1Ti per OSD). Configures NooBaa with PV-pool backing store for object storage. Provides `ocs-storagecluster-ceph-rbd`, `ocs-storagecluster-cephfs`, and NooBaa storage classes.

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

A self-service operations dashboard built with Flask and deployed via OpenShift BuildConfig from this repo's `dashboard/` directory. Exposed at `dashboard.<apps-domain>`. Features:
- **Traffic generator** — burst mode (fixed request count) or sustained mode (continuous for up to 60 minutes) with configurable concurrency (1–50 threads)
- **Traffic shifting** — route traffic across Reviews v1/v2/v3 by percentage for canary deployment demos
- **Fault injection** — inject delays or HTTP errors into the ratings service to test resilience
- **Circuit breaker** — limit connections to the reviews service to demonstrate cascading failure prevention
- **Request timeout & retries** — set timeouts and auto-retries on the reviews service
- **Help page** — built-in guide with demo scenarios for each feature
- Links to Gatus health monitor, task log with live progress bars

### Gatus

Deploys [Gatus](https://github.com/TwiN/gatus) health monitoring with endpoints for Bookinfo, Kiali, the Operations Dashboard, and the OpenShift Console. Exposed at `gatus.<apps-domain>`.

### Quay Registry

Deploys Red Hat Quay backed by ODF managed object storage (NooBaa). Falls back to S3 config when ODF is unavailable.

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

2. Log in to your cluster:

   ```bash
   oc login https://api.<cluster>.<domain>:6443 -u admin -p <password>
   ```

3. Set your context in `group_vars/all.yml`:

   ```yaml
   ocp_context: "<your oc context>"
   ```

   Find it with `oc config current-context`.

4. Run the playbook:

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
| `litellm_azure_model_name` | `Mistral-Small-4-119B-2603` | Display name for the Azure GPT-4 model in LiteLLM |

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
```

## Playbook structure

```
ansible/
├── ansible.cfg
├── requirements.yml
├── run.sh
├── site.yml
├── inventory/hosts.yml
├── group_vars/all.yml
└── roles/
    ├── operators/              # Namespaces, OperatorGroups, Subscriptions (12 operators)
    ├── service_mesh/           # Istio, IstioCNI, Kiali, OSSMConsole, monitoring
    ├── network_observability/  # FlowCollector with eBPF agent
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
    └── gatus/                  # Gatus health monitoring
```

## Idempotency

The playbook is fully idempotent. Running it multiple times against the same cluster is safe and will only apply changes where needed.
