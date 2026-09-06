
# Adding Datadog APM to a Kubernetes Application: From HTTP Request to Distributed Trace

## A complete walkthrough of enabling distributed tracing on a FastAPI application running on AWS EKS

---

## Problem

Infrastructure metrics tell you that something is wrong. APM tells you exactly 
what is wrong and where.

Without APM:
```text
Alert: High latency on sre-demo-api
You: Check logs... check metrics... guess at root cause...
Time to resolution: 30-60 minutes
```

With APM:
```text
Alert: High latency on sre-demo-api
You: Open trace → see 2.57s in /api/slow → asyncio.sleep() is the culprit
Time to resolution: 2 minutes
```

APM gives you:
- Complete request lifecycle from entry to response
- Exact line-level visibility into where time was spent
- Error traces with full stack context
- Latency percentiles (p50, p95, p99) per endpoint
- Correlation between traces, logs, and infrastructure metrics

This article covers the complete APM setup journey as Phase 7 of a larger 
SRE observability project on AWS EKS — including the troubleshooting that 
was required to get traces flowing.

---

## Architecture

```text
User Request
     |
     v
AWS LoadBalancer
     |
     v
FastAPI App (sre-demo-api pod)
     |
     +-- ddtrace patch(fastapi=True)
     |        |
     |   Automatic span creation per request
     |        |
     v        v
  Response   Trace sent to DD_AGENT_HOST:8126
                  |
                  v
           Datadog Node Agent (DaemonSet)
                  |
                  v
           Datadog APM Backend
                  |
              +---+---+
              |       |
           Traces   Metrics
              |       |
           Flame   Request
           Graph    Rate,
                   Errors,
                   Latency
```

---

## Key Concepts

### What is a Trace?

A trace represents the complete journey of a single request through your system:

```text
Trace: GET /api/slow (2.57s total)
  └── Span: asgi.request GET /api/slow (2.57s)
            HTTP method: GET
            HTTP status: 200
            URL: http://lb.../api/slow
            Service: sre-demo-api
            Version: 1.0.0
            Env: dev
```

### What is a Span?

A span is a single operation within a trace. Our simple FastAPI app produces 
one span per request. A more complex application with database calls and 
external API calls would produce multiple nested spans:

```text
Trace: GET /api/orders (250ms total)
  └── Span: asgi.request (250ms)
        └── Span: postgres.query SELECT orders (180ms)
        └── Span: redis.get cache_key (5ms)
        └── Span: http.request payment-service (60ms)
```

### What is a Flame Graph?

A flame graph is a visual representation of spans over time:

```text
|←————————————————— 2.57s ————————————————→|
[GET /api/slow                              ]  ← root span
```

For our `/api/slow` endpoint, the entire time is one span because 
`asyncio.sleep()` is not instrumented — it just waits. In production 
with real dependencies, you'd see nested spans.

---

## Configuration Changes

### Three things needed to enable APM:

**1. Application instrumentation** — ddtrace patching  
**2. Environment variables** — tell ddtrace where to send traces  
**3. Agent configuration** — ensure port 8126 is open (already done in Phase 5)

---

## Step 1 — Kubernetes Deployment Changes

Updated `kubernetes/deployment.yaml` with APM environment variables:

```yaml
env:
  # Send traces to Datadog agent running on the same node
  - name: DD_AGENT_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP   # ← dynamically gets node IP

  # Enable APM tracing
  - name: DD_TRACE_ENABLED
    value: "true"

  # Unified service tagging - correlates metrics, logs, traces
  - name: DD_ENV
    value: "dev"
  - name: DD_SERVICE
    value: "sre-demo-api"
  - name: DD_VERSION
    value: "1.0.0"

  # Enable Python runtime metrics
  - name: DD_RUNTIME_METRICS_ENABLED
    value: "true"

  # Inject trace IDs into logs for correlation
  - name: DD_LOGS_INJECTION
    value: "true"

  # APM agent port
  - name: DD_TRACE_AGENT_PORT
    value: "8126"
```

**Why `status.hostIP` for `DD_AGENT_HOST`?**

The Datadog agent runs as a DaemonSet — one pod per node. Each application 
pod needs to send traces to the agent on its own node. `status.hostIP` 
dynamically resolves to the IP of whatever node the pod is running on. 
Hardcoding a node IP would break when pods reschedule to different nodes.

**Unified service tagging (`DD_SERVICE`, `DD_ENV`, `DD_VERSION`):**

These three tags are the foundation of Datadog's correlation system:

```text
DD_SERVICE=sre-demo-api  → identifies the service
DD_ENV=dev               → which environment
DD_VERSION=1.0.0         → which code version

Result: Every metric, log, and trace is tagged identically.
        You can pivot from a metric spike → related traces → related logs
        without losing context.
```

Also added Kubernetes labels matching these tags:

```yaml
labels:
  tags.datadoghq.com/env: "dev"
  tags.datadoghq.com/service: "sre-demo-api"
  tags.datadoghq.com/version: "1.0.0"
```

Datadog reads these labels automatically — no additional configuration needed.

---

## Step 2 — Application Instrumentation

