#!/bin/bash

# Set required variables
STACK_NAME=$1

# Fetch the exported CloudFormation values
CLUSTER_NAME=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-ClusterName\`].Value" --output text)
CLUSTER_ENDPOINT=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-ClusterEndpoint\`].Value" --output text)
CLUSTER_ROLE_ARN=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-ClusterRoleArn\`].Value" --output text)
OIDC_PROVIDER_ARN=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-OIDCProviderArn\`].Value" --output text)
VPC_ID=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-VPCId\`].Value" --output text)
SECURITY_GROUP_ID=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-SecurityGroupId\`].Value" --output text)

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "Failed to fetch details"
  exit 1
fi
curl checkip.amazonaws.com

# Print fetched values for debugging
echo "Cluster Name: $CLUSTER_NAME"
echo "Cluster Endpoint: $CLUSTER_ENDPOINT"
echo "Cluster Role ARN: $CLUSTER_ROLE_ARN"
echo "OIDC Provider ARN: $OIDC_PROVIDER_ARN"
echo "VPC ID: $VPC_ID"
echo "Security Group ID: $SECURITY_GROUP_ID"

# Ensure kubectl is configured correctly
export KUBECONFIG=~/.kube/config
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region ap-southeast-2

# Create the CoreDNS service account with IRSA annotation
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coredns
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: $CLUSTER_ROLE_ARN
EOF

echo "Created service account for CoreDNS with IAM role."

# Check if aws-auth ConfigMap exists
if kubectl get configmap -n kube-system aws-auth >/dev/null 2>&1; then
  # Fetch the current aws-auth ConfigMap
  kubectl get configmap -n kube-system aws-auth -o yaml > aws-auth.yaml

  # Update aws-auth ConfigMap to map the IAM role to the coredns service account
  cat <<EOF >> aws-auth.yaml
  - groups:
    - system:masters
    rolearn: $CLUSTER_ROLE_ARN
    username: system:node:{{SessionName}}
EOF

  # Apply the updated aws-auth ConfigMap
  kubectl apply -f aws-auth.yaml

  echo "Updated aws-auth ConfigMap with CoreDNS IAM role."

  # Clean up
  rm aws-auth.yaml
else
  echo "aws-auth ConfigMap not found. Skipping update."
fi

echo "All tasks completed successfully."
