# 6.4 — Garantizar la inmutabilidad de los contenedores en tiempo de ejecución

**Certificación:** CKS (Certified Kubernetes Security Specialist), currículo v1.34
**Dominio:** Monitoring, Logging and Runtime Security · **Peso:** 4

---

## 1. El problema en producción

Una imagen de contenedor es un artefacto direccionable por contenido, firmado y escaneado. En el momento en que el kubelet se la entrega al runtime CRI, esa garantía se evapora: el runtime OCI apila un `upperdir` escribible sobre las capas de la imagen, y desde ese instante el contenedor en ejecución es un sistema de archivos *mutable* que ya no se corresponde con nada que hayas escaneado, firmado ni atestiguado.

Todo lo que hace tratable la seguridad de contenedores depende de cerrar esa brecha:

| Garantía que *creés* tener | Qué la rompe |
|---|---|
| "Este pod ejecuta el código que escaneamos en CI" | El atacante escribe `/usr/bin/curl` o sobrescribe el binario de la aplicación en la capa escribible |
| "Dos réplicas de este Deployment son idénticas" | A una réplica le hicieron `kubectl exec` y la parchearon a mano a las 03:00 durante un incidente |
| "Podemos razonar forensemente sobre el radio de impacto" | El post-mortem muestra un contenedor cuyo sistema de archivos divergió de su imagen hace semanas; nadie sabe cuándo |
| "Reconstruir desde la imagen elimina el compromiso" | Es cierto — pero solo si podés *detectar* que hace falta hacerlo, lo que requiere señales de deriva |
| "El SBOM es preciso" | Un binario estático depositado no aparece en ningún SBOM |

La cadena de ataque a la que apunta este control es corta y extremadamente común:

1. **Acceso inicial** — RCE por un bug de deserialización, SSRF o una dependencia vulnerable en la propia aplicación.
2. **Transferencia de herramientas al interior** (MITRE ATT&CK **T1105**) — el atacante necesita herramientas. `curl`/`wget` de un `nc` estático, `kubectl` o un minero de criptomonedas hacia una ruta escribible.
3. **Ejecución** — `chmod +x` y ejecutarlo.
4. **Persistencia** (**T1543**, **T1546**) — sobrescribir un script de entrypoint, dejar una entrada de cron, parchear una biblioteca compartida para que sobreviva al reinicio de un proceso *dentro del mismo contenedor*.
5. **Escalada / movimiento lateral** (**T1611**) — usar las herramientas depositadas contra el API server, el nodo o pods vecinos.

La inmutabilidad en tiempo de ejecución rompe la cadena en los pasos 2–3, que es el lugar más barato posible donde romperla. Notá la asimetría crucial: un atacante con RCE tiene *ejecución arbitraria de código dentro de tu proceso*, algo que no podés prevenir a posteriori. Lo que sí *podés* prevenir es que esa ejecución se convierta en una presencia **duradera, asistida por herramientas y difícil de detectar**.

### La inmutabilidad son tres propiedades separadas

CKS lo formula como un único objetivo, pero en producción se descompone en tres controles con tres capas de aplicación distintas, y confundirlos es el error de diseño más común:

| Propiedad | Significado | Capa de aplicación |
|---|---|---|
| **Inmutabilidad de imagen** | Los bytes que se ejecutan son exactamente los bytes que se firmaron. Los tags no pueden reapuntarse por debajo tuyo. | Registry + fijación por digest + `AlwaysPullImages` + verificación de firma |
| **Inmutabilidad del sistema de archivos** | El contenedor en ejecución no puede modificar su propio sistema de archivos raíz. | Runtime OCI (`root.readonly`), LSMs (AppArmor/SELinux) |
| **Inmutabilidad de configuración** | El spec del Pod, los ConfigMaps y los Secrets se reemplazan mediante rollout, nunca se parchean in situ. | API server (`immutable: true`), RBAC, GitOps, política de admisión |

Un sistema de archivos raíz de solo lectura en un contenedor construido `FROM ubuntu:latest` con un tag mutable y un PVC escribible en `/var/lib` no te da casi nada. Las tres propiedades tienen que sostenerse juntas.

---

## 2. Mecánica: qué hace realmente `readOnlyRootFilesystem`

Este es el campo que CKS evalúa, y entender su semántica exacta te dice con precisión qué es lo que *no* cubre.

### 2.1 El camino desde el PodSpec hasta el kernel

```
PodSpec.spec.containers[].securityContext.readOnlyRootFilesystem: true
        │
        ▼
kubelet → CRI  ContainerConfig.linux.security_context.readonly_rootfs = true
        │
        ▼
containerd → OCI runtime spec (config.json)   "root": { "path": "rootfs", "readonly": true }
        │
        ▼
runc:  mount(NULL, rootfs, NULL, MS_BIND|MS_REMOUNT|MS_RDONLY|..., NULL)
```

El último paso es el importante. runc **no** crea un overlay de solo lectura. Construye el overlay normal de lectura-escritura y después **remonta con bind el punto de montaje en modo solo lectura**. Dos consecuencias que podés observar directamente:

```console
$ kubectl exec -n payments deploy/edge -c nginx -- cat /proc/self/mountinfo | head -3
1877 1876 0:143 / / ro,relatime master:412 - overlay overlay rw,lowerdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2401/fs:/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2400/fs,upperdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2417/fs,workdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2417/work
1878 1877 0:146 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
1879 1877 0:147 / /dev rw,nosuid,noexec,relatime - tmpfs tmpfs rw,size=65536k,mode=755
```

Leé el campo 6 (`ro,relatime`) frente a las opciones del superbloque después del separador `-` (`overlay rw,...`). **El montaje es de solo lectura; el sistema de archivos que hay debajo es de lectura-escritura.** Esa distinción es la razón por la que:

- `readOnlyRootFilesystem` lo aplica el kernel mediante flags de montaje, no el driver de almacenamiento — es barato, inmediato, y devuelve `EROFS` (errno 30) en cada intento de escritura.
- Se aplica **únicamente a ese punto de montaje**. Cada otro montaje en el espacio de nombres de montaje del contenedor lleva sus propios flags.

### 2.2 Verificar a nivel del runtime

```console
$ CID=$(sudo crictl ps -q --name nginx --state Running | head -1)
$ sudo crictl inspect --output json "$CID" | jq '.info.runtimeSpec.root'
{
  "path": "rootfs",
  "readonly": true
}
```

Y las rutas que el CRI endurece por defecto, con independencia de tu PodSpec:

```console
$ sudo crictl inspect --output json "$CID" | jq '.info.runtimeSpec.linux | {maskedPaths, readonlyPaths}'
{
  "maskedPaths": [
    "/proc/acpi",
    "/proc/asound",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/proc/scsi",
    "/sys/firmware",
    "/sys/devices/virtual/powercap"
  ],
  "readonlyPaths": [
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger"
  ]
}
```

Estos valores por defecto son la razón por la que un contenedor no puede escribir `/proc/sys/kernel/core_pattern` (una primitiva clásica de escape de contenedor) ni siquiera sin `readOnlyRootFilesystem`. Se deshacen con `securityContext.procMount: Unmasked`, que requiere el feature gate `ProcMountType` y está prohibido por los Pod Security Standards `baseline` y `restricted` — tratá cualquier pedido de eso como una señal de alarma.

### 2.3 Lo que `readOnlyRootFilesystem: true` **no** cubre

Esta es la parte que hace fallar las auditorías.

```console
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'awk "{print \$5, \$6}" /proc/self/mountinfo'
/ ro,relatime
/proc rw,nosuid,nodev,noexec,relatime
/dev rw,nosuid,noexec,relatime
/dev/shm rw,nosuid,nodev,noexec,relatime
/dev/termination-log rw,nosuid,nodev,relatime
/etc/hosts rw,nosuid,nodev,relatime
/etc/hostname rw,nosuid,nodev,relatime
/etc/resolv.conf rw,nosuid,nodev,relatime
/etc/nginx/nginx.conf ro,relatime
/tmp rw,relatime
/var/run/secrets/kubernetes.io/serviceaccount ro,relatime
```

Todo excepto `/` y las dos entradas `ro` es escribible. Concretamente, con `readOnlyRootFilesystem: true` un atacante todavía puede:

| Superficie escribible | Origen | ¿Ejecución permitida? | Mitigación |
|---|---|---|---|
| `/dev/shm` (tmpfs de 64 MiB) | Valor por defecto del CRI | No — `noexec` | Mantener `noexec`; monitorear preparación de material |
| `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf` | Bind mounts del kubelet desde el directorio del pod | No (archivo, no directorio) | Detectar ediciones (primitiva de secuestro de DNS) |
| `/dev/termination-log` | kubelet, `terminationMessagePath` | No | Poner `terminationMessagePolicy: FallbackToLogsOnError`; no se puede eliminar |
| Cualquier `emptyDir` que hayas montado | tu PodSpec | **Sí, por defecto** | Ver §4 — acá es donde hace falta disciplina |
| Cualquier PVC | tu PodSpec | **Sí** | Solo estado genuino; nunca montar encima de `/usr`, `/bin`, `/opt/app` |
| `hostPath` | tu PodSpec | **Sí, y escapa del contenedor** | Prohibido por PSS `baseline`/`restricted` |
| Memoria anónima vía `memfd_create(2)` + `fexecve(2)` | kernel | **Sí — sin archivo** | Indetectable por cualquier control basado en rutas; necesita eBPF/Falco |

La última fila es la que termina con el argumento de "sistema de archivos raíz de solo lectura = problema resuelto". La ejecución sin archivo (`memfd_create` → escribir ELF → `execveat(fd, "", ..., AT_EMPTY_PATH)`, MITRE **T1620**) no toca ninguna ruta en ningún sistema de archivos. `readOnlyRootFilesystem`, las reglas de ruta de AppArmor y los contextos de archivo de SELinux son todos ciegos a eso. Solo la detección en tiempo de ejecución a nivel de syscall lo ve. **Prevención y detección no son sustitutos la una de la otra.**

---

## 3. Análisis comparativo del conjunto de controles

### 3.1 Controles, cobertura y costo

| Control | Capa de aplicación | Bloquea | Ciego a | Costo operativo |
|---|---|---|---|---|
| `readOnlyRootFilesystem: true` | Runtime OCI, remontaje bind `MS_RDONLY` | Todas las escrituras en `/` | Volúmenes, `/dev/shm`, archivos inyectados por el kubelet, memfd | Refactorización de la aplicación para reubicar el estado escribible; **medio**, por única vez |
| Imagen base distroless / `scratch` | Construcción de la imagen | `sh`, `curl`, `apt`, `python` — toda la caja de herramientas de living-off-the-land | Binario enlazado estáticamente depositado en un montaje escribible | `kubectl exec`/`kubectl cp` dejan de funcionar; depuración vía contenedores efímeros; **medio** |
| Fijación por digest (`image: repo@sha256:…`) | Resolución de la imagen | Reapuntado de tag mutable; deriva del tipo "ayer funcionaba" | Registry comprometido sirviendo un digest firmado pero malicioso | Requiere renovate/automatización; **medio, recurrente** |
| Plugin de admisión `AlwaysPullImages` | API server | Reutilización de una imagen cacheada por un pod cuya SA no tiene permisos de pull | Nada sobre el contenido | Carga del registry, latencia de pull, acoplamiento de disponibilidad; **bajo–medio** |
| Verificación con Cosign / Sigstore (Kyverno `verifyImages`, `ImagePolicyWebhook`) | Admisión | Imágenes sin firmar o mal atestiguadas | Imágenes firmadas pero vulnerables | Gestión de claves/Fulcio; **medio** |
| PSS `restricted` (Pod Security Admission) | API server, incorporado | `privileged`, escalada de privilegios, todas las capabilities, `hostPath`, namespaces del host, obligación de no-root, seccomp | **NO exige `readOnlyRootFilesystem`** | Gratis (etiquetar el namespace); **muy bajo** |
| ValidatingAdmissionPolicy (CEL, en proceso) | API server | Cualquier regla a nivel de spec que puedas expresar, incluidos rootfs de solo lectura y fijación por digest | Comportamiento posterior a la admisión | Sin pods extra, sin riesgo de latencia/disponibilidad de webhook; **bajo** |
| Kyverno / OPA Gatekeeper | Webhook de validación+mutación | Lo mismo, más *mutación* (autoinyección) y verificación de imágenes | Comportamiento posterior a la admisión | Dependencia extra del plano de control; caída del webhook = impacto en el clúster; **medio** |
| Perfil AppArmor `deny /** w` | LSM, basado en rutas | Escrituras **en cualquier parte**, incluidos volúmenes y PVCs | memfd; requiere que el perfil esté presente en cada nodo | Autoría de perfiles por workload + distribución a nodos; **alto** |
| SELinux (`seLinuxOptions`, MCS) | LSM, basado en etiquetas | Escrituras entre contenedores y hacia el host; escrituras dentro del contenedor con type enforcement | memfd | Experiencia centrada en RHEL/OpenShift; **alto** |
| seccomp `RuntimeDefault` | LSM, filtro por número de syscall | ~44 syscalls peligrosas (`mount`, `pivot_root`, `kexec_load`, `bpf`…) | **No puede filtrar `write(2)` por ruta** — seccomp solo ve valores de registros, nunca desreferencia punteros | Gratis; **muy bajo** — habilitalo siempre |
| Sensores Falco / Tetragon / eBPF | Detección en tiempo de ejecución | Nada (solo detección, salvo en modo de aplicación) | — | Agente de nodo, ajuste de reglas, fatiga de alertas; **medio–alto** |
| ConfigMaps/Secrets con `immutable: true` | API server | Mutación de configuración in situ; además elimina el watch del kubelet (gran ganancia de escalabilidad) | Nada sobre el fs del contenedor | Requiere nombres con hash del contenido para el rollout; **bajo** |
| Eliminación por RBAC de `pods/exec`, `pods/attach`, `pods/ephemeralcontainers`, `pods/portforward` | API server | Deriva provocada por humanos, la causa nº 1 en el mundo real | Atacante ya dentro del contenedor | Cambio cultural; **medio** |

**Idea clave para revisiones de diseño:** `seccomp` y `readOnlyRootFilesystem` son complementarios, no redundantes. seccomp filtra *qué syscall*, nunca *qué ruta* — físicamente no puede, porque desreferenciar un puntero de espacio de usuario dentro de un filtro BPF sería una vulnerabilidad TOCTOU. El control de escritura acotado por ruta es exclusivamente competencia de un LSM (AppArmor/SELinux) o de un flag de montaje (`readOnlyRootFilesystem`).

### 3.2 Estrategias para el estado escribible que realmente necesitás

Casi ningún workload real escribe cero bytes. Elegir correctamente el almacén de respaldo es todo el ejercicio de diseño.

| Estrategia | Almacén de respaldo | Sobrevive al reinicio del contenedor | Sobrevive al reprogramado del pod | Contabilizado contra | ¿`noexec`? | Veredicto |
|---|---|---|---|---|---|---|
| `emptyDir: {}` | Disco del nodo bajo `/var/lib/kubelet/pods/<uid>/volumes/` | Sí | No | Límite de `ephemeral-storage` del Pod; el kubelet expulsa el pod al superar `sizeLimit` | No | **Opción por defecto** para scratch/caché |
| `emptyDir: {medium: Memory, sizeLimit: 64Mi}` | tmpfs | Sí | No | **Límite de memoria del contenedor** — las páginas de tmpfs se cargan al cgroup del pod | No | Lo mejor para material de secretos, archivos PID, temporales pequeños; nunca toca el disco |
| Volumen `configMap` / `secret` / `downwardAPI` / `projected` | tmpfs, montado **siempre de solo lectura** | Sí | Sí | despreciable | n/a | Inyección de configuración; ya es inmutable |
| PVC (CSI) | Volumen externo | Sí | Sí | Cuota de la StorageClass | No | Solo estado durable genuino |
| `hostPath` | Sistema de archivos del nodo | Sí | No (fijado al nodo) | Nada | No | **Prohibido** — rompe por completo la frontera del contenedor |

Dos comportamientos que sorprenden a la gente en producción:

- **Tamaño de un `emptyDir` respaldado por memoria.** Desde la funcionalidad `SizeMemoryBackedVolumes` (habilitada por defecto desde v1.22), el tmpfs se crea con `size=` tomado de `sizeLimit`. Excederlo le da al proceso un `ENOSPC` inmediato. Sin ese gate, el tmpfs toma por defecto el 50% de la RAM del *nodo* y el pod termina siendo eliminado por OOM — un modo de falla mucho peor. Definí siempre `sizeLimit`, y agregalo siempre a `resources.limits.memory` del contenedor.
- **Tamaño de un `emptyDir` respaldado por disco.** `sizeLimit` *no* es una cuota de sistema de archivos. El gestor de expulsión del kubelet mide el uso durante el mantenimiento periódico (~10 s) y **expulsa el pod entero**. Obtenés `Evicted`, no `ENOSPC`, y lo obtenés con segundos de retraso.

---

## 4. Manifiestos de producción completos

### 4.1 Workload de referencia: nginx, no-root, solo lectura, fijado por digest

Este es el ejercicio canónico de "hacer inmutable un workload hambriento de sistema de archivos". El nginx de fábrica escribe en `/var/cache/nginx/*`, `/var/run/nginx.pid` y `/etc/nginx/conf.d` — todo lo cual hay que reubicar sobre tmpfs.

Primero, resolvé el digest. Nunca lo copies a mano desde un navegador:

```console
$ crane digest docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine
sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3

$ skopeo inspect docker://docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine | jq -r '.Digest'
sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3
```

> El digest de arriba es un ejemplo. Volvé a resolverlo en tu propio pipeline y dejá que un bot (Renovate, `digestabot`) lo mantenga actualizado — un digest fijado que quedó viejo es una falla de *gestión de vulnerabilidades*, y por eso la fijación tiene que ser automatizada y no manual.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    # Baseline platform posture. Note: `restricted` does NOT imply
    # readOnlyRootFilesystem — that is added by the VAP in section 5.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.34
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.34
    security.example.com/immutability: enforce
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: edge
  namespace: payments
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  # Content-hashed name. `immutable: true` means this object can never be
  # edited; a config change produces a NEW ConfigMap and a NEW Deployment
  # revision. Generate the suffix with kustomize configMapGenerator or a
  # sha256 of the data block in CI.
  name: edge-nginx-conf-7f4c2b9d61
  namespace: payments
