# Add-on Managed AGC Scenario

This scenario demonstrates **AKS add-on managed** Application Gateway for Containers (AGC).

In managed mode the ALB controller running inside AKS owns the full lifecycle of AGC resources. You declare an `ApplicationLoadBalancer` custom resource pointing at a delegated subnet and the controller creates the underlying traffic controller, frontend, and association automatically.

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│  Azure Resource Group (rg-agc-demo-XXXX)                        │
│                                                                 │
│  ┌──────────────────────┐   ┌──────────────────────────────┐    │
│  │ VNet 10.0.0.0/8      │   │ WAF Policy (Prevention)      │    │
│  │  ├─ AKS subnet       │   │  • DRS 2.1                   │    │
│  │  │  10.240.0.0/16    │   │  • BlockBadBots (User-Agent) │    │
│  │  └─ AGC subnet       │   │  • BlockUriToken (URI)       │    │
│  │     10.241.0.0/24    │   └──────────────────────────────┘    │
│  │     (delegated)      │                                       │
│  └──────────┬───────────┘                                       │
│             │                                                   │
│  ┌──────────▼───────────┐                                       │
│  │ Private AKS Cluster  │                                       │
│  │  • Azure CNI Overlay │                                       │
│  │  • Workload Identity │                                       │
│  │  • ALB controller    │◄── creates AGC resources              │
│  │    add-on enabled    │    from ApplicationLoadBalancer CR     │
│  │  • Gateway API       │                                       │
│  │    (Standard)        │                                       │
│  └──────────────────────┘                                       │
│                                                                 │
│  Node Resource Group (MC_...)                                   │
│  ┌──────────────────────┐                                       │
│  │ Traffic Controller   │◄── auto-created by ALB controller     │
│  │  ├─ Frontend         │                                       │
│  │  └─ Association      │                                       │
│  └──────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────┘
```

## What this scenario includes

| Component | Details |
|-----------|---------|
| **AKS cluster** | Private, Azure CNI Overlay, OIDC Issuer + Workload Identity, system + user node pools (AzureLinux) |
| **ALB controller add-on** | Enabled via `azapi_update_resource` (preview API `2025-09-02-preview`) |
| **Gateway API** | Installed via `ingressProfile.gatewayAPI.installation = "Standard"` |
| **AGC subnet** | `/24`, delegated to `Microsoft.ServiceNetworking/trafficControllers` |
| **WAF policy** | Azure WAF with Default Rule Set 2.1, plus two custom rules |
| **Demo 1 — Gateway API** | Namespace `test-app` — `ApplicationLoadBalancer` CR, `Gateway`, `HTTPRoute`, WAF CR |
| **Demo 2 — Ingress API** | Namespace `test-app-ingress` — standard `Ingress` resource sharing the same ALB |

## File reference

```text
agc-managed/
├── deploy.sh                        # Deploy + wait + print endpoints
├── test.sh                          # cURL validation of allow/block
├── k8s/
│   ├── test-app-gateway.yaml        # Demo 1 manifest (all-in-one)
│   ├── test-app-ingress.yaml        # Demo 2 manifest (all-in-one)
│   └── waf-policy.yaml              # WebApplicationFirewallPolicy CR
└── terraform/
    ├── main.tf                      # All Azure resources
    ├── variables.tf                 # Input variables with defaults
    ├── outputs.tf                   # Values consumed by deploy.sh
    ├── versions.tf                  # Provider constraints
    └── terraform.tfvars.example     # Sample variable overrides
```

## Prerequisites

### Azure subscription setup

Before deploying, ensure the required resource providers and preview features are registered:

```bash
# Register resource providers
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking

# Register preview features
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
az feature register --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview

# Wait until both features show "Registered", then propagate
az provider register --namespace Microsoft.ContainerService

