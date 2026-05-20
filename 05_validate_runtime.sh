#!/usr/bin/env bash
# ==============================================================================
# 05_validate_runtime.sh
# Validates the deployed CDP + CFM cluster by:
#   - Querying CM for the cluster and service health status
#   - Verifying key TCP ports are open
#   - Printing a summary of service URLs
#
# Read-only: makes no changes to the cluster or host configuration.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_cmd curl
require_cmd jq

PASS=0
WARN=0
FAIL=0

ok()   { echo "[  OK  ] $*"; PASS=$((PASS+1)); }
warn() { echo "[ WARN ] $*"; WARN=$((WARN+1)); }
fail() { echo "[ FAIL ] $*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# CM readiness
# ---------------------------------------------------------------------------

echo ""
echo "=== Cloudera Manager ==="

CM_CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
          -u "${CM_ADMIN_USER:-admin}:${CM_ADMIN_PASS:-admin}" \
          "http://${MANAGER_HOST}:7180/api/version" 2>/dev/null || echo "000")
if [[ "${CM_CODE}" == "200" ]]; then
  ok "CM HTTP API responding on :7180"
else
  fail "CM HTTP API not responding (HTTP ${CM_CODE})"
fi

# ---------------------------------------------------------------------------
# CM API setup
# ---------------------------------------------------------------------------

CM_API_VERSION="$(cm_api_version)"
CM_API_BASE="http://${MANAGER_HOST}:7180/api/${CM_API_VERSION}"

# ---------------------------------------------------------------------------
# Cluster health
# ---------------------------------------------------------------------------

echo ""
echo "=== Cluster Health ==="

CLUSTER_RESP=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_NAME}" 2>/dev/null || true)
CLUSTER_STATE=$(echo "${CLUSTER_RESP}" | jq -r '.entityStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

if [[ "${CLUSTER_STATE}" == "GOOD_HEALTH" ]]; then
  ok "Cluster '${CLUSTER_NAME}' entity status: ${CLUSTER_STATE}"
elif [[ "${CLUSTER_STATE}" == "CONCERNING_HEALTH" ]]; then
  warn "Cluster '${CLUSTER_NAME}' entity status: ${CLUSTER_STATE}"
else
  fail "Cluster '${CLUSTER_NAME}' entity status: ${CLUSTER_STATE}"
fi

# ---------------------------------------------------------------------------
# Service health
# ---------------------------------------------------------------------------

echo ""
echo "=== Service Health ==="

SERVICES_RESP=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_NAME}/services" 2>/dev/null || true)

while IFS= read -r line; do
  SVC_NAME=$(echo "${line}" | cut -d'|' -f1)
  SVC_TYPE=$(echo "${line}" | cut -d'|' -f2)
  SVC_STATE=$(echo "${line}" | cut -d'|' -f3)
  SVC_HEALTH=$(echo "${line}" | cut -d'|' -f4)

  case "${SVC_STATE}" in
    STARTED)
      if [[ "${SVC_HEALTH}" == "GOOD" ]]; then
        ok "${SVC_TYPE} (${SVC_NAME}): ${SVC_STATE} / ${SVC_HEALTH}"
      else
        warn "${SVC_TYPE} (${SVC_NAME}): ${SVC_STATE} / ${SVC_HEALTH}"
      fi
      ;;
    STOPPED)
      fail "${SVC_TYPE} (${SVC_NAME}): ${SVC_STATE}"
      ;;
    *)
      warn "${SVC_TYPE} (${SVC_NAME}): ${SVC_STATE} / ${SVC_HEALTH}"
      ;;
  esac
done < <(echo "${SERVICES_RESP}" | \
  jq -r '.items[] | "\(.name)|\(.type)|\(.serviceState // "UNKNOWN")|\(.healthSummary // "UNKNOWN")"' \
  2>/dev/null || true)

# ---------------------------------------------------------------------------
# CMS health
# ---------------------------------------------------------------------------

echo ""
echo "=== Management Services Health ==="

