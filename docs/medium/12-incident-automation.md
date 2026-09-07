# Automating Incident Creation from Datadog Alerts

## Building a Monitor → Workflow → Incident pipeline that responds faster than any human can

---

## Problem

Monitoring without incident management is incomplete. An alert fires at 3am — 
what happens next?

```text
Without automation:
  3:00am - Monitor fires
  3:07am - Engineer wakes up, checks phone
  3:12am - Engineer opens Datadog
  3:15am - Engineer manually creates incident
  3:18am - Engineer fills in severity, title, links
  3:20am - Engineer notifies team
  
  20 minutes lost before investigation even starts
  Critical context missing from incident record

With automation:
  3:00am - Monitor fires
  3:00am - Workflow creates incident automatically
             ├── Title populated from monitor name
             ├── Severity set to SEV-1
             ├── Dashboard link included
             └── Runbook link included
  3:00am - Incident record complete
  3:07am - Engineer wakes up, opens incident with full context
  
  Investigation starts immediately
```

This article covers how we built automated incident creation as Phase 12 
of a larger SRE observability project on AWS EKS with Datadog.

---

## Architecture

```text
P1 Monitor Alert
(API Availability - No Traffic)
        |
        v
Datadog Workflow Automation
(sre-demo-api — Auto Incident on P1 Alert)
        |
        v
Datadog Incident Created automatically:
  Title:    Monitor Alert: [sre-demo-api] API Availability - No Traffic
  Severity: SEV-1
  Notes:    Service info + Dashboard link + Runbook link
        |
        v
Incident Response page
        |
        v
Engineer investigates with full context
```

---

## Components

### Datadog Incident Management

A formal system for tracking service disruptions:

```text
Incident contains:
  ├── ID and Title
  ├── Severity (SEV-1 to SEV-5)
  ├── Status (Active, Stable, Resolved)
  ├── Timeline of events
  ├── Linked monitors and dashboards
  ├── Responders (who is working on it)
  ├── Runbook link
  ├── Customer impact
  └── Postmortem (after resolution)
```

**Severity levels:**
SEV-1: Complete outage, all users affected
SEV-2: Major degradation, many users affected
SEV-3: Partial degradation, some users affected
SEV-4: Minor issue, workaround available
SEV-5: Cosmetic issue, no user impact


### Datadog Workflow Automation

An automation engine that connects monitoring events to actions:

```text
Trigger → Condition → Action → Action → ...

Our workflow:
Monitor Alert → Create Incident (SEV-1)
```

Supports 2500+ actions including:
- Create/update incidents
- Send Slack messages
- Create PagerDuty alerts
- Run GitHub Actions
- Scale Kubernetes deployments
- Call any HTTP API

---

## Runbooks

Before building automation, we created runbooks — the human-readable 
response guides that the incident links to.

### What is a Runbook?

A runbook answers: **"The alert fired. Now what?"**

```text
Good runbook:
  - Alert name and severity
  - Impact on users
  - First 5 checks to do (< 2 minutes)
  - Possible causes with fixes
  - Recovery validation
  - Escalation path

Bad runbook:
  - "Check if the service is down"
  - Generic troubleshooting steps
  - No specific commands
```

### Runbooks Created
docs/runbooks/
├── api-availability.md ← P1: Complete outage response
├── api-5xx.md ← P2: High error rate response
├── high-latency.md ← P3: Slow response response
└── pod-restarts.md ← P2: CrashLoopBackOff response


### Example: API Availability Runbook

```markdown
## Initial Checks (< 2 minutes)

### 1. Check pod status
kubectl get pods -n sre-demo
Expected: sre-demo-api-xxx 1/1 Running

### 2. Check pod logs
kubectl logs -n sre-demo -l app=sre-demo-api --tail=50

### 3. Check service
kubectl get svc -n sre-demo

### 4. Test endpoint
curl -v http://${LB}/api/health
```

Runbooks are stored in Git — version controlled, reviewable, 
improvable after every incident. The incident links directly to 
the relevant runbook.

