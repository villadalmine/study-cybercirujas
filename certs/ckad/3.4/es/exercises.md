# 3.4 Debugging in Kubernetes — Ejercicios guiados

**Examen:** CKAD (versión 1.35) · **Peso:** 3

Todos los ejercicios usan un namespace dedicado para no interferir con otros recursos del cluster.

```bash
kubectl create namespace ckad-3-4
kubectl config set-context --current --namespace=ckad-3-4
```

---

## Ejercicio 1 — `kubectl exec`: comandos directos, sesión interactiva, multi-container

1. Creá un Pod con dos contenedores: uno principal (`app`) y un sidecar (`sidecar`).

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: multi
     labels:
       app: multi
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "echo 'DB_HOST=db.internal' > /tmp/env.txt; sleep 3600"]
     - name: sidecar
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
   EOF
   kubectl wait --for=condition=Ready pod/multi --timeout=60s
   ```

2. Corré un comando puntual (no interactivo) dentro del contenedor `app`, sin abrir una sesión.

   ```bash
   kubectl exec multi -c app -- cat /tmp/env.txt
   ```

3. Abrí una sesión interactiva dentro del contenedor `sidecar`.

   ```bash
   kubectl exec -it multi -c sidecar -- sh
   / # ps aux
   / # exit
   ```

4. Ejecutá `kubectl exec` **sin** indicar `-c` en este Pod de dos contenedores.

   ```bash
   kubectl exec multi -- ps aux
   ```

5. Probá qué pasa si el comando a ejecutar empieza con un guion, sin usar `--`.

   ```bash
   kubectl exec multi -c app ps aux
   ```

<details>
<summary>Preguntas — Ejercicio 1</summary>

1. ¿Por qué el paso 2 no necesita `-it`?
2. ¿Qué error da el paso 4, y por qué `kubectl exec` no puede simplemente elegir un contenedor por default?
3. ¿Qué diferencia de comportamiento hay entre el paso 3 (con `--`) y el paso 5 (sin `--`)?

**Respuestas**

1. `-it` (`--stdin --tty`) sirve para asignar una terminal interactiva a una sesión que el usuario controla en vivo (como una shell). El paso 2 corre un único comando (`cat`) que no necesita entrada del usuario ni una TTY: `kubectl exec` lo ejecuta, imprime la salida y termina, sin abrir sesión.
2. Da `error: a container name must be specified for pod multi, choose one of: [app sidecar]`. Igual que con `kubectl logs`, un Pod multi-contenedor no tiene un contenedor "default" implícito — `kubectl exec` necesita saber explícitamente en cuál de los namespaces de proceso ejecutar el comando, así que exige `-c` (o falla).
3. En este caso puntual (`ps aux` no tiene flags que empiecen con `-` que kubectl pueda confundir) probablemente ambos funcionan igual. Pero el `--` es la práctica correcta siempre: separa las flags que le corresponden a `kubectl` (como `-c`, `-it`) del comando remoto. Sin `--`, si el comando remoto tuviera una flag como `-l` o `-h`, `kubectl` podría intentar interpretarla como una flag propia y fallar con un error de parsing en vez de pasarla al contenedor.

</details>

---

## Ejercicio 2 — El límite de `kubectl exec`: imagen sin shell y `kubectl debug --target`

1. Creá un Pod con una imagen que **no tiene shell** (similar a una imagen *distroless* de producción).

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: api
     labels:
       app: api
   spec:
     containers:
     - name: api
       image: registry.k8s.io/pause:3.9
   EOF
   kubectl wait --for=condition=Ready pod/api --timeout=60s
   ```

2. Intentá abrir una shell dentro del contenedor.

   ```bash
   kubectl exec -it api -- sh
   ```

3. Como falló, adjuntá un **ephemeral container** con herramientas, apuntado al contenedor `api` con `--target`.

   ```bash
   kubectl debug -it api --image=busybox --target=api -- sh
   / # ps aux
   / # exit
   ```

4. Confirmá que el Pod original quedó con un contenedor efímero registrado.

   ```bash
   kubectl get pod api -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
   kubectl get pod api
   ```

<details>
<summary>Preguntas — Ejercicio 2</summary>

1. ¿Qué mensaje de error da el paso 2, y qué parte del mensaje indica específicamente que el problema es la ausencia de shell (y no, por ejemplo, un problema de permisos)?
2. En el paso 3, ¿por qué `ps aux` dentro del contenedor de debug muestra el proceso del contenedor `api` (`/pause`), si técnicamente son contenedores distintos?
3. En el paso 4, ¿cuántos contenedores muestra `kubectl get pod api` en la columna `READY` (por ejemplo `1/1` o `2/2`), y por qué?

