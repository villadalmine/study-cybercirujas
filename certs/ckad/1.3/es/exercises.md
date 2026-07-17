# 1.3 Understand multi-container Pod design patterns (e.g. sidecar, init and others)

> Fuente de referencia: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

Estos ejercicios asumen que tenés un cluster de Kubernetes disponible (`minikube`, `kind` o similar) y `kubectl` configurado contra él. Trabajá en un namespace propio para no interferir con otros recursos:

```bash
kubectl create namespace ckad-1-3
kubectl config set-context --current --namespace=ckad-1-3
```

---

## Ejercicio 1 — Init Containers

Los **init containers** corren secuencialmente, uno por uno, antes de que arranquen los containers principales del Pod. Cada uno debe terminar exitosamente (exit code 0) para que el siguiente inicie. Se usan para tareas de setup: esperar una dependencia, clonar un repo, generar configuración, etc.

1. Creá el archivo `init-demo.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: init-demo
   spec:
     initContainers:
     - name: wait-for-config
       image: busybox:1.36
       command: ['sh', '-c', 'echo "Generando config..."; sleep 5; echo "app.ready=true" > /shared/config.txt']
       volumeMounts:
       - name: shared-data
         mountPath: /shared
     containers:
     - name: main-app
       image: busybox:1.36
       command: ['sh', '-c', 'cat /shared/config.txt; sleep 3600']
       volumeMounts:
       - name: shared-data
         mountPath: /shared
     volumes:
     - name: shared-data
       emptyDir: {}
   ```

2. Aplicá el manifiesto y observá el estado del Pod en tiempo real:

   ```bash
   kubectl apply -f init-demo.yaml
   kubectl get pod init-demo -w
   ```

   Cortá el `watch` con `Ctrl+C` cuando el Pod pase a `Running`.

3. Revisá los logs del init container por separado con `-c`:

   ```bash
   kubectl logs init-demo -c wait-for-config
   ```

4. Confirmá que el container principal pudo leer el archivo que generó el init container:

   ```bash
   kubectl logs init-demo -c main-app
   ```

5. Inspeccioná la sección `status.initContainerStatuses` del Pod:

   ```bash
   kubectl get pod init-demo -o jsonpath='{.status.initContainerStatuses[0].state}'
   ```

**Preguntas de comprensión**

- ¿Qué pasa con el container `main-app` si `wait-for-config` termina con exit code distinto de 0?
- Si definís dos init containers, ¿en qué orden se ejecutan y qué ocurre si el segundo falla luego de que el primero completó exitosamente?
- ¿Por qué `init-demo` pudo compartir el archivo `config.txt` entre el init container y el container principal aunque son imágenes distintas?

---

## Ejercicio 2 — Sidecar nativo (init container con `restartPolicy: Always`)

Desde Kubernetes 1.29 (GA en 1.33) existe el patrón de **native sidecar**: un init container con `restartPolicy: Always` arranca antes que los containers principales, pero **no bloquea** el arranque de estos —queda corriendo en paralelo durante toda la vida del Pod— y se apaga automáticamente después que terminan los containers principales.

1. Creá `sidecar-nativo.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sidecar-nativo
   spec:
     initContainers:
     - name: log-shipper
       image: busybox:1.36
       restartPolicy: Always
       command: ['sh', '-c', 'while true; do echo "shipping logs $(date)"; sleep 5; done']
       volumeMounts:
       - name: logs
         mountPath: /var/log/app
     containers:
     - name: main-app
       image: busybox:1.36
       command: ['sh', '-c', 'while true; do echo "$(date) hola desde main-app" >> /var/log/app/app.log; sleep 2; done']
       volumeMounts:
       - name: logs
         mountPath: /var/log/app
     volumes:
     - name: logs
       emptyDir: {}
   ```

2. Aplicá y verificá cuántos containers quedan `Ready` una vez que el Pod está `Running`:

   ```bash
   kubectl apply -f sidecar-nativo.yaml
   kubectl get pod sidecar-nativo
   ```

