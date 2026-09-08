# Phase 16: Building a Complete SRE Observability Platform on AWS EKS — End-to-End Summary

*Part 16 of 16 in the SRE Observability on AWS EKS with Datadog series*

---

## What We Built

This series set out to build a production-style SRE observability platform from scratch — not by clicking through managed services and calling it done, but by constructing each layer deliberately, understanding why it exists, and documenting every real problem encountered along the way.

16 phases. 16 articles. One working platform.

Here is the complete picture.

---

## The Full Architecture

```
Developer (VSCode + WSL2 Ubuntu)
         |
         v
    GitHub Repository
         |
    +----+----+
    |         |
   CI         CD
(PR tests) (main deploy)
    |         |
    v         v
Docker Build → AWS ECR
                |
                v
            AWS EKS (us-east-1)
            |            |
         App Pod      Datadog Agent (DaemonSet)
         (FastAPI)         |
            |         +---------+
            |         |         |
            +----+----+         |
                 |              |
            Datadog Cloud       |
                 |              |
         +-------+--------+     |
         |       |        |     |
      Metrics   Logs   Traces   |
         |       |        |     |
         +-------+--------+-----+
                 |
         Golden Signals Dashboard
         SLIs / SLOs / Error Budgets
         Monitors / Alerts
         Incident Automation
         Chaos Validation
         Terraform as Code
```

---

## Phase-by-Phase Summary

### Phase 1 — FastAPI Application
Built the demo service with three signal-generating endpoints: normal traffic (`/api/products`, `/api/orders`, `/api/users`), latency simulation (`/api/slow`), and error simulation (`/api/error`). Instrumented with ddtrace for APM and structlog for JSON logging.

**Key fix:** ddtrace required Python 3.12 — incompatible with Python 3.14.

---

### Phase 2 — AWS Infrastructure with Terraform
Provisioned VPC, EKS cluster (`sre-demo-dev-eks-cluster`, K8s 1.32, t3.small nodes), and ECR repository using official Terraform modules.

**Key fixes:** AdministratorAccess for terraform IAM user; disabled KMS encryption config; enabled `map_public_ip_on_launch` on public subnets.

---

### Phase 3 — Kubernetes Deployment
Deployed the app to EKS with a full Kubernetes manifest set — namespace, deployment, LoadBalancer service, ConfigMap, HPA. Used kubeconform for offline manifest validation.

---

### Phase 4 — GitHub Actions CI/CD
Built two pipelines: CI (lint → test → build → Trivy scan on PRs) and CD (build → push ECR → deploy EKS → smoke test on main). Path-filtered to only trigger on relevant file changes.

**Key fix:** OIDC authentication abandoned due to unresolved IAM trust policy sub claim mismatch — using AWS access keys as workaround.

---

### Phase 5 — Datadog Agent on EKS
Installed the Datadog agent as a DaemonSet via Helm with a custom `values.yaml` enabling APM, log collection, process monitoring, and Kubernetes state metrics.

**Key fix:** `datadog.env` required a string value, not a map — resolved a range iteration error in the Helm chart.

---

### Phase 6 — Kubernetes Infrastructure Monitoring
Enabled the Kubernetes integration in Datadog. Kubernetes Explorer showing cluster health — 1 node, 9 pods, 5 deployments — all visible with live metrics.

---

### Phase 7 — Datadog APM
Enabled distributed tracing using `ddtrace-run` with `patch(fastapi=True)`. Flame graphs visible in Datadog APM for all instrumented endpoints.

**Key fix:** `patch()` must be called before FastAPI import — import order matters for monkey-patching.

---

### Phase 8 — Log-Trace Correlation
Connected structured logs to APM traces using `dd.trace_id` in every log entry. Clicking a trace ID in Log Explorer opens the full APM flame graph.

**Key fix:** `dd.trace_id` (dot notation) — not `dd_trace_id` (underscore). The underscore variant is not recognised by Datadog's correlation engine.

---

