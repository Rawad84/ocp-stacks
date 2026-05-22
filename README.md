# OCP Stacks

A collection of manifest-driven deployment and validation frameworks for OpenShift (OCP 4.x) operator-based stacks.

Each stack is self-contained with its own manifests, scripts, and documentation.

## Stacks

| Stack | Description |
|-------|-------------|
| [quay-operator](./quay-operator/) | Red Hat Quay registry on OCP 4.20 using the Quay Operator and ODF MCG storage |

## Structure

Each stack follows the same layout:

```
<stack-name>/
├── README.md        # Stack-specific documentation
├── manifests/       # Kubernetes/OpenShift resource definitions
└── scripts/         # Deploy, validate, test, and cleanup scripts
```

## Requirements

- OCP 4.x cluster with `cluster-admin`
- `oc` CLI logged in
- Stack-specific requirements listed in each stack's README
