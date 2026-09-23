# TLS Certificate Configuration & Auto-Rotation on OpenShift — Any Application or Database

Complete step-by-step guide for putting a trusted TLS cert on any OpenShift Route and keeping it rotated automatically. Worked example uses Jenkins (`jenkins-jenkins.apps.lab.ocp.local`, namespace `jenkins`); every step is written so you can swap in any app.

> **Placeholder convention** (same as repo root README): anything in `<angle brackets>` is a placeholder — replace the whole token before running.

---

## Table of Contents

1. [Concepts — pick your TLS termination](#part-0--concepts--pick-your-tls-termination)
2. [Create a lab CA and an app certificate](#part-1--create-a-lab-ca-and-an-app-certificate)
3. [Attach the cert to the Route](#part-2--attach-the-cert-to-the-route)
4. [Distribute CA trust to clients](#part-3--distribute-ca-trust-to-clients)
5. [Auto-rotation — Option A: cert-manager + openshift-routes](#part-4--auto-rotation)
6. [Auto-rotation — Option B: openssl script + cron](#part-4--auto-rotation)
7. [Verification](#part-5--verification)
8. [Databases & non-HTTP services](#part-6--databases--non-http-services)
9. [Troubleshooting](#part-7--troubleshooting)
10. [Appendix — wildcard certs, HAProxy, reencrypt](#part-8--appendix)

---

## Part 0 — Concepts: pick your TLS termination

The Route's `spec.tls.termination` decides where TLS ends. Choose first; it changes everything downstream.

| Termination | TLS ends at | Traffic router→pod | Use when |
|---|---|---|---|
| `edge` | **Router (HAProxy)** | Plain HTTP | Default for web apps/UI/APIs. Simplest — cert lives only on the route. **Jenkins uses this.** |
| `reencrypt` | Router | **New TLS** to the pod | Policy requires encryption in transit inside the cluster too. App must serve HTTPS (or use service-CA cert). |
| `passthrough` | **Pod itself** | TLS untouched (SNI routing only) | App does its own TLS — **databases**, anything non-HTTP, mTLS. Router never sees plaintext. |

```
Client ──TLS──► Router ──HTTP──► Pod            edge
Client ──TLS──► Router ──TLS──► Pod             reencrypt  (two cert hops)
Client ──TLS──────────────► Pod                 passthrough (router just proxies TCP by SNI)
```

**Key implication for rotation:** with `edge`, the cert is a field on the Route object — rotate by patching the route, zero app changes. With `passthrough`, the cert lives in a Secret mounted by the pod — rotate by updating the secret + pod reload/restart.

---

## Part 1 — Create a lab CA and an app certificate

`.local` domains can't be publicly validated, so we run a private CA. One CA signs every app cert — clients only ever trust one root.

### 1.1 Create the CA (once per environment)

```bash
mkdir -p ~/ocp-certs && cd ~/ocp-certs

openssl genrsa -out lab-ca.key 4096

openssl req -x509 -new -nodes -key lab-ca.key -sha256 -days 3650 \
  -subj "/CN=Lab-Internal-CA/O=Lab" \
  -out lab-ca.crt
```

Guard `lab-ca.key` — it signs everything. `chmod 600 lab-ca.key`.

### 1.2 Per-app openssl config

`app.cnf` — set CN + SANs to the **route hostname** (browsers/clients validate SAN, not CN):

```ini
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = <app-hostname>            # e.g. jenkins-jenkins.apps.lab.ocp.local
O = Lab

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = <app-hostname>
# DNS.2 = <second-hostname-if-any>
# Or one cert for everything:
# DNS.1 = *.apps.lab.ocp.local
```

### 1.3 Key, CSR, sign

```bash
openssl genrsa -out app.key 2048
openssl req -new -key app.key -out app.csr -config app.cnf

openssl x509 -req -in app.csr -CA lab-ca.crt -CAkey lab-ca.key \
  -CAcreateserial -out app.crt -days 365 -sha256 \
  -extensions v3_req -extfile app.cnf
```

### 1.4 Verify before touching the cluster

```bash
openssl x509 -in app.crt -noout -subject -issuer -dates -ext subjectAltName
openssl verify -CAfile lab-ca.crt app.crt        # must print: app.crt: OK
```

---

## Part 2 — Attach the cert to the Route

Jenkins example: service `jenkins`, ns `jenkins`, port `8080` (targetPort name `http`), prefix `/jenkins`.

### 2.1 Create or replace the edge route

```bash
oc project <namespace>

oc create route edge <route-name> \
  --service=<service-name> \
  --hostname=<app-hostname> \
  --path=<url-prefix> \                      # omit if app serves at /
  --cert=~/ocp-certs/app.crt \
  --key=~/ocp-certs/app.key \
  --ca-cert=~/ocp-certs/lab-ca.crt \
  --insecure-policy=Redirect \
  --dry-run=client -o yaml | oc apply -f -
```

For Jenkins concretely:

```bash
oc create route edge jenkins --service=jenkins \
  --hostname=jenkins-jenkins.apps.lab.ocp.local --path=/jenkins \
  --cert=~/ocp-certs/app.crt --key=~/ocp-certs/app.key \
  --ca-cert=~/ocp-certs/lab-ca.crt --insecure-policy=Redirect \
  -n jenkins --dry-run=client -o yaml | oc apply -f -
```

### 2.2 Or patch an existing route in place

```bash
oc patch route <route-name> -n <namespace> --type=merge -p "
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(sed 's/^/      /' ~/ocp-certs/app.crt)
    key: |
$(sed 's/^/      /' ~/ocp-certs/app.key)
    caCertificate: |
$(sed 's/^/      /' ~/ocp-certs/lab-ca.crt)
"
```

> **Note on `caCertificate`**: on an edge route it's used for reencrypt-style destination verification and is optional; harmless to include. The router serves `certificate`+`key` at the edge regardless.

> **Security note**: the private key stored in `route.spec.tls.key` is copied by the router into a managed secret — anyone with `get route` on the namespace can read it. Keep route RBAC tight, or use Part 4 Option A where cert-manager owns the secret.

### 2.3 App-side setting (Jenkins example)

Jenkins itself stays HTTP — but tell it its public URL or it warns "reverse proxy setup is broken" and generates wrong callback links:

**Manage Jenkins → System → Jenkins URL** → `https://jenkins-jenkins.apps.lab.ocp.local/jenkins/`

For other apps: whatever base-url/external-url setting the app has (e.g. `ROOT_URL`, `server.baseUrl`, GitLab `external_url`).

---

## Part 3 — Distribute CA trust to clients

The cert chains to `lab-ca.crt`, which nothing trusts yet. Install it on every client.

```bash
# RHEL / CentOS / Fedora
sudo cp lab-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# Debian / Ubuntu
sudo cp lab-ca.crt /usr/local/share/ca-certificates/lab-ca.crt
sudo update-ca-certificates
```

- **Firefox**: own trust store — Settings → Privacy & Security → Certificates → Authorities → Import `lab-ca.crt`.
- **Cluster nodes** (if pods must call the route): add to the cluster-wide proxy trust — `oc create configmap lab-ca -n openshift-config --from-file=ca-bundle.crt=lab-ca.crt`, then `oc patch proxy/cluster --type=merge -p '{"spec":{"trustedCA":{"name":"lab-ca"}}}'`. Triggers a node config rollout — do it once, not per-app.
- **Java apps**: `keytool -import -trustcacerts -alias lab-ca -file lab-ca.crt -keystore $JAVA_HOME/lib/security/cacerts -storepass changeit -noprompt`
- **curl without trust**: `curl --cacert lab-ca.crt https://<app-hostname>/...`

---

## Part 4 — Auto-rotation

Two supported paths. **Option A** is the recommended end-state; **Option B** needs nothing installed.

### Option A — cert-manager + openshift-routes (fully automatic)

cert-manager issues and renews certs; the `openshift-routes` addon watches annotated Routes and injects the cert — including on renewal. No human in the loop.

#### A.1 Install cert-manager

```bash
# Upstream manifests (or use OperatorHub: "cert-manager Operator for Red Hat OpenShift")
oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml

oc wait --for=condition=Available \
  deploy/cert-manager deploy/cert-manager-webhook deploy/cert-manager-cainjector \
  -n cert-manager --timeout=120s
```

#### A.2 Bootstrap the CA inside cert-manager

`manifests/lab-ca-issuers.yaml` (also in this folder). Three objects: a `selfSigned` ClusterIssuer → a 10-year root CA `Certificate` → a `ca` ClusterIssuer that signs leaf certs for the whole cluster.

```bash
oc apply -f manifests/lab-ca-issuers.yaml
oc get clusterissuer lab-ca-issuer        # READY=True
oc get secret lab-root-ca-secret -n cert-manager   # your CA now lives here
```

#### A.3 Install the openshift-routes controller

```bash
oc apply -f https://github.com/cert-manager/openshift-routes/releases/latest/download/cert-manager-openshift-routes.yaml
```

#### A.4 Annotate the route — done

`manifests/route-tls-certmanager.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: jenkins
  namespace: jenkins
  annotations:
    cert-manager.io/issuer-name: lab-ca-issuer            # required
    cert-manager.io/issuer-kind: ClusterIssuer
    cert-manager.io/common-name: <app-hostname>
    cert-manager.io/duration: 2160h                     # 90d cert
    cert-manager.io/renew-before: 720h                  # renew 30d early
    cert-manager.io/private-key-rotation-policy: Always
spec:
  host: <app-hostname>
  path: <url-prefix>
  to: { kind: Service, name: <service-name> }
  port: { targetPort: http }
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

```bash
oc apply -f manifests/route-tls-certmanager.yaml
# or annotate an existing route:
oc annotate route <route-name> -n <namespace> \
  cert-manager.io/issuer-name=lab-ca-issuer \
  cert-manager.io/issuer-kind=ClusterIssuer \
  cert-manager.io/common-name=<app-hostname> \
  cert-manager.io/duration=2160h cert-manager.io/renew-before=720h
```

Within a minute the controller writes `certificate`, `key`, `caCertificate` into `spec.tls`. **Rotation = automatic** — at `renew-before` it reissues and rewrites the route. Repeat the annotation on any app's route.

#### A.5 Pull the CA for client trust

```bash
oc get secret lab-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-ca.crt
```

#### A.6 Verify the loop

```bash
oc get certificate,certificaterequest -A | grep -i <app>
oc get route <route-name> -n <namespace> -o jsonpath='{.spec.tls.certificate}' \
  | openssl x509 -noout -subject -dates -issuer
```

---

### Option B — openssl script + cron (zero installs)

`scripts/rotate-cert.sh` — generic for any edge route. It: (1) asks the live endpoint for its cert's `enddate`, (2) exits if > `DAYS_LEFT_MIN` days remain, (3) otherwise regenerates key+CSR, signs with the lab CA, and `oc patch`es the route.

```bash
chmod +x scripts/rotate-cert.sh

# Configure via env — defaults match Jenkins:
export HOST=<app-hostname> NS=<namespace> ROUTE=<route-name> \
       CERTDIR=~/ocp-certs CNF=~/ocp-certs/app.cnf

# Test — should report "nothing to do" on a fresh cert
./scripts/rotate-cert.sh

# Force-test the rotation path once:
DAYS_LEFT_MIN=400 ./scripts/rotate-cert.sh
```

#### B.1 Schedule it — host cron

```cron
# crontab -e — weekly check, rotates when <30d remain
0 3 * * 0 HOST=<app-hostname> NS=<ns> ROUTE=<route> CERTDIR=/home/centos/ocp-certs /home/centos/ocp-certs/rotate-cert.sh >> /home/centos/cert-rotate.log 2>&1
```

The cron environment needs a **non-interactive credential**. `oc login` sessions expire — use a dedicated SA (see `manifests/cert-rotator-rbac.yaml`, least-privilege: patch only this one route):

```bash
oc apply -f manifests/cert-rotator-rbac.yaml
TOKEN=$(oc create token cert-rotator -n <namespace> --duration=8760h)
# Then in the script env or a sourced file:
#   KUBECONFIG=/path/to/kubeconfig  OR  oc login --token=$TOKEN --server=https://api.lab.ocp.local:6443
```

#### B.2 Alternative — in-cluster CronJob (survives host reboots)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: route-cert-rotator
  namespace: <namespace>
spec:
  schedule: "0 3 * * 0"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: cert-rotator          # from cert-rotator-rbac.yaml
          containers:
          - name: rotate
            image: quay.io/openshift/origin-cli:latest
            env:
            - name: HOST
              value: <app-hostname>
            - name: ROUTE
              value: <route-name>
            - name: NS
              value: <namespace>
            command: ["/bin/bash","-c"]
            args:
            - |
              set -e
              # CA material mounted from a secret you maintain
              cd /certs
              # ...same logic as rotate-cert.sh (openssl present in origin-cli)
              # or simply re-sign unconditionally:
              openssl req -new -key app.key -out app.csr -config app.cnf
              openssl x509 -req -in app.csr -CA lab-ca.crt -CAkey lab-ca.key \
                -CAcreateserial -out app.crt -days 365 -sha256 \
                -extensions v3_req -extfile app.cnf
              oc patch route "$ROUTE" -n "$NS" --type=merge -p "$(cat /patch/template.json)"
            volumeMounts:
            - { name: certs, mountPath: /certs }
          volumes:
          - name: certs
            secret: { secretName: lab-ca-material }   # lab-ca.crt, lab-ca.key, app.cnf, app.key
          restartPolicy: OnFailure
```

> Storing the CA private key in-cluster is the trade-off here — acceptable in a lab, questionable elsewhere. Option A keeps the CA key inside a cert-manager secret under the same model.

---

## Part 5 — Verification

```bash
# What cert is actually being served?
openssl s_client -connect <app-hostname>:443 -servername <app-hostname> \
  -CAfile lab-ca.crt < /dev/null | openssl x509 -noout -subject -issuer -dates

# What cert is on the route object?
oc get route <route-name> -n <namespace> -o jsonpath='{.spec.tls.certificate}' \
  | openssl x509 -noout -subject -dates

# End-to-end
curl --cacert lab-ca.crt -I https://<app-hostname>/<path>      # 200/302, no cert error
curl -I http://<app-hostname>/<path>                            # 302 → https (Redirect policy)

# Jenkins specifically
curl --cacert lab-ca.crt -s https://jenkins-jenkins.apps.lab.ocp.local/jenkins/login | grep -i jenkins
```

---

## Part 6 — Databases & non-HTTP services

Routes can carry non-HTTP TLS via SNI. For Postgres/MySQL/Redis-style traffic:

### 6.1 Passthrough route — DB does its own TLS

```bash
oc create route passthrough <db-route> \
  --service=<db-service> --hostname=<db-hostname> -n <namespace>
```

- Cert+key live in a **Secret mounted by the DB pod** — the route carries no key material.
- DB config: `ssl = on`, `ssl_cert_file`, `ssl_key_file` (Postgres); `require_secure_transport`, `ssl-cert`, `ssl-key` (MySQL); `tls-port`, `tls-cert-file` (Redis).
- Clients connect with `sslmode=verify-full` + `sslrootcert=lab-ca.crt`.

### 6.2 Generate the serving cert — service CA (auto-rotating, free)

OpenShift's **service-ca-operator** mints certs for internal services and **rotates them automatically** (~26-month lifetime, renewed and the Secret rewritten in place):

```bash
oc annotate service <db-service> -n <namespace> \
  service.beta.openshift.io/serving-cert-secret-name=<db-tls-secret>
```

The secret appears with `tls.crt`/`tls.key` signed by the cluster's service CA. Mount it into the DB pod:

```yaml
volumeMounts:
- { name: tls, mountPath: /etc/db-tls, readOnly: true }
volumes:
- name: tls
  secret: { secretName: <db-tls-secret> }
```

In-cluster clients trust it via the injected bundle (`service.beta.openshift.io/inject-cabundle: "true"` on a ConfigMap, or the service CA is already in every pod's `/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`).

> **Rotation caveat**: the operator rewrites the secret automatically, but the DB pod must **reload or restart** to pick it up — databases don't watch files. Pair with `oc rollout restart` on a schedule, or reloader-style annotation.

### 6.3 External clients on passthrough

The service CA cert won't be trusted by external clients — either (a) distribute the service CA bundle, or (b) sign the DB's serving cert with `lab-ca` (Part 1 flow, `extendedKeyUsage = serverAuth`) and rotate with the Option-B script pattern pointed at the Secret instead of a Route:

```bash
oc create secret tls <db-tls-secret> --cert=app.crt --key=app.key \
  -n <namespace> --dry-run=client -o yaml | oc apply -f -
oc rollout restart deploy/<db-deployment> -n <namespace>
```

### 6.4 Which model for which workload

| Workload | Recommended | Rotation owner |
|---|---|---|
| Web UI / REST API (Jenkins, ArgoCD, apps) | `edge` route + Option A | cert-manager, fully automatic |
| Internal svc↔svc TLS | service-CA annotation | service-ca-operator, automatic (pod reload needed) |
| DB exposed outside cluster | `passthrough` + lab-CA cert in secret | Option-B script (secret + rollout restart) |
| Mandatory encryption to pod | `reencrypt` route | edge cert via Option A; pod cert via service CA |

---

## Part 7 — Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `ERR_CERT_COMMON_NAME_INVALID` | SAN missing the hostname | `openssl x509 -in app.crt -noout -ext subjectAltName` — reissue with correct `[alt_names]` |
| `certificate signed by unknown authority` | Client doesn't trust `lab-ca.crt` | Part 3 — install CA into client trust store |
| Cert on route ≠ cert served | Router hasn't reloaded / stale route | `oc get route` vs `openssl s_client`; restart router pods `oc -n openshift-ingress delete pod -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default` |
| 503 / app unreachable after TLS | Wrong targetPort or health check path | `oc describe route`; for Jenkins the probe path is `/jenkins/login` not `/` |
| Jenkins "reverse proxy setup is broken" | Jenkins URL still `http://` | Manage Jenkins → System → Jenkins URL → `https://...` |
| Redirect loop http↔https | Proxy headers missing | Ensure `insecureEdgeTerminationPolicy: Redirect`; external LB must pass `X-Forwarded-Proto` |
| cert-manager Certificate stuck | Issuer not ready / bad commonName | `oc describe certificate <name>` and `oc describe certificaterequest` — events name the failure |
| openshift-routes not injecting | Controller down or annotation typo | `oc get pods -n cert-manager`; annotation is `cert-manager.io/issuer-name` exactly |
| Script can't patch route | Expired `oc` token in cron | Use SA token (`cert-rotator-rbac.yaml`), not interactive login |

---

## Part 8 — Appendix

### Wildcard instead of per-app certs

One cert for `*.apps.lab.ocp.local` covers every route — fewer certs, same trust. Set `DNS.1 = *.apps.lab.ocp.local` in `app.cnf`, then reuse `app.crt`/`app.key` on every route. Trade-off: one compromised key = every app impersonable; cert-manager's per-route automation (Option A) makes per-app certs nearly free anyway.

### External HAProxy TLS frontend (svc-infra)

For traffic that enters via the external HAProxy rather than the OpenShift router directly — `manifests/jenkins-https-frontend.cfg`:

```bash
cat app.crt app.key | sudo tee /etc/haproxy/certs/app.pem && sudo chmod 600 /etc/haproxy/certs/app.pem
sudo systemctl reload haproxy
```

On rotation, rebuild the PEM and `reload` — HAProxy reloads certs without dropping connections. The same `rotate-cert.sh` can be extended with those two lines for the HAProxy path.

### Reencrypt deep-dive (if required later)

`termination: reencrypt` needs the **pod** to serve TLS: annotate the service with `service.beta.openshift.io/serving-cert-secret-name`, mount that secret, configure the app for HTTPS, then set `destinationCACertificate` on the route to the service CA bundle. Edge cert still managed per Parts 2/4. Rarely needed in a lab — prefer `edge` + NetworkPolicy.

---

## Decision Recap

```
Is this a .local/internal domain?
└─ yes → private CA required → Part 1 (one-time, 10y root)

HTTP app on a Route?
└─ edge termination → Part 2
   ├─ want zero-touch rotation → Option A (cert-manager + openshift-routes)
   └─ minimal deps            → Option B (rotate-cert.sh + cron)

DB / non-HTTP?
└─ passthrough → cert in Secret → service-CA (internal) or lab-CA + script (external)
```
