#!/usr/bin/env bash
# ==============================================================================
# 05_deploy_cluster.sh
# Deploys the CDP Runtime + CFM + CSA cluster via CM importClusterTemplate.
#
# Follows the edge2ai-workshop create_cluster.py pattern:
#   1. Validate variables and generate the cluster template
#   2. Import the template (parcels should already be pre-staged by step 04)
#   3. If the command fails, restart Management Services and retry (up to
#      MAX_IMPORT_RETRIES times).  CM's retry API re-attempts only the
#      sub-commands that failed — services that already started are skipped.
#   4. Restart Management Services after successful deployment
#   5. Clear paywall credentials from CM
#
# Runs on the Cloudera Manager host.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "05_deploy_cluster"
need_root
require_cmd curl
require_cmd jq
require_cmd envsubst

MAX_IMPORT_RETRIES=2   # matches edge2ai's import_retries=2

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------

echo "[INFO] Validating configuration ..."

REQUIRED_VARS=(
  CLUSTER_NAME CLUSTER_HOST
  CDH_VERSION CDH_BUILD CDH_PARCEL_REPO
  CM_VERSION CFM_BUILD CFM_PARCEL_REPO_URL
  CSA_FLINK_BUILD CSA_PARCEL_REPO
  DB_HOST DB_PORT
  HIVE_DB_NAME HIVE_DB_USER HIVE_DB_PASS
  HUE_DB_NAME  HUE_DB_USER  HUE_DB_PASS
  REG_DB_NAME  REG_DB_USER  REG_DB_PASS
  SSB_DB_NAME  SSB_DB_USER  SSB_DB_PASS
  NIFI_JAVA_HOME
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] Required variable not set: ${var}" >&2
    exit 1
  fi
done

echo "[INFO] CLUSTER_NAME    : ${CLUSTER_NAME}"
echo "[INFO] CLUSTER_HOST    : ${CLUSTER_HOST}"
echo "[INFO] CDH_BUILD       : ${CDH_BUILD}"
echo "[INFO] CFM_BUILD       : ${CFM_BUILD}"
echo "[INFO] CSA_FLINK_BUILD : ${CSA_FLINK_BUILD}"
echo "[INFO] NIFI_JAVA_HOME  : ${NIFI_JAVA_HOME}"

# ---------------------------------------------------------------------------
# Generate the cluster template
# ---------------------------------------------------------------------------

TEMPLATE_FILE="${SCRIPT_DIR}/templates/cluster.json.tmpl"
GENERATED_TEMPLATE="/tmp/cluster_${CLUSTER_NAME}.json"

[[ -f "${TEMPLATE_FILE}" ]] || { echo "[ERROR] Template not found: ${TEMPLATE_FILE}" >&2; exit 1; }

echo "[INFO] Generating cluster template -> ${GENERATED_TEMPLATE} ..."

# Determine Kafka -> ZooKeeper TLS setting dynamically.
# If ZooKeeper already exists (retry scenario), read its actual TLS config.
# Otherwise default to false (non-TLS, safe for fresh deployments).
_zk_tls_enabled() {
  local raw
  raw=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/zookeeper/config" 2>/dev/null \
    | jq -r '(.items // []) | map(select(.name == "zookeeper_tls_enabled")) | .[0].value // ""' \
    2>/dev/null || echo "")
  case "${raw}" in
    true|True|TRUE) echo "true" ;;
    *)              echo "false" ;;
  esac
}

export KAFKA_ZK_SECURE
KAFKA_ZK_SECURE=$(_zk_tls_enabled)
echo "[INFO] KAFKA_ZK_SECURE (mirrors ZooKeeper TLS): ${KAFKA_ZK_SECURE}"

