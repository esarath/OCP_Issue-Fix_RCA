#!/bin/bash
# =============================================================================
# rotate-cert.sh — check the cert served on an OpenShift edge route and rotate
# it (regenerate from local CA + patch route) when < DAYS_LEFT_MIN days remain.
#
# Generic: works for ANY app route — set the vars below or export them.
# Schedule via cron:  0 3 * * 0 /home/centos/manifests/jenkins/rotate-jenkins-cert.sh >> ~/cert-rotate.log 2>&1
#
# Requires: oc (logged in, or KUBECONFIG/token env), openssl
# =============================================================================
set -euo pipefail

# ---- Config (edit or export before running) ---------------------------------
HOST="${HOST:-jenkins-jenkins.apps.lab.ocp.local}"   # route hostname
NS="${NS:-jenkins}"                                  # route namespace
ROUTE="${ROUTE:-jenkins}"                            # route name
CERTDIR="${CERTDIR:-$HOME/jenkins-certs}"            # CA + cert workdir
DAYS_LEFT_MIN="${DAYS_LEFT_MIN:-30}"                 # rotate threshold
CERT_DAYS="${CERT_DAYS:-365}"                        # new cert lifetime
CNF="${CNF:-$CERTDIR/app.cnf}"                       # openssl CSR config
# -----------------------------------------------------------------------------

cd "$CERTDIR"
CA_CRT="${CA_CRT:-lab-ca.crt}"
CA_KEY="${CA_KEY:-lab-ca.key}"
APP_KEY="app.key"
APP_CRT="app.crt"

# Days remaining on the cert currently served
end_date=$(echo | openssl s_client -connect "${HOST}:443" -servername "${HOST}" 2>/dev/null \
           | openssl x509 -noout -enddate | cut -d= -f2)
expiry_epoch=$(date -d "$end_date" +%s)
days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))

if [ "$days_left" -gt "$DAYS_LEFT_MIN" ]; then
  echo "[$(date)] Cert for ${HOST} valid ${days_left}d — nothing to do."
  exit 0
fi

echo "[$(date)] Cert for ${HOST} expires in ${days_left}d — rotating."

openssl genrsa -out "${APP_KEY}.new" 2048
openssl req -new -key "${APP_KEY}.new" -out app.csr -config "$CNF"
openssl x509 -req -in app.csr -CA "$CA_CRT" -CAkey "$CA_KEY" \
  -CAcreateserial -out "${APP_CRT}.new" -days "$CERT_DAYS" -sha256 \
  -extensions v3_req -extfile "$CNF"

mv "${APP_KEY}.new" "$APP_KEY"
mv "${APP_CRT}.new" "$APP_CRT"

# Patch the route — edge termination, redirect http->https
oc patch route "$ROUTE" -n "$NS" --type=merge -p "
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(sed 's/^/      /' "$APP_CRT")
    key: |
$(sed 's/^/      /' "$APP_KEY")
    caCertificate: |
$(sed 's/^/      /' "$CA_CRT")
"

echo "[$(date)] Route ${NS}/${ROUTE} updated. New cert:"
openssl x509 -in "$APP_CRT" -noout -subject -enddate
