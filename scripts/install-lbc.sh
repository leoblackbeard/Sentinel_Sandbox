#!/usr/bin/env bash
# Instala/actualiza el AWS Load Balancer Controller en el cluster del kubeconfig actual.
# Uso: install-lbc.sh <cluster-name> <vpc-id> <region>
set -euo pipefail

CLUSTER="$1"
VPC_ID="$2"
REGION="$3"

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null

# Credenciales vía EKS Pod Identity (asociación creada por Terraform para
# kube-system/aws-load-balancer-controller). vpcId y region explícitos para no
# depender de IMDS, que en AL2023 no es alcanzable desde los pods (hop limit 1).
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  ${LBC_CHART_VERSION:+--version "$LBC_CHART_VERSION"} \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m

# El webhook del controller debe estar listo antes de crear Services.
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s
