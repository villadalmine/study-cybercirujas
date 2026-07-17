# CKAD 3.4 — Debugging in Kubernetes (ejercicios guiados)

> Fuente de referencia: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

**Prerrequisitos**: acceso a un cluster (`minikube`, `kind` o similar) con `kubectl` configurado, y un namespace de trabajo:

```bash
kubectl create namespace debug-lab
kubectl config set-context --current --namespace=debug-lab
```

---

## Ejercicio 1 — Pod en estado `Pending`

1. Creá un Pod que pide más recursos de los que el cluster puede ofrecer:

```yaml
# pending-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pending-pod
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        cpu: "100"
        memory: "500Gi"
```

```bash
kubectl apply -f pending-pod.yaml
```

2. Verificá el estado del Pod:

```bash
kubectl get pod pending-pod
```

3. Investigá la causa con `describe`, prestando atención a la sección `Events`:

```bash
kubectl describe pod pending-pod
```

4. Limpiá el recurso:

```bash
kubectl delete -f pending-pod.yaml
```

**Preguntas**
- ¿Qué sección de `kubectl describe pod` muestra la razón exacta por la que el scheduler no pudo asignar el Pod a un Node?
- ¿Qué comando usarías para ver rápidamente si el problema es de recursos insuficientes en los Nodes del cluster?

---

## Ejercicio 2 — `CrashLoopBackOff`

1. Creá un Pod cuyo container termina inmediatamente con error:

```yaml
# crash-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: crash-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'fallo simulado' && exit 1"]
```

```bash
kubectl apply -f crash-pod.yaml
```

2. Esperá unos segundos y observá el estado y el conteo de reinicios:

```bash
kubectl get pod crash-pod -w
```

(salí con `Ctrl+C` cuando veas `CrashLoopBackOff`)

3. Revisá los logs del intento actual:

```bash
kubectl logs crash-pod
```

4. Revisá los logs del contenedor anterior (el que crasheó antes del último restart):

```bash
kubectl logs crash-pod --previous
```

5. Limpiá el recurso:

```bash
kubectl delete -f crash-pod.yaml
```

**Preguntas**
- ¿Por qué `kubectl logs crash-pod` puede no mostrar información útil apenas creado el Pod, y qué flag soluciona eso para ver el intento fallido anterior?
- ¿Qué campo de `kubectl describe pod crash-pod` indica cuántas veces se reinició el container?

---

## Ejercicio 3 — Debugging interactivo con `kubectl exec`

1. Creá un Pod de larga duración:

```bash
kubectl run debug-target --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/debug-target
```

2. Abrí una shell interactiva dentro del container:

```bash
kubectl exec -it debug-target -- /bin/sh
```

3. Dentro de la shell, verificá que el proceso `nginx` esté corriendo y que el archivo de configuración exista:

```bash
ps aux
cat /etc/nginx/nginx.conf
exit
```

4. Ejecutá un comando puntual sin entrar a una shell interactiva:

```bash
kubectl exec debug-target -- nginx -v
```

5. Limpiá el recurso:

```bash
kubectl delete pod debug-target
```

**Preguntas**
- ¿Qué combinación de flags de `kubectl exec` es necesaria para obtener una terminal interactiva (TTY + stdin)?
- Si el Pod tuviera más de un container, ¿qué flag usarías para indicar a cuál conectarte?

---

## Ejercicio 4 — Ephemeral containers con `kubectl debug`

1. Creá un Pod minimalista sin herramientas de debugging (imagen `distroless` o similar, simulada con `busybox` sin shell de utilidades extendidas):

```bash
kubectl run minimal-pod --image=busybox --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/minimal-pod
```

2. Adjuntá un ephemeral container con herramientas de red/diagnóstico al Pod en ejecución, sin reiniciarlo:

```bash
kubectl debug -it minimal-pod --image=busybox --target=minimal-pod -- sh
```

3. Dentro de la sesión, verificá que compartís los namespaces de proceso con el container original:

```bash
ps aux
exit
```

4. Confirmá que el ephemeral container quedó registrado en la definición del Pod:

```bash
kubectl get pod minimal-pod -o jsonpath='{.spec.ephemeralContainers[*].name}'
```

5. Limpiá el recurso:

```bash
kubectl delete pod minimal-pod
```

**Preguntas**
- ¿Cuál es la ventaja principal de `kubectl debug` con ephemeral containers frente a modificar la imagen del container original para agregar herramientas de diagnóstico?
- ¿Qué hace el flag `--target` y por qué es necesario para ver los procesos del container original con `ps aux`?

---

## Ejercicio 5 — Fallas de `readinessProbe` / `livenessProbe`

1. Creá un Pod con una `readinessProbe` que apunta a un path inexistente:

```yaml
# probe-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: probe-pod
spec:
  containers:
  - name: app
    image: nginx
    readinessProbe:
      httpGet:
        path: /no-existe
        port: 80
      periodSeconds: 5
      failureThreshold: 2
```

```bash
kubectl apply -f probe-pod.yaml
```

2. Observá que el Pod corre pero nunca queda `Ready`:

```bash
kubectl get pod probe-pod
```

3. Confirmá la causa en los eventos:

```bash
kubectl describe pod probe-pod | grep -A5 Events
```

4. Corregí el path de la probe con `kubectl edit` o reaplicando el manifiesto con `/` como path, y verificá que el Pod pase a `Ready`:

```bash
kubectl set probe pod probe-pod --readiness --get-url=http://:80/
kubectl get pod probe-pod -w
```

5. Limpiá el recurso:

```bash
kubectl delete -f probe-pod.yaml
```

**Preguntas**
- ¿Qué diferencia de comportamiento hay entre un Pod que falla su `readinessProbe` y uno que falla su `livenessProbe`?
- ¿En qué columna de `kubectl get pod` se refleja que un container no pasó su `readinessProbe`, aunque el Pod esté en fase `Running`?

---

## Ejercicio 6 — Conectividad de un `Service`

1. Desplegá una app y su Service, pero con un `selector` mal configurado:

```yaml
# broken-svc.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
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
        image: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web-incorrecto
  ports:
  - port: 80
    targetPort: 80
```

```bash
kubectl apply -f broken-svc.yaml
```

2. Verificá que el Service no tiene endpoints:

```bash
kubectl get endpoints web-svc
```

3. Confirmá el mismatch comparando los labels del Deployment con el selector del Service:

```bash
kubectl get pods -l app=web --show-labels
kubectl describe service web-svc | grep Selector
```

4. Corregí el selector y confirmá que aparecen endpoints:

```bash
kubectl patch service web-svc -p '{"spec":{"selector":{"app":"web"}}}'
kubectl get endpoints web-svc
```

5. Probá la resolución DNS del Service desde otro Pod:

```bash
kubectl run tmp-shell --image=busybox --restart=Never -it --rm -- nslookup web-svc
```

6. Limpiá los recursos:

```bash
kubectl delete -f broken-svc.yaml
```

**Preguntas**
- ¿Qué comando confirma, sin ambigüedad, que un `Service` no tiene ningún Pod backend asociado?
- ¿Qué patrón de nombre resuelve `nslookup` para un Service dentro del mismo namespace vs. en otro namespace?

---

## Ejercicio 7 — Uso de recursos con `kubectl top`

1. Asegurate de tener `metrics-server` instalado (en `minikube`: `minikube addons enable metrics-server`).

2. Desplegá un Pod que consume CPU de forma sostenida:

```bash
kubectl run cpu-hog --image=busybox --restart=Never -- sh -c "while true; do :; done"
```

3. Esperá ~30 segundos a que metrics-server recolecte datos y consultá el consumo:

```bash
kubectl top pod cpu-hog
```

4. Consultá el consumo agregado por Node:

```bash
kubectl top node
```

5. Limpiá el recurso:

```bash
kubectl delete pod cpu-hog
```

**Preguntas**
- ¿Por qué `kubectl top pod` puede devolver `error: Metrics API not available` inmediatamente después de instalar `metrics-server`?
- ¿Qué diferencia hay entre lo que reporta `kubectl top pod` y los valores de `resources.requests`/`resources.limits` definidos en el manifiesto?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
- La sección `Events` del `describe pod` (al final de la salida) muestra el mensaje del scheduler, por ejemplo `0/1 nodes are available: 1 Insufficient cpu`.
- `kubectl describe nodes` (o `kubectl top node` si hay metrics-server) muestra la capacidad y el uso actual de cada Node para comparar contra lo solicitado (`requests`) por el Pod.

**Ejercicio 2**
- Apenas creado, el container puede seguir en su primer intento o aún no haber terminado, así que `kubectl logs` sin flags muestra el proceso actual (que puede estar vacío o en curso). El flag `--previous` (`-p`) muestra los logs del container terminado en el intento inmediatamente anterior al actual.
- El campo `Restart Count` dentro de la sección `Containers` del `describe pod`.

**Ejercicio 3**
- `-i` (stdin) combinado con `-t` (tty): `kubectl exec -it <pod> -- <comando>`.
- El flag `-c <nombre-container>` (`--container`).

**Ejercicio 4**
- Permite diagnosticar un Pod en ejecución sin modificar su spec original, sin necesidad de reconstruir la imagen ni causar un restart de los containers existentes, ideal para imágenes `distroless` sin shell.
- `--target` hace que el ephemeral container comparta el namespace de procesos (`PID namespace`) del container indicado, permitiendo ver sus procesos con herramientas como `ps`; sin ese flag, el ephemeral container ve solo sus propios procesos.

**Ejercicio 5**
- Si falla la `readinessProbe`, el container sigue corriendo pero el Pod se retira de los Endpoints del Service (no recibe tráfico); si falla la `livenessProbe`, kubelet reinicia el container.
- En la columna `READY` de `kubectl get pod` (por ejemplo `0/1` en vez de `1/1`), aunque `STATUS` siga mostrando `Running`.

**Ejercicio 6**
- `kubectl get endpoints <service>`: si la lista de `ENDPOINTS` está vacía, no hay Pods backend coincidiendo con el selector.
- Dentro del mismo namespace alcanza con `<service>`; para otro namespace hace falta `<service>.<namespace>` o el FQDN completo `<service>.<namespace>.svc.cluster.local`.

**Ejercicio 7**
- Porque metrics-server necesita tiempo (típicamente 1-2 minutos) para hacer su primer scrape de métricas de los kubelets antes de que la Metrics API tenga datos disponibles.
- `kubectl top` reporta el uso real instantáneo de CPU/memoria medido por metrics-server; `requests`/`limits` son valores declarados en el manifiesto que el scheduler y el kubelet usan para reservar y limitar recursos, no reflejan el consumo real.

</details>