
```markdown
# From Metrics to Reliability: Implementing SLIs, SLOs and Error Budgets in Datadog

## Turning observability data into formal reliability commitments with math that actually makes sense

---

## Problem

Dashboards show you what's happening. SLOs tell you whether what's happening 
is acceptable.

Without SLOs:
```text
Engineer: "Is the service healthy?"
Response: "Latency looks okay... errors seem normal..."
Decision: Deploy? Roll back? Unknown.
```

With SLOs:
```text
Engineer: "Is the service healthy?"
Response: "Availability SLO: 100% ✅ | Latency SLO: 92.8% ⚠️ | Error budget: 29% remaining"
Decision: Service is up but latency budget burning fast. Investigate /api/slow before deploying.
```

This article covers how we implemented SLIs, SLOs and Error Budgets as 
Phase 10 of a larger SRE observability project on AWS EKS with Datadog.

---

## The Math — Made Simple

### SLI (Service Level Indicator)

An SLI is a ratio that measures one aspect of your service reliability.

**Availability SLI formula:**
```
                    Good Requests
SLI = ─────────────────────────────────── × 100
       Good Requests + Bad Requests
```

**Example:**
```
1000 total requests
  914 returned 200/400/404 (good)
   86 returned 500 (bad)

SLI = 914 / (914 + 86) × 100
    = 914 / 1000 × 100
    = 91.4%
```

**Latency SLI formula:**
```
                    Fast Requests (< threshold)
SLI = ─────────────────────────────────────────── × 100
       Fast Requests + Slow Requests (≥ threshold)
```

**Example:**
```
1000 total requests
  929 completed in under 2 seconds (good)
   71 took 2+ seconds (bad - our /api/slow endpoint)

SLI = 929 / (929 + 71) × 100
    = 929 / 1000 × 100
    = 92.9%
```

---

### SLO (Service Level Objective)

An SLO is the TARGET you set for your SLI.

```
SLO = "My SLI must be at or above X% over Y time window"
```

**Our SLOs:**
```
Availability SLO: SLI ≥ 99%  over 30 days
Latency SLO:      SLI ≥ 90%  over 30 days
```

**What Target=90% means (latency SLO):**

```
Target = 90%

Translation: "90% of all requests must complete in under 2 seconds"

If you send 100 requests:
  ≥ 90 must be fast (< 2s)  ← target
  ≤ 10 can be slow (≥ 2s)   ← allowed failures

If only 85 requests are fast → SLO BREACHED
If 95 requests are fast      → SLO MET (with 5% margin)
```

**What Status=92.8% means:**

```
Status = 92.8%

This is your CURRENT SLI value compared to the target.

92.8% > 90% target → SLO is currently BEING MET ✅

Translation: "Right now, 92.8% of requests in the last 30 days 
             completed in under 2 seconds"

The 2.8% margin above the 90% target is your cushion.
```

**Simple comparison:**
```
Target  = the minimum acceptable score (like a passing grade)
Status  = your actual current score

Target: 90%  (you need at least this)
Status: 92.8% (you currently have this)
Result: Passing ✅ but only by 2.8 points
```

---

### Error Budget

Error budget is the amount of unreliability your SLO allows.

**Error Budget formula:**
```
Error Budget = 100% - SLO Target
```

**Our error budgets:**
```
Availability SLO target = 99%
Error Budget = 100% - 99% = 1%

Over 30 days = 43,200 minutes
1% of 43,200 = 432 minutes of allowed downtime per month
             = 7.2 hours per month
             = ~14.4 seconds per hour
```

```
Latency SLO target = 90%
Error Budget = 100% - 90% = 10%

If we handle 1000 requests per day:
10% of 1000 = 100 requests per day allowed to be slow
```

**Error Budget Remaining formula:**
```
                    Actual Bad Events
Budget Consumed = ──────────────────────── × 100
                   Allowed Bad Events

Budget Remaining = 100% - Budget Consumed
```

**Our latency example:**
```
Allowed bad events (10% of total): ~185 requests
Actual bad events (slow requests): 131 requests (/api/slow hits)

Budget Consumed  = 131/185 × 100 = 70.8%
Budget Remaining = 100% - 70.8% = 29.2% ≈ 29%
```

This matches what Datadog showed: **Error Budget Left: 29%**

---

### Burn Rate

Burn rate measures how fast you're consuming the error budget.

```
Burn Rate = 1x  → consuming budget at exactly the SLO rate
                   (will exhaust budget exactly at end of window)

Burn Rate = 2x  → consuming 2× faster than allowed
                   (will exhaust budget in half the window)

