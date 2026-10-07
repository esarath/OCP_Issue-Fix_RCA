# RCA — Metrics API Unavailable Cluster-Wide: Stale Aggregator CA Bundle While CMO Is Unmanaged

| Field | Detail |
|---|---|
| **Document status** | **EXECUTED & VERIFIED** — remediation completed on the live cluster 2026-10-07 |
| **Cluster** | lab.ocp.local — OpenShift 4.20.35, 3 control-plane + 2 worker nodes (dev/test) |
| **Detected** | 2026-10-07 ~09:45 UTC, during a routine cluster-health check (`kubectl`/`oc` emitted `couldn't get resource list for metrics.k8s.io/v1beta1` warnings) |
| **Impact started** | 2026-09-30 12:20 UTC (APIService `FailedDiscoveryCheck` transition); scrape-auth noise began 2026-09-25 |
| **Severity** | Medium — metrics API fully down (no `oc adm top`, no HPA metrics, no console graphs). No workload or control-plane impact |
| **Category** | Configuration drift caused by an unmanaged operator (follow-on to Issues 22/24 — the CMO stop was never reverted) |
| **Related** | Issue 24 (same root cause on the kubelet trust chain); Issue 22 (replica pin that stopped CMO); OCP 4.20.38 patch readiness |

---

## 1. Executive Summary

Every command that performs API discovery printed:

```
metrics.k8s.io/v1beta1: the server is currently unable to handle the request
```

and `oc adm top nodes` returned nothing. `APIService v1beta1.metrics.k8s.io` reported `Available=False (FailedDiscoveryCheck)` with a `401` from the metrics-server backend.

This was **not** a load or capacity problem — the cluster was nearly idle. It was a **trust failure on the aggregated-API path**. The kube-apiserver proxies metrics API requests to metrics-server using a client certificate signed by the `aggregator-client-signer` CA. That CA rotated on 2026-09-28 as part of normal ~15-day signer rotation. metrics-server validates the proxy cert against a CA bundle in a secret that **only the Cluster Monitoring Operator maintains** — and CMO had been scaled to 0 (and marked `unmanaged` via a ClusterVersion override) since 2026-09-17 for the Issue 22 memory pin. The mounted bundle still held the August/early-September signers, so the new proxy cert was rejected: `x509: certificate signed by unknown authority` → `FailedDiscoveryCheck`.

A second, independent credential had also rotted while CMO was off: `metrics-client-certs`, the client certificate Prometheus presents when scraping metrics-server's `/metrics`, expired on 2026-09-25 and produced a `certificate has expired` 401 every ~30 seconds.

**Fix executed (§6):** refreshed the stale secret from the authoritative source, re-minted the scrape cert through the normal CSR flow, then removed the root cause — scaled CMO back to 1 and cleared the ClusterVersion override so CMO is fully managed again. Verified within minutes: `APIService Available=True`, `oc adm top` working, 209 pods reporting metrics, zero further auth errors.

---

## 2. Impact Assessment

| Area | Impact |
|---|---|
| Application workloads / ingress / API / etcd | **None** — 5/5 nodes Ready, all ClusterOperators Available throughout |
| `metrics.k8s.io` API (`oc adm top`, `kubectl top`, console utilization, HPA metrics feed) | **Fully unavailable** 2026-09-30 → 2026-10-07 |
| Prometheus scrape of metrics-server `/metrics` | Auth failures every ~30s since 2026-09-25 (expired client cert) |
| Alerting | No `Critical` alerts routed for this failure mode — detected only by interactive CLI warnings |
| Data loss | None — metrics samples simply absent for the window |

---

## 3. Timeline (UTC)

