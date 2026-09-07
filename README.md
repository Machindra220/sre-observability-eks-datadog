
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
         Golden Signals
         SLIs / SLOs
         Monitors / Alerts
         Incidents
```

---

## Technology Stack

| Layer | Technology |
|---|---|
| Cloud | AWS (EKS, ECR, VPC, IAM, EC2, ELB) |
| IaC | Terraform |
| Containers | Docker, Kubernetes, Helm |
| Observability | Datadog (Metrics, Logs, APM, Dashboards, Monitors) |
| CI/CD | GitHub Actions |
| Application | Python FastAPI |
| Scripting | Bash |
| OS | Linux (WSL2 Ubuntu) |

---

## Repository Structure

```text
sre-observability-eks-datadog/
├── app/
│   ├── src/main.py          # FastAPI application
│   ├── tests/test_api.py    # Unit tests
│   ├── Dockerfile           # Container definition
│   ├── requirements.txt     # Python dependencies
│   └── docker-compose.yml   # Local development
│
├── infrastructure/
│   └── terraform/
│       ├── versions.tf      # Provider version pins
│       ├── variables.tf     # Configuration variables
│       ├── outputs.tf       # Output values
│       ├── vpc.tf           # VPC + subnets
│       ├── eks.tf           # EKS cluster + node group
│       └── ecr.tf           # Container registry
│
├── kubernetes/
│   ├── namespace.yaml       # sre-demo namespace
│   ├── deployment.yaml      # App deployment + APM config
│   ├── service.yaml         # LoadBalancer service
│   ├── configmap.yaml       # App configuration
│   └── hpa.yaml             # Horizontal pod autoscaler
│
├── datadog/
│   └── agent/
│       ├── values.yaml      # Datadog Helm configuration
│       ├── install.sh       # Agent installation script
│       └── README.md        # Installation guide
│
├── scripts/
│   ├── infra-up.sh          # Start everything (infra + app + datadog)
│   └── infra-down.sh        # Stop everything safely
│
├── docs/
│   ├── medium/              # Medium article drafts
│   │   ├── 01-fastapi-observability-app.md
│   │   ├── 02-eks-terraform-infrastructure.md
│   │   ├── 03-deploy-to-eks.md
│   │   ├── 04-github-actions-cicd.md
│   │   ├── 05-datadog-eks-monitoring.md
│   │   ├── 06-kubernetes-monitoring.md
│   │   ├── 07-datadog-apm.md
│   │   ├── 08-datadog-logs.md
│   │   └── 09-golden-signals.md
│   └── screenshots/         # Article screenshots by phase
│
├── .github/
│   └── workflows/
│       ├── ci.yml           # CI pipeline (PR)
│       └── deploy.yml       # CD pipeline (main)
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
| Phase 10 | SLIs, SLOs, Error Budgets | 🔄 In Progress |
| Phase 11 | Monitors and alerting | ⏳ Planned |
| Phase 12 | Incident automation | ⏳ Planned |
| Phase 13 | Failure injection and incident response | ⏳ Planned |
| Phase 14 | Incident investigation exercises | ⏳ Planned |
| Phase 15 | Datadog as Code (Terraform) | ⏳ Planned |
| Phase 16 | Complete SRE platform summary | ⏳ Planned |

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
- APP Key (Organization Settings → Application Keys)

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

### 3. Set Datadog keys

```bash
# Add to ~/.bashrc for persistence
echo 'export DD_API_KEY="your-datadog-api-key"' >> ~/.bashrc
echo 'export DD_APP_KEY="your-datadog-app-key"' >> ~/.bashrc
source ~/.bashrc
```

### 4. Start everything

```bash
# Creates infrastructure, deploys app, installs Datadog — one command
./scripts/infra-up.sh
```

This takes ~20-25 minutes on first run (EKS cluster creation).

### 5. Verify

```bash
# Check all pods running
kubectl get pods -A

# Get app URL
kubectl get svc sre-demo-api -n sre-demo

# Test app
curl http://<EXTERNAL-IP>/api/health
```

### 6. Stop everything (saves AWS cost)

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
| GET /api/slow | Latency simulation (2-5s) | High latency traces |
| GET /api/error | Failure simulation (4xx/5xx) | Error traces |

---

## AWS Infrastructure

| Resource | Type | Cost |
|---|---|---|
| EKS Control Plane | Managed | ~$73/mo |
| EC2 Worker Node | t3.small | ~$15/mo |
| ECR Repository | Storage | ~$0.10/GB |
| ELB Load Balancer | Classic | ~$18/mo |
| **Total** | | **~$106/mo** |

**Cost tip:** Run `./scripts/infra-down.sh` after each session.
EKS charges by the hour even when idle.

---

## Datadog Configuration

### Agent Installation

```bash
export DD_API_KEY="your-api-key"
export DD_APP_KEY="your-app-key"
cd datadog/agent
./install.sh
```

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

### Dashboards Created

| Dashboard | Purpose |
|---|---|
| SRE - Kubernetes Infrastructure | Node, pod, container health |
| SRE — Golden Signals | Traffic, Latency, Errors, Saturation |

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

# Create virtual environment
python3.12 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run tests
python -m pytest tests/ -v

# Run app locally
uvicorn src.main:app --host 0.0.0.0 --port 8080 --reload

# Or with Docker
docker compose up
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
| 10 | From Metrics to Reliability: SLIs, SLOs and Error Budgets | ⏳ Planned |
| 11 | Building Actionable Datadog Monitors Without Alert Fatigue | ⏳ Planned |
| 12 | Automating Incident Creation from Datadog Alerts | ⏳ Planned |
| 13 | Breaking Production on Purpose: Failure Injection | ⏳ Planned |
| 14 | Debugging a Kubernetes Incident Using Datadog | ⏳ Planned |
| 15 | Turning Observability into Code: Datadog with Terraform | ⏳ Planned |
| 16 | Building a Complete SRE Observability Pipeline | ⏳ Planned |

---

## Lessons Learned

- **patch(fastapi=True) before FastAPI import** — import order matters
  for ddtrace monkey-patching
- **dd.trace_id not dd_trace_id** — dot notation required for log-trace
  correlation
- **ECR latest tag must be managed explicitly** — terraform destroy
  wipes images
- **t3.small is tight with Datadog** — agent consumes ~300MB RAM
- **Always verify running container code** — Docker cache causes
  stale deployments
- **infra-up/down scripts save hours** — automate everything you repeat

---

## Author

**Machindranath Wagare**
~10 years IT/SRE/Cloud Operations experience
[machindra220@gmail.com](mailto:machindra220@gmail.com)
[github.com/Machindra220](https://github.com/Machindra220)

---

*Building in public — follow the journey through the Medium article series.*