---

## Building the Workflow

### Step 1 — Monitor Trigger
Datadog → Automation → Workflow Automation → New Workflow
Trigger: Monitor


The Monitor trigger fires whenever a linked monitor changes state 
(OK → Alert, OK → Warning, Alert → Recovery).

**Mention handle:**
@workflow-name-Sep-08-2026-0011


This handle is added to the monitor's notification message to link 
the workflow to the monitor.

### Step 2 — Create Incident Action
Action: Datadog Incidents → Create Incident

Title: Monitor Alert: {{Trigger.monitorName}}
Severity: SEV-1
Notes and Links:
Monitor triggered: {{Trigger.monitorName}}
Service: sre-demo-api
Dashboard: https://app.datadoghq.com/apm/services/sre-demo-api
Runbook: https://github.com/Machindra220/.../api-availability.md


**Why dynamic title with `{{Trigger.monitorName}}`?**

If we hardcode the title, the workflow only makes sense for one monitor. 
Using the trigger variable makes it reusable — the same workflow can be 
linked to multiple monitors, and each incident title will reflect which 
monitor fired.

### Step 3 — Link Workflow to Monitor

In the P1 monitor's notification message:
{{#is_alert}}
🚨 CRITICAL: sre-demo-api receiving NO traffic
Service may be down or load balancer misconfigured
Check: kubectl get pods -n sre-demo
Check: kubectl get svc -n sre-demo
{{/is_alert}}
{{#is_recovery}}
✅ sre-demo-api traffic restored
{{/is_recovery}}

@workflow-name-Sep-08-2026-0011

The `@workflow-...` handle in the message body tells Datadog to 
trigger this workflow when the monitor fires.

### Step 4 — Publish Workflow

Workflows must be published to run automatically:
Workflow Automation → your workflow → Publish


Unpublished workflows only run manually for testing.

---

## Complete Flow When P1 Fires

```text
t=0:00  API returns no traffic (LB misconfigured, pods down, etc.)

t=0:05  Monitor evaluates: sum(requests) over 5min = 0
        Threshold: < 1
        Status: OK → ALERT

t=0:05  Monitor notification sent
        @workflow-Machindra-Sep-08-2026-0011 triggered

t=0:05  Workflow executes:
        Create Incident:
          Title: "Monitor Alert: [sre-demo-api] API Availability - No Traffic"
          Severity: SEV-1
          Status: Active
          Notes: service info, dashboard link, runbook link

t=0:05  Incident created in Datadog Incident Management
        Incident ID: INC-XXX assigned

t=7:00  Engineer wakes up (assuming night alert)
        Opens Datadog → Incidents
        Sees: INC-XXX, SEV-1, Active, with full context
        Clicks runbook link → follows response steps
        
t=7:02  Investigation starts immediately with full context
        No time wasted manually creating incident record
```

---

## Incident Lifecycle

Once created, incidents follow a structured lifecycle:

```text
ACTIVE    → Issue is occurring, being investigated
    ↓
STABLE    → Root cause identified, fix in progress
    ↓
RESOLVED  → Fix deployed, service restored
    ↓
POSTMORTEM → Written within 48 hours of resolution
```

**Updating incident status:**
Datadog → Incident Response → Incidents → select incident
→ Update Status
→ Add timeline entries
→ Link related monitors/traces/logs


---

## What Triggers What

Our complete monitor → workflow mapping:

| Monitor | Severity | Workflow |
|---|---|---|
| API Availability - No Traffic | P1 | ✅ Auto-creates SEV-1 incident |
| High Error Rate | P2 | Manual incident creation |
| High p99 Latency | P3 | Manual incident creation |
| Pod Restart Rate | P2 | Manual incident creation |
| SLO Burn Rate | P2 | Manual incident creation |

In production, you'd automate all P1 and P2 monitors. We automated 
P1 to demonstrate the pattern — extending to other monitors is 
straightforward.

---

## Testing the Workflow

### Manual test
Workflow Automation → your workflow → Run

This triggers the workflow manually without needing a real alert.

### Real test — trigger the P1 monitor

```bash
# Stop all traffic to the service
kubectl scale deployment sre-demo-api --replicas=0 -n sre-demo

# Wait 5 minutes for monitor to fire
# Check: Datadog → Incidents → new incident should appear

# Restore service
kubectl scale deployment sre-demo-api --replicas=1 -n sre-demo
```

### Verify incident was created
Datadog → Incident Response → Incidents
Filter: Active
Look for: Monitor Alert: [sre-demo-api] API Availability - No Traffic


---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Automation scope | P1 only | All P1 and P2 monitors |
| Notification | No recipients | PagerDuty + Slack channel |
| Severity mapping | Hardcoded SEV-1 | Dynamic based on monitor priority |
| Responder assignment | None | Auto-assign on-call engineer |
| Runbook location | GitHub | Confluence, Notion, or Datadog Notebooks |
| Incident template | Minimal | Full template with impact, timeline sections |
| Escalation | None | Auto-escalate if not acknowledged in 10 min |
| Postmortem | Manual | Auto-create postmortem template on resolution |

**Dynamic severity mapping in production:**

```javascript
// In workflow conditional logic:
if (monitor.priority == "P1") {
  severity = "SEV-1"
} else if (monitor.priority == "P2") {
  severity = "SEV-2"
} else {
  severity = "SEV-3"
}
```

**Auto-assign on-call:**
Workflow action: On-Call → Get current on-call user
Workflow action: Incidents → Add responder


---

## Runbook Quality Standards

After building four runbooks, these standards emerged:

### Every runbook must have:
1. Alert name and priority
2. Impact statement (who is affected, how severely)
3. Initial checks (max 4 steps, completable in 2 minutes)
4. Specific kubectl/curl commands (not just "check the service")
5. Possible causes table with fixes
6. Recovery validation (how do you know it's fixed?)
7. Escalation path (who to call if stuck)


### Runbook anti-patterns:
❌ "Check if the service is running"
→ too vague, no command

✅ "kubectl get pods -n sre-demo"
→ specific, runnable immediately

❌ "Investigate the issue"
→ what does that mean at 3am?

✅ "Check APM traces: Datadog → APM → Traces → filter service:sre-demo-api status:error"
→ specific navigation path

❌ "Fix the problem and restart"
→ how? which command?

✅ "kubectl rollout restart deployment/sre-demo-api -n sre-demo"
→ copy-paste ready


---

## Lessons Learned

1. **Automate incident creation, not investigation.** The workflow 
   creates the incident record instantly — but humans still investigate 
   and fix. Automation handles the administrative overhead, not the 
   engineering judgment.

2. **Runbooks before automation.** We wrote runbooks before building 
   the workflow because the workflow links to the runbook. A workflow 
   that creates an incident with no runbook link is less useful than 
   one with a clear response guide.

3. **Dynamic titles using trigger variables.** Hardcoded titles 
   (`"API is down"`) make the workflow single-purpose. Dynamic titles 
   (`{{Trigger.monitorName}}`) make it reusable across multiple monitors.

4. **Publish is required for automatic execution.** An unpublished 
   workflow only runs manually. This is easy to forget — always verify 
   the green dot (published) is showing in Workflow Automation list.

5. **The @workflow handle connects monitor to workflow.** Adding 
   `@workflow-handle` to the monitor message body is the link between 
   the two systems. Without it, the workflow never triggers automatically.

6. **Incidents should be linked to monitors, traces, and logs.** 
   Datadog allows you to link related signals to an incident. During 
   investigation, add the relevant APM trace, the error log, and the 
   dashboard to the incident — creates a complete audit trail for the 
   postmortem.

---

## What's Next

**Article 13: Breaking Production on Purpose — Failure Injection and 
Incident Response on Kubernetes**

With monitoring, alerting, and incident automation in place, we'll 
deliberately break our service in controlled ways to test the complete 
pipeline — from failure to alert to incident to investigation to recovery.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*