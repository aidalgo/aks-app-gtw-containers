# BYO AGC Scenario

This scenario demonstrates **Bring Your Own (BYO)** Application Gateway for Containers (AGC).

In BYO mode the AGC traffic controller, frontend, and association are **pre-created in Azure** using `azapi_resource` (the AzAPI Terraform provider). Kubernetes manifests then reference those existing resources by full ARM resource ID instead of letting the ALB controller create them implicitly.

## Architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Azure Resource Group (rg-agc-byo-XXXX)                              │
│                                                                      │
│  ┌──────────────────────┐   ┌─────────────────────────────────┐      │
│  │ VNet 10.0.0.0/8      │   │ WAF Policy (Prevention)         │      │
│  │  ├─ AKS subnet       │   │  • DRS 2.1                      │      │
│  │  │  10.240.0.0/16    │   │  • BlockBadBots (User-Agent)    │      │
│  │  └─ AGC subnet       │   │  • BlockUriToken (URI)          │      │
│  │     10.241.0.0/24    │   └─────────────────────────────────┘      │
│  │     (delegated)      │                                            │
│  └──────────┬───────────┘                                            │
│             │                                                        │
│  ┌──────────▼───────────┐   ┌─────────────────────────────────┐      │
│  │ Private AKS Cluster  │   │ BYO Traffic Controller          │      │
│  │  • Azure CNI Overlay │   │  (alb-agc-byo-XXXX)             │      │
│  │  • Workload Identity │   │  ├─ Frontend (frontend-XXXX)    │      │
│  │  • ALB controller    │   │  └─ Association ──► AGC subnet  │      │
│  │    add-on enabled    │   │                                 │      │
│  │  • Gateway API       │   │  Created by Terraform         │      │
│  │    (Standard)        │   │  azapi_resource               │      │
│  └──────────────────────┘   └─────────────────────────────────┘      │
│                                                                      │
│  K8s manifests reference BYO resources:                              │
│   • Gateway annotation: alb.networking.azure.io/alb-id: <ALB ID>    │
│   • Gateway address:    alb.networking.azure.io/alb-frontend         │
│   • Ingress annotation: alb.networking.azure.io/alb-id: <ALB ID>    │
│   • Ingress annotation: alb.networking.azure.io/alb-frontend         │
└──────────────────────────────────────────────────────────────────────┘
```

## What this scenario includes

| Component | Details |
|-----------|---------|
| **AKS cluster** | Private, Azure CNI Overlay, OIDC Issuer + Workload Identity, system + user node pools (AzureLinux) |
| **ALB controller add-on** | Enabled via `azapi_update_resource` (preview API `2025-09-02-preview`) |
| **Gateway API** | Installed via `ingressProfile.gatewayAPI.installation = "Standard"` |
| **AGC subnet** | `/24`, delegated to `Microsoft.ServiceNetworking/trafficControllers` |
| **BYO traffic controller** | Created by `azapi_resource` (`Microsoft.ServiceNetworking/trafficControllers`) |
| **BYO frontend** | Created by `azapi_resource` (child of traffic controller) |
| **BYO association** | Created by `azapi_resource` (child of traffic controller), linked to the AGC subnet |
| **WAF policy** | Azure WAF with Default Rule Set 2.1 + two custom rules |
| **Demo 1 — Gateway API** | Namespace `test-app-byo` — `Gateway` + `HTTPRoute` pinned to BYO ALB/frontend |
| **Demo 2 — Ingress API** | Namespace `test-app-ingress-byo` — `Ingress` referencing the BYO ALB by ID |

## File reference

```text
agc-byo/
├── deploy.sh                           # Deploy + WAF + wait + print endpoints
├── test.sh                             # cURL validation of allow/block
├── k8s/
│   ├── test-app-gateway-byo.yaml       # Demo 1 manifest (Gateway API)
│   ├── test-app-ingress-byo.yaml       # Demo 2 manifest (Ingress)
│   └── waf-policy.yaml                 # WebApplicationFirewallPolicy CR
└── terraform/
    ├── main.tf                         # All Azure + BYO resources
    ├── variables.tf                    # Input variables with defaults
    ├── outputs.tf                      # Values consumed by deploy.sh
    ├── versions.tf                     # Provider constraints
    ├── terraform.tfvars.example        # Sample variable overrides
    └── terraform.tfvars                # Your local overrides (git-ignored)
