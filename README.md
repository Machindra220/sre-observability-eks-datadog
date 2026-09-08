# SRE Observability Platform — AWS EKS + Datadog

A production-style SRE observability platform built on AWS EKS with Datadog,
documented as a 16-part Medium article series.

---

## Project Overview

This project demonstrates a complete SRE workflow:

```text
Code → GitHub → CI/CD → Docker → ECR → EKS → Datadog
                                              |
                                    Metrics + Logs + Traces
                                              |
                                    Golden Signals → SLOs
                                              |
                                    Monitors → Alerts → Incidents
                                              |
                                    Chaos Validation → Datadog as Code
```

---

## Architecture

```text
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
Docker Build  AWS ECR
              |
              v
           AWS EKS
           |     |
        App Pod  Datadog Agent (DaemonSet)
           |          |
           +----+-----+
                |
           Datadog Cloud
                |
         +------+------+
         |      |      |
      Metrics  Logs  Traces
         |      |      |
         +------+------+
                |
         Golden Signals Dashboard
         SLIs / SLOs / Error Budgets
         Monitors / Alerts
         Incident Automation
         Chaos Validation
         Terraform as Code
```

---

## Technology Stack

| Layer | Technology |
|---|---|
| Cloud | AWS (EKS, ECR, VPC, IAM, EC2, ELB) |
| IaC | Terraform (AWS + Datadog providers) |
| Containers | Docker, Kubernetes 1.32, Helm |
| Observability | Datadog (Metrics, Logs, APM, Dashboards, Monitors, SLOs, Incidents) |
| CI/CD | GitHub Actions |
| Application | Python 3.12, FastAPI, ddtrace, structlog |
| Scripting | Bash |
| OS | Linux (WSL2 Ubuntu) |

---

## Repository Structure

```text
sre-observability-eks-datadog/
├── app/
│   ├── src/main.py              # FastAPI application
│   ├── tests/test_api.py        # Unit tests
│   ├── Dockerfile               # Container definition
│   ├── requirements.txt         # Python dependencies
│   └── docker-compose.yml       # Local development
│
├── infrastructure/
│   └── terraform/
│       ├── versions.tf          # Provider version pins
│       ├── variables.tf         # Configuration variables
│       ├── outputs.tf           # Output values
│       ├── vpc.tf               # VPC + subnets
│       ├── eks.tf               # EKS cluster + node group
│       ├── ecr.tf               # Container registry
│       └── datadog/             # Datadog as Code (Phase 15)
│           ├── providers.tf
│           ├── variables.tf
│           ├── monitors.tf
│           ├── slos.tf
│           ├── dashboard.tf
│           ├── outputs.tf
│           └── terraform.tfvars.example
│
├── kubernetes/
│   ├── namespace.yaml           # sre-demo namespace
│   ├── deployment.yaml          # App deployment + APM config
│   ├── service.yaml             # LoadBalancer service
│   ├── configmap.yaml           # App configuration
│   └── hpa.yaml                 # Horizontal pod autoscaler
│
├── datadog/
│   └── agent/
│       ├── values.yaml          # Datadog Helm configuration
│       ├── install.sh           # Agent installation script
│       └── README.md            # Installation guide
│
├── scripts/
│   ├── infra-up.sh              # Start everything (infra + app + datadog)
│   ├── infra-down.sh            # Stop everything safely
│   └── chaos/                   # Phase 13 failure injection scripts
│       ├── common.sh
│       ├── inject-high-error-rate.sh
│       ├── inject-high-latency.sh
│       ├── inject-pod-crash.sh
│       ├── inject-availability-drop.sh
│       ├── restore-all.sh
│       └── run-all-scenarios.sh
│
├── docs/
│   ├── medium/                  # All 16 Medium article drafts
│   ├── runbooks/                # Monitor runbooks
│   │   ├── api-availability.md
│   │   ├── api-5xx.md
│   │   ├── high-latency.md
│   │   └── pod-restarts.md
│   └── screenshots/             # Phase-by-phase screenshots
│
├── .github/
│   └── workflows/
│       ├── ci.yml               # CI pipeline (PR)
│       └── deploy.yml           # CD pipeline (main)
│
├── README.md
└── CHANGELOG.md
```

---

## Project Roadmap

