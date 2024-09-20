#!/bin/bash
# Set required variables
STACK_NAME=$1

if [[ -z "$STACK_NAME"  ]]; then
  echo "Usage: $0 <STACK_NAME>"
  exit 1
fi

VPC_ID=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-VPCId\`].Value" --output text)
SECURITY_GROUP_ID=$(aws cloudformation list-exports --query "Exports[?Name==\`${STACK_NAME}-SecurityGroupId\`].Value" --output text)

REGION="ap-southeast-2"
# SECURITY_GROUP_ID=""

# # Look up the default security group if not provided
# if [[ -z "$SECURITY_GROUP_ID" ]]; then
#     echo "Looking up the default security group for VPC: $VPC_ID"
#     SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
#         --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
#         --query 'SecurityGroups[0].GroupId' \
#         --output text --region "$REGION")

#     if [[ -z "$SECURITY_GROUP_ID" ]]; then
#         echo "Failed to find the default security group for VPC: $VPC_ID"
#         exit 1
#     fi
#     echo "Default Security Group: $SECURITY_GROUP_ID"
# fi

# Function to check if a VPC endpoint already exists
check_endpoint_exists() {
  local service_name=$1
  aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$service_name" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "$REGION"
}

# Function to create a VPC interface endpoint
create_vpc_interface_endpoint() {
  local service_name=$1
  local endpoint_name="${STACK_NAME}-${service_name##*.}-vpc-endpoint"

  echo "Creating VPC Interface Endpoint for $service_name"
  aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --service-name "$service_name" \
    --vpc-endpoint-type Interface \
    --subnet-ids "$SUBNET_IDS" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --private-dns-enabled \
    --region "$REGION" \
    --query 'VpcEndpoint.VpcEndpointId' --output text

  echo "VPC Interface Endpoint created for $service_name: $endpoint_name"
}

# Function to create a VPC gateway endpoint
create_vpc_gateway_endpoint() {
  local service_name=$1
  local route_table_ids=$2
  local endpoint_name="${STACK_NAME}-${service_name##*.}-gateway-endpoint"

  echo "Creating VPC Gateway Endpoint for $service_name"
  aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --service-name "$service_name" \
    --vpc-endpoint-type Gateway \
    --route-table-ids $route_table_ids \
    --region "$REGION" \
    --query 'VpcEndpoint.VpcEndpointId' --output text

  echo "VPC Gateway Endpoint created for $service_name: $endpoint_name"
}

# Define the required SSM and Logs interface endpoints
INTERFACE_SERVICES=(
    "com.amazonaws.$REGION.ec2"
    "com.amazonaws.$REGION.ecr.api"
    "com.amazonaws.$REGION.ecr.dkr"
    "com.amazonaws.$REGION.sts"
    "com.amazonaws.$REGION.ssm"
    "com.amazonaws.$REGION.ssmmessages"
    "com.amazonaws.$REGION.ec2messages"
    "com.amazonaws.$REGION.logs"  # CloudWatch Logs
)

# Define the S3 gateway endpoint
GATEWAY_SERVICES=(
    "com.amazonaws.$REGION.s3"
)

# Get the list of subnets in the VPC for interface endpoints
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' ',')

if [[ -z "$SUBNET_IDS" ]]; then
  echo "No subnets found for VPC: $VPC_ID"
  exit 1
fi
echo "Using subnets: $SUBNET_IDS"

# Get the list of route table IDs for gateway endpoints (S3)
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[*].RouteTableId" --output text --region "$REGION")

if [[ -z "$ROUTE_TABLE_IDS" ]]; then
  echo "No route tables found for VPC: $VPC_ID"
  exit 1
fi

# Check and create VPC interface endpoints for each service
for service in "${INTERFACE_SERVICES[@]}"; do
  endpoint_id=$(check_endpoint_exists "$service")
  if [[ "$endpoint_id" == "None" ]]; then
    create_vpc_interface_endpoint "$service"
  else
    echo "VPC Interface Endpoint already exists for $service: $endpoint_id"
  fi
done

# Check and create the VPC gateway endpoint for S3
for service in "${GATEWAY_SERVICES[@]}"; do
  endpoint_id=$(check_endpoint_exists "$service")
  if [[ "$endpoint_id" == "None" ]]; then
    create_vpc_gateway_endpoint "$service" "$ROUTE_TABLE_IDS"
  else
    echo "VPC Gateway Endpoint already exists for $service: $endpoint_id"
  fi
done

echo "All tasks completed."
