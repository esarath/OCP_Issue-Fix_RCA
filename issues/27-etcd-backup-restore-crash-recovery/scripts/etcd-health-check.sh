#!/bin/bash
# =============================================================================
# etcd-health-check.sh — quick etcd health readout for the lab cluster.
# Read-only; safe to run any time.
# =============================================================================
set -euo pipefail

NS=openshift-etcd
POD=$(oc get pods -n $NS -l app=etcd -o jsonpath='{.items[0].metadata.name}')

echo "=== etcd pods ==="
oc get pods -n $NS -l app=etcd -o wide

echo; echo "=== member list (raft status) ==="
oc -n $NS exec "$POD" -c etcdctl -- etcdctl member list -w table

echo; echo "=== endpoint health ==="
oc -n $NS exec "$POD" -c etcdctl -- etcdctl endpoint health --cluster -w table

echo; echo "=== alarms ==="
oc -n $NS exec "$POD" -c etcdctl -- etcdctl alarm list || true

echo; echo "=== operator status ==="
oc get clusteroperator etcd
oc get etcd cluster -o jsonpath='{.status.conditions}' 2>/dev/null | head -5
