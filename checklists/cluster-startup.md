# OCP Cluster Startup Checklist

**Cluster**: lab.ocp.local | OCP 4.16.55
**Use this**: Every time the cluster is powered on after a shutdown or extended downtime

> **Note:** Steps 3 and 3b below now also run automatically via cron every 5 minutes
> (`crontab -l` on the bastion) — both are safe no-ops when the cluster is healthy.
> This checklist still applies for manual verification, and as a fallback if cron
> is ever disabled.

---

## Step 1 — Start VMs (on Proxmox host)

```bash
ssh root@192.168.29.2

# Start infra node first (DNS, DHCP, HAProxy must be up before nodes)
qm start 100

# Wait ~30s for services to come up, then start masters
sleep 30
qm start 201 202 203

# Wait for masters to settle, then start workers
sleep 60
qm start 301 302

# Verify all VMs are running
qm list
```

Expected state:

| VMID | Name | Status |
|------|------|--------|
| 100 | svc-infra | running |
| 201 | master-1 | running |
| 202 | master-2 | running |
| 203 | master-3 | running |
| 301 | worker-1 | running |
| 302 | worker-2 | running |

---

## Step 2 — Verify infrastructure services (on svc-infra)

```bash
ssh centos@192.168.29.10

# DNS
systemctl is-active named

# DHCP
systemctl is-active dhcpd

# HAProxy
systemctl is-active haproxy

# HTTP (ignition server)
systemctl is-active httpd
```

All should return `active`. If any are failed: `sudo systemctl restart <service>`

---

## Step 3 — Run certificate recovery script

**Always run this after any cluster restart.** Kubelet certificates expire if the
cluster was offline during the renewal window. The script is safe to run even when
certs are healthy — it will report "No pending CSRs" and move on.

```bash
# Dry run first to assess state (no changes made)
bash /home/centos/approve-csrs.sh --dry-run

# If dry run looks correct, run live
bash /home/centos/approve-csrs.sh
```

The script handles automatically:
- Approving kubelet client certificate CSRs (Phase 1)
- Approving kubelet serving certificate CSRs (Phase 2)
- Verifying all nodes return to Ready (Phase 3)
- Force-deleting stuck Terminating ingress router pods (Phase 4)
- Recovering stuck DNS pods (Phase 5)
- Final health verification including console HTTP 200 check (Phase 6)

Full log written to: `/home/centos/csr-approval.log`

If the console check still fails after the script completes, wait 60s and retest:
```bash
curl -k -s -o /dev/null -w "%{http_code}" \
  https://console-openshift-console.apps.lab.ocp.local
```

> For detailed diagnosis if something is still wrong, see the runbook:
> `/home/centos/ocp/runbooks/kubelet-cert-recovery.md`

---

## Step 3b — Run OVN-Kubernetes crash-loop recovery script

**Also run this after any cluster restart**, alongside Step 3 — this handles a
*different* failure mode than kubelet cert expiry: `ovnkube-controller` hitting a
startup race against its own admission webhook and crash-looping. Signature is
`oc get csr` showing **zero** pending CSRs while nodes are still `NotReady` with
`No CNI configuration file in /etc/kubernetes/cni/net.d/`. Also safe to run when
healthy — it's a no-op if no node matches the signature.

```bash
# Dry run first to assess state (no changes made)
bash /home/centos/fix-ovn-crashloop.sh --dry-run

# If dry run looks correct, run live
bash /home/centos/fix-ovn-crashloop.sh
```

The script handles automatically:
- Detecting nodes stuck in the crash-loop signature (only after it's persisted ≥180s)
- Temporarily relaxing the `network-node-identity` webhook to break the startup race
- Recovering affected nodes **one at a time** (not all at once — see RCA for why)
- Reverting the webhook back to enforced (`Fail`) unconditionally before exiting

Full log written to: `/home/centos/ovn-crashloop-fix.log`

> For detailed diagnosis and the blast-radius warning, see:
> `~/OCP_Issue-Fix_RCA/issues/03-ovn-kubernetes-crash-loop-after-reboot/RCA.md`

---

## Step 4 — Verify cluster health

```bash
export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig

# All nodes Ready
oc get nodes

# All operators healthy (no output = all good)
oc get clusteroperator | grep -v "True.*False.*False"

# No pending CSRs
oc get csr | grep Pending

# Router pods running
oc get pods -n openshift-ingress
```

---

## Step 5 — Confirm web console

Open in browser: **https://console-openshift-console.apps.lab.ocp.local**

Login with: `kubeadmin` / password in `/home/centos/ocp/install/auth/kubeadmin-password`

```bash
cat /home/centos/ocp/install/auth/kubeadmin-password
```

---

## Quick Health Summary

```bash
# One-liner cluster health check
export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig
echo "=== Nodes ===" && oc get nodes --no-headers \
  && echo "=== Pending CSRs ===" && oc get csr | grep Pending \
  && echo "=== Degraded Operators ===" && oc get co | grep -v "True.*False.*False" \
  && echo "=== Console ===" && curl -k -s -o /dev/null -w "HTTP %{http_code}\n" \
     https://console-openshift-console.apps.lab.ocp.local
```

---

## Troubleshooting

| Symptom | First check | Resolution |
|---|---|---|
| Console unreachable, CSRs pending | `oc get csr \| grep Pending` | Run `approve-csrs.sh` |
| Console unreachable, 0 CSRs pending, node message has "No CNI configuration file" | `oc describe node <n>` conditions | Run `fix-ovn-crashloop.sh` |
| Nodes NotReady | `oc get csr \| grep Pending` first, then node condition `reason` | `approve-csrs.sh` (Unknown/NodeStatusUnknown) or `fix-ovn-crashloop.sh` (False/KubeletNotReady) |
| Router pods 0/1 | DNS operator status | Run `approve-csrs.sh` (handles DNS recovery) |
| HAProxy backends DOWN | `systemctl status haproxy` | Check worker nodes are up, run `approve-csrs.sh` |
| DNS pods ImagePullBackOff | Multus still initializing | Delete stuck pods, they reschedule automatically |

Both `approve-csrs.sh` and `fix-ovn-crashloop.sh` also run automatically via cron every 5 minutes — check `/home/centos/csr-approval.log` and `/home/centos/ovn-crashloop-fix.log` before running anything by hand.

Full runbooks:
- `/home/centos/ocp/runbooks/kubelet-cert-recovery.md`
- `~/OCP_Issue-Fix_RCA/issues/03-ovn-kubernetes-crash-loop-after-reboot/RCA.md`

---

*Created: 2026-06-30*
