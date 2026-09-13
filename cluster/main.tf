terraform {
  required_version = ">= 1.3.0"
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Generate a random 3-digit suffix for the cluster name
resource "random_integer" "cluster_suffix" {
  min = 100
  max = 999
}

locals {
  cluster_name = "jgoh${random_integer.cluster_suffix.result}"
  install_dir  = "${path.module}/install-dir"
  brew_init    = "eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)\""
}

# Look up the existing Route53 hosted zone
data "aws_route53_zone" "cluster" {
  name = var.base_domain
}

# Render install-config.yaml from template
resource "local_file" "install_config" {
  content = templatefile("${path.module}/install-config.yaml.tpl", {
    cluster_name         = local.cluster_name
    base_domain          = var.base_domain
    aws_region           = var.aws_region
    master_instance_type = var.master_instance_type
    master_replicas      = var.master_replicas
    worker_instance_type = var.worker_instance_type
    worker_replicas      = var.worker_replicas
    pull_secret          = file("${path.module}/${var.pull_secret_path}")
    ssh_key              = file(pathexpand(var.ssh_public_key_path))
  })
  filename = "${local.install_dir}/install-config.yaml"
}

# Back up install-config (/usr/local/bin/openshift-install consumes it)
resource "local_file" "install_config_backup" {
  content  = local_file.install_config.content
  filename = "${local.install_dir}/install-config.yaml.bak"
}

# Phase 1: Generate manifests so we can modify worker MachineSets
resource "null_resource" "generate_manifests" {
  depends_on = [local_file.install_config]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${local.brew_init} && openshift-install create manifests --dir=${local.install_dir} --log-level=info"
  }
}

# Phase 2: Patch worker MachineSets to add 300GB additional SSD
resource "null_resource" "patch_worker_machinesets" {
  depends_on = [null_resource.generate_manifests]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail
			python3 -m venv /tmp/pyyaml-venv
			/tmp/pyyaml-venv/bin/pip install pyyaml -q

			for f in ${local.install_dir}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml; do
				[ -f "$f" ] || continue
				/tmp/pyyaml-venv/bin/python3 -c "
			import yaml, sys

			with open('$f') as fh:
			    doc = yaml.safe_load(fh)

			block_devices = doc['spec']['template']['spec']['providerSpec']['value']['blockDevices']
			block_devices.append({
			    'deviceName': '/dev/xvdb',
			    'ebs': {
			        'encrypted': True,
			        'volumeSize': ${var.worker_extra_disk_size},
			        'volumeType': 'gp3',
			        'iops': 3000
			    }
			})

			with open('$f', 'w') as fh:
			    yaml.dump(doc, fh, default_flow_style=False)
			"
				echo "Patched $f with additional ${var.worker_extra_disk_size}GB SSD"
			done
		SCRIPT
  }
}

# Phase 3: Create the cluster from modified manifests
resource "null_resource" "cluster_install" {
  depends_on = [null_resource.patch_worker_machinesets]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${local.brew_init} && openshift-install create cluster --dir=${local.install_dir} --log-level=info"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "${self.triggers.brew_init} && openshift-install destroy cluster --dir=${self.triggers.install_dir} --log-level=info || true"
  }

  triggers = {
    install_dir  = local.install_dir
    cluster_name = local.cluster_name
    brew_init    = local.brew_init
  }
}

# Phase 4: Apply GPU worker MachineSet
resource "null_resource" "gpu_machineset" {
  depends_on = [null_resource.cluster_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail
			${local.brew_init}
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			oc wait clusteroperators --all --for=condition=Available=True --timeout=600s

			INFRA_ID=$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)
			AMI_ID=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}')

			sed -e "s|CLUSTER_NAME|$INFRA_ID|g" \
			    -e "s|AMI_ID|$AMI_ID|g" \
			    -e "s|GPU_INSTANCE_TYPE|${var.gpu_instance_type}|g" \
			    -e "s|GPU_REGION|${var.aws_region}|g" \
			    -e "s|GPU_AZ|${var.gpu_availability_zone}|g" \
			    ${path.module}/manifests/gpu-machineset.yaml.tpl | oc apply -f -

			echo "GPU MachineSet created. Waiting for node..."
			oc wait machineset "$INFRA_ID-gpu-${var.gpu_availability_zone}" \
			  -n openshift-machine-api \
			  --for=jsonpath='{.status.readyReplicas}'=1 \
			  --timeout=600s
		SCRIPT
  }

  triggers = {
    cluster_name      = local.cluster_name
    gpu_instance_type = var.gpu_instance_type
    gpu_az            = var.gpu_availability_zone
  }
}

# Phase 5: Install operators
resource "null_resource" "operators" {
  depends_on = [null_resource.cluster_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail
			${local.brew_init}
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Creating operator namespaces..."
			oc apply -f ${path.module}/operators/01-namespaces.yaml
			sleep 10

			echo "Creating operator groups..."
			oc apply -f ${path.module}/operators/02-operatorgroups.yaml
			sleep 10

			echo "Creating operator subscriptions..."
			oc apply -f ${path.module}/operators/03-subscriptions.yaml

			echo "Operators installed. Monitor with: oc get csv -A"
		SCRIPT
  }

  triggers = {
    cluster_name = local.cluster_name
  }
}

# Phase 6: Configure ODF StorageCluster (waits for LSO + ODF operators to be ready)
resource "null_resource" "odf_storage" {
  depends_on = [null_resource.operators]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -eo pipefail
			${local.brew_init}
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Waiting for Local Storage Operator to be ready..."
			until oc get csv -n openshift-local-storage -o jsonpath='{.items[?(@.spec.displayName=="Local Storage")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Waiting for ODF Operator to be ready..."
			until oc get csv -n openshift-storage -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Data Foundation")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Applying ODF storage configuration..."
			oc apply -f ${path.module}/operators/04-odf-storage.yaml

			echo "ODF StorageCluster created. Devices will be discovered and adopted."
		SCRIPT
  }

  triggers = {
    cluster_name = local.cluster_name
  }
}

# Phase 7: Configure OpenShift AI (waits for RHOAI operator to be ready)
resource "null_resource" "openshift_ai" {
  depends_on = [null_resource.operators]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -eo pipefail
			${local.brew_init}
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Waiting for OpenShift AI Operator to be ready..."
			until oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Applying OpenShift AI configuration..."
			oc apply -f ${path.module}/operators/05-openshift-ai.yaml

			echo "Waiting for OdhDashboardConfig CRD..."
			until oc get crd odhdashboardconfigs.opendatahub.io 2>/dev/null; do
				sleep 15
			done

			echo "Re-applying to create OdhDashboardConfig..."
			oc apply -f ${path.module}/operators/05-openshift-ai.yaml

			echo "OpenShift AI fully configured."
		SCRIPT
  }

  triggers = {
    cluster_name = local.cluster_name
  }
}

# Phase 8: Configure Quay Registry (waits for Quay operator to be ready)
resource "null_resource" "quay_registry" {
  depends_on = [null_resource.operators]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -eo pipefail
			${local.brew_init}
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Waiting for Quay Operator to be ready..."
			until oc get csv -n quay-enterprise -o jsonpath='{.items[?(@.spec.displayName=="Red Hat Quay")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Creating Quay Registry..."
			oc apply -f ${path.module}/operators/06-quay-registry.yaml

			echo "Quay Registry created."
		SCRIPT
  }

  triggers = {
    cluster_name = local.cluster_name
  }
}
