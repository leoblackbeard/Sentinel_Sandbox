#!/usr/bin/env bash
# Espera a que un Service LoadBalancer tenga hostname y lo escribe en $GITHUB_OUTPUT.
# Uso: wait-lb.sh <namespace> <service> [intentos]
set -euo pipefail

NS="$1"
SVC="$2"
TRIES="${3:-40}"

for i in $(seq 1 "$TRIES"); do
  HOST=$(kubectl get svc "$SVC" -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  if [ -n "$HOST" ]; then
    echo "endpoint=$HOST" >> "$GITHUB_OUTPUT"
    echo "$NS/$SVC -> $HOST"
    exit 0
  fi
  echo "[$i/$TRIES] $NS/$SVC sin hostname todavía"
  sleep 15
done

echo "::error::Timeout esperando el NLB de $NS/$SVC"
echo "--- Service ---"
kubectl describe svc "$SVC" -n "$NS" || true
echo "--- Últimos logs del AWS Load Balancer Controller ---"
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=50 || true
exit 1
