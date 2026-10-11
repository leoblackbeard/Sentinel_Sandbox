#!/usr/bin/env bash
# Diagnóstico cuando validate-e2e falla. Nunca hace fallar el job por sí mismo.
# Variables: AWS_REGION, GATEWAY_CLUSTER, BACKEND_ENDPOINT
set -uo pipefail

for LB in sentinel-gateway-nlb sentinel-backend-nlb; do
  echo "================ $LB ================"
  LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
  if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
    echo "No existe"; continue
  fi
  aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
    --query 'LoadBalancers[0].{Scheme:Scheme,State:State.Code,AZs:AvailabilityZones[].ZoneName}' --output yaml
  for TG in $(aws elbv2 describe-target-groups --load-balancer-arn "$LB_ARN" \
      --query 'TargetGroups[].TargetGroupArn' --output text); do
    echo "--- Target health ($TG)"
    aws elbv2 describe-target-health --target-group-arn "$TG" \
      --query 'TargetHealthDescriptions[].{IP:Target.Id,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
      --output table
  done
done

echo "================ Tramo gateway -> backend (desde un pod nginx) ================"
aws eks update-kubeconfig --name "$GATEWAY_CLUSTER" --region "$AWS_REGION" >/dev/null
kubectl -n sentinel-gateway get pods -o wide
echo "--- nginx -> NLB interno del backend ($BACKEND_ENDPOINT:8080)"
kubectl -n sentinel-gateway exec deploy/proxy -- wget -qO- -T 5 "http://$BACKEND_ENDPOINT:8080" || echo "FALLA el tramo peering/backend"
echo "--- nginx local (puerto 80 dentro del pod)"
kubectl -n sentinel-gateway exec deploy/proxy -- wget -qO- -T 5 "http://127.0.0.1" || echo "FALLA nginx -> backend"
exit 0
