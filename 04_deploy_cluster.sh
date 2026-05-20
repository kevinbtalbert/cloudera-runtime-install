#!/usr/bin/env bash
# ==============================================================================
# 04_deploy_cluster.sh
# Deploys the CDP Runtime cluster and CFM (NiFi / NiFi Registry) services by:
#   1. Validating required variables
#   2. Substituting environment variables into the cluster template
#   3. Checking whether the cluster already exists
#   4. Importing the cluster template via the CM importClusterTemplate API
#   5. Polling the deployment command until it completes
#
# The cluster template (templates/cluster.json.tmpl) covers:
#   CDP services: ZooKeeper, HDFS, YARN, Tez, Hive Metastore, Hive on Tez, Hue
#   CFM services: NiFi, NiFi Registry (with PostgreSQL)
#   CSA services: Flink, SQL Stream Builder (with PostgreSQL)
#
# Parcels are downloaded, distributed, and activated automatically by CM
# when addRepositories=true is set on the import.
#
# Typical runtime: 30-90 minutes depending on network speed and parcel sizes.
# Runs on the Cloudera Manager host.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "04_deploy_cluster"
need_root
require_cmd curl
require_cmd jq
require_cmd envsubst

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
# Generate the cluster template from the template file
# ---------------------------------------------------------------------------

TEMPLATE_FILE="${SCRIPT_DIR}/templates/cluster.json.tmpl"
GENERATED_TEMPLATE="/tmp/cluster_${CLUSTER_NAME}.json"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "[ERROR] Template file not found: ${TEMPLATE_FILE}" >&2
  exit 1
fi

echo "[INFO] Generating cluster template -> ${GENERATED_TEMPLATE} ..."

# Explicit variable list prevents envsubst from clobbering unrelated
# shell variables that happen to match ${...} patterns in the JSON.
SUBST_VARS='${CLUSTER_NAME}${CLUSTER_HOST}${CDH_VERSION}${CDH_BUILD}${CDH_PARCEL_REPO}${CM_VERSION}${CFM_BUILD}${CFM_PARCEL_REPO_URL}${CSA_FLINK_BUILD}${CSA_PARCEL_REPO}${DB_HOST}${DB_PORT}${HIVE_DB_NAME}${HIVE_DB_USER}${HIVE_DB_PASS}${HUE_DB_NAME}${HUE_DB_USER}${HUE_DB_PASS}${REG_DB_NAME}${REG_DB_USER}${REG_DB_PASS}${SSB_DB_NAME}${SSB_DB_USER}${SSB_DB_PASS}${NIFI_JAVA_HOME}'

envsubst "${SUBST_VARS}" < "${TEMPLATE_FILE}" > "${GENERATED_TEMPLATE}"

# Validate JSON before sending to CM
if ! jq . "${GENERATED_TEMPLATE}" > /dev/null 2>&1; then
  echo "[ERROR] Generated template is not valid JSON: ${GENERATED_TEMPLATE}" >&2
  exit 1
fi
echo "[INFO] Template JSON is valid."

# ---------------------------------------------------------------------------
# Derive CM API base URL
# ---------------------------------------------------------------------------

wait_for_cm 60

CM_API_VERSION="$(cm_api_version)"
CM_API_BASE="http://${MANAGER_HOST}:7180/api/${CM_API_VERSION}"
echo "[INFO] Using CM API: ${CM_API_BASE}"

# ---------------------------------------------------------------------------
# Check whether the cluster already exists
# ---------------------------------------------------------------------------

CLUSTER_STATUS=$(cm_curl \
  "${CM_API_BASE}/clusters/$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${CLUSTER_NAME}")" \
  -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

if [[ "${CLUSTER_STATUS}" == "200" ]]; then
  echo "[INFO] Cluster '${CLUSTER_NAME}' already exists in CM.  Skipping template import."
  echo "[INFO] To re-deploy, delete the cluster in CM and re-run this script."
  exit 0
fi

# ---------------------------------------------------------------------------
# Import cluster template
# ---------------------------------------------------------------------------

echo "[INFO] Importing cluster template (this drives parcel download + service deployment) ..."
echo "[INFO] This step typically takes 30-90 minutes.  Do not interrupt the process."

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
# Wait for deployment to complete (up to 2 hours)
# ---------------------------------------------------------------------------

wait_for_command "${CM_API_BASE}" "${CMD_ID}" 7200

# ---------------------------------------------------------------------------
# Restart Management Services after cluster is up
# ---------------------------------------------------------------------------

echo "[INFO] Restarting Cloudera Management Services ..."
MGMT_CMD_RESP=$(cm_curl "${CM_API_BASE}/cm/service/commands/restart" -X POST)
MGMT_CMD_ID=$(echo "${MGMT_CMD_RESP}" | jq -r '.id // empty' 2>/dev/null || true)

if [[ -n "${MGMT_CMD_ID}" && "${MGMT_CMD_ID}" != "null" ]]; then
  wait_for_command "${CM_API_BASE}" "${MGMT_CMD_ID}" 300
else
  echo "[WARN] Could not retrieve Management Services restart command ID."
fi

# ---------------------------------------------------------------------------
# Clear paywall credentials from CM config
# ---------------------------------------------------------------------------

echo "[INFO] Clearing paywall credentials from CM config ..."
cm_curl "${CM_API_BASE}/cm/config" \
  -X PUT \
  -d '{"items": [
        {"name": "REMOTE_REPO_OVERRIDE_USER",     "value": ""},
        {"name": "REMOTE_REPO_OVERRIDE_PASSWORD", "value": ""}
      ]}' \
  > /dev/null

echo "[INFO] 04_deploy_cluster: complete."
echo "[INFO] CDP cluster '${CLUSTER_NAME}' is deployed.  Run 05_validate_runtime.sh to verify."
