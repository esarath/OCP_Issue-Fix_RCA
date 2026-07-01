# Nested vCenter Setup — VMware Workstation Pro (Windows 10 host)

**Context:** The original vCenter at `192.168.29.50` referenced for the MTV pilot migration (see [README.md](README.md)) is currently unreachable — confirmed via ICMP (`Destination Host Unreachable`) and ARP (`FAILED`) from both the Proxmox host (`192.168.29.2`) and the bastion (`192.168.29.10`) on 2026-07-01. Until that host is confirmed back up, use this nested lab setup instead to unblock MTV pilot testing (Linux + Windows small VMs).

**Host resources:** Windows 10 system, 12 vCPU / 20GB RAM total (not a lab-only budget — the whole machine), VMware Workstation Pro installed, 200GB free external disk for VM storage.

---

## Resource Plan

VCSA's official minimum (Tiny deployment: 2 vCPU / 14GB RAM) alone consumes ~70% of the entire 20GB host budget, and it runs *inside* the nested ESXi VM, not alongside it — so Workstation only hosts **one** VM (the nested ESXi), sized to internally run VCSA + the 2 test VMs.

| Layer | vCPU | RAM | Disk (thin) |
|---|---|---|---|
| Windows 10 + Workstation (reserved, not assigned to any VM) | ~2 | ~4GB | — |
| **Nested ESXi VM** (the only Workstation-level VM) | 10 | 16GB | 100-120GB |
| — VCSA, inside the nested ESXi (resized post-deploy, see Phase F) | 2 | **10GB** (below official 14GB min) | ~30-40GB actual |
| — Linux test VM | 1-2 | 1-2GB | ~10GB actual |
| — Windows test VM | 2 | 2GB | ~20GB actual |

This fully commits the 20GB budget with no safety margin. Running VCSA at 10GB instead of its supported 14GB minimum is an unsupported-but-common homelab practice — expect a noticeably slow vCenter UI, especially right after power-on. Functional for MTV connectivity/inventory/cold-migration testing.

**Fallback if RAM pressure is unworkable:** skip VCSA entirely, point MTV's vSphere Provider directly at the nested ESXi host's own API (`https://192.168.29.51/sdk`) instead of vCenter — frees the whole 14GB VCSA footprint.

---

## Phase A — Prep the Windows 10 host