SUBST_VARS='${CLUSTER_NAME}${CLUSTER_HOST}${CDH_VERSION}${CDH_BUILD}${CDH_PARCEL_REPO}${CM_VERSION}${CFM_BUILD}${CFM_PARCEL_REPO_URL}${CSA_FLINK_BUILD}${CSA_PARCEL_REPO}${DB_HOST}${DB_PORT}${HIVE_DB_NAME}${HIVE_DB_USER}${HIVE_DB_PASS}${HUE_DB_NAME}${HUE_DB_USER}${HUE_DB_PASS}${REG_DB_NAME}${REG_DB_USER}${REG_DB_PASS}${SSB_DB_NAME}${SSB_DB_USER}${SSB_DB_PASS}${NIFI_JAVA_HOME}${KAFKA_ZK_SECURE}'

envsubst "${SUBST_VARS}" < "${TEMPLATE_FILE}" > "${GENERATED_TEMPLATE}"

if ! jq . "${GENERATED_TEMPLATE}" > /dev/null 2>&1; then
  echo "[ERROR] Generated template is not valid JSON." >&2; exit 1
fi
echo "[INFO] Template JSON is valid."

# ---------------------------------------------------------------------------
# CM API setup
# ---------------------------------------------------------------------------

wait_for_cm 60

CM_API_VERSION="$(cm_api_version)"
CM_API_BASE="http://${MANAGER_HOST}:7180/api/${CM_API_VERSION}"
echo "[INFO] Using CM API: ${CM_API_BASE}"

# ---------------------------------------------------------------------------
# Check whether the cluster already exists.
# If it exists but contains only CORE_SETTINGS (stub from a failed previous
# import), delete it automatically so this run can start fresh.
# A fully deployed cluster is left untouched — exit 0 to skip.
# ---------------------------------------------------------------------------

CLUSTER_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${CLUSTER_NAME}")
CLUSTER_STATUS=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}" \
  -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

if [[ "${CLUSTER_STATUS}" == "200" ]]; then
  # Count how many non-CORE_SETTINGS services the cluster has
  SERVICE_COUNT=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services" \
    | jq '[.items[] | select(.type != "CORE_SETTINGS")] | length' 2>/dev/null || echo "0")

  if [[ "${SERVICE_COUNT}" -gt 0 ]]; then
    echo "[INFO] Cluster '${CLUSTER_NAME}' already exists with ${SERVICE_COUNT} deployed service(s)."
    echo "[INFO] Skipping template import.  Delete the cluster in CM to redeploy from scratch."
    exit 0
  fi

  echo "[WARN] Cluster '${CLUSTER_NAME}' exists but has no deployed services (stub from a failed run)."
  echo "[WARN] Deleting stub cluster and redeploying ..."

  # Stop any active commands on the cluster before deleting
  cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/commands/stop" -X POST > /dev/null 2>&1 || true
  sleep 5

  DELETE_RESP=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}" -X DELETE)
  if echo "${DELETE_RESP}" | jq -e '.message' &>/dev/null; then
    # CM returned an error message — may still have active commands; wait and retry once
    sleep 15
    cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}" -X DELETE > /dev/null 2>&1 || true
  fi
  echo "[INFO] Stub cluster deleted."

  # Clean ALL HDFS on-disk state for a clean retry.
  #
  # When a previous import formatted the NameNode and then failed later (e.g.
  # Kafka KRaft error), we end up with:
  #   - NameNode dirs:  formatted with cluster ID X
  #   - DataNode dirs:  VERSION files still referencing cluster ID X
  # On retry, HDFS format creates a NEW cluster ID Y.  The DataNode then
  # rejects the NameNode because X != Y and crashes ("Supervisor FATAL").
  #
  # Fix: clean NameNode, Secondary NameNode, AND DataNode directories so all
  # sides start fresh with the same new cluster ID after format.
  # Safe here because we confirmed the cluster is a stub (CORE_SETTINGS only).
  echo "[INFO] Cleaning HDFS on-disk state (NN + SNN + DN) for clean retry ..."
  for _hdfs_dir in \
      "/dfs/nn" "/dfs/snn" "/dfs/dn" \
      "/var/lib/hadoop-hdfs/cache/hdfs/dfs/namenode" \
      "/var/lib/hadoop-hdfs/cache/hdfs/dfs/namesecondary" \
      "/var/lib/hadoop-hdfs/cache/hdfs/dfs/data"; do
    if [[ -d "${_hdfs_dir}" ]]; then
      rm -rf "${_hdfs_dir}"
      echo "[INFO]   Removed: ${_hdfs_dir}"
    fi
  done

  # Wait for CM to finish any residual parcel distribution that was started by
  # the previous import.  Parcel distribution runs against the hosts, not the
  # cluster object, so it survives cluster deletion.  Starting a new import
  # while a distribution is still running causes "concurrent action" errors.
  echo "[INFO] Waiting for any residual parcel operations to clear (up to 180s) ..."
  sleep 120
