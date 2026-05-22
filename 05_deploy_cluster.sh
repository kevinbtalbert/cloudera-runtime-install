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

# Post-process: strip excluded services/products/repos based on feature flags
echo "[INFO] Feature flags: INCLUDE_NIFI=${INCLUDE_NIFI:-true}  INCLUDE_SSB_FLINK=${INCLUDE_SSB_FLINK:-true}"
python3 - "${GENERATED_TEMPLATE}" "${INCLUDE_NIFI:-true}" "${INCLUDE_SSB_FLINK:-true}" <<'FILTER_PY'
import json, sys
tmpl, inc_nifi, inc_ssb = sys.argv[1], sys.argv[2].lower()=='true', sys.argv[3].lower()=='true'
with open(tmpl) as f: d = json.load(f)
excl_types = set()
excl_prod  = set()
if not inc_nifi: excl_types |= {'NIFI','NIFIREGISTRY'}; excl_prod.add('CFM')
if not inc_ssb:  excl_types |= {'FLINK','SQL_STREAM_BUILDER'}; excl_prod.add('FLINK')
if not excl_types: sys.exit(0)
excl_refs = {rg['refName'] for s in d.get('services',[]) if s.get('serviceType') in excl_types
             for rg in s.get('roleConfigGroups',[])}
d['services']    = [s for s in d.get('services',[])    if s.get('serviceType') not in excl_types]
d['products']    = [p for p in d.get('products',[])    if p.get('product')     not in excl_prod]
d['repositories']= [r for r in d.get('repositories',[])
                    if not(not inc_nifi and 'cfm' in r.lower())
                    if not(not inc_ssb  and '/csa/' in r.lower())]
for ht in d.get('hostTemplates',[]):
    ht['roleConfigGroupsRefNames']=[r for r in ht.get('roleConfigGroupsRefNames',[]) if r not in excl_refs]
with open(tmpl,'w') as f: json.dump(d,f,indent=2)
print('[INFO] Removed services:', ', '.join(sorted(excl_types)))
FILTER_PY

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
# Pre-import preparation
#
# EVERYTHING below runs BEFORE importClusterTemplate is submitted.
# Once the import starts it cannot be influenced — all state must be correct.
# ---------------------------------------------------------------------------

CLUSTER_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${CLUSTER_NAME}")

# Helper: clean comma-separated HDFS directories
_clean_hdfs_dirs() {
  local dir_list="$1"
  IFS=',' read -ra _dirs <<< "${dir_list}"
  for _d in "${_dirs[@]}"; do
    _d="${_d// /}"
    [[ -z "${_d}" ]] && continue
    if [[ -d "${_d}" ]]; then
      rm -rf "${_d}"
      echo "[INFO]   Cleaned: ${_d}"
    fi
  done
}

# Default HDFS dir paths (overridden below if cluster exists in CM)
_hdfs_nn_dirs="/dfs/nn"
_hdfs_snn_dirs="/dfs/snn"
_hdfs_dn_dirs="/dfs/dn"

CLUSTER_STATUS=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}"   -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

if [[ "${CLUSTER_STATUS}" == "200" ]]; then
  SERVICE_COUNT=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services"     | jq '[.items[] | select(.type != "CORE_SETTINGS")] | length' 2>/dev/null || echo "0")

  if [[ "${SERVICE_COUNT}" -gt 0 ]]; then
    echo "[INFO] Cluster '${CLUSTER_NAME}' already exists with ${SERVICE_COUNT} deployed service(s)."
    echo "[INFO] Skipping template import.  Delete the cluster in CM to redeploy from scratch."
    exit 0
  fi

  echo "[WARN] Stub cluster detected.  Querying HDFS paths before deletion ..."

  # Query actual HDFS paths BEFORE deleting (while CM service configs are queryable)
  _hdfs_nn_dirs=$(cm_curl     "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/hdfs/roleConfigGroups/hdfs-NAMENODE-BASE/config"     2>/dev/null | jq -r '(.items//[]) | map(select(.name=="dfs_name_dir_list")) | .[0].value // "/dfs/nn"'     2>/dev/null || echo "/dfs/nn")
  _hdfs_snn_dirs=$(cm_curl     "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/hdfs/roleConfigGroups/hdfs-SECONDARYNAMENODE-BASE/config"     2>/dev/null | jq -r '(.items//[]) | map(select(.name=="fs_checkpoint_dir_list")) | .[0].value // "/dfs/snn"'     2>/dev/null || echo "/dfs/snn")
  _hdfs_dn_dirs=$(cm_curl     "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/hdfs/roleConfigGroups/hdfs-DATANODE-BASE/config"     2>/dev/null | jq -r '(.items//[]) | map(select(.name=="dfs_data_dir_list")) | .[0].value // "/dfs/dn"'     2>/dev/null || echo "/dfs/dn")

  # Now delete the stub cluster
  cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/commands/stop" -X POST > /dev/null 2>&1 || true
  sleep 5
  DELETE_RESP=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}" -X DELETE)
  if echo "${DELETE_RESP}" | jq -e '.message' &>/dev/null; then
    sleep 15
    cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}" -X DELETE > /dev/null 2>&1 || true
  fi
  echo "[INFO] Stub cluster deleted."
