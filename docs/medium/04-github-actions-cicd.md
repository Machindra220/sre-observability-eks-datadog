# From Git Push to EKS: Building a GitHub Actions CI/CD Pipeline for Kubernetes

## Automating build, test, and deployment to AWS EKS using GitHub Actions with ECR image publishing

---

## Problem

Manually building Docker images, pushing to ECR, and running kubectl commands 
works fine for initial setup. It doesn't scale. Every deployment becomes a 
manual, error-prone process with no audit trail and no consistency.

A production CI/CD pipeline should:
- Run tests automatically on every change
- Build and push immutable images tagged to exact commits
- Deploy to Kubernetes without manual intervention
- Verify the deployment succeeded
- Use secure authentication — no long-lived credentials stored anywhere

This article covers how I built that pipeline as Phase 4 of a larger SRE 
observability project on AWS EKS.

---

## Architecture

```text
Developer
    |
    v
Git Push → GitHub
    |
    +--→ CI Pipeline (Pull Requests)
    |         |
    |         ├── Python Tests
    |         ├── Docker Build
    |         └── Trivy Security Scan
    |
    +--→ CD Pipeline (main branch)
              |
              ├── Tests
              ├── AWS Authentication
              ├── Docker Build + Push to ECR
              ├── kubectl Deploy to EKS
              ├── Rollout Verification
              └── Smoke Test
```

---

## Pipeline Design Decisions

### CI on Pull Requests, CD on main push

```yaml
# ci.yml
on:
  pull_request:
    branches: [main]

# deploy.yml
on:
  push:
    branches: [main]
```

CI runs on every PR — catches broken code before it merges.
CD runs only when code lands on main — deploys only validated code.

This separation means:
- Developers get fast feedback on PRs without triggering deployments
- Every merge to main automatically deploys
- No manual deployment steps

### Git SHA image tagging

```yaml
IMAGE_TAG: ${{ github.sha }}
```

Every image is tagged with the full Git commit SHA:
sre-demo-dev-ecr-api:144e5d983b20e6b4f40f28adbb4ab5gaf254005c


**Why this matters for SRE:**
When an incident occurs, `kubectl get deployment` immediately shows which 
commit is running. You can `git show 144e5d9` to see exactly what changed. 
Deployment traceability is non-negotiable in production.

---

## CI Pipeline

```yaml
name: CI

on:
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: |
          cd app
          pip install -r requirements.txt

      - name: Run tests
        run: |
          cd app
          python -m pytest tests/ -v

  docker-build:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - name: Build Docker image
        run: docker build -t sre-demo-api:${{ github.sha }} ./app

  security-scan:
    runs-on: ubuntu-latest
    needs: docker-build
    steps:
      - uses: actions/checkout@v4
      - name: Build image for scanning
        run: docker build -t sre-demo-api:${{ github.sha }} ./app
      - name: Run Trivy security scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: sre-demo-api:${{ github.sha }}
          format: table
          exit-code: 0
          severity: HIGH,CRITICAL
```

**Job dependency chain:** `test` → `docker-build` → `security-scan`

If tests fail, Docker build never runs. If Docker build fails, security 
scan never runs. This saves time and prevents wasted compute.

**`exit-code: 0` on Trivy** — reports vulnerabilities but doesn't fail 
the pipeline. In production, set `exit-code: 1` to block deployments 
with CRITICAL vulnerabilities.

---

## CD Pipeline

```yaml
name: Deploy

on:
  push:
    branches: [main]

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: sre-demo-dev-ecr-api
  EKS_CLUSTER: sre-demo-dev-eks-cluster
  AWS_ACCOUNT_ID: 502274764708

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Run tests
        run: |
          cd app
          pip install -r requirements.txt
          python -m pytest tests/ -v

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push Docker image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          cd app
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG

      - name: Update kubeconfig
        run: |
          aws eks update-kubeconfig \
            --region $AWS_REGION \
            --name $EKS_CLUSTER

      - name: Deploy to EKS
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          kubectl set image deployment/sre-demo-api \
            sre-demo-api=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -n sre-demo

      - name: Wait for rollout
        run: |
          kubectl rollout status deployment/sre-demo-api \
            -n sre-demo \
            --timeout=120s

      - name: Smoke test
        run: |
          LB=$(kubectl get svc sre-demo-api -n sre-demo \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
          sleep 10
          curl -f http://${LB}/api/health
```

