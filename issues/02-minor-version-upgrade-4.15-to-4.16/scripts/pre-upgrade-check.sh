#!/bin/bash
# Pre-upgrade health and readiness check for OCP minor version upgrades.
# Run this before initiating any upgrade. All checks must pass (PASS) before proceeding.
# Usage: bash pre-upgrade-check.sh [target-version]
# Example: bash pre-upgrade-check.sh 4.16.55

export KUBECONFIG=${KUBECONFIG:-/home/centos/ocp/install/auth/kubeconfig}
TARGET_VERSION=${1:-""}
PASS=0; FAIL=0; WARN=0

green()  { echo -e "\033[32m[PASS]\033[0m $*"; ((PASS++)); }
red()    { echo -e "\033[31m[FAIL]\033[0m $*"; ((FAIL++)); }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; ((WARN++)); }
header() { echo -e "\n\033[1m>>> $* \033[0m"; }

header "1. CLUSTER VERSION"
CV=$(oc get clusterversion version --no-headers 2>/dev/null)
CUR_VER=$(echo "$CV" | awk '{print $2}')
PROGRESSING=$(echo "$CV" | awk '{print $4}')
echo "  Current version: $CUR_VER"
if [ "$PROGRESSING" = "False" ]; then
    green "Cluster not currently upgrading"
else
    red "Cluster is already progressing ($PROGRESSING) — do not start another upgrade"
fi

header "2. NODE HEALTH"
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v "Ready$" | grep -v "Ready," || true)
if [ -z "$NOT_READY" ]; then
    NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
    green "All $NODE_COUNT nodes are Ready"
else
    red "Nodes not in Ready state:"
    echo "$NOT_READY" | sed 's/^/    /'
fi

header "3. CLUSTER OPERATORS"
UNHEALTHY=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$UNHEALTHY" ]; then
    CO_COUNT=$(oc get co --no-headers 2>/dev/null | wc -l)
    green "All $CO_COUNT cluster operators healthy"
else
    red "Unhealthy cluster operators:"
    echo "$UNHEALTHY" | sed 's/^/    /'
fi

header "4. MACHINECONFIGPOOLS"
MCP_NOT_UPDATED=$(oc get mcp --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$MCP_NOT_UPDATED" ]; then
    green "All MCPs are updated and not degraded"
else
    red "MCPs not ready:"
    echo "$MCP_NOT_UPDATED" | sed 's/^/    /'
fi

header "5. PENDING CSRs"
PENDING_CSR=$(oc get csr --no-headers 2>/dev/null | grep -v "Approved" || true)
if [ -z "$PENDING_CSR" ]; then
    green "No pending CSRs"
else
    yellow "Pending/Denied CSRs found — approve before upgrade:"
    echo "$PENDING_CSR" | sed 's/^/    /'
fi

header "6. DISK SPACE (minimum: / ≥15% free, /boot ≥100MB free)"
for node in $(oc get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
    DISK=$(oc debug node/$node -- chroot /host df -h / /boot 2>/dev/null \
           | grep -v "^Filesystem\|Starting\|chroot" 2>/dev/null)
    ROOT_PCT=$(echo "$DISK" | grep " /$" | awk '{print $5}' | tr -d '%')
    BOOT_FREE=$(echo "$DISK" | grep " /boot$" | awk '{print $4}')
    if [ -n "$ROOT_PCT" ] && [ "$ROOT_PCT" -gt 85 ]; then
        red "$node: / is ${ROOT_PCT}% used — clean up before upgrading"
    elif [ -n "$ROOT_PCT" ] && [ "$ROOT_PCT" -gt 75 ]; then
        yellow "$node: / is ${ROOT_PCT}% used — monitor closely"
    elif [ -n "$ROOT_PCT" ]; then
        green "$node: / is ${ROOT_PCT}% used  /boot free: $BOOT_FREE"
    else
        yellow "$node: could not read disk usage"
    fi
done

header "7. PODDISRUPTIONBUDGETS — PDBs THAT WILL BLOCK NODE DRAIN"
BLOCKING_PDBS=$(oc get pdb -A --no-headers 2>/dev/null | awk '$5=="0"')
if [ -z "$BLOCKING_PDBS" ]; then
    green "No PDBs with allowedDisruptions=0 found"
else
    yellow "The following PDBs have allowedDisruptions=0 and WILL block node drain during MCO phase:"
    echo "$BLOCKING_PDBS" | awk '{printf "    %-40s %-40s minAvailable=%s\n", $1, $2, $4}'
    echo ""
    echo "  Plan: delete each before its node is drained, or scale up the workload to 2+ replicas."
fi

header "8. PULL SECRET (quay.io authentication)"
HAS_AUTH=$(oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d | \
  python3 -c "import json,sys,base64; d=json.load(sys.stdin); \
  q=d['auths'].get('quay.io',{}); a=q.get('auth',''); \
  creds=base64.b64decode(a).decode() if a else ''; \
  print(creds.split(':')[0] if ':' in creds else '')" 2>/dev/null)
if [ -n "$HAS_AUTH" ]; then
    green "quay.io pull secret authenticated (user: $HAS_AUTH)"
else
    red "quay.io pull secret missing or unauthenticated — image pulls may be rate-limited"
fi

header "9. ETCD HEALTH"
ETCD_PODS=$(oc get pods -n openshift-etcd --no-headers 2>/dev/null | grep "^etcd-" | grep -v "guard\|pruner")
ETCD_NOT_READY=$(echo "$ETCD_PODS" | awk '$2!="4/4"' || true)
if [ -z "$ETCD_NOT_READY" ]; then
    ETCD_COUNT=$(echo "$ETCD_PODS" | wc -l)
    green "All $ETCD_COUNT etcd pods running 4/4"
else
    red "etcd pods not fully ready:"
    echo "$ETCD_NOT_READY" | sed 's/^/    /'
fi

header "10. UPDATE PATH"
if [ -n "$TARGET_VERSION" ]; then
    AVAILABLE=$(oc adm upgrade 2>/dev/null | grep "$TARGET_VERSION" || true)
    if [ -n "$AVAILABLE" ]; then
        green "Target version $TARGET_VERSION is available in the update graph"
    else
        yellow "Target version $TARGET_VERSION not found in recommended updates — check channel"
        echo "  Current channel: $(oc get clusterversion -o jsonpath='{.items[0].spec.channel}' 2>/dev/null)"
        echo "  Run: oc patch clusterversion version --type merge -p '{\"spec\":{\"channel\":\"stable-4.16\"}}'"
    fi
else
    echo "  (no target version specified — skipping update path check)"
    echo "  Usage: $0 4.16.55"
fi

echo ""
echo "================================================"
echo "  RESULTS: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "================================================"
if [ "$FAIL" -gt 0 ]; then
    echo "  ACTION REQUIRED: Fix all FAIL items before upgrading."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo "  WARNING: Review WARN items before proceeding."
    exit 0
else
    echo "  Cluster is ready to upgrade."
    exit 0
fi
