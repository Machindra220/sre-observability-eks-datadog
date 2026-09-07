```bash
cat > ~/sre-datadog-eks-observability/docs/medium/11-datadog-monitors.md << 'EOF'
```

---

```markdown
# Building Actionable Datadog Monitors Without Creating Alert Fatigue

## Five production-style monitors that tell you exactly what's wrong and what to do about it

---

## Problem

Most monitoring setups fail in one of two ways:

**Too few monitors:** Problems go undetected until users complain.
**Too many monitors:** Alerts fire constantly, engineers learn to ignore them.

Alert fatigue is real — when every alert feels like noise, the one critical 
alert that matters gets ignored too. The goal is monitors that fire rarely 
but always meaningfully.

This article covers how we built five production-style monitors as Phase 11 
of a larger SRE observability project on AWS EKS with Datadog.

---

## What Are We Achieving With These Monitors?

Before building anything, understand the purpose:

```text
Without monitors:
  Problem occurs → Users notice → Users complain → Engineer investigates
  Time to detection: minutes to hours

With good monitors:
  Problem occurs → Monitor fires → Engineer notified → Fix before users notice
  Time to detection: seconds to minutes
```

Each monitor we build answers a specific operational question:

| Monitor | Question it answers |
|---|---|
| API Availability | Is the service completely down? |
| High Error Rate | Are users getting errors right now? |
| High p99 Latency | Are users experiencing slow responses? |
| Pod Restart Rate | Is the application crashing repeatedly? |
| SLO Burn Rate | Are we burning reliability budget too fast? |

Together these five monitors cover every major failure mode for our service.

---

## Monitor Design Principles

### 1. Every alert must be actionable

```
Bad alert:  "CPU is high"
            → What do I do? Unknown.

Good alert: "Pod restart rate > 3 in 15 minutes in sre-demo namespace"
            → Check: kubectl get pods -n sre-demo
            → Causes: OOM kill, liveness probe failure, app crash
            → Action: Clear and specific
```

### 2. Set thresholds based on data, not guesses

Before setting a threshold, look at historical metrics:
- What is the normal baseline?
- What value indicates a real problem?
- What value is just noise?

Our error rate threshold of 5 errors/5 minutes was chosen because:
- Normal traffic generates 0-2 errors from health probes
- 5+ errors means `/api/error` is being hit repeatedly OR real failures
- Below 5 is normal variance, above 5 needs investigation

### 3. Use evaluation windows, not point-in-time

```
Point-in-time: "Alert if errors > 0 right now"
→ Fires on every single 500 error
→ Constant noise

Windowed:      "Alert if sum of errors > 5 in last 5 minutes"
→ Fires only on sustained error conditions
→ Meaningful signal
```

### 4. Add hysteresis (warning before alert)

```
Warning threshold: fires early, low urgency
Alert threshold:   fires later, high urgency, page someone

Example (latency):
  Warning: p99 > 2s  → "Getting slow, investigate when convenient"
  Alert:   p99 > 3s  → "Users are suffering, investigate NOW"
```

### 5. Handle missing data explicitly

```
Missing data = monitor has no metrics to evaluate
Options:
  Show last known status → hides outages (bad)
  Evaluate as 0          → treats silence as zero traffic
  Alert                  → treats silence as an outage

For availability monitors: missing data = outage → Alert
For restart monitors: missing data = no restarts → OK
```

---

## Priority System

| Priority | Meaning | Response |
|---|---|---|
| P1 Critical | Complete outage, revenue impact | Page immediately, all hands |
| P2 High | Significant degradation, many users affected | Page on-call engineer |
| P3 Medium | Partial degradation, some users affected | Investigate within 30 min |
| P4 Low | Minor issue, workaround available | Investigate next business day |
| P5 Info | Informational, no action needed | Review weekly |

Our mapping:
```
API Availability (down = everyone affected)   → P1 Critical
High Error Rate (errors = bad user experience) → P2 High
Pod Restart Rate (crash loop = instability)    → P2 High
SLO Burn Rate (budget risk)                   → P2 High
High Latency (slow = degraded experience)     → P3 Medium
```

---

## Monitor 1 — API Availability (P1 Critical)

### What it detects
Service is completely down — no traffic reaching the application.

### Why P1
If no requests are being served, every user is affected. This is a 
complete outage. Maximum urgency.

### Configuration
```
Metric: trace.fastapi.request
Filter: service:sre-demo-api env:dev
Aggregation: count sum over last 5 minutes

Alert:   < 1   (zero requests = outage)
Warning: < 10  (very low traffic = partial issue)

