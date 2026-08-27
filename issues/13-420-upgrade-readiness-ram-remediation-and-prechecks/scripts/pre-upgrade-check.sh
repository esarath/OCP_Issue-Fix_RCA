#!/bin/bash
# Pre-upgrade health and readiness check for OCP minor (y-stream) version upgrades.
# Adapted from issue 02's script for the 4.19->4.20 effort: drops CNV/GitOps-specific
# checks (neither installed on this cluster as of issue 12), adds channel-drift and
# named-admin checks (issue 08). Run before initiating any upgrade — all checks
# should PASS before proceeding; WARN items need a conscious decision, not a blocker.
# Usage: bash pre-upgrade-check.sh [target-version] [target-channel]
# Example: bash pre-upgrade-check.sh 4.20.x stable-4.20

export KUBECONFIG=${KUBECONFIG:-/home/centos/ocp/install/auth/kubeconfig}
TARGET_VERSION=${1:-""}
TARGET_CHANNEL=${2:-""}
PASS=0; FAIL=0; WARN=0

green()  { echo -e "\033[32m[PASS]\033[0m $*"; ((PASS++)); }
red()    { echo -e "\033[31m[FAIL]\033[0m $*"; ((FAIL++)); }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; ((WARN++)); }
header() { echo -e "\n\033[1m>>> $* \033[0m"; }

header "1. CLUSTER VERSION & CHANNEL"
CV=$(oc get clusterversion version --no-headers 2>/dev/null)
CUR_VER=$(echo "$CV" | awk '{print $2}')
PROGRESSING=$(echo "$CV" | awk '{print $4}')
CUR_CHANNEL=$(oc get clusterversion version -o jsonpath='{.spec.channel}' 2>/dev/null)
echo "  Current version: $CUR_VER   Current channel: $CUR_CHANNEL"
if [ "$PROGRESSING" = "False" ]; then
    green "Cluster not currently upgrading"
else
    red "Cluster is already progressing ($PROGRESSING) — do not start another upgrade"
fi
if [ -n "$TARGET_CHANNEL" ] && [ "$CUR_CHANNEL" != "$TARGET_CHANNEL" ]; then
    yellow "Current channel ($CUR_CHANNEL) != target channel ($TARGET_CHANNEL) — switch deliberately, not via console click (see issue 08 channel-drift incident)"
fi

header "2. WHO'S RUNNING THIS (attribution)"
WHOAMI=$(oc whoami 2>/dev/null)
echo "  Identity: $WHOAMI"
if [ "$WHOAMI" = "kube:admin" ]; then
    yellow "Running as shared kube:admin bootstrap credential — use a named admin account for attributable channel/upgrade changes (issue 08, issue 10)"
else
    green "Running as named identity: $WHOAMI"
fi

header "3. NODE HEALTH"
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | awk '$2!="Ready" && $2!="Ready,SchedulingDisabled"')
if [ -z "$NOT_READY" ]; then
    NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
    green "All $NODE_COUNT nodes are Ready"
else
    red "Nodes not in Ready state:"
    echo "$NOT_READY" | sed 's/^/    /'
fi

header "4. CLUSTER OPERATORS"
UNHEALTHY=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$UNHEALTHY" ]; then
    CO_COUNT=$(oc get co --no-headers 2>/dev/null | wc -l)
    green "All $CO_COUNT cluster operators healthy"
else
    red "Unhealthy cluster operators:"
    echo "$UNHEALTHY" | sed 's/^/    /'
fi

