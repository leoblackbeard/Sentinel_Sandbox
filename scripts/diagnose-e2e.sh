#!/usr/bin/env bash
# Diagnóstico del camino end-to-end. Nunca hace fallar el job por sí mismo.
# Variables: AWS_REGION; opcionales GATEWAY_CLUSTER (default eks-gateway) y
# BACKEND_ENDPOINT (si falta, se toma del NLB interno).
set -uo pipefail

GATEWAY_CLUSTER="${GATEWAY_CLUSTER:-eks-gateway}"

nlb_arn() {
  aws elbv2 describe-load-balancers --names "$1" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null
}

for LB in sentinel-gateway-nlb sentinel-backend-nlb; do
  echo "================ $LB ================"
  LB_ARN=$(nlb_arn "$LB")
  if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ]; then
    echo "No existe"; continue
  fi

  aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
    --query 'LoadBalancers[0].{Scheme:Scheme,State:State.Code,DNS:DNSName,SecurityGroups:SecurityGroups,Subnets:AvailabilityZones[].{AZ:ZoneName,Subnet:SubnetId}}' \
    --output yaml

  echo "--- Listeners"
  aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
    --query 'Listeners[].{Port:Port,Protocol:Protocol}' --output table

  echo "--- Atributos relevantes"
  aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$LB_ARN" \
    --query "Attributes[?contains(Key,'cross_zone') || contains(Key,'enforce_security_group')]" --output table

  for TG in $(aws elbv2 describe-target-groups --load-balancer-arn "$LB_ARN" \
      --query 'TargetGroups[].TargetGroupArn' --output text); do
    echo "--- Target health"
    aws elbv2 describe-target-health --target-group-arn "$TG" \
      --query 'TargetHealthDescriptions[].{IP:Target.Id,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
      --output table
  done

  echo "--- Reglas de entrada de los security groups del NLB"
  for SG in $(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
      --query 'LoadBalancers[0].SecurityGroups[]' --output text); do
    echo "SG $SG"
    aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG" \
      --query 'SecurityGroupRules[?IsEgress==`false`].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SrcSG:ReferencedGroupInfo.GroupId,Desc:Description}' \
      --output table
  done

  echo "--- Ruta por defecto de cada subnet del NLB"
  for SUBNET in $(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" \
      --query 'LoadBalancers[0].AvailabilityZones[].SubnetId' --output text); do
    NAME=$(aws ec2 describe-subnets --subnet-ids "$SUBNET" \
      --query "Subnets[0].Tags[?Key=='Name'].Value | [0]" --output text)
    ROUTE=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0].[GatewayId,NatGatewayId]" --output text)
    echo "$SUBNET ($NAME) -> 0.0.0.0/0 via: $ROUTE"
  done
done

echo "================ Subnets públicas etiquetadas en la VPC gateway ================"
aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/role/elb,Values=1" "Name=tag:Tier,Values=gateway" \
  --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table

if [ -z "${BACKEND_ENDPOINT:-}" ]; then
  BACKEND_ENDPOINT=$(aws elbv2 describe-load-balancers --names sentinel-backend-nlb \
    --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
fi
PUBLIC_ENDPOINT=$(aws elbv2 describe-load-balancers --names sentinel-gateway-nlb \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)

echo "================ Desde un pod nginx ================"
aws eks update-kubeconfig --name "$GATEWAY_CLUSTER" --region "$AWS_REGION" >/dev/null
kubectl -n sentinel-gateway get pods -o wide
echo "--- nginx -> NLB interno del backend ($BACKEND_ENDPOINT:8080)"
kubectl -n sentinel-gateway exec deploy/proxy -- wget -qO- -T 5 "http://$BACKEND_ENDPOINT:8080" || echo "FALLA el tramo peering/backend"
echo "--- nginx local (puerto 80 dentro del pod)"
kubectl -n sentinel-gateway exec deploy/proxy -- wget -qO- -T 5 "http://127.0.0.1" || echo "FALLA nginx -> backend"
echo "--- pod -> NLB público por internet (sale por el NAT, entra como cliente externo)"
kubectl -n sentinel-gateway exec deploy/proxy -- wget -qO- -T 5 "http://$PUBLIC_ENDPOINT" || echo "FALLA la entrada por el NLB público"

echo "================ Service del gateway y logs del controller ================"
kubectl -n sentinel-gateway get svc proxy-nlb -o jsonpath='{.spec.loadBalancerClass}{"\n"}{.metadata.annotations}{"\n"}'
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=200 \
  | grep -iE 'error|subnet|proxy-nlb' | tail -25 || true
exit 0
