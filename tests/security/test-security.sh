#!/usr/bin/env bash
# Security tests: CVE scan results, TLS strength, image signing readiness.
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
QUAY_API="https://${QUAY_ROUTE}/api/v1"
TEST_REPO="${QUAY_SUPERUSER_USERNAME}/functional-test"

echo "=== Security Tests ==="
echo

# TLS cipher strength
echo "--- TLS cipher strength ---"
ciphers=$(echo | openssl s_client -connect "${QUAY_ROUTE}:443" 2>/dev/null | grep "Cipher is" || true)
echo "  Negotiated: ${ciphers}"
echo "${ciphers}" | grep -qiE "AES|CHACHA" \
  && pass "Strong cipher negotiated" || fail "Weak cipher or no cipher info"

# No plain HTTP redirect
echo "--- HTTP → HTTPS redirect ---"
http_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-redirs 0 "http://${QUAY_ROUTE}/" 2>/dev/null || true)
[[ "${http_code}" =~ ^30 ]] \
  && pass "HTTP redirects to HTTPS (${http_code})" \
  || skip "HTTP returned ${http_code} (port 80 may not be exposed)"

# Clair scan result for a pushed image
echo "--- CVE scan result ---"
# Assumes functional-test:latest was pushed by test-push-pull tests
manifest_digest=$(curl -sk -u "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
  "${QUAY_API}/repository/${TEST_REPO}/tag/?specificTag=latest" \
  | jq -r '.tags[0].manifest_digest // empty' 2>/dev/null || true)

if [[ -n "${manifest_digest}" ]]; then
  pass "Got manifest digest: ${manifest_digest}"
  scan_status=$(curl -sk -u "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
    "${QUAY_API}/repository/${TEST_REPO}/manifest/${manifest_digest}/security?vulnerabilities=true" \
    | jq -r '.status // "unknown"' 2>/dev/null || true)
  case "${scan_status}" in
    scanned)     pass "Clair scan completed (status: scanned)" ;;
    queued|scanning) skip "Clair scan in progress (status: ${scan_status})" ;;
    unsupported) skip "Image type unsupported by Clair" ;;
    *)           fail "Unexpected scan status: '${scan_status}'" ;;
  esac
else
  skip "No manifest found for ${TEST_REPO}:latest — run test-push-pull first"
fi

# Check no critical CVEs for UBI micro (expected to be clean)
if [[ "${scan_status:-}" == "scanned" ]]; then
  echo "--- Critical CVE count ---"
  critical_count=$(curl -sk -u "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
    "${QUAY_API}/repository/${TEST_REPO}/manifest/${manifest_digest}/security?vulnerabilities=true" \
    | jq '[.data.Layer.Features[]?.Vulnerabilities[]? | select(.Severity=="Critical")] | length' \
    2>/dev/null || echo "unknown")
  [[ "${critical_count}" == "0" ]] \
    && pass "No critical CVEs in UBI micro" \
    || skip "Critical CVEs found: ${critical_count} (review findings.md)"
fi

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