### The wrong approach (what didn't work)

Initially we used `TraceMiddleware` from `ddtrace.contrib.asgi`:

```python
from ddtrace.contrib.asgi import TraceMiddleware
app.add_middleware(TraceMiddleware)
```

**Result:** `dd_trace_id: null` in all logs. No traces in Datadog.

**Root cause:** `TraceMiddleware` has compatibility issues with ddtrace 
2.11.5 and FastAPI's async middleware chain. The middleware runs in a 
different async context than the request handlers, so trace context 
doesn't propagate correctly.

### The correct approach

Use `patch(fastapi=True)` **before** importing FastAPI:

```python
# MUST be called before FastAPI import
from ddtrace import patch, tracer
patch(fastapi=True)

# Now import FastAPI
from fastapi import FastAPI
app = FastAPI(...)
```

`patch(fastapi=True)` monkey-patches FastAPI's routing internals at import 
time — every route handler automatically gets a span created around it. 
This is more reliable than middleware because it hooks directly into 
FastAPI's request handling.

**Why order matters:** Python's import system caches modules. If FastAPI 
is imported before `patch()` is called, the original unpatched code is 
already cached and `patch()` has nothing to modify.

### Log + Trace correlation

We added trace context to every log line:

```python
@app.middleware("http")
async def request_middleware(request: Request, call_next):
    request_id = str(uuid.uuid4())
    start = time.time()

    response = await call_next(request)

    duration_ms = round((time.time() - start) * 1000, 2)

    # Get active trace context
    span = tracer.current_span()
    trace_id = span.trace_id if span else None
    span_id = span.span_id if span else None

    log.info(
        "request",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        duration_ms=duration_ms,
        dd_trace_id=str(trace_id) if trace_id else None,
        dd_span_id=str(span_id) if span_id else None,
    )
```

With `DD_LOGS_INJECTION=true`, Datadog automatically links logs to their 
corresponding traces using `dd_trace_id`. In the Datadog UI you can 
click "View in Logs" from a trace and see exactly the log lines generated 
during that request.

---

## Troubleshooting Journey

### Issue 1 — DD_TRACE_ENABLED was false

**Symptom:** APM page showed "Get Started" — no traces.

**Discovery:** `kubectl describe pod` showed `DD_TRACE_ENABLED: false` — 
the old deployment manifest was still active.

**Fix:** Applied updated `deployment.yaml` with `DD_TRACE_ENABLED: true`.

### Issue 2 — ImagePullBackOff after deployment update

**Symptom:** New pod failed with `ImagePullBackOff`.

**Root cause:** The `latest` ECR tag didn't exist — it was deleted when 
we ran `terraform destroy` in a previous session. The deployment references 
`:latest` but ECR only had the old Git SHA tag.

**Fix:** Rebuilt and pushed both `:GIT_SHA` and `:latest` tags:

```bash
docker build -t ${ECR_URL}:${GIT_SHA} -t ${ECR_URL}:latest .
docker push ${ECR_URL}:${GIT_SHA}
docker push ${ECR_URL}:latest
```

**Prevention:** Added ECR push step to `infra-up.sh` so latest tag always 
exists after infrastructure recreation.

### Issue 3 — traces not flowing despite DD_TRACE_ENABLED=true

**Symptom:** Logs showed `dd_trace_id: null`. APM page still empty.

**Diagnosis:** Checked process running as PID 1:

```bash
kubectl exec -n sre-demo <pod> -- cat /proc/1/cmdline | tr '\0' ' '
# Output: /usr/local/bin/python3.12 /usr/local/bin/uvicorn src.main:app...
```

Expected: `ddtrace-run uvicorn src.main:app`  
Actual: `python3.12 uvicorn src.main:app`

Even though Dockerfile CMD had `ddtrace-run`, the running image was stale.

**Further diagnosis:** Checked agent APM connectivity:

```bash
kubectl exec -n datadog datadog-agent-nsmfl -c agent -- agent status | grep APM
# failure APM traces invalid status code: 404
```

This confirmed the agent couldn't reach the Datadog APM endpoint — 
a temporary connectivity issue that resolved itself.

**Root fix:** Switched from `TraceMiddleware` to `patch(fastapi=True)` 
and force-rebuilt the image with `--no-cache`:

```bash
docker build --no-cache -t ${ECR_URL}:latest .
```

### Issue 4 — `ps` not available in slim container

**Symptom:** `kubectl exec -- ps aux` failed with "executable not found".

**Root cause:** `python:3.12-slim` doesn't include `ps` — minimal image.

**Alternative:** Read `/proc/1/cmdline` directly:

```bash
kubectl exec -n sre-demo <pod> -- cat /proc/1/cmdline | tr '\0' ' '
```

This is actually more reliable than `ps` for checking PID 1's command.

---

## Validation

### APM Traces page

```
Datadog → APM → Traces
Filter: env:dev, service:sre-demo-api
```

Results:
```
Requests: 187 total (0.2 req/s)
Errors:   12 total (6.47%)
Resources visible:
  GET /api/ready      (health probes - most frequent)
  GET /api/health
  GET /api/products
  GET /api/error      (red - errors)
  GET /api/slow       (yellow - high latency)
```

