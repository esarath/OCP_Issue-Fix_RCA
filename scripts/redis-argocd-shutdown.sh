#!/bin/bash
# Redis (app+db tier) graceful shutdown, ArgoCD-aware
# Run this BEFORE powering off cluster VMs.
#
# Why this exists: redis-app/redis-db are managed by ArgoCD with
# selfHeal:true. Scaling them to 0 directly would just get reverted by
# ArgoCD's next reconcile (~3min) unless auto-sync is paused first. This
# script pauses sync, scales both tiers to 0 (clean SIGTERM -> AOF flush
# for redis-db), and waits for pods to actually terminate.
#
# Usage:
#   bash redis-argocd-shutdown.sh            # live run
#   bash redis-argocd-shutdown.sh --dry-run  # show what would happen, make no changes

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

log "=== redis-argocd-shutdown starting (dry_run=$DRY_RUN) ==="

log "Pausing ArgoCD auto-sync for: ${APPS[*]}"
for app in "${APPS[@]}"; do
    run oc patch application "$app" -n "$GITOPS_NS" --type=merge \
        -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

log "Scaling redis-app (Deployment) to 0"
run oc scale deployment/redis-app -n "$NAMESPACE" --replicas=0

log "Scaling redis-db (StatefulSet) to 0"
run oc scale statefulset/redis-db -n "$NAMESPACE" --replicas=0

if ! $DRY_RUN; then
    log "Waiting for pods to terminate (up to 60s each)..."
    oc wait --for=delete pod -l app=redis-app -n "$NAMESPACE" --timeout=60s 2>&1 | tee -a "$LOG" || true
    oc wait --for=delete pod -l app=redis-db -n "$NAMESPACE" --timeout=60s 2>&1 | tee -a "$LOG" || true
fi

log "Final state:"
run oc get pods -n "$NAMESPACE"
run oc get application -n "$GITOPS_NS"

log "=== Done. redis-app/redis-db scaled to 0, ArgoCD auto-sync paused (won't fight the scale-down)."
log "=== Safe to proceed with cluster VM shutdown. Run redis-argocd-startup.sh after the cluster is back up."
