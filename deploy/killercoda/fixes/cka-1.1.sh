#!/usr/bin/env bash
# Reference fix for cka 1.1, as a student would do it on the Killercoda host (kubectl as root, no study-lab).
set -euo pipefail
NS=cka-1-1-storage-lab
prov=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].provisioner}')
kubectl delete storageclass cka-lab-broken-sc
printf 'apiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata:\n  name: cka-lab-broken-sc\nprovisioner: %s\nreclaimPolicy: Delete\nvolumeBindingMode: WaitForFirstConsumer\n' "$prov" | kubectl apply -f -
for i in $(seq 1 40); do kubectl get pod -n "$NS" cka-lab-writer -o jsonpath='{.status.phase}' | grep -q Running && exit 0; sleep 3; done
kubectl get pvc,pod -A -o wide >&2; kubectl describe pvc,pod -n "$NS" 2>&1 | tail -40 >&2; kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -25 >&2
exit 1
