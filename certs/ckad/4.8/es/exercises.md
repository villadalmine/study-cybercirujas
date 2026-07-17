# Tema 4.8 — Application Security: SecurityContext y Capabilities (CKAD v1.35)

> Fuente de referencia: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf) — dominio *Application Environment, Configuration and Security*, ítem "Understand Application security (SecurityContexts, Capabilities, etc.)".

Requisitos previos: un clúster con `kubectl` configurado (`kind`, `minikube` o similar) y permisos para crear Pods. Todos los ejercicios usan el namespace `ckad-sec`.

```bash
kubectl create namespace ckad-sec
kubectl config set-context --current --namespace=ckad-sec
```

---

## Ejercicio 1 — `securityContext` a nivel Pod: `runAsUser`, `runAsGroup`, `fsGroup`

1. Creá el archivo `pod-level-sc.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-level-sc
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  volumes:
    - name: data
      emptyDir: {}
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
```

2. Aplicá el manifiesto y esperá a que el Pod esté `Running`:

```bash
kubectl apply -f pod-level-sc.yaml
kubectl wait --for=condition=Ready pod/pod-level-sc --timeout=60s
```

3. Verificá la identidad del proceso dentro del contenedor:

```bash
kubectl exec pod-level-sc -- id
```

4. Verificá el group ownership del volumen montado:

```bash
kubectl exec pod-level-sc -- ls -ld /data
```

### Preguntas de comprensión

1. ¿Por qué el proceso corre con UID 1000 y GID 3000 aunque la imagen `busybox` no declara ningún `USER` en su Dockerfile?
2. ¿Qué diferencia hay entre `runAsGroup` y `fsGroup`, y cuál de los dos determina el group ownership de `/data`?

---

## Ejercicio 2 — `securityContext` a nivel Container: precedencia sobre el Pod

1. Modificá el manifiesto anterior para agregar un segundo contenedor que sobrescriba el `runAsUser` heredado, guardalo como `container-level-sc.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: container-level-sc
spec:
  securityContext:
    runAsUser: 1000
    fsGroup: 2000
  containers:
    - name: default-user
      image: busybox:1.36
      command: ["sleep", "3600"]
    - name: overridden-user
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        runAsUser: 4000
```

2. Aplicá el manifiesto:

```bash
kubectl apply -f container-level-sc.yaml
kubectl wait --for=condition=Ready pod/container-level-sc --timeout=60s
```

3. Compará el UID efectivo en cada contenedor:

```bash
kubectl exec container-level-sc -c default-user -- id -u
kubectl exec container-level-sc -c overridden-user -- id -u
```

### Preguntas de comprensión

1. ¿Qué regla de precedencia de Kubernetes explica que `overridden-user` corra como UID 4000 en vez de heredar el 1000 del Pod?
2. ¿El `fsGroup` definido a nivel Pod también puede sobrescribirse a nivel Container? ¿Por qué (pensá en qué recurso describe ese campo)?

---

## Ejercicio 3 — `runAsNonRoot`: bloqueo de contenedores que corren como root

1. Creá `nonroot-fail.yaml` usando una imagen cuyo `USER` por defecto es root, sin fijar `runAsUser`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nonroot-fail
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      image: nginx:1.27
```

2. Aplicá el manifiesto y observá el estado del Pod:

```bash
kubectl apply -f nonroot-fail.yaml
kubectl get pod nonroot-fail
kubectl describe pod nonroot-fail | tail -n 15
```

3. Corregí el problema agregando `runAsUser: 101` (UID no privilegiado que usa la imagen `nginx` oficial) y volvé a aplicar:

```bash
kubectl delete pod nonroot-fail
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nonroot-fail
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
  containers:
    - name: app
      image: nginx:1.27
```

4. Reaplicá y confirmá que ahora arranca:

```bash
kubectl apply -f nonroot-fail.yaml
kubectl get pod nonroot-fail
```

### Preguntas de comprensión

1. ¿En qué `status.containerStatuses[].state` y con qué motivo (`reason`) queda el Pod del paso 2, y en qué fase (`kubectl get pod`) lo ves reflejado?
2. ¿Por qué declarar solo `runAsNonRoot: true` sin `runAsUser` no alcanza para garantizar que el contenedor corra con un UID específico no-root?

---

## Ejercicio 4 — Linux Capabilities: `drop: [ALL]` + `add` selectivo

1. Creá `cap-fail.yaml`: un contenedor no-root que intenta escuchar en el puerto 80 (puerto privilegiado, <1024) sin capabilities extra:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cap-fail
spec:
  securityContext:
    runAsUser: 1000
  containers:
    - name: app
      image: busybox:1.36
      command: ["nc", "-l", "-p", "80"]
      securityContext:
        capabilities:
          drop: ["ALL"]
```