### Flame Graph — GET /api/slow

```
Trace ID: 6a9da68e00000000d738126ae26223e7
Duration: 2.57s
Status:   200 OK
URL:      http://lb.../api/slow

Flame Graph:
|←————————————————————————— 2.57s ————————————————————————→|
[GET /api/slow                                              ]
 sre-demo-api: 100% of execution time
```

The entire 2.57 seconds is one span — this is correct. Our `/api/slow` 
endpoint does `asyncio.sleep(random.uniform(2.0, 5.0))` — pure waiting, 
no sub-operations to trace. In a production app, you'd see database queries, 
cache lookups, and external API calls as separate nested spans.

### APM Service Page

```
Datadog → APM → Services → sre-demo-api
```

Shows:
- Request rate timeseries
- Error rate with spikes from /api/error
- Latency chart with spikes up to 4.5s from /api/slow
- p50, p95, p99 latency percentiles

**Setup guidance status:**
```
✅ Monitors (1)           — auto-detected
✅ Version Tagging        — DD_VERSION working
✅ Error Tracking         — errors being captured
✅ Distributed Tracing    — traces flowing
✅ Infrastructure Monitoring — linked to host metrics
✅ Log Management         — logs flowing
```

---

## What APM Enables Going Forward

With traces flowing, we can now:

1. **Add request rate widgets to dashboard** — `trace.fastapi.request` metric 
   now exists in Datadog

2. **Create latency monitors** — alert when p99 latency exceeds threshold

3. **Correlate logs with traces** — click a trace → see related logs

4. **Error tracking** — group similar errors, track error rate trends

5. **SLO based on APM metrics** — Phase 10 will use `trace.fastapi.request` 
   for availability SLOs

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Sampling | 100% (all traces) | Configure sampling rules — trace errors always, sample normal at 10-20% |
| Custom spans | None | Add manual spans around DB queries, external calls |
| Sensitive data | Not scrubbed | Configure obfuscation rules for PII in URLs/headers |
| Error tracking | Auto-detected | Add custom error fingerprinting |
| Service map | Single service | Multiple services with propagated trace context |
| Trace retention | Default (15 days) | Configure retention filters |
| Runtime metrics | Enabled | Monitor GC pauses, thread count, heap usage |

**Sampling in production:**

Tracing 100% of requests at high traffic volume is expensive. Configure 
sampling rules:

```python
# Keep 100% of error traces, 10% of normal traces
from ddtrace import tracer
tracer.configure(
    sampler=DatadogSampler(
        rules=[SamplingRule(sample_rate=1.0, name="error"),
               SamplingRule(sample_rate=0.1)]
    )
)
```

**Custom spans for better visibility:**

```python
from ddtrace import tracer

@app.get("/api/orders")
async def orders():
    with tracer.trace("db.query", service="postgres") as span:
        span.set_tag("db.type", "postgresql")
        result = await db.fetch_orders()
    return result
```

---

## Lessons Learned

1. **`patch()` must be called before framework import.** Python caches 
   imported modules — if FastAPI is imported before `patch(fastapi=True)`, 
   the original unpatched code is cached. Import order is not just style, 
   it determines whether instrumentation works.

2. **`TraceMiddleware` has async context issues with ddtrace 2.11.5.** 
   The ASGI middleware approach doesn't reliably propagate trace context 
   in async FastAPI applications. `patch(fastapi=True)` hooks at a lower 
   level and works correctly.

3. **Always verify the running process, not just the Dockerfile.** The 
   Dockerfile had `ddtrace-run` in CMD, but the running container showed 
   plain `uvicorn`. A stale image was cached. `--no-cache` on docker build 
   resolved it. Never assume the running container matches the Dockerfile.

4. **`status.hostIP` is the correct pattern for DaemonSet agents.** 
   Hardcoding an agent IP breaks when pods reschedule. `fieldRef: status.hostIP` 
   dynamically resolves to the correct node — this is the Datadog-recommended 
   pattern for Kubernetes deployments.

5. **Unified service tagging pays dividends immediately.** Having 
   `DD_SERVICE`, `DD_ENV`, `DD_VERSION` set correctly means the service 
   appeared in APM with correct metadata, error tracking linked automatically, 
   and version tracking worked without any additional configuration.

6. **Slim container images are missing common tools.** `python:3.12-slim` 
   doesn't include `ps`, `curl`, or other debugging tools. Use `/proc` 
   filesystem directly for process inspection. In production, consider 
   ephemeral debug containers or `kubectl debug`.

7. **ECR `latest` tag must be managed explicitly.** Unlike Docker Hub, 
   ECR doesn't automatically maintain a `latest` tag. Every `terraform destroy` 
   wipes the repository. Add ECR push to your infrastructure startup 
   automation.

---

## What's Next

**Article 8: Centralized Kubernetes Logging with Datadog — Connecting 
Logs, Metrics and Traces**

With APM traces flowing, we'll configure log-to-trace correlation so 
that clicking a trace in APM shows the exact log lines generated during 
that request — closing the loop between the three pillars of observability.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*
```