| Phase | Description | Status |
|---|---|---|
| Phase 1 | FastAPI demo app — APM, structured logging, failure endpoints | ✅ Complete |
| Phase 2 | AWS infrastructure — Terraform VPC, EKS, ECR | ✅ Complete |
| Phase 3 | Kubernetes deployment — LoadBalancer, HPA, health probes | ✅ Complete |
| Phase 4 | GitHub Actions CI/CD — automated build, push, deploy | ✅ Complete |
| Phase 5 | Datadog agent on EKS — Helm install, metrics, logs | ✅ Complete |
| Phase 6 | Kubernetes infrastructure monitoring dashboard | ✅ Complete |
| Phase 7 | Datadog APM — distributed tracing, flame graphs | ✅ Complete |
| Phase 8 | Log-trace correlation — connect logs to APM traces | ✅ Complete |
| Phase 9 | Golden Signals dashboard — Traffic, Latency, Errors, Saturation | ✅ Complete |
| Phase 10 | SLIs, SLOs, Error Budgets | ✅ Complete |
| Phase 11 | Monitors and alerting | ✅ Complete |
| Phase 12 | Incident automation | ✅ Complete |
| Phase 13 | Failure injection and chaos engineering | ✅ Complete |
| Phase 14 | Incident investigation exercises | ✅ Complete |
| Phase 15 | Datadog as Code — Terraform | ✅ Complete |
| Phase 16 | Complete SRE platform summary | ✅ Complete |

### Phase Status Legend
| Symbol | Meaning |
|---|---|
| ⏳ | Planned |
| 🔄 | In Progress |
| ✅ | Complete |

---

## Prerequisites

```bash
# Required tools
aws --version        # AWS CLI v2
terraform --version  # Terraform >= 1.5
kubectl version      # kubectl >= 1.29
helm version         # Helm >= 3.0
docker --version     # Docker >= 24
git --version        # Git >= 2.0
```

AWS account with:
- IAM user with AdministratorAccess
- Configured via `aws configure`

Datadog account:
- API Key (Organization Settings → API Keys)
- APP Key (Organization Settings → Application Keys) — enable all required scopes at creation

---

## Quick Start

### 1. Clone repository

```bash
git clone https://github.com/Machindra220/sre-observability-eks-datadog.git
cd sre-observability-eks-datadog
```

### 2. Configure AWS credentials

```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output (json)

# Verify
aws sts get-caller-identity
```

### 3. Store Datadog keys in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name sre-demo/datadog2 \
  --secret-string '{"DD_API_KEY":"<your-api-key>","DD_APP_KEY":"<your-app-key>"}'
