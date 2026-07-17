#!/usr/bin/env bash
#
# break-fix-ckad-1-3.sh
# CKAD (examen v1.35) - Tema 1.3: Understand multi-container Pod design
# patterns (sidecar, init and others). Peso en el examen: 5.
#
# Fuente de referencia (curricula oficial, solo como referencia, no se
# copia texto de ahi): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# ADVERTENCIA: ejecutar SOLO en una VM de laboratorio descartable con
# acceso a un cluster de Kubernetes de prueba (kind, minikube, k3s, etc.).
# El script crea y usa un namespace propio ("ckad-1-3-multicontainer") y
# no toca nada fuera de el, pero esta pensado para un cluster de una sola
# vez, no para un cluster real ni compartido.
#
# Requiere Kubernetes >= 1.29 para el soporte nativo de sidecar containers
# (initContainers[].restartPolicy: Always). Casi cualquier kind/minikube
# reciente ya lo trae por defecto.

set -euo pipefail

NAMESPACE="ckad-1-3-multicontainer"
POD_NAME="multi-pattern-pod"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

command -v kubectl >/dev/null 2>&1 || { echo "Falta kubectl en el PATH. Abortando." >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "No hay un cluster de Kubernetes accesible. Abortando." >&2; exit 1; }

log "Creando namespace descartable '${NAMESPACE}' (idempotente)..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Limpiando restos de una corrida anterior, si los hay..."
kubectl -n "${NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found --wait=true

log "Desplegando la version CORRECTA del Pod multi-container (baseline)..."
cat <<'EOF_BASELINE' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-pattern-pod
  labels:
    lab: ckad-1-3
spec:
  volumes:
    - name: shared-content
      emptyDir: {}
  initContainers:
    # init container clasico: corre una sola vez, prepara datos
    # compartidos para los containers que arrancan despues.
    - name: init-config
      image: busybox:1.36
      command: ["sh", "-c", "echo '<h1>Hello from CKAD 1.3 lab</h1>' > /work-dir/index.html"]
      volumeMounts:
        - name: shared-content
          mountPath: /work-dir
    # sidecar nativo: es un initContainer con restartPolicy Always,
    # arranca antes que los containers normales y sigue vivo durante
    # toda la vida del Pod.
    - name: sidecar-logger
      image: busybox:1.36
      restartPolicy: Always
      command: ["sh", "-c", "while true; do echo '[sidecar] contenido actual:'; cat /site/index.html 2>/dev/null || echo '[sidecar] index.html todavia no existe'; sleep 15; done"]
      volumeMounts:
        - name: shared-content
          mountPath: /site
  containers:
    - name: web
      image: nginx:1.27-alpine
      volumeMounts:
        - name: shared-content
          mountPath: /usr/share/nginx/html
      ports:
        - containerPort: 80
EOF_BASELINE

log "Esperando a que el baseline llegue a Ready (puede tardar por el pull de imagenes)..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=120s

log "Verificando que el baseline funciona: 'web' debe servir el HTML generado por 'init-config'"
kubectl -n "${NAMESPACE}" exec "${POD_NAME}" -c web -- wget -qO- http://localhost/

log "Baseline OK. Ahora se rompe el laboratorio a proposito..."
kubectl -n "${NAMESPACE}" delete pod "${POD_NAME}" --wait=true

cat <<'EOF_BROKEN' | kubectl apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-pattern-pod
  labels:
    lab: ckad-1-3
spec:
  volumes:
    - name: shared-content
      emptyDir: {}
  initContainers:
    - name: init-config
      image: busybox:1.36
      command: ["sh", "-c", "echo '<h1>Hello from CKAD 1.3 lab</h1>' > /work-dir/index.html"]
      volumeMounts:
        - name: shared-content
          mountPath: /data
    - name: sidecar-logger
      image: busybox:1.36
      restartPolicy: Always
      command: ["sh", "-c", "while true; do echo '[sidecar] contenido actual:'; cat /site/index.html 2>/dev/null || echo '[sidecar] index.html todavia no existe'; sleep 15; done"]
      volumeMounts:
        - name: shared-content
          mountPath: /site
  containers:
    - name: web
      image: nginx:1.27-alpine
      volumeMounts:
        - name: shared-content
          mountPath: /usr/share/nginx/html
      ports:
        - containerPort: 80
EOF_BROKEN

sleep 20

log "Estado actual del laboratorio (roto a proposito):"
kubectl -n "${NAMESPACE}" get pod "${POD_NAME}"

cat <<MSG

