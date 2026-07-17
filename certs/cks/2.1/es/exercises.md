# CKS 2.1 — Use appropriate Pod Security Standards

> Referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

Los **Pod Security Standards (PSS)** definen tres niveles de restricción para Pods — `Privileged`, `Baseline` y `Restricted` — que se aplican mediante el **Pod Security Admission (PSA)**, un admission controller incorporado en el `kube-apiserver` (GA desde v1.25, reemplazo de `PodSecurityPolicy`, eliminado en esa misma versión). PSA se activa por `namespace` mediante labels, sin necesidad de webhooks externos.

Vas a necesitar un cluster donde puedas crear namespaces y aplicar Pods (`minikube`, `kind` o similar sirven).

---

## Bloque 1 — Niveles de PSS y enforcement por namespace

1. Creá un namespace de prueba:
   ```bash
   kubectl create namespace restricted-ns
   ```

2. Etiquetalo para que el nivel `restricted` se aplique en modo `enforce`:
   ```bash
   kubectl label namespace restricted-ns \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=latest
   ```

3. Confirmá las labels:
   ```bash
   kubectl get ns restricted-ns --show-labels
   ```

4. Intentá crear un Pod privilegiado:
   ```yaml
   # pod-privileged.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-privileged
     namespace: restricted-ns
   spec:
     containers:
     - name: app
       image: nginx:1.27
       securityContext:
         privileged: true
   ```
   ```bash
   kubectl apply -f pod-privileged.yaml
   ```
   Leé el mensaje de error devuelto por el API server.

5. Intentá crear un Pod que monte un volumen `hostPath` (sin `privileged`):
   ```yaml
   # pod-hostpath.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-hostpath
     namespace: restricted-ns
   spec:
     containers:
     - name: app
       image: nginx:1.27
       volumeMounts:
       - name: host-data
         mountPath: /data
     volumes:
     - name: host-data
       hostPath:
         path: /var/data
   ```
   ```bash
   kubectl apply -f pod-hostpath.yaml
   ```

6. Intentá crear un Pod "normal", sin ningún `securityContext`:
   ```yaml
   # nginx-minimo.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-minimo
     namespace: restricted-ns
   spec:
     containers:
     - name: nginx
       image: nginx:1.27
   ```
   ```bash
   kubectl apply -f nginx-minimo.yaml
   ```
   Contá cuántas violaciones distintas lista el error.

**Preguntas de comprensión — Bloque 1**

1. ¿Qué diferencia de alcance hay entre los niveles `Privileged`, `Baseline` y `Restricted`?
2. El Pod del paso 5 no pide privilegios especiales, ¿por qué es rechazado igual bajo `restricted`?
3. ¿Qué diferencia hay entre fijar `enforce-version=latest` y fijarlo a una versión puntual como `v1.32`?

---

## Bloque 2 — Corregir un manifiesto para que cumpla `Restricted`

1. Reescribí el Pod para que cumpla `Restricted`, usando una imagen que sí corre sin root (`nginx:1.27` estándar necesita bind a puerto 80, que requiere root):
   ```yaml
   # nginx-restricted.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-restricted
     namespace: restricted-ns
   spec:
     securityContext:
       runAsNonRoot: true
       seccompProfile:
         type: RuntimeDefault
     containers:
     - name: nginx
       image: nginxinc/nginx-unprivileged:1.27
       securityContext:
         allowPrivilegeEscalation: false
         runAsNonRoot: true
         runAsUser: 101
         capabilities:
           drop:
           - ALL
   ```

2. Aplicalo y confirmá que el Pod queda `Running`:
   ```bash
   kubectl apply -f nginx-restricted.yaml
   kubectl get pod nginx-restricted -n restricted-ns
   ```

3. Verificá el UID efectivo dentro del contenedor:
   ```bash
   kubectl exec -n restricted-ns nginx-restricted -- id
   ```

4. Editá el manifiesto para agregar `capabilities.add: [NET_ADMIN]` y volvé a aplicar. Observá el rechazo.

5. Cambiá esa capability agregada por `NET_BIND_SERVICE` y volvé a aplicar. Observá que esta vez es admitida.

**Preguntas de comprensión — Bloque 2**

1. Bajo `Restricted`, ¿cuál es la única capability que un contenedor puede agregar con `capabilities.add`?
2. Si hubieras usado la imagen `nginx:1.27` estándar en el paso 1 en lugar de `nginx-unprivileged`, el Pod habría sido *admitido* igual por el API server. ¿Por qué, y en qué estado terminaría probablemente?
3. ¿Por qué `Restricted` exige `seccompProfile.type` explícito (`RuntimeDefault` o `Localhost`) en vez de aceptar que quede sin definir?

---

## Bloque 3 — Migración gradual con `audit` y `warn`

1. Cambiá el namespace para aplicar `enforce` en `baseline`, y `warn`/`audit` en `restricted` (para detectar violaciones sin bloquear todavía):
   ```bash
   kubectl label namespace restricted-ns \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=latest \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/warn-version=latest \
     pod-security.kubernetes.io/audit=restricted \
     pod-security.kubernetes.io/audit-version=latest \
     --overwrite
   ```

