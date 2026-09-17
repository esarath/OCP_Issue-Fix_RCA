# Issue 22 — Monitoring Scaling Approaches: Memory Pressure Fix Analysis

| Field | Detail |
|---|---|
| **Date** | 2026-09-17 |
| **Type** | Technical Analysis & Implementation Guide |
| **Status** | Completed — CR patch approach successfully implemented |
| **Scope** | Comprehensive analysis of monitoring scaling approaches for memory pressure remediation |
| **Cluster** | lab.ocp.local (OCP 4.20.35, dev/testing environment) |
| **Problem** | Worker-2 memory pressure at 90% (7344Mi/8192Mi) caused by monitoring components |
| **Solution Applied** | CR patch approach to scale down monitoring replicas from 2 to 1 |

---

## Problem Context

**Initial Memory Pressure Analysis:**
- **Worker-2**: 7344Mi/8192Mi (90%) - Critical memory pressure
- **Worker-1**: 5648Mi/8192Mi (69%) - Acceptable memory usage
- **Primary Memory Consumers on Worker-2**:
  - Prometheus (prometheus-k8s): 2423Mi
  - Alertmanager: 66Mi
  - Prometheus user-workload: 104Mi
  - Thanos Querier: 80Mi
  - Thanos Ruler: 56Mi
  - **Total monitoring memory**: ~2.7GB

**Impact:**
- Risk of pod eviction during upgrades
- Resource constraints for new workloads
- Potential system instability

---

## Comprehensive Monitoring Scaling Approaches

### Approach 1: ConfigMap Configuration (Recommended by OpenShift Documentation)

#### Overview
The ConfigMap approach is the officially recommended method for configuring OpenShift monitoring stack. The Cluster Monitoring Operator (CMO) reads configuration from ConfigMaps and applies changes to the monitoring CRs.

#### Architecture
```
ConfigMap (cluster-monitoring-config) 
    ↓
Cluster Monitoring Operator (CMO)
    ↓
Monitoring CRs (Prometheus, Alertmanager, etc.)
    ↓
Pods scaled accordingly
```

#### Implementation Steps

**Step 1: Backup Current Configuration**
```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml > monitoring-config-backup.yaml
oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o yaml > user-workload-config-backup.yaml
```

**Step 2: Edit Main Monitoring ConfigMap**
```bash
oc edit configmap cluster-monitoring-config -n openshift-monitoring
```

**Expected Configuration:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    prometheusK8s:
      replicas: 1
      retention: 15d
      resources:
        requests:
          cpu: 70m
          memory: 1Gi
    alertmanagerMain:
      replicas: 1
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: nfs-storage
          resources:
            requests:
              storage: 2Gi
```

**Step 3: Edit User Workload Monitoring ConfigMap**
```bash
oc edit configmap user-workload-monitoring-config -n openshift-user-workload-monitoring
```

**Expected Configuration:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    prometheus:
      replicas: 1
      retention: 15d
      resources:
        requests:
          cpu: 70m
          memory: 1Gi
    thanosRuler:
      replicas: 1
      resources:
        requests:
          cpu: 10m
          memory: 50Mi
```

**Step 4: Monitor Reconciliation**
```bash
# Watch CMO apply changes
oc get pods -n openshift-monitoring -w
oc logs -n openshift-monitoring cluster-monitoring-operator-<pod> -f
```

**Step 5: Verify Changes**
```bash
oc get prometheus -n openshift-monitoring
oc get alertmanager -n openshift-monitoring
oc get prometheus -n openshift-user-workload-monitoring
oc get thanosruler -n openshift-user-workload-monitoring
```

#### When to Use This Approach
- ✅ **Production environments** where configuration changes should be tracked in GitOps
- ✅ **Compliance requirements** where all changes must be auditable
- ✅ **Multi-cluster deployments** where consistent configuration is needed
- ✅ **When using GitOps** for cluster configuration management
- ✅ **When configuration changes are complex** (multiple parameters, resources, etc.)

#### Advantages
- **Officially supported** by Red Hat documentation
- **Declarative configuration** - easier to version control
- **CMO manages lifecycle** - automatic reconciliation
- **Consistent across clusters** - can be managed via GitOps
- **Validation by admission webhook** - prevents invalid configurations

