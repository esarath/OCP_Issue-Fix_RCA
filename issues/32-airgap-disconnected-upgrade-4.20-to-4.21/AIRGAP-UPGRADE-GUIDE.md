# Air-Gapped Upgrade Runbook — OCP 4.20.x → 4.21.y

> **What this document is, in plain terms:** your cluster lives on a private
> network with no route to the internet. OpenShift still needs its upgrade
> bits — container images, the update "map" that says which version can
> follow which, and cryptographic signatures that prove the bits are Red
> Hat's. Since the cluster can't fetch any of that, *you* fetch it on a
> connected machine, carry it in on removable media, load it into a registry
> inside the airgap, and tell the cluster "your update source is over there
> now." This is the complete playbook for doing that for a 4.20 → 4.21
> minor upgrade on a banking-critical production cluster.

**Reading this doc:** angle-bracket tokens — `<mirror.bank.local>`, `<digest>`,
`<domain>` — are placeholders; replace the whole token. Every command is
followed by what it does and why. Sections in **bold ALL-CAPS gates** must
pass before continuing — treat them like pre-flight checklists, not
suggestions.

**Environment used throughout (replace with yours):**

| Item | Value in examples |
|---|---|
| Current version | `4.20.35` |
| Target version | `4.21.<z>` (pick the latest z-stream on your channel date) |
| Mirror registry | `mirror.bank.local:8443` |
| Connected staging host | internet-reachable VM with `oc`, `oc-mirror`, podman |
| Airgap bastion | inside the disconnected network; can reach the mirror registry + cluster API |
| Control plane | 3 masters · Workers: 2 |
| Expected duration | mirror ~1–2h (network-dependent) + upgrade ~1.5–3h + buffer → book a **6–8h window** |

---

## Phase 0 — Governance (T-14 days → T-1 day)

The paperwork layer. Banking production means none of this is optional:

- [ ] **Change record (CRQ)** approved by CAB; window booked off-peak; no
      conflict with financial-close / regulatory-reporting freeze periods.
- [ ] **Release notes reviewed** — every intermediate z-stream between
      4.20.35 and your target 4.21.<z>, plus the 4.21 minor notes:
      removed APIs, new admin-ack gates, deprecated features.
      Links: `https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/release_notes/`
      and `https://access.redhat.com/errata` (search `OpenShift Container Platform 4.21`).
- [ ] **App owner sign-offs** — payments, channels, core-banking
      connectors, batch jobs. Someone from each team confirms their smoke
      test and their contact number for the window.
- [ ] **Vendor/agent compatibility** — EDR/AV agents, monitoring agents
      (Dynatrace/AppD/NR), backup agents, service mesh: confirm each
      vendor certifies OCP 4.21.
- [ ] **Rollback authority declared** — name the human who can call
      "abort" and invoke the etcd restore; document the criteria now, not
      mid-incident.
- [ ] **NOC bridge** open for the whole window; comms templates ready.
- [ ] **Restore rehearsal in lab ≤90 days old** — Phase 8 of this doc
      executed end-to-end on a non-prod cluster. A written-down restore
      that has never been run is a hypothesis, not a plan.

---

## Phase 1 — Pre-flight validation (T-3d, and again inside the window)

Every check must pass. A `FAIL` anywhere stops the change.

### 1.1 Baseline health gate

```bash
oc get clusterversion
```
→ Expect `VERSION 4.20.x`, `AVAILABLE=True`, `PROGRESSING=False`.
Confirms the cluster isn't mid-change and isn't carrying a failed prior
update.

```bash
oc get co | awk '$3!="True" || $4!="False" || $5!="False"'
```
→ Must return **empty**. `oc get co` lists ClusterOperators; awk filters
to any that aren't `Available=True / Progressing=False / Degraded=False`.
A degraded operator = fix it first, or the upgrade wedges on it.

