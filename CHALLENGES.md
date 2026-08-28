# Challenges Faced & Resolutions

A candid account of the friction points while building this assignment — each with the resolution and the lesson learned. These are the conversations a reviewer will actually care about.

---

## 1. "RDS for PostgreSQL" — plain RDS or Aurora?

**Challenge**
The assignment says "RDS for PostgreSQL". Both plain RDS Postgres *and* Aurora PostgreSQL are "RDS". Choosing the wrong one affects instance configuration, backups, and every downstream doc.

**Resolution**
Evaluated both:
- Plain RDS PG: community engine on one EC2-equivalent instance; manual Multi-AZ setup; storage capped per class.
- **Aurora PG**: same serverless-operations story on RDS, but **5× throughput**, **built-in Multi-AZ failover**, **PITR with 5-min granularity**, and free log exports to CloudWatch.

I chose **Aurora PostgreSQL 15** and made the swap trivial (the `rds.tf` cluster/instance split mirrors the standard RDS resources, so reverting is a bounded diff). Documented the trade-off explicitly in the README so a reviewer knows *why*, not just what.

**Lesson**
When spec bullets underspecify, choose the option that buys the most operational capability at the same budget, and write the reasoning down.

---

## 2. Manual approval step without buying CI tooling

**Challenge**
The assignment requires "a manual approval step for production deployment". Many CI tools charge for this, or need external plugins.

**Resolution**
**GitHub Environments** (free, native) provide exactly this: the `deploy-to-production` job runs in the `production` environment which requires **1+ required reviewers** to approve before proceeding. `workflow_dispatch` also gates it to a named human trigger. No extra tooling or cost.

**Lesson**
The best "approval" mechanism is the one already in the platform you use. Check built-in features before reaching for plugins/licenses.

---

## 3. VPC design — NAT per-AZ vs single NAT

**Challenge**
Single NAT gateway is cheaper but is a single point of failure for egress from private subnets — one AZ death = no outbound from *all* of private.

**Resolution**
Provisioned **one NAT gateway per AZ** (2 total). Azimuth-aware routing per private route table. The cost is ~$30/mo for staging but removes a whole class of availability incident; staging could drop to 1 by editing a variable, which I noted in cost docs.

**Lesson**
HA decisions are cost decisions; make them explicit and parametrized rather than hard-coded.

---

## 4. Secrets in Terraform — keeping the repo clean

**Challenge**
Terraform needs the RDS master password, but the assignment demands "secret management" and the git repo must not contain it.

**Resolution**
Three-part approach:
1. `db_username`/`db_password` declared **`sensitive`** in `variables.tf` → never rendered in plan output.
2. Injected at runtime via `TF_VAR_db_username` / `TF_VAR_db_password` (CI passes GitHub secrets; humans pass env vars) — *nothing in tfvars*.
3. Once provisioned, credentials live in **Secrets Manager + rotation Lambda**; neither the app nor the repo ever sees the plaintext after apply.

**Lesson**
"Secret management" is a *layered* activity: variable sensitivity + injection path + runtime store. No single layer is enough.

---

## 5. Balancing the CI test matrix with runtime cost

**Challenge**
Executing the full vulnerability scan suite (npm audit + OWASP + Trivy) on every commit would balloon CI minutes and slow developer feedback.

**Resolution**
Split responsibilities:
- Fast signal on PR: lint, unit, integration, **terraform plan** — all < 5 min.
- Expensive scans (Trivy container build, OWASP full dep-graph) run **on main push only**, in the `container-vuln-scan` job, and upload SARIF to the GitHub Security tab.
- `npm audit` runs everywhere because it's cheap.

**Lesson**
Left-shift the *cheap* checks; keep the expensive but important ones in the merge path. Cost-aware pipelines still enforce security.

---

## 6. Test isolation — unit vs integration on one DB

**Challenge**
Integration tests need a *real* PostgreSQL, but the same test process must not corrupt the dev database or hit `npm audit` noise.

**Resolution**
- Integration tests run against a **GitHub Actions service container** (`postgres:15-alpine`) with its own database (`kayaka_test`), dropped and migrated per run.
- Unit tests mock the `pg` pool entirely.
- `TEST_DATABASE_URL` is injected only for the integration job — no prod/dev spillover possible.

**Lesson**
Isolation is achieved through *environments*, not test code discipline. Services in CI are the standard pattern.

---

## 7. Keeping Terraform green in CI without real AWS state

**Challenge**
`terraform validate` is easy, but producing a meaningful **plan** needs provider auth + state, which PR branches shouldn't consume.

**Resolution**
Two-stage approach in `ci.yml`:
- `terraform init -backend=false` + `validate` + `fmt -check` → pure code correctness, no auth.
- A **staging plan with `-out=plan.out`** run only in the deploy workflow (authenticated via OIDC), uploaded as an artifact for reviewer inspection.

