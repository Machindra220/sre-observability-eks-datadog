#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# inject-high-error-rate.sh
#
# Scenario 1 — High Error Rate
# Floods /error to push 5xx rate above the P2 monitor threshold.
#
# Expected trigger : "P2 High Error Rate" monitor → SEV-1 incident
# Datadog metric   : trace.fastapi.request.errors / trace.fastapi.request.hits
# Duration         : ~3 minutes (configurable via DURATION_SECS)
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DURATION_SECS=${DURATION_SECS:-180}   # how long to sustain load
CONCURRENCY=${CONCURRENCY:-10}         # parallel curl workers
SLEEP_BETWEEN=0.1                      # seconds between each request per worker

main() {
  check_prereqs

  local app_url
  app_url=$(get_app_url)

  log_info "=== Scenario 1: High Error Rate Injection ==="
  log_info "Target      : ${app_url}/error"
  log_info "Concurrency : ${CONCURRENCY} workers"
  log_info "Duration    : ${DURATION_SECS}s"
  log_warn "Watch Datadog → Monitors → 'P2 High Error Rate'"
  echo ""

  local end_time=$(( $(date +%s) + DURATION_SECS ))
  local pids=()

  # Spawn N background workers, each hammering /error
  for (( i=1; i<=CONCURRENCY; i++ )); do
    (
      while [[ $(date +%s) -lt ${end_time} ]]; do
        curl -sf "${app_url}/api/error" -o /dev/null || true
        sleep "${SLEEP_BETWEEN}"
      done
    ) &
    pids+=($!)
  done

  log_info "Load started. PID group: ${pids[*]}"

  # Progress ticker
  local elapsed=0
  while [[ $(date +%s) -lt ${end_time} ]]; do
    elapsed=$(( $(date +%s) - (end_time - DURATION_SECS) ))
    printf "\r${CYN}[INFO]${NC}  Elapsed: %ds / %ds — errors flying..." \
      "${elapsed}" "${DURATION_SECS}"
    sleep 5
  done
  echo ""

  # Clean up workers
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true

  log_success "Scenario 1 complete. Check Datadog for triggered alerts."
  log_info "To restore: run restore-all.sh (no-op for this scenario — no infra change made)"
}

main "$@"