```

### 4. Start everything

```bash
./scripts/infra-up.sh
```

Takes ~20–25 minutes on first run (EKS cluster creation).

### 5. Verify

```bash
kubectl get pods -A
kubectl get svc sre-demo-api -n sre-demo
curl http://<EXTERNAL-IP>/api/health
```

### 6. Deploy Datadog resources via Terraform

```bash
cd infrastructure/terraform/datadog
terraform init
terraform apply
```

### 7. Stop everything (saves AWS cost)

```bash
./scripts/infra-down.sh
```

---

## Application Endpoints

| Endpoint | Purpose | Signal Generated |
|---|---|---|
| GET /api/health | Liveness probe | Normal 200 |
| GET /api/ready | Readiness probe | Normal 200 |
| GET /api/products | Normal business traffic | Metrics, traces |
| GET /api/orders | Normal business traffic | Metrics, traces |
| GET /api/users | Normal business traffic | Metrics, traces |
| GET /api/slow | Latency simulation (2–5s) | High latency traces |
| GET /api/error | Failure simulation (5xx) | Error traces |

---

## AWS Infrastructure

| Resource | Type | Cost |
|---|---|---|
| EKS Control Plane | Managed | ~$73/mo |
| EC2 Worker Node | t3.small | ~$15/mo |
| ECR Repository | Storage | ~$0.10/GB |
| ELB Load Balancer | Classic | ~$18/mo |
| **Total** | | **~$106/mo** |

**Cost tip:** Run `./scripts/infra-down.sh` after each session — EKS charges by the hour.

---

## Datadog Configuration

### Features Enabled

| Feature | Status |
|---|---|
| Infrastructure metrics | ✅ |
| Container metrics | ✅ |
| Kubernetes state metrics | ✅ |
| Log collection (all containers) | ✅ |
| APM (distributed tracing) | ✅ |
| Process monitoring | ✅ |
| Log-trace correlation | ✅ |
| Runtime metrics | ✅ |

### Resources Created via Terraform

| Resource | Type | Details |
|---|---|---|
| API Availability - No Traffic | Monitor P1 | requests < 1 in 5m |
| High Error Rate | Monitor P2 | errors > 10 in 5m |
| Pod Restart Rate | Monitor P2 | restarts > 3 in 15m |
| SLO Error Budget Burn Rate | Monitor P2 | error rate > 1% |
| High p99 Latency | Monitor P3 | p99 > 2s |
| Availability SLO | SLO | 99% target, 30d window |
| Latency SLO | SLO | 90% target, 30d window |
| Golden Signals | Dashboard | Traffic, Latency, Errors, Saturation |

---

## Chaos Engineering

Phase 13 failure injection scripts in `scripts/chaos/`:

| Script | Failure Mode | Monitor Triggered |
|---|---|---|
| `inject-high-error-rate.sh` | Flood `/api/error` | P2 High Error Rate |
| `inject-high-latency.sh` | Flood `/api/slow` | P3 High Latency |
| `inject-pod-crash.sh` | kubectl command override → exit 1 | P2 Pod Restart |
| `inject-availability-drop.sh` | Scale to 0 replicas | P1 Availability |
| `restore-all.sh` | Recover all scenarios | — |

All 5 monitors validated firing correctly against real failures.

---

## CI/CD Pipeline

### CI (Pull Requests)
```
Lint → Tests → Docker Build → Security Scan (Trivy)
```

### CD (Push to main — app/** or kubernetes/**)
```
Tests → Build → Push to ECR → Deploy to EKS → Rollout → Smoke Test
```

Authentication: AWS Access Keys via GitHub Secrets
(OIDC setup pending — see known issues)

---

## Local Development

```bash
cd app
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m pytest tests/ -v
uvicorn src.main:app --host 0.0.0.0 --port 8080 --reload
```

---

## Known Issues

| Issue | Status | Workaround |
|---|---|---|
| GitHub OIDC authentication | ⚠️ Pending | Using AWS access keys in GitHub Secrets |
| ECR latest tag deleted on terraform destroy | ⚠️ Known | infra-up.sh rebuilds and pushes |
| kube-state-metrics v1beta1 warnings | ℹ️ Harmless | Pin kube-state-metrics version |
| Python 3.14 incompatible with ddtrace | ℹ️ Known | Use Python 3.12 |

---

## Medium Article Series

| # | Title | Status |
|---|---|---|
| 1 | Building a Lightweight FastAPI Service for Kubernetes Observability | ✅ Written |
| 2 | Provisioning AWS EKS Infrastructure with Terraform | ✅ Written |
| 3 | Deploying a Containerized Application to AWS EKS | ✅ Written |
| 4 | From Git Push to EKS: Building a GitHub Actions CI/CD Pipeline | ✅ Written |
| 5 | Installing Datadog on Kubernetes: Monitoring an EKS Cluster from Scratch | ✅ Written |
| 6 | Monitoring Kubernetes Workloads with Datadog | ✅ Written |
| 7 | Adding Datadog APM to a Kubernetes Application | ✅ Written |
| 8 | Centralized Kubernetes Logging with Datadog | ✅ Written |
| 9 | Implementing the Four Golden Signals with Datadog | ✅ Written |
| 10 | From Metrics to Reliability: SLIs, SLOs and Error Budgets | ✅ Written |
| 11 | Building Actionable Datadog Monitors Without Alert Fatigue | ✅ Written |
| 12 | Automating Incident Creation from Datadog Alerts | ✅ Written |
| 13 | Breaking Production on Purpose: Chaos Engineering on EKS | ✅ Written |
| 14 | Debugging a Kubernetes Incident Using Datadog | ✅ Written |
| 15 | Turning Observability into Code: Datadog with Terraform | ✅ Written |
| 16 | Building a Complete SRE Observability Platform — End-to-End Summary | ✅ Written |

---

## Lessons Learned

- **patch(fastapi=True) before FastAPI import** — import order matters for ddtrace
- **dd.trace_id not dd_trace_id** — dot notation required for log-trace correlation
- **ddtrace silently ignores a bad trace agent URL** — use kubectl patch with exit 1 for crash injection
- **LoadBalancer service must be deleted before terraform destroy** — prevents orphaned ELBs
- **Datadog APP key scopes must be set at creation** — key is only shown once
- **burn_rate() monitor query requires a higher Datadog plan** — use error rate % as proxy
- **Datadog org tag policies surface only at apply time** — check allowed keys before writing HCL
- **t3.small is tight with Datadog** — agent consumes ~300MB RAM
- **infra-up/down scripts save hours** — automate everything you repeat

---

## Author

**Machindranath Wagare**

- 💼 ~10 years IT/SRE/Cloud Operations experience
- 📧 [machindra.wagre@gmail.com](mailto:machindra.wagre@gmail.com)
- 🐙 [github.com/Machindra220](https://github.com/Machindra220)
---

*All 16 phases complete. Built in public — follow the journey through the Medium article series.*