# ocp-provisioning

Automated provisioning and day-2 configuration of OpenShift Container Platform (OCP) clusters on AWS. This project supports two workflows:

1. **Terraform (full cluster)** — stands up a cluster from scratch via `openshift-install`, including bastion host, GPU workers, and the base operators
2. **Ansible (day-2 only)** — configures an existing cluster with operators, Service Mesh, ODF, Quay, GPU workers, model serving, and demo tooling

Both are designed for repeatable demo and sandbox environments.

## Project Structure

```
ocp-provisioning/
├── terraform/              # Full cluster provisioning from scratch
│   ├── bastion/            # RHEL 10 bastion host for OCP management
│   └── cluster/            # OpenShift cluster provisioning (IPI)
│       ├── manifests/      # GPU worker MachineSet templates
│       ├── operators/      # Operator namespaces, groups, subscriptions, and configs
│       ├── main.tf         # Cluster install orchestration (11 phases)
│       ├── variables.tf    # Cluster configuration variables
│       ├── outputs.tf      # Cluster endpoints and credentials
│       └── install-config.yaml.tpl
├── ansible/                # Day-2 Ansible playbook for existing clusters
│   ├── site.yml            # Main playbook (17 roles)
│   ├── group_vars/all.yml  # Configuration variables
│   ├── roles/              # operators, service_mesh, network_observability, gpu_worker, odf, quay, etc.
│   └── README.md           # Ansible-specific docs
├── dashboard/              # Operations dashboard (Flask app, built via BuildConfig)
├── devfile.yaml            # Dev Spaces workspace definition (installs Claude CLI)
├── .vscode/extensions.json # Extensions recommended to Dev Spaces workspaces
└── README.md
```

---

## Option A: Ansible Playbook (Day-2 on an Existing Cluster)

Use this when you already have an OpenShift 4.22+ cluster on AWS and want to install operators, add a GPU worker node, and deploy a model.

**What it does:**

- Installs 14 operators (NFD, RHOAI 3.5, NVIDIA GPU, Service Mesh 3, Kiali, Network Observability, ODF, Observability, Pipelines, Quay, Web Terminal, GitOps, Connectivity Link, Dev Spaces)
- Deploys Service Mesh 3 (Istio + Kiali) with Thanos Querier integration and Network Observability (eBPF FlowCollector)
- Deploys ODF with gp3 EBS-backed Ceph storage and NooBaa object storage
- Deploys Quay Registry backed by ODF managed storage (or S3 fallback)
- Creates GPU MachineSets (g4dn.4xlarge, g6e.4xlarge, p4d.24xlarge, p4de.24xlarge) with dedicated MachineConfigPool by auto-discovering cluster config
- Configures OpenShift AI with KServe, OGX (GenAI Studio playground), AI Gateway, and MCP server
- Deploys Qwen3-4B on vLLM via a modelcar OCI image with external endpoint, bearer token auth, and GenAI Studio playground
- Deploys LiteLLM proxy with PostgreSQL backend, proxying Qwen3-4B and Azure GPT-4 via reusable credentials
- Deploys Bookinfo demo app with Istio sidecar injection and Gatus health monitoring (probes in-cluster service DNS, with the Gatus UI embedded in the dashboard)
- Deploys OpenShift Dev Spaces with a `CheCluster` and registers this repo as a one-click workspace sample; workspaces install the Claude Code CLI and the Kubernetes extension on start
- Deploys Operations Dashboard with sidebar navigation, login authentication, Service Mesh controls (traffic shifting, fault injection, circuit breaker, timeouts/retries), Platform Admin (MachineSet scaling, cluster shutdown), node resiliency testing (stop/start the backing EC2 instance, or destroy a Machine and let its MachineSet rebuild it), AI Assistant (chat with MCP server tool use), embedded health monitor, floating task log with toast notifications, and sustained traffic generator
- Optionally publishes public DNS via upstream ExternalDNS against Cloudflare, giving the dashboard and Dev Spaces routes on a real domain (off by default)

### Quick Start

