# Deploying a Containerized Application to AWS EKS: From Docker Image to Live Kubernetes Service

## A complete walkthrough of pushing to ECR and deploying to EKS with production-style Kubernetes manifests

---

## Problem

Getting a containerized application running on Kubernetes involves more steps than 
most tutorials show. You need to:

- Authenticate to a private container registry
- Build and tag images correctly for traceability
- Write Kubernetes manifests that reflect production patterns
- Understand what each manifest does and why
- Validate before applying
- Debug when things go wrong

This article covers the complete journey from Docker image to a live application 
accessible via an AWS Load Balancer, as Phase 3 of a larger SRE observability project.

---

## Architecture

```text
Local Machine (WSL2)
       |
   Docker Build
       |
   ECR Push
       |
   AWS ECR
       |
   EKS Pull
       |
  +---------+
  |   Pod   |
  | FastAPI |
  +---------+
       |
   Service
       |
  LoadBalancer
       |
     User
```

---

## Prerequisites

- EKS cluster running (Phase 2)
- Docker working in WSL2
- AWS CLI configured
- kubectl connected to cluster

---

## Step 1 — Authenticate Docker to ECR

ECR is a private registry. Docker needs a temporary token to push images.

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  502274764708.dkr.ecr.us-east-1.amazonaws.com
```

**How this works:**
- `aws ecr get-login-password` generates a 12-hour temporary token
- The token is piped directly to `docker login` — never stored in plaintext
- No long-lived credentials are used

Token expires every 12 hours. In CI/CD pipelines, this command runs before 
every push automatically.

---

## Step 2 — Build and Tag Image

```bash
GIT_SHA=$(git rev-parse --short HEAD)
ECR_URL="502274764708.dkr.ecr.us-east-1.amazonaws.com/sre-demo-dev-ecr-api"

docker build -t ${ECR_URL}:${GIT_SHA} -t ${ECR_URL}:latest .
```

**Why Git SHA as image tag:**

Every image is tagged with the exact Git commit that produced it:

sre-demo-dev-ecr-api:3a149d7 ← traceable to a specific commit
sre-demo-dev-ecr-api:latest ← convenience tag for quick reference


This is critical for observability — when a bad deployment causes an incident, 
you can immediately identify which commit introduced the problem.

**Never deploy `latest` in production** — it's not traceable. Always deploy 
the Git SHA tag. We use `latest` here for convenience during learning.

---

## Step 3 — Push to ECR

```bash
docker push ${ECR_URL}:${GIT_SHA}
docker push ${ECR_URL}:latest
```

```text
856032098bb1: Layer already exists
6f9432833129: Layer already exists
3a149d7: digest: sha256:92d5c8b5... size: 2200
```

**Layer caching:** Docker only uploads changed layers. Unchanged layers 
(`Layer already exists`) are skipped — pushing subsequent builds is fast.

Verify in ECR:
```bash
aws ecr list-images --repository-name sre-demo-dev-ecr-api --region us-east-1
```

---

## Kubernetes Manifests

### Why validate before applying?

Applying broken manifests to a production cluster can cause outages. 
Always validate first:

```bash
# Offline schema validation — no cluster needed
kubeconform -kubernetes-version 1.32.0 *.yaml
```

No output = no errors. Use `-verbose` to see each file result:

namespace.yaml - Namespace sre-demo is valid
deployment.yaml - Deployment sre-demo-api is valid
service.yaml - Service sre-demo-api is valid
configmap.yaml - ConfigMap sre-demo-api-config is valid
hpa.yaml - HorizontalPodAutoscaler sre-demo-api is valid


---

### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: sre-demo
  labels:
    app: sre-demo
    environment: dev
```

**Why namespaces matter:**
Namespaces isolate resources. Our application lives in `sre-demo`, completely 
separate from `kube-system`. This means:
- `kubectl get pods -n sre-demo` shows only our pods
- Resource quotas can be applied per namespace
- RBAC can be scoped per namespace
- Accidental deletion of system resources is prevented

---

### configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sre-demo-api-config
  namespace: sre-demo
