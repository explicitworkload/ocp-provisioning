variable "aws_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS region for deployment"
}

variable "instance_type" {
  type        = string
  default     = "t3.xlarge" # 4 vCPU / 16GB RAM recommended for mirroring / heavy CLI tasks
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