1. BIOS/UEFI: confirm Intel VT-x + VT-d (or AMD-V + AMD-Vi) enabled.
2. Disable Hyper-V (conflicts with Workstation's nested virtualization — both want exclusive control of VT-x):
   - "Turn Windows features on or off" → uncheck **Hyper-V**, **Virtual Machine Platform**, **Windows Hypervisor Platform**, **Windows Sandbox**
   - Elevated cmd: `bcdedit /set hypervisorlaunchtype off`
   - Reboot
3. Confirm VMware Workstation Pro 17.x installed.
4. Format/mount the 200GB external disk with a drive letter (e.g. `E:\`) for all nested VM files.

## Phase B — Download installers

1. `support.broadcom.com` (VMware downloads moved here post-acquisition) — free account, 60-day eval covers lab use.
2. Download ESXi 8.0 (or 7.0) ISO.
3. Download matching VMware vCenter Server (VCSA) installer ISO.

## Phase C — Create the nested ESXi VM in Workstation

1. File → New Virtual Machine → **Custom (advanced)**.
2. Installer disc image: the ESXi ISO.
3. **Guest OS: "VMware ESXi"** — critical for proper nested-virtualization exposure.
4. Name `Nested-ESXi01`, location on the external drive (`E:\VMs\Nested-ESXi01`).
5. Processors: **10 vCPU**. Confirm **"Virtualize Intel VT-x/EPT or AMD-V/RVI"** checked.
6. Memory: **16 GB**.
7. Network adapter: **Bridged** (puts nested ESXi on `192.168.29.0/24`, same segment as Proxmox/OCP — no extra routing needed for MTV to reach it).
8. Disk: **100-120GB**, thin-provisioned (leave "Allocate all disk space now" unchecked).
9. Power on, complete the standard ESXi installer prompts (EULA, disk select, root password, reboot).

## Phase D — Configure nested ESXi networking

1. DCUI (yellow console) → F2 → log in as root.
2. **Configure Management Network** → static IP on `192.168.29.0/24`. Avoid IPs already in use (`.2` Proxmox, `.10` svc-infra, `.21-23` masters, `.31-32` workers) — use **192.168.29.51** for the ESXi host (reserving `.50` for VCSA).
3. Subnet mask `255.255.255.0`, gateway, DNS.
4. DCUI "Test Management Network" → confirm gateway ping succeeds.
5. Browse `https://192.168.29.51/` from Windows to confirm the ESXi host client loads.

## Phase E — Deploy VCSA onto the nested ESXi

1. Mount VCSA ISO, run `vcsa-ui-installer\win32\installer.exe` → Install.
2. **Stage 1:**
   - EULA → Deployment type: **vCenter Server with embedded Platform Services Controller**
   - Target: `192.168.29.51`, root credentials, accept cert
   - VM name `vcenter-mtv-lab`, set VCSA root password
   - **Deployment size: Tiny. Storage size: Default.**
   - Datastore: ESXi local datastore, **check "Enable Thin Disk Mode"** (essential — avoids reserving VCSA's full ~400-500GB nominal size upfront)
   - Network: bridged port group, static IP **192.168.29.50**, mask, gateway, DNS
   - Finish (15-30+ min)
3. **Stage 2** (auto-continues):
   - Time sync: "Synchronize time with ESXi host"
   - SSO domain `vsphere.local`, set SSO admin password
   - Decline CEIP, Finish
4. Browse `https://192.168.29.50/ui` to confirm vSphere Client loads.

## Phase F — Resize VCSA to fit the RAM budget

1. Power off VCSA VM (ESXi host client).
2. Edit VM settings → reduce memory 14GB → **10GB** (don't go lower — below ~8-10GB, vCenter services tend to crash-loop).
3. Power on, allow extra time (5-10+ min) for services to start under memory pressure.
4. Verify login at the vSphere Client URL — be patient on first load.

## Phase G — Create the 2 test VMs + inventory

1. Log in as `administrator@vsphere.local`.
2. Create Datacenter `Lab-DC`, add the nested ESXi host (`192.168.29.51`).
3. **Linux VM:** 1-2 vCPU, 1-2GB RAM, 20GB thin disk — minimal distro (Debian netinst / minimal Ubuntu Server / Alpine).
4. **Windows VM:** 2 vCPU, 2GB RAM, 40-60GB thin disk — **Windows Server Core** (no GUI, boots reliably at 2GB); free eval ISO from Microsoft Evaluation Center.
5. Install VMware Tools / open-vm-tools on both (needed per [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md) Phase 7 Windows notes).

## Phase H — Recreate the `svc-mtv` service account

1. Administration → Single Sign-On → Users and Groups → domain `vsphere.local` → Add User → `svc-mtv`.
2. Administration → Access Control → Global Permissions → Add Permission → `svc-mtv` → Role: **Read-only** (sufficient for MTV inventory discovery + cold migration where source VMs are powered off manually first).

## Phase I — Confirm reachability from the OCP side

From svc-infra or the Proxmox host:
```bash
ping 192.168.29.50
curl -k https://192.168.29.50/
```
Once both succeed, proceed to MTV Provider creation (see [MIGRATION-PROCEDURE.md](MIGRATION-PROCEDURE.md) Phase 2).

---

## Status

- [x] Confirmed original `192.168.29.50` vCenter unreachable (2026-07-01)
- [ ] Nested ESXi + VCSA deployed on Windows 10 / Workstation Pro
- [ ] `svc-mtv` service account recreated
- [ ] Connectivity from OCP cluster to nested vCenter confirmed
- [ ] MTV Provider created against nested vCenter
- [ ] Pilot Linux VM migration
- [ ] Pilot Windows VM migration

*Plan created: 2026-07-01, to be executed on the Windows 10 host, continuing next session.*