fi

# ---------------------------------------------------------------------------
# Wait for CM parcel operations to be idle before starting the import
# ---------------------------------------------------------------------------
# CM's parcel distribution locks are global.  If a previous import left a
# distribution in-flight, the new import will fail immediately with a
# "concurrent action" error.  Poll for up to 3 minutes until no parcel is
# in a transitional state (DOWNLOADING / DISTRIBUTING / ACTIVATING).

_wait_parcels_idle() {
  local waited=0
  local max_wait=180
  local transitional_re="DOWNLOADING|DISTRIBUTING|ACTIVATING|UNDISTRIBUTING|DEACTIVATING"
  echo "[INFO] Checking for active parcel operations ..."
  while [[ "${waited}" -lt "${max_wait}" ]]; do
    # Query parcels from any visible cluster; if none exist yet just proceed
    local busy
    busy=$(cm_curl "${CM_API_BASE}/clusters" 2>/dev/null \
      | jq -r '.items[].name' 2>/dev/null \
      | while IFS= read -r cname; do
          local enc
          enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${cname}")
          cm_curl "${CM_API_BASE}/clusters/${enc}/parcels" 2>/dev/null \
            | jq -r ".items[]? | select(.stage | test(\"${transitional_re}\")) | .product + \" \" + .version" 2>/dev/null
        done) || true

    if [[ -z "${busy}" ]]; then
      echo "[INFO] No active parcel operations detected."
      return 0
    fi

    echo "[INFO] Parcel operations still running: ${busy}"
    sleep 15
    waited=$((waited + 15))
  done
  echo "[WARN] Parcel operations did not clear within ${max_wait}s — proceeding anyway."
}

_wait_parcels_idle

# ---------------------------------------------------------------------------
# Import cluster template
# ---------------------------------------------------------------------------

echo "[INFO] Importing cluster template ..."
echo "[INFO] Parcels should already be pre-staged in /opt/cloudera/parcel-repo."

IMPORT_RESP=$(cm_curl \
  "${CM_API_BASE}/cm/importClusterTemplate?addRepositories=true" \
  -X POST \
  --data-binary "@${GENERATED_TEMPLATE}")

CMD_ID=$(echo "${IMPORT_RESP}" | jq -r '.id // empty' 2>/dev/null || true)

if [[ -z "${CMD_ID}" ]]; then
  echo "[ERROR] No command ID returned from importClusterTemplate." >&2
  echo "[ERROR] CM response: ${IMPORT_RESP}" >&2
  exit 1
fi

echo "[INFO] Deployment command ID: ${CMD_ID}"

# ---------------------------------------------------------------------------
# Wait with retry  (mirrors edge2ai create_cluster.py create_cluster())
#
# CM's retry API re-attempts only failed sub-commands.  Services that
# already started are skipped, so each retry makes forward progress.
# Between retries we restart Management Services to clear stale state —
# exactly what edge2ai does before each retry attempt.
# ---------------------------------------------------------------------------

