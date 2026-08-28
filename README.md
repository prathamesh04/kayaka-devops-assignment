# Kayaka DevOps Assignment

End-to-end infrastructure provisioning, deployment automation, monitoring and logging for the **Kayaka** application, following production-grade DevOps practices.

## Architecture Overview

```
                        ┌────────────────────────────────────────────┐
   Users  ─────────►    │   Application Load Balancer (public)      │
                        │   TLS 1.2/1.3 · HTTP→HTTPS redirect       │
                        └──────────────┬─────────────────────────────┘
                                       │
                                     port 3000
                        ┌──────────────▼─────────────────────────────┐
                        │   ECS Fargate — Kayaka App (private)       │
                        │   · Auto-scaling (CPU/Memory/Requests)     │
                        │   · /health, /ready, /metrics              │
                        └──────────────┬─────────────────────────────┘
                                       │ 5432 (only via SG)
                        ┌──────────────▼─────────────────────────────┐
                        │   Aurora PostgreSQL (RDS, private)         │
                        │   · Multi-AZ (prod) · Encrypted · PITR     │
                        └────────────────────────────────────────────┘

        ┌──────────────── Security Boundary ─────────────────────────────────┐
        │  ECS          : private subnets, no public IP, SG allow-listed     │
        │  RDS          : private subnets, no public access                   │
        │  Bastion      : public subnet, SSM Session Manager (no SSH keys)    │
        │  Secrets      : AWS Secrets Manager + rotation                       │
        └─────────────────────────────────────────────────────────────────────┘
```

**Core building blocks**

| Layer | Technology | Why |
|---|---|---|
| Compute | **ECS Fargate** | Serverless, no cluster management, per-task scaling |
| Database | **Aurora PostgreSQL 15** | Compatible with PostgreSQL, 5× throughput, Multi-AZ built-in |
| Load balancer | **ALB** | L7 routing, health checks, canary rollouts ready |
| Infrastructure | **Terraform** | IaC, remote state with locking, reviewable diffs |
| CI/CD | **GitHub Actions** | Native GitHub integration, OIDC (no long-lived keys) |
| Logs | **CloudWatch Logs** + **VPC Flow Logs** | Centralized, queryable, log-based alarms |
| Metrics | **CloudWatch** + **Prometheus (dev)** | INFRA + APP metrics, percentiles |
| Secrets | **AWS Secrets Manager** | Rotating credentials, KMS-encrypted |

---

## Repository Layout

```
├── app/                        # Sample Node.js application
│   ├── src/                    # Express API, pg pool, prometheus metrics
│   ├── tests/unit/             # Unit tests (mocked DB)
│   ├── tests/integration/      # Integration tests (real PostgreSQL)
│   └── Dockerfile              # Multi-stage, non-root, healthcheck
├── terraform/
│   ├── main.tf                 # Provider, backend (S3 + DynamoDB lock)
│   ├── variables.tf            # Configurable parameters
│   ├── vpc.tf                  # VPC, subnets, NAT, flow logs
│   ├── security_groups.tf      # Least-privilege SG rules
│   ├── alb.tf                  # ALB + S3 access logs
│   ├── ecs.tf                  # ECR, ECS cluster/task/service, autoscaling
│   ├── rds.tf                  # Aurora PG, Secrets Manager, rotation
│   ├── ec2.tf                  # Bastion (SSM-only)
│   ├── iam.tf                  # Least-privilege IAM roles
│   ├── monitoring.tf          # Dashboards + alarms + SNS
│   ├── outputs.tf              # Key resource references
│   └── environments/           # staging.tfvars / production.tfvars
├── bootstrap/
│   └── oidc.tf                 # GitHub Actions OIDC provider + staging/prod IAM roles
├── .github/workflows/
│   ├── ci.yml                  # Tests + vuln scan + terraform validate/plan
│   ├── deploy-staging.yml      # Auto-deploy on merge to main
│   └── deploy-production.yml   # Manual approval required
├── monitoring/
│   ├── dashboard_infrastructure.json
│   ├── dashboard_application.json
│   └── prometheus.yml
├── scripts/
│   ├── setup-backend.sh        # Terraform remote state bootstrap
│   └── backup-rds.sh           # Snapshot + S3 export + retention
└── docker-compose.yml          # Local dev (app + PG + Grafana)
```

---

## Quick Start — Local Development