```bash
oc get nodes; oc get mcp
```
→ All nodes `Ready`. Both MachineConfigPools `UPDATED=True,
UPDATING=False, DEGRADED=False`. An MCP already mid-roll means a config
change is in flight — never stack an upgrade on it.

```bash
oc get pods -A | grep -vE 'Running|Completed'
```
→ Lists anything not healthy. Expected output: just the header row.

```bash
oc get etcd cluster -o jsonpath='{.status.conditions}' | python3 -m json.tool | grep -B1 '"status": "True"' | grep -i degraded
```
→ Checks every etcd-operator `*Degraded` condition; expected output:
nothing.

### 1.2 Minor-upgrade-specific gates (these don't exist for z-streams)

```bash
# APIs in use that may be REMOVED in the target Kubernetes minor
oc get apirequestcounts -o jsonpath='{range .items[*]}{.metadata.name}{" requests="}{.status.requestCount}{"\n"}{end}' | sort
```
→ `apirequestcounts` tracks which API groups/versions the cluster has
served recently. Cross-check nonzero entries against the "Removed APIs"
list in the 4.21 release notes. Anything still calling a removed API
breaks *after* the upgrade — remediate the workload now.

```bash
# Admin-ack gates — the CVO can refuse a minor upgrade until a human
# acknowledges documented removals
oc get cm admin-acks -n openshift-config -o yaml 2>/dev/null
oc describe clusterversion | grep -iA3 upgradeable
```
→ If the 4.21 release notes declare a gate (name pattern
`ack-4.20-<something>-in-4.21`), and you've verified nothing uses the
removed API, acknowledge it:

```bash
oc -n openshift-config patch cm admin-acks --type=merge \
  -p '{"data":{"<gate-name-from-4.21-release-notes>":"true"}}'
```
→ This writes the acknowledgment the CVO checks for. It's also an audit
artifact — recorded proof a human reviewed the removals. Reference:
[Preparing to update to OCP 4.21](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/updating_clusters/preparing-to-update).

### 1.3 Capacity & drainability

```bash
oc describe nodes | grep -A6 'Allocated resources'
```
→ With only 2 workers, ALL worker workloads must fit on ONE worker while
its peer drains. Verify headroom; banking standard is N+2 workers — flag
to infra if you're at the margin.

```bash
oc get pdb -A | awk 'NR>1 && $5==0'
```
→ Lists PodDisruptionBudgets with `disruptionsAllowed=0` — these *block
node drains*, which blocks the upgrade mid-flight. Coordinate with app
owners to scale up replicas or relax the PDB for the window.

### 1.4 Airgap-specific prerequisites

```bash
# Mirror registry reachable from the cluster + healthy
curl -sk https://mirror.bank.local:8443/v2/_catalog | head
oc get imagedigestmirrorset,imagetagmirrorset
oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA}'
```
→ Confirms: (a) registry answers, (b) mirror mappings exist and point at
it, (c) its CA is already in the cluster's trust bundle. If (c) is empty
the nodes can't pull from it — set that up in a *prior* window because it
rolls all nodes (see Phase 4b).

Or just run the bundled gate script:

```bash
bash scripts/airgap-preflight-check.sh mirror.bank.local:8443
```

---

## Phase 2 — Backup (inside the window, immediately before the upgrade)

### 2.1 etcd snapshot — your only real rollback

```bash
oc debug node/master-1.<domain>
# inside the debug shell:
chroot /host /usr/local/bin/cluster-backup.sh /home/core/backup
exit
```
→ `oc debug node` drops a privileged shell on the master;
`cluster-backup.sh` ships with RHCOS and produces two files in
`/home/core/backup`:
- `snapshot_<ts>.db` — the etcd data snapshot
- `static_kuberesources_<ts>.tar.gz` — the static-pod manifests **at
  4.20.x** — this is what lets a restore resurrect the *old version's*
  control plane, not just the old data

**Both files must come from the same backup run** — the restore script
validates that and refuses otherwise.

