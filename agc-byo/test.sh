#!/usr/bin/env bash
set -euo pipefail

# Get both addresses
RG=$(terraform -chdir=terraform output -raw resource_group)
AKS=$(terraform -chdir=terraform output -raw aks_name)

GW_ADDR=$(az aks command invoke -g "$RG" -n "$AKS" \
	--command "kubectl get gateway gateway -n test-app-byo -o jsonpath='{.status.addresses[0].value}'" \
	--query logs -o tsv)

INGRESS_ADDR=""
for i in $(seq 1 24); do
	INGRESS_ADDR=$(az aks command invoke -g "$RG" -n "$AKS" \
		--command "kubectl get ingress echo-ingress -n test-app-ingress-byo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'" \
		--query logs -o tsv 2>/dev/null || true)
	if [[ -n "$INGRESS_ADDR" && "$INGRESS_ADDR" != "None" ]]; then
		break
	fi
	sleep 5
done

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

# WAF custom rule — User-Agent block (WAF targets the Ingress resource directly)
curl -si -H "User-Agent: BadBot" http://$INGRESS_ADDR/ | head -1

# WAF managed rule — SQL injection
curl -si "http://$INGRESS_ADDR/?id=1'+OR+'1'%3D'1" | head -1