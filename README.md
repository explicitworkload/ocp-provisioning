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

- OpenShift Data Foundation (balanced profile)
- Node Feature Discovery
- OpenShift AI
- NVIDIA GPU Operator
- Lightspeed Operator
- Cluster Observability Operator
- OpenShift Pipelines
- Red Hat Quay
- Web Terminal
- OpenShift GitOps

### Prerequisites

- A Route53 hosted zone for your base domain (e.g. `kubernetes.day`)
- A [Red Hat pull secret](https://console.redhat.com/openshift/install/pull-secret) saved as `cluster/pull-secret.json`
- SSH key pair on the bastion (`~/.ssh/id_rsa.pub`)

### Deploy Cluster

From the bastion host:

```sh
tmux new -s ocp

cd cluster

# Save your Red Hat pull secret (download from https://console.redhat.com/openshift/install/pull-secret)
vi pull-secret.json

tofu init
tofu apply
```

A random cluster name (e.g. `aws472`) is generated automatically. The cluster will be available at `aws472.kubernetes.day`.

### Cluster Outputs

After deployment, OpenTofu will output:

- **Cluster name** — the generated name (e.g. `aws472`)
- **Console URL** — `https://console-openshift-console.apps.<name>.kubernetes.day`
- **Kubeconfig path** — `cluster/install-dir/auth/kubeconfig`
- **Kubeadmin password** — `cluster/install-dir/auth/kubeadmin-password`

### Destroy Cluster

```sh
cd cluster
tofu destroy
```

## License

[MIT](LICENSE)
