# Finzla Cloud & Platform Engineer Assessment

[![PR Validation](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/validate.yml/badge.svg)](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/validate.yml)

[![CI/CD - Franchesny](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/deploy.yml/badge.svg)](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/deploy.yml)

This README documents the contents of the `franchesny-ecs` repository as provided. 

---

## 1. Repository Overview

The repository contains an implementation of the Finzla technical assessment. It includes:

- A minimal HTTP service (Python/FastAPI)
- Terraform configuration for AWS infrastructure (VPC, ECS, ECR, ALB, IAM, etc.)
- GitHub Actions workflows for CI/CD and PR validation
- IAM and OIDC configuration to allow GitHub Actions to assume a deploy role

**Important:** The repository does **not** contain a `Dockerfile`. The CI workflow (`ci.yml`) expects one to exist under `./app`; without it, the build step will fail. This is noted in the relevant section.

---

## 2. Application Code

### `app/main.py`

A FastAPI application exposing three endpoints:

- `GET /health` – returns `{"status": "ok"}` (HTTP 200)
- `GET /version` – returns version, git commit, build number, environment, and server time
- `GET /` – returns service metadata

The app reads environment variables:
- `APP_ENV` (default `development`)
- `APP_VERSION` (default `0.0.0`)
- `GIT_COMMIT` (default `unknown`)
- `BUILD_NUMBER` (default `unknown`)

Logging is configured to write to **stdout** using `logging.basicConfig` with `stream=sys.stdout`. No credentials or secrets are stored in code.

### `app/test_main.py`

Uses `fastapi.testclient` to test the `/health` and `/version` endpoints. Tests verify:
- `/health` returns 200 and `{"status": "ok"}`
- `/version` returns the expected fields (`version`, `git_commit`, `env`, `server_time_utc`)

### `app/requirements.txt`

Runtime dependencies:
- `fastapi==0.115.0`
- `uvicorn[standard]==0.30.6`

### `app/requirements-dev.txt`

Test dependencies (includes runtime dependencies):
- `pytest==8.3.3`
- `httpx==0.27.2`

**Note:** There is no `Dockerfile` in the repository. The CI workflow assumes one exists (`docker build -t pulse-app-pr-check ./app`). The user must add it for the build step to succeed.

---

## 3. AWS Infrastructure (Terraform)

The Terraform configuration is split into two directories (implied by the file contents):

- **`terraform/envs/prod/`** – production environment stack
- **`terraform/`** (likely a separate root) – IAM/OIDC setup for GitHub Actions

### 3.1 Production Environment (`terraform/envs/prod/`)

| File | Purpose |
|------|---------|
| `backend.tf` | S3 remote state backend: bucket `franchesny-tfstate-acctid`, key `franchesny/prod/terraform.tfstate`, `use_lockfile = true`, `encrypt = true`. |
| `provider.tf` | Requires AWS provider version `6.63.0`; sets region from `var.aws_region`. Also defines `data "aws_caller_identity" "current"`. |
| `variables.tf` | Defines `aws_region` (default `us-east-1`), `project_name` (default `franchesny`), `environment` (default `prod`), `tags` (default map), and `image_tag` (default `latest`). |
| `vpc.tf` | Creates a VPC (CIDR `10.0.0.0/16`) with two public and two private subnets, a single NAT gateway, DNS support and hostnames enabled. Public subnets tagged `Tier = public`, private subnets `Tier = private`. |
| `sg.tf` | Defines two security groups: `alb_sg` (ingress HTTP/HTTPS from 0.0.0.0/0, egress all) and `ecs_tasks_sg` (ingress from ALB SG on port 8080, egress all). |
| `ecr.tf` | Creates ECR repository named `${project_name}/pulseservice`, with image scan on push, mutable tags, force delete, and a lifecycle policy that expires untagged images after 2 days. |
| `ecs.tf` | Creates an ECS cluster named `${project_name}-ecs-cluster` with FARGATE as default capacity provider (weight 100). |
| `alb.tf` | Creates an ALB with two listeners: HTTP (redirects to HTTPS) and HTTPS (terminates TLS using the self-signed cert from `acm.tf`). Forwards to target group `pulsesvc_tg` (HTTP:8080, health check path `/health`). |
| `appservice.tf` | Defines the ECS service `pulseservice` with 256 CPU / 512 MB memory. Uses task and execution IAM roles, attaches to the ALB target group, runs in private subnets, and is secured by `ecs_tasks_sg`. `enable_execute_command = true`. |
| `acm.tf` | Generates a self-signed TLS certificate using `tls_self_signed_cert` (validity 1 year) and imports it into ACM. Used for the ALB HTTPS listener. |
| `iam.tf` | Creates two IAM roles: `ecs_task_execution_role` (attaches managed policy `AmazonECSTaskExecutionRolePolicy`) and `ecs_task_role` (no policies attached — application has no AWS permissions). |

