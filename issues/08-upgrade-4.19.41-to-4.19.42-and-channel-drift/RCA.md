# RCA — Upgrade 4.19.41 → 4.19.42: Worker Image Pull Stall + Post-Upgrade Channel Drift

**Cluster**: lab.ocp.local | Proxmox | 3 masters + 2 workers
**Upgrade**: 4.19.41 → 4.19.42
**Started**: 2026-08-20 06:50:07 UTC | **Completed**: 2026-08-20 09:01:06 UTC (~2h11m)

---

## Pre-upgrade state

```
$ oc get clusterversion
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.19.41   True        False         37h     Cluster version is 4.19.41

$ oc get co   # all Available=True/Progressing=False/Degraded=False
$ oc get nodes   # all 5 Ready
$ oc adm upgrade
Channel: stable-4.19
Recommended updates:
  VERSION     IMAGE
  4.19.42     quay.io/openshift-release-dev/ocp-release@sha256:b49da113...
```
Clean baseline confirmed before proceeding.

## etcd backup

Taken via `cluster-backup.sh` on master-1 before triggering the upgrade:
```
$ oc debug node/master-1.lab.ocp.local -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup
...
Snapshot saved at /home/core/assets/backup/snapshot_2026-08-20_064920.db
{"hash":3169114825,"revision":4484008,"totalKey":15473,"totalSize":95723520}
```
96MB snapshot + static pod resources, verified present (`ls -la`) and copied off-node via
`oc debug ... -- chroot /host tar -C /home/core/assets/backup -cf - .` streamed to a local tarball
(avoided SSH — see below).

**Note**: SSH to `master-1.lab.ocp.local` failed host-key verification (`REMOTE HOST
IDENTIFICATION HAS CHANGED`). Did not override `known_hosts` blindly; used the `oc debug` +
`tar` stream over the API server instead, which requires no SSH trust at all. Worth
investigating separately why the host key changed.

## Upgrade trigger

```
$ oc adm upgrade --to=4.19.42
Requested update to 4.19.42
```
Audit-confirmed: `2026-08-20T06:50:07Z`, `verb: patch`, `user: system:admin`, `resource:
clusterversions/version` — this session's action, correctly scoped to `--to=4.19.42` only
(did not touch `spec.channel`).

CVO picked up the new `spec.desiredUpdate` on the next reconcile (~90s later, generation
17→18) and began rolling out.

## Stall at 86%

```
$ oc get clusterversion version -o jsonpath='...'
Working towards 4.19.42: 794 of 923 done (86% complete), waiting on machine-config
```
Held at this state from ~08:09 UTC through ~08:49 UTC (~40 min).

```
$ oc get co machine-config
NAME             VERSION   AVAILABLE   PROGRESSING   DEGRADED   MESSAGE
machine-config   4.19.41   True        True          True       Unable to apply 4.19.42:
  error during waitForDaemonsetRollout: [context deadline exceeded, daemonset
  machine-config-daemon is not ready. status: (desired: 5, updated: 3, ready: 4, unavailable: 1)]

$ oc get pods -n openshift-machine-config-operator
machine-config-daemon-hx8hz   1/2   ImagePullBackOff   0   32m   192.168.29.32   worker-2.lab.ocp.local
```