Prerequisites: Docker, Node 22 (LTS), npm.

```bash
# 1. Start PostgreSQL + app + Grafana locally
docker compose up -d db

# 2. Apply schema and seed data
docker compose --profile tools run --rm migrate
docker compose --profile tools run --rm seed

# 3. Run the app
docker compose up -d app
curl http://localhost:3000/health
# → {"status":"healthy",...}

# 4. Run tests
cd app && npm ci && npm run test:unit

# 5. Observability (local)
docker compose up -d prometheus grafana
# Grafana → http://localhost:3001  (admin/admin)
# Prometheus → http://localhost:9090
```

---

## Provisioning AWS Infrastructure

### 1. Pre-requisites

- AWS account + CLI configured (`aws configure`)
- Terraform ≥ 1.5
- Permissions bounded by the `kayaka-infra-admin` role policy (see Security)

### 2. Bootstrap remote state

```bash
# Creates S3 bucket + DynamoDB lock table (run once per account)
./scripts/setup-backend.sh
```

### 3. Deploy staging

```bash
cd terraform
terraform init

# pass secrets without committing them
export TF_VAR_db_username="kayaka_admin"
export TF_VAR_db_password="$(openssl rand -base64 24)"

terraform workspace select -or-create staging
terraform plan   -var-file=environments/staging.tfvars
terraform apply  -var-file=environments/staging.tfvars
```

### 4. Deploy production

```bash
terraform workspace select -or-create production
terraform plan   -var-file=environments/production.tfvars
terraform apply  -var-file=environments/production.tfvars
```

The application is reachable at the ALB DNS printed in the output:

```
lb = http://kayaka-prod-alb-1234567890.ap-south-1.elb.amazonaws.com
```

### State management

| Aspect | Implementation |
|---|---|
| Backend | S3 bucket (`kayaka-terraform-state`), per-workspace keys |
| Locking | DynamoDB table `terraform-locks` (prevents concurrent applies) |
| Encryption | SSE-AES256 on S3 + versioning enabled |
| Separation | Distinct state per environment via workspaces |

### What Terraform provisions

- **VPC**: 1 (10.0.0.0/16), 2 public + 2 private subnets, IGW, 2 NAT gateways, VPC flow logs → CloudWatch
- **Compute**: Fargate tasks ×2 (prod), auto-scaling on CPU (70%), memory (75%), requests (1000/sec/target)
- **DB**: Aurora PostgreSQL 15, Multi-AZ in prod, encryption (KMS), Enhanced Monitoring, PITR backups
- **Load balancer**: ALB with HTTP→HTTPS redirect, S3 access logs, TLS 1.3 policy
- **Security groups**: least-privilege (ALB→ECS→RDS chain), no public DB
- **Secrets**: Secrets Manager secret + 30-day rotation Lambda
- **Monitoring**: 2 dashboards, 8+ alarms → SNS (email + Slack)

### Configurable parameters (`variables.tf`)

`vpc_cidr`, subnet CIDRs, `db_instance_class`, `ecs_cpu/memory`, `ecs_desired_count`, `backup_retention_period`, `domain_name`, `certificate_arn`, `allowed_cidr_blocks`, `enable_deletion_protection`, alert endpoints and more.

---

## CI/CD Pipelines

### Pull requests — `ci.yml`

Every PR to `main` and every push runs:

1. **Lint & format** (ESLint)
2. **Unit tests** + coverage (Vitest, mocked DB)
3. **Integration tests** against a real PostgreSQL 15 service container (GitHub Actions service)
4. **Dependency vulnerability scan** — `npm audit --audit-level=high` + OWASP Dependency-Check, report uploaded as artifact
5. **Container vulnerability scan** — `trivy` on the built image; HIGH/CRITICAL reported to GitHub Security tab, **build fails on CRITICAL**
6. **Terraform validate** — `init`, `validate`, `fmt -check`, plus a full **plan for staging** (via OIDC, staged state) uploaded as artifact

### Merge to `main` — `deploy-staging.yml`

On merge to main, automatically deploys to **staging**:

1. Configure AWS credentials **via OIDC OIDC federation** (no static keys in secrets)
2. Build multi-stage image → push to ECR (immutable tags by SHA)
3. `terraform apply` staging workspace (idempotent)
4. Render new image into ECS task definition → `aws ecs deploy` with **wait-for-service-stability**
5. Slack notification (success/failure)

