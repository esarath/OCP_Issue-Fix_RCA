#!/usr/bin/env bash
# verify-metrics-api-trust.sh — read-only health check for the metrics.k8s.io
# aggregated-API trust chain (Issue 31).
#
# Checks:
#   1. APIService v1beta1.metrics.k8s.io is Available
#   2. The CA-bundle secret mounted by metrics-server is in sync with
#      kube-system/extension-apiserver-authentication (requestheader CA)
#   3. metrics-client-certs (Prometheus scrape cert) is not expired / expiring soon
#   4. cluster-monitoring-operator is running and NOT unmanaged via
#      ClusterVersion.spec.overrides
#
# Exit 0 = healthy, 1 = attention needed. No cluster changes are made.
# Usage: ./verify-metrics-api-trust.sh   (needs `oc` or `kubectl` + openssl)

set -u
OC=$(command -v oc || command -v kubectl)
fail=0
say()  { printf '%s\n' "$*"; }
bad()  { say "FAIL: $*"; fail=1; }
ok()   { say "OK:   $*"; }
warn() { say "WARN: $*"; }

[ -z "$OC" ] && { say "FAIL: oc/kubectl not found"; exit 1; }

echo "== 1. APIService availability =="
state=$($OC get apiservice v1beta1.metrics.k8s.io \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
if [ "$state" = "True" ]; then
  ok "APIService v1beta1.metrics.k8s.io Available=True"
else
  bad "APIService Available='$state' ($($OC get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null))"
fi

echo "== 2. metrics-server CA-bundle drift vs source =="
ms_secret=$($OC get deploy metrics-server -n openshift-monitoring \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="client-ca-bundle")].secret.secretName}' 2>/dev/null)
if [ -z "$ms_secret" ]; then
  bad "could not find client-ca-bundle volume on metrics-server deployment"
else
  src=$(mktemp); mnt=$(mktemp)
  $OC get cm extension-apiserver-authentication -n kube-system \
    -o jsonpath='{.data.requestheader-client-ca-file}' > "$src" 2>/dev/null
  $OC get secret "$ms_secret" -n openshift-monitoring \
    -o jsonpath='{.data.requestheader-client-ca-file}' | base64 -d > "$mnt" 2>/dev/null
  # every CA in the source bundle must be present in the mounted bundle
  missing=$(python3 - "$src" "$mnt" <<'EOF' 2>/dev/null
import sys, re
def subs(f):
    return set(re.findall(r'CN=[^\s]+', open(f).read()))
src, mnt = subs(sys.argv[1]), subs(sys.argv[2])
print("\n".join(sorted(src - mnt)))
EOF
)
  if [ -z "$missing" ]; then
    ok "secret $ms_secret carries all source requestheader CAs"
  else
    bad "secret $ms_secret is MISSING signer(s): $(echo "$missing" | tr '\n' ' ')"
  fi
  rm -f "$src" "$mnt"
fi

echo "== 3. metrics-client-certs expiry =="
crt=$($OC get secret metrics-client-certs -n openshift-monitoring \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -z "$crt" ]; then
  bad "metrics-client-certs secret missing or has no tls.crt"
else
  end=$(printf '%s' "$crt" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -z "$end" ]; then
    bad "could not parse metrics-client-certs tls.crt"
  else
    end_epoch=$(date -d "$end" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$end" +%s)
    now=$(date +%s); days=$(( (end_epoch - now) / 86400 ))
    if [ "$days" -lt 0 ]; then
      bad "metrics-client-certs EXPIRED $((-days))d ago ($end)"
    elif [ "$days" -lt 7 ]; then
      warn "metrics-client-certs expires in ${days}d ($end) — CMO should renew it; check CMO health"
    else
      ok "metrics-client-certs valid ${days}d (until $end)"
    fi
  fi
fi

echo "== 4. CMO running + managed =="
ready=$($OC get deploy cluster-monitoring-operator -n openshift-monitoring \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${ready:-0}" -ge 1 ] && ok "cluster-monitoring-operator ready" \
  || bad "cluster-monitoring-operator readyReplicas=${ready:-0}"
ovr=$($OC get clusterversion version -o jsonpath='{.spec.overrides}' 2>/dev/null)
if echo "$ovr" | grep -q cluster-monitoring-operator; then
  bad "ClusterVersion override still marks CMO unmanaged (blocks upgrades)"
else
  ok "no CMO ClusterVersion override"
fi

echo "== 5. Live metrics sanity =="
if $OC get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1; then
  ok "metrics.k8s.io/v1beta1/nodes responds"
else
  bad "metrics.k8s.io/v1beta1/nodes not responding"
fi

echo
[ "$fail" -eq 0 ] && say "RESULT: healthy" || say "RESULT: attention needed"
exit "$fail"