### 3.2 IAM / OIDC Setup (separate Terraform root)

Files: `backend.tf`, `provider.tf`, `variables.tf`, `oidc.tf`, `service-linkedroles.tf`

| File | Purpose |
|------|---------|
| `backend.tf` | S3 backend for IAM state (bucket `permission-tfstate-716542960555`, key `franchesny/permissions/terraform.tfstate`). |
| `provider.tf` | AWS provider configuration. |
| `variables.tf` | Defines `aws_region` and `project_name`. |
| `oidc.tf` | Sets up the GitHub OIDC provider, an IAM role (`franchesny-github-deploy-role`) with trust conditions for the specific GitHub repo/branch, and attaches two IAM policies (see below). |
| `service-linkedroles.tf` | Creates the ECS service-linked role (`aws_iam_service_linked_role` for `ecs.amazonaws.com`). |

#### IAM Policies for the Deploy Role

The deploy role is defined in `oidc.tf` and is granted two policies:

- **`github_deploy_policy_1`** – permissions for ECR (auth, push/pull, lifecycle), ECS service updates, `iam:PassRole` for ECS roles, CloudWatch alarms, ACM import/describe/delete (scoped to project).
- **`github_deploy_policy_2`** – permissions for network resources (VPC, subnets, NAT, ALB, target groups, SGs), IAM for project-specific roles/policies, S3 state bucket access, and read-only access to certain services.

These policies are **scoped** to resources prefixed with `franchesny` (e.g., `arn:aws:ecr:...:repository/franchesny*`). The deploy role itself **cannot** modify its own policy (no `iam:PutRolePolicy` on its own ARN), which prevents privilege escalation.

---

## 4. GitHub Actions Workflows

Three workflows are present:

### 4.1 `ci.yml` – Build & Push to ECR

- Triggers on push to `main` when files under `app/**` or `.github/workflows/ci.yml` change.
- Steps:
  1. Checkout
  2. Configure AWS credentials via OIDC (assume `franchesny-github-deploy-role`)
  3. Login to ECR
  4. Build and push Docker image tagged `sha-<commit>` and `latest` to ECR repository `franchesny/pulseservice`

**Note:** This workflow references `./app` as the build context, but no `Dockerfile` is present. It will fail unless the user adds one.

### 4.2 `cd.yml` – Terraform Plan & Apply

- Triggers on push to `main` when files under `terraform/**` or `.github/workflows/cd.yml` change, and supports manual dispatch.
- Steps:
  1. Checkout
  2. Configure AWS credentials via OIDC
  3. Setup Terraform 1.15.6
  4. `terraform init`
  5. `terraform plan`
  6. `terraform apply -auto-approve`
  7. (Commented out) ECS service stability wait and health check against `https://pulse.suworks.me/health`

**Important:** The health check is **commented out** – no automatic validation of the deployment occurs after apply. This is a known gap that should be re-enabled for production readiness.

### 4.3 `validate.yml` – PR Validation

- Triggers on pull requests to `main` when paths under `app/**`, `.github/workflows/**`, or `terraform/**` change.
- Jobs:
  1. **Terraform checks** – `fmt -check`, `init`, `validate`, `plan` (uses OIDC credentials)
  2. **App build & test** – builds Docker image (no push) and runs `pytest`
  3. **Security scan** – uses Trivy in IaC mode to scan the `terraform` directory for misconfigurations (critical severity only, fails on findings)

---

## 5. Security & Least Privilege