3. Confirmá que `log-shipper` sigue corriendo en paralelo a `main-app` (no terminó):

   ```bash
   kubectl logs sidecar-nativo -c log-shipper --tail=5
   kubectl logs sidecar-nativo -c main-app --tail=5
   ```

4. Compará la sección `spec.initContainers[0].restartPolicy` de este Pod contra el `wait-for-config` del Ejercicio 1:

   ```bash
   kubectl get pod sidecar-nativo -o jsonpath='{.spec.initContainers[0].restartPolicy}'
   ```

**Preguntas de comprensión**

- ¿Cuál es la diferencia clave de comportamiento entre un init container "clásico" (sin `restartPolicy`) y un native sidecar (`restartPolicy: Always`)?
- Al hacer `kubectl get pod sidecar-nativo`, la columna `READY` muestra `2/2`. ¿Por qué se cuenta el sidecar como "ready" si nunca termina su ejecución?
- ¿Qué ventaja tiene el native sidecar sobre correr el mismo container de logging como un container normal más en `spec.containers`?

---

## Ejercicio 3 — Sidecar clásico con volumen compartido (logging sidecar)

Antes de que existiera el native sidecar, el patrón se implementaba con dos containers normales que comparten un `emptyDir`. Sigue siendo válido y aparece en el examen.

1. Creá `sidecar-clasico.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sidecar-clasico
   spec:
     containers:
     - name: main-app
       image: busybox:1.36
       command: ['sh', '-c', 'while true; do echo "$(date) request procesado" >> /var/log/app.log; sleep 2; done']
       volumeMounts:
       - name: logs
         mountPath: /var/log
     - name: log-sidecar
       image: busybox:1.36
       command: ['sh', '-c', 'tail -f /var/log/app.log']
       volumeMounts:
       - name: logs
         mountPath: /var/log
     volumes:
     - name: logs
       emptyDir: {}
   ```

2. Aplicá el manifiesto:

   ```bash
   kubectl apply -f sidecar-clasico.yaml
   ```

3. Seguí en vivo los logs que produce el sidecar (que en realidad lee lo que escribe `main-app`):

   ```bash
   kubectl logs sidecar-clasico -c log-sidecar -f
   ```

   Dejalo corriendo unos segundos y cortá con `Ctrl+C`.

4. Eliminá manualmente `main-app` con `kubectl exec` para ver qué pasa con el Pod completo:

   ```bash
   kubectl exec sidecar-clasico -c main-app -- kill 1
   kubectl get pod sidecar-clasico -w
   ```

   Cortá con `Ctrl+C` cuando veas el resultado.

**Preguntas de comprensión**

- En este diseño, ¿ambos containers comparten el mismo filesystem completo o solo el volumen `logs`?
- Si el proceso principal (PID 1) de `main-app` muere, ¿qué le pasa al Pod y por qué afecta también a `log-sidecar`?
- ¿Qué diferencia práctica notás entre este sidecar clásico y el native sidecar del Ejercicio 2 en cuanto al orden de arranque?

---

## Ejercicio 4 — Patrón Adapter (normalización de salida)

El patrón **adapter** transforma la salida de un container legacy a un formato estandarizado que otro sistema (por ejemplo, un colector de métricas) espera consumir.

1. Creá `adapter-demo.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: adapter-demo
   spec:
     containers:
     - name: legacy-app
       image: busybox:1.36
       command: ['sh', '-c', 'while true; do echo "requests=42 errors=1 latency_ms=120" > /metrics/raw.txt; sleep 5; done']
       volumeMounts:
       - name: metrics
         mountPath: /metrics
     - name: metrics-adapter
       image: busybox:1.36
       command: ['sh', '-c', 'while true; do if [ -f /metrics/raw.txt ]; then awk "{for(i=1;i<=NF;i++) print \$i}" /metrics/raw.txt | sed "s/=/ /" > /metrics/prometheus.txt; fi; sleep 5; done']
       volumeMounts:
       - name: metrics
         mountPath: /metrics
     volumes:
     - name: metrics
       emptyDir: {}
   ```

