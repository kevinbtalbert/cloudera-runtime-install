#!/usr/bin/env bash
# ==============================================================================
# Shared helpers for cloudera-runtime-install scripts.
# Sources EXPORTS automatically when the EXPORTS_FILE variable is unset.
# ==============================================================================

set -uo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EXPORTS_FILE="${EXPORTS_FILE:-${_LIB_DIR}/../EXPORTS}"

# Source EXPORTS once (guard via CM_ADMIN_USER which EXPORTS always sets).
if [[ -z "${CM_ADMIN_USER:-}" && -f "${_EXPORTS_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${_EXPORTS_FILE}"
fi

LOG_DIR="${LOG_DIR:-/var/log/cloudera-bootstrap}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_init() {
  local name="$1"
  mkdir -p "${LOG_DIR}"
  local log_file="${LOG_DIR}/${name}_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "${log_file}") 2>&1
  echo "=== Host: $(hostname) | Date: $(date) | Script: ${name} ==="
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" &>/dev/null; then
    echo "[ERROR] Required command not found: ${cmd}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Cloudera Manager REST API helpers
# ---------------------------------------------------------------------------

# Return the highest API version supported by CM (e.g. "v44").
cm_api_version() {
  local host="${CM_HOST:-${MANAGER_HOST:-localhost}}"
  local ver
  ver=$(curl -s --max-time 10 \
        -u "${CM_ADMIN_USER:-admin}:${CM_ADMIN_PASS:-admin}" \
        "http://${host}:7180/api/version" 2>/dev/null) || true
  if [[ -z "${ver}" ]]; then
    echo "v44"
  else
    echo "${ver}"
  fi
}

# Convenience wrapper: curl with CM credentials and JSON content type.
# Usage: cm_curl <url> [extra curl args ...]
cm_curl() {
  local url="$1"; shift
  curl -s --max-time 120 \
       -u "${CM_ADMIN_USER:-admin}:${CM_ADMIN_PASS:-admin}" \
       -H "Content-Type: application/json" \
       "${url}" "$@"
}

# Block until CM's HTTP API responds with 200, or exit on timeout.
wait_for_cm() {
  local host="${CM_HOST:-${MANAGER_HOST:-localhost}}"
  local max_wait="${1:-300}"
  local waited=0
  echo "[INFO] Waiting up to ${max_wait}s for Cloudera Manager at http://${host}:7180 ..."
  while [[ "${waited}" -lt "${max_wait}" ]]; do
    local code
    code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
           -u "${CM_ADMIN_USER:-admin}:${CM_ADMIN_PASS:-admin}" \
           "http://${host}:7180/api/version" 2>/dev/null) || code="000"
    if [[ "${code}" == "200" ]]; then
      echo "[INFO] Cloudera Manager is ready."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    echo "[INFO] CM not ready (HTTP ${code}), ${waited}s elapsed / ${max_wait}s ..."
  done
  echo "[ERROR] Cloudera Manager did not respond within ${max_wait}s." >&2
  exit 1
}

# Emit one progress line for a CM command response.
# Shows step counts (done/total) and the name of the most recent active or
# completed child step.  Works even when all children finished between polls.
# Uses a temp file so the JSON is not embedded in shell/Python string literals.
_cmd_progress_line() {
  local resp="$1"
  local _tmp
  _tmp=$(mktemp /tmp/cm_cmd_resp.XXXXXX.json)
  printf '%s' "${resp}" > "${_tmp}"

  python3 - "${_tmp}" <<'PYEOF' 2>/dev/null
import json, sys, os

path = sys.argv[1]
try:
    with open(path) as fh:
        d = json.load(fh)
finally:
    os.unlink(path)

items = (d.get('children') or {}).get('items') or []
if not items:
    sys.exit(0)

total    = len(items)
done_ok  = sum(1 for c in items if c.get('active') == False and c.get('success') == True)
done_bad = sum(1 for c in items if c.get('active') == False and c.get('success') == False)
running  = [c for c in items if c.get('active') == True]

def label(c):
    parts = [c.get('name') or '']
    svc  = (c.get('serviceRef') or {}).get('serviceName') or ''
    role = (c.get('roleRef')    or {}).get('roleName')    or ''
    if svc:  parts.append(f'[{svc}]')
    if role: parts.append(f'/{role}')
    return ' '.join(p for p in parts if p)

if running:
    msg = f'{done_ok}/{total} done | running: {label(running[-1])}'
else:
    completed = sorted([c for c in items if not c.get('active')],
                       key=lambda c: c.get('endTime') or '')
    last = label(completed[-1]) if completed else ''
    fail_note = f' ({done_bad} failed)' if done_bad else ''
    msg = f'{done_ok}/{total} done{fail_note}' + (f' | last: {last}' if last else '')

print(msg)
PYEOF
}

# Poll a CM command by ID until it finishes.  Prints step progress on each
# interval so you can see what CM is working on.
# Usage: wait_for_command <api_base_url> <command_id> [timeout_secs]
wait_for_command() {
  require_cmd jq
  local api_base="$1"
  local cmd_id="$2"
  local max_wait="${3:-7200}"
  local waited=0
  local interval=15

  echo "[INFO] Polling command ${cmd_id} (timeout ${max_wait}s) ..."
  while [[ "${waited}" -lt "${max_wait}" ]]; do
    local resp active success msg
    resp=$(cm_curl "${api_base}/commands/${cmd_id}") || true

    active=$(echo "${resp}"  | jq -r '.active  // true'  2>/dev/null || echo "true")
    success=$(echo "${resp}" | jq -r '.success // false' 2>/dev/null || echo "false")

    if [[ "${active}" == "false" ]]; then
      if [[ "${success}" == "true" ]]; then
        echo "[INFO] Command ${cmd_id} succeeded."
        return 0
      else
        msg=$(echo "${resp}" | jq -r '.resultMessage // "no message"' 2>/dev/null || echo "unknown")
        echo "[ERROR] Command ${cmd_id} failed: ${msg}" >&2
        echo "${resp}" | jq -r '
          .children.items[]?
          | select(.success == false and .active == false)
          | "[FAILED] \(.name // "") service=\(.serviceRef.serviceName // "-") msg=\(.resultMessage // "")"
        ' 2>/dev/null || true
        return 1
      fi
    fi

    sleep "${interval}"
    waited=$((waited + interval))

    local progress
    progress=$(_cmd_progress_line "${resp}") || true
    if [[ -n "${progress}" ]]; then
      echo "[INFO] ${waited}s | ${progress}"
    else
      echo "[INFO] ${waited}s | Command ${cmd_id} running ..."
    fi
  done

  echo "[ERROR] Command ${cmd_id} timed out after ${max_wait}s." >&2
  return 1
}
