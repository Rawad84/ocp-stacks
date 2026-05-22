#!/usr/bin/env bash
# External-access deployment variant.
# Identical to deploy.sh except Step 5 uses the external NooBaa S3 route so that
# Quay's blob redirect URLs are resolvable from outside the cluster.
# The cluster router CA cert is injected into the config bundle so Quay trusts
# the external route's TLS certificate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/env.sh
source "${SCRIPT_DIR}/../env.sh"

export KUBECONFIG="${KUBECONFIG:-/root/ocp-aws-ipi/install-output/auth/kubeconfig}"

LOG_FILE="${REPO_ROOT}/deploy-full-scale-external-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "Log file: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date +%T)] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
skip() { echo "[$(date +%T)] [SKIP] $*"; }

wait_for_csv() {
  local ns="$1" pkg="$2"
  log "Waiting for CSV matching '${pkg}' in ${ns} to succeed..."
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until oc get csv -n "${ns}" \
        -o jsonpath='{range .items[*]}{.spec.displayName}{" "}{.status.phase}{"\n"}{end}' \
        2>/dev/null | grep -i "${pkg}" | grep -q "Succeeded"; do
    [[ $(date +%s) -gt ${deadline} ]] && die "Timed out waiting for '${pkg}' CSV in ${ns}"
    sleep 10
  done
  log "'${pkg}' CSV succeeded."
}

wait_for_condition() {
  local resource="$1" ns="$2" condition="$3"
  log "Waiting for ${resource} condition: ${condition}..."
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until oc wait "${resource}" -n "${ns}" --for="${condition}" --timeout=10s &>/dev/null; do
    [[ $(date +%s) -gt ${deadline} ]] && die "Timed out waiting for ${resource}"
    sleep 10
  done
}

