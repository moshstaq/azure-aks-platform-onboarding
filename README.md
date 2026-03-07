# Azure AKS Platform Onboarding

End-to-end workload onboarding onto an Azure AKS landing zone. Demonstrates the full path from application code to a running, secured, auto-scaling deployment on Kubernetes — the pattern a platform engineer follows when onboarding a development team onto an existing Azure platform.

---

## Scenario

A development team has a Python API that needs deploying onto the Azure landing zone. As the platform engineer the job is to build everything between the developer pushing code and the application running in AKS, securely and repeatably. This covers the application, the container registry, the Kubernetes manifests managed via Helm, and the CI/CD pipeline that automates the full delivery path.

---

## Architecture

```
Developer pushes code
        │
        ▼
GitHub Actions pipeline
        ├── Build Docker image (multi-stage, non-root user)
        ├── Scan image for vulnerabilities (Trivy)
        ├── Push image to Azure Container Registry
        │
        ▼
Helm deploys to AKS (landing zone spoke VNet)
        ├── Deployment    — 2 replicas, workload node pool
        ├── Service       — ClusterIP, internal only
        ├── Ingress       — AGIC annotation
        ├── HPA           — scales 2 to 5 replicas at 70% CPU
        ├── ServiceAccount — workload identity annotation
        └── SecretProviderClass — Key Vault CSI integration
        │
        ▼
Traffic path
Internet → Application Gateway (hub) → VNet Peering → AGIC → Service → Pods
                                                                │
                                                                └── Workload identity
                                                                    fetches DB_PASSWORD
                                                                    from Key Vault
```

### Hub-Spoke Context

This project deploys into the spoke VNet of the Azure landing zone. The Application Gateway lives in the hub and is the only internet entry point. NSG rules on the AKS subnet block all inbound traffic except from the hub CIDR (10.0.0.0/16).

```
Hub VNet (10.0.0.0/16)              Spoke VNet (10.1.0.0/16)
├── snet-appgw (10.0.2.0/24)        ├── snet-aks (10.1.4.0/22)
│   └── Application Gateway         │   └── AKS nodes and pods
│                                   │
└────────── VNet Peering ───────────┘
```

---

## Repository Structure

```
azure-aks-platform-onboarding/
├── app/
│   ├── main.py              ← FastAPI application
│   ├── requirements.txt     ← Python dependencies
│   └── Dockerfile           ← Multi-stage build, non-root user
├── infra/
│   └── acr/                 ← Azure Container Registry Terraform
│       ├── main.tf
│       ├── outputs.tf
│       ├── backend.tf
│       └── versions.tf
├── helm/
│   └── azure-app/           ← Helm chart for AKS deployment
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           ├── hpa.yaml
│           ├── serviceaccount.yaml
│           └── secretprovider.yaml
└── .github/
    └── workflows/
        └── ci-cd.yml        ← Build, scan, push, deploy pipeline
```

---

## Application

Python FastAPI with three endpoints:

| Endpoint            | Purpose                                                            |
| ------------------- | ------------------------------------------------------------------ |
| `GET /health`       | Liveness and readiness probe target                                |
| `GET /info`         | Returns environment and region from injected environment variables |
| `GET /secret-check` | Confirms Key Vault secret is mounted without exposing the value    |

### Dockerfile Design

The Dockerfile uses a multi-stage build to keep the final image minimal and secure. Stage 1 installs Python dependencies including pip and any build tools. Stage 2 copies only the installed packages and application code into a clean base image. The result has no pip, no build tools and no cache. A non-root system user runs the application — running containers as root is a security risk in enterprise environments.

---

## Infrastructure

### Azure Container Registry

Basic SKU used for lab cost discipline (~$5/month). In production Premium SKU would be used with a Private Endpoint to restrict image pulls to within the VNet. The Private Endpoint pattern is already implemented in the landing zone storage module.

Admin credentials are disabled. AKS authenticates to ACR via AcrPull RBAC assigned to the kubelet managed identity — no username or password stored anywhere.

### Helm Chart

The Helm chart separates structure from configuration. Templates define the Kubernetes resources once. The values file holds defaults. At deploy time only the values that differ per environment are overridden — no copying or modifying templates.

```bash
helm install azure-app helm/azure-app \
  --set serviceAccount.clientId="<managed-identity-client-id>" \
  --set keyVault.vaultName="<key-vault-name>" \
  --namespace default
```

### Workload Identity

Pods authenticate to Azure Key Vault using workload identity. No credentials are stored in the cluster.

```
Pod runs with ServiceAccount (azure-app-sa)
        │  ServiceAccount annotated with managed identity client ID
        ▼
Workload identity webhook injects projected OIDC token at pod startup
        │
        ▼
Token exchanged for Azure access token via Azure AD
        │  Federated credential subject: system:serviceaccount:default:azure-app-sa
        ▼
Managed identity presents Key Vault Secrets User role
        │
        ▼
CSI Secrets Store driver fetches db-password from Key Vault
        │
        ▼
Secret synced to Kubernetes Secret (azure-app-secrets)
        │
        ▼
DB_PASSWORD injected as environment variable into pod
```

### Kubernetes Resources

