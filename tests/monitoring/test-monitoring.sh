#!/usr/bin/env bash
# Monitoring tests: Prometheus metrics scraping, alert rules loaded, dashboards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )); }
fail() { echo "  [FAIL] $*"; (( FAIL++ )); }
skip() { echo "  [SKIP] $*"; }

echo "=== Monitoring Tests ==="
echo

# ServiceMonitor exists
echo "--- ServiceMonitor ---"
sm_count=$(oc get servicemonitor -n "${QUAY_NAMESPACE}" 2>/dev/null | grep -c quay || true)
[[ "${sm_count}" -ge 1 ]] \
  && pass "ServiceMonitor(s) found: ${sm_count}" || fail "No ServiceMonitors in ${QUAY_NAMESPACE}"

# PrometheusRule exists
echo "--- PrometheusRule ---"
pr_count=$(oc get prometheusrule -n "${QUAY_NAMESPACE}" 2>/dev/null | grep -c quay || true)
[[ "${pr_count}" -ge 1 ]] \
  && pass "PrometheusRule(s) found: ${pr_count}" || fail "No PrometheusRules in ${QUAY_NAMESPACE}"

# Check that cluster monitoring can reach the quay-enterprise namespace
echo "--- openshift-monitoring namespace label ---"
ns_label=$(oc get namespace "${QUAY_NAMESPACE}" \
  -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null || true)
# Not required for user workload monitoring path, but good to note
[[ "${ns_label}" == "true" ]] \
  && pass "Namespace has cluster-monitoring label" \
  || skip "Namespace does not have openshift.io/cluster-monitoring=true (user workload monitoring may be used instead)"

# User workload monitoring enabled
echo "--- User workload monitoring ---"
uwm_enabled=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c "enableUserWorkload: true" || true)
[[ "${uwm_enabled}" -ge 1 ]] \
  && pass "User workload monitoring enabled" \
  || fail "User workload monitoring not enabled — enable it to scrape ${QUAY_NAMESPACE}"

# Verify at least one Quay metric is queryable via Thanos querier
echo "--- Prometheus metric query ---"
thanos_route=$(oc get route -n openshift-monitoring \
  -l app.kubernetes.io/name=thanos-querier \
  -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)

if [[ -n "${thanos_route}" ]]; then
  token=$(oc create token prometheus-k8s -n openshift-monitoring --duration=60s 2>/dev/null || true)
  if [[ -n "${token}" ]]; then
    metric_count=$(curl -sk -H "Authorization: Bearer ${token}" \
      "https://${thanos_route}/api/v1/query?query=up{namespace=\"${QUAY_NAMESPACE}\"}" \
      | jq '.data.result | length' 2>/dev/null || echo 0)
    [[ "${metric_count}" -gt 0 ]] \
      && pass "Thanos returns ${metric_count} up{} series for ${QUAY_NAMESPACE}" \
      || fail "No up{} metrics found for ${QUAY_NAMESPACE} in Thanos"
  else
    skip "Could not create prometheus-k8s token"
  fi
else
  skip "Thanos querier route not found"
fi

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