# Install Azure CLI extensions
az extension add --name alb
az extension add --name aks-preview
```

### Local tools

- **Azure CLI** (`az`) logged in with a subscription that can create AKS, VNet, WAF, and RBAC assignments
- **Terraform ≥ 1.6** with providers: `azurerm ≥ 4.0`, `azapi ≥ 1.13`, `random ≥ 3.5`
- No local `kubectl` needed — scripts use `az aks command invoke` against the private cluster

## Terraform variables

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `eastus2` | Azure region |
| `name_prefix` | `agc-demo` | Prefix for all resource names (a random 4-char suffix is appended) |
| `system_node_count` | `1` | Nodes in the system pool |
| `node_vm_size` | `Standard_D2s_v5` | VM SKU for both pools |
| `vnet_address_space` | `["10.0.0.0/8"]` | VNet address space |
| `subnet_address_prefix` | `10.240.0.0/16` | AKS node subnet |
| `agc_subnet_address_prefix` | `10.241.0.0/24` | AGC delegated subnet (must be `/24` or smaller for CNI Overlay) |
| `allowed_source_ranges` | `[]` (open) | CIDR ranges allowed to reach the AGC frontend; all other IPs are blocked by a WAF rule. Leave empty to allow all traffic. |

## Terraform resources created

1. **Resource group** — `rg-agc-demo-XXXX`
2. **VNet** with AKS and AGC subnets (AGC subnet delegated to `Microsoft.ServiceNetworking/trafficControllers`)
3. **AKS cluster** — private, CNI Overlay, Workload Identity, system + user node pools
4. **ALB controller add-on + Gateway API** — enabled via `azapi_update_resource` on the AKS resource
5. **RBAC role assignments** for the ALB controller managed identity:
   - `AppGw for Containers Configuration Manager` on the node resource group (create/manage traffic controller)
   - `Network Contributor` on the AGC subnet (attach frontend)
   - `Network Contributor` on the WAF policy (attach WAF to AGC security policy)
6. **WAF policy** — `azurerm_web_application_firewall_policy` with DRS 2.1 + custom rules

## Kubernetes manifests in detail

### Demo 1 — Gateway API (`k8s/test-app-gateway.yaml`)

This single manifest creates everything for the Gateway API demo:

| Kind | Name | Namespace | Purpose |
|------|------|-----------|---------|
| `Namespace` | `test-app` | — | Isolates demo resources |
| `Deployment` | `echo-server` | `test-app` | 2 replicas of `ealen/echo-server` on port 80 |
| `Service` | `echo-server` | `test-app` | ClusterIP service fronting the echo pods |
| `ApplicationLoadBalancer` | `alb` | `test-app` | Tells the ALB controller which subnet to associate AGC with — `__AGC_SUBNET_ID__` is replaced by `deploy.sh` |
| `Gateway` | `gateway` | `test-app` | Uses `GatewayClass: azure-alb-external`, HTTP listener on port 80, annotated with `alb-namespace: test-app` and `alb-name: alb` |
| `HTTPRoute` | `echo-route` | `test-app` | Routes all traffic (`/`) to `echo-server:80` |

### Demo 2 — Ingress API (`k8s/test-app-ingress.yaml`)

| Kind | Name | Namespace | Purpose |
|------|------|-----------|---------|
| `Namespace` | `test-app-ingress` | — | Separate namespace for the Ingress demo |
| `Deployment` | `echo-server` | `test-app-ingress` | Identical echo-server (2 replicas) |
| `Service` | `echo-server` | `test-app-ingress` | ClusterIP service |
| `Ingress` | `echo-ingress` | `test-app-ingress` | `ingressClassName: azure-alb-external`, cross-namespace reference to the ALB via annotations `alb-name: alb` / `alb-namespace: test-app` |

> **Cross-namespace sharing**: The Ingress demo does not create its own `ApplicationLoadBalancer`. It reuses the one from `test-app` by pointing annotations at it, so both demos share the same AGC traffic controller and frontend.

### WAF policy CR (`k8s/waf-policy.yaml`)

```yaml
kind: WebApplicationFirewallPolicy
metadata:
  name: echo-waf-policy
  namespace: test-app
spec:
  targetRef:
    kind: ApplicationLoadBalancer
    name: alb                      # targets the shared ALB
  webApplicationFirewall:
    id: __WAF_POLICY_ID__          # Azure resource ID, replaced by deploy.sh
```

Because the CR targets the `ApplicationLoadBalancer`, WAF inspection applies to **all** Gateway API routes behind that ALB.

> **Note:** AGC WAF only supports **Gateway API** resources. Although the managed scenario's Ingress demo also goes through the same ALB, WAF inspection is applied only to Gateway API traffic (`HTTPRoute`). The Ingress demo shows basic routing without WAF.

## WAF rules explained

| Rule | Type | What it does | How to trigger |
|------|------|-------------|----------------|
| **AllowOnlyKnownIPs** | Custom (priority 1) | Blocks any source IP **not** in `allowed_source_ranges`. Only active when the variable is set. | Request from an IP outside the allowlist |
| **DRS 2.1** | Managed | OWASP-style rules including SQLi, XSS, LFI, etc. | `curl "http://<addr>/?id=1'+OR+'1'%3D'1"` |
| **BlockBadBots** | Custom (priority 2) | Blocks if `User-Agent` header contains `BadBot` | `curl -H "User-Agent: BadBot" http://<addr>/` |
| **BlockUriToken** | Custom (priority 3) | Blocks if request URI contains `blockme` | `curl "http://<addr>/?demo=blockme"` |

