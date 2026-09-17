# Issue 21 — Security Patch Application Guide for OpenShift 4.20.35

| Field | Detail |
|---|---|
| **Date** | 2026-09-17 |
| **Type** | Security patch procedure guide |
| **Status** | Procedure documented and ready for execution |
| **Scope** | Apply security patches to OpenShift 4.20.35 cluster before major upgrade |
| **Target Version** | 4.20.38 (includes all security patches from 4.20.35, 4.20.36, 4.20.37) |
| **Related Issues** | None (baseline security hardening procedure) |

---

## Cluster Status Assessment

**Current Cluster State:**
- **OpenShift Version**: 4.20.35
- **RHCOS Version**: 9.6.20260818-0 (Plow)
- **Kernel**: 5.14.0-570.135.1.el9_6.x86_64
- **Architecture**: HighlyAvailable (3 master + 2 worker nodes)
- **Platform**: Baremetal (None cloud provider)
- **Network**: OVNKubernetes with MTU 1400

**Available Security Updates:**
- 4.20.38 (latest in fast channel) - **Recommended**
- 4.20.37, 4.20.36 (intermediate security updates)

**Cluster Health Score**: 9.5/10
- All 35 cluster operators healthy (Available=True, Progressing=False, Degraded=False)
- All 5 nodes Ready and healthy
- All 226 pods running normally
- No critical issues preventing upgrade operations

---

## Security Patch Application Methods

### Method A: Cluster Update (Recommended)
**Most comprehensive approach** - includes all security patches:

```bash
# Set the desired version
oc patch clusterversion/version --type='json' -p='[{"op": "replace", "path": "/spec/desiredUpdate/version", "value":"4.20.38"}]'

# Monitor the upgrade progress
oc get clusterversion version -w

# Check cluster operator status during upgrade
oc get clusteroperator
```

**Advantages:**
- Latest security patches included
- Comprehensive (kernel, container runtime, cluster components)
- Automated handling with automatic rollback if needed
- Thoroughly tested by Red Hat

### Method B: Machine Config Updates Only
**For OS/kernel patches only** - without changing cluster version:

```bash
# Check current machine config
oc get machineconfigpool

# Monitor the update process
oc get machineconfigpool -w
```

### Method C: Manual Node Patching (Advanced)
**For individual node security patches**:

```bash
# Cordon the node
oc adm cordon <node-name>

# Drain the node
oc adm drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Check if the node needs reboot
oc debug node/<node-name> -- chroot /host rpm -qa kernel

# Reboot the node (if needed)
oc debug node/<node-name> -- chroot /host reboot

# Uncordon the node
oc adm uncordon <node-name>
```

---

## Complete Security Patch Procedure

### Phase 1: Pre-Patch Preparation

#### Step 1: Backup Critical Configuration
```bash
# Backup cluster configuration
oc get clusterconfiguration -A > cluster-config-backup.yaml
oc get machineconfigpools -o yaml > mcp-backup.yaml
oc get machineconfig -o yaml > mc-backup.yaml
```

#### Step 2: Verify Cluster Health
```bash
# Check cluster operators
oc get clusteroperator

# Check machine config pools
oc get machineconfigpool

# Check node status
oc get nodes

# Check pod status
oc get pods -A | grep -E "CrashLoopBackOff|Error|ImagePullBackOff"
```

#### Step 3: Review Security Advisories
```bash
# Check for available security updates
oc get clusterversion version -o yaml | grep -A 20 "availableUpdates"

# Check Red Hat security advisories for current version
# Visit: https://access.redhat.com/errata/RHSA-2026:57545 (for 4.20.35)
```

#### Step 4: Pre-Flight Checks
```bash
# Schedule maintenance window (allow 30-60 minutes)
# Notify users of potential service disruption

# Ensure cluster is healthy
oc get clusteroperator | grep -v "True.*False.*False"

# Check for resource pressure
oc describe nodes | grep -A 5 "Allocated resources"

# Verify storage capacity
oc get pv
oc get pvc -A
```

### Phase 2: Security Patch Application

#### Option 1: Apply Cluster Update (Recommended)
```bash
# Apply the latest security update
oc patch clusterversion/version --type='json' -p='[{"op": "replace", "path": "/spec/desiredUpdate/version", "value":"4.20.38"}]'

# Monitor the upgrade progress
oc get clusterversion version -w
```

#### Option 2: Update Operator Subscriptions
```bash
# Check installed operators
oc get subscription -A

# For each subscription, check for updates
oc get csv -n <namespace>

# Update operators if needed
oc patch subscription <subscription-name> -n <namespace> --type='json' -p='[{"op": "replace", "path": "/spec/channel", "value":"<latest-channel>"}]'
```

### Phase 3: Monitor During Update

```bash
# Watch cluster version progress
oc get clusterversion version -w

# Monitor machine config pools
oc get machineconfigpool -w

# Check for any pod failures
oc get pods -A -w | grep -E "Error|CrashLoopBackOff"

# Check cluster operator status
watch oc get clusteroperator
```