CMS_RESP=$(cm_curl "${CM_API_BASE}/cm/service" 2>/dev/null || true)
CMS_STATE=$(echo "${CMS_RESP}" | jq -r '.serviceState // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
CMS_HEALTH=$(echo "${CMS_RESP}" | jq -r '.healthSummary // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

if [[ "${CMS_STATE}" == "STARTED" && "${CMS_HEALTH}" == "GOOD" ]]; then
  ok "Management Services: ${CMS_STATE} / ${CMS_HEALTH}"
else
  warn "Management Services: ${CMS_STATE} / ${CMS_HEALTH}"
fi

# ---------------------------------------------------------------------------
# Port checks
# ---------------------------------------------------------------------------

echo ""
echo "=== Port Checks ==="

check_port() {
  local host="$1"
  local port="$2"
  local label="$3"
  if nc -z -w 5 "${host}" "${port}" &>/dev/null 2>&1; then
    ok "${label} (${host}:${port})"
  else
    fail "${label} (${host}:${port})"
  fi
}

check_port "${MANAGER_HOST}"  7180  "CM UI HTTP"
check_port "${MANAGER_HOST}"  7182  "CM Agent port"
check_port "${MANAGER_HOST}"  5432  "PostgreSQL"
check_port "${CLUSTER_HOST}"  9870  "HDFS NameNode UI"
check_port "${CLUSTER_HOST}"  8088  "YARN ResourceManager UI"
check_port "${CLUSTER_HOST}"  10000 "HiveServer2 (HIVE_ON_TEZ)"
check_port "${CLUSTER_HOST}"  9092  "Kafka broker"
check_port "${CLUSTER_HOST}"  21050 "Impala JDBC/ODBC (IMPALAD)"
check_port "${CLUSTER_HOST}"  25010 "Impala StateStore"
check_port "${CLUSTER_HOST}"  25020 "Impala CatalogServer"
check_port "${CLUSTER_HOST}"  8888  "Hue"
check_port "${CLUSTER_HOST}"  8080  "NiFi HTTP"
check_port "${CLUSTER_HOST}"  18080 "NiFi Registry HTTP"
check_port "${CLUSTER_HOST}"  18121 "SQL Stream Builder"

# ---------------------------------------------------------------------------
# Parcel summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Activated Parcels ==="

PARCELS_RESP=$(cm_curl "${CM_API_BASE}/clusters/${CLUSTER_NAME}/parcels" 2>/dev/null || true)
echo "${PARCELS_RESP}" | \
  jq -r '.items[] | select(.stage == "ACTIVATED") | "  \(.product) \(.version)"' \
  2>/dev/null || echo "  (could not retrieve parcel list)"

# ---------------------------------------------------------------------------
# Service endpoint summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Service Endpoints ==="
echo "  Cloudera Manager  : http://${MANAGER_HOST}:7180"
echo "  HDFS NameNode UI  : http://${CLUSTER_HOST}:9870"
echo "  YARN ResourceMgr  : http://${CLUSTER_HOST}:8088"
echo "  HiveServer2       : jdbc:hive2://${CLUSTER_HOST}:10000"
echo "  Kafka broker      : ${CLUSTER_HOST}:9092"
echo "  Impala            : jdbc:impala://${CLUSTER_HOST}:21050"
echo "  Hue               : http://${CLUSTER_HOST}:8888"
echo "  NiFi              : http://${CLUSTER_HOST}:8080/nifi"
echo "  NiFi Registry     : http://${CLUSTER_HOST}:18080/nifi-registry"
echo "  SQL Stream Builder: http://${CLUSTER_HOST}:18121"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Validation Summary ==="
echo "  PASS: ${PASS}  |  WARN: ${WARN}  |  FAIL: ${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
  echo "[WARN] ${FAIL} check(s) failed.  Review the output above."
  exit 1
fi

if [[ "${WARN}" -gt 0 ]]; then
  echo "[WARN] ${WARN} check(s) require attention."
fi

echo "[INFO] 05_validate_runtime: complete."
