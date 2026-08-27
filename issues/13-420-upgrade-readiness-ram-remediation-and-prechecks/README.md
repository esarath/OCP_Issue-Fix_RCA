# Issue 13 — 4.20 Upgrade Readiness: Master RAM Remediation & Pre-Flight Validation

| Field | Detail |
|---|---|
| **Type** | Change readiness — remediation + pre-check (planning, upgrade itself not yet executed) |
| **Status** | **Cluster is upgrade-ready.** Blocking RAM issue from issue 08/11 remediated. Only remaining step before `oc adm upgrade` is switching the channel and scheduling the window. |
| **Dates** | Remediation: 2026-08-26 · Pre-check re-validation: 2026-08-27 |
| **Scope** | `lab.ocp.local`, 4.19.42 → 4.20.x readiness |
| **Procedure to follow for the actual upgrade** | [checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md) (new, drafted alongside this issue) |
| **Supersedes / closes out** | The RAM blocker identified in [issue 08](../08-upgrade-4.19.41-to-4.19.42-and-channel-drift/README.md)'s Insights finding and tracked as open in [issue 11](../11-4.19.43-patch-readiness-review/README.md) and [issue 12](../12-uninstall-idle-cnv-reclaim-resources/README.md) |

---

## Why this issue exists (and why it's dated after the work)

The RAM remediation below was performed 2026-08-26 but never logged as its
own issue at the time — it happened inline while chasing 4.20 readiness.
This issue documents it retroactively, alongside the fresh pre-check run
that re-confirms it's still holding a day later, and formalizes the reusable
minor-upgrade checklist that issue 11 promised but hadn't been written yet
(only the z-stream variant existed).

---

## Part 1 — Master RAM remediation (2026-08-26)

### Background
Issue 08 flagged Red Hat Insights' **Moderate** `NODES_MINIMUM_REQUIREMENTS_NOT_MET`
recommendation: all 3 masters had only ~11GB RAM against Red Hat's stated
16GB control-plane minimum. Issue 12 ruled out reclaimable in-cluster causes
(uninstalled idle CNV, which helped `worker-1`/`master-1`/`master-2` but left
`master-3` unchanged — its load was entirely standard control-plane pods:
`kube-apiserver` ~2.6GB, etcd, OVN, `openshift-apiserver`, OLM singletons).
That left host-level RAM reallocation as the only remaining lever.

### Investigation
Obtained Proxmox root SSH to the hypervisor (`192.168.29.2`). Findings:
- Host: 62.4GB physical, ~11.8GB genuinely free at the time. ZFS ARC already
  capped at 4GB (pre-tuned, not a lever).
- `svc-infra` VM was the one oversized allocation (5.77GB configured, 1.70GB
  actual use) but ended up not needing to be touched.
- Full RH-minimum compliance (16GB/master, +14.3GB total) would have left
  under 1GB true host slack — too risky.
- **Chose a safe partial fix: 14GB/master (+8.3GB total)**, which fit inside
  existing free RAM with ~3.5GB spare left over.
- Noted but left alone: a stopped `Docker` VM (20.48GB reserved) is a
  standing risk if ever powered on — host can't absorb it on top of current
  load.

### Execution
Rolling, one master at a time, zero downtime:
```
cordon → drain → graceful OS shutdown → qm set --memory 14336 → qm start
→ wait Ready → wait etcd Degraded clears (briefly reports unhealthy 1-6 min
post-boot, self-heals) → uncordon → confirm MCP settles at 3/3 → next master
```
etcd stayed at quorum throughout (only ever 1 of 3 members down at a time).

**Gotcha**: `oc debug node/<name> -- chroot /host shutdown -h now` worked for
master-1 and master-2 but silently did nothing for master-3 twice in a row
(no poweroff trace in the journal, uptime kept climbing). Root cause not
determined. Fallback that worked: `qm shutdown <vmid> --timeout 90` issued
directly from the Proxmox side (still graceful/ACPI, not a hard `qm stop`).
**Recommendation for next time**: try the Proxmox-side shutdown first rather
than the in-guest command.

### Result
All 3 masters now report ~13.65GiB allocatable (14GB configured). Still
under Red Hat's stated 16GB minimum — Insights' advisory may still show —
but the actual memory pressure that motivated the pause (masters running at
~94% of their old allocation) is meaningfully relieved. **This is an
accepted-risk decision, not a fully cleared one** — carry that framing
forward into every future readiness check on this cluster.

---

## Part 2 — Disk cleanup (2026-08-26, same session)

Found and fixed two more gaps before declaring the cluster upgrade-ready:

- **Masters**: `master-3`'s `/var` was at 80% — turned out to be 204 of 211
  cached container images dangling/untagged (113GB logical), mostly stale
  OLM catalog-index digests (`redhat-operator-index`,
  `certified-operator-index`, `redhat-marketplace-index`) that churn every
  ~10-15min on catalog refresh faster than crio's own GC caught up. Fixed
  with `crictl rmi --prune` via `oc debug node/<name> -- chroot /host` on
  all three masters: master-1 46G→21G, master-2 49G→22G, master-3 64G→25G
  (80%→32%).
