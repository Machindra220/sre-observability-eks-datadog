# Installing Datadog on Kubernetes: Monitoring an EKS Cluster from Scratch

## A complete walkthrough of deploying the Datadog agent on AWS EKS using Helm and validating full observability

---

## Problem

Running an application on Kubernetes without observability is flying blind. 
You don't know:
- How much CPU and memory your pods are consuming
- Whether your application logs are capturing errors
- How requests flow through your service
- When something is about to fail before it actually does

Installing the Datadog agent is the first step toward answering all of these 
questions. This article covers the complete installation process as Phase 5 
of a larger SRE observability project on AWS EKS.

---

## Architecture

```text
EKS Cluster
     |
     +-- Node (EC2 t3.small)
          |
          +-- kube-system pods
          |    ├── aws-node (VPC CNI)
          |    ├── coredns
          |    └── kube-proxy
          |
          +-- sre-demo pods
          |    └── sre-demo-api (FastAPI)
          |
          +-- datadog pods
               ├── datadog-agent (DaemonSet)    ← runs on every node
               ├── cluster-agent               ← cluster-level metrics
               ├── kube-state-metrics          ← K8s object states
               └── operator                   ← manages agent lifecycle
                    |
                    v
               Datadog Cloud
                    |
               +----+----+
               |         |
           Metrics      Logs
               |         |
               +----+----+
                    |
                   APM
```

---

## Datadog Agent Components

Understanding what each component does before installing:

| Component | Type | Purpose |
|---|---|---|
| Node Agent | DaemonSet | Runs on every node, collects metrics/logs/traces |
| Cluster Agent | Deployment | Collects cluster-level Kubernetes metrics |
| kube-state-metrics | Deployment | Exposes Kubernetes object states as metrics |
| Operator | Deployment | Manages Datadog agent lifecycle |

**Why DaemonSet for the node agent?**
A DaemonSet ensures exactly one agent pod runs on every node. When you add 
a new node, Kubernetes automatically schedules an agent pod on it. No manual 
installation required.

---

## Prerequisites

- EKS cluster running with kubectl connected
- Helm installed (v3+)
- Datadog account with API key and APP key
- AWS CLI configured

---

## Datadog Account Setup

### Which site/region to use

Check your Datadog URL to determine your site:

| URL | Site value |
|---|---|
| app.datadoghq.com | datadoghq.com (US1) |
| app.datadoghq.eu | datadoghq.eu (EU) |
| us3.datadoghq.com | us3.datadoghq.com |
| us5.datadoghq.com | us5.datadoghq.com |

This must match the `site` field in `values.yaml`.

### API Key vs APP Key

| Key | Purpose |
|---|---|
| API Key | Agent authentication — sends metrics/logs/traces to Datadog |
| APP Key | Management authentication — creates monitors, dashboards via API/Terraform |

Both are required. Neither should ever be committed to Git.

---

## Configuration

### Helm values.yaml

Rather than passing dozens of `--set` flags to Helm, we use a values file 
that overrides specific defaults from the Datadog chart:

```yaml
datadog:
  apiKeyExistingSecret: datadog-secret
  appKeyExistingSecret: datadog-secret

  site: datadoghq.com

  logs:
    enabled: true
    containerCollectAll: true

  apm:
    portEnabled: true
    port: 8126

  processAgent:
    enabled: true
    processCollection: true

  kubeStateMetricsEnabled: true
  kubeStateMetricsCore:
    enabled: true

  collectEvents: true

  networkMonitoring:
    enabled: false

  tags:
    - "env:dev"
    - "project:sre-demo"
    - "cluster:sre-demo-dev-eks-cluster"

clusterAgent:
  enabled: true
  metricsProvider:
    enabled: true

agents:
  containers:
    agent:
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 256m
          memory: 512Mi
    traceAgent:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
    processAgent:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
```

**Key configuration decisions:**

**`apiKeyExistingSecret`** — references a Kubernetes Secret instead of 
hardcoding the API key. The secret is created separately and never stored 
in the values file or Git.