- **Authentication:** GitHub Actions assumes an IAM role via OIDC. No AWS access keys are stored in the repository.
- **Trust restrictions:** The OIDC role's trust policy allows only the specific repository (`gunslingerrepo/franchesny-ecs`) and only for `main` branch pushes and pull requests. This prevents other repos or workflows from assuming the role.
- **IAM scoping:** The deploy role’s policies are carefully scoped to resources prefixed with the project name (`franchesny`). It cannot access other repositories, roles, or resources outside this project.
- **Secrets:** No secrets, passwords, or private keys are present in the repository.
- **Network security:** The application container is not directly exposed to the internet. The ALB is the only entry point; ECS tasks run in private subnets and only accept traffic from the ALB security group.
- **TLS:** The ALB terminates HTTPS using a self-signed ACM certificate. For production, a real certificate (e.g., from ACM with DNS validation) should be used.

---

## 6. Request Path (Internet → AWS → Application)

```
Client (HTTPS)
   │
   ▼
ALB (public subnet) – accepts HTTPS on port 443
   │  TLS termination (self-signed cert)
   │  Forwards to target group "pulsesvc_tg" on HTTP:8080
   │  (HTTP listener on port 80 redirects to HTTPS)
   ▼
ECS Task (private subnet) – FastAPI container listening on 8080
   │  Container pulls image from ECR
   │  Logs to stdout/stderr → CloudWatch Logs
   ▼
VPC private subnet – no direct internet inbound (NAT only for outbound)
```

---

## 7. Monitoring & Alerts

The repository **does not** include explicit CloudWatch alarm definitions or log group retention settings. The assessment requires at least 3 metrics and 2 alerts; these are conceptually defined but **not implemented** in Terraform.

**Suggested metrics (not implemented):**
- HTTP 5xx rate (from ALB)
- Target response time
- Unhealthy host count

**Suggested alerts (not implemented):**
- High 5xx rate
- Unhealthy targets for >10 minutes

**Logging:** Application logs are sent to CloudWatch Logs automatically via the ECS task execution role (`AmazonECSTaskExecutionRolePolicy`). Retention is not set; a `aws_cloudwatch_log_group` with `retention_in_days` should be added.

---

## 8. Incident Investigation (Troubleshooting Exercise)

The README should include this section. Based on the code provided, the following is a scenario-specific plan:

**Scenario:** A new release deployed, GitHub Actions reports success, ECS shows expected tasks running, but customers get 503 and ALB reports unhealthy targets.

**First steps:**
1. Check ALB target group health – `aws elbv2 describe-target-health --target-group-arn <tg-arn>`
2. Check ECS service events – `aws ecs describe-services --cluster <cluster> --services pulseservice`
3. Inspect task logs in CloudWatch – `aws logs tail /ecs/franchesny-pulseservice --follow`

**Possible causes:**
1. **Container crashloops** – App fails to start (e.g., missing dependencies, environment variables not set). Verify by checking task `lastStatus` and CloudWatch logs.
2. **Health check misconfiguration** – The app may not respond on port 8080 or the path `/health` may not return 200. Test locally with `docker run` or check logs.
3. **Security group or routing issue** – ECS tasks may not be reachable from ALB. Verify SG rules and that the target group is in the same VPC.

**Recovery:** Roll back to the previous image tag by running `terraform apply -var="image_tag=sha-<previous>"`. This will trigger a new deployment with the old image. Ensure `minimum_healthy_percent` and `maximum_percent` are set appropriately (not currently configured).

**Prevention:** Enable the commented health check in `cd.yml`, add CloudWatch alarms, and implement a canary/blue-green deployment.

---

## 9. Engineering Judgement (Short Answers)

### Architecture Choice
**Why ECS/Fargate?** It is a managed, serverless container service that minimizes operational overhead, provides native integration with ALB and IAM, and is cost-effective for a single service. EKS was rejected due to complexity and higher management burden.

### Reliability
**What happens if deployment fails health checks?** If `minimum_healthy_percent` is not set to 100, the service might temporarily have zero healthy tasks. The ALB will stop sending traffic to unhealthy tasks; if all are unhealthy, customers get 503. Rollback should be performed immediately.

**How to roll back?** Re-run Terraform with the previous image tag.

### Cost Drivers
1. **NAT Gateway** – recurring monthly fee (~$30–40). **Control:** Use a single NAT, or use VPC endpoints.
2. **Application Load Balancer** – hourly + LCU charges. **Control:** Keep it simple, enable idle timeout.

### Production Readiness
1. **Canary/blue-green deployments** – to minimize risk.
2. **Real ACM certificate** – replace self-signed with a publicly trusted cert.
3. **Full observability** – CloudWatch alarms, log retention, and tracing.

