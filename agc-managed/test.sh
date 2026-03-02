#!/usr/bin/env bash
set -euo pipefail

# Get both addresses
RG=$(terraform -chdir=terraform output -raw resource_group)
AKS=$(terraform -chdir=terraform output -raw aks_name)

GW_ADDR=$(az aks command invoke -g "$RG" -n "$AKS" \
  --command "kubectl get gateway gateway -n test-app -o jsonpath='{.status.addresses[0].value}'" \
  --query logs -o tsv)

INGRESS_ADDR=$(az aks command invoke -g "$RG" -n "$AKS" \
  --command "kubectl get ingress echo-ingress -n test-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" \
  --query logs -o tsv)

if [[ -z "$GW_ADDR" || "$GW_ADDR" == "None" ]]; then
  echo "Gateway address is empty. Ensure test-app Gateway is Programmed first."
  exit 1
fi

if [[ -z "$INGRESS_ADDR" || "$INGRESS_ADDR" == "None" ]]; then
  echo "Ingress address is empty. Ensure test-app-ingress Ingress has a hostname first."
  exit 1
fi

echo "Gateway API : $GW_ADDR"
echo "Ingress     : $INGRESS_ADDR"

# --- DEMO 1: Gateway API ---

# Normal request
curl -si http://$GW_ADDR/ | head -1

# WAF custom rule — User-Agent block
curl -si -H "User-Agent: BadBot" http://$GW_ADDR/ | head -1

# WAF managed rule — SQL injection
curl -si "http://$GW_ADDR/?id=1'+OR+'1'%3D'1" | head -1


# --- DEMO 2: Ingress API ---

# Normal request
curl -si http://$INGRESS_ADDR/ | head -1

# WAF custom rule — User-Agent block (WAF is on the traffic controller, applies to all frontends)
curl -si -H "User-Agent: BadBot" http://$INGRESS_ADDR/ | head -1

# WAF managed rule — SQL injection
curl -si "http://$INGRESS_ADDR/?id=1'+OR+'1'%3D'1" | head -1