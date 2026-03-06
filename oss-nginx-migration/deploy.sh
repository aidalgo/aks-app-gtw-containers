#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

echo "==> Reading Terraform outputs..."
RG=$(terraform -chdir="$TF_DIR" output -raw resource_group)
AKS=$(terraform -chdir="$TF_DIR" output -raw aks_name)

echo "    Resource group : $RG"
echo "    AKS cluster    : $AKS"

aks_apply() {
  local file="$1"
  local filename
  filename="$(basename "$file")"
  local output
  output=$(az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "kubectl apply -f $filename" \
    --file "$file" 2>&1 || true)

  echo "$output"
  if ! grep -q "exitcode=0" <<< "$output"; then
    return 1
  fi
}

aks_cmd() {
  local output
  output=$(az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "$1" 2>&1 || true)

  echo "$output"
  if ! grep -q "exitcode=0" <<< "$output"; then
    return 1
  fi
}

echo ""
echo "==> Rendering ingress-nginx chart manifest with Helm..."
GENERATED_NGINX="$SCRIPT_DIR/k8s/.ingress-nginx-generated.yaml"
helm template ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClass=nginx \
  --set controller.ingressClassResource.default=true \
  > "$GENERATED_NGINX"

echo "==> Ensuring ingress-nginx namespace exists..."
aks_cmd "kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -"

echo "==> Installing or upgrading ingress-nginx on AKS..."
aks_apply "$GENERATED_NGINX"

echo "==> Waiting for ingress-nginx controller rollout (up to 6 min)..."
aks_cmd "kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=360s"

echo ""
echo "==> Deploying test workloads..."
aks_apply "$SCRIPT_DIR/k8s/test-app.yaml"

echo "==> Waiting for test workloads rollout (up to 3 min)..."
aks_cmd "kubectl -n test-app-nginx rollout status deployment/echo-web --timeout=180s"
aks_cmd "kubectl -n test-app-nginx rollout status deployment/echo-api --timeout=180s"

echo "==> Deploying optional canary backend workload..."
aks_apply "$SCRIPT_DIR/k8s/test-app-canary-deployment.yaml"
aks_apply "$SCRIPT_DIR/k8s/test-app-canary-service.yaml"
aks_cmd "kubectl -n test-app-nginx rollout status deployment/echo-canary --timeout=180s"

echo ""
echo "==> Deploying primary path-based ingress..."
aks_apply "$SCRIPT_DIR/k8s/test-app-ingress.yaml"

echo "==> Deploying optional rewrite ingress..."
aks_apply "$SCRIPT_DIR/k8s/test-app-ingress-rewrite.yaml"

echo "==> Deploying optional app-root ingress..."
aks_apply "$SCRIPT_DIR/k8s/test-app-ingress-app-root.yaml"

echo "==> Deploying optional permanent-redirect ingress..."
aks_apply "$SCRIPT_DIR/k8s/test-app-ingress-permanent-redirect.yaml"

echo "==> Deploying optional canary ingress..."
aks_apply "$SCRIPT_DIR/k8s/test-app-ingress-canary.yaml"

echo ""
echo "==> Waiting for NGINX external address (up to 6 min)..."
for i in $(seq 1 36); do
  NGINX_ADDR=$(az aks command invoke \
    --resource-group "$RG" --name "$AKS" \
    --command "kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'" \
    --query logs -o tsv 2>/dev/null || true)
  if [[ -n "$NGINX_ADDR" && "$NGINX_ADDR" != "None" ]]; then
    break
  fi
  echo "    Waiting... (${i}/36)"
  sleep 10
done

echo ""
echo "==> Current ingress resources:"
aks_cmd "kubectl get ingress -n test-app-nginx"

echo ""
echo "==> NGINX external address:"
aks_cmd "kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"

echo ""
echo "Done. Validate with:"
echo "  ./test.sh"
