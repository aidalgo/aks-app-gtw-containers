# AKS + Application Gateway for Containers Demo

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

This repository demonstrates three ways to expose workloads running on a private AKS cluster:

- **Add-on managed mode** (`agc-managed/`): AGC resources are created and managed by the controller from Kubernetes custom resources.
- **BYO mode** (`agc-byo/`): AGC resources are pre-created in Azure, then referenced from Kubernetes manifests.
- **OSS NGINX migration** (`oss-nginx-migration/`): AKS is provisioned with Terraform and ingress is provided by open source `ingress-nginx`.

Both AGC scenarios also include:

- Gateway API example (`Gateway` + `HTTPRoute`)
- Kubernetes Ingress example (`Ingress`)
- Azure WAF policy integration and simple validation tests

The OSS NGINX scenario focuses on ingress migration patterns (`IngressClass`, path routing, and rewrite rules) without AGC-specific resources.

## Architecture overview

```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Azure Resource Group                                                           │
│                                                                                 │
│  ┌──────────────────────┐   ┌──────────────────────┐   ┌────────────────────┐   │
│  │ VNet 10.0.0.0/8      │   │ WAF Policy           │   │ Private AKS        │   │
│  │  ├─ AKS subnet       │   │  • DRS 2.1           │   │  • Azure CNI       │   │
│  │  │  10.240.0.0/16    │   │  • Custom block      │   │    Overlay         │   │
│  │  └─ AGC subnet       │   │    rules             │   │  • Workload Id     │   │
│  │     10.241.0.0/24    │   └──────────────────────┘   │  • ALB controller  │   │
│  │     (delegated)      │                              │  • Gateway API     │   │
│  └──────────────────────┘                              └─────────┬──────────┘   │
│                                                                  │              │
│             ┌────────────────────────────────────┬───────────────┘              │
│             │                                    │                              │
│             ▼                                    ▼                              │
│  ┌──────────────────────────┐     ┌──────────────────────────────┐              │
│  │  Add-on Managed Mode     │     │  BYO Mode (agc-byo/)         │              │
│  │  (agc-managed/)          │     │                              │              │
│  │                          │     │  Traffic Controller, Frontend│              │
│  │  ALB controller creates  │     │  & Association pre-created   │              │
│  │  AGC resources from      │     │  in Azure via Terraform      │              │
│  │  ApplicationLoadBalancer │     │  azapi_resource (AzAPI)       │              │
│  │  custom resource         │     │                              │              │
│  │                          │     │  K8s manifests reference     │              │
│  │  ┌────────────────────┐  │     │  resources by ARM ID         │              │
│  │  │ Traffic Controller │  │     │                              │              │
│  │  │  ├─ Frontend       │  │     │  ┌────────────────────────┐  │              │
│  │  │  └─ Association    │  │     │  │ Traffic Controller     │  │              │
│  │  │  (auto-created)    │  │     │  │  ├─ Frontend           │  │              │
│  │  └────────────────────┘  │     │  │  └─ Association        │  │              │
│  └──────────────────────────┘     │  │  (pre-provisioned)     │  │              │
│                                   │  └────────────────────────┘  │              │
│                                   └──────────────────────────────┘              │
└─────────────────────────────────────────────────────────────────────────────────┘
```

See [agc-managed/README.md](agc-managed/README.md) and [agc-byo/README.md](agc-byo/README.md) for detailed per-scenario architecture diagrams.

For the NGINX path, see [oss-nginx-migration/README.md](oss-nginx-migration/README.md).

## What this demo deploys

For each scenario, Terraform provisions:

- A new resource group
- A virtual network with:
  - AKS subnet
  - delegated AGC subnet (`Microsoft.ServiceNetworking/trafficControllers`)
- A private AKS cluster (Azure CNI Overlay, OIDC issuer, Workload Identity)
- AGC add-on enablement + Gateway API installation (`Standard`)
- RBAC for the ALB controller managed identity
- Azure WAF policy (Default Rule Set 2.1 + custom block rules)

