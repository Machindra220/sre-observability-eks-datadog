#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# inject-pod-crash.sh
#
# Scenario 3 — Pod CrashLoopBackOff
# Patches the deployment with a bad env var that causes the app
# to crash immediately on startup → CrashLoopBackOff.
#
# Expected trigger : "P2 Pod Restart" monitor → alert
# Datadog metric   : kubernetes.containers.restarts
# Restore          : run restore-all.sh  (removes the bad patch)
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Name of the env var injected to cause a crash.
# The FastAPI app reads DD_ENV; we point it at an invalid value
# so ddtrace init fails hard on startup.

BAD_ENV_VAR="DD_TRACE_AGENT_URL"
BAD_ENV_VAL="http://does-not-exist.invalid:9999"

# Inject a bad startup command → container exits → CrashLoopBackOff
kubectl patch deployment sre-demo-api -n sre-demo --patch '{"spec":{"template":{"spec":{"containers":[{"name":"sre-demo-api","command":["/bin/sh","-c","echo crash && exit 1"]}]}}}}'


OBSERVE_SECS=${OBSERVE_SECS:-120}   # how long to watch before suggesting restore

main() {
  check_prereqs

  log_info "=== Scenario 3: Pod CrashLoopBackOff Injection ==="
  log_info "Deployment  : ${DEPLOYMENT} (namespace: ${NAMESPACE})"
  log_info "Bad env var : ${BAD_ENV_VAR}=${BAD_ENV_VAL}"
  log_warn "This will crash all pods. Run restore-all.sh to recover."
  echo ""

  # Capture the current replica count so restore can set it back
  local replicas
  replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}')
  log_info "Current replicas: ${replicas} — saving for restore"
  echo "${replicas}" > /tmp/sre-phase13-replicas.bak

  # Patch the deployment with the bad env var
  log_info "Patching deployment to inject bad env var..."
  kubectl set env deployment/"${DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    "${BAD_ENV_VAR}=${BAD_ENV_VAL}"

  log_warn "Pods are restarting. Watching for CrashLoopBackOff..."
  echo ""

  # Stream pod status for OBSERVE_SECS seconds
  local end_time=$(( $(date +%s) + OBSERVE_SECS ))
  while [[ $(date +%s) -lt ${end_time} ]]; do
    echo -e "${CYN}--- Pod status ($(date +%H:%M:%S)) ---${NC}"
    kubectl get pods -n "${NAMESPACE}" \
      -l app="${DEPLOYMENT}" \
      --no-headers \
      -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,REASON:.status.containerStatuses[0].state.waiting.reason" \
      2>/dev/null || true
    echo ""
    sleep 15
  done

  log_warn "Observation window done."
  log_warn "→ To recover, run: ./restore-all.sh"
  log_info "→ Check Datadog: Monitors → 'P2 Pod Restart'"
}

main "$@"
