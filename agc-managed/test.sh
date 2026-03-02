#!/usr/bin/env bash
set -euo pipefail

# Get both addresses
RG=$(terraform -chdir=terraform output -raw resource_group)
AKS=$(terraform -chdir=terraform output -raw aks_name)

echo "==> Fetching Gateway address..."
GW_ADDR=$(az aks command invoke -g "$RG" -n "$AKS" \
  --command "kubectl get gateway gateway -n test-app -o jsonpath='{.status.addresses[0].value}'" \
  --query logs -o tsv)

echo "==> Fetching Ingress address..."
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

echo ""
echo "Gateway API : $GW_ADDR"
echo "Ingress     : $INGRESS_ADDR"
echo ""

test_curl() {
  local label="$1"; shift
  printf "%-50s " "$label"
  local status
  status=$(curl -m 10 -s -o /dev/null -w "%{http_code}" "$@" 2>/dev/null) || status="TIMEOUT"
  echo "$status"
}

# --- DEMO 1: Gateway API (with WAF) ---
echo "--- Gateway API (WAF enabled) ---"
test_curl "Normal request"                          "http://$GW_ADDR/"
test_curl "WAF: BlockBadBots (User-Agent)"          -H "User-Agent: BadBot" "http://$GW_ADDR/"
test_curl "WAF: DRS 2.1 SQL injection"              "http://$GW_ADDR/?id=1'+OR+'1'%3D'1"
test_curl "WAF: BlockUriToken (URI contains blockme)" "http://$GW_ADDR/?demo=blockme"

echo ""

# --- DEMO 2: Ingress API (no WAF — AGC WAF only supports Gateway API) ---
echo "--- Ingress API (no WAF) ---"
test_curl "Normal request"                          "http://$INGRESS_ADDR/"

echo ""
echo "Expected: Gateway 200 normal / 403 WAF rules. Ingress 200 (WAF not supported)."