All rules use **Prevention** mode — matching requests receive HTTP 403.

> **Why IP restriction?** AGC frontends are [always public](https://learn.microsoft.com/azure/application-gateway/for-containers/application-gateway-for-containers-components) (private frontends are not supported today). The `AllowOnlyKnownIPs` WAF rule is the recommended approach to restrict access to known networks or corporate egress IPs.

## Deploy (step by step)

### 1. Provision infrastructure

```bash
cd agc-managed/terraform
terraform init
terraform validate
terraform apply
```

Typical apply time: **10–15 minutes** (AKS cluster creation dominates).

### 2. Deploy Kubernetes resources

```bash
cd ..          # back to agc-managed/
chmod +x deploy.sh
./deploy.sh
```

What the script does in order:

1. Reads Terraform outputs: `resource_group`, `aks_name`, `agc_subnet_id`, `waf_policy_id`, `aks_node_resource_group`
2. Generates `k8s/.test-app-gateway-generated.yaml` — replaces `__AGC_SUBNET_ID__` placeholder
3. Applies the Gateway manifest via `az aks command invoke`
4. Waits up to 3 min for `ApplicationLoadBalancer/alb` to become `Accepted`
5. Deletes any stale `securityPolicies/waf` on the traffic controller (ARM REST call) to avoid duplicates
6. Generates and applies the WAF CR (`__WAF_POLICY_ID__` replacement)
7. Waits up to 3 min for `Gateway/gateway` to become `Programmed`
8. Prints the public FQDN of the Gateway
9. Generates and applies the Ingress manifest (`__AGC_SUBNET_ID__` replacement)
10. Polls up to 3 min for the Ingress to receive a hostname
11. Prints the Ingress public FQDN

## Validate

```bash
chmod +x test.sh
./test.sh
```

The test script reads the Gateway and Ingress addresses from the cluster and runs six cURL checks:

| # | Target | Request | Expected |
|---|--------|---------|----------|
| 1 | Gateway | Normal `GET /` | `HTTP/1.1 200 OK` |
| 2 | Gateway | `User-Agent: BadBot` | `HTTP/1.1 403 Forbidden` |
| 3 | Gateway | SQLi query string | `HTTP/1.1 403 Forbidden` |
| 4 | Ingress | Normal `GET /` | `HTTP/1.1 200 OK` |
| 5 | Ingress | `User-Agent: BadBot` | `HTTP/1.1 403 Forbidden` |
| 6 | Ingress | SQLi query string | `HTTP/1.1 403 Forbidden` |

## How private-cluster interaction works

The AKS cluster has `private_cluster_enabled = true`, so the API server is not publicly reachable. All `kubectl` commands are executed through:

```bash
az aks command invoke \
  --resource-group <RG> \
  --name <AKS> \
  --command "kubectl ..." \
  --file <optional manifest>
```

This tunnels the command through Azure and does not require a local kubeconfig or VPN.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `ApplicationLoadBalancer` stays `Pending` | ALB controller identity missing `Network Contributor` on AGC subnet or `Contributor` on node RG | Verify role assignments in `terraform output` and re-run `terraform apply` |
| Gateway never becomes `Programmed` | AGC subnet too small or not properly delegated | Ensure subnet is `/24` with delegation to `Microsoft.ServiceNetworking/trafficControllers` |
| WAF returns 200 instead of 403 | WAF policy not yet propagated (can take 60–90 s) | Wait and retry; check the `WebApplicationFirewallPolicy` CR status |
| `az aks command invoke` times out | Private DNS resolution delay for new cluster | Retry after a minute; ensure your Azure CLI is up to date |
| Ingress has no address | ALB controller has not reconciled the Ingress yet | Check that `ingressClassName` is `azure-alb-external` and ALB annotations are correct |

## Cleanup

```bash
cd agc-managed/terraform
terraform destroy
```

This removes the resource group, AKS cluster, VNet, WAF policy, and all associated resources.