2. Aplicá el manifiesto y esperá a que el Pod esté `Running`:

   ```bash
   kubectl apply -f adapter-demo.yaml
   kubectl wait --for=condition=Ready pod/adapter-demo --timeout=60s
   ```

3. Verificá el formato "legacy" original:

   ```bash
   kubectl exec adapter-demo -c legacy-app -- cat /metrics/raw.txt
   ```

4. Verificá el formato transformado que produjo el adapter:

   ```bash
   kubectl exec adapter-demo -c metrics-adapter -- cat /metrics/prometheus.txt
   ```

**Preguntas de comprensión**

- ¿Por qué conviene resolver la transformación de formato con un container adapter en el mismo Pod en lugar de modificar el código de `legacy-app`?
- ¿Qué es lo que hace que este ejemplo sea un patrón "adapter" y no un patrón "sidecar" genérico? (pensá en el propósito específico del container secundario)
- ¿Qué pasaría si `metrics-adapter` corriera en un Pod separado en vez de compartir Pod con `legacy-app`?

---

## Ejercicio 5 — Patrón Ambassador (proxy de red)

El patrón **ambassador** coloca un proxy en un container separado dentro del mismo Pod, para que el container principal hable siempre con `localhost` y el ambassador se encargue de la complejidad de conectividad hacia el exterior (descubrimiento, TLS, retries, etc.).