### Phase 9 — Golden Signals Dashboard
Built the four golden signals dashboard in Datadog — Traffic (request rate), Latency (p50/p95/p99), Errors (rate + percentage), Saturation (pod CPU and memory). All metrics sourced from `trace.fastapi.request` APM metrics.

---

### Phase 10 — SLIs, SLOs, Error Budgets
Defined two SLOs: Availability (99% target, non-5xx / total requests) and Latency (90% target, p99 < 2s). Error budget tracking visible in Datadog SLO status page.

---

### Phase 11 — Monitors and Alerting
Created 5 custom monitors covering all major failure modes:

| Monitor | Priority | Threshold |
|---|---|---|
| API Availability - No Traffic | P1 Critical | requests < 1 in 5m |
| High Error Rate | P2 High | errors > 10 in 5m |
| Pod Restart Rate | P2 High | restarts > 3 in 15m |
| SLO Error Budget Burn Rate | P2 High | error rate > 1% |
| High p99 Latency | P3 Medium | p99 > 2s in 5m |

---

### Phase 12 — Incident Automation
Built a Datadog workflow triggered by the P1 monitor: monitor alert → auto-create SEV-1 incident in Incident Response. Created runbooks for all 5 monitors in `docs/runbooks/`.

---

### Phase 13 — Chaos Engineering and Failure Injection
Ran 4 real failure scenarios against the live platform:

| Scenario | Method | Monitor Triggered |
|---|---|---|
| High Error Rate | Flood `/api/error` | P2 High Error Rate ✅ |
| High Latency | Flood `/api/slow` | P3 High Latency ✅ |
| Pod CrashLoopBackOff | kubectl patch command override | P2 Pod Restart ✅ |
| Availability Drop | Scale to 0 replicas | P1 Availability ✅ |

All 5 monitors fired correctly. The P1 incident auto-creation workflow triggered without manual intervention. `restore-all.sh` recovered the deployment cleanly every time.

**Key fixes:** `/api/` prefix on all endpoints; `ddtrace` silently ignores a bad trace agent URL — use `kubectl patch` with `exit 1` to force CrashLoopBackOff; fixed double-else bash syntax bug in `restore-all.sh`.

---

### Phase 14 — Incident Investigation
Documented the full investigation methodology across all 4 chaos scenarios — the Datadog tool sequence, what each signal means, and the diagnostic patterns that apply to any incident.

**Core pattern:** Monitors → APM traffic shape → Traces → Logs → Kubernetes Explorer. When APM shows zero traffic, the problem is upstream of the app — go to Kubernetes, not logs.

---

### Phase 15 — Datadog as Code with Terraform
Converted all manually created Datadog resources into Terraform using the Datadog provider. API and APP keys fetched from AWS Secrets Manager — no manual key exports.

```
terraform apply → 5 monitors + 2 SLOs + 1 dashboard created
```

**Key fixes:** APP key requires explicit scope selection at creation time — Datadog does not show the key again; `burn_rate()` query not available on all plans — replaced with error rate percentage; org tag policy restricts tag keys to `team` and `ai` only.

---

## The Complete Technology Stack

| Layer | Technology |
|---|---|
| Cloud | AWS (EKS, ECR, VPC, IAM, ELB) |
| Infrastructure as Code | Terraform (AWS + Datadog providers) |
| Containers | Docker, Kubernetes 1.32, Helm |
| Observability | Datadog (APM, Logs, Metrics, Dashboards, Monitors, SLOs, Incidents) |
| CI/CD | GitHub Actions |
| Application | Python 3.12, FastAPI, ddtrace, structlog |
| Scripting | Bash (infra-up, infra-down, chaos, restore) |
| OS | Linux (WSL2 Ubuntu on Windows 11) |

---

## Every Lesson Learned

The real value of building in public is the problems — not the happy path. Here are the most useful ones from across all 16 phases:

**Application:**
- `patch(fastapi=True)` must come before the FastAPI import
- `dd.trace_id` not `dd_trace_id` — dot notation only
- ddtrace silently ignores a missing trace agent — it never crashes the app

