#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# restore-all.sh
#
# Restores the deployment to a healthy state after any Phase 13
# chaos scenario. Safe to run multiple times.
#
# What it does:
#   1. Removes bad env var injected by Scenario 3
#   2. Restores replica count (from backup or default of 2)
#   3. Waits for all pods to be Running
#   4. Confirms health endpoint is reachable
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BAD_ENV_VAR="DD_TRACE_AGENT_URL"
DEFAULT_REPLICAS=2
REPLICA_BACKUP="/tmp/sre-phase13-replicas.bak"

main() {
  check_prereqs

  log_info "=== Phase 13 Restore: Full Recovery ==="
  echo ""

  # ── Step 1: Remove bad env var (Scenario 3) ──────────────
  log_info "Step 1/3 — Removing injected bad env var (${BAD_ENV_VAR})..."
  # Remove bad env var
  kubectl set env deployment/"${DEPLOYMENT}" \
    -n "${NAMESPACE}" "${BAD_ENV_VAR}-" 2>/dev/null \
  && log_success "Bad env var removed." \
  || log_info "Env var not present — skipping."

# Remove bad command override (Scenario 3 fix)
  kubectl patch deployment sre-demo-api -n sre-demo \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"sre-demo-api","command":null}]}}}}' \
  2>/dev/null && log_success "Command override removed." || true
  
  # ── Step 2: Restore replica count ────────────────────────
  local target_replicas=${DEFAULT_REPLICAS}
  if [[ -f "${REPLICA_BACKUP}" ]]; then
    target_replicas=$(cat "${REPLICA_BACKUP}")
    log_info "Step 2/3 — Restoring replicas to ${target_replicas} (from backup)..."
    rm -f "${REPLICA_BACKUP}"
  else
    log_info "Step 2/3 — No backup found; restoring to default (${target_replicas} replicas)..."
  fi

  kubectl scale deployment "${DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    --replicas="${target_replicas}"
  log_success "Scale command sent."
  echo ""

  # ── Step 3: Wait for pods to be Running ──────────────────
  log_info "Step 3/3 — Waiting for pods to become Ready..."
  kubectl rollout status deployment/"${DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    --timeout=120s

  echo ""
  log_info "Final pod status:"
  kubectl get pods -n "${NAMESPACE}" \
    -l app="${DEPLOYMENT}" \
    -o wide
  echo ""

  # ── Health check ─────────────────────────────────────────
  local app_url
  app_url=$(get_app_url)

  log_info "Health check: ${app_url}/api/health"
  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "${app_url}/api/health" || echo "000")

  if [[ "${http_code}" == "200" ]]; then
    log_success "API is healthy (HTTP 200). Restore complete. ✓"
  else
    log_warn "API returned HTTP ${http_code}. Pods may still be warming up — retry in 30s."
  fi

  echo ""
  log_info "Next step: resolve the open incident in Datadog and document the timeline."
}

main "$@"
