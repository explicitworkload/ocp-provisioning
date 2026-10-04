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
  default     = "m5.4xlarge"
  description = "EC2 instance type for CPU worker nodes (16 vCPU, 64 GB)"
}

variable "gpu_availability_zone" {
  type        = string
  default     = "ap-southeast-1a"
  description = "Availability zone for the GPU worker nodes"
}

variable "master_replicas" {
  type        = number
  default     = 3
  description = "Number of control plane nodes"
}

variable "worker_replicas" {
  type        = number
  default     = 6
  description = "Number of CPU worker nodes"
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


variable "lightspeed_azure_url" {
  type        = string
  default     = "https://llm-gpt4-lightspeed.cognitiveservices.azure.com/"
  description = "Azure OpenAI endpoint URL for Lightspeed"
}

variable "lightspeed_azure_deployment" {
  type        = string
  default     = "gpt-4"
  description = "Azure OpenAI deployment name for Lightspeed"
}

variable "lightspeed_azure_model" {
  type        = string
  default     = "gpt-4"
  description = "Model name exposed to Lightspeed"
}
