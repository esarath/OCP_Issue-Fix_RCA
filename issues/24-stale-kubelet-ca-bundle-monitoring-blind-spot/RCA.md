# RCA — Node Metrics Lost on worker-1 (and At Risk on All Nodes): Stale Kubelet CA Bundle While Cluster Monitoring Operator Is Unmanaged

| Field | Detail |
|---|---|
| **Document status** | **DRAFT — PENDING CUSTOMER APPROVAL. No remediation has been performed.** |
| **Cluster** | lab.ocp.local — OpenShift 4.20.35, 3 control-plane + 2 worker nodes (dev/test) |
| **Detected** | 2026-09-21 ~10:20 UTC, during an upgrade-readiness health check |
| **Impact started** | 2026-09-21 ~09:12 UTC (worker-1); worker-2 partially (see §4) |
| **Severity** | Low today (observability only, no workload impact). Rises to Medium on 2026-09-25, and it blocks the planned 4.20.38 patch |
| **Category** | Configuration drift caused by an unsupported/temporary change (monitoring replica pin, Issue 22) |
| **Related** | Issue 22 (monitoring replica scaling); OCP 4.20.35 → 4.20.38 patch preparation |

---

## 1. Executive Summary

`oc adm top nodes` returns `<unknown>` for worker-1, and Prometheus cannot scrape worker-1's kubelet (all three endpoints down) or worker-2's `/metrics` endpoint. Two `TargetDown` alerts are firing.

**The nodes are healthy.** The failure is that the monitoring stack no longer trusts the certificates the kubelets present. The list of trusted certificate authorities that monitoring uses is a copy that the Cluster Monitoring Operator (CMO) keeps up to date. On 2026-09-17, CMO was deliberately stopped (and locked in the stopped state via a ClusterVersion override) to keep a memory-saving change in place. With CMO stopped, that copy stopped updating. On 2026-09-20 the cluster's certificate signer rotated on its normal schedule. Certificates issued by the new signer are not in the frozen copy, so monitoring rejects them.

There is **no impact on running applications, the control plane, or cluster availability**. The impact is a monitoring blind spot on the affected nodes, and it will spread: master-2's kubelet certificate expires on **2026-09-25**, and every kubelet certificate renewed from now on will come from the new signer.

**Recommended fix (§7, Option A):** end the temporary change (re-enable CMO and clear the override). That restores the automatic sync, and it is also a hard prerequisite for the planned 4.20.38 patch, because the cluster reports `Upgradeable=False` while the override exists. Expected impact of the fix: no workload downtime, a brief monitoring gap (~2–5 minutes), and about 1.4 GiB of memory requests returned to the workers.

---

## 2. Impact Assessment

| Area | Impact |
|---|---|
| Application workloads / ingress / API / etcd | **None** — verified: all 5 nodes Ready, 34/34 ClusterOperators healthy, etcd 3/3, no non-running pods |
| `oc adm top nodes` / metrics API | worker-1 shows `<unknown>` (metrics-server: 283 scrape failures in the retained log) |
| Prometheus kubelet metrics | worker-1: `/metrics`, `/metrics/cadvisor`, `/metrics/probes` all down. worker-2: `/metrics` down |
| Console dashboards / alerting on those metrics | No container CPU/memory or kubelet data for worker-1; alert rules that depend on it cannot fire |
| Alert delivery | `TargetDown` (kubelet, crio) is firing at *warning* severity. Per the configured routing only *Critical* alerts are sent to Slack, so nobody was notified |
| Upgrade | Separate but related: the same root cause (CMO unmanaged) makes `Upgradeable=False` |
| Data loss | None. Samples for the affected windows are simply missing |

---

## 3. Timeline (UTC)

