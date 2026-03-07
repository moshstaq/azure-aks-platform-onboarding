# Project 1 — Work Notes

**Azure AKS Platform Onboarding**
Sessions 2 | March 2026

## Session 2 — AKS Provisioning and Helm Deployment

### Objective

Provision AKS cluster from the landing zone, deploy the Helm chart, resolve workload identity and AGIC authentication, validate the full traffic path from App Gateway through to Key Vault secret resolution.

### Final State

- AKS cluster running — 1 system node, 1 workload node
- Both `azure-app` pods Running with Key Vault secret mounted
- AGIC reconciled App Gateway backend pool
- All three endpoints responding correctly through App Gateway public IP

**Validated responses:**

```
GET /health       -> {"status":"healthy","timestamp":"2026-03-06T04:40:40.264695"}
GET /info         -> {"app":"azure-aks-platform-onboarding","environment":"dev","region":"eastus2"}
GET /secret-check -> {"secret_mounted":true,"source":"Azure Key Vault via workload identity"}
```

---

### Problems Encountered — Session 2

---

#### Problem 1 — snet-appgw subnet not found

|                 |                                                                                                                                                                                                                                                                                                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `terraform apply` on AKS module failed: Subnet `snet-appgw` was not found in `vnet-hub`                                                                                                                                                                                                                                                                          |
| **Root Cause**  | The AKS module uses a data source to read `snet-appgw` from `vnet-hub`. The connectivity module only had `snet-shared-services` — `snet-appgw` was never created in the platform layer.                                                                                                                                                                          |
| **Fix Applied** | Added `azurerm_subnet.appgw` to `platform/connectivity/main.tf` and added `snet_appgw_id` output. Applied connectivity first to create the subnet, then AKS apply succeeded. Also removed the duplicate `azurerm_subnet.appgw` resource block from `appgw.tf` in the AKS module — the subnet is now permanently managed in connectivity, not ephemeral with AKS. |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                                                                                                                                      |

---

#### Problem 2 — Multiple resources already exist, not in Terraform state

|                 |                                                                                                                                                                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `terraform apply` failed with 409 Conflict on `mi-agic`, `fed-agic`, `agic_rg_reader` and `agic_subnet_network_contributor` — resources already exist in Azure but not in state                                                                       |
| **Root Cause**  | AKS was destroyed in a previous session but the destroy was incomplete — managed identities, federated credentials and role assignments were not fully cleaned up. On redeploy Terraform tried to create them again and Azure rejected with conflict. |
| **Fix Applied** | Imported each resource into Terraform state using `terraform import` with the full resource ID. Role assignment IDs retrieved using `az role assignment list` filtered by principal ID. After import, `terraform apply` completed successfully.       |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                           |

---

#### Problem 3 — SecretProviderClass CRD not found

|                 |                                                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Problem**     | `kubectl apply -f manifests/secretprovider.yaml` failed: no matches for kind `SecretProviderClass` in version `secrets-store.csi.x-k8s.io/v1`                                  |
| **Root Cause**  | The CSI Secrets Store driver was not installed on the cluster. The SecretProviderClass is a custom resource defined by that driver. Without the driver the CRD does not exist. |
| **Fix Applied** | Installed `csi-secrets-store-provider-azure` Helm chart with `syncSecret.enabled=true`. SecretProviderClass applied successfully after installation.                           |
| **Status**      | ✅ Resolved                                                                                                                                                                    |

---

#### Problem 4 — AADSTS700213: No matching federated identity record for azure-app-sa

|                 |                                                                                                                                                                                                                                                                                       |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | Pod stuck in ContainerCreating: `ClientAssertionCredential authentication failed — no matching federated identity record found for system:serviceaccount:default:azure-app-sa`                                                                                                        |
| **Root Cause**  | The workload managed identity `mi-aks-nginx-demo` had a federated credential for `nginx-demo-sa` (from the landing zone demo workload) but not for `azure-app-sa` used by this project. Azure AD rejected the OIDC token because the subject did not match any registered credential. |
| **Fix Applied** | Created a new federated identity credential on `mi-aks-nginx-demo` with subject `system:serviceaccount:default:azure-app-sa` using `az identity federated-credential create` with the AKS OIDC issuer URL.                                                                            |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                                                           |

