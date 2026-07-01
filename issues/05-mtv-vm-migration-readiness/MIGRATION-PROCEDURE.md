# MTV Migration Procedure — ESXi/vCenter → OpenShift Virtualization

**Cluster:** lab.ocp.local | OCP 4.16.55 | OpenShift Virtualization 4.16.38 | MTV 2.7.12
**Prerequisite:** Resolve the blocking issues in [README.md](README.md) (compute + storage capacity) before starting Phase 3 onward. Phases 0-2 (provider setup, connectivity checks) can be done in parallel with capacity remediation.

---

## Phase 0 — Prerequisites Checklist

- [ ] Worker compute capacity increased to fit control-plane + planned guest VM footprint
- [ ] Storage backend expanded, `nfs-storage` StorageProfile has explicit `claimPropertySets`
- [ ] Network bridge + `NetworkAttachmentDefinition` created (this phase, below) for VMs that must keep their IP
- [ ] Network path from OCP cluster to vCenter API (TCP 443) and ESXi hosts (TCP 443/902 for NBD, or via VDDK) confirmed open
- [ ] vCenter service account with read-only (minimum) access to the VMs/datastores/networks being migrated
- [ ] vCenter CA certificate (or thumbprint) available, or explicit decision to skip cert verification (lab only — never in production)
- [ ] List of VMs to migrate, with: guest OS + version, vCPU/RAM, disk sizes, source network/port group, whether VMware Tools is installed and current
- [ ] Change window / migration order agreed (which VMs first — start with a low-risk Linux VM as a pilot)
- [ ] Downtime tolerance per VM decided: **cold** migration (VM powered off, simplest, some downtime) vs **warm** migration (VM stays up during bulk copy, short cutover window, requires CBT-capable vSphere and more moving parts)

---

## Phase 1 — Prepare the OCP Target Environment

### 1a. Confirm OpenShift Virtualization + MTV health
```bash
export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig
oc get csv -n openshift-cnv
oc get hyperconverged -n openshift-cnv
oc get csv -n openshift-mtv
oc get pods -n openshift-mtv
# All should be Running/Succeeded — forklift-controller and forklift-validation
# must be 2/2 and 1/1 Running (not Pending) before continuing
```

### 1b. Storage — verify capacity and StorageProfile
```bash
oc get storageclass
oc get storageprofile nfs-storage -o yaml

# If claimPropertySets is missing from .spec (not just .status):
oc patch storageprofile nfs-storage --type=merge -p '{
  "spec": {
    "claimPropertySets": [
      {"accessModes": ["ReadWriteMany"], "volumeMode": "Filesystem"}
    ]
  }
}'
```

### 1c. Networking — create a bridge for VMs that must keep their IP

Using kubernetes-nmstate (bundled with OpenShift Virtualization):

```yaml
# nncp-br1.yaml — apply once per worker, or use nodeSelector for all VM-capable workers
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br1-worker-bridge
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: <physical-nic-e.g.-eth1>
```
```bash
oc apply -f nncp-br1.yaml
oc get nncp   # wait for Available
```

Then the NetworkAttachmentDefinition MTV's network mapping will target:
```yaml
# nad-br1.yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: br1-network
  namespace: <target-namespace>
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "br1-network",
    "type": "bridge",
    "bridge": "br1"
  }'
```
```bash
oc apply -f nad-br1.yaml
```

### 1d. Create the target namespace(s)
```bash
oc new-project vm-migration-linux
oc new-project vm-migration-windows
# Or one project per application — avoid a single dumping-ground namespace
```

---

## Phase 2 — Create the Source Provider (vCenter)

Via web console: **Migration → Providers for virtualization → Create Provider**

- **Type:** VMware
- **Name:** e.g. `vcenter-prod`
- **vCenter URL:** `https://<vcenter-fqdn-or-ip>/sdk`
- **Credentials:** service account username/password (stored as a `Secret`)
- **CA certificate:** paste vCenter's CA cert, or check "Skip certificate verification" (lab only)
- **VDDK init image:** strongly recommended for performance — build once per vCenter version using VMware's SDK per Red Hat's documented process, push to an accessible registry, reference the image here. Without VDDK, MTV falls back to a slower NBD-based copy.