_apply_kafka_fixes() {
  local api_base="${1:-${CM_API_BASE}}"
  local cluster="${2:-${CLUSTER_ENCODED}}"

  # Fix 1: CM defaults metadata.store to KRaft; ZooKeeper mode is required here.
  cm_curl \
    "${api_base}/clusters/${cluster}/services/kafka/roleConfigGroups/kafka-KAFKA_BROKER-BASE/config" \
    -X PUT \
    -d '{"items": [{"name": "metadata.store", "value": "Zookeeper"}]}' \
    > /dev/null 2>&1 || true

  # Fix 2: zookeeper.secure.connection.enable must match ZooKeeper's actual
  # TLS setting — query it dynamically so this works with and without TLS.
  local zk_tls
  zk_tls=$(cm_curl "${api_base}/clusters/${cluster}/services/zookeeper/config" 2>/dev/null \
    | jq -r '(.items // []) | map(select(.name == "zookeeper_tls_enabled")) | .[0].value // ""' \
    2>/dev/null || echo "")
  case "${zk_tls}" in
    true|True|TRUE) zk_tls="true" ;;
    *)              zk_tls="false" ;;
  esac
  echo "[INFO] ZooKeeper TLS=${zk_tls} → Kafka zookeeper.secure.connection.enable=${zk_tls}"
  cm_curl \
    "${api_base}/clusters/${cluster}/services/kafka/config" \
    -X PUT \
    -d "{\"items\": [{\"name\": \"zookeeper.secure.connection.enable\", \"value\": \"${zk_tls}\"}]}" \
    > /dev/null 2>&1 || true
}

_recover_start_services() {
  echo "[INFO] Pre-start: applying Kafka config fixes ..."
  _apply_kafka_fixes "${CM_API_BASE}" "${CLUSTER_ENCODED}"

  # Start services in dependency order.  Per-service start (not firstRun)
  # skips HDFS re-format and Kafka KRaft init — both fail when services
  # already have data from a previous deployment attempt.
  local services=(zookeeper hdfs yarn queuemanager hive hive_on_tez kafka impala hue nifi nifiregistry flink sql_stream_builder)

  for svc in "${services[@]}"; do
    local state
    state=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/${svc}" \
      | jq -r '.serviceState // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

    case "${state}" in
      STARTED)
        echo "[INFO]   ${svc}: already STARTED"
        ;;
      STOPPED)
        echo "[INFO]   ${svc}: starting ..."
        local cmd_id
        cmd_id=$(cm_curl \
          "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/${svc}/commands/start" \
          -X POST | jq -r '.id // empty' 2>/dev/null || true)
        if [[ -n "${cmd_id}" ]]; then
          wait_for_command "${CM_API_BASE}" "${cmd_id}" 300 || \
            echo "[WARN]   ${svc} start did not complete cleanly — check CM UI"
        else
          echo "[WARN]   ${svc}: start command returned no ID"
        fi
        ;;
      NA)
        echo "[INFO]   ${svc}: NA (gateway-only, no start needed)"
        ;;
      *)
        echo "[INFO]   ${svc}: state=${state} — skipping"
        ;;
    esac
  done
}