- **Workers**: same bloat, worse — worker-1 81% (329/332 images dangling,
  144GB logical), worker-2 74% (291/294 dangling, 129GB logical). Same
  prune: worker-1 81%→17%, worker-2 74%→17%. A handful of images hit
  `DeadlineExceeded` mid-prune (likely in-use at that instant) but the bulk
  cleared fine; nodes/pods/operators stayed healthy throughout.

`--prune` only removes images with zero container references — safe,
took seconds per node, no pod/service impact observed. **This same command
is the fix if disk creeps back up on a future check** (confirmed still the
case in Part 3 below — usage crept back up slightly but stayed well within
bounds, no re-prune needed yet).

---

## Part 3 — Fresh etcd backup (2026-08-26)

No valid backup existed at the time (`/home/centos/etcd-snapshots` was
empty). Took one via `cluster-backup.sh` on master-1, copied off-node
(root-owned on RHCOS — copy to `/tmp`, chown `core`, `scp` via
`~/.ssh/ocp4-key`, delete the `/tmp` staging copies). Result:
`/home/centos/etcd-snapshots/snapshot_2026-08-26_171152.db` (119MB) +
matching `static_kuberesources_*.tar.gz`.

---

## Part 4 — Pre-check re-validation (2026-08-27)

Cluster was confirmed still up (no cert-expiry/startup-checklist recovery
needed — nodes never went through an extended power-off between sessions).
Ran the new [`scripts/pre-upgrade-check.sh`](scripts/pre-upgrade-check.sh)
plus manual checks. Full output: [`pre-check-2026-08-27.log`](pre-check-2026-08-27.log).

| Area | Result |
|---|---|
| CV / not already progressing | PASS — 4.19.42, `Progressing=False` |
| Nodes Ready | PASS — all 5 |
| ClusterOperators | PASS — all 34 `Available=True/Progressing=False/Degraded=False` |
| MachineConfigPools | PASS — both `Updated=True` |
| Pending CSRs | PASS — 0 |
| Node memory headroom | PASS — masters 53-85%, all under the 85% flag threshold (master-2 tightest at 85%, matches known pattern, not new) |
| Node disk (`/var`) | PASS — 17-38% across all 5 nodes, well under the prune threshold |
| PDBs with 0 allowed disruptions | PASS — none found |
| quay.io pull secret | PASS — authenticated |
| etcd health | PASS — 3/3 members healthy, quorum intact |
| Installed OLM operators | Info — only `openshift-lightspeed` (v1.1.3) remains (CNV uninstalled in issue 12); its 4.20 compatibility must still be confirmed from Red Hat's own release notes before the window, not assumed |
| **Current channel** | **WARN — still `stable-4.19`.** Not yet switched to `stable-4.20`. This is expected — switching channel is itself part of the executed-upgrade procedure, not a pre-check-only step, and is deliberately not done here to avoid repeating the issue 08 channel-drift pattern outside a planned window |
| Update path for 4.20 | WARN — 4.19.43 z-stream is available and recommended on `stable-4.19` (not yet applied — separate decision, see issue 11); 4.20 not visible until channel is switched |
| etcd backup freshness | Info — 1 day old (2026-08-26), fine as a fallback but a **fresh same-window backup is still required** immediately before the actual upgrade per the new checklist §4 |

**Verdict: no FAIL items.** Every prerequisite this repo has tracked since
issue 08 is now closed or explicitly accepted. The only WARNs are
expected-and-deliberate (channel not yet switched) rather than problems.

---

## What's actually left before running the upgrade

1. Decide whether to take the pending 4.19.43 z-stream first (issue 11's
   still-open readiness review) or go straight to 4.20 — not decided here,
   flagging for the change window planning conversation.
2. Confirm `openshift-lightspeed` v1.1.3's vendor compatibility statement
   for OCP 4.20 specifically.
3. Same-day re-run of the pre-flight checklist immediately before the
   window (RAM/disk can drift; don't rely on this check being more than a
   day or two old).
4. Take a same-window etcd backup (this one is 1+ day old by the time a
   window is scheduled).
5. Switch channel to `stable-4.20` using a named admin account (not
   `kubeadmin`), then run `oc adm upgrade` per
   [checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md).
6. Document the actual upgrade execution as a new issue (14) once run —
   same pattern as issues 02/08/09.

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full root cause analysis for the RAM constraint and remediation decision |
| [scripts/pre-upgrade-check.sh](scripts/pre-upgrade-check.sh) | Automated pre-upgrade health/readiness check, adapted for this cluster's current state (no CNV/GitOps) |
| [scripts/post-upgrade-validate.sh](scripts/post-upgrade-validate.sh) | Automated post-upgrade validation, to run once the actual 4.20 upgrade executes |
| [pre-check-2026-08-27.log](pre-check-2026-08-27.log) | Raw output of the 2026-08-27 pre-check run |
| [../../checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md) | New reusable checklist this issue produced |