data:
  APP_ENV: "dev"
  APP_VERSION: "1.0.0"
  LOG_LEVEL: "info"
```

ConfigMaps externalize configuration from container images. Changing an 
environment variable doesn't require rebuilding the image — just update 
the ConfigMap and roll the deployment.

**Rule of thumb:** If it changes between environments (dev/staging/prod), 
it belongs in a ConfigMap or Secret, not baked into the image.

---

### deployment.yaml

Key sections explained:

**Resource requests and limits:**
```yaml
resources:
  requests:
    cpu: "100m"      # 0.1 CPU core guaranteed
    memory: "128Mi"  # 128 Mebibytes guaranteed
  limits:
    cpu: "500m"      # Maximum 0.5 CPU core
    memory: "256Mi"  # Maximum 256 Mebibytes
```

- `requests` — what Kubernetes reserves on the node for this pod
- `limits` — hard ceiling; pod is killed if memory exceeds this
- `100m` CPU = 100 millicores = 0.1 of one CPU core
- On t3.small (2 vCPU = 2000m), our pod uses a maximum of 25% CPU

**Health probes:**
```yaml
livenessProbe:
  httpGet:
    path: /api/health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /api/ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
```

- `livenessProbe` — if this fails, Kubernetes restarts the container
- `readinessProbe` — if this fails, Kubernetes stops sending traffic to the pod
- `initialDelaySeconds` — wait before first probe (gives app time to start)
- `periodSeconds` — how often to check

This is why we built `/api/health` and `/api/ready` as separate endpoints. 
In production, readiness might check database connectivity while liveness 
just confirms the process is alive.

**Datadog environment variables:**
```yaml
env:
  - name: DD_AGENT_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
  - name: DD_TRACE_ENABLED
    value: "false"
  - name: DD_SERVICE
    value: "sre-demo-api"
  - name: DD_VERSION
    value: "1.0.0"
  - name: DD_ENV
    value: "dev"
```

- `DD_AGENT_HOST: status.hostIP` — tells ddtrace to send traces to the 
  Datadog agent running on the same node (DaemonSet pattern)
- `DD_TRACE_ENABLED: false` — disabled until Datadog agent is installed
- `DD_SERVICE`, `DD_VERSION`, `DD_ENV` — unified service tagging for 
  correlating metrics, logs, and traces in Datadog

---

### service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sre-demo-api
  namespace: sre-demo
spec:
  type: LoadBalancer
  selector:
    app: sre-demo-api
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
```

`type: LoadBalancer` triggers AWS to provision an ELB automatically. 
Traffic flow:

```text
User → Port 80 (ELB) → Port 8080 (Pod)
```

The `selector` matches pods with label `app: sre-demo-api` — this is how 
Kubernetes knows which pods to send traffic to. If labels don't match 
between Service and Deployment, traffic never reaches the pods.

---

### hpa.yaml

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sre-demo-api
  namespace: sre-demo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sre-demo-api
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

HPA automatically scales pod count based on CPU utilization:
- Below 70% CPU → stay at minimum (1 pod)
- Above 70% CPU → scale up (max 3 pods)

This is our first step toward handling load automatically. Later, Datadog 
metrics can drive custom scaling decisions.

---

## Deployment

```bash
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f hpa.yaml
```

Watch the pod come up:
```bash
kubectl get pods -n sre-demo -w

NAME                           READY   STATUS    RESTARTS   AGE
sre-demo-api-6fb49cbc9-v4qk2   1/1     Running   0          49s
```

`1/1` means 1 container running out of 1 expected — healthy.

---

## Validation

```bash
kubectl get svc -n sre-demo

NAME           TYPE           CLUSTER-IP     EXTERNAL-IP                                          PORT(S)
sre-demo-api   LoadBalancer   172.20.124.5   a0b91df686da...us-east-1.elb.amazonaws.com           80:31134/TCP
```

