output "cluster_name" {
  value       = local.cluster_name
  description = "Generated cluster name"
}

output "cluster_domain" {
  value       = "${local.cluster_name}.${var.base_domain}"
  description = "Fully qualified cluster domain"
}

output "console_url" {
  value       = "https://console-openshift-console.apps.${local.cluster_name}.${var.base_domain}"
  description = "OpenShift web console URL"
}

output "kubeconfig_path" {
  value       = "${local.install_dir}/auth/kubeconfig"
  description = "Path to the cluster kubeconfig"
}

output "kubeadmin_password_path" {
  value       = "${local.install_dir}/auth/kubeadmin-password"
  description = "Path to the kubeadmin password file"
}

output "route53_name_servers" {
  value       = data.aws_route53_zone.cluster.name_servers
  description = "Name servers for the Route53 hosted zone"
}