2. Aplicá y revisá los logs:

```bash
kubectl apply -f cap-fail.yaml
kubectl logs cap-fail
```

3. Ahora agregá la capability necesaria en `cap-fixed.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cap-fixed
spec:
  securityContext:
    runAsUser: 1000
  containers:
    - name: app
      image: busybox:1.36
      command: ["nc", "-l", "-p", "80"]
      securityContext:
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
```

4. Aplicá y confirmá que el proceso queda escuchando sin errores:

```bash
kubectl apply -f cap-fixed.yaml
kubectl logs cap-fixed
kubectl get pod cap-fixed
```

### Preguntas de comprensión

1. ¿Por qué un proceso con UID 1000 (no root) puede bindear el puerto 80 solo después de agregar `NET_BIND_SERVICE`, en vez de necesitar ser root?
2. ¿Qué ventaja de seguridad aporta hacer `drop: ["ALL"]` antes de agregar capabilities puntuales, en lugar de dejar el set de capabilities por default del container runtime?

---

## Ejercicio 5 — `privileged: true` y su alcance

1. Creá `privileged-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
```

2. Aplicá y esperá a que esté listo:

```bash
kubectl apply -f privileged-pod.yaml
kubectl wait --for=condition=Ready pod/privileged-pod --timeout=60s
```

3. Desde dentro del contenedor, listá los dispositivos de bloque del host (visibles solo por el modo privileged):

```bash
kubectl exec privileged-pod -- ls /dev
```

4. Compará con el Pod `cap-fail` del Ejercicio 4 (no privileged) intentando el mismo comando:

```bash
kubectl exec cap-fail -- ls /dev 2>&1 || true
```

### Preguntas de comprensión

1. ¿Qué otorga `privileged: true` que no otorga simplemente agregar capabilities una por una (por ejemplo `SYS_ADMIN`)?
2. En un clúster con Pod Security Admission en modo `restricted`, ¿qué pasaría al intentar aplicar `privileged-pod.yaml`?

---

## Ejercicio 6 — `readOnlyRootFilesystem` y `allowPrivilegeEscalation`

1. Creá `readonly-fail.yaml`, un contenedor con filesystem raíz de solo lectura que intenta escribir en `/tmp`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-fail
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hola > /tmp/test.txt && sleep 3600"]
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
```

2. Aplicá y revisá por qué el contenedor no queda `Running`:

```bash
kubectl apply -f readonly-fail.yaml
kubectl get pod readonly-fail
kubectl logs readonly-fail
```

3. Corregí montando un `emptyDir` en `/tmp` para darle un lugar escribible, en `readonly-fixed.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-fixed
spec:
  volumes:
    - name: tmp
      emptyDir: {}
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hola > /tmp/test.txt && sleep 3600"]
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
      volumeMounts:
        - name: tmp
          mountPath: /tmp
