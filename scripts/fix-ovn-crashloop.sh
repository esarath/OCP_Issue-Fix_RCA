#!/bin/bash
# OCP OVN-Kubernetes Crash-Loop Auto-Remediation
# Detects and fixes the ovnkube-controller startup race (self-referential
# network-node-identity webhook) that can crash-loop a node's OVN pod
# indefinitely after a reboot, leaving the node stuck NotReady with
# "No CNI configuration file in /etc/kubernetes/cni/net.d/".
# RCA: ~/OCP_Issue-Fix_RCA/issues/03-ovn-kubernetes-crash-loop-after-reboot/RCA.md
#
# Distinct from the kubelet-cert-expiry case (issue 01 / approve-csrs.sh):
# that shows node condition status=Unknown reason=NodeStatusUnknown.
# This issue shows status=False reason=KubeletNotReady with a CNI-config
# message, and only after the condition has persisted for a few minutes
# (ruling out a node that is simply still booting normally).
#
# Fixes ONE node at a time, waiting for each to recover before moving to
# the next — deleting multiple ovnkube-node pods simultaneously has been
# observed to destabilize otherwise-healthy nodes via OVN interconnect
# reconciliation. The webhook failurePolicy is ALWAYS reverted to Fail
# before this script exits, even on error (trap below).
#
# Usage:
#   bash fix-ovn-crashloop.sh            # live run
#   bash fix-ovn-crashloop.sh --dry-run  # show what would happen, make no changes

export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig
oc config use-context admin > /dev/null 2>&1

LOG=/home/centos/ovn-crashloop-fix.log
CONSOLE_URL="https://console-openshift-console.apps.lab.ocp.local"
WEBHOOK="network-node-identity.openshift.io"
OVN_NS="openshift-ovn-kubernetes"
STALE_THRESHOLD_SECS=180   # condition must persist this long before we act
NODE_RECOVERY_TIMEOUT=120  # seconds to wait per node after deleting its pod
DRY_RUN=false
WEBHOOK_LOOSENED=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

run() {
    if $DRY_RUN; then
        log "[DRY-RUN] Would run: $*"
    else
        "$@"
    fi
}

