# CKS 6.4 — Garantizar la Inmutabilidad de los Contenedores en Tiempo de Ejecución
## Ejercicios Guiados (versión de examen 1.34 · peso del dominio 4%)

> **Qué significa "inmutabilidad" en el contexto de CKS.** Un contenedor es inmutable cuando su sistema de archivos no puede modificarse después de arrancar, cuando no puede agregársele nada que no estuviera en la imagen, y cuando la imagen misma no puede cambiar bajo una referencia estable. En la práctica esto son cuatro controles independientes, y el examen evalúa los cuatro:
> 1. `securityContext.readOnlyRootFilesystem: true` — la capa del contenedor se monta `ro`.
> 2. Superficies de escritura explícitas únicamente (`emptyDir`, `tmpfs`) en las rutas que el proceso realmente necesita.
> 3. Una imagen mínima (sin shell, sin gestor de paquetes, con UID no-root incorporado).
> 4. Aplicación en tiempo de admisión para que lo anterior no pueda omitirse, más fijación por digest para que el tag no pueda intercambiarse por debajo tuyo.

### Prerrequisitos

- Un clúster en **v1.34** (`kubeadm` o `kind`), `kubectl` como `cluster-admin`.
- SSH root en al menos un nodo worker, con `crictl` y `jq` disponibles (necesarios en los Ejercicios 4 y 8).
- Acceso saliente a `docker.io` y `registry.k8s.io`.

```bash
kubectl version --short
# Client Version: v1.34.0
# Server Version: v1.34.0

kubectl create namespace immutability-lab
kubectl config set-context --current --namespace=immutability-lab
```

---

## Ejercicio 1 — Establecer la línea base: cuánto daño permite un contenedor mutable

1. Creá un Pod deliberadamente sin endurecer:

```yaml
# 01-mutable.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mutable-app
  namespace: immutability-lab
spec:
  containers:
    - name: app
      image: nginx:1.27
      ports:
        - containerPort: 80
```

```bash
kubectl apply -f 01-mutable.yaml
kubectl wait --for=condition=Ready pod/mutable-app --timeout=60s
```

2. Confirmá la identidad bajo la que corre el proceso:

```bash
kubectl exec mutable-app -- id
# uid=0(root) gid=0(root) groups=0(root)
```

3. Desfigurá el contenido servido — una escritura en la propia capa de la imagen:

```bash
kubectl exec mutable-app -- sh -c \
  'echo "<h1>compromised</h1>" > /usr/share/nginx/html/index.html'
kubectl exec mutable-app -- cat /usr/share/nginx/html/index.html
# <h1>compromised</h1>
```

4. Plantá un ejecutable que nunca fue parte de la imagen, y ejecutalo:

```bash
kubectl exec mutable-app -- sh -c 'cp /bin/sh /usr/local/bin/backdoor && chmod 4755 /usr/local/bin/backdoor'
kubectl exec mutable-app -- ls -l /usr/local/bin/backdoor
# -rwsr-xr-x 1 root root 125688 Aug  5 10:04 /usr/local/bin/backdoor
kubectl exec mutable-app -- /usr/local/bin/backdoor -c 'id'
# uid=0(root) gid=0(root) groups=0(root)
```

5. Confirmá que la imagen incluye un gestor de paquetes, es decir, que un atacante puede descargar herramientas arbitrarias:

```bash
kubectl exec mutable-app -- sh -c 'command -v apt-get; command -v curl; command -v sh'
# /usr/bin/apt-get
# /usr/bin/curl
# /bin/sh
```

6. Comprobá que la modificación *no* es visible para el API server — la especificación del Pod está sin cambios:

```bash
kubectl get pod mutable-app -o jsonpath='{.spec.containers[0].image}{"\n"}'
# nginx:1.27
```

**Comprobá tu comprensión**

- **Q1.** El sistema de archivos del contenedor ahora difiere de la imagen que dice estar ejecutando. ¿Qué objeto de Kubernetes registra esa desviación, y qué te dice eso sobre detectar esta clase de ataque solo con `kubectl`?
- **Q2.** Si este Pod es parte de un Deployment con 3 réplicas y el atacante modifica solo un Pod, ¿qué hace que el compromiso sea a la vez más difícil de detectar y auto-reparable desde el punto de vista del atacante?
- **Q3.** El paso 4 activó el bit setuid. ¿Bajo qué circunstancia eso realmente ayuda al atacante dentro de un contenedor, y qué campo de `securityContext` lo neutraliza independientemente de `readOnlyRootFilesystem`?

---

## Ejercicio 2 — Activar `readOnlyRootFilesystem` y diagnosticar las consecuencias

Las aplicaciones reales escriben en algún lado. La habilidad de examen no es "activar el flag", es "activar el flag, leer el crash, y montar exactamente las rutas necesarias".

1. Aplicá la versión endurecida ingenua:

```yaml
# 02-readonly-broken.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-web
  namespace: immutability-lab
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
      securityContext:
        readOnlyRootFilesystem: true
```

```bash
kubectl apply -f 02-readonly-broken.yaml
kubectl get pod immutable-web -w
# NAME            READY   STATUS             RESTARTS   AGE
# immutable-web   0/1     Error              0          4s
# immutable-web   0/1     CrashLoopBackOff   1          6s
```

2. Leé la falla real — no `describe`, el log del contenedor:

```bash
kubectl logs immutable-web
```
```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: /etc/nginx/conf.d/default.conf is not a file or does not exist
/docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/08/05 10:11:58 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
```

3. Fijate en la *razón de salida* registrada por el kubelet, que es lo que te da `describe`:

```bash
kubectl describe pod immutable-web | sed -n '/Last State/,/Ready/p'
# Last State:     Terminated
#   Reason:       Error
#   Exit Code:    1
```

4. Enumerá lo que el proceso necesita. `errno 30` es `EROFS`; el log nombra una ruta, pero nginx también necesita un archivo PID. Confirmalo desde la imagen misma antes de adivinar:

```bash
kubectl run nginx-probe --rm -it --restart=Never --image=nginx:1.27 \
  --command -- grep -E '^(pid|user)' /etc/nginx/nginx.conf
# user  nginx;
# pid        /var/run/nginx.pid;
```

5. Montá exactamente esas dos rutas como `emptyDir`, y aprovechá para descartar capabilities:

```yaml
# 03-readonly-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-web
  namespace: immutability-lab
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      ports:
        - containerPort: 80
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
      volumeMounts:
        - name: nginx-cache
          mountPath: /var/cache/nginx
        - name: nginx-run
          mountPath: /var/run
  volumes:
    - name: nginx-cache
      emptyDir: {}
    - name: nginx-run
      emptyDir: {}
```

```bash
kubectl delete pod immutable-web --now
kubectl apply -f 03-readonly-fixed.yaml
kubectl wait --for=condition=Ready pod/immutable-web --timeout=60s
kubectl logs immutable-web | tail -1
# /docker-entrypoint.sh: Configuration complete; ready for start up
```

6. Volvé a ejecutar los ataques del Ejercicio 1 contra él:

```bash
kubectl exec immutable-web -- sh -c 'echo x > /usr/share/nginx/html/index.html'
# sh: 1: cannot create /usr/share/nginx/html/index.html: Read-only file system
# command terminated with exit code 2

kubectl exec immutable-web -- sh -c 'cp /bin/sh /usr/local/bin/backdoor'
# cp: cannot create regular file '/usr/local/bin/backdoor': Read-only file system
# command terminated with exit code 1
```

7. Ahora encontrá el agujero que vos mismo acabás de crear:

```bash
kubectl exec immutable-web -- sh -c 'cp /bin/sh /var/cache/nginx/backdoor && /var/cache/nginx/backdoor -c id'
# uid=0(root) gid=0(root) groups=0(root)
```

**Comprobá tu comprensión**

- **Q4.** `kubectl describe` reportó solo `Exit Code: 1`. ¿Por qué la causa raíz apareció únicamente en `kubectl logs`, y cuál es la regla general para diagnosticar una regresión de `readOnlyRootFilesystem`?
- **Q5.** En el paso 5 descartaste `ALL` las capabilities y agregaste cuatro de vuelta. ¿Por qué esta imagen específica sigue necesitando `SETUID`, `SETGID` y `CHOWN` aunque el contenedor arranca como root?
- **Q6.** El paso 7 ejecutó una shell copiada dentro de un `emptyDir`. ¿`readOnlyRootFilesystem: true` aplica a los volúmenes montados? ¿Qué tendrías que cambiar para hacer esa ruta no ejecutable, y por qué no podés hacerlo solo con `emptyDir`?
- **Q7.** El script de entrypoint `10-listen-on-ipv6-by-default.sh` registró un mensaje informativo en lugar de fallar. ¿Qué te dice eso sobre cómo manejan las imágenes bien construidas un root de solo lectura, y qué revisarías en una imagen propia antes de activar el flag?

---

## Ejercicio 3 — Combinar inmutabilidad con no-root y un perfil restricted completo

Solo lectura por sí sola te sigue dejando corriendo como UID 0. El endurecimiento de producción es la combinación.

1. Intentá ejecutar la variante *unprivileged* de nginx, que escucha en 8080 y escribe su PID bajo `/tmp`:

```yaml
# 04-nonroot-immutable.yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-web-nonroot
  namespace: immutability-lab
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    fsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: nginxinc/nginx-unprivileged:1.27-alpine
      ports:
        - containerPort: 8080
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: cache
      emptyDir: {}
    - name: run
      emptyDir: {}
    - name: tmp
      emptyDir: {}
```

```bash
kubectl apply -f 04-nonroot-immutable.yaml
kubectl wait --for=condition=Ready pod/immutable-web-nonroot --timeout=60s
kubectl exec immutable-web-nonroot -- id
# uid=101(nginx) gid=101(nginx) groups=101(nginx)
```

2. Verificá que el servicio efectivamente responde en 8080:

```bash
kubectl run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  -s -o /dev/null -w '%{http_code}\n' http://immutable-web-nonroot.immutability-lab.pod.cluster.local:8080
```
*(alternativa más simple si el DNS para FQDNs de Pod no está configurado)*
```bash
kubectl port-forward pod/immutable-web-nonroot 8080:8080 >/dev/null 2>&1 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080
# 200
kill %1
```

3. Comprobá que la escalada de privilegios está bloqueada incluso si existiera un binario setuid:

```bash
kubectl exec immutable-web-nonroot -- cat /proc/self/status | grep -E 'NoNewPrivs|CapEff|CapBnd'
# CapBnd: 0000000000000000
# CapEff: 0000000000000000
# NoNewPrivs:     1
```

4. Contrastá con el Pod basado en root del Ejercicio 2:

```bash
kubectl exec immutable-web -- cat /proc/self/status | grep -E 'NoNewPrivs|CapEff'
# CapEff: 0000000000000400
# NoNewPrivs:     0
```

**Comprobá tu comprensión**

- **Q8.** `CapEff: 0000000000000400` — ¿qué capability es esa, y por qué es la única que queda efectiva aunque agregaste cuatro en el manifiesto?
- **Q9.** En el paso 3 aparece `NoNewPrivs: 1`. ¿Qué campo lo establece, y qué seguiría siendo posible si activaras `readOnlyRootFilesystem: true` pero dejaras `allowPrivilegeEscalation` sin definir?
- **Q10.** ¿Por qué cambiar a `nginxinc/nginx-unprivileged` también te permitió descartar `NET_BIND_SERVICE`? ¿Cuál es el principio general para el examen cuando una tarea dice "correr como no-root y mantener el servicio accesible"?
- **Q11.** `runAsNonRoot: true` y `runAsUser: 101` están ambos definidos. ¿Qué pasa en la admisión y en el arranque si el `USER` de la imagen es `root` y definís solo `runAsNonRoot: true`? ¿Cuál es el error exacto?

---

## Ejercicio 4 — Verificar la inmutabilidad desde dentro del contenedor y desde el nodo

Una tarea de examen puede pedirte *demostrar* que un contenedor es inmutable, no solo escribir el YAML.

1. Desde adentro — las opciones del montaje raíz:

```bash
kubectl exec immutable-web -- head -1 /proc/mounts
# overlay / overlay ro,relatime,lowerdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/... 0 0
```

2. Desde adentro — qué rutas siguen siendo escribibles:

```bash
kubectl exec immutable-web -- sh -c "grep -E ' (rw|ro),' /proc/mounts | awk '{print \$2, \$4}' | cut -d, -f1"
# / ro
# /dev rw
# /dev/shm rw
# /var/cache/nginx rw
# /var/run rw
# /etc/hosts rw
# /dev/termination-log rw
# /etc/hostname rw
# /etc/resolv.conf rw
# /var/run/secrets/kubernetes.io/serviceaccount ro
```

3. Inspeccioná `/dev/shm` específicamente — un tmpfs escribible que el runtime siempre agrega:

```bash
kubectl exec immutable-web -- sh -c 'grep /dev/shm /proc/mounts'
# shm /dev/shm tmpfs rw,nosuid,nodev,noexec,relatime,size=65536k 0 0
kubectl exec immutable-web -- sh -c 'cp /bin/sh /dev/shm/x && /dev/shm/x -c id'
# sh: 1: /dev/shm/x: Permission denied
```

4. Desde el nodo — localizá el contenedor y leé el contexto de seguridad de CRI:

```bash
# on the worker node
CID=$(sudo crictl ps --name nginx --pod $(sudo crictl pods --name immutable-web -q) -q)
sudo crictl inspect "$CID" | jq '.info.config.linux.security_context.readonly_rootfs'
# true
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.root.readonly'
# true
```

5. Desde el nodo — listá cada montaje que el runtime hizo de lectura-escritura, que es el inventario autoritativo de superficie escribible:

```bash
sudo crictl inspect "$CID" \
  | jq -r '.info.runtimeSpec.mounts[] | "\(.destination)\t\(.options | join(","))"' \
  | grep -v ',ro'
# /proc     nosuid,noexec,nodev,rprivate,rw
# /dev      nosuid,strictatime,rprivate,rw,mode=755,size=65536k
# /dev/shm  nosuid,noexec,nodev,rprivate,rw,mode=1777,size=65536k
# /var/cache/nginx  rbind,rprivate,rw
# /var/run          rbind,rprivate,rw
```

6. Confirmá la imagen en ejecución por digest, no por tag:

```bash
kubectl get pod immutable-web -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
# docker.io/library/nginx@sha256:6b1daa0462fbd0d33e40d1e6b0b7f68a4b4b1b0f... (yours will differ)
```

**Comprobá tu comprensión**

- **Q12.** El paso 3 mostró que la copia a `/dev/shm` funcionó pero la ejecución falló con `Permission denied`. ¿Qué opción de montaje causó eso, y por qué `/dev/shm` es más seguro por defecto que tu propio `emptyDir` en `/tmp`?
- **Q13.** `/etc/hosts`, `/etc/hostname` y `/etc/resolv.conf` están montados `rw` a pesar de `readOnlyRootFilesystem: true`. ¿Por qué hace esto el kubelet, y representa una exposición real?
- **Q14.** ¿Por qué `.status.containerStatuses[].imageID` es una afirmación más fuerte sobre lo que está corriendo que `.spec.containers[].image`?
- **Q15.** Te dan un nodo y te dicen "un contenedor en `kube-system` tiene un sistema de archivos raíz escribible — encontralo" sin acceso a `kubectl`. Escribí el one-liner de `crictl` + `jq`.

