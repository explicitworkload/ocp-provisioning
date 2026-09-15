# ocp-provisioning

Automated end-to-end provisioning of an OpenShift Container Platform (OCP) cluster on AWS using OpenTofu. This project stands up a fully configured cluster — from bastion host to GPU-enabled worker nodes — with day-2 operators, ODF-backed object storage, a private Quay registry, and OpenShift AI pre-configured for model serving, all in a single `tofu apply`. It is designed for repeatable demo and sandbox environments that can be torn down and rebuilt in under an hour.

## Project Structure

```
ocp-provisioning/
├── bastion/                # RHEL 10 bastion host for OCP management
├── cluster/                # OpenShift cluster provisioning (IPI)
│   ├── manifests/          # GPU worker MachineSet templates
│   ├── operators/          # Operator namespaces, groups, subscriptions, and configs
│   ├── main.tf             # Cluster install orchestration (9 phases)
│   ├── variables.tf        # Cluster configuration variables
│   ├── outputs.tf          # Cluster endpoints and credentials
│   └── install-config.yaml.tpl
└── README.md
```

## Prerequisites

### AWS

- An AWS account with credentials configured (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`)
- An existing Route53 hosted zone for your base domain (e.g. `sandbox199.opentlc.com`)
- Sufficient EC2 quotas: 3x `m5.xlarge`, 6x `m5.4xlarge`, 1x `g4dn.4xlarge`, plus 1x `t3.xlarge` for the bastion
- Elastic IP quota of at least 10 in your target region

### Red Hat Pull Secret

A pull secret is required to install OpenShift. Download it from the [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) and save it as `cluster/pull-secret.json`.

> **Do not commit `pull-secret.json` to the repository.** It is listed in `.gitignore`.

### SSH Key Pair

An SSH key pair is needed in two places:

1. **Local machine** (`~/.ssh/id_rsa.pub`) — used by the bastion OpenTofu config to allow SSH access to the bastion host
2. **Bastion host** (`~/.ssh/id_rsa.pub`) — used by the cluster OpenTofu config and injected into all cluster nodes for SSH access

After the bastion is provisioned, copy your key to it:

```sh
scp ~/.ssh/id_rsa.pub ec2-user@<bastion_public_ip>:~/.ssh/id_rsa.pub
scp ~/.ssh/id_rsa ec2-user@<bastion_public_ip>:~/.ssh/id_rsa
```

### Tools

The following are required on your local machine:

- [OpenTofu](https://opentofu.org/docs/intro/install/) (>= 1.3.0)
- AWS CLI (for credential management)

All other tools (oc, kubectl, openshift-install, etc.) are installed automatically on the bastion host via Homebrew.

## Bastion Host

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

### Deploy Bastion

```sh
export AWS_ACCESS_KEY_ID="<your-access-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret-key>"

cd bastion
tofu init && tofu apply
ssh ec2-user@<bastion_public_ip>
```

## OpenShift Cluster

Provisions an OpenShift cluster via IPI (`openshift-install`) orchestrated by OpenTofu. Run this **from the bastion host** inside a tmux session.

### Cluster Topology

| Role | Instance Type | Count | Notes |
|------|---------------|-------|-------|
| Master | `m5.xlarge` (4 vCPU, 16 GB) | 3 | Control plane |
| CPU Worker | `m5.4xlarge` (16 vCPU, 64 GB) | 6 | + 300 GB additional gp3 SSD each |
| GPU Worker | `g4dn.4xlarge` (16 vCPU, 64 GB, 1x T4) | 1 | NVIDIA GPU workloads |
| GPU Worker | `p4de.24xlarge` (96 vCPU, 1.1 TB, 8x A100 80GB) | 0 | Scale-up ready (set replicas to 1) |

### Provisioning Phases

The cluster install is orchestrated in 9 phases:

| Phase | Resource | Description |
|-------|----------|-------------|
| 1 | `generate_manifests` | Generate install manifests from `install-config.yaml` |
| 2 | `patch_worker_machinesets` | Add 300 GB gp3 SSD to each worker MachineSet |
| 3 | `cluster_install` | Run `openshift-install create cluster` |
| 4 | `gpu_machineset` | Apply GPU worker MachineSets and patch security groups |
| 5 | `operators` | Install all operator subscriptions |
| 6 | `odf_storage` | Configure Local Storage and ODF StorageCluster |
| 7 | `openshift_ai` | Configure OpenShift AI (DataScienceCluster + Dashboard) |
| 8 | `console_plugins` | Enable console plugins |
| 9 | `quay_registry` | Deploy Quay Registry (waits for NooBaa) |

### Operators

| Operator | Channel | Purpose |
|----------|---------|---------|
| OpenShift Data Foundation | stable-4.22 | Storage (Ceph + NooBaa object storage via Local Storage) |
| Local Storage Operator | stable | Discovers and manages worker node SSDs for ODF |
| Node Feature Discovery | stable | Hardware feature detection for GPU scheduling |
| NVIDIA GPU Operator | v26.7 | GPU drivers, device plugin, and monitoring |
| OpenShift AI (RHOAI) | stable-3.5 | KServe, OGX, AI Gateway, TrustyAI |
| Red Hat Lightspeed | stable | AI assistant for OpenShift console |
| Cluster Observability Operator | stable | Monitoring and observability |
| OpenShift Pipelines | latest | Tekton-based CI/CD pipelines |
| Red Hat Quay | stable-3.18 | Private container registry (backed by NooBaa) |
| OpenShift GitOps | latest | Argo CD-based GitOps |
| Web Terminal | fast | In-console terminal |

**Console plugins enabled:** odf-console, pipelines-console-plugin, gitops-plugin, kuadrant-console-plugin

### Networking

| Network | CIDR | Purpose |
|---------|------|---------|
| Machine Network | `10.0.0.0/16` | VPC subnet for node IPs |
| Cluster Network | `10.128.0.0/14` (hostPrefix `/23`) | Pod IPs (510 pods max per node) |
| Service Network | `172.30.0.0/16` | ClusterIP service IPs |

CNI: OVNKubernetes

### Deploy Cluster

From the bastion host:

```sh
export AWS_ACCESS_KEY_ID="<your-access-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret-key>"

tmux new -s ocp

cd ~/ocp-provisioning/cluster

# Save your Red Hat pull secret (download from https://console.redhat.com/openshift/install/pull-secret)
vi pull-secret.json

tofu init
tofu apply
```

A random cluster name (e.g. `jgoh742`) is generated automatically. The cluster will be available at `jgoh742.sandbox199.opentlc.com`.

### Cluster Outputs

After deployment, OpenTofu will output:

- **Cluster name** — the generated name (e.g. `jgoh742`)
- **Console URL** — `https://console-openshift-console.apps.<name>.sandbox199.opentlc.com`
- **Kubeconfig path** — `cluster/install-dir/auth/kubeconfig`
- **Kubeadmin password** — `cluster/install-dir/auth/kubeadmin-password`

### Destroy Cluster

```sh
cd ~/ocp-provisioning/cluster
tofu destroy
rm -rf install-dir
```

## License

[MIT](LICENSE)