#### Disadvantages
- **Limited by OpenShift version** - not all parameters available in all versions
- **Admission webhook restrictions** - some fields may be rejected
- **Reconciliation delays** - CMO may take time to apply changes
- **Complex debugging** - when things fail, harder to troubleshoot

#### Version-Specific Limitations
**OpenShift 4.20 ConfigMap Limitations:**
- ❌ `prometheusK8s.replicas` - Not supported via ConfigMap in 4.20
- ❌ `alertmanagerMain.replicas` - Not supported via ConfigMap in 4.20
- ❌ `prometheus.replicas` (user-workload) - Not supported via ConfigMap in 4.20
- ❌ `thanosRuler.replicas` - Not supported via ConfigMap in 4.20

**Error Encountered:**
```
Error from server (Forbidden): admission webhook "monitoringconfigmaps.openshift.io" denied the request: 
failed to parse data at key "config.yaml": error unmarshaling: unknown field "alertmanagerMain.replicas"
unknown field "prometheusK8s.replicas"
```

---

### Approach 2: CR Patch Approach (What We Successfully Used)

#### Overview
Direct modification of the monitoring Custom Resources (Prometheus, Alertmanager, ThanosRuler) using kubectl patch commands. This approach bypasses ConfigMap limitations and directly modifies the CR specifications.

#### Architecture
```
kubectl patch Prometheus CR
    ↓
Direct CR modification
    ↓
Operator detects change
    ↓
Pods scaled immediately
```

#### Implementation Steps

**Step 1: Backup Current Configuration**
```bash
oc get prometheus k8s -n openshift-monitoring -o yaml > prometheus-backup.yaml
oc get alertmanager main -n openshift-monitoring -o yaml > alertmanager-backup.yaml
oc get prometheus user-workload -n openshift-user-workload-monitoring -o yaml > user-workload-prometheus-backup.yaml
oc get thanosruler user-workload -n openshift-user-workload-monitoring -o yaml > thanos-ruler-backup.yaml
```

**Step 2: Scale Down Prometheus**
```bash
oc patch prometheus k8s -n openshift-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
```

**Step 3: Scale Down Alertmanager**
```bash
oc patch alertmanager main -n openshift-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
```

**Step 4: Scale Down User Workload Prometheus**
```bash
oc patch prometheus user-workload -n openshift-user-workload-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
```

**Step 5: Scale Down Thanos Ruler**
```bash
oc patch thanosruler user-workload -n openshift-user-workload-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
```

**Step 6: Monitor the Changes**
```bash
# Watch pods terminate and restart
oc get pods -n openshift-monitoring -w
oc get pods -n openshift-user-workload-monitoring -w

# Check CR status
oc get prometheus -n openshift-monitoring
oc get alertmanager -n openshift-monitoring
oc get prometheus -n openshift-user-workload-monitoring
oc get thanosruler -n openshift-user-workload-monitoring
```

**Step 7: Verify Memory Improvement**
```bash
# Check node memory allocation
oc describe nodes | grep -A 5 "Allocated resources"

# Check specific node
oc describe node worker-2.lab.ocp.local | grep -A 5 "Allocated resources"
```

**Step 8: Verify Monitoring Functionality**
```bash
# Check monitoring operator status
oc get clusteroperator monitoring

# Test Prometheus access
oc port-forward -n openshift-monitoring prometheus-k8s-0 9090:9090
curl http://localhost:9090/api/v1/status/config

# Test Alertmanager access
oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093
curl http://localhost:9093/api/v1/status
```

#### When to Use This Approach
- ✅ **Development/testing environments** where quick changes are needed
- ✅ **When ConfigMap approach fails** due to version limitations
- ✅ **Emergency situations** requiring immediate action
- ✅ **One-off changes** that don't need to be tracked in GitOps
- ✅ **When direct control** over CRs is preferred
- ✅ **Troubleshooting** and testing configurations

#### Advantages
- **Immediate effect** - changes applied directly to CRs
- **Bypasses ConfigMap limitations** - works when ConfigMap approach fails
- **Full control** - direct access to all CR fields
- **Quick troubleshooting** - easier to debug issues
- **No admission webhook restrictions** - direct CR modification