---

#### Problem 5 — CSI driver forbidden from listing Kubernetes Secrets

|                 |                                                                                                                                                                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | CSI driver logs: `secrets is forbidden: User system:serviceaccount:kube-system:secrets-store-csi-driver cannot list resource secrets at cluster scope`. Secret `azure-app-secrets` never synced.                                          |
| **Root Cause**  | The syncSecret feature requires the CSI driver service account to have permission to create and manage Kubernetes Secrets at cluster scope. The Helm chart installed without this RBAC permission.                                        |
| **Fix Applied** | Created ClusterRoleBinding granting `cluster-admin` to the CSI driver service account. Reinstalled the Helm chart with explicit syncSecret flags. Driver successfully created `azure-app-secrets` Kubernetes Secret from Key Vault value. |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                               |

---

#### Problem 6 — ErrImagePull after AKS redeploy

|                 |                                                                                                                                                                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Problem**     | Pods in `ErrImagePull` / `ImagePullBackOff` after reprovisioning AKS                                                                                                                                                                                         |
| **Root Cause**  | AKS was destroyed and reprovisioned, creating a new kubelet managed identity with a different object ID. The AcrPull role assignment was on the old identity (`2ca76e89`) which no longer existed. New kubelet identity (`6a4b8528`) had no pull permission. |
| **Fix Applied** | Ran `az role assignment create` assigning AcrPull to the new kubelet identity on the ACR resource. Deleted the stale assignment from the old identity. Pods moved to Running immediately.                                                                    |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                                  |

---

#### Problem 7 — AADSTS700016: Application identifier not found (workload identity)

|                 |                                                                                                                                                                                                                    |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Problem**     | Pod mount failed: `Application with identifier e66735b3 was not found in the directory`                                                                                                                            |
| **Root Cause**  | AKS was destroyed and reprovisioned, creating a new workload managed identity with a different client ID. The Helm chart was still using the old client ID from the previous session in `serviceAccount.clientId`. |
| **Fix Applied** | Retrieved new `workload_identity_client_id` from `terraform output`. Ran `helm upgrade` with the correct client ID. Also added new federated credential for `azure-app-sa` pointing to the new OIDC issuer URL.    |
| **Status**      | ✅ Resolved                                                                                                                                                                                                        |

---

#### Problem 8 — AADSTS700016: Application identifier not found (AGIC)

|                 |                                                                                                                                                                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | 502 Bad Gateway from App Gateway. AGIC logs showed: `Application with identifier 48669d21 was not found in the directory`                                                                                                                   |
| **Root Cause**  | Same pattern as Problem 7 but for AGIC. The `mi-agic` identity was recreated on redeploy with a new client ID. AGIC was installed with the old client ID from the previous session and could not authenticate to manage the App Gateway.    |
| **Fix Applied** | Uninstalled AGIC. Retrieved new `agic_client_id` from `terraform output`. Reinstalled AGIC with correct client ID. Created new federated credential for `ingress-azure` service account. AGIC reconciled the backend pool and 502 resolved. |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                 |

---

## Recurring Pattern — Identity Drift on Redeploy

Six of the eight Session 2 problems share a common root cause: managed identity client IDs and object IDs change every time AKS is destroyed and reprovisioned. This creates a cascade of manual fixes:

- AcrPull role assignment points to stale kubelet identity
- Helm chart uses stale workload identity client ID
- AGIC uses stale AGIC identity client ID
- Federated credentials point to old OIDC issuer URL

This is acceptable for manual sessions but must be solved before CI/CD automation in Session 3.