**Respuestas**

1. Algo como `error: ... exec: "sh": executable file not found in $PATH: unknown`. La frase `executable file not found in $PATH` indica que el runtime buscó el binario `sh` dentro del filesystem de la imagen y no lo encontró — es un problema de que la imagen no incluye ese binario, no un error de autenticación/permisos (que daría un mensaje distinto, tipo `forbidden`).
2. Porque `--target=api` hace que el ephemeral container **comparta el namespace de proceso (PID)** con el contenedor `api`, aunque siga siendo un contenedor separado con su propio filesystem (el de `busybox`). Compartir el namespace de PID es lo que permite ver, señalizar o inspeccionar procesos de otro contenedor sin necesidad de "entrar" a su filesystem.
3. Sigue mostrando `1/1`: los ephemeral containers **no cuentan** para el `READY` del Pod (no tienen probes, no forman parte del ciclo de vida normal de contenedores) y no se pueden quitar sin borrar y recrear el Pod entero — son estrictamente para debug puntual.

</details>

---

## Ejercicio 3 — `kubectl debug --copy-to`: investigar sin tocar el Pod original

1. Creá un Pod cuyo contenedor crashea segundos después de arrancar (muy poco tiempo para hacer `exec` a tiempo).

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: flaky
     labels:
       app: flaky
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "echo 'INFO boot ok'; sleep 2; exit 1"]
   EOF
   ```

2. Esperá un par de ciclos de reinicio y confirmá el estado.

   ```bash
   sleep 30
   kubectl get pod flaky
   ```

3. Intentá entrar con `kubectl exec` mientras el contenedor está en medio del ciclo de crash.

   ```bash
   kubectl exec -it flaky -- sh
   ```

4. Creá una **copia** del Pod reemplazando el comando de arranque por una shell, para poder inspeccionar el filesystem sin que se dispare el crash.

   ```bash
   kubectl debug flaky -it --copy-to=flaky-debug --container=app -- sh
   / # ls /
   / # exit
   ```

5. Confirmá que el Pod original **no fue tocado** (sigue crasheando) y que la copia es un objeto aparte.

   ```bash
   kubectl get pod flaky flaky-debug
   ```

<details>
<summary>Preguntas — Ejercicio 3</summary>

1. ¿Por qué el paso 3 falla la mayoría de las veces (a veces con "unable to upgrade connection", a veces con el Pod ya reiniciado)?
2. ¿Qué pasó exactamente con el `command` del contenedor `app` en la copia `flaky-debug` respecto al Pod original? ¿Por qué el paso 4 no termina en el mismo crash loop?
3. `RESTARTS` en el paso 5, ¿sigue creciendo en `flaky` mientras se investiga con `flaky-debug`? Justificá con lo que significa `--copy-to`.

**Respuestas**

1. `kubectl exec` requiere que el contenedor esté en estado `Running` en el momento exacto de la conexión. Como `app` corre 2 segundos y termina, hay una ventana muy chica para conectarse antes de que el contenedor pase a `Terminated`/`CrashLoopBackOff` y la conexión falle (o directamente no llegue a tiempo).
2. `kubectl debug ... --copy-to=flaky-debug --container=app -- sh` crea un Pod nuevo con la misma spec que `flaky`, pero **reemplaza el `command`** del contenedor indicado en `--container` por el comando pasado después de `--` (acá, `sh`). El contenedor de la copia arranca directamente en una shell interactiva en vez de correr el script original que hacía `exit 1`, así que nunca dispara el crash.
3. Sí, `flaky` sigue reiniciándose de forma independiente — `--copy-to` crea un **objeto Pod completamente nuevo** (`flaky-debug`), no modifica ni pausa el original. Esto es justamente lo que lo hace seguro de usar: se puede investigar sin alterar el estado (ni el historial de reinicios) del Pod real.

</details>

---

## Ejercicio 4 — `kubectl debug node/<nombre>`: depurar el Node

1. Identificá un Node del cluster.

   ```bash
   kubectl get nodes
   ```

2. Lanzá un Pod de debug privilegiado sobre ese Node (reemplazá `<node>` por el nombre obtenido en el paso 1).

   ```bash
   kubectl debug node/<node> -it --image=busybox
   ```

3. Dentro de la sesión, usá `chroot` para operar como si estuvieras en el filesystem real del Node.

   ```bash
   / # chroot /host
   # cat /etc/os-release
   # df -h /var/lib/kubelet
   # exit
   / # exit
   ```

4. Listá los Pods del namespace `default` y confirmá que quedó un Pod de debug pendiente de limpieza manual.

   ```bash
   kubectl get pods -n default -o wide | grep node-debugger
   ```

5. Borralo.

   ```bash
   kubectl delete pod -n default -l "kubernetes.io/debug=node" --ignore-not-found 2>/dev/null || \
   kubectl get pods -n default | grep node-debugger | awk '{print $1}' | xargs -r kubectl delete pod -n default
   ```

<details>
<summary>Preguntas — Ejercicio 4</summary>

1. ¿Por qué el Pod de debug del paso 2 aparece en el namespace `default` (paso 4) y no en `ckad-3-4`, aunque ese sea el contexto actual?
2. ¿Qué gana la sesión al hacer `chroot /host` en el paso 3, en vez de simplemente inspeccionar el filesystem de la imagen `busybox`?
3. ¿Por qué este Pod de debug **no** se borra solo al salir de la sesión interactiva (a diferencia de, por ejemplo, `kubectl run --rm -it`)?

**Respuestas**

1. `kubectl debug node/<node>` crea un Pod de debug de **nivel de cluster**, no asociado a la app que se está corriendo en un namespace puntual — por eso se crea siempre en `default` (o el namespace configurado por default en el kubeconfig), independientemente del `--namespace` actual del contexto.
2. `busybox` por sí sola solo tiene el filesystem de esa imagen mínima. El Pod de debug de Node monta el filesystem real del Node en `/host` (vía un `hostPath` de `/`), así que `chroot /host` hace que los comandos siguientes (`cat /etc/os-release`, `df -h`) vean el sistema operativo y los discos reales del Node, no los del contenedor `busybox`.
3. El Pod de debug de Node no usa `--rm`, y además corre con `hostNetwork`/`hostPID` y acceso privilegiado — Kubernetes lo trata como un Pod normal de larga duración, no como un proceso efímero atado a la sesión de terminal. Queda corriendo (y consumiendo el Node) hasta que se borra explícitamente con `kubectl delete pod`.

</details>

---

## Ejercicio 5 — `kubectl port-forward`: aislar problema de app vs. Service

1. Desplegá una app y un Service cuyo `selector` está mal escrito a propósito (no matchea los labels del Pod).

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: web
     template:
       metadata:
         labels:
           app: web
       spec:
         containers:
         - name: web
           image: nginx:1.27
           ports:
           - containerPort: 80
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: web-svc
   spec:
     selector:
       app: web-svc
     ports:
     - port: 80
       targetPort: 80
   EOF
   kubectl wait --for=condition=Available deployment/web --timeout=60s
   ```