---

## Ejercicio 5 — Inmutabilidad en la capa de imagen: sin shell, sin desviación, digest fijado

1. Desplegá un contenedor construido `FROM scratch` e intentá obtener una shell:

```yaml
# 05-noshell.yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-shell
  namespace: immutability-lab
spec:
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 65535
        capabilities:
          drop: ["ALL"]
```

```bash
kubectl apply -f 05-noshell.yaml
kubectl wait --for=condition=Ready pod/no-shell --timeout=60s
kubectl exec -it no-shell -- /bin/sh
```
```
error: Internal error occurred: error executing command in container: failed to exec in container:
failed to start exec "e0b1...": OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

2. Confirmá lo mismo para una imagen distroless, e inspeccionala sin ejecutar nada:

```bash
kubectl run distroless --restart=Never --image=gcr.io/distroless/static-debian12:nonroot \
  --command -- /nonexistent
kubectl describe pod distroless | grep -A2 'Last State'
# Last State:  Terminated
#   Reason:    StartError
```

3. Observá cómo *sí* se depura un Pod así — un contenedor efímero con su propia imagen:

```bash
kubectl debug -it no-shell --image=busybox:1.36 --target=pause -- sh
# / # ls /proc/1/root 2>/dev/null || echo "cannot traverse target rootfs"
# / # exit
```

4. Ahora abordá la mutabilidad del tag. Resolvé el tag a un digest:

```bash
kubectl get pod immutable-web -o jsonpath='{.status.containerStatuses[0].imageID}' \
  | cut -d@ -f2
# sha256:6b1daa0462fbd0d33e40d1e6b0b7f68a4b4b1b0f...   (yours will differ)
```

5. Fijalo. Reemplazá la referencia por tag con una referencia por digest y notá que `imagePullPolicy` se vuelve irrelevante para la corrección:

```bash
DIGEST=$(kubectl get pod immutable-web -o jsonpath='{.status.containerStatuses[0].imageID}' | cut -d@ -f2)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pinned-web
  namespace: immutability-lab
spec:
  containers:
    - name: nginx
      image: nginx@${DIGEST}
      imagePullPolicy: IfNotPresent
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
      volumeMounts:
        - { name: cache, mountPath: /var/cache/nginx }
        - { name: run,   mountPath: /var/run }
  volumes:
    - { name: cache, emptyDir: {} }
    - { name: run,   emptyDir: {} }
EOF
kubectl wait --for=condition=Ready pod/pinned-web --timeout=90s
```

6. Mostrá que una referencia por digest se autoverifica, rompiéndola:

```bash
kubectl run bad-digest --restart=Never \
  --image=nginx@sha256:0000000000000000000000000000000000000000000000000000000000000000
