## Session 1 — Application, ACR and Helm Chart

### Objective

Build the application layer and infrastructure foundation for the platform onboarding project. Covers the FastAPI application, multi-stage Docker build, Azure Container Registry provisioning, and Helm chart scaffolding.

### What Was Built

- FastAPI application with `/health`, `/info` and `/secret-check` endpoints
- Multi-stage Dockerfile — builder stage installs dependencies, runtime stage copies only what is needed, non-root user for security
- Azure Container Registry provisioned via Terraform with Private Endpoint (later downgraded to Basic SKU)
- Helm chart with six templates: Deployment, Service, Ingress, HPA, ServiceAccount, SecretProviderClass
- `values.yaml` as single source of truth for all configurable parameters
- Project README written

---

### Problems Encountered — Session 1

---

#### Problem 1 — Helm templates showing red lines in editor

|                 |                                                                                                                                                                                              |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | All Helm template files showing red lines / validation errors in VS Code                                                                                                                     |
| **Root Cause**  | YAML linter does not understand Helm Go template syntax. `{{ .Values.something }}` is valid Helm but invalid YAML — the linter flags it as an error.                                         |
| **Fix Applied** | Validated with `helm template` instead of the YAML linter. Helm understands the template syntax. Red lines in editor are cosmetic — not actual errors. All six templates rendered correctly. |
| **Status**      | ✅ Resolved                                                                                                                                                                                  |

---

#### Problem 2 — Helm template failed with nil pointer on service.type

|                 |                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `helm template` returned: nil pointer evaluating interface {}.type at `.Values.service.type`                               |
| **Root Cause**  | `values.yaml` was empty. The template referenced `.Values.service.type` but no values file existed to provide the default. |
| **Fix Applied** | Wrote the complete `values.yaml` with all required default values. Helm template rendered cleanly after.                   |
| **Status**      | ✅ Resolved                                                                                                                |

---

#### Problem 3 — Git push rejected due to .terraform directory (264MB)

|                 |                                                                                                                                                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | GitHub rejected push: File `infra/acr/.terraform/...` is 94.75 MB — exceeds GitHub's 100MB file size limit                                                                                                                   |
| **Root Cause**  | The `.terraform` directory containing provider binaries was committed before `.gitignore` was in place. Git history contained the large binary even after deletion from working tree.                                        |
| **Fix Applied** | Used `git filter-branch` to rewrite entire history removing the `.terraform` directory. Force pushed the cleaned history. Added comprehensive `.gitignore` covering `.terraform/`, `*.tfstate`, `__pycache__`, and OS files. |
| **Status**      | ✅ Resolved                                                                                                                                                                                                                  |

---

#### Problem 4 — ACR SKU downgrade blocked by existing network rules

|                 |                                                                                                                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | `terraform apply` failed with 409 Conflict: Cannot update the registry SKU — Registry has IP rules. Please remove them before proceeding.                                                                              |
| **Root Cause**  | ACR was on Premium SKU with network rules and a Private Endpoint. Azure requires all network restrictions to be removed before allowing SKU downgrade. Terraform cannot remove them automatically during a SKU change. |
| **Fix Applied** | Removed network rules via CLI: `az acr update --default-action Allow` and `az acr network-rule remove`. Then `terraform apply` succeeded, downgrading from Premium (~$20/month) to Basic (~$5/month).                  |
| **Status**      | ✅ Resolved                                                                                                                                                                                                            |

---

#### Problem 5 — Helm chart values.yaml empty after terminal cleared

|                 |                                                                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Problem**     | Helm chart structure was created but file contents were never written. After terminal session cleared all six template files and values.yaml were empty. |
| **Root Cause**  | Files were created with `touch` or `mkdir` but content was never written in the same session. Context was lost when terminal cleared.                    |
| **Fix Applied** | Rewrote all Helm templates from scratch using the architecture decisions already agreed. Validated with `helm template` to confirm correct rendering.    |
| **Status**      | ✅ Resolved                                                                                                                                              |

---
