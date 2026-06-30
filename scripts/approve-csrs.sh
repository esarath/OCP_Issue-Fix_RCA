#!/bin/bash
# OCP Cluster Recovery Script
# Handles kubelet certificate renewal and cascading failures after cluster restart
# Runbook: /home/centos/ocp/runbooks/kubelet-cert-recovery.md
#
# Usage:
#   bash approve-csrs.sh            # live run
#   bash approve-csrs.sh --dry-run  # show what would happen, make no changes

export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig
oc config use-context admin > /dev/null 2>&1

LOG=/home/centos/csr-approval.log
CONSOLE_URL="https://console-openshift-console.apps.lab.ocp.local"
DRY_RUN=false

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

approve_pending_csrs() {
    local PENDING
    PENDING=$(oc get csr 2>/dev/null | grep -c Pending || true)
    if [ "$PENDING" -gt 0 ]; then
        log "Found $PENDING pending CSR(s) — approving..."
        oc get csr -o name 2>/dev/null | while read -r csr; do
            STATUS=$(oc get "$csr" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null)
            if [ -z "$STATUS" ]; then
                run oc adm certificate approve "$csr" 2>/dev/null
                log "Approved $csr"
            fi
        done
    else
        log "No pending CSRs found."
    fi
}

# ─── Phase 1: Approve kubelet client certificates ────────────────────────────

log "=== Phase 1: Kubelet client certificate renewal ==="
approve_pending_csrs

log "Waiting 60s for kubelet serving CSRs to appear..."
$DRY_RUN || sleep 60

# ─── Phase 2: Approve kubelet serving certificates ───────────────────────────

log "=== Phase 2: Kubelet serving certificate renewal ==="
approve_pending_csrs

# ─── Phase 3: Verify nodes are Ready ─────────────────────────────────────────

log "=== Phase 3: Node status check ==="
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l)
if [ "$NOT_READY" -gt 0 ]; then
    log "WARNING: $NOT_READY node(s) not Ready — waiting 30s and rechecking..."
    $DRY_RUN || sleep 30
    oc get nodes 2>/dev/null | tee -a "$LOG"
else
    log "All nodes Ready."
    oc get nodes --no-headers 2>/dev/null | tee -a "$LOG"
fi

# ─── Phase 4: Clean up stuck Terminating ingress router pods ─────────────────

log "=== Phase 4: Ingress router pod cleanup ==="
TERMINATING=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep Terminating | awk '{print $1}')
if [ -n "$TERMINATING" ]; then
    log "Force-deleting stuck Terminating router pods: $TERMINATING"
    run oc delete pod -n openshift-ingress $TERMINATING --force --grace-period=0 2>/dev/null
    log "Waiting 20s for new router pods to schedule..."
    $DRY_RUN || sleep 20
else
    log "No stuck Terminating router pods found."
fi

# ─── Phase 5: Check and recover DNS pods ─────────────────────────────────────

log "=== Phase 5: DNS pod health check ==="
DNS_DEGRADED=$(oc get clusteroperator dns --no-headers 2>/dev/null | grep -v "True.*False.*False" | wc -l)
if [ "$DNS_DEGRADED" -gt 0 ]; then
    log "DNS operator degraded — checking for stuck pods..."
    STUCK_DNS=$(oc get pods -n openshift-dns --no-headers 2>/dev/null | grep -v " Running" | awk '{print $1}')
    if [ -n "$STUCK_DNS" ]; then
        log "Deleting stuck DNS pods: $STUCK_DNS"
        run oc delete pod -n openshift-dns $STUCK_DNS 2>/dev/null
        log "Waiting 30s for DNS pods to reschedule..."
        $DRY_RUN || sleep 30
    fi
else
    log "DNS operator healthy."
fi

# ─── Phase 6: Final verification ─────────────────────────────────────────────

log "=== Phase 6: Final verification ==="

# Cluster operators
DEGRADED_OPS=$(oc get clusteroperator --no-headers 2>/dev/null | grep -v "True.*False.*False")
if [ -n "$DEGRADED_OPS" ]; then
    log "WARNING: Degraded cluster operators:"
    echo "$DEGRADED_OPS" | tee -a "$LOG"
else
    log "All cluster operators healthy."
fi

# Router pods
log "Ingress router pods:"
oc get pods -n openshift-ingress -o wide --no-headers 2>/dev/null | tee -a "$LOG"

# Pending CSRs
REMAINING=$(oc get csr 2>/dev/null | grep -c Pending || true)
if [ "$REMAINING" -gt 0 ]; then
    log "WARNING: $REMAINING CSR(s) still pending — you may need to re-run this script."
else
    log "No pending CSRs."
fi

# Console reachability
log "Testing console reachability..."
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 15 "$CONSOLE_URL" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    log "SUCCESS: Console is reachable ($CONSOLE_URL) — HTTP $HTTP_CODE"
else
    log "WARNING: Console returned HTTP $HTTP_CODE — may still be starting up, retry in ~60s"
fi

log "=== Recovery complete. Full log: $LOG ==="