```

4. Aplicá y confirmá que ahora sí escribe correctamente:

```bash
kubectl apply -f readonly-fixed.yaml
kubectl wait --for=condition=Ready pod/readonly-fixed --timeout=60s
kubectl exec readonly-fixed -- cat /tmp/test.txt
```

### Preguntas de comprensión

1. ¿Por qué falla el contenedor de `readonly-fail.yaml` y cómo lo resuelve montar un volumen en `/tmp` en vez de sacar `readOnlyRootFilesystem`?
2. ¿Qué comportamiento del kernel bloquea concretamente `allowPrivilegeEscalation: false` (pensá en binarios `setuid`/`setgid` y el flag `no_new_privs`)?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
1. Porque `securityContext.runAsUser`/`runAsGroup` a nivel Pod se aplican como el UID/GID efectivo del proceso en tiempo de ejecución, independientemente del `USER` (o su ausencia) definido en la imagen — el kubelet/container runtime fuerza esa identidad al arrancar el proceso.
2. `runAsGroup` fija el GID primario del proceso. `fsGroup` es un GID suplementario que Kubernetes aplica a los volúmenes montados (cambia el group ownership de los archivos, típicamente vía `chown`/`chgrp` recursivo o `fsGroupChangePolicy`), para que el proceso pueda leer/escribir en ellos aunque su UID/GID de proceso no coincida con el dueño original del volumen. El group ownership de `/data` lo determina `fsGroup` (2000), no `runAsGroup`.

**Ejercicio 2**
1. Kubernetes aplica el `securityContext` de forma jerárquica: los campos definidos a nivel Container sobrescriben los del Pod para ese contenedor puntual; los campos no repetidos a nivel Container se heredan del Pod. Por eso `overridden-user` toma `runAsUser: 4000` en lugar de heredar 1000.
2. No, `fsGroup` es exclusivamente un campo de `PodSecurityContext` (no existe en `SecurityContext` de Container) porque describe el ownership de volúmenes compartidos por todos los contenedores del Pod, no un atributo de un proceso individual.

**Ejercicio 3**
1. El contenedor queda en `waiting` con `reason: CreateContainerConfigError` (no llega a iniciar el proceso), y en `kubectl get pod` se refleja como `Status: CreateContainerConfigError` (no `Running`, no `CrashLoopBackOff`, porque el error ocurre antes de ejecutar el entrypoint).
2. Porque `runAsNonRoot: true` es solo una validación: el kubelet chequea que el UID efectivo con el que arrancaría el contenedor no sea 0, pero si no se especifica `runAsUser`, ese UID efectivo es el que trae la imagen (el `USER` de su Dockerfile). Si ese UID es 0 (root), la validación falla; si la imagen ya define un `USER` no-root, puede pasar sin declarar `runAsUser`, pero no hay control explícito de *qué* UID se usa.

**Ejercicio 4**
1. Porque bindear puertos <1024 no depende de ser root (UID 0) sino de poseer la capability Linux `CAP_NET_BIND_SERVICE`. Al hacer `drop: ["ALL"]` se remueven todas las capabilities (incluida esa), y al agregar explícitamente `NET_BIND_SERVICE` se la devuelve sin necesidad de correr como root.
2. Aplica el principio de menor privilegio: el set de capabilities por default del container runtime (por ejemplo el de Docker/containerd) incluye varias capabilities que la mayoría de las apps no necesitan (`CHOWN`, `SETUID`, `SETGID`, `NET_RAW`, etc.). Partir de `drop: ["ALL"]` y sumar solo lo estrictamente necesario reduce la superficie de ataque frente a comprometer el proceso.

**Ejercicio 5**
1. `privileged: true` desactiva prácticamente todo el aislamiento de seguridad del contenedor: otorga todas las capabilities Linux, deshabilita las restricciones de seccomp/AppArmor por defecto y da acceso a los dispositivos del host (`/dev`), entre otras cosas. Agregar capabilities individuales (como `SYS_ADMIN`) amplía privilegios puntuales pero mantiene el resto de las restricciones (seccomp, acceso a dispositivos, namespaces) intactas.
2. Pod Security Admission en modo `restricted` rechaza la creación del Pod: ese perfil prohíbe explícitamente `privileged: true` (y exige, entre otras cosas, `allowPrivilegeEscalation: false`, `runAsNonRoot: true` y `capabilities.drop: ["ALL"]`).

**Ejercicio 6**
1. Falla porque `readOnlyRootFilesystem: true` monta el filesystem raíz del contenedor (incluido `/tmp`, salvo que se monte un volumen ahí) como solo lectura, y el comando intenta escribir un archivo en `/tmp`, lo que produce un error de "Read-only file system" y el contenedor termina con estado de error. Montar un `emptyDir` en `/tmp` da un punto de montaje escribible independiente del resto del filesystem raíz, permitiendo mantener el resto de la imagen inmutable en vez de desactivar la protección por completo.
2. `allowPrivilegeEscalation: false` habilita la flag de kernel `no_new_privs` en el proceso, que impide que este (o cualquier proceso hijo) obtenga más privilegios de los que ya tiene al ejecutar un binario, incluso si ese binario tiene el bit `setuid`/`setgid` activado. En la práctica, anula la escalación de privilegios vía binarios `setuid` (como `sudo` o `su`) dentro del contenedor.

</details>