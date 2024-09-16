#!/bin/bash

# Input parameters
CLUSTER_NAME=$1
AWS_REGION=$2
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
  echo "Usage: $0 <cluster-name> <aws-region>"
  exit 1
fi

# Get the OIDC issuer URL for the EKS cluster
OIDC_ISSUER_URL=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

if [ -z "$OIDC_ISSUER_URL" ]; then
  echo "Failed to get OIDC issuer URL for cluster: $CLUSTER_NAME"
  exit 1
fi

# Extract the OIDC provider URL (remove the "https://" prefix)
OIDC_PROVIDER_URL=$(echo "$OIDC_ISSUER_URL" | sed 's/^https:\/\///')

# Construct the OIDC provider ARN
OIDC_PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC_PROVIDER_URL"

# Output the OIDC provider ARN
echo "OIDC Provider ARN: $OIDC_PROVIDER_ARN"

# Optionally export it as an environment variable or pass it to the next pipeline stage
export OIDC_PROVIDER_ARN
