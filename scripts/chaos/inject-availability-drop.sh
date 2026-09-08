#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# inject-availability-drop.sh
#
# Scenario 4 — Availability Drop (most severe)
# Scales the deployment to 0 replicas → 100% of requests 503.
#
# Expected trigger : "P1 API Availability" monitor → SEV-1 incident
# Datadog metric   : trace.fastapi.request.hits (drops to zero)
# Restore          : run restore-all.sh
#
# Run this last — it's the hardest failure and triggers the P1 path.
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

OBSERVE_SECS=${OBSERVE_SECS:-90}
BACKGROUND_PROBE_INTERVAL=5   # seconds between health-check probes during outage

main() {
  check_prereqs

  local app_url
  app_url=$(get_app_url)

  log_info "=== Scenario 4: Availability Drop Injection ==="
  log_info "Deployment  : ${DEPLOYMENT} (namespace: ${NAMESPACE})"
  log_warn "Scaling to 0 replicas — the API will be completely unreachable."
  log_warn "This triggers the P1 monitor. Run restore-all.sh to recover."
  echo ""

  # Save current replica count
  local replicas
  replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}')
  log_info "Current replicas: ${replicas} — saving for restore"
  echo "${replicas}" > /tmp/sre-phase13-replicas.bak

  # Scale to zero
  log_info "Scaling deployment to 0..."
  kubectl scale deployment "${DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0
  log_warn "All pods are terminating. API is down."
  echo ""

  # Probe the health endpoint in the background to confirm outage
  log_info "Probing ${app_url}/api/health every ${BACKGROUND_PROBE_INTERVAL}s during outage..."
  echo ""

  local end_time=$(( $(date +%s) + OBSERVE_SECS ))
  while [[ $(date +%s) -lt ${end_time} ]]; do
    local http_code
    http_code=$(curl -o /dev/null -s -w "%{http_code}" \
      --max-time 5 "${app_url}/api/health" || echo "000")

    local elapsed=$(( $(date +%s) - (end_time - OBSERVE_SECS) ))

    if [[ "${http_code}" == "000" || "${http_code}" == "5"* ]]; then
      echo -e "${RED}[DOWN]${NC}  ${elapsed}s — HTTP ${http_code} (expected during outage)"
    else
      echo -e "${GRN}[UP]${NC}    ${elapsed}s — HTTP ${http_code} (unexpected — pods still running?)"
    fi

    sleep "${BACKGROUND_PROBE_INTERVAL}"
  done

  echo ""
  log_warn "Observation window done. API is still down."
  log_warn "→ To recover, run: ./restore-all.sh"
  log_info "→ Check Datadog: Monitors → 'P1 API Availability' → Incident created"
}

main "$@"
