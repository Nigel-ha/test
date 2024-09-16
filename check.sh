CLUSTER_NAME=$1
kubectl config set-credentials eks-user --token=$(aws eks get-token --cluster-name $CLUSTER_NAME --query 'status.token' --output text)

kubectl get serviceaccount -n kube-system coredns -o yaml
aws iam list-open-id-connect-providers
