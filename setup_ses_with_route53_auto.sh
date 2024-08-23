#!/bin/bash

# Parameters
BASE_DOMAIN="example.com"  # Replace with your base domain
REGION="us-east-1"         # Replace with your preferred AWS region
ENVIRONMENT=$1             # The environment parameter (NonProd or Prod)

# Validate ENVIRONMENT parameter
if [ -z "${ENVIRONMENT}" ]; then
  echo "Error: Environment parameter is required (NonProd or Prod)."
  exit 1
fi

if [ "${ENVIRONMENT}" != "NonProd" ] && [ "${ENVIRONMENT}" != "Prod" ]; then
  echo "Error: Invalid environment parameter. Please use 'NonProd' or 'Prod'."
  exit 1
fi

# Subdomains (without "-np" extension)
SUBDOMAINS=("cpp" "accp")

# Function to get the HOSTED_ZONE_ID for the BASE_DOMAIN
get_hosted_zone_id() {
  local base_domain=$1
  
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${base_domain}" --query "HostedZones[0].Id" --output text)
  HOSTED_ZONE_ID=$(echo $HOSTED_ZONE_ID | sed 's|/hostedzone/||')  # Remove the /hostedzone/ prefix
  echo "Hosted Zone ID for ${base_domain}: ${HOSTED_ZONE_ID}"
}

# Function to add the verification token to Route 53
add_verification_token_to_route53() {
  local full_domain=$1
  local verification_token=$2

  echo "Adding verification token for ${full_domain} to Route 53..."

  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch '{
    "Comment": "Add SES verification token for '${full_domain}'",
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_amazonses.'${full_domain}'",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [{
          "Value": "\"'${verification_token}'\""
        }]
      }
    }]
  }' --region "${REGION}"

  echo "Verification token added to Route 53."
}

# Get the HOSTED_ZONE_ID
get_hosted_zone_id "${BASE_DOMAIN}"

# Loop through each subdomain
for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
  if [ "${ENVIRONMENT}" == "NonProd" ]; then
    FULL_DOMAIN="${SUBDOMAIN}-np.${BASE_DOMAIN}"
  else
    FULL_DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
  fi
  
  echo "Checking SES domain identity