```bash
# Set up virtual environment and install dependencies
cd ansible
python3 -m venv .venv
source .venv/bin/activate
pip install ansible kubernetes

# Edit group_vars/all.yml and set ocp_context to your cluster context
# Find it with: oc config current-context

# Run
./run.sh
```

**Optional extras**, both off by default and never requiring secrets in the repo:

```bash
# Publish public DNS for the dashboard and Dev Spaces via Cloudflare.
# Runs last in the playbook, after the Routes it publishes exist.
read -rs CF_TOKEN
ansible-playbook site.yml --tags external-dns \
  -e deploy_external_dns=true -e cloudflare_api_token="$CF_TOKEN"

# Enable node Stop/Start in the dashboard. Needs ec2:DescribeInstances,
# ec2:StopInstances and ec2:StartInstances. Destroy & Rebuild works without it.
read -rs AWS_KEY; read -rs AWS_SECRET
ansible-playbook site.yml --tags dashboard \
  -e dashboard_aws_access_key_id="$AWS_KEY" \
  -e dashboard_aws_secret_access_key="$AWS_SECRET"
```

See [ansible/README.md](ansible/README.md) for full variable reference, tags, Cloudflare and TLS notes, node resiliency testing, and Quay S3 configuration.

---

## Option B: Terraform (Full Cluster from Scratch)

Use this to provision a complete cluster from nothing, including the bastion host and the base operators. Storage (ODF) and Quay are left to the Ansible day-2 playbook, so they are configured in one place.

### Prerequisites

#### AWS

