# Issue 05 — MTV VM Migration Readiness (ESXi/vCenter → OpenShift Virtualization)

| Field | Detail |
|---|---|
| **Date** | 2026-07-01 |
| **Type** | Planned Migration |
| **Status** | Precheck complete — **Blocked** on capacity, ready once resolved |
| **Scope** | Migrate Linux and Windows VMs from ESXi/vCenter to OCP (lab.ocp.local) via MTV 2.7.12 |
| **Target Namespace(s)** | TBD per workload — create per-application namespace, don't dump all VMs into one namespace |

---

## Precheck Summary

| Area | Status | Finding |
|---|---|---|
| Operators (CNV + MTV) | ✅ Pass | `kubevirt-hyperconverged-operator.v4.16.38` (OpenShift Virtualization), `mtv-operator.v2.7.12` — both `Succeeded` |
| HyperConverged CR | ✅ Pass | `Available=True`, `Progressing=False`, `Degraded=False` |
| Nested virtualization | ✅ Pass | `/dev/kvm` present, `vmx`/`svm` CPU flags exposed on `worker-1`/`worker-2`, `devices.kubevirt.io/kvm` capacity present on both |
| VM-capable nodes | ⚠️ Limited | Only 2 of 5 nodes (`worker-1`, `worker-2`) run `virt-handler` — masters carry the standard `node-role.kubernetes.io/master` taint (expected/correct), so **all guest VM capacity is confined to 2 workers** |
| **Compute capacity** | 🔴 **Blocking** | Each worker: 3 vCPU / ~9GB RAM capacity (~2.5 vCPU / ~8.3GB allocatable). `worker-1` at 99% memory requested, `worker-2` at 95% CPU / 91% memory requested — **before any guest VM is added**. Direct proof: MTV's own `forklift-controller` (0/2 containers) and `forklift-validation` (0/1) pods have sat `Pending` for 45+ minutes with `FailedScheduling: Insufficient cpu, Insufficient memory` |
| **Storage capacity** | 🔴 **Blocking** | Single default StorageClass `nfs-storage` (`nfs-client-provisioner`, `ReclaimPolicy=Retain`, `AllowVolumeExpansion=false`), backed by an NFS export (`/var/nfs/dynamic`) on `svc-infra`'s root disk (`/dev/sda1`, 50GB total) — only **38GB free**. A single Windows Server VM disk alone commonly exceeds that. `StorageProfile nfs-storage` also has no explicit `claimPropertySets` in `.status` — CDI may not reliably infer access/volume mode for this provisioner without manual configuration |
| VM networking | ⚠️ Needs setup | No `NetworkAttachmentDefinition` exists cluster-wide. Without one, migrated VMs only get the default pod network (masquerade/NAT) — they will **not** retain their original IP or be directly reachable from the existing LAN. Required before migrating anything that isn't disposable/test-only |
| MTV source provider | ℹ️ Info | Only the built-in `host` (OCP) provider exists, `Ready`/`Connected`/inventory populated — confirms MTV's own reconciliation into this cluster works correctly. No vCenter/ESXi provider configured yet (expected — that's step 1 of the actual migration, see [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md)) |
| [NESTED-VCENTER-SETUP.md](NESTED-VCENTER-SETUP.md) | Step-by-step nested vCenter + ESXi lab setup on VMware Workstation Pro (Windows 10), used since the original vCenter at 192.168.29.50 was unreachable during the pilot precheck |

**Verdict:** The MTV/OpenShift Virtualization software stack is correctly installed and healthy. The cluster's current **compute and storage sizing** is the blocker, not the software. Both need headroom added before attempting a real migration — see remediation below.

---

## Blocking Issues — Remediation

### 1. Compute capacity (workers)

Current: 2× workers @ 3 vCPU / 9GB RAM, already saturated by existing OCP + OpenShift Virtualization control-plane pods (virt-api ×2, virt-controller ×2, virt-operator ×2, virt-handler, virt-exportproxy ×2, monitoring stack, ingress router, DNS, multus, etc.) — this is normal control-plane footprint, not waste.

**Fix:** increase worker vCPU/RAM on Proxmox (`qm set <vmid> --cores N --memory M`), sized for:
- MTV's own controller pods (~750m CPU / ~656Mi memory combined, currently unschedulable)
- Plus real headroom per planned guest VM (a modest Linux VM: 2 vCPU/4GB; a typical Windows Server VM: 4 vCPU/8GB+)

As a lab sizing baseline: budget for existing control-plane footprint (~3 vCPU / ~8GB already consumed across both workers) **plus** the sum of all planned guest VM requests. Adding a 3rd worker is also worth considering so VM capacity isn't concentrated on just 2 nodes.

### 2. Storage capacity

Current: 38GB free on the NFS backend's root disk — will not hold more than one or two small VM disks.

**Fix options (pick one, in order of lab-friendliness):**
- Expand the `svc-infra` VM's disk (`/dev/sda1`) on Proxmox and grow the filesystem, or
- Attach a dedicated, larger disk to `svc-infra` for `/var/nfs/dynamic` specifically, or
- Point a new StorageClass at different, larger-capacity storage entirely

Also set explicit `claimPropertySets` on the `nfs-storage` StorageProfile (`accessModes: [ReadWriteMany]`, `volumeMode: Filesystem`) so CDI doesn't have to guess:
```bash
oc patch storageprofile nfs-storage --type=merge -p '{
  "spec": {
    "claimPropertySets": [
      {"accessModes": ["ReadWriteMany"], "volumeMode": "Filesystem"}
    ]
  }
}'
```

### 3. VM networking

**Fix:** create a Linux bridge `NodeNetworkConfigurationPolicy` (kubernetes-nmstate, bundled with OpenShift Virtualization) on the worker nodes, bridging to the physical/VLAN interface those VMs need to land on, then a matching `NetworkAttachmentDefinition` for MTV's network mapping to target. Full steps in [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md) Phase 1.
| [NESTED-VCENTER-SETUP.md](NESTED-VCENTER-SETUP.md) | Step-by-step nested vCenter + ESXi lab setup on VMware Workstation Pro (Windows 10), used since the original vCenter at 192.168.29.50 was unreachable during the pilot precheck |

---

## Files

| File | Description |
|---|---|
| [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md) | Full step-by-step migration procedure: prerequisites, provider setup, network/storage mapping, plan creation, execution for Linux and Windows VMs |
| [NESTED-VCENTER-SETUP.md](NESTED-VCENTER-SETUP.md) | Step-by-step nested vCenter + ESXi lab setup on VMware Workstation Pro (Windows 10), used since the original vCenter at 192.168.29.50 was unreachable during the pilot precheck |
| [POST-MIGRATION-CHECKLIST.md](POST-MIGRATION-CHECKLIST.md) | Post-migration verification checklist (common, Linux-specific, Windows-specific, cutover, rollback) |

---

## Related

- Cluster is currently healthy otherwise: all 5 nodes `Ready`, no degraded operators as of this precheck (see [Issue 03](../03-ovn-kubernetes-crash-loop-after-reboot/) for the automated recovery that keeps it that way across reboots)
- `oc`/`kubectl` on the bastion match server version 4.16.55 (see [Issue 04](../04-oc-client-server-version-skew/))
