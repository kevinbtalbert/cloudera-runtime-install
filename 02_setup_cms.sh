#!/usr/bin/env bash
# ==============================================================================
# 02_setup_cms.sh
# Configures Cloudera Management Services (CMS) via the CM REST API:
#   1. Wait for CM to be ready
#   2. Accept the trial licence
#   3. Store Cloudera archive paywall credentials in CM
#   4. Create and start CMS roles (ServiceMonitor, HostMonitor,
#      EventServer, AlertPublisher, ReportsManager)
#   5. Configure the ReportsManager database (rman)
#
# Idempotent: skips steps that are already complete.
# Runs on the Cloudera Manager host.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "02_setup_cms"
need_root
require_cmd curl
require_cmd jq

# ---------------------------------------------------------------------------
# Derive API base URL
# ---------------------------------------------------------------------------

wait_for_cm 300

CM_API_VERSION="$(cm_api_version)"
CM_API_BASE="http://${MANAGER_HOST}:7180/api/${CM_API_VERSION}"
echo "[INFO] Using CM API: ${CM_API_BASE}"

# ---------------------------------------------------------------------------
# Accept trial licence
# ---------------------------------------------------------------------------

echo "[INFO] Accepting trial licence ..."
TRIAL_RESP=$(cm_curl "${CM_API_BASE}/cm/trial/begin" -X POST)
TRIAL_MSG=$(echo "${TRIAL_RESP}" | jq -r '.message // ""' 2>/dev/null || true)
if echo "${TRIAL_RESP}" | jq -e '.message' &>/dev/null; then
  echo "[INFO] Trial response: ${TRIAL_MSG}"
else
  echo "[INFO] Trial accepted (or already active)."
fi

# ---------------------------------------------------------------------------
# Store paywall credentials in CM
# ---------------------------------------------------------------------------

echo "[INFO] Setting Cloudera archive paywall credentials ..."
cm_curl "${CM_API_BASE}/cm/config" \
  -X PUT \
  -d "$(jq -n \
    --arg u "${CLOUDERA_REPO_USER:-}" \
    --arg p "${CLOUDERA_REPO_PASS:-}" \
    '{items: [
       {name: "REMOTE_REPO_OVERRIDE_USER",     value: $u},
       {name: "REMOTE_REPO_OVERRIDE_PASSWORD", value: $p}
     ]}')" \
  > /dev/null
echo "[INFO] Paywall credentials stored."

# ---------------------------------------------------------------------------
# Create Cloudera Management Service (CMS)
# ---------------------------------------------------------------------------

CMS_STATUS=$(cm_curl "${CM_API_BASE}/cm/service" -o /dev/null -w "%{http_code}")
if [[ "${CMS_STATUS}" == "200" ]]; then
  echo "[INFO] Cloudera Management Service already exists; skipping creation."
else
  echo "[INFO] Creating Cloudera Management Service ..."
  cm_curl "${CM_API_BASE}/cm/service" \
    -X PUT \
    -d '{
      "roles": [
        {"type": "SERVICEMONITOR"},
        {"type": "HOSTMONITOR"},
        {"type": "EVENTSERVER"},
        {"type": "ALERTPUBLISHER"},
        {"type": "REPORTSMANAGER"}
      ]
    }' > /dev/null
  echo "[INFO] CMS created."
fi

# ---------------------------------------------------------------------------
# Configure ReportsManager database
# ---------------------------------------------------------------------------

echo "[INFO] Configuring ReportsManager database ..."
cm_curl "${CM_API_BASE}/cm/service/roleConfigGroups/mgmt-REPORTSMANAGER-BASE/config" \
  -X PUT \
  -d "$(jq -n \
    --arg host  "${DB_HOST:-localhost}" \
    --arg port  "${DB_PORT:-5432}" \
    --arg name  "${RM_DB_NAME:-rman}" \
    --arg user  "${RM_DB_USER:-rman}" \
    --arg pass  "${RM_DB_PASS}" \
    '{items: [
       {name: "headlamp_database_type",     value: "postgresql"},
       {name: "headlamp_database_host",     value: $host},
       {name: "headlamp_database_port",     value: $port},
       {name: "headlamp_database_name",     value: $name},
       {name: "headlamp_database_user",     value: $user},
       {name: "headlamp_database_password", value: $pass}
     ]}')" \
  > /dev/null
echo "[INFO] ReportsManager database configured."

# ---------------------------------------------------------------------------
# Start CMS
# ---------------------------------------------------------------------------

echo "[INFO] Starting Cloudera Management Service ..."
START_RESP=$(cm_curl "${CM_API_BASE}/cm/service/commands/start" -X POST)
START_CMD_ID=$(echo "${START_RESP}" | jq -r '.id' 2>/dev/null || echo "")

if [[ -z "${START_CMD_ID}" || "${START_CMD_ID}" == "null" ]]; then
  echo "[WARN] Could not retrieve start command ID; CMS may already be running."
else
  wait_for_command "${CM_API_BASE}" "${START_CMD_ID}" 300
fi

# ---------------------------------------------------------------------------
# Verify CMS is running
# ---------------------------------------------------------------------------

sleep 5
CMS_STATE=$(cm_curl "${CM_API_BASE}/cm/service" | jq -r '.serviceState // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
echo "[INFO] CMS service state: ${CMS_STATE}"

if [[ "${CMS_STATE}" != "STARTED" ]]; then
  echo "[WARN] CMS state is '${CMS_STATE}'; it may still be starting.  Check CM UI if services fail."
fi

echo "[INFO] 02_setup_cms: complete."
