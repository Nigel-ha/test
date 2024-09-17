#!/bin/bash

# Parameters
STACK_NAME=$1  # The CloudFormation stack name
CLUSTER_NAME=$2  # The EKS Cluster name
REGION=${3:-"ap-southeast-2"}  # Default region if not provided

# Fetch the CoreDNS IAM Role ARN from the CloudFormation export
CORE_DNS_IAM_ROLE_ARN=$(aws cloudformation list-exports --region "$REGION" \
  --query "Exports[?Name==\`${STACK_NAME}-CoreDNSIAMRoleArn\`].Value" --output text)

if [[ -z "$CORE_DNS_IAM_ROLE_ARN" ]]; then
  echo "Failed to retrieve CoreDNS IAM Role ARN from CloudFormation export."
  exit 1
fi

echo "CoreDNS IAM Role ARN: $CORE_DNS_IAM_ROLE_ARN"

# Ensure kubectl is configured for the correct cluster
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Annotate the CoreDNS service account with the IAM role ARN using kubectl
kubectl annotate serviceaccount coredns -n kube-system \
  eks.amazonaws.com/role-arn="$CORE_DNS_IAM_ROLE_ARN" --overwrite

if [ $? -eq 0 ]; then
  echo "Successfully annotated CoreDNS service account with IAM role."
else
  echo "Failed to annotate CoreDNS service account."
  exit 1
fi