fi

# ---------------------------------------------------------------------------
# On-disk state cleanup — runs BEFORE importClusterTemplate is submitted.
#
# FAILURE RECOVERY: If deployment fails and you need to start over:
#   1. Delete the cluster in CM (or let this script detect it as a stub)
#   2. Run this script again — it detects and cleans stale on-disk state
#   3. Do NOT intervene once importClusterTemplate is running
#
# Manual recovery (run as root on the cluster host if the script can't clean):
#   rm -rf /dfs/nn /dfs/snn /dfs/dn /var/lib/zookeeper
#   Then delete the cluster in CM and re-run this script.
#
# What is cleaned and why:
#
#   HDFS (NN + SNN + DN): a previous import may have formatted HDFS and then
#   failed on a later service (e.g. Kafka config).  The next import refuses to
#   re-format non-empty dirs.  NN+SNN+DN must be cleaned together — a cluster
#   ID mismatch between them causes DataNode "Supervisor FATAL" crash loops.
#
#   ZooKeeper data dir: ZooKeeper persists state across restarts.  Stale Kafka
#   chroot data (/kafka/cluster/id, /kafka/brokers, etc.) from a previous
#   deployment survives into the next firstRun and can cause Kafka broker
#   startup failures.  Cleaning ZooKeeper ensures a truly fresh start.
# ---------------------------------------------------------------------------

echo "[INFO] Pre-import: checking on-disk state ..."
echo "[INFO]   HDFS NN dirs:   ${_hdfs_nn_dirs}"
echo "[INFO]   HDFS SNN dirs:  ${_hdfs_snn_dirs}"
echo "[INFO]   HDFS DN dirs:   ${_hdfs_dn_dirs}"

# ZooKeeper and Kafka data dirs (query from CM while cluster exists, else use defaults)
_zk_data_dir="/var/lib/zookeeper"
_kafka_log_dirs="/var/local/kafka/data"
if [[ "${CLUSTER_STATUS}" == "200" ]]; then
  _zk_data_dir_queried=$(cm_curl \
    "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/zookeeper/roleConfigGroups/zookeeper-SERVER-BASE/config" \
    2>/dev/null | jq -r '(.items//[]) | map(select(.name=="dataDir")) | .[0].value // ""' \
    2>/dev/null || echo "")
  [[ -n "${_zk_data_dir_queried}" ]] && _zk_data_dir="${_zk_data_dir_queried}"

  _kafka_log_dirs_queried=$(cm_curl \
    "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services/kafka/roleConfigGroups/kafka-KAFKA_BROKER-BASE/config" \
    2>/dev/null | jq -r '(.items//[]) | map(select(.name=="log.dirs")) | .[0].value // ""' \
    2>/dev/null || echo "")
  [[ -n "${_kafka_log_dirs_queried}" ]] && _kafka_log_dirs="${_kafka_log_dirs_queried}"
fi
echo "[INFO]   ZooKeeper data: ${_zk_data_dir}"
echo "[INFO]   Kafka log.dirs: ${_kafka_log_dirs}"

_needs_clean=false
IFS=',' read -ra _nn_check_arr <<< "${_hdfs_nn_dirs}"
for _d in "${_nn_check_arr[@]}"; do
  _d="${_d// /}"
  if [[ -d "${_d}/current" ]]; then
    echo "[WARN] Stale HDFS data found at ${_d}/current — will clean NN+SNN+DN+ZK."
    _needs_clean=true
    break
  fi
done

_recreate_db() {
  # Drop and recreate a PostgreSQL database to clear stale migration/schema state.
  local db_name="$1" db_owner="$2"
  echo "[INFO]   Recreating database '${db_name}' (owner ${db_owner}) ..."
  ( cd /tmp && sudo -u postgres psql -Atc \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db_name}' AND pid<>pg_backend_pid();" \
    2>/dev/null ) || true
  ( cd /tmp && sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null ) || true
  ( cd /tmp && sudo -u postgres psql -c \
    "CREATE DATABASE ${db_name} OWNER ${db_owner} ENCODING 'UTF8';" 2>/dev/null ) || true
}