```bash
# Exfiltrate OFF the cluster to approved vault/NFS storage:
ssh core@master-1.<domain> 'sudo tar czf - /home/core/backup' \
  > etcd-backup-pre-4.21-$(date +%F).tar.gz
sha256sum etcd-backup-pre-4.21-*.tar.gz   # record in the CRQ
```
→ A backup sitting on the master you're about to re-image is not a
backup. Off-box, checksummed, evidenced.

### 2.2 Cluster state capture (for post-upgrade diff + audit)

```bash
mkdir -p pre-upgrade-state && cd pre-upgrade-state
oc get co -o yaml > co.yaml
oc get mcp -o yaml > mcp.yaml
oc get nodes -o yaml > nodes.yaml
oc get csv -A -o yaml > csvs.yaml
oc get clusterversion version -o yaml > cv.yaml
```

### 2.3 Application backups

→ Confirm OADP/Velero (or your backup product) backups for stateful apps
completed <24h ago and have been restore-tested. See
[issue 30](../30-app-db-backup-dr-planning/README.md) for the full
app/DB backup pattern.

### 2.4 Silence alerts for the window

→ Alertmanager silence covering window duration + 30m buffer, via
console (Observe → Silences → Create) or the API. Expected drain/reboot
noise should not page anyone; dashboards stay live for the bridge.

---

## Phase 3 — Mirror the 4.21 payload (connected → transfer → disconnected)

### 3.1 Install `oc` + `oc-mirror` on the connected host

```bash
bash scripts/install-oc-mirror.sh 4.21.<z>
# or manually:
mkdir -p /tmp/ocp-tools && cd /tmp/ocp-tools

# 1) the oc CLI — its own tarball
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.21.<z>/openshift-client-linux.tar.gz
tar xzf openshift-client-linux.tar.gz oc kubectl

# 2) oc-mirror — a SEPARATE tarball, NOT inside the client archive
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.21.<z>/oc-mirror.tar.gz
tar xzf oc-mirror.tar.gz

sudo install oc kubectl oc-mirror /usr/local/bin/
oc version --client && oc-mirror version
```

**Why this trips people up:** `tar xzf openshift-client-linux.tar.gz oc
oc-mirror` fails with `tar: oc-mirror: Cannot find in archive` because
the client tarball only contains `oc` + `kubectl`. `oc-mirror` is
distributed as its own plugin archive — see Troubleshooting T1.

```bash
# Authenticate to Red Hat registries (needs a pull secret from
# console.redhat.com → OpenShift → Downloads → Pull secret)
oc registry login --registry registry.redhat.io --auth-basic <user>:<pass> --to ~/pull-secret.json
oc registry login --registry registry.connect.redhat.com --auth-basic <user>:<pass> --to ~/pull-secret.json
```
→ `oc registry login` merges registry creds into your auth file the same
way `podman login` does. Without these, image pulls from Red Hat
registries get `unauthorized` errors mid-mirror.

### 3.2 Write the image set config

Use [manifests/imageset-ocp-4.21.yaml](manifests/imageset-ocp-4.21.yaml)
as your starting point — reproduced here with annotations:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: fast-4.21          # there is no eus-4.21 — EUS exists only on even minors
      minVersion: 4.21.<z>
      maxVersion: 4.21.<z>
      shortestPath: true       # only the images for this exact update path
    graph: true                # builds the local update-graph image (OSUS)
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21
    packages:
    - name: metallb-operator
    - name: openshift-gitops-operator
    - name: zero-trust-workload-identity-manager   # <- enumerate YOUR prod list
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.20   # keep old index
    packages:
    - name: metallb-operator                               # so operator rollback stays possible
    - name: openshift-gitops-operator
    - name: zero-trust-workload-identity-manager
  additionalImages: []          # bank-internal images your workloads pull
