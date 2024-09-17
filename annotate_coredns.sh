#!/bin/bash

# Ensure the script is called with the cluster name
if [[ -z "$1" ]]; then
  echo "Usage: $0 <ClusterName>"
  exit 1
fi

# Parameters
CLUSTER_NAME=$1
REGION="ap-southeast-2"  # Fixed region as requested

# Function to look up CloudFormation exports based on the ClusterName
get_export_value() {
  local export_name=$1
  local export_value

  export_value=$(aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name==\`${CLUSTER_NAME}-$export_name\`].Value" --output text)

  if [[ -z "$export_value" || "$export_value" == "None" ]]; then
    echo "Error: Could not find CloudFormation export for ${CLUSTER_NAME}-$export_name"
    exit 1
  fi

  echo "$export_value"
}

# Fetch the CoreDNS IAM Role ARN and other required values from CloudFormation exports
CORE_DNS_IAM_ROLE_ARN=$(get_export_value "CoreDNSIAMRoleArn")
CLUSTER_NAME_OUTPUT=$(get_export_value "ClusterName")

echo "CoreDNS IAM Role ARN: $CORE_DNS_IAM_ROLE_ARN"
echo "EKS Cluster Name: $CLUSTER_NAME_OUTPUT"

# Ensure kubectl is configured for the correct cluster
aws eks update-kubeconfig --name "$CLUSTER_NAME_OUTPUT" --region "$REGION"

# Annotate the CoreDNS service account with the IAM role ARN using kubectl
kubectl annotate serviceaccount coredns -n kube-system \
  eks.amazonaws.com/role-arn="$CORE_DNS_IAM_ROLE_ARN" --overwrite

if [ $? -eq 0 ]; then
  echo "Successfully annotated CoreDNS service account with IAM role."
else
  echo "Failed to annotate CoreDNS service account."
  exit 1
fi