```

## Prerequisites

- **Azure CLI** (`az`) logged in with a subscription that can create AKS, VNet, WAF, RBAC assignments, and `Microsoft.ServiceNetworking` resources
- **`alb` CLI extension** — `az extension add --name alb` (the deploy script installs it if missing)
- **Terraform ≥ 1.6** with providers: `azurerm ≥ 4.0`, `azapi ≥ 1.13`, `random ≥ 3.5`
- No local `kubectl` needed — scripts use `az aks command invoke` against the private cluster

## Terraform variables

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `eastus2` | Azure region |
| `name_prefix` | `agc-byo` | Prefix for all resource names (a random 4-char suffix is appended) |
| `system_node_count` | `1` | Nodes in the system pool |
| `node_vm_size` | `Standard_D2s_v5` | VM SKU for both pools |
| `vnet_address_space` | `["10.0.0.0/8"]` | VNet address space |
| `aks_subnet_address_prefix` | `10.240.0.0/16` | AKS node subnet |
| `agc_subnet_address_prefix` | `10.241.0.0/24` | AGC delegated subnet (must be `/24` or smaller for CNI Overlay) |
| `allowed_source_ranges` | `[]` (open) | CIDR ranges allowed to reach the AGC frontend; all other IPs are blocked by a WAF rule. Leave empty to allow all traffic. |

A sample file is provided:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit location/prefix if needed, then:
terraform init && terraform apply
```

## Terraform resources created

1. **Resource group** — `rg-agc-byo-XXXX`
2. **VNet** with AKS and AGC subnets (AGC subnet delegated to `Microsoft.ServiceNetworking/trafficControllers`)
3. **AKS cluster** — private, CNI Overlay, Workload Identity, system + user node pools
4. **ALB controller add-on + Gateway API** — enabled via `azapi_update_resource` on the AKS resource
5. **RBAC role assignments** for the ALB controller managed identity:
   - `AppGw for Containers Configuration Manager` on the resource group (create/manage AGC child resources)
   - `Network Contributor` on the AGC subnet (attach association)
   - `Network Contributor` on the WAF policy (attach WAF to security policy)
6. **WAF policy** — `azurerm_web_application_firewall_policy` with DRS 2.1 + custom rules
7. **BYO AGC resources** (via `azapi_resource`):
   - Traffic controller: `Microsoft.ServiceNetworking/trafficControllers`
   - Frontend: `Microsoft.ServiceNetworking/trafficControllers/frontends`
   - Association: `Microsoft.ServiceNetworking/trafficControllers/associations` (linked to AGC subnet)

> **Why AzAPI?** The `Microsoft.ServiceNetworking/trafficControllers` resource type is not yet natively modeled in the `azurerm` provider. The `azapi` provider gives full lifecycle management (create, read, update, delete) directly from the ARM API.

## Kubernetes manifests in detail

### Demo 1 — Gateway API (`k8s/test-app-gateway-byo.yaml`)

| Kind | Name | Namespace | Purpose |
|------|------|-----------|---------|
| `Namespace` | `test-app-byo` | — | Isolates BYO Gateway demo |
| `Deployment` | `echo-server` | `test-app-byo` | 2 replicas of `ealen/echo-server` on port 80 |
| `Service` | `echo-server` | `test-app-byo` | ClusterIP service fronting echo pods |
| `Gateway` | `gateway` | `test-app-byo` | `GatewayClass: azure-alb-external`, annotated with `alb-id: __ALB_ID__`, binds a specific frontend via `addresses[].type: alb.networking.azure.io/alb-frontend` + `addresses[].value: __FRONTEND_NAME__` |
| `HTTPRoute` | `echo-route` | `test-app-byo` | Routes all traffic (`/`) to `echo-server:80` |

**Key BYO annotations** (replaced by `deploy.sh`):

```yaml
annotations:
  alb.networking.azure.io/alb-id: /subscriptions/.../trafficControllers/alb-agc-byo-XXXX
spec:
  addresses:
    - type: alb.networking.azure.io/alb-frontend
      value: frontend-XXXX
```

### Demo 2 — Ingress API (`k8s/test-app-ingress-byo.yaml`)

| Kind | Name | Namespace | Purpose |
|------|------|-----------|---------|
| `Namespace` | `test-app-ingress-byo` | — | Separate namespace for Ingress demo |
| `Deployment` | `echo-server` | `test-app-ingress-byo` | Identical echo-server (2 replicas) |
| `Service` | `echo-server` | `test-app-ingress-byo` | ClusterIP service |
| `Ingress` | `echo-ingress` | `test-app-ingress-byo` | `ingressClassName: azure-alb-external`, annotated with `alb-id: __ALB_ID__` and `alb-frontend: __INGRESS_FRONTEND_NAME__` to reference the BYO traffic controller and a dedicated frontend |

