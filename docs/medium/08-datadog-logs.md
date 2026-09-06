
# Centralized Kubernetes Logging with Datadog: Connecting Logs, Metrics and Traces

## A complete walkthrough of log collection, structured logging, and log-trace correlation on AWS EKS

---

## Problem

Logs without context are just noise. In a distributed system, a single user 
request might generate dozens of log lines across multiple services. Without 
correlation, you're manually searching through thousands of log lines trying 
to find which ones belong to the slow request that triggered the alert.

Log-trace correlation solves this:
```text
Without correlation:
Alert fires → search logs for "error" → find 500 matching lines
→ guess which ones are from the problematic request
→ 30 minutes of manual investigation

With correlation:
Alert fires → click trace → click Logs tab
→ see exact log lines from that request
→ 30 seconds to root cause
```

This article covers how we implemented centralized log collection, structured 
logging, and log-trace correlation as Phase 8 of a larger SRE observability 
project on AWS EKS with Datadog.

---

## Architecture

```text
FastAPI App (sre-demo-api)
     |
     +-- structlog (JSON formatter)
     |        |
     |   {"dd.trace_id": "123", "path": "/api/error", "status": 500}
     |        |
     v        v
  stdout  Datadog Agent (DaemonSet)
              |
              +-- reads container stdout
              |
              v
         Datadog Log Management
              |
         +----+----+
         |         |
      Log         Trace
    Explorer      APM
         |         |
         +---------+
               |
         Log-Trace
         Correlation
```

---

## Three Pillars of Observability

Before diving into implementation, understand why all three pillars matter:

| Pillar | What it answers | Tool |
|---|---|---|
| **Metrics** | Is the system healthy? (CPU, memory, request rate) | Datadog Infrastructure |
| **Traces** | Where is the slowness/error? (which request, which code path) | Datadog APM |
| **Logs** | What exactly happened? (detailed context, variables, stack traces) | Datadog Log Management |

Each pillar alone is incomplete. Together they give complete observability:
```text
Metric spike detected (high error rate)
        ↓
Find the trace (which request failed)
        ↓
Open the logs (what exactly happened in that request)
        ↓
Root cause identified
```

---

## Log Collection — How It Works on Kubernetes

When we enabled `containerCollectAll: true` in the Datadog Helm values, 
the agent automatically reads container stdout/stderr from every pod.

```text
Pod stdout
    ↓
/var/log/containers/<pod-name>.log  (written by container runtime)
    ↓
Datadog Agent (reads this file via volume mount)
    ↓
Parses JSON, enriches with Kubernetes metadata
    ↓
Sends to Datadog Log Management
```

The agent automatically adds Kubernetes metadata to every log:
```json
{
  "kube_namespace": "sre-demo",
  "kube_pod_name": "sre-demo-api-89d7dcd86-2vtfn",
  "kube_container_name": "sre-demo-api",
  "kube_deployment": "sre-demo-api",
  "cluster_name": "sre-demo-dev-eks-cluster",
  "env": "dev",
  "service": "sre-demo-api",
  "version": "1.0.0"
}
```

No manual configuration needed — unified service tagging (`DD_SERVICE`, 
`DD_ENV`, `DD_VERSION`) ensures these tags appear on every log automatically.

---

## Structured Logging

### Why JSON logs?

```text
Unstructured log:
"2026-09-07 00:46:33 GET /api/error 500 0.48ms"
→ Datadog can't parse fields
→ Can't filter by status code
→ Can't aggregate by endpoint

Structured JSON log:
{"method":"GET","path":"/api/error","status":500,"duration_ms":0.48}
→ Every field is queryable
→ Filter: status:500
→ Group by: @path
→ Average duration by endpoint
```

### structlog configuration

```python
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),  # ISO timestamp
        structlog.processors.add_log_level,            # info/error/warn
        structlog.processors.JSONRenderer(),           # output as JSON
    ]
)
```

Every log line is valid JSON — Datadog parses it automatically without 
custom parsing rules.

---

## Log-Trace Correlation

### The problem we solved

Datadog requires specific field names to correlate logs with traces:

