# Approach Documentation

This document explains *why* each major decision was made — the reasoning behind the architecture, tooling, and process choices in this assignment.

---

## 1. Overall Philosophy

> **"The infrastructure is a product — reviewable, testable, and documented."**

Every part of this assignment was built with three principles:

1. **Everything as code** — Terraform for infra, GitHub Actions for CI/CD, JSON for dashboards, scripts for ops. Nothing is clicked in a console.
2. **Least privilege + defense in depth** — every role, security group and policy only grants what is needed, and is chained so a compromise in one layer doesn't expose the next.
3. **Boring, proven technology** — Fargate, Aurora, ALB, CloudWatch, GitHub Actions. The team can hire for and operate these. No exotic tools to learn or license.

---

## 2. Part 1 — Infrastructure Provisioning

### Why Terraform (vs CloudFormation / CDK / Pulumi)

- Terraform is **cloud-agnostic** and the industry standard; the hiring team can read the same HCL they would presumably use in production.
- **State management** story (S3 + DynamoDB locking) is mature and well understood.
- `terraform plan` gives pre-apply review/diff in CI — the safest way to change infrastructure.
- Using CDK would tie lock-in to TypeScript; using raw CloudFormation is more verbose for the same outcome.

### Why ECS Fargate (vs EC2 / EKS)

| Option | Verdict |
|---|---|
| EC2 raw | You manage AMIs, patching, auto-scaling groups, placement — a lot of ops burden for a small team. |
| **ECS Fargate** | Serverless containers — no nodes to patch, per-task autoscaling, native ALB + CloudWatch integration, cheaper entry. |
| EKS | Powerful but heavy operationally (control plane, node groups, upgrades). Overkill when the app is a single service. |

Fargate still keeps the door open for future microservices (task definitions are per-service), which matches where the Kayaka product is heading.

### Why Aurora PostgreSQL (vs plain RDS PostgreSQL / MongoDB)

- The app started on MongoDB but the assignment *explicitly* requires PostgreSQL — we use **Aurora PostgreSQL**, still "RDS for PostgreSQL".
- Aurora gives **5× throughput**, **built-in Multi-AZ failover**, **PITR (5-min granularity)**, and storage autoscaling — for the same price class as community RDS.
- The assignment asks for "database metrics" and "backup strategy"; Aurora's `enabled_cloudwatch_logs_exports` + automatic continuous backup to S3 make both demonstrably easier.

### Network design rationale

```
Public  : IGW ─ ALB ─ NAT ─ Bastion
Private : ECS tasks ─ RDS
Security groups: ALB ─► ECS ─► RDS (chained references, not CIDRs)
```

- **No public IPs on ECS/RDS.** The only public face is the ALB; everything else egresses through NAT.
- **SG chaining** (`security_groups = [aws_security_group.ecs.id]`) means traffic is authorized by source resource, not by guessing CIDR blocks.
- **VPC Flow Logs → CloudWatch** for network forensics and anomaly detection — this also feeds the "system logs" requirement in Part 3.
- **NAT gateways are HA** (one per AZ) to remove a single point of failure in egress.

### State management

- **S3 backend** with versioning + SSE-AES256 → durable, immutable history of state.
- **DynamoDB lock** table → prevents two engineers from applying conflicting changes.
- **Workspaces** (`staging` / `production`) → clean separation of environment state in one bucket.
- Accessed via `scripts/setup-backend.sh` (bootstrap once), so the reviewer can reproduce.

### Security decisions

