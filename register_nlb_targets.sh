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

  if [ -z "$SECURITY_GROUP_ID" ]; then
    echo "Failed to create security group for $CLUSTER_NAME. Exiting."
    exit 1
  fi

  echo "Created Security Group with ID: $SECURITY_GROUP_ID"

  # Add ingress rules
  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 443 --cidr 172.0.0.0/8 --region "$AWS_REGION"
  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 8443 --cidr 172.0.0.0/8 --region "$AWS_REGION"
  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 443 --cidr 10.0.0.0/8 --region "$AWS_REGION"
  aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 8443 --cidr 10.0.0.0/8 --region "$AWS_REGION"

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
if [ "$SPOKE_SUBNET_B" != "None" ] && [ -n "$SPOKE_SUBNET_B" ]; then
  if [ -n "$SUBNET_IDS" ]; then
    SUBNET_IDS+=" $SPOKE_SUBNET_B"  # Space-separated
  else
    SUBNET_IDS+="$SPOKE_SUBNET_B"
  fi
fi
if [ "$SPOKE_SUBNET_C" != "None" ] && [ -n "$SPOKE_SUBNET_C" ]; then
  if [ -n "$SUBNET_IDS" ]; then
    SUBNET_IDS+=" $SPOKE_SUBNET_C"  # Space-separated
  else
    SUBNET_IDS+="$SPOKE_SUBNET_C"
  fi
fi

if [ -z "$SUBNET_IDS" ]; then
  echo "No valid subnets found from CloudFormation exports. Exiting."
  exit 1
fi

echo "Using subnets: $SUBNET_IDS"

# Check if the EKS API VPC endpoint already exists
ENDPOINT_SERVICE_NAME="com.amazonaws.${AWS_REGION}.eks"
EXISTING_ENDPOINT=$(aws ec2 describe-vpc-endpoints \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$ENDPOINT_SERVICE_NAME" \
  --query "VpcEndpoints[?VpcEndpointType=='Interface'].[VpcEndpointId]" \
  --output text)

if [ -z "$EXISTING_ENDPOINT" ]; then
  echo "EKS API VPC endpoint does not exist. Creating the endpoint..."
  
  # Create the VPC Endpoint for EKS API
  ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --service-name "$ENDPOINT_SERVICE_NAME" \
    --subnet-ids "$SUBNET_IDS" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --vpc-endpoint-type Interface \
    --region "$AWS_REGION" \
    --query "VpcEndpoint.VpcEndpointId" \
    --output text)

  echo "Created VPC Endpoint: $ENDPOINT_ID"
else
  echo "EKS API VPC endpoint already exists: $EXISTING_ENDPOINT"
  ENDPOINT_ID=$EXISTING_ENDPOINT
fi

# Get the network interface IDs associated with the endpoint
NETWORK_INTERFACE_IDS=$(aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$ENDPOINT_ID" \
  --region "$AWS_REGION" \
  --query "VpcEndpoints[0].NetworkInterfaceIds[]" \
  --output text)

if [ -z "$NETWORK_INTERFACE_IDS" ]; then
  echo "Failed to retrieve network interfaces for VPC Endpoint $ENDPOINT_ID"
  exit 1
fi

# Get the private IP addresses of the network interfaces
IP_ADDRESSES=""
for NI_ID in $NETWORK_INTERFACE_IDS; do
  IP_ADDRESS=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "$NI_ID" \
    --region "$AWS_REGION" \
    --query "NetworkInterfaces[0].PrivateIpAddress" \
    --output text)
  
  if [ -n "$IP_ADDRESS" ]; then
    IP_ADDRESSES+="$IP_ADDRESS "
  fi
done

if [ -z "$IP_ADDRESSES" ]; then
  echo "Failed to retrieve IP addresses for the network interfaces of the VPC Endpoint $ENDPOINT_ID"
  exit 1
fi

# Get the Target Group ARN by name
TARGET_GROUP_NAME="${CLUSTER_NAME}-nlb-tg"
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --region "$AWS_REGION" \
  --names "$TARGET_GROUP_NAME" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

if [ -z "$TARGET_GROUP_ARN" ]; then
  echo "Failed to find Target Group ARN for $TARGET_GROUP_NAME"
  exit 1
fi

echo "Found Target Group ARN: $TARGET_GROUP_ARN"

# Build the list of targets to register
declare -a TARGETS_ARGS=()

for IP in $IP_ADDRESSES; do
  echo "Found IP $IP"
  
  # Build the target argument without the AvailabilityZone (AWS will handle it automatically)
  TARGET_ARG="Id=$IP,Port=443"
  
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

# Register new targets
echo "Registering new targets..."
aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "${TARGETS_ARGS[@]}"

echo "Registration complete. Registered targets:"
for IP in $IP_ADDRESSES; do
  echo "- $IP:443"
done
