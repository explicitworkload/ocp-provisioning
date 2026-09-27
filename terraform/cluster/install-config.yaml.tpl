apiVersion: v1
metadata:
  name: ${cluster_name}
baseDomain: ${base_domain}
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    platform:
      aws:
        type: ${worker_instance_type}
    replicas: ${worker_replicas}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: ${master_instance_type}
  replicas: ${master_replicas}
networking:
  clusterNetwork:
    - cidr: 10.244.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.20.0.0/16
platform:
  aws:
    region: ${aws_region}
publish: External
pullSecret: '${pull_secret}'
sshKey: '${ssh_key}'
