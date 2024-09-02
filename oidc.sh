aws eks describe-cluster --name <cluster-name> --query "cluster.identity.oidc.issuer" --output text

#https://oidc.eks.<region>.amazonaws.com/id/<eks-cluster-id>

aws iam list-open-id-connect-providers | grep <eks-cluster-id>
aws iam create-open-id-connect-provider \
  --url https://oidc.eks.<region>.amazonaws.com/id/<eks-cluster-id> \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list <thumbprint>
