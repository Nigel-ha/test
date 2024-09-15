#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Parameters
CLUSTER_NAME=$1
REGION=$2

# Get the Target Group ARN by name
TARGET_GROUP_NAME="${CLUSTER_NAME}-nlb-tg"
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --names "$TARGET_GROUP_NAME" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

if [ -z "$TARGET_GROUP_ARN" ]; then
  echo "Failed to find Target Group ARN for $TARGET_GROUP_NAME"
  exit 1
fi

echo "Found Target Group ARN: $TARGET_GROUP_ARN"

# Get the EKS cluster endpoint
ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.endpoint" \
  --output text)

# Extract the DNS name from the endpoint URL
ENDPOINT_DNS=$(echo "$ENDPOINT" | awk -F/ '{print $3}')

# Resolve the endpoint DNS name to get the IP addresses using dig
IP_ADDRESSES=$(dig +short "$ENDPOINT_DNS")

if [ -z "$IP_ADDRESSES" ]; then
  echo "Failed to resolve IP addresses for $ENDPOINT_DNS"
  exit 1
fi

# Build the list of targets to register
declare -a TARGETS_ARGS=()

for IP in $IP_ADDRESSES; do
  AZ=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=addresses.private-ip-address,Values=$IP" \
    --query "NetworkInterfaces[0].AvailabilityZone" \
    --output text)
  if [ -z "$AZ" ] || [ "$AZ" == "None" ]; then
    echo "Failed to find Availability Zone for IP address $IP"
    exit 1
  fi
  echo "Found IP $IP in AZ $AZ"
  # Build the target argument
  TARGET_ARG="Id=$IP,Port=443,AvailabilityZone=$AZ"
  # Append to the targets arguments array
  TARGETS_ARGS+=("$TARGET_ARG")
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

echo "Registering new targets..."
aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "${TARGETS_ARGS[@]}"

echo "Registration complete. Registered targets:"
for IP in $IP_ADDRESSES; do
  echo "- $IP:443"
done
