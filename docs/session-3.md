# Project 1 — Work Notes

**Azure AKS Platform Onboarding**
Session 3 | March 2026

---

## Session 3 — GitHub Actions CI/CD Pipeline

### Objective

Build a GitHub Actions pipeline that eliminates every manual step from Sessions 1 and 2. A single `git push` to main builds the image, scans for vulnerabilities, pushes to ACR, configures all infrastructure dependencies, deploys via Helm, and validates all three endpoints through App Gateway.

### Final State

All three pipeline jobs passing end to end:

```
Build, Scan and Push   ✅  42s
Deploy to AKS          ✅  1m10s
Validate Endpoints     ✅  1m24s
```

Pipeline performs the following automatically on every push to main:

- Builds Docker image from `app/` directory
- Scans image with Trivy for CRITICAL and HIGH CVEs
- Pushes image to ACR via OIDC — no stored credentials
- Reads kubelet identity, workload identity, AGIC identity and OIDC issuer dynamically from Azure CLI
- Assigns AcrPull to kubelet identity (idempotent)
- Creates federated credentials for `azure-app-sa` and `ingress-azure` (idempotent)
- Installs CSI Secrets Store driver (idempotent)
- Grants CSI driver RBAC for secret sync (idempotent)
- Installs AGIC with correct identity (idempotent)
- Creates `db-password` in Key Vault (idempotent)
- Deploys or upgrades Helm chart with current image tag and identity values
- Waits for pod rollout to complete
- Validates `/health`, `/info` and `/secret-check` through App Gateway

---

### Problems Encountered — Session 3

---

#### Problem 1 — GitHub Actions masking job outputs containing subscription ID

|                 |                                                                                                                                                                                                                                                                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | Pipeline annotation: `Skip output 'acr_id' since it may contain secret`. The `acr_id`, `appgw_id` and `oidc_issuer` outputs from the `get-infra-values` job arrived as empty strings in the `deploy` job. The `--scope` argument for AcrPull assignment was empty, causing `argument --scope: expected one argument`.            |
| **Root Cause**  | GitHub Actions automatically detects and masks any job output that contains a value matching a registered secret. The subscription ID `d277e2ff-...` is registered as `AZURE_SUBSCRIPTION_ID`. Any output containing that string — including resource IDs and OIDC issuer URLs — is blanked before being passed to the next job. |
| **Fix Applied** | Removed the `get-infra-values` job entirely. All Azure CLI lookups moved inline into the `deploy` job using `GITHUB_ENV` with uppercase variable names. Values are fetched and used within the same job — they never cross job boundaries so masking does not apply. ACR ID moved to a GitHub secret `AZURE_ACR_ID`.             |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                                                                                                      |

---

#### Problem 2 — GitHub Actions SP lacks permission to assign roles on ACR

|                 |                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `az role assignment create` for AcrPull failed: `The client 'a814055a-...' does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write' over scope '.../acraksplatform'`                                                                                                                                                                         |
| **Root Cause**  | The GitHub Actions service principal was created by the OIDC identity module in the landing zone with scoped permissions for that repo. It had no `roleAssignments/write` permission on ACR resources in the app-dev resource group.                                                                                                                                              |
| **Fix Applied** | Assigned `User Access Administrator` role to the GitHub Actions SP on the ACR resource scope. This allows the SP to assign roles on that specific resource without granting broad subscription-level access. Also switched `az role assignment create` to use `--assignee-object-id` and `--assignee-principal-type ServicePrincipal` to bypass the Graph API permission warning. |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                                                                                                                                                       |

---

#### Problem 3 — GitHub Actions SP lacks permission to read and write Key Vault secrets

|                 |                                                                                                                                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `az keyvault secret list` failed: `Caller is not authorized to perform action on resource. Action: 'Microsoft.KeyVault/vaults/secrets/readMetadata/action'`                                                             |
| **Root Cause**  | The Key Vault uses RBAC authorisation. The GitHub Actions SP had no role assignment on the Key Vault. Even listing secrets requires `Key Vault Secrets User` at minimum — writing requires `Key Vault Secrets Officer`. |
| **Fix Applied** | Assigned `Key Vault Secrets Officer` role to the GitHub Actions SP on the Key Vault resource scope. This allows the pipeline to check for existing secrets and create new ones.                                         |
| **Status**      | ✅ Resolved                                                                                                                                                                                                             |

---

#### Problem 4 — Kubeconfig pointing to stale cluster FQDN on destroy

|                 |                                                                                                                                                                                                                                                         |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `helm uninstall` failed: `Kubernetes cluster unreachable: dial tcp: lookup aks-app-dev-0i50aluk.hcp.eastus2.azmk8s.io: no such host`                                                                                                                    |
| **Root Cause**  | The local kubeconfig still had the FQDN from a previous AKS cluster deployment. When AKS is destroyed and reprovisioned the cluster gets a new randomly generated FQDN. The old entry in `~/.kube/config` pointed to a DNS name that no longer existed. |
| **Fix Applied** | Ran `az aks get-credentials --overwrite-existing` to refresh the kubeconfig with the current cluster FQDN before running helm uninstall.                                                                                                                |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                                             |

---

### Security Decisions Made

During pipeline development a security review identified hardcoded values that should be secrets:

| Value           | Original Location               | Fixed Location                                    |
| --------------- | ------------------------------- | ------------------------------------------------- |
| Subscription ID | `ACR_ID` env var in workflow    | `AZURE_ACR_ID` GitHub secret                      |
| Tenant ID       | `TENANT_ID` env var in workflow | `AZURE_TENANT_ID` GitHub secret (already existed) |
| ACR resource ID | Hardcoded in workflow env block | `AZURE_ACR_ID` GitHub secret                      |

