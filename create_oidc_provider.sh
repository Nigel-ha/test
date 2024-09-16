#!/bin/bash

# Variables
CLUSTER_NAME=$1
THUMBPRINT="9e99a48a9960b14926bb7f3b02e22da0cedef055"  # Use appropriate thumbprint for your OIDC provider

# Function to get the OIDC URL for the EKS cluster
get_oidc_url() {
    local cluster_name=$1
    echo "Fetching OIDC URL for EKS cluster: $cluster_name"

    # Use AWS CLI to describe the EKS cluster and get OIDC URL
    oidc_url=$(aws eks describe-cluster --name $cluster_name --query "cluster.identity.oidc.issuer" --output text)

    if [ -z "$oidc_url" ]; then
        echo "Error: Unable to fetch OIDC URL for EKS cluster $cluster_name"
        exit 1
    fi

    echo "OIDC URL: $oidc_url"
}

# Function to create the OIDC provider
create_oidc_provider() {
    local oidc_url=$1
    local thumbprint=$2

    echo "Creating OIDC provider with URL: $oidc_url and Thumbprint: $thumbprint"

    # Use AWS CLI to create the OIDC provider
    aws iam create-open-id-connect-provider \
        --url $oidc_url \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list $thumbprint

    if [ $? -eq 0 ]; then
        echo "OIDC provider created successfully!"
    else
        echo "Error: Failed to create OIDC provider"
        exit 1
    fi
}

# Main script execution
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: Cluster name is required"
    exit 1
fi

# Step 1: Get the OIDC URL
get_oidc_url $CLUSTER_NAME

# Step 2: Create OIDC provider
create_oidc_provider $oidc_url $THUMBPRINT
