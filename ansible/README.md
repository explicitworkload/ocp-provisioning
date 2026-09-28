# OCP Day-2 Ansible Playbook

Ansible playbook for configuring an existing OpenShift 4.22+ cluster with operators, a GPU worker node, and model serving via OpenShift AI 3.5.

This playbook does **not** create the cluster from scratch. It assumes you already have an OpenShift cluster running on AWS and are authenticated via `oc login`.

## What gets installed

### Operators (9 subscriptions)

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

**Excluded:** OpenShift Data Foundation (ODF) and Local Storage Operator (LSO).

### GPU Worker

Creates an AWS `g4dn.4xlarge` MachineSet (1x NVIDIA T4, 16 GB VRAM) by auto-discovering the cluster's AMI, security groups, and region from existing worker MachineSets.

### OpenShift AI 3.5

Configures DSCInitialization, DataScienceCluster, and OdhDashboardConfig with:
- KServe (Standard deployment mode) with external endpoints and bearer token auth
- OGX (GenAI Studio playground) — patched post-creation since DSC ignores unknown fields
- AI Gateway — patched post-creation (same reason as OGX)
- Model registry, hardware profiles with GPU accelerator
- Auto-discovers cluster apps domain for GenAI Studio `clusterDomains` config

### Model Serving

Deploys Qwen3-4B (`quay.io/redhat-ai-services/modelcar-catalog:qwen3-4b`) using the pre-installed RHOAI vLLM CUDA ServingRuntime on a GPU node. The InferenceService is configured with:
- External endpoint via `networking.kserve.io/visibility: exposed`
- Bearer token auth via `security.opendatahub.io/enable-auth`
- GenAI Studio integration via `opendatahub.io/genai-asset` label
- `Recreate` deployment strategy to avoid GPU contention during rollouts
- RBAC (ClusterRole + RoleBinding) for ServiceAccount-based token access
- Tool/function calling via `--enable-auto-tool-choice` and `--tool-call-parser=hermes`

### GenAI Studio Playground (OGX)

Deploys the full GenAI Studio playground stack:
- **pgvector PostgreSQL** — vector database for RAG (PVC-backed, with `vector` extension installed)
- **OGXServer** — Llama Stack-based playground with vLLM inference, pgvector vector_io, and RAG support
- **Llama Stack ConfigMap** — full provider config (inference, vector_io, responses, files, tool_runtime)

### LiteLLM Proxy

Deploys a LiteLLM proxy with PostgreSQL backend for unified OpenAI-compatible API access:
- **PostgreSQL** — persistent storage for API keys, teams, budgets, and usage logs
- **LiteLLM proxy** — routes requests to multiple LLM backends via a single endpoint
- **Qwen3-4B** — proxied from the cluster's InferenceService
- **Azure GPT-4** — via Azure AD client credentials with reusable credential stored in LiteLLM DB
- Exposed via OpenShift Route with edge TLS

## Prerequisites

- An existing OpenShift 4.22+ cluster on AWS
- `oc` CLI authenticated (`oc login`)
- Python 3.x with `ansible` and `kubernetes` packages
- The `kubernetes.core` Ansible collection

```bash
pip install ansible kubernetes
ansible-galaxy collection install -r requirements.yml
```

## Quick start

1. Log in to your cluster:

   ```bash
   oc login https://api.<cluster>.<domain>:6443 -u admin -p <password>
   ```

2. Set your context in `group_vars/all.yml`:

   ```yaml
   ocp_context: "<your oc context>"
   ```

   Find it with `oc config current-context`.

3. Run the playbook:

   ```bash
   ansible-playbook site.yml
   ```

   Or use the wrapper script (handles terminal IO quirks):

   ```bash
   ./run.sh
   ```

## Configuration

All variables are in `group_vars/all.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `ocp_context` | (empty) | Kube context from `oc config current-context` |
| `gpu_instance_type` | `g4dn.4xlarge` | AWS instance type for GPU worker |
| `gpu_availability_zone` | `us-east-2a` | AZ for GPU MachineSet |
| `gpu_replicas` | `1` | Number of GPU worker nodes |
| `gpu_volume_size` | `120` | Root volume size (GB) for GPU worker |
| `model_namespace` | `qwen3-4b` | Namespace for the model deployment |
| `model_name` | `qwen3-4b` | InferenceService name |
| `model_image` | `quay.io/redhat-ai-services/modelcar-catalog:qwen3-4b` | Modelcar OCI image |
| `model_max_model_len` | `32768` | vLLM max model context length (must fit GPU VRAM) |
| `model_max_output_tokens` | `4096` | Max output tokens per generation request |
| `deploy_quay_registry` | `false` | Deploy QuayRegistry CR (requires S3 config) |
| `console_plugins` | `[pipelines-console-plugin, gitops-plugin, kuadrant-console-plugin]` | Console plugins to enable |
| `litellm_master_key` | (random) | LiteLLM API master key (auto-generated, persisted in cluster secret) |
| `litellm_ui_password` | (random) | LiteLLM UI password (auto-generated, persisted in cluster secret) |
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
ansible-playbook site.yml --tags operators      # Operators only
ansible-playbook site.yml --tags gpu            # GPU MachineSet + NFD + NVIDIA
ansible-playbook site.yml --tags openshift-ai   # OpenShift AI config only
ansible-playbook site.yml --tags model-serving  # Model deployment only
ansible-playbook site.yml --tags quay           # Quay only
ansible-playbook site.yml --tags console        # Console plugins only
ansible-playbook site.yml --tags litellm        # LiteLLM proxy only
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
    ├── operators/          # Namespaces, OperatorGroups, Subscriptions
    ├── gpu_worker/         # GPU MachineSet (auto-discovers cluster config)
    ├── nfd/                # NodeFeatureDiscovery instance
    ├── nvidia_gpu/         # NVIDIA ClusterPolicy
    ├── openshift_ai/       # DSCI, DSC, OdhDashboardConfig
    ├── quay/               # QuayRegistry (conditional)
    ├── console_plugins/    # Console plugin enablement
    ├── model_serving/      # RBAC, pgvector, OGXServer, ServingRuntime, InferenceService
    └── litellm/            # LiteLLM proxy, PostgreSQL, reusable Azure credentials
```

## Idempotency

The playbook is fully idempotent. Running it multiple times against the same cluster is safe and will only apply changes where needed.
