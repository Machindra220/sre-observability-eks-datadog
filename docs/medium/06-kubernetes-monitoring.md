# Monitoring Kubernetes Workloads with Datadog: Pods, Nodes, Containers and Deployments

## Building your first Kubernetes infrastructure dashboard and understanding what to monitor and why

---

## Problem

Installing the Datadog agent is just the beginning. The real work is understanding 
what the agent is collecting, what matters for reliability, and how to build 
dashboards that give you actionable visibility into your cluster.

Most observability tutorials show you pretty dashboards without explaining:
- Why you chose those specific metrics
- What the numbers actually mean
- How to interpret spikes and anomalies
- Which pods and components deserve monitoring attention

This article covers how I built a Kubernetes infrastructure monitoring dashboard 
as Phase 6 of a larger SRE observability project on AWS EKS with Datadog.

---

## Architecture

```text
EKS Cluster
     |
     +-- kube-system    (DNS, networking, proxy)
     |    ├── coredns x2
     |    ├── aws-node
     |    └── kube-proxy
     |
     +-- datadog        (observability layer)
     |    ├── datadog-agent (DaemonSet - 3 containers)
     |    ├── cluster-agent
     |    ├── kube-state-metrics
     |    └── operator
     |
     +-- sre-demo       (our application)
          └── sre-demo-api
               |
          Datadog Agent collects ←──────────────────┘
               |
          Datadog Cloud
               |
          Custom Dashboard
```

---

## What Datadog Collects Automatically

Once the agent is running, these metrics flow immediately — no configuration needed:

### Node Metrics
kubernetes.cpu.usage.total — CPU used by the node (nanocores)
kubernetes.memory.usage — Memory used by the node (bytes)
kubernetes.filesystem.usage — Disk usage
kubernetes.network.rx_bytes — Network bytes received
kubernetes.network.tx_bytes — Network bytes transmitted


### Pod and Container Metrics
kubernetes_state.pod.ready — Is the pod ready? (0 or 1)
kubernetes_state.container.restarts — How many times has container restarted?
kubernetes_state.deployment.replicas_available — Available replicas per deployment
container.cpu.usage — Container CPU usage (nanocores)
container.memory.usage — Container memory usage (bytes)


### Kubernetes State Metrics
kubernetes_state.deployment.replicas_desired — What we want
kubernetes_state.deployment.replicas_available — What we have
kubernetes_state.pod.status.phase — Pod phase (Running/Pending/Failed)


---

## Enabling Kubernetes Integration

Datadog's Kubernetes dashboards are available after enabling the integration:
Datadog → Integrations → search "Kubernetes" → Install
Datadog → Integrations → search "Amazon EKS (Agent)" → Install


After installation, navigate to:
Datadog → Infrastructure → Kubernetes


This reveals the Kubernetes Explorer — a real-time view of your entire cluster.

---

## Kubernetes Explorer

### Overview Page
Clusters : 1 (sre-demo-dev-eks-cluster)
Namespaces : 3 (kube-system, datadog, sre-demo)
Nodes : 1 (ip-10-0-102-83.ec2.internal)
Deployments : 5
Pods : 9
Containers : 24
Replica Sets: 6
Services : 9


**Cost of unused resources: $1.30** — Datadog automatically calculates 
cluster efficiency. 67.1% cluster idle is expected for a single-node 
learning environment.

### Nodes View
Node: ip-10-0-102-83.ec2.internal
Status: READY
Kubernetes: v1.32.13-eks-cb19647
Pods: 9 running
CPU: 3.41%
Memory: 39.73%


Node running well within capacity on t3.small (2 vCPU, 2GB RAM).

### Deployments View

All 5 deployments showing:
- Rollout Status: COMPLETED
- Availability: AVAILABLE
- Pod Status: all green
- Monitors: 1 OK each

---

## Pod Priority for SRE Monitoring

Not all pods deserve equal attention. Here's how to think about monitoring priority:

### Critical — Alert on these
| Pod | Why Critical |
|---|---|
| `sre-demo-api` | User-facing — outage = customer impact |
| `datadog-agent` | Monitoring blind spot if down |
| `datadog-cluster-agent` | Lose cluster-level metrics |

### Important — Dashboard visibility
| Pod | Why Important |
|---|---|
| `coredns` | DNS failure breaks inter-pod communication |
| `aws-node` | VPC CNI failure breaks pod networking |
| `kube-proxy` | Network rules — affects service routing |

### Informational — Low priority
| Pod | Why Low Priority |
|---|---|
| `kube-state-metrics` | Dashboard gaps only, not user-facing |
| `datadog-operator` | Agent management, not real-time critical |

---

## Sidecar Containers

The Datadog node agent pod runs `3/3` containers — three processes in one pod:
datadog-agent-nsmfl (pod)
├── agent ← core metrics collection
├── trace-agent ← APM trace collection (port 8126)
└── process-agent ← process monitoring


This is the sidecar pattern — multiple containers sharing the same pod, 
network namespace, and storage. Each container has a specific responsibility.

Our `sre-demo-api` pod runs only 1 container — no sidecars needed yet. 
In a production setup, you might add a log shipping sidecar or a service 
mesh proxy (Envoy) as a sidecar.

---

## Building the Dashboard

### Dashboard: SRE - Kubernetes Infrastructure

We built a custom dashboard with 7 widgets covering infrastructure and 
application health.

**Widget configuration approach:**

For Query Value widgets showing current state:
Aggregation: sum or max (not avg)
Reduce values in timeframe to: last (not sum)


Using `last` instead of `sum` shows the current value, not accumulated 
total over the time window. This is the most common dashboard configuration 
mistake — `sum` over 1 hour accumulates every data point, producing 
misleadingly large numbers.

### Widget 1 — Container Restarts
Metric: kubernetes_state.container.restarts
Filter: cluster_name:sre-demo-dev-eks-cluster
Aggregation: sum
Reduce to: last
Value: 0 ✅


Zero restarts = stable cluster. In production, set an alert when this 
exceeds 3 restarts in 5 minutes — indicates a crash loop.

### Widget 2 — Available Replicas
Metric: kubernetes_state.deployment.replicas_available
Filter: cluster_name:sre-demo-dev-eks-cluster
Aggregation: sum
Reduce to: last
Value: 6 ✅


6 = coredns(2) + cluster-agent(1) + kube-state-metrics(1) + operator(1) + sre-demo-api(1)

### Widget 3 — Ready Pods
Metric: kubernetes_state.pod.ready
Filter: cluster_name:sre-demo-dev-eks-cluster
Aggregation: sum
Reduce to: last
Value: 9 ✅


9 pods = all pods across kube-system, datadog, and sre-demo namespaces.

**Why pods (9) > replicas (6)?**
DaemonSet pods (datadog-agent, aws-node, kube-proxy) count as pods but 
not as deployment replicas. Pods is the total count of all running 
containers regardless of how they were created.

### Widget 4 — Node CPU Usage (Timeseries)
Metric: kubernetes.cpu.usage.total
Filter: cluster_name:sre-demo-dev-eks-cluster
Aggregation: avg by host
Value: ~8 mcores


Very low CPU usage — t3.small handling the load comfortably.

### Widget 5 — Node Memory Usage (Timeseries)
Metric: kubernetes.memory.usage
Filter: cluster_name:sre-demo-dev-eks-cluster
Aggregation: avg by host
Value: ~40 MB stable


Flat memory line = no memory leaks, stable workload.

### Widget 6 — App Memory Usage (Timeseries)

Metric: container.memory.usage
Filter: kube_namespace:sre-demo
Aggregation: avg by pod_name
Value: ~48 MB flat


Our FastAPI app consuming ~48MB — well within the 256Mi limit.

### Widget 7 — App CPU Usage (Timeseries)

Metric: container.cpu.usage
Filter: kube_namespace:sre-demo
Aggregation: avg by pod_name
Value: spike visible during load test