Subscription ID and tenant ID on their own cannot authenticate to Azure — a valid federated token or client secret is still required. However keeping them out of the public repo is best practice and costs nothing.

GitHub secrets configured on `azure-aks-platform-onboarding` repo:

```
AZURE_CLIENT_ID        — GitHub Actions SP client ID
AZURE_TENANT_ID        — Azure AD tenant ID
AZURE_SUBSCRIPTION_ID  — Azure subscription ID
AZURE_ACR_ID           — Full ACR resource ID
```

---

### Pipeline Trigger — Consideration for Production

The pipeline currently triggers on every push to `main`. This means any documentation change, README update or comment edit triggers a full build, scan, push and deploy cycle. In a lab environment this is fine. In production it is wasteful and risky.

**Recommended trigger strategy for production:**

```yaml
on:
  push:
    branches: [main]
    paths:
      - "app/**"
      - "helm/**"
  pull_request:
    branches: [main]
    paths:
      - "app/**"
      - "helm/**"
  workflow_dispatch:
```

**What this changes:**

The pipeline only triggers when files in `app/` or `helm/` are modified. Changes to `docs/`, `README.md`, `infra/` or `.github/` do not trigger a deploy. `workflow_dispatch` keeps the ability to trigger manually from the GitHub Actions UI at any time.

**Why this matters:**

- Avoids deploying unchanged application code on documentation commits
- Reduces ACR storage consumption from unnecessary image pushes
- Reduces AKS churn from unnecessary Helm upgrades
- Prevents accidental production deploys from non-application changes
- Matches the GitOps principle — infrastructure changes should not trigger application deployments and vice versa

**Additional trigger patterns worth knowing:**

```yaml
# Tag-based release — deploy only on version tags
on:
  push:
    tags:
      - 'v*'

# Environment promotion — separate workflows per environment
on:
  push:
    branches:
      - main        # deploys to dev
      - staging     # deploys to staging
      - production  # deploys to production
```

For this project the path-filtered trigger is the right next step. It keeps the simplicity of push-to-deploy while avoiding unnecessary pipeline runs on non-application changes.

---

### Permissions Granted to GitHub Actions Service Principal

The following role assignments were added to the GitHub Actions SP (`a814055a-7ff5-411d-9c31-fa4cdd2f06e1`) during this session:

| Role                      | Scope              | Purpose                             |
| ------------------------- | ------------------ | ----------------------------------- |
| User Access Administrator | ACR resource       | Assign AcrPull to kubelet identity  |
| Key Vault Secrets Officer | Key Vault resource | List and create secrets in pipeline |

These are in addition to the permissions granted by the OIDC identity module in the landing zone (Contributor on the subscription for Terraform operations).

---

### Idempotency Pattern

Every step in the deploy job checks whether the resource already exists before creating it. This means the pipeline is safe to run multiple times without errors or duplicate resources.

```bash
# Pattern used throughout the pipeline
EXISTING=$(az ... --query "..." -o tsv)

if [ -z "$EXISTING" ]; then
  az ... create ...
  echo "Created"
else
  echo "Already exists - skipping"
fi
```

This is important because `workflow_dispatch` allows manual re-runs and the pipeline may be triggered multiple times against the same cluster.

---

### Lessons Learned

- GitHub Actions masks any job output or environment variable that contains a value matching a registered secret. This includes resource IDs that happen to contain the subscription ID. Never pass sensitive-looking values between jobs via outputs — fetch them inline in the job that uses them.
- Service principals need explicit RBAC for every Azure action the pipeline performs. The principle of least privilege applies — grant only what is needed at the narrowest scope possible.
- Always use `--assignee-object-id` with `--assignee-principal-type ServicePrincipal` when assigning roles from a pipeline. The default `--assignee` flag tries to resolve via Graph API which the SP may not have permission to query.
- Kubeconfig entries become stale when AKS is destroyed and reprovisioned. Always run `az aks get-credentials --overwrite-existing` at the start of any session that involves a freshly provisioned cluster.
- Pipeline triggers should be scoped to the paths that actually affect the deployment. Push-to-main on all files is a starting point, not a final design.

---

## Project 1 — Completion Summary

### What Was Delivered

A complete platform onboarding pattern demonstrating the full path from application code to a running, secured, auto-scaling deployment on Kubernetes.

| Component                | Description                                                                            |
| ------------------------ | -------------------------------------------------------------------------------------- |
| FastAPI application      | Three endpoints — health, info, secret-check                                           |
| Multi-stage Dockerfile   | Non-root user, minimal runtime image                                                   |
| Azure Container Registry | Basic SKU, AcrPull via managed identity                                                |
| Helm chart               | Six templates — Deployment, Service, Ingress, HPA, ServiceAccount, SecretProviderClass |
| Workload identity        | Pods authenticate to Key Vault via OIDC — no stored credentials                        |
| Hub-spoke traffic path   | App Gateway → AGIC → Service → Pods                                                    |
| GitHub Actions pipeline  | Build, scan, push, deploy, validate — fully automated                                  |
| OIDC authentication      | Pipeline authenticates to Azure without stored secrets                                 |
| Idempotent deploy        | Pipeline safe to run multiple times                                                    |

### Next Steps Before Session 4

- Update pipeline trigger to path-filtered (`app/**` and `helm/**` only)
- Add Trivy `exit-code: 1` for CRITICAL CVEs to block deployments with critical vulnerabilities
- Write CV bullets for Project 1
- Update README with final architecture and pipeline diagram

---

## Session 4 Scope — Polish and Documentation

- Update pipeline trigger strategy
- Harden Trivy scan to fail on CRITICAL CVEs
- Write final README with architecture diagram
- Write CV bullets for Project 1
- Update GitHub profile README with Project 1 completion
