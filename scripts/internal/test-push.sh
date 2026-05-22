#!/usr/bin/env bash
# Push-only smoke test — used with internal S3 deployment (deploy.sh).
# Pull from Quay is skipped because Quay redirects blob fetches to the internal
# NooBaa hostname (s3.openshift-storage.svc) which is not resolvable outside the cluster.
# Use test-push-pull-external.sh when deployed with deploy-external.sh.
# Requires: podman, oc, jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
  -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
  -o jsonpath='{.items[0].spec.host}')
TEST_IMAGE="ubi9/ubi-micro:latest"
TARGET_REPO="${QUAY_ROUTE}/${QUAY_SUPERUSER_USERNAME}/test-push-pull"
TARGET_TAG="${TARGET_REPO}:smoke"

echo "=== Push Smoke Test (internal S3) ==="
echo "Quay: https://${QUAY_ROUTE}"
echo "Target: ${TARGET_TAG}"
echo

# Login
echo "--- Login ---"
if podman login "${QUAY_ROUTE}" \
     -u "${QUAY_SUPERUSER_USERNAME}" \
     -p "${QUAY_SUPERUSER_PASSWORD}" \
     --tls-verify=false 2>&1; then
  pass "podman login succeeded"
else
  fail "podman login failed"
  exit 1
fi

# Pull source image
echo "--- Pull source image ---"
if podman pull "registry.access.redhat.com/${TEST_IMAGE}" --tls-verify=false; then
  pass "Pulled source image from registry.access.redhat.com"
else
  fail "Failed to pull source image"
  exit 1
fi

# Tag and push to Quay
echo "--- Push to Quay ---"
podman tag "registry.access.redhat.com/${TEST_IMAGE}" "${TARGET_TAG}"
if podman push "${TARGET_TAG}" --tls-verify=false; then
  pass "Pushed ${TARGET_TAG}"
else
  fail "Push failed"
  exit 1
fi

# Verify image exists via Quay API
echo "--- API verification ---"
TOKEN=$(oc get secret quay-admin-token -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
tag_resp=$(curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Requested-With: XMLHttpRequest" \
  "https://${QUAY_ROUTE}/api/v1/repository/${QUAY_SUPERUSER_USERNAME}/test-push-pull/tag/" \
  | jq -r '.tags[0].name // empty' 2>/dev/null || true)
if [[ "${tag_resp}" == "smoke" ]]; then
  pass "Image tag 'smoke' confirmed via Quay API"
else
  fail "Image tag not found via API (got: '${tag_resp}')"
fi

# Cleanup
echo "--- Cleanup ---"
podman rmi "${TARGET_TAG}" --force 2>/dev/null || true

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