### Production — `deploy-production.yml`

- Triggered via **`workflow_dispatch`** (manual) after staging is green, or automatically after a successful staging run
- **Manual approval gate**: job runs in the `production` GitHub Environment with a required reviewer
- Before deploying, a **smoke test** validates the staging `/health` endpoint
- Safe rollout: ECS deployment with min healthy 100% / max 200%, followed by a health check on the prod URL
- Slack notifications on both success and failure

> GitHub **Environments** provide the approval mechanism — no extra tooling needed. Secrets like `DB_USERNAME`/`DB_PASSWORD` and `SLACK_WEBHOOK_URL` are stored as GitHub encrypted secrets, per environment.

### One-time GitHub Actions setup (required before pipelines run)

The pipelines assume an AWS **OIDC role** per environment and a handful of repository secrets. Without these, the very first job fails with `Could not assume role with OIDC: Request ARN is invalid` (a missing `AWS_ACCOUNT_ID`).

**1. Apply the OIDC provider + IAM roles** (run once with account-level credentials):

```bash
cd bootstrap
terraform init        # uses the same S3 backend and lock table
terraform apply
# creates: token.actions.githubusercontent.com OIDC provider,
#          roles github-actions-staging and github-actions-production
# Trust is scoped to repo:prathamesh04/kayaka-devops-assignment:*
```

**2. Add GitHub repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Description |
|---|---|
| `AWS_ACCOUNT_ID` | 12-digit AWS account ID (used to build the role ARN) |
| `DB_USERNAME` / `DB_PASSWORD` | RDS admin credentials, injected via `TF_VAR_*` |
| `STAGING_URL` / `PRODUCTION_URL` | ALB endpoints for smoke/health checks |
| `SLACK_WEBHOOK_URL` | Notifications channel |