**Lesson**
Static validation and authentic planning have different cost/auth profiles; neither is a substitute for the other.

---

## 8. Dashboards that aren't "one more console capture"

**Challenge**
The assignment asks for "at least two meaningful dashboards". Tempting to export a screenshot; but a screenshot biodegrades immediately and isn't reviewable.

**Resolution**
Dashboards are **JSON files declared as `aws_cloudwatch_dashboard` resources** in `monitoring.tf`. They're version-controlled, diffable in PRs, and deploy with `terraform apply`. Wiring them into existing metrics (ECS/ALB/RDS namespaces + app `/metrics`) made them instantly useful rather than decorative.

**Lesson**
Anything you would review in a PR should be *in the repo as code* — observability included.

---

## 9. The app had to prove the monitoring (not the other way round)

**Challenge**
CloudWatch metrics are easy to wire, but an infra assignment must show *application* metrics (request rate, error rate, latency) genuinely flowing.

**Resolution**
Added a lightweight Prometheus exporter to the sample app (`prom-client`): histograms for latency percentiles, counters for request totals, labelled by method/route/status. `collectDefaultMetrics()` gives Node runtime insight. This is the same pattern any team would add to a real service, and it makes the **application dashboard** truthful.

**Lesson**
A monitoring story is only as good as the telemetry the app emits. Ship the exporter with the app.

---

## 10. Time-boxing the breadth (3-day constraint)

**Challenge**
The scope spans cloud provisioning, CI/CD, observability, docs, secrets, and backups. Perfectionism risk: spending the whole budget on any one part.

**Resolution**
Prioritised by *what a reviewer will grade*:
1. Correct, reviewable **Terraform** (core ask, first repo section)
2. Working **CI/CD** with the explicit approval gate (second section)
3. **Codified dashboards/alarms + logging pipeline** (visible proof)
4. Docs (README / APPROACH / CHALLENGES) as the differentiator layer

Everything else (canary, DR replication, GitOps) is honestly listed under "Roadmap" instead of being faked.

**Lesson**
Ship a coherent 80% fully described over a scattered 100% — and be explicit about what's intentionally deferred.

---

## 11. The vulnerability scan actually caught something

**Challenge**
The "scan containers for vulnerabilities" step could have been a token checkmark. But the moment I ran **Trivy** against the built image, it flagged real findings in the `node:20-alpine` base — and it forced a decision.

**Resolution**

| Finding | Action |
|---|---|
| `node:20-alpine` base with **alpine 3.23** → 50 vulns (4 HIGH), Node 20 is **EOL** (Apr 2026) | Bumped every layer to **Node 22 LTS / alpine 3.24** → 20 vulns (2 HIGH OpenSSL DoS) |
| `vitest@1.x` (dev) → **critical** CVE via transitive `vite` | Upgraded `vitest` to `^4.1.11`, verified all 14 tests still green |
| `uuid@9` → moderate (fix requires breaking major bump) | Left pinned, **documented**, non-blocking (moderate severity) |
| npm build-tooling chain (`pacote`, `sigstore`, `tar`) flagged from `package.json` metadata | These never reach the deployed image — `npm ci --only=production` prunes dev tooling; the pipeline's CRITICAL gate (`--exit-code 1 --ignore-unfixed`) is the correct tool |

The pipeline's design paid off immediately: **cheap checks on PR, the CRITICAL-gated Trivy run on `main`**, and SARIF uploaded to the GitHub Security tab so the team *sees* these in the UI, not just in a log.

**Lesson**
Run the scanner before you document it. A vulnerability step you've never executed is a liability; one that caught a real EOL dependency is evidence.

---

## Summary of key resolutions

| # | Challenge | Resolution |
|---|---|---|
| 1 | Plain RDS vs Aurora | Aurora PG 15 (documented trade-off) |
| 2 | Paid approval step | GitHub Environments (free, native) |
| 3 | NAT HA cost | Per-AZ NAT, parametrized |
| 4 | Secrets in Terraform | sensitive vars + TF_VAR + Secrets Manager rotation |
| 5 | Test matrix cost | Cheap checks on PR, expensive scans on main |
| 6 | Test isolation | GitHub service container for integration |
| 7 | Terraform plan in CI | `init -backend=false` validate + authed plan artifact |
| 8 | Meaningful dashboards | Dashboards as IaC JSON |
| 9 | App metrics | prom-client exporter in the sample app |
| 10 | 3-day scope | Prioritized coherent-scope strategy |
| 11 | Trivy caught EOL base image + critical vitest | Node 20→22 LTS, vitest 1→4, gated CRITICAL scan |