immutable: true
data:
  nginx.conf: |
    worker_processes auto;
    # PID file relocated onto the tmpfs emptyDir; the default /var/run/nginx.pid
    # lives on the read-only root filesystem.
    pid /tmp/nginx/nginx.pid;
    error_log /dev/stderr warn;

    events {
      worker_connections 1024;
    }

    http {
      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;
      access_log    /dev/stdout combined;

      # Every temp path nginx may write to, relocated under /tmp.
      client_body_temp_path /tmp/nginx/client_body;
      proxy_temp_path       /tmp/nginx/proxy;
      fastcgi_temp_path     /tmp/nginx/fastcgi;
      uwsgi_temp_path       /tmp/nginx/uwsgi;
      scgi_temp_path        /tmp/nginx/scgi;

      sendfile        on;
      keepalive_timeout 65;
      server_tokens   off;

      server {
        listen 8080;
        server_name _;
        root /usr/share/nginx/html;

        location = /healthz {
          access_log off;
          add_header Content-Type text/plain;
          return 200 "ok\n";
        }

        location / {
          try_files $uri $uri/ =404;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge
  namespace: payments
  labels:
    app.kubernetes.io/name: edge
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: edge
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: edge
      annotations:
        # Forces a rollout whenever the (immutable) ConfigMap name changes.
        checksum/config: "7f4c2b9d61"
    spec:
      serviceAccountName: edge
      automountServiceAccountToken: false
      enableServiceLinks: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
        # AppArmor as a first-class field (GA in v1.31). Replaces the
        # deprecated container.apparmor.security.beta.kubernetes.io/<name>
        # annotation. The profile must already be loaded on the node.
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-immutable-nginx

      initContainers:
        # The classic pattern: an init container populates the writable
        # emptyDir so the main container never has to mkdir at startup.
        - name: prepare-tmp
          image: docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine@sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              mkdir -p /tmp/nginx/client_body \
                       /tmp/nginx/proxy \
                       /tmp/nginx/fastcgi \
                       /tmp/nginx/uwsgi \
                       /tmp/nginx/scgi
              chmod 0700 /tmp/nginx
              ls -la /tmp/nginx
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            privileged: false
            runAsNonRoot: true
            runAsUser: 101
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { cpu: 100m, memory: 32Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp

      containers:
        - name: nginx
          image: docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine@sha256:9f7cd4d4a53ea6b0a4bd52a7ef6ee65cd58c68c76ecb5f47d9f7d3fbb2d1f5c3
          imagePullPolicy: IfNotPresent
          args: ["nginx", "-g", "daemon off;", "-c", "/etc/nginx/nginx.conf"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            # ── The objective of this section ──────────────────────────────
            readOnlyRootFilesystem: true
            # ───────────────────────────────────────────────────────────────
            allowPrivilegeEscalation: false
            privileged: false
            runAsNonRoot: true
            runAsUser: 101
            runAsGroup: 101
            capabilities:
              drop: ["ALL"]
              # NET_BIND_SERVICE is NOT needed: we listen on 8080, not 80.
              # Adding it here would be the single most common gratuitous
              # capability grant in the wild.
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests:
              cpu: 100m
              # tmpfs pages are charged to this cgroup: 64Mi (tmp) is included.
              memory: 128Mi
              ephemeral-storage: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
              ephemeral-storage: 128Mi
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
          terminationMessagePolicy: FallbackToLogsOnError
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: nginx-cache
              mountPath: /var/cache/nginx
            - name: nginx-run
              mountPath: /var/run

      volumes:
        # Memory-backed: never touches node disk, wiped on container restart.
        # sizeLimit is enforced as the tmpfs `size=` mount option.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: nginx-cache
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
        - name: nginx-run
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
        - name: nginx-conf
          configMap:
            name: edge-nginx-conf-7f4c2b9d61
            defaultMode: 0444
---
apiVersion: v1
kind: Service
metadata:
  name: edge
  namespace: payments
spec:
  selector:
    app.kubernetes.io/name: edge
  ports:
    - name: http
      port: 80
      targetPort: http
```

### 4.2 El caso ideal: un binario estático sobre `scratch`

Para todo lo que compiles vos mismo, la postura más fuerte es un único binario estático sin prácticamente sistema de archivos. No hay nada que sobrescribir ni nada que ejecutar.

```dockerfile
# syntax=docker/dockerfile:1.7
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0 → pure-static; -trimpath + -buildid= → reproducible builds,
# so the digest is verifiable by a third party.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -buildid=" \
      -o /out/app ./cmd/app

FROM scratch
# CA bundle and passwd are the only two things a static Go binary usually
# needs from the base image.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build --chown=65532:65532 /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
```

```yaml
containers:
  - name: app
    image: ghcr.io/example/app@sha256:3c1f0e2b8a7d64f5c9e0b1a2d3f4e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2
    securityContext:
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 65532
      runAsGroup: 65532
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
    volumeMounts:
      - name: tmp
        mountPath: /tmp          # Go's os.CreateTemp, TLS session cache, pprof
volumes:
  - name: tmp
    emptyDir: { medium: Memory, sizeLimit: 16Mi }
```

Compromiso, dicho con honestidad: `kubectl exec` y `kubectl cp` ahora son imposibles (no hay shell, no hay `tar`). Ese es el *objetivo* — pero significa que tu runbook de respuesta a incidentes tiene que reescribirse alrededor de contenedores efímeros de depuración (§7.3) antes de poner esto en producción, no después.

### 4.3 Perfil de AppArmor: denegar escrituras en todas partes, incluidos los volúmenes

`readOnlyRootFilesystem` no puede proteger el `emptyDir` que acabás de montar en `/tmp`. Si necesitás `/tmp` escribible para datos pero no para *código*, un LSM es la única herramienta capaz de expresar eso.

`/etc/apparmor.d/k8s-immutable-nginx` en cada nodo:

```
#include <tunables/global>

profile k8s-immutable-nginx flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  # ── Capabilities ────────────────────────────────────────────────────────
  # We listen on 8080, so we need none at all.
  deny capability,

  # ── Network ─────────────────────────────────────────────────────────────
  network inet  stream,
  network inet6 stream,
  network unix  stream,
  deny network raw,
  deny network packet,

  # ── Read everywhere, execute only the known binary ──────────────────────
  /** r,
  /usr/sbin/nginx ix,
  /usr/lib/nginx/modules/*.so mr,

  # ── The only writable islands: must mirror the emptyDir mounts ──────────
  /tmp/**             rwk,
  /var/cache/nginx/** rwk,
  /var/run/**         rwk,
  /dev/std{out,err}   w,

  # ── Explicit, audited denials ───────────────────────────────────────────
  audit deny /usr/**  w,
  audit deny /bin/**  w,
  audit deny /sbin/** w,
  audit deny /lib/**  w,
  audit deny /etc/**  w,
  audit deny /**/     w,

  # No new executables anywhere, even inside the writable islands.
  audit deny /tmp/**             x,
  audit deny /var/cache/nginx/** x,
  audit deny /var/run/**         x,
  audit deny /dev/shm/**         x,

  # ── Escape primitives ───────────────────────────────────────────────────
  deny mount,
  deny umount,
  deny pivot_root,
  deny ptrace (trace, tracedby, read),
  audit deny /proc/*/mem      w,
  audit deny /proc/sys/**     w,
  audit deny @{PROC}/kcore    rwklx,
}
```

Distribuilo y cargalo con un DaemonSet (el prerrequisito a nivel de nodo que la gente olvida):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: kube-system
spec:
  selector:
    matchLabels: { name: apparmor-loader }
  template:
    metadata:
      labels: { name: apparmor-loader }
    spec:
      hostPID: false
      # Loading an AppArmor profile REQUIRES writing to the node's
      # securityfs. This is a deliberately privileged, deliberately
      # tiny, deliberately audited exception to everything above.
      containers:
        - name: loader
          image: registry.k8s.io/apparmor-loader:v0.4.1
          args: ["-poll", "10s", "/profiles"]
          securityContext:
            privileged: true
          volumeMounts:
            - name: profiles
              mountPath: /profiles
              readOnly: true
            - name: sys
              mountPath: /sys
              readOnly: false
      volumes:
        - name: profiles
          configMap:
            name: apparmor-profiles
        - name: sys
          hostPath:
            path: /sys
            type: Directory
      tolerations:
        - operator: Exists
```

Verificá que el perfil esté realmente aplicado — no meramente solicitado:

```console
$ kubectl exec -n payments deploy/edge -c nginx -- cat /proc/self/attr/current
k8s-immutable-nginx (enforce)

$ sudo aa-status | grep -A2 'profiles are in enforce'
27 profiles are in enforce mode.
   /usr/bin/man
   k8s-immutable-nginx
```

---

## 5. Aplicación en la admisión

### 5.1 La brecha de Pod Security Admission

Leé esto con atención, porque es el dato que peor se enuncia con más frecuencia en este dominio:

**El Pod Security Standard `restricted` no exige `readOnlyRootFilesystem`.**

`restricted` exige `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, un perfil seccomp `RuntimeDefault`/`Localhost`, una lista restringida de tipos de volumen, ausencia de namespaces del host y ausencia de contenedores privilegiados. El sistema de archivos raíz de solo lectura queda deliberadamente excluido porque demasiadas imágenes legítimas no pueden satisfacerlo sin modificaciones.

La prueba, en un solo comando:

```console
$ kubectl label ns demo pod-security.kubernetes.io/enforce=restricted --overwrite
namespace/demo labeled

$ kubectl run probe -n demo --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"busybox:1.36","command":["sleep","3600"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
pod/probe created

$ kubectl get pod probe -n demo -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}'

$ kubectl exec -n demo probe -- sh -c 'echo pwned > /usr/bin/backdoor && ls -l /usr/bin/backdoor'
-rw-r--r--    1 1000     root             6 Aug  5 14:31 /usr/bin/backdoor
```

Un pod que satisface completamente `restricted` acaba de escribir dentro de `/usr/bin`. Cerrar esa brecha es para lo que sirve la siguiente sección.

### 5.2 ValidatingAdmissionPolicy (CEL) — la respuesta incorporada

`admissionregistration.k8s.io/v1` es GA desde v1.30. Preferí esto antes que un webhook: corre en proceso dentro del API server, no agrega ninguna dependencia de disponibilidad, y no puede fallar en modo abierto por un pod de política caído.

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-container-immutability.security.example.com
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchConditions:
    # Ephemeral containers arrive via the pods/ephemeralcontainers
    # subresource, which this rule does not match — deliberately.
    # Debug containers MUST stay writable; gate them with RBAC instead.
    - name: skip-system-namespaces
      expression: >-
        !(request.namespace in ['kube-system', 'kube-node-lease', 'kube-public'])
  variables:
    - name: workloadContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : [])
    - name: offendersRootFS
      expression: >-
        variables.workloadContainers.filter(c,
          !has(c.securityContext) ||
          !has(c.securityContext.readOnlyRootFilesystem) ||
          c.securityContext.readOnlyRootFilesystem != true
        ).map(c, c.name)
    - name: offendersDigest
      expression: >-
        variables.workloadContainers.filter(c,
          !c.image.contains('@sha256:')
        ).map(c, c.name)
    - name: offendersVolumes
      expression: >-
        (has(object.spec.volumes) ? object.spec.volumes : []).filter(v,
          has(v.hostPath)
        ).map(v, v.name)
  validations:
    - expression: "size(variables.offendersRootFS) == 0"
      messageExpression: >-
        'containers must set securityContext.readOnlyRootFilesystem: true — offending containers: '
        + variables.offendersRootFS.join(', ')
      reason: Forbidden
    - expression: "size(variables.offendersDigest) == 0"
      messageExpression: >-
        'container images must be pinned by digest (repo@sha256:...) — offending containers: '
        + variables.offendersDigest.join(', ')
      reason: Forbidden
    - expression: "size(variables.offendersVolumes) == 0"
      messageExpression: >-
        'hostPath volumes defeat container immutability — offending volumes: '
        + variables.offendersVolumes.join(', ')
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-container-immutability-binding
spec:
  policyName: require-container-immutability.security.example.com
  # Audit first, then add Deny. Rolling this out Deny-first will page you.
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: security.example.com/immutability
          operator: In
          values: ["enforce"]
```

Despliegue por etapas — la única manera responsable de poner esto en producción:

```console
# Phase 1: observe only. Nothing is blocked; violations land in the audit log.
$ kubectl patch validatingadmissionpolicybinding require-container-immutability-binding \
    --type=json -p='[{"op":"replace","path":"/spec/validationActions","value":["Audit","Warn"]}]'
validatingadmissionpolicybinding.admissionregistration.k8s.io/require-container-immutability-binding patched

# Phase 2: count violations from the API server audit log.
$ sudo jq -r 'select(.annotations["validation.policy.admission.k8s.io/validation_failure"] != null)
    | .objectRef.namespace' /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn
     43 legacy-batch
     11 observability
      2 payments

# Phase 3: flip to Deny only for namespaces that are already at zero.
```

Verificá que muerda:

```console
$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mutable
  namespace: payments
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF
Error from server (Forbidden): error when creating "STDIN": pods "mutable" is forbidden: ValidatingAdmissionPolicy 'require-container-immutability.security.example.com' with binding 'require-container-immutability-binding' denied request: containers must set securityContext.readOnlyRootFilesystem: true — offending containers: app
```

### 5.3 Kyverno — cuando además querés *mutación* y verificación de imágenes

Las políticas CEL solo pueden validar. Kyverno puede inyectar el campo por vos (enorme para migraciones brownfield) y puede verificar firmas, cosa que VAP no puede.

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: container-immutability
  annotations:
    policies.kyverno.io/title: Enforce container runtime immutability
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    # ── 1. Mutate: default the field in, so teams opt OUT rather than IN ──
    - name: default-read-only-root-filesystem
      match:
        any:
          - resources:
              kinds: ["Pod"]
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "kube-node-lease", "kube-public"]
          - resources:
              annotations:
                security.example.com/immutability-exception: "approved"
      mutate:
        foreach:
          - list: "request.object.spec.containers"
            patchStrategicMerge:
              spec:
                containers:
                  - name: "{{ element.name }}"
                    securityContext:
                      readOnlyRootFilesystem: true
          - list: "request.object.spec.[initContainers][]"
            patchStrategicMerge:
              spec:
                initContainers:
                  - name: "{{ element.name }}"
                    securityContext:
                      readOnlyRootFilesystem: true

    # ── 2. Validate: no hostPath, ever ───────────────────────────────────
    - name: block-hostpath
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "hostPath volumes are forbidden; they bypass container immutability entirely."
        foreach:
          - list: "request.object.spec.[volumes][]"
            deny:
              conditions:
                any:
                  - key: "{{ element.keys(@).contains('hostPath') }}"
                    operator: Equals
                    value: true

    # ── 3. Validate: image immutability by digest ─────────────────────────
    - name: require-digest-pinning
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Images must be referenced by digest: {{ element.image }}"
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ regex_match('^.+@sha256:[a-f0-9]{64}$', '{{ element.image }}') }}"
                    operator: Equals
                    value: false

    # ── 4. Verify: only signed images run (VAP cannot do this) ────────────
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      verifyImages:
        - imageReferences:
            - "ghcr.io/example/*"
          # Rewrite the tag to the verified digest — belt and braces.
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/example/*/.github/workflows/release.yaml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

**Advertencia de diseño.** Un webhook de mutación que *silenciosamente* agrega `readOnlyRootFilesystem: true` va a romper los workloads en tiempo de ejecución en vez de en el momento del `kubectl apply` — el pod se admite y después entra en `CrashLoopBackOff`. Ejecutá la regla 1 en `Audit` durante un ciclo de release completo y publicá el diff a los equipos propietarios antes de aplicarla.

### 5.4 Equivalente en OPA Gatekeeper

```yaml
---
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequirereadonlyrootfilesystem
spec:
  crd:
    spec:
      names:
        kind: K8sRequireReadOnlyRootFilesystem
      validation:
        openAPIV3Schema:
          type: object
          properties:
            exemptImages:
              type: array
              items: { type: string }
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequirereadonlyrootfilesystem

        violation[{"msg": msg}] {
          c := input_containers[_]
          not exempt(c.image)
          not c.securityContext.readOnlyRootFilesystem == true
          msg := sprintf(
            "container <%v> must set securityContext.readOnlyRootFilesystem: true",
            [c.name])
        }

        input_containers[c] { c := input.review.object.spec.containers[_] }
        input_containers[c] { c := input.review.object.spec.initContainers[_] }

        exempt(image) {
          prefix := input.parameters.exemptImages[_]
          startswith(image, trim_suffix(prefix, "*"))
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequireReadOnlyRootFilesystem
metadata:
  name: require-read-only-root-filesystem
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    exemptImages:
      - "registry.k8s.io/apparmor-loader*"
```

### 5.5 Inmutabilidad de imagen a nivel del API server

Habilitá `AlwaysPullImages` en el manifiesto del static pod del kube-apiserver (`/etc/kubernetes/manifests/kube-apiserver.yaml`):

```yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --enable-admission-plugins=NodeRestriction,AlwaysPullImages,ValidatingAdmissionPolicy
        - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit.log
        # ... remaining flags unchanged
```

`AlwaysPullImages` sobrescribe el `imagePullPolicy` de cada contenedor a `Always`. Su valor de seguridad no es la frescura — es que un pod del namespace A ya no puede *usar* una imagen cacheada en el nodo por un pod del namespace B cuyo pull secret no posee. Sin eso, la caché local de imágenes del nodo es una fuga de confidencialidad entre inquilinos.

Confirmá que tuvo efecto:

```console
$ kubectl -n kube-system get pod kube-apiserver-cp-1 \
    -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep enable-admission
"--enable-admission-plugins=NodeRestriction,AlwaysPullImages,ValidatingAdmissionPolicy"

$ kubectl run t --image=busybox:1.36 --restart=Never --command -- sleep 60
pod/t created
$ kubectl get pod t -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
Always
```

Compromiso, explícitamente: `AlwaysPullImages` acopla el arranque de los pods a la disponibilidad del registry. Una caída del registry ahora bloquea *cada* reinicio de pod en todo el clúster, incluso durante una falla de nodo, que es cuando más necesitás capacidad. Mitigalo con un registry de caché pull-through dentro del clúster, y entendé que este es un costo real de disponibilidad pagado a cambio de una ganancia real de confidencialidad.

### 5.6 La regla por defecto de `imagePullPolicy`, que sorprende a todo el mundo

| Referencia de imagen | `imagePullPolicy` omitido → |
|---|---|
| `nginx:1.27.4` | `IfNotPresent` |
| `nginx:latest` | `Always` |
| `nginx` (sin tag) | `Always` |
| `nginx@sha256:…` | `IfNotPresent` |

Las imágenes fijadas por digest usan por defecto `IfNotPresent` — correctamente, ya que el contenido es inmutable por definición. `AlwaysPullImages` anula todo lo anterior.

### 5.7 Eliminar la deriva provocada por humanos con RBAC

La causa abrumadoramente más común de deriva de contenedores en clústeres reales no es un atacante. Es un SRE arreglando algo a las 03:00.

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workload-viewer
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/status", "services", "configmaps", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  # NOTE the deliberate absences:
  #   pods/exec               – interactive shell into a running container
  #   pods/attach             – attach to PID 1
  #   pods/ephemeralcontainers – kubectl debug
  #   pods/portforward        – tunnel to a pod-local service
  # These are the four verbs that turn a read-only operator into one who
  # can mutate a running container. Grant them via a separate, audited,
  # time-boxed break-glass binding.
```

Auditá quién los tiene actualmente:

```console
$ kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
  .items[] | . as $b |
  $b.subjects[]? |
  "\($b.kind)/\($b.metadata.name)\t\(.kind)/\(.name)"' | sort -u > /tmp/bindings

$ kubectl get clusterroles,roles -A -o json | jq -r '
  .items[] | select(.rules[]?.resources[]? | test("pods/(exec|attach|ephemeralcontainers)")) |
  "\(.kind)/\(.metadata.name)"'
ClusterRole/cluster-admin
ClusterRole/admin
ClusterRole/edit
ClusterRole/debug-breakglass
```

Después confirmá que la política de auditoría registre cada uso:

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  # Any mutation of a running container is a Metadata-level event at minimum.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "pods/ephemeralcontainers"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: Metadata
    omitStages: ["RequestReceived"]
```

---

## 6. Detección en tiempo de ejecución: lo que la admisión no puede ver

El control de admisión es una compuerta de un solo disparo en `t=0`. Todo lo posterior es tarea del sensor de runtime.

### 6.1 Reglas de deriva de Falco

El conjunto de reglas upstream de Falco incluye las detecciones relevantes; en las versiones recientes las reglas de deriva viven en el ruleset `falco-incubating` y deben cargarse explícitamente:

```yaml
# /etc/falco/falco.yaml (excerpt)
rules_files:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/falco-incubating_rules.yaml   # contains the drift rules
  - /etc/falco/rules.d                       # our overrides, loaded last

# Prefer the modern eBPF (CO-RE) driver over the kernel module.
engine:
  kind: modern_ebpf
  modern_ebpf:
    cpus_for_each_buffer: 2
```

Reglas personalizadas que codifican *tu* contrato de inmutabilidad:

```yaml
# /etc/falco/rules.d/immutability.yaml
---
- list: immutable_namespaces
  items: [payments, checkout, ledger]

- macro: in_immutable_workload
  condition: (k8s.ns.name in (immutable_namespaces))

- macro: declared_writable_path
  condition: >
    (fd.name startswith /tmp/ or
     fd.name startswith /var/cache/nginx/ or
     fd.name startswith /var/run/ or
     fd.name startswith /dev/stdout or
     fd.name startswith /dev/stderr or
     fd.name startswith /dev/termination-log or
     fd.name startswith /proc/self/)

- rule: Write outside declared writable paths in immutable workload
  desc: >
    A container in an immutability-enforced namespace opened a file for
    writing outside the emptyDir mounts declared in its PodSpec. With
    readOnlyRootFilesystem this should be impossible for the root fs, so a
    hit means either a misdeclared volume or an unexpected writable mount.
  condition: >
    open_write
    and container
    and in_immutable_workload
    and not declared_writable_path
  output: >
    Unexpected write in immutable workload
    (file=%fd.name evt=%evt.type proc=%proc.name cmdline=%proc.cmdline
     user=%user.name uid=%user.uid parent=%proc.pname
     container_id=%container.id image=%container.image.repository
     k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name)
  priority: WARNING
  tags: [container, filesystem, immutability, mitre_persistence, T1543]

- rule: New executable created inside container
  desc: >
    A file was created and made executable inside a container. This is the
    canonical "drop a tool and chmod +x" step (MITRE T1105 -> T1059).
  condition: >
    chmod
    and container
    and (evt.arg.mode contains "S_IXUSR" or
         evt.arg.mode contains "S_IXGRP" or
         evt.arg.mode contains "S_IXOTH")
    and not proc.name in (dpkg, rpm, apk, pip, npm)
  output: >
    File made executable inside container
    (file=%evt.arg.filename mode=%evt.arg.mode proc=%proc.name
     cmdline=%proc.cmdline container_id=%container.id
     image=%container.image.repository k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, filesystem, mitre_execution, T1105]

- rule: Fileless execution via memfd
  desc: >
    Execution from an anonymous memory file descriptor. Defeats
    readOnlyRootFilesystem, AppArmor path rules and SELinux file contexts,
    because no path is ever touched (MITRE T1620).
  condition: >
    spawned_process
    and container
    and proc.exepath startswith "memfd:"
  output: >
    Fileless execution detected
    (exepath=%proc.exepath proc=%proc.name cmdline=%proc.cmdline
     parent=%proc.pname user=%user.name container_id=%container.id
     image=%container.image.repository k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name)
  priority: CRITICAL
  tags: [container, process, mitre_defense_evasion, T1620]
```

Salida en vivo durante un compromiso simulado:

```console
$ kubectl exec -n payments deploy/legacy-batch -- sh -c 'cp /bin/busybox /tmp/nc && chmod +x /tmp/nc'

$ kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=20 | grep -i immutab
16:04:22.951231455: Warning Unexpected write in immutable workload (file=/tmp/nc evt=openat proc=cp cmdline=cp /bin/busybox /tmp/nc user=root uid=0 parent=sh container_id=3f2b0c9a1d77 image=docker.io/library/debian k8s_ns=payments k8s_pod=legacy-batch-6c9f7d5b84-q2xzt)
16:04:22.958604112: Critical File made executable inside container (file=/tmp/nc mode=S_IXUSR|S_IXGRP|S_IXOTH|S_IRUSR|S_IRGRP|S_IROTH|S_IWUSR proc=chmod cmdline=chmod +x /tmp/nc container_id=3f2b0c9a1d77 image=docker.io/library/debian k8s_ns=payments k8s_pod=legacy-batch-6c9f7d5b84-q2xzt)
```

Notá que esto se disparó por una escritura en `/tmp` — exactamente la superficie que `readOnlyRootFilesystem` no puede cubrir. Esa es la división del trabajo entre los dos controles, demostrada.

Reglas upstream que vale la pena habilitar por nombre, en lugar de reescribirlas:

| Regla de Falco | Detecta |
|---|---|
| `Drop and execute new binary in container` | Ejecución de un binario que no estaba presente en la imagen |
| `Container Drift Detected (open+create)` | `O_CREAT` sobre una ruta que no existía en la imagen |
| `Container Drift Detected (chmod)` | `chmod +x` sobre un archivo del contenedor |
| `Write below binary dir` | Escrituras bajo `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin` |
| `Write below etc` | Manipulación de configuración |
| `Fileless execution via memfd_create` | Ejecución basada en `memfd` |
| `Launch Package Management Process in Container` | `apt`/`yum`/`apk` en tiempo de ejecución |

### 6.2 Detección de deriva offline: diff del directorio superior del overlay

Falco es un flujo. A veces necesitás una respuesta puntual a "¿este contenedor divergió de su imagen?" — el equivalente de `docker diff`, que `crictl` no provee. Leé directamente el snapshotter de containerd en el nodo:

```console
$ CID=$(sudo crictl ps -q --name legacy-batch --state Running | head -1)
$ echo "$CID"
3f2b0c9a1d7742a9f0b3e8c1d6a5b4c3928170e6f5d4c3b2a1908f7e6d5c4b3a

$ SNAP=$(sudo ctr -n k8s.io containers info "$CID" | jq -r '.SnapshotKey')
$ echo "$SNAP"
3f2b0c9a1d7742a9f0b3e8c1d6a5b4c3928170e6f5d4c3b2a1908f7e6d5c4b3a

$ UPPER=$(sudo ctr -n k8s.io snapshots mounts /tmp/inspect "$SNAP" \
          | tr ',' '\n' | sed -n 's/^upperdir=//p')
$ echo "$UPPER"
/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/2417/fs

# Everything below is a divergence from the image layers.
$ sudo find "$UPPER" -mindepth 1 \( -type f -o -type l \) -printf '%M %10s %TY-%Tm-%Td %TH:%TM %P\n'
-rw-r--r--      12288 2026-08-05 16:01 var/lib/dpkg/lock-frontend
-rwxr-xr-x    1183448 2026-08-05 16:04 usr/bin/nc
-rw-r--r--        842 2026-08-05 16:05 etc/cron.d/sync
-rw-r--r--       4096 2026-08-05 15:58 var/log/app.log

# Whiteout entries (character device, 0/0) mark files DELETED from the image.
$ sudo find "$UPPER" -type c -printf '%P\n'
usr/bin/apt
etc/ssl/certs/ca-certificates.crt
```

`usr/bin/nc`, `etc/cron.d/sync` y un bundle de CA eliminado: este contenedor está comprometido. Dos archivos (`var/lib/dpkg/lock-frontend`, `var/log/app.log`) son benignos pero se habrían evitado de plano con `readOnlyRootFilesystem` más un `emptyDir` en `/var/log`.

Barrido en toda la flota, como DaemonSet de nodo o como bucle por SSH:

```console
$ for cid in $(sudo crictl ps -q); do
    name=$(sudo crictl inspect "$cid" | jq -r '.status.metadata.name')
    ns=$(sudo crictl inspect "$cid" | jq -r '.status.labels["io.kubernetes.pod.namespace"]')
    ro=$(sudo crictl inspect "$cid" | jq -r '.info.runtimeSpec.root.readonly')
    snap=$(sudo ctr -n k8s.io containers info "$cid" 2>/dev/null | jq -r '.SnapshotKey')
    upper=$(sudo ctr -n k8s.io snapshots mounts /tmp/x "$snap" 2>/dev/null | tr ',' '\n' | sed -n 's/^upperdir=//p')
    n=$( [ -n "$upper" ] && sudo find "$upper" -mindepth 1 -type f 2>/dev/null | wc -l || echo "?" )
    printf '%-16s %-28s ro=%-5s drifted_files=%s\n' "$ns" "$name" "$ro" "$n"
  done
kube-system      kube-proxy                   ro=false drifted_files=3
payments         nginx                        ro=true  drifted_files=0
payments         legacy-batch                 ro=false drifted_files=417
observability    otel-collector               ro=true  drifted_files=0
```

`drifted_files=417` en `legacy-batch` es tu backlog de remediación, ya priorizado.

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Auditoría de cumplimiento en toda la flota

```console
$ kubectl get pods -A -o json | jq -r '
  .items[] as $p |
  ($p.spec.containers + ($p.spec.initContainers // []))[] |
  select((.securityContext.readOnlyRootFilesystem // false) != true) |
  [$p.metadata.namespace, $p.metadata.name, .name, .image] | @tsv' \
  | column -t -s $'\t' | head -20
observability  loki-0                        loki       grafana/loki:3.4.1
observability  promtail-mn4kd                promtail   grafana/promtail:3.4.1
payments       legacy-batch-6c9f7d5b84-q2xzt app        docker.io/library/debian:12
kube-system    coredns-6f9d84b7c9-w2hnp      coredns    registry.k8s.io/coredns/coredns:v1.12.0
```

Agregá por workload propietario en vez de por pod, para que el informe se corresponda con los equipos:

```console
$ kubectl get pods -A -o json | jq -r '
  .items[] as $p |
  ($p.metadata.ownerReferences[0].name // $p.metadata.name) as $owner |
  ($p.spec.containers + ($p.spec.initContainers // []))[] |
  select((.securityContext.readOnlyRootFilesystem // false) != true) |
  "\($p.metadata.namespace)/\($owner)"' | sort | uniq -c | sort -rn
     12 observability/promtail
      6 payments/legacy-batch-6c9f7d5b84
      2 kube-system/coredns-6f9d84b7c9
```

Vista compacta por contenedor:

```console
$ kubectl get pods -n payments -o custom-columns=\
'POD:.metadata.name,CONTAINER:.spec.containers[*].name,RO_ROOTFS:.spec.containers[*].securityContext.readOnlyRootFilesystem,PRIVESC:.spec.containers[*].securityContext.allowPrivilegeEscalation,IMAGE:.spec.containers[*].image'
POD                             CONTAINER   RO_ROOTFS   PRIVESC   IMAGE
edge-5b8f7c9d64-4nfgm           nginx       true        false     docker.io/nginxinc/nginx-unprivileged@sha256:9f7cd4d4...
edge-5b8f7c9d64-7xk2p           nginx       true        false     docker.io/nginxinc/nginx-unprivileged@sha256:9f7cd4d4...
legacy-batch-6c9f7d5b84-q2xzt   app         <none>      <none>    docker.io/library/debian:12
```

### 7.2 Verificación positiva — probá la aplicación, no la infieras

Nunca aceptes un campo en verde en el spec como prueba. Probá el comportamiento:

```console
# 1. The API server thinks it is set.
$ kubectl get pod -n payments -l app.kubernetes.io/name=edge \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}{end}'
edge-5b8f7c9d64-4nfgm	true
edge-5b8f7c9d64-7xk2p	true
edge-5b8f7c9d64-9pmr8	true

# 2. The kernel agrees.
$ kubectl exec -n payments deploy/edge -c nginx -- grep -m1 ' / ' /proc/self/mountinfo
1877 1876 0:143 / / ro,relatime master:412 - overlay overlay rw,lowerdir=...

# 3. A write actually fails.
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'touch /usr/bin/backdoor'
touch: /usr/bin/backdoor: Read-only file system
command terminated with exit code 1

# 4. The declared writable island actually works.
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'touch /tmp/probe && ls -l /tmp/probe'
-rw-r--r--    1 nginx    nginx            0 Aug  5 16:11 /tmp/probe

# 5. tmpfs sizeLimit is really applied as the mount option.
$ kubectl exec -n payments deploy/edge -c nginx -- sh -c 'grep " /tmp " /proc/self/mountinfo'
1901 1877 0:152 / /tmp rw,relatime - tmpfs tmpfs rw,size=65536k,inode64

# 6. Capabilities and no-new-privs.
$ kubectl exec -n payments deploy/edge -c nginx -- grep -E 'CapEff|NoNewPrivs' /proc/self/status
NoNewPrivs:	1
CapEff:	0000000000000000

# 7. seccomp mode 2 (filtered).
$ kubectl exec -n payments deploy/edge -c nginx -- grep Seccomp /proc/self/status
Seccomp:	2
Seccomp_filters:	1
```

`CapEff: 0000000000000000` y `Seccomp: 2` son las dos líneas que hay que buscar. Cualquier otra cosa y el securityContext no tuvo efecto de la manera que creés.

### 7.3 Depurar un contenedor distroless y de solo lectura

No podés hacer `kubectl exec` — no hay shell. Los contenedores efímeros comparten los namespaces del objetivo sin modificarlo:

```console
$ kubectl debug -n payments -it edge-5b8f7c9d64-4nfgm \
    --image=nicolaka/netshoot:v0.13 \
    --target=nginx \
    --profile=general \
    -- bash
Targeting container "nginx". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-x7k2m.
If you don't see a command prompt, try pressing enter.

debugger:~# ps aux
PID   USER     TIME  COMMAND
    1 101       0:00 nginx: master process nginx -g daemon off; -c /etc/nginx/nginx.conf
   29 101       0:00 nginx: worker process
   47 root      0:00 bash
   58 root      0:00 ps aux

# The target's root filesystem, reachable through /proc
debugger:~# ls -la /proc/1/root/usr/share/nginx/html
total 16
drwxr-xr-x    2 root  root  4096 Jan 14 00:00 .
drwxr-xr-x    3 root  root  4096 Jan 14 00:00 ..
-rw-r--r--    1 root  root   497 Jan 14 00:00 50x.html
-rw-r--r--    1 root  root   615 Jan 14 00:00 index.html

# The target's mount flags, from outside the target
debugger:~# grep -E ' / | /tmp ' /proc/1/mountinfo
1877 1876 0:143 / / ro,relatime master:412 - overlay overlay rw,lowerdir=...
1901 1877 0:152 / /tmp rw,relatime - tmpfs tmpfs rw,size=65536k,inode64

# Confirm the debug container itself is a separate, writable filesystem —
# this is why the VAP in 5.2 deliberately excludes ephemeral containers.
debugger:~# touch /root/scratch && echo ok
ok
```

Dos prerrequisitos que se suelen pasar por alto:

- `--target` requiere que el CRI soporte el direccionamiento del namespace de procesos. containerd ≥ 1.4 y CRI-O lo soportan; si el flag se ignora silenciosamente, solo vas a ver el PID 1 del propio contenedor de depuración.
- `--profile=general` (o `restricted`, `netadmin`, `sysadmin`) controla el securityContext del contenedor de depuración. Bajo un namespace con PSA `restricted`, el perfil por defecto puede ser rechazado — usá `--profile=restricted`.

### 7.4 Encontrar todas las rutas en las que escribe un workload, antes de aplicar la política

La pregunta de migración siempre es "¿en qué directorios escribe realmente esta cosa?". Tres técnicas, en orden de preferencia:

**(a) Reproducción local — la más rápida, sin clúster de por medio.**

```console
$ docker run --rm --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -p 8080:8080 \
    docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine
2026/08/05 16:20:41 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)

$ docker run --rm --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --tmpfs /var/cache/nginx:rw,size=32m \
    docker.io/nginxinc/nginx-unprivileged:1.27.4-alpine
2026/08/05 16:21:12 [emerg] 1#1: open() "/tmp/nginx.pid" failed (2: No such file or directory)
```

Iterá hasta que arranque. Cada `EROFS` nombra exactamente un directorio a agregar.

**(b) Diff del upperdir del overlay después de una ejecución representativa** — §6.2. Esto captura rutas que una prueba de humo sintética nunca ejercita, como una rotación de logs una vez al día.

**(c) Trazado de syscalls, cuando (a) y (b) no coinciden.**

```console
$ kubectl debug -n payments -it legacy-batch-6c9f7d5b84-q2xzt \
    --image=nicolaka/netshoot:v0.13 --target=app \
    --profile=sysadmin -- bash

debugger:~# strace -f -qq -e trace=creat,open,openat,mkdir,unlink,rename -p 1 2>&1 \
              | grep -vE 'O_RDONLY|ENOENT' | awk -F'"' '{print $2}' | sort -u
/var/log/app/audit.log
/var/lib/app/session.db
/run/app.pid
```

`--profile=sysadmin` otorga `SYS_PTRACE`, que `strace` necesita. Usalo en un namespace de staging; no dejes en producción un binding que lo permita.

### 7.5 Referencia de firmas de falla

| Síntoma | errno / evento | Causa raíz | Remediación |
|---|---|---|---|
| `Read-only file system` en los logs, `CrashLoopBackOff` | `EROFS` (30) | Escritura sobre el rootfs de solo lectura | Montar un `emptyDir` en esa ruta, o reubicar la escritura vía configuración |
| `Permission denied` en un `emptyDir` montado | `EACCES` (13) | `runAsNonRoot` + volumen cuyo dueño es root | Definir `securityContext.fsGroup`; agregar `fsGroupChangePolicy: OnRootMismatch` para evitar un chown recursivo completo en cada arranque |
| `No space left on device` en un montaje tmpfs | `ENOSPC` (28) | `sizeLimit` del `emptyDir` respaldado por memoria demasiado chico | Subir `sizeLimit` **y** `resources.limits.memory` a la vez |
| Estado del pod `Evicted`, mensaje `… exceeds the local ephemeral storage limit` | expulsión | `emptyDir` respaldado por disco por encima de `sizeLimit`, detectado en el mantenimiento de ~10 s | Subir `sizeLimit`; mover el estado genuino a un PVC |
| Pod `OOMKilled` poco después de E/S temporal intensa | OOM del cgroup | Páginas de tmpfs cargadas al límite de memoria del contenedor | Incluir el `sizeLimit` del tmpfs en `limits.memory` |
| `CreateContainerError`, `apparmor profile is not loaded` | kubelet | Perfil referenciado pero ausente en ese nodo | Desplegar el DaemonSet cargador; agregar una `nodeAffinity` o esperar a que el cargador esté Ready |
| `container has runAsNonRoot and image will run as root` | kubelet | El `USER` de la imagen es root o el UID numérico no se puede resolver | Definir un `runAsUser` numérico; corregir el `USER` del Dockerfile |
| El pod nunca se crea; el `kubectl apply` de un **Deployment** tiene éxito | admisión | La VAP/webhook deniega el **Pod**, no el Deployment | `kubectl describe rs` — ver más abajo |
| Falco en silencio después de actualizar el kernel del nodo | driver | Desajuste del módulo de kernel / sonda eBPF | Cambiar a `engine.kind: modern_ebpf` (CO-RE, sin driver por kernel) |

La indirección Deployment/Pod merece su propio ejemplo trabajado, porque es la consecuencia operativa más confusa de una política de admisión a nivel de pod:

```console
$ kubectl apply -f deploy-noncompliant.yaml
deployment.apps/legacy-batch created           # <-- succeeds!

$ kubectl get deploy legacy-batch -n payments
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
legacy-batch   0/3     0            0           24s

$ kubectl describe rs -n payments -l app=legacy-batch | tail -8
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  22s (x4 over 24s)  replicaset-controller  Error creating: pods "legacy-batch-6c9f7d5b84-" is forbidden: ValidatingAdmissionPolicy 'require-container-immutability.security.example.com' with binding 'require-container-immutability-binding' denied request: containers must set securityContext.readOnlyRootFilesystem: true — offending containers: app
  Warning  FailedCreate  12s (x3 over 20s)  replicaset-controller  (combined from similar events): Error creating: pods "legacy-batch-6c9f7d5b84-" is forbidden: ...
```

Mitigá el costo de experiencia de usuario agregando `Warn` a `validationActions` — el API server entonces devuelve un encabezado de advertencia en el apply del *Deployment*, que `kubectl` imprime de inmediato:

```console
$ kubectl apply -f deploy-noncompliant.yaml
Warning: ValidatingAdmissionPolicy 'require-container-immutability.security.example.com' ... containers must set securityContext.readOnlyRootFilesystem: true — offending containers: app
deployment.apps/legacy-batch created
```

### 7.6 Un manual de migración que sobrevivió al contacto con equipos reales

1. **Medir.** Ejecutá la auditoría de §7.1; publicá los conteos por equipo propietario, no por pod.
2. **Observar.** Vinculá la VAP con `validationActions: ["Audit","Warn"]`. No se rompe nada. Recolectá dos semanas de datos.
3. **Descubrir las rutas de escritura** por workload con §7.4(a) y (b). Producí un PR por workload que agregue los montajes `emptyDir` *y* `readOnlyRootFilesystem: true` en el mismo commit — nunca por separado, o entregás un estado intermedio roto.
4. **Canario.** Una réplica, `maxUnavailable: 0`, tráfico real, 24 h. Vigilá `EROFS` en los logs y los contadores de reinicio de pods, no solo la disponibilidad.
5. **Aplicar por namespace.** Pasá el binding a `Deny` solo para los namespaces que ya estén en cero violaciones. El `namespaceSelector` de §5.2 hace que esto sea un cambio de una sola etiqueta.
6. **Detectar el resto.** Los workloads con una anotación de excepción firmada reciben cobertura compensatoria de Falco según §6.1 y una fecha de revisión.
7. **Trinquete.** Un job trimestral que hace fallar CI si la lista de excepciones creció.

---

## 8. Referencia rápida para el día del examen

```console
# Add readOnlyRootFilesystem to an existing deployment, imperatively.
$ kubectl patch deploy edge -n payments --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/securityContext/readOnlyRootFilesystem","value":true}
  ]'
deployment.apps/edge patched

# If securityContext does not exist yet, create the whole object first.
$ kubectl patch deploy edge -n payments --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/securityContext",
     "value":{"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,
              "capabilities":{"drop":["ALL"]}}}
  ]'

# Add the writable emptyDir in one shot.
$ kubectl patch deploy edge -n payments --type=json -p='[
    {"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"tmp","emptyDir":{"medium":"Memory","sizeLimit":"64Mi"}}]},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"tmp","mountPath":"/tmp"}]}
  ]'

# Field reference, straight from the API server — no internet needed.
$ kubectl explain pod.spec.containers.securityContext.readOnlyRootFilesystem
KIND:       Pod
VERSION:    v1

FIELD: readOnlyRootFilesystem <boolean>

DESCRIPTION:
    Whether this container has a read-only root filesystem. Default is false.
    Note that this field cannot be set when spec.os.name is windows.

$ kubectl explain pod.spec.volumes.emptyDir
```

Seis hechos que deciden la pregunta:

1. `readOnlyRootFilesystem` vive en el `securityContext` del **contenedor**, nunca en el de nivel de pod. No hay equivalente a nivel de pod.
2. También hay que definirlo en los **initContainers**. Los auditores y las políticas los revisan; la gente los olvida.
3. Afecta **solo al sistema de archivos raíz**. Los volúmenes montados siguen siendo escribibles salvo que además pongas `readOnly: true` en el `volumeMount`.
4. Los volúmenes `configMap`, `secret`, `downwardAPI` y `projected` se montan **siempre** de solo lectura.
5. PSS `restricted` **no** lo exige.
6. No se puede definir cuando `spec.os.name: windows`.

---

## 9. Referencias

**Documentación oficial de Kubernetes**

- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Security Context API reference (`SecurityContext` v1) — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Volumes: `emptyDir` — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Local ephemeral storage and `sizeLimit` — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage
- Images and `imagePullPolicy` defaults — https://kubernetes.io/docs/concepts/containers/images/
- Admission controllers reference (`AlwaysPullImages`, `ImagePolicyWebhook`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Assign SELinux labels to a container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#assign-selinux-labels-to-a-container
- Immutable ConfigMaps and Secrets — https://kubernetes.io/docs/concepts/configuration/configmap/#configmap-immutable
- Ephemeral Containers — https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- Debug Running Pods (`kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Security Checklist — https://kubernetes.io/docs/concepts/security/security-checklist/

**CNCF / certificación**

- CKS Curriculum v1.34 (PDF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF curriculum repository — https://github.com/cncf/curriculum
- CKS Exam Program — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Runtime, OCI e internals de Linux**

- OCI Runtime Specification — `config.json` `root.readonly` — https://github.com/opencontainers/runtime-spec/blob/main/config.md#root
- OCI Runtime Spec, Linux `maskedPaths` / `readonlyPaths` — https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#masked-paths
- runc — https://github.com/opencontainers/runc
- containerd documentation — https://containerd.io/docs/
- `crictl` user guide — https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md
- Linux `overlayfs` documentation — https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
- `seccomp(2)` manual page — https://man7.org/linux/man-pages/man2/seccomp.2.html
- `memfd_create(2)` manual page — https://man7.org/linux/man-pages/man2/memfd_create.2.html
- AppArmor documentation — https://gitlab.com/apparmor/apparmor/-/wikis/Documentation

**Motores de política y seguridad en tiempo de ejecución**

- Falco documentation — https://falco.org/docs/
- Falco default and incubating rules — https://github.com/falcosecurity/rules
- Kyverno policy documentation — https://kyverno.io/docs/
- Kyverno policy library — https://kyverno.io/policies/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Cilium Tetragon — https://tetragon.io/docs/
- Sigstore / cosign — https://docs.sigstore.dev/

**Guías de endurecimiento y modelos de amenaza**

- NSA/CISA Kubernetes Hardening Guide — https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- MITRE ATT&CK for Containers — https://attack.mitre.org/matrices/enterprise/containers/
- MITRE ATT&CK T1610 / T1611 / T1105 / T1620 — https://attack.mitre.org/techniques/T1611/
- Distroless container images — https://github.com/GoogleContainerTools/distroless
- `crane` (go-containerregistry) — https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md
- `skopeo` — https://github.com/containers/skopeo