```

Field notes:
- `platform.channels` — which release channel's images to mirror. Pin
  `minVersion == maxVersion` to mirror exactly one release. To mirror a
  z-stream range instead, set them apart.
- `graph: true` — makes oc-mirror also build the OpenShift Update Service
  graph image so `oc adm upgrade` can show recommendations *inside* the
  airgap. Without it, you're committed to explicit `--to-image` forever.
- `operators` — enumerate the real prod list, don't guess:
  `oc get packagemanifests` or `oc get csv -A` on the prod cluster.
- Keeping the **v4.20 catalog** mirrored means an operator rollback
  (reinstall a prior CSV) still has a source post-upgrade.

### 3.3 Mirror to disk, transfer, disk-to-mirror

```bash
# CONNECTED host — pull everything into a portable archive
oc-mirror --config imageset-ocp-4.21.yaml file:///data/ocp-mirror --v2
```
→ `--v2` selects the current plugin (v1 is deprecated). `file://` =
mirror-to-disk mode. Output: `/data/ocp-mirror/mirror_<seq>.tar`
(typically ~8–15 GB for one release + a few operators).

```bash
# --- transfer to the airgap on approved media (your bank's import process) ---

# DISCONNECTED bastion — push the archive into the mirror registry
oc-mirror --from /data/ocp-mirror/mirror_<seq>.tar docker://mirror.bank.local:8443 --v2
```
→ `--from` + `docker://` = disk-to-mirror mode. On success, oc-mirror
writes the cluster-side manifests into `working-dir/cluster-resources/`:

| Generated file | What it's for |
|---|---|
| `idms-*.yaml` / `itms-*.yaml` | ImageDigestMirrorSet / ImageTagMirrorSet — tells every node "when something asks for quay.io/…, pull it from mirror.bank.local instead" |
| `signature-configmap-*.yaml` | The release image's cryptographic signature — the CVO's trust anchor when it can't reach Red Hat |
| `cs-*.yaml` | CatalogSource pointing OLM at your mirrored operator index |
| `updateService*.yaml` | (when `graph: true`) manifests to deploy the local OSUS |

### 3.4 Verify the payload landed

```bash
oc image info mirror.bank.local:8443/openshift-release-dev/ocp-release:4.21.<z>-x86_64 \
  --registry-config=~/mirror-pull-secret.json --filter-by-os=linux/amd64 -o json | jq -r .digest
```
→ `oc image info` inspects a registry image without pulling layers.
Confirms the release image actually exists on your mirror and gives you
the `sha256:` digest to use at Phase 5 — **always upgrade by digest, not
tag**: a tag can move; a digest cannot. Record it in the CRQ.

---

## Phase 4 — Point the cluster at the new image set (inside the window)

```bash
# a) Release signature ConfigMap — REQUIRED, do this first
oc apply -f working-dir/cluster-resources/signature-configmap-*.yaml
```
→ The CVO cryptographically verifies release payloads against signature
data. Connected clusters can fetch signatures; airgapped ones can't — so
oc-mirror packages them as a ConfigMap. Skip this and Phase 5 fails with
`no valid signature for the desired image`.

```bash
# b) Registry redirects — only if the generated IDMS/ITMS differs from live
diff <(oc get imagedigestmirrorset -o yaml) working-dir/cluster-resources/idms-*.yaml || \
  oc apply -f working-dir/cluster-resources/idms-*.yaml
```
→ ⚠ **IDMS/ITMS changes rewrite `registries.conf` on every node**, and
the Machine Config Operator rolls that out as a drain+reboot of every
node sequentially. If this apply triggers an MCP rollout, **wait for all
pools `UPDATED=True` before continuing** — do not begin the upgrade while
nodes are mid-reboot. If your existing IDMS already maps quay.io → your
mirror and oc-mirror's generated set is identical, this is a no-op — the
`diff` check exists exactly to skip an unnecessary rollout.

```bash
# c) Mirrored catalog — swaps OLM's operator source to the mirrored index
oc apply -f working-dir/cluster-resources/cs-*.yaml
```
→ After this, `oc get packagemanifests` serves operator content from your
registry, enabling operator updates post-upgrade.

