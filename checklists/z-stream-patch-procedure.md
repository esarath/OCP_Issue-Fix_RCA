# Checklist — Z-Stream Patch Upgrade Procedure (e.g. 4.19.42 → 4.19.43)

**Use this when**: applying a z-stream (patch-level, same y-stream) OpenShift
update via the CVO. Drafted against the live 4.19.42 → 4.19.43 patch decision
on `lab.ocp.local`, 2026-08-20 — reusable for future z-streams on this
cluster.

**Related**: [issue 08](../issues/08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md)
(prior z-stream, same cluster, includes a self-recovered image-pull stall and
the channel-drift/attribution incident) · [issue 09](../issues/09-upgrade-4.18-to-4.19-image-pull-timeout/README.md)
(earlier z-stream, different self-recovered image-pull stall — same failure
*category* twice now).

---

## 1. What's actually changing

A z-stream bump touches:

| Component | Changes? | Notes |
|---|---|---|
| `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd` | Yes — image bump | Rolled one master at a time; HA maintained throughout |
| `kubelet` / CRI-O | Yes — patch-level bump only | Same Kubernetes minor version; no API removals possible at this boundary |
| RHCOS build / node OS packages | Maybe | Depends on the specific release — check the errata; if RHCOS is bumped, workers reboot, if not, they don't |
| ClusterOperator versions | Yes, in lockstep | All bump to the new x.y.z together |
| CRD schemas / API resources | **No removals possible** | API removals only happen at y-stream boundaries — this is a hard guarantee, not a "probably" |
| OLM operators (CNV, Lightspeed) | **Not touched by this** | Independent lifecycle — but confirm their own compatibility statement for the new z-stream (§3 below) |
| Application data / PVs | Not touched by the upgrade itself | But see the backup gap in §7 — this cluster currently has no evidence of an app-data backup solution (no Velero/OADP operator installed) |

**Net scope**: control plane + node OS/kubelet only. No planned application
data changes, no API compatibility risk. The risk surface is entirely about
*execution* (node drains, image pulls, brief control-plane disruption), not
about *compatibility*.

---

## 2. Pros & cons

**Pros**
- Applies the CVE fixes in the associated RHSA — closes a real, disclosed security exposure window
- Keeps the cluster within Red Hat's supported patch currency (relevant if support contracts require it)
- Z-stream = lowest-risk upgrade category available (no API removals, no y-stream component rewrites)
- This cluster has a track record of two prior z-streams both completing successfully (issues 08, 09) — the pattern is understood

**Cons / consequences**
- Every control-plane component restarts (rolling) — brief per-master API disruption windows, not zero-risk even if brief
- Every worker gets cordoned/drained — any workload without adequate replica count + PDB sees a restart-induced blip
- **This cluster has now hit the same failure category twice** (worker node stalls on `ocp-v4.0-art-dev` image pull during MCO rollout — issues 08 and 09, different specific mechanisms) — treat this as a known, moderately-likely-to-recur risk, not a one-off
- No supported downgrade path — the only rollback is etcd restore, which is itself disruptive (§7)
- CNV is installed with running VM infrastructure — live migration during worker drains carries its own (small but nonzero) failure risk, and this cluster has no evidence of VM-disk-level backup independent of etcd

---

## 3. Application / operator compatibility check

- [ ] Confirm `kubevirt-hyperconverged-operator` (currently v4.19.33) and `lightspeed-operator` (currently v1.1.2) both explicitly support the target OCP z-stream, per each vendor's own release notes — don't assume, z-stream compatibility is *near*-universal but not contractually guaranteed by Red Hat for third-party/vendor operators
- [ ] `oc get vmi -A` — enumerate all running VMs. For each: confirm live migration is enabled/expected to succeed, or plan an explicit stop/start window with the VM owner
- [ ] Identify any single-replica, no-PDB application that lives on a worker node — these will see a real (if brief) restart during that worker's drain; get owner sign-off if the app is sensitive to this

---

## 4. Expected downtime / disruption profile

**There is no full cluster outage in a normal z-stream upgrade.** What actually happens:

