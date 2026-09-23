#!/bin/bash
# =============================================================================
# get-ad-ca.sh — pull the TLS cert chain from the AD/LDAP server and write
# ad-ca.crt (the CA/root that OCP needs to trust LDAPS).
#
# Usage:  ./get-ad-ca.sh <ad-host> [port]      e.g. ./get-ad-ca.sh ad.lab.ocp.local
# =============================================================================
set -euo pipefail
HOST="${1:?usage: $0 <ad-host> [port]}"
PORT="${2:-636}"
OUT="ad-ca.crt"

# Grab the full presented chain
openssl s_client -connect "${HOST}:${PORT}" -servername "${HOST}" -showcerts </dev/null 2>/dev/null \
  | openssl storeutl -certs /dev/stdin > chain.pem 2>/dev/null || true

# Fallback for openssl without storeutl: dump all PEM blocks
if [ ! -s chain.pem ]; then
  openssl s_client -connect "${HOST}:${PORT}" -servername "${HOST}" -showcerts </dev/null 2>/dev/null \
    | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' > chain.pem
fi

echo "=== Presented chain ==="
awk 'BEGIN{n=0} /BEGIN CERT/{n++} {print > ("cert" n ".pem")} END{print n " certs"}' chain.pem
for f in cert*.pem; do
  [ -s "$f" ] && openssl x509 -in "$f" -noout -subject -issuer 2>/dev/null | sed "s/^/$f: /"
done

# The LAST cert in the chain is (usually) the root CA — that's what goes in ad-ca.crt
last=$(ls cert*.pem | tail -1)
cp "$last" "$OUT"
echo
echo "Wrote $OUT — verify it's actually the ROOT CA (subject == issuer):"
openssl x509 -in "$OUT" -noout -subject -issuer

echo
echo "NOTE: if the server omits the root from the chain, get the CA cert from"
echo "your AD/PKI admin instead. Then create the ConfigMap:"
echo "  oc create configmap ldap-ca --from-file=ca.crt=$OUT -n openshift-config"