---

## 10. What is Missing / Known Gaps

- **Dockerfile** – not present; needed for CI builds.
- **Health check in CD** – commented out.
- **CloudWatch alarms & log group retention** – not implemented.
- **Real TLS certificate** – currently self-signed.
- **Autoscaling** – disabled (intentionally).
- **Environment separation** – only `prod` is defined; no `dev` environment.

---

## 11. How to Run / Deploy

1. **Dockerfile:** Add a multi-stage Dockerfile in `app/` that installs requirements and runs `uvicorn main:app --host 0.0.0.0 --port 8080`.
2. **Terraform (IAM):** In the IAM root, run `terraform init` and `terraform apply` to create the OIDC provider and deploy role.
3. **Terraform (Prod):** In `terraform/envs/prod`, run `terraform init` and `terraform apply -var="image_tag=sha-<commit>"` (the CD pipeline does this automatically).
4. **CI/CD:** Push to `main` triggers the workflows. The deploy role must have sufficient permissions.

---

## 12. Evidence of Operation

The repository **does not include** evidence of live deployment (e.g., Terraform plan output, Docker build logs). The user may run the workflows and capture outputs. Without a Dockerfile, the CI build will fail; after adding it, the pipeline should run.

---

## 13. Summary

This repository provides a solid foundation for the assessment, covering:
- A simple HTTP service with health/version endpoints
- Terraform infrastructure for VPC, ECS, ECR, ALB, IAM, and security groups
- OIDC-based GitHub Actions workflows for CI/CD and PR validation
- Least-privilege IAM policies scoped to the project

However, several items remain incomplete: the Dockerfile, health check in CD, monitoring/alarms, and a real certificate. These should be addressed for a fully production-ready solution.

---

*This documentation is based solely on the files provided. No claims are made about functionality that isn't explicitly implemented or configured.*




======


# Finzla Cloud & Platform Engineer Assessment – Repository Documentation

This README documents the contents of the `franchesny-ecs` repository as provided. It describes what is actually implemented and flags any gaps. The repository includes a **minimal FastAPI service**, **Terraform infrastructure** for AWS (VPC, ECS, ECR, ALB, IAM), **GitHub Actions CI/CD pipelines**, and an **OIDC-based authentication** mechanism. The Dockerfile is now included.

---

## 1. Repository Structure

```
franchesny-ecs/
├── app/
│   ├── Dockerfile               # Multi-stage build, non‑root user, Python 3.12 slim
│   ├── main.py                  # FastAPI application (health, version, root)
│   ├── test_main.py             # Unit tests for /health and /version
│   ├── requirements.txt         # Runtime dependencies
│   └── requirements-dev.txt     # Test dependencies
├── terraform/
│   ├── envs/prod/               # Production infrastructure (VPC, ECS, ALB, etc.)
│   │   ├── acm.tf
│   │   ├── alb.tf
│   │   ├── appservice.tf
│   │   ├── backend.tf
│   │   ├── ecr.tf
│   │   ├── ecs.tf
│   │   ├── iam.tf
│   │   ├── provider.tf
│   │   ├── sg.tf
│   │   ├── variables.tf
│   │   └── vpc.tf
│   └── (separate IAM/OIDC root)
│       ├── backend.tf
│       ├── provider.tf
│       ├── variables.tf
│       ├── oidc.tf
│       └── service-linkedroles.tf
└── .github/workflows/
    ├── deploy.yml                   # CI/CD pipeline
    └── validate.yml             # PR validation (terraform fmt/validate/plan, app tests, security scan)
```

---

## 2. Application

### 2.1 Source Code (`app/main.py`)
A FastAPI service with three endpoints:
- `GET /health` → `{"status": "ok"}` (HTTP 200)
- `GET /version` → returns version, git commit, build number, environment, and server time
- `GET /` → returns service metadata

Environment variables used: `APP_ENV`, `APP_VERSION`, `GIT_COMMIT`, `BUILD_NUMBER`. All logs are written to `stdout`/`stderr` – no file logging. No credentials or secrets are stored in the code.

### 2.2 Dockerfile (`app/Dockerfile`)
Multi-stage build:

- **Builder stage:** installs dependencies into a virtual environment (`/opt/venv`) using `requirements.txt`.
- **Runtime stage:** uses `python:3.12-slim`, adds build-time metadata (`APP_VERSION`, `GIT_COMMIT`, `BUILD_NUMBER`), creates a non‑root user (`appuser`), copies the virtual environment and the application source (`src/`), and runs `uvicorn src.main:app` on port `8080`. The container runs as a non‑root user, uses `PYTHONDONTWRITEBYTECODE` and `PYTHONUNBUFFERED`, and exposes port 8080.

> **Note:** The Dockerfile expects the application code to be inside `app/src/` (i.e., `src/main.py`). However, the actual Python file in the repository is `app/main.py`. For the Docker build to succeed, either the directory must be renamed or the `COPY` line adjusted. This is a discrepancy that should be corrected.

### 2.3 Tests (`app/test_main.py`)
Uses `fastapi.testclient` to test:
- `GET /health` returns `200` and `{"status": "ok"}`
- `GET /version` returns the expected fields (`version`, `git_commit`, `env`, `server_time_utc`)

### 2.4 Requirements
- **Runtime:** `fastapi==0.115.0`, `uvicorn[standard]==0.30.6`
- **Dev:** `pytest==8.3.3`, `httpx==0.27.2`

---

## 3. AWS Infrastructure (Terraform)

The Terraform code is split into two root modules:

### 3.1 Production Stack (`terraform/envs/prod/`)
| File | Purpose |
|------|---------|
| `backend.tf` | S3 remote state backend (bucket `franchesny-tfstate-acctid`, key `franchesny/prod/terraform.tfstate`, `use_lockfile = true`, `encrypt = true`). |
| `provider.tf` | AWS provider (version 6.63.0) using `var.aws_region`. |
| `variables.tf` | Defines `aws_region`, `project_name`, `environment`, `tags`, `image_tag`. |
| `vpc.tf` | Creates VPC (10.0.0.0/16) with two public/private subnets, a single NAT gateway, DNS hostnames and support enabled. |
| `sg.tf` | Security groups for ALB (HTTP/HTTPS from 0.0.0.0/0) and ECS tasks (ingress from ALB on port 8080, egress all). |
| `ecr.tf` | ECR repository `franchesny/pulseservice` with image scanning, mutable tags, force delete, and a lifecycle policy for untagged images. |
| `ecs.tf` | ECS cluster with FARGATE capacity provider. |
| `alb.tf` | ALB with HTTP→HTTPS redirect and HTTPS listener using a self‑signed ACM cert. Target group `pulsesvc_tg` on port 8080, health check path `/health`. |
| `appservice.tf` | ECS service `pulseservice` (256 CPU / 512 MB), attaches to the ALB target group, runs in private subnets, uses the ECS task and execution roles. |
| `iam.tf` | Creates ECS task execution role (with `AmazonECSTaskExecutionRolePolicy`) and an empty ECS task role. |
| `acm.tf` | Generates a self‑signed TLS certificate and imports it into ACM for the ALB. |

### 3.2 IAM / OIDC Setup (separate root)
| File | Purpose |
|------|---------|
| `backend.tf` | S3 backend for IAM state (bucket `permission-tfstate-716542960555`). |
| `provider.tf` | AWS provider. |
| `variables.tf` | Defines `aws_region` and `project_name`. |
| `oidc.tf` | Creates the GitHub OIDC provider, an IAM role (`franchesny-github-deploy-role`) with trust restricted to this repository (main branch and PRs), and attaches two least‑privilege policies. |
| `service-linkedroles.tf` | Creates the ECS service‑linked role. |

The two policies attached to the deploy role are carefully scoped to project resources (e.g., ECR repos with prefix `franchesny`, ECS services, ALB, VPC, IAM roles with prefix `franchesny-ecs-*`). The role **cannot** modify its own policy or access unrelated AWS resources.

---

## 4. CI/CD (GitHub Actions)

### 4.1 `ci.yml` – Build & Push
- Triggers on push to `main` when `app/**` or `ci.yml` changes.
- Steps: Checkout → Configure AWS credentials via OIDC → Login to ECR → Build and push image tagged `sha-<commit>` and `latest`.

### 4.2 `cd.yml` – Terraform Plan & Apply
- Triggers on push to `main` when `terraform/**` or `cd.yml` changes (plus manual dispatch).
- Steps: Checkout → Configure AWS credentials → Setup Terraform → `init` → `plan` → `apply -auto-approve`.  
- **Note:** The health‑check step is commented out. It should be enabled to verify the deployment after apply.

