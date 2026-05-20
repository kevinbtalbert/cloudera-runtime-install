#!/usr/bin/env bash
# ==============================================================================
# 00_create_service_databases.sh
# Ensures every PostgreSQL database required by the deployed services exists
# before the cluster template is imported.
#
# This script is the single authoritative source for all service databases.
# It covers databases that should have been created by the base install kit
# (07_create_cm_and_registry_dbs.sh) as well as new databases required by the
# services deployed by this kit.  Every call is idempotent — existing roles
# and databases are skipped, nothing is dropped or recreated.
#
# Databases managed:
#
#   Service                 Database    Variable group   Created by
#   ----------------------  ----------  ---------------  --------------------
#   Cloudera Manager        scm         CM_DB_*          base kit (verified)
#   Reports Manager         rman        RM_DB_*          base kit (verified)
#   NiFi Registry           nifireg     REG_DB_*         base kit (verified)
#   Hue                     hue         HUE_DB_*         base kit EXPORTS / this kit
#   Hive Metastore          metastore   HIVE_DB_*        base kit EXPORTS / this kit
#   SQL Stream Builder      ssb         SSB_DB_*         this kit
#   Ranger (optional)       ranger      RANGER_DB_*      this kit (CREATE_EXTRA_DBS)
#
# Runs on the Cloudera Manager / PostgreSQL host.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "00_create_service_databases"
need_root

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

require_cmd psql

PG_SERVICE="postgresql-${PG_MAJOR:-14}"
if ! systemctl is-active --quiet "${PG_SERVICE}"; then
  echo "[ERROR] PostgreSQL service '${PG_SERVICE}' is not running." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helper: create role + database if they do not already exist.
# Uses -Atc (unaligned, tuples-only) for a clean empty-or-1 result.
# ---------------------------------------------------------------------------