In BYO mode, Terraform also creates (via `azapi_resource`):

- AGC traffic controller
- AGC frontend
- AGC association to the delegated subnet

## Repository layout

```text
agc-managed/
  terraform/   # Managed-mode infrastructure
  k8s/         # Gateway + Ingress + WAF CRs (managed mode)
  deploy.sh    # Applies manifests via az aks command invoke
  test.sh      # cURL checks for allow/block behavior

agc-byo/
  terraform/   # BYO infrastructure and ALB resources
  k8s/         # Gateway + Ingress + WAF CRs (BYO mode)
  deploy.sh    # Applies manifests via az aks command invoke
  test.sh      # cURL checks for allow/block behavior

oss-nginx-migration/
  terraform/   # AKS infrastructure for OSS NGINX demo
  k8s/         # Test app + NGINX Ingress manifests
  deploy.sh    # Installs ingress-nginx and applies manifests
  test.sh      # cURL checks for path and rewrite behavior
```

## Prerequisites

### 1. Azure subscription and CLI

```bash
# Sign in and select your subscription
az login
az account set --subscription <your-subscription-id>

# Register required resource providers
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking

# Register required preview features
az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
az feature register --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview

# Wait for features to register (check with)
az feature show --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview --query properties.state -o tsv
az feature show --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview --query properties.state -o tsv

# Propagate the feature registration
az provider register --namespace Microsoft.ContainerService

# Install Azure CLI extensions
az extension add --name alb
az extension add --name aks-preview
```

### 2. Local tools

- **Terraform ≥ 1.5** (or compatible with the providers in `versions.tf`)
- **Azure CLI** (`az`) logged in
- `kubectl` is optional — deployment scripts use `az aks command invoke` against the private cluster

## Required Azure permissions

The deploying identity (user or service principal) needs the following:

| Permission / Role | Scope | Reason |
| --- | --- | --- |
| **Contributor** | Resource group (or subscription) | Create AKS, VNet, WAF policy, and AGC resources |
| **Role Based Access Control Administrator** or **User Access Administrator** | Resource group | Terraform creates RBAC role assignments for the ALB controller managed identity |
| `Microsoft.ServiceNetworking/trafficControllers/*` | Subscription | Required resource provider for Application Gateway for Containers |

## Quick start

Choose one scenario.

### Option A: Add-on managed mode

```bash
cd agc-managed/terraform
terraform init
terraform validate
terraform apply

cd ..
./deploy.sh
./test.sh
```

Detailed guide: [agc-managed/README.md](agc-managed/README.md)

### Option B: BYO mode

```bash
cd agc-byo/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform apply

cd ..
./deploy.sh
./test.sh
```

Detailed guide: [agc-byo/README.md](agc-byo/README.md)

### Option C: OSS NGINX migration

```bash
cd oss-nginx-migration/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform apply

cd ..
./deploy.sh
./test.sh
```

Detailed guide: [oss-nginx-migration/README.md](oss-nginx-migration/README.md)

## Expected test behavior

Both `test.sh` scripts validate:

- normal request returns `HTTP/1.1 200 OK`
- custom WAF rule blocks `User-Agent: BadBot` with `HTTP/1.1 403 Forbidden`
- managed WAF rule blocks SQLi-style query with `HTTP/1.1 403 Forbidden`

## Notes

- This demo uses **private AKS** clusters; scripts interact with the cluster through `az aks command invoke`.
- Generated Kubernetes files are written as hidden files under each scenario `k8s/` folder (for placeholder substitution).
- Subnet sizing for AGC association in overlay scenarios should follow current Azure guidance (the BYO README includes context).

## Cleanup

Destroy resources from the scenario you deployed:

```bash
cd agc-managed/terraform && terraform destroy
# or
cd agc-byo/terraform && terraform destroy
# or
cd oss-nginx-migration/terraform && terraform destroy
```

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