2. Confirmá que el Service no tiene ningún Endpoint.

   ```bash
   kubectl get endpoints web-svc
   ```

3. Probá acceso **directo al Pod**, sin pasar por el Service.

   ```bash
   POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl port-forward pod/$POD 8080:80 &
   sleep 2
   curl -s -o /dev/null -w "%{http_code}\n" localhost:8080
   kill %1
   ```

4. Probá acceso **vía el Service**.

   ```bash
   kubectl port-forward svc/web-svc 8081:80
   ```

5. Corregí el `selector` del Service y repetí el paso 4.

   ```bash
   kubectl patch service web-svc -p '{"spec":{"selector":{"app":"web"}}}'
   kubectl get endpoints web-svc
   kubectl port-forward svc/web-svc 8081:80 &
   sleep 2
   curl -s -o /dev/null -w "%{http_code}\n" localhost:8081
   kill %1
   ```

<details>
<summary>Preguntas — Ejercicio 5</summary>

1. ¿Qué muestra `kubectl get endpoints web-svc` en el paso 2, y qué relación hay entre ese resultado y el `selector` del Service?
2. ¿Por qué el paso 3 funciona (`200`) mientras que el paso 4, antes de corregir el `selector`, falla?
3. Con este resultado, ¿en qué "capa" se puede afirmar con certeza que **no** está el problema, y en cuál sí?

**Respuestas**

