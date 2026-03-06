#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

RG=$(terraform -chdir="$TF_DIR" output -raw resource_group)
AKS=$(terraform -chdir="$TF_DIR" output -raw aks_name)

aks_cmd_capture() {
  local command="$1"
  local output
  output=$(az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "$command" 2>&1 || true)

  if ! grep -q "exitcode=0" <<< "$output"; then
    echo "$output"
    return 1
  fi

  echo "$output"
}

assert_cmd() {
  local label="$1"
  local command="$2"

  printf "%-50s " "$label"

  if ! aks_cmd_capture "$command" >/dev/null; then
    echo "FAIL"
    return 1
  fi

  echo "OK"
}

assert_jsonpath_equals() {
  local label="$1"
  local command="$2"
  local expected="$3"

  printf "%-50s " "$label"

  local output
  output=$(aks_cmd_capture "$command") || {
    echo "FAIL"
    return 1
  }

  local actual
  actual=$(echo "$output" | tail -n 1 | tr -d '\r')

  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL (expected '$expected', got '$actual')"
    return 1
  fi

  echo "OK"
}

assert_jsonpath_nonempty() {
  local label="$1"
  local command="$2"

  printf "%-50s " "$label"

  local output
  output=$(aks_cmd_capture "$command") || {
    echo "FAIL"
    return 1
  }

  local actual
  actual=$(echo "$output" | tail -n 1 | tr -d '\r')

  if [[ -z "$actual" || "$actual" == "None" ]]; then
    echo "FAIL (empty)"
    return 1
  fi

  echo "OK"
}

echo "==> Validating NGINX ingress sample manifests..."

echo ""
echo "--- Workload readiness ---"
assert_cmd "Deployment available: echo-web" "kubectl -n test-app-nginx wait --for=condition=available deployment/echo-web --timeout=120s"
assert_cmd "Deployment available: echo-api" "kubectl -n test-app-nginx wait --for=condition=available deployment/echo-api --timeout=120s"
assert_cmd "Deployment available: echo-canary" "kubectl -n test-app-nginx wait --for=condition=available deployment/echo-canary --timeout=120s"

echo ""
echo "--- Ingress resources present ---"
assert_cmd "Ingress exists: echo-ingress" "kubectl -n test-app-nginx get ingress echo-ingress"
assert_cmd "Ingress exists: echo-ingress-rewrite" "kubectl -n test-app-nginx get ingress echo-ingress-rewrite"
assert_cmd "Ingress exists: echo-ingress-app-root" "kubectl -n test-app-nginx get ingress echo-ingress-app-root"
assert_cmd "Ingress exists: echo-ingress-permanent-redirect" "kubectl -n test-app-nginx get ingress echo-ingress-permanent-redirect"
assert_cmd "Ingress exists: echo-ingress-canary" "kubectl -n test-app-nginx get ingress echo-ingress-canary"

echo ""
echo "--- Ingress wiring checks ---"
assert_jsonpath_equals "App-root host is app-root.local" "kubectl -n test-app-nginx get ingress echo-ingress-app-root -o jsonpath='{.spec.rules[0].host}'" "app-root.local"
assert_jsonpath_equals "Canary annotation enabled" "kubectl -n test-app-nginx get ingress echo-ingress-canary -o jsonpath='{.metadata.annotations.nginx\\.ingress\\.kubernetes\\.io/canary}'" "true"
assert_jsonpath_equals "Canary weight is 20" "kubectl -n test-app-nginx get ingress echo-ingress-canary -o jsonpath='{.metadata.annotations.nginx\\.ingress\\.kubernetes\\.io/canary-weight}'" "20"

echo ""
echo "--- Ingress address assignment ---"
assert_jsonpath_nonempty "Address assigned: echo-ingress" "kubectl -n test-app-nginx get ingress echo-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"
assert_jsonpath_nonempty "Address assigned: echo-ingress-rewrite" "kubectl -n test-app-nginx get ingress echo-ingress-rewrite -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"
assert_jsonpath_nonempty "Address assigned: echo-ingress-app-root" "kubectl -n test-app-nginx get ingress echo-ingress-app-root -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"
assert_jsonpath_nonempty "Address assigned: echo-ingress-permanent-redirect" "kubectl -n test-app-nginx get ingress echo-ingress-permanent-redirect -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"
assert_jsonpath_nonempty "Address assigned: echo-ingress-canary" "kubectl -n test-app-nginx get ingress echo-ingress-canary -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}'"

echo ""
echo "Ingress sample manifest checks completed successfully (resource-level validation)."