if [[ "${_needs_clean}" == "true" ]]; then
  _clean_hdfs_dirs "${_hdfs_nn_dirs}"
  _clean_hdfs_dirs "${_hdfs_snn_dirs}"
  _clean_hdfs_dirs "${_hdfs_dn_dirs}"
  if [[ -d "${_zk_data_dir}" ]]; then
    rm -rf "${_zk_data_dir}"
    echo "[INFO]   Cleaned ZooKeeper: ${_zk_data_dir}"
  fi
  # Clean Kafka data dirs: after ZooKeeper is wiped, Kafka gets a new cluster ID.
  # If the Kafka log.dirs contain old meta.properties with the previous cluster ID,
  # Kafka refuses to start (cluster ID mismatch).  Must clean together with ZK.
  _clean_hdfs_dirs "${_kafka_log_dirs}"
  echo "[INFO]   Cleaned Kafka log.dirs: ${_kafka_log_dirs}"

  # Clean Queue Manager H2 fallback database.
  # The YARN Queue Manager Store uses a jceks-encrypted PostgreSQL password.
  # When jceks decryption fails it falls back to an embedded H2 database at
  # /var/lib/hadoop-yarn/config-service.mv.db  If that file exists from a
  # previous deployment with a different password the service crashes with
  # "Wrong user name or password [28000]".
  for _qm_h2 in "/var/lib/hadoop-yarn/config-service.mv.db" \
                "/var/lib/hadoop-yarn/config-service.trace.db"; do
    if [[ -f "${_qm_h2}" ]]; then
      rm -f "${_qm_h2}"
      echo "[INFO]   Cleaned QueueManager H2: ${_qm_h2}"
    fi
  done

  # Recreate service databases to clear stale Django migration locks (Hue),
  # stale schema state from NiFi Registry, Hive Metastore, and SSB.
  # scm and rman are NOT recreated — CM server owns scm; rman is managed by CMS.
  echo "[INFO] Recreating service databases to clear stale migration state ..."
  _recreate_db "${HUE_DB_NAME}"  "${HUE_DB_USER}"
  [[ "${INCLUDE_NIFI:-true}"     == "true" ]] && _recreate_db "${REG_DB_NAME}"  "${REG_DB_USER}"
  _recreate_db "${HIVE_DB_NAME}" "${HIVE_DB_USER}"
  [[ "${INCLUDE_SSB_FLINK:-true}" == "true" ]] && _recreate_db "${SSB_DB_NAME}" "${SSB_DB_USER}"

  echo "[INFO] On-disk and database state cleaned — ready for fresh import."
else
  echo "[INFO] On-disk state is clean."
fi

# Wait for residual parcel operations from any previous import to clear before
# starting a new one (concurrent parcel distribution causes "concurrent action" errors).
echo "[INFO] Waiting 120s for residual parcel operations to clear ..."
sleep 120
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
  # Also disable ZooKeeper SASL auth — both default to KRaft/true and break
  # Kafka in non-Kerberos setups.
  cm_curl \
    "${api_base}/clusters/${cluster}/services/kafka/roleConfigGroups/kafka-KAFKA_BROKER-BASE/config" \
    -X PUT \
    -d '{"items": [
      {"name": "metadata.store",                  "value": "Zookeeper"},
      {"name": "authenticate.zookeeper.connection","value": "false"},
      {"name": "zookeeper.set.acl",               "value": "false"}
    ]}' \
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
  echo "[INFO] Applying Kafka config fixes ..."
  _apply_kafka_fixes "${CM_API_BASE}" "${CLUSTER_ENCODED}"

  echo "[INFO] Starting cluster (CM handles dependency order) ..."
  local start_resp start_id
  start_resp=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/commands/restart" -X POST)
  start_id=$(echo "${start_resp}" | jq -r '.id // empty' 2>/dev/null || true)
  if [[ -n "${start_id}" ]]; then
    wait_for_command "${CM_API_BASE}" "${start_id}" 3600 || \
      echo "[WARN] Cluster start did not complete cleanly — check CM UI."
  else
    echo "[WARN] Could not get cluster start command ID."
  fi
}

_is_hdfs_already_formatted_failure() {
  # Returns 0 if the import failed because HDFS namenode dirs are not empty
  # (retry scenario where HDFS is already formatted from a previous run).
  # In that case there is no point retrying the full import — go straight to
  # _recover_start_services which starts services individually without format.
  local cmd_id="$1"
  local msg
  msg=$(cm_curl "${CM_API_BASE}/commands/${cmd_id}" 2>/dev/null \
    | jq -r '[.. | objects | .resultMessage? // empty] | join(" ")' \
    2>/dev/null | head -c 2000)
  echo "${msg}" | grep -qi "not formatting\|not empty\|already formatted\|data appears to exist" \
    && return 0
  return 1
}

RETRIES=0
while true; do
  if wait_for_command "${CM_API_BASE}" "${CMD_ID}" 7200; then
    echo "[INFO] Cluster deployment succeeded."
    break
  fi

  # Fast-path: if HDFS refused to format (dirs not empty from a previous
  # deployment), retrying importClusterTemplate will always fail the same way.
  # Skip straight to service-by-service recovery instead.
  _SVC_COUNT_FAST=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_ENCODED}/services" \
    | jq '[.items[] | select(.type != "CORE_SETTINGS")] | length' 2>/dev/null || echo "0")
  if [[ "${_SVC_COUNT_FAST}" -gt 0 ]] && _is_hdfs_already_formatted_failure "${CMD_ID}"; then
    echo "[WARN] HDFS already-formatted failure detected — skipping retries."
    echo "[WARN] Starting services individually (bypasses HDFS re-format)."
    _recover_start_services
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

echo "[INFO] 05_deploy_cluster: complete."
echo "[INFO] Run 06_validate_runtime.sh to verify service health."
