variable "aws_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS region for deployment"
}

# 8 vCPU / 16 GB. Compute-optimised rather than burstable: a t3 earns CPU
# credits and spends them under load, so a long oc-mirror or openshift-install
# run - exactly what this host exists for - can exhaust the balance and then
# crawl at the baseline until it recovers. Same memory as the t3.xlarge it
# replaces, twice the vCPU, no throttling.
variable "instance_type" {
  type        = string
  default     = "c6i.2xlarge"
  description = "EC2 instance size for RHEL 10 Bastion"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Path to your local Mac SSH public key"
}

variable "allowed_ssh_cidr" {
  type        = string
  default     = "0.0.0.0/0" # Replace with your public IP (e.g., 203.0.113.5/32) for better security
  description = "IP block allowed to SSH into the Bastion"
}