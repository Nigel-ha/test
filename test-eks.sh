#!/bin/bash

# Check if the correct number of arguments are passed
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <cluster-name>"
    exit 1
fi

# Set variables
CLUSTER_NAME="$1"  # Take the cluster name as a parameter
REGION="${AWS_REGION}"  # Use the REGION from the environment variable
KUBECONFIG_PATH="$HOME/.kube/config"

# Check if REGION environment variable is set
if [ -z "$REGION" ]; then
    echo "Error: AWS_REGION environment variable is not set."
    exit 1
fi

# Step 1: Update kubeconfig to connect to your EKS cluster
echo "Updating kubeconfig for cluster: $CLUSTER_NAME in region: $REGION..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$KUBECONFIG_PATH"

if [ $? -ne 0 ]; then
    echo "Error: Failed to update kubeconfig. Ensure the EKS cluster exists and your AWS CLI is configured correctly."
    exit 1
fi

# Step 2: Perform a basic test task - check if nodes are ready
echo "Checking cluster nodes status..."
kubectl get nodes

if [ $? -ne 0 ]; then
    echo "Error: Failed to connect to the EKS cluster or retrieve node information. Check your kubeconfig and cluster status."
    exit 1
fi

# Optional Step 3: Verify that core Kubernetes components are running (e.g., kube-system pods)
echo "Checking kube-system pods status..."
kubectl get pods -n kube-system

if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve kube-system pods. The cluster may not be set up correctly."
    exit 1
fi

echo "EKS cluster '$CLUSTER_NAME' is accessible and appears to be set up correctly."

# Optional Step 4: Run a basic test deployment to ensure the cluster can handle workloads
echo "Running a basic test deployment..."
kubectl apply -f https://k8s.io/examples/application/deployment.yaml

if [ $? -ne 0 ]; then
    echo "Error: Failed to apply the test deployment. The cluster may not be functioning correctly."
    exit 1
fi

# Verify the test deployment
echo "Verifying the test deployment..."
kubectl rollout status deployment/nginx-deployment

if [ $? -ne 0 ]; then
    echo "Error: Test deployment did not roll out successfully."
    exit 1
fi

echo "Test deployment rolled out successfully. EKS cluster '$CLUSTER_NAME' is working as expected."
