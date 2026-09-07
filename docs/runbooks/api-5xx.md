# Runbook: High Error Rate (5xx)

## Alert
[sre-demo-api] High Error Rate (P2 High)

## Impact
Users receiving 500 errors. Service degraded but partially available.

## Initial Checks

### 1. Check error traces in APM
Datadog → APM → Traces
Filter: service:sre-demo-api status:error

Look for: which endpoint, what exception, stack trace

### 2. Check error logs
Datadog → Logs
Filter: service:sre-demo-api status:error


### 3. Check pod status
```bash
kubectl get pods -n sre-demo
kubectl describe pod -n sre-demo -l app=sre-demo-api
```

### 4. Check recent deployments
```bash
kubectl rollout history deployment/sre-demo-api -n sre-demo
```

## Possible Causes

| Symptom | Cause | Fix |
|---|---|---|
| All endpoints failing | App bug | Rollback deployment |
| One endpoint failing | Specific bug | Fix and redeploy |
| Started after deploy | Bad deployment | Rollback |
| Random failures | Resource pressure | Scale up or increase limits |

## Mitigation

### Rollback deployment
```bash
kubectl rollout undo deployment/sre-demo-api -n sre-demo
```

### Check and increase resources
```bash
kubectl describe pod -n sre-demo -l app=sre-demo-api | grep -A5 "Limits"
```

## Recovery Validation
Datadog → Monitors → [sre-demo-api] High Error Rate
Status should return to OK within 5 minutes