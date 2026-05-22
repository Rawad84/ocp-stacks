#!/usr/bin/env bash
# Storage tests: NooBaa health, OBC binding, bucket object count, PVC status.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )); }
fail() { echo "  [FAIL] $*"; (( FAIL++ )); }

echo "=== Storage Tests ==="
echo

# NooBaa phase
echo "--- NooBaa status ---"
noobaa_phase=$(oc get noobaa "${NOOBAA_NAME}" -n "${ODF_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
[[ "${noobaa_phase}" == "Ready" ]] \
  && pass "NooBaa phase: Ready" || fail "NooBaa phase: '${noobaa_phase}'"

# NooBaa management console accessible
mgmt_svc=$(oc get svc -n "${ODF_NAMESPACE}" -l app=noobaa -o name 2>/dev/null | grep -i mgmt | head -1 || true)
[[ -n "${mgmt_svc}" ]] \
  && pass "NooBaa management service present: ${mgmt_svc}" || fail "NooBaa management service not found"

# OBC phase
echo "--- ObjectBucketClaim ---"
obc_phase=$(oc get obc "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)
[[ "${obc_phase}" == "Bound" ]] \
  && pass "OBC ${OBC_NAME}: Bound" || fail "OBC ${OBC_NAME}: '${obc_phase}'"

# OBC ConfigMap has expected keys
echo "--- OBC ConfigMap keys ---"
for key in BUCKET_NAME BUCKET_HOST BUCKET_PORT; do
  val=$(oc get configmap "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null || true)
  [[ -n "${val}" ]] \
    && pass "OBC ConfigMap key ${key}: ${val}" || fail "OBC ConfigMap missing key ${key}"
done

# OBC Secret has expected keys
echo "--- OBC Secret keys ---"
for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  val=$(oc get secret "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d || true)
  [[ -n "${val}" ]] \
    && pass "OBC Secret key ${key} present" || fail "OBC Secret missing key ${key}"
done

# NooBaa PVCs healthy
echo "--- NooBaa PVCs ---"
pvcs=$(oc get pvc -n "${ODF_NAMESPACE}" -l app=noobaa \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null || true)
echo "${pvcs}" | grep -qvw "Bound" \
  && fail "Some NooBaa PVCs not Bound: ${pvcs}" || pass "All NooBaa PVCs Bound"

# S3 endpoint reachable from within the cluster (run as a pod)
echo "--- S3 endpoint connectivity (in-cluster) ---"
bucket_host=$(oc get configmap "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data.BUCKET_HOST}' 2>/dev/null || true)
bucket_port=$(oc get configmap "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data.BUCKET_PORT}' 2>/dev/null || true)
if [[ -n "${bucket_host}" ]]; then
  s3_code=$(oc run s3-probe --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
    --restart=Never --rm -it --quiet -n "${QUAY_NAMESPACE}" \
    -- curl -sk -o /dev/null -w "%{http_code}" \
    "https://${bucket_host}:${bucket_port}/" 2>/dev/null || echo "unknown")
  [[ "${s3_code}" =~ ^(200|403|400)$ ]] \
    && pass "S3 endpoint reachable in-cluster (HTTP ${s3_code})" \
    || fail "S3 endpoint probe returned ${s3_code}"
else
  fail "Cannot determine bucket host from OBC ConfigMap"
fi

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
