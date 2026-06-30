# Runbook: OCP Kubelet Certificate Expiry Recovery

**Applies to:** OCP 4.x lab/dev clusters  
**Symptom:** Web console unreachable, HAProxy backends DOWN, worker pods phantom-Running  
**Recovery time:** ~10–15 minutes

---

## Quick Reference (TL;DR)

```bash
# Step 1 — Approve all pending CSRs (run twice, 60s apart)
oc get csr -o name | xargs oc adm certificate approve

# Step 2 — Wait ~60s for serving cert CSRs to appear, then approve again
sleep 60 && oc get csr -o name | xargs oc adm certificate approve

# Step 3 — Verify nodes are Ready
oc get nodes

# Step 4 — Force-delete any stuck Terminating ingress pods
oc get pods -n openshift-ingress | grep Terminating
oc delete pod -n openshift-ingress <pod-name> --force --grace-period=0

# Step 5 — If DNS pods are stuck, delete and let them reschedule
oc get pods -n openshift-dns | grep -v Running
oc delete pod -n openshift-dns <stuck-pod-name>

# Step 6 — Verify console is reachable
curl -k -s -o /dev/null -w "%{http_code}" https://console-openshift-console.apps.lab.ocp.local
# Expect: 200
```

---

## Background

OCP worker nodes use short-lived (~30-day) X.509 client certificates for the kubelet to authenticate with the API server. These auto-rotate when the cluster is running, but if the cluster is **powered off or workers are offline** during the renewal window, certificates expire and must be manually approved.

### Two certificate types to renew

| Type | Signer | Used for |
|---|---|---|
| Kubelet client cert | `kubernetes.io/kube-apiserver-client-kubelet` | Kubelet → API server auth |
| Kubelet serving cert | `kubernetes.io/kubelet-serving` | API server → Kubelet (port 10250) |

Both types appear as CSRs and both must be approved.

---

## Failure Chain

```
Kubelet certs expired
        │
        ▼
Kubelets authenticate as system:anonymous
        │
        ├──► Cannot register nodes with API server
        ├──► Cannot receive pod assignments
        └──► Cannot start/stop pods on workers
                │
                ▼
        Router pods never actually start on workers
        (port 443/80 not listening on worker nodes)
                │
                ▼
        HAProxy load balancer: all backends DOWN
        (SSL_ERROR_ZERO_RETURN — server closes TLS immediately)
                │
                ▼
        Web console unreachable
```

**Warning:** `oc get pods` will show router pods as `1/1 Running` — this is stale etcd state. The containers do not actually exist on the nodes. Always cross-check with `crictl ps` on the node.

---

## Diagnosis Steps

### 1. Confirm the symptom
```bash
curl -k -v --connect-timeout 10 https://console-openshift-console.apps.lab.ocp.local
# SSL_ERROR_ZERO_RETURN or connection refused = ingress is down
```

### 2. Check HAProxy load balancer status
```bash
systemctl status haproxy
# Look for: "Server ingress_https_backend/worker-N is DOWN"
# Look for: "backend 'ingress_https_backend' has no server available!"
```

### 3. Verify no CSRs are pending
```bash
oc get csr | grep Pending
# Many pending CSRs with requestor "node-bootstrapper" = cert expiry confirmed
```

### 4. Confirm kubelet cert error on worker nodes
```bash
ssh -i ~/.ssh/ocp4-key core@<worker-ip> \
  "sudo journalctl -u kubelet --no-pager -n 10 | grep -E 'certificate|anonymous'"
# Look for: "No valid client certificate is found"
# Look for: User "system:anonymous" cannot ...
```

### 5. Confirm containers are not actually running
```bash
ssh -i ~/.ssh/ocp4-key core@<worker-ip> "sudo crictl ps"
# If only a handful of containers (not the full workload) = kubelet not syncing pods
```

---

## Recovery Procedure

### Phase 1 — Renew kubelet client certificates

```bash
# Approve all pending client cert CSRs
oc get csr -o name | xargs oc adm certificate approve

# Verify nodes return to Ready
oc get nodes
# All nodes should show STATUS=Ready within ~30s
```

### Phase 2 — Approve kubelet serving certificates

After ~60 seconds, a second batch of CSRs appears for the serving certs:

```bash
oc get csr | grep Pending
# New CSRs with signer: kubernetes.io/kubelet-serving

oc get csr -o name | xargs oc adm certificate approve
```

