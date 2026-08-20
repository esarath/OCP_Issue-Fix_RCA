# Issue 08 — Upgrade 4.19.41 → 4.19.42: Worker Image Pull Stall (IPv6 DNS) + Post-Upgrade Channel Drift

| Field | Detail |
|---|---|
| **Date** | 2026-08-20 |
| **Severity** | Low (upgrade), Medium (channel drift / attribution gap) |
| **Status** | Resolved |
| **Affected** | `machine-config` operator, `worker-2.lab.ocp.local`; cluster update channel (post-upgrade) |
| **Root Cause (upgrade stall)** | `machine-config-daemon` pod on worker-2 hit `ImagePullBackOff` — DNS lookups for `quay.io` resolved only unreachable IPv6 (AAAA) addresses, despite valid IPv4 A records existing upstream. Self-recovered via kubelet retry backoff. |
| **Root Cause (channel drift)** | Cluster's update channel was changed twice post-upgrade (`stable-4.19` → `candidate-4.20` → `candidate-4.19`) via the web console, both times as `kube:admin` — the shared, unattributable bootstrap credential. |
| **Resolution** | Upgrade completed on its own; channel manually reset to `stable-4.19`; onboarded a traceability fix — see [checklist](../../checklists/admin-user-onboarding.md) |

---

## Part 1 — Upgrade stall on image pull

### Symptom
`oc adm upgrade` stalled at 86% (794/923):
```
Working towards 4.19.42: 794 of 923 done (86% complete), waiting on machine-config
```
`oc get co machine-config` showed `Degraded=True`:
```
Unable to apply 4.19.42: error during waitForDaemonsetRollout: [context deadline exceeded,
daemonset machine-config-daemon is not ready. status: (desired: 5, updated: 3, ready: 4, unavailable: 1)]
```
One pod, `machine-config-daemon-hx8hz` on `worker-2.lab.ocp.local`, was `1/2 ImagePullBackOff`.

### Diagnosis
1. Pod events showed repeated failures (122 retries over ~32 min):
   ```
   Failed to pull image "...ocp-v4.0-art-dev@sha256:cd7248e4...":
   dial tcp [2600:1f18:d77:9001:852c:b033:9764:47b9]:443: connect: network is unreachable
   ```
2. `getent hosts quay.io` on **both** worker nodes returned only IPv6 (AAAA) addresses — no A records — while a direct `dig +short A quay.io @192.168.29.10` returned valid IPv4 addresses (`100.59.151.36`, `3.229.30.151`, etc.). Neither node has any IPv6 route or address configured (`ip -6 route` empty of any default route on both).
3. Ruled out a worker-2-specific misconfiguration: `worker-1` has the identical (IPv6-only) `getent hosts` behavior, but avoided the failure because it already had ~190 `ocp-v4.0-art-dev` image layers cached locally from prior upgrades (including [issue 09](../09-upgrade-4.18-to-4.19-image-pull-timeout/README.md)) and never needed a fresh pull of this digest. worker-2 lacked that cache and hit the bug head-on.
4. Conclusion: the combined A+AAAA lookup path used by CRI-O/Go's resolver is surfacing only the (unreachable) AAAA answer from the `192.168.29.10` infra resolver, even though the same resolver serves valid A records to a direct, explicit `dig A` query. This is a resolver-side quirk, not a node network fault.

### Resolution
Kubelet's own retry/backoff eventually succeeded (~08:49 UTC, after ~40 min stalled) without manual intervention. Upgrade completed at **09:01:06 UTC**. A manual pod deletion was also approved and issued around the same time as a secondary unblock attempt, but the DaemonSet had already self-recovered by the time it landed — confirmed via the resulting pod being fresh (`machine-config-daemon-zlgtz`, 11s old) with no side effects.

### This is a recurring pattern
This is the **second** upgrade in a row (see [issue 09](../09-upgrade-4.18-to-4.19-image-pull-timeout/README.md), 2026-08-18, 4.18.50→4.19.41) where a node stalled mid-MCO-rollout on a `quay.io/openshift-release-dev/ocp-v4.0-art-dev` image pull and then self-recovered. The specific mechanism differs (retry-timeout exhaustion vs. IPv6-only DNS resolution this time), but the pattern — a node without a warm local cache stalling on a live registry pull during upgrade — is now established across two separate incidents.

