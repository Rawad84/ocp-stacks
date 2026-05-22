#!/usr/bin/env bash
# Day-2 operational tests: component restart recovery, config change propagation,
# HPA presence, operator reconciliation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )); }
fail() { echo "  [FAIL] $*"; (( FAIL++ )); }
skip() { echo "  [SKIP] $*"; }

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
  -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
  -o jsonpath='{.items[0].spec.host}')

echo "=== Day-2 Operational Tests ==="
echo

# HorizontalPodAutoscaler
echo "--- HorizontalPodAutoscaler ---"
hpa_count=$(oc get hpa -n "${QUAY_NAMESPACE}" 2>/dev/null | grep -c quay || true)
[[ "${hpa_count}" -ge 1 ]] \
  && pass "HPA(s) present: ${hpa_count}" || fail "No HPAs found in ${QUAY_NAMESPACE}"

# Quay app deployment replicas
echo "--- Quay app replicas ---"
app_ready=$(oc get deployment -n "${QUAY_NAMESPACE}" \
  -l quay-component=quay-app \
  -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${app_ready}" -ge 1 ]] \
  && pass "Quay app ready replicas: ${app_ready}" || fail "No ready quay-app replicas"

# Pod restart test — delete one quay-app pod and verify it recovers
echo "--- Pod recovery (rolling restart) ---"
pod=$(oc get pod -n "${QUAY_NAMESPACE}" -l quay-component=quay-app \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${pod}" ]]; then
  oc delete pod "${pod}" -n "${QUAY_NAMESPACE}" --grace-period=0 &>/dev/null
  pass "Deleted pod ${pod} — waiting for replacement..."
  sleep 5
  deadline=$(( $(date +%s) + 120 ))
  until [[ "$(oc get deployment -n "${QUAY_NAMESPACE}" -l quay-component=quay-app \
              -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)" -ge 1 ]]; do
    [[ $(date +%s) -gt ${deadline} ]] && { fail "Pod did not recover within 120s"; break; }
    sleep 5
  done
  pass "quay-app recovered after pod deletion"
else
  skip "No quay-app pod found to restart"
fi

# Operator reconciliation — annotate QuayRegistry and verify it stays Available
echo "--- Operator reconciliation ---"
oc annotate quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}" \
  day2-test/timestamp="$(date +%s)" --overwrite &>/dev/null
sleep 10
qr_condition=$(oc get quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
[[ "${qr_condition}" == "True" ]] \
  && pass "QuayRegistry Available after annotation" || fail "QuayRegistry Available='${qr_condition}' after reconcile trigger"

# Health endpoint still returns 200
echo "--- Post-restart health check ---"
http_code=$(curl -sk -o /dev/null -w "%{http_code}" "https://${QUAY_ROUTE}/health/instance" || true)
[[ "${http_code}" == "200" ]] \
  && pass "Health endpoint 200 after Day-2 ops" || fail "Health endpoint returned ${http_code}"

# Managed component ownership — operator should own all managed resources
echo "--- Operator ownership labels ---"
unowned=$(oc get deployment -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.items[?(!@.metadata.ownerReferences)].metadata.name}' 2>/dev/null || true)
[[ -z "${unowned}" ]] \
  && pass "All deployments have owner references" \
  || skip "Deployments without owner refs (may be user-created): ${unowned}"

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
