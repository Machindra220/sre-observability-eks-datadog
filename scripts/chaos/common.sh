#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# common.sh — shared config and helpers for Phase 13 chaos scripts
# Source this file; do not run it directly.
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ────────────────────────────────────────────────────
NAMESPACE="sre-demo"
DEPLOYMENT="sre-demo-api"
APP_PORT="80"

# Resolve the LoadBalancer hostname once and export it
get_app_url() {
  local hostname
  hostname=$(kubectl get svc "${DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

  if [[ -z "${hostname}" ]]; then
    echo "[ERROR] Could not resolve LoadBalancer hostname. Is infra up?" >&2
    exit 1
  fi

  echo "http://${hostname}:${APP_PORT}"
}

# ── Colours ───────────────────────────────────────────────────
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YEL}[WARN]${NC}  $*"; }
log_success() { echo -e "${GRN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Prerequisite check ────────────────────────────────────────
check_prereqs() {
  local missing=0
  for cmd in kubectl curl; do
    if ! command -v "${cmd}" &>/dev/null; then
      log_error "Required tool not found: ${cmd}"
      missing=1
    fi
  done
  [[ ${missing} -eq 0 ]] || exit 1
}