1. Creá `ambassador-demo.yaml`. Usamos `socat` para simular un proxy simple que redirige tráfico local hacia un servicio externo:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: ambassador-demo
   spec:
     containers:
     - name: main-app
       image: busybox:1.36
       command: ['sh', '-c', 'sleep 3600']
     - name: ambassador
       image: alpine/socat
       args: ["tcp-listen:9000,fork,reuseaddr", "tcp:kubernetes.default.svc:443"]
   ```

2. Aplicá y esperá que esté listo:

   ```bash
   kubectl apply -f ambassador-demo.yaml
   kubectl wait --for=condition=Ready pod/ambassador-demo --timeout=60s
   ```

3. Desde `main-app`, conectate a `localhost:9000` en lugar de resolver directamente el servicio externo:

   ```bash
   kubectl exec ambassador-demo -c main-app -- wget -qO- --no-check-certificate https://localhost:9000/version
   ```

4. Compará qué IP ve `main-app` al conectarse a `localhost` versus la IP real del `ambassador`:

   ```bash
   kubectl exec ambassador-demo -c main-app -- hostname -i
   kubectl exec ambassador-demo -c ambassador -- hostname -i
   ```

**Preguntas de comprensión**

- ¿Por qué ambos containers ven la misma IP de Pod al ejecutar `hostname -i`?
- Si mañana el destino real cambia (otro cluster, otro namespace), ¿qué archivo tenés que modificar y qué container hay que reiniciar? ¿Necesitás tocar `main-app`?
- ¿En qué se diferencia conceptualmente el patrón ambassador del patrón adapter, si ambos son "un container secundario que le facilita la vida al principal"?

---

## Ejercicio 6 — `shareProcessNamespace`: visibilidad de procesos entre containers

Por defecto cada container de un Pod tiene su propio namespace de procesos (PID namespace). `shareProcessNamespace: true` permite que todos los containers del Pod vean los procesos de los demás, útil para debugging o para que un sidecar pueda enviar señales a procesos del container principal.

1. Creá `shared-pid.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: shared-pid
   spec:
     shareProcessNamespace: true
     containers:
     - name: main-app
       image: busybox:1.36
       command: ['sh', '-c', 'sleep 3600']
     - name: debug-sidecar
       image: busybox:1.36
       command: ['sh', '-c', 'sleep 3600']
   ```

2. Aplicá el manifiesto:

   ```bash
   kubectl apply -f shared-pid.yaml
   ```

3. Desde `debug-sidecar`, listá los procesos del Pod completo:

   ```bash
   kubectl exec shared-pid -c debug-sidecar -- ps aux
   ```

4. Identificá el proceso `sleep` que corre dentro de `main-app` y confirmá que es visible desde `debug-sidecar` (en un Pod sin `shareProcessNamespace` no lo verías).

5. Como comparación, repetí el ejercicio quitando la línea `shareProcessNamespace: true` (o creando un segundo Pod `shared-pid-off` sin esa línea) y volvé a correr `ps aux` desde el sidecar.

**Preguntas de comprensión**

- ¿Qué proceso aparece con PID 1 quando `shareProcessNamespace: true` está activo, y qué container lo originó?
- ¿Qué implicancia de seguridad tiene habilitar `shareProcessNamespace` entre containers que antes estaban aislados entre sí?
- Nombrá un caso de uso legítimo del examen CKAD donde convendría usar `shareProcessNamespace` en vez de (o junto con) el patrón sidecar clásico.

---

## Limpieza

```bash
kubectl delete pod init-demo sidecar-nativo sidecar-clasico adapter-demo ambassador-demo shared-pid
kubectl delete namespace ckad-1-3
```

---

<details>
<summary><strong>Ver respuestas</strong></summary>

### Ejercicio 1 — Init Containers

- Si `wait-for-config` termina con exit code distinto de 0, Kubernetes lo reintenta según la `restartPolicy` del Pod (por defecto `Always`), y **`main-app` nunca arranca** hasta que el init container complete exitosamente. El Pod queda en fase `Pending` con status `Init:Error` o `Init:CrashLoopBackOff`.
- Los init containers se ejecutan **secuencialmente en el orden declarado** en la lista `initContainers`. Si el segundo falla después de que el primero completó, el primero no se vuelve a ejecutar: Kubernetes reintenta solo el que falló, y los containers principales del Pod siguen sin arrancar hasta que todos los init containers completen en orden.
- Porque ambos containers montan el mismo volumen `emptyDir` llamado `shared-data` en la ruta `/shared`. El volumen vive a nivel Pod, no a nivel container, así que sobrevive al init container y está disponible para el container principal cuando este arranca (aunque las imágenes de cada container sean completamente independientes).

### Ejercicio 2 — Sidecar nativo

- El init container clásico **bloquea** el arranque de los containers principales hasta que termina (exit 0) y luego **deja de existir**. El native sidecar (`restartPolicy: Always`) también arranca antes que los containers principales, pero **no bloquea**: Kubernetes lo considera "started" (tras pasar su `startupProbe` si tiene una, o inmediatamente) y continúa con los containers principales mientras el sidecar sigue corriendo en paralelo durante toda la vida del Pod.
- Porque Kubernetes trata a los init containers con `restartPolicy: Always` como parte del conteo de "containers que deben estar corriendo" del Pod, igual que los containers de `spec.containers`. Al estar corriendo (no haber terminado) y pasar sus probes, cuenta como `Ready`, sumando al total mostrado en `READY` (2/2 = `main-app` + `log-shipper`).
- El native sidecar arranca **antes** que los containers principales y se apaga **después** de que estos terminan (orden de shutdown inverso), lo cual es crítico para casos como un proxy de red o un log shipper: garantiza que el sidecar esté disponible desde el primer instante que el container principal corre, y siga disponible hasta el último instante antes de que el Pod termine — algo que un container normal en `spec.containers` no garantiza (todos arrancan en paralelo, sin orden garantizado).

### Ejercicio 3 — Sidecar clásico

- Comparten **únicamente el volumen `logs`** montado en `/var/log`. El resto del filesystem de cada container es independiente (cada uno con su propia imagen y capas). Sí comparten la red del Pod (misma IP) y, si se habilitara, el PID namespace.
- Si el PID 1 de `main-app` muere, ese container termina y Kubernetes lo reinicia según la `restartPolicy` del Pod — pero **no afecta directamente** a `log-sidecar`, que es un container independiente y sigue corriendo. Lo que sí se ve afectado es que `main-app` deja de escribir en `app.log` momentáneamente mientras se reinicia, y el Pod puede mostrar `READY 1/2` transitoriamente.
- En el sidecar clásico, ambos containers arrancan **al mismo tiempo** (en paralelo, sin orden garantizado) al ser ambos parte de `spec.containers`; no hay garantía de que `log-sidecar` esté listo antes que `main-app` empiece a escribir logs. En el native sidecar, el sidecar arranca **antes** que el container principal, eliminando esa condición de carrera.

### Ejercicio 4 — Adapter

- Porque `legacy-app` puede ser una aplicación de terceros o legacy que no se puede modificar (sin código fuente disponible, o cuyo cambio implica riesgo/costo alto). El adapter resuelve la incompatibilidad de formato sin tocar el binario/imagen original, manteniendo el principio de responsabilidad única.
- Es un patrón **adapter** porque el propósito específico del container secundario es **transformar/normalizar un formato de salida** a otro formato estándar (aquí, de `clave=valor` a formato tipo Prometheus). Un sidecar es el término genérico para "container auxiliar en el mismo Pod"; adapter, ambassador y logging-sidecar son *especializaciones* de ese patrón general según su propósito.
- Se perdería la ventaja de compartir ciclo de vida y red/volumen local: tendrías que exponer `raw.txt` vía red (no `emptyDir` local), coordinar el despliegue y escalado de ambos Pods por separado, y perderías la garantía de que el adapter está siempre co-ubicado con la instancia específica de `legacy-app` que está transformando.

### Ejercicio 5 — Ambassador

- Porque ambos containers pertenecen al **mismo Pod**, y en Kubernetes todos los containers de un Pod comparten el mismo **network namespace**: misma IP de Pod, mismo `localhost`, y se comunican entre sí por puertos en `127.0.0.1` en vez de por IP de Pod a Pod.
- Solo hay que modificar la configuración/args del container `ambassador` (por ejemplo el destino del `socat`, o la config de un proxy real como Envoy) y reiniciar/actualizar únicamente ese container (o el Pod completo si el proxy no soporta reload en caliente). **No hace falta tocar `main-app`**, que sigue apuntando siempre a `localhost:9000` — esa es la esencia del patrón: aislar la complejidad de conectividad del container principal.
- El **ambassador** resuelve conectividad de red hacia el exterior (proxy, descubrimiento de servicios, TLS, retries) para que el container principal siempre hable con `localhost`. El **adapter** resuelve normalización de formato de datos/salida (logs, métricas) para que un sistema externo consuma un formato esperado. Ambos son sidecars, pero el ambassador opera en la capa de red/transporte y el adapter en la capa de formato/datos.

### Ejercicio 6 — shareProcessNamespace

- El PID 1 corresponde al **container de infraestructura `pause`** (o, según la versión/runtime, al primer proceso lanzado del primer container definido en el Pod). En la práctica, dentro del Pod vas a ver que el proceso `pause` ocupa el PID 1 y los procesos de `main-app` y `debug-sidecar` aparecen con PIDs subsiguientes, visibles ambos desde cualquier container.
- Habilitar `shareProcessNamespace` **rompe el aislamiento de procesos** entre containers: cualquier container puede ver (y, si tiene privilegios/capabilities suficientes, enviar señales a, o acceder vía `/proc/<pid>` a) los procesos de los demás containers del Pod, incluyendo posibles variables de entorno o file descriptors sensibles expuestos vía `/proc`. Es un trade-off de seguridad que solo se justifica para debugging o necesidades operativas específicas.
- Un caso de uso típico de examen: un container de **debugging/diagnóstico** (por ejemplo basado en `busybox` o una imagen con herramientas como `strace`/`lsof`) que necesita inspeccionar o enviar señales (`kill -HUP`) a un proceso que corre en el container principal para forzar un reload de configuración, sin necesidad de que el container principal incluya esas herramientas de diagnóstico en su propia imagen.

</details>