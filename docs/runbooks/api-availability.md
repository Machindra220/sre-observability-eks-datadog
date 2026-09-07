# Runbook: API Availability - No Traffic

## Alert
[sre-demo-api] API Availability - No Traffic (P1 Critical)

## Impact
Complete service outage. All users affected. Zero requests being served.

## Symptoms
- Monitor: API Availability showing ALERT
- No traffic in Golden Signals dashboard
- Users reporting service unavailable

## Initial Checks (< 2 minutes)

### 1. Check pod status
```bash
kubectl get pods -n sre-demo
```
Expected: `sre-demo-api-xxx   1/1   Running`
If not running: pod has crashed → check logs

### 2. Check pod logs
```bash
kubectl logs -n sre-demo -l app=sre-demo-api --tail=50
```
Look for: exceptions, OOM errors, startup failures

### 3. Check service and LoadBalancer
```bash
kubectl get svc -n sre-demo
```
Expected: EXTERNAL-IP is assigned
If pending: LoadBalancer not provisioned

### 4. Test endpoint directly
```bash
LB=$(kubectl get svc sre-demo-api -n sre-demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -v http://${LB}/api/health
```

## Possible Causes

| Symptom | Cause | Fix |
|---|---|---|
| Pod not running | App crash | Check logs, restart pod |
| ImagePullBackOff | ECR auth expired | Re-push image |
| OOMKilled | Memory limit | Increase memory limit |
| No EXTERNAL-IP | LB not provisioned | Delete/recreate service |
| CrashLoopBackOff | Startup failure | Check env vars, secrets |

## Mitigation

### Restart deployment
```bash
kubectl rollout restart deployment/sre-demo-api -n sre-demo
kubectl rollout status deployment/sre-demo-api -n sre-demo
```

### Rollback to previous version
```bash
kubectl rollout undo deployment/sre-demo-api -n sre-demo
```

### Scale up replicas
```bash
kubectl scale deployment sre-demo-api --replicas=2 -n sre-demo
```

## Recovery Validation
```bash
curl http://${LB}/api/health
# Expected: {"status":"healthy","version":"1.0.0","env":"dev"}
```

Monitor should recover within 5 minutes of fix.

## Escalation
If not resolved in 15 minutes → escalate to senior engineer