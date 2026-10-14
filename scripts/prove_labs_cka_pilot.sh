#!/usr/bin/env bash
# Pilot proof: CKA 1.1, 3.3, 3.4, 3.5 — run, check FAIL, manual fix (from each lab's solution), check PASS, down.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
L=scripts/study-lab
now() { date +%s.%N; }
el() { echo "$(now) - $1" | bc | xargs printf '%.1f'; }
fix_1_1() {
  $L exec cka 1.1 -- kubectl delete storageclass cka-lab-broken-sc
  printf 'apiVersion: storage.k8s.io/v1\nkind: StorageClass\nmetadata:\n  name: cka-lab-broken-sc\nprovisioner: rancher.io/local-path\nreclaimPolicy: Delete\nvolumeBindingMode: WaitForFirstConsumer\n' | $L exec cka 1.1 -- kubectl apply -f -
  for i in $(seq 1 40); do $L exec cka 1.1 -- kubectl get pod -n cka-1-1-storage-lab cka-lab-writer -o jsonpath='{.status.phase}' | grep -q Running && break; sleep 3; done
}
fix_3_3() {
  $L exec cka 3.3 -- kubectl set resources deployment/revenue-api -n autoscaling-lab --containers=revenue-api --requests=cpu=200m
  $L exec cka 3.3 -- kubectl rollout status deployment/revenue-api -n autoscaling-lab --timeout=120s
  for i in $(seq 1 40); do $L exec cka 3.3 -- kubectl get hpa -n autoscaling-lab -o jsonpath='{.items[0].status.currentMetrics[0].resource.current.averageUtilization}' | grep -q . && break; sleep 5; done
}
fix_3_4() {
  $L exec cka 3.4 -- kubectl patch deployment webapp -n cka-3-4-selfheal --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/"},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/port","value":80},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/periodSeconds","value":5}]'
}
fix_3_5() {
  $L exec cka 3.5 -- kubectl -n cka-3-5-lab set resources deployment/web-quota --containers=nginx --requests=cpu=100m --limits=cpu=150m
  $L exec cka 3.5 -- kubectl label node lab-control-plane lab.cka.io/tier=gpu-ultra --overwrite
  $L exec cka 3.5 -- kubectl -n cka-3-5-lab rollout status deployment/web-quota --timeout=120s
  $L exec cka 3.5 -- kubectl -n cka-3-5-lab rollout status deployment/web-affinity --timeout=120s
}
for t in ${TOPICS:-1.1 3.3 3.4 3.5}; do
  echo "=================== cka $t"
  s=$(now); $L run cka $t > /tmp/run-$t.log 2>&1; rc=$?; echo "RUN rc=$rc $(el $s)s"; [ $rc = 0 ] || { tail -20 /tmp/run-$t.log; $L down cka $t; continue; }
  docker stats --no-stream --format 'RAM {{.MemUsage}}' study-lab-cka-${t/./-}
  s=$(now); $L run cka $t 2>&1 | grep -E 'already|recreat'; echo "RUN#2 $(el $s)s"
  $L check cka $t > /tmp/check1-$t.log 2>&1; echo "CHECK before fix rc=$? :: $(tail -1 /tmp/check1-$t.log)"
  fix_${t/./_} > /tmp/fix-$t.log 2>&1; echo "FIX applied (log /tmp/fix-$t.log)"
  $L check cka $t > /tmp/check2-$t.log 2>&1; echo "CHECK after fix rc=$? :: $(tail -1 /tmp/check2-$t.log)"
  s=$(now); $L down cka $t > /tmp/down-$t.log 2>&1; echo "DOWN rc=$? $(el $s)s"
  echo "LEFT containers: $(docker ps -a --filter label=study-lab=1 -q | wc -l)"
done
