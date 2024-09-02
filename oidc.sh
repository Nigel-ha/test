aws eks describe-cluster --name <cluster-name> --query "cluster.identity.oidc.issuer" --output text
