#!/usr/bin/env bash
# ==============================================================================
# 01_install_jdbc_driver.sh
# Installs database drivers needed by cluster services:
#
#   postgresql-jdbc        PostgreSQL JDBC driver for NiFi Registry.
#                          Installed to /usr/share/java.  CM uses this path
#                          when nifi.registry.db.driver.directory=/usr/share/java.
#
#   psycopg2-binary        PostgreSQL driver for Python 3.11, required by Hue.
#                          Hue in CDP 7.3.2 uses a Python 3.11 virtualenv inside
#                          the CDH parcel.  The base kit installs psycopg2 for
#                          Python 3.9 only.  Without this, Hue migrations fail
#                          with "ModuleNotFoundError: No module named 'psycopg2'".
#
# Run this script on every host that will run NiFi Registry or Hue.
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

# SSB's common.sh searches /usr/share/java/ for 'postgresql-connector-java.jar'
# (not 'postgresql-jdbc.jar').  Create the symlink so SSB can find the driver.
if [[ ! -f "${JDBC_DIR}/postgresql-connector-java.jar" ]]; then
  echo "[INFO] Creating postgresql-connector-java.jar symlink for SQL Stream Builder ..."
  ln -sf "${JDBC_JAR}" "${JDBC_DIR}/postgresql-connector-java.jar"
fi
echo "[INFO] postgresql-connector-java.jar -> $(readlink -f "${JDBC_DIR}/postgresql-connector-java.jar")"

# ---------------------------------------------------------------------------
# Install psycopg2-binary for Python 3.11 (required by Hue)
#
# Hue in CDP 7.3.2 uses a Python 3.11 virtualenv inside the CDH parcel.
# The Hue startup script adds the psycopg2 location to PYTHONPATH so Django
# can import it from the system Python 3.11 site-packages.
# ---------------------------------------------------------------------------

if command -v python3.11 &>/dev/null; then
  echo "[INFO] Installing psycopg2-binary for Python 3.11 (required by Hue) ..."
  python3.11 -m pip install --quiet psycopg2-binary 2>/dev/null || \
    echo "[WARN] psycopg2-binary install failed — Hue may fail to start."

  # Verify
  if python3.11 -c "import psycopg2; print('[INFO] psycopg2', psycopg2.__version__, 'installed for Python 3.11')" 2>/dev/null; then
    :
  else
    echo "[WARN] psycopg2 not importable by Python 3.11 — Hue migrations will fail."
  fi
else
  echo "[WARN] python3.11 not found — skipping psycopg2 install for Hue."
fi

echo "[INFO] 01_install_jdbc_driver: complete."
