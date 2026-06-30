# OCP Minor Version Upgrade Runbook — 4.15 → 4.16

**Cluster**: lab.ocp.local | Proxmox | 3 masters + 2 workers
**Tested on**: 4.15.59 → 4.16.55 (2026-06-30)

This document serves as both the RCA for issues encountered and a reusable runbook
for future minor version upgrades on this cluster.

---

## Table of Contents

1. [Pre-Upgrade Checklist](#1-pre-upgrade-checklist)
2. [Initiating the Upgrade](#2-initiating-the-upgrade)
3. [Monitoring the Upgrade](#3-monitoring-the-upgrade)
4. [Issues Encountered & Fixes](#4-issues-encountered--fixes)
5. [Post-Upgrade Validation](#5-post-upgrade-validation)
6. [Rollback Reference](#6-rollback-reference)

---

## 1. Pre-Upgrade Checklist

Complete every item before initiating the upgrade. A failed pre-check item is a
reason to postpone the upgrade.

### 1.1 Verify Cluster Health

```bash
export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig

# All nodes must be Ready with no taints other than master role taint
oc get nodes
# Expected: all STATUS=Ready, no SchedulingDisabled

# All cluster operators must be Available=True, Progressing=False, Degraded=False
oc get co
# Expected: no False in AVAILABLE column, no True in PROGRESSING/DEGRADED

# No pending or failed CSRs
oc get csr
# Expected: all Approved or no output

# etcd must be healthy (3 members, all healthy)
oc get etcd -o jsonpath='{.items[0].status.conditions[?(@.type=="EtcdMembersAvailable")].message}'
# Expected: "3 members are available"
```

### 1.2 Check Disk Space on All Nodes

Minimum requirements before upgrade: **root/var ≥ 15% free**, **/boot ≥ 100 MB free**.
The upgrade pulls hundreds of container images and new OS layers.

```bash
# Check disk on each node via debug pod
for node in master-1 master-2 master-3 worker-1 worker-2; do
  echo "=== ${node}.lab.ocp.local ==="
  oc debug node/${node}.lab.ocp.local -- chroot /host df -h / /var /boot 2>/dev/null \
    | grep -v "^Filesystem\|Starting\|chroot"
done
```

**Disk space seen during this upgrade (post-upgrade — slightly higher than pre-upgrade):**

| Node | / Used | / Free | /boot Free |
|---|---|---|---|
| master-1 | 37G / 80G (47%) | 43G | 208M |
| master-2 | 42G / 80G (52%) | 39G | 208M |
| master-3 | 41G / 80G (52%) | 39G | 208M |
| worker-1 | 20G / 80G (26%) | 60G | 208M |
| worker-2 | 21G / 80G (27%) | 59G | 208M |

> **Rule of thumb**: If any node is above 80% on `/` or `/var`, clean up old container
> images before upgrading: `oc debug node/<name> -- chroot /host crictl rmi --prune`

### 1.3 PDB Audit — Critical Step

PodDisruptionBudgets with `allowedDisruptions=0` will block the MCO from draining
nodes during the upgrade. Identify and plan for them **before** starting.

```bash
# List all PDBs with 0 allowed disruptions
oc get pdb -A | awk 'NR==1 || $5=="0"'

# Show which deployments/statefulsets they protect and replica count
oc get pdb -A -o json | python3 - << 'EOF'
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    ns = item['metadata']['name']
    name = item['metadata']['name']
    namespace = item['metadata']['namespace']
    allowed = item['status'].get('disruptionsAllowed', 0)
    current = item['status'].get('currentHealthy', '?')
    desired = item['status'].get('desiredHealthy', '?')
    if allowed == 0:
        print(f"WILL BLOCK DRAIN: {namespace}/{name}  "
              f"(healthy={current}, desired={desired}, allowed={allowed})")
EOF
```

**PDBs that blocked this upgrade:**

| Namespace | PDB | Pod | Why blocked |
|---|---|---|---|
| `openshift-gitops` | `openshift-gitops-controller-pdb` | `openshift-gitops-application-controller-0` | StatefulSet 1 replica, minAvailable=1 |
| `openshift-cnv` | `virt-api-pdb` | `virt-api-*` | Deployment 1 ready replica, minAvailable=1 |

**Decision**: These PDBs can be safely deleted during the drain phase. The operators
that own them (GitOps, CNV) recreate them automatically once the pods reschedule.

### 1.4 Verify Pull Secret

The upgrade pulls ~200+ images from quay.io. Confirm the pull secret has valid
authenticated credentials (authenticated accounts have higher rate limits than anonymous).

```bash
# Confirm quay.io key is present and has a username
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  python3 -c "
import json,sys,base64
d=json.load(sys.stdin)
q=d['auths'].get('quay.io',{})
a=q.get('auth','')
creds=base64.b64decode(a).decode() if a else ''
print('Has auth:', bool(a))
print('User:', creds.split(':')[0] if ':' in creds else 'MISSING')
"
# Expected: Has auth: True, User: <service-account-name>
```

### 1.5 Check Available Update Path

```bash
# Verify 4.16 target is available from current version
oc adm upgrade
# Look for "Recommended updates:" section listing 4.16.x

# Confirm the specific target image digest
oc adm upgrade --to-image=quay.io/openshift-release-dev/ocp-release:4.16.55-x86_64 \
  --allow-explicit-upgrade --dry-run 2>/dev/null || \
oc adm upgrade channel stable-4.16
```

### 1.6 Take an etcd Backup

```bash
# Run backup on one master node
oc debug node/master-1.lab.ocp.local -- \
  chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# Copy backup off the node
BACKUP_DIR=/home/centos/etcd-snapshots/pre-upgrade-4.16-$(date +%Y%m%d)
mkdir -p $BACKUP_DIR
# scp or oc cp the backup files
```

> Previous etcd snapshots stored in: `/home/centos/etcd-snapshots/`

### 1.7 Set Upgrade Channel

```bash
# Set to stable-4.16 channel
oc patch clusterversion version --type merge \
  -p '{"spec":{"channel":"stable-4.16"}}'

# Confirm channel set
oc get clusterversion -o jsonpath='{.items[0].spec.channel}'
# Expected: stable-4.16
```

---

## 2. Initiating the Upgrade

```bash
# Start the upgrade to a specific z-stream release
oc adm upgrade --to=4.16.55

# Confirm upgrade is progressing (should show Progressing=True within 60s)
oc get clusterversion
```

Start the background monitor to log upgrade progress:

```bash
# Start upgrade monitor (logs every 60s to upgrade-4.16.55.log)
nohup /home/centos/ocp/upgrade-logs/monitor.sh &
echo "Monitor PID: $!"

# Watch live
tail -f /home/centos/ocp/upgrade-logs/upgrade-4.16.55.log
```

---

## 3. Monitoring the Upgrade

### 3.1 Key Commands

```bash
# Overall progress (check every 5-10 min)
oc get clusterversion

# Operators with issues (filter out fully-healthy ones)
oc get co | grep -v "True.*False.*False"

# Node status during MCO phase
oc get nodes

# MachineConfigPool status
oc get mcp

# Watch multus rollout (network operator phase)
oc get pods -n openshift-multus | grep multus-additional-cni

# Watch node drain progress (MCO phase)
oc logs -n openshift-machine-config-operator \
  -l k8s-app=machine-config-controller --tail=10 | grep -v "certificate"
```

### 3.2 Upgrade Phases

The upgrade progresses through these phases (in order):

| Phase | Operator(s) | What Happens | Typical Duration |
|---|---|---|---|
| 1. Control plane operators | kube-apiserver, kube-controller-manager, kube-scheduler | Operator rollouts, new manifests applied | 20–40 min |
| 2. Network rollout | network (multus) | New multus CNI plugins deployed node-by-node; CNI briefly disrupted per node | 30–60 min |
| 3. Monitoring stack | monitoring | Prometheus, thanos-querier, alertmanager updated | 10–20 min |
| 4. Node OS update (MCO) | machine-config | Each node: cordon → drain → rpm-ostree OS update → reboot → uncordon | 15–20 min per node |
| 5. Final operators | ingress, authentication, console, etc. | Remaining operator rollouts | 10–20 min |

### 3.3 Normal vs. Concerning Behaviour

| Symptom | Normal? | Action |
|---|---|---|
| Progress counter drops (e.g. 80% → 14%) | Yes | CVO recounts at each phase boundary |
| `MultipleErrors` on clusterversion for a few minutes | Yes | Transient during network rollout |
| Nodes `NotReady` for 2–5 min | Yes | MCO reboot in progress |
| Nodes `SchedulingDisabled` for 10–40 min | Yes | MCO drain + OS update in progress |
| `ErrImagePull` / `ImagePullBackOff` for a few minutes | Often yes | Transient; retry usually succeeds |
| Same pod stuck `Pending` for >15 min | No | Investigate scheduling constraint |
| MCO drain stuck >15 min | No | Check for PDB blocking eviction |
| Same `ErrImagePull` repeated for >10 min | No | Check for `pull QPS exceeded` — delete pod to reset backoff |

---

## 4. Issues Encountered & Fixes

### Issue A — quay.io Image Pull Rate Limit (thanos-querier)

**When**: During network operator rollout (~90 min into upgrade)

**Symptom**:
```
thanos-querier-*   4/6   ErrImagePull   6   ...
```
Container `thanos-query` stuck with:
```
state: {"waiting":{"message":"pull QPS exceeded","reason":"ErrImagePull"}}
```

**Root Cause**: The upgrade pulled 200+ images from quay.io in rapid succession. The
multus CNI upgrade disrupted worker node network, forcing thanos-querier pods to restart
and re-pull images. The quay.io per-second rate limit was hit on the retries. The pod
had restarted 6 times, pushing its backoff to 10+ minutes.

**Impact**: `thanos-querier` service endpoint down → `kube-controller-manager` garbage
collector could not reach `https://thanos-querier.openshift-monitoring.svc:9091` →
KCM marked Degraded → upgrade stalled waiting on KCM.

**Fix**:
```bash
# Delete both stuck pods to reset backoff (Deployment recreates them immediately)
oc delete pod thanos-querier-<hash>-<id1> thanos-querier-<hash>-<id2> \
  -n openshift-monitoring

# Verify new pods come up 6/6
oc get pods -n openshift-monitoring | grep thanos-querier
# Expected: 6/6 Running within 2-3 minutes
```

**Prevention**: Nothing to pre-configure. If you see `ErrImagePull` with `pull QPS exceeded`
on any pod during an upgrade, deleting the pod immediately (rather than waiting for
exponential backoff) is the fastest recovery.

---

### Issue B — PDB Blocking MCO Drain on worker-1

**When**: MCO node OS update phase, worker-1

**Symptom**: MCO drain controller log repeating every 5 seconds for 47+ minutes:
```
error when evicting pods/"openshift-gitops-application-controller-0" -n "openshift-gitops"
(will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

Node annotation confirmed drain was requested but never acknowledged:
```
machineconfiguration.openshift.io/desiredDrain:   drain-rendered-worker-eed7e2b00...
machineconfiguration.openshift.io/lastAppliedDrain: uncordon-rendered-worker-97b9f39...
```

**Root Cause**: `openshift-gitops-application-controller` StatefulSet runs 1 replica.
Its PDB `openshift-gitops-controller-pdb` requires `minAvailable=1`, leaving
`allowedDisruptions=0`. With only 1 pod, eviction is always blocked.

**Fix**:
```bash
# Confirm the blocking PDB
oc get pdb openshift-gitops-controller-pdb -n openshift-gitops

# Delete it — GitOps operator recreates it automatically
oc delete pdb openshift-gitops-controller-pdb -n openshift-gitops

# MCO retries drain every 5 minutes after a 10-min failure window
# Watch for success in controller logs
oc logs -n openshift-machine-config-operator \
  -l k8s-app=machine-config-controller --tail=5 | grep "Evicted\|successful"
# Expected: "Evicted pod openshift-gitops/openshift-gitops-application-controller-0"
#           "operation successful; applying completion annotation"
```

---

### Issue C — PDB Blocking MCO Drain on worker-2

**When**: MCO node OS update phase, worker-2 (immediately after worker-1 completed)

**Symptom**: Same pattern as Issue B, different pod:
```
error when evicting pods/"virt-api-575bd7dfbd-nsm2z" -n "openshift-cnv"
(will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

**Root Cause**: `virt-api` Deployment had 1 ready replica on worker-2 (the other replica
was not ready). PDB `virt-api-pdb` requires `minAvailable=1` → `allowedDisruptions=0`.

**Fix**:
```bash
oc delete pdb virt-api-pdb -n openshift-cnv
# CNV operator recreates it automatically after pods reschedule
```

---

## 5. Post-Upgrade Validation

Run every check below in order. **Do not declare the upgrade complete until all pass.**

### 5.1 Cluster Version

```bash
oc get clusterversion
```
**Expected**:
```
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.16.55   True        False         Xm      Cluster version is 4.16.55
```
Fail if: `PROGRESSING=True`, `AVAILABLE=False`, or version is not the target.

### 5.2 All Nodes Ready and Updated

```bash
oc get nodes -o wide
```
**Expected**: All nodes `STATUS=Ready` (no `SchedulingDisabled`, no `NotReady`).
All nodes on the new kubelet version (`v1.29.14+7b5d27f` for 4.16.55).

```bash
# Quick version check — all must match
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

### 5.3 All Cluster Operators Healthy

```bash
oc get co
```
**Expected**: Every row shows `True / False / False` (Available / Progressing / Degraded).

```bash
# Fail-fast: this should return only the header
oc get co | grep -v "True.*False.*False"
```

### 5.4 MachineConfigPools Fully Updated

```bash
oc get mcp
```
**Expected**: Both `master` and `worker` pools show `UPDATED=True, UPDATING=False, DEGRADED=False`,
and `READYMACHINECOUNT` equals `MACHINECOUNT`.

### 5.5 No Pending or Denied CSRs

```bash
oc get csr | grep -v "Approved\|NAME"
# Expected: no output
```

If pending CSRs exist (common after node reboots):
```bash
oc get csr -o name | xargs oc adm certificate approve
```

### 5.6 etcd Health

```bash
# All 3 etcd pods running 4/4
oc get pods -n openshift-etcd | grep "^etcd-"
# Expected: all 4/4 Running

# etcd members report healthy
oc rsh -n openshift-etcd etcd-master-1.lab.ocp.local \
  etcdctl endpoint health --cluster 2>/dev/null
# Expected: all endpoints healthy=true
```

### 5.7 Disk Space (Post-Upgrade)

```bash
for node in master-1 master-2 master-3 worker-1 worker-2; do
  echo "=== ${node}.lab.ocp.local ==="
  oc debug node/${node}.lab.ocp.local -- chroot /host df -h / /boot 2>/dev/null \
    | grep -v "^Filesystem\|Starting\|chroot"
done
```
**Expected**: No node above 85% on `/`. `/boot` free > 100 MB.

**Post-upgrade disk usage observed (2026-06-30)**:

| Node | / Used | / Free | /boot Free |
|---|---|---|---|
| master-1 | 37G / 80G (47%) | 43G | 208M ✓ |
| master-2 | 42G / 80G (52%) | 39G | 208M ✓ |
| master-3 | 41G / 80G (52%) | 39G | 208M ✓ |
| worker-1 | 20G / 80G (26%) | 60G | 208M ✓ |
| worker-2 | 21G / 80G (27%) | 59G | 208M ✓ |

### 5.8 Web Console Accessible

```bash
curl -k -s -o /dev/null -w "%{http_code}" \
  https://console-openshift-console.apps.lab.ocp.local
# Expected: 200
```

Also verify login via browser: `https://console-openshift-console.apps.lab.ocp.local`

### 5.9 Router Pods Healthy

```bash
oc get pods -n openshift-ingress
# Expected: all router-default-* pods Running 1/1, 2 replicas
```

### 5.10 Monitoring Stack Healthy

```bash
oc get pods -n openshift-monitoring | grep -E "prometheus-k8s|alertmanager|thanos-querier"
# Expected: all Running with full container counts
```

### 5.11 Key Workloads Healthy

```bash
# GitOps controller (was disrupted during upgrade)
oc get pod openshift-gitops-application-controller-0 -n openshift-gitops
# Expected: 1/1 Running

# CNV virt-api (was disrupted during upgrade)
oc get pods -n openshift-cnv | grep virt-api
# Expected: all Running

# Image registry
oc get pods -n openshift-image-registry
# Expected: image-registry-* Running 1/1
```

### 5.12 No Firing Critical Alerts

```bash
# Check for critical alerts via Prometheus API
oc -n openshift-monitoring exec -c prometheus \
  $(oc get pod -n openshift-monitoring -l app.kubernetes.io/name=prometheus \
    --no-headers | head -1 | awk '{print $1}') -- \
  curl -s 'http://localhost:9090/api/v1/alerts' | \
  python3 -c "
import json,sys
data=json.load(sys.stdin)
alerts=[a for a in data['data']['alerts'] if a['labels'].get('severity') in ('critical','warning')]
for a in alerts[:10]: print(a['labels'].get('alertname'), a['labels'].get('severity'))
print(f'Total: {len(alerts)} active alerts')
"
```

### 5.13 Upgrade Next-Step Warning (for future 4.17 upgrade)

```bash
oc get clusterversion -o jsonpath='{.items[0].status.conditions[?(@.type=="Upgradeable")].message}'
```

On this cluster post-4.16 upgrade, you will see:
```
Cluster operator kube-apiserver should not be upgraded between minor versions:
KubeletMinorVersionUpgradeable: Kubelet minor versions on 5 nodes will not be
supported in the next OpenShift minor version upgrade.
```
This warning is **expected and non-blocking for 4.16 operation**. It is a reminder
that before upgrading to 4.17, the kubelet versions must first be at 4.16 levels
(which they are after a successful 4.15→4.16 upgrade — this warning clears on its own
within ~24 hours as the cluster reconciles).

---

## 6. Rollback Reference

OCP does not support automated rollback after an upgrade completes. However:

**If upgrade stalls and has not passed 50% + node reboots started**:
```bash
# Pause the upgrade
oc patch clusterversion version --type merge -p '{"spec":{"desiredUpdate":null}}'
```

**If nodes have already been rebooted to new OS**: Full rollback is not possible without
restoring from etcd snapshot. Etcd snapshot taken in pre-upgrade step can be used
following the OCP etcd restore procedure.

**Pre-upgrade etcd snapshot location**: `/home/centos/etcd-snapshots/`

---

## Appendix — Upgrade Timeline (2026-06-30)

| Time (UTC) | Event |
|---|---|
| 13:29 | Upgrade initiated: 4.15.59 → 4.16.55 |
| 13:30–15:50 | Control plane operators and network operator rolling out |
| 15:53 | `thanos-querier` hit quay.io rate limit; pods deleted to fix |
| 16:10 | Network operator (multus) completed |
| 16:23 | MCO started worker-1 OS update; drain blocked by `openshift-gitops` PDB |
| 17:18 | `openshift-gitops-controller-pdb` deleted; drain succeeded |
| 17:26 | worker-1 rebooting |
| 17:40 | MCO started worker-2 OS update; drain blocked by `virt-api` PDB |
| 17:41 | `virt-api-pdb` deleted |
| 17:53 | **Upgrade complete: 4.16.55** |