create_db() {
  local db_name="$1"
  local db_user="$2"
  local db_pass="$3"

  local role_exists db_exists
  role_exists=$(sudo -u postgres psql -Atc \
    "SELECT 1 FROM pg_roles WHERE rolname='${db_user}'" 2>/dev/null || echo "")
  if [[ "${role_exists}" == "1" ]]; then
    echo "[INFO]   role '${db_user}': already exists"
  else
    echo "[INFO]   role '${db_user}': creating ..."
    sudo -u postgres psql -c \
      "CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_pass}';"
  fi

  db_exists=$(sudo -u postgres psql -Atc \
    "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null || echo "")
  if [[ "${db_exists}" == "1" ]]; then
    echo "[INFO]   database '${db_name}': already exists"
  else
    echo "[INFO]   database '${db_name}': creating ..."
    sudo -u postgres psql -c \
      "CREATE DATABASE ${db_name} OWNER ${db_user} ENCODING 'UTF8';"
  fi
}

# ---------------------------------------------------------------------------
# Cloudera Manager Server
# Required by scm_prepare_database.sh (base kit step 11).
# ---------------------------------------------------------------------------

echo "[INFO] --- Cloudera Manager (${CM_DB_NAME:-scm}) ---"
: "${CM_DB_NAME:?CM_DB_NAME must be set — check parent EXPORTS}"
: "${CM_DB_USER:?CM_DB_USER must be set — check parent EXPORTS}"
: "${CM_DB_PASS:?CM_DB_PASS must be set — check parent EXPORTS}"
create_db "${CM_DB_NAME}" "${CM_DB_USER}" "${CM_DB_PASS}"

# ---------------------------------------------------------------------------
# Cloudera Reports Manager
# Required by CM Management Services (step 02_setup_cms.sh).
# ---------------------------------------------------------------------------

echo "[INFO] --- Reports Manager (${RM_DB_NAME:-rman}) ---"
: "${RM_DB_NAME:?RM_DB_NAME must be set — check parent EXPORTS}"
: "${RM_DB_USER:?RM_DB_USER must be set — check parent EXPORTS}"
: "${RM_DB_PASS:?RM_DB_PASS must be set — check parent EXPORTS}"
create_db "${RM_DB_NAME}" "${RM_DB_USER}" "${RM_DB_PASS}"

# ---------------------------------------------------------------------------
# NiFi Registry
# Required by the NIFIREGISTRY service in the cluster template.
# ---------------------------------------------------------------------------

echo "[INFO] --- NiFi Registry (${REG_DB_NAME:-nifireg}) ---"
: "${REG_DB_NAME:?REG_DB_NAME must be set — check parent EXPORTS}"
: "${REG_DB_USER:?REG_DB_USER must be set — check parent EXPORTS}"
: "${REG_DB_PASS:?REG_DB_PASS must be set — check parent EXPORTS}"
create_db "${REG_DB_NAME}" "${REG_DB_USER}" "${REG_DB_PASS}"

# ---------------------------------------------------------------------------
# Hive Metastore
# Required by the HIVE service in the cluster template.
# CM initialises the schema automatically on first Hivemetastore start.
# ---------------------------------------------------------------------------

echo "[INFO] --- Hive Metastore (${HIVE_DB_NAME:-metastore}) ---"
: "${HIVE_DB_NAME:?HIVE_DB_NAME must be set — check parent EXPORTS}"
: "${HIVE_DB_USER:?HIVE_DB_USER must be set — check parent EXPORTS}"
: "${HIVE_DB_PASS:?HIVE_DB_PASS must be set — check parent EXPORTS}"
create_db "${HIVE_DB_NAME}" "${HIVE_DB_USER}" "${HIVE_DB_PASS}"

# ---------------------------------------------------------------------------
# Hue
# Required by the HUE service in the cluster template.
# ---------------------------------------------------------------------------

echo "[INFO] --- Hue (${HUE_DB_NAME:-hue}) ---"
: "${HUE_DB_NAME:?HUE_DB_NAME must be set — check parent EXPORTS}"
: "${HUE_DB_USER:?HUE_DB_USER must be set — check parent EXPORTS}"
: "${HUE_DB_PASS:?HUE_DB_PASS must be set — check parent EXPORTS}"
create_db "${HUE_DB_NAME}" "${HUE_DB_USER}" "${HUE_DB_PASS}"

# ---------------------------------------------------------------------------
# SQL Stream Builder
# Required by the SQL_STREAM_BUILDER service in the cluster template.
# ---------------------------------------------------------------------------

echo "[INFO] --- SQL Stream Builder (${SSB_DB_NAME:-ssb}) ---"
: "${SSB_DB_NAME:?SSB_DB_NAME must be set in EXPORTS}"
: "${SSB_DB_USER:?SSB_DB_USER must be set in EXPORTS}"
: "${SSB_DB_PASS:?SSB_DB_PASS must be set in EXPORTS}"
create_db "${SSB_DB_NAME}" "${SSB_DB_USER}" "${SSB_DB_PASS}"

# ---------------------------------------------------------------------------
# Ranger (optional)
# Only created when CREATE_EXTRA_DBS=true.  Set this in EXPORTS before running
# if you plan to deploy Apache Ranger.
# ---------------------------------------------------------------------------

echo "[INFO] --- Ranger (${RANGER_DB_NAME:-ranger}) ---"
if [[ "${CREATE_EXTRA_DBS:-false}" == "true" ]]; then
  : "${RANGER_DB_NAME:?RANGER_DB_NAME must be set in EXPORTS}"
  : "${RANGER_DB_USER:?RANGER_DB_USER must be set in EXPORTS}"
  : "${RANGER_DB_PASS:?RANGER_DB_PASS must be set in EXPORTS}"
  create_db "${RANGER_DB_NAME}" "${RANGER_DB_USER}" "${RANGER_DB_PASS}"
else
  echo "[INFO]   skipped (CREATE_EXTRA_DBS=${CREATE_EXTRA_DBS:-false})"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "[INFO] All service databases verified.  Current database list:"
sudo -u postgres psql -Atc \
  "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" \
  | sed 's/^/[INFO]   /'

echo ""
echo "[INFO] 00_create_service_databases: complete."
