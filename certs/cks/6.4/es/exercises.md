# Ensure immutability of containers at runtime (CKS 6.4)

> Fuente de referencia: [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

La inmutabilidad de un container en runtime tiene dos caras complementarias: que el **filesystem raíz no se pueda modificar** una vez el container está corriendo, y que la **imagen en sí** tenga la mínima superficie posible (sin shell, sin gestor de paquetes) para que, aun si alguien logra ejecutar código dentro del container, no tenga herramientas para explotarlo o persistir cambios. Estos ejercicios recorren ambos frentes: `readOnlyRootFilesystem`, el uso de `emptyDir` para los paths que sí necesitan escritura, el resto del `securityContext` de defensa en profundidad, la aplicación del perfil `restricted` de Pod Security Admission a nivel namespace, y una comparación con imágenes mínimas sin shell.

## Ejercicio 1: comprobar que un container "normal" es mutable en runtime

1. Creá el manifiesto de un Pod sin ninguna restricción de `securityContext`:

```yaml
cat <<EOF > mutable-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mutable-nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    ports:
    - containerPort: 80
EOF
```

2. Aplicalo y esperá a que esté listo:

```bash
kubectl apply -f mutable-pod.yaml
kubectl wait --for=condition=Ready pod/mutable-nginx --timeout=60s
```

3. Escribí un archivo dentro del filesystem del container:

```bash
kubectl exec mutable-nginx -- sh -c "echo pwned > /usr/share/nginx/html/index.html && cat /usr/share/nginx/html/index.html"
```

4. Instalá un paquete que no estaba en la imagen original:

```bash
kubectl exec mutable-nginx -- sh -c "apt-get update -qq && apt-get install -y -qq curl && which curl"
```

Ambos comandos van a completarse sin error: el filesystem raíz del container es completamente escribible por default.

**Preguntas de verificación:**

1. ¿Por qué representa un riesgo de seguridad que un atacante con acceso al container pueda escribir archivos o instalar paquetes en tiempo de ejecución?
2. ¿Qué mecanismo nativo de Kubernetes permite bloquear cualquier escritura en el filesystem raíz del container?

## Ejercicio 2: activar `readOnlyRootFilesystem`

1. Borrá el Pod anterior y creá una versión con el filesystem raíz de solo lectura:

```yaml
kubectl delete pod mutable-nginx --ignore-not-found

cat <<EOF > readonly-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    securityContext:
      readOnlyRootFilesystem: true
    ports:
    - containerPort: 80
EOF
```

2. Aplicalo y observá su estado:

```bash
kubectl apply -f readonly-pod.yaml
kubectl get pod readonly-nginx -w
```

3. Vas a ver que el Pod entra en `CrashLoopBackOff` (o queda `NotReady`). Revisá el motivo:

```bash
kubectl logs readonly-nginx
```

El log muestra algo como `mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)`.

**Preguntas de verificación:**

3. ¿Por qué falla nginx al arrancar con `readOnlyRootFilesystem: true`?
4. Kubernetes ya bloquea la escritura a nivel de filesystem completo; ¿qué mecanismo daría acceso de escritura únicamente a los paths puntuales que la aplicación necesita, sin volver a abrir todo el filesystem?

## Ejercicio 3: dar acceso de escritura solo a los paths necesarios con `emptyDir`

1. Borrá el Pod anterior y creá una versión que monta `emptyDir` en los directorios que nginx necesita escribir (`/var/cache/nginx`, `/var/run`, `/tmp`):

```yaml
kubectl delete pod readonly-nginx --ignore-not-found

cat <<EOF > readonly-writable-paths.yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-nginx-fixed
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    securityContext:
      readOnlyRootFilesystem: true
    ports:
    - containerPort: 80
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
EOF
```

2. Aplicalo y confirmá que esta vez arranca bien:

```bash
kubectl apply -f readonly-writable-paths.yaml
kubectl wait --for=condition=Ready pod/readonly-nginx-fixed --timeout=60s
```

3. Confirmá que sí podés escribir en un path montado:

```bash
kubectl exec readonly-nginx-fixed -- sh -c "touch /var/cache/nginx/proof && echo OK"
```

4. Confirmá que el resto del filesystem sigue siendo inmutable:

```bash
kubectl exec readonly-nginx-fixed -- sh -c "echo test > /usr/share/nginx/html/index.html"
```

Este último comando falla con `Read-only file system`, aunque el Pod esté `Running`.

**Preguntas de verificación:**

5. ¿Por qué el comando del paso 4 sigue fallando aunque el Pod ahora esté `Running` y tenga volúmenes de escritura montados?
6. Si se borra este Pod, ¿qué pasa con los archivos escritos en `/var/cache/nginx`? ¿Por qué esto no compromete la inmutabilidad del container?

## Ejercicio 4: defensa en profundidad — imagen non-root, sin privilege escalation, sin capabilities

1. Reemplazá la imagen oficial (que corre como `root` y necesita el puerto 80) por una variante pensada para correr como usuario no privilegiado, y sumá el resto de las restricciones de `securityContext`:

```yaml
cat <<EOF > hardened-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-nginx
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: nginx
    image: nginxinc/nginx-unprivileged:1.27-alpine
    securityContext:
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
    ports:
    - containerPort: 8080
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
EOF
```

2. Aplicalo y verificá que corre como usuario no root:

```bash
kubectl apply -f hardened-nginx.yaml
kubectl wait --for=condition=Ready pod/hardened-nginx --timeout=60s
kubectl exec hardened-nginx -- id
```

3. Confirmá que sigue sin poder escribir fuera de los paths montados:

```bash
kubectl exec hardened-nginx -- sh -c "touch /root/x"
```

**Preguntas de verificación:**

7. ¿Por qué no alcanza con poner `runAsNonRoot: true` sobre la imagen oficial `nginx:1.27` sin cambiar de imagen?
8. ¿Qué previene específicamente `allowPrivilegeEscalation: false`, más allá de correr como usuario no root?

## Ejercicio 5: forzar la inmutabilidad a nivel de cluster con Pod Security Admission

1. Creá un namespace y etiquetalo para que el admission controller de Pod Security rechace cualquier Pod que no cumpla el perfil `restricted`:

```bash
kubectl create namespace secure-workloads
kubectl label namespace secure-workloads \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

2. Intentá crear en ese namespace el Pod sin restricciones del Ejercicio 1:

```bash
kubectl apply -n secure-workloads -f mutable-pod.yaml
```

El comando falla: el admission controller devuelve el listado de violaciones (falta `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile`, etc.).

3. Ahora aplicá el Pod endurecido del Ejercicio 4 en el mismo namespace:

```bash
kubectl apply -n secure-workloads -f hardened-nginx.yaml
```

Este sí se crea, porque ya cumple todos los requisitos del perfil `restricted`.

**Preguntas de verificación:**

9. En modo `enforce`, ¿qué ocurre exactamente con un Pod que viola el perfil `restricted`: se crea igual y queda marcado, o la creación es rechazada?
10. ¿Por qué conviene aplicar el perfil `restricted` a nivel namespace en lugar de confiar en que cada manifiesto incluya manualmente el `securityContext` correcto?

## Ejercicio 6: inmutabilidad de la imagen — contraste con un container sin shell

1. Corré un Pod desde una imagen mínima que no incluye shell ni utilidades:

```bash
kubectl run pause-test --image=registry.k8s.io/pause:3.9 --restart=Never
kubectl wait --for=condition=Ready pod/pause-test --timeout=30s
```

2. Intentá abrir una shell interactiva dentro de ese Pod:

```bash
kubectl exec -it pause-test -- sh
```

El comando falla con algo como `OCI runtime exec failed: exec: "sh": executable file not found in $PATH`.

3. Compará contra el Pod `hardened-nginx` del Ejercicio 4, que sí tiene shell (Alpine):

```bash
kubectl exec -it hardened-nginx -- sh
```

Este sí abre una shell interactiva, aunque el filesystem raíz siga siendo de solo lectura.

**Preguntas de verificación:**

11. Aunque no configuramos `readOnlyRootFilesystem` en `pause-test`, ¿por qué la ausencia de shell y de gestor de paquetes en la imagen sigue siendo un aporte real a la inmutabilidad del container en runtime?
12. ¿Por qué en la práctica conviene combinar imágenes mínimas (sin shell) con `readOnlyRootFilesystem`, en vez de apoyarse en un solo control?

## Limpieza

```bash
kubectl delete pod hardened-nginx readonly-nginx-fixed pause-test --ignore-not-found
kubectl delete namespace secure-workloads --ignore-not-found
```

<details>
<summary>Ver respuestas</summary>

1. Porque el filesystem del container en ejecución deja de coincidir con la imagen auditada/escaneada: un atacante puede dejar malware persistente durante la vida del Pod, modificar binarios o configuración, e instalar herramientas nuevas (como `curl`) que amplían lo que puede hacer, todo sin que quede reflejado en la imagen original ni sea detectable comparando contra ella.

2. `securityContext.readOnlyRootFilesystem: true` en el container, que monta el filesystem raíz del container en modo solo lectura.

3. Porque nginx necesita escribir archivos temporales y de caché al arrancar (`/var/cache/nginx/*`), el PID file (`/var/run/nginx.pid`) y archivos temporales (`/tmp`), y con el filesystem raíz completo en solo lectura ninguna de esas escrituras es posible.

4. Montar volúmenes `emptyDir` en los paths exactos que la aplicación necesita escribir (`volumeMounts` sobre `volumes` de tipo `emptyDir`), dejando el resto del filesystem raíz en solo lectura.

5. Porque `readOnlyRootFilesystem: true` sigue aplicando a todo el filesystem raíz excepto a los paths donde se montó explícitamente un volumen escribible. Solo se "abre" lo que se monta; todo lo demás (como `/usr/share/nginx/html`, que no tiene ningún volumen montado ahí) permanece de solo lectura.

6. Los archivos se pierden: un `emptyDir` es efímero y está atado al ciclo de vida del Pod, se borra cuando el Pod se elimina. Esto no compromete la inmutabilidad porque el próximo Pod arranca siempre desde la imagen original (sin modificar) más volúmenes vacíos nuevos — no hay drift acumulado entre reinicios.

7. Porque la imagen oficial `nginx:1.27` está construida para correr como `root`: sus archivos, permisos y el binding al puerto 80 (puerto privilegiado, <1024) asumen ese usuario. Poner `runAsNonRoot: true` sin cambiar de imagen no "convierte" la imagen en no-root: el kubelet directamente rechaza arrancar el container (o falla al iniciar) porque el proceso no puede escribir sus propios archivos ni bindear el puerto. Por eso se usa una imagen construida específicamente para correr sin privilegios (como `nginxinc/nginx-unprivileged`, que escucha en un puerto >1024 y es dueña de sus archivos como usuario no root).

8. Evita que un proceso obtenga más privilegios que su proceso padre, aunque ya esté corriendo como no-root — por ejemplo, bloquea la ejecución efectiva de binarios con bit `setuid`/`setgid` o capabilities de archivo, que de otro modo permitirían escalar privilegios (como un `sudo` o `su` si existieran en la imagen).

9. En modo `enforce`, la creación del Pod es rechazada directamente por el API server (el comando `kubectl apply` falla con el listado de violaciones). Esto es distinto de `audit`, que permite la creación pero registra la violación en el audit log, y de `warn`, que también permite la creación pero devuelve una advertencia visible al cliente (`kubectl`).

10. Porque centraliza el control en la capa de admisión del cluster, independientemente de lo que cada autor de manifiestos escriba u olvide escribir. Un namespace con `restricted` aplicado garantiza una base mínima consistente y auditable para todos los Pods de ese namespace, sin depender de que cada equipo recuerde agregar el `securityContext` correcto manualmente.

11. Porque aunque el filesystem fuera escribible, un atacante que logra ejecutar código (por ejemplo vía una vulnerabilidad en la app) no tiene shell interactiva ni gestor de paquetes disponibles para explorar el sistema, descargar herramientas adicionales o instalar persistencia manualmente. Reduce la superficie de ataque práctica independientemente de los permisos del filesystem.

12. Porque son controles independientes que cubren fallos distintos: `readOnlyRootFilesystem` bloquea la escritura aunque exista una shell disponible; una imagen sin shell bloquea la explotación interactiva aunque algún path quedara escribible por error de configuración. Combinarlos da defensa en profundidad: si uno de los dos controles falla o se configura mal, el otro sigue reduciendo el impacto.

</details>