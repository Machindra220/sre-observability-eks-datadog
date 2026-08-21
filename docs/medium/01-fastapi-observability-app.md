# Building a Lightweight FastAPI Service for Kubernetes Observability

## A production-style demo API designed to generate real telemetry for SRE learning

---

## Problem

Most observability tutorials show you how to configure dashboards using pre-built sample
applications. You never see how the application itself needs to be structured to produce
useful telemetry.

Before you can monitor anything meaningfully, you need an application that:
- Produces structured logs
- Emits APM traces
- Exposes realistic endpoints
- Can simulate failures on demand

This article covers how I built that foundation as Phase 1 of a larger SRE observability
project running on AWS EKS with Datadog.

---

## Architecture

```text
Developer (VSCode + WSL2 Ubuntu)
           |
           v
     FastAPI Application
           |
     +-----+------+
     |            |
  Normal       Failure
 Endpoints    Endpoints
     |            |
  /products    /error
  /orders      /slow
  /users
     |
  Structured Logs + Request IDs + Latency
     |
  ddtrace (Datadog APM)
```

---

## Technology Choices

| Component | Choice | Reason |
|---|---|---|
| Language | Python 3.12 | ddtrace not yet compatible with Python 3.14 |
| Framework | FastAPI | Async, lightweight, minimal boilerplate |
| APM | ddtrace 2.11.5 | Datadog's Python tracing library |
| Logging | structlog | Structured JSON logs, easy Datadog parsing |
| Tests | pytest + pytest-asyncio | Async endpoint testing |
| Container | Docker (python:3.12-slim) | Minimal image size |

---

## Repository Structure

```text
sre-observability-eks-datadog/
├── app/
│   ├── src/
│   │   └── main.py
│   ├── tests/
│   │   └── test_api.py
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── requirements.txt
│   └── README.md
├── docs/
│   └── medium/
│       └── 01-fastapi-observability-app.md
├── .gitignore
└── README.md
```

---

## Application Design

The application exists for one purpose: **generate realistic telemetry for observability
testing.**

It is intentionally simple. No database. No authentication. No business logic complexity.
Every endpoint exists to produce a specific type of signal.

### Endpoints

| Endpoint | Purpose | Signal Generated |
|---|---|---|
| GET /api/health | Liveness probe | Normal 200 |
| GET /api/ready | Readiness probe | Normal 200 |
| GET /api/products | Normal business traffic | Metrics, traces |
| GET /api/orders | Normal business traffic | Metrics, traces |
| GET /api/users | Normal business traffic | Metrics, traces |
| GET /api/slow | Latency simulation | High latency traces |
| GET /api/error | Failure simulation | 4xx, 5xx, exceptions |

### /api/slow

Introduces a random delay between 2-5 seconds using `asyncio.sleep()`.
This is used later to trigger latency monitors and demonstrate APM trace waterfall views.

### /api/error

Randomly returns one of three failure types:
- `400 Bad Request` — client error
- `500 Internal Server Error` — server error
- Unhandled `ValueError` exception — triggers exception handler

This gives us all the error types we need to test alerting rules without
needing to break real infrastructure.

---

## Implementation

### Request Middleware

Every request gets a UUID assigned and timing captured:

```python
@app.middleware("http")
async def request_middleware(request: Request, call_next):
    request_id = str(uuid.uuid4())
    start = time.time()
    request.state.request_id = request_id

    response = await call_next(request)

    duration_ms = round((time.time() - start) * 1000, 2)
    log.info(
        "request",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        duration_ms=duration_ms,
        request_id=request_id,
    )
    response.headers["X-Request-ID"] = request_id
    return response
```

**Why this matters for observability:**
- `request_id` correlates logs to a specific request
- `duration_ms` gives us latency at the application layer
- JSON structured logs are directly parseable by Datadog Log Management

### Structured Logging

```python
structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)
```

Every log line is valid JSON. When Datadog collects container logs,
it can parse these fields automatically without custom parsing rules.

Example log output:
```json
{
  "timestamp": "2026-08-21T10:23:45.123Z",
  "level": "info",
  "event": "request",
  "method": "GET",
  "path": "/api/products",
  "status": 200,
  "duration_ms": 12.4,
  "request_id": "a1b2c3d4-..."
}
```

### Datadog APM

```python
from ddtrace import tracer
from ddtrace.contrib.asgi import TraceMiddleware

app.add_middleware(TraceMiddleware)
```

`TraceMiddleware` automatically instruments every HTTP request with a trace.
When the Datadog agent is running, traces appear in APM without any manual
span creation.

The Dockerfile uses `ddtrace-run` as the entrypoint:

```dockerfile
CMD ["ddtrace-run", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

`ddtrace-run` wraps the process and handles trace context propagation automatically.

### Exception Handler

```python
@app.exception_handler(Exception)
async def unhandled_exception(request: Request, exc: Exception):
    log.error("unhandled_exception", path=request.url.path, error=str(exc))
    return JSONResponse(status_code=500, content={"error": "unexpected error"})