### 4.3 `validate.yml` – PR Validation
- Triggers on pull requests to `main` when `app/**`, `.github/workflows/**`, or `terraform/**` change.
- Jobs:
  1. **Terraform** – `fmt`, `init`, `validate`, `plan`.
  2. **App build & test** – Docker build (no push) and `pytest`.
  3. **Security scan** – Trivy in IaC mode on the `terraform` directory (critical severity only).

---

## 5. Security & Least Privilege

- **Authentication:** GitHub Actions assumes a deploy role via OIDC. No static AWS keys are stored.
- **Trust restrictions:** OIDC trust policy allows only the specific repository (`gunslingerrepo/franchesny-ecs`) for `main` branch and PRs.
- **IAM scoping:** The deploy role has two policies that are restricted to resources prefixed with `franchesny`. It cannot modify itself or access other projects.
- **Network isolation:** ECS tasks run in private subnets, accepting traffic only from the ALB security group. The ALB is the sole entry point.
- **TLS:** The ALB terminates HTTPS using a self‑signed ACM certificate (for production, a real certificate should be used).
- **No secrets** are committed.

---

## 6. Architectural Diagrams

### 6.1 Request Path (Internet → AWS → Application)

```
                        ┌─────────────────────────────────────────────┐
                        │                 Internet                    │
                        └───────────────────────┬─────────────────────┘
                                                │ HTTPS (443)
                                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                            Route 53 (optional)                       │
│                    DNS: pulse.suworks.me → ALB DNS                   │
└───────────────────────────────────┬─────────────────────────────────┘
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Load Balancer                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Public subnet (AZ-a)        ALB (internet‑facing)             │  │
│  └───────────────────────────────────────────────────────────────┘  │
│  • Listener 80 → Redirect to 443                                    │
│  • Listener 443 → HTTPS (self‑signed cert)                          │
│  • Target Group "pulsesvc_tg" (HTTP:8080, /health)                  │
└───────────────────────────────────┬─────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          ECS Cluster (Fargate)                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Private subnet (AZ-a)         ECS Task (pulseservice)          │  │
│  │   • FastAPI container on 8080                                   │  │
│  │   • Security group: ingress from ALB only                       │  │
│  │   • Pulls image from ECR                                        │  │
│  │   • Logs → CloudWatch                                          │  │
│  └───────────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │ Private subnet (AZ-b)         ECS Task (pulseservice)          │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────┬───────────────────────────────┘
                                      │ outbound only
                                      ▼
                              NAT Gateway → Internet
```

### 6.2 High‑Level AWS Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                              VPC                              │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Public Subnet (10.0.1.0/24)                            │  │
│  │  • ALB                                                 │  │
│  │  • NAT Gateway (single, in AZ-a)                       │  │
│  └─────────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Public Subnet (10.0.2.0/24)                            │  │
│  │  • (ALB can be in both AZs for HA; here only one shown) │  │
│  └─────────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Private Subnet (10.0.10.0/24)                          │  │
│  │  • ECS Tasks (Fargate) – pulseservice                   │  │
│  └─────────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  Private Subnet (10.0.11.0/24)                          │  │
│  │  • ECS Tasks (second AZ)                                │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
        │
        ▼
   ┌───────────┐
   │   ECR     │  ← ─ pushes images from GitHub Actions
   └───────────┘
        │
        ▼
   ┌───────────────┐
   │   ECS Cluster │  ← pulls images, runs tasks
   └───────────────┘
