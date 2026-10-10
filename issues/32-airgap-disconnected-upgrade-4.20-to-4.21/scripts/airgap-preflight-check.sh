#!/bin/bash
# Air-gapped upgrade PRE-FLIGHT gate — the checks that must PASS before the
# change window opens for a disconnected OCP upgrade.
# Complements the general upgrade checks in
# issues/13-.../scripts/pre-upgrade-check.sh (clusterVersion, MCP, etcd, PDBs).
# This script adds the airgap-only side: mirror registry, CA trust, IDMS/ITMS,
# release image pullability through the mirror.
#
# Usage:  bash airgap-preflight-check.sh <mirror-host:port> [release-image-ref]
# Example: bash airgap-preflight-check.sh mirror.bank.local:8443 \
#            mirror.bank.local:8443/openshift-release-dev/ocp-release@sha256:abc...
set -uo pipefail

MIRROR="${1:?usage: $0 <mirror-host:port> [release-image-ref]}"
RELEASE_REF="${2:-}"
PASS=0; FAIL=0; WARN=0
green()  { echo -e "\033[32m[PASS]\033[0m $*"; ((PASS++)); }
red()    { echo -e "\033[31m[FAIL]\033[0m $*"; ((FAIL++)); }
yellow() { echo -e "\033[33m[WARN]\033[0m $*"; ((WARN++)); }
header() { echo -e "\n\033[1m>>> $* \033[0m"; }

header "1. MIRROR REGISTRY REACHABILITY (from this bastion)"
if curl -sk --connect-timeout 5 "https://${MIRROR}/v2/_catalog" -o /dev/null; then
    green "https://${MIRROR}/v2/ responds"
else
    red "Cannot reach https://${MIRROR}/v2/ — registry down or DNS/firewall issue"
fi

header "2. CLUSTER CA TRUST FOR THE MIRROR"
TRUST=$(oc get image.config.openshift.io/cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2>/dev/null)
if [ -n "$TRUST" ]; then
    green "additionalTrustedCA configured (configmap: $TRUST) — verify it contains ${MIRROR}'s CA"
    oc get configmap "$TRUST" -n openshift-config -o jsonpath='{.data}' 2>/dev/null | grep -q "${MIRROR}" \
        && green "  ...and it names ${MIRROR}" \
        || yellow "  ...CA bundle does not name ${MIRROR} — check the configmap keys match host[:port]"
else
    yellow "No additionalTrustedCA set — only OK if mirror uses a public/internal-CA cert already trusted"
fi

header "3. MIRROR MAPPINGS (IDMS / ITMS)"
IDMS=$(oc get imagedigestmirrorset --no-headers 2>/dev/null | wc -l)
ITMS=$(oc get imagetagmirrorset --no-headers 2>/dev/null | wc -l)
if [ "$IDMS" -gt 0 ] || [ "$ITMS" -gt 0 ]; then
    green "Found $IDMS ImageDigestMirrorSet(s), $ITMS ImageTagMirrorSet(s)"
    oc get imagedigestmirrorset,imagetagmirrorset -o json 2>/dev/null | grep -q "$MIRROR" \
        && green "  ...and they reference ${MIRROR}" \
        || red "  ...but none reference ${MIRROR} — mirror redirects point elsewhere!"
else
    red "No IDMS/ITMS objects — quay.io pulls will NOT be redirected to the mirror"
fi

header "4. MCP / NODE STATE (no rollout in flight)"
MCPS=$(oc get mcp --no-headers 2>/dev/null | awk '$4=="True" || $5=="True"')
if [ -z "$MCPS" ]; then green "All MCPs quiet (not updating/degraded)"; else
    red "MCP(s) mid-rollout or degraded — wait before upgrading:"; echo "$MCPS"; fi
NOTREADY=$(oc get nodes --no-headers 2>/dev/null | awk '$2!="Ready"')
if [ -z "$NOTREADY" ]; then green "All nodes Ready"; else
    red "Node(s) not Ready:"; echo "$NOTREADY"; fi

header "5. OPERATOR / CLUSTER HEALTH"
BADCO=$(oc get co --no-headers 2>/dev/null | awk '$3!="True" || $4!="False" || $5!="False"')
if [ -z "$BADCO" ]; then green "All ClusterOperators healthy"; else
    red "ClusterOperator(s) not healthy:"; echo "$BADCO"; fi

header "6. RELEASE IMAGE ON MIRROR"
if [ -n "$RELEASE_REF" ]; then
    if oc image info "$RELEASE_REF" -o json >/dev/null 2>&1; then
        green "Release image resolvable on mirror: $RELEASE_REF"
    else
        red "Cannot resolve $RELEASE_REF — image not mirrored yet, or auth missing"
    fi
else
    yellow "No release-image-ref given — skipping pullability check (pass it as arg 2)"
fi

header "7. RELEASE SIGNATURE CONFIGMAP"
SIGCMS=$(oc get configmap -n openshift-config-managed --no-headers 2>/dev/null | grep -c release-signatures || true)
if [ "$SIGCMS" -gt 0 ]; then
    green "Found $SIGCMS release-signature ConfigMap(s) in openshift-config-managed"
    yellow "  ...verify the one for THIS upgrade's digest exists: apply signature-configmap-*.yaml from the latest oc-mirror output"
else
    red "No release-signature ConfigMaps — CVO will reject the payload ('no valid signature')"
fi

echo
echo "======== SUMMARY: $PASS PASS | $WARN WARN | $FAIL FAIL ========"
[ "$FAIL" -eq 0 ] && echo "Gate result: OK to proceed (review WARNs)" || echo "Gate result: STOP — fix FAIL items first"
exit "$FAIL"