csv_succeeded() {
  local ns="$1" pkg="$2"
  oc get csv -n "${ns}" \
    -o jsonpath='{range .items[*]}{.spec.displayName}{" "}{.status.phase}{"\n"}{end}' \
    2>/dev/null | grep -i "${pkg}" | grep -q "Succeeded"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

[[ -z "${STORAGE_CLASS}" ]] && die "STORAGE_CLASS is not set. Edit scripts/env.sh or export STORAGE_CLASS=<name>."
oc whoami &>/dev/null    || die "Not logged into an OpenShift cluster. Run: oc login ..."
oc auth can-i '*' '*' --all-namespaces &>/dev/null || die "cluster-admin privileges required."

log "=== Starting Quay on OCP 4.20 deployment (external-access mode) ==="
log "Cluster: $(oc whoami --show-server)"
log "Storage class: ${STORAGE_CLASS}"

# ---------------------------------------------------------------------------
# Step 1 — Namespaces
# ---------------------------------------------------------------------------

log "--- Step 1: Namespaces ---"
oc apply -f "${REPO_ROOT}/manifests/00-namespace/"

# ---------------------------------------------------------------------------
# Step 2 — ODF Operator (MCG-only)
# ---------------------------------------------------------------------------

log "--- Step 2: ODF Operator ---"
if csv_succeeded "${ODF_NAMESPACE}" "OpenShift Data Foundation"; then
  skip "ODF CSV already Succeeded — skipping subscription apply and wait"
else
  oc apply -f "${REPO_ROOT}/manifests/01-operator/odf-operatorgroup.yaml"
  oc apply -f "${REPO_ROOT}/manifests/01-operator/odf-subscription.yaml"
  wait_for_csv "${ODF_NAMESPACE}" "OpenShift Data Foundation"
fi

# ---------------------------------------------------------------------------
# Step 3 — Activate NooBaa / MCG via StorageCluster
# ---------------------------------------------------------------------------

log "--- Step 3: StorageCluster (MCG-only) ---"
noobaa_phase=$(oc get noobaa "${NOOBAA_NAME}" -n "${ODF_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [[ "${noobaa_phase}" == "Ready" ]]; then
  skip "NooBaa already Ready — skipping StorageCluster apply and wait"
else
  oc apply -f "${REPO_ROOT}/manifests/03-storage/storagecluster-mcg.yaml"

  log "Waiting for noobaa-operator deployment to scale up (ODF activating MCG)..."
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until [[ "$(oc get deployment noobaa-operator -n "${ODF_NAMESPACE}" \
             -o jsonpath='{.spec.replicas}' 2>/dev/null)" -ge "1" ]]; do
    [[ $(date +%s) -gt ${deadline} ]] && die "Timed out waiting for noobaa-operator to scale up"
    sleep 10
  done
  log "noobaa-operator scaled up. Waiting for NooBaa to reach Ready phase (3-5 minutes)..."

  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until [[ "$(oc get noobaa "${NOOBAA_NAME}" -n "${ODF_NAMESPACE}" \
             -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; do
    [[ $(date +%s) -gt ${deadline} ]] && die "Timed out waiting for NooBaa Ready"
    sleep 15
  done
  log "NooBaa is Ready."
fi

# ---------------------------------------------------------------------------
# Step 4 — ObjectBucketClaim
# ---------------------------------------------------------------------------

log "--- Step 4: ObjectBucketClaim ---"
obc_phase=$(oc get obc "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [[ "${obc_phase}" == "Bound" ]]; then
  skip "OBC ${OBC_NAME} already Bound — skipping"
else
  oc apply -f "${REPO_ROOT}/manifests/03-storage/objectbucketclaim.yaml"

  log "Waiting for OBC ${OBC_NAME} to be Bound..."
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  until [[ "$(oc get obc "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
             -o jsonpath='{.status.phase}' 2>/dev/null)" == "Bound" ]]; do
    [[ $(date +%s) -gt ${deadline} ]] && die "Timed out waiting for OBC to be Bound"
    sleep 10
  done
  log "OBC is Bound."
fi

# ---------------------------------------------------------------------------
# Step 5 — Build Quay config bundle secret (external-access variant)
# ---------------------------------------------------------------------------
# Uses the external NooBaa S3 route instead of the internal service hostname.
# Injects the cluster router CA so Quay trusts the external route's TLS cert.

log "--- Step 5: Quay config bundle (external) ---"

BUCKET_NAME=$(oc get configmap "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
              -o jsonpath='{.data.BUCKET_NAME}')
NOOBAA_S3_HOST=$(oc get route s3 -n "${ODF_NAMESPACE}" -o jsonpath='{.spec.host}')
NOOBAA_S3_PORT="443"
AWS_ACCESS_KEY_ID=$(oc get secret "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
                    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(oc get secret "${OBC_NAME}" -n "${QUAY_NAMESPACE}" \
                        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

# Fetch the cluster router CA and indent each line by 4 spaces for the YAML literal block.
ROUTER_CA_CERT=$(oc get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | sed 's/^/    /')

export BUCKET_NAME NOOBAA_S3_HOST NOOBAA_S3_PORT \
       AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
       QUAY_SUPERUSER_USERNAME QUAY_SUPERUSER_PASSWORD QUAY_SUPERUSER_EMAIL \
       ROUTER_CA_CERT

log "Bucket: ${BUCKET_NAME} | Host: ${NOOBAA_S3_HOST}:${NOOBAA_S3_PORT}"

envsubst < "${REPO_ROOT}/manifests/02-quay-registry/quay-config-bundle-external-template.yaml" \
  | oc apply -f -

# ---------------------------------------------------------------------------
# Step 6 — Quay Operator
# ---------------------------------------------------------------------------

log "--- Step 6: Quay Operator ---"
if csv_succeeded "openshift-operators" "Red Hat Quay"; then
  skip "Quay CSV already Succeeded — skipping subscription apply and wait"
else
  oc apply -f "${REPO_ROOT}/manifests/01-operator/quay-subscription.yaml"
  wait_for_csv "openshift-operators" "Red Hat Quay"
fi

# ---------------------------------------------------------------------------
# Step 7 — QuayRegistry
# ---------------------------------------------------------------------------

log "--- Step 7: QuayRegistry ---"
qr_condition=$(oc get quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)

if [[ "${qr_condition}" == "True" ]]; then
  skip "QuayRegistry already Available — skipping apply and wait"
else
  oc apply -f "${REPO_ROOT}/manifests/02-quay-registry/quay-registry.yaml"

  log "Waiting for QuayRegistry to reach Ready condition (5-10 minutes)..."
  wait_for_condition \
    "quayregistry/${QUAY_REGISTRY_NAME}" \
    "${QUAY_NAMESPACE}" \
    "condition=Available"
fi

# ---------------------------------------------------------------------------
# Step 8 — RBAC and monitoring manifests
# ---------------------------------------------------------------------------

log "--- Step 8: RBAC ---"
oc apply -f "${REPO_ROOT}/manifests/06-rbac/"

log "--- Step 9: Monitoring ---"
oc apply -f "${REPO_ROOT}/manifests/07-monitoring/"

# ---------------------------------------------------------------------------
# Step 9 — Seed initial superuser
# ---------------------------------------------------------------------------

log "--- Step 9: Seed superuser ---"

QUAY_ROUTE=$(oc get route -n "${QUAY_NAMESPACE}" \
             -l quay-operator/quayregistry="${QUAY_REGISTRY_NAME}" \
             -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
[[ -z "${QUAY_ROUTE}" ]] && die "Could not determine Quay route hostname."
export QUAY_ROUTE

existing_token=$(oc get secret quay-admin-token -n "${QUAY_NAMESPACE}" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)

if [[ -n "${existing_token}" ]]; then
  skip "quay-admin-token secret already exists — skipping superuser init job"
else
  if oc get job quay-init-superuser -n "${QUAY_NAMESPACE}" &>/dev/null; then
    log "Deleting previous quay-init-superuser job..."
    oc delete job quay-init-superuser -n "${QUAY_NAMESPACE}"
  fi

  envsubst < "${REPO_ROOT}/manifests/05-auth/quay-init-config-configmap.yaml" | oc apply -f -
  envsubst < "${REPO_ROOT}/manifests/05-auth/quay-init-credentials-secret.yaml" | oc apply -f -
  oc apply -f "${REPO_ROOT}/manifests/05-auth/quay-init-user-job.yaml"

  log "Waiting for init Job to complete..."
  oc wait job/quay-init-superuser -n "${QUAY_NAMESPACE}" \
     --for=condition=Complete --timeout=120s

  ADMIN_TOKEN=$(oc logs -n "${QUAY_NAMESPACE}" -l job-name=quay-init-superuser \
    2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || true)
  if [[ -n "${ADMIN_TOKEN}" ]]; then
    oc create secret generic quay-admin-token \
      -n "${QUAY_NAMESPACE}" \
      --from-literal=token="${ADMIN_TOKEN}" \
      --dry-run=client -o yaml | oc apply -f -
    log "OAuth token saved to secret quay-admin-token."
  else
    log "Warning: could not extract OAuth token from init job logs."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log ""
log "=== Deployment complete (external-access mode) ==="
log "Quay URL:  https://${QUAY_ROUTE}"
log "Username:  ${QUAY_SUPERUSER_USERNAME}"
log "Password:  (set in scripts/env.sh)"
log "Storage:   ${NOOBAA_S3_HOST}:${NOOBAA_S3_PORT} (external route)"
log ""
log "Run ./scripts/validate.sh to verify the deployment."
