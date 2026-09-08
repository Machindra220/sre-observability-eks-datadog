# Phase 13: Chaos Engineering on EKS — Injecting Failures and Running the Full Incident Response Playbook

*Part 13 of 16 in the SRE Observability on AWS EKS with Datadog series*

---

## Introduction

Phases 1 through 12 built a complete observability platform — APM, logging, dashboards, SLOs, monitors, and automated incident creation. But building observability and *trusting* it under pressure are two very different things.

Phase 13 is where we deliberately break the system.

The goal is simple: inject real failures, confirm that every monitor fires, and walk through the full incident response lifecycle — detection, triage, resolution — using the platform we built. No synthetic data, no simulated alerts. Real pods crashing, real traffic dropping to zero, real Datadog alerts firing.

This is what chaos engineering looks like at a practical SRE level — not a full Chaos Monkey implementation, but a disciplined game day that validates the entire observability stack end-to-end.

By the end of this phase, we will have proven that the platform works exactly as designed when things go wrong.

---

## What We Built in This Phase

- Four failure injection scripts targeting distinct failure modes
- A master restore script that recovers the deployment safely after any scenario
- A full orchestration script that runs all scenarios in sequence
- Validated all five Datadog monitors firing against real failures
- Walked through a complete P1 incident response lifecycle

All scripts live in `scripts/chaos/` in the repository.

---

## The 4 Failure Scenarios

Each scenario targets a specific failure mode and a specific Datadog monitor. They are designed to be run independently or in sequence, with automatic restore between each.

| # | Scenario | Method | Monitor Triggered | Severity |
|---|---|---|---|---|
| 1 | High Error Rate | Flood `/api/error` with concurrent requests | P2 High Error Rate | High |
| 2 | High Latency | Flood `/api/slow` with concurrent requests | P3 High p99 Latency | Medium |
| 3 | Pod CrashLoopBackOff | Patch deployment with a bad startup command | P2 Pod Restart Rate | High |
| 4 | Availability Drop | Scale deployment to 0 replicas | P1 API Availability | Critical |

---

## Script Architecture

Before diving into each scenario, a note on the script design.

All chaos scripts share a `common.sh` that handles service discovery, logging helpers, and prerequisite checks. The key function is `get_app_url()`, which dynamically resolves the LoadBalancer hostname at runtime using `kubectl`:

```bash
get_app_url() {
  local hostname
  hostname=$(kubectl get svc "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  echo "http://${hostname}:${APP_PORT}"
}
```

This means the scripts work regardless of which LoadBalancer hostname AWS assigns — no hardcoded URLs.

---

## Scenario 1 — High Error Rate

### What it does

`inject-high-error-rate.sh` spawns 10 concurrent workers that continuously hit `/api/error`. Each worker loops for 180 seconds with a short sleep between requests — enough sustained load to push the 5xx rate above the P2 monitor threshold.

```bash
DURATION_SECS=180
CONCURRENCY=10

for (( i=1; i<=CONCURRENCY; i++ )); do
  (
    while [[ $(date +%s) -lt ${end_time} ]]; do
      curl -sf "${app_url}/api/error" -o /dev/null || true
      sleep 0.1
    done
  ) &
done
```

### What fired

The `[sre-demo-api] High Error Rate` monitor transitioned from OK → ALERT within the first evaluation window. The monitor behaviour graph showed a clean green-to-red transition, confirming the error rate crossed the threshold.

**Monitor query:** `sum(last_5m):sum:trace.fastapi.request.errors{service:sre-demo-api, env:dev}`

> **📸 Screenshot:** Monitor status page showing ALERT state with green → red transition

### Real issue encountered

The `/api/error` endpoint was only reachable at `/api/error`, not `/error`. This sounds obvious, but the original scripts used `/error` — resulting in 404s instead of 5xx responses. The monitor would never have fired with 404s because the error metric only counts application-level errors, not routing errors. Fixing the endpoint prefix was critical.

---

## Scenario 2 — High Latency

### What it does

`inject-high-latency.sh` uses 15 concurrent workers hitting `/api/slow` — the endpoint that introduces a ~2 second artificial delay. With 15 workers running concurrently, the p99 latency climbs well above the 2s threshold.

A baseline probe runs before the flood starts to confirm connectivity and document the pre-injection latency:

```bash
baseline_ms=$(curl -o /dev/null -s -w "%{time_total}" "${app_url}/api/slow" \
  | awk '{printf "%.0f", $1 * 1000}')
log_info "Baseline latency: ${baseline_ms}ms"
```