Missing data: Evaluate as 0 → status ALERT
```

**The missing data setting is critical.** If the application crashes 
and stops sending metrics, a monitor that shows "No Data" instead of 
"Alert" creates a blind spot — you think everything is fine when the 
service is actually down.

### What it catches
- Application crash (pod dies, no replacement)
- Load balancer misconfiguration
- DNS failure
- Network partition
- Deployment gone wrong

---

## Monitor 2 — High Error Rate (P2 High)

### What it detects
Sustained 500 errors — the service is running but returning failures.

### Why P2
Users are getting errors. The service is up but degraded. Needs immediate 
investigation but not a complete all-hands response.

### Configuration
```
Metric: trace.fastapi.request.errors
Filter: service:sre-demo-api env:dev
Aggregation: sum over last 5 minutes

Alert:   > 5 errors  (sustained error condition)
Warning: > 2 errors  (early warning)
```

**Why sum not rate?**
At our traffic volume (low), counting absolute errors is more meaningful 
than rate. At high traffic volume, use error rate percentage instead.

### What it catches
- Application bug returning 500s
- Dependency failure causing exceptions
- Database connection failures
- Memory exhaustion causing crashes
- Bad deployment introducing bugs

### Backtested validation
Monitor preview showed **2 Alert, 2 Recover** transitions during our 
testing period — confirming it would have fired during our `/api/error` 
traffic tests and recovered when traffic stopped. This validates the 
threshold is correctly calibrated.

---

## Monitor 3 — High p99 Latency (P3 Medium)

### What it detects
Slow responses at the 99th percentile — worst-case user experience is degraded.

### Why P3
Slow is bad but not as urgent as broken. Users can wait a few seconds; 
they can't tolerate errors. Investigate within 30 minutes.

### Configuration
```
Metric: trace.fastapi.request
Filter: service:sre-demo-api env:dev
Aggregation: p99 over last 5 minutes

Alert:   > 3s  (significantly slow)
Warning: > 2s  (approaching threshold)
```

**Why p99 not average?**
Average latency hides the worst user experiences. If 99 requests take 
100ms and 1 request takes 10s, the average is ~200ms — looks fine. 
The p99 is 10s — shows the real problem.

### What it catches
- Slow database queries
- External API timeouts
- Memory pressure causing GC pauses
- CPU saturation causing queue buildup
- Our intentional `/api/slow` endpoint (2-5s delay)

### Backtested validation
Preview showed **1 Alert, 1 Warn, 2 Recover** — fired during `/api/slow` 
traffic and recovered when slow requests stopped.

---

## Monitor 4 — Pod Restart Rate (P2 High)

### What it detects
Containers restarting repeatedly — indicates a crash loop.

### Why P2
A pod in CrashLoopBackOff means the application is continuously failing. 
Each restart causes brief downtime. If unchecked, it can cascade.

### Configuration
```
Metric: kubernetes_state.container.restarts
Filter: kube_namespace:sre-demo
Aggregation: sum over last 15 minutes

Alert:   > 3 restarts  (crash loop pattern)
Warning: > 1 restart   (unexpected restart)

Missing data: OK (no restarts = healthy)
```

**Why 15 minute window?**
Kubernetes has exponential backoff for restarts. A pod restarts at:
- 0s, 10s, 20s, 40s, 80s, 160s intervals
- After 3 restarts in 15 minutes, it's clearly in a crash loop

**Missing data = OK** — unlike the availability monitor, no restart 
data means no restarts happened, which is healthy.

### What it catches
- OOMKilled (memory limit exceeded)
- Liveness probe failures
- Application startup crashes
- Misconfigured environment variables
- Missing secrets causing startup failure

---

## Monitor 5 — SLO Availability Burn Rate (P2 High)

### What it detects
Error budget being consumed faster than the SLO allows.

### Why this is different from other monitors

Standard monitors fire when a threshold is crossed right now.
Burn rate monitors fire when you're on track to exhaust your error 
budget before the window ends.

```
Scenario:
  SLO: 99% availability over 30 days
  Error budget: 1% = 432 minutes of allowed downtime

  Day 1: Service has 2-hour outage
  Day 1 burn rate: 2 hours / (432 min / 30 days) = ~8x

  At 8x burn rate:
    Budget exhausts in 30/8 = 3.75 days
    Not 30 days

  Burn rate alert fires on Day 1
  → Fix the problem before budget is exhausted
```

### Configuration
```
SLO: sre-demo-api — Availability
Type: Burn Rate Alert
Evaluate overall SLO (not per group)

Long window:  1 hour
Short window: 5 minutes

Alert: burn rate > 2x  (exhausts budget in 15 days instead of 30)
Warn:  burn rate > 1.5x
```

**Why two windows?**
Multi-window burn rate detection reduces false positives:
- Short window (5m): detects current burn rate
- Long window (1h): confirms it's sustained, not a spike
- Both must exceed threshold to fire

### What it catches
- Sustained error conditions burning budget
- Slow degradation that would exhaust budget before month end
- Deployment introducing reliability regression

---

## AWS Secrets Manager Integration

During this phase we also solved the key management problem that caused 
daily friction — re-exporting API keys every terminal session.

### Solution: AWS Secrets Manager

```bash
# Store once
aws secretsmanager create-secret \
  --name "sre-demo/datadog" \
  --secret-string '{"DD_API_KEY":"...","DD_APP_KEY":"..."}'