| When | Event | Evidence |
|---|---|---|
| 2026-08-26 14:10 | Certificate signer `kube-csr-signer_@1787753455` created | CA bundle |
| 2026-09-05 08:30 | Signer `@1788597007` created. **CMO performs its last sync of the monitoring CA copy (4 certs)** | ConfigMap `managedFields` timestamp 08:30:16 |
| 2026-09-17 | CMO scaled to 0 and a `ClusterVersion.spec.overrides` entry set to `unmanaged: true`, to keep 5 monitoring components at 1 replica (memory relief; Issue 22) | ClusterVersion spec; `Upgradeable=False` / `ClusterVersionOverridesSet` |
| 2026-09-20 08:30:34 | Scheduled signer rotation: new signer `@1789893034` (rotation period 360 h). The source CA ConfigMap now has 5 certs; the monitoring copy stays at 4 | `csr-signer` secret annotations; ConfigMaps |
| 2026-09-20 11:57:34 | worker-1's kubelet receives a new serving certificate from the new signer | Live certificate `notBefore` |
| 2026-09-21 ~09:07–09:10 | Whole-cluster restart (all nodes up ~1 h at 10:15). worker-2 receives its new certificate (`notBefore` 09:07:01) | Node uptime; live certificate |
| 2026-09-21 09:11:55 | `TargetDown` (kubelet, crio) becomes active; worker-2 `/metrics` first scraped as down at 09:12:24 | Prometheus alerts; `up` history |
| 2026-09-21 ~10:20 | Detected in health check: `oc adm top nodes` → worker-1 `<unknown>` | Operator terminal output |

**Why it surfaced only on 09-21 even though worker-1's certificate changed on 09-20:** Prometheus' `up` history shows worker-1 was scraped successfully until the restart. The most likely explanation is that monitoring components were still using TLS connections opened *before* the certificate changed, and only re-verified the certificate when the restart forced new connections. This is consistent with worker-2, where `/metrics` failed but `/metrics/cadvisor` still succeeds (separate connection pools). It is an inference from that pattern; it was not proven by packet capture. The fault was therefore latent from 09-20 and triggered by the restart.

---

## 4. Root Cause Analysis

