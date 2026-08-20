# Issue 12 — Uninstall Idle OpenShift Virtualization (CNV) to Reclaim Resources

| Field | Detail |
|---|---|
| **Date** | 2026-08-20 |
| **Type** | Resource reclamation (administration, not an incident) |
| **Status** | Completed |
| **Trigger** | Follow-up to [issue 11](../11-4.19.43-patch-readiness-review/README.md)'s 4.20-readiness re-check — investigated why a cluster with no running applications/databases was showing high memory usage on `master-3` and `worker-1` |
| **Supersedes** | [issue 05](../05-mtv-vm-migration-readiness/README.md) — the MTV VM migration plan CNV was installed for is abandoned |

---

## Why

During a re-check of 4.20 upgrade readiness, master node memory was still
tight (~85-88%) despite this cluster having no application or database
workloads running. Investigation found the actual cause: **OpenShift
Virtualization (CNV) was fully installed and running its entire
control-plane stack — ~34 pods, ~2.7GB of memory — while managing zero
actual VMs**, for 85+ days. It had been installed for the MTV VM migration
pilot in issue 05, which never progressed past the precheck stage (blocked
on capacity at the time) and has since been decided as not going forward.

Confirmed before touching anything:
- `oc get vm -A` / `oc get vmi -A` — zero VMs, zero VM instances
- `oc get pvc -n openshift-virtualization-os-images` — no storage behind the golden-image DataVolumes (they'd never actually provisioned, consistent with the `ErrClaimNotValid` errors noted in issue 08)
- MTV/Forklift operator was already gone from the cluster (not present in current CSV list) — the migration effort had already effectively lapsed
- `HyperConverged` CR was healthy, not mid-reconcile — safe to remove cleanly

**Distribution mattered more than the raw total**: of the ~2.7GB, 16 of the
~34 CNV pods were concentrated on `worker-1` alone — directly explaining why
that specific node was running tight.

---

## Removal Procedure

1. **Delete the `HyperConverged` CR** (`kubevirt-hyperconverged` in `openshift-cnv`) — triggers HCO's own managed-resource teardown. This alone removed the bulk of the footprint: `virt-api`, `virt-controller`, `virt-handler`, `virt-exportproxy`, `cdi-deployment`, `cdi-apiserver`, `bridge-marker`, `kubemacpool`, `kube-cni-linux-bridge-plugin`, `virt-template-validator`, `kubevirt-apiserver-proxy`, `kubevirt-console-plugin`, `kubevirt-ipam-controller-manager`. Also auto-removed the `openshift-virtualization-os-images` namespace (SSP-managed).
2. **Delete the OLM Subscription and CSV** (`kubevirt-hyperconverged` / `kubevirt-hyperconverged-operator.v4.19.33`) — the top-level operator deployments (`virt-operator`, `cdi-operator`, `hco-operator`, `hco-webhook`, `cluster-network-addons-operator`, `ssp-operator`, `aaq-operator`, `hostpath-provisioner-operator`) are not owned by the CSV directly and didn't cascade-delete from this step alone.
3. **Delete the `openshift-cnv` namespace** — cleanly removed the remaining operator deployments.
4. **Verified no custom resources remained**, then deleted the 7 now-empty leftover CRDs (`aaqs.aaq.kubevirt.io`, `cdis.cdi.kubevirt.io`, `hostpathprovisioners.hostpathprovisioner.kubevirt.io`, `hyperconvergeds.hco.kubevirt.io`, `kubevirts.kubevirt.io`, `networkaddonsconfigs.networkaddonsoperator.network.kubevirt.io`, `ssps.ssp.kubevirt.io`) for a fully clean uninstall.

`openshift-lightspeed` (the other installed operator, ~61Mi) was left untouched — negligible footprint, not part of this investigation.

---

## Result — Measured Before/After

| Node | Before | After |
|---|---|---|
| worker-1 | 81% | **74%** |
| master-2 | 72% | **66%** |
| master-1 | 63% | **55%** |
| worker-2 | 69% | **65%** |
| master-3 | 86% | 85-88% (unchanged — never hosted much CNV load directly; **still an open item for 4.20 readiness**, see issue 11) |

Post-removal health check: all ClusterOperators `Available=True/Progressing=False/Degraded=False`, all 5 nodes `Ready`, `openshift-lightspeed` unaffected.

---

## Follow-ups

- `master-3`'s memory pressure is **not** explained by CNV and remains an open question for the 4.20 y-stream readiness decision tracked in issue 11 — worth its own investigation.
- If VM migration is ever revisited, CNV would need to be reinstalled from OperatorHub — nothing here prevents that, this was a clean uninstall, not a lockout.
- Proxmox-host-level memory headroom (user-reported 64GB physical, fully allocated across the 5 VMs) was flagged as worth checking directly on the hypervisor (`192.168.29.2`) but not yet done — that access attempt was blocked pending explicit confirmation, separate from this in-cluster cleanup.
