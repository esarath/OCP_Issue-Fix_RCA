# Issue 01 — Web Console Unreachable After Cluster Restart

| Field | Detail |
|---|---|
| **Date** | 2026-06-30 |
| **Severity** | High |
| **Status** | Resolved |
| **Affected** | Web console, all worker-hosted workloads |
| **Root Cause** | Kubelet client certificates expired on worker nodes during cluster downtime |
| **Resolution Time** | ~15 minutes |

---

## Symptom

`https://console-openshift-console.apps.lab.ocp.local` was unreachable after cluster restart.

```
curl: (35) OpenSSL SSL_connect: SSL_ERROR_ZERO_RETURN
```

HAProxy accepted the TCP connection on port 443 but immediately closed it without completing the TLS handshake. `oc get pods -n openshift-ingress` falsely showed router pods as `1/1 Running`.

---

## Quick Fix

```bash
# 1. Approve all pending kubelet CSRs (run the recovery script)
bash scripts/approve-csrs.sh

# Or dry-run first to see what would happen
bash scripts/approve-csrs.sh --dry-run

# 2. Verify console is back
curl -k -s -o /dev/null -w "%{http_code}" \
  https://console-openshift-console.apps.lab.ocp.local
# Expected: 200
```

---

## Root Cause (Summary)

OCP kubelet certificates (~30-day lifetime) expired while the cluster was offline.
On restart, kubelets authenticated as `system:anonymous` and could not start any pods.
The router pods never ran on the workers, so HAProxy had no live backends.

Full analysis → [RCA.md](RCA.md)

---

## Files

| File | Description |
|---|---|
| [RCA.md](RCA.md) | Full root cause analysis, failure chain, and step-by-step diagnosis |
| [scripts/approve-csrs.sh](scripts/approve-csrs.sh) | Automated 6-phase recovery script |

---

## Prevention

Run `scripts/approve-csrs.sh` on every cluster restart.
See [cluster startup checklist](../../checklists/cluster-startup.md).
