# 4.7 Understand CRDs, install and configure operators

## Overview

Kubernetes exposes native cluster capabilities (Pods, Deployments, Services) through a declarative API. **Custom Resource Definitions (CRDs)** extend the API with domain-specific resource types without requiring changes to core API server source code.

An **Operator** is an architectural pattern combining a Custom Resource Definition with a **custom controller** executing a reconciliation control loop to automate domain-specific operational workflows (deployments, backups, high availability failover, schema migrations).

---

## Custom Resource Definitions (CRDs)

### Custom Resources vs CRDs

A **Custom Resource (CR)** is an object instance of an extended API type that behaves like a native Kubernetes object: it supports standard `kubectl` operations (`get`, `describe`, `edit`, `delete`), schema validation, and lifecycle status fields.

A **CustomResourceDefinition (CRD)** is the cluster-scoped API registration resource defining the custom object schema: API group, singular/plural names, short names, OpenAPI v3 validation rules, and scope (`Namespaced` vs `Cluster`).

### Anatomy of a CRD Manifest

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.storage.example.com   # <plural>.<group>
spec:
  group: storage.example.com
  names:
    kind: Backup
    plural: backups
    singular: backup
    shortNames:
      - bkp
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                schedule:
                  type: string
                retentionDays:
                  type: integer
                  minimum: 1
              required: ["schedule"]
            status:
              type: object
              properties:
                lastBackupTime:
                  type: string
      subresources:
        status: {}
```

Key schema fields:
- `name`: Must follow `<plural>.<group>`.
- `versions`: Lists supported API versions. Exactly one version must set `storage: true` (the version format persisted inside `etcd`).
- `subresources.status: {}`: Enables the `/status` API subresource, separating user-driven `spec` writes from controller-driven `status` updates.
- `openAPIV3Schema`: Mandatory structural validation schema evaluated by `kube-apiserver` prior to object persistence.

### Managing CRDs and Custom Resources

```bash
# Register CRD in cluster
kubectl apply -f backup-crd.yaml
kubectl get crd backups.storage.example.com

# Create Custom Resource instance
kubectl apply -f - <<EOF
apiVersion: storage.example.com/v1
kind: Backup
metadata:
  name: nightly-backup
spec:
  schedule: "0 2 * * *"
  retentionDays: 7
EOF

# Query Custom Resource instances
kubectl get backups
kubectl get bkp
```

Without an active controller watching the custom resource, a CR is simply a data structure stored inside `etcd`. The CRD defines object structure; the controller implements automated behaviors.

> **Warning**: Deleting a `CustomResourceDefinition` cascades and deletes ALL associated Custom Resource instances across all namespaces throughout the cluster.

---

## The Operator Pattern

An **Operator** couples CRD schemas with custom controllers executing reconciliation control loops:

$$\text{Observe Current State} \longrightarrow \text{Compare with Spec} \longrightarrow \text{Reconcile Differences} \longrightarrow \text{Update Status}$$

Operators execute as standard Deployments within cluster namespaces, using RBAC ServiceAccounts granting permissions to manage target Kubernetes API objects.

---

## Installing Operators

Operators are typically deployed using three approaches:

1. **Manifest Bundles**: Direct `kubectl apply -f` of CRDs, RBAC roles, and controller Deployment manifests.
2. **Helm Charts**: Helm packages deploying CRDs and controller workloads.
3. **Operator Lifecycle Manager (OLM)**: Automated lifecycle management tool deploying operators via `Subscription` and `CatalogSource` resources.

---

## Troubleshooting Operator Workloads

```bash
# Verify operator controller pod deployment
kubectl get deployment -n <operator-namespace>

# View controller logs to monitor reconciliation loops
kubectl logs -n <operator-namespace> deploy/<operator-controller> -f

# Inspect Custom Resource status fields
kubectl describe <custom-resource> <resource-name>
```

---

## References

- Custom Resources: https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Extend Kubernetes API with CRDs: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
- Operator Pattern: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