CLI equivalent:
```bash
oc create secret generic vcenter-creds -n openshift-mtv \
  --from-literal=user='<svc-account>@vsphere.local' \
  --from-literal=password='<password>' \
  --from-literal=cacert="$(cat vcenter-ca.pem)"   # omit if skipping cert verification

cat <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: vcenter-prod
  namespace: openshift-mtv
spec:
  type: vsphere
  url: https://<vcenter-fqdn-or-ip>/sdk
  secret:
    name: vcenter-creds
    namespace: openshift-mtv
  settings:
    vddkInitImage: <registry>/vddk:<version>   # omit to use NBD fallback
EOF
```

Verify:
```bash
oc get providers.forklift.konveyor.io -n openshift-mtv
# STATUS should be Ready, CONNECTED=True, INVENTORY=True
```

If it doesn't go Ready: check `oc describe provider vcenter-prod -n openshift-mtv` for auth/connectivity/cert errors first.

---

## Phase 3 — Network Mapping

Via web console: **Migration → Network mappings → Create**, or:

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: NetworkMap
metadata:
  name: vcenter-network-map
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vcenter-prod
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        name: "VM Network"          # exact source port group name from vCenter inventory
      destination:
        type: multus
        name: br1-network
        namespace: <target-namespace>
    - source:
        name: "Isolated-Test-Net"
      destination:
        type: pod                    # falls back to default pod network (NAT, no fixed IP)
```

---

## Phase 4 — Storage Mapping

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: StorageMap
metadata:
  name: vcenter-storage-map
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vcenter-prod
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  map:
    - source:
        name: "datastore1"           # exact source datastore name from vCenter inventory
      destination:
        storageClass: nfs-storage
        accessMode: ReadWriteMany
        volumeMode: Filesystem
```

---

## Phase 5 — Select VMs and Create the Migration Plan

1. **Migration → Plans for virtualization → Create Plan**
2. Select provider `vcenter-prod`, browse inventory, select VMs (start with one pilot Linux VM)
3. Select target namespace, network map, storage map from Phases 3-4
4. **Migration type:**
   - **Cold** — source VM is powered off before copy starts. Simpler, more reliable, use this first.
   - **Warm** — source VM stays running; MTV does an initial full copy, then incremental syncs via CBT, then a short cutover (final sync + power-off + power-on target). Requires vSphere CBT support and more validation.
5. **Preserve static IPs:** enable if the VM must keep its exact IP (requires the network map to target a bridge NAD, not pod network — see Phase 3)
6. **Hooks (optional):** pre-migration hook (e.g., stop a database service cleanly) / post-migration hook (e.g., run a validation script) via an Ansible playbook `ConfigMap`

CLI equivalent (abbreviated):
```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: pilot-linux-migration
  namespace: openshift-mtv
spec:
  provider:
    source: {name: vcenter-prod, namespace: openshift-mtv}
    destination: {name: host, namespace: openshift-mtv}
  targetNamespace: vm-migration-linux
  map:
    network: {name: vcenter-network-map, namespace: openshift-mtv}
    storage: {name: vcenter-storage-map, namespace: openshift-mtv}
  warm: false
  vms:
    - id: <vm-moref-from-inventory>
```

---

## Phase 6 — Validate the Plan Before Running

MTV runs automatic validation against each VM (via `forklift-validation`) and surfaces **concerns**:

```bash
oc get plan pilot-linux-migration -n openshift-mtv -o jsonpath='{.status.migration.vms[*].conditions}'
```

Common concerns to resolve before proceeding:
- Source VM has existing vSphere snapshots (consolidate/remove first — snapshots complicate and slow the copy)
- Unsupported disk type (e.g., RDM passthrough disks need special handling)
- CPU/host compatibility warnings
- VMware Tools not installed or out of date (needed for clean quiesce on cold migration, and for the OS to release its device state properly)

