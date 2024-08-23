#!/bin/bash

# Validate number of parameters
if [ $# -ne 2 ]; then
  echo "Error: Two parameters required: <Environment> <BaseDomain>"
  echo "Usage: $0 <Environment> <BaseDomain>"
  exit 1
fi

# Parameters
ENVIRONMENT=$1        # The environment parameter (NonProd or Prod)
BASE_DOMAIN=$2        # The base domain (e.g., mail.example.com)
SES_REGION="ap-southeast-2"  # SES region, e.g., ap-southeast-2

# Validate ENVIRONMENT parameter
if [ "${ENVIRONMENT}" != "NonProd" ] && [ "${ENVIRONMENT}" != "Prod" ]; then
  echo "Error: Invalid environment parameter. Please use 'NonProd' or 'Prod'."
  exit 1
fi

# Subdomains (without "-np" extension)
SUBDOMAINS=("cpp" "accp")

# Function to get the HOSTED_ZONE_ID for each full domain
get_hosted_zone_id() {
  local full_domain=$1
  
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${full_domain}." --query "HostedZones[0].Id" --output text)
  HOSTED_ZONE_ID=$(echo $HOSTED_ZONE_ID | sed 's|/hostedzone/||')  # Remove the /hostedzone/ prefix
  if [ -z "${HOSTED_ZONE_ID}" ]; then
    echo "Error: Could not find hosted zone for ${full_domain}."
    exit 1
  fi
  echo "Hosted Zone ID for ${full_domain}: ${HOSTED_ZONE_ID}"
}

# Function to add the verification token to Route 53
add_verification_token_to_route53() {
  local full_domain=$1
  local verification_token=$2

  echo "Adding verification token for ${full_domain} to Route 53 in hosted zone ${HOSTED_ZONE_ID}..."

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
  }'

  if [ $? -ne 0 ]; then
    echo "Error: Failed to add the verification token for ${full_domain}."
    exit 1
  fi

  echo "Verification token added to Route 53."
}

# Loop through each subdomain
for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
  if [ "${ENVIRONMENT}" == "NonProd" ]; then
    FULL_DOMAIN="${SUBDOMAIN}-np.${BASE_DOMAIN}"
  else
    FULL_DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
  fi
  
  echo "Processing domain: ${FULL_DOMAIN}"
  
  # Get the HOSTED_ZONE_ID for this specific full domain
  get_hosted_zone_id "${FULL_DOMAIN}"
  
  # Create SES domain identity if it doesn't exist
  aws ses verify-domain-identity --domain "${FULL_DOMAIN}" --region "${SES_REGION}"
  
  # Get the verification token
  VERIFICATION_TOKEN=$(aws ses get-identity-verification-attributes --identities "${FULL_DOMAIN}" --query "VerificationAttributes.\"${FULL_DOMAIN}\".VerificationToken" --output text --region "${SES_REGION}")
  
  if [ -z "${VERIFICATION_TOKEN}" ]; then
    echo "Error: Could not retrieve verification token for ${FULL_DOMAIN}."
    exit 1
  fi
  
  echo "Verification token for ${FULL_DOMAIN}: ${VERIFICATION_TOKEN}"
  
  # Add verification token to Route 53
  add_verification_token_to_route53 "${FULL_DOMAIN}" "${VERIFICATION_TOKEN}"
  
  echo "Please wait for the DNS changes to propagate and check the SES console to confirm verification."
  
  echo ""
done

echo "Script completed."
