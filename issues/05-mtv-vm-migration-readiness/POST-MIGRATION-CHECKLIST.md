# Post-Migration Verification Checklist — MTV (ESXi/vCenter → OpenShift Virtualization)

Run through this per-VM immediately after each migration completes, **before** powering off the source VM in vCenter (Phase 9 of [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md)).

---

## 1. Common Checks (all VMs, Linux and Windows)

### Platform-level
```bash
export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig
oc get vm -n <namespace>              # STATUS should be Running
oc get vmi -n <namespace>             # PHASE should be Running, READY True
oc describe vm <name> -n <namespace>  # confirm vCPU/memory match source spec
```

- [ ] `VirtualMachine` status `Running`, `VirtualMachineInstance` `Ready=True`
- [ ] vCPU and memory match the source VM's original allocation
- [ ] Disk size(s) match source (check inside guest, not just the PVC size)
- [ ] No `CrashLoopBackOff`/restart loop on the `virt-launcher` pod:
  ```bash
  oc get pods -n <namespace> -l kubevirt.io=virt-launcher
  ```

### Console / boot
```bash
virtctl console <vm-name> -n <namespace>
# or
virtctl vnc <vm-name> -n <namespace>
```
- [ ] VM boots cleanly to a login prompt (no fsck errors, no boot-device errors, no kernel panic)
- [ ] Hostname is correct (matches source, unless intentionally renamed)
- [ ] System clock is correct and NTP/chronyd is syncing (clock drift after migration is common)

### Networking
- [ ] IP address matches expectation (source IP preserved if that was the plan, or correctly reassigned if not)
- [ ] Can reach default gateway: `ping -c3 <gateway>`
- [ ] DNS resolution works from inside the guest
- [ ] Reachable from the expected subnets/firewall zones (test from a client on the same network the source VM was reachable from)
- [ ] Correct interface driver in use — confirm it's the VirtIO NIC, not still expecting a VMXNET3/E1000 driver

### Guest agent
```bash
oc get vmi <name> -n <namespace> -o jsonpath='{.status.guestOSInfo}'
```
- [ ] Populated (non-empty) — confirms the in-guest agent (qemu-guest-agent / virtio-win agent) is installed and reporting
- [ ] If empty: agent isn't installed/running yet — install it (see OS-specific sections below) rather than assuming migration failed

### Application-level
- [ ] Expected services are running (`systemctl status <service>` / Windows Services console)
- [ ] Application listens on expected ports — compare against a pre-migration baseline captured from the source VM
- [ ] No data loss: for anything critical, spot-check file checksums or row counts against the source (do this *before* powering off the source, while both are available for comparison)
- [ ] Monitoring/backup agents re-registered or reconnected (they often key off hostname/UUID which may have changed)

---

## 2. Linux-Specific Checks

- [ ] `lsmod | grep virtio` shows `virtio_blk`, `virtio_net` (and `virtio_balloon` if memory ballooning is enabled) loaded
- [ ] `/etc/fstab` has no stale VMware-specific device references (rare, but check if disks were referenced by path rather than UUID/label)
- [ ] SELinux/AppArmor status matches expected baseline (`getenforce`, or `aa-status`)
- [ ] If `open-vm-tools` was installed pre-migration: uninstall it and replace with `qemu-guest-agent`
  ```bash
  sudo systemctl disable --now open-vm-tools 2>/dev/null
  sudo yum remove -y open-vm-tools 2>/dev/null || sudo apt remove -y open-vm-tools 2>/dev/null
  sudo yum install -y qemu-guest-agent 2>/dev/null || sudo apt install -y qemu-guest-agent 2>/dev/null
  sudo systemctl enable --now qemu-guest-agent
  ```
- [ ] `chronyd`/`ntpd` active and synced: `chronyc tracking` or `ntpq -p`
- [ ] Swap, if configured, is active and correctly sized (`swapon --show`)

---

## 3. Windows-Specific Checks

- [ ] **Device Manager**: no "Unknown device" or yellow-bang entries — confirms VirtIO drivers (disk, network, balloon) injected and bound correctly. This is the single most important Windows check; `INACCESSIBLE_BOOT_DEVICE` at boot means this step failed during conversion.
- [ ] Network adapter shows as **Red Hat VirtIO Ethernet Adapter** (or similar VirtIO name), not a ghost VMXNET3/E1000 entry
- [ ] Storage controller shows **Red Hat VirtIO SCSI controller**
- [ ] VMware Tools uninstalled (`Programs and Features`) and replaced with the QEMU guest agent service (`QEMU Guest Agent` should appear in `services.msc`, Running)
- [ ] System activation status:
  ```powershell
  slmgr /dlv
  ```
  Reactivate if hardware ID changes triggered a licensing issue (common with KMS/MAK-licensed Windows Server — plan for this in advance, don't treat it as a migration failure)
- [ ] Event Viewer → System log: no repeating boot-time driver or disk errors in the first few boots
- [ ] RDP connectivity works from a client on the expected network
- [ ] Windows Time service synced: `w32tm /query /status`
- [ ] Windows Firewall profile/rules preserved as expected (network profile can flip to "Public" after a NIC change, which silently re-applies stricter firewall rules — check this explicitly)

---

## 4. Cutover Validation

- [ ] Migration `Plan` status shows `Succeeded`:
  ```bash
  oc get plan <plan-name> -n openshift-mtv
  ```
- [ ] Source VM powered off in vCenter (not deleted yet) to avoid IP/MAC conflicts
- [ ] DNS records, load balancer pool members, monitoring targets, and any hardcoded IP/hostname references updated to point at the new VM if anything changed
- [ ] For warm migrations: confirm the final incremental sync completed before cutover (check `Plan` conditions for the cutover timestamp and sync status)

---

## 5. Rollback Plan

- [ ] Source VM retained (powered off, not deleted) for an agreed retention window — recommend at minimum 1-2 weeks for production workloads
- [ ] Rollback procedure documented and understood by the team *before* cutover, not improvised after a problem is found:
  - Power the source VM back on in vCenter
  - Revert DNS/load-balancer changes back to the source VM's IP
  - Power off / scale down the migrated OCP VM to avoid IP conflicts
- [ ] Deletion of the source VM only happens after an explicit sign-off, once the migrated VM has been stable in production for the agreed retention window

---

*Checklist created: 2026-07-01, companion to [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md)*