**`containerCollectAll: true`** — collects logs from every container on 
the node automatically. No per-container configuration needed.

**`apm.portEnabled: true`** — opens port 8126 on every node for trace 
collection. Our FastAPI app (ddtrace) sends traces here.

**`networkMonitoring.enabled: false`** — disabled to save cost. NPM 
requires an additional Datadog subscription.

**Resource limits on t3.small** — critical. The Datadog agent itself 
consumes CPU and memory. Without limits, it could starve our application.

**Unified service tags** — `env:dev`, `project:sre-demo`, `cluster:...` 
applied to every metric, log, and trace. This enables filtering across 
all telemetry types by environment or project.

---

## Installation Script

```bash
#!/bin/bash
set -e

echo "=== Installing Datadog Agent on EKS ==="

# Add official Datadog Helm repository
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Create dedicated namespace for Datadog components
kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -

# Create Kubernetes secret from environment variables
# Keys never touch the filesystem or Git
kubectl create secret generic datadog-secret \
  --from-literal=api-key=$DD_API_KEY \
  --from-literal=app-key=$DD_APP_KEY \
  --namespace datadog \
  --dry-run=client -o yaml | kubectl apply -f -

# Install Datadog agent via Helm
helm upgrade --install datadog-agent datadog/datadog \
  --namespace datadog \
  --values values.yaml \
  --wait \
  --timeout 5m

echo "=== Datadog Agent installed successfully ==="
```

**Why `--dry-run=client -o yaml | kubectl apply`?**
This idempotent pattern means running the script twice won't fail with 
"already exists". The secret is recreated if it exists, created if it 
doesn't. Safe for automation.

**Why `helm upgrade --install`?**
`upgrade --install` installs if not present, upgrades if already installed. 
One command handles both cases — better than separate `install` and `upgrade` 
commands.

---

## Installation

```bash
# Set API keys as environment variables
export DD_API_KEY="<your-datadog-api-key>"
export DD_APP_KEY="<your-datadog-app-key>"

# Run installation
cd datadog/agent
./install.sh
```

---

## Validation

### Check pods are running

```bash
kubectl get pods -n datadog

NAME                                                READY   STATUS    RESTARTS   AGE
datadog-agent-7ldhm                                 3/3     Running   0          113s
datadog-agent-cluster-agent-695478478b-k4zc8        1/1     Running   0          113s
datadog-agent-kube-state-metrics-696546c965-rrrgd   1/1     Running   0          113s
datadog-agent-operator-5c4d6d6864-72cq2             1/1     Running   0          113s
```

`3/3` on the node agent means 3 containers running:
- `agent` — core metrics collection
- `trace-agent` — APM trace collection
- `process-agent` — process monitoring

### Check agent status

```bash
kubectl exec -n datadog datadog-agent-7ldhm \
  -c agent -- agent status | head -50
```

### Verify in Datadog UI

**Infrastructure → Hosts:**
- EKS node appears within 2-3 minutes
- Tagged with `env:dev`, `cluster:sre-demo-dev-eks-cluster`
- CPU usage visible

**Logs → Log Explorer:**
- Logs from all containers flowing
- `sre-demo-api` logs visible with structured JSON fields
- `GET /api/ready 200 OK` log entries from health probes

**Kubernetes Explorer:**
- All 9 pods visible across namespaces
- `sre-demo-api` — RUNNING, 0.33% CPU, 44% memory
- All Datadog pods — RUNNING

---

## Troubleshooting Encountered

### Helm values.yaml — Wrong env format

**Error:**
range can't iterate over dev


**Root cause:** `datadog.env` in values.yaml expects a list of objects, 
not a plain string. We had `env: dev` which Helm tried to iterate over.

**Fix:** Removed `env: dev` from the `datadog:` block. Environment 
tagging is handled via the `tags:` list instead:
```yaml
tags:
  - "env:dev"
```