Do not proceed past **Critical** concerns — MTV will block execution on those; **Warning**-level concerns are a judgment call.

---

## Phase 7 — Execute the Migration

```bash
oc get plan pilot-linux-migration -n openshift-mtv    # confirm Ready=True
# Start via web console "Start" button, or:
oc patch plan pilot-linux-migration -n openshift-mtv --type=merge -p '{"spec":{"warm":false}}'
```

Monitor progress:
```bash
oc get migration -n openshift-mtv
oc describe migration <migration-name> -n openshift-mtv

# Per-VM DataVolume import progress
oc get dv -n vm-migration-linux
oc describe dv <dv-name> -n vm-migration-linux

# Importer pod logs (disk copy progress)
oc logs -n vm-migration-linux -l app=containerized-data-importer -f
```

### Linux VMs
- Modern kernels (RHEL 7+/most current distros) already have `virtio_blk`/`virtio_net` drivers built in — no driver injection needed, boots natively on KVM/virtio devices.
- If `open-vm-tools` is installed, it's harmless to leave initially but should be replaced with `qemu-guest-agent` post-migration (see checklist).

### Windows VMs
- MTV automatically injects VirtIO drivers into the Windows image during conversion (via the bundled `virtio-win` driver disk) — this is what prevents "INACCESSIBLE_BOOT_DEVICE" on first boot. Confirm this step completes in the conversion pod logs; don't skip it.
- VMware Tools should be installed and current on the source **before** migration — it's used for clean guest quiesce, especially important for warm migration's incremental syncs.
- After migration, VMware Tools should be uninstalled and replaced with the QEMU guest agent (usually injected automatically by MTV's Windows driver disk; verify in Post-Migration Checklist).
- Watch for Windows activation/licensing implications if the hardware ID changes significantly (relevant for KMS/MAK-licensed Windows Server) — plan for reactivation.

### Warm migration cutover (if used)
- Precopy runs in the background with periodic incremental syncs while the source VM stays up
- When ready, trigger **Cutover** (web console or `oc patch` the Migration's cutover time) — this does a final incremental sync, powers off the source, and powers on the target
- Keep the cutover window short and pre-announced; this is the only point with real downtime in a warm migration

---

## Phase 8 — Handle Common Failure Points

| Symptom | Likely cause | Check |
|---|---|---|
| DataVolume stuck `ImportInProgress` indefinitely | Storage out of space | `oc describe dv`, `df` on NFS backend |
| Import fails immediately | Provider/network path to ESXi/vCenter blocked, or cert trust issue | `oc logs` on the importer pod, re-check Phase 0 connectivity |
| Windows VM boots to `INACCESSIBLE_BOOT_DEVICE` | VirtIO driver injection didn't run/complete | Re-check conversion pod logs for the Windows VM; confirm `virtio-win` step ran |
| VM has no network / wrong IP | Network map points to `pod` type instead of the bridge NAD, or NAD/bridge misconfigured | `oc get networkmap -o yaml`, `oc get nncp`, `oc get net-attach-def -n <ns>` |
| Plan won't start, blocked on validation | Unresolved Critical concern | `oc get plan -o yaml`, check `.status.migration.vms[].conditions` |

---

## Phase 9 — Cutover and Source Decommission

- [ ] Confirm migrated VM is `Running`, reachable, and passes the [Post-Migration Checklist](POST-MIGRATION-CHECKLIST.md) before touching the source
- [ ] Power off (don't delete yet) the source VM in vCenter to avoid IP/MAC conflicts if the target reuses the same IP
- [ ] Update any hardcoded references (DNS records, load balancer pool members, monitoring targets, firewall rules) that pointed at the source VM's host/hypervisor-specific identifiers
- [ ] Retain the powered-off source VM for an agreed rollback window (e.g., 1-2 weeks) before deleting
- [ ] Repeat Phases 5-9 for the next VM/batch once the pilot is fully validated

---

*Procedure created: 2026-07-01, following the precheck in [README.md](README.md)*