```text
❌ Wrong field names (what we had initially):
{"dd_trace_id": "123456", "dd_span_id": "789"}

✅ Correct field names (what Datadog expects):
{"dd.trace_id": "123456", "dd.span_id": "789"}
```

The dot notation (`dd.trace_id`) is Datadog's standard. Underscore 
(`dd_trace_id`) is not recognized for correlation.

### Implementation

```python
@app.middleware("http")
async def request_middleware(request: Request, call_next):
    request_id = str(uuid.uuid4())
    start = time.time()

    response = await call_next(request)

    duration_ms = round((time.time() - start) * 1000, 2)

    # Get active trace context
    span = tracer.current_span()
    if span:
        # Convert 128-bit trace ID to 64-bit for Datadog log correlation
        trace_id = span.trace_id & 0xFFFFFFFFFFFFFFFF
        span_id = span.span_id
    else:
        trace_id = None
        span_id = None

    log.info(
        "request",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        duration_ms=duration_ms,
        request_id=request_id,
        **{"dd.trace_id": str(trace_id) if trace_id else None},
        **{"dd.span_id": str(span_id) if span_id else None},
    )
```

**Why 128-bit to 64-bit conversion?**

ddtrace internally uses 128-bit trace IDs but Datadog's log correlation 
system uses 64-bit IDs. The lower 64 bits (`& 0xFFFFFFFFFFFFFFFF`) gives 
the value Datadog uses to match logs to traces.

### Result in logs

```json
{
  "method": "GET",
  "path": "/api/ready",
  "status": 200,
  "duration_ms": 0.51,
  "request_id": "b8ffa631-c206-486f-b383-3989fb502293",
  "dd.trace_id": "141717162854811310477643289570031358134",
  "dd.span_id": "1887915670218354300",
  "event": "request",
  "timestamp": "2026-09-06T19:14:30.067550Z",
  "level": "info"
}
```

---

## Validation

### Logs in Datadog

```
Datadog → Logs → Log Explorer
Filter: service:sre-demo-api
```

Every request generates a structured log with:
- HTTP method, path, status code
- Response duration in milliseconds
- Unique request ID
- Trace ID and span ID for correlation
- ISO timestamp
- Log level

### Log-Trace Correlation in action

```
Datadog → APM → Traces
Click any trace → Logs tab
```

The Logs tab shows log lines generated during that exact request — 
identified by matching `dd.trace_id` values.

For a `GET /api/error` 500 trace:
```json
{
  "duration_ms": 0.48,
  "event": "request",
  "level": "info",
  "method": "GET",
  "path": "/api/error",
  "status": 500,
  "timestamp": "2026-09-06T19:16:33.175054Z"
}
```

The log is linked to the trace — one click from APM to the exact log line.

---

## Troubleshooting Encountered

### Issue 1 — Wrong field name format

**Symptom:** Logs tab in trace showed "No logs found" with hint 
"inject trace_id and span_id".

**Root cause:** We used `dd_trace_id` (underscore) but Datadog requires 
`dd.trace_id` (dot).

**Fix:** Updated log.info call to use Python's `**{}` dict unpacking to 
output dot-notation keys:
```python
**{"dd.trace_id": str(trace_id) if trace_id else None},
**{"dd.span_id": str(span_id) if span_id else None},
```

Python doesn't allow dots in keyword arguments directly, so dict unpacking 
is the only way to produce dot-notation JSON keys.

### Issue 2 — Docker layer caching preventing code updates

**Symptom:** Code change committed, image rebuilt, deployment restarted — 
but container still ran old code.

**Root cause:** Docker caches the `COPY src/ ./src/` layer. If the layer 
hash matches a cached version, Docker uses the cache even with `--no-cache` 
on some systems. Additionally, ECR login expired mid-session causing silent 
push failures.

**Diagnosis:**
```bash
# Check what code is actually in the running container
kubectl exec -n sre-demo <pod> -- cat /app/src/main.py | grep "dd.trace_id"
```

**Fix:** Force deployment to use exact image digest:
```bash
kubectl set image deployment/sre-demo-api \
  sre-demo-api=${ECR_URL}@sha256:<exact-digest> \
  -n sre-demo
```

Using a digest instead of a tag guarantees Kubernetes pulls the exact 
image — no caching possible.

