#!/usr/bin/env bash
# ==============================================================================
# 02_setup_cms.sh
# Configures Cloudera Management Services (CMS) via the CM REST API:
#   1. Wait for CM to be ready
#   2. Verify a Cloudera licence is installed (fails if none found)
#   3. Store Cloudera archive paywall credentials in CM
#   4. Create CMS roles if not already present
#   5. Configure the ReportsManager database (rman)
#   6. Start CMS and wait for STARTED state
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
# Verify a Cloudera licence is installed
# A valid licence must be uploaded before this script runs.
# CM UI: Administration → Licence → Upload Licence
# ---------------------------------------------------------------------------

echo "[INFO] Checking Cloudera licence ..."
LICENSE_HTTP=$(cm_curl "${CM_API_BASE}/cm/license" -o /dev/null -w "%{http_code}")

if [[ "${LICENSE_HTTP}" != "200" ]]; then
  echo "[ERROR] No Cloudera licence is installed (HTTP ${LICENSE_HTTP})." >&2
  echo "[ERROR] Upload your licence before running this script:" >&2
  echo "[ERROR]   CM UI → Administration → Licence → Upload Licence" >&2
  exit 1
fi

LICENSE_OWNER=$(cm_curl "${CM_API_BASE}/cm/license" \
  | jq -r '.owner // "unknown"' 2>/dev/null || echo "unknown")
echo "[INFO] Licence verified: ${LICENSE_OWNER}"

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
# Create Cloudera Management Service (CMS) if not already present
# ---------------------------------------------------------------------------

CMS_HTTP=$(cm_curl "${CM_API_BASE}/cm/service" -o /dev/null -w "%{http_code}")
if [[ "${CMS_HTTP}" == "200" ]]; then
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
#
# Discover the actual role config group name at runtime rather than
# hard-coding it — different CM versions use different naming conventions.
# ---------------------------------------------------------------------------

# headlamp_database_* properties live on the REPORTSMANAGER role config group.
# Note: headlamp_database_port does NOT exist as a CM property — port is not
# configurable here and defaults to the PostgreSQL standard port internally.
echo "[INFO] Configuring ReportsManager database ..."
RM_CONFIG_RESP=$(cm_curl "${CM_API_BASE}/cm/service/roleConfigGroups/mgmt-REPORTSMANAGER-BASE/config" \
  -X PUT \
  -d "$(jq -n \
    --arg host "${DB_HOST}" \
    --arg name "${RM_DB_NAME}" \
    --arg user "${RM_DB_USER}" \
    --arg pass "${RM_DB_PASS}" \
    '{items: [
       {name: "headlamp_database_type",     value: "postgresql"},
       {name: "headlamp_database_host",     value: $host},
       {name: "headlamp_database_name",     value: $name},
       {name: "headlamp_database_user",     value: $user},
       {name: "headlamp_database_password", value: $pass}
     ]}')")

# Verify the database type was actually applied
RM_DB_TYPE_SET=$(echo "${RM_CONFIG_RESP}" \
  | jq -r '.items[] | select(.name == "headlamp_database_type") | .value' \
  2>/dev/null || echo "")

if [[ "${RM_DB_TYPE_SET}" != "postgresql" ]]; then
  echo "[ERROR] Failed to set ReportsManager database type." >&2
  echo "[ERROR] CM response: ${RM_CONFIG_RESP}" >&2
  exit 1
fi
echo "[INFO] ReportsManager database configured (type=${RM_DB_TYPE_SET}, host=${DB_HOST}, db=${RM_DB_NAME}, user=${RM_DB_USER})."

# ---------------------------------------------------------------------------
# Start CMS and poll serviceState directly
#
# We fire the start command and then watch the actual service state rather
# than tracking the command ID.  CM start commands for CMS can remain
# "active" for a long time (ReportsManager schema init, LevelDB setup)
# even after the roles are genuinely running.  The service state is the
# reliable signal.
# ---------------------------------------------------------------------------

CMS_STATE=$(cm_curl "${CM_API_BASE}/cm/service" \
  | jq -r '.serviceState // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

if [[ "${CMS_STATE}" == "STARTED" ]]; then
  echo "[INFO] CMS is already STARTED."
else
  echo "[INFO] Issuing CMS start command ..."
  cm_curl "${CM_API_BASE}/cm/service/commands/start" -X POST > /dev/null

  CMS_WAIT=0
  CMS_MAX=900   # 15 minutes
  echo "[INFO] Polling CMS serviceState (up to ${CMS_MAX}s) ..."
  while [[ "${CMS_WAIT}" -lt "${CMS_MAX}" ]]; do
    CMS_STATE=$(cm_curl "${CM_API_BASE}/cm/service" \
      | jq -r '.serviceState // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    if [[ "${CMS_STATE}" == "STARTED" ]]; then
      break
    fi
    sleep 15
    CMS_WAIT=$((CMS_WAIT + 15))
    echo "[INFO] CMS state: ${CMS_STATE} (${CMS_WAIT}s elapsed) ..."
  done

  if [[ "${CMS_STATE}" != "STARTED" ]]; then
    echo "[ERROR] CMS did not reach STARTED within ${CMS_MAX}s." >&2
    echo "[ERROR] Check CM UI → Cloudera Management Service for role failures." >&2
    exit 1
  fi
fi

echo "[INFO] CMS is STARTED."
echo "[INFO] 02_setup_cms: complete."