aws secretsmanager create-secret \
  --name "sre-demo/aws-iam" \
  --secret-string '{"AWS_ACCESS_KEY_ID":"...","AWS_SECRET_ACCESS_KEY":"..."}'
```

```bash
# Load every morning with one command
source scripts/load-secrets.sh

# Output:
# ✅ DD_API_KEY loaded (46b61cf1...)
# ✅ DD_APP_KEY loaded (ddpat_6o...)
# ✅ AWS_ACCESS_KEY_ID loaded (AKIAXJ4P...)
# ✅ AWS_SECRET_ACCESS_KEY loaded
```

**Why keep secrets out of Terraform?**
```
terraform destroy → deletes all Terraform-managed resources
                  → if secrets were in Terraform, they'd be deleted too
                  → lose API keys, have to recreate manually

Secrets Manager is created once, survives terraform destroy
Infrastructure is ephemeral. Secrets are permanent.
```

Cost: ~$0.80/month for 2 secrets. Worth every cent.

---

## Validation

All 5 monitors created and showing OK:

| Priority | Monitor | Status |
|---|---|---|
| P1 | API Availability - No Traffic | ✅ OK |
| P2 | High Error Rate | ✅ OK |
| P2 | Pod Restart Rate | ✅ OK |
| P2 | SLO Availability Burn Rate | ✅ OK |
| P3 | High p99 Latency | ✅ OK |

Backtested data confirmed monitors would have fired correctly during 
our traffic tests:
- Error Rate: 2 alerts during error traffic tests
- Latency: 1 alert during /api/slow traffic tests
- Availability: 0 alerts (service was always up)
- Pod Restart: 0 alerts (pods never crashed)
- SLO Burn Rate: 0 alerts (burn rate healthy)

---

## Testing Monitors

To verify monitors work, trigger them deliberately:

```bash
LB=$(kubectl get svc sre-demo-api -n sre-demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Trigger High Error Rate monitor
for i in {1..20}; do
  curl -s http://${LB}/api/error > /dev/null
done

# Trigger High Latency monitor
for i in {1..10}; do
  curl -s http://${LB}/api/slow > /dev/null &
done
```

Watch monitors transition from OK → Warning → Alert → Recovery in 
Datadog → Monitors → List.

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Notifications | No recipients | PagerDuty, Slack, email |
| Escalation | None | Auto-escalate P1 after 5 min |
| Renotification | Disabled | Renotify every 30 min for P1/P2 |
| Thresholds | Static | Dynamic baselines with anomaly detection |
| Burn rate windows | 1h/5m | Multiple: 1h/5m, 6h/30m for different severities |
| Maintenance windows | None | Schedule downtime during deployments |
| Monitor-as-code | Manual UI | Terraform Datadog provider |
| Alert routing | None | Route by service, severity, time of day |

**Notification setup for production:**

```
Datadog → Monitors → Settings → Notification Policies
→ Create routing rules:
  P1 → PagerDuty (immediate page)
  P2 → Slack #incidents + PagerDuty (after 10 min)
  P3 → Slack #alerts only
```

---

## Lessons Learned

1. **Missing data handling is not optional.** A monitor that shows 
   "No Data" during an outage is worse than no monitor — it creates 
   false confidence. Always explicitly configure missing data behavior.

2. **Backtesting validates threshold calibration.** Datadog's preview 
   chart shows how many times the monitor would have fired historically. 
   If it shows 50 alerts in 1 hour, your threshold is too sensitive. 
   If it shows 0 alerts ever, it's too loose.

3. **P1 monitors should be very few.** If everything is P1, nothing 
   is P1. Reserve P1 for true complete outages. Our only P1 monitor 
   is "no traffic at all" — a genuine complete service failure.

4. **Multi-window burn rate is more reliable than single-window.** 
   A single 5-minute spike in error rate can trigger a single-window 
   burn rate alert. The dual-window (1h + 5m) requires both to be 
   elevated — filtering out transient spikes.

5. **AWS Secrets Manager pays dividends immediately.** One `source` 
   command replaces four manual `export` commands every session. 
   Small automation, outsized daily benefit. Always automate repeated 
   manual steps.

6. **Monitor names should include service and condition.** 
   `[sre-demo-api] High Error Rate` tells you immediately which 
   service and what's wrong. `High Error Rate` alone is ambiguous 
   at 3am when you're half asleep.

---

## What's Next

**Article 12: Automating Incident Creation from Datadog Alerts**

With monitors firing correctly, we'll automate the incident response 
workflow — when a P1 or P2 monitor fires, Datadog automatically creates 
an incident, assigns it, and notifies the right people without manual 
intervention.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*
```

---
