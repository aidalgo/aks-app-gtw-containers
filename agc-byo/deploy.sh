#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

echo "==> Reading BYO Terraform outputs..."
AKS_RG=$(terraform -chdir="$TF_DIR" output -raw resource_group)
AKS_NAME=$(terraform -chdir="$TF_DIR" output -raw aks_name)
ALB_ID=$(terraform -chdir="$TF_DIR" output -raw alb_id)
FRONTEND_NAME=$(terraform -chdir="$TF_DIR" output -raw frontend_name)
WAF_POLICY_ID=$(terraform -chdir="$TF_DIR" output -raw waf_policy_id)
ALB_NAME="${ALB_ID##*/}"

echo "    AKS resource group : $AKS_RG"
echo "    AKS name           : $AKS_NAME"
echo "    ALB id             : $ALB_ID"
echo "    ALB name           : $ALB_NAME"
echo "    Frontend name      : $FRONTEND_NAME"
echo "    WAF policy id      : $WAF_POLICY_ID"

aks_apply() {
  local file="$1"
  local filename
  filename="$(basename "$file")"
  az aks command invoke \
    --resource-group "$AKS_RG" \
    --name "$AKS_NAME" \
    --command "kubectl apply -f $filename" \
    --file "$file"
}

aks_cmd() {
  az aks command invoke \
    --resource-group "$AKS_RG" \
    --name "$AKS_NAME" \
    --command "$1"
}

echo ""
echo "========================================"
echo " BYO DEMO 1 — Gateway API"
echo "========================================"

echo ""
echo "==> Generating Gateway BYO manifest..."
GW_FILE="$SCRIPT_DIR/k8s/.test-app-gateway-byo-generated.yaml"
sed -e "s|__ALB_ID__|$ALB_ID|g" \
    -e "s|__FRONTEND_NAME__|$FRONTEND_NAME|g" \
    "$SCRIPT_DIR/k8s/test-app-gateway-byo.yaml" > "$GW_FILE"

echo "==> Applying Gateway BYO resources..."
aks_apply "$GW_FILE"

echo ""
echo "==> Waiting for Gateway programming..."
aks_cmd "kubectl wait gateway/gateway -n test-app-byo --for=condition=Programmed --timeout=240s"

echo ""
echo "==> Gateway address:"
aks_cmd "kubectl get gateway gateway -n test-app-byo -o jsonpath='{.status.addresses[0].value}'"

echo ""
echo "========================================"
echo " BYO DEMO 2 — Ingress API"
echo "========================================"

echo ""
echo "==> Generating Ingress BYO manifest..."
ING_FILE="$SCRIPT_DIR/k8s/.test-app-ingress-byo-generated.yaml"
sed -e "s|__ALB_ID__|$ALB_ID|g" "$SCRIPT_DIR/k8s/test-app-ingress-byo.yaml" > "$ING_FILE"

echo "==> Applying Ingress BYO resources..."
aks_apply "$ING_FILE"

echo ""
echo "==> Waiting for Ingress address..."
for i in $(seq 1 24); do
  INGRESS_ADDR=$(az aks command invoke \
    --resource-group "$AKS_RG" \
    --name "$AKS_NAME" \
    --command "kubectl get ingress echo-ingress -n test-app-ingress-byo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'" \
    --query logs -o tsv 2>/dev/null || true)
  if [[ -n "$INGRESS_ADDR" && "$INGRESS_ADDR" != "None" ]]; then
    break
  fi
  echo "    Waiting... (${i}/24)"
  sleep 10
done

echo ""
echo "==> Ingress address:"
aks_cmd "kubectl get ingress echo-ingress -n test-app-ingress-byo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"

echo ""
echo "========================================"
echo " WAF — Gateway API"
echo "========================================"

echo ""
echo "==> Ensuring ALB CLI extension is installed..."
if ! az extension show --name alb >/dev/null 2>&1; then
  az extension add --name alb >/dev/null
fi

echo "==> Ensuring AGC WAF security policy exists..."
if ! az network alb security-policy show -g "$AKS_RG" --alb-name "$ALB_NAME" -n waf >/dev/null 2>&1; then
  az network alb security-policy waf create \
    -g "$AKS_RG" \
    --alb-name "$ALB_NAME" \
    -n waf \
    --waf-policy-id "$WAF_POLICY_ID" >/dev/null
fi

echo ""
echo "==> Generating WAF policy manifest..."
WAF_FILE="$SCRIPT_DIR/k8s/.waf-policy-generated.yaml"
sed "s|__WAF_POLICY_ID__|$WAF_POLICY_ID|g" "$SCRIPT_DIR/k8s/waf-policy.yaml" > "$WAF_FILE"

echo "==> Applying WebApplicationFirewallPolicy CR (Gateway HTTPRoute)..."
aks_apply "$WAF_FILE"

echo ""
echo "==> Waiting for WAF to propagate (90 s)..."
sleep 90

echo ""
echo "Done. BYO scenario deployed."
echo "Test Gateway WAF: curl -H 'User-Agent: BadBot' http://<gateway address>/  (expect HTTP 403)"
echo "Test Ingress:     curl http://<ingress address>/"
