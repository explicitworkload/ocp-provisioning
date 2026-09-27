terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Ensure the Default VPC exists (creates one if it was deleted)
resource "aws_default_vpc" "default" {}

# Fetch Default Subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [aws_default_vpc.default.id]
  }
}

# Fetch latest Red Hat Enterprise Linux 9 AMI in ap-southeast-1
data "aws_ami" "rhel10" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat Official Owner ID

  filter {
    name   = "name"
    values = ["RHEL-10.*_HVM-*-x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# SSH Key Pair Import
resource "aws_key_pair" "bastion_key" {
  key_name   = "ocp-bastion-key"
  public_key = file(var.ssh_public_key_path)
}

# Security Group for Bastion Host
resource "aws_security_group" "bastion_sg" {
  name        = "ocp-bastion-sg"
  description = "Allow inbound SSH access to RHEL10 Bastion"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    description = "SSH from allowed IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ocp-bastion-sg"
  }
}

# RHEL 10 Bastion Instance
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.rhel10.id
  instance_type               = var.instance_type
  subnet_id                   = element(data.aws_subnets.default.ids, 0)
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  key_name                    = aws_key_pair.bastion_key.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 100 # 100GB root volume for container images / mirroring
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Provisioning script run on first boot
  user_data = <<-EOF
	#!/bin/bash
	set -euo pipefail
	exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

	echo "Updating system packages..."
	dnf update -y
	dnf install -y git wget curl tar jq gcc libffi-devel python3-devel tmux

	# Determine target user
	TARGET_USER="ec2-user"
	USER_HOME="/home/$TARGET_USER"

	# Install Homebrew for ec2-user
	echo "Installing Homebrew..."
	sudo -u $TARGET_USER NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

	# Set Homebrew PATH for ec2-user's login shell
	echo >> $USER_HOME/.bashrc
	echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"' >> $USER_HOME/.bashrc
	echo >> $USER_HOME/.bash_profile
	echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"' >> $USER_HOME/.bash_profile

	# Set Homebrew PATH for the current script
	eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"

	# Install CLI tools via Homebrew
	echo "Installing AWS CLI, kubectx, OpenTofu, OpenShift CLI, and kubectl via Homebrew..."
	sudo -u $TARGET_USER /home/linuxbrew/.linuxbrew/bin/brew install awscli kubectx opentofu openshift-cli kubernetes-cli

	# Install OpenShift tools not available via Homebrew
	echo "Downloading and installing additional OpenShift tools..."
	WORKDIR="/tmp/ocp_tools"
	mkdir -p $WORKDIR && cd $WORKDIR

	# Download oc-mirror plugin
	wget -q https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/oc-mirror.tar.gz
	tar -xzf oc-mirror.tar.gz -C /usr/local/bin oc-mirror
	chmod +x /usr/local/bin/oc-mirror

	# Download OpenShift Installer
	wget -q https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-install-linux.tar.gz
	tar -xzf openshift-install-linux.tar.gz -C /usr/local/bin openshift-install
	chmod +x /usr/local/bin/openshift-install

	rm -rf $WORKDIR
	cd /

	# Set up tmux config and TPM for ec2-user
	echo "Setting up tmux..."
	cat > $USER_HOME/.tmux.conf << 'TMUXCONF'
	${file("${path.module}/tmux.conf")}
	TMUXCONF
	chown $TARGET_USER:$TARGET_USER $USER_HOME/.tmux.conf
	sudo -u $TARGET_USER git clone https://github.com/tmux-plugins/tpm $USER_HOME/.tmux/plugins/tpm
	sudo -u $TARGET_USER $USER_HOME/.tmux/plugins/tpm/bin/install_plugins

	echo "Bastion Setup Complete!"
	EOF

  tags = {
    Name = "ocp-rhel10-bastion"
  }
}