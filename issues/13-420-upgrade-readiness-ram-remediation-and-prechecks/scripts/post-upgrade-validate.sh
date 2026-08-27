#!/bin/bash
# Post-upgrade validation for OCP minor (y-stream) version upgrades.
# Adapted from issue 02's script: drops CNV/GitOps-specific checks (neither
# installed on this cluster as of issue 12), adds channel re-check (issue 08).
# Run after upgrade completes. All checks should PASS before declaring success.
# Usage: bash post-upgrade-validate.sh <expected-version> [expected-channel]
# Example: bash post-upgrade-validate.sh 4.20.1 stable-4.20

export KUBECONFIG=${KUBECONFIG:-/home/centos/ocp/install/auth/kubeconfig}
EXPECTED_VERSION=${1:-""}
EXPECTED_CHANNEL=${2:-""}
PASS=0; FAIL=0; WARN=0

green()  { echo -e "\033[32m[PASS]\033[0m $*"; ((PASS++)); }
red()    { echo -e "\033[31m[FAIL]\033[0m $*"; ((FAIL++)); }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; ((WARN++)); }
header() { echo -e "\n\033[1m>>> $* \033[0m"; }

header "1. CLUSTER VERSION"
CV_VERSION=$(oc get clusterversion version -o jsonpath='{.status.history[0].version}' 2>/dev/null)
CV_STATE=$(oc get clusterversion version -o jsonpath='{.status.history[0].state}' 2>/dev/null)
CV_PROGRESSING=$(oc get clusterversion version \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
echo "  Current version : $CV_VERSION"
echo "  History state   : $CV_STATE"
if [ -n "$EXPECTED_VERSION" ] && [ "$CV_VERSION" != "$EXPECTED_VERSION" ]; then
    red "Version mismatch — expected $EXPECTED_VERSION, got $CV_VERSION"
elif [ "$CV_STATE" = "Completed" ] && [ "$CV_PROGRESSING" = "False" ]; then
    green "Upgrade to $CV_VERSION completed and not progressing"
else
    red "Upgrade not in Completed state (state=$CV_STATE, progressing=$CV_PROGRESSING)"
fi

header "2. CHANNEL (issue 08 channel-drift lesson)"
CUR_CHANNEL=$(oc get clusterversion version -o jsonpath='{.spec.channel}' 2>/dev/null)
echo "  Current channel: $CUR_CHANNEL"
if [ -n "$EXPECTED_CHANNEL" ] && [ "$CUR_CHANNEL" != "$EXPECTED_CHANNEL" ]; then
    red "Channel mismatch — expected $EXPECTED_CHANNEL, got $CUR_CHANNEL"
else
    green "Channel as expected"
fi

header "3. ALL NODES READY AND ON TARGET VERSION"
NODES=$(oc get nodes --no-headers 2>/dev/null)
NOT_READY=$(echo "$NODES" | awk '$2!="Ready" && $2!="Ready,SchedulingDisabled"')
if [ -z "$NOT_READY" ]; then
    NODE_COUNT=$(echo "$NODES" | wc -l)
    green "All $NODE_COUNT nodes are Ready"
else
    red "Nodes not Ready:"
    echo "$NOT_READY" | sed 's/^/    /'
fi

DISTINCT_KUBELETS=$(oc get nodes --no-headers 2>/dev/null | awk '{print $NF}' | sort -u)
KUBELET_COUNT=$(echo "$DISTINCT_KUBELETS" | wc -l)
if [ "$KUBELET_COUNT" -eq 1 ]; then
    green "All nodes on the same kubelet version ($DISTINCT_KUBELETS)"
else
    red "Nodes on inconsistent kubelet versions (expected all 5 to match):"
    oc get nodes --no-headers 2>/dev/null | awk '{print "    "$1, $NF}'
fi
# Note: OCP y-stream != kubelet minor version (e.g. OCP 4.19.x ships kubelet
# v1.32.x, not v1.19.x) — there's no reliable string-derivable mapping, so
# this only checks fleet consistency, not a computed expected string.

header "4. ALL CLUSTER OPERATORS HEALTHY"
UNHEALTHY=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$UNHEALTHY" ]; then
    CO_COUNT=$(oc get co --no-headers 2>/dev/null | wc -l)
    green "All $CO_COUNT cluster operators: Available=True Progressing=False Degraded=False"
else
    red "Unhealthy cluster operators:"
    echo "$UNHEALTHY" | sed 's/^/    /'
fi

header "5. MACHINECONFIGPOOLS FULLY UPDATED"
MCP_ISSUES=$(oc get mcp --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$MCP_ISSUES" ]; then
    green "All MCPs: Updated=True Updating=False Degraded=False"
else
    red "MCPs not fully updated:"
    echo "$MCP_ISSUES" | sed 's/^/    /'
fi

header "6. NO PENDING CSRs"
PENDING=$(oc get csr --no-headers 2>/dev/null | grep -v "Approved" || true)
if [ -z "$PENDING" ]; then
    green "No pending or denied CSRs"
else
    yellow "Pending CSRs found — approve with: oc get csr -o name | xargs oc adm certificate approve"
    echo "$PENDING" | sed 's/^/    /'
fi

header "7. ETCD HEALTH"
ETCD_PODS=$(oc get pods -n openshift-etcd --no-headers 2>/dev/null | grep "^etcd-" | grep -v "guard\|pruner")
ETCD_BAD=$(echo "$ETCD_PODS" | awk '{split($2,a,"/"); if (a[1]!=a[2]) print}')
if [ -z "$ETCD_BAD" ]; then
    green "All etcd pods fully ready"
else
    red "etcd pods not fully ready:"
    echo "$ETCD_BAD" | sed 's/^/    /'
fi

header "8. WEB CONSOLE ACCESSIBLE"
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
  https://console-openshift-console.apps.lab.ocp.local 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    green "Web console returned HTTP $HTTP_CODE"
else
    red "Web console returned HTTP $HTTP_CODE (expected 200)"
fi

header "9. ROUTER PODS"
ROUTER_BAD=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | \
  grep "router-default" | awk '$2!="1/1" || $3!="Running"' || true)
ROUTER_COUNT=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep -c "router-default" || true)
if [ -z "$ROUTER_BAD" ] && [ "$ROUTER_COUNT" -ge 2 ]; then
    green "Router pods: $ROUTER_COUNT/2 Running 1/1"
