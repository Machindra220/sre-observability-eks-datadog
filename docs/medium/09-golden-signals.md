
# Implementing the Four Golden Signals with Datadog

## Building a production-style SRE dashboard using Traffic, Latency, Errors, and Saturation metrics from APM and infrastructure data

---

## Problem

Every service generates hundreds of metrics. Which ones actually matter?

Google's SRE Book answers this with the Four Golden Signals — if you can 
only monitor four things for a user-facing service, monitor these:

```text
Traffic    → How much demand is hitting your system?
Latency    → How long does it take to respond?
Errors     → How often does it fail?
Saturation → How full is your system?
```

These four signals are sufficient to detect virtually every user-impacting 
problem before users notice or report it. This article covers how we 
implemented the Golden Signals dashboard as Phase 9 of a larger SRE 
observability project on AWS EKS with Datadog.

---

## Why These Four Signals

### Traffic

Traffic tells you the baseline demand on your system and helps detect:
- Sudden drops (outage, routing failure)
- Sudden spikes (viral traffic, DDoS attack)
- Gradual growth (capacity planning)

Without traffic data, you can't distinguish "the system is slow because 
it's broken" from "the system is slow because it's handling 10x normal load."

### Latency

Latency measures user experience directly. Two key rules:

1. **Measure slow requests separately from fast ones** — average latency 
   hides the worst user experiences. Use percentiles.

2. **Track error latency separately** — a fast error (500 in 1ms) is 
   different from a slow error (timeout after 30s). Both are bad but 
   for different reasons.

**Percentile thresholds for our service:**
```
p50 (median): < 200ms    → typical user experience
p95:          < 1s       → most users are happy
p99:          < 2s       → worst-case users still acceptable
```

Our `/api/slow` endpoint deliberately violates all three — p99 reaches 
4-5 seconds — making it easy to test alerting.

### Errors

Error rate tells you the reliability of your service from the user's 
perspective. Track both:
- **Rate** — errors per second (absolute volume)
- **Percentage** — errors / total requests (relative severity)

A spike from 0 to 10 errors/second means very different things at 
100 req/s (10% error rate — critical) vs 10,000 req/s (0.1% — normal).

### Saturation

Saturation measures how close your system is to its limits. When a 
service becomes saturated:
- Requests queue up → latency increases
- Memory fills up → OOM kills → pod restarts
- CPU maxes out → slow responses → cascading failures

Track saturation proactively — by the time latency spikes, you're 
already degraded.

---

## Architecture

```text
FastAPI App (sre-demo-api)
     |
     +-- ddtrace (APM)
     |        |
     |   trace.fastapi.request        ← Traffic + Latency + Errors
     |   trace.fastapi.request.errors ← Error count
     |
     +-- Container metrics
              |
         container.cpu.usage    ← CPU Saturation
         container.memory.usage ← Memory Saturation
              |
              v
         Datadog
              |
     Golden Signals Dashboard
```

---

## Metrics Used

### Traffic
```
trace.fastapi.request
  aggregation: count
  filter: service:sre-demo-api env:dev
  → Requests per second, grouped by resource_name (endpoint)
```

### Latency
```
trace.fastapi.request
  aggregation: p50 / p95 / p99
  filter: service:sre-demo-api env:dev
  → Latency percentiles over time
```

### Errors
```
trace.fastapi.request.errors
  aggregation: count
  filter: service:sre-demo-api env:dev
  → Error count over time

Formula: (errors / total) * 100
  → Error rate percentage
```

### Saturation
```
container.cpu.usage
  aggregation: avg by pod_name
  filter: kube_namespace:sre-demo
  → CPU usage per pod

container.memory.usage
  aggregation: avg by pod_name
  filter: kube_namespace:sre-demo
  → Memory usage per pod
```

---

## Dashboard Widgets

### Widget 1 — Request Rate (Traffic)

```
Type: Timeseries
Metric: trace.fastapi.request
Filter: service:sre-demo-api env:dev
Aggregation: count
Group by: resource_name
Title: Request Rate (req/s)
```

Groups traffic by endpoint — immediately visible which endpoints are 
receiving traffic and in what proportion.

### Widget 2 — Total Requests (Traffic)

```
Type: Query Value
Metric: trace.fastapi.request
Filter: service:sre-demo-api env:dev
Aggregation: count
Reduce to: sum
Title: Total Requests (1hr)
Value: 1.11k (1,110 requests)
```

