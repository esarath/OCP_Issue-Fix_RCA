# Issue 02 — Minor Version Upgrade: OCP 4.15.59 → 4.16.55

| Field | Detail |
|---|---|
| **Date** | 2026-06-30 |
| **Type** | Planned Upgrade |
| **Severity** | Medium (planned, issues encountered mid-upgrade) |
| **Status** | Completed |
| **From Version** | 4.15.59 |
| **To Version** | 4.16.55 |
| **Upgrade Started** | 2026-06-30 13:29 UTC |
| **Upgrade Completed** | 2026-06-30 17:53 UTC |
| **Total Duration** | ~4h 24m |
| **Cluster** | lab.ocp.local — 3 masters + 2 workers (Proxmox) |

---

## Summary

Minor version upgrade from OCP 4.15 to 4.16 via the `stable-4.16` channel. The upgrade
completed successfully but required manual intervention at three points:

| # | Issue | Fix |
|---|---|---|
| 1 | `thanos-querier` pods hit quay.io image pull rate limit mid-upgrade | Deleted pods to reset backoff — re-pulled cleanly |
| 2 | `openshift-gitops-application-controller` PDB blocked worker-1 node drain | Deleted `openshift-gitops-controller-pdb` temporarily |
| 3 | `virt-api` PDB blocked worker-2 node drain | Deleted `virt-api-pdb` temporarily |

---

## Quick Reference — Pre-Upgrade PDB Audit

Run this before every upgrade to identify PDBs that will block node drains:

```bash
# Find PDBs with 0 allowed disruptions (will block drain)
oc get pdb -A | awk 'NR==1 || $5=="0"'

# Find single-replica workloads on workers that have a PDB
oc get pdb -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    name = item['metadata']['name']
    ns = item['metadata']['namespace']
    allowed = item['status'].get('disruptionsAllowed', 0)
    if allowed == 0:
        print(f'BLOCKED: {ns}/{name}')
"
```

---

## Quick Reference — Fix PDB-Blocked Drain During Upgrade

```bash
# 1. Find which pod is blocking the drain (check MCO controller logs)
oc logs -n openshift-machine-config-operator \
  -l k8s-app=machine-config-controller --tail=10 | grep "evicting\|Cannot evict"

# 2. Delete the blocking PDB (operator will recreate it)
oc delete pdb <pdb-name> -n <namespace>

# 3. MCO retries drain every 5 minutes — confirm success in logs
oc logs -n openshift-machine-config-operator \
  -l k8s-app=machine-config-controller --tail=5 | grep "Evicted\|successful"
```

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full runbook: pre-upgrade, upgrade execution, issue fixes, post-upgrade validation |
| [scripts/pre-upgrade-check.sh](scripts/pre-upgrade-check.sh) | Automated pre-upgrade health and PDB check |
| [scripts/post-upgrade-validate.sh](scripts/post-upgrade-validate.sh) | Automated post-upgrade validation |

---

## Post-Upgrade State (Verified)

```
NAME      VERSION   AVAILABLE   PROGRESSING
version   4.16.55   True        False         ← Cluster version is 4.16.55

All 5 nodes: Ready @ v1.29.14+7b5d27f
All 33 cluster operators: Available=True, Progressing=False, Degraded=False
RHCOS: 416.94.202601071926-0
Kernel: 5.14.0-427.105.1.el9_4.x86_64
CRI-O: 1.29.13
```
