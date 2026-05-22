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

if [[ "${INCLUDE_SSB_FLINK:-true}" != "true" ]]; then
  echo "[INFO] INCLUDE_SSB_FLINK=false — skipping CSA CSD installation."
  exit 0
fi

: "${CLOUDERA_REPO_USER:?CLOUDERA_REPO_USER must be set in EXPORTS}"
: "${CLOUDERA_REPO_PASS:?CLOUDERA_REPO_PASS must be set in EXPORTS}"
: "${CSA_CSD_BASE_URL:?CSA_CSD_BASE_URL must be set in EXPORTS}"
: "${CSA_FLINK_CSD_JAR:?CSA_FLINK_CSD_JAR must be set in EXPORTS}"
: "${CSA_SSB_CSD_JAR:?CSA_SSB_CSD_JAR must be set in EXPORTS}"

CSD_DIR='/opt/cloudera/csd'
CM_RESTART_WAIT_SECONDS="${CM_RESTART_WAIT_SECONDS:-120}"

# ---------------------------------------------------------------------------
# Helper: download a CSD JAR from the authenticated Cloudera archive.
# Credentials are embedded in the URL so they survive HTTP redirects —
# the Cloudera archive redirects through SSO and loses Basic Auth headers
# passed via -u, but URL-embedded credentials persist through redirects.
# ---------------------------------------------------------------------------

# Tracks whether any JAR was newly written this run.
CSDS_CHANGED=0

download_csd() {
  local jar_name="$1"
  local dest="${CSD_DIR}/${jar_name}"

  if [[ -f "${dest}" ]]; then
    echo "[INFO] ${jar_name}: already installed, skipping download."
    return 0
  fi

  # Build URL with credentials embedded: https://USER:PASS@host/path
  local base_no_scheme="${CSA_CSD_BASE_URL#https://}"
  local url="https://${CLOUDERA_REPO_USER}:${CLOUDERA_REPO_PASS}@${base_no_scheme}/${jar_name}"

  echo "[INFO] Downloading ${jar_name} ..."
  curl -fSL --progress-bar \
       -o "${dest}.tmp" \
       "${url}"

  # Validate the file is a real JAR: JARs are ZIP files and start with PK\x03\x04
  local magic
  magic=$(python3 - "${dest}.tmp" <<'PYEOF'
import sys
with open(sys.argv[1], 'rb') as f:
    print(f.read(4).hex())
PYEOF
  ) 2>/dev/null || magic=""

  if [[ "${magic}" != "504b0304" ]]; then
    echo "[ERROR] ${jar_name} is not a valid JAR (magic bytes: ${magic})." >&2
    echo "[ERROR] Expected 504b0304 (ZIP/JAR). Got an error page — check credentials and URL." >&2
    echo "[ERROR] URL (redacted): ${CSA_CSD_BASE_URL}/${jar_name}" >&2
    rm -f "${dest}.tmp"
    exit 1
  fi

  mv -f "${dest}.tmp" "${dest}"
  echo "[INFO] Installed: ${dest} ($(du -sh "${dest}" | cut -f1))"
  CSDS_CHANGED=1
}

# ---------------------------------------------------------------------------
# Download CSDs (skipped per-file if already present)
# ---------------------------------------------------------------------------

mkdir -p "${CSD_DIR}"

download_csd "${CSA_FLINK_CSD_JAR}"
download_csd "${CSA_SSB_CSD_JAR}"

# ---------------------------------------------------------------------------
# Fix ownership on any file that was newly written
# ---------------------------------------------------------------------------

chown cloudera-scm:cloudera-scm "${CSD_DIR}/${CSA_FLINK_CSD_JAR}" \
                                 "${CSD_DIR}/${CSA_SSB_CSD_JAR}"

# ---------------------------------------------------------------------------
# Restart CM server only if new CSD JARs were installed this run.
# CM needs to rescan /opt/cloudera/csd after new JARs appear, but if both
# JARs were already present from a previous run the restart is unnecessary.
# ---------------------------------------------------------------------------

if [[ "${CSDS_CHANGED}" -eq 1 ]]; then
  echo "[INFO] New CSDs installed — restarting cloudera-scm-server to load them ..."
  systemctl restart cloudera-scm-server
  echo "[INFO] Waiting ${CM_RESTART_WAIT_SECONDS}s for CM server to restart ..."
  sleep "${CM_RESTART_WAIT_SECONDS}"
  wait_for_cm 300
else
  echo "[INFO] All CSD JARs were already present — skipping CM restart."
fi

# ---------------------------------------------------------------------------
# Verify CSD directory
# ---------------------------------------------------------------------------

echo "[INFO] Current CSD directory contents:"
ls -lh "${CSD_DIR}"/*.jar 2>/dev/null || echo "  (no JARs found)"

echo "[INFO] 03_install_csa_csds: complete."