#!/bin/bash

# Parameters
BASE_DOMAIN="example.com"  # Replace with your base domain
REGION="us-east-1"         # Replace with your preferred AWS region

# Subdomains
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
  FULL_DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
  
  echo "Checking SES domain identity for ${FULL_DOMAIN}..."
  
  # Get the verification status
  VERIFICATION_STATUS=$(aws ses get-identity-verification-attributes --identities "${FULL_DOMAIN}" --query "VerificationAttributes['${FULL_DOMAIN}'].VerificationStatus" --output text --region "${REGION}")
  
  if [ "${VERIFICATION_STATUS}" == "Success" ]; then
    echo "${FULL_DOMAIN} is already verified."
  else
    echo "${FULL_DOMAIN} is not verified."
    
    # Create SES domain identity if it doesn't exist
    aws ses verify-domain-identity --domain "${FULL_DOMAIN}" --region "${REGION}"
    
    # Get the verification token
    VERIFICATION_TOKEN=$(aws ses get-identity-verification-attributes --identities "${FULL_DOMAIN}" --query "VerificationAttributes['${FULL_DOMAIN}'].VerificationToken" --output text --region "${REGION}")
    
    echo "Verification token for ${FULL_DOMAIN}: ${VERIFICATION_TOKEN}"
    
    # Add verification token to Route 53
    add_verification_token_to_route53 "${FULL_DOMAIN}" "${VERIFICATION_TOKEN}"
    
    echo "Please wait for the DNS changes to propagate and check the SES console to confirm verification."
  fi
  
  echo ""
done

echo "Script completed."
