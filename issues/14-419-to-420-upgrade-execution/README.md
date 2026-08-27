# Issue 14 — 4.19.43 → 4.20.35 Minor Version Upgrade: Execution & Internals Deep-Dive

| Field | Detail |
|---|---|
| **Type** | Change execution — live y-stream upgrade, captured in depth (not just steps, but *why* the cluster does what it does internally) |
| **Status** | **COMPLETED** — 2026-08-27 14:34 UTC → 16:03 UTC (~1h29m). All 34 operators clean at 4.20.35, all 5 nodes converged, etcd 3/3, 0 pending CSRs. |
| **Scope** | `lab.ocp.local`, 4.19.43 → 4.20.35, channel `fast-4.20` |
| **Closes out** | [issue 13](../13-420-upgrade-readiness-ram-remediation-and-prechecks/README.md) — all readiness prerequisites (RAM, disk, backup, health) confirmed done there |
| **Procedure followed** | [checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md) |
| **Purpose of this doc** | Unlike prior issues, this one exists to capture *what actually happens inside the cluster* during a y-stream upgrade — CVO's task-graph mechanics, operator update ordering/dependencies, static-pod revision rollouts, MCO node draining/rebooting, and any anomalies found along the way — as a reference for understanding OCP's internal upgrade machinery, not just a status log. |
| **Interactive companion** | [Cluster Signal Map](https://claude.ai/code/artifact/c22152ed-607c-4a70-8120-318f309c8f02) — a step-through diagram of which components talk to which (control plane ↔ node, master ↔ worker) at every stage of this exact run, built from the findings below |

---

## Background — y-stream vs. z-stream, and what `candidate`/`fast`/`stable` channels actually mean

An OCP version is `X.Y.Z` (e.g. `4.20.35`): **X** = major, **Y** = minor, **Z** = patch. The two upgrade types this repo deals with are named after which number moves:

| | **Z-stream** (patch, e.g. issue 08's `4.19.41→4.19.42`) | **Y-stream** (minor, **this issue**, `4.19.43→4.20.35`) |
|---|---|---|
| Kubernetes version | Unchanged | **Bumped** — this run: kubelet v1.32.13 → **v1.33.13** |
| API deprecations/removals | None — no Kubernetes API version change | **Can remove/change APIs** deprecated in the prior minor — workloads or operators using a removed API can break |
| Node reboots | Usually none, or limited to nodes with an actual RHCOS/kernel change | **Every node reboots** — the CVO/MCO task graph is much larger (962 tasks this run vs. a handful for a z-stream) |
| OLM operator compatibility | Rarely a concern | **Must be re-verified per target minor** — this is why this cluster's `lightspeed-operator` compatibility was checked (and ultimately removed) before this window, see project history |
| Rollback | `--to-image` back to the prior z-stream is sometimes viable if caught early | **No supported rollback once underway** — a one-way door, which is exactly why issue 13's readiness gate (RAM, disk, fresh backup) existed before this run |
| Typical duration | Minutes to ~30 min | Much longer — **this run took 1h29m** end to end |

**Channels (`candidate-X.Y`, `fast-X.Y`, `stable-X.Y`) are not different builds — they're different gates on the *same* release images**, controlling which upgrade edges Red Hat's Cincinnati graph exposes to a given cluster for a given minor:

- **`candidate-X.Y`** — newest builds, exposed almost immediately after Red Hat builds them. No soak time, no fleet-health signal yet. Not recommended for production.
- **`fast-X.Y`** — the same builds, promoted out of `candidate` once they clear Red Hat's internal CI/QE gates. Vetted, but without real-world fleet telemetry behind them yet.
- **`stable-X.Y`** — the same builds again, promoted out of `fast` only once enough real clusters have run them (via `candidate`/`fast`) without reporting problems back through telemetry. This is the recommended channel for production, and what this cluster normally targets.

**Why this run actually used `fast-4.20` instead of `stable-4.20`:** each release image carries its own metadata listing which channels it's a valid *entry point* for. Querying Red Hat's Cincinnati graph directly during this cluster's readiness work found that `4.19.43`'s own release metadata listed `candidate-4.20`/`fast-4.20` as valid entry channels but **not** `stable-4.20` — Red Hat simply hadn't tagged this specific z-stream into the stable-4.20 entry-edge yet (normal promotion lag, not a bug). A valid `4.19.43 → 4.20.35` edge already existed on `fast-4.20`, so that channel was used for this run instead of waiting. Switching channels itself never triggers an upgrade — it only changes what `oc adm upgrade` reports as available/recommended.

---

## Pre-upgrade state (confirmed 2026-08-27, ~14:15 UTC)

- ClusterVersion 4.19.43, `Available=True`, `Progressing=False`
- Channel switched to `fast-4.20` **outside this session** prior to this check (previously `stable-4.19`; `stable-4.20` still doesn't exist as a valid entry point for this z-stream per the Cincinnati graph investigation in issue 13's continuation — see project memory)
- All 5 nodes Ready, 34/34 ClusterOperators clean, both MCPs updated (master 3/3, worker 2/2, 0 degraded)
- etcd 3/3 members, 5/5 containers Running, 0 pending CSRs, 0 blocking PDBs
- Master RAM 56-57%, worker RAM 53-62% (the issue-13 14GB/master fix still holding)
- Node `/var` disk 24-34% across all 5 nodes
- Fresh etcd backup already existed from earlier that morning: `snapshot_2026-08-27_071409.db` (07:14 UTC)

## Trigger command

```
oc adm upgrade --to=4.20.35
# -> spec.desiredUpdate = {image: sha256:ffb9ee7de8d13bce19d67ce5c6c13c56ad8e9e1906341fccc7c5d12e2fb6d97e, version: 4.20.35}
```

Authenticated as `system:admin` (cert-based cluster-admin from the install kubeconfig, not the `kubeadmin` htpasswd user).

**First-hand observation on lag:** immediately after running this, `oc adm upgrade` still reported `Cluster version is 4.19.43` / `Progressing=False` for roughly 45-60 seconds before the CVO picked up the new `desiredUpdate` and flipped to `Progressing=True`. The CVO reconciles on its own interval — writing `spec.desiredUpdate` doesn't synchronously kick a sync loop, it's picked up on the next reconcile pass. Don't mistake this lag for the command having failed.

---

## How the CVO actually applies an upgrade (observed mechanics)

The moment the new desired image is accepted, the `cluster-version-operator` **pod itself is redeployed** onto the new release's CVO binary first (this is why `oc get pods -n openshift-cluster-version` shows a fresh `cluster-version-operator-<hash>` with `AGE` reset, plus a completed one-shot `version-4.20.35-<hash>` job pod that extracts/verifies the release payload). Everything downstream is then driven by *that* new CVO binary, not the old one — the operator that manages the upgrade is itself upgraded as step zero.

From there the CVO walks a **fixed, numbered task graph** built from the release image's manifest set — this cluster's payload has **962 total tasks**. Confirmed by tailing the CVO logs live:

```
Running sync for clusterrole "system:openshift:scc:restricted-v3" (98 of 962)
Running sync for clusterrolebinding "system:openshift:scc:restricted-v3" (101 of 962)
Running sync for namespace "openshift-kube-apiserver-operator" (102 of 962)
Running sync for securitycontextconstraints "anyuid" (103 of 962)
...
Running sync for clusteroperator "kube-apiserver" (122 of 962)
```

Key mechanics observed directly from these logs:

1. **RBAC and cluster-scoped objects (ClusterRoles, ClusterRoleBindings, SCCs, CRDs) sync first and fast** — each takes ~50ms, no waiting involved, because they have no "operator reports its own version" gate.
2. **Each operator's manifests (namespace, SA, RBAC, Deployment) sync in order, then the CVO explicitly syncs the `ClusterOperator` object itself as one of the numbered tasks** (e.g. task 122 = `clusteroperator "kube-apiserver"`). This is the **synchronization gate**: the CVO will not consider that numbered task "done" until the operator's own `ClusterOperator` status reports `Available=True, Progressing=False` **at the new version**. Until then you get the log line:
   ```
   error running apply for clusteroperator "kube-apiserver" (122 of 962): Cluster operator kube-apiserver is updating versions
   ```
   This is **expected, not a failure** — the CVO retries this gate on every sync loop (roughly every few seconds to minutes with backoff) until the operator finishes rolling out on its own.
3. **Multiple operators can be "updating versions" concurrently** — observed both `etcd` and `kube-apiserver` blocking the graph at the same time (`errs=[Cluster operator etcd is updating versions Cluster operator kube-apiserver is updating versions]`). The task graph has parallel workers (16 worker goroutines observed: `Worker 0` through `Worker 15` in the logs), so independent branches of the manifest graph can proceed in parallel; it's only a *specific* operator's own rollout gate that serializes.
4. **Observed update order so far**: `config-operator` was first to flip to 4.20.35 (it manages base CRDs/config resources other operators depend on — makes sense as the earliest dependency), then `etcd` and `kube-apiserver` began updating **together**, not strictly sequentially. This contradicts a naive assumption that etcd must fully finish before the API server layer touches anything — in practice the CVO parallelizes wherever the manifest graph allows it, and only genuinely serializes where an explicit dependency edge exists.

---

## How etcd's own operator rolls out a new revision (observed mechanics)

`etcd` ClusterOperator going `Progressing=True` doesn't mean "redeploying etcd" in the docker-compose sense — OpenShift's etcd is managed as a **revisioned static pod**, and the rollout is its own state machine:

- The **RevisionController** (one of ~25 sub-controllers inside the etcd-operator, all individually surfaced as their own `*Degraded` conditions — `EtcdMembersControllerDegraded`, `NodeInstallerDegraded`, `DefragControllerDegraded`, etc.) bumps a new revision number when the target manifest/config changes.
- The **InstallerController** then runs a one-shot "installer pod" **on one master at a time** that writes the new static-pod manifest into `/etc/kubernetes/manifests/` on that node — the kubelet on that node picks it up and restarts just that etcd container locally (no scheduler involved, static pods are kubelet-managed, not API-server-scheduled).
- Live snapshot mid-rollout:
  ```
  etcd-master-1   revision 19   Running   <- already rolled
  etcd-master-2   revision 18   Running   <- old revision, not yet touched
  etcd-master-3   revision 18   Running   <- old revision, not yet touched
  ```
  and the operator's own status corroborates it explicitly: `NodeInstallerProgressing=True  2 nodes are at revision 18; 1 node is at revision 19`.
- This is **exactly one master at a time by design** — the GuardController/quorum-guard logic ensures only one etcd member is ever mid-restart, keeping 2-of-3 quorum intact throughout (same pattern seen manually during issue 13's RAM remediation, except here it's the etcd-operator doing the cordon-equivalent automatically rather than a human running `qm`/drain).
- `kube-apiserver` uses the **identical revision + InstallerController pattern** (own revision counter, currently at 37 uniformly — hadn't started its per-node rollout yet at capture time, still on 37/37 across all masters even while its ClusterOperator already reported `Progressing=True`). This says the kube-apiserver operator's *other* sub-controllers (cert rotation, config observation, etc.) can go Progressing before the static-pod revision itself actually starts bumping — "Progressing" is a coarse aggregate of many finer sub-conditions, not a single linear step.

---

## Anomalies / findings noticed along the way (not blocking, but real)

1. **Dangling admission webhook configurations from removed operators.** `kube-apiserver`'s own status carries these live errors:
   ```
   MutatingAdmissionWebhookConfigurationError=True
     ca-mutatur.forklift.konveyor: unable to find service forklift-api.openshift-mtv: service "forklift-api" not found
     plans.forklift.konveyor: unable to find service forklift-api.openshift-mtv: ...
   ValidatingAdmissionWebhookConfigurationError=True
     plans.forklift.konveyor / providers.forklift.konveyor / secrets.forklift.konveyor: same, service not found
     vtempostack.tempo.grafana.com: unable to find service tempo-operator-controller-service.openshift-tempo-operator: not found
   ```
   `forklift` is MTV (Migration Toolkit for Virtualization), which rides alongside CNV/OpenShift Virtualization — consistent with issue 12's CNV removal having left orphaned `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` objects behind pointing at services that no longer exist. Same story for a leftover Tempo-operator webhook. **Not currently failing anything** (these conditions are `...ConfigurationError=True` but don't flip `kube-apiserver` to `Degraded`, and API requests that don't match those webhooks' rules are unaffected) — but they're upgrade-hygiene debt worth cleaning up post-upgrade: `oc get mutatingwebhookconfigurations,validatingwebhookconfigurations | grep -E 'forklift|tempo'` and delete the orphans once confirmed unused.
2. **`KubeletMinorVersionUpgradeable=False` — "Kubelet minor versions on 5 nodes will not be supported in the next OpenShift minor version upgrade."** Expected/transient during any y-stream: the control plane jumps to 4.20 before the MCO has rolled new RHCOS+kubelet out to the nodes, so there's a brief window where node kubelet minor version trails the control plane by one more minor than will be supported *after this upgrade completes and a future one is attempted*. This clears once MCO finishes updating the node pools to the 4.20 rendered config. Documented here so it isn't mistaken for a new problem if seen again mid-upgrade.

---

## Per-node baseline / control-plane pod granularity (captured ~14:41 UTC, mid-upgrade)

This section is tracked **per individual node** (not just per-ClusterOperator aggregate) for both control-plane and data/worker nodes, at every stage, per explicit request.

**Node-level OS/kubelet/MCO state at this point — nothing here has moved yet:**

| Node | Kubelet | OS image | CRI-O | MCO current cfg | MCO desired cfg | MCO state |
|---|---|---|---|---|---|---|
| master-1/2/3 | v1.32.13 | RHCOS 9.6.20260811-0 (Plow) | 1.32.13-9.rhaos4.19 | `rendered-master-f47e1e2...` | *same* | Done |
| worker-1/2 | v1.32.13 | RHCOS 9.6.20260811-0 (Plow) | 1.32.13-9.rhaos4.19 | `rendered-worker-db128d2...` | *same* | Done |

**Key sequencing insight:** at this stage of the upgrade, `current == desired` on every node's MCO annotations and the OS image/kubelet version are completely unchanged. This confirms the ordering: **the control-plane component upgrade (etcd, kube-apiserver, etc. as static-pod revision bumps) happens entirely first, before the Machine Config Operator ever renders a new `rendered-master-*`/`rendered-worker-*` config or touches node OS images.** The MCO/node-reboot phase is a distinct, later stage — it hasn't started yet even though several ClusterOperators are already on 4.20.35.

**Per-master control-plane pod status, this snapshot:**

| Master | etcd revision | etcd installer pod | kube-apiserver revision | kube-apiserver installer pod | kube-apiserver pod ready? |
|---|---|---|---|---|---|
| master-1 | 19 (done) | `installer-19` completed | mid-move 37→39 | `installer-39` **running now** | **NOT ready** (being replaced) |
| master-2 | 18 (not yet touched) | none running | 37 (untouched) | none | Ready |
| master-3 | 19, installer **running now** | `installer-19` **running now** | 37 (untouched) | none | Ready |

Reading this together: **master-1 is currently absorbing the kube-apiserver revision bump** (its own apiserver static pod is down/being recreated) while **master-3 is simultaneously absorbing the etcd revision bump**. These are two different masters being touched by two different operators' InstallerControllers *at the same time* — confirms the etcd-operator and kube-apiserver-operator each manage their own independent one-node-at-a-time rollout, and those two independent rollouts are not coordinated with each other to avoid ever touching the same node simultaneously. Quorum safety is maintained *within* each operator's own domain (etcd guards etcd quorum, kube-apiserver guards its own guard-pod readiness), not by a single cluster-wide "only one master touched at a time" rule.

Also visible: kube-apiserver revision jumped straight from 37 towards 39 (skipping a directly-observed 38) — `revision-pruner-37/38/39` all exist on every master, meaning revision 38 was created and already pruned in between polls (each config-relevant change bumps a new revision; multiple small changes early in the upgrade can cycle through revisions faster than this polling interval catches). Guard pods on master-2/master-3 (`kube-apiserver-guard`) show a restart-count bump from 2→3 on one container — consistent with transient guard-readiness flaps while their sibling master-1's apiserver was down, self-recovered, not a real issue.

Worker nodes (worker-1, worker-2): **completely untouched so far** — no installer/revision-pruner pods exist on workers because workers don't run control-plane static pods at all. Workers will only be touched once MCO's own node-by-node cordon/drain/reboot phase begins (expected after all control-plane ClusterOperators finish, roughly mirroring how issue 13's manual RAM-bump procedure did cordon → drain → reboot → uncordon, except this time MCO drives it automatically pool-by-pool: `master` pool first, then `worker` pool).

---

## Live timeline

| Time (UTC) | Event |
|---|---|
| ~14:15 | Pre-upgrade health/readiness re-confirmed clean (see above) |
| ~14:32 | `oc adm upgrade --to=4.20.35` issued |
| 14:34:18 | CVO redeployed onto new binary; task graph running; `config-operator` already at 4.20.35 |
| 14:39:13 | `etcd` and `kube-apiserver` both `Progressing=True`; etcd revision rollout underway (master-1 at rev 19, master-2/3 still rev 18); kube-apiserver still uniformly at rev 37 (other sub-controllers progressing first) |
| 14:41 | Per-node snapshot: master-1 mid kube-apiserver revision 39 install (pod down); master-3 mid etcd revision 19 install; master-2 untouched by either; all node OS/kubelet/MCO config still pre-upgrade baseline (MCO phase not started); workers completely untouched |
| ~14:50 | `etcd` and `kube-apiserver` ClusterOperators both fully clean at 4.20.35 (`Available=True, Progressing=False, Degraded=False`) — control-plane layer 1 done. CVO now gating on `kube-controller-manager` and `kube-scheduler`. Overall: **142 of 962 tasks, 14% complete**. Scheduler mid-rollout on master-1 (new pod at revision 20, `Pending`); controller-manager not yet visibly moved (still uniform revision 32 on all 3 masters, same "operator says Progressing before the static pod revision itself moves" pattern seen earlier with kube-apiserver). MCO/node layer completely untouched on all 5 nodes — `current==desired` config on every node, no cordons, 0 pending CSRs, no anomalies. |

*(This table is being appended to live as the upgrade proceeds — next updates will cover MCO node cordon/drain/reboot sequence for masters then workers — captured per-node, not just per-pool — remaining operator rollouts, and final validation.)*

---

## Update — ~14:50 UTC: kube-controller-manager & kube-scheduler rolling

**Overall progress:** `Working towards 4.20.35: 142 of 962 done (14% complete), waiting on kube-controller-manager, kube-scheduler`

**ClusterOperators not yet clean:**

| Operator | Version | Available | Progressing | Degraded | Message |
|---|---|---|---|---|---|
| kube-controller-manager | 4.19.43 | True | True | False | NodeInstallerProgressing: 3 nodes are at revision 32; 0 nodes have achieved new revision 34 |
| kube-scheduler | 4.19.43 | True | True | False | NodeInstallerProgressing: 3 nodes are at revision 19; 0 nodes have achieved new revision 20 |

`etcd` and `kube-apiserver` are now both **fully settled at 4.20.35**, `Degraded=False`, no message — confirming they're done, not just "not currently blocking."

**Per-master control-plane pod snapshot at this instant:**

| Master | kube-controller-manager | kube-scheduler |
|---|---|---|
| master-1 | revision 32, Running (unmoved) | revision **20**, **Pending** (new pod being stood up) |
| master-2 | revision 32, Running (unmoved) | revision 19, Running (not yet touched) |
| master-3 | revision 32, Running (unmoved) | revision 19, Running (not yet touched) |

Reading this: **master-1 is the current target again** — same node that took the first kube-apiserver bump earlier is now also first for the scheduler bump. Controller-manager hasn't visibly started (still uniform revision 32 everywhere) even though its ClusterOperator already reports `Progressing=True` — consistent with the earlier observation that "Progressing" on these operators is a coarse aggregate flipped before the per-node static-pod revision counter actually moves. No `installer-*` pod was caught running for either operator at this exact poll (a timing gap between polls, not a sign anything is stuck — kube-scheduler's own revision counter already moved to 20 on master-1, which can only happen via that mechanism).

**Per-node MCO/OS/kubelet state:** unchanged from the previous capture — `current==desired` on all 5 nodes, `MCO-STATE=Done` everywhere, no cordons (`SCHEDULABLE=<none>` on every node), 0 pending CSRs. The MCO/reboot phase has still not started; the control-plane static-pod layer is still working through its remaining two operators first.

**Anomalies:** none. No `Degraded=True` anywhere, no unexpected errors in CVO output beyond the expected "operator is updating versions" gating messages.

---

## Update — ~15:00 UTC: kube-controller-manager & kube-scheduler done; onto machine-api

**Overall progress:** `Working towards 4.20.35: 244 of 962 done (25% complete), waiting on machine-api`

`kube-controller-manager` and `kube-scheduler` are now **both fully settled at 4.20.35** — no operator currently shows non-clean in `oc get co` (the gate had already cleared by the time this poll ran). `cloud-controller-manager` and `control-plane-machine-set` also quietly reached 4.20.35 in this same window without ever showing up as a blocking gate in the earlier polls — a reminder that not every operator's rollout is slow enough to catch mid-flight; some finish inside a single ~10-minute polling gap.

**Per-master control-plane pod snapshot — both now uniform across all three masters (fully converged, not mid-rollout):**

| Master | kube-controller-manager | kube-scheduler |
|---|---|---|
| master-1 | revision **34**, Running | revision **20**, Running |
| master-2 | revision **34**, Running | revision **20**, Running |
| master-3 | revision **34**, Running | revision **20**, Running |

Confirms the pattern held: master-1 was first to pick up each new revision in every rollout so far (etcd, kube-apiserver, kube-scheduler), master-2/master-3 followed — not a strict rule enforced anywhere, just what this cluster's InstallerControllers happened to schedule each time.

**CVO now gating on `machine-api`** (4.19.43, but its own ClusterOperator already reports `Progressing=False` at capture time — likely mid-transition between polls, expect it clean by the next check).

**Cluster-operator version tally at this point:** 6 of 34 now on 4.20.35 (`config-operator`, `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `cloud-controller-manager`, `control-plane-machine-set` — 7 actually, see full list captured this poll), remainder still 4.19.43.

**Per-node MCO/OS/kubelet state:** unchanged — all 5 nodes still `current==desired`, `MCO-STATE=Done`, no cordons, 0 pending CSRs. Still entirely within the control-plane-operator phase; MCO/node-reboot phase has not begun.

**Anomalies:** none.

---

## Update — ~15:09 UTC: big jump to 78% — Deployment/DaemonSet operators now rolling (different mechanism than static pods)

**Overall progress:** `Working towards 4.20.35: 753 of 962 done (78% complete), waiting on monitoring, openshift-apiserver`

`machine-api` finished cleanly in this gap (4.20.35, clean) — the earlier "waiting on machine-api" cleared without ever being caught mid-rollout, same as `cloud-controller-manager`/`control-plane-machine-set` before it.

**New thing worth capturing: from here on, most remaining operators are NOT static pods on masters — they're ordinary Kubernetes Deployments/DaemonSets, and they roll by the standard Kubernetes mechanism (ReplicaSet swap / DaemonSet rolling update), not the InstallerController/revision-counter pattern etcd and kube-apiserver used.** Caught two of them mid-rollout:

**`openshift-apiserver`** (Deployment, 3 replicas, one per master) — `APIServerDeploymentProgressing: 2/3 pods updated, 2/3 available`:

| Pod (ReplicaSet) | Node | Ready |
|---|---|---|
| `apiserver-567b8cd7c9-szvcv` (**old** RS) | master-3 | true — not yet replaced |
| `apiserver-7d5d7b7474-r2fz7` (**new** RS) | master-2 | false — mid-startup |
| `apiserver-7d5d7b7474-zjbht` (**new** RS) | master-1 | true — done |

**`authentication`'s `oauth-apiserver`** (Deployment, 3 replicas, one per master) — same shape, `2/3 pods have been updated and 2/3 pods are available`:

| Pod (ReplicaSet) | Node | Ready |
|---|---|---|
| `apiserver-55d7859bb8-kljz2` (new) | master-1 | true |
| `apiserver-55d7859bb8-gpvsl` (new) | master-2 | true |
| `apiserver-55d7859bb8-bb52z` (new) | *(unscheduled yet)* | — |
| `apiserver-59bf496dfb-vbt5x` (**old**) | master-3 | false — being torn down |

Same master-1-first, master-3-last ordering as every static-pod rollout so far — but this time it's a **Kubernetes Deployment controller** doing a standard rolling update (spin up new ReplicaSet pod → wait Ready → tear down one old pod), not an operator-specific InstallerController writing to local disk.

**`node-tuning`** (`Working towards "4.20.35"`, 3m46s in) is a **DaemonSet** (`tuned`), and DaemonSets by definition run one pod per node — **this is the first operator to touch worker nodes at all** in this upgrade, even though the MCO node-reboot phase hasn't started. Only the DaemonSet pod's own image needs bumping; no node reboot required for that:

| Node | `tuned` pod ready? |
|---|---|
| master-1 | true |
| master-2 | **false** — mid-rollout |
| master-3 | true |
| worker-1 | true |
| worker-2 | true |

**`monitoring`** (`Rolling out the stack`, 8 days "SINCE" — meaning this operator has been intermittently reconciling for other reasons and just picked up the version bump as part of the same reconcile, not a fresh event) — confirms the monitoring stack's actual pod placement, which is a useful data point on its own: **Prometheus, Alertmanager, Thanos Querier, kube-state-metrics, and the monitoring-plugin all run on the *worker* nodes**, not masters — the first clear example in this upgrade of application/platform workload living on workers rather than masters, distinct from the master-only control-plane static pods seen in every earlier update. `node-exporter` is the one exception (correctly a DaemonSet, one pod per node including masters).

**Per-node MCO/OS/kubelet state:** still unchanged — all 5 nodes `current==desired`, `MCO-STATE=Done`, no cordons, 0 pending CSRs. Even though `tuned` (a DaemonSet) has now touched every node including workers, that's a plain pod image bump, not an MCO-driven OS/kubelet change — the two are independent mechanisms and shouldn't be conflated. The actual MCO/reboot phase still has not begun on any node.

**Anomalies:** none — the `false` ready states above (master-2's openshift-apiserver/tuned pods, master-3's oauth-apiserver pod) are normal mid-rolling-update transients, not degradation; none of the owning ClusterOperators report `Degraded=True`.

---

## Update — ~15:14 UTC: 79% — down to the last 4 operators, all node-touching by nature

**Overall progress:** `Working towards 4.20.35: 766 of 962 done (79% complete), waiting on olm`

Progress slowed (78%→79% in 5 minutes, vs. 25%→78% in the previous gap) — expected, the earlier jump was many fast Deployment/DaemonSet rollouts landing together; what's left now is a smaller set of operators with more moving parts each.

**30 of 34 ClusterOperators are now on 4.20.35.** Exactly 4 remain on 4.19.43:

| Operator | Why it's plausibly last |
|---|---|
| `olm` | Aggregate operator over OLM's own sub-components (catalog-operator, olm-operator, packageserver) — those three (`operator-lifecycle-manager`, `-catalog`, `-packageserver`) are **already** at 4.20.35 individually; `olm` itself is just the umbrella waiting to report the aggregate |
| `network` | OVN-Kubernetes has a DaemonSet component (`ovnkube-node`) running on every node — plausibly timed to land close to the MCO node-reboot phase rather than earlier |
| `dns` | CoreDNS is also DaemonSet-based, same reasoning |
| `machine-config` | **This is the operator that drives the node-by-node OS/reboot phase.** By design, `machine-config`'s own ClusterOperator doesn't report itself fully at the target version until the MachineConfigPools it manages have actually converged nodes to the new rendered config — so it structurally can't finish before the reboot phase runs, it's *gating* on that phase, not just slow to start it. |

This means **the MCO/node-reboot phase is very likely the next thing to happen** — everything captured so far has been the control-plane-pod and platform-operator layer; `machine-config` being the last holdout is the tell.

**OLM sub-components, captured per-node (for completeness before this layer finishes):**

| Pod | Node |
|---|---|
| `catalog-operator` | master-2 |
| `olm-operator` | master-1 |
| `package-server-manager` | master-2 |
| `packageserver` (×2) | master-1, master-2 |
| `certified-operators`, `community-operators` (catalog sources) | master-3 |
| `redhat-marketplace`, `redhat-operators`, `marketplace-operator` | master-1 |

All catalog-source pods restarted freshly around 15:07 (consistent with the recurring ~10-15min catalog-index churn noted in prior issues — normal, not upgrade-specific).

**Per-node MCO/OS/kubelet state:** still unchanged — all 5 nodes `current==desired`, `MCO-STATE=Done`, no cordons, 0 pending CSRs. This is the last capture expected to show this — the next poll should catch the MCO phase beginning.

**Anomalies:** none. Shortening the polling interval further now that the highest-risk phase (master reboots) is imminent.

---

## Update — ~15:20 UTC: 81% — DNS/multus DaemonSets rolling; MCO's own components upgrading themselves first

**Overall progress:** `Working towards 4.20.35: 788 of 962 done (81% complete), waiting on dns, network`

`dns` (`Have 2 up-to-date DNS pods, want 5`) and `network` (`DaemonSet "/openshift-multus/multus" update is rolling out (1 out of 5 updated)`) are now the two visibly-progressing operators — both are DaemonSets, same one-pod-per-node mechanism as `tuned` earlier, now touching every node again:

| Node | `dns-default` ready? | `multus` ready? |
|---|---|---|
| master-1 | true | true |
| master-2 | true | true |
| master-3 | true | **false** — mid-rollout |
| worker-1 | true | true |
| worker-2 | **false** (1 of 2 containers) | true |

`olm` cleared since the last capture (no longer listed as non-clean).

**Important nuance caught this poll: the Machine Config Operator's *own* components are already rolling — this is separate from, and precedes, the actual node OS rollout.** `machine-config-operator`, `machine-config-controller`, the `machine-config-daemon` DaemonSet, and `machine-config-server` pods all show `RESTARTS=2` (or `1,1`) across every node including workers — meaning their own container images already got bumped to the 4.20 versions as ordinary manifest-apply/DaemonSet updates. This is the **operator upgrading itself**, the same pattern CVO went through as step zero. The `machine-config` ClusterOperator itself is still `4.19.43`/clean, and — critically — **no node's `currentConfig`/`desiredConfig` has diverged yet, and both MCPs still show `UPDATING=False`**. So: MCO's control-plane pieces are now running on the new code, but they have not yet rendered a new `rendered-master-*`/`rendered-worker-*` config or told any node to reboot. That's the very next thing expected.

**Per-node MCO/OS/kubelet state:** still fully unchanged — all 5 nodes `current==desired`, `MCO-STATE=Done`, no cordons, all nodes `Ready`, 0 pending CSRs. `etcd` remains clean at 4.20.35 (3/3, quorum intact — nothing here yet threatens it since no node has been touched).

**Anomalies:** none. The two `false` DaemonSet pod states above are normal mid-rollout transients on a healthy pattern seen several times already this run.

---

## Update — ~15:25 UTC: progress stalled at 81% — caught a real, live "bypasses the API server" image pull in progress

**Overall progress:** unchanged at `788 of 962 done (81% complete)` — first poll-to-poll gap with **no** task-count movement all run.

**Root cause of the stall, found directly:** `network`'s message changed to `DaemonSet "/openshift-ovn-kubernetes/ovnkube-upgrades-prepuller" is not available (awaiting 5 nodes)`. This is the OVN-Kubernetes operator's **prepuller** pattern — before it touches the live SDN, it stands up a throwaway DaemonSet on every node whose only job is to pull the new `ovnkube` container image in advance, so the *actual* network-component swap later doesn't stall on a slow image pull mid-cutover (a deliberate design choice for exactly the highest-blast-radius component in the cluster: the SDN).

Caught it live, mid-pull, on **all 5 nodes simultaneously**:

| Node | Prepuller pod | State | Started |
|---|---|---|---|
| master-1 | `ovnkube-upgrades-prepuller-g7m9r` | ContainerCreating (pulling) | 15:17:38Z |
| master-2 | `ovnkube-upgrades-prepuller-dr57q` | ContainerCreating (pulling) | 15:17:38Z |
| master-3 | `ovnkube-upgrades-prepuller-9bfw4` | ContainerCreating (pulling) | 15:17:38Z |
| worker-1 | `ovnkube-upgrades-prepuller-4llxw` | ContainerCreating (pulling) | 15:17:38Z |
| worker-2 | `ovnkube-upgrades-prepuller-mrhqp` | ContainerCreating (pulling) | 15:17:38Z |

Event log confirms exactly what: `Pulling image "quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:96a41271e...​"` on all 5 nodes at the identical timestamp — **this is a real, live instance of the "CRI-O pulls images straight from the registry, no API server involved" link** called out as one of only three non-API-mediated paths in this cluster's architecture. ~8 minutes in at capture time with no `ImagePullBackOff`/error reason on any node — a large image pulling slowly, not stuck.

`dns` is now at 4/5 (only master-3's replacement pod not yet ready — old pod still serving alongside it, standard surge-then-retire behavior for a DaemonSet update).

**Per-node MCO/OS/kubelet state:** unchanged — all 5 nodes `current==desired`, all `Ready`, no cordons, 0 pending CSRs. `etcd` still clean 4.20.35, quorum untouched. The prepuller finishing is the last thing sitting between here and the real OVN cutover, which itself likely precedes or overlaps the MCO node-reboot phase.

**Anomalies:** none — a stalled task-count with a large image pull actively in flight (confirmed via events, not just inferred) is expected, not a hang.

---

## Update — ~15:30 UTC: 82% — prepuller finished and was torn down, multus-additional-cni-plugins now mid-rollout

**Overall progress:** `Working towards 4.20.35: 789 of 962 done (82% complete), waiting on network`

The `ovnkube-upgrades-prepuller` DaemonSet finished pulling on all 5 nodes and **was already removed** (querying its pods now returns nothing) — the prepull-then-cleanup lifecycle completed in a single ~13-minute window (started 15:17:38Z, gone by 15:30). `network`'s blocking message moved on to a different DaemonSet: `"/openshift-multus/multus-additional-cni-plugins" update is rolling out (3 out of 5 updated)` — a second, smaller Multus-family DaemonSet (separate from the `multus` one already updated earlier) rolling normally.

**Per-node MCO/OS/kubelet state:** still fully unchanged — all 5 nodes `current==desired`, all `Ready`, no cordons, 0 pending CSRs. `etcd` remains clean at 4.20.35, quorum untouched. `machine-config` CO still not yet at target — still the structural signal that the node-reboot phase is still ahead of us, now likely closer given the network/OVN layer is nearly through its own rollout.

**Anomalies:** none.

---

## Update — ~15:35 UTC: 86% — down to the last gate, `machine-config` itself, still pre-rollout

**Overall progress:** `Working towards 4.20.35: 830 of 962 done (86% complete), waiting on machine-config`

`network`, `dns`, and `olm` all cleared in this gap — **`oc get co` now shows zero non-clean operators**, meaning `machine-config` is the sole remaining gate, exactly as predicted two updates ago.

**But — important nuance — `machine-config`'s own ClusterOperator hasn't even flipped to `Progressing=True` yet at this capture:**
```
Progressing=False   Cluster version is 4.19.43   (stale message, condition not yet transitioned)
Available=True
```
And **no new `rendered-master-*`/`rendered-worker-*` config exists yet** — `rendered-master-f47e1e246ca48b86b170c52b31d07c12` (7h17m old, predates this upgrade entirely — it's left over from earlier maintenance today) is still the newest one on record. So CVO already considers itself "waiting on machine-config" as the blocking task, but the Machine Config Controller itself is still only in a preparatory reconcile: its logs show it just finished repopulating its informer caches for `ControllerConfig` and `MachineConfigPool` at 15:33:32 — the object that carries the new release's OS image reference (`ControllerConfig`) was just refreshed, which is the precondition for rendering a genuinely new config. **The actual render — and the node cordon/drain/reboot sequence that follows it — has not begun on any node.**

**Per-node MCO/OS/kubelet state:** unchanged — all 5 nodes `current==desired` against the *pre-upgrade* rendered configs, all `Ready`, no cordons, 0 pending CSRs, `etcd` clean at 4.20.35 with quorum untouched.

**Anomalies:** none — this looks like a normal short pause between "CVO says the last gate is machine-config" and "machine-config actually starts rendering," not a stall.

---

## Update — ~15:41 UTC: 86% — MCO phase has begun. **Correction: master and worker pools are draining CONCURRENTLY, not sequentially**

**Overall progress:** still `830 of 962 done (86%)`, now `waiting on machine-config` with `machine-config` itself `Progressing=True: "Working towards 4.20.35"`. `ingress` also newly progressing (router Deployment rolling, standard rolling-update pattern, 1 of 2 replicas updated — unrelated to MCO).

**The MCO node-rollout phase is live.** New rendered configs now exist and are the *desired* (not yet *current*) config on one node per pool:

| Node | Cordoned? | Current cfg | Desired cfg | MCO state |
|---|---|---|---|---|
| master-1 | no | `...f47e1e2` (old) | `...f47e1e2` (old) | Done |
| master-2 | no | `...f47e1e2` (old) | `...f47e1e2` (old) | Done |
| **master-3** | **yes (SchedulingDisabled)** | `...f47e1e2` (old) | **`rendered-master-05e78b07ab1e6fd23c0ed5493c1d09a3` (new)** | **Working** |
| **worker-1** | **yes (SchedulingDisabled)** | `...db128d2` (old) | **`rendered-worker-8d6aaebe12e22b871741f45b0e1370bf` (new)** | **Working** |
| worker-2 | no | `...db128d2` (old) | `...db128d2` (old) | Done |

`oc get mcp` confirms both pools flipped to `UPDATING=True` **at the same time**: `master` pool `UPDATED=False, UPDATING=True`, `worker` pool `UPDATED=False, UPDATING=True`.

**This corrects an assumption made earlier in this doc (and in the companion "Cluster Signal Map" artifact built alongside this capture): the master pool does *not* have to fully finish before the worker pool starts.** MCO here is draining **one master (master-3) and one worker (worker-1) at the exact same time** — each `MachineConfigPool` manages its own node-by-node rollout independently; nothing in the mechanism itself serializes "all masters, then all workers." (It's still true that *within* a pool, MCO does exactly one node at a time — that part held.) The real constraint that matters is etcd quorum, checked next.

**etcd quorum verified intact during master-3's drain:** all 3 etcd static pods still `Running` (master-3's hasn't been killed yet — cordon+drain doesn't touch static pods, only the reboot at the end will), and the etcd operator reports `3 members are available` / `No unhealthy members found`. Static pods and DaemonSet pods are the only things left running on master-3 and worker-1 right now — every regular Deployment/ReplicaSet-owned pod was successfully evicted, confirming the drain step completed cleanly on both nodes:

```
Remaining on master-3: etcd, kube-apiserver, kube-controller-manager, kube-scheduler
                        (all "Node"-owned static pods — never evicted by a drain)
                        + 12 DaemonSet pods (tuned, dns-default, node-resolver, node-ca,
                        machine-config-daemon/server, node-exporter, multus family,
                        network-node-identity, iptables-alerter, ovnkube-node)
```

**Live `rpm-ostree` rebase caught in progress on master-3**, straight from the MCD's own log — this is the actual OS-layer mechanism behind "applying the new rendered config":
```
Updating OS to layered image "quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:5e347c56...​"
Running: rpm-ostree rebase --experimental ostree-unverified-registry:...
ostree chunk layers already present: 38 · needed: 13 (300.6 MB) · custom layers needed: 2 (193.0 MB)
[0/15] through [7/15] chunks fetched so far...
```
This confirms RHCOS upgrades are themselves image-based (ostree/rpm-ostree), not package-by-package — the node pulls a new base image (mostly cached already: 38 of 51 chunks were already present locally, presumably shared lineage with the current 9.6.20260811-0 build) and will reboot into it once the rebase completes. Node OS image and kubelet version on master-3/worker-1 are still pre-upgrade at this exact capture (reboot hasn't happened yet).

**Anomalies:** none. Everything above is the expected, healthy shape of an MCO rollout — cordon → drain (confirmed complete) → rpm-ostree rebase (in progress) → reboot (not yet reached) → uncordon, on one master and one worker simultaneously, independently, with etcd quorum unaffected throughout.

---

## Update — ~15:47 UTC: master-3 completed its reboot cycle — caught the transient degraded cascade live, and confirmed it's already self-healing

**Overall progress:** counter reads `120 of 962 done (12% complete), waiting up to 40 minutes on etcd, kube-apiserver` — **this is not a regression, it's CVO switching into its degraded-operator grace-period display.** When a critical operator (here: `etcd`, `kube-apiserver`) reports `Degraded=True` mid-update, CVO stops showing the raw task counter and instead shows a bounded wait-and-retry countdown, precisely so a normal, self-healing reboot blip doesn't get treated as a hard failure. Confirmed below that this is exactly that case.

**Node state at the moment of peak disruption:**

| Node | Status | Kubelet | OS build | Notes |
|---|---|---|---|---|
| master-1 | Ready | v1.32.13 | 20260811-0 | untouched |
| master-2 | Ready | v1.32.13 | 20260811-0 | untouched |
| **master-3** | **`NotReady`, cordoned** | **v1.33.13** | **20260818-0** | mid post-reboot settle |
| **worker-1** | Ready (uncordoned) | **v1.33.13** | **20260818-0** | **rollout complete, converged** |
| **worker-2** | Ready, **now cordoned** | v1.32.13 | 20260811-0 | **worker pool moved to its 2nd node** |

**Confirms the kubelet version jump is real and immediate on reboot**: master-3 and worker-1 both already report **kubelet v1.33.13** (OCP 4.20 ships Kubernetes 1.33, vs. 4.19's 1.32 — the minor-version jump in Kubernetes itself is the whole reason this is called a "y-stream"/minor upgrade) and the newer RHCOS build `9.6.20260818-0`, up from `9.6.20260811-0`. **worker-1 has fully converged** (current==desired, uncordoned) — the worker pool already finished its first node and moved on to worker-2, independently of the master pool's progress on master-3.

**The degraded cascade, captured at the exact moment it happened, with root cause:**

```
etcd:                     EtcdMembersDegraded: 2 of 3 members available, master-3 unhealthy
kube-apiserver:           NodeControllerDegraded: master-3 not ready since 15:46:49Z —
                          KubeletNotReady: "no CNI configuration file in /etc/kubernetes/cni/net.d/.
                          Has your network provider started?"
kube-controller-manager:  (same NodeControllerDegraded, same cause)
kube-scheduler:           (same NodeControllerDegraded, same cause)
image-registry:           Available=False (deployment does not have available replicas) — 5s old
ingress:                  Available=False (router deployment MinimumReplicasUnavailable) — 4s old
```

**Root cause, confirmed by immediate follow-up check: this is the exact expected reboot transient, already resolved by the time of the very next query.** A freshly-rebooted node's kubelet comes up before its CNI (OVN) has finished initializing and written `/etc/kubernetes/cni/net.d/` — so kubelet reports the node NotReady for pod networking purposes for roughly a minute, which cascades into etcd (that node's member briefly unreachable) and the three static-pod operators (their `NodeController` sub-check keys off node readiness). Confirmed recovered on immediate re-check:
```
master-3 node conditions:  Ready=True — "kubelet is posting ready status"
ovnkube-node-5t9cf on master-3: 8/8 Running (8 restarts — consistent with the reboot cycle)
```
`image-registry`'s and `ingress`'s dips are a **separate, correctly-explained side effect of worker-2 now being drained** (not master-3): `cluster-image-registry-operator`'s pod was evicted and is rescheduling, and one of the two `router-default` replicas that lived on worker-2 is `Terminating` with its replacement `Pending` — ordinary Deployment-capacity dip from an MCD eviction, not a new fault. This is precisely the "first genuine workload disruption" moment anticipated earlier in this doc for the worker pool.

**etcd quorum was never actually lost** — "2 of 3 members available" is above the quorum floor (etcd needs 2-of-3, not 3-of-3); this is the same "briefly unhealthy for 1-6 minutes post-boot, self-heals" pattern already documented from the manual RAM-bump procedure in issue 13, just happening automatically here.

**Anomalies:** a real, live degraded cascade occurred (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `image-registry`, `ingress` all briefly non-clean) — flagged in full above rather than glossed over, but root-caused to the expected post-reboot CNI-init window on master-3 plus the expected eviction dip on worker-2, and **already confirmed recovering** on the very next query (master-3 back to `Ready=True`, its OVN pod healthy). Continuing to poll at a shorter interval to confirm full recovery across all the above operators before easing off.

**Worker pool fully converged, ~15:54 UTC.** `oc get mcp` now shows `worker: UPDATED=True, UPDATING=False, READYMACHINECOUNT=2, UPDATEDMACHINECOUNT=2` — both worker-1 and worker-2 are on kubelet v1.33.13 / RHCOS `9.6.20260818-0`, uncordoned, `MCO-STATE=Done`. **The worker pool has finished before the master pool** — a direct confirmation of the earlier correction that the two pools aren't sequenced against each other; whichever pool has fewer/faster nodes to roll can finish first.

**Master pool now on its 2nd node, master-1 — same expected reboot-transient pattern recurred, this time even more cleanly:** `master-1` NotReady/cordoned since `15:53:50Z`, same `KubeletNotReady: no CNI configuration file` cause, cascading to the same three `NodeControllerDegraded` operators (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`). **This time `etcd` stayed clean throughout** (`Available=True, Degraded=False`, no unhealthy-member message) — plausibly because etcd's cross-member traffic rides the host network directly rather than the pod overlay, so it isn't necessarily affected by a CNI-init gap the way the API-server-side NodeController checks are; or simply a shorter window this time. Either way, a cleaner recovery than master-3's. Progress counter again shows the CVO grace-period display (`122/962, waiting up to 40 minutes on kube-apiserver`) rather than raw counting — same designed behavior as before, not a new fault.

**Confirmed fully recovered, ~15:52 UTC.** `etcd` back to clean (`Available=True, Degraded=False`, no message — full 3/3 healthy). `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `image-registry` all clean. Only `ingress` (normal transient `DeploymentRollingOut`) and `machine-config` (still the expected gating operator) remain non-clean — the same healthy shape as every prior "in progress" capture. CVO's progress display also reverted from the 40-minute grace-period message back to ordinary task counting, now at **65% (630/962)** — confirming the whole episode was exactly the bounded, self-healing degraded-window CVO is designed to tolerate, not a real fault. **Master-3 and worker-1 have both fully converged** (`MCO-STATE=Done`, kubelet v1.33.13, RHCOS `9.6.20260818-0`, uncordoned). **Master pool has now moved to master-1** (cordoned, `Working`) and **worker pool is still on worker-2** (cordoned, `Working`) — both pools continuing their independent one-at-a-time rollout as expected, no CSRs pending.

---

## Update — ~15:59 UTC: 86% — master-1 converged cleanly; master-2 is the last node in the whole cluster left to update

**Overall progress:** back to `830 of 962 done (86% complete), waiting on machine-config` — normal task counting resumed, confirming master-1's reboot-transient (previous update) fully cleared with **zero lasting effect** and no repeat of any degraded condition. `oc get co` shows **only `machine-config` non-clean** — every other operator, including the ones that cascaded during master-1's reboot, is clean.

**Node state — 4 of 5 nodes now fully converged, only master-2 left:**

| Node | Cordoned? | Kubelet | OS build | MCO state |
|---|---|---|---|---|
| master-1 | no | **v1.33.13** | **20260818-0** | Done — converged |
| **master-2** | **yes** | v1.32.13 (old) | 20260811-0 (old) | **Working — last node in the cluster** |
| master-3 | no | v1.33.13 | 20260818-0 | Done |
| worker-1 | no | v1.33.13 | 20260818-0 | Done |
| worker-2 | no | v1.33.13 | 20260818-0 | Done |

`master` MCP: `READYMACHINECOUNT=2, UPDATEDMACHINECOUNT=2` of 3 — matches. `worker` MCP: fully `UPDATED=True`. `etcd` clean, quorum untouched, 0 pending CSRs. This is very likely the last reboot of the entire upgrade — once master-2 completes its cordon → drain → rebase → reboot → uncordon cycle, both MachineConfigPools converge, `machine-config`'s ClusterOperator can finally report itself at 4.20.35, and the CVO's task graph should complete.

**Anomalies:** none.

---

## Final State — upgrade completed ~16:02:57 UTC

`oc get clusterversion` confirms the upgrade finished and the CVO wrote a `Completed` history entry:

```
startedTime: 2026-08-27T14:33:42Z   completionTime: 2026-08-27T16:02:57Z   version: 4.20.35   state: Completed
```

**Total elapsed time: ~1h29m** from `oc adm upgrade --to=4.20.35` to full completion.

**Per-node before/after:**

| Node | Kubelet before | Kubelet after | OS build before | OS build after | Rendered config after |
|---|---|---|---|---|---|
| master-1 | v1.32.13 | **v1.33.13** | 9.6.20260811-0 | **9.6.20260818-0** | `rendered-master-05e78b07...` |
| master-2 | v1.32.13 | **v1.33.13** | 9.6.20260811-0 | **9.6.20260818-0** | `rendered-master-05e78b07...` |
| master-3 | v1.32.13 | **v1.33.13** | 9.6.20260811-0 | **9.6.20260818-0** | `rendered-master-05e78b07...` |
| worker-1 | v1.32.13 | **v1.33.13** | 9.6.20260811-0 | **9.6.20260818-0** | `rendered-worker-8d6aaebe...` |
| worker-2 | v1.32.13 | **v1.33.13** | 9.6.20260811-0 | **9.6.20260818-0** | `rendered-worker-8d6aaebe...` |

All 5 nodes converged onto identical rendered configs within their pool (`master` MCP and `worker` MCP both `UPDATED=True`), all 5 `Ready`, none cordoned. **All 34 ClusterOperators clean at 4.20.35** (`Available=True, Progressing=False, Degraded=False`). `etcd` 3/3 healthy, quorum never genuinely lost at any point (lowest observed was 2-of-3, always above the quorum floor). **0 pending CSRs** at completion — kubelet cert renewal on every rebooted node auto-approved cleanly. Master RAM settled at 40-69% (master-3 tightest, consistent with its historical pattern), node `/var` disk 34-57% (master-1/master-3 climbing again toward the level that previously triggered a `crictl rmi --prune`, not yet urgent).

**What this run demonstrated, tying back to this doc's purpose:** the CVO drives everything through a fixed, numbered manifest-graph (962 tasks here) gated on each ClusterOperator's own convergence; static-pod operators (etcd, kube-apiserver, scheduler, controller-manager) roll via their own revision-counter + InstallerController, one master at a time, writing manifests straight to local disk; Deployment/DaemonSet-based operators use ordinary Kubernetes rolling updates; and the two MachineConfigPools (master, worker) roll **independently of each other**, not sequentially — the single biggest correction to the initial assumption made at the start of this capture, confirmed by direct observation of master-3/worker-1 and later master-1/worker-2 draining concurrently. The one recurring, real, self-healing failure signature observed three times (once per master reboot) was the "`KubeletNotReady`: no CNI configuration file" cascade into `etcd`/`kube-apiserver`/`kube-controller-manager`/`kube-scheduler` `NodeControllerDegraded` — always cleared within about a minute of the node coming back up, never threatened etcd quorum, and got cleaner each time (the last one, master-2, isn't even visible in this final state because it cleared before the completion poll caught it).

---

Related: [[project-ocp-issue-repo]], issue 13, `checklists/minor-version-upgrade-procedure.md`