#### Disadvantages
- **Not officially recommended** for production configuration management
- **Manual reconciliation** - CMO may override changes
- **No GitOps integration** - changes not tracked in version control
- **Risk of configuration drift** - manual changes may be lost
- **Less auditable** - harder to track configuration history

#### Live Implementation Results

**Commands Executed:**
```bash
# Successfully applied all patches
oc patch prometheus k8s -n openshift-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
# Output: prometheus.monitoring.coreos.com/k8s patched

oc patch alertmanager main -n openshift-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
# Output: alertmanager.monitoring.coreos.com/main patched

oc patch prometheus user-workload -n openshift-user-workload-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
# Output: prometheus.monitoring.coreos.com/user-workload patched

oc patch thanosruler user-workload -n openshift-user-workload-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
# Output: thanosruler.monitoring.coreos.com/user-workload patched
```

**Results After 3 Minutes:**
```
NAME            DESIRED   READY   REPLICAS   STATUS
prometheus/k8s  1         1       -          ✅ Scaled down
alertmanager/main 1       1       1          ✅ Scaled down  
prometheus/user-workload 1   1       -          ✅ Scaled down
thanosruler/user-workload 1   1       1          ✅ Scaled down
```

**Pod Status:**
- ✅ Only `-0` replicas running (no `-1` replicas)
- ✅ All pods healthy and running
- ✅ Monitoring operator: AVAILABLE=True, PROGRESSING=False, DEGRADED=False

**Memory Improvement:**
- Worker-2: 90% → 89% (minimal improvement due to other pods)
- Worker-1: 69% → 54% (significant improvement)

---

### Approach 3: Manual CR Editing

#### Overview
Direct editing of Custom Resources using `oc edit` command to modify specifications interactively.

#### Implementation Steps

**Step 1: Edit Prometheus CR**
```bash
oc edit prometheus k8s -n openshift-monitoring
# Find "replicas: 2" and change to "replicas: 1"
# Save and exit
```

**Step 2: Edit Alertmanager CR**
```bash
oc edit alertmanager main -n openshift-monitoring
# Find "replicas: 2" and change to "replicas: 1"
# Save and exit
```

**Step 3: Edit User Workload Components**
```bash
oc edit prometheus user-workload -n openshift-user-workload-monitoring
oc edit thanosruler user-workload -n openshift-user-workload-monitoring
# Change replicas: 2 to replicas: 1
```

**Step 4: Monitor Changes**
```bash
oc get pods -n openshift-monitoring -w
oc get pods -n openshift-user-workload-monitoring -w
```

#### When to Use This Approach
- ✅ **Interactive troubleshooting** when you need to see the full configuration
- ✅ **Learning and exploration** of CR structure
- ✅ **Complex multi-field changes** that are easier to do interactively
- ✅ **When you need to see** the current configuration before making changes

#### Advantages
- **Interactive** - see full configuration before editing
- **Visual feedback** - easier to understand the structure
- **Multi-field changes** - can modify multiple fields at once
- **Validation on save** - editor validates before applying

#### Disadvantages
- **Error-prone** - manual editing can introduce syntax errors
- **Not scriptable** - can't be automated
- **Risk of mistakes** - easier to make unintended changes
- **No audit trail** - changes not logged like patch commands

---

### Approach 4: Resource Limits Adjustment

#### Overview
Instead of scaling down replicas, adjust resource requests and limits to reduce memory pressure while maintaining high availability.

#### Implementation Steps

**Step 1: Edit Prometheus Resource Requests**
```bash
oc edit prometheus k8s -n openshift-monitoring
```

**Resource Configuration:**
```yaml
spec:
  resources:
    requests:
      cpu: 50m        # Reduced from 70m
      memory: 512Mi    # Reduced from 1Gi
    limits:
      cpu: 200m       # Reduced from higher limits
      memory: 1Gi      # Reduced from higher limits
```

**Step 2: Edit Other Components**
```bash
oc edit alertmanager main -n openshift-monitoring
oc edit prometheus user-workload -n openshift-user-workload-monitoring
oc edit thanosruler user-workload -n openshift-user-workload-monitoring
```

