#!/bin/bash
# Install `oc` + `oc-mirror` on a connected (internet-reachable) host.
#
# WHY THIS EXISTS: `oc-mirror` is NOT inside openshift-client-linux.tar.gz —
# that archive only contains `oc` and `kubectl`. oc-mirror ships as its own
# tarball (oc-mirror.tar.gz) in the same download directory. Extracting the
# client archive asking for oc-mirror fails with:
#   tar: oc-mirror: Cannot find in archive
# This script does both downloads correctly.
#
# Usage:   bash install-oc-mirror.sh <ocp-version>
# Example: bash install-oc-mirror.sh 4.21.4
#          bash install-oc-mirror.sh latest        # uses the 'stable' dir
set -euo pipefail

VER="${1:?usage: $0 <ocp-version|latest>}"
# 'latest' isn't a real dir on the mirror — stable is
[ "$VER" = "latest" ] && VER="stable"
BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${VER}"
WORKDIR="$(mktemp -d /tmp/ocp-tools.XXXXXX)"
echo "==> Working in $WORKDIR"
cd "$WORKDIR"

echo "==> Downloading openshift-client-linux.tar.gz from $BASE"
curl -fLO "${BASE}/openshift-client-linux.tar.gz"
echo "==> Downloading oc-mirror.tar.gz from $BASE"
curl -fLO "${BASE}/oc-mirror.tar.gz"

echo "==> Extracting"
tar xzf openshift-client-linux.tar.gz oc kubectl
tar xzf oc-mirror.tar.gz
[ -f ./oc-mirror ] || { echo "ERROR: oc-mirror binary not found after extract"; ls -la; exit 1; }

echo "==> Installing to /usr/local/bin"
sudo install -m 0755 oc kubectl oc-mirror /usr/local/bin/

echo "==> Verify"
oc version --client
oc-mirror version
echo "Done. oc-mirror is a standalone binary — invoke it as 'oc-mirror', NOT 'oc mirror'."
