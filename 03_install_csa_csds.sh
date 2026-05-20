#!/usr/bin/env bash
# ==============================================================================
# 03_install_csa_csds.sh
# Downloads and installs the Cloudera Streaming Analytics (CSA) CSD JARs:
#   FLINK-<build>.jar                    Apache Flink
#   SQL_STREAM_BUILDER-<build>.jar       SQL Stream Builder (SSB)
#
# Follows the same pattern as 13_install_cfm_csds.sh from the base kit.
# Restarts cloudera-scm-server after installing CSDs so CM picks them up.
# Must run BEFORE the cluster template is imported (04_deploy_cluster.sh).
# Runs on the Cloudera Manager host.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "03_install_csa_csds"
need_root
require_cmd curl

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------

: "${CLOUDERA_REPO_USER:?CLOUDERA_REPO_USER must be set in EXPORTS}"
: "${CLOUDERA_REPO_PASS:?CLOUDERA_REPO_PASS must be set in EXPORTS}"
: "${CSA_CSD_BASE_URL:?CSA_CSD_BASE_URL must be set in EXPORTS}"
: "${CSA_FLINK_CSD_JAR:?CSA_FLINK_CSD_JAR must be set in EXPORTS}"
: "${CSA_SSB_CSD_JAR:?CSA_SSB_CSD_JAR must be set in EXPORTS}"

CSD_DIR='/opt/cloudera/csd'
MIN_JAR_BYTES=51200   # 50 KB minimum sanity check
CM_RESTART_WAIT_SECONDS="${CM_RESTART_WAIT_SECONDS:-120}"

# ---------------------------------------------------------------------------
# Helper: download a CSD JAR from the authenticated Cloudera archive
# ---------------------------------------------------------------------------

download_csd() {
  local jar_name="$1"
  local dest="${CSD_DIR}/${jar_name}"
  local url="${CSA_CSD_BASE_URL}/${jar_name}"

  echo "[INFO] Downloading ${jar_name} ..."
  curl -fSL --progress-bar \
       -u "${CLOUDERA_REPO_USER}:${CLOUDERA_REPO_PASS}" \
       -o "${dest}.tmp" \
       "${url}"

  # Validate size
  local size
  size=$(stat -c '%s' "${dest}.tmp" 2>/dev/null || stat -f '%z' "${dest}.tmp" 2>/dev/null || echo 0)
  if [[ "${size}" -lt "${MIN_JAR_BYTES}" ]]; then
    echo "[ERROR] ${jar_name} is too small (${size} bytes); download may have failed." >&2
    rm -f "${dest}.tmp"
    exit 1
  fi

  mv -f "${dest}.tmp" "${dest}"
  echo "[INFO] Installed: ${dest} ($(du -sh "${dest}" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Download CSDs
# ---------------------------------------------------------------------------

mkdir -p "${CSD_DIR}"

download_csd "${CSA_FLINK_CSD_JAR}"
download_csd "${CSA_SSB_CSD_JAR}"

# ---------------------------------------------------------------------------
# Fix ownership
# ---------------------------------------------------------------------------

chown cloudera-scm:cloudera-scm "${CSD_DIR}/${CSA_FLINK_CSD_JAR}" \
                                 "${CSD_DIR}/${CSA_SSB_CSD_JAR}"
echo "[INFO] Ownership set to cloudera-scm:cloudera-scm."

# ---------------------------------------------------------------------------
# Restart CM server so it scans the updated CSD directory
# ---------------------------------------------------------------------------

echo "[INFO] Restarting cloudera-scm-server to load new CSDs ..."
systemctl restart cloudera-scm-server

echo "[INFO] Waiting ${CM_RESTART_WAIT_SECONDS}s for CM server to restart ..."
sleep "${CM_RESTART_WAIT_SECONDS}"

wait_for_cm 300

# ---------------------------------------------------------------------------
# Verify CSD directory
# ---------------------------------------------------------------------------

echo "[INFO] Current CSD directory contents:"
ls -lh "${CSD_DIR}"/*.jar 2>/dev/null || echo "  (no JARs found)"

echo "[INFO] 03_install_csa_csds: complete."
