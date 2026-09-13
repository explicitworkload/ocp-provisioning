apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: CLUSTER_NAME-gpu-GPU_AZ
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: CLUSTER_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: CLUSTER_NAME
      machine.openshift.io/cluster-api-machineset: CLUSTER_NAME-gpu-GPU_AZ
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: CLUSTER_NAME
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: CLUSTER_NAME-gpu-GPU_AZ
    spec:
      metadata:
        labels:
          node-role.kubernetes.io/gpu: ""
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AWSMachineProviderConfig
          ami:
            id: AMI_ID
          blockDevices:
            - ebs:
                encrypted: true
                iops: 0
                kmsKey: {}
                volumeSize: 120
                volumeType: gp3
          credentialsSecret:
            name: aws-cloud-credentials
          deviceIndex: 0
          iamInstanceProfile:
            id: CLUSTER_NAME-worker-profile
          instanceType: GPU_INSTANCE_TYPE
          kind: AWSMachineProviderConfig
          placement:
            availabilityZone: GPU_AZ
            region: GPU_REGION
          securityGroups:
            - filters:
                - name: tag:Name
                  values:
                    - CLUSTER_NAME-worker-sg
          subnet:
            filters:
              - name: tag:Name
                values:
                  - CLUSTER_NAME-subnet-private-GPU_AZ
          tags:
            - name: kubernetes.io/cluster/CLUSTER_NAME
              value: owned
          userDataSecret:
            name: worker-user-data