set_webhook_policy() {
    local policy="$1"
    run oc patch validatingwebhookconfigurations "$WEBHOOK" --type='json' -p="[
        {\"op\":\"replace\",\"path\":\"/webhooks/0/failurePolicy\",\"value\":\"$policy\"},
        {\"op\":\"replace\",\"path\":\"/webhooks/1/failurePolicy\",\"value\":\"$policy\"}]" > /dev/null 2>&1
    log "Set $WEBHOOK failurePolicy=$policy"
}

# Always leave the webhook the way we found it — even on Ctrl-C, error, or timeout.
cleanup() {
    if $WEBHOOK_LOOSENED; then
        log "Reverting $WEBHOOK failurePolicy to Fail (cleanup)"
        set_webhook_policy "Fail"
    fi
}
trap cleanup EXIT

# ─── Phase 1: Detect nodes stuck in the CNI-not-ready crash-loop signature ───

log "=== Phase 1: Scanning for OVN crash-loop signature ==="

AFFECTED_NODES=()
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    COND_JSON=$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' 2>/dev/null)
    STATUS=$(echo "$COND_JSON" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    REASON=$(echo "$COND_JSON" | grep -o '"reason":"[^"]*"' | cut -d'"' -f4)
    MESSAGE=$(echo "$COND_JSON" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    TRANSITION=$(echo "$COND_JSON" | grep -o '"lastTransitionTime":"[^"]*"' | cut -d'"' -f4)

    if [ "$STATUS" = "False" ] && [ "$REASON" = "KubeletNotReady" ] && [[ "$MESSAGE" == *"No CNI configuration file"* ]]; then
        if [ -n "$TRANSITION" ]; then
            TRANSITION_EPOCH=$(date -d "$TRANSITION" +%s 2>/dev/null)
            NOW_EPOCH=$(date +%s)
            AGE=$((NOW_EPOCH - TRANSITION_EPOCH))
            if [ "$AGE" -ge "$STALE_THRESHOLD_SECS" ]; then
                log "Node $node: NotReady/KubeletNotReady with CNI-config message for ${AGE}s — matches crash-loop signature"
                AFFECTED_NODES+=("$node")
            else
                log "Node $node: shows the CNI-config message but only ${AGE}s old (< ${STALE_THRESHOLD_SECS}s) — likely still booting normally, skipping this run"
            fi
        fi
    fi
done

if [ ${#AFFECTED_NODES[@]} -eq 0 ]; then
    log "No nodes matching the OVN crash-loop signature. Nothing to do."
    exit 0
fi

log "Affected nodes: ${AFFECTED_NODES[*]}"

# ─── Phase 2: Loosen the network-node-identity webhook ──────────────────────

log "=== Phase 2: Loosening $WEBHOOK to break the startup race ==="
CURRENT_POLICY=$(oc get validatingwebhookconfigurations "$WEBHOOK" -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null)
if [ "$CURRENT_POLICY" = "Ignore" ]; then
    log "WARNING: webhook already set to Ignore — a previous run may not have cleaned up. Proceeding, will still revert to Fail on exit."
    WEBHOOK_LOOSENED=true
else
    set_webhook_policy "Ignore"
    WEBHOOK_LOOSENED=true
fi

# ─── Phase 3: Recover affected nodes ONE AT A TIME ───────────────────────────

log "=== Phase 3: Recovering affected nodes (one at a time) ==="
for node in "${AFFECTED_NODES[@]}"; do
    POD=$(oc get pods -n "$OVN_NS" --field-selector spec.nodeName="$node" -o jsonpath='{.items[?(@.metadata.labels.app=="ovnkube-node")].metadata.name}' 2>/dev/null)
    if [ -z "$POD" ]; then
        log "Node $node: could not find its ovnkube-node pod, skipping"
        continue
    fi

    log "Node $node: force-deleting $POD"
    run oc delete pod "$POD" -n "$OVN_NS" --force --grace-period=0 > /dev/null 2>&1

    if $DRY_RUN; then
        continue
    fi

    log "Node $node: waiting up to ${NODE_RECOVERY_TIMEOUT}s for Ready..."
    WAITED=0
    RECOVERED=false
    while [ "$WAITED" -lt "$NODE_RECOVERY_TIMEOUT" ]; do
        sleep 10
        WAITED=$((WAITED + 10))
        NODE_STATUS=$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$NODE_STATUS" = "True" ]; then
            log "Node $node: Ready after ${WAITED}s"
            RECOVERED=true
            break
        fi
    done

    if ! $RECOVERED; then
        log "WARNING: Node $node did not reach Ready within ${NODE_RECOVERY_TIMEOUT}s — moving on, will re-check next run"
    fi
done

# ─── Phase 4: Revert webhook (also handled by trap, done explicitly here too) ─

log "=== Phase 4: Reverting $WEBHOOK to failurePolicy=Fail ==="
set_webhook_policy "Fail"
WEBHOOK_LOOSENED=false

# ─── Phase 5: Final verification ─────────────────────────────────────────────

log "=== Phase 5: Final verification ==="
oc get nodes --no-headers 2>/dev/null | tee -a "$LOG"

STILL_NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l)
if [ "$STILL_NOT_READY" -gt 0 ]; then
    log "WARNING: $STILL_NOT_READY node(s) still not Ready — will re-check on next cron run"
else
    log "All nodes Ready."
fi

HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 15 "$CONSOLE_URL" 2>/dev/null)
log "Console reachability: HTTP $HTTP_CODE"

log "=== OVN crash-loop remediation run complete. Full log: $LOG ==="
