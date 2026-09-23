#!/usr/bin/env bash
# verify-kubelet-ca-bundle.sh  (READ-ONLY - changes nothing on the cluster)
#
# Checks that the CA bundle monitoring uses to trust kubelet serving certs
# (openshift-monitoring/kubelet-serving-ca-bundle) matches the source of truth
# (openshift-config-managed/kubelet-serving-ca), and that every node's live
# kubelet serving cert was issued by a signer present in the monitoring copy.
#
# Exit 0 = healthy, 1 = drift / at-risk nodes found, 2 = could not run.
# Related: Issue 24 (stale kubelet CA bundle while CMO is unmanaged).

export PATH=/usr/local/bin:/usr/bin:/bin
[ -z "${KUBECONFIG:-}" ] && export KUBECONFIG=/home/centos/ocp/install/auth/kubeconfig

SRC_NS=openshift-config-managed; SRC_CM=kubelet-serving-ca
DST_NS=openshift-monitoring;     DST_CM=kubelet-serving-ca-bundle

for bin in oc openssl csplit; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 2; }
done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
rc=0

# split_bundle <pem file> <outdir> -> writes one cert per file, prints their SKIs
split_bundle() {
  mkdir -p "$2"
  csplit -s -z -f "$2/c-" "$1" '/-----BEGIN CERT/' '{*}' 2>/dev/null
  for f in "$2"/c-*; do
    [ -e "$f" ] || continue
    openssl x509 -in "$f" -noout -ext subjectKeyIdentifier 2>/dev/null | tail -1 | tr -d ' '
  done | sort -u
}

oc get cm -n "$SRC_NS" "$SRC_CM" -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp/src.pem" 2>/dev/null
oc get cm -n "$DST_NS" "$DST_CM" -o jsonpath='{.data.ca-bundle\.crt}' > "$tmp/dst.pem" 2>/dev/null
[ -s "$tmp/src.pem" ] && [ -s "$tmp/dst.pem" ] || { echo "could not read one or both ConfigMaps"; exit 2; }

split_bundle "$tmp/src.pem" "$tmp/src" > "$tmp/src.ski"
split_bundle "$tmp/dst.pem" "$tmp/dst" > "$tmp/dst.ski"

echo "== 1. Bundle sync ($SRC_NS/$SRC_CM -> $DST_NS/$DST_CM) =="
echo "source certs: $(wc -l < "$tmp/src.ski")   monitoring copy: $(wc -l < "$tmp/dst.ski")"
missing=$(comm -23 "$tmp/src.ski" "$tmp/dst.ski")
if [ -n "$missing" ]; then
  rc=1
  echo "DRIFT: monitoring copy is missing these signers from the source:"
  for f in "$tmp"/src/c-*; do
    ski=$(openssl x509 -in "$f" -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' ')
    if echo "$missing" | grep -qx "$ski"; then
      echo "  - $(openssl x509 -in "$f" -noout -subject | sed 's/subject=//')  $(openssl x509 -in "$f" -noout -enddate)"
    fi
  done
else
  echo "OK: monitoring copy contains every signer in the source"
fi

echo; echo "== 2. Live kubelet serving certs vs monitoring copy =="
printf '%-26s %-16s %-22s %s\n' NODE IP CERT_NOT_AFTER RESULT
while read -r node ip; do
  cert=$(echo | timeout 10 openssl s_client -connect "$ip:10250" 2>/dev/null | openssl x509 2>/dev/null)
  if [ -z "$cert" ]; then printf '%-26s %-16s %-22s %s\n' "$node" "$ip" "-" "UNREACHABLE"; rc=1; continue; fi
  aki=$(echo "$cert" | openssl x509 -noout -ext authorityKeyIdentifier 2>/dev/null | tail -1 | tr -d ' ' | sed 's/^keyid://')
  exp=$(echo "$cert" | openssl x509 -noout -enddate | sed 's/notAfter=//')
  if grep -qx "$aki" "$tmp/dst.ski"; then res="OK"; else res="AT RISK (signer not in monitoring bundle)"; rc=1; fi
  printf '%-26s %-16s %-22s %s\n' "$node" "$ip" "$exp" "$res"
done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

echo; echo "== 3. Symptoms =="
echo -n "CMO replicas: "; oc get deploy cluster-monitoring-operator -n openshift-monitoring -o jsonpath='{.spec.replicas}'; echo
echo -n "ClusterVersion overrides: "; oc get clusterversion version -o jsonpath='{.spec.overrides}'; echo
echo -n "oc adm top nodes with <unknown>: "; oc adm top nodes --no-headers 2>/dev/null | grep -c unknown

echo; [ $rc -eq 0 ] && echo "RESULT: healthy" || echo "RESULT: ATTENTION NEEDED (see above)"
exit $rc