1. Muestra `<none>` en la columna `ENDPOINTS`. Un Service solo agrega a su lista de Endpoints las IPs de los Pods cuyos labels coinciden **exactamente** con `spec.selector`; como el Service busca `app: web-svc` y el Pod tiene `app: web`, no matchea ningún Pod y la lista queda vacía.
2. `kubectl port-forward pod/<pod>` apunta directo a la IP del Pod, sin consultar el `selector` del Service en absoluto — el binario y el puerto 80 del contenedor `nginx` funcionan perfectamente. `kubectl port-forward svc/web-svc`, en cambio, necesita resolver el Service a uno de sus Pods backend usando los Endpoints; como la lista está vacía, no tiene a qué Pod conectarse y falla (típicamente con un error del estilo `no endpoints available for service "web-svc"`).
3. Se puede afirmar con certeza que el problema **no** está en la aplicación (`nginx` responde `200` correctamente cuando se accede directo al Pod). El problema está aislado a la capa de **Service/networking** — específicamente a la relación `selector`↔`labels` — que es exactamente lo que se corrige en el paso 5.

</details>

---

## Ejercicio 6 — `kubectl proxy` y `kubectl cp`

1. Levantá un proxy local hacia la API en background.

   ```bash
   kubectl proxy --port=8001 &
   sleep 2
   ```

2. Consultá el Pod `web` (del ejercicio anterior) directamente vía la API REST, sin usar `kubectl get`.

   ```bash
   POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
   curl -s http://localhost:8001/api/v1/namespaces/ckad-3-4/pods/$POD | grep '"phase"'
   ```

3. Copiá un archivo local hacia el contenedor `web`, reemplazando el contenido que sirve `nginx`.

   ```bash
   echo "<h1>ckad-3-4 debug lab</h1>" > /tmp/index.html
   kubectl cp /tmp/index.html $POD:/usr/share/nginx/html/index.html -c web
   ```

4. Confirmá el cambio, primero copiando el archivo de vuelta, y después pidiéndolo por HTTP a través del proxy de la API (vía el subresource `proxy` de un Pod).

   ```bash
   kubectl cp $POD:/usr/share/nginx/html/index.html -c web /tmp/index-check.html
   diff /tmp/index.html /tmp/index-check.html && echo "sin diferencias"

   curl -s http://localhost:8001/api/v1/namespaces/ckad-3-4/pods/$POD:80/proxy/
   ```

5. Cerrá el proxy en background.

   ```bash
   kill %1
   ```

<details>
<summary>Preguntas — Ejercicio 6</summary>

1. ¿Qué diferencia de alcance hay entre `kubectl proxy` (usado acá) y `kubectl port-forward` (usado en el ejercicio anterior) para llegar al mismo Pod?
2. ¿Por qué `kubectl cp` en el paso 3 funciona sin problemas contra el contenedor `web` (imagen `nginx`), a diferencia del Pod `api` del Ejercicio 2?
3. En el paso 4, la URL usa `.../pods/$POD:80/proxy/` en vez de `.../pods/$POD` a secas. ¿Qué parte de esa URL sería necesario ajustar si `nginx` escuchara en el puerto `8080` en lugar del `80`?

**Respuestas**

1. `kubectl port-forward` abre un túnel puntual a un recurso específico (un Pod o un Service, a un puerto dado) y solo sirve ese propósito. `kubectl proxy` da acceso a **toda la API REST** del cluster con las credenciales del `kubeconfig` actual — desde ahí se puede consultar cualquier recurso (no solo Pods) y también usar el subresource `proxy` para llegar a las apps corriendo adentro, como se ve en el paso 4.
2. La imagen `nginx` es una imagen completa basada en Debian que incluye `tar` (herramienta que `kubectl cp` usa internamente para empaquetar el contenido antes de transferirlo). La imagen `registry.k8s.io/pause:3.9` del Ejercicio 2, en cambio, no tiene ni siquiera un shell, mucho menos `tar` — ahí `kubectl cp` fallaría igual que `kubectl exec`.
3. Habría que cambiar el `:80` en `$POD:80` por `:8080` (el puerto del contenedor al que se quiere llegar) — esa parte de la URL indica a qué puerto del Pod reenviar la solicitud proxied, de forma análoga al segundo número en `kubectl port-forward <recurso> <local>:<remoto>`.

</details>

---

## Ejercicio 7 — Diagnóstico combinado: leer `STATUS`/`REASON` y elegir la herramienta correcta