**Step 3: Monitor Performance**
```bash
# Watch for OOMKilled events
oc get events -n openshift-monitoring --field-selector reason=OOMKilling

# Check pod restarts
oc get pods -n openshift-monitoring
```

#### When to Use This Approach
- ✅ **When maintaining HA is critical** but memory is constrained
- ✅ **When replicas cannot be reduced** due to workload requirements
- ✅ **When you have performance monitoring** to validate resource changes
- ✅ **When workloads are predictable** and can handle reduced resources

#### Advantages
- **Maintains HA** - keeps multiple replicas
- **Gradual optimization** - can fine-tune resources
- **Performance-based** - can adjust based on actual usage
- **No downtime** - pods continue running with adjusted resources

#### Disadvantages
- **Risk of performance degradation** - reduced resources may impact monitoring
- **Complex tuning** - requires careful monitoring and adjustment
- **Potential instability** - pods may be OOMKilled if too aggressive
- **Workload dependent** - effectiveness varies based on monitoring load

---

### Approach 5: Data Retention Reduction

#### Overview
Reduce the amount of metrics data stored, which reduces memory and storage requirements while keeping HA.

#### Implementation Steps

**Step 1: Edit Monitoring ConfigMap**
```bash
oc edit configmap cluster-monitoring-config -n openshift-monitoring
```

**Retention Configuration:**
```yaml
data:
  config.yaml: |
    prometheusK8s:
      retention: 7d  # Reduced from 15d
      retentionSize: 10GB  # Add size limit
```

**Step 2: Edit User Workload Config**
```bash
oc edit configmap user-workload-monitoring-config -n openshift-user-workload-monitoring
```

**User Workload Retention:**
```yaml
data:
  config.yaml: |
    prometheus:
      retention: 7d  # Reduced from 15d
      retentionSize: 5GB  # Add size limit
```

**Step 3: Monitor Storage**
```bash
# Check PVC usage
oc get pvc -n openshift-monitoring
oc exec -n openshift-monitoring prometheus-k8s-0 -- df -h
```

#### When to Use This Approach
- ✅ **When long-term metrics history is not critical** for dev/testing
- ✅ **When storage is constrained** along with memory
- ✅ **When maintaining HA is required** but resources are limited
- ✅ **When you have external metrics storage** for long-term retention

#### Advantages
- **Maintains HA** - keeps multiple replicas
- **Reduces memory footprint** - less data to process
- **Reduces storage requirements** - smaller PVCs needed
- **Gradual cleanup** - old data ages out naturally

#### Disadvantages
- **Loss of historical data** - shorter retention period
- **Limited debugging** - less historical context for issues
- **Performance impact** - may not significantly reduce memory usage
- **Storage-dependent** - effectiveness depends on data patterns

---

### Approach 6: Pod Affinity and Scheduling

#### Overview
Use Kubernetes pod affinity and anti-affinity rules to better distribute monitoring pods across nodes.

#### Implementation Steps

**Step 1: Edit Prometheus Affinity**
```bash
oc edit prometheus k8s -n openshift-monitoring
```

**Affinity Configuration:**
```yaml
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
          topologyKey: kubernetes.io/hostname
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: prometheus
        topologyKey: kubernetes.io/hostname
```

**Step 2: Add Node Affinity (Optional)**
```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
            - worker-1.lab.ocp.local
```

**Step 3: Monitor Pod Distribution**
```bash
oc get pods -n openshift-monitoring -o wide
oc get pods -n openshift-user-workload-monitoring -o wide
```

#### When to Use This Approach
- ✅ **When you have multiple worker nodes** with uneven pod distribution
- ✅ **When you want to maintain HA** but balance resource usage
- ✅ **When adding new worker nodes** to the cluster
- ✅ **When specific workloads** need to be isolated to certain nodes

#### Advantages
- **Better resource distribution** - spreads load across nodes
- **Maintains HA** - keeps multiple replicas
- **Flexible scheduling** - can optimize for performance or cost
- **No functional changes** - monitoring behavior unchanged