### Session 3 Resolution Plan

- Add AcrPull role assignment to AKS Terraform module so it is managed as code and recreated automatically on redeploy
- CI/CD pipeline reads `workload_identity_client_id` and `agic_client_id` dynamically from `terraform output` — never hardcoded
- Pipeline recreates federated credentials as part of the deploy step using current OIDC issuer URL
- Single source of truth: Terraform outputs feed everything downstream

---

## Lessons Learned

### Technical

- Helm chart validation must use `helm template`, not a YAML linter. Go template syntax is not valid YAML.
- `git filter-branch` rewrites entire history — use it when large binaries are committed before `.gitignore` is in place. Always set up `.gitignore` before first commit.
- Azure SKU downgrade operations often require pre-conditions to be met via CLI before Terraform can apply. Read the error message carefully — it tells you exactly what to remove first.
- SecretProviderClass is a CRD introduced by the CSI Secrets Store driver. The driver must be installed before the resource can be applied.
- CSI syncSecret requires explicit RBAC. The Helm chart does not grant it automatically — a ClusterRoleBinding is needed.
- Workload identity federated credentials are tied to the OIDC issuer URL of a specific cluster. When the cluster is destroyed the URL changes and credentials become stale.
- Managed identity object IDs and client IDs are stable within a deployment but change on destroy and recreate. Never hardcode them in pipeline configuration.

### Process

- Destroy order matters. Always destroy Helm releases before `terraform destroy` to avoid orphaned Kubernetes resources.
- Document `terraform output` values at the end of each session. They are needed for the next session and change on every redeploy.
- When a pod is stuck in ContainerCreating, `kubectl describe pod` immediately. The Events section gives the exact failure reason within seconds.
- 502 from App Gateway means the backend is reachable but unhealthy or misconfigured. Check AGIC logs first — it will show authentication or reconciliation errors.
- 404 from App Gateway means no backend rule matched. Check the Ingress resource address field — if empty, AGIC has not reconciled yet. Wait 2 minutes.

---

## Current Infrastructure Values

> These change on every AKS redeploy. Always retrieve from `terraform output` at the start of each session.

| Resource                    | Value                                           |
| --------------------------- | ----------------------------------------------- |
| App Gateway Public IP       | `20.1.135.148`                                  |
| AKS Cluster                 | `aks-app-dev` (rg-app-dev)                      |
| Key Vault                   | `kv-aks-appdev`                                 |
| ACR                         | `acraksplatform.azurecr.io`                     |
| Workload Identity Client ID | `c16bcce0-6550-44b0-86b8-4c8e063b9597`          |
| Kubelet Identity Object ID  | `6a4b8528-b0eb-4201-9e6b-a76ff5203a02`          |
| AGIC Identity Client ID     | retrieve from `terraform output agic_client_id` |
| Tenant ID                   | `5be5dc5e-baf8-4a95-998d-1bd76c3aa0eb`          |
| Subscription ID             | `d277e2ff-ef0c-495f-92de-938e9c7fb6ff`          |

---

## Session 3 — GitHub Actions CI/CD Pipeline

### Scope

- Write `.github/workflows/ci-cd.yml` in `azure-aks-platform-onboarding` repo
- Build Docker image on push to main
- Scan image with Trivy for vulnerabilities
- Push image to ACR using OIDC authentication
- Deploy via Helm reading identity values dynamically from Terraform outputs
- Add AcrPull role assignment to AKS Terraform module
- Handle federated credential recreation in pipeline

### Pre-Session Checklist

- [ ] Platform modules applied: connectivity, management, governance, networking
- [ ] AKS applied and healthy
- [ ] `update-manifests.sh` run
- [ ] CSI driver installed with RBAC
- [ ] AGIC installed with current client ID
- [ ] Federated credentials created for `azure-app-sa` and `ingress-azure`
- [ ] `db-password` secret in Key Vault
- [ ] ACR provisioned and image pushed