============================================================
 SINTOMA
============================================================
El Pod '${POD_NAME}' nunca llega a Running/Ready. 'kubectl get pod'
muestra algo como:

  NAME               READY   STATUS                  RESTARTS
  ${POD_NAME}  0/2     Init:CrashLoopBackOff   N

Los containers 'sidecar-logger' (el sidecar nativo) y 'web' quedan
bloqueados: en un Pod, cada initContainer regular debe terminar con
exito (exit 0) antes de que arranque el siguiente initContainer o
cualquier container normal, sin importar si ese siguiente init
container es un sidecar (restartPolicy: Always) o no.

============================================================
 OBJETIVO
============================================================
1. Diagnosticar por que falla el init container 'init-config'.
   Pistas: kubectl describe pod, kubectl logs ... -c init-config
   (o --previous si ya reinicio).
2. Identificar la causa raiz: un mismatch entre el 'mountPath'
   declarado en volumeMounts de 'init-config' y el path que usa el
   comando de ese mismo container para escribir el archivo.
3. Corregir el manifiesto del Pod para que ambos paths coincidan.
4. 'initContainers' es un campo inmutable en un Pod ya creado: la
   correccion se aplica recreando el Pod (delete + apply), no con
   'kubectl edit' en caliente.
5. Confirmar que el Pod llega a READY 2/2, STATUS Running, que 'web'
   sirve el HTML generado por 'init-config', y que 'sidecar-logger'
   puede leerlo del volumen compartido (kubectl logs -c sidecar-logger).

Namespace del laboratorio: ${NAMESPACE}
Pod: ${POD_NAME}
============================================================
MSG

# ============================================================
# SOLUCION PASO A PASO (no se ejecuta, es solo referencia)
# ============================================================
#
# 1) Ver el estado y los eventos del Pod:
#      kubectl -n ckad-1-3-multicontainer describe pod multi-pattern-pod
#    En Events aparece algo como:
#      Error: failed to start container "init-config": ... exec: "sh":
#      ... /work-dir/index.html: No such file or directory
#
# 2) Ver el log del init container que fallo:
#      kubectl -n ckad-1-3-multicontainer logs multi-pattern-pod -c init-config
#    (agregar --previous si ya hizo al menos un restart)
#    El error confirma que el comando intenta escribir en /work-dir/,
#    pero dentro del container solo existe /data (que es donde se
#    monto el volumen 'shared-content').
#
# 3) Diagnostico: en el Pod roto, 'init-config' tiene:
#      command: escribe en /work-dir/index.html
#      volumeMounts.mountPath: /data
#    Los dos paths no coinciden, asi que /work-dir no existe dentro
#    del container y el comando falla con exit code distinto de 0.
#
# 4) Corregir el manifiesto para que ambos paths coincidan (cualquiera
#    de las dos opciones sirve, aca se deja el mountPath en /work-dir
#    para que coincida con el command, sin tocar el resto del Pod):
#
#      initContainers:
#        - name: init-config
#          image: busybox:1.36
#          command: ["sh", "-c", "echo '<h1>Hello from CKAD 1.3 lab</h1>' > /work-dir/index.html"]
#          volumeMounts:
#            - name: shared-content
#              mountPath: /work-dir   # <- antes decia /data
#
# 5) Como 'initContainers' es inmutable en un Pod existente, borrar y
#    recrear el Pod con el manifiesto corregido (guardarlo, por
#    ejemplo, en fixed-pod.yaml):
#      kubectl -n ckad-1-3-multicontainer delete pod multi-pattern-pod
#      kubectl -n ckad-1-3-multicontainer apply -f fixed-pod.yaml
#
# 6) Verificar que llega a Ready:
#      kubectl -n ckad-1-3-multicontainer get pod multi-pattern-pod -w
#    Debe mostrar READY 2/2 y STATUS Running.
#
# 7) Verificar el contenido servido por 'web':
#      kubectl -n ckad-1-3-multicontainer exec multi-pattern-pod -c web -- wget -qO- http://localhost/
#    Debe devolver: <h1>Hello from CKAD 1.3 lab</h1>
#
# 8) Verificar que el sidecar puede leer el volumen compartido:
#      kubectl -n ckad-1-3-multicontainer logs multi-pattern-pod -c sidecar-logger
#    Debe mostrar, cada 15 segundos, el contenido de index.html en vez
#    de "index.html todavia no existe".
#
# 9) Limpieza del laboratorio (opcional, VM descartable):
#      kubectl delete namespace ckad-1-3-multicontainer
#
# ============================================================