```bash
# d) OPTIONAL — local update service (only if you used graph: true)
oc apply -f working-dir/cluster-resources/updateService*.yaml
# then point the CVO at it (URL per the generated manifest):
oc patch clusterversion/version --type merge \
  -p '{"spec":{"upstream":"<osus-service-or-route-url>"}}'
```
→ With OSUS deployed, `oc adm upgrade` behaves like a connected cluster —
it can list recommended versions and edges inside the airgap. Without it,
explicit `--to-image` (Phase 5) is the supported path and works fine.

```bash
# e) End-to-end pull test through the mirror on a real node
oc debug node/worker-1.<domain> -- chroot /host \
  podman pull mirror.bank.local:8443/openshift-release-dev/ocp-release@sha256:<digest>
```
→ Proves the whole chain — node → DNS → registry → TLS/CA trust → auth —
works before you're 45 minutes into a change window. Do not skip this.

**GATE:** all of Phase 4 done, MCPs quiet, `oc get co` still clean.

---

## Phase 5 — Execute the upgrade

```bash
oc adm upgrade --to-image=mirror.bank.local:8443/openshift-release-dev/ocp-release@sha256:<digest>
```
→ Writes `spec.desiredUpdate` on the ClusterVersion with the exact image
digest you verified. Deterministic and auditable — the digest in the CRQ
is the digest the cluster runs. (If you deployed OSUS in Phase 4d,
`oc adm upgrade --to=4.21.<z>` works too.)

Expect ~45–60s of lag before `oc adm upgrade` shows progress — the CVO
reconciles on an interval, not synchronously (same observation as
[issue 14](../14-419-to-420-upgrade-execution/README.md)).

### Monitor the rollout

```bash
watch oc adm upgrade                      # % complete + what it's waiting on
watch 'oc get co | grep -vw "4.21'       # operators flipping to the new version
watch oc get mcp                          # UPDATING=True => node drain/reboot phase
watch oc get nodes                        # SchedulingDisabled => node draining
```

Same internal sequence as a connected upgrade (full mechanics in
[issue 14](../14-419-to-420-upgrade-execution/README.md) and
[checklists/minor-version-upgrade-procedure.md](../../checklists/minor-version-upgrade-procedure.md)):
CVO self-updates → control-plane operators → master pool → worker pool →
remaining operators. Expect **every node to reboot** on a minor upgrade.

### In-window checkpoints

| Stage | Pass condition |
|---|---|
| ~25% through task graph | No `Failing=True`, no repeating `UnableToApply` |
| Masters rolled | All 3 `Ready`, `oc get etcd cluster` shows quorum |
| First worker rolled | Node `Ready`, workloads rescheduled, app smoke green |
| Complete | `oc get clusterversion` → `4.21.<z>`, `PROGRESSING=False` |

**Abort criteria — any one means stop and go to Phase 8:**
- `Failing=True` or `UnableToApply` persisting >20 min with no forward progress
- Any ClusterOperator `Degraded=True` >15 min
- A node failing to return `Ready` >30 min after reboot
- etcd health alarms or quorum loss
- Critical-path smoke test failure mid-window

---

## Phase 6 — Post-upgrade validation

```bash
oc get clusterversion                                 # 4.21.z, Available=True, Progressing=False
oc get co                                             # every operator at 4.21.z, healthy
oc get mcp                                            # all pools updated, machines ready
oc get nodes -o wide                                  # OS-IMAGE column shows new RHCOS
oc get pods -A | grep -vE 'Running|Completed'         # header only
```

```bash
# Operator estate — swing catalogs to the v4.21 index, let OLM roll CSVs
oc get catalogsource -n openshift-marketplace
oc patch catalogsource redhat-operators -n openshift-marketplace --type=merge \
  -p '{"spec":{"image":"mirror.bank.local:8443/redhat/redhat-operator-index:v4.21"}}'
oc get installplans -A      # approve Manual InstallPlans; Automatic ones roll alone
oc get csv -A | grep -v Succeeded   # everything converges on Succeeded
```