kubectl describe pod bad-digest | grep -E 'Failed|Error' | head -2
# Warning  Failed  ...  Failed to pull image "nginx@sha256:0000...": failed to resolve reference: not found
# Warning  Failed  ...  Error: ErrImagePull
```

**Comprobá tu comprensión**

- **Q16.** `kubectl exec` falló en el Pod `pause`. ¿Quitar la shell impide que un atacante que ya logró RCE dentro del proceso haga daño? ¿Qué clase de atacante detiene realmente?
- **Q17.** En el paso 3 adjuntaste un contenedor efímero `busybox`. Explicá con precisión por qué esto es un agujero en tu narrativa de inmutabilidad, y qué dos controles de Kubernetes lo cierran.
- **Q18.** Con `image: nginx:1.27` e `imagePullPolicy: IfNotPresent`, describí el ataque concreto en el que dos Pods del mismo Deployment ejecutan código distinto. ¿Por qué una referencia por digest vuelve seguro a `IfNotPresent`?
- **Q19.** `imagePullPolicy: Always` se propone a menudo como la solución a la mutabilidad de tags. Nombrá una propiedad de seguridad que *sí* provee y que `IfNotPresent` no, y una razón por la que aun así no sustituye la fijación por digest.

---

## Ejercicio 6 — Aplicarlo: PSA no alcanza, así que escribí una ValidatingAdmissionPolicy

1. Creá un namespace que aplique el Pod Security Standard `restricted`:

```bash
kubectl create namespace psa-restricted
kubectl label namespace psa-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.34
```

2. Verificá que `restricted` rechaza un Pod sin endurecer:

```bash
kubectl -n psa-restricted run rejected --image=nginx:1.27
```
```
Error from server (Forbidden): pods "rejected" is forbidden: violates PodSecurity "restricted:v1.34":
allowPrivilegeEscalation != false (container "rejected" must set securityContext.allowPrivilegeEscalation=false),
unrestricted capabilities (container "rejected" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "rejected" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "rejected" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

3. Ahora enviá un Pod que cumple completamente con `restricted` pero tiene un sistema de archivos raíz **escribible**:

```yaml
# 06-psa-gap.yaml
apiVersion: v1
kind: Pod
metadata:
  name: psa-passes-but-mutable
  namespace: psa-restricted
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

```bash
kubectl apply -f 06-psa-gap.yaml
# pod/psa-passes-but-mutable created            <-- ADMITTED

kubectl -n psa-restricted exec psa-passes-but-mutable -- \
  sh -c 'cp /bin/busybox /tmp/payload && chmod +x /tmp/payload && /tmp/payload id'
# uid=1000 gid=0(root)
```

**Este es el hecho más importante de este tema: ningún nivel de Pod Security Standard — ni siquiera `restricted` — requiere `readOnlyRootFilesystem`.** Tenés que agregarlo vos mismo.

4. Cerrá la brecha con una `ValidatingAdmissionPolicy` (GA `admissionregistration.k8s.io/v1`):

```yaml
# 07-vap.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-immutable-rootfs
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "every container must set securityContext.readOnlyRootFilesystem: true"
      reason: Invalid
    - expression: >-
        !has(object.spec.initContainers) ||
        object.spec.initContainers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "every initContainer must set securityContext.readOnlyRootFilesystem: true"
      reason: Invalid
    - expression: >-
        object.spec.containers.all(c, c.image.contains('@sha256:'))
      message: "images must be pinned by digest (repo@sha256:...), not by tag"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-immutable-rootfs-binding
spec:
  policyName: require-immutable-rootfs
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        immutability: enforced
```

```bash
kubectl apply -f 07-vap.yaml
kubectl label namespace psa-restricted immutability=enforced
```

5. Volvé a probar:

```bash
kubectl delete pod psa-passes-but-mutable -n psa-restricted --now
kubectl apply -f 06-psa-gap.yaml
```
```
Error from server (Forbidden): error when creating "06-psa-gap.yaml": pods "psa-passes-but-mutable"
is forbidden: ValidatingAdmissionPolicy 'require-immutable-rootfs' with binding
'require-immutable-rootfs-binding' denied request: every container must set
securityContext.readOnlyRootFilesystem: true
```

6. Ahora observá la trampa: aplicá la misma especificación a través de un **Deployment**.

```bash
kubectl -n psa-restricted create deployment gap --image=busybox:1.36 -- sleep 3600
# deployment.apps/gap created                   <-- ACCEPTED

kubectl -n psa-restricted get deploy gap
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# gap    0/1     0            0           15s

kubectl -n psa-restricted describe rs -l app=gap | tail -4
# Events:
#   Type     Reason        Age   From                   Message
#   Warning  FailedCreate  12s   replicaset-controller  Error creating: pods "gap-7d9f5c8b6-" is forbidden:
#     ValidatingAdmissionPolicy 'require-immutable-rootfs' ... denied request: every container must set
#     securityContext.readOnlyRootFilesystem: true
```

7. Opcional — verificá si tu clúster expone la contraparte mutante, que podría *inyectar* el campo en lugar de rechazar:

```bash
kubectl api-resources | grep -i admissionpolicy
# validatingadmissionpolicies          admissionregistration.k8s.io/v1     false   ValidatingAdmissionPolicy
# validatingadmissionpolicybindings    admissionregistration.k8s.io/v1     false   ValidatingAdmissionPolicyBinding
# mutatingadmissionpolicies            admissionregistration.k8s.io/v1beta1 false  MutatingAdmissionPolicy
```

**Comprobá tu comprensión**

- **Q20.** Nombrá las cuatro cosas que `restricted` *sí* aplica y que se relacionan con la integridad del contenedor, y establecé explícitamente qué no aplica.
- **Q21.** En el paso 6 el Deployment fue aceptado pero ningún Pod se ejecutó. Explicá el mecanismo, y decí dónde vería realmente el error un operador en un incidente real.
- **Q22.** El binding usa `failurePolicy: Fail` en la política. ¿Qué se rompe si una expresión CEL de la política es inválida en tiempo de ejecución, y en qué difiere eso de `failurePolicy: Ignore`?
- **Q23.** Reescribí la primera `expression` usando la sintaxis opcional de CEL para que sea más corta, y explicá por qué se requiere `has(c.securityContext)` antes de desreferenciar el campo.
- **Q24.** Tu política verifica `c.image.contains('@sha256:')`. Dá una referencia de imagen que pase esta verificación pero que igual no sea lo que pretendías, y ajustá la expresión.

---

## Ejercicio 7 — El bypass del contenedor efímero y cómo cerrarlo

1. Con la política del Ejercicio 6 activa, intentá adjuntar un contenedor de depuración a un Pod existente que cumple:

```bash
kubectl label namespace immutability-lab immutability=enforced
kubectl debug -it pinned-web --image=busybox:1.36 --target=nginx -- sh
```

2. Observá si es admitido. Los `matchConstraints` por defecto de arriba cubren `pods` en `UPDATE`, pero `kubectl debug` escribe al **subrecurso `pods/ephemeralcontainers`**:

```bash
kubectl get pod pinned-web -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
# debugger-8xk2j
kubectl exec pinned-web -c debugger-8xk2j -- sh -c 'cp /bin/busybox /payload && ls -l /payload'
# -rwxr-xr-x 1 root root 1153680 Aug  5 10:31 /payload
```

3. Extendé la política para cubrir el subrecurso y validar los contenedores efímeros:

```yaml
# 08-vap-ephemeral.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-immutable-ephemeral
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["UPDATE"]
        resources:   ["pods/ephemeralcontainers"]
  validations:
    - expression: >-
        !has(object.spec.ephemeralContainers) ||
        object.spec.ephemeralContainers.all(c,
          has(c.securityContext) &&
          has(c.securityContext.readOnlyRootFilesystem) &&
          c.securityContext.readOnlyRootFilesystem == true)
      message: "ephemeral containers must also set readOnlyRootFilesystem: true"
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-immutable-ephemeral-binding
spec:
  policyName: require-immutable-ephemeral
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        immutability: enforced
```

```bash
kubectl apply -f 08-vap-ephemeral.yaml
kubectl delete pod pinned-web --now && kubectl apply -f - <<'EOF'
# (re-apply the pinned-web manifest from Exercise 5, step 5)
EOF
kubectl debug -it pinned-web --image=busybox:1.36 --target=nginx -- sh
```
```
error: ephemeralcontainers "pinned-web" is forbidden: ValidatingAdmissionPolicy
'require-immutable-ephemeral' with binding 'require-immutable-ephemeral-binding' denied request:
ephemeral containers must also set readOnlyRootFilesystem: true
```

4. Cerrá también la vía de RBAC — el control duradero:

```bash
kubectl create clusterrole no-debug --verb=create,patch \
  --resource=pods/ephemeralcontainers --dry-run=client -o yaml
```
Después confirmá qué sujetos lo tienen actualmente:
```bash
kubectl auth can-i update pods/ephemeralcontainers --as=system:serviceaccount:default:default
# no
kubectl auth can-i update pods/ephemeralcontainers
# yes
```

**Comprobá tu comprensión**

- **Q25.** ¿Por qué la política original del Ejercicio 6 no se activó con `kubectl debug`, aunque coincidía con `UPDATE` sobre `pods`?
- **Q26.** Un contenedor efímero no puede eliminarse una vez agregado. ¿Qué consecuencia operativa tiene eso para un clúster que aplica inmutabilidad, y cómo te deshacés realmente de él?
- **Q27.** Entre la VAP y la restricción de RBAC sobre `pods/ephemeralcontainers`, ¿cuál desplegarías primero en producción, y por qué?

---

## Ejercicio 8 — Defensa en profundidad: AppArmor como segundo candado, a nivel de kernel (requiere acceso al nodo)

`readOnlyRootFilesystem` es aplicado por el montaje del container runtime. AppArmor es aplicado por el LSM, de forma independiente.

1. En el nodo worker, verificá que AppArmor está activo:

```bash
sudo aa-status | head -3
# apparmor module is loaded.
# 45 profiles are loaded.
# 42 profiles are in enforce mode.
```

2. Escribí un perfil que deniegue escrituras a los directorios propios de la imagen:

```bash
sudo tee /etc/apparmor.d/k8s-immutable >/dev/null <<'EOF'
#include <tunables/global>

profile k8s-immutable flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,

  # Nothing in the image may be modified.
  deny /bin/**        w,
  deny /sbin/**       w,
  deny /usr/**        w,
  deny /etc/**        w,
  deny /lib/**        w,

  # Nothing may be executed from the writable scratch volumes.
  deny /var/cache/nginx/** x,
  deny /tmp/**             x,
}
EOF

sudo apparmor_parser -q -r /etc/apparmor.d/k8s-immutable
sudo aa-status | grep k8s-immutable
#    k8s-immutable
```

3. Referencialo desde el Pod usando el campo GA de la API (v1.30+; la vieja anotación `container.apparmor.security.beta.kubernetes.io/<name>` está obsoleta):

```yaml
# 09-apparmor.yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-immutable
  namespace: immutability-lab
spec:
  nodeName: <your-worker-node>
  containers:
    - name: nginx
      image: nginx:1.27
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-immutable
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
      volumeMounts:
        - { name: cache, mountPath: /var/cache/nginx }
        - { name: run,   mountPath: /var/run }
  volumes:
    - { name: cache, emptyDir: {} }
    - { name: run,   emptyDir: {} }
```

```bash
kubectl apply -f 09-apparmor.yaml
kubectl wait --for=condition=Ready pod/apparmor-immutable --timeout=60s
kubectl exec apparmor-immutable -- cat /proc/self/attr/current
# k8s-immutable (enforce)
```

4. Verificá que el agujero del Ejercicio 2 paso 7 ahora está cerrado:

```bash
kubectl exec apparmor-immutable -- sh -c 'cp /bin/sh /var/cache/nginx/backdoor && /var/cache/nginx/backdoor -c id'
# sh: 1: /var/cache/nginx/backdoor: Permission denied
# command terminated with exit code 126
```

5. Leé el registro propio del kernel sobre la denegación, en el nodo:

```bash
sudo dmesg | grep -i 'apparmor="DENIED"' | tail -1
# audit: type=1400 ... apparmor="DENIED" operation="exec" profile="k8s-immutable"
#   name="/var/cache/nginx/backdoor" pid=41827 comm="sh" requested_mask="x" denied_mask="x"
```

6. Confirmá el modo de falla cuando el perfil no está en un nodo:

```bash
kubectl apply -f 09-apparmor.yaml   # against a node without the profile loaded
kubectl describe pod apparmor-immutable | grep -A1 'Reason:'
# Reason:  AppArmor
# Message: Cannot enforce AppArmor: profile "k8s-immutable" is not loaded
```

**Comprobá tu comprensión**

- **Q28.** Dá dos cosas que AppArmor aplica acá y que `readOnlyRootFilesystem` estructuralmente no puede.
- **Q29.** El paso 6 muestra que el Pod falla cuando el perfil está ausente. ¿Por qué este modo de falla es el *deseado*, y qué implica sobre cómo debés desplegar perfiles en un pool de nodos?
- **Q30.** El perfil deniega `x` en `/tmp/**`. ¿Cuál es el control equivalente basado en seccomp, y por qué seccomp es la herramienta incorrecta para este requisito en particular?

---

## Ejercicio 9 — Auditoría y limpieza a nivel de clúster

1. Encontrá cada contenedor del clúster sin un sistema de archivos raíz inmutable:

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | .metadata as $m
  | (.spec.containers + (.spec.initContainers // []) + (.spec.ephemeralContainers // []))[]
  | select((.securityContext.readOnlyRootFilesystem // false) != true)
  | "\($m.namespace)\t\($m.name)\t\(.name)"' \
  | column -t
# kube-system  coredns-668d6bf9bc-7lz9x  coredns
# kube-system  kube-proxy-2xq4p          kube-proxy
# default      legacy-api-7f6c4b8d9-mq2sv  api
```

2. El equivalente sin `jq`, útil cuando la terminal del examen está pelada:

```bash
kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,C:.spec.containers[*].name,ROFS:.spec.containers[*].securityContext.readOnlyRootFilesystem' \
  | grep -E '<none>|false'
```

3. Encontrá cada contenedor que corre desde un tag mutable en lugar de un digest:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}' \
  | grep -v '@sha256:'
```

4. Ejecutá la política en modo solo-auditoría contra el clúster entero antes de aplicarla en ningún lado — cambiá el binding y leé las anotaciones del log de auditoría:

```bash
kubectl patch validatingadmissionpolicybinding require-immutable-rootfs-binding \
  --type=merge -p '{"spec":{"validationActions":["Audit","Warn"],"matchResources":{"namespaceSelector":{}}}}'
kubectl -n default run probe --image=nginx:1.27
# Warning: ValidatingAdmissionPolicy 'require-immutable-rootfs' ... every container must set
#   securityContext.readOnlyRootFilesystem: true
# pod/probe created
```

5. Desmontá todo:

```bash
kubectl delete validatingadmissionpolicybinding require-immutable-rootfs-binding require-immutable-ephemeral-binding
kubectl delete validatingadmissionpolicy require-immutable-rootfs require-immutable-ephemeral
kubectl delete namespace immutability-lab psa-restricted --wait=false
kubectl config set-context --current --namespace=default
# on the node, if Exercise 8 was done:
sudo apparmor_parser -R /etc/apparmor.d/k8s-immutable && sudo rm /etc/apparmor.d/k8s-immutable
```

**Comprobá tu comprensión**

- **Q31.** El filtro `jq` del paso 1 usa `// false`. ¿Qué caso del mundo real maneja eso, y qué se perdería la consulta sin él?
- **Q32.** El paso 4 usó `["Audit","Warn"]`. Describí la secuencia de despliegue que usarías para introducir un requisito de `readOnlyRootFilesystem` en un clúster en producción con 400 cargas de trabajo, y nombrá la señal que vigilarías en cada etapa.

---

## Fuentes de referencia

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Common Expression Language in Kubernetes* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Restrict a Container's Access to Resources with AppArmor* — https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes, *Images* (pull policy, digests) — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Volumes — emptyDir* — https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Kubernetes, *Debug Running Pods — Ephemeral Containers* — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container
- Kubernetes, *Security Checklist* — https://kubernetes.io/docs/concepts/security/security-checklist/
- GoogleContainerTools, *distroless* — https://github.com/GoogleContainerTools/distroless

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** Ninguno. La capa escribible del contenedor vive enteramente en el nodo, en el `upperdir` del overlayfs del runtime; el API server almacena solo la especificación deseada. `kubectl get/describe` va a reportar un Pod sano, `Running` y sin modificar para siempre. Detectar esta clase de ataque requiere o bien un agente de runtime observando las syscalls del sistema de archivos (las reglas `write_below_binary_dir` / `Write below etc` de Falco), comparación desde el nodo de la capa superior del overlay contra la imagen, o — mucho más barato — eliminar la posibilidad por completo con `readOnlyRootFilesystem`. Esta asimetría es todo el argumento a favor de la inmutabilidad: la prevención es casi gratis, la detección no.

**Q2.** El balanceo de carga significa que solo ~1 de cada 3 peticiones llega a la réplica comprometida, así que los síntomas intermitentes se descartan como inestabilidad. Y es "auto-reparable" en la dirección equivocada para el defensor: la desviación desaparece en el momento en que ese Pod se reinicia o se reprograma, llevándose la evidencia forense consigo, mientras que la persistencia real del atacante vive en otro lado (una imagen mutada, un pipeline de CI comprometido, un `CronJob`). Un compromiso a nivel de Pod que se desvanece al reiniciar es un *síntoma*; tratá el artefacto efímero como evidencia, no como la causa raíz.

**Q3.** Setuid solo ayuda si el proceso está corriendo como un usuario **no-root** y el binario es propiedad de root — entonces ejecutarlo eleva a UID 0. Acá el contenedor ya era root, así que no cambia nada; importa para los Pods endurecidos no-root. `allowPrivilegeEscalation: false` lo neutraliza estableciendo el flag de proceso `no_new_privs`, que hace que el kernel ignore los bits setuid/setgid y las capabilities de archivo en `execve()` para ese proceso y todos sus descendientes — independientemente de si el sistema de archivos raíz es escribible.

**Q4.** `describe` muestra la visión del kubelet: el contenedor salió con estado 1. El kubelet no tiene visibilidad de *por qué* salió un proceso — ese razonamiento vive en el stderr del propio proceso, que es el log del contenedor. La regla: para regresiones de `readOnlyRootFilesystem`, siempre `kubectl logs <pod> --previous` (necesario una vez que el Pod está en `CrashLoopBackOff`, ya que el contenedor actual puede no haber arrancado todavía) y buscá `EROFS` / `Read-only file system` / `errno 30`. `describe` solo sirve para la clase de fallas de *scheduling e imagen*; la salida de logs es la única fuente para la clase de fallas de *arranque*.

**Q5.** El proceso maestro de nginx arranca como root para hacer bind al puerto 80, luego bifurca workers que baja al usuario `nginx` — ese fork-and-drop requiere `SETUID` y `SETGID`. `CHOWN` es necesario porque el maestro ajusta la propiedad de las rutas de log y temporales para esos workers. Ser UID 0 no alcanza: el *bounding set* de capabilities es lo que el kernel realmente consulta, y `drop: ["ALL"]` lo vacía, así que un proceso root pierde `setuid(2)` igual que uno no-root. Esto es exactamente por qué `runAsUser: 0` y "tiene capabilities" son conceptos ortogonales.

**Q6.** No — `readOnlyRootFilesystem` aplica **solo a la capa raíz propia del contenedor**. Cada `volumeMount` tiene su propio montaje y su propia semántica de lectura-escritura; `emptyDir` es de lectura-escritura por definición. Podés hacer un montaje individual de solo lectura con `volumeMounts[].readOnly: true`, pero eso anula el propósito acá (nginx debe escribir en su caché). Para hacerlo *escribible pero no ejecutable* necesitás la opción de montaje `noexec`, y `emptyDir` no expone opciones de montaje — eso requiere un driver CSI que soporte `mountOptions`, o un control a nivel de kernel como la regla de AppArmor `deny /var/cache/nginx/** x` usada en el Ejercicio 8. **Implicancia de diseño:** cada ruta escribible que agregás es una candidata a zona de descarga; agregá las menos posibles y mantenelas fuera de `$PATH`.

**Q7.** Las imágenes bien construidas sondean la capacidad de escritura (`[ ! -w "$file" ]`) y se degradan con gracia en lugar de abortar. El entrypoint de nginx hace exactamente esto para el script de IPv6 — de ahí el mensaje informativo en lugar de un crash. Para una imagen propia, antes de activar el flag: ejecutala localmente con `docker run --read-only` (o `podman run --read-only`), recorré un ciclo completo de peticiones, e inventariá cada `EROFS`; alternativamente `strace -f -e trace=open,openat,mkdir -P ...` y buscá aperturas en modo escritura fuera de tus volúmenes previstos. Hacé esto en staging, no iterando sobre CrashLoopBackOff en el clúster.

**Q8.** `0x400` = bit 10 = **`CAP_NET_BIND_SERVICE`**. Es la única *efectiva* porque el conjunto efectivo se calcula después de que el proceso ya arrancó y descartó lo que ya no necesita — el maestro de nginx retiene solo lo que sigue usando en régimen estacionario. `CAP_SETUID`/`CAP_SETGID`/`CAP_CHOWN` eran necesarias durante el arranque (bifurcar workers, corregir propiedad) y ya fueron liberadas para cuando leés `/proc/self/status`. Notá además que la shell de `kubectl exec` hereda el conjunto *bounding* del contenedor, así que comparar `CapBnd` entre los dos Pods es la verificación más confiable de lo que el manifiesto realmente otorgó.

**Q9.** `allowPrivilegeEscalation: false` establece `no_new_privs`. Sin él, un sistema de archivos raíz de solo lectura todavía le permite a un atacante ejecutar un binario setuid-root que estaba **horneado en la imagen** — y las imágenes base de Debian/Alpine incluyen varios (`/usr/bin/passwd`, `/bin/su`, `/usr/bin/mount`, `/usr/bin/newgrp`). La inmutabilidad impide *plantar* un nuevo vector de escalada; no hace nada con los que ya están en la imagen. Los dos controles son complementarios, y por eso `restricted` exige el segundo y toda línea base seria exige ambos.

**Q10.** `nginxinc/nginx-unprivileged` está construida para escuchar en **8080** (>1024), y solo los puertos por debajo de 1024 requieren `CAP_NET_BIND_SERVICE` en Linux. El principio general para el examen: no intentes forzar una imagen diseñada para root a ser no-root agregando capabilities y reescribiendo propiedad de archivos — **elegí o construí una imagen diseñada para la restricción**, luego exponé el puerto real mediante el `targetPort` del Service para que nada aguas abajo cambie. `Service.port: 80 → targetPort: 8080` mantiene estable el contrato mientras el Pod sigue sin privilegios.

**Q11.** Con solo `runAsNonRoot: true` y una imagen cuyo `USER` es root, el Pod es **admitido** — el API server no puede inspeccionar los metadatos de la imagen — y después falla al arrancar el contenedor. El kubelet resuelve el UID configurado de la imagen, ve 0, y se niega:
```
Error: container has runAsNonRoot and image will run as root
```
con el Pod entrando en `CreateContainerConfigError`. Este es un escenario favorito del examen: la solución es agregar un `runAsUser: <distinto de cero>` explícito (que anula la imagen), o usar una imagen con un `USER` no-root. Definir `runAsUser` solo, sin `runAsNonRoot`, es más débil, porque una edición posterior del manifiesto o una mutación de admisión podría volver a ponerlo en 0 sin resistencia.

**Q12.** `noexec`, que el container runtime aplica a `/dev/shm` incondicionalmente (junto con `nosuid,nodev`). Tu propio `emptyDir` en `/tmp` no recibe ninguna de esas opciones — Kubernetes lo monta como un bind mount ordinario, de lectura-escritura y ejecutable. Así que un `emptyDir` en `/tmp` es estrictamente más peligroso que el `/dev/shm` provisto por el runtime, y "activé `readOnlyRootFilesystem` y monté un `emptyDir` en `/tmp`" restaura una ruta ejecutable, escribible y conocida por todos. Si la carga de trabajo solo necesita *datos* temporales, está bien; si `$PATH` o cualquier intérprete puede alcanzarla, es una zona de descarga.

**Q13.** El kubelet gestiona esos tres archivos él mismo: inyecta la configuración de DNS del Pod, el hostname, y las entradas de `hostAliases` en la creación del contenedor, y debe poder actualizar `/etc/hosts` durante toda la vida del Pod. Son bind mounts de archivos individuales, así que no están cubiertos por la capa raíz de solo lectura. La exposición es real pero acotada: un atacante con acceso de escritura dentro del contenedor puede envenenar la resolución de nombres del propio contenedor (`/etc/resolv.conf`, `/etc/hosts`) para redirigir su tráfico saliente. No da ejecución de código y no afecta a otros Pods; mitigá con AppArmor (`deny /etc/** w`) o no otorgando `exec` en primer lugar.

**Q14.** `.spec.containers[].image` es la *solicitud* — una cadena mutable, provista por un humano, como `nginx:1.27`, que dice lo que el autor pidió. `.status.containerStatuses[].imageID` es el *hecho* — el digest direccionable por contenido de la imagen que el runtime realmente desempaquetó y arrancó, según lo reporta CRI. Si alguien volvió a publicar el tag `1.27`, o un nodo tenía una capa cacheada obsoleta bajo `IfNotPresent`, solo el `imageID` lo revela. Durante un incidente, comparar `imageID` entre todas las réplicas de un Deployment es la manera más rápida de detectar desviación de imagen a nivel de nodo.

**Q15.**
```bash
for c in $(sudo crictl ps -q); do
  sudo crictl inspect "$c" | jq -r \
    'select(.info.config.linux.security_context.readonly_rootfs != true)
     | "\(.status.labels["io.kubernetes.pod.namespace"])/\(.status.labels["io.kubernetes.pod.name"]) \(.status.metadata.name)"'
done | grep '^kube-system/'
```
El namespace y el nombre del pod se llevan como labels de CRI (`io.kubernetes.pod.namespace`, `io.kubernetes.pod.name`), que es la forma de correlacionar contenedores del lado del nodo de vuelta a objetos de Kubernetes sin el API server. `.info.runtimeSpec.root.readonly` es el campo equivalente si preferís leer la especificación OCI directamente.

**Q16.** No detiene a un atacante que ya tiene ejecución de código dentro del proceso — puede llamar a `execve` sobre cualquier cosa presente, reservar memoria, abrir sockets, y leer Secrets montados, todo sin una shell. Lo que sí detiene es la enorme clase de ataques que *invocan una shell*: payloads de inyección de comandos que asumen `/bin/sh -c`, reverse shells desde RCEs de aplicaciones web, y — críticamente — un atacante con permiso solo de `kubectl exec`, para quien la ausencia de shell significa ningún punto de apoyo interactivo. También colapsa el instrumental de post-explotación disponible (`curl`, `wget`, `apt`, `nc` todos ausentes), lo que eleva el esfuerzo y fuerza técnicas más ruidosas. Tratalo como un control fuerte de imposición de costos, no como una frontera.

**Q17.** Un contenedor efímero corre en los namespaces del Pod objetivo (PID, red, y opcionalmente el namespace de procesos) pero trae **su propia imagen y su propio sistema de archivos raíz completamente escribible**. Así que `kubectl debug --image=busybox` le entrega al usuario un entorno escribible y rico en herramientas dentro de un Pod por lo demás inmutable, y con `--target` puede leer `/proc/<pid>/root` y `/proc/<pid>/environ` del contenedor endurecido. Los dos controles que lo cierran: (1) RBAC — denegar `create`/`update`/`patch` sobre el subrecurso `pods/ephemeralcontainers` a todos salvo identidades de emergencia; (2) admisión — una `ValidatingAdmissionPolicy` (o PSA, que sí evalúa contenedores efímeros para sus propios campos) que coincida con `pods/ephemeralcontainers` e imponga los mismos requisitos de contexto de seguridad, como en el Ejercicio 7.

**Q18.** El nodo A descargó `nginx:1.27` en marzo. En junio el tag se vuelve a publicar — legítimamente por upstream, o maliciosamente tras un compromiso de credenciales del registro. El nodo B, programando una réplica nueva hoy, no tiene copia cacheada y descarga el contenido *nuevo*. Con `imagePullPolicy: IfNotPresent`, el nodo A nunca vuelve a descargar, así que el Deployment ahora corre dos bases de código distintas bajo una especificación idéntica, sin ningún campo en la API que lo revele. Una referencia por digest es direccionable por contenido: `nginx@sha256:<d>` solo puede resolver a los bytes cuyo hash es `<d>`, y el runtime verifica el hash después de la descarga. No hay nada que volver a chequear, así que `IfNotPresent` pasa a ser no solo seguro sino óptimo — una capa cacheada que coincide con el digest *es* la imagen correcta, por definición.

**Q19.** Lo que `Always` provee: el kubelet contacta al registro en cada arranque de contenedor, lo que significa que los **`imagePullSecrets` se revalidan** — un Pod no puede seguir corriendo una imagen cuyas credenciales de descarga fueron revocadas, y un usuario sin acceso al registro no puede arrancar un Pod desde una imagen privada cacheada a la que nunca tuvo derecho. Esa propiedad de autorización es genuinamente valiosa y es por lo que `Always` se recomienda para clústeres multi-tenant. Por qué no es un sustituto: `Always` sigue resolviendo un *tag mutable*, así que garantiza que obtengas "lo que sea que ese tag apunte ahora mismo" — que es precisamente el valor controlado por el atacante en el escenario del tag republicado. Convierte un riesgo de imagen obsoleta en un riesgo de imagen maliciosa fresca. Fijación por digest más `Always` te da ambas propiedades.

**Q20.** `restricted` aplica, entre otras cosas: `runAsNonRoot: true`; `allowPrivilegeEscalation: false`; `capabilities.drop: ["ALL"]` (con solo `NET_BIND_SERVICE` agregable); `seccompProfile.type` de `RuntimeDefault` o `Localhost`; más la herencia de `baseline` — sin contenedores privilegiados, sin namespaces del host, sin `hostPath`, sin `hostPort`, tipos de volumen restringidos, sin sysctls inseguros. **No** aplica `readOnlyRootFilesystem`, y no restringe en absoluto la procedencia de la imagen (tag vs digest, lista blanca de registros). Esas tres brechas son exactamente lo que el tema 6.4 te pide cerrar con un mecanismo de admisión separado. Memorizá esto: "PSA restricted ≠ inmutable."

**Q21.** La `ValidatingAdmissionPolicy` coincidía con `pods`, así que evalúa el objeto Pod en su creación. Un Deployment no crea Pods directamente — crea un ReplicaSet, y el **controlador de ReplicaSet** crea Pods, usando la identidad propia del controller-manager. Los objetos Deployment y ReplicaSet en sí nunca se validan, así que son aceptados; el rechazo ocurre después, de forma asíncrona, cuando el controlador intenta crear el Pod. El operador lo ve en los eventos del ReplicaSet (`kubectl describe rs`) y en las `status.conditions` del Deployment (`ReplicaFailure=True`, razón `FailedCreate`) — nunca en la salida de `kubectl apply`. Esta es la firma de falla estándar de *cualquier* control de admisión a nivel de Pod (PSA se comporta idénticamente) y es por lo que `validationActions: ["Warn"]` importa: las respuestas `Warn` sí aparecen en la creación del Deployment, dándole retroalimentación inmediata al autor.

**Q22.** Con `failurePolicy: Fail`, una expresión CEL que da error en tiempo de ejecución — una discordancia de tipos, la desreferencia de un campo no definido, o exceder el presupuesto de costo — hace que la **petición sea rechazada**. Combinado con un binding que coincida ampliamente, una expresión defectuosa puede bloquear toda creación de Pods en el clúster entero, incluyendo `kube-system`, lo que es una caída autoinfligida que sobrevive a un reinicio del plano de control. `failurePolicy: Ignore` deja pasar la petición en cambio, cambiando riesgo de disponibilidad por una brecha de seguridad silenciosa. Notá que los errores de *compilación* de CEL se detectan cuando se crea el objeto de política (`spec.validations[0].expression: Invalid value: ... undefined field`), así que `Fail` se trata principalmente de errores de evaluación en tiempo de ejecución — que es precisamente por lo que debés ejercitar la política en modo `Audit`/`Warn` contra tráfico real antes de pasar a `Deny`.

**Q23.**
```cel
object.spec.containers.all(c, c.?securityContext.?readOnlyRootFilesystem.orValue(false) == true)
```
Kubernetes CEL habilita tipos opcionales, así que `?field` produce un `optional<T>` que hace cortocircuito en lugar de dar error, y `orValue()` provee el valor por defecto. La guarda `has()` en la forma larga es necesaria porque `securityContext` es un campo *opcional* en el esquema del Pod: desreferenciar un campo ausente en CEL lanza `no such key`, lo que bajo `failurePolicy: Fail` rechaza la petición con un error de evaluación opaco en lugar de tu mensaje previsto. La regla para escribir políticas: nunca desreferencies un campo opcional sin `has()` o el operador `?`.

**Q24.** `myregistry.io/evil@sha256:abc...` pasa — la verificación valida la *forma* de la referencia, no su origen, así que un atacante que pueda definir el campo image simplemente fija un digest de un registro que controla. También acepta una referencia como `nginx:latest@sha256:...`, donde el tag es decorativo. Ajustá anclando también el registro:
```cel
object.spec.containers.all(c,
  c.image.startsWith('registry.internal.example.com/') &&
  c.image.contains('@sha256:'))
```
En producción esto corresponde a un controlador de admisión de verificación de firmas (Sigstore policy-controller, Kyverno `verifyImages`) que coteja el digest contra una firma, ya que una lista blanca de registros solo prueba *de dónde* vinieron los bytes, no *quién* los construyó.

**Q25.** Porque los subrecursos se comparan explícitamente. Una entrada de `resourceRules` que lista `resources: ["pods"]` coincide con el recurso Pod en sí; la escritura de contenedores efímeros apunta a `pods/ephemeralcontainers`, un subrecurso distinto que debe nombrarse por separado (`resources: ["pods", "pods/ephemeralcontainers"]`). Esto es idéntico a cómo `ValidatingWebhookConfiguration` y RBAC tratan los subrecursos, y es una fuente rutinaria de bypasses de políticas — lo mismo aplica a `pods/exec`, `pods/attach`, `pods/portforward` y `pods/eviction`. Al escribir cualquier política con alcance de Pod, enumerá los subrecursos deliberadamente.

**Q26.** `spec.ephemeralContainers` es de solo agregado: el API server rechaza la eliminación, y `kubectl` no ofrece verbo de borrado para él. Una vez que se adjuntó un contenedor de depuración, la única forma de devolver el Pod a un estado conocido-bueno es **eliminar el Pod** y dejar que su controlador lo recree — para un Pod suelto, eso significa perderlo por completo. Operativamente esto es una ventaja para la inmutabilidad: un contenedor efímero es una marca permanente y auditable en la especificación del Pod, así que "¿este Pod fue depurado alguna vez?" es respondible desde la API mucho después de que el contenedor de depuración terminó. Incluí `spec.ephemeralContainers` en tus auditorías de desviación.

**Q27.** RBAC primero. Es un control único y bien entendido que aplica a todas las vías de acceso al subrecurso, no tiene costo de evaluación en tiempo de ejecución, no puede romperse por un error de CEL que tumbe la creación de Pods, y falla cerrado por defecto (la ausencia de una concesión es una denegación). La VAP es la segunda capa, y vale la pena tenerla porque RBAC es grueso — un rol de SRE de emergencia que legítimamente necesita `pods/ephemeralcontainers` igual se beneficia de verse obligado a adjuntar un contenedor de depuración endurecido. Regla de orden: preferí el mecanismo cuyo modo de falla es "nadie puede depurar" por sobre aquel cuyo modo de falla es "nadie puede desplegar".

**Q28.** (1) **Control de ejecución en rutas escribibles.** `readOnlyRootFilesystem` no puede expresar "esta ruta es escribible pero no ejecutable" — cada `emptyDir` que agregás es completamente ejecutable. La regla `deny /var/cache/nginx/** x` de AppArmor cierra exactamente el agujero demostrado en el Ejercicio 2 paso 7. (2) **Punto de aplicación independiente.** El root de solo lectura es una propiedad de un montaje, aplicada por el runtime en la creación del contenedor; un contenedor que gane `CAP_SYS_ADMIN` (por una mala configuración, un CVE del runtime, o un sidecar privilegiado compartiendo namespaces) puede remontarlo como lectura-escritura. AppArmor es aplicado por el LSM en cada syscall y no se deshace remontando. Además, AppArmor puede expresar reglas *más finas que un montaje* — denegar escrituras a `/etc/**` mientras las permite en otro lado de la misma capa — y produce registros de auditoría del kernel de cada denegación, dándote detección junto con prevención.

**Q29.** Fallar cerrado es lo correcto porque la alternativa — arrancar el contenedor silenciosamente *sin* el perfil — significaría que un Pod que se cree confinado corre sin confinamiento, y nada en `kubectl get pod` lo diría. Un control de seguridad que se degrada de forma invisible es peor que ningún control, porque produce falsa confianza. La implicancia para el despliegue: el perfil debe estar presente en **cada nodo al que el Pod podría ser programado**, antes de que la carga de trabajo lo referencie. En la práctica: distribuí perfiles con un DaemonSet privilegiado (o imagen de nodo / gestión de configuración), condicioná el despliegue de la carga de trabajo a que ese DaemonSet esté `Ready` en todo el clúster, y usá `nodeSelector`/labels de nodo durante un despliegue por fases para que los Pods solo puedan aterrizar en nodos que ya llevan el perfil. `kubectl exec <pod> -- cat /proc/self/attr/current` es la verificación por Pod, y `aa-status` la verificación por nodo.

**Q30.** El equivalente con seccomp sería bloquear las syscalls `execve`/`execveat` — pero seccomp filtra únicamente por **números de syscall y valores de registros**. No puede desreferenciar el puntero al argumento de nombre de ruta, así que no tiene forma de expresar "denegar exec *de archivos bajo /tmp*"; solo puede denegar `execve` por completo, lo que rompe cualquier proceso que genere hijos (incluyendo el maestro de nginx bifurcando workers, y cada script de shell en un entrypoint). El control de acceso obligatorio consciente de rutas es precisamente el trabajo para el que existe un LSM, y por eso AppArmor (basado en rutas) o SELinux (basado en etiquetas) es la herramienta correcta acá y seccomp la incorrecta. Usá seccomp para *reducción de superficie de ataque* — `RuntimeDefault` bloquea ~44 syscalls peligrosas como `mount`, `pivot_root`, `bpf`, `kexec_load`, `ptrace` — y un LSM para política *con alcance de recurso*. Son capas complementarias, no alternativas.

**Q31.** `// false` es el operador alternativo de jq: provee `false` cuando el lado izquierdo es `null` **o** `false`. El caso real que maneja es que el campo esté completamente **ausente** — un contenedor sin ningún `securityContext`, o uno que define otros campos pero omite `readOnlyRootFilesystem`. Sin él, `.securityContext.readOnlyRootFilesystem` evalúa a `null` para esos contenedores y `null != true` sigue cumpliéndose, así que el `select` funciona de casualidad — pero que `.securityContext` sea `null` hace que toda la expresión de ruta produzca `null` en lugar de dar error solo por la permisividad de jq, y en el momento en que extendés el filtro con una comparación encadenada o un `| .[]` se rompe. Escribir el valor por defecto explícitamente hace visible la suposición "no definido significa inseguro", que es el punto: **la ausencia es un hallazgo, no un hueco en los datos.**

**Q32.** Cuatro etapas, cada una con una señal explícita:
1. **Medir (`Audit` solamente, sin `namespaceSelector`).** Vinculá la política a todo el clúster con `validationActions: ["Audit"]` y leé las anotaciones `validation.policy.admission.k8s.io/validation_failure` del log de auditoría del API server. Señal: la cantidad y la *distribución por dueño* de las cargas de trabajo que fallan. Esperá que la mayoría falle; esa es la línea base, y necesitás la lista de dueños para planificar el trabajo.
2. **Advertir (`["Audit","Warn"]`).** Los desarrolladores ahora ven el mensaje en la salida de `kubectl apply` y en CI. Señal: la cantidad de fallas bajando semana a semana sin que vos abras tickets. Esta etapa también saca a la luz la asimetría Deployment-vs-Pod de la Q21 — `Warn` es la única acción que llega a la persona que ejecuta `kubectl apply` sobre un Deployment.
3. **Aplicar por excepción (`["Deny"]` + `namespaceSelector: {matchLabels: {immutability: enforced}}`).** Los equipos se suman etiquetando su namespace a medida que terminan la remediación. Señal: cantidad de namespaces etiquetados, y cero eventos `FailedCreate` en los `ReplicaSet`s de esos namespaces. Los namespaces nuevos deberían etiquetarse en su creación para que el trinquete solo se ajuste.
4. **Invertir el valor por defecto.** Una vez que el conjunto restante es chico y conocido, invertí el selector — aplicá en todos lados excepto en namespaces que lleven una etiqueta `immutability: exempt` explícita y con plazo. Señal: la lista de excepciones achicándose, y una alerta ante cualquier excepción más vieja que su vencimiento acordado. Nunca apliques en `kube-system` sin confirmar antes que los DaemonSets del plano de control y del CNI cumplen; varios (`kube-proxy`, algunos agentes CNI) legítimamente necesitan un root escribible y requieren una excepción a nivel de namespace o remediación por carga de trabajo aguas arriba.

</details>