**Lesson:** Always validate Helm values against the chart's default 
values file before installing:
https://github.com/DataDog/helm-charts/blob/main/charts/datadog/values.yaml


### kube-state-metrics RBAC warnings

**Error in logs:**
Failed to list *v1beta1.CronJob: the server could not find the requested resource
Failed to list *v1beta1.Ingress: the server could not find the requested resource


**Root cause:** kube-state-metrics is trying to list deprecated `v1beta1` 
API resources that no longer exist in Kubernetes 1.32 (which uses `v1`).

**Impact:** Harmless for our project — core metrics still collected. 
These warnings come from the kube-state-metrics component, not our application.

**Production fix:** Pin kube-state-metrics to a version compatible with 
Kubernetes 1.32 in values.yaml.

### kubeconfig stale after cluster recreation

**Problem:** `kubectl` commands failed after recreating the EKS cluster.

**Root cause:** kubeconfig stored the old cluster endpoint. New cluster 
has a different endpoint.

**Fix:** Always run after `terraform apply`:
```bash
aws eks update-kubeconfig --region us-east-1 --name sre-demo-dev-eks-cluster
```

---

## What's Flowing into Datadog

After installation, Datadog automatically collects:

### Metrics
kubernetes.cpu.usage.total
kubernetes.memory.usage
kubernetes.pods.running
kubernetes.nodes.by_condition
container.cpu.usage
container.memory.usage


### Logs
All container stdout/stderr
Structured JSON fields parsed automatically
service, env, version tags applied


### Events
Pod scheduled
Pod started
Pod failed
Node ready
Deployment updated


---

## Cost Breakdown

| Component | Cost |
|---|---|
| Datadog Pro (1 host) | ~$15/mo |
| Log ingestion | ~$0.10/GB |
| APM | Included in Pro |
| **Total Datadog** | **~$16/mo** |

**Trial account:** All features free for 14 days — sufficient to complete 
this entire project series.

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| API key storage | Kubernetes Secret | AWS Secrets Manager + ESO |
| Agent resources | Conservative limits | Profile actual usage, right-size |
| Log collection | All containers | Filter to relevant services |
| kube-state-metrics | Default (v1beta1 warnings) | Pin compatible version |
| Network monitoring | Disabled | Enable if network visibility needed |
| Agent version | Latest | Pin specific version, test upgrades |
| Multiple clusters | Single | Cluster-level tags for differentiation |
| RBAC | Default | Scope to minimum required permissions |

---

## Lessons Learned

1. **Helm values files are safer than --set flags.** Long helm install 
   commands with dozens of `--set` flags are hard to read, review, and 
   version control. A values.yaml file is self-documenting and committable.

2. **Never hardcode secrets in values files.** Using `apiKeyExistingSecret` 
   separates the secret lifecycle from the Helm chart lifecycle. Rotating 
   API keys doesn't require a Helm upgrade.

3. **Resource limits on the agent matter on small nodes.** On t3.small 
   with 2GB RAM, an unconstrained Datadog agent can consume enough memory 
   to trigger OOM kills on application pods. Always set limits.

4. **Unified service tagging from day one.** Applying `env`, `service`, 
   and `version` tags consistently across metrics, logs, and traces makes 
   correlation trivial later. Retrofitting tags is painful.

5. **kubeconfig must be updated after every cluster recreation.** This is 
   easy to forget and causes confusing errors. Automate it in your infra-up 
   script.

6. **kube-state-metrics API version warnings are a known issue.** Don't 
   spend time debugging these — they're a compatibility gap between 
   kube-state-metrics and newer Kubernetes API versions. Pin the version 
   if they become noisy.

---

## What's Next

**Article 6: Monitoring Kubernetes Workloads with Datadog — Pods, Nodes, 
Containers and Deployments**

With the agent running and data flowing, we'll build our first Datadog 
dashboards focused on Kubernetes infrastructure health — node capacity, 
pod status, container resource usage, and deployment availability.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*