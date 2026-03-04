# OSS NGINX Ingress Migration Scenario

This scenario demonstrates a private AKS cluster provisioned with Terraform, using the open source `ingress-nginx` controller instead of Application Gateway for Containers.

It is intended as a side-by-side migration example from AGC-style ingress definitions to NGINX ingress behavior.

## Architecture

```text
┌────────────────────────────────────────────────────────────────┐
│ Azure Resource Group (rg-nginx-demo-XXXX)                      │
│                                                                │
│  ┌────────────────────────────┐                                │
│  │ VNet 10.0.0.0/8            │                                │
│  │  └─ AKS subnet             │                                │
│  │     10.240.0.0/16          │                                │
│  └───────────────┬────────────┘                                │
│                  │                                             │
│          ┌───────▼────────────────────┐                        │
│          │ Private AKS cluster        │                        │
│          │  • Azure CNI Overlay       │                        │
│          │  • Workload Identity       │                        │
│          │  • ingress-nginx controller│                        │
│          └──────────────┬─────────────┘                        │
│                         │                                      │
│          ┌──────────────▼──────────────┐                       │
│          │ Namespace: test-app-nginx   │                       │
│          │  • echo-web service         │                       │
│          │  • echo-api service         │                       │
│          │  • Ingress (/) and (/api)   │                       │
│          │  • Optional rewrite ingress │                       │
│          └─────────────────────────────┘                       │
└────────────────────────────────────────────────────────────────┘
```

## What this scenario includes

- Private AKS cluster built with Terraform
- `ingress-nginx` installed from Helm chart (rendered locally, applied via `az aks command invoke`)
- Path-based ingress routing (`/` and `/api`)
- Optional rewrite ingress example (`/rewrite/<path>`)

## File reference

```text
oss-nginx-migration/
├── deploy.sh
├── test.sh
├── k8s/
│   ├── test-app.yaml
│   ├── test-app-ingress.yaml
│   └── test-app-ingress-rewrite.yaml
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── versions.tf
    └── terraform.tfvars.example
```

## Prerequisites

- Azure CLI (`az`) logged in and targeting your subscription
- Terraform `>= 1.6.0`
- Helm (`helm`) installed locally
- No local kubeconfig required (cluster is private and scripts use `az aks command invoke`)

## Terraform variables

| Variable | Default | Description |
| --- | --- | --- |
| `location` | `eastus2` | Azure region |
| `name_prefix` | `nginx-demo` | Prefix for resource names |
| `system_node_count` | `1` | System node pool size |
| `apps_node_count` | `1` | User node pool size |
| `node_vm_size` | `Standard_D2s_v5` | VM SKU |
| `vnet_address_space` | `["10.0.0.0/8"]` | VNet CIDR |
| `subnet_address_prefix` | `10.240.0.0/16` | AKS subnet CIDR |

## Deploy

```bash
cd oss-nginx-migration/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform apply

cd ..
./deploy.sh
```

`deploy.sh` performs the following:

1. Reads Terraform outputs (`resource_group`, `aks_name`)
2. Renders `ingress-nginx` Helm chart to `k8s/.ingress-nginx-generated.yaml`
3. Applies NGINX controller resources via `az aks command invoke`
4. Deploys test workloads and ingress manifests
5. Waits for the public LoadBalancer address and prints it

## Validate

```bash
./test.sh
```

Expected checks:

- `GET /` returns HTTP 200 and `web-ok`
- `GET /api` returns HTTP 200 and `api-ok`
- `GET /rewrite/hello` returns HTTP 200 via rewrite ingress

## Guided migration to AGC (BYO)

After your NGINX-based cluster is up and validated, use the migration utility to generate AGC-compatible Gateway API resources.

This guided section shows how to use the [Application Gateway for Containers Migration Utility](https://github.com/Azure/Application-Gateway-for-Containers-Migration-Utility) to convert NGINX Ingress manifests into AGC-compatible Gateway API resources.

Model clarification:
- **ALB Controller installation** can be AKS add-on or Helm.
- **AGC ownership mode** can be Managed or BYO.
- This migration walkthrough targets **BYO ownership**.

### Scope

This is a migration-tool walkthrough only.

- It assumes your AKS cluster already has Application Gateway for Containers enabled in **BYO mode**.
- It focuses on what the migration utility generates from source manifests.
- For AGC environment setup, use [../agc-byo/README.md](../agc-byo/README.md).
- You can also reference [../agc-managed/README.md](../agc-managed/README.md).

### What you will migrate

This walkthrough uses:

- [k8s/test-app-ingress.yaml](k8s/test-app-ingress.yaml)
- [k8s/test-app-ingress-rewrite.yaml](k8s/test-app-ingress-rewrite.yaml)

### Prerequisites for migration utility

1. Existing AGC BYO deployment on AKS.
2. Azure CLI authenticated to the right subscription.
3. Migration utility binary available (release or locally built).
4. AGC resource ID for BYO mode (`--byo-resource-id`), for example:

```text
/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ServiceNetworking/trafficControllers/<agc-name>
```

### Step 1: Get the migration utility

Download a release binary (or build from source):

```bash
git clone https://github.com/Azure/Application-Gateway-for-Containers-Migration-Utility.git
cd Application-Gateway-for-Containers-Migration-Utility
./build.sh
```

### Step 2: Define required inputs

```bash
export AGC_ID="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ServiceNetworking/trafficControllers/<agc-name>"
export OUT_DIR="./migration-output"
```

### Step 3: Run dry-run first

```bash
agc-migration files \
    --provider nginx \
    --ingress-class nginx \
    --byo-resource-id "$AGC_ID" \
    --dry-run \
    ./k8s/test-app-ingress.yaml \
    ./k8s/test-app-ingress-rewrite.yaml
```

Review the report for `warning`, `not-supported`, and `error` items before continuing.

### Step 4: Generate converted manifests

```bash
agc-migration files \
    --provider nginx \
    --ingress-class nginx \
    --byo-resource-id "$AGC_ID" \
    --output-dir "$OUT_DIR" \
    ./k8s/test-app-ingress.yaml \
    ./k8s/test-app-ingress-rewrite.yaml
```

### Step 5: Review generated output

Typical generated resources include:

- `Gateway`
- `HTTPRoute`
- `ReferenceGrant`
- Policy resources when applicable (`RoutePolicy`, `HealthCheckPolicy`, `WAFPolicy`, etc.)

### Step 6: Apply generated manifests to AKS

From `terraform/`:

```bash
RG=$(terraform output -raw resource_group)
AKS=$(terraform output -raw aks_name)
```

From this folder:

```bash
az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "kubectl apply -f migration-output"
```

### Step 7: Validate generated AGC resources

```bash
az aks command invoke \
    --resource-group "$RG" \
    --name "$AKS" \
    --command "kubectl get gateway,httproute -A"
```

### Common notes

- The migration utility does not modify existing source ingresses.
- Some NGINX annotations may need manual post-edit.
- Always review generated YAML before production apply.

## Migration notes (NGINX -> AGC)

- Replace `ingressClassName: azure-alb-external` with `ingressClassName: nginx`
- Remove AGC annotations such as `alb-name`, `alb-namespace`, `alb-id`, and frontend references
- Remove AGC-specific custom resources (`ApplicationLoadBalancer`, AGC WAF CR)
- Add NGINX annotations only when needed (for example rewrite behavior)

## Cleanup

```bash
cd terraform
terraform destroy
```