```bash
# Functional smoke — critical path first
# - console + SSO/LDAP login        - registry pull/push
# - routes/ingress (MetalLB VIPs)   - synthetic transaction per critical app
# - alerting firing/delivering      - cronjobs resumed
```

```bash
# Hygiene + evidence
oc delete pods -A --field-selector=status.phase==Succeeded   # installer/pruner debris
oc get co -o yaml > post-upgrade-state/co.yaml               # diff vs pre-upgrade-state/
```
→ Attach to the CRQ: timeline, ClusterVersion history, etcd backup
checksum, smoke results. Remove alert silences; hypercare 24–72h.

---

## Phase 7 — Decision matrix when something goes wrong

| Failure signature | First move |
|---|---|
| One operator stuck/crash-looping | **Fix-forward** — troubleshoot that operator; the CVO retries its gate continuously, upgrade resumes on its own |
| `UnableToApply` on a specific manifest | Read the CVO event (`oc describe clusterversion`) for the object name — usually a manually-edited/tainted resource; correct it, CVO retries |
| Node stuck `NotReady` post-reboot | SSH/console to the node: `systemctl status kubelet`, `crictl ps`, journal. One node can be re-imaged/replaced — not an etcd-restore problem |
| `no valid signature` on the desired image | Phase 4a was skipped — apply the signature ConfigMap and the CVO proceeds |
| `ImagePullBackOff` on new-version pods | Mirror missing a tag or bad IDMS mapping — `oc get imagedigestmirrorset`, `oc image info` the tag on the mirror |
| Upgrade *succeeded* but regression found after | Fix-forward. Post-facto etcd restore is a last resort and loses everything since the snapshot |
| etcd corrupted / control plane unrecoverable / mandate to revert to 4.20 | **Phase 8** |

---

## Phase 8 — Emergency restore to pre-upgrade state (last resort)