### Phase 4: Post-Patch Verification

#### Step 1: Verify Node Updates
```bash
# Check all nodes are updated
oc get nodes -o wide

# Verify OS and kernel versions
oc get node -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion

# Check machine config pool status
oc get machineconfigpool
```

#### Step 2: Verify Cluster Health
```bash
# Check cluster operators
oc get clusteroperator

# Check for any degraded components
oc get clusteroperator | grep Degraded

# Check pod status
oc get pods -A
```

#### Step 3: Check System Logs
```bash
# Check node logs for any issues
oc logs -n openshift-machine-config-operator <machine-config-daemon-pod>

# Check kernel logs
oc debug node/<node-name> -- chroot /host journalctl -k
```

#### Step 4: Security Specific Checks
```bash
# Check for CVEs (use OpenSCAP scanner if available)
oc get security

# Check Red Hat Security Advisories
# Visit: https://access.redhat.com/security/
```

---

## Rollback Plan

If the update causes issues:

```bash
# Check rollback status
oc get clusterversion version -o yaml | grep -A 10 "history"

# Rollback to previous version (if available)
oc edit clusterversion version
# Change desiredUpdate.version back to "4.20.35"
```

---

## Recommendations for Your Cluster

### Recommended Strategy
**Apply 4.20.38 update** because:
1. Latest security patches included
2. Comprehensive (kernel, container runtime, cluster components)
3. Automated handling with automatic rollback
4. Thoroughly tested by Red Hat

### Pre-Upgrade Actions
- Monitor Worker-2 memory (currently at 90% - consider scaling out)
- Clean up 13 released PVCs to free storage resources
- Ensure backups of etcd and application data are current
- Review marketplace connectivity

### Post-Upgrade Actions
- Verify all operators are healthy
- Validate workloads are running correctly
- Review resource allocation changes
- Monitor logs for upgrade-related issues

### Long-term Improvements
- Add 1-2 additional worker nodes for better resource distribution
- Evaluate storage class performance
- Implement resource usage alerts for proactive capacity management

---

## Security Considerations

### Current Security Status
- **Kernel version**: 5.14.0-570.135.1.el9_6.x86_64 is current for RHCOS 9.6
- **Container runtime**: CRI-O 1.33.13 is appropriate for the cluster version
- **Security patches**: Available in 4.20.38 update

### CVE Monitoring
- Review Red Hat Security Advisories: https://access.redhat.com/security/
- Check errata for specific CVEs: https://access.redhat.com/errata/RHSA-2026:66377 (4.20.38)
- Document CVEs addressed in change ticket before approval

---

## Execution Timeline

### Maintenance Window
- **Duration**: 30-60 minutes expected
- **Impact**: Temporary service disruption during control plane upgrade
- **User Notification**: Required before starting

### Monitoring Timeline
- **Pre-Flight**: 15 minutes for health checks
- **Update Execution**: 30-45 minutes for cluster update
- **Post-Flight**: 15 minutes for verification
- **Total**: ~60-90 minutes

---

## Success Criteria

✅ All cluster operators Available=True, Progressing=False, Degraded=False
✅ All 5 nodes Ready with updated versions
✅ All pods running normally (no CrashLoopBackOff, Error states)
✅ Machine config pools updated and not degraded
✅ No security-related warnings in logs
✅ Applications functioning normally

---

## Next Steps

1. **Schedule maintenance window** and notify users
2. **Perform pre-flight checks** using Phase 1 steps
3. **Execute security patch update** using Method A (recommended)
4. **Monitor progress** using Phase 3 commands
5. **Verify success** using Phase 4 verification steps
6. **Document results** and update this issue with actual execution timeline

---

## Related Documentation

- [Red Hat: Preparing to update a cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/updating_clusters/preparing-to-update-a-cluster)
- [Red Hat: Updating a cluster](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/updating_clusters/updating-a-cluster)
- [OpenShift Update Process Explained](https://kubernetes.recipes/recipes/configuration/openshift-cluster-update-process-explained/)
- [Security Advisories](https://access.redhat.com/security/)
- [Errata for 4.20.38](https://access.redhat.com/errata/RHSA-2026:66377)

---

## Cluster Health Baseline (Pre-Patch)

**Resource Utilization:**
- Master-1: CPU 50%, Memory 67%
- Master-2: CPU 43%, Memory 53%
- Master-3: CPU 51%, Memory 68%
- Worker-1: CPU 44%, Memory 69%
- Worker-2: CPU 56%, Memory 90% ⚠️

**Known Issues:**
- Historical marketplace operator connectivity warnings (resolved)
- Recent node reboots on all masters (scheduled, recovered successfully)
- High memory usage on Worker-2 (monitor during upgrade)

**Storage Status:**
- 6 active PVCs bound (total 154Gi)
- 13 released PVCs (cleanup recommended)

---

**Status**: Ready for execution once maintenance window is scheduled and pre-flight checks are completed.