# ocp-provisioning

OpenTofu configurations for provisioning OpenShift Container Platform (OCP) infrastructure on AWS.

## Project Structure

```
ocp-provisioning/
├── bastion/       # RHEL 10 bastion host for OCP management
├── cluster/       # OpenShift cluster provisioning (coming soon)
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

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.3.0
- An AWS account with credentials configured
- An SSH key pair at `~/.ssh/id_rsa` (or specify a different path)

## Usage

1. **Export AWS credentials**

   ```sh
   export AWS_ACCESS_KEY_ID="<your-access-key>"
   export AWS_SECRET_ACCESS_KEY="<your-secret-key>"
   ```

2. **Clone the repository**

   ```sh
   git clone https://github.com/explicitworkload/ocp-provisioning.git
   cd ocp-provisioning/bastion
   ```

3. **Configure variables**

   Create a `terraform.tfvars` file:

   ```hcl
   aws_region          = "ap-southeast-1"
   instance_type       = "t3.xlarge"
   ssh_public_key_path = "~/.ssh/id_rsa.pub"
   ```

4. **Deploy**

   ```sh
   tofu init
   tofu plan
   tofu apply
   ```

5. **Connect**

   ```sh
   ssh ec2-user@<bastion_public_ip>
   ```

   The bastion public IP and SSH command are printed as OpenTofu outputs after `apply`.

## Variables

| Name | Description | Default |
|------|-------------|---------|
| `aws_region` | AWS region for deployment | `ap-southeast-1` |
| `instance_type` | EC2 instance size | `t3.xlarge` |
| `ssh_public_key_path` | Path to your SSH public key | `~/.ssh/id_rsa.pub` |
| `allowed_ssh_cidr` | CIDR block allowed to SSH into the bastion | `0.0.0.0/0` |

## Outputs

| Name | Description |
|------|-------------|
| `bastion_public_ip` | Public IP address of the bastion |
| `ssh_connection_command` | Ready-to-use SSH command |

## Cleanup

```sh
cd bastion
tofu destroy
```

## License

[MIT](LICENSE)
