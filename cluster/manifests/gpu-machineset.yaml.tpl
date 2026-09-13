apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: CLUSTER_NAME-gpu-ap-southeast-1a
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: CLUSTER_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: CLUSTER_NAME
      machine.openshift.io/cluster-api-machineset: CLUSTER_NAME-gpu-ap-southeast-1a
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: CLUSTER_NAME
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: CLUSTER_NAME-gpu-ap-southeast-1a
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
          instanceType: g5.4xlarge
          kind: AWSMachineProviderConfig
          placement:
            availabilityZone: ap-southeast-1a
            region: ap-southeast-1
          securityGroups:
            - filters:
                - name: tag:Name
                  values:
                    - CLUSTER_NAME-node
            - filters:
                - name: tag:Name
                  values:
                    - CLUSTER_NAME-lb
          subnet:
            filters:
              - name: tag:Name
                values:
                  - CLUSTER_NAME-private-ap-southeast-1a
          tags:
            - name: kubernetes.io/cluster/CLUSTER_NAME
              value: owned
          userDataSecret:
            name: worker-user-data
