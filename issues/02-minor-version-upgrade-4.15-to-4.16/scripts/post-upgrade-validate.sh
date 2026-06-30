#!/bin/bash
# Post-upgrade validation for OCP minor version upgrades.
# Run after upgrade completes. All checks must PASS before declaring success.
# Usage: bash post-upgrade-validate.sh <expected-version>
# Example: bash post-upgrade-validate.sh 4.16.55

export KUBECONFIG=${KUBECONFIG:-/home/centos/ocp/install/auth/kubeconfig}
EXPECTED_VERSION=${1:-""}
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

header "2. ALL NODES READY AND ON TARGET VERSION"
NODES=$(oc get nodes --no-headers 2>/dev/null)
NOT_READY=$(echo "$NODES" | grep -v " Ready " | grep -v " Ready," || true)
if [ -z "$NOT_READY" ]; then
    NODE_COUNT=$(echo "$NODES" | wc -l)
    green "All $NODE_COUNT nodes are Ready"
else
    red "Nodes not Ready:"
    echo "$NOT_READY" | sed 's/^/    /'
fi

if [ -n "$EXPECTED_VERSION" ]; then
    EXPECTED_KUBELET="v1.$(echo $EXPECTED_VERSION | cut -d. -f2)"
    WRONG_VER=$(oc get nodes --no-headers 2>/dev/null | \
      awk -v ver="$EXPECTED_KUBELET" '$NF !~ ver {print $1, $NF}' || true)
    if [ -z "$WRONG_VER" ]; then
        green "All nodes on expected kubelet version (matching $EXPECTED_KUBELET)"
    else
        red "Nodes on wrong kubelet version:"
        echo "$WRONG_VER" | sed 's/^/    /'
    fi
fi

header "3. ALL CLUSTER OPERATORS HEALTHY"
UNHEALTHY=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$UNHEALTHY" ]; then
    CO_COUNT=$(oc get co --no-headers 2>/dev/null | wc -l)
    green "All $CO_COUNT cluster operators: Available=True Progressing=False Degraded=False"
else
    red "Unhealthy cluster operators:"
    echo "$UNHEALTHY" | sed 's/^/    /'
fi

header "4. MACHINECONFIGPOOLS FULLY UPDATED"
MCP_ISSUES=$(oc get mcp --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$MCP_ISSUES" ]; then
    green "All MCPs: Updated=True Updating=False Degraded=False"
else
    red "MCPs not fully updated:"
    echo "$MCP_ISSUES" | sed 's/^/    /'
fi

header "5. NO PENDING CSRs"
PENDING=$(oc get csr --no-headers 2>/dev/null | grep -v "Approved" || true)
if [ -z "$PENDING" ]; then
    green "No pending or denied CSRs"
else
    yellow "Pending CSRs found — approve with: oc get csr -o name | xargs oc adm certificate approve"
    echo "$PENDING" | sed 's/^/    /'
fi

header "6. ETCD HEALTH"
ETCD_PODS=$(oc get pods -n openshift-etcd --no-headers 2>/dev/null | grep "^etcd-" | grep -v "guard\|pruner")
ETCD_BAD=$(echo "$ETCD_PODS" | awk '$2!="4/4"' || true)
if [ -z "$ETCD_BAD" ]; then
    green "All etcd pods running 4/4"
else
    red "etcd pods not fully ready:"
    echo "$ETCD_BAD" | sed 's/^/    /'
fi

header "7. WEB CONSOLE ACCESSIBLE"
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" \
  https://console-openshift-console.apps.lab.ocp.local 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    green "Web console returned HTTP $HTTP_CODE"
else
    red "Web console returned HTTP $HTTP_CODE (expected 200)"
fi

header "8. ROUTER PODS"
ROUTER_BAD=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | \
  grep "router-default" | awk '$2!="1/1" || $3!="Running"' || true)
ROUTER_COUNT=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep -c "router-default" || true)
if [ -z "$ROUTER_BAD" ] && [ "$ROUTER_COUNT" -ge 2 ]; then
    green "Router pods: $ROUTER_COUNT/2 Running 1/1"
else
    red "Router pods not healthy (count=$ROUTER_COUNT):"
    echo "$ROUTER_BAD" | sed 's/^/    /'
fi

header "9. MONITORING STACK"
MON_BAD=$(oc get pods -n openshift-monitoring --no-headers 2>/dev/null | \
  grep -E "prometheus-k8s|alertmanager|thanos-querier" | \
  awk '$3!="Running"' || true)
if [ -z "$MON_BAD" ]; then
    green "Prometheus, Alertmanager, and Thanos Querier pods Running"
else
    red "Monitoring pods not healthy:"
    echo "$MON_BAD" | sed 's/^/    /'
fi

header "10. DISK SPACE POST-UPGRADE"
for node in $(oc get nodes --no-headers 2>/dev/null | awk '{print $1}'); do
    DISK=$(oc debug node/$node -- chroot /host df -h / /boot 2>/dev/null \
           | grep -v "^Filesystem\|Starting\|chroot")
    ROOT_PCT=$(echo "$DISK" | grep " /$" | awk '{print $5}' | tr -d '%')
    BOOT_FREE=$(echo "$DISK" | grep " /boot$" | awk '{print $4}')
    if [ -n "$ROOT_PCT" ] && [ "$ROOT_PCT" -gt 85 ]; then
        red "$node: / is ${ROOT_PCT}% used — clean up old container images"
    else
        green "$node: / is ${ROOT_PCT}% used  /boot: $BOOT_FREE free"
    fi
done

header "11. KEY WORKLOADS THAT WERE DISRUPTED DURING UPGRADE"
# GitOps application controller
GITOPS=$(oc get pod openshift-gitops-application-controller-0 \
  -n openshift-gitops --no-headers 2>/dev/null | awk '{print $2, $3}')
if echo "$GITOPS" | grep -q "1/1.*Running"; then
    green "openshift-gitops-application-controller-0: $GITOPS"
else
    yellow "openshift-gitops-application-controller-0: $GITOPS"
fi

# virt-api
VIRT_API_BAD=$(oc get pods -n openshift-cnv --no-headers 2>/dev/null | \
  grep "virt-api" | awk '$2!="1/1" || $3!="Running"' | wc -l)
VIRT_API_TOTAL=$(oc get pods -n openshift-cnv --no-headers 2>/dev/null | \
  grep -c "virt-api" || true)
if [ "$VIRT_API_BAD" -eq 0 ] && [ "$VIRT_API_TOTAL" -gt 0 ]; then
    green "virt-api pods: $VIRT_API_TOTAL Running"
else
    yellow "virt-api: $VIRT_API_BAD/$VIRT_API_TOTAL pods not Running (may still be recovering)"
fi

header "12. UPGRADEABLE STATUS FOR NEXT UPGRADE"
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