**Ruled out first**: `oc get mcp` showed no MachineConfigPool actually `UPDATING` — same
rendered config, same OS image on all 5 nodes throughout. This was purely the
`machine-config` *operator's own* DaemonSet failing to roll out, not a node OS/reboot stall
(different from issue 09's failure mode).

### Pod-level diagnosis
```
$ oc describe pod machine-config-daemon-hx8hz -n openshift-machine-config-operator
...
Warning  Failed  32m  kubelet  Failed to pull image "...ocp-v4.0-art-dev@sha256:cd7248e4...":
  dial tcp 32.199.235.149:443: connect: network is unreachable
Warning  Failed  32m  kubelet  Failed to pull image "...":
  dial tcp [2600:1f18:d77:9001:852c:b033:9764:47b9]:443: connect: network is unreachable
Warning  Failed  29m (x5)  kubelet  ... lookup quay.io on 192.168.29.10:53: server misbehaving
Normal   BackOff  2m35s (x122 over 32m)  kubelet  Back-off pulling image ...
```
Two distinct failure modes interleaved: an IPv6 "network unreachable" (majority) and an
intermittent DNS "server misbehaving." Both point at name resolution / addressing, not
registry auth or disk space.

### DNS investigation
```
$ oc debug node/worker-2.lab.ocp.local -- chroot /host getent hosts quay.io
2600:1f18:d77:9001:...  quay.io   (x8, all IPv6, no A records returned)

$ oc debug node/worker-2.lab.ocp.local -- chroot /host ip route
default via 192.168.29.99 dev br-ex   # IPv4 only — no IPv6 default route

$ oc debug node/worker-2.lab.ocp.local -- chroot /host ip -6 route
# no default IPv6 route — same on worker-1 (checked for comparison)

$ oc debug node/worker-2.lab.ocp.local -- chroot /host dig +short A quay.io @192.168.29.10
100.59.151.36
3.229.30.151
32.199.235.149
54.144.130.43
107.20.140.110
54.175.201.215
98.85.70.196
32.194.242.93
```
The DNS server (`192.168.29.10`) **does** hold valid A records and serves them correctly to
an explicit, type-specific query. But the combined-lookup path (`getent hosts`, and by
extension whatever CRI-O/Go's resolver uses under the hood) surfaces only the AAAA answers,
which are then unreachable because no node in this cluster has any IPv6 route.

### Why worker-1 didn't hit this
```
$ oc debug node/worker-1.lab.ocp.local -- chroot /host getent hosts quay.io
# identical IPv6-only result — same underlying condition exists on worker-1 too

$ oc debug node/worker-1.lab.ocp.local -- chroot /host crictl images | grep ocp-v4.0-art-dev | wc -l
# ~190 layers already cached locally
```
worker-1 has the same latent DNS behavior but never needed to actually hit the network for
this digest — it already had ~190 `ocp-v4.0-art-dev` layers cached from prior upgrades
(including issue 09). worker-2 lacked the cache and hit the bug on a genuinely fresh pull.

## Resolution

Kubelet's built-in retry/backoff eventually succeeded on its own:
```
08:49:33  794/923 (86%) waiting on machine-config
08:51:05  374/923 (40%)
08:58:49  117/923 (12%) waiting up to 40 min on etcd     <- CVO task-count fluctuation, not a regression
09:00:20  673/923 (72%)
09:01:06  Progressing=False — Cluster version is 4.19.42
```
(The non-monotonic percentage across these lines reflects the CVO's internal task counter
across different sync passes/operators, not the upgrade going backward.)

A manual `oc delete pod machine-config-daemon-hx8hz` was proposed and, after user
confirmation, executed at approximately the same time — but by the time it landed the
DaemonSet had already self-recovered (confirmed: the resulting pod `machine-config-daemon-zlgtz`
was already `2/2 Running` at 11s old, i.e., a routine replacement of an already-healthy
rollout, not a rescue of a stuck one).

## Post-upgrade verification

```
$ oc get clusterversion   # 4.19.42, Available=True, Progressing=False
$ oc get co               # all healthy, including machine-config (Degraded=False)
$ oc get nodes            # all 5 Ready
$ oc get pods -n openshift-machine-config-operator | grep daemon   # all 2/2 Running
```
No etcd impact, no data loss, no node outage. Backup was never needed but is retained
(on master-1 and off-node) per standard practice.

## Resource/health review (requested separately)

```
$ oc adm top nodes
master-3   11% cpu   88% mem
worker-1   11% cpu   81% mem
(others 60-70% mem, 5-13% cpu)

$ oc get nodes -o custom-columns=...DISK...
master-3: 82% /var used (15G free of 80G)   <- tightest node
worker-1: 80% /var used (17G free of 80G)

$ oc get nodes -o ...   # DiskPressure/MemoryPressure/PIDPressure all False on all nodes
$ oc get pvc -A         # all Bound
```
No blocking issues. `KubeMemoryOvercommit` alert present but consistent with the headroom
numbers above, not an active fault.

Non-critical, pre-existing, unrelated to this upgrade (noted, not investigated further per
user direction): `ErrClaimNotValid` on several `openshift-virtualization-os-images`
DataVolumes — missing `accessMode`/`volumeMode` on the `nfs-storage` StorageProfile.

## Part 2 — Channel drift investigation

Full detail and remediation in [README.md](README.md#part-2--post-upgrade-update-channel-drift-attribution-gap).
Audit trail commands used:
```
$ oc get clusterversion version -o jsonpath='{.spec.channel}'
# candidate-4.20  (expected stable-4.19 — investigated)

$ oc debug node/master-1.lab.ocp.local -- chroot /host grep -l "candidate-4.20" /var/log/kube-apiserver/audit*.log
# no hits — audit profile "Default" doesn't log request bodies, only metadata

# Searched for the PATCH verb itself (not the value) across all three masters' audit logs:
$ for m in master-1 master-2 master-3; do
    oc debug node/${m}.lab.ocp.local -- chroot /host bash -c '
      for f in /var/log/kube-apiserver/audit*.log; do
        grep -a "\"resource\":\"clusterversions\"" "$f" | grep -a "\"verb\":\"patch\""
      done'
  done
```
Found on **master-3**'s audit log (the API request had landed on a different apiserver
instance than master-1, via the HAProxy load balancer — a reminder to always check all
three when tracing a cluster-wide resource change):
```
{"auditID":"29d3ac63-...","verb":"patch",
 "user":{"username":"kube:admin","groups":["system:cluster-admins",...]},
 "sourceIPs":["192.168.29.10","10.128.2.2","10.129.0.59"],
 "userAgent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) ... Chrome/151.0.0.0 ...",
 "objectRef":{"resource":"clusterversions","name":"version",...},
 "requestReceivedTimestamp":"2026-08-20T09:31:08.286236Z"}
```
Confirmed: web-console-originated change, `kube:admin` identity (shared `kubeadmin`
bootstrap credential, still present in `kube-system` at time of investigation, 144+ days
old). A second, later change (`candidate-4.20` → `candidate-4.19`) was observed the same way
during a follow-up check. Channel was manually reset to `stable-4.19` and confirmed.

Remediation adopted to close the attribution gap: [checklists/admin-user-onboarding.md](../../checklists/admin-user-onboarding.md).

## Root Cause (Summary)

1. **Upgrade stall**: worker-2's `machine-config-daemon` pod failed to pull a required
   image because DNS lookups for `quay.io` resolved only unreachable IPv6 addresses via the
   combined A+AAAA resolution path, despite the same resolver serving valid A records to an
   explicit query. Self-recovered via kubelet retry.
2. **Channel drift**: the shared `kubeadmin` bootstrap credential remained active, allowing
   an unattributable console-based change to the cluster's update channel to a pre-release
   (`candidate-*`) track, twice, with no way to identify who made it beyond "someone with
   the kubeadmin password."

## Recommendations / Follow-ups

1. Mirror release images locally (`oc adm release mirror`) or fix the `192.168.29.10`
   resolver's AAAA/A behavior — same recommendation as issue 09, now reinforced by a second
   occurrence.
2. Complete the [admin-user-onboarding checklist](../../checklists/admin-user-onboarding.md):
   add named cluster-admin users, retire `kubeadmin`, raise audit profile to
   `WriteRequestBodies`.
3. Do not attempt a 4.19→4.20 upgrade until master node RAM is raised — Insights flags
   `NODES_MINIMUM_REQUIREMENTS_NOT_MET` (Moderate risk); masters have ~11GB vs. the 16GB
   Red Hat minimum for control-plane nodes.
4. When tracing any cluster-wide resource change via audit logs, check **all three**
   masters' logs, not just one — the load balancer can route the mutating request to any of
   them.
