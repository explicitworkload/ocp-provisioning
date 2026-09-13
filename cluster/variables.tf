variable "base_domain" {
  type        = string
  default     = "sandbox199.opentlc.com"
  description = "Base domain for the OpenShift cluster (must have an existing Route53 hosted zone)"
}

variable "aws_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS region for the cluster"
}

variable "master_instance_type" {
  type        = string
  default     = "m5.xlarge"
  description = "EC2 instance type for control plane nodes (4 vCPU, 16 GB)"
}

variable "worker_instance_type" {
  type        = string
  default     = "m5.2xlarge"
  description = "EC2 instance type for CPU worker nodes (8 vCPU, 32 GB)"
}

variable "gpu_instance_type" {
  type        = string
  default     = "g4dn.4xlarge"
  description = "EC2 instance type for GPU worker node (16 vCPU, 64 GB, 1x T4)"
}

variable "gpu_availability_zone" {
  type        = string
  default     = "ap-southeast-1b"
  description = "Availability zone for the GPU worker node"
}

variable "master_replicas" {
  type        = number
  default     = 3
  description = "Number of control plane nodes"
}

variable "worker_replicas" {
  type        = number
  default     = 3
  description = "Number of CPU worker nodes"
}

variable "worker_extra_disk_size" {
  type        = number
  default     = 300
  description = "Size in GB of the additional SSD attached to each CPU worker"
}

variable "pull_secret_path" {
  type        = string
  default     = "pull-secret.json"
  description = "Path to the Red Hat pull secret JSON file"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Path to the SSH public key for cluster node access"
}