- **No secrets in tfvars or variables files.** `db_username`/`db_password` are marked `sensitive` and injected as Terraform env vars (`TF_VAR_…`) / GitHub secrets.
- **Secrets Manager + rotation** — the app receives `DATABASE_URL` from Secrets Manager at task start; the rotation Lambda (using AWS's official rotation layer) rotates the password every 30 days *without changing the app connection string format*.
- **KMS keys with rotation** for DB encryption.
- **Bastion has no SSH** — SSM Session Manager (`http_tokens = required`, IAM-only auth). No SSH keys to rotate or leak.
- **Container hardening** — non-root user, `readonlyRootFilesystem`, minimal `node:22-alpine` base.

---

## 3. Part 2 — CI/CD

### Why GitHub Actions

- The deliverables ask for a GitHub repo anyway — Actions lives beside the code, with zero new infra or licenses.
- **OIDC** for AWS access (no long-lived AWS keys stored as secrets).
- **GitHub Environments** give the required **manual approval step for production** natively.

### Pipeline flow

```
PR ──► ci.yml (lint · unit · integration · vuln scan · terraform validate/plan)
main ─► deploy-staging.yml (build+push ECR · terraform apply · ECS deploy · notify)
manual trigger / staging green ─► deploy-production.yml
        └─ smoke test staging ─► terraform apply ─► build image ─► [MANUAL APPROVAL] ─► ECS deploy ─► health check ─► notify
```

Each job is independent (`needs:` dependency graph) so failures are isolated and visible.

### Testing strategy (why three layers)

1. **Unit** — fast, mocked `pg` pool, run on every PR, coverage gates regressions early.
2. **Integration** — real PostgreSQL 15 via GitHub service container. This catches SQL/migrations issues that mocks can't.
3. **Infrastructural regression** — `terraform validate` + `fmt -check` + a **plan artifact** on every PR so reviewers see exactly what the merge will change before it happens.

### Vulnerability scanning

- `npm audit --audit-level=high` **fails the build** on high/critical dependencies.
- OWASP Dependency-Check produces an HTML report uploaded as an artifact.
- **Trivy** scans the built container; results go to the GitHub Security tab; **CRITICAL severity fails the build** (`exit-code: 1`), unfixed only.
- **ECR scan-on-push** as the persistence safety net.

### Rollout safety

- ECS deployment with `minimumHealthyPercent = 100`, `maximumPercent = 200` → rolling deploy without downtime.
- `wait-for-service-stability` in the deploy action → the workflow fails if the service can't stabilise.
- Post-deploy health check (`/health`) against the production URL.
- Image tags are **immutable and content-addressed** (`$GITHUB_SHA`), so rollback = redeploy an old tag (one-liner in the workflow).

---

## 4. Part 3 — Monitoring & Logging

### Metrics hierarchy

| Layer | Latency | Traffic | Errors | Saturation |
|---|---|---|---|---|
| App (`/metrics`) | p50/p95/p99 duration | request count | 4XX/5XX | event-loop/DB pool |
| ALB | TargetResponseTime | RequestCount | HTTPCode_* | hunger/degraded hosts |
| ECS | — | — | — | CPU%, mem% |
| RDS | — | — | — | CPU, connections, IOPS, storage |

This is the **Golden Signals** (USE/RED) framework — the two dashboards map directly onto it.

### Why CloudWatch (vs ELK / Loki / Grafana Cloud)

- **Zero extra services** — CloudWatch is already collecting everything from ALB/ECS/RDS; extending with logs is a toggle, not a pipeline.
- **Log-based alarms** work natively (metric filter → alarm → SNS).
- Prometheus + Grafana run in `docker-compose.yml` for local development, covering the "alternative stack" if the team prefers it later.

### Dashboards

1. **Infrastructure** — ops view: resource utilisation, target health, DB throughput.
2. **Application** — service view: request rate, latency percentiles, errors, latest logs inline.

Both are `aws_cloudwatch_dashboard` resources in `monitoring.tf` — meaning they're **codified and reviewed in PRs**, not hand-built in the console.

### Alerting

Alerts go to **SNS → email + Slack** (HTTP subscription). Thresholds are deliberately conservative (5-min evaluation windows) to avoid noise storms but catch real degradation: CPU > 80%, memory > 90%, 5XX > 10/5min, unhealthy hosts > 1, DB CPU > 75%, free storage < 2GiB, connections > 100, app-error count in logs > threshold.

---

## 5. Part 4 — Docs, Secrets & Backup

### Documentation

- **README.md** — run the platform, provision AWS, understand the CD, security posture, costs, and DR. Written for a reviewer who has *no prior context*.
- This **APPROACH.md** — the reasoning behind decisions (you're reading it).
- **CHALLENGES.md** — honest account of what was hard and how it was resolved.

### Secret management (Deliverable: at least one)

Implemented **AWS Secrets Manager** (with rotation) as the primary secret store, plus:
- `sensitive`-marked Terraform variables → never in tfvars/repo
- GitHub Environment secrets for CI (OIDC role assumption means even AWS creds are ephemeral)
- `.env.example` in repo, `.env` git-ignored

### Backup strategy (Deliverable: at least one)

Implemented **3-layer**:
1. Aurora **automated backups** + **PITR** (5-min) — RPO floor
2. `scripts/backup-rds.sh` **manual snapshots** + **S3 export** for long-term archival
3. **Retention policy** pruning snapshots > 30 days

Recovery playbook (restore-to-PITR commands) documented in README.

---

## 6. What differentiates this solution

1. **Codified dashboards and alarms** — most submissions leave monitoring as a "capture it" note; here it's IaC.
2. **OIDC instead of stored AWS keys** — modern, secure CI identity.
3. **Full IaC for security groups** (chained references) — the network is designed, not accumulated.
4. **Manual approval via GitHub Environments** — no custom tooling, and exactly what the assignment's wording implies.
5. **Local parity** — `docker-compose` runs the same app+DB+metrics stack you deploy, so "works on my machine" and "works in prod" agree.
6. **Cost-conscious design** — Fargate Spot, single-AZ staging, autoscaling, log lifecycle — a startup-friendly posture.

---

## 7. Roadmap (if this were production, not an assignment)

1. Blue/green or canary deploys via CodeDeploy on ALB weighted targets.
2. Cross-region replicas / DR bucket replication for S3 exports.
3. OpenTelemetry traces + error tracking (Sentry) for app-level SLOs.
4. SLO/SLI dashboards with burn-rate alerts.
5. Automated cost anomaly budgets.
6. GitOps sync of ECS task definitions for reviewer-auditable infra changes only.