#### Disadvantages
- **Complex configuration** - affinity rules can be difficult to tune
- **May not solve memory pressure** - just redistributes the problem
- **Scheduling constraints** - may prevent pod placement
- **Requires adequate node capacity** - needs sufficient resources on all nodes

---

## Current Cluster Analysis

### Cluster Configuration
- **OpenShift Version**: 4.20.35
- **Architecture**: 3 masters + 2 workers
- **Environment**: Development/Testing
- **Monitoring Stack**: OpenShift monitoring with user-workload enabled

### Current Memory Pressure State
**After CR Patch Implementation:**
- **Worker-1**: 4371Mi/8192Mi (54%) - ✅ Healthy
- **Worker-2**: 7257Mi/8192Mi (89%) - ⚠️ Still High

### Pod Distribution Analysis
**Worker-2 (36 pods):**
- Monitoring: prometheus-k8s-0, alertmanager-main-0, thanos-querier
- GitOps: 4 pods (operator, application-controller, dex-server, repo-server)
- Networking: 6 pods (DNS, router, frr-k8s, multus, network-diagnostics)
- Storage: nfs-provisioner, image-registry
- System: tuned, machine-config-daemon, kube-rbac-proxy, etc.

**Worker-1 (17 pods):**
- Monitoring: thanos-querier, metrics-server
- GitOps: 0 pods
- Networking: Minimal pods
- System: Basic node components

### Why Minimal Memory Improvement
Despite scaling down monitoring replicas, worker-2 memory only improved from 90% to 89% because:

1. **Pod distribution imbalance**: Worker-2 hosts 36 pods vs Worker-1's 17 pods
2. **Non-monitoring workloads**: GitOps, networking, and system pods consume significant memory
3. **Monitoring components still present**: Prometheus-k8s-0 still runs on worker-2
4. **Memory request vs actual usage**: Kubernetes allocates based on requests, not actual usage

### Current Cluster Approach
**The cluster follows a hybrid approach:**
- **ConfigMap for basic configuration**: enableUserWorkload, storage settings
- **Direct CR modification for replicas**: Due to OpenShift 4.20 ConfigMap limitations
- **Manual intervention for troubleshooting**: Direct pod and node management

**Version-Specific Constraints:**
- OpenShift 4.20 does not support replica configuration via ConfigMap
- CR patch approach required for replica scaling
- CMO manages reconciliation but allows direct CR modification

---

## Live Implementation Summary

### What We Actually Did

**Initial Approach Attempted:**
1. ✅ Backed up existing configurations
2. ❌ ConfigMap approach failed due to OpenShift 4.20 limitations
3. ✅ Switched to CR patch approach
4. ✅ Successfully scaled down all monitoring components

**Commands Executed:**
```bash
# Backup configurations
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml > /tmp/monitoring-config-backup-20260917.yaml
oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o yaml > /tmp/user-workload-config-backup-20260917.yaml

# CR patch approach (successful)
oc patch prometheus k8s -n openshift-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
oc patch alertmanager main -n openshift-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
oc patch prometheus user-workload -n openshift-user-workload-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
oc patch thanosruler user-workload -n openshift-user-workload-monitoring --type='json' -p='[{"op": "replace", "path": "/spec/replicas", "value":1}]'
```

### Results Achieved

**Monitoring Components:**
- ✅ All components scaled from 2 replicas to 1 replica
- ✅ All pods healthy and running
- ✅ Monitoring operator healthy (AVAILABLE=True, PROGRESSING=False, DEGRADED=False)
- ✅ Monitoring functionality verified

**Memory Pressure:**
- Worker-1: 69% → 54% (15% improvement)
- Worker-2: 90% → 89% (1% improvement)

**Pod Status:**
- ✅ Only single replicas running (no -1 pods)
- ✅ No pod restarts or failures
- ✅ All monitoring components accessible

### Lessons Learned

**Technical Lessons:**
1. **ConfigMap limitations**: OpenShift 4.20 doesn't support replica configuration via ConfigMap
2. **CR patch reliability**: Direct CR modification works reliably when ConfigMap approach fails
3. **Memory complexity**: Scaling monitoring replicas alone doesn't solve memory pressure if pod distribution is uneven
4. **CMO behavior**: CMO allows direct CR modification and doesn't immediately revert changes

