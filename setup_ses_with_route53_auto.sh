#!/bin/bash

# Validate number of parameters
if [ $# -ne 1 ]; then
  echo "Error: One parameter required: <BaseDomain>"
  echo "Usage: $0 <BaseDomain>"
  exit 1
fi

# Parameters
BASE_DOMAIN=$1        # The base domain (e.g., cpp-np.mail.example.com)
SES_REGION="ap-southeast-2"  # SES region, e.g., ap-southeast-2
MAIL_FROM_SUBDOMAIN="bounce"  # Subdomain for MAIL FROM (e.g., bounce)

# Function to get the HOSTED_ZONE_ID for the domain
get_hosted_zone_id() {
  local domain=$1
  
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${domain}." --query "HostedZones[0].Id" --output text)
  HOSTED_ZONE_ID=$(echo $HOSTED_ZONE_ID | sed 's|/hostedzone/||')  # Remove the /hostedzone/ prefix
  if [ -z "${HOSTED_ZONE_ID}" ]; then
    echo "Error: Could not find hosted zone for ${domain}."
    exit 1
  fi
  echo "Hosted Zone ID for ${domain}: ${HOSTED_ZONE_ID}"
}

# Function to add the verification token to Route 53
add_verification_token_to_route53() {
  local domain=$1
  local verification_token=$2

  echo "Adding verification token for ${domain} to Route 53 in hosted zone ${HOSTED_ZONE_ID}..."

  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch '{
    "Comment": "Add SES verification token for '${domain}'",
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_amazonses.'${domain}'",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [{
          "Value": "\"'${verification_token}'\""
        }]
      }
    }]
  }'

  if [ $? -ne 0 ]; then
    echo "Error: Failed to add the verification token for ${domain}."
    exit 1
  fi

  echo "Verification token added to Route 53."
}

# Function to set up custom MAIL FROM domain
setup_custom_mail_from() {
  local domain=$1
  local mail_from_domain=$2

  echo "Setting up Custom MAIL FROM domain (${mail_from_domain}) for ${domain}..."

  aws ses set-identity-mail-from-domain \
    --identity "${domain}" \
    --mail-from-domain "${mail_from_domain}" \
    --region "${SES_REGION}"

  echo "Custom MAIL FROM domain set for ${domain}."

  # Add MX and SPF records for the MAIL FROM domain
  echo "Adding MX and SPF records to Route 53 for ${mail_from_domain}..."

  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch '{
    "Comment": "Add MX and SPF records for custom MAIL FROM domain '${mail_from_domain}'",
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'${mail_from_domain}'",
          "Type": "MX",
          "TTL": 300,
          "ResourceRecords": [
            {"Value": "10 feedback-smtp.'${SES_REGION}'.amazonses.com"}
          ]
        }
      },
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'${mail_from_domain}'",
          "Type": "TXT",
          "TTL": 300,
          "ResourceRecords": [
            {"Value": "\"v=spf1 include:amazonses.com -all\""}
          ]
        }
      }
    ]
  }'

  if [ $? -ne 0 ]; then
    echo "Error: Failed to add MX and SPF records for ${mail_from_domain}."
    exit 1
  fi

  echo "MX and SPF records added for ${mail_from_domain}."
}

# Get the HOSTED_ZONE_ID for the base domain
get_hosted_zone_id "${BASE_DOMAIN}"

# Verify the domain in SES
aws ses verify-domain-identity --domain "${BASE_DOMAIN}" --region "${SES_REGION}"

# Get the verification token
VERIFICATION_TOKEN=$(aws ses get-identity-verification-attributes --identities "${BASE_DOMAIN}" --query "VerificationAttributes.\"${BASE_DOMAIN}\".VerificationToken" --output text --region "${SES_REGION}")

if [ -z "${VERIFICATION_TOKEN}" ]; then
  echo "Error: Could not retrieve verification token for ${BASE_DOMAIN}."
  exit 1
fi

echo "Verification token for ${BASE_DOMAIN}: ${VERIFICATION_TOKEN}"

# Add verification token to Route 53
add_verification_token_to_route53 "${BASE_DOMAIN}" "${VERIFICATION_TOKEN}"

# Set up custom MAIL FROM domain
CUSTOM_MAIL_FROM_DOMAIN="${MAIL_FROM_SUBDOMAIN}.${BASE_DOMAIN}"
setup_custom_mail_from "${BASE_DOMAIN}" "${CUSTOM_MAIL_FROM_DOMAIN}"

echo "Please wait for the DNS changes to propagate and check the SES console to confirm verification."

echo "Script completed."
