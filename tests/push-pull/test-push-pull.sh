#!/usr/bin/env bash
# Extended push/pull tests: multiple tags, skopeo copy, image deletion.
# Run after deploy.sh completes and a repository exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )); }
fail() { echo "  [FAIL] $*"; (( FAIL++ )); }

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
  -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
  -o jsonpath='{.items[0].spec.host}')
REPO="${QUAY_ROUTE}/${QUAY_SUPERUSER_USERNAME}/functional-test"

echo "=== Extended Push/Pull Tests ==="
echo "Target repo: ${REPO}"
echo

# Push two distinct tags
for tag in v1.0 v1.1 latest; do
  echo "--- Push tag: ${tag} ---"
  podman tag "registry.access.redhat.com/ubi9/ubi-micro:latest" "${REPO}:${tag}" 2>/dev/null || true
  if podman push "${REPO}:${tag}" --tls-verify=false 2>&1; then
    pass "Pushed ${tag}"
  else
    fail "Failed to push ${tag}"
  fi
done

# Verify all tags are present via API
echo "--- Tag listing via API ---"
tags=$(curl -sk -u "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
  "https://${QUAY_ROUTE}/api/v1/repository/${QUAY_SUPERUSER_USERNAME}/functional-test/tag/" \
  | jq -r '.tags[].name' 2>/dev/null | sort || true)
for tag in v1.0 v1.1 latest; do
  echo "${tags}" | grep -q "^${tag}$" \
    && pass "Tag ${tag} listed in API" || fail "Tag ${tag} not found in API response"
done

# skopeo inspect
echo "--- skopeo inspect ---"
if command -v skopeo &>/dev/null; then
  if skopeo inspect --tls-verify=false \
       --creds "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
       "docker://${REPO}:latest" &>/dev/null; then
    pass "skopeo inspect succeeded"
  else
    fail "skopeo inspect failed"
  fi
else
  echo "  [SKIP] skopeo not available"
fi

# Delete a tag via API
echo "--- Tag deletion ---"
del_code=$(curl -sk -o /dev/null -w "%{http_code}" -X DELETE \
  -u "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
  "https://${QUAY_ROUTE}/api/v1/repository/${QUAY_SUPERUSER_USERNAME}/functional-test/tag/v1.0")
[[ "${del_code}" == "204" ]] \
  && pass "Tag v1.0 deleted (204)" || fail "Tag deletion returned ${del_code}"

# Cleanup
podman rmi "${REPO}:v1.1" "${REPO}:latest" --force 2>/dev/null || true

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
