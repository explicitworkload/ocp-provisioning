# ocp-provisioning

OpenTofu configurations for provisioning OpenShift Container Platform (OCP) infrastructure on AWS.

## Project Structure

```
ocp-provisioning/
├── bastion/                # RHEL 10 bastion host for OCP management
├── cluster/                # OpenShift cluster provisioning (IPI)
│   ├── manifests/          # GPU worker MachineSet template
│   ├── operators/          # Operator namespaces, groups, and subscriptions
│   ├── main.tf             # Cluster install orchestration
│   ├── variables.tf        # Cluster configuration variables
│   ├── outputs.tf          # Cluster endpoints and credentials
│   └── install-config.yaml.tpl
└── README.md
```

## Prerequisites

### AWS

- An AWS account with credentials configured (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`)
- An existing Route53 hosted zone for your base domain (e.g. `sandbox199.opentlc.com`)
- Sufficient EC2 quotas: 3x `m5.xlarge`, 3x `m5.2xlarge`, 1x `g5.4xlarge`, plus 1x `t3.xlarge` for the bastion
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

**Cluster topology:**

| Role | Instance Type | Count | Notes |
|------|---------------|-------|-------|
| Master | `m5.xlarge` (4 vCPU, 16 GB) | 3 | Control plane |
| CPU Worker | `m5.2xlarge` (8 vCPU, 32 GB) | 3 | + 300 GB additional SSD each |
| GPU Worker | `g5.4xlarge` (16 vCPU, 64 GB, 1x A10G) | 1 | NVIDIA GPU workloads |

**Operators installed:**

- OpenShift Data Foundation (balanced profile, adopts 300 GB worker SSDs via Local Storage Operator)
- Node Feature Discovery
- OpenShift AI 3.5 (KServe, OGX, AI Gateway, TrustyAI enabled)
- NVIDIA GPU Operator
- Lightspeed Operator
- Cluster Observability Operator
- OpenShift Pipelines
- Red Hat Quay
- Web Terminal
- OpenShift GitOps

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