**Operational Lessons:**
1. **Backup importance**: Always backup before making changes
2. **Version awareness**: Check OpenShift version documentation for supported features
3. **Holistic analysis**: Memory pressure requires analyzing entire pod distribution, not just monitoring
4. **Dev environment trade-offs**: For dev clusters, single replica monitoring is acceptable

---

## Approach Comparison Matrix

| Approach | Production Use | Dev Use | Speed | GitOps Ready | Version Constraints | Memory Impact | HA Impact |
|----------|---------------|---------|-------|--------------|-------------------|---------------|-----------|
| **ConfigMap** | ✅ Recommended | ✅ Good | Medium | ✅ Yes | ❌ Version limited | Medium | None |
| **CR Patch** | ⚠️ Emergency | ✅ Ideal | Fast | ❌ No | ✅ Works always | High | Reduced |
| **Manual Edit** | ❌ Not recommended | ✅ Good | Medium | ❌ No | ✅ Works always | High | Reduced |
| **Resource Limits** | ✅ Good | ✅ Good | Medium | ✅ Yes | ✅ Works always | Medium | None |
| **Retention Reduction** | ✅ Good | ✅ Good | Slow | ✅ Yes | ✅ Works always | Low | None |
| **Pod Affinity** | ✅ Good | ✅ Good | Medium | ✅ Yes | ✅ Works always | Redistribution | None |

---

## Recommendations by Use Case

### Production Clusters
**Recommended Approach: ConfigMap**
- Use ConfigMap for all configuration changes
- Implement GitOps for configuration management
- Use resource limits and retention tuning for optimization
- Maintain HA with multiple replicas
- Use pod affinity for load distribution

### Development/Testing Clusters
**Recommended Approach: CR Patch**
- Use CR patch for quick changes
- Scale down replicas to reduce resource usage
- Accept reduced HA for development workloads
- Use direct editing for troubleshooting
- Focus on functionality over resilience

### Emergency Situations
**Recommended Approach: CR Patch**
- Immediate action required
- Bypass configuration management
- Direct CR modification for speed
- Document changes post-incident
- Plan for proper configuration afterward

### Multi-Cluster Environments
**Recommended Approach: ConfigMap + GitOps**
- Consistent configuration across clusters
- Centralized configuration management
- Version-controlled changes
- Automated deployment
- Compliance and audit requirements

---

## Future Improvements for Current Cluster

### Immediate Actions
1. **Add third worker node** to distribute pod load
2. **Implement pod affinity rules** to balance monitoring components
3. **Scale down non-critical components** (GitOps, networking) on worker-2
4. **Monitor resource usage** to identify optimization opportunities

### Long-term Improvements
1. **Implement GitOps** for monitoring configuration management
2. **Add resource quotas** to prevent memory pressure
3. **Implement automated scaling** based on resource usage
4. **Consider migration to newer OpenShift version** with enhanced ConfigMap support

### Configuration Management
1. **Document current configuration** in version control
2. **Implement configuration drift detection**
3. **Add monitoring configuration to backup procedures**
4. **Create runbooks for common scaling scenarios**

---

## Conclusion

**Approach Selection Summary:**
- **ConfigMap approach**: Ideal for production but limited by OpenShift 4.20
- **CR patch approach**: Successfully used for immediate memory pressure relief
- **Current cluster**: Hybrid approach due to version constraints and dev environment

**Live Implementation Success:**
- ✅ Monitoring components successfully scaled down
- ✅ Memory pressure partially addressed
- ✅ Monitoring functionality maintained
- ⚠️ Pod distribution still uneven requires additional optimization

**Key Takeaway:**
For OpenShift 4.20 environments experiencing memory pressure, the CR patch approach provides immediate relief when ConfigMap limitations prevent replica configuration. However, comprehensive memory pressure resolution requires holistic analysis of pod distribution and resource allocation across all workloads, not just monitoring components.

---

## Related Documentation

- [OpenShift Monitoring Configuration](https://docs.openshift.com/container-platform/4.20/monitoring/configuring-the-monitoring-stack.html)
- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [Kubernetes Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [OpenShift Cluster Scaling](https://docs.openshift.com/container-platform/4.20/scalability/index.html)