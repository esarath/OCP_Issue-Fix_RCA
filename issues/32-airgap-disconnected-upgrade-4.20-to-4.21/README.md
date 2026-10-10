# Issue 32 — Air-Gapped (Disconnected) Upgrade 4.20.x → 4.21.y: Full Runbook

| Field | Detail |
|---|---|
| **Type** | Procedure / deployment-execution guide — disconnected (air-gapped) y-stream upgrade |
| **Status** | Documented — ready for execution; rehearse in lab before banking production use |
| **Scope** | OCP 4.20.x → 4.21.y, fully disconnected environment, internal mirror registry |
| **Audience** | Anyone running the change — written so each command says **what it does and why**, not just "run this" |
| **Builds on** | [checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md) (the *connected* version of this flow), [issue 14](../14-419-to-420-upgrade-execution/README.md) (live 4.19→4.20 internals), [issue 27](../27-etcd-backup-restore-crash-recovery/README.md) (etcd backup/restore detail), [issue 17](../17-skopeo-local-registry-cluster-trust/README.md) (local registry + cluster CA trust wiring — same pattern as the mirror registry here) |

## What this is

An end-to-end runbook for upgrading an **air-gapped** OpenShift cluster — one that cannot reach `quay.io`, `registry.redhat.io`, or `api.openshift.com` — from 4.20.x to 4.21.y. The connected equivalent is [checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md); this document covers only what changes when the internet doesn't exist in the equation, plus the full phase-by-phase execution.

**The one-paragraph mental model:** in a connected cluster, the Cluster Version Operator (CVO) asks Red Hat's Cincinnati service "what's next?" and pulls the payload from `quay.io`. Air-gapped, both of those are gone — so *you* become the distributor: pull the release image + operator catalogs on an internet-connected host with `oc-mirror`, carry the tarball into the airgap on approved media, push it into an internal mirror registry, install a local update-graph service + a release signature ConfigMap so the CVO trusts it, then point `oc adm upgrade` at the mirrored image. Everything else (the rollout itself, node drains, monitoring) is identical to a connected upgrade.

## Contents

| File | Purpose |
|---|---|
| [AIRGAP-UPGRADE-GUIDE.md](AIRGAP-UPGRADE-GUIDE.md) | **The runbook** — phased execution: pre-flight → backup → mirroring → cluster wiring → upgrade → validation → recovery. Every command annotated. |
| [manifests/imageset-ocp-4.21.yaml](manifests/imageset-ocp-4.21.yaml) | Concrete oc-mirror image set config for this exact upgrade — copy, fill in operators/versions, run |
| [scripts/install-oc-mirror.sh](scripts/install-oc-mirror.sh) | Download + install `oc` and `oc-mirror` correctly (they are **separate downloads** — see gotchas below) |
| [scripts/airgap-preflight-check.sh](scripts/airgap-preflight-check.sh) | Pre-flight gate: mirror registry reachable, CA trusted, IDMS/ITMS applied, release image pullable through the mirror — run before opening the change window |

## Critical gotchas (learned the hard way)

1. **`oc-mirror` is NOT inside `openshift-client-linux.tar.gz`.** That tarball only ships `oc` + `kubectl`. `oc-mirror` is its own file — `oc-mirror.tar.gz` in the same download directory. Running `tar xzf openshift-client-linux.tar.gz oc oc-mirror` fails with `tar: oc-mirror: Cannot find in archive`. Download it separately — see [scripts/install-oc-mirror.sh](scripts/install-oc-mirror.sh) and §Mirror Phase of the guide.
2. **No downgrade exists, in connected OR disconnected.** The only way back is the etcd restore in the guide's recovery section — take the snapshot *inside* the window right before `--to-image`.
3. **The release signature ConfigMap is not optional in airgap.** Connected clusters fetch signatures from Red Hat; disconnected clusters have nothing to fetch — apply the generated `signature-configmap-*.yaml` or the CVO rejects the payload with "no valid signature".
4. **`graph: true` in the image set config** is what produces the local OpenShift Update Service (OSUS) so `oc adm upgrade` can show update recommendations inside the airgap — without it you must always use `--to-image` explicitly.
5. **IDMS/ITMS changes roll `registries.conf` on every node** (sequential drain+reboot via MCO). Apply them early in the window — or in a prior window — never stacked on top of the upgrade rollout itself.

## Quick reference — the whole upgrade in 6 commands

```bash
# Connected host (internet)
oc-mirror --config imageset-ocp-4.21.yaml file:///data/ocp-mirror --v2

# Disconnected bastion (after media transfer)
oc-mirror --from /data/ocp-mirror/mirror_<seq>.tar docker://mirror.bank.local:8443 --v2
oc apply -f working-dir/cluster-resources/signature-configmap-*.yaml
oc apply -f working-dir/cluster-resources/cs-*.yaml

# Inside the change window, after etcd backup + preflight PASS
oc adm upgrade --to-image=mirror.bank.local:8443/openshift-release-dev/ocp-release@sha256:<digest>
```

## Official Red Hat references

- **Disconnected update procedure** — [Updating a cluster in a disconnected environment (OCP 4.21)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/disconnected_environments/updating-a-cluster-in-a-disconnected-environment)
- **oc-mirror v2** — [Mirroring images for a disconnected installation using oc-mirror plugin v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/disconnected_environments/installing-mirroring-disconnected)
- **Client downloads** — `https://mirror.openshift.com/pub/openshift-v4/clients/ocp/<version>/` (`openshift-client-linux.tar.gz` + `oc-mirror.tar.gz` are **separate files**)
- **mirror-registry (Quay)** — `https://mirror.openshift.com/pub/cgw/mirror-registry/latest/` and [Creating a mirror registry with mirror registry for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/disconnected_environments/mirroring-creating-mirror-registry)
- **etcd disaster recovery** — [Restoring to an earlier cluster state](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/backup_and_restore/control-plane-backup-and-restore#dr-restoring-cluster-state) (detail also in [issue 27](../27-etcd-backup-restore-crash-recovery/README.md))
- **Admin-ack gates** — [Preparing to update to OpenShift Container Platform 4.21](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/updating_clusters/preparing-to-update) (check the 4.21 release notes for any required `ack-4.20-*` keys before upgrading)
- **Errata/CVEs for the target release** — `https://access.redhat.com/errata` (search `OpenShift Container Platform 4.21`)
