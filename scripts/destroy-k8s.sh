#!/usr/bin/env bash
# Borra los workloads y espera a que el AWS LB Controller elimine los NLBs y sus
# security groups. Debe correr ANTES de terraform destroy: el controller tiene
# que seguir vivo para quitar los finalizers y limpiar lo que creó en AWS.
set -uo pipefail

REGION="${AWS_REGION:-eu-central-1}"

delete_ns() {
  local cluster="$1" ns="$2"
  if ! aws eks describe-cluster --name "$cluster" --region "$REGION" >/dev/null 2>&1; then
    echo "Cluster $cluster no existe; nada que borrar."
    return 0
  fi
  aws eks update-kubeconfig --name "$cluster" --region "$REGION" >/dev/null
  echo "Borrando namespace $ns en $cluster..."
  kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=10m
}

wait_nlb_gone() {
  local name="$1"
  for i in $(seq 1 40); do
    if ! aws elbv2 describe-load-balancers --names "$name" >/dev/null 2>&1; then
      echo "$name eliminado."
      return 0
    fi
    echo "[$i/40] esperando a que se elimine $name..."
    sleep 15
  done
  echo "::error::$name sigue existiendo tras 10 minutos"
  return 1
}

# Primero el gateway (depende del backend), luego el backend.
delete_ns eks-gateway sentinel-gateway
delete_ns eks-backend sentinel-backend

STATUS=0
wait_nlb_gone sentinel-gateway-nlb || STATUS=1
wait_nlb_gone sentinel-backend-nlb || STATUS=1

# Security groups que el controller crea para los NLBs (prefijo k8s-). Normalmente
# los borra él mismo; esto es una red de seguridad para que la VPC se pueda borrar.
# Las interfaces de red del NLB tardan unos minutos en liberarse: se reintenta.
for SG in $(aws ec2 describe-security-groups \
    --filters "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query 'SecurityGroups[].GroupId' --output text); do
  for i in $(seq 1 20); do
    if aws ec2 delete-security-group --group-id "$SG" 2>/dev/null; then
      echo "Security group residual $SG borrado."
      break
    fi
    echo "[$i/20] $SG todavía en uso, reintentando..."
    sleep 15
  done
done

exit $STATUS
