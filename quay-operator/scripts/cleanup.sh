#!/usr/bin/env bash
# Removes all resources created by deploy.sh.
# Does NOT delete the openshift-storage or openshift-operators namespaces
# as those may be shared with other workloads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Cleanup: Quay on OCP ==="
echo "This will delete:"
echo "  - QuayRegistry ${QUAY_REGISTRY_NAME} in ${QUAY_NAMESPACE}"
echo "  - OBC ${OBC_NAME} in ${QUAY_NAMESPACE}"
echo "  - NooBaa ${NOOBAA_NAME} in ${ODF_NAMESPACE}"
echo "  - ODF Subscription and OperatorGroup in ${ODF_NAMESPACE}"
echo "  - Quay Subscription in openshift-operators"
echo "  - Namespace ${QUAY_NAMESPACE}"
echo
read -r -p "Confirm cleanup? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

log() { echo "[$(date +%T)] $*"; }

# QuayRegistry (operator will clean up owned resources)
log "Deleting QuayRegistry..."
oc delete quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}" --ignore-not-found

# OBC (NooBaa reclaims the bucket)
log "Deleting ObjectBucketClaim..."
oc delete obc "${OBC_NAME}" -n "${QUAY_NAMESPACE}" --ignore-not-found

# NooBaa — admission webhook blocks deletion unless removed first.
log "Deleting NooBaa webhook and NooBaa..."
oc delete validatingwebhookconfiguration \
  "$(oc get validatingwebhookconfiguration 2>/dev/null | awk '/noobaa/{print $1}')" \
  --ignore-not-found 2>/dev/null || true
oc delete noobaa "${NOOBAA_NAME}" -n "${ODF_NAMESPACE}" --ignore-not-found

# StorageCluster
log "Deleting StorageCluster..."
oc delete storagecluster ocs-storagecluster -n "${ODF_NAMESPACE}" --ignore-not-found

# ODF operator
log "Deleting ODF Subscription and OperatorGroup..."
oc delete subscription odf-operator -n "${ODF_NAMESPACE}" --ignore-not-found
oc delete operatorgroup openshift-storage-operatorgroup -n "${ODF_NAMESPACE}" --ignore-not-found
oc delete csv -n "${ODF_NAMESPACE}" \
  "$(oc get csv -n "${ODF_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" \
  --ignore-not-found 2>/dev/null || true

# Quay operator
log "Deleting Quay Subscription..."
oc delete subscription quay-operator -n openshift-operators --ignore-not-found
oc delete csv -n openshift-operators \
  "$(oc get csv -n openshift-operators \
     -o jsonpath='{.items[?(@.spec.displayName=="Red Hat Quay")].metadata.name}' 2>/dev/null || true)" \
  --ignore-not-found 2>/dev/null || true

# Namespace (deletes all remaining resources)
log "Deleting namespace ${QUAY_NAMESPACE}..."
oc delete namespace "${QUAY_NAMESPACE}" --ignore-not-found

log "Cleanup complete."