### Widget 3 — p99 Latency (Latency)

```
Type: Timeseries
Metric: trace.fastapi.request
Filter: service:sre-demo-api env:dev
Aggregation: p99
Title: p99 Latency
Spikes: 4.57s, 4.29s (from /api/slow)
```

### Widget 4 — Latency Percentiles (Latency)

```
Type: Timeseries
Query A: trace.fastapi.request, p50
Query B: trace.fastapi.request, p95
Query C: trace.fastapi.request, p99
Filter: service:sre-demo-api
Title: Latency Percentiles (p50/p95/p99)
```

Three lines on one chart — immediately shows the spread between typical 
and worst-case response times.

### Widget 5 — Error Rate (Errors)

```
Type: Timeseries
Metric: trace.fastapi.request.errors
Filter: service:sre-demo-api env:dev
Aggregation: sum
Title: Error Rate
```

### Widget 6 — Error Rate % (Errors)

```
Type: Query Value
Query A: trace.fastapi.request.errors, sum, avg
Query B: trace.fastapi.request, sum, avg
Formula: (a/b)*100
Unit: percent
Title: Error Rate %
Value: 47.91%
```

**Why 47.91%?** Our `/api/error` endpoint randomly returns 400 or 500 
responses. During heavy testing, we hit this endpoint as frequently as 
normal endpoints. In production this would be ~0.1-1%.

### Widget 7 — App CPU Saturation (Saturation)

```
Type: Timeseries
Metric: container.cpu.usage
Filter: kube_namespace:sre-demo
Aggregation: avg by pod_name
Title: App CPU Saturation
```

Shows CPU spikes that correlate exactly with our traffic load tests — 
validating end-to-end observability.

### Widget 8 — App Memory Saturation (Saturation)

```
Type: Timeseries
Metric: container.memory.usage
Filter: kube_namespace:sre-demo
Aggregation: avg by pod_name
Title: App Memory Saturation
Value: stable ~50MB
```

Flat line confirms no memory leak in our FastAPI application.

---

## Key Datadog Concepts Learned

### Aggregation vs Reduce (Query Value widgets)

**Aggregation** — how to combine values across multiple sources:
```
sum  → add all sources together
avg  → average across sources
p99  → 99th percentile across sources
```

**Reduce** — how to collapse time series to single number:
```
sum  → accumulate all time points (663 total requests)
last → most recent data point
avg  → average over time window
```

**Common mistake:** Using `sum` to reduce gives accumulated totals, 
not current state. Use `last` for "what is it now", `sum` for "how 
many total", `avg` for "what is the typical value".

### Formula widgets for derived metrics

Error rate percentage requires dividing two metrics:

```
Query A: errors count → (a)
Query B: total requests count → (b)
Formula: (a / b) * 100
```

Datadog formula widgets support: `+`, `-`, `*`, `/`, and functions 
like `abs()`, `log2()`, `top()`.

### Why percentiles over averages

```text
10 requests with response times:
10ms, 10ms, 10ms, 10ms, 10ms, 10ms, 10ms, 10ms, 10ms, 5000ms

Average: 509ms  ← looks bad, but 90% of users had 10ms
p99:     5000ms ← shows the real problem accurately
p50:     10ms   ← shows typical experience accurately
```

Averages are distorted by outliers. Percentiles tell the truth about 
what each segment of your users is experiencing.

---

## Traffic Generation for Testing

We generated sustained traffic across all endpoints to populate the dashboard:

```bash
for i in {1..100}; do
  curl -s http://${LB}/api/health > /dev/null
  curl -s http://${LB}/api/products > /dev/null
  curl -s http://${LB}/api/orders > /dev/null
  curl -s http://${LB}/api/users > /dev/null
  curl -s http://${LB}/api/error > /dev/null
  curl -s http://${LB}/api/slow > /dev/null
  sleep 2
done
```

**What this revealed:**
- Request rate widget showed clear traffic pattern by endpoint
- Latency widget spiked every ~12 seconds (each `/api/slow` call)
- CPU saturation widget showed spikes matching traffic loop timing
- Error rate confirmed ~50% during testing (expected with `/api/error`)

---

## Alert Thresholds for Production

Based on the Golden Signals, here are the monitors we'll create in Phase 11:

| Signal | Metric | Warning | Critical |
|---|---|---|---|
| Traffic | Request rate drops | < 50% of baseline | = 0 (complete outage) |
| Latency | p99 response time | > 1s | > 2s |
| Latency | p95 response time | > 500ms | > 1s |
| Errors | Error rate % | > 1% | > 5% |
| Saturation | CPU usage | > 70% | > 85% |
| Saturation | Memory usage | > 75% | > 90% |

---

## Infrastructure Automation Update

Added Datadog agent installation to `infra-up.sh` — now running one 
script restores complete project state:

```bash
./scripts/infra-up.sh
```

Sequence:
```
1. terraform apply (VPC, EKS, ECR)
2. Build + push Docker image
3. Update kubeconfig
4. Wait for node Ready
5. Apply Kubernetes manifests
6. Wait for app pod Ready
7. Install Datadog agent (Helm)
8. Show cluster status
```

This eliminates the manual steps required when recreating infrastructure 
between sessions — critical for a cost-conscious learning environment 
where we destroy and recreate infrastructure regularly.

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Error rate | ~48% (intentional) | Should be < 0.1% |
| Latency threshold | p99 < 5s | p99 < 500ms for most APIs |
| Traffic baseline | Manual load test | Establish from 2 weeks of production data |
| Saturation alerts | None yet | Alert at 70% CPU, 80% memory |
| Dashboard access | Single user | Share with team, embed in runbooks |
| Time range | 1 hour | Monitor 24h trends for capacity planning |
| Custom metrics | None | Add business metrics (orders/sec, revenue/min) |

---

## Lessons Learned

1. **Percentiles over averages, always.** A single slow request 
   (4.57s `/api/slow`) was invisible in the average but clearly 
   visible at p99. In production, averages hide the worst user 
   experiences.

2. **Error rate percentage requires careful formula construction.** 
   Dividing `last` values gives wrong results (32k%). Dividing `avg` 
   values gives meaningful percentages. The reduce function matters 
   as much as the aggregation.

3. **High error rates during testing are expected.** 48% error rate 
   looks alarming but is correct — we designed `/api/error` to fail. 
   Understanding your baseline before setting alert thresholds prevents 
   alert fatigue.

4. **CPU saturation spikes correlate with traffic.** Every traffic 
   loop produced a visible CPU spike in the saturation widget — 
   validating that our observability pipeline captures the full 
   cause-and-effect chain.

5. **Golden Signals are sufficient, not exhaustive.** Four signals 
   cover most incidents. Start here before adding specialized metrics. 
   Each additional metric increases cognitive load for on-call engineers.

6. **Automate infrastructure restoration.** Adding Datadog to 
   `infra-up.sh` saves 10-15 minutes every session. In a project 
   where infrastructure is destroyed and recreated regularly, 
   automation compounds in value quickly.

---

## What's Next

**Article 10: From Metrics to Reliability — Implementing SLIs, SLOs 
and Error Budgets in Datadog**

With the Golden Signals dashboard complete, we'll formalize our 
reliability targets by defining Service Level Indicators (SLIs), 
Service Level Objectives (SLOs), and Error Budgets — turning 
observability data into reliability commitments.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*
```

---

```bash
cd ~/sre-datadog-eks-observability
git add docs/medium/09-golden-signals.md
git commit -m "docs: add Medium article 09 - Golden Signals dashboard"
git push origin main
```

---

**Screenshots to capture:**
```
[ ] Full Golden Signals dashboard (all 8 widgets)
[ ] Request Rate widget (traffic by endpoint)
[ ] Latency Percentiles widget (p50/p95/p99 lines)
[ ] Error Rate % widget (47.91%)
[ ] App CPU Saturation widget (spikes during load test)
[ ] App Memory Saturation widget (flat stable line)
```

---

**STATE UPDATE**
```
Completed:
✅ Phase 1 - FastAPI application
✅ Phase 2 - AWS infrastructure (Terraform)
✅ Phase 3 - EKS deployment
✅ Phase 4 - GitHub Actions CI/CD
✅ Phase 5 - Datadog agent on EKS
✅ Phase 6 - Kubernetes infrastructure monitoring
✅ Phase 7 - Datadog APM (distributed tracing)
✅ Phase 8 - Log-trace correlation
✅ Phase 9 - Golden Signals dashboard
✅ Articles 1-9 committed to docs/medium/
✅ infra-up.sh updated with Datadog installation