### 4.1 Direct cause
Monitoring components validate kubelet serving certificates against the bundle in `openshift-monitoring/kubelet-serving-ca-bundle`. That bundle is missing the current signer `CN=kube-csr-signer_@1789893034`, so certificates issued by it fail verification:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```
(seen in both `metrics-server` logs and Prometheus target `lastError`)

### 4.2 Root cause
`kubelet-serving-ca-bundle` is owned and synchronised **only by the Cluster Monitoring Operator**, from `openshift-config-managed/kubelet-serving-ca`. CMO has been deliberately switched off since 2026-09-17, so nothing has updated the copy since 2026-09-05.

### 4.3 Why CMO is off
Replica counts of 5 monitoring components (`prometheus-k8s`, `alertmanager-main`, `thanos-querier`, `metrics-server`, `monitoring-plugin`) are hardcoded in CMO and are not exposed in `cluster-monitoring-config`. CMO reverts any direct edit within seconds. To make a reduction to 1 replica stick, CMO had to be stopped, and because the CVO restores CMO on its own, a `ClusterVersion.spec.overrides` entry was also required. Stopping the operator that owns the CA sync was an unrecognised side effect of that change.

### 4.4 Trigger
The scheduled rotation of `kube-csr-signer` on 2026-09-20 (rotation period 15 days; observed signers created 08-26, 09-05, 09-20). This is normal cluster behaviour; the frozen bundle simply could not follow it.

### 4.5 Why only some nodes are affected today
Evidence: certificate issuer of each node's live kubelet serving certificate versus the signers in the frozen bundle.

| Node | Cert issued by signer | Issued (UTC) | Expires (UTC) | In frozen bundle? | Monitoring |
|---|---|---|---|---|---|
| master-1 | `@1788597007` | 09-17 15:08 | 10-05 08:30 | Yes | OK |
| master-2 | `@1787753455` | 08-26 16:28 | **09-25 14:10** | Yes | OK — **until 09-25** |
| master-3 | `@1788597007` | 09-19 13:45 | 10-05 08:30 | Yes | OK |
| worker-1 | `@1789893034` | 09-20 11:57 | 10-20 08:30 | **No** | **Failing** |
| worker-2 | `@1789893034` | 09-21 09:07 | 10-20 08:30 | **No** | **Failing** (`/metrics`) |

A certificate cannot outlive its signer, so master-2's certificate ends on 2026-09-25 14:10 at the latest. The kubelet will then obtain a new one from the current signer, which the frozen bundle does not trust. **Every node will fall out of monitoring as its certificate renews**, so this will not stay limited to worker-1.

### 4.6 Five-whys
1. *Why is worker-1 `<unknown>`?* metrics-server rejects worker-1's kubelet certificate.
2. *Why is it rejected?* Its signer is not in the CA bundle metrics-server trusts.
3. *Why is the signer missing?* The bundle copy last synced on 2026-09-05; the signer was created on 2026-09-20.
4. *Why did the copy not sync?* CMO, the only component that syncs it, has been stopped since 2026-09-17.
5. *Why is CMO stopped?* It was intentionally stopped and locked via a ClusterVersion override so a 2→1 replica memory-saving pin would persist. The dependency between CMO and the CA sync was not identified when the change was made.

### 4.7 Contributing factors
- **Unsupported change:** the pin can only be kept by disabling CMO's ownership, which the platform treats as a blocker for upgrades and does not maintain.
- **Weak detection:** the only alerts are `warning`-level and are not routed outside the console. There is no check that compares the monitoring CA copy with its source.
- **Underlying capacity constraint:** the pin was made because worker memory is tight (worker-2 requests ~88% of allocatable). That constraint still exists (see §9).

### 4.8 Ruled out / not related
- **Node or kubelet fault:** ruled out. Nodes Ready, kubelet certificates valid (issuer, dates and reachability checked).
- **Certificate expiry or a pending CSR:** ruled out. 0 pending CSRs; the certificates are valid until 10-20.
- **Network or DNS:** ruled out. The TLS handshake completes; the error is a trust failure, not a connection failure.
- **`PrometheusOperatorRejectedResources` (user-workload-monitoring, 2 ServiceMonitors)** is also firing. It has *not* been investigated and is not attributed to this issue. It will be reviewed once CMO is running again.
- A ~35-minute blip in worker-1 scrapes around 2026-09-18 16:37 was seen in Prometheus history. It was not analysed and is not attributed to this issue.

---

## 5. Evidence

| # | Evidence | Observed |
|---|---|---|
| E1 | `oc adm top nodes` | worker-1 `<unknown>`; other 4 nodes report values |
| E2 | metrics-server log | `Get "https://192.168.29.31:10250/metrics/resource": tls: failed to verify certificate: x509: certificate signed by unknown authority` (283 occurrences, worker-1 only) |
| E3 | Prometheus targets | worker-1 `/metrics`, `/metrics/cadvisor`, `/metrics/probes` = down; worker-2 `/metrics` = down; same x509 error |
| E4 | Source ConfigMap `openshift-config-managed/kubelet-serving-ca` | **5** certs, includes `kube-csr-signer_@1789893034` |
| E5 | Monitoring copy `openshift-monitoring/kubelet-serving-ca-bundle` | **4** certs, last modified 2026-09-05T08:30:16Z, does **not** include `@1789893034` |
| E6 | File actually mounted in the metrics-server pod | Same 4-cert stale bundle |
| E7 | Live kubelet certificates | worker-1/worker-2 authority key `AA:3B:8D:C2…` = signer `@1789893034`; masters use `@1787753455` / `@1788597007` |
| E8 | `csr-signer` secret | `not-before 2026-09-20T08:30:33Z`, `refresh-period 360h0m0s` |
| E9 | CMO / ClusterVersion | CMO replicas `0`; `spec.overrides` contains `cluster-monitoring-operator` `unmanaged: true`; `Upgradeable=False (ClusterVersionOverridesSet)` |
| E10 | Prometheus history | worker-1 up until ~09:12 UTC 2026-09-21, then down; worker-2 `/metrics` first down 09:12:24 |

Read-only reproduction: `scripts/verify-kubelet-ca-bundle.sh` (exit 1 = drift or at-risk nodes; current run reproduces E4/E5/E7).

---

## 6. Solution Options

| | **A. End the temporary change (recommended)** | **B. Manual sync (workaround)** |
|---|---|---|
| What | Re-enable CMO, remove the ClusterVersion override | Copy the source CA bundle into the monitoring ConfigMap by hand; restart the two consumers; leave CMO off |
| Fixes root cause | **Yes** — automatic sync restored permanently | **No** — treats the symptom only |
| Recurs | No | **Yes**, at every signer rotation (~every 15 days; next ~2026-10-05) and needs manual repeat |
| Unblocks 4.20.38 patch | **Yes** | **No** (`Upgradeable=False` remains) |
| Keeps memory saving | No — 5 components return to 2 replicas (+~1.4 GiB requests) | Yes |
| Downtime | None for workloads; monitoring gap ~2–5 min | None for workloads; monitoring gap ~2–5 min |
| Supportability | Fully supported state | Remains an unsupported, unmanaged configuration |
| Risk | Low (see §8) | Low, but operational risk of forgetting the next rotation |
| Rollback | Re-apply the pin (re-introduces this defect) | Restore the saved ConfigMap |

**Not recommended — automating Option B (scheduled sync).** It would remove the manual step, but it still leaves CMO unmanaged, still blocks upgrades, and adds a custom component to maintain.

### Recommendation
**Option A**, executed before **2026-09-25 14:10 UTC** (master-2 certificate renewal) and before the 4.20.38 patch. Option B is acceptable only if the memory saving must be preserved for a defined period, and then it should be repeated after each signer rotation and removed before upgrade.

---

## 7. Proposed Change Plan (Option A) — for approval

**Change type:** normal, low risk. **Downtime:** none for workloads. **Suggested window:** any time before 2026-09-25 14:10 UTC, outside busy use of the monitoring stack (~30 min including verification).

### 7.1 Pre-checks (read-only)
```bash
oc get nodes                                   # all Ready
oc get co | grep -v "True.*False.*False"       # none listed
oc get pods -A | grep -vE "Running|Completed"  # none
oc adm top nodes                               # note baseline
./scripts/verify-kubelet-ca-bundle.sh          # confirms current drift (expected: exit 1)
mkdir -p ~/change-24 && cd ~/change-24
oc get clusterversion version -o yaml > cv-before.yaml
oc get cm kubelet-serving-ca-bundle -n openshift-monitoring -o yaml > kubelet-ca-bundle-before.yaml
oc get deploy cluster-monitoring-operator -n openshift-monitoring -o yaml > cmo-before.yaml
```

### 7.2 Change
```bash
oc scale deployment cluster-monitoring-operator -n openshift-monitoring --replicas=1
oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[]}}'
```
CMO returns, re-syncs the CA bundle, and re-asserts 2 replicas on the five components.

### 7.3 Verification (wait 2–5 minutes, then)
```bash
oc get clusterversion version -o jsonpath='{.spec.overrides}'                # empty
oc get deploy cluster-monitoring-operator -n openshift-monitoring            # 1/1
./scripts/verify-kubelet-ca-bundle.sh                                        # RESULT: healthy, exit 0
oc adm top nodes                                                             # worker-1 shows values
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'localhost:9090/api/v1/query?query=up{job="kubelet"}==0'           # empty result
oc get pods -n openshift-monitoring | grep -vE "Running|Completed"          # none Pending
oc adm upgrade | grep -i upgradeable                                          # no ClusterVersionOverridesSet
```
**If a consumer has not picked up the new bundle** after ~5 minutes: `oc rollout restart deploy/metrics-server -n openshift-monitoring`; restart `prometheus-k8s-0` and then `prometheus-k8s-1` one at a time (data is on PVCs).

### 7.4 Rollback
Restore the temporary change (this is how the pin was originally applied):
```bash
oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[{"kind":"Deployment","group":"apps","name":"cluster-monitoring-operator","namespace":"openshift-monitoring","unmanaged":true}]}}'
oc scale deployment cluster-monitoring-operator -n openshift-monitoring --replicas=0
sleep 10
oc patch prometheus k8s -n openshift-monitoring --type=merge -p '{"spec":{"replicas":1}}'
oc patch alertmanager main -n openshift-monitoring --type=merge -p '{"spec":{"replicas":1}}'
oc scale deployment thanos-querier metrics-server monitoring-plugin -n openshift-monitoring --replicas=1
```
**Note:** rolling back re-creates this defect, so it should be paired with Option B's manual sync and a scheduled reminder for the next signer rotation.

### 7.5 Option B commands (only if approved as an interim measure)
```bash
oc get cm kubelet-serving-ca -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ca.crt
oc patch cm kubelet-serving-ca-bundle -n openshift-monitoring --type=merge \
  -p "$(jq -n --rawfile c ca.crt '{data:{"ca-bundle.crt":$c}}')"