```

---

## 7. Monitoring & Alerts

The repository does **not** include CloudWatch alarms or log group retention settings. The assessment requires at least **3 metrics** and **2 alerts**. Below are the recommended (but not yet implemented) items:

**Metrics:**
- HTTP 5xx rate (from ALB)
- Target response time (from ALB)
- Unhealthy host count (from ALB)

**Alerts:**
- `5xx` rate > 5% for 5 minutes → on‑call engineer
- `UnhealthyHostCount` > 0 for 10 minutes → on‑call engineer

**Logging:** Application logs are sent to CloudWatch Logs via the ECS task execution role. Retention is not set; a `aws_cloudwatch_log_group` with `retention_in_days = 30` should be added.

---

## 8. Incident Investigation (Troubleshooting Exercise)

**Scenario:** New release deployed; GitHub Actions successful; ECS shows expected tasks running; customers get 503; ALB shows unhealthy targets.

**First steps:**
1. Check ALB target group health: `aws elbv2 describe-target-health --target-group-arn <tg-arn>`
2. Check ECS service events: `aws ecs describe-services --cluster <cluster> --services pulseservice`
3. Inspect task logs in CloudWatch.

**Possible causes:**
1. **Container crashloops** – App fails to start (missing dependencies, environment variables). Verify via task `lastStatus` and logs.
2. **Health check mismatch** – App does not respond on port 8080 or `/health` returns non‑200. Test locally with Docker.
3. **Security group / routing** – ECS tasks not reachable from ALB. Check SG rules and target group VPC.

**Recovery:** Roll back to previous image tag by running `terraform apply -var="image_tag=sha-<previous>"`. Set `minimum_healthy_percent = 100` and `maximum_percent = 200` to avoid downtime.

**Prevention:** Enable the commented health check in `cd.yml`, add CloudWatch alarms, and implement canary/blue‑green deployments.

---

## 9. Engineering Judgement

### Architecture Choice
**Why ECS/Fargate?** Managed, serverless container service with minimal operational overhead, native ALB integration, and IAM. EKS was rejected for complexity.

### Reliability
- If deployment fails health checks, the ALB will stop sending traffic to unhealthy tasks. With `minimum_healthy_percent` not set, there is a risk of zero healthy tasks. **Recommendation:** Set `minimum_healthy_percent = 100`.
- **Rollback:** Re‑run Terraform with the previous image tag.

### Cost
1. **NAT Gateway** – ~$30–40/month. Control: single NAT, VPC endpoints.
2. **ALB** – ~$20–25/month + LCU. Control: idle timeout, simplicity.

### Production Readiness – Top 3 Improvements
1. **Canary/blue‑green deployments** – use CodeDeploy or ALB weighted target groups.
2. **Real ACM certificate** – replace self‑signed cert with a publicly trusted one (DNS validated).
3. **Full observability** – CloudWatch alarms, log retention, and tracing (X‑Ray).

---

## 10. Five Solid Recommendations for Production

1. **Enable automatic health checks in `cd.yml`** – uncomment the health check step and point it to the actual ALB DNS name (or use the Terraform output). This ensures the pipeline fails if the deployment is broken.

2. **Add CloudWatch alarms and log retention** – create `aws_cloudwatch_metric_alarm` for high 5xx and unhealthy targets; add `aws_cloudwatch_log_group` with `retention_in_days = 30` (or 90 for audit). These are essential for proactive monitoring.

3. **Implement canary/blue‑green deployment** – use AWS CodeDeploy or ALB weighted target groups to shift traffic gradually, reducing risk of full outage.

4. **Replace the self‑signed certificate with a real ACM cert** – obtain a certificate for `pulse.suworks.me` (or similar) via DNS validation. This is critical for production traffic and user trust.

5. **Use a remote state lock and separate environments** – already done, but ensure the S3 bucket has versioning and MFA delete enabled. Also consider a `dev` environment with separate state and less restrictive IAM.

---

## 11. Known Gaps / Discrepancies

- **Dockerfile path mismatch:** The Dockerfile copies `src/`, but the application code is in `app/main.py`. Either move the code to `app/src/main.py` or update the `COPY` line.
- **Health check in CD:** Commented out – must be enabled.
- **No CloudWatch alarms or log groups** – not implemented in Terraform.
- **Self‑signed certificate** – not production‑ready.
- **Autoscaling disabled** – intentionally, but should be enabled for production.
- **No environment separation** – only `prod`; a `dev` environment is missing.

---

## 12. How to Run / Deploy

1. **Dockerfile:** Fix the path issue (move `main.py` to `app/src/main.py` or change the `COPY` command).
2. **Terraform IAM:** In the IAM root, run `terraform init` and `terraform apply`.
3. **Terraform Prod:** In `terraform/envs/prod`, run `terraform init` and `terraform apply -var="image_tag=sha-<commit>"`.
4. **CI/CD:** Push to `main` to trigger the pipelines.

---

*This documentation is based solely on the files provided in the repository. No claims are made about functionality not explicitly implemented.*
