#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# run-all-scenarios.sh
#
# Orchestrates all 4 Phase 13 failure scenarios in sequence.
# Restores to healthy state between each scenario.
#
# Usage: ./run-all-scenarios.sh
#   or run each inject-*.sh individually for fine-grained control.
#
# Sequence:
#   1. High Error Rate   → restore → pause
#   2. High Latency      → pause
#   3. Pod CrashLoop     → restore → pause
#   4. Availability Drop → restore
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

PAUSE_BETWEEN=60   # seconds to pause between scenarios (Datadog needs time to settle)

separator() {
  echo ""
  echo -e "${YEL}══════════════════════════════════════════════════${NC}"
  echo -e "${YEL}  $*${NC}"
  echo -e "${YEL}══════════════════════════════════════════════════${NC}"
  echo ""
}

pause_with_countdown() {
  local secs=${1:-60}
  log_info "Pausing ${secs}s to let Datadog settle before next scenario..."
  for (( i=secs; i>0; i-- )); do
    printf "\r  %ds remaining..." "${i}"
    sleep 1
  done
  echo ""
}

main() {
  check_prereqs

  log_info "=== Phase 13: Full Chaos Suite ==="
  log_info "All 4 scenarios will run with automatic restore between each."
  log_warn "Estimated total time: ~15 minutes"
  echo ""
  read -rp "Press ENTER to start, or Ctrl+C to abort..."
  echo ""

  # ── Scenario 1 ────────────────────────────────────────────
  separator "Scenario 1 / 4 — High Error Rate"
  DURATION_SECS=120 CONCURRENCY=10 \
    bash "${SCRIPT_DIR}/inject-high-error-rate.sh"

  pause_with_countdown "${PAUSE_BETWEEN}"

  # ── Scenario 2 ────────────────────────────────────────────
  separator "Scenario 2 / 4 — High Latency"
  DURATION_SECS=120 CONCURRENCY=15 \
    bash "${SCRIPT_DIR}/inject-high-latency.sh"

  pause_with_countdown "${PAUSE_BETWEEN}"

  # ── Scenario 3 ────────────────────────────────────────────
  separator "Scenario 3 / 4 — Pod CrashLoopBackOff"
  OBSERVE_SECS=90 \
    bash "${SCRIPT_DIR}/inject-pod-crash.sh"

  log_info "Restoring after Scenario 3..."
  bash "${SCRIPT_DIR}/restore-all.sh"

  pause_with_countdown "${PAUSE_BETWEEN}"

  # ── Scenario 4 ────────────────────────────────────────────
  separator "Scenario 4 / 4 — Availability Drop (P1)"
  OBSERVE_SECS=90 \
    bash "${SCRIPT_DIR}/inject-availability-drop.sh"

  log_info "Restoring after Scenario 4..."
  bash "${SCRIPT_DIR}/restore-all.sh"

  # ── Done ──────────────────────────────────────────────────
  separator "All Scenarios Complete"
  log_success "Platform is healthy and all scenarios have been injected."
  log_info "Next steps:"
  echo "  1. Verify all monitors fired in Datadog"
  echo "  2. Check incidents were auto-created (Phase 12 workflow)"
  echo "  3. Capture screenshots for docs/screenshots/phase-13/"
  echo "  4. Resolve open incidents in Datadog with a post-mortem note"
}

main "$@"
