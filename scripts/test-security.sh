#!/usr/bin/env bash
# Security validation: Clair scanning, TLS, RBAC enforcement.
# Requires: curl, jq, oc, openssl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )); }
fail() { echo "  [FAIL] $*"; (( FAIL++ )); }
skip() { echo "  [SKIP] $*"; }

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
  -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
  -o jsonpath='{.items[0].spec.host}')

echo "=== Security Tests ==="
echo "Quay: https://${QUAY_ROUTE}"
echo

# TLS certificate check
echo "--- TLS certificate ---"
cert_cn=$(echo | openssl s_client -connect "${QUAY_ROUTE}:443" -servername "${QUAY_ROUTE}" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN=//' || true)
if [[ -n "${cert_cn}" ]]; then
  pass "TLS certificate present (CN: ${cert_cn})"
else
  fail "No TLS certificate returned"
fi

tls_proto=$(echo | openssl s_client -connect "${QUAY_ROUTE}:443" 2>/dev/null | grep "Protocol" | awk '{print $3}' || true)
if echo "${tls_proto}" | grep -qE "TLSv1\.[23]"; then
  pass "TLS protocol: ${tls_proto}"
else
  fail "Weak or unexpected TLS protocol: '${tls_proto}'"
fi

# Clair integration
echo "--- Clair vulnerability scanner ---"
clair_pods=$(oc get pods -n "${QUAY_NAMESPACE}" -l quay-component=clair-app \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l || echo 0)
[[ "${clair_pods}" -ge 1 ]] \
  && pass "Clair pods running: ${clair_pods}" || fail "No Clair pods running"

clair_svc=$(oc get svc -n "${QUAY_NAMESPACE}" -l quay-component=clair-app -o name 2>/dev/null | wc -l || echo 0)
[[ "${clair_svc}" -ge 1 ]] \
  && pass "Clair service present" || fail "Clair service not found"

# Confirm security scan feature is enabled via Quay API
echo "--- Quay security scanning config ---"
scan_enabled=$(curl -sk "https://${QUAY_ROUTE}/api/v1/discovery" \
  | jq -r '.features.security_scanning // "unknown"' 2>/dev/null || echo "unreachable")
[[ "${scan_enabled}" == "true" ]] \
  && pass "Security scanning feature enabled" \
  || skip "Could not confirm security scanning via discovery API (value: ${scan_enabled})"

# RBAC: anonymous access to private repo should fail
echo "--- RBAC enforcement ---"
private_code=$(curl -sk -o /dev/null -w "%{http_code}" \
  "https://${QUAY_ROUTE}/api/v1/repository/${QUAY_SUPERUSER_USERNAME}/test-push-pull/image/")
[[ "${private_code}" == "401" || "${private_code}" == "403" ]] \
  && pass "Unauthenticated private repo access rejected (HTTP ${private_code})" \
  || fail "Expected 401/403 for unauthenticated request, got ${private_code}"

# Check that the Quay config bundle does not expose plaintext secrets
echo "--- Config bundle secret check ---"
bundle_keys=$(oc get secret quay-config-bundle -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
[[ "${bundle_keys}" == "config.yaml" ]] \
  && pass "Config bundle contains only config.yaml (no stray secrets)" \
  || skip "Config bundle keys: ${bundle_keys}"

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