> **Note:** AGC WAF is only supported with **Gateway API** (`HTTPRoute`/`Gateway`). Kubernetes Ingress resources cannot be targeted by a `WebApplicationFirewallPolicy` CR. The Ingress demo shows basic routing without WAF.

### WAF policy CR (`k8s/waf-policy.yaml`)

```yaml
kind: WebApplicationFirewallPolicy
metadata:
  name: waf-gateway
  namespace: test-app-byo
spec:
  targetRef:
    kind: HTTPRoute
    name: echo-route            # targets the Gateway API route directly
  webApplicationFirewall:
    id: __WAF_POLICY_ID__       # Azure WAF resource ID, replaced by deploy.sh
```

> **Managed vs BYO WAF targeting**: In managed mode the WAF CR targets the `ApplicationLoadBalancer` (all routes). In BYO mode it targets the `HTTPRoute` directly. Note that AGC WAF **only supports Gateway API** resources — Kubernetes Ingress resources cannot be targeted.

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
cd agc-byo/terraform
cp terraform.tfvars.example terraform.tfvars   # edit if needed
terraform init
terraform validate
terraform apply
```

Typical apply time: **12–18 minutes** (AKS cluster + BYO ALB creation).

### 2. Deploy Kubernetes resources

```bash
cd ..          # back to agc-byo/
chmod +x deploy.sh
./deploy.sh
```

What the script does in order:

1. Reads Terraform outputs: `resource_group`, `aks_name`, `alb_id`, `frontend_name`, `waf_policy_id`
2. Generates `k8s/.test-app-gateway-byo-generated.yaml` — replaces `__ALB_ID__` and `__FRONTEND_NAME__`
3. Applies the Gateway BYO manifest via `az aks command invoke`
4. Waits up to 4 min for `Gateway/gateway` to become `Programmed`
5. Prints the public FQDN of the Gateway
6. Generates and applies the Ingress BYO manifest (`__ALB_ID__` replacement)
7. Polls up to 4 min for the Ingress to receive a hostname
8. Prints the Ingress public FQDN
9. Ensures the `alb` CLI extension is installed
10. Creates an AGC security policy (`az network alb security-policy waf create`) if it does not already exist
11. Generates and applies the `WebApplicationFirewallPolicy` CR
12. Waits 90 seconds for WAF propagation

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

## Key differences from add-on managed mode

| Aspect | Managed (agc-managed/) | BYO (agc-byo/) |
|--------|-------------------|------------|
| AGC lifecycle | Controller creates/deletes traffic controller from `ApplicationLoadBalancer` CR | You pre-create with `azapi_resource`; controller only reconciles K8s-side objects |
| K8s reference | `alb-name` + `alb-namespace` annotations | `alb-id` annotation with full ARM resource ID |
| Frontend binding | Implicit (controller assigns) | Explicit via `addresses[].type/value` on the Gateway |
| WAF CR target | `ApplicationLoadBalancer` (all routes) | `HTTPRoute` (per-route granularity) |
| RBAC | `Configuration Manager` on node RG + `Network Contributor` on subnet/WAF | `Configuration Manager` on RG + `Network Contributor` on subnet/WAF |
| AGC security policy | Controller creates from CR | Manually created via `az network alb security-policy waf create` |

## Overlay networking note

For AKS with Azure CNI Overlay the AGC association subnet must be `/24` or a more specific prefix (not `/23`). This repo defaults to `10.241.0.0/24`. If you change the VNet layout, keep the AGC subnet at `/24` or smaller.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `terraform apply` fails on traffic controller | `Microsoft.ServiceNetworking` provider not registered | `az provider register -n Microsoft.ServiceNetworking` |
| Gateway never becomes `Programmed` | ALB identity missing `Configuration Manager` role on RG | Verify RBAC in portal or re-run `terraform apply` |
| WAF returns 200 instead of 403 | Security policy or WAF CR not yet propagated (can take 60–90 s) | Wait and retry; check `az network alb security-policy show` |
| `az aks command invoke` times out | Private DNS resolution delay for new cluster | Retry after a minute; ensure Azure CLI is up to date |
| Ingress has no address after 4 min | ALB controller has not reconciled the Ingress | Verify `alb-id` annotation matches `terraform output alb_id` |
| Association create fails with subnet error | Subnet prefix too large for CNI Overlay | Ensure `agc_subnet_address_prefix` is `/24` or smaller |

## Cleanup

```bash
cd agc-byo/terraform
terraform destroy
```

This removes the resource group, AKS cluster, VNet, WAF policy, BYO ALB resources, and all associated RBAC assignments.