Restores etcd to the Phase-2 snapshot → the cluster comes back at the
**4.20.x state captured at backup time**. API is down ~30–60+ min during
this. Detail beyond this summary lives in
[issue 27](../27-etcd-backup-restore-crash-recovery/README.md) and the
official
[Restoring to an earlier cluster state](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/backup_and_restore/control-plane-backup-and-restore#dr-restoring-cluster-state)
doc — **follow the 4.21 doc verbatim at execution time**.

```bash
# 0. Establish SSH to ALL THREE masters BEFORE starting — the API will be
#    unreachable once you begin. Verify: ssh core@master-1/2/3.<domain>
# 1. Stage the backup on the recovery master (master-1)
scp etcd-backup-pre-4.21-*.tar.gz core@master-1.<domain>:/home/core/
ssh core@master-1.<domain>
sudo tar xzf etcd-backup-pre-4.21-*.tar.gz -C /home/core/
ls /home/core/backup    # MUST contain snapshot_*.db AND static_kuberesources_*.tar.gz
```

```bash
# 2. On the recovery host — move static-pod manifests out of kubelet's
#    watch dir so nothing fights the restore, then stop kubelet
sudo mv /etc/kubernetes/manifests/etcd-pod.yaml /tmp
sudo mv /etc/kubernetes/manifests/kube-apiserver-pod.yaml /tmp
sudo mv /etc/kubernetes/manifests/kube-controller-manager-pod.yaml /tmp
sudo mv /etc/kubernetes/manifests/kube-scheduler-pod.yaml /tmp
sudo systemctl stop kubelet.service

# 3. Run the restore — the script: moves the live etcd data-dir aside to
#    /var/lib/etcd-backup, extracts static-pod-resources from the tar,
#    and restores the snapshot into a fresh single-member etcd
sudo -E /usr/local/bin/cluster-restore.sh /home/core/backup

# 4. Restart kubelet — restored etcd + control-plane static pods come up
sudo systemctl start kubelet.service
sudo crictl ps | grep etcd        # wait for the etcd container
```

```bash
# 5. From the bastion — API returns as kube-apiserver static pod starts
oc get nodes                      # give it several minutes

# 6. Force the etcd operator to redeploy/scale remaining members in
oc patch etcd cluster --type=merge \
  -p='{"spec":{"forceRedeploymentReason":"recovery-'"$(date --rfc-3339=ns)"'"}}'

# 7. On EACH remaining master — wipe stale member data so it rejoins the
#    restored cluster cleanly (repeat on master-3)
ssh core@master-2.<domain>
sudo systemctl stop kubelet.service
sudo mv /var/lib/etcd/member /var/lib/etcd-backup-member 2>/dev/null || sudo rm -rf /var/lib/etcd/member
sudo systemctl start kubelet.service
```

```bash
# 8. Verify
oc adm wait-for-stable-cluster
oc get etcd cluster
oc get co | awk '$3!="True"'
```

Nodes may still run the newer RHCOS image afterward — a tolerated,
temporary version skew that operators reconcile as they settle.

**Other rollback paths (not etcd):**
- *Operator regression* → delete the new CSV + approve the prior
  InstallPlan (the v4.20 catalog you kept mirrored in Phase 3.2 is the
  source for it)
- *App data corruption* → restore PVs via OADP/Velero or storage
  snapshots — orthogonal to the OCP version

---

## Troubleshooting — oc-mirror & airgap-specific

| # | Symptom | Cause | Fix |
|---|---|---|---|
| T1 | `tar: oc-mirror: Cannot find in archive` | `oc-mirror` isn't inside `openshift-client-linux.tar.gz` | Download `oc-mirror.tar.gz` separately from the same `clients/ocp/<ver>/` dir — see `scripts/install-oc-mirror.sh` |
| T2 | `unauthorized: access to the requested resource is not authorized` during mirror | Missing/stale Red Hat registry creds | `oc registry login --registry registry.redhat.io ...` (and `registry.connect.redhat.com`) with a valid pull secret |
| T3 | `x509: certificate signed by unknown authority` pushing to mirror | Mirror registry CA not trusted by the *bastion* (this is a host-side error, not the cluster) | `cp mirror-ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust` on the bastion, or `--dest-skip-tls` (lab only) |
| T4 | `no valid signature for the desired image` at upgrade time | Signature ConfigMap not applied | `oc apply -f working-dir/cluster-resources/signature-configmap-*.yaml` |
| T5 | `The cluster version is up to date` / no recommendations shown | No OSUS (no `graph: true`) or CVO still pointing at public Cincinnati | Use `--to-image=<digest>` explicitly, or deploy the updateService manifests + repoint `spec.upstream` |
| T6 | `ImagePullBackOff` referencing `quay.io/...` during rollout | IDMS/ITMS not applied or mapping mismatch | `oc get imagedigestmirrorset -o yaml`, diff against generated manifests, re-apply |
| T7 | `oc-mirror` hangs mid-push | Registry out of disk, or blob size limits (some registries/Nginx proxies cap body size) | Check registry disk; raise proxy `client_max_body_size`; retry — oc-mirror resumes |
| T8 | `command not found: oc-mirror` after installing | Wrong tarball extracted, or not in PATH | `which oc-mirror`; re-run install script; it lives as a standalone binary, not an `oc` subcommand alias — invoke as `oc-mirror`, not `oc mirror` |

---

## Appendix — Window timeline template

| Time | Step |
|---|---|
| T-0 | Phase 1 health gate re-run inside window; alert silence on |
| T+15m | Phase 2 etcd backup taken, exfiltrated, checksum recorded |
| T+30m | Phase 4 cluster wiring (signature CM → IDMS diff → catalog → pull test) |
| T+45m | Phase 5 `--to-image` issued |
| T+45m → T+3h | Monitor; stage checkpoints per Phase 5 table |
| T+3h | Phase 6 validation + smoke |
| T+4h | App-owner sign-off; buffer for issues |
| T+5h | Unsilence alerts; evidence to CRQ; window close |
