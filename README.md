# Quay on OpenShift

Deploys Red Hat Quay on OCP 4.20 using the Quay Operator and ODF MCG for object storage.

## Prerequisites

- OCP 4.20 cluster with `cluster-admin`
- `oc` CLI logged in
- `podman` installed

## Configuration

Edit `scripts/env.sh` before running any script. Key values to update:

| Variable | Description |
|----------|-------------|
| `STORAGE_CLASS` | StorageClass for NooBaa PVCs. Run `oc get storageclass` to list available classes. Common values: `gp3-csi` (AWS), `thin-csi` (vSphere) |
| `QUAY_SUPERUSER_PASSWORD` | Password for the initial Quay admin account. Change from the default before deploying |
| `QUAY_SUPERUSER_USERNAME` | Quay admin username. Default is `quayadmin` |
| `QUAY_SUPERUSER_EMAIL` | Email address for the admin account |

All other values (namespace names, registry name, timeouts) can be left as defaults for a standard deployment.

## Internal vs External S3

This deployment uses ODF NooBaa as the blob storage backend for Quay. There are two ways to configure how Quay references that storage:

**Internal S3** (`scripts/internal/`)
- Quay uses the internal cluster DNS hostname (`s3.openshift-storage.svc`) to talk to NooBaa
- Push from outside the cluster works fine — Quay writes the blob internally
- Pull from outside the cluster fails — when a client pulls an image, Quay redirects it to fetch the blob directly from NooBaa using the internal hostname, which is not resolvable outside the cluster
- Pull works fine from inside the cluster (e.g. OpenShift pods, `oc debug` nodes) since they can resolve internal DNS

**External S3** (`scripts/external/`)
- Quay uses the external NooBaa S3 route (`s3-openshift-storage.apps.*`) so blob redirect URLs are resolvable from anywhere
- Both push and pull work from outside the cluster
- Requires the cluster router CA cert to be injected into the Quay config bundle so Quay trusts the external route's TLS certificate. This is handled automatically by the deploy script

> Use **internal** if your CI/CD and workloads run inside OpenShift.  
> Use **external** if you need to push or pull from a laptop, Jenkins server, or any machine outside the cluster.

## Deploy

Choose the flavor that matches your environment:

```bash
# Sandbox (reduced resources, no Clair)
scripts/internal/deploy-sandbox.sh

# Full scale
scripts/internal/deploy-full-scale.sh

# External S3 variants (push + pull from outside cluster)
scripts/external/deploy-sandbox.sh
scripts/external/deploy-full-scale.sh
```

## Validate & Test

```bash
scripts/validate-sandbox.sh       # or validate-full.sh
scripts/test-auth.sh
scripts/internal/test-push-pull.sh
```

## Cleanup

```bash
scripts/cleanup.sh
```