RETRIES=0
while true; do
  if wait_for_command "${CM_API_BASE}" "${CMD_ID}" 7200; then
    echo "[INFO] Cluster deployment succeeded."
    break
  fi

  # Command failed
  if [[ "${RETRIES}" -ge "${MAX_IMPORT_RETRIES}" ]]; then
    echo "[WARN] Template import failed after ${MAX_IMPORT_RETRIES} retries."

    # Check whether services exist (import got past parcel + template apply phases)
    # vs a stub cluster (import failed before services were created).
    SERVICE_COUNT=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services" \
      | jq '[.items[] | select(.type != "CORE_SETTINGS")] | length' 2>/dev/null || echo "0")

    if [[ "${SERVICE_COUNT}" -gt 0 ]]; then
      echo "[INFO] ${SERVICE_COUNT} service(s) exist — entering recovery mode."
      echo "[INFO] Starting services individually to bypass firstRun format/init issues."
      echo "[INFO] This handles both:"
      echo "[INFO]   - Fresh first run where Kafka KRaft default caused failure"
      echo "[INFO]   - Retry after cluster delete where HDFS is already formatted"
      _recover_start_services
    else
      echo "[ERROR] No services deployed (stub cluster). Import failed before service creation." >&2
      echo "[ERROR] Check CM UI for the root cause (likely a parcel or template error)." >&2
      cm_curl "${CM_API_BASE}/commands/${CMD_ID}" | jq -r '
        .children.items[]?
        | select(.success == false and .active == false)
        | "  [FAILED] \(.name) service=\(.serviceRef.serviceName // "-") msg=\(.resultMessage // "")"
      ' 2>/dev/null || true
      exit 1
    fi
    break
  fi

  RETRIES=$((RETRIES + 1))
  echo ""
  echo "[WARN] ============================================================"
  echo "[WARN] Deployment attempt failed.  Starting retry ${RETRIES}/${MAX_IMPORT_RETRIES}."
  echo "[WARN] Restarting Management Services to clear stale state ..."
  echo "[WARN] ============================================================"

  MGMT_RESTART_RESP=$(cm_curl "${CM_API_BASE}/cm/service/commands/restart" -X POST)
  MGMT_RESTART_ID=$(echo "${MGMT_RESTART_RESP}" | jq -r '.id // empty' 2>/dev/null || true)
  if [[ -n "${MGMT_RESTART_ID}" ]]; then
    wait_for_command "${CM_API_BASE}" "${MGMT_RESTART_ID}" 300 || true
  fi

  # Apply known config fixes before every retry so they are in place when
  # CM re-attempts the failed sub-commands.
  echo "[INFO] Pre-retry: applying Kafka config fixes ..."
  _apply_kafka_fixes "${CM_API_BASE}" "${CLUSTER_ENCODED}"

  echo "[INFO] Waiting 120s for CM parcel operations to clear before retry ..."
  sleep 120

  # CM retry: re-attempts only the failed sub-commands
  RETRY_RESP=$(cm_curl "${CM_API_BASE}/commands/${CMD_ID}/retry" -X POST)
  CMD_ID=$(echo "${RETRY_RESP}" | jq -r '.id // empty' 2>/dev/null || true)

  if [[ -z "${CMD_ID}" ]]; then
    echo "[ERROR] Could not get retry command ID from CM." >&2
    exit 1
  fi
  echo "[INFO] Retry command ID: ${CMD_ID}"
done

# ---------------------------------------------------------------------------
# Post-deploy: configure SQL Stream Builder database
#
# The SSB datasource property names are not known ahead of time — they vary
# by CSD version and are not the same as the Spring Boot application keys.
# We discover them by querying the STREAMING_SQL_ENGINE role config group
# after it exists, find the DB-related properties, set them, then restart SSB.
# ---------------------------------------------------------------------------

echo "[INFO] Configuring SQL Stream Builder database ..."

SSB_ROLE_GROUP="sql_stream_builder-STREAMING_SQL_ENGINE-BASE"
SSB_CONFIG_URL="${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/sql_stream_builder/roleConfigGroups/${SSB_ROLE_GROUP}/config"

# Discover which DB property names actually exist in this CSD version
SSB_CONFIG_FULL=$(cm_curl "${SSB_CONFIG_URL}?view=full" 2>/dev/null || echo "")

