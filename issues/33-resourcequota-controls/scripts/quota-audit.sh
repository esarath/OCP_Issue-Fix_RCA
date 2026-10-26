#!/usr/bin/env bash
# quota-audit.sh — read-only ResourceQuota usage audit.
# Lists every ResourceQuota (and ClusterResourceQuota) with hard vs used per
# resource, flags any resource at >= WARN_THRESHOLD percent.
# Usage: ./quota-audit.sh [warn-threshold-percent]   (default 80)
# Exit 0 = all clear, 1 = at least one resource at/above threshold or error.
set -u

WARN_THRESHOLD="${1:-80}"
WARN_THRESHOLD=$((WARN_THRESHOLD))
FLAGFILE=$(mktemp)
trap 'rm -f "$FLAGFILE"' EXIT

norm() { # normalize cpu (m) and mem/storage (Ki/Mi/Gi) to a plain integer
  local v="$1"
  case "$v" in
    *m)  echo $(( ${v%m} / 1000 )) ;;           # millicpu -> whole cores
    *Gi) echo $(( ${v%Gi} * 1000000000 )) ;;
    *Mi) echo $(( ${v%Mi} * 1000000 )) ;;
    *Ki) echo $(( ${v%Ki} * 1000 )) ;;
    *)   echo "${v:-0}" ;;
  esac
}

print_row() { # res used hard
  local res="$1" used="$2" hard="$3" un hn p
  un=$(norm "$used"); hn=$(norm "$hard")
  if [ "${hn:-0}" -eq 0 ] 2>/dev/null; then p=0; else p=$(( un * 100 / hn )); fi
  if [ "$p" -ge "$WARN_THRESHOLD" ]; then
    echo "  FLAG  $res  used=$used hard=$hard (${p}%)"
    echo flag >> "$FLAGFILE"
  else
    echo "  ok    $res  used=$used hard=$hard (${p}%)"
  fi
}

echo "== ResourceQuota audit (threshold ${WARN_THRESHOLD}%) =="

oc get resourcequota --all-namespaces -o json | jq -c '.items[]' | while read -r q; do
  ns=$(echo "$q" | jq -r '.metadata.namespace')
  name=$(echo "$q" | jq -r '.metadata.name')
  echo "--- ns=$ns quota=$name"
  while IFS=$'\t' read -r res used hard; do
    print_row "$res" "$used" "$hard"
  done < <(echo "$q" | jq -r '
    (.status.hard // {}) as $h |
    (.status.used // {}) as $u |
    ($h | keys[]) as $k | "\($k)\t\($u[$k] // "0")\t\($h[$k])"')
done

echo "== ClusterResourceQuota (OCP multi-project) =="
oc get clusterresourcequota -o json 2>/dev/null | jq -c '.items[]?' | while read -r q; do
  name=$(echo "$q" | jq -r '.metadata.name')
  echo "--- clusterquota=$name"
  while IFS=$'\t' read -r res used hard; do
    print_row "$res" "$used" "$hard"
  done < <(echo "$q" | jq -r '
    (.status.total.hard // .spec.quota.hard // {}) as $h |
    (.status.total.used // {}) as $u |
    ($h | keys[]) as $k | "\($k)\t\($u[$k] // "0")\t\($h[$k])"')
done

if [ -s "$FLAGFILE" ]; then
  echo
  echo "RESULT: $(wc -l < "$FLAGFILE" | tr -d ' ') resource(s) at/above ${WARN_THRESHOLD}% — review needed."
  exit 1
fi
echo
echo "RESULT: all quotas below ${WARN_THRESHOLD}%."
exit 0
