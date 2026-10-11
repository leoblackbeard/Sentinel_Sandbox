#!/usr/bin/env bash
# Si el Service se creó antes de instalar el AWS Load Balancer Controller, no tiene
# spec.loadBalancerClass (lo pone el webhook del controller y es inmutable) y se
# queda en <pending>. Lo borramos para que el siguiente apply lo cree bien.
# Uso: recreate-orphan-svc.sh <namespace> <service>
set -euo pipefail

NS="$1"
SVC="$2"

if ! kubectl get svc "$SVC" -n "$NS" >/dev/null 2>&1; then
  echo "$NS/$SVC no existe todavía; nada que hacer."
  exit 0
fi

CLASS=$(kubectl get svc "$SVC" -n "$NS" -o jsonpath='{.spec.loadBalancerClass}')
if [ -z "$CLASS" ]; then
  echo "$NS/$SVC sin loadBalancerClass: se borra para recrearlo con el controller."
  kubectl delete svc "$SVC" -n "$NS" --wait=true
else
  echo "$NS/$SVC ya gestionado por $CLASS."
fi
