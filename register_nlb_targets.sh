#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Variables
CLUSTER_NAME=$1
AWS_REGION=${2:-ap-southeast-2}  # Default region set to ap-southeast-2 if not provided

# Check if the cluster name is provided
if [ -z "$CLUSTER_NAME" ]; then
  echo "Usage: $0 <CLUSTER_NAME> [AWS_REGION]"
  exit 1
fi

# Retrieve VPC ID from CloudFormation export "spokeVPC"
VPC_ID=$(aws cloudformation list-exports --region "$AWS_REGION" --query "Exports[?Name=='spokeVPC'].Value" --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  echo "Failed to retrieve VPC ID from CloudFormation export 'spokeVPC'. Exiting."
  exit 1
fi

echo "Using VPC ID: $VPC_ID"

# Security group name based on the cluster name
SECURITY_GROUP_NAME="${CLUSTER_NAME}-sg"

# Check if security group already exists
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" --query "SecurityGroups[0].GroupId" --output text)

if [ "$SECURITY_GROUP_ID" == "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
  echo "Security group $SECURITY_GROUP_NAME does not exist. Creating it..."

  # Create the security group
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "Security group for $CLUSTER_NAME allowing 443 and 8443 from 172.0.0.0/8 and 10.0.0.0/8" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' --output text)

  # Check if the security group was created successfully
  if [ -z "$SECURITY_GROUP_ID" ]; then
    echo "Failed to create security group for $CLUSTER_NAME. Exiting."
    exit 1
  fi

  echo "Created Security Group with ID: $SECURITY_GROUP_ID"

  # Add ingress rules
  aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 443 \
    --cidr 172.0.0.0/8 \
    --region "$AWS_REGION"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 8443 \
    --cidr 172.0.0.0/8 \
    --region "$AWS_REGION"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 443 \
    --cidr 10.0.0.0/8 \
    --region "$AWS_REGION"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 8443 \
    --cidr 10.0.0.0/8 \
    --region "$AWS_REGION"

  echo "Ingress rules added to Security Group $SECURITY_GROUP_NAME"
else
  echo "Security group $SECURITY_GROUP_NAME already exists with ID: $SECURITY_GROUP_ID"
fi

# Look up CloudFormation exports for spoke subnets
function get_subnet_from_export {
  local export_name=$1
  aws cloudformation list-exports --region "$AWS_REGION" --query "Exports[?Name=='$export_name'].Value" --output text
}

SPOKE_SUBNET_A=$(get_subnet_from_export "spokeSubnetA")
SPOKE_SUBNET_B=$(get_subnet_from_export "spokeSubnetB")
SPOKE_SUBNET_C=$(get_subnet_from_export "spokeSubnetC")

# Build the subnet list by including only valid subnets (i.e., not "None")
SUBNET_IDS=""
if [ "$SPOKE_SUBNET_A" != "None" ] && [ -n "$SPOKE_SUBNET_A" ]; then
  SUBNET_IDS+="$SPOKE_SUBNET_A"
fi
if [ "$SPOKE_SUBNET
