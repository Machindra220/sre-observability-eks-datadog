#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# inject-high-latency.sh
#
# Scenario 2 — High Latency
# Floods /latency to push p99 response time above 2 s threshold.
#
# Expected trigger : "P3 High Latency" monitor → alert
# Datadog metric   : trace.fastapi.request.duration (p99)
# Duration         : ~3 minutes (configurable via DURATION_SECS)
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DURATION_SECS=${DURATION_SECS:-180}
CONCURRENCY=${CONCURRENCY:-15}   # more workers → more concurrent slow requests
SLEEP_BETWEEN=0.2

main() {
  check_prereqs

  local app_url
  app_url=$(get_app_url)

  log_info "=== Scenario 2: High Latency Injection ==="
  log_info "Target      : ${app_url}/api/slow"
  log_info "Concurrency : ${CONCURRENCY} workers"
  log_info "Duration    : ${DURATION_SECS}s"
  log_warn "Watch Datadog → Monitors → 'P3 High Latency'"
  echo ""

  # Baseline — confirm endpoint is reachable before flooding
  log_info "Sending one baseline request to confirm connectivity..."
  local baseline_ms
  baseline_ms=$(curl -o /dev/null -s -w "%{time_total}" "${app_url}/api/slow" \
    | awk '{printf "%.0f", $1 * 1000}')
  log_info "Baseline latency: ${baseline_ms}ms"
  echo ""

  local end_time=$(( $(date +%s) + DURATION_SECS ))
  local pids=()

  for (( i=1; i<=CONCURRENCY; i++ )); do
    (
      while [[ $(date +%s) -lt ${end_time} ]]; do
        curl -sf "${app_url}/api/slow" -o /dev/null || true
        sleep "${SLEEP_BETWEEN}"
      done
    ) &
    pids+=($!)
  done

  log_info "Load started. PID group: ${pids[*]}"

  local elapsed=0
  while [[ $(date +%s) -lt ${end_time} ]]; do
    elapsed=$(( $(date +%s) - (end_time - DURATION_SECS) ))
    printf "\r${CYN}[INFO]${NC}  Elapsed: %ds / %ds — slow requests in flight..." \
      "${elapsed}" "${DURATION_SECS}"
    sleep 5
  done
  echo ""

  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true

  log_success "Scenario 2 complete. Check Datadog for latency alert."
  log_info "Metric to inspect: trace.fastapi.request.duration (p99), grouped by service"
}

main "$@"
