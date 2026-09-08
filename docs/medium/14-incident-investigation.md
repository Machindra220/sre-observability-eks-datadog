# Phase 14: Debugging Kubernetes Incidents Using Datadog — A Practical Investigation Playbook

*Part 14 of 16 in the SRE Observability on AWS EKS with Datadog series*

---

## Introduction

Phase 13 broke the system. Phase 14 is about how you figure out what broke and why.

Injecting failures and watching monitors fire is satisfying. But the real skill in SRE work is what happens next — opening Datadog with an active P1 incident and knowing exactly where to look, in what order, and what each signal means. That investigative instinct is what separates a platform that generates alerts from one that actually reduces MTTR.

This phase documents the investigation methodology used during each of the four Phase 13 failure scenarios. Not what the failure was — we already knew that, because we injected it. But how the Datadog toolchain tells you the story of a failure when you *don't* know what happened. That is the perspective to read this phase from.

Each scenario becomes an investigation exercise: a failure mode, the signals it produces, the Datadog tools used to investigate, and the path from alert to root cause.

---

## The Investigation Toolchain

Before walking through each scenario, here are the five Datadog surfaces used across all investigations — in the order you reach for them during a real incident.

| Tool | When you reach for it | What it answers |
|---|---|---|
| **Monitors** | First — the alert itself | What threshold crossed, when, which service |
| **APM Service Map** | Second — service-level view | Is it one service or cascading? |
| **APM Traces** | Third — request-level detail | Which requests failed, what the error was |
| **Log Explorer** | Fourth — raw application context | Stack traces, error messages, timestamps |
| **Kubernetes Explorer** | For infra failures | Pod state, restart count, events |

A disciplined investigator works top-down: monitors → service → traces → logs. Jumping straight to logs without context wastes time. Jumping straight to Kubernetes without checking APM first misses application-layer failures that look like infra problems.

---

## Investigation 1 — High Error Rate

### The alert

**Monitor:** `[sre-demo-api] High Error Rate`  
**Severity:** P2 High  
**Query:** `sum(last_5m):sum:trace.fastapi.request.errors{service:sre-demo-api, env:dev}`

The monitor fired within the first evaluation window of the load injection. The behavior graph showed a clean green-to-red transition — error rate crossed threshold and stayed there.

### Investigation path

**Step 1 — Read the monitor message**

The monitor message template included a direct APM link:
```
Check: https://app.datadoghq.com/apm/services/sre-demo-api
```
This is why runbooks and monitor messages with deep links matter — they cut 30–60 seconds off every investigation.

**Step 2 — APM Service page**

Navigate to APM → Services → `sre-demo-api`.

Key signals visible immediately:
- **Error rate graph** spiking — matching the monitor window exactly
- **Request volume** steady — traffic volume is normal, only errors are elevated
- **Latency** unchanged — errors are fast 5xx responses, not slow ones

The combination of stable traffic + stable latency + spiking errors immediately points to an **application-level error**, not a resource saturation problem.

**Step 3 — Drill into error traces**

APM → Traces → filter by `status:error`.

