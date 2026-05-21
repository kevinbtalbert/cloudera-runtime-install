#!/usr/bin/env bash
# ==============================================================================
# 04_stage_parcels.sh
# Pre-stages all required parcels into /opt/cloudera/parcel-repo BEFORE the
# cluster template is imported.
#
# This follows the edge2ai-workshop pattern: parcels are downloaded to the
# local parcel-repo directory so that when importClusterTemplate runs in step
# 05, Cloudera Manager finds them on disk and only needs to distribute and
# activate them.  Without pre-staging, CM must download multi-GB parcels from
# the internet during the template import, which is slow and fragile.
#
# Parcels staged:
#   CDH   - CDP Runtime (HDFS, YARN, Hive, Kafka, Impala, Hue, ...)
#   CFM   - Cloudera Flow Management (NiFi, NiFi Registry)
#   FLINK - Cloudera Streaming Analytics (Flink, SQL Stream Builder)
#
# Credentials are embedded in the download URL so they survive HTTP redirects.
# The Cloudera archive uses SSO redirects that drop Basic Auth headers, but
# URL-embedded credentials persist through all hops.
#
# Runs on the Cloudera Manager host.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

log_init "04_stage_parcels"
need_root
require_cmd curl
require_cmd python3

: "${CLOUDERA_REPO_USER:?CLOUDERA_REPO_USER must be set in EXPORTS}"
: "${CLOUDERA_REPO_PASS:?CLOUDERA_REPO_PASS must be set in EXPORTS}"

PARCEL_REPO_DIR='/opt/cloudera/parcel-repo'
PARCEL_OS='el9'

mkdir -p "${PARCEL_REPO_DIR}"

# ---------------------------------------------------------------------------
# Helper: inject credentials into a https:// URL
# ---------------------------------------------------------------------------

authed_url() {
  local url="$1"
  local no_scheme="${url#https://}"
  echo "https://${CLOUDERA_REPO_USER}:${CLOUDERA_REPO_PASS}@${no_scheme}"
}

# ---------------------------------------------------------------------------
# Helper: fetch manifest.json and return the parcel filename for our OS
# that matches the given version string.
# The manifest is written to a temp file so Python reads it directly — this
# avoids control-character corruption that happens when JSON is expanded
# inside a shell heredoc or string literal.
# ---------------------------------------------------------------------------

find_parcel_name() {
  local product="$1"   # e.g. CDH
  local version="$2"   # e.g. 7.3.2-1.cdh7.3.2.p0.77083870
  local repo_url="$3"  # e.g. https://archive.cloudera.com/p/cdh7/.../parcels/

  echo "[INFO] Fetching manifest: ${repo_url}manifest.json ..." >&2

  local manifest_file
  manifest_file=$(mktemp /tmp/parcel_manifest.XXXXXX.json)

  curl -fsSL "$(authed_url "${repo_url}")manifest.json" \
       -o "${manifest_file}" 2>/dev/null || {
    rm -f "${manifest_file}"
    echo "[ERROR] Could not fetch manifest from ${repo_url}" >&2
    return 1
  }

  local result
  result=$(python3 - "${manifest_file}" "${version}" "${PARCEL_OS}" <<'PYEOF'
import json, sys
manifest_file, version, os_suffix = sys.argv[1], sys.argv[2], sys.argv[3]
with open(manifest_file) as fh:
    data = json.load(fh)
for p in data.get('parcels', []):
    name = p.get('parcelName', '')
    if version in name and os_suffix in name:
        print(name)
        sys.exit(0)
sys.exit(1)
PYEOF
  ) || true

  rm -f "${manifest_file}"

  if [[ -z "${result}" ]]; then
    return 1
  fi
  echo "${result}"
}

# ---------------------------------------------------------------------------
# Helper: download one parcel + its SHA to the parcel-repo directory.
# Validates the downloaded file is a real gzip (1f8b magic bytes).
# Idempotent: skips if the parcel file already exists.
# ---------------------------------------------------------------------------

stage_parcel() {
  local product="$1"   # e.g. CDH
  local version="$2"   # e.g. 7.3.2-1.cdh7.3.2.p0.77083870
  local repo_url="$3"  # trailing slash required

  echo "[INFO] =============================="
  echo "[INFO] Staging ${product} ${version}"
  echo "[INFO] =============================="

  local parcel_name
  parcel_name=$(find_parcel_name "${product}" "${version}" "${repo_url}") || {
    echo "[ERROR] No ${PARCEL_OS} parcel found for ${product} ${version}" >&2
    exit 1
  }
  echo "[INFO] Parcel filename: ${parcel_name}"

  local dest="${PARCEL_REPO_DIR}/${parcel_name}"

  if [[ -f "${dest}" ]]; then
    echo "[INFO] ${parcel_name}: already in parcel-repo, skipping download."
  else
    echo "[INFO] Downloading ${parcel_name} (this may take several minutes) ..."
    curl -SL --progress-bar \
         -o "${dest}.tmp" \
         "$(authed_url "${repo_url}")${parcel_name}"

    # Validate gzip magic bytes (1f 8b)
    local magic
    magic=$(python3 - "${dest}.tmp" <<'PYEOF'
import sys
with open(sys.argv[1], 'rb') as f:
    print(f.read(2).hex())
PYEOF
    ) 2>/dev/null || magic=""

    if [[ "${magic}" != "1f8b" ]]; then
      echo "[ERROR] ${parcel_name}: not a valid parcel file (magic=${magic})." >&2
      echo "[ERROR] Expected gzip (1f8b). Got an error page — check CLOUDERA_REPO_USER/PASS." >&2
      rm -f "${dest}.tmp"
      exit 1
    fi

    mv -f "${dest}.tmp" "${dest}"
    echo "[INFO] Downloaded: ${parcel_name} ($(du -sh "${dest}" | cut -f1))"
  fi

  # Download SHA file alongside the parcel (CM uses this for integrity checks)
  if [[ ! -f "${dest}.sha256" && ! -f "${dest}.sha" ]]; then
    echo "[INFO] Downloading SHA for ${parcel_name} ..."
    curl -fsSL -o "${dest}.sha256" \
         "$(authed_url "${repo_url}")${parcel_name}.sha256" 2>/dev/null \
    || curl -fsSL -o "${dest}.sha" \
         "$(authed_url "${repo_url}")${parcel_name}.sha" 2>/dev/null \
    || echo "[WARN] Could not download SHA file (non-fatal)."
  fi
}

# ---------------------------------------------------------------------------
# Stage all three parcels
# ---------------------------------------------------------------------------

stage_parcel "CDH"   "${CDH_BUILD}"        "${CDH_PARCEL_REPO}"
stage_parcel "CFM"   "${CFM_BUILD}"        "${CFM_PARCEL_REPO_URL}"
stage_parcel "FLINK" "${CSA_FLINK_BUILD}"  "${CSA_PARCEL_REPO}"

# ---------------------------------------------------------------------------
# Fix ownership so CM agent can read the parcel-repo
# ---------------------------------------------------------------------------

chown -R cloudera-scm:cloudera-scm "${PARCEL_REPO_DIR}"
echo ""
echo "[INFO] Parcel-repo contents:"
ls -lh "${PARCEL_REPO_DIR}"

echo ""
echo "[INFO] 04_stage_parcels: complete."
echo "[INFO] CM will find these parcels locally when the cluster template is imported."
