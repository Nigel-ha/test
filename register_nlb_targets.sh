#!/bin/bash

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
if [ "$SPOKE_SUBNET_B" != "None" ] && [ -n "$SPOKE_SUBNET_B" ]; then
  if [ -n "$SUBNET_IDS" ]; then
    SUBNET_IDS+=" $SPOKE_SUBNET_B"  # Comma-separated
  else
    SUBNET_IDS+="$SPOKE_SUBNET_B"
  fi
fi
if [ "$SPOKE_SUBNET_C" != "None" ] && [ -n "$SPOKE_SUBNET_C" ]; then
  if [ -n "$SUBNET_IDS" ]; then
    SUBNET_IDS+=" $SPOKE_SUBNET_C"  # Comma-separated
  else
    SUBNET_IDS+="$SPOKE_SUBNET_C"
  fi
fi

# Strip any accidental spaces
# SUBNET_IDS=$(echo "$SUBNET_IDS" | tr -d '[:space:]')

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

# Get the private IP addresses of the endpoint network interfaces
IP_ADDRESSES=$(aws ec2 describe-network-interfaces \
  --filters "Name=vpc-endpoint-id,Values=$ENDPOINT_ID" \
  --query "NetworkInterfaces[].PrivateIpAddress" \
  --output text)

if [ -z "$IP_ADDRESSES" ]; then
  echo "Failed to retrieve IP addresses for the VPC Endpoint $ENDPOINT_ID"
  exit 1
fi

# Build the list of targets to register
declare -a TARGETS_ARGS=()

for IP in $IP_ADDRESSES; do
  AZ=$(aws ec2 describe-network-interfaces \
    --region "$AWS_REGION" \
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

# Register new targets
echo "Registering new targets..."
aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets "${TARGETS_ARGS[@]}"

echo "Registration complete. Registered targets:"
for IP in $IP_ADDRESSES; do
  echo "- $IP:443"
done