else
    red "Router pods not healthy (count=$ROUTER_COUNT):"
    echo "$ROUTER_BAD" | sed 's/^/    /'
fi

header "10. MONITORING STACK"
MON_BAD=$(oc get pods -n openshift-monitoring --no-headers 2>/dev/null | \
  grep -E "prometheus-k8s|alertmanager|thanos-querier" | \
  awk '$3!="Running"' || true)
if [ -z "$MON_BAD" ]; then
    green "Prometheus, Alertmanager, and Thanos Querier pods Running"
else
    red "Monitoring pods not healthy:"
    echo "$MON_BAD" | sed 's/^/    /'
fi

header "11. NODE MEMORY & DISK POST-UPGRADE"
oc adm top nodes 2>/dev/null | sed 's/^/  /'
for node in $(oc get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
    PCT=$(oc debug node/$node -- chroot /host df -h /var 2>/dev/null \
           | grep -v "^Filesystem\|Starting\|chroot" | awk '{print $5}' | tr -d '%')
    if [ -n "$PCT" ] && [ "$PCT" -gt 85 ]; then
        red "$node: /var is ${PCT}% used — prune old container images"
    else
        green "$node: /var is ${PCT}% used"
    fi
done

header "12. INSTALLED OLM OPERATORS STILL HEALTHY"
CSV_BAD=$(oc get csv -A --no-headers 2>/dev/null | awk '$NF!="Succeeded"')
if [ -z "$CSV_BAD" ]; then
    green "All installed CSVs report Succeeded"
else
    yellow "CSVs not in Succeeded phase — check reconciliation against the new API surface:"
    echo "$CSV_BAD" | sed 's/^/    /'
fi

header "13. BASTION oc CLIENT VERSION (issue 04 lesson — refresh, don't assume)"
oc version 2>/dev/null | sed 's/^/  /'
yellow "Manually confirm Client and Server versions match (or intentionally close) — refresh via checklists/cluster-startup.md's client install steps if not"

header "14. UPGRADEABLE STATUS FOR NEXT UPGRADE"
UPGRADEABLE=$(oc get clusterversion version \
  -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].status}' 2>/dev/null)
UPGRADEABLE_MSG=$(oc get clusterversion version \
  -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}' 2>/dev/null)
if [ "$UPGRADEABLE" = "True" ]; then
    green "Cluster is Upgradeable for next minor version"
else
    yellow "Cluster not yet Upgradeable for next minor version (normal — resolves within 24h):"
    echo "  $UPGRADEABLE_MSG" | fold -s -w 90 | sed 's/^/  /'
fi

echo ""
echo "================================================"
echo "  RESULTS: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "================================================"
if [ "$FAIL" -gt 0 ]; then
    echo "  ACTION REQUIRED: Investigate FAIL items."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo "  Upgrade complete with warnings — review WARN items."
    exit 0
else
    echo "  Upgrade fully validated. Cluster healthy."
    exit 0
fi