1. Desplegá tres Pods rotos al mismo tiempo, cada uno con una falla distinta.

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: needs-too-much
   spec:
     containers:
     - name: app
       image: nginx:1.27
       resources:
         requests:
           cpu: "32"
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad-tag
   spec:
     containers:
     - name: app
       image: nginx:1.27-does-not-exist
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
   spec:
     containers:
     - name: app
       image: polinux/stress
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
       resources:
         limits:
           memory: "50Mi"
   EOF
   sleep 40
   ```

2. Mirá el estado general y anotá el `STATUS` de cada uno.

   ```bash
   kubectl get pods
   ```

3. Para `needs-too-much`, confirmá la causa en `Events`.

   ```bash
   kubectl describe pod needs-too-much | tail -6
   ```

4. Para `bad-tag`, confirmá la causa en `Events`.

   ```bash
   kubectl describe pod bad-tag | tail -6
   ```

5. Para `memory-hog`, confirmá la causa combinando `describe` y `logs --previous`.

   ```bash
   kubectl describe pod memory-hog | grep -A6 "Last State"
   kubectl logs memory-hog --previous
   ```

6. Corregí los tres: bajá el `cpu` request a algo razonable, corregí el tag de imagen, y subí el `memory` limit por encima de lo que reserva `stress`.

   ```bash
   kubectl delete pod needs-too-much bad-tag memory-hog

   cat <<'EOF' | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: needs-too-much
   spec:
     containers:
     - name: app
       image: nginx:1.27
       resources:
         requests:
           cpu: "100m"
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad-tag
   spec:
     containers:
     - name: app
       image: nginx:1.27
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
   spec:
     containers:
     - name: app
       image: polinux/stress
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
       resources:
         limits:
           memory: "300Mi"
   EOF
   kubectl wait --for=condition=Ready pod/needs-too-much pod/bad-tag pod/memory-hog --timeout=60s
   kubectl get pods
   ```

<details>
<summary>Preguntas — Ejercicio 7</summary>

1. ¿Qué `STATUS` esperás ver para cada uno de los tres Pods en el paso 2, y qué comando del paso 3/4/5 confirma cada causa?
2. ¿Por qué `needs-too-much` nunca pasa a `Running` con solo esperar más tiempo, a diferencia de `memory-hog`, que sí llega a arrancar (aunque termine reiniciándose)?
3. En el paso 5, ¿por qué hace falta tanto `describe` como `logs --previous` para diagnosticar `memory-hog` — qué información aporta cada uno que el otro no da?

**Respuestas**

1. `needs-too-much` queda en `Pending` (pide `32` CPUs completas, que ningún Node del lab tiene disponibles) — se confirma con el evento `FailedScheduling: Insufficient cpu` en el paso 3. `bad-tag` queda en `ImagePullBackOff`/`ErrImagePull` (el tag `nginx:1.27-does-not-exist` no existe en el registry) — se confirma con el evento `Failed to pull image` en el paso 4. `memory-hog` queda en `CrashLoopBackOff` con `Last State: Terminated, Reason: OOMKilled` — se confirma con `describe` (paso 5) mostrando `OOMKilled`, mientras que `stress` no llega a loguear nada útil antes de que lo maten.
2. `Pending` por falta de recursos es un problema de **scheduling**: el `kube-scheduler` directamente no asigna el Pod a ningún Node hasta que exista uno con suficiente CPU disponible — nunca llega a crearse un contenedor, así que no hay nada que "reintentar". `memory-hog`, en cambio, sí logra ser programado y su contenedor sí arranca; recién cuando el proceso `stress` supera el `memory limit` el kubelet lo mata (`OOMKilled`) y el kubelet lo reinicia según la `restartPolicy`, generando el patrón `CrashLoopBackOff` en lugar de quedar bloqueado antes de arrancar.
3. `kubectl describe` aporta el **veredicto de la plataforma**: `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137` — confirma que el kernel mató el proceso por exceso de memoria, algo que la aplicación misma no puede reportar porque no le da tiempo de loguear nada al ser terminada abruptamente (`SIGKILL`). `kubectl logs --previous` aporta lo que la aplicación alcanzó a escribir en stdout/stderr antes de morir — en este caso, probablemente nada o muy poco, lo cual en sí mismo es una pista: un crash con logs vacíos apunta a una terminación externa abrupta (como `OOMKilled`) en vez de un error manejado por la propia app.

</details>

---

## Limpieza

```bash
# por si algún background job de proxy/port-forward quedó vivo
kill %1 %2 2>/dev/null

kubectl get pods -n default | grep node-debugger | awk '{print $1}' | xargs -r kubectl delete pod -n default

kubectl config set-context --current --namespace=default
kubectl delete namespace ckad-3-4
```
