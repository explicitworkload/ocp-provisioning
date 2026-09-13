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
  cluster_name = "aws${random_integer.cluster_suffix.result}"
  install_dir  = "${path.module}/install-dir"
}

# Create Route53 hosted zone for the base domain
resource "aws_route53_zone" "cluster" {
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

# DNS validation: wait until the domain's NS records match this Route53 zone
resource "null_resource" "dns_validation" {
  depends_on = [aws_route53_zone.cluster]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail

			EXPECTED_NS=$(aws route53 get-hosted-zone --id ${aws_route53_zone.cluster.zone_id} \
			  --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | sort)

			echo ""
			echo "============================================="
			echo " Route53 hosted zone created for ${var.base_domain}"
			echo " Zone ID: ${aws_route53_zone.cluster.zone_id}"
			echo "============================================="
			echo ""
			echo " Set these NS records at your domain registrar:"
			echo ""
			echo "$EXPECTED_NS"
			echo ""
			echo " Waiting for DNS propagation..."
			echo "============================================="
			echo ""

			while true; do
				ACTUAL_NS=$(dig +short NS ${var.base_domain} @8.8.8.8 2>/dev/null | sed 's/\.$//' | sort || true)
				MATCH=true
				for ns in $EXPECTED_NS; do
					if ! echo "$ACTUAL_NS" | grep -qi "$ns"; then
						MATCH=false
						break
					fi
				done

				if [ "$MATCH" = true ] && [ -n "$ACTUAL_NS" ]; then
					echo "DNS delegation verified — NS records match."
					break
				fi

				echo "NS records not yet propagated. Retrying in 30s..."
				sleep 30
			done
		SCRIPT
  }
}

# Phase 1: Generate manifests so we can modify worker MachineSets
resource "null_resource" "generate_manifests" {
  depends_on = [local_file.install_config, null_resource.dns_validation]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "/usr/local/bin/openshift-install create manifests --dir=${local.install_dir} --log-level=info"
  }
}

# Phase 2: Patch worker MachineSets to add 300GB additional SSD
resource "null_resource" "patch_worker_machinesets" {
  depends_on = [null_resource.generate_manifests]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail
			pip3 install pyyaml -q

			for f in ${local.install_dir}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml; do
				[ -f "$f" ] || continue
				python3 -c "
			import yaml, sys

			with open('$f') as fh:
			    doc = yaml.safe_load(fh)

			block_devices = doc['spec']['template']['spec']['providerSpec']['value']['blockDevices']
			block_devices.append({
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
    command     = "/usr/local/bin/openshift-install create cluster --dir=${local.install_dir} --log-level=info"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "/usr/local/bin/openshift-install destroy cluster --dir=${self.triggers.install_dir} --log-level=info || true"
  }

  triggers = {
    install_dir  = local.install_dir
    cluster_name = local.cluster_name
  }
}

# Phase 4: Apply GPU worker MachineSet
resource "null_resource" "gpu_machineset" {
  depends_on = [null_resource.cluster_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			/usr/local/bin/oc wait clusteroperators --all --for=condition=Available=True --timeout=600s

			INFRA_ID=$(/usr/local/bin/oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)
			AMI_ID=$(/usr/local/bin/oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.ami.id}')

			sed -e "s|CLUSTER_NAME|$INFRA_ID|g" \
			    -e "s|AMI_ID|$AMI_ID|g" \
			    ${path.module}/manifests/gpu-machineset.yaml.tpl | /usr/local/bin/oc apply -f -

			echo "GPU MachineSet created. Waiting for node..."
			/usr/local/bin/oc wait machineset "$INFRA_ID-gpu-ap-southeast-1a" \
			  -n openshift-machine-api \
			  --for=jsonpath='{.status.readyReplicas}'=1 \
			  --timeout=600s
		SCRIPT
  }

  triggers = {
    cluster_name = local.cluster_name
  }
}

# Phase 5: Install operators
resource "null_resource" "operators" {
  depends_on = [null_resource.cluster_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-SCRIPT
			set -euo pipefail
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Creating operator namespaces..."
			/usr/local/bin/oc apply -f ${path.module}/operators/01-namespaces.yaml
			sleep 10

			echo "Creating operator groups..."
			/usr/local/bin/oc apply -f ${path.module}/operators/02-operatorgroups.yaml
			sleep 10

			echo "Creating operator subscriptions..."
			/usr/local/bin/oc apply -f ${path.module}/operators/03-subscriptions.yaml

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
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Waiting for Local Storage Operator to be ready..."
			until /usr/local/bin/oc get csv -n openshift-local-storage -o jsonpath='{.items[?(@.spec.displayName=="Local Storage")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Waiting for ODF Operator to be ready..."
			until /usr/local/bin/oc get csv -n openshift-storage -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Data Foundation")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Applying ODF storage configuration..."
			/usr/local/bin/oc apply -f ${path.module}/operators/04-odf-storage.yaml

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
			export KUBECONFIG=${local.install_dir}/auth/kubeconfig

			echo "Waiting for OpenShift AI Operator to be ready..."
			until /usr/local/bin/oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].status.phase}' 2>/dev/null | grep -q Succeeded; do
				sleep 30
			done

			echo "Applying OpenShift AI configuration..."
			/usr/local/bin/oc apply -f ${path.module}/operators/05-openshift-ai.yaml

			echo "OpenShift AI configured with KServe, ModelMesh, and all components."
		SCRIPT
  }

  triggers = {
    cluster_name = local.cluster_name
  }
}