| When | Event | Evidence |
|---|---|---|
| 2026-08-26 14:10 | `kube-csr-signer_@1787753455` created | CA subjects/serial |
| 2026-08-29 03:17 | `metrics-client-certs` minted for `prometheus-k8s` SA by that signer | Secret cert `notBefore` |
| 2026-09-17 | CMO scaled to 0 + `ClusterVersion.spec.overrides` `unmanaged:true` (Issue 22 pin; never reverted after Issue 24's recommendation) | ClusterVersion spec; Issue 24 RCA |
| 2026-09-10 ~14:11 | Last sync of the metrics-server CA-bundle secret (`metrics-server-92qmguums1qi8` contains signers `@1787753466` Aug-26 + `@1789049502` Sep-10) | Secret bundle SKIDs |
| 2026-09-25 14:10:55 | `kube-csr-signer_@1787753455` expires → `metrics-client-certs` expires with it; 401 `certificate has expired` noise begins every ~30s | metrics-server log; cert `notAfter` |
| 2026-09-28 14:01 | Scheduled rotation: new `aggregator-client-signer@1790604083` (SKID `DE:A9:A6:5A…`). Source bundle updated; CMO-managed copy stays frozen | Bundle comparison §5 |
| 2026-09-30 12:20:19 | kube-apiserver begins presenting a proxy cert from the new signer; `APIService` → `Available=False (FailedDiscoveryCheck)`, 401 `bad status ... 401` | APIService condition `lastTransitionTime` |
| 2026-10-07 09:45 | Detected during health check; RCA performed; fix applied; APIService `Available=True` at 09:49 | Terminal output |
| 2026-10-07 10:00 | CMO scaled to 1, reconciled all 15 tasks, regenerated bundle secret as `metrics-server-824e055j4ou3h`, repointed the deployment; ClusterVersion override cleared | CMO log |

---

## 4. Root Cause Analysis

### 4.1 Direct cause
`v1beta1.metrics.k8s.io` is an aggregated API: kube-apiserver proxies requests to `Service metrics-server` (openshift-monitoring:443 → pod :10250) and authenticates with a client cert signed by `aggregator-client-signer`. metrics-server validates it against `--requestheader-client-ca-file=/etc/client-ca-bundle/requestheader-client-ca-file`, sourced from secret `metrics-server-92qmguums1qi8`. That secret's bundle did not contain the current signer:

| Bundle | Signers present (SKID) |
|---|---|
| Mounted secret (stale) | `aggregator-client-signer@1787753466` `2B:25:28:B1…`, `@1789049502` `BB:16:F7:FD…` |
| Source `kube-system/extension-apiserver-authentication` | `@1789049502` `BB:16:F7:FD…`, `@1790604083` `DE:A9:A6:5A…` ← current |

Failing cert AKID `DE:A9:A6:5A:8A:40:6F:27:83:D2:63:91:5E:91:F9:1B:64:0C:E4:6C` = signer `@1790604083`, absent from the stale bundle → `401` → `FailedDiscoveryCheck`.

### 4.2 Root cause
The `metrics-server-<hash>` secret is generated and kept in sync **only by the Cluster Monitoring Operator** (hash in the name = content digest). CMO was stopped on 2026-09-17, so the copy froze while signers kept rotating. The same mechanism caused Issue 24 on a different bundle (`kubelet-serving-ca-bundle`); this is the second trust chain to break under the same root cause — the Issue 24 fix (re-enable CMO) was documented but had not been executed.

### 4.3 Trigger
Normal scheduled signer rotation. OCP control-plane signers rotate roughly every 14–15 days on this cluster (aggregator signers observed 08-26 → 09-10 → 09-28). Any operator-maintained CA copy will drift within weeks of CMO stopping — this is guaranteed, not probabilistic.

### 4.4 Second defect
`metrics-client-certs` (CN=`system:serviceaccount:openshift-monitoring:prometheus-k8s`, used by Prometheus's `tls-client-certificate-auth` scrape class on the metrics-server ServiceMonitor) was issued 2026-08-29 by `kube-csr-signer_@1787753455` and expired 2026-09-25. CMO normally re-mints it via a `kubernetes.io/kube-apiserver-client` CSR before expiry. With CMO off, it expired → `certificate has expired` 401s every ~30s (visible in metrics-server logs, error SN `7EDE99A6FE42EE0BFF93C09AC5D77D70`).

### 4.5 Five-whys
1. *Why "server unable to handle the request"?* APIService `FailedDiscoveryCheck` — backend returned 401.
2. *Why 401?* kube-apiserver's aggregator proxy cert is signed by a CA metrics-server doesn't trust.
3. *Why untrusted?* metrics-server's CA-bundle secret was last synced ~09-10; the signer rotated 09-28.
4. *Why no sync?* CMO, the sole owner of that secret, has been scaled to 0 since 09-17.
5. *Why is CMO off?* Issue 22's monitoring replica pin required stopping CMO and marking it `unmanaged`; Issue 24's recommended revert was never executed, so the drift silently continued into the next rotation cycles.

### 4.6 Contributing factors
- **Unreverted temporary change:** Issue 24 already documented that CMO-off breaks CA syncs and blocks upgrades; the revert was pending approval for 16 days.
- **Weak detection:** the failure surfaces only as client-side warnings; no `Critical` alert covers `FailedDiscoveryCheck` or scrape-cert expiry.
- **No drift monitor:** nothing compared the CMO-managed bundles against their sources.

### 4.7 Ruled out
- **Load/capacity:** ruled out — nodes at 2–18% CPU; the error is TLS-layer auth, not throttling.
- **Pod/service/network fault:** ruled out — metrics-server pod Running 1/1, Service endpoints match pod IP, TLS handshake completes (a network failure would not produce an x509 error).
- **APIService misconfiguration:** ruled out — spec points at the correct service/port; the failure was trust, not routing.

---

## 5. Evidence

| # | Evidence | Observed |
|---|---|---|
| E1 | `kubectl get apiservice v1beta1.metrics.k8s.io` | `False (FailedDiscoveryCheck)`; message: `bad status from https://10.131.0.61:10250/apis/metrics.k8s.io/v1beta1: 401`; `lastTransitionTime 2026-09-30T12:20:19Z` |
| E2 | metrics-server pod log | `Unable to authenticate the request` — `x509: certificate signed by unknown authority` (AKID `DE:A9:A6:5A…`) and `x509: certificate has expired ... after 2026-09-25T14:10:55Z` (AKID `9A:80:35:1C…`) |
| E3 | Bundle diff | Stale secret = signers `@1787753466`+`@1789049502`; source CM = `@1789049502`+`@1790604083` (`DE:A9:A6:5A…`) |
| E4 | `metrics-client-certs` secret | cert CN=`system:serviceaccount:openshift-monitoring:prometheus-k8s`, issuer `kube-csr-signer_@1787753455`, `notAfter=Sep 25 14:10:55 2026` — expired |
| E5 | ServiceMonitor `metrics-server` | `scrapeClass: tls-client-certificate-auth` → Prometheus scrapeConfig uses `/etc/prometheus/secrets/metrics-client-certs/tls.crt` |
| E6 | CMO state | Deployment `spec.replicas=0` for ~20 days; ClusterVersion override `unmanaged:true` present; `Upgradeable=False (ClusterVersionOverridesSet)` |
| E7 | Post-fix | `APIService Available=True (Passed)`; `oc adm top` returns all 5 nodes; pod-metrics endpoint reports 209 pods; 0 auth errors in subsequent minutes; CMO log `Created Secret/metrics-server-824e055j4ou3h` |

---

## 6. Executed Change Record

**Change type:** emergency repair + root-cause remediation. **Downtime:** none (metrics API already down; restoration is read-path only).

### 6.1 Immediate restoration — refresh the stale trust bundle
```bash
# Source of truth: kube-system/extension-apiserver-authentication
oc get cm extension-apiserver-authentication -n kube-system \
  -o jsonpath='{.data.requestheader-client-ca-file}' > rh-ca.crt
oc get cm extension-apiserver-authentication -n kube-system \
  -o jsonpath='{.data.client-ca-file}' > client-ca.crt

oc patch secret metrics-server-92qmguums1qi8 -n openshift-monitoring --type=merge \
  -p "{\"data\":{\"requestheader-client-ca-file\":\"$(base64 -w0 rh-ca.crt)\",\"client-ca-file\":\"$(base64 -w0 client-ca.crt)\"}}"
```
Secret-projection propagation + metrics-server's dynamic CA reload restored the API in ~75 s — **no pod restart needed**.

### 6.2 Re-mint the expired Prometheus scrape cert (same flow CMO uses)
```bash
openssl req -new -newkey rsa:2048 -nodes \
  -subj "/CN=system:serviceaccount:openshift-monitoring:prometheus-k8s" \
  -keyout tls.key -out tls.csr

# submit as a kubernetes.io/kube-apiserver-client CSR, approve, harvest
oc create -f csr.yaml                 # signerName: kubernetes.io/kube-apiserver-client
oc certificate approve <csr-name>
oc get csr <csr-name> -o jsonpath='{.status.certificate}' | base64 -d > tls.crt

oc patch secret metrics-client-certs -n openshift-monitoring --type=merge \
  -p "{\"data\":{\"tls.crt\":\"$(base64 -w0 tls.crt)\",\"tls.key\":\"$(base64 -w0 tls.key)\"}}"
```
New cert valid to 2026-11-04 (signed by current `kube-csr-signer_@1791189861`).

### 6.3 Root-cause fix — bring CMO back under management (Issue 24 Option A)
```bash
oc scale deployment cluster-monitoring-operator -n openshift-monitoring --replicas=1
oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[]}}'
```
Observed after ~30 s: CMO reconciled all 15 tasks and regenerated the bundle secret itself (`metrics-server-824e055j4ou3h`), repointing the deployment — superseding the manual patch.

### 6.4 Verification results
| Check | Result |
|---|---|
| `APIService v1beta1.metrics.k8s.io` | `Available=True (Passed)` |
| `oc adm top nodes` | All 5 nodes reporting (CPU 2–10%, mem 41–82%) |
| `kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods` | 209 pods reporting |
| metrics-server auth errors | 0 in the minutes after the fix |
| CMO | 1/1 Running; regenerated bundle secret; deployment repointed |
| ClusterVersion | `spec.overrides=[]`; `Upgradeable=False` condition cleared |
| ClusterOperators | all `Available=True`, none Degraded/Progressing |

---

## 7. Why Recurrence Is Now Automatic (no custom automation)

This is **OCP-native machinery**, not a script:

| Function | Owner | Behaviour |
|---|---|---|
| Signer rotation | `cluster-kube-apiserver-operator` | Rotates `aggregator-client-signer`, `kube-csr-signer`, etc. ~every 14–15 d |
| Trust publication | `cluster-kube-apiserver-operator` | Updates `kube-system/extension-apiserver-authentication` |
| metrics-server CA-bundle secret | `cluster-monitoring-operator` | Regenerates `metrics-server-<hash>` on every CA change, repoints the deployment — **observed live in this fix** |
| `metrics-client-certs` renewal | `cluster-monitoring-operator` | Re-mints via CSR before expiry |
| CSR issuance | `kube-controller-manager` signer | Approves/issues built-in signer CSRs |

The only thing that defeated it was CMO being stopped + unmanaged. With §6.3 applied, the loop is closed permanently.

Caveat: with the override cleared, the CVO owns the CMO deployment again — an `oc scale` on it will be reconciled back to the release state, which is the desired behaviour.

---

## 8. Preventive Actions

| # | Action | Type | Effort | Status |
|---|---|---|---|---|
| P1 | Keep CMO managed — the override was removed and the deployment is 1/1; CVO re-asserts it from now on | Prevent | — | **Done 2026-10-07** |
| P2 | Run `scripts/verify-metrics-api-trust.sh` on a schedule (cron) and before every upgrade/patch; alert on non-zero exit | Detect | Low | Proposed |
| P3 | Add to the pre-upgrade checklist: `ClusterVersion.spec.overrides` must be empty, APIService must be Available, CMO must be ready | Prevent | Low | Proposed |
| P4 | Route an alert for `APIService` `FailedDiscoveryCheck` / scrape-cert expiry to the Slack Critical channel (Issue 16 receiver) instead of relying on interactive CLI warnings | Detect | Low | Proposed |
| P5 | If monitoring memory relief is ever needed again: use supported `cluster-monitoring-config` options or add worker capacity — never by stopping CMO (Issue 24 P4, reaffirmed) | Prevent | Medium | Proposed |
| P6 | Add `issues/24` P5-style cross-reference: the CMO-off defect affects **all** CMO-synced trust material, not just the kubelet bundle | Document | Low | **Done — this doc** |

---

## 9. Lessons

- **One unmanaged operator, many blast radii.** CMO owns at least three trust artifacts: `kubelet-serving-ca-bundle` (Issue 24), `metrics-server-<hash>` (this issue), and `metrics-client-certs` (this issue). Stopping it guarantees a different failure at each signer rotation.
- **Lab cost-savings via `unmanaged` overrides are a booby trap.** The pin saved ~1.4 GiB of requests and cost two metrics outages plus an upgrade blocker.
- **The platform self-heals the moment you let it.** CMO regenerated the exact artifact patched by hand within 30 seconds of starting — manual patching is only a bridge, never the fix.

*Prepared from live cluster evidence collected and remediated 2026-10-07.*