The `staging` / `production` GitHub **Environments** can additionally gate with required reviewers (the production pipeline's approval gate).

**3. Push to `main`** — `ci.yml` runs on the PR; merging triggers the staging deploy, and a completed staging run with `workflow_dispatch` triggers production.

---

## Monitoring & Logging

### Metrics (by layer)

| Layer | Metrics | Source |
|---|---|---|
| **Infra** | CPU, memory (ECS) · target health, latency p95 (ALB) | CloudWatch |
| **Application** | request rate, error rate, latency p50/p95/p99, DB pool | App `/metrics` (prom-client) |
| **Database** | CPU, FreeableMemory, connections, IOPS, Deadlocks | CloudWatch RDS |

### Dashboards (2 shipped)

1. **dashboard_infrastructure.json** — ECS resource utilization, ALB requests/latency/errors, RDS instance + throughput metrics, target health
2. **dashboard_application.json** — request rate, API latency percentiles, error rate (4XX/5XX), resource usage, latest application logs widget

### Centralized logging

| Log source | Destination | Retention |
|---|---|---|
| Application logs (winston JSON) | CloudWatch Logs `/ecs/{env}/app` | 30 days |
| Access logs (morgan) | CloudWatch Logs (same group) | 30 days |
| VPC flow logs (ALL traffic) | CloudWatch Logs `/aws/vpc/flow-logs/{env}` | 30 days |
| RDS PostgreSQL logs | CloudWatch Logs (enabled exports) | 30 days |
| ALB access logs | S3 (`{env}-alb-logs-{acct}`) | 30 days lifecycle |

**Log-based alerting**: metric filter on `"level":"error"` → alarm `ApplicationErrorCount` → SNS.

### Alarms (SNS → Slack + email)

- ECS CPU > 80%, ECS memory > 90%
- ALB 5XX, unhealthy hosts
- RDS CPU > 75%, free storage < 2GiB, connections > 100
- Application error count > threshold

---

## Security Considerations

| Control | Implementation |
|---|---|
| **Secrets management** | AWS Secrets Manager + KMS, 30-day rotation via Lambda, never in repos / task definitions |
| **Identity** | GitHub Actions uses **OIDC** (role assumption, no static keys) · **IAM least privilege** per role |
| **Network security** | Private subnets for ECS/RDS · security-group chaining (ALB→ECS→RDS) · no public DB · NAT-only egress |
| **TLS everywhere** | HTTPS via ACM cert, TLS 1.2–1.3 only, HTTP→HTTPS redirect, `drop_invalid_header_fields` |
| **Encryption at rest** | RDS/KMS rotated keys, EBS encrypted, S3 SSE + public access blocked |
| **Containers** | Non-root user, `readonlyRootFilesystem`, minimal alpine image, trivy + ECR scan-on-push |
| **Dependencies** | `npm audit` (fail on high) + OWASP Dependency Check in CI |
| **Observability** | VPC flow logs for network forensics, CloudWatch alarms for anomalies |
| **Secret scanning** | GitHub pushes scanned by secret scanning (GitHub native) |
| **Backups** | RDS automated backups + manual snapshots with 30-day retention |

### IAM roles (least privilege)

- `ecs-execution`: ECR pull, logs, SecretsManager GetSecretValue (pinned ARN), KMS Decrypt
- `ecs-task`: CloudWatch PutMetricData (scoped namespace), logs
- `rds-monitoring`: Enhanced Monitoring only
- `vpc-flow`: put flow logs only
- `bastion`: SSM Session Manager + SecretsManager read
- CI/CD roles: `github-actions-staging` / `github-actions-production`

---

## Backup Strategy

### Automated (built-in)

- **RDS automated backups**: enabled by default, retention 7 days (staging) / **30 days** (prod)
- **PITR**: Aurora continuous backup to S3 (5-minute granularity) — restorable to any point in time
- **Manual snapshots**: via `scripts/backup-rds.sh`

### Manual / long-term

```bash
# Manual snapshot + optional S3 export
./scripts/backup-rds.sh kayaka kayaka-production-db my-backup-bucket
```

- Creates `kayaka-production-db-backup-YYYY-MM-DD-HH-MM`
- Optionally exports to S3 for long-term archival
- Enforces a **30-day retention** policy (auto-deletes snapshots older than the cutoff)

### Recovery (RTO/RPO)

| Scenario | RPO | RTO |
|---|---|---|
| DB failure (Single-AZ → restore snapshot) | ~5–15 min (PITR) | ~15–30 min |
| Multi-AZ failover (prod) | 0 | ~60–120 sec (automatic) |
| Full region loss | 0 (S3 exports) | hours (bucket + cross-region restore procedure documented) |

### Restore steps

```bash
# Restore from PITR
aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier kayaka-production-db \
  --restore-to-time 2026-08-26T20:00:00Z \
  --db-cluster-identifier kayaka-production-db-restored
```

---

## Cost Optimization

| Measure | Saving |
|---|---|
| **Fargate Spot** capacity provider (base 1, weight 1) | ~70% cheaper on on-demand for workload tasks |
| **Autoscaling** down to min capacity outside peak | no idle capacity |
| `db.t3.medium` and right-sizing via variables | predictable spend; scale type, not count |
| Storage autoscaling on RDS (`max_allocated_storage`) | pay only for used storage |
| ALB/S3 log lifecycle 30-day expiry | capped log storage |
| Single-AZ Aurora for staging, Multi-AZ prod | staging at ~half DB cost |
| ECR lifecycle policy keeps last 30 images | bounded registry storage |

---

## Assumptions & Trade-offs

1. **Aurora instead of plain RDS Postgres**: assignment says "RDS for PostgreSQL"; Aurora is the AWS PostgreSQL engine on RDS — chosen for 5× throughput, Multi-AZ, and PITR. A community-edition RDS instance config is drop-in replaceable in `rds.tf`.
2. **ECS/Fargate over EC2/vanilla EKS**: serverless ops fits a small startup team; you get autoscaling, logging and deployability with far less operational surface.
3. **Terraform Cloud managed**: state in **our** S3 (not TFC) to keep everything in-repo and auditable.
4. **A single sample app** powers both environments — realistic, simple, and focused on the platform concerns the assignment targets.
5. **GitHub Environments** are the manual-approval mechanism — no extra CI tooling license needed.

---

## Extendability / Roadmap

- **Canary deployments** via ALB weighted target groups / CodeDeploy blue-green (prepared: deploy controller ready for it)
- **Cost visibility**: AWS Budgets + cost anomaly alerts
- **Cross-region DR**: copy RDS final snapshots / S3 export to a standby region
- **GitOps**: ArgoCD-style sync for task definitions once config grows
- **Error tracking**: Sentry integration on the app side

---

## Security Contact

For infrastructure or security issues: devops@kayaka.work