#!/bin/bash
# Redis (app+db tier) startup, ArgoCD-aware
# Run this AFTER the cluster is back up (nodes Ready, ArgoCD pods Running).
# Safe no-op if auto-sync was never paused / replicas already correct.
#
# Undoes redis-argocd-shutdown.sh: re-enables ArgoCD auto-sync (prune +
# selfHeal), forces an immediate refresh so it reconciles replica counts
# back to desired state without waiting for the ~3min poll, then waits
# for pods to become Ready and reports final status.
#
# Usage:
#   bash redis-argocd-startup.sh            # live run
#   bash redis-argocd-startup.sh --dry-run  # show what would happen, make no changes

export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig
oc config use-context admin > /dev/null 2>&1

LOG=/home/centos/redis-argocd-lifecycle.log
NAMESPACE=redis-platform
GITOPS_NS=openshift-gitops
APPS=(redis-platform-appl redis-app-appl redis-db-appl)
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

run() {
    if $DRY_RUN; then
        log "DRY-RUN: would run: $*"
    else
        log "running: $*"
        "$@" 2>&1 | tee -a "$LOG"
    fi
}

log "=== redis-argocd-startup starting (dry_run=$DRY_RUN) ==="

log "Waiting for openshift-gitops-server to be reachable (up to 5min)..."
if ! $DRY_RUN; then
    for i in $(seq 1 30); do
        if oc get application -n "$GITOPS_NS" > /dev/null 2>&1; then
            log "openshift-gitops API reachable."
            break
        fi
        sleep 10
    done
fi

log "Re-enabling ArgoCD auto-sync for: ${APPS[*]}"
for app in "${APPS[@]}"; do
    run oc patch application "$app" -n "$GITOPS_NS" --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done

log "Forcing immediate refresh (skip the ~3min poll wait)"
for app in "${APPS[@]}"; do
    run oc annotate application "$app" -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite
done

if ! $DRY_RUN; then
    log "Waiting for redis-app pods to be Ready (up to 180s)..."
    oc wait --for=condition=Ready pod -l app=redis-app -n "$NAMESPACE" --timeout=180s 2>&1 | tee -a "$LOG" || true
    log "Waiting for redis-db pod to be Ready (up to 180s)..."
    oc wait --for=condition=Ready pod -l app=redis-db -n "$NAMESPACE" --timeout=180s 2>&1 | tee -a "$LOG" || true
fi

log "Final status:"
run oc get application -n "$GITOPS_NS"
run oc get pods -n "$NAMESPACE"
run oc get pvc -n "$NAMESPACE"
run oc get pdb -n "$NAMESPACE"

log "=== Done. Compare against Section 9 of the LLD if anything looks off:"
log "=== https://github.com/esarath/OCP_Issue-Fix_RCA/blob/main/issues/15-redis-app-db-gitops-deployment/Redis-OCP-GitOps-LLD.md"
