#!/usr/bin/env bash
# Cluster-specific configuration — edit these values before running any script.

# All variables exported so envsubst works correctly when any script
# step is run in isolation (not just as part of the full deploy.sh).

# Namespaces
export QUAY_NAMESPACE="quay-enterprise"
export ODF_NAMESPACE="openshift-storage"

# Quay
export QUAY_REGISTRY_NAME="quay-registry"
export QUAY_SUPERUSER_USERNAME="quayadmin"
export QUAY_SUPERUSER_PASSWORD="changeme123!"   # change before deploying
export QUAY_SUPERUSER_EMAIL="admin@example.com"

# NooBaa / OBC
export NOOBAA_NAME="noobaa"
export OBC_NAME="quay-bucket"

# StorageClass used for NooBaa DB and core PVCs.
# Run: oc get storageclass — to list available classes on your cluster.
export STORAGE_CLASS="gp3-csi"     # e.g. gp3-csi, thin-csi

# Optional: set a custom route hostname. Leave empty to use the operator default.
export QUAY_ROUTE_HOSTNAME=""

# Timeout (seconds) for wait loops
export WAIT_TIMEOUT=600
