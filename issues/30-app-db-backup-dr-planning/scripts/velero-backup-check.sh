#!/bin/bash
# =============================================================================
# velero-backup-check.sh — backup health + restore-test audit.
# Read-only. Run weekly; exit 1 if something needs attention.
# =============================================================================
set -euo pipefail
NS=openshift-adp
FAIL=0

echo "=== Velero deployment ==="
oc get deploy velero -n $NS 2>/dev/null || { echo "velero not installed"; exit 1; }
oc get pods -n $NS | grep -E 'velero|node-agent' || true

echo; echo "=== Schedules ==="
oc get schedule -n $NS

echo; echo "=== Last 10 backups ==="
oc get backup -n $NS --sort-by=.metadata.creationTimestamp | tail -10

echo; echo "=== Failed/partial backups ==="
FAILED=$(oc get backup -n $NS -o jsonpath='{.items[?(@.status.phase!="Completed")].metadata.name}')
if [ -n "$FAILED" ]; then echo "ATTENTION: $FAILED"; FAIL=1; else echo "none"; fi

echo; echo "=== Backup storage location status ==="
oc get backupstoragelocation -n $NS -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.lastValidationTime}{"\n"}{end}'

echo; echo "=== Restore history (drill evidence) ==="
oc get restore -n $NS 2>/dev/null || echo "none — a restore test has NEVER been run. Schedule a drill (Guide Part 6.2)."

exit $FAIL
