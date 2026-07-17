#!/usr/bin/env bash
#
# CKS 1.34 - Dominio 4.4: Perform static analysis of user workloads and container images
#            (e.g. Kubesec, KubeLinter) - peso en el examen: 5
#
# Fuentes de referencia:
#   - CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#   - KubeLinter docs:            https://docs.kubelinter.io/
#   - KubeLinter repo (releases): https://github.com/stackrox/kube-linter
#   - Kubesec:                    https://kubesec.io/
#   - Kubesec repo (releases):    https://github.com/controlplaneio/kubesec
#
# ADVERTENCIA: este script aplica un Deployment deliberadamente inseguro a un
# namespace del cluster. Ejecutalo SOLO en una VM de laboratorio descartable
# (kubeadm de un solo nodo, kind, minikube, etc.) que puedas destruir sin
# problema. No lo corras contra un cluster real ni compartido.

set -euo pipefail

LAB_NS="cks-4-4-static-analysis"
WORKDIR="${HOME}/cks-labs/4.4-static-analysis"
MANIFEST="${WORKDIR}/insecure-app.yaml"

confirm_disposable_vm() {
  if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM:-}" == "yes" ]]; then
    return 0
  fi
  echo "Este script va a desplegar un workload deliberadamente inseguro."
  read -r -p "¿Estás en una VM de laboratorio descartable? Escribí 'si' para continuar: " ans
  if [[ "${ans,,}" != "si" ]]; then
    echo "Cancelado. No se modificó nada."
    exit 1
  fi
}

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl en el PATH."; exit 1; }
  kubectl cluster-info >/dev/null 2>&1 || { echo "No hay un cluster accesible con el kubeconfig actual."; exit 1; }
}

break_scenario() {
  mkdir -p "${WORKDIR}"

  cat > "${MANIFEST}" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: insecure-app
  labels:
    app: insecure-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: insecure-app
  template:
    metadata:
      labels:
        app: insecure-app
    spec:
      automountServiceAccountToken: true
      hostNetwork: true
      hostPID: true
      containers:
        - name: app
          image: alpine:latest
          command: ["/bin/sh", "-c", "sleep 3600"]
          securityContext:
            privileged: true
            allowPrivilegeEscalation: true
            capabilities:
              add:
                - SYS_ADMIN
                - NET_ADMIN
          volumeMounts:
            - name: host-root
              mountPath: /host
      volumes:
        - name: host-root
          hostPath:
            path: /
            type: Directory
EOF

  kubectl create namespace "${LAB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${LAB_NS}" apply -f "${MANIFEST}"
  kubectl -n "${LAB_NS}" rollout status deployment/insecure-app --timeout=90s
}

show_symptom_and_goal() {
  cat <<EOF

================================================================
SÍNTOMA
================================================================
El Deployment "insecure-app" en el namespace "${LAB_NS}" quedó
Running sin ningún error ni advertencia del cluster:

  kubectl -n ${LAB_NS} get pods

El cluster lo aceptó sin quejarse porque no hay ningún admission
controller ni policy engine bloqueando este Pod en runtime. El
problema no es que algo esté roto: es que el manifiesto tiene
múltiples configuraciones inseguras que nadie detectó ANTES de
aplicarlo.

================================================================
OBJETIVO
================================================================
Tu tarea es hacer static analysis del manifiesto
"${MANIFEST}" con Kubesec y/o KubeLinter, identificar los
findings de severidad alta/critical, y corregir el YAML hasta que:

  1. "kube-linter lint ${MANIFEST}" no reporte ningún error para
     los checks: privileged-container, run-as-non-root,
     host-network, host-pid, sensitive-host-mounts, latest-tag,
     unset-cpu-requirements, unset-memory-requirements.

  2. "kubesec scan ${MANIFEST}" devuelva un score positivo
     (score > 0), sin los "critical" que tiene ahora
     (privileged, capability SYS_ADMIN, hostPath a "/").

  3. El Deployment corregido siga levantando el Pod en Running
     tras volver a aplicarlo:

       kubectl -n ${LAB_NS} apply -f ${MANIFEST}
       kubectl -n ${LAB_NS} get pods

No se te pide instalar un policy engine (eso es otro dominio):
se te pide arreglar el manifiesto usando lo que te dicen las
herramientas de static analysis.

Si no tenés kube-linter ni kubesec instalados en esta VM, instalalos
vos (son binarios standalone, no dependen de nada del cluster).
La solución comentada al final de este script explica cómo.
================================================================

EOF
}