Burn Rate = 0x  → not consuming any budget
                   (perfectly healthy)
```

**Our burn rate was ~0.8x** — consuming budget slightly slower than 
the SLO rate. Healthy, but /api/slow is consistently burning budget.

---

## Why These Targets?

### Availability: 99% (not 99.9%)

Production APIs typically target 99.9% or higher. We chose 99% because:

```
Our /api/error endpoint randomly returns 500 errors.
In testing, we generate heavy error traffic.
99.9% target would be immediately breached and stay breached.
99% gives us meaningful signal without constant breach.
```

In production, you'd set targets based on:
- Historical baseline (what have you actually achieved?)
- Business requirements (what do users expect?)
- Cost of reliability (higher targets = more engineering effort)

### Latency: 90% under 2 seconds

```
Our /api/slow takes 2-5 seconds deliberately.
If we target 95%: breached immediately (too strict)
If we target 50%: meaningless (too loose)
90% is achievable but meaningful - /api/slow consumes the budget
```

The 2-second threshold comes from research showing users perceive 
responses over 2 seconds as "slow." Under 1 second feels "instant."

---

## Architecture

```text
FastAPI App
     |
     +-- trace.fastapi.request      ← all requests
     +-- trace.fastapi.request      ← filtered by status_code < 500
     +-- trace.fastapi.request      ← filtered by duration < 2s
     |
     v
Datadog APM
     |
     v
SLO Calculation Engine
     |
     +-- Good Events count
     +-- Bad Events count
     +-- SLI = Good/(Good+Bad) × 100
     +-- Compare to Target
     +-- Calculate Error Budget
     |
     v
SLO Dashboard
     |
     +-- Status (current SLI %)
     +-- Error Budget Left (%)
     +-- Error Budget Burndown chart
     +-- Burn Rate chart
     +-- Per-endpoint breakdown
```

---

## SLO 1 — Availability

### Configuration

```
Type: Metric Based (By Count)

Good Events:
  Metric: trace.fastapi.request
  Filter: service:sre-demo-api
  Threshold: http.status_code < 500
  → Counts requests returning 200, 400, 404

Bad Events:
  Metric: trace.fastapi.request
  Filter: service:sre-demo-api
  Threshold: http.status_code >= 500
  → Counts requests returning 500, 502, 503

Target: 99%
Warning: 99.5%
Window: 30 days rolling
```

### Why 400 is a "Good Event"

This is a common SRE decision point:

```
400 Bad Request = client sent invalid data
                = client's fault, not service's fault
                = service is working correctly

500 Internal Server Error = service failed
                          = service's fault
                          = counts against availability
```

A 400 means your service correctly rejected bad input. Your service 
is functioning as designed. Only 5xx errors indicate service failure.

### Results

```
Status: 100.0% ✅
Error Budget: 100% (17.8 reqs)
Burn Rate: ~0

Breakdown:
  http.status_code:200 → 100% (1.64K requests)
  http.status_code:400 → 100% (49 requests)
  http.status_code:404 → 100% (10 requests)
  http.status_code:500 → 100% (86 requests counted as bad events)
```

100% availability because even though we have 500 errors, 
the SLI formula counts them correctly and we're within the 1% budget.

---

## SLO 2 — Latency

### Configuration

```
Type: Metric Based (By Count)

Good Events:
  Metric: trace.fastapi.request
  Filter: service:sre-demo-api
  Threshold: duration < 2 seconds
  Group by: resource_name

Bad Events:
  Metric: trace.fastapi.request
  Filter: service:sre-demo-api
  Threshold: duration >= 2 seconds
  Group by: resource_name

Target: 90%
Warning: 95%
Window: 30 days rolling
```

### Results — The Interesting Part

```
Overall Status: 92.9% ✅ (above 90% target)
Error Budget: 29% remaining ⚠️

Per-endpoint breakdown:
  get_/api/slow   → 0.0% 🔴 Error Budget: -900%
  get_/api/orders → 100% ✅
  get_/api/users  → 100% ✅
  get_/api/ready  → 100% ✅
  get_/api/health → 100% ✅
```

**`/api/slow` is at 0% with -900% error budget.**

This is the power of SLOs — the overall service passes (92.9% > 90%) 
but the per-endpoint view immediately identifies the problematic endpoint.

**Why -900%?**
```
/api/slow takes 2-5 seconds → ALL requests are "bad events"
Good events: 0
Bad events: 131

SLI = 0 / (0 + 131) × 100 = 0%

