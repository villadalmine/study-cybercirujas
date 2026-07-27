# Guided Exercises — 4.7 Understand CRDs, install and configure operators

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working Kubernetes cluster with `kubectl` configured.

---

## Exercise 1 — Inspecting Cluster CRDs

1. List registered CustomResourceDefinitions:
   ```bash
   kubectl get crds
   ```
2. Inspect CRD metadata and OpenAPI validation schemas:
   ```bash
   kubectl get crd <crd-name> -o yaml
   ```

---

## Exercise 2 — Manifesting a CustomResourceDefinition

1. Create manifest `backuppolicy-crd.yaml`:
   ```yaml
   apiVersion: apiextensions.k8s.io/v1
   kind: CustomResourceDefinition
   metadata:
     name: backuppolicies.training.example.com
   spec:
     group: training.example.com
     names:
       kind: BackupPolicy
       listKind: BackupPolicyList
       plural: backuppolicies
       singular: backuppolicy
       shortNames:
         - bkp
     scope: Namespaced
     versions:
       - name: v1
         served: true
         storage: true
         subresources:
           status: {}
         schema:
           openAPIV3Schema:
             type: object
             properties:
               spec:
                 type: object
                 required:
                   - schedule
                   - targetPVC
                 properties:
                   schedule:
                     type: string
                   retentionDays:
                     type: integer
                     minimum: 1
                   targetPVC:
                     type: string
   ```
2. Apply CRD and confirm status:
   ```bash
   kubectl apply -f backuppolicy-crd.yaml
   kubectl get crd backuppolicies.training.example.com
   ```

---

## Exercise 3 — Creating Custom Resources

1. Manifest Custom Resource `nightly-backup.yaml`:
   ```yaml
   apiVersion: training.example.com/v1
   kind: BackupPolicy
   metadata:
     name: nightly-backup
   spec:
     schedule: "0 2 * * *"
     retentionDays: 7
     targetPVC: data-pvc
   ```
2. Apply and query custom resources:
   ```bash
   kubectl apply -f nightly-backup.yaml
   kubectl get backuppolicies
   ```

---

## Exercise 4 — Installing an Operator (cert-manager)

1. Apply cert-manager operator release bundle:
   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
   ```
2. Verify created CRDs and running operator Pods:
   ```bash
   kubectl get crds | grep cert-manager.io
   kubectl get pods -n cert-manager
   ```

---

<details>
<summary>View Answers</summary>

1. A CRD defines schema structures; an Operator supplies controller logic automating reconciliation loops.
2. `openAPIV3Schema` forces API server structural validation prior to etcd persistence.
3. `Established: True` indicates the CRD registration completed successfully.

</details>
