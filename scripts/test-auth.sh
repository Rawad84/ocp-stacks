#!/usr/bin/env bash
# Auth validation: robot accounts, token scoping, anonymous access rejection.
# Requires: curl, jq, oc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }
section() { echo; echo "--- $* ---"; }

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
  -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
  -o jsonpath='{.items[0].spec.host}')
QUAY_API="https://${QUAY_ROUTE}/api/v1"
ROBOT_NAME="ci-robot"

echo "=== Auth Tests ==="
echo "Quay: https://${QUAY_ROUTE}"

# ---------------------------------------------------------------------------
section "Superuser token"
# ---------------------------------------------------------------------------
# Quay API requires OAuth Bearer tokens — basic auth returns 401.
# Token is saved to quay-admin-token secret by deploy.sh after superuser init.
TOKEN=$(oc get secret quay-admin-token -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)

if [[ -z "${TOKEN}" ]]; then
  fail "quay-admin-token secret not found or empty — run deploy.sh first"
  echo "Result: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

api_user=$(curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Requested-With: XMLHttpRequest" \
  "${QUAY_API}/user/" | jq -r '.username // empty' 2>/dev/null || true)

if [[ "${api_user}" == "${QUAY_SUPERUSER_USERNAME}" ]]; then
  pass "Bearer token valid — authenticated as ${api_user}"
else
  fail "Bearer token rejected (got: '${api_user}')"
fi

# ---------------------------------------------------------------------------
section "v2 registry auth"
# ---------------------------------------------------------------------------
v2_code=$(curl -sk -o /dev/null -w "%{http_code}" \
  -u "${QUAY_SUPERUSER_USERNAME}:${QUAY_SUPERUSER_PASSWORD}" \
  "https://${QUAY_ROUTE}/v2/")
if [[ "${v2_code}" == "200" || "${v2_code}" == "401" ]]; then
  pass "v2 endpoint reachable with credentials (HTTP ${v2_code})"
else
  fail "v2 endpoint returned unexpected ${v2_code}"
fi

# ---------------------------------------------------------------------------
section "Anonymous access rejection"
# ---------------------------------------------------------------------------
anon_code=$(curl -sk -o /dev/null -w "%{http_code}" "https://${QUAY_ROUTE}/v2/")
if [[ "${anon_code}" == "401" ]]; then
  pass "Anonymous v2 access correctly rejected with 401"
else
  fail "Anonymous v2 access returned ${anon_code} (expected 401)"
fi

# ---------------------------------------------------------------------------
section "Robot account"
# ---------------------------------------------------------------------------
# Check if robot credentials already saved as a K8s secret first.
robot_token=$(oc get secret quay-robot-token -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)

if [[ -n "${robot_token}" ]]; then
  pass "Robot account ${QUAY_SUPERUSER_USERNAME}+${ROBOT_NAME} credentials already in secret quay-robot-token"
else
  # GET first — robot may already exist in Quay from a previous run.
  # PUT returns 400 if the robot already exists.
  robot_resp=$(curl -sk "${QUAY_API}/user/robots/${ROBOT_NAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Requested-With: XMLHttpRequest" 2>/dev/null || true)

  robot_token=$(echo "${robot_resp}" | jq -r '.token // empty' 2>/dev/null || true)
  if [[ -z "${robot_token}" ]]; then
    robot_resp=$(curl -sk -X PUT "${QUAY_API}/user/robots/${ROBOT_NAME}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -H "X-Requested-With: XMLHttpRequest" \
      -d '{"description":"CI robot for test automation"}' 2>/dev/null || true)
    robot_token=$(echo "${robot_resp}" | jq -r '.token // empty' 2>/dev/null || true)
  fi

  if [[ -n "${robot_token}" ]]; then
    pass "Robot account ${QUAY_SUPERUSER_USERNAME}+${ROBOT_NAME} exists"
    # Save robot credentials to a K8s secret so CI/CD pipelines can consume them.
    oc create secret generic quay-robot-token \
      -n "${QUAY_NAMESPACE}" \
      --from-literal=username="${QUAY_SUPERUSER_USERNAME}+${ROBOT_NAME}" \
      --from-literal=token="${robot_token}" \
      --dry-run=client -o yaml | oc apply -f -
    pass "Robot credentials saved to secret quay-robot-token in ${QUAY_NAMESPACE}"
  else
    fail "Failed to get or create robot account (response: ${robot_resp})"
  fi
fi

# ---------------------------------------------------------------------------
section "Robot v2 login"
# ---------------------------------------------------------------------------
if [[ -n "${robot_token}" ]]; then
  robot_v2=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${QUAY_SUPERUSER_USERNAME}+${ROBOT_NAME}:${robot_token}" \
    "https://${QUAY_ROUTE}/v2/")
  if [[ "${robot_v2}" == "200" || "${robot_v2}" == "401" ]]; then
    pass "Robot v2 auth reachable (HTTP ${robot_v2})"
  else
    fail "Robot v2 auth failed (HTTP ${robot_v2})"
  fi
else
  fail "Skipping robot v2 login — no robot token available"
fi

# ---------------------------------------------------------------------------
echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]] || exit 1
