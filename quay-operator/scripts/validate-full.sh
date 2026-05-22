#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/env.sh
source "${SCRIPT_DIR}/env.sh"

# Optional: pass --sandbox to skip checks that are not applicable in sandbox mode
# (Clair disabled, HPA disabled, reduced replicas).
# Usage: ./validate.sh --sandbox
SANDBOX=false
[[ "${1:-}" == "--sandbox" ]] && SANDBOX=true

PASS=0; FAIL=0; SKIP=0
pass() { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }
skip() { echo "  [SKIP] $*"; SKIP=$(( SKIP + 1 )); }
section() { echo; echo "=== $* ==="; }

echo "Deployment flavor: $( [[ "${SANDBOX}" == "true" ]] && echo "sandbox" || echo "full" )"

# ---------------------------------------------------------------------------
section "Operators"
# ---------------------------------------------------------------------------

odf_phase=$(oc get csv -n "${ODF_NAMESPACE}" \
  -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Data Foundation")].status.phase}' 2>/dev/null || true)
if [[ "${odf_phase}" == "Succeeded" ]]; then
  pass "ODF CSV Succeeded"
else
  fail "ODF CSV not Succeeded (got: '${odf_phase}')"
fi

quay_phase=$(oc get csv -n openshift-operators \
  -o jsonpath='{.items[?(@.spec.displayName=="Red Hat Quay")].status.phase}' 2>/dev/null || true)
if [[ "${quay_phase}" == "Succeeded" ]]; then
  pass "Quay CSV Succeeded"
else
  fail "Quay CSV not Succeeded (got: '${quay_phase}')"
fi

# ---------------------------------------------------------------------------
section "NooBaa / MCG"
# ---------------------------------------------------------------------------

noobaa_phase=$(oc get noobaa "${NOOBAA_NAME}" -n "${ODF_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "${noobaa_phase}" == "Ready" ]]; then
  pass "NooBaa phase: Ready"
else
  fail "NooBaa phase: '${noobaa_phase}' (expected Ready)"
fi

obc_phase=$(oc get obc "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "${obc_phase}" == "Bound" ]]; then
  pass "OBC ${OBC_NAME}: Bound"
else
  fail "OBC ${OBC_NAME}: '${obc_phase}' (expected Bound)"
fi

# ---------------------------------------------------------------------------
section "QuayRegistry"
# ---------------------------------------------------------------------------

qr_condition=$(oc get quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
if [[ "${qr_condition}" == "True" ]]; then
  pass "QuayRegistry Available=True"
else
  fail "QuayRegistry Available='${qr_condition}'"
fi

# Sandbox: quay-app (2) + database (1) + redis (1) = 4 minimum
# Full:    quay-app (2) + database (1) + redis (1) + clair-app (2) + clair-postgres (1) = 7 minimum
min_pods=4
[[ "${SANDBOX}" == "false" ]] && min_pods=7
ready_pods=$(oc get pods -n "${QUAY_NAMESPACE}" --no-headers 2>/dev/null \
  | awk '$3=="Running"' | wc -l)
if [[ "${ready_pods}" -ge "${min_pods}" ]]; then
  pass "Running pods in ${QUAY_NAMESPACE}: ${ready_pods} (min ${min_pods})"
else
  fail "Too few running pods: ${ready_pods} (expected >= ${min_pods})"
fi

# Clair check — skipped in sandbox
if [[ "${SANDBOX}" == "true" ]]; then
  skip "Clair deployment check (disabled in sandbox)"
else
  clair_ready=$(oc get deployment quay-registry-clair-app -n "${QUAY_NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${clair_ready}" -ge 1 ]]; then
    pass "Clair deployment ready (${clair_ready} replicas)"
  else
    fail "Clair deployment has 0 ready replicas"
  fi
fi

# HPA check — skipped in sandbox
if [[ "${SANDBOX}" == "true" ]]; then
  skip "HPA check (disabled in sandbox)"
else
  hpa_count=$(oc get hpa -n "${QUAY_NAMESPACE}" 2>/dev/null | grep -c quay || true)
  if [[ "${hpa_count}" -ge 1 ]]; then
    pass "HPA(s) present: ${hpa_count}"
  else
    fail "No HPAs found in ${QUAY_NAMESPACE}"
  fi
fi

# ---------------------------------------------------------------------------
section "Routes & TLS"
# ---------------------------------------------------------------------------

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
  -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
  -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)

if [[ -n "${QUAY_ROUTE}" ]]; then
  pass "Quay route found: ${QUAY_ROUTE}"
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" "https://${QUAY_ROUTE}/health/instance" || true)
  if [[ "${http_code}" == "200" ]]; then
    pass "Health endpoint returned 200"
  else
    fail "Health endpoint returned ${http_code}"
  fi
else
  fail "No Quay route found"
fi

# ---------------------------------------------------------------------------
section "Config bundle"
# ---------------------------------------------------------------------------

if oc get secret quay-config-bundle -n "${QUAY_NAMESPACE}" &>/dev/null; then
  pass "Config bundle secret exists"
else
  fail "Config bundle secret missing"
fi

# ---------------------------------------------------------------------------
section "Monitoring"
# ---------------------------------------------------------------------------

sm_count=$(oc get servicemonitor -n "${QUAY_NAMESPACE}" 2>/dev/null | grep -c quay || true)
if [[ "${sm_count}" -ge 1 ]]; then
  pass "ServiceMonitor(s) present: ${sm_count}"
else
  fail "No ServiceMonitors found in ${QUAY_NAMESPACE}"
fi

pr_count=$(oc get prometheusrule -n "${QUAY_NAMESPACE}" 2>/dev/null | grep -c quay || true)
if [[ "${pr_count}" -ge 1 ]]; then
  pass "PrometheusRule(s) present: ${pr_count}"
else
  fail "No PrometheusRules found in ${QUAY_NAMESPACE}"
fi

# ---------------------------------------------------------------------------
echo
echo "Result: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[[ "${FAIL}" -eq 0 ]] || exit 1