Error budget allowed: ~14 slow requests
Actual slow requests: 131
Budget consumed: 131/14 × 100 = 936% → shown as -900% (over budget)
```

---

## Reading the SLO Dashboard

### Error Budget Burndown Chart

```
100% ────────────────────────────────┐
                                     │ ← budget dropping
                                     │
                                     └──── today
 0%  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  ← "out of budget" line
```

A healthy chart shows a nearly flat line near 100%.
A dropping line means budget is being consumed.
Hitting the "out of budget" line = SLO breached.

### Burn Rate Chart

```
Burn Rate
   1.0 ────────────────  ← sustainable rate
   0.8                    ← our current rate (healthy)
   0.5
   0.0 ────────────────
        Aug          Sep
```

Our burn rate of ~0.8x means we're consuming budget slightly 
slower than the SLO allows — sustainable over 30 days.

### SLO States

| State | Meaning |
|---|---|
| OK (green) | SLI > target, budget healthy |
| Warning (yellow) | SLI between warning and target thresholds |
| Breached (red) | SLI < target, SLO violated |

Our SLOs:
```
Availability → OK (100% >> 99% target)
Latency      → Warning (92.8% > 90% target, but budget at 29%)
```

---

## Error Budget Policy

Error budgets are useful only when you have a policy for how to use them:

```
Error Budget > 50% → Ship features freely
                     Run experiments
                     Accept higher deployment risk

Error Budget 20-50% → Be cautious
                      Run smaller experiments
                      Monitor deployments closely

Error Budget < 20%  → Freeze non-critical deployments
                      Focus on reliability work
                      Investigate budget consumption

Error Budget = 0%   → Stop all deployments
                      Incident response mode
                      All hands on reliability
```

Our latency budget at 29% → we should be cautious about 
deploying changes that might increase latency further.

---

## What's Missing — Future Enhancements

### Burn Rate Alerts

An SLO without a burn rate alert is incomplete. Next phase will add:

```
Alert: Burn rate > 2x for 1 hour
→ At this rate, budget exhausts in 15 days instead of 30
→ Page on-call engineer

Alert: Burn rate > 10x for 5 minutes
→ Critical: budget exhausts in 72 hours
→ Immediate incident response
```

### SLO-based Deployment Gates

```
CI/CD pipeline check:
  If error_budget_remaining < 20%:
    Block deployment
    Require manual approval
  Else:
    Proceed with deployment
```

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Availability target | 99% | 99.9% or 99.95% |
| Latency target | 90% | 95-99% depending on endpoint |
| Latency threshold | 2s | 200-500ms for most APIs |
| Window | 30 days | Multiple windows (7d, 30d, 90d) |
| Bad event definition | HTTP 5xx | Include timeouts, circuit breaks |
| Error budget policy | None | Formal policy with deployment gates |
| Burn rate alerts | None | Multi-window burn rate monitors |
| SLO review | None | Weekly SLO review meeting |

---

## Lessons Learned

1. **Target is the minimum, Status is the actual.** Target=90% means 
   "I need at least 90%." Status=92.8% means "I currently have 92.8%." 
   The gap between them (2.8%) is your cushion before breaching.

2. **SLOs reveal endpoint-level problems that overall metrics hide.** 
   The latency SLO passed overall (92.9%) but per-endpoint breakdown 
   immediately showed `/api/slow` at 0%. Without per-endpoint grouping, 
   this would be invisible.

3. **400 errors are not your fault.** Count 4xx as good events in 
   availability SLOs. Your service correctly processed the request — 
   the client sent bad data. Counting 4xx as failures inflates your 
   error rate and makes SLOs meaninglessly strict.

4. **Error budget without policy is just a number.** The budget tells 
   you how much unreliability you have left. The policy tells you what 
   to do when it runs low. Both are necessary.

5. **Start with loose targets and tighten over time.** We chose 99% 
   availability and 90% latency — achievable in a learning environment. 
   In production, establish baseline first (what have you actually 
   achieved over the past 90 days?) then set target slightly below that.

6. **Burn rate is more actionable than budget remaining.** 29% budget 
   remaining sounds alarming. 0.8x burn rate sounds healthy. Both 
   describe the same situation — but burn rate tells you the trajectory, 
   not just the current state.

---

## What's Next

**Article 11: Building Actionable Datadog Monitors Without Creating 
Alert Fatigue**

With SLOs defined, we'll create monitors that alert when those SLOs 
are at risk — before they breach. Including burn rate alerts, 
multi-window alerting, and the discipline to keep alert noise low.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*
```