- An AWS account with credentials configured (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`)
- An existing Route53 hosted zone for your base domain (e.g. `sandbox199.opentlc.com`)
- Sufficient EC2 quotas: 3x `m5.xlarge`, 6x `m5.4xlarge`, 1x `g4dn.4xlarge`, plus 1x `t3.xlarge` for the bastion
- Elastic IP quota of at least 10 in your target region

#### Red Hat Pull Secret

A pull secret is required to install OpenShift. Download it from the [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) and save it as `terraform/cluster/pull-secret.json`.

> **Do not commit `pull-secret.json` to the repository.** It is listed in `.gitignore`.

#### SSH Key Pair

An SSH key pair is needed in two places:

1. **Local machine** (`~/.ssh/id_rsa.pub`) — used by the bastion OpenTofu config to allow SSH access to the bastion host
2. **Bastion host** (`~/.ssh/id_rsa.pub`) — used by the cluster OpenTofu config and injected into all cluster nodes for SSH access

After the bastion is provisioned, copy your key to it:

```sh
scp ~/.ssh/id_rsa.pub ec2-user@<bastion_public_ip>:~/.ssh/id_rsa.pub
scp ~/.ssh/id_rsa ec2-user@<bastion_public_ip>:~/.ssh/id_rsa
```

#### Tools

The following are required on your local machine:

- [OpenTofu](https://opentofu.org/docs/intro/install/) (>= 1.3.0)
- AWS CLI (for credential management)

All other tools (oc, kubectl, openshift-install, etc.) are installed automatically on the bastion host via Homebrew.

### Bastion Host

Provisions a RHEL 10 bastion host on AWS pre-loaded with OpenShift tooling.

**What it creates:**

- EC2 instance running RHEL 10 (`t3.xlarge` by default) with a 100 GB gp3 root volume
- Security group allowing inbound SSH and all outbound traffic
- SSH key pair imported from your local machine

**Pre-installed tools:**

- OpenShift CLI (`oc`), `oc-mirror`, and `openshift-install`
- AWS CLI, `kubectx`, `kubectl`, and OpenTofu (via Homebrew)
- tmux with [TPM](https://github.com/tmux-plugins/tpm) and powerline
- Git, wget, curl, jq, and other common utilities

#### Deploy Bastion

```sh
export AWS_ACCESS_KEY_ID="<your-access-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret-key>"

cd terraform/bastion
tofu init && tofu apply
ssh ec2-user@<bastion_public_ip>
```

### OpenShift Cluster

Provisions an OpenShift cluster via IPI (`openshift-install`) orchestrated by OpenTofu. Run this **from the bastion host** inside a tmux session.

#### Cluster Topology

| Role | Instance Type | Count | Notes |
|------|---------------|-------|-------|
| Master | `m5.xlarge` (4 vCPU, 16 GB) | 3 | Control plane |
| CPU Worker | `m5.4xlarge` (16 vCPU, 64 GB) | 6 | + 300 GB additional gp3 SSD each |
| GPU Worker | `g4dn.4xlarge` (16 vCPU, 64 GB, 1x T4) | 1 | NVIDIA GPU workloads |
| GPU Worker | `p4de.24xlarge` (96 vCPU, 1.1 TB, 8x A100 80GB) | 0 | Scale-up ready (set replicas to 1) |

#### Provisioning Phases

| Phase | Resource | Description |
|-------|----------|-------------|
| 1 | `generate_manifests` | Generate install manifests from `install-config.yaml` |
| 2 | `patch_worker_machinesets` | Add 300 GB gp3 SSD to each worker MachineSet |
| 3 | `cluster_install` | Run `openshift-install create cluster` |
| 4 | `gpu_machineset` | Apply GPU worker MachineSets and patch security groups |
| 5 | `operators` | Install all operator subscriptions |
| 6 | `nfd_instance` | Create NodeFeatureDiscovery instance for hardware detection |
| 7 | `gpu_clusterpolicy` | Create NVIDIA ClusterPolicy for container AI workloads |
| 8 | `openshift_ai` | Configure OpenShift AI (DataScienceCluster + Dashboard) |
| 9 | `console_plugins` | Enable console plugins |

#### Operators

| Operator | Channel | Purpose |
|----------|---------|---------|
| Node Feature Discovery | stable | Hardware feature detection for GPU scheduling |
| NVIDIA GPU Operator | v26.7 | GPU drivers, device plugin, and monitoring |
| OpenShift AI (RHOAI) | stable-3.5 | KServe, OGX, AI Gateway, TrustyAI |
| Red Hat Lightspeed | stable | AI assistant for OpenShift console |
| Cluster Observability Operator | stable | Monitoring and observability |
| OpenShift Pipelines | latest | Tekton-based CI/CD pipelines |
| Red Hat Connectivity Link | stable | Kuadrant API gateway policies |
| OpenShift GitOps | latest | Argo CD-based GitOps |
| Web Terminal | fast | In-console terminal |

**Console plugins enabled:** pipelines-console-plugin, gitops-plugin, kuadrant-console-plugin

#### Networking

| Network | CIDR | Purpose |
|---------|------|---------|
| Machine Network | `10.0.0.0/16` | VPC subnet for node IPs |
| Cluster Network | `10.128.0.0/14` (hostPrefix `/23`) | Pod IPs (510 pods max per node) |
| Service Network | `172.30.0.0/16` | ClusterIP service IPs |

CNI: OVNKubernetes

#### Deploy Cluster

From the bastion host:

```sh
export AWS_ACCESS_KEY_ID="<your-access-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret-key>"

tmux new -s ocp

cd ~/ocp-provisioning/terraform/cluster

# Save your Red Hat pull secret (download from https://console.redhat.com/openshift/install/pull-secret)
vi pull-secret.json

tofu init
tofu apply
```

A random cluster name (e.g. `jgoh742`) is generated automatically. The cluster will be available at `jgoh742.sandbox199.opentlc.com`.

#### Cluster Outputs

After deployment, OpenTofu will output:

- **Cluster name** — the generated name (e.g. `jgoh742`)
- **Console URL** — `https://console-openshift-console.apps.<name>.sandbox199.opentlc.com`
- **Kubeconfig path** — `terraform/cluster/install-dir/auth/kubeconfig`
- **Kubeadmin password** — `terraform/cluster/install-dir/auth/kubeadmin-password`

#### Destroy Cluster

```sh
cd ~/ocp-provisioning/terraform/cluster
tofu destroy
rm -rf install-dir
```

## License

[MIT](LICENSE)
