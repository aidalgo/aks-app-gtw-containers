#!/usr/bin/env bash
# deploy.sh — apply k8s manifests to the private AKS cluster via az aks command invoke.
# Run from the repository root: ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

echo "==> Reading Terraform outputs..."
RG=$(terraform -chdir="$TF_DIR" output -raw resource_group)
AKS=$(terraform -chdir="$TF_DIR" output -raw aks_name)
AGC_SUBNET_ID=$(terraform -chdir="$TF_DIR" output -raw agc_subnet_id)
WAF_POLICY_ID=$(terraform -chdir="$TF_DIR" output -raw waf_policy_id)
NODE_RG=$(terraform -chdir="$TF_DIR" output -raw aks_node_resource_group)

echo "    Resource group   : $RG"
echo "    AKS cluster      : $AKS"
echo "    AGC subnet ID    : $AGC_SUBNET_ID"
echo "    WAF policy ID    : $WAF_POLICY_ID"
echo "    Node RG          : $NODE_RG"

# aks_apply FILE
# Uploads a manifest and applies it. az aks command invoke places uploaded
# files in the command working directory, so reference by filename only.
aks_apply() {
  local file="$1"
  local filename
  filename="$(basename "$file")"
  az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "kubectl apply -f $filename" \
    --file "$file"
}

# aks_cmd CMD
# Runs an arbitrary kubectl command – no file upload needed.
aks_cmd() {
  az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "$1"
}

echo ""
echo "========================================"
echo " DEMO 1 — Gateway API"
echo "========================================"

echo ""
echo "==> Generating test-app-gateway.yaml with AGC subnet ID..."
GENERATED_GATEWAY="$SCRIPT_DIR/k8s/.test-app-gateway-generated.yaml"
sed "s|__AGC_SUBNET_ID__|$AGC_SUBNET_ID|g" "$SCRIPT_DIR/k8s/test-app-gateway.yaml" > "$GENERATED_GATEWAY"

echo "==> Deploying test-app-gateway (namespace, deployment, service, ALB CR, Gateway, HTTPRoute)..."
aks_apply "$GENERATED_GATEWAY"

echo ""
echo "==> Waiting for ApplicationLoadBalancer to become ready (up to 3 min)..."
aks_cmd "kubectl wait applicationloadbalancer/alb -n test-app --for=condition=Accepted --timeout=180s"

echo ""
echo "==> Removing legacy manual SecurityPolicy (if present) to avoid duplicate WAF references..."
TC_ID=$(az resource list \
  --resource-group "$NODE_RG" \
  --resource-type "Microsoft.ServiceNetworking/trafficControllers" \
  --query "[0].id" -o tsv)
echo "    Traffic controller : $TC_ID"
az rest --method DELETE \
  --url "https://management.azure.com${TC_ID}/securityPolicies/waf?api-version=2025-01-01" \
  --output none >/dev/null 2>&1 || true
echo "    Cleanup complete."

echo ""
echo "==> Applying WebApplicationFirewallPolicy CR..."
GENERATED_WAF="$SCRIPT_DIR/k8s/.waf-policy-generated.yaml"
sed "s|__WAF_POLICY_ID__|$WAF_POLICY_ID|g" "$SCRIPT_DIR/k8s/waf-policy.yaml" > "$GENERATED_WAF"
aks_apply "$GENERATED_WAF"

echo ""
echo "==> Waiting for the Gateway to be assigned an address (up to 3 min)..."
aks_cmd "kubectl wait gateway/gateway -n test-app --for=condition=Programmed --timeout=180s"

echo ""
echo "==> Fetching the public address..."
aks_cmd "kubectl get gateway gateway -n test-app -o jsonpath='{.status.addresses[0].value}'"

echo ""
echo "Done. The address is printed above — test with:"
echo "  Normal request : curl http://<address>/"
echo "  WAF block      : curl -H 'User-Agent: BadBot' http://<address>/  (expect HTTP 403)"
echo "  WAF block      : curl 'http://<address>/?demo=blockme'          (expect HTTP 403)"

echo ""
echo "========================================"
echo " DEMO 2 — Ingress API"
echo "========================================"

echo ""
echo "==> Generating test-app-ingress.yaml with AGC subnet ID..."
GENERATED_INGRESS="$SCRIPT_DIR/k8s/.test-app-ingress-generated.yaml"
sed "s|__AGC_SUBNET_ID__|$AGC_SUBNET_ID|g" "$SCRIPT_DIR/k8s/test-app-ingress.yaml" > "$GENERATED_INGRESS"

echo "==> Deploying test-app-ingress (namespace, deployment, service, Ingress)..."
aks_apply "$GENERATED_INGRESS"

echo ""
echo "==> Waiting for Ingress to be assigned an address (up to 3 min)..."
for i in $(seq 1 18); do
  INGRESS_ADDR=$(az aks command invoke \
    --resource-group "$RG" --name "$AKS" \
    --command "kubectl get ingress echo-ingress -n test-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'" \
    --query logs -o tsv 2>/dev/null || true)
  if [[ -n "$INGRESS_ADDR" && "$INGRESS_ADDR" != "None" ]]; then
    break
  fi
  echo "    Waiting... (${i}/18)"
  sleep 10
done

echo ""
echo "==> Fetching the Ingress public address..."
aks_cmd "kubectl get ingress echo-ingress -n test-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"

echo ""
echo "Done. The Ingress address is printed above — test with:  curl http://<address printed above>/"
