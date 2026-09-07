# Finzla Cloud & Platform Engineer Assessment

[![PR Validation](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/validate.yml/badge.svg)](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/validate.yml)
[![CI/CD - Franchesny](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/deploy.yml/badge.svg)](https://github.com/gunslingerrepo/franchesny-ecs/actions/workflows/deploy.yml)

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

### 4.1 `deploy.yml` – Build & Push | Terraform Plan & Apply
- Triggers on push to `main` when `app/**` or `deploy.yml` changes.
- Steps: Checkout → Configure AWS credentials via OIDC → Login to ECR → Build and push image tagged `sha-<commit>` and `latest`.
- Triggers on push to `main` when `terraform/**` or `deploy.yml` changes (plus manual dispatch).
- Steps: Checkout → Configure AWS credentials → Setup Terraform → `init` → `plan` → `apply -auto-approve`.  

### 4.2 `validate.yml` – PR Validation
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

## 8. Engineering Judgement

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

## 9. Five Solid Recommendations for Production

1. **Enable automatic health checks in `deploy.yml`** – uncomment the health check step and point it to the actual ALB DNS name (or use the Terraform output). This ensures the pipeline fails if the deployment is broken.

2. **Add CloudWatch alarms and log retention** – create `aws_cloudwatch_metric_alarm` for high 5xx and unhealthy targets; add `aws_cloudwatch_log_group` with `retention_in_days = 30` (or 90 for audit). These are essential for proactive monitoring.

3. **Implement canary/blue‑green deployment** – use AWS CodeDeploy or ALB weighted target groups to shift traffic gradually, reducing risk of full outage.

4. **Replace the self‑signed certificate with a real ACM cert** – obtain a certificate for `pulse.suworks.me` (or similar) via DNS validation. This is critical for production traffic and user trust.

5. **Use a remote state lock and separate environments** – already done, but ensure the S3 bucket has versioning and MFA delete enabled. Also consider a `dev` environment with separate state and less restrictive IAM.

---