Test all endpoints:
```bash
LB="a0b91df686da740f1a616ed31aa1065e-1644974265.us-east-1.elb.amazonaws.com"

curl http://${LB}/api/health
# {"status":"healthy","version":"1.0.0","env":"dev"}

curl http://${LB}/api/products
# {"products":[{"id":1,"name":"Widget A","price":9.99},...]}

curl http://${LB}/api/error
# {"error":"internal server error","type":"server"}
```

Application is live on EKS and responding correctly.

---

## Troubleshooting Reference

### Pod not starting

```bash
# Check pod status and events
kubectl describe pod <pod-name> -n sre-demo

# Check container logs
kubectl logs <pod-name> -n sre-demo
```

Common causes:
- Image pull failure → wrong ECR URL or missing IAM permissions
- CrashLoopBackOff → application error, check logs
- Pending → insufficient node resources

### Image pull failures

```bash
# Verify ECR image exists
aws ecr list-images --repository-name sre-demo-dev-ecr-api --region us-east-1

# Verify node has ECR pull permissions
aws iam list-attached-role-policies --role-name <node-role-name>
# Should include AmazonEC2ContainerRegistryReadOnly
```

### Service has no EXTERNAL-IP

LoadBalancer provisioning takes 2-3 minutes. If stuck longer:
```bash
kubectl describe svc sre-demo-api -n sre-demo
# Check Events section for errors
```

### kubectl connects to wrong cluster

```bash
# List all configured contexts
kubectl config get-contexts

# Switch to correct context
kubectl config use-context arn:aws:eks:us-east-1:502274764708:cluster/sre-demo-dev-eks-cluster
```

---

## Cost Reminder
EKS Control Plane : ~$73/mo
EC2 t3.small : ~$15/mo
ELB : ~$18/mo
Total : ~$106/mo

Run terraform destroy between sessions to avoid unnecessary charges.


---

## Production Considerations

| Area | Demo Approach | Production Change |
|---|---|---|
| Image tag | `latest` + Git SHA | Git SHA only, never latest |
| Replicas | 1 | Minimum 2, across multiple AZs |
| Resource limits | Conservative | Profile actual usage, right-size |
| Health probe timing | Generic | Tune to actual app startup time |
| Service type | LoadBalancer | Ingress controller + ACM certificate |
| Namespace | Single | Per team or per service |
| Image pull | Node IAM role | IRSA (IAM Roles for Service Accounts) |
| ConfigMap | Plaintext | Secrets Manager for sensitive values |
| HPA | CPU only | Custom metrics via Datadog |

---

## Lessons Learned

1. **Label consistency is everything in Kubernetes.** The Service `selector` 
   must exactly match Deployment pod labels. One typo and traffic never reaches 
   your pods — with no obvious error message.

2. **Validate manifests before applying.** kubeconform catches schema errors 
   offline without needing a cluster. A broken manifest applied to production 
   can cause an outage.

3. **Git SHA image tags enable deployment traceability.** When an incident 
   occurs, you need to know exactly which code is running. `latest` tells 
   you nothing. `3a149d7` tells you everything.

4. **Resource requests matter more than limits.** Kubernetes uses `requests` 
   for scheduling decisions. A pod without requests can be scheduled onto a 
   node that can't actually support it, causing OOM kills under load.

5. **LoadBalancer provisioning is asynchronous.** AWS provisions the ELB in 
   the background after `kubectl apply`. Allow 2-3 minutes before expecting 
   an EXTERNAL-IP.

6. **Separate liveness and readiness probes.** Liveness restarts unhealthy 
   containers. Readiness controls traffic routing. Using the same endpoint 
   for both means a temporarily overloaded pod gets killed instead of just 
   removed from rotation.

---

## What's Next

**Article 4: Building a GitHub Actions CI/CD Pipeline — Automating Every 
Deployment from Git Push to EKS**

We'll automate everything we did manually in this article — build, push, 
deploy — triggered automatically on every Git push using GitHub Actions 
with secure AWS authentication via OIDC.

---

## Repository

[github.com/Machindra220/sre-observability-eks-datadog](https://github.com/Machindra220/sre-observability-eks-datadog)

---

*This article is part of a series documenting a complete SRE observability 
platform built on AWS EKS with Datadog.*