**Prevention:**
- Re-authenticate to ECR before every push session
- Verify ECR has the latest tag after pushing
- Use exact digest in production deployments

### Issue 3 — ECR login expiry

**Symptom:** `docker push` appeared to succeed but ECR showed old image.

**Root cause:** ECR authentication tokens expire after 12 hours. After 
expiry, pushes silently fail or update the wrong tag.

**Fix:** Always re-authenticate before pushing:
```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  <account>.dkr.ecr.us-east-1.amazonaws.com
```

Add this to the start of any script that pushes to ECR.

---

## Log Queries in Datadog

Useful queries for our application:

```
# All errors
service:sre-demo-api status:error

# Slow requests (duration > 2000ms)
service:sre-demo-api @duration_ms:>2000

# Specific endpoint
service:sre-demo-api @path:/api/error

# 500 errors only
service:sre-demo-api @status:500

# Requests with trace IDs (correlated)
service:sre-demo-api _exists_:dd.trace_id
```

---

## What's in Each Log Field

| Field | Type | Purpose |
|---|---|---|
| `method` | string | HTTP method (GET, POST) |
| `path` | string | Request path (/api/products) |
| `status` | int | HTTP response code |
| `duration_ms` | float | Response time in milliseconds |
| `request_id` | UUID | Unique per-request identifier |
| `dd.trace_id` | string | Links log to APM trace |
| `dd.span_id` | string | Links log to specific span |
| `event` | string | Log event type (request/error) |
| `timestamp` | ISO8601 | When the log was generated |
| `level` | string | Log level (info/error/warn) |

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Log retention | Default (15 days trial) | Configure retention policy |
| Log volume | All requests logged | Sample high-frequency health probes |
| Sensitive data | Not scrubbed | Configure log scrubbing rules for PII |
| Log indexes | Single index | Multiple indexes by service/env |
| Log archives | None | Configure S3 archive for compliance |
| Error alerting | Manual check | Log-based monitors for error patterns |
| Log parsing | Auto JSON | Custom parsing for legacy format logs |

**Reducing log volume in production:**

Health probe endpoints (`/api/health`, `/api/ready`) are called every 
10-30 seconds by Kubernetes. At scale, these generate thousands of logs 
per hour with zero value. Exclude them:

```python
@app.middleware("http")
async def request_middleware(request: Request, call_next):
    response = await call_next(request)
    
    # Don't log health probes - reduces noise
    if request.url.path not in ["/api/health", "/api/ready"]:
        log.info("request", ...)
    
    return response
```

---

## Lessons Learned

1. **Field name format matters exactly.** `dd_trace_id` vs `dd.trace_id` 
   looks like a minor difference but completely breaks log-trace correlation. 
   Always verify against Datadog's exact documentation, not assumptions.

2. **Python dot-notation in log fields requires dict unpacking.** Python 
   keyword arguments can't contain dots. `log.info(dd.trace_id=value)` 
   is a syntax error. Use `**{"dd.trace_id": value}` — this is the only 
   way to produce dot-notation JSON keys with structlog.

3. **Docker layer caching is not always your friend.** `COPY src/` creates 
   a cached layer. Verifying the running container's code directly with 
   `kubectl exec -- cat` is more reliable than assuming the build and push 
   worked correctly.

4. **ECR tokens have a 12-hour TTL.** Any workflow longer than 12 hours 
   needs to re-authenticate. Add ECR login to every script that pushes images 
   rather than assuming the session is still valid.

5. **Structured logs pay dividends immediately.** Within minutes of logs 
   flowing into Datadog, we could filter by status code, group by endpoint, 
   and calculate average duration — all without writing any parsing rules.

6. **Log-trace correlation is the multiplier.** Individually, logs and 
   traces are useful. Connected, they reduce investigation time from minutes 
   to seconds. The `dd.trace_id` field is a small implementation detail 
   with outsized operational value.

---

## What's Next

**Article 9: Implementing the Four Golden Signals with Datadog**

With metrics, traces, and logs all flowing and correlated, we'll build 
the Golden Signals dashboard — Traffic, Latency, Errors, and Saturation — 
the four metrics that Google's SRE book identifies as sufficient to monitor 
any service.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*
```