header "5. MACHINECONFIGPOOLS"
MCP_NOT_UPDATED=$(oc get mcp --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$MCP_NOT_UPDATED" ]; then
    green "All MCPs are updated and not degraded"
else
    red "MCPs not ready:"
    echo "$MCP_NOT_UPDATED" | sed 's/^/    /'
fi

header "6. PENDING CSRs"
PENDING_CSR=$(oc get csr --no-headers 2>/dev/null | grep -v "Approved" || true)
if [ -z "$PENDING_CSR" ]; then
    green "No pending CSRs"
else
    yellow "Pending/Denied CSRs found — approve before upgrade:"
    echo "$PENDING_CSR" | sed 's/^/    /'
fi

header "7. NODE MEMORY HEADROOM (RAM was the 4.20 blocker — issues 08/11/12/13)"
oc adm top nodes 2>/dev/null | sed 's/^/  /'
TIGHT_MEM=$(oc adm top nodes --no-headers 2>/dev/null | awk '{gsub("%","",$5); if ($5+0 > 85) print}')
if [ -z "$TIGHT_MEM" ]; then
    green "No node above 85% memory"
else
    yellow "Node(s) above 85% memory — re-verify this is expected, not fresh pressure:"
    echo "$TIGHT_MEM" | sed 's/^/    /'
fi

header "8. DISK SPACE (/var — minimum: ≥15% free)"
for node in $(oc get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
    DISK=$(oc debug node/$node -- chroot /host df -h /var 2>/dev/null \
           | grep -v "^Filesystem\|Starting\|chroot" 2>/dev/null)
    PCT=$(echo "$DISK" | awk '{print $5}' | tr -d '%')
    if [ -n "$PCT" ] && [ "$PCT" -gt 85 ]; then
        red "$node: /var is ${PCT}% used — prune before upgrading (crictl rmi --prune)"
    elif [ -n "$PCT" ] && [ "$PCT" -gt 50 ]; then
        yellow "$node: /var is ${PCT}% used — monitor, consider pruning"
    elif [ -n "$PCT" ]; then
        green "$node: /var is ${PCT}% used"
    else
        yellow "$node: could not read disk usage"
    fi
done

header "9. PODDISRUPTIONBUDGETS — PDBs THAT WILL BLOCK NODE DRAIN"
BLOCKING_PDBS=$(oc get pdb -A --no-headers 2>/dev/null | awk '$5=="0"')
if [ -z "$BLOCKING_PDBS" ]; then
    green "No PDBs with allowedDisruptions=0 found"
else
    yellow "The following PDBs have allowedDisruptions=0 and WILL block node drain during MCO phase:"
    echo "$BLOCKING_PDBS" | awk '{printf "    %-40s %-40s\n", $1, $2}'
fi

header "10. PULL SECRET (quay.io authentication — issue 02 hit a rate limit without this)"
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

header "11. ETCD HEALTH"
ETCD_PODS=$(oc get pods -n openshift-etcd --no-headers 2>/dev/null | grep "^etcd-" | grep -v "guard\|pruner")
ETCD_NOT_READY=$(echo "$ETCD_PODS" | awk '{split($2,a,"/"); if (a[1]!=a[2]) print}')
if [ -z "$ETCD_NOT_READY" ]; then
    ETCD_COUNT=$(echo "$ETCD_PODS" | wc -l)
    green "All $ETCD_COUNT etcd pods fully ready"
else
    red "etcd pods not fully ready:"
    echo "$ETCD_NOT_READY" | sed 's/^/    /'
fi

header "12. INSTALLED OLM OPERATORS (confirm vendor compat with target y-stream manually)"
oc get csv -A --no-headers 2>/dev/null | awk '{print "  " $1, $2, $NF}'

header "13. UPDATE PATH"
if [ -n "$TARGET_VERSION" ]; then
    AVAILABLE=$(oc adm upgrade 2>/dev/null | grep "$TARGET_VERSION" || true)
    if [ -n "$AVAILABLE" ]; then
        green "Target version $TARGET_VERSION is available in the update graph"
    else
        yellow "Target version $TARGET_VERSION not found in recommended updates on current channel ($CUR_CHANNEL)"
        [ -n "$TARGET_CHANNEL" ] && echo "  Switch channel first: oc adm upgrade channel $TARGET_CHANNEL"
    fi
else
    echo "  (no target version specified — skipping update path check)"
    echo "  Usage: $0 4.20.x stable-4.20"
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