Each error trace shows:
- Endpoint: `GET /api/error`
- HTTP status: `500`
- Span duration: ~5ms (fast fail — not a timeout)
- Error type: `server` (from the app's response body)

The flame graph for each error trace has a single red span — the `/api/error` handler — with no downstream dependencies. This is a self-contained application error, not a cascading failure.

**Step 4 — Log Explorer**

Logs → filter `service:sre-demo-api` + `status:error`.

Each log entry shows:
```json
{
  "level": "error",
  "message": "Simulated server error",
  "endpoint": "/api/error",
  "dd.trace_id": "4321098765432109876"
}
```

The `dd.trace_id` field links the log directly to the APM trace — clicking it opens the full trace context from the log line.

### Root cause

Application endpoint `/api/error` intentionally returns 500. Load test hitting this endpoint at high concurrency pushed error rate above threshold.

### MTTR breakdown

| Step | Time |
|---|---|
| Alert received | T+0:00 |
| Monitor message → APM link opened | T+0:30 |
| Error rate spike confirmed in APM | T+1:00 |
| Error traces filtered and inspected | T+2:00 |
| Root cause confirmed | T+2:30 |

**Investigation time: ~2.5 minutes**

---

## Investigation 2 — High p99 Latency

### The alert

**Monitor:** `[sre-demo-api] High p99 Latency`  
**Severity:** P3 Medium  
**Query:** `percentile(last_5m):p99:trace.fastapi.request{service:sre-demo-api, env:dev}`

### Investigation path

**Step 1 — APM Service page**

Navigate to APM → Services → `sre-demo-api`.

Key signals:
- **p99 latency** elevated — far above baseline
- **Error rate** normal — this is not errors causing slowness
- **Request volume** elevated — more concurrent requests than usual
- **p50 latency** normal — median is fine, only the tail is slow

The p50 vs p99 divergence is the critical signal here. When median latency is normal but p99 is elevated, it means a **subset of requests** are slow — not all of them. This is the signature of a slow endpoint being hit alongside normal endpoints.

**Step 2 — APM Traces — sort by duration**

Filter traces by duration descending. The slowest requests immediately cluster around the `/api/slow` endpoint with durations of 2,000–5,000ms.

The flame graph for a slow trace shows:
- Single span for the `/api/slow` handler
- Duration: ~2,300ms
- No downstream calls — the latency is internal to the handler
- No errors — slow but successful

**Step 3 — Resource check**

In parallel, check Infrastructure → Host map for CPU/memory on the EKS node. Both normal. This rules out resource saturation as the cause — the slowness is in the application code, not the infrastructure.

**Step 4 — Confirm scope**

Filter APM traces by endpoint to confirm the slow requests are isolated to `/api/slow`. Normal endpoints (`/api/health`, `/api/products`) show baseline latency. The blast radius is one endpoint only.

### Root cause

`/api/slow` introduces an artificial 2–5 second delay. Concurrent load to this endpoint pushed p99 above threshold without affecting normal traffic.

### Key takeaway

**p50 vs p99 divergence tells you it's a subset problem, not a systemic one.** A systemic slowdown (memory pressure, CPU saturation, slow downstream dependency) would elevate both. Tail-only elevation always means look at outlier requests first.

---

## Investigation 3 — Pod CrashLoopBackOff

### The alert

**Monitor:** `[sre-demo-api] Pod Restart Rate`  
**Severity:** P2 High  
**Query:** `sum(last_15m):sum:kubernetes_state.container.restarts{kube_namespace:sre-demo...}`

This is an infrastructure-layer failure, not an application-layer one. The investigation path is different.

### Investigation path

**Step 1 — Kubernetes Explorer**

Infrastructure → Kubernetes Explorer → Pods → filter `namespace:sre-demo`.

Pod status immediately shows the failure:
```
sre-demo-api-<hash>   0/1   CrashLoopBackOff   5   4m
```

Restart count climbing every 30–60 seconds. The `0/1` ready state means the pod is failing its readiness probe — no traffic is being routed to it.

**Step 2 — Pod events**

Click the pod → Events tab.

```
Back-off restarting failed container
Started container sre-demo-api
Container sre-demo-api failed liveness probe, will be restarted
```

The events confirm the container starts and exits immediately — it never reaches a running state long enough to pass the liveness probe.

**Step 3 — Container logs**

Click the pod → Logs tab (or Datadog Log Explorer filter `pod_name:<crashing-pod>`).

```
crash
```

That's the entire container output. The startup command was `echo crash && exit 1` — the container printed "crash" and exited with code 1 before the application ever started.

**Step 4 — APM impact assessment**

APM → Services → `sre-demo-api` → request volume graph.

Traffic dropped significantly during the crash loop — the failing pod was receiving no traffic (readiness probe failing), and with only the remaining healthy pod handling requests, throughput halved. If both pods had been crashing, traffic would have dropped to zero.

### Root cause

Deployment patched with a startup command override (`/bin/sh -c "echo crash && exit 1"`). Container exits on every start → Kubernetes restarts it → CrashLoopBackOff.

### Key takeaway

**CrashLoopBackOff investigations start at the container log, not the application log.** If the application never starts, there are no application logs. The container stdout is the only evidence — and it's often a single line. Always check pod events first to understand the lifecycle, then container logs to see the last words.

---

## Investigation 4 — Availability Drop (P1)

### The alert

**Monitor:** `[sre-demo-api] API Availability - No Traffic`  
**Severity:** P1 Critical  
**Query:** `sum(last_5m):count:trace.fastapi.request{service:sre-demo-api, env:dev}`

This is the most severe scenario. No traffic reaching the application means either the app is down, the load balancer is broken, or the network path is broken.

### The auto-created incident

Before any manual investigation began, the Phase 12 workflow automation created a SEV-1 incident in Datadog Incident Response. The incident included:
- Triggered monitor name and ID
- Timestamp of the trigger
- Link back to the monitor

This is the value of Phase 12 in practice — the investigation starts with context already assembled, not from a raw alert notification.

### Investigation path

**Step 1 — Monitor behavior graph**

The graph showed a three-stage transition:
- **Green (OK)** — normal traffic flowing
- **Orange (Warn)** — traffic dropping but not yet zero
- **Red (Alert)** — sustained zero traffic

The warn state before alert is a key signal. A sudden drop straight to alert (no warn) would suggest a network-level cut. A warn-then-alert transition suggests traffic draining — consistent with pods being removed from the load balancer before scaling to zero completes.

**Step 2 — APM — zero request count**

APM → Services → `sre-demo-api` → request volume: flatline. No traces being generated means no requests are reaching the application layer.

**Step 3 — Kubernetes Explorer**

Infrastructure → Kubernetes Explorer → Deployments → `sre-demo-api`.

```
Desired: 0   Available: 0   Ready: 0
```

Deployment scaled to 0 replicas. No pods running. This is the definitive root cause signal — the application has no running instances.

**Step 4 — Check recent deployment events**

Kubernetes Explorer → Events → filter `deployment:sre-demo-api`.

```
Scaled down replica set sre-demo-api-77c57fd8bd to 0 from 1
```

Timestamp matches the monitor alert time exactly. Root cause confirmed.

**Step 5 — Confirm LoadBalancer state**

```bash
kubectl get endpoints sre-demo-api -n sre-demo
```
```
NAME           ENDPOINTS   AGE
sre-demo-api   <none>      45m
```

No endpoints registered — the LoadBalancer has nothing to route to. All traffic is being dropped at the load balancer level, which explains why APM shows zero traces (requests never reach the app).

### Root cause

Deployment scaled to 0 replicas. LoadBalancer endpoints drained. All inbound traffic dropped with no application to handle it.

### Incident resolution

Post-mortem note added to the Datadog incident:
```
Root cause: Deployment scaled to 0 replicas (chaos injection - Phase 13 validation).
Resolution: restore-all.sh executed — deployment restored to 2 replicas.
Time to detect: ~1 minute (monitor evaluation window).
Time to resolve: ~3.5 minutes (including restore rollout).
No data loss. No persistent impact.
```

Incident resolved and closed.

### MTTR breakdown

| Step | Time |
|---|---|
| P1 monitor fires | T+0:00 |
| Incident auto-created (Phase 12 workflow) | T+0:05 |
| Monitor warn → alert transition reviewed | T+1:00 |
| APM flatline confirmed | T+1:30 |
| Kubernetes Explorer — 0 replicas identified | T+2:00 |
| Root cause confirmed | T+2:00 |
| restore-all.sh executed | T+2:30 |
| Deployment healthy, HTTP 200 confirmed | T+3:45 |
| Incident resolved | T+4:00 |

**Total MTTR: ~4 minutes**

---

## Cross-Scenario Patterns

After running four investigations, these patterns hold across all of them:

### Pattern 1 — Start with the monitor, not the terminal

Every investigation started in Datadog, not with `kubectl`. The monitor message, behavior graph, and APM link give you more context in 30 seconds than `kubectl describe pod` gives you in 3 minutes.

### Pattern 2 — APM traffic shape tells you the failure type

| Traffic shape | Failure type |
|---|---|
| Volume stable, errors spike | Application error (bad code path) |
| Volume stable, latency spikes | Slow endpoint or resource contention |
| Volume drops, errors spike | Partial availability loss |
| Volume flatlines, no errors | Complete availability loss (infra layer) |

### Pattern 3 — When APM is empty, go to Kubernetes

APM generates traces only when requests reach the application. If APM shows nothing, the problem is upstream of the app — load balancer, network, or no running pods. That's when Kubernetes Explorer becomes the primary tool.

### Pattern 4 — Log-trace correlation shortcuts root cause analysis

The `dd.trace_id` in every structured log entry means you can jump from a log line directly to the full APM trace. During the error rate investigation, clicking the trace ID in a log entry opened the exact flame graph for that failing request — eliminating the need to manually correlate timestamps.

### Pattern 5 — p50 vs p99 divergence = subset problem

When median latency is normal but p99 is elevated, some requests are slow and most are not. Always filter by duration descending in APM traces before assuming a systemic problem.

---

## Investigation Checklist

For any P1/P2 incident, run through this checklist in order:

```
[ ] 1. Read the monitor message — note threshold, metric, time of trigger
[ ] 2. Open APM service page — check traffic volume, error rate, latency (all three)
[ ] 3. Is traffic present in APM?
        YES → filter traces by error or duration → flame graph → logs
        NO  → go to Kubernetes Explorer → check pod/deployment state
[ ] 4. Is the issue one endpoint or all endpoints?
        ONE  → application code path issue
        ALL  → infra or config change
[ ] 5. Check recent deployment events for changes
[ ] 6. Confirm resolution → verify monitor returns to OK → close incident
```

---

## What This Phase Proved

**The observability platform is not just decorative.** Every tool used in these investigations was built in a previous phase — APM (Phase 7), log-trace correlation (Phase 8), the dashboard (Phase 9), the monitors (Phase 11). Under real (simulated) failure conditions, each one provided actionable signal.

**Investigation time is directly proportional to preparation.** The monitors had deep links in their messages. Logs had `dd.trace_id`. Runbooks existed. Each of these reduced cognitive load during the investigation — decisions were already made, paths were already marked.

**Automated incident creation (Phase 12) gives you a head start.** The P1 incident was already open and timestamped before any manual investigation began. In a real on-call scenario that means the incident timeline is accurate and the communication channel exists before the first human acts.

---

## Screenshots to Capture

```
docs/screenshots/phase-14/
├── 01-apm-error-rate-spike.png          # APM service page during error flood
├── 02-error-trace-flamegraph.png        # Single error trace flame graph
├── 03-latency-p99-vs-p50.png           # p99 elevated, p50 normal
├── 04-slow-trace-flamegraph.png         # Slow /api/slow trace
├── 05-kubernetes-explorer-crashloop.png # Pod in CrashLoopBackOff
├── 06-pod-events-crash.png             # Container exit events
├── 07-apm-zero-traffic.png             # APM flatline during availability drop
├── 08-kubernetes-zero-replicas.png     # Deployment showing 0/0/0
└── 09-incident-resolved.png            # Closed incident with timeline
```

---

## Key Takeaways

- **Observability tools are only useful if you know the investigation order.** Monitors → APM → Logs → Kubernetes — not the other way around.
- **APM traffic shape is a diagnostic shortcut.** Learn to read volume + error rate + latency together before drilling into individual traces.
- **CrashLoopBackOff starts at container stdout, not application logs.** The application never ran — there are no application logs to read.
- **Log-trace correlation turns logs from noise into navigation.** A `dd.trace_id` in every log line means every log is a doorway into APM context.
- **Automated incidents reduce MTTR.** The timeline was already open before investigation began. That matters at 3am.

---

## What's Next — Phase 15: Datadog as Code with Terraform

Phase 14 closed the loop on the operational side — we can now detect, investigate, and resolve failures using the platform.

Phase 15 takes everything configured manually in the Datadog UI — monitors, dashboards, SLOs — and converts it to Terraform code using the Datadog provider. Observability infrastructure becomes version-controlled, peer-reviewed, and reproducible with a single `terraform apply`.

---

*All code for this series is available at [github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)*

*Next: [Phase 15 — Datadog as Code with Terraform](#)*