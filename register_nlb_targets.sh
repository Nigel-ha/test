#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Parameters
CLUSTER_NAME=$1
REGION=$2
TARGET_GROUP_ARN=$3

# Get the EKS cluster endpoint
ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.endpoint" \
  --output text)

# Extract the DNS name from the endpoint URL
ENDPOINT_DNS=$(echo "$ENDPOINT" | awk -F/ '{print $3}')

# Resolve the endpoint DNS name to get the IP addresses
IP_ADDRESSES=$(dig +short "$ENDPOINT_DNS")

if [ -z "$IP_ADDRESSES" ]; then
  echo "Failed to resolve IP addresses for $ENDPOINT_DNS"
  exit 1
fi

# Build the list of targets to register
TARGETS=()
for IP in $IP_ADDRESSES; do
  TARGETS+=("{\"Id\":\"$IP\",\"Port\":443}")
done

# Deregister existing targets
EXISTING_TARGETS=$(aws elbv2 describe-target-health \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --query "TargetHealthDescriptions[].Target" \
  --output json)

if [ "$EXISTING_TARGETS" != "[]" ]; then
  echo "Deregistering existing targets..."
  aws elbv2 deregister-targets \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --targets "$EXISTING_TARGETS"
fi

# Register new targets
echo "Registering new targets..."
aws elbv2 register-targets \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "${TARGETS[@]}"

echo "Registration complete. Registered targets:"
for IP in $IP_ADDRESSES; do
  echo "- $IP:443"
done