| Resource            | Purpose                                                              |
| ------------------- | -------------------------------------------------------------------- |
| Deployment          | Runs 2 pod replicas on the workload node pool                        |
| Service             | ClusterIP providing stable internal DNS for the pods                 |
| Ingress             | AGIC annotation triggers automatic App Gateway backend configuration |
| HPA                 | Scales pods between 2 and 5 replicas based on CPU utilisation        |
| ServiceAccount      | Kubernetes identity linked to Azure managed identity via OIDC        |
| SecretProviderClass | Instructs CSI driver to fetch secrets from Key Vault                 |

---

## Deployment Order

This project depends on the Azure landing zone being provisioned first.

```bash
# 1. Provision landing zone (azure-landing-zone repo)
cd platform/connectivity            && terraform apply -auto-approve
cd platform/management              && terraform apply -auto-approve
cd platform/governance              && terraform apply -auto-approve
cd landing-zones/app-dev/networking && terraform apply -auto-approve
cd landing-zones/app-dev/workloads/compute/aks && terraform apply -auto-approve

# 2. Run update-manifests.sh to patch managed identity client IDs
./landing-zones/app-dev/workloads/compute/aks/update-manifests.sh

# 3. Provision ACR (this repo)
cd infra/acr && terraform init && terraform apply -auto-approve

# 4. Build and push image
az acr login --name acraksplatform
docker build -t acraksplatform.azurecr.io/azure-app:v1.0.0 app/
docker push acraksplatform.azurecr.io/azure-app:v1.0.0

# 5. Deploy via Helm
az aks get-credentials \
  --resource-group rg-app-dev \
  --name aks-app-dev \
  --overwrite-existing

helm install azure-app helm/azure-app \
  --set serviceAccount.clientId="<client-id>" \
  --set keyVault.vaultName="<vault-name>"

# 6. Validate
curl http://<app-gateway-ip>/health
curl http://<app-gateway-ip>/info
curl http://<app-gateway-ip>/secret-check

# 7. Destroy when done
helm uninstall azure-app
cd landing-zones/app-dev/workloads/compute/aks && terraform destroy -auto-approve
cd infra/acr && terraform destroy -auto-approve
```

---

## Cost

| Resource            | Status                                   | Cost      |
| ------------------- | ---------------------------------------- | --------- |
| ACR Basic           | Ephemeral — destroyed after testing      | ~$5/month |
| AKS Cluster         | Ephemeral — destroyed after each session | ~$10/day  |
| Application Gateway | Ephemeral — destroyed after each session | ~$7/day   |

All ephemeral resources are destroyed after validation to stay within the $20/month lab budget.

---

## Dependencies

This project consumes outputs from the [azure-landing-zone](https://github.com/moshstaq/azure-landing-zone) repo via Terraform remote state.

| Remote State Key                          | Output Used           | Purpose                          |
| ----------------------------------------- | --------------------- | -------------------------------- |
| `landing-zone-app-dev-networking.tfstate` | `vnet_app_dev_id`     | VNet link for DNS zone           |
| `landing-zone-app-dev-networking.tfstate` | `snet_app_id`         | Subnet for Private Endpoint      |
| `landing-zone-app-dev-networking.tfstate` | `resource_group_name` | Resource group for all resources |
| `landing-zone-app-dev-networking.tfstate` | `location`            | Azure region                     |

---

## CI/CD Pipeline

The GitHub Actions pipeline automates the full delivery path on every push to main that modifies app/ or helm/ files.

### Pipeline Jobs

**Job 1 — Build, Scan and Push**

- Builds Docker image using multi-stage build
- Scans image with Trivy — pipeline blocks on CRITICAL CVEs
- Pushes to ACR via OIDC — no stored credentials

**Job 2 — Deploy to AKS**

- Reads all identity values dynamically from Azure CLI at runtime
- Assigns AcrPull to kubelet identity (idempotent)
- Creates federated credentials for workload identity and AGIC (idempotent)
- Installs CSI Secrets Store driver (idempotent)
- Installs AGIC with current identity values (idempotent)
- Ensures db-password exists in Key Vault (idempotent)
- Helm install or upgrade with current image tag

**Job 3 — Validate Endpoints**

- Retrieves App Gateway public IP
- Waits for AGIC reconciliation
- Validates all three endpoints return expected responses

### Authentication

The pipeline authenticates to Azure using OIDC federated credentials. No secrets are stored in GitHub. The service principal has a federated credential scoped to the main branch of this repo.

### Pipeline Trigger

Triggers on push or pull request to main when app/ or helm/ files change. Documentation and infrastructure changes do not trigger a deployment. Manual dispatch available via GitHub Actions UI.

### GitHub Secrets Required

| Secret                | Purpose                                        |
| --------------------- | ---------------------------------------------- |
| AZURE_CLIENT_ID       | GitHub Actions service principal               |
| AZURE_TENANT_ID       | Azure AD tenant                                |
| AZURE_SUBSCRIPTION_ID | Azure subscription                             |
| AZURE_ACR_ID          | Full ACR resource ID for role assignment scope |

### Identity Drift Handling

Managed identity client IDs change every time AKS is destroyed and reprovisioned. The pipeline reads all identity values dynamically from Azure CLI at runtime so it is safe to run after any redeploy without manual intervention.

## Related

[azure-landing-zone](https://github.com/moshstaq/azure-landing-zone) — the platform this project deploys onto.