2. Probá el Pod mínimo del Bloque 1 (`nginx-minimo.yaml`) con `--dry-run=server`:
   ```bash
   kubectl apply -f nginx-minimo.yaml --dry-run=server
   ```
   Observá los `Warning:` que devuelve el API server. Confirmá que el Pod **no** quedó creado:
   ```bash
   kubectl get pod nginx-minimo -n restricted-ns
   ```

3. Aplicalo ahora sin `--dry-run`:
   ```bash
   kubectl apply -f nginx-minimo.yaml
   ```
   Notá que el Pod se crea igual (cumple `baseline`), pero los warnings de `restricted` se siguen mostrando.

4. Si tenés audit logging habilitado en el `kube-apiserver`, buscá en el audit log la anotación `pod-security.kubernetes.io/audit-violations` asociada al evento de creación de `nginx-minimo`.

5. Una vez que todos los workloads del namespace cumplan `restricted` (Bloque 2), promové el enforcement:
   ```bash
   kubectl label namespace restricted-ns \
     pod-security.kubernetes.io/enforce=restricted \
     --overwrite
   ```

**Preguntas de comprensión — Bloque 3**

1. ¿Cuál es el beneficio práctico de configurar `warn`/`audit` en un nivel más estricto que `enforce` antes de migrar?
2. ¿`--dry-run=server` dispara los warnings de `pod-security.kubernetes.io/warn`? ¿Crea el Pod?
3. `PodSecurityPolicy` fue eliminado en v1.25. ¿Qué lo reemplazó como mecanismo nativo, y es un webhook externo o algo incorporado al `kube-apiserver`?

---

<details>
<summary>Respuestas</summary>

**Bloque 1**

1. `Privileged` no impone ninguna restricción (equivale a no tener PSS). `Baseline` bloquea los vectores de escalamiento de privilegios más conocidos (contenedores privilegiados, namespaces de host, `hostPath`, capabilities fuera de la lista por defecto, etc.) pero sigue siendo permisivo para facilitar la adopción amplia. `Restricted` aplica todo lo de `Baseline` y además fuerza buenas prácticas de hardening: `runAsNonRoot`, `allowPrivilegeEscalation: false`, `seccompProfile` explícito y `capabilities.drop: [ALL]` con como máximo `NET_BIND_SERVICE` agregada.
2. Porque `hostPath` es una de las verificaciones de `Baseline` (no solo de `Restricted`): montar el filesystem del nodo permite eludir el aislamiento del contenedor incluso sin `privileged: true`, así que está prohibido en ambos niveles.
3. `enforce-version=latest` hace que el namespace siga automáticamente las reglas más nuevas de PSS a medida que el cluster se actualiza (puede endurecerse solo tras un upgrade). Fijar una versión puntual (`v1.32`) "congela" el comportamiento de validación a esa versión, evitando que un upgrade de cluster rompa Pods que antes pasaban, a costa de no recibir automáticamente controles nuevos.

**Bloque 2**

1. `NET_BIND_SERVICE` (permite bindear puertos <1024 sin ser root). Cualquier otra capability agregada es rechazada.
2. El Pod es admitido porque el manifiesto en sí (los campos de `securityContext`) cumple `Restricted` — PSA solo valida la especificación del Pod, no el comportamiento en runtime. Pero `nginx:1.27` estándar necesita root para bindear el puerto 80 y escribir en `/var/cache/nginx` y `/var/run`; al forzar `runAsNonRoot`/`runAsUser: 101` sin usar la imagen unprivileged, el proceso falla al arrancar y el Pod termina en `CrashLoopBackOff`.
3. Porque dejar `seccompProfile` sin definir puede heredar el comportamiento por defecto del container runtime, que en versiones o configuraciones antiguas equivale a `Unconfined` (sin filtrado de syscalls). `Restricted` exige que el perfil quede explícito y auditable (`RuntimeDefault` o `Localhost`) para garantizar que siempre haya filtrado de syscalls activo, sin depender de la configuración del nodo.

**Bloque 3**

1. Permite detectar qué workloads violarían el nivel más estricto (vía warnings al cliente y/o anotaciones en el audit log) sin bloquear nada todavía, dando tiempo a corregir manifiestos antes de subir `enforce` y romper despliegues en producción.
2. Sí, dispara los warnings igual que un apply real, porque el API server valida el objeto contra PSA antes de decidir si lo persiste. Pero con `--dry-run=server` el objeto no se persiste ni se crea el Pod — solo se devuelve la respuesta de validación.
3. Lo reemplazó el **Pod Security Admission (PSA)**, que no es un webhook externo sino un admission controller incorporado (in-tree) en el propio `kube-apiserver`, configurado por labels de namespace en lugar de objetos `PodSecurityPolicy` cluster-wide.

</details>