**Kubernetes:**
- LoadBalancer services must be deleted before `terraform destroy` — orphaned ELBs block VPC deletion
- `map_public_ip_on_launch = true` must be explicit in Terraform VPC configs
- CrashLoopBackOff investigation starts at container stdout, not application logs
- `kubectl patch` with `exit 1` is the most reliable crash injection method

**Terraform:**
- Disable KMS encryption config on EKS recreation to avoid key access failures
- Keep Datadog state separate from AWS state — independent lifecycles
- Datadog APP key scopes must be set at creation — the key is only shown once
- `burn_rate()` monitor query requires a higher Datadog plan tier
- Datadog org tag policies surface only at apply time — check before writing HCL

**GitHub Actions:**
- OIDC IAM trust policy sub claim formatting is a common pitfall — verify the exact claim format before abandoning OIDC
- Path filters on `app/**`, `kubernetes/**`, `.github/workflows/**` prevent unnecessary pipeline runs

**Observability:**
- APM traffic shape (volume + errors + latency together) is the fastest triage signal
- p50 vs p99 divergence always means a subset problem, not systemic
- Log-trace correlation with `dd.trace_id` turns logs from noise into APM navigation
- Automated incident creation reduces MTTR by starting the timeline before any human acts

---

## What a Production Hardening Roadmap Looks Like

This platform is a strong foundation. Here is what the next iteration would add:

**Security:**
- Resolve GitHub Actions OIDC authentication (eliminate long-lived access keys)
- Enable EKS IRSA (IAM Roles for Service Accounts) — remove node-level AWS permissions
- Add Trivy scanning results to Datadog Security

**Reliability:**
- Multi-node EKS node group — single t3.small is a single point of failure
- Pod Disruption Budgets to protect against simultaneous eviction
- Liveness and readiness probes tuned to actual app startup time

**Observability:**
- Synthetic monitors in Datadog — external availability checks independent of agent health
- Custom business metrics (orders processed, users registered) beyond golden signals
- Datadog SLO alerts wired to PagerDuty or OpsGenie for real on-call routing

**Operations:**
- S3 backend for Terraform state — enables team collaboration and state locking
- Datadog Terraform in CI/CD — observability config changes go through pull request review
- Scheduled chaos game days — quarterly validation that monitors still fire correctly

---

## Repository at a Glance

```
sre-observability-eks-datadog/
├── app/                          # FastAPI application + tests
├── infrastructure/terraform/     # AWS infra (VPC, EKS, ECR)
│   └── datadog/                  # Datadog as Code (Phase 15)
├── kubernetes/                   # K8s manifests
├── datadog/agent/                # Helm values + install script
├── scripts/
│   ├── infra-up.sh               # One command to start everything
│   ├── infra-down.sh             # Safe teardown with correct ordering
│   └── chaos/                    # Phase 13 failure injection scripts
├── docs/
│   ├── medium/                   # All 16 article drafts
│   ├── runbooks/                 # 5 monitor runbooks
│   └── screenshots/              # Phase-by-phase screenshots
└── .github/workflows/            # CI + CD pipelines
```

---

## Final Numbers

| Metric | Value |
|---|---|
| Phases completed | 16 / 16 |
| Medium articles written | 16 |
| AWS resources (Terraform) | 47 |
| Datadog resources (Terraform) | 8 |
| Monitors created | 5 |
| SLOs defined | 2 |
| Chaos scenarios validated | 4 |
| Monitors that fired correctly | 5 / 5 |
| Scripts written | 12+ |
| Real issues documented | 20+ |

---

## Closing

Every phase in this series was validated against a real running environment before the article was written. The problems are real, the fixes are real, and the platform works.

The goal was never to build the most complex observability setup — it was to build one that a working SRE engineer would recognise as honest, practical, and production-minded. Something that demonstrates not just familiarity with the tools, but understanding of why they exist and what they tell you when things break.

That goal is met.

---

*All code: [github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)*

*Thank you for following along.*