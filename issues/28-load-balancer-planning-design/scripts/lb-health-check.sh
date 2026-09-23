#!/bin/bash
# =============================================================================
# lb-health-check.sh — audit LB layers on the lab cluster:
#   router pods & endpoints, MetalLB state, service backends,
#   and flag deployments whose probes won't protect the LB (missing readiness).
# Read-only.
# =============================================================================
set -euo pipefail

echo "=== IngressController (router) ==="
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='replicas={.spec.replicas} strategy={.spec.endpointPublishingStrategy.type} domain={.status.domain}{"\n"}'
oc get pods -n openshift-ingress -o wide

echo; echo "=== MetalLB ==="
oc get pods -n metallb-system 2>/dev/null | head -8
oc get ipaddresspool -n metallb-system 2>/dev/null
oc get l2advertisement -n metallb-system 2>/dev/null

echo; echo "=== LoadBalancer services ==="
oc get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || \
oc get svc -A | grep LoadBalancer || true

echo; echo "=== Probe alignment audit (deployments missing readinessProbe) ==="
missing=0
for ns in $(oc get projects -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' \
           | grep -v '^openshift\|^kube-\|^default$'); do
  for d in $(oc get deploy -n "$ns" -o name 2>/dev/null); do
    if ! oc get "$d" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' | grep -q .; then
      echo "  $ns $d — NO readinessProbe (LB can't drain it safely)"
      missing=$((missing+1))
    fi
  done
done
[ "$missing" -eq 0 ] && echo "  All deployments have readinessProbes."

echo; echo "=== External LB spot-checks (svc-infra) ==="
for url in "https://api.lab.ocp.local:6443/healthz" "http://192.168.29.10:80"; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 "$url" || echo "FAIL")
  echo "  $url -> $code"
done