**Recommendation carried forward from issue 09, now reinforced**: consider mirroring release images locally (`oc adm release mirror`) to remove the live dependency on `quay.io` during upgrade windows, and/or investigate the `192.168.29.10` resolver's AAAA/A answer-ordering behavior directly (likely the `named` service on `svc-infra`) since it is now implicated in both this issue and general external-name resolution reliability.

---

## Part 2 — Post-upgrade update-channel drift (attribution gap)

### Timeline
| Time (UTC) | Event |
|---|---|
| 06:56 | Pre-upgrade check: channel confirmed `stable-4.19` |
| 09:01 | Upgrade to 4.19.42 completes |
| 09:31:08 | `spec.channel` patched to `candidate-4.20` — audit shows `user: kube:admin`, `userAgent: Mozilla/5.0 ... Chrome/151.0.0.0` (web console), source `192.168.29.10` |
| ~10:3x | Channel found changed again, to `candidate-4.19` — same unattributable `kube:admin` identity |
| ~10:4x | Channel manually reset to `stable-4.19` via `oc adm upgrade channel stable-4.19`, confirmed |

### Why it couldn't be traced to a person
`kube:admin` is the identity presented by the shared `kubeadmin` bootstrap
credential (secret `kubeadmin` in `kube-system`, still present, 144+ days
old). Every person who has that password is indistinguishable in the audit
log. Additionally, the cluster's audit profile was `Default`, which logs
only request metadata — confirmed via `oc debug node/<master> -- chroot /host
grep candidate-4.20 /var/log/kube-apiserver/audit*.log`, which found nothing,
because the actual patch **value** isn't captured at that audit level, only
the fact that a patch occurred.

### Why `candidate-4.20` is a real concern, not just noise
`candidate-*` channels serve pre-release, less-validated builds. A cluster
staying on `candidate-4.20` risks an unintended jump to an unvetted y-stream
build via console click, with no rollback path (minor version upgrades are
one-directional). This was caught during a readiness review for a
*potential* future 4.20 upgrade — see [Insights findings](#insights-finding-node-resources)
below for why 4.20 isn't recommended yet regardless of channel.

### Resolution
1. Channel manually confirmed and reset to `stable-4.19`.
2. Root-caused the attribution gap to the still-active `kubeadmin` credential
   and the `Default` audit profile.
3. Adopted a permanent fix: **[admin-user-onboarding checklist](../../checklists/admin-user-onboarding.md)**
   — add named HTPasswd cluster-admin users, retire `kubeadmin`, and raise
   the audit profile to `WriteRequestBodies` so any future change is both
   attributable to a person and captured with its actual before/after value.

---

## Insights finding: node resources {#insights-finding-node-resources}

While assessing 4.20 upgrade readiness, Red Hat Insights flagged a
**Moderate**-risk recommendation: *"An OCP node behaves unexpectedly when it
doesn't meet the minimum resource requirements."* Checked against actual
hardware:

| Role | vCPU | RAM | Red Hat minimum |
|---|---|---|---|
| Masters (x3) | 5 | ~11 GB | 16 GB (control-plane) |
| Workers (x2) | 3 | ~9 GB | 8 GB |

Masters are under Red Hat's stated minimum, which correlates with
master-3 running at 88% memory / 98% requests-committed under normal,
non-upgrade load. A minor version upgrade (y-stream, heavier than the patch
bump completed here) runs overlapping component revisions during rollout and
needs more headroom than this cluster currently has on its masters.
**Recommendation: do not attempt a 4.19→4.20 upgrade until master RAM is
increased, or accept elevated risk of memory pressure during that specific
upgrade.**

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full command-level timeline and evidence |
| [../../checklists/admin-user-onboarding.md](../../checklists/admin-user-onboarding.md) | Adopted fix for the attribution gap |

## Prevention / Watch Items

- Mirror release images locally, or investigate the `192.168.29.10` resolver's IPv6/IPv4 answer behavior (recurring across issues 03 and 04).
- Do not attempt 4.19→4.20 until master node RAM is raised to meet the 16GB control-plane minimum.
- Follow the [admin-user-onboarding checklist](../../checklists/admin-user-onboarding.md) for any additional admin accounts.
- Periodically confirm `oc get clusterversion version -o jsonpath='{.spec.channel}'` is still `stable-4.19` (or whatever the intended channel is) — nothing currently alerts on channel drift itself.