| Phase | Duration (typical) | User-visible impact |
|---|---|---|
| Control plane rollout (3 masters, one at a time) | ~15–30 min | Each master briefly unavailable (~1–3 min) during its own restart; load balancer routes around it — API stays reachable throughout via the other two masters |
| Worker rollout (2 workers, one at a time, default `maxUnavailable: 1`) | ~5–15 min per worker if a reboot is required by this release; less if not | Workloads on the draining worker are rescheduled/restarted — zero downtime for apps with 2+ replicas + a PDB across both workers; brief downtime for single-replica/no-PDB apps |
| VM live migration (if any VMs running, CNV) | Minutes per VM, proportional to memory/disk churn | No VM downtime if migration succeeds cleanly; a failed/unsupported migration means a real VM restart |
| **Total wall clock (this cluster's own history)** | Issue 08: ~2h11m (included a ~40 min self-recovered stall). A clean run without a stall: realistically **30–60 min** | — |

**Recommended maintenance window**: 1.5–2 hours, to absorb a repeat of the known stall pattern without needing to extend the window live.

---

## 5. Known issues that could arise (grounded in this cluster's actual history)

| Risk | Likelihood here | Evidence | Response |
|---|---|---|---|
| Worker `machine-config-daemon` stalls on image pull | **Moderate — has happened twice already** | Issues 08, 09 | Do NOT panic-restore. Both prior incidents self-recovered via kubelet retry within ~10–40 min. Follow the diagnosis sequence in issue 09's RCA before considering manual intervention: `oc get clusterversion` → `oc get co` → `oc get mcp` → node annotations → wait through one retry cycle |
| VM live migration failure/timeout | Low-moderate, untested at scale here | CNV installed, PDBs present, no prior incident on record | Coordinate with VM owners beforehand; have a manual stop/start fallback plan per VM |
| A single-replica app blips during worker drain | Depends on what's deployed | Not yet inventoried — do §3 before the window | Get owner sign-off if flagged |
| Insights/conditionalUpdates risk appears once 4.19.43 is visible on `stable-4.19` | Low | None flagged as of this writing (checked: `conditionalUpdates: none`) | Re-check `oc get clusterversion version -o json` → `.status.conditionalUpdates` right before the window — this is target-specific and could change |
| CVO patch itself introduces a genuine regression | Low (z-stream, RHSA-scoped) | No prior incident of this type on this cluster | This is what the etcd backup + restore plan (§7) exists for |

---

## 6. Pre-flight validation checklist

- [ ] `oc get co` / `oc get nodes` / `oc get mcp` — cluster fully healthy, nothing already degraded
- [ ] `oc adm upgrade` — confirm 4.19.43 (or target version) is actually recommended on `stable-4.19`
- [ ] `oc get clusterversion version -o json` → `.status.conditionalUpdates` — empty/no relevant risk for this target
- [ ] Fresh etcd backup taken and verified (§7)
- [ ] `oc adm top nodes` — record current headroom as a baseline (master-3 was the tightest node at last check, 84% memory — not blocking, but know your starting point)
- [ ] `oc get vmi -A` — VM inventory done, owners notified (§3)
- [ ] Single-replica/no-PDB app inventory done, owners notified (§3)
- [ ] Errata (RHSA) reviewed, CVE list recorded in the change ticket
- [ ] Change ticket approved with this document attached

## 7. Backup & restoration plan

### 7a. What gets backed up, and what doesn't

| Data | Covered by etcd backup? | Notes |
|---|---|---|
| All Kubernetes/OpenShift API objects (deployments, configs, RBAC, CRDs, etc.) | ✅ Yes | Full cluster state as etcd sees it |
| Control plane configuration | ✅ Yes | Static pod manifests are regenerated from etcd content on restore |
| **Application/VM persistent data (PV contents)** | ❌ **No** | etcd stores the *metadata* (PVC/PV objects), not the actual bytes on the storage backend. **This cluster shows no installed backup operator (no Velero/OADP in the CSV list)** — if a VM disk or application PV gets corrupted independently of the control plane, there is currently no in-cluster mechanism to restore it. This is a gap worth closing before relying on this plan for anything beyond control-plane recovery. |
| RHCOS node OS state | N/A | Nodes are stateless/immutable by design — recovered by re-provisioning via ignition from MCO, not by backup/restore |

### 7b. Pre-upgrade backup procedure

Same procedure already proven in issue 08:
```bash
oc debug node/master-1.lab.ocp.local -- chroot /host \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup
```
Then verify (don't just trust the script's exit code):
```bash
oc debug node/master-1.lab.ocp.local -- chroot /host ls -la /home/core/assets/backup
```
And copy off-node (avoids relying on a single master surviving):
```bash
oc debug node/master-1.lab.ocp.local -- chroot /host \
  tar -C /home/core/assets/backup -cf - . > ./etcd-backup-<date>.tar
```

### 7c. Decision thresholds — when to actually restore vs. wait it out

**Do not restore reflexively.** Both prior incidents on this cluster (issues 08, 09) looked alarming mid-stall and both self-recovered without any restore. Use this decision ladder:

1. **CVO shows `Progressing=True`, some operator `Degraded=True`, but nodes are still `Ready` and no data loss indicators** → this is the known pattern. Follow the diagnosis sequence (issue 09 RCA), wait through at least one MCO retry/reboot cycle (~10–40 min based on history) before escalating.
2. **Stalled >90 minutes with zero forward progress on the same task, or `Failing=True` on ClusterVersion** → escalate to manual diagnosis by an admin; still not automatically a restore trigger — most stuck-node scenarios are fixable in place (delete the stuck pod, check node resources, check DNS as done in issue 08).
3. **etcd itself reports quorum loss, or 2+ masters become simultaneously unreachable/corrupted** → this is the actual restore trigger. Proceed to §7d.

### 7d. Restoration procedure (control plane / etcd)

Only invoke this for a genuine control-plane failure (§7c, tier 3) — this is disruptive in its own right.

1. On a surviving master (or the one holding the best/most recent state), run the official restore:
   ```bash
   /usr/local/bin/cluster-restore.sh /home/core/assets/backup/snapshot_<timestamp>.db
   ```
2. This regenerates static pod manifests and restarts etcd from the snapshot on that node.
3. For the remaining masters: if they're intact, they rejoin the reformed etcd cluster automatically. If any master is unrecoverable (corrupted disk, VM lost), it must be **recreated from scratch** and rejoined per OpenShift's standard "replace an unhealthy etcd member" procedure — this is the step whose duration depends entirely on how fast a new master VM can be provisioned on Proxmox, which is not currently automated for this cluster as far as this document knows. Budget extra time here if that's the case.
4. Verify etcd quorum reformed: `oc get pods -n openshift-etcd`, check all `etcd-guard` pods healthy.
5. Verify API server and all ClusterOperators reconcile: `oc get co` until all `Available=True/Progressing=False/Degraded=False`.
6. Verify all nodes rejoin: `oc get nodes` — all `Ready`.

### 7e. Restoration timeline estimate

| Step | Estimated time |
|---|---|
| Run `cluster-restore.sh`, etcd comes back on the recovery node | ~10–15 min |
| Remaining intact masters rejoin automatically | ~10–20 min |
| Full ClusterOperator reconciliation across the cluster | ~20–40 min |
| **If any master needs to be recreated from scratch** | **+1–3 hours, dependent entirely on Proxmox VM provisioning speed — not currently automated for this cluster** |
| **Total (no master recreation needed)** | **~45 min – 1.5 hours** |
| **Total (one master needs recreation)** | **~2.5–4.5 hours** |

### 7f. Application/VM data restoration

**Not covered by the above** — see the gap noted in §7a. If a VM disk or application PV is corrupted independently of the control plane, restoration depends entirely on whatever storage-backend-level snapshot/backup exists outside this cluster (e.g., NFS-side snapshots, if the storage array supports them). This should be confirmed and documented separately — it is out of scope for what etcd backup protects.

---

## 8. Post-upgrade validation checklist

- [ ] `oc get clusterversion` — target version, `Available=True`, `Progressing=False`
- [ ] `oc get co` — all healthy
- [ ] `oc get nodes` — all `Ready`, consistent kubelet version across all 5
- [ ] `oc get vmi -A` — all VMs `Running` again post-migration
- [ ] Spot-check the specific applications flagged in §3 — actual behavior, not just cluster-green
- [ ] `oc adm top nodes` — compare against the pre-flight baseline (§6); confirm no lingering resource pressure
- [ ] Document actual outcome (timing, any incidents hit, resolution) as a new numbered issue in this repo, same as issues 08/09/10

## 9. Timeline & approval planning

| When | Activity |
|---|---|
| T-3 to T-5 days | Confirm target version is on `stable-4.19`; pull RHSA content; draft change ticket (CVE list, risk classification, this document attached) |
| T-2 days | Circulate to app/VM owners flagged in §3; get change approval |
| T-1 day | Re-run pre-flight checklist (§6) to confirm nothing drifted |
| T-0 (window) | Execute upgrade; budget 1.5–2 hours |
| T+0, immediately after | Post-upgrade validation (§8) |
| T+1 day | Document outcome in repo, close change ticket |

**Rollback statement for the ticket**: no supported version downgrade exists for a z-stream. Rollback = etcd restore (§7), reserved for genuine control-plane failure only (§7c) — not for the known, self-recovering stall pattern already seen twice on this cluster.