### Phase 3 — Clean up stuck router pods

The old router pods will be stuck in `Terminating` because the kubelet was offline when deletion was attempted:

```bash
oc get pods -n openshift-ingress
# Look for pods in Terminating state

oc delete pod -n openshift-ingress \
  $(oc get pods -n openshift-ingress --no-headers | grep Terminating | awk '{print $1}') \
  --force --grace-period=0
```

### Phase 4 — Watch for DNS recovery (if needed)

When workers come back online, Multus CNI reinitializes before DNS. If DNS pods were scheduled during this window they will fail with sandbox errors:

```bash
oc get pods -n openshift-dns
# Look for: ImagePullBackOff, ContainerCreating (stuck), or FailedCreatePodSandBox events

# Check cluster operator status
oc get clusteroperator dns
# If AVAILABLE=False or DEGRADED=True, delete the stuck pods

oc delete pod -n openshift-dns \
  $(oc get pods -n openshift-dns --no-headers | grep -v Running | awk '{print $1}')
# Pods will reschedule cleanly once Multus is ready (~1-2 min)
```

### Phase 5 — Verify full recovery

```bash
# Console reachable
curl -k -s -o /dev/null -w "HTTP %{http_code}\n" \
  https://console-openshift-console.apps.lab.ocp.local
# Expect: HTTP 200

# Router pods healthy
oc get pods -n openshift-ingress
# Expect: all pods 1/1 Running

# No degraded operators
oc get clusteroperator | grep -v "True.*False.*False"
# Expect: no output (all operators healthy)

# No pending CSRs
oc get csr | grep Pending
# Expect: no output
```

---

## Environment Reference (lab.ocp.local)

| Resource | Value |
|---|---|
| HAProxy load balancer | `svc-infra.ocp.local` — 192.168.29.10 |
| Worker-1 | `worker-1.lab.ocp.local` — 192.168.29.31 |
| Worker-2 | `worker-2.lab.ocp.local` — 192.168.29.32 |
| Master nodes | 192.168.29.21 / .22 / .23 |
| SSH key | `~/.ssh/ocp4-key` (user: `core`) |
| HAProxy config | `/etc/haproxy/haproxy.cfg` |
| Console URL | `https://console-openshift-console.apps.lab.ocp.local` |
| API URL | `https://api.lab.ocp.local:6443` |

---

## Prevention

This problem occurs on lab clusters that are shut down and restarted. Two mitigations:

### Option A — Approve CSRs on every cluster startup (recommended for lab)

Add to your startup checklist or a post-boot script on the bastion:

```bash
#!/bin/bash
# Run after cluster nodes are back online
echo "Approving kubelet client CSRs..."
oc get csr -o name | xargs oc adm certificate approve 2>/dev/null

echo "Waiting 60s for serving cert CSRs..."
sleep 60

echo "Approving kubelet serving CSRs..."
oc get csr -o name | xargs oc adm certificate approve 2>/dev/null

echo "Node status:"
oc get nodes
```

Save as `/home/centos/approve-csrs.sh` — a version of this already exists in the home directory.

### Option B — Monitor CSR backlog

```bash
# Quick health check — run after any cluster restart
oc get csr | grep -c Pending
# If > 0, run the approval commands above
```

### Option C — Check certificate expiry before shutdown

```bash
# Check when worker kubelet certs expire
oc get csr --sort-by='.metadata.creationTimestamp' | tail -5
# If approaching expiry, approve any pending CSRs before shutting down
```

---

## Key Diagnostic Commands

```bash
# How many CSRs are pending?
oc get csr | grep -c Pending

# What are workers doing?
ssh -i ~/.ssh/ocp4-key core@192.168.29.31 \
  "sudo journalctl -u kubelet --no-pager -n 20 2>&1 | grep -E 'cert|anonymous|forbidden'"

# Are containers actually running on workers?
ssh -i ~/.ssh/ocp4-key core@192.168.29.31 "sudo crictl ps"

# Is port 443 listening on workers?
ssh -i ~/.ssh/ocp4-key core@192.168.29.31 "sudo ss -tlnp | grep ':443'"

# HAProxy backend health
journalctl -u haproxy --no-pager -n 20 | grep -E 'DOWN|UP|ALERT'

# All cluster operator health
oc get clusteroperator
```

---

*Runbook created: 2026-06-30*  
*Incident: Web console unreachable after cluster restart — kubelet cert expiry on worker-1 and worker-2*