SSB_DB_PROPS=$(echo "${SSB_CONFIG_FULL}" | jq -r '
  .items[]?
  | select(.name | test("datasource|database|jdbc|postgres"; "i"))
  | .name
' 2>/dev/null || echo "")

if [[ -z "${SSB_DB_PROPS}" ]]; then
  echo "[WARN] No datasource/database properties found on ${SSB_ROLE_GROUP}."
  echo "[WARN] SSB database must be configured manually in CM after deployment."
  echo "[WARN] Available SSB role properties (first 20):"
  echo "${SSB_CONFIG_FULL}" | jq -r '.items[].name' 2>/dev/null | head -20 | sed 's/^/[WARN]   /' || true
else
  echo "[INFO] Discovered SSB DB properties: $(echo "${SSB_DB_PROPS}" | tr '\n' ' ')"

  # Build config items dynamically from the discovered property names
  SSB_CONFIG_ITEMS=$(echo "${SSB_DB_PROPS}" | python3 - \
    "${DB_HOST}" "${DB_PORT}" "${SSB_DB_NAME}" "${SSB_DB_USER}" "${SSB_DB_PASS}" <<'PYEOF'
import sys, json

props = sys.stdin.read().split()
host, port, dbname, user, password = sys.argv[1:6]
jdbc_url = f"jdbc:postgresql://{host}:{port}/{dbname}"

mapping = {}
for p in props:
    pl = p.lower()
    if 'url'      in pl: mapping[p] = jdbc_url
    elif 'user'   in pl and 'password' not in pl: mapping[p] = user
    elif 'pass'   in pl: mapping[p] = password
    elif 'name'   in pl or 'database' in pl: mapping[p] = dbname
    elif 'host'   in pl: mapping[p] = host
    elif 'port'   in pl: mapping[p] = port
    elif 'driver' in pl: mapping[p] = "org.postgresql.Driver"

items = [{"name": k, "value": v} for k, v in mapping.items()]
print(json.dumps({"items": items}))
PYEOF
  )

  echo "[INFO] Setting SSB database config ..."
  SSB_SET_RESP=$(cm_curl "${SSB_CONFIG_URL}" -X PUT -d "${SSB_CONFIG_ITEMS}")

  if echo "${SSB_SET_RESP}" | jq -e '.message' &>/dev/null; then
    echo "[WARN] SSB database config response: $(echo "${SSB_SET_RESP}" | jq -r '.message')"
  else
    echo "[INFO] SSB database configured."

    # Restart SSB so it picks up the new datasource settings
    echo "[INFO] Restarting SQL Stream Builder ..."
    SSB_RESTART=$(cm_curl \
      "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/sql_stream_builder/commands/restart" \
      -X POST)
    SSB_RESTART_ID=$(echo "${SSB_RESTART}" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -n "${SSB_RESTART_ID}" ]]; then
      wait_for_command "${CM_API_BASE}" "${SSB_RESTART_ID}" 300 || \
        echo "[WARN] SSB restart did not complete cleanly — check CM UI."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Full cluster restart
# Restarts all services in dependency order so everything comes up clean
# after all configuration changes (Kafka metadata store, SSB database, etc.)
# ---------------------------------------------------------------------------

echo "[INFO] Restarting cluster '${CLUSTER_NAME}' ..."
CLUSTER_RESTART_RESP=$(cm_curl \
  "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/commands/restart" -X POST)
CLUSTER_RESTART_ID=$(echo "${CLUSTER_RESTART_RESP}" | jq -r '.id // empty' 2>/dev/null || true)

if [[ -n "${CLUSTER_RESTART_ID}" && "${CLUSTER_RESTART_ID}" != "null" ]]; then
  wait_for_command "${CM_API_BASE}" "${CLUSTER_RESTART_ID}" 3600 || \
    echo "[WARN] Cluster restart did not complete cleanly — check CM UI."
else
  echo "[WARN] Could not get cluster restart command ID."
fi

# ---------------------------------------------------------------------------
# Post-deploy: restart Management Services (picks up new cluster metrics)
# ---------------------------------------------------------------------------

echo "[INFO] Restarting Cloudera Management Services ..."
MGMT_RESP=$(cm_curl "${CM_API_BASE}/cm/service/commands/restart" -X POST)
MGMT_ID=$(echo "${MGMT_RESP}" | jq -r '.id // empty' 2>/dev/null || true)
if [[ -n "${MGMT_ID}" && "${MGMT_ID}" != "null" ]]; then
  wait_for_command "${CM_API_BASE}" "${MGMT_ID}" 300 || true
fi

# ---------------------------------------------------------------------------
# Clear paywall credentials
# ---------------------------------------------------------------------------

echo "[INFO] Clearing paywall credentials from CM ..."
cm_curl "${CM_API_BASE}/cm/config" -X PUT \
  -d '{"items": [
        {"name": "REMOTE_REPO_OVERRIDE_USER",     "value": ""},
        {"name": "REMOTE_REPO_OVERRIDE_PASSWORD", "value": ""}
      ]}' > /dev/null

echo "[INFO] 05_deploy_cluster: complete."
echo "[INFO] Run 06_validate_runtime.sh to verify service health."