```

Unhandled exceptions are caught, logged as structured errors, and return a clean
500 response. Without this, FastAPI returns a generic error with no log output.

---

## Dockerfile

```dockerfile
FROM python:3.12-slim

WORKDIR /app

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

USER appuser

EXPOSE 8080

CMD ["ddtrace-run", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

**Key decisions:**
- `python:3.12-slim` — minimal base image, reduces attack surface
- Non-root user (`appuser`) — security best practice
- `--no-cache-dir` — keeps image size small
- `ddtrace-run` as entrypoint — APM auto-instrumentation without code changes

---

## Testing

```python
@pytest.mark.asyncio
async def test_health():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/health")
    assert r.status_code == 200
    assert r.json()["status"] == "healthy"
```

Tests use `httpx.AsyncClient` with `ASGITransport` — this tests the actual
FastAPI application in-process without needing a running server.

```text
platform linux -- Python 3.12.13, pytest-8.2.0
collected 6 items

tests/test_api.py::test_health PASSED
tests/test_api.py::test_ready PASSED
tests/test_api.py::test_products PASSED
tests/test_api.py::test_orders PASSED
tests/test_api.py::test_users PASSED
tests/test_api.py::test_error_returns_error_status PASSED

6 passed in 0.86s
```

---

## Troubleshooting Encountered

### Python 3.14 Incompatibility

**Problem:** `ddtrace==2.8.5` fails to build on Python 3.14 due to missing
`pkg_resources` module.

**Root cause:** ddtrace's build system uses `pkg_resources` which was removed
in Python 3.14.

**Fix:**
- Install Python 3.12 via deadsnakes PPA
- Recreate virtualenv with Python 3.12
- Upgrade ddtrace to 2.11.5

```bash
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt install python3.12 python3.12-venv -y
python3.12 -m venv .venv
```

**Lesson:** Always check library support matrices before using the latest
Python version. In SRE work, stability beats novelty.

### pytest Module Import Error

**Problem:** Running `python -m pytest app/tests/` from project root failed
with `ModuleNotFoundError: No module named 'src'`.

**Fix:** Run pytest from inside the `app/` directory where `src/` is directly
accessible as a module.

```bash
cd app
python -m pytest tests/ -v
```

**Lesson:** Python's module resolution is path-dependent. Always be aware of
your working directory when running tests.

### Docker Base Image Error

**Problem:** Dockerfile had `FROM python3.12-slim` (missing colon).
Docker tried to pull `python3.12-slim` as an image name from Docker Hub
and failed with authorization error.

**Fix:**
```bash
sed -i 's/FROM python3.12-slim/FROM python:3.12-slim/' Dockerfile
```

Correct format: `FROM python:3.12-slim`

---

## Validation

```bash
# All endpoints responding correctly
curl http://localhost:8080/api/health
# {"status":"healthy","version":"1.0.0","env":"dev"}

curl http://localhost:8080/api/slow
# {"message":"slow response","delay_ms":4214}

curl http://localhost:8080/api/error
# {"error":"internal server error","type":"server"}  ← varies each call

# Docker container running
docker build -t sre-demo-api:local .
docker run --rm -p 8080:8080 -e DD_TRACE_ENABLED=false sre-demo-api:local
```

---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Secret management | ENV vars | AWS Secrets Manager / K8s Secrets |
| Health checks | Simple 200 | Check DB connections, dependencies |
| Error simulation | Random | Remove /api/error or gate behind feature flag |
| Logging | stdout JSON | Ship to centralized log platform |
| Image size | python:3.12-slim | Consider distroless for smaller attack surface |
| Non-root user | ✅ Already done | Keep, add read-only filesystem |
| Resource limits | None | Set CPU/memory requests and limits in K8s |

---

## Lessons Learned

1. **Structure your application for observability from day one.** Adding
   request IDs, structured logs, and trace middleware after the fact is
   painful. Build it in upfront.

2. **Failure endpoints are underrated.** Having `/api/error` and `/api/slow`
   means you can test your entire alerting pipeline without breaking real
   infrastructure.

3. **Python version matters more than you think.** Library compatibility
   issues with Python 3.14 cost real time. In production environments,
   pin your Python version explicitly.

4. **ddtrace-run is the simplest APM path.** Wrapping your process with
   `ddtrace-run` gives you automatic instrumentation without touching
   application code. Save manual span creation for business-critical
   custom traces.

---

## What's Next

**Article 2: Deploying AWS Infrastructure with Terraform — VPC, EKS, and ECR**

We'll provision the complete AWS infrastructure needed to run this application
on Kubernetes, using Terraform for everything. No manual console clicks.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability
platform built on AWS EKS with Datadog.*