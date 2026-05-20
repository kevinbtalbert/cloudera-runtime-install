#!/usr/bin/env bash
# ==============================================================================
# 01_install_jdbc_driver.sh
# Installs the PostgreSQL JDBC driver required by NiFi Registry.
#
# Run this script on EVERY host that will run the NiFi Registry role.
# The RUN_RUNTIME wrapper runs it on the manager host automatically.
# If NiFi Registry will run on a separate agent host, run this script on
# that host before deploying the cluster template.
#
# The driver JAR is installed to /usr/share/java by the postgresql-jdbc
# system package.  CM uses this path when the cluster template sets
# nifi.registry.db.driver.directory=/usr/share/java.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "01_install_jdbc_driver"
need_root

require_cmd dnf

# ---------------------------------------------------------------------------
# Install postgresql-jdbc
# ---------------------------------------------------------------------------

echo "[INFO] Installing postgresql-jdbc ..."
dnf install -y postgresql-jdbc

# ---------------------------------------------------------------------------
# Verify the JAR is present
# ---------------------------------------------------------------------------

JDBC_DIR='/usr/share/java'
JDBC_JAR=$(find "${JDBC_DIR}" -maxdepth 1 -name 'postgresql*.jar' 2>/dev/null | head -1)

if [[ -z "${JDBC_JAR}" ]]; then
  echo "[ERROR] No postgresql JDBC JAR found in ${JDBC_DIR} after install." >&2
  exit 1
fi

echo "[INFO] JDBC driver present: ${JDBC_JAR}"
ls -lh "${JDBC_DIR}"/postgresql*.jar

echo "[INFO] 01_install_jdbc_driver: complete."