main() {
  confirm_disposable_vm
  check_prereqs
  break_scenario
  show_symptom_and_goal
}

main "$@"

# ================================================================
# SOLUCIÓN PASO A PASO (no se ejecuta - léela solo si te trabaste)
# ================================================================
#
# 1) Instalar KubeLinter (binario standalone, no necesita el cluster):
#
#      curl -sSL -o kube-linter.tar.gz \
#        https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux.tar.gz
#      tar -xzf kube-linter.tar.gz
#      sudo install -m 0755 kube-linter /usr/local/bin/kube-linter
#      kube-linter version
#
# 2) Correr KubeLinter contra el manifiesto roto y leer los findings:
#
#      kube-linter lint "$HOME/cks-labs/4.4-static-analysis/insecure-app.yaml"
#
#    Vas a ver algo como:
#      (object: <no namespace>/insecure-app) container "app" is
#        running as privileged (check: privileged-container, ...)
#      (object: <no namespace>/insecure-app) container "app" does not
#        have a read-only root filesystem ...
#      (object: <no namespace>/insecure-app) container "app" has
#        cpu/memory requests/limits unset ...
#      (object: <no namespace>/insecure-app) image "alpine:latest"
#        uses a mutable tag (check: latest-tag)
#      (object: <no namespace>/insecure-app) host network namespace
#        is enabled (check: host-network)
#      ... hostPID y el hostPath a "/" también van a salir marcados
#      (sensitive-host-mounts).
#
# 3) Instalar Kubesec. Opción rápida con Docker/Podman (no requiere
#    compilar nada):
#
#      docker run -i --rm kubesec/kubesec:v2 scan /dev/stdin \
#        < "$HOME/cks-labs/4.4-static-analysis/insecure-app.yaml"
#
#    O como binario standalone (releases en
#    https://github.com/controlplaneio/kubesec/releases):
#
#      curl -sSL -o kubesec.tar.gz \
#        https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz
#      tar -xzf kubesec.tar.gz
#      sudo install -m 0755 kubesec /usr/local/bin/kubesec
#      kubesec scan "$HOME/cks-labs/4.4-static-analysis/insecure-app.yaml"
#
#    El score va a salir negativo, con "critical" en:
#      containers[] .securityContext .privileged == true
#      containers[] .securityContext .capabilities .add == SYS_ADMIN
#      volumes[] .hostPath .path == "/"
#
# 4) Corregir el manifiesto punto por punto (esto es lo que hay que
#    escribir en insecure-app.yaml):
#
#      - Sacar hostNetwork: true y hostPID: true por completo.
#      - Sacar el volumeMount y el volume de hostPath a "/".
#      - Poner automountServiceAccountToken: false (este Pod no
#        necesita hablar con la API).
#      - Cambiar securityContext del container a:
#          securityContext:
#            privileged: false
#            allowPrivilegeEscalation: false
#            readOnlyRootFilesystem: true
#            runAsNonRoot: true
#            runAsUser: 1000
#            capabilities:
#              drop: ["ALL"]
#      - Pinnear la imagen a un tag inmutable, ej: alpine:3.20
#        (o mejor, por digest: alpine@sha256:<digest>).
#      - Agregar resources con requests y limits de cpu/memory:
#          resources:
#            requests:
#              cpu: "50m"
#              memory: "32Mi"
#            limits:
#              cpu: "100m"
#              memory: "64Mi"
#
# 5) Volver a correr kube-linter y kubesec sobre el archivo corregido
#    y confirmar que no quedan findings critical/high y que el score
#    de kubesec es positivo.
#
# 6) Reaplicar y confirmar que el Pod sigue Running (alpine con
#    "sleep 3600" no necesita escribir en el filesystem, así que
#    corre sin problema con readOnlyRootFilesystem: true y como
#    usuario no-root):
#
#      kubectl -n cks-4-4-static-analysis apply -f \
#        "$HOME/cks-labs/4.4-static-analysis/insecure-app.yaml"
#      kubectl -n cks-4-4-static-analysis get pods
#
# 7) Limpieza del laboratorio:
#
#      kubectl delete namespace cks-4-4-static-analysis
#      rm -rf "$HOME/cks-labs/4.4-static-analysis"
#
# ================================================================