### What fired

The `[sre-demo-api] High p99 Latency` monitor fired within the first 5-minute evaluation window. The sustained red bar in the monitor behavior graph confirmed p99 stayed above threshold for the entire load period.

**Monitor query:** `percentile(last_5m):p99:trace.fastapi.request{service:sre-demo-api, env:dev}`

> **📸 Screenshot:** P3 High Latency monitor in ALERT state — sustained red bar across the full window

### Real issue encountered

The latency endpoint in the app is `/api/slow`, not `/api/latency`. This was discovered during pre-flight testing when `/api/latency` returned a 404. Always test each endpoint independently before running load scripts against them.

---

## Scenario 3 — Pod CrashLoopBackOff

### What it does

This scenario injects a failure at the Kubernetes layer rather than the application layer. The original approach of setting a bad `DD_TRACE_AGENT_URL` environment variable failed — ddtrace handles a missing trace agent gracefully and continues starting up. The app never crashed.

The correct approach is to patch the deployment with a startup command that always exits with a non-zero code:

```bash
kubectl patch deployment sre-demo-api -n sre-demo \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"sre-demo-api","command":["/bin/sh","-c","echo crash && exit 1"]}]}}}}'
```

This guarantees the container exits immediately on startup, triggering `CrashLoopBackOff` within seconds.

### What fired

The `[sre-demo-api] Pod Restart Rate` monitor fired as the restart count climbed past the threshold. Kubernetes progressively backs off restart attempts — the sequence was `Error → CrashLoopBackOff` with restart count incrementing every 30–60 seconds.

**Monitor query:** `sum(last_15m):sum:kubernetes_state.container.restarts{kube_namespace:sre-demo...}`

> **📸 Screenshot:** P2 Pod Restart Rate monitor in ALERT state

### Restore

```bash
# Remove the command override — reverts to the Dockerfile CMD
kubectl patch deployment sre-demo-api -n sre-demo \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"sre-demo-api","command":null}]}}}}'
```

### Lesson learned

**ddtrace does not crash the app on a missing trace agent.** It logs a warning and continues. If you want to test ddtrace failure specifically, you need to test at startup by pointing `DD_TRACE_AGENT_URL` to an unreachable host *and* setting `DD_TRACE_STARTUP_LOGS=true` to observe it — but it still won't exit. For crash injection, always use a direct command override.

---

## Scenario 4 — Availability Drop (P1)

### What it does

The most severe scenario. Scaling the deployment to 0 replicas means every incoming request returns a 503 immediately — the LoadBalancer has no healthy backend to route to.

```bash
kubectl scale deployment sre-demo-api -n sre-demo --replicas=0
```

The script probes `/api/health` every 5 seconds during the outage window and prints each HTTP response code, creating a real-time outage log in the terminal.

### What fired

The `[sre-demo-api] API Availability - No Traffic` monitor showed the full transition:
- **Green (OK)** → brief **orange (Warn)** → sustained **red (Alert)**

The warn state appears because traffic dropped sharply but the monitor needed one evaluation cycle to confirm zero traffic before escalating to alert. This is expected behaviour and the graph tells a clear story.

**Monitor:** Priority P1, severity:critical  
**Query:** `sum(last_5m):count:trace.fastapi.request{service:sre-demo-api, env:dev}`

> **📸 Screenshot:** P1 monitor showing green → orange → red transition

### Incident auto-creation

The Phase 12 workflow automation wired to this P1 monitor automatically created an incident in Datadog Incident Response the moment the monitor fired — no manual intervention required.

> **📸 Screenshot:** Incident Response showing auto-created SEV-1 incident

---

## The Restore Script

Every chaos scenario needs a reliable recovery path. `restore-all.sh` handles all scenarios in a single run:

```
Step 1 — Remove bad env var (DD_TRACE_AGENT_URL)
Step 2 — Remove command override (null patch)
Step 3 — Restore replica count (from backup or default 2)
Step 4 — Wait for rollout to complete
Step 5 — Health check confirmation
```

Output on successful restore:

```
[OK]    Bad env var removed.
[OK]    Command override removed.
[OK]    Scale command sent.
[INFO]  deployment "sre-demo-api" successfully rolled out
[OK]    API is healthy (HTTP 200). Restore complete. ✓
```

### Bug we caught and fixed

The original `restore-all.sh` had two issues:

1. **Bash syntax error** — two `else` blocks inside a single `if` statement. This would have caused the script to fail immediately on execution.
2. **URL mismatch** — the log message printed `/api/health` but the actual `curl` call hit `/health`, which returns 404. The health check would have reported failure even on a healthy deployment.

Both were caught during review before the script was run in production — this is why validating scripts before using them in chaos scenarios matters.

---

## What the Platform Proved

Running all four scenarios confirmed the following end-to-end:

**All monitors fired correctly:**
Every monitor built in Phase 11 triggered against a real failure with no false negatives. The queries and thresholds were correctly calibrated.

**APM traces correlated with failures:**
During the error rate and latency scenarios, APM flame graphs in Datadog showed the exact requests causing the failures — error spans visible in red, slow spans showing the full latency breakdown.

**Kubernetes Explorer reflected pod state:**
During Scenario 3, the Kubernetes Explorer showed pods transitioning through `Running → Error → CrashLoopBackOff` in real time. The `kubernetes_state.container.restarts` metric fed the monitor correctly.

**Phase 12 automation held up under real conditions:**
The P1 monitor firing triggered the incident creation workflow automatically. The incident appeared in Datadog Incident Response without any manual action — exactly what was built in Phase 12.

**Restore was clean and repeatable:**
`restore-all.sh` recovered the deployment to 2 healthy replicas with a confirmed HTTP 200 health check every time it was run.

---

## Incident Response Walkthrough — Scenario 4

Here is the full IR lifecycle for the availability drop:

**T+0:00** — `kubectl scale --replicas=0` executed  
**T+0:30** — Traffic drops to zero; P1 monitor evaluation begins  
**T+1:00** — Monitor transitions Warn → Alert  
**T+1:05** — Phase 12 workflow fires; SEV-1 incident auto-created in Datadog  
**T+1:10** — On-call engineer receives alert (monitor notification)  
**T+2:00** — Root cause identified: deployment scaled to 0 (chaos test)  
**T+2:30** — `restore-all.sh` executed  
**T+3:30** — Deployment rolled out; 2 pods Running  
**T+3:45** — Health check confirmed HTTP 200  
**T+4:00** — Incident resolved with post-mortem note  

**Resolution note added to incident:**
> Root cause: Intentional chaos injection for Phase 13 validation.  
> Resolution: Deployment restored to 2 healthy replicas via restore-all.sh.  
> All monitors confirmed firing correctly.

---

## Monitor Recovery Note

After chaos scenarios using `last_15m` windows (like Pod Restart Rate), monitors do not immediately return to OK once the failure stops. Datadog must complete a full clean evaluation window — up to 15 minutes — before the monitor resolves. This is expected and correct behaviour. Do not interpret a slow recovery as a malfunction.

---

## Screenshots Captured

```
docs/screenshots/phase-13/
├── 01-error-rate-monitor-alert.png
├── 02-latency-p99-monitor-alert.png
├── 03-pod-restart-monitor-alert.png
├── 04-p1-availability-monitor-alert.png
└── 05-incident-auto-created.png
```

---

## Repository Structure After Phase 13

```
scripts/
└── chaos/
    ├── common.sh
    ├── inject-high-error-rate.sh
    ├── inject-high-latency.sh
    ├── inject-pod-crash.sh
    ├── inject-availability-drop.sh
    ├── restore-all.sh
    └── run-all-scenarios.sh

docs/
├── screenshots/phase-13/
└── medium/phase-13-chaos-engineering.md
```

---

## Key Takeaways

- **Chaos engineering doesn't require complex tooling.** Four `kubectl` and `curl` commands are enough to validate a complete observability stack.
- **Test your failure injection before trusting it.** The ddtrace env var approach silently failed — production chaos scripts need to be validated just like application code.
- **Endpoint discovery matters.** Scripts that hit wrong paths produce misleading results. Always pre-flight test each endpoint before injecting load.
- **Restore scripts are as important as inject scripts.** A chaos scenario without a reliable restore path is just an outage.
- **The platform held.** Every monitor fired. Every alert was real. The automation worked.

---

## What's Next — Phase 14: Datadog as Code

Phase 13 proved the platform works under real failure conditions.

Phase 14 takes everything configured manually through the Datadog UI — monitors, dashboards, SLOs — and converts it to code using Terraform's Datadog provider. Infrastructure as code for observability: version-controlled, reproducible, and deployable in a single `terraform apply`.

---

*All code for this series is available at [github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)*

*Next: [Phase 14 — Datadog as Code with Terraform](#)*