---

## Key Pipeline Steps Explained

### AWS Authentication

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: us-east-1
```

Credentials are stored as GitHub Secrets — never in code. GitHub masks 
these values in all log output automatically.

**Production note:** We attempted GitHub OIDC authentication (no stored 
credentials) but encountered `sub` claim mismatches in the IAM trust policy. 
OIDC is the correct production approach — see the troubleshooting section.

### ECR Login

```yaml
- name: Login to Amazon ECR
  id: login-ecr
  uses: aws-actions/amazon-ecr-login@v2
```

Generates a temporary 12-hour ECR token automatically. The `id: login-ecr` 
allows subsequent steps to reference `${{ steps.login-ecr.outputs.registry }}` 
to get the ECR registry URL.

### Rolling Deployment

```yaml
kubectl set image deployment/sre-demo-api \
  sre-demo-api=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
  -n sre-demo
```

`kubectl set image` updates the deployment with the new image tag. Kubernetes 
performs a rolling update — new pods start before old pods terminate, ensuring 
zero downtime.

### Rollout Verification

```yaml
kubectl rollout status deployment/sre-demo-api \
  -n sre-demo \
  --timeout=120s
```

Waits up to 120 seconds for the rollout to complete. If new pods fail to 
start (crash, image pull error, failed health checks), this step fails and 
the pipeline reports failure. Without this, the pipeline would report success 
even if the deployment is broken.

### Smoke Test

```yaml
LB=$(kubectl get svc sre-demo-api -n sre-demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -f http://${LB}/api/health
```

`curl -f` returns exit code 1 on HTTP errors — pipeline fails if health 
check returns anything other than 200. This is the final gate before 
declaring a deployment successful.

---

## Troubleshooting Encountered

### Test Flakiness — /api/error endpoint

**Problem:** `test_error_returns_error_status` failed intermittently in CI.

**Root cause:** `/api/error` randomly raises a `ValueError` exception. 
The ddtrace middleware intercepted the exception before FastAPI's exception 
handler could return a 500 response, causing the test to see an unhandled 
exception instead of an HTTP response.

**Fix:** Removed the exception-raising path from `/api/error`. The endpoint 
now returns 400 or 500 responses directly without raising exceptions.

```python
@app.get("/api/error")
async def error():
    error_type = random.choice(["client", "server", "server"])
    if error_type == "client":
        return JSONResponse(status_code=400, content={"error": "bad request"})
    else:
        return JSONResponse(status_code=500, content={"error": "internal server error"})
```

**Lesson:** Randomized behavior in endpoints makes tests flaky. Either 
control randomness with seeds in tests or make endpoints deterministic.

### OIDC Authentication Failure

**Problem:** `Not authorized to perform sts:AssumeRoleWithWebIdentity`

**Attempted:** GitHub OIDC → AWS IAM Role assumption without stored credentials.

**Root cause:** The `sub` claim in the GitHub JWT token didn't match the 
IAM trust policy condition. The exact format of the `sub` claim varies 
based on workflow trigger type (push, PR, workflow_dispatch).

**Debugging approach:**
```yaml
- name: Get OIDC token claims
  run: |
    TOKEN=$(curl -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
    echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

**Temporary fix:** Switched to AWS access key authentication via GitHub Secrets.

**Production fix:** Inspect the actual `sub` claim from the debug workflow 
output and match it exactly in the IAM trust policy `StringLike` condition.

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": 
    "repo:Machindra220/sre-observability-eks-datadog:*"
}
```

### Namespace Not Found

**Problem:** Pipeline failed with `namespaces "sre-demo" not found`

**Root cause:** EKS cluster was recreated after `terraform destroy` but 
Kubernetes manifests were not reapplied.

**Fix:** Always apply base Kubernetes resources after recreating the cluster:
```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/deployment.yaml
kubectl apply -f kubernetes/service.yaml
kubectl apply -f kubernetes/hpa.yaml
```

**Production note:** This is a gap in our current pipeline — it assumes 
the namespace already exists. A production pipeline should apply base 
manifests as part of the deployment or use a separate bootstrap job.

---

## Validation

Successful pipeline output:
✅ Run tests — 6 passed in 0.52s
✅ Configure AWS — Credentials configured
✅ Login to ECR — Login Succeeded
✅ Build and push — digest: sha256:92d5c8b5...
✅ Update kubeconfig — Added new context
✅ Deploy to EKS — deployment.apps/sre-demo-api image updated
✅ Wait for rollout — successfully rolled out
✅ Smoke test — {"status":"healthy","version":"1.0.0","env":"dev"}

Total duration: 1m 14s


Verify deployment traceability:
```bash
kubectl get deployment sre-demo-api -n sre-demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Output:
# 502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-demo-dev-ecr-api:144e5d983b20e6b4f40f28adbb4ab9eaf254005c
```

Full Git SHA visible in the running deployment — complete traceability.

---

## Manifest Validation

Before committing workflows, validate with actionlint:

```bash
# Install actionlint
curl -sL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash | bash
sudo mv actionlint /usr/local/bin/

# Validate
actionlint .github/workflows/ci.yml
actionlint .github/workflows/deploy.yml
# No output = no errors
```

---

## Cost Considerations

GitHub Actions usage for this project:
CI pipeline : ~2 min per PR
CD pipeline : ~1m 14s per push
Free tier : 2,000 min/month for public repos
500 min/month for private repos

This project fits comfortably within free tier limits.


---

## Production Considerations

| Area | Current Approach | Production Change |
|---|---|---|
| Authentication | AWS Access Keys in Secrets | OIDC — no stored credentials |
| Environments | Single (dev) | Separate dev/staging/prod pipelines |
| Image scanning | Trivy, non-blocking | Block on CRITICAL CVEs |
| Rollback | Manual kubectl | Automated rollback on smoke test failure |
| Notifications | None | Slack/PagerDuty on failure |
| Namespace bootstrap | Manual | Pipeline bootstrap job |
| Secrets management | GitHub Secrets | AWS Secrets Manager |
| Deployment strategy | Rolling update | Blue/green or canary |
| Pipeline approval | None | Manual approval gate for production |

---

## Lessons Learned

1. **Test your tests before trusting CI.** The flaky `/api/error` test 
   passed locally sometimes and failed in CI consistently. Random behavior 
   in application code needs controlled behavior in tests.

2. **OIDC is worth the setup pain.** Stored AWS credentials in GitHub 
   Secrets work but carry real risk — leaked secrets mean compromised AWS 
   accounts. OIDC eliminates that risk entirely. The `sub` claim format 
   must be verified from an actual JWT, not assumed.

3. **`kubectl rollout status` is your deployment gate.** Without it, 
   your pipeline reports success even when pods are crash-looping. Always 
   wait for rollout completion before declaring victory.

4. **Git SHA tags create accountability.** When something breaks in 
   production, the first question is "what changed?" A full Git SHA in 
   the running image answers that immediately.

5. **Namespace recreation is a gap.** Our pipeline assumes Kubernetes 
   base resources exist. In a real environment, destroying and recreating 
   the cluster without a bootstrap step will break deployments silently.

6. **Pipeline duration matters.** At 1m 14s end-to-end, this pipeline 
   gives fast feedback. As the project grows, cache Docker layers and 
   pip dependencies to keep it under 3 minutes.

---

## What's Next

**Article 5: Installing Datadog on Kubernetes — Monitoring an EKS Cluster 
from Scratch**

With the deployment pipeline automated, we'll install the Datadog agent 
as a DaemonSet on EKS using Helm, enable infrastructure monitoring, and 
start seeing our first real metrics from the cluster.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*