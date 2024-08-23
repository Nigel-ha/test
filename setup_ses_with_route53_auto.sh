#!/bin/bash

# Validate number of parameters
if [ $# -ne 2 ]; then
  echo "Error: Two parameters required: <Environment> <BaseDomain>"
  echo "Usage: $0 <Environment> <BaseDomain>"
  exit 1
fi

# Parameters
ENVIRONMENT=$1        # The environment parameter (NonProd or Prod)
BASE_DOMAIN=$2        # The base domain (e.g., cpp-np.mail.example.com)
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

  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
    \"Comment\": \"Add SES verification token for ${full_domain}\",
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"_amazonses.${full_domain}\",
        \"Type\": \"TXT\",
        \"TTL\": 300,
        \"ResourceRecords\": [{
          \"Value\": \"\\\"${verification_token}\\\"\"
        }]
      }
    }]
  }"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to add the verification token for ${full_domain}."
    exit 1
  fi

  echo "Verification token added to Route 53."
}

# Function to set up custom MAIL FROM domain
setup_custom_mail_from() {
  local full_domain=$1
  local mail_from_domain=$2

  echo "Setting up Custom MAIL FROM domain (${mail_from_domain}) for ${full_domain}..."

  aws ses set-identity-mail-from-domain \
    --identity "${full_domain}" \
    --mail-from-domain "${mail_from_domain}" \
    --region "${SES_REGION}"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to set the MAIL FROM domain for ${full_domain}."
    exit 1
  fi

  echo "Custom MAIL FROM domain set for ${full_domain}."

  # Add MX and SPF records for the MAIL FROM domain
  echo "Adding MX and SPF records to Route 53 for ${mail_from_domain}..."

  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
    \"Comment\": \"Add MX and SPF records for custom MAIL FROM domain ${mail_from_domain}\",
    \"Changes\": [
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${mail_from_domain}\",
          \"Type\": \"MX\",
          \"TTL\": 300,
          \"ResourceRecords\": [
            {\"Value\": \"10 feedback-smtp.${SES_REGION}.amazonses.com\"}
          ]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${mail_from_domain}\",
          \"Type\": \"TXT\",
          \"TTL\": 300,
          \"ResourceRecords\": [
            {\"Value\": \"\\\"v=spf1 include:amazonses.com -all\\\"\"}
          ]
        }
      }
    ]
  }"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to add MX and SPF records for ${mail_from_domain}."
    exit 1
  fi

  echo "MX and SPF records added for ${mail_from_domain}."
}

# Function to enable DKIM and add DKIM records to Route 53
setup_dkim() {
  local full_domain=$1

  echo "Enabling DKIM for ${full_domain}..."

  DKIM_TOKENS=$(aws ses verify-domain-dkim --domain "${full_domain}" --query "DkimTokens" --output text --region "${SES_REGION}")

  if [ -z "${DKIM_TOKENS}" ]; then
    echo "Error: Failed to retrieve DKIM tokens for ${full_domain}."
    exit 1
  fi

  echo "DKIM tokens for ${full_domain}: ${DKIM_TOKENS}"

  # Split DKIM tokens into an array
  IFS=$'\t' read -r -a DKIM_TOKEN_ARRAY <<< "$DKIM_TOKENS"

  echo "Adding DKIM CNAME records to Route 53 for ${full_domain}..."

  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "{
    \"Comment\": \"Add DKIM records for ${full_domain}\",
    \"Changes\": [
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${DKIM_TOKEN_ARRAY[0]}._domainkey.${full_domain}\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [
            {\"Value\": \"${DKIM_TOKEN_ARRAY[0]}.dkim.amazonses.com\"}
          ]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${DKIM_TOKEN_ARRAY[1]}._domainkey.${full_domain}\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [
            {\"Value\": \"${DKIM_TOKEN_ARRAY[1]}.dkim.amazonses.com\"}
          ]
        }
      },
      {
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${DKIM_TOKEN_ARRAY[2]}._domainkey.${full_domain}\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [
            {\"Value\": \"${DKIM_TOKEN_ARRAY[2]}.dkim.amazonses.com\"}
          ]
        }
      }
    ]
  }"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to add DKIM records for ${full_domain}."
    exit 1
  fi

  echo "DKIM records added for ${full_domain}."
}

# Loop through each subdomain
for SUBDOMAIN in "${SUBDOMAINS[@]}"; do
  if [ "${ENVIRONMENT}" == "NonProd" ]; then
    FULL_DOMAIN="${SUBDOMAIN}-np.${BASE_DOMAIN}"
    MAIL_FROM_DOMAIN="bounce.${FULL_DOMAIN}"
  else
    FULL_DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
    MAIL_FROM_DOMAIN="bounce.${FULL_DOMAIN}"
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
  
  # Set up custom MAIL FROM domain
  setup_custom_mail_from "${FULL_DOMAIN}" "${MAIL_FROM_DOMAIN}"

  # Enable DKIM and add DKIM records
  setup_dkim "${FULL_DOMAIN}"
  
  echo "Please wait for the DNS changes to propagate and check the SES console to confirm verification."
  
  echo ""
done

echo "Script completed."
