# Issue 04 — `oc` Client/Server Version Skew After Cluster Upgrade

| Field | Detail |
|---|---|
| **Date** | 2026-07-01 |
| **Severity** | Low |
| **Status** | Resolved |
| **Affected** | Bastion host `oc`/`kubectl` CLI only — no cluster impact |
| **Root Cause** | Cluster was upgraded 4.15.59 → 4.16.55 ([Issue 02](../02-minor-version-upgrade-4.15-to-4.16/)) but the `oc`/`kubectl` binaries on the bastion were never updated to match |
| **Resolution Time** | ~5 minutes |

---

## Symptom

Noticed while checking cluster state during unrelated troubleshooting:

```bash
oc version
# Client Version: 4.15.59
# Server Version: 4.16.55
```

No functional breakage — client/server skew of one minor version is within the
Kubernetes-supported range — but it's drift from the intended post-upgrade state
and worth closing before it grows into a larger gap.

---

## Quick Fix

```bash
# 1. Confirm the skew and target version
oc version

# 2. Download the matching client from the official mirror and verify checksum
curl -sL -o openshift-client-linux.tar.gz \
  "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/<SERVER_VERSION>/openshift-client-linux-<SERVER_VERSION>.tar.gz"
curl -sL -o sha256sum.txt \
  "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/<SERVER_VERSION>/sha256sum.txt"
sha256sum openshift-client-linux.tar.gz
grep openshift-client-linux-<SERVER_VERSION>.tar.gz sha256sum.txt
# Confirm the two hashes match before proceeding

# 3. Extract and sanity-check before installing
tar xzf openshift-client-linux.tar.gz oc kubectl
./oc version --client

# 4. Back up the old binaries, then install (requires sudo — /usr/local/bin is root-owned)
sudo cp /usr/local/bin/oc /usr/local/bin/oc.<OLD_VERSION>.bak
sudo cp /usr/local/bin/kubectl /usr/local/bin/kubectl.bak
sudo install -m 0755 -o root -g root ./oc /usr/local/bin/oc
sudo install -m 0755 -o root -g root ./kubectl /usr/local/bin/kubectl

# 5. Verify
oc version
oc get nodes
oc get clusteroperator | head -3

# 6. Once confirmed working, remove the backups
sudo rm -f /usr/local/bin/oc.<OLD_VERSION>.bak /usr/local/bin/kubectl.bak
```

Resolved on 2026-07-01: client and server both `4.16.55`, cluster confirmed healthy
(all 5 nodes `Ready`, `authentication`/`baremetal`/etc. operators `AVAILABLE=True`)
after the swap.

---

## Root Cause (Summary)

[Issue 02](../02-minor-version-upgrade-4.15-to-4.16/) upgraded the cluster itself
from 4.15.59 to 4.16.55, but the upgrade runbook only covers the in-cluster upgrade
path (control plane, operators, nodes) — it doesn't include a step to refresh the
`oc`/`kubectl` binaries on the bastion host that operators actually run commands
from. Those are a separate, manually-managed install at `/usr/local/bin/oc`
(installed 2025-10-22, predates this repo), so they silently drifted out of sync
with the cluster the moment the upgrade completed.

---

## Prevention

- **Add a step to the upgrade runbook**: after any cluster upgrade, refresh the
  bastion's `oc`/`kubectl` to match the new server version as part of
  [Issue 02](../02-minor-version-upgrade-4.15-to-4.16/)'s post-upgrade validation,
  not as an afterthought discovered later.
- Always verify a downloaded client's `sha256sum` against the mirror's published
  `sha256sum.txt` before installing — don't skip this because it's "just a CLI tool."
- Keep exactly one dated backup of the previous binary until the new one is
  confirmed working against the live cluster (`oc get nodes` / `oc get clusteroperator`),
  then remove it — don't accumulate stale `.bak` files on `/usr/local/bin`.
- Client/server skew of ±1 minor version is functionally supported by Kubernetes
  and not an emergency — this is a low-severity hygiene fix, not something to
  block other work for.

---

## Files

This issue was small enough that the fix commands above are the full record —
no separate RCA.md or script needed.