---

## Traffic Generation and Observability

We generated 50 iterations of traffic across all endpoints:

```bash
for i in {1..50}; do
  curl -s http://${LB}/api/health > /dev/null
  curl -s http://${LB}/api/products > /dev/null
  curl -s http://${LB}/api/error > /dev/null
  curl -s http://${LB}/api/slow > /dev/null
done
```

This created ~200 requests. The result was immediately visible in the 
App CPU Usage widget — a clear spike at exactly the time the loop ran, 
returning to baseline afterward.

**This is observability working correctly:**

Action taken (traffic loop)
↓
Metric captured (CPU spike)
↓
Visible in dashboard (spike at 17:35)
↓
Returns to baseline (traffic stopped)


---

## Key Metric Concepts

### Aggregation vs Reduce

Two separate operations happen when building a Query Value widget:

**Aggregation** — how to combine values across multiple sources at each point in time:
- `sum` — add all values together
- `avg` — average across all sources
- `max` — highest value

**Reduce** — how to collapse the time series to a single number:
- `sum` — add all time points together (usually wrong for current state)
- `last` — show the most recent value (usually correct for current state)
- `avg` — average over the time window

**Common mistake:** Using `sum` for reduce shows accumulated totals (216 replicas) instead of current state (6 replicas).

### nanocores vs percent

`kubernetes.cpu.usage.total` returns nanocores (billionths of a CPU core):
1 CPU core = 1,000,000,000 nanocores
8 mcores = 8,000,000 nanocores = 0.008 CPU cores


`system.cpu.user` returns percentage — misleading when summed across 
multiple processes (showed 698% in our testing).

Always use Kubernetes-native metrics (`kubernetes.*`, `container.*`) 
over system metrics (`system.*`) for container workloads.

---

## Pending — Phase 7

Two widgets couldn't be added yet:
trace.flask.request ← APM disabled (DD_TRACE_ENABLED=false)
trace.flask.request.errors ← APM disabled


These require Datadog APM to be enabled and the Datadog agent to be 
receiving traces from our FastAPI app. This is the focus of Phase 7.

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Dashboard scope | Single cluster | Multi-cluster with cluster variable |
| Metric retention | 14 days (trial) | 15 months (Pro) |
| Alert on restarts | Manual check | Automated monitor |
| Node count | 1 | 3+ across AZs |
| Resource headroom | ~60% free | Target 40-60% utilization |
| Custom metrics | None | Business metrics (orders/sec, revenue) |

---

## Lessons Learned

1. **`last` not `sum` for current state widgets.** Using `sum` to reduce 
   a time series accumulates all data points — showing 216 replicas instead 
   of 6. Always use `last` for "what is the current value" questions.

2. **Pods ≠ Replicas.** DaemonSet pods count toward total pod count but 
   not toward deployment replica count. Understanding this distinction 
   prevents confusion when dashboard numbers don't add up intuitively.

3. **Traffic spikes are immediately visible.** The 50-iteration load test 
   showed up as a clear CPU spike within seconds. This validates that 
   the monitoring pipeline is working end-to-end.

4. **Not all pods deserve equal monitoring attention.** Prioritize 
   user-facing services and the monitoring stack itself. System pods are 
   important but rarely the root cause of user-impacting incidents.

5. **Kubernetes-native metrics are more meaningful than system metrics.** 
   `container.cpu.usage` tells you what a specific container is consuming. 
   `system.cpu.user` tells you what the entire node's CPU is doing — 
   less useful for debugging specific workload issues.

6. **Flat memory lines are good.** A constantly growing memory line 
   indicates a memory leak. Our app's flat ~48MB line confirms no leak.

---

## What's Next

**Article 7: Adding Datadog APM to a Kubernetes Application — From HTTP 
Request to Distributed Trace**

With infrastructure monitoring in place, we'll enable Datadog APM on our 
FastAPI application — enabling distributed tracing, request-level visibility, 
and the ability to correlate slow requests with specific code paths.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*
