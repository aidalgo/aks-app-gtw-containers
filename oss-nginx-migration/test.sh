#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

RG=$(terraform -chdir="$TF_DIR" output -raw resource_group)
AKS=$(terraform -chdir="$TF_DIR" output -raw aks_name)

echo "==> Fetching NGINX ingress address..."
ADDR=$(az aks command invoke -g "$RG" -n "$AKS" \
  --command "kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'" \
  --query logs -o tsv)

if [[ -z "$ADDR" || "$ADDR" == "None" ]]; then
  echo "NGINX ingress address is empty. Run ./deploy.sh first and wait for LB provisioning."
  exit 1
fi

echo ""
echo "Ingress address: $ADDR"
echo ""

test_curl() {
  local label="$1"
  local path="$2"
  local expected="$3"

  printf "%-45s " "$label"
  local status
  status=$(curl -m 10 -s -o /tmp/nginx-test-body-$$.txt -w "%{http_code}" "http://$ADDR$path" 2>/dev/null) || status="TIMEOUT"

  if [[ "$status" != "$expected" ]]; then
    echo "$status (expected $expected)"
    rm -f /tmp/nginx-test-body-$$.txt
    return 1
  fi

  cat /tmp/nginx-test-body-$$.txt
  rm -f /tmp/nginx-test-body-$$.txt
}

echo "--- NGINX Ingress checks ---"
test_curl "Root path (/)" "/" "200"
test_curl "API path (/api)" "/api" "200"
test_curl "Rewrite path (/rewrite/hello)" "/rewrite/hello" "200"

echo ""
echo "Expected response bodies include: web-ok (/) and rewrite, api-ok (/api)."