oc rollout restart deploy/metrics-server -n openshift-monitoring
oc delete pod prometheus-k8s-0 -n openshift-monitoring     # brief monitoring gap; data is on the PVC
```
Rollback for B: `oc apply -f kubelet-ca-bundle-before.yaml` (saved in the pre-checks).

---

## 8. Risks of the Change and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Second replicas cannot be scheduled — worker-2 memory *requests* rise from ~88% to ~91% of allocatable | Low–Medium | Requests are what the scheduler checks, and they fit by calculation (not yet tested). Pre-check the placement; if a replica stays Pending, the first responder is rollback or relieving memory (§9). Monitoring stays available with 1 replica of each in the meantime |
| Brief monitoring/metrics gap while Prometheus/metrics-server restart | High (expected) | ~2–5 min, no workload impact; data retained on PVCs |
| CMO reconciles other drift accumulated while stopped (e.g. `PrometheusOperatorRejectedResources`) | Low | Review `oc get co monitoring` and pods after the change; nothing else in the cluster depends on it |
| Real memory (not requests) on worker nodes rises ~2.7 GiB (mostly second Prometheus) | Medium | Workers had ~6.4 GiB and ~4.0 GiB available at the last check (only 1 h after boot; re-check before the change) |

---

## 9. Preventive Actions (proposed — each subject to approval)

| # | Action | Type | Effort |
|---|---|---|---|
| P1 | Run `scripts/verify-kubelet-ca-bundle.sh` as a scheduled check (cron) and after every signer rotation; alert on non-zero exit | Detect | Low |
| P2 | Add the script and the "no ClusterVersion overrides" check to the pre-upgrade checklist | Prevent | Low |
| P3 | Route `TargetDown` for the kubelet job (currently warning → console only) to a monitored channel | Detect | Low |
| P4 | Do not use CMO-unmanaged overrides for capacity relief. Address the underlying constraint instead (worker RAM headroom, e.g. +RAM on the Proxmox VMs or trimming the largest requesters such as `openshift-gitops`, ~2 GiB requests) | Prevent | Medium |
| P5 | Add an addendum to Issue 22 noting that its replica pin requires the CMO override and causes this defect | Document | Low |
| P6 | Correct-and-extend the runbook: "if the pin must be re-applied, repeat the CA sync after every signer rotation" | Document | Low |

---

## 10. Related Constraint to Note for the 4.20.38 Patch

Independent of this defect, neither worker can absorb the other's non-DaemonSet pods while its peer is drained: ~8,313 MiB of requests versus ~8,087 MiB allocatable (a ~226 MiB shortfall before Option A, ~1.6 GiB after). Some lower-priority pods are expected to be Pending during each worker reboot. This is temporary and non-blocking, but it should be planned (e.g. scaling down non-essential workloads for the window). Also take a fresh etcd backup on the day (the latest is from 2026-08-27).

---

## 11. Approval

| Item | Decision |
|---|---|
| Approve Option A (end temporary change) | ☐ Approved  ☐ Rejected  ☐ Alternative: ____________ |
| Approve Option B as interim only | ☐ Approved  ☐ Rejected |
| Approved change window (UTC) | __________________ |
| Preventive actions P1–P6 | ☐ All  ☐ Selected: ____________ |
| Approver name / role | __________________ |
| Date | __________________ |

*Prepared from live cluster evidence collected 2026-09-21. Statements marked as inference (§3 latency explanation, §8 scheduling estimate) are not independently proven.*
