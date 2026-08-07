# Ejercicios Guiados — Tema 4.1: Kubernetes Reconciliation Loop and Control Plane Architecture

> **Requisitos previos.** Un cluster donde tengas acceso al control plane (kubeadm sobre un nodo, o `kind`/`minikube`). Varios pasos leen `/etc/kubernetes/manifests/` y ejecutan `etcdctl`, así que necesitás `sudo` en el control-plane node o `kubectl exec` contra el pod estático de etcd. Verificá tu contexto antes de empezar:
>
> ```console
> $ kubectl config current-context
> kubernetes-admin@kubernetes
> $ kubectl version -o yaml | grep -A2 serverVersion
> serverVersion:
>   major: "1"
>   minor: "31"
> ```
>
> Trabajá siempre en un namespace descartable para no ensuciar el cluster:
>
> ```console
> $ kubectl create namespace lab-4-1
> namespace/lab-4-1 created
> $ kubectl config set-context --current --namespace=lab-4-1
> Context "kubernetes-admin@kubernetes" modified.
> ```

---

## Ejercicio 1 — Anatomía del control plane

El control plane es un conjunto de procesos, no un binario monolítico. En un cluster kubeadm corren como **static pods**: el kubelet los arranca directamente desde manifiestos en disco, sin pasar por el API server.

1. Listá los componentes del plano de control que corren como pods:

   ```console
   $ kubectl get pods -n kube-system -o wide \
       -l 'tier=control-plane'
   NAME                              READY   STATUS    RESTARTS   AGE   NODE
   etcd-cp1                          1/1     Running   0          9d    cp1
   kube-apiserver-cp1                1/1     Running   0          9d    cp1
   kube-controller-manager-cp1       1/1     Running   2          9d    cp1
   kube-scheduler-cp1                1/1     Running   2          9d    cp1
   ```

2. Confirmá que son **static pods** mirando el manifiesto en disco (en el control-plane node):

   ```console
   $ sudo ls -1 /etc/kubernetes/manifests/
   etcd.yaml
   kube-apiserver.yaml
   kube-controller-manager.yaml
   kube-scheduler.yaml
   ```

3. Observá el sufijo `-cp1` del nombre de cada pod y compará con el `ownerReferences`:

   ```console
   $ kubectl get pod kube-apiserver-cp1 -n kube-system \
       -o jsonpath='{.metadata.ownerReferences}{"\n"}'
   [{"apiVersion":"v1","controller":true,"kind":"Node","name":"cp1","uid":"..."}]
   ```

4. Inspeccioná los flags con los que arrancó el scheduler y el controller-manager, porque ahí viven muchas decisiones de reconciliación:

   ```console
   $ kubectl get pod kube-controller-manager-cp1 -n kube-system \
       -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep -E 'concurrent|resync|node-monitor'
   "--concurrent-deployment-syncs=5"
   "--node-monitor-period=5s"
   "--node-monitor-grace-period=40s"
   ```

**Preguntas de comprensión**

- 1a. ¿Por qué el pod `kube-apiserver-cp1` tiene como `ownerReference` un objeto `Node` y no un `ReplicaSet` o `Deployment`? ¿Qué implica eso para su ciclo de vida?
- 1b. Si el API server está caído, ¿cómo consigue el kubelet reiniciar el static pod `kube-apiserver`? ¿Qué "gallina y huevo" resuelve este diseño?
- 1c. El flag `--node-monitor-grace-period=40s` pertenece al `node-lifecycle-controller`. ¿Qué acción dispara el controller cuando ese período expira sin señales de un nodo?

---

## Ejercicio 2 — El reconciliation loop en acción

Un controller es un bucle que compara **desired state** (lo que pediste, guardado en etcd vía el API server) contra **actual state** (lo que existe) y actúa para cerrar la brecha. Vamos a provocar drift y observar cómo se cierra.

1. Creá un Deployment y esperá a que converja:

   ```console
   $ kubectl create deployment web --image=nginx:1.27 --replicas=3
   deployment.apps/web created
   $ kubectl rollout status deployment/web
   deployment "web" successfully rolled out
   ```

2. En una terminal, dejá un watch abierto sobre los pods:

   ```console
   $ kubectl get pods -l app=web --watch
   NAME                   READY   STATUS    RESTARTS   AGE
   web-6f9c8b7d5c-2xk4p   1/1     Running   0          30s
   web-6f9c8b7d5c-8ndqz   1/1     Running   0          30s
   web-6f9c8b7d5c-lm7ws   1/1     Running   0          30s
   ```

3. En otra terminal, introducí drift borrando un pod y volvé a mirar el watch:

   ```console
   $ kubectl delete pod web-6f9c8b7d5c-2xk4p
   pod "web-6f9c8b7d5c-2xk4p" deleted
   ```

   En el watch aparece casi inmediatamente:

   ```console
   web-6f9c8b7d5c-2xk4p   1/1     Terminating   0     58s
   web-6f9c8b7d5c-q4rt9   0/1     Pending       0     0s
   web-6f9c8b7d5c-q4rt9   0/1     ContainerCreating   0     0s
   web-6f9c8b7d5c-q4rt9   1/1     Running       0     2s
   ```

4. Mirá el hilo causal en los eventos del ReplicaSet:

   ```console
   $ kubectl describe replicaset -l app=web | grep -A6 Events:
   Events:
     Type    Reason            Age   From                   Message
     ----    ------            ----  ----                   -------
     Normal  SuccessfulCreate  70s   replicaset-controller  Created pod: web-6f9c8b7d5c-2xk4p
     Normal  SuccessfulCreate  12s   replicaset-controller  Created pod: web-6f9c8b7d5c-q4rt9
   ```

5. Ahora probá el otro sentido del drift: agregá un pod "de más" que _matchee_ el selector del ReplicaSet, y observá qué hace el controller.

   ```console
   $ RS=$(kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.name}')
   $ kubectl run intruso --image=nginx:1.27 --labels="app=web,pod-template-hash=6f9c8b7d5c" \
       --overrides="{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"apps/v1\",\"kind\":\"ReplicaSet\",\"name\":\"$RS\",\"uid\":\"$(kubectl get rs $RS -o jsonpath='{.metadata.uid}')\",\"controller\":true}]}}"
   pod/intruso created
   ```

   Segundos después:

   ```console
   $ kubectl get pods -l app=web
   NAME                   READY   STATUS        RESTARTS   AGE
   intruso                1/1     Terminating   0          3s
   web-6f9c8b7d5c-8ndqz   1/1     Running       0          2m
   web-6f9c8b7d5c-lm7ws   1/1     Running       0          2m
   web-6f9c8b7d5c-q4rt9   1/1     Running       0          70s
   ```

**Preguntas de comprensión**

- 2a. En el paso 3 no ejecutaste ningún comando de "recrear". ¿Qué componente decidió crear `web-6f9c8b7d5c-q4rt9`, y sobre qué comparación tomó la decisión?
- 2b. En el paso 5 el ReplicaSet tenía 3 réplicas y le "sobró" un pod. Describí cómo el controller elige **cuál** pod borrar (pista: cost/deletion ordering) y por qué no borró uno de los `Running` sanos originales.
- 2c. Este comportamiento se describe como **level-triggered** y no **edge-triggered**. Definí ambos y explicá por qué el modelo level-triggered hace que un controller sea robusto ante eventos perdidos.

---

## Ejercicio 3 — etcd como source of truth y el mecanismo list-watch

El desired state no vive en el controller ni en el kubelet: vive en **etcd**, y el API server es la única puerta de entrada. Los controllers no _pollean_ el API server en un `for` infinito; usan **list-watch** sobre un stream incremental indexado por `resourceVersion`.

1. Mirá la clave real que representa tu Deployment dentro de etcd (desde el control-plane node):

   ```console
   $ sudo ETCDCTL_API=3 etcdctl \
       --endpoints=https://127.0.0.1:2379 \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/deployments/lab-4-1/web --keys-only
   /registry/deployments/lab-4-1/web
   ```

2. Confirmá que el prefijo `/registry` es el árbol completo del cluster:

   ```console
   $ sudo ETCDCTL_API=3 etcdctl ... get /registry/ --prefix --keys-only | \
       sed 's|/registry/\([^/]*\)/.*|\1|' | sort | uniq -c | sort -rn | head
       412 pods
       118 events
        96 endpointslices
        73 leases
        ...
   ```

3. Observá el `resourceVersion` como reloj lógico monótono del cluster. Abrí un watch **verboso** que imprime la versión de cada evento:

   ```console
   $ kubectl get pods -l app=web -w -o custom-columns=\
   'NAME:.metadata.name,RV:.metadata.resourceVersion,PHASE:.status.phase'
   NAME                   RV        PHASE
   web-6f9c8b7d5c-8ndqz   184213    Running
   web-6f9c8b7d5c-lm7ws   184219    Running
   web-6f9c8b7d5c-q4rt9   184240    Running
   ```

4. En otra terminal, tocá un pod y mirá cómo salta el `resourceVersion` en el watch:

   ```console
   $ kubectl annotate pod web-6f9c8b7d5c-8ndqz demo=1 --overwrite
   pod/web-6f9c8b7d5c-8ndqz annotated
   ```

   En el watch aparece una nueva línea del mismo pod con `RV` mayor:

   ```console
   web-6f9c8b7d5c-8ndqz   184305    Running
   ```

5. Verificá que el watch es **incremental** y no un re-listado completo. Pedí un watch a partir de una versión concreta:

   ```console
   $ kubectl get --raw \
     "/api/v1/namespaces/lab-4-1/pods?watch=1&resourceVersion=184240" | head -1
   {"type":"MODIFIED","object":{"kind":"Pod","apiVersion":"v1","metadata":{"name":"web-6f9c8b7d5c-8ndqz","resourceVersion":"184305",...
   ```

**Preguntas de comprensión**

- 3a. ¿Por qué los controllers usan **list-watch** en lugar de un `GET` periódico de todos los objetos? Nombrá al menos dos consecuencias sobre etcd y sobre latencia de reacción.
- 3b. El `resourceVersion` que ves es un valor de etcd (`revision`). ¿Es comparable entre recursos de tipos distintos (p.ej. un Pod y un Secret)? ¿Y cómo lo usa un informer para reanudar un watch tras una desconexión?
- 3c. Si un watch está desconectado el tiempo suficiente como para que etcd ya haya compactado el `resourceVersion` desde el que quiere reanudar, ¿qué error devuelve el API server y cómo se recupera el informer? (pista: `410 Gone`).

---

## Ejercicio 4 — Optimistic concurrency y robustez del bucle

El API server no usa locks; usa **optimistic concurrency control** basado en `resourceVersion`. Cada escritura declara sobre qué versión se hizo, y si otra escritura ganó la carrera, la tuya se rechaza. Esto es lo que hace seguro que N réplicas de un controller (o vos y un controller) escriban en paralelo.

1. Capturá el `resourceVersion` actual del Deployment:

   ```console
   $ kubectl get deployment web -o jsonpath='{.metadata.resourceVersion}{"\n"}'
   184450
   ```

2. Simulá un update con una versión **vieja** (una conflict-detection artificial) usando `--server-side` no; usá un replace con RV fijo:

   ```console
   $ kubectl get deployment web -o yaml > /tmp/web.yaml
   # editá /tmp/web.yaml: cambiá replicas a 4, dejá el resourceVersion viejo
   $ kubectl replace -f /tmp/web.yaml   # tras haber tocado el deployment desde otra terminal
   Error from server (Conflict): error when replacing "web.yaml": Operation cannot be
   fulfilled on deployments.apps "web": the object has been modified; please apply your
   changes to the latest version and try again
   ```

3. Ahora demostrá la robustez **level-triggered** apagando temporalmente el controller-manager y provocando drift mientras está caído. Mové su manifiesto fuera del directorio de static pods:

   ```console
   $ sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
   $ sleep 20 && kubectl get pods -n kube-system -l component=kube-controller-manager
   No resources found in kube-system namespace.
   ```

4. Con el controller-manager caído, introducí drift borrando un pod:

   ```console
   $ kubectl delete pod -l app=web --field-selector status.phase=Running \
       -o name | head -1 | xargs kubectl delete
   pod "web-6f9c8b7d5c-lm7ws" deleted
   $ sleep 15 && kubectl get pods -l app=web
   NAME                   READY   STATUS    RESTARTS   AGE
   web-6f9c8b7d5c-8ndqz   1/1     Running   0          9m
   web-6f9c8b7d5c-q4rt9   1/1     Running   0          8m
   ```

   Solo 2 pods: **nadie reconcilió** porque el controller no existe.

5. Restaurá el controller-manager y observá que reconcilia sin necesidad de "reproducir" el evento de borrado que se perdió:

   ```console
   $ sudo mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
   $ sleep 20 && kubectl get pods -l app=web
   NAME                   READY   STATUS    RESTARTS   AGE
   web-6f9c8b7d5c-8ndqz   1/1     Running   0          10m
   web-6f9c8b7d5c-q4rt9   1/1     Running   0          9m
   web-6f9c8b7d5c-vv2mn   1/1     Running   0          8s
   ```

**Preguntas de comprensión**

- 4a. En el paso 2 el `replace` falló con `409 Conflict`. Explicá cómo el `resourceVersion` incluido en el objeto actúa como token de optimistic concurrency, y qué debe hacer un cliente bien escrito ante ese conflicto.
- 4b. En el paso 5 el controller-manager arrancó "desde cero", sin haber visto el evento `DELETED` del pod. ¿Cómo supo entonces que faltaba una réplica? Conectá tu respuesta con lo que un informer hace en su **initial LIST** al arrancar.
- 4c. Este experimento ilustra por qué se dice que Kubernetes converge a **eventual consistency** en vez de garantizar transacciones inmediatas. Da un ejemplo de producción donde este comportamiento es una ventaja y otro donde te puede morder.

---

## Ejercicio 5 — Leader election: por qué solo una réplica actúa

`kube-controller-manager` y `kube-scheduler` pueden correr en HA (varias réplicas), pero **solo una actúa a la vez**. Coordinan con un objeto `Lease` en `kube-system` usando leader election. Si dos escribieran a la vez, tendrías doble reconciliación y carreras.

1. Listá los Leases del control plane:

   ```console
   $ kubectl get leases -n kube-system
   NAME                                   HOLDER                          AGE
   kube-controller-manager                cp1_1a2b3c4d-...                9d
   kube-scheduler                         cp1_9f8e7d6c-...                9d
   ...
   ```

2. Mirá el detalle del Lease del scheduler; fijate en el `renewTime` que va cambiando:

   ```console
   $ kubectl get lease kube-scheduler -n kube-system -o yaml | \
       grep -E 'holderIdentity|leaseDuration|renewTime|acquireTime'
     holderIdentity: cp1_9f8e7d6c-...
     leaseDurationSeconds: 15
     renewTime: "2026-08-07T14:22:31.004512Z"
     acquireTime: "2026-07-29T09:10:02.771190Z"
   ```

3. Confirmá que el `renewTime` avanza (el líder renueva su lease periódicamente):

   ```console
   $ for i in 1 2 3; do
       kubectl get lease kube-scheduler -n kube-system \
         -o jsonpath='{.spec.renewTime}{"\n"}'; sleep 3
     done
   2026-08-07T14:22:31.004512Z
   2026-08-07T14:22:33.318844Z
   2026-08-07T14:22:35.622197Z
   ```

4. (Opcional, solo si tenés HA real) Forzá un failover apagando el líder actual y cronometrá cuánto tarda otro en tomar el lease. En single-node podés simularlo mirando la reelección tras reiniciar el pod:

   ```console
   $ kubectl delete pod -n kube-system kube-scheduler-cp1
   pod "kube-scheduler-cp1" deleted
   $ kubectl get lease kube-scheduler -n kube-system \
       -o jsonpath='{.spec.acquireTime}{"\n"}'   # antes vs después del reinicio
   2026-08-07T14:24:10.889012Z   # nuevo acquireTime -> se readquirió el liderazgo
   ```

**Preguntas de comprensión**

- 5a. ¿Qué campos del `Lease` implementan el algoritmo? Explicá el rol de `leaseDurationSeconds` y `renewTime`, y cómo un candidato decide que el líder murió.
- 5b. Si `leaseDurationSeconds=15`, ¿cuál es aproximadamente la ventana máxima de "no hay reconciliación" durante un failover, y qué trade-off tenés si lo bajás mucho?
- 5c. El scheduler es el único que asigna pods a nodos. ¿Qué problema concreto de producción evita la leader election acá que **no** evitaría en un controller idempotente cualquiera?

---

## Ejercicio 6 — Diagnóstico del control plane bajo carga

Cuando la reconciliación se atrasa, el síntoma es "los pods tardan en aparecer" o "los cambios no se aplican". Las causas casi siempre están en el eje **etcd → apiserver → controller work queue**. Estos son los primeros lugares donde mirar.

1. Chequeá la salud de etcd (latencia de disco de etcd es la causa #1 de un control plane lento):

   ```console
   $ sudo ETCDCTL_API=3 etcdctl ... endpoint status --write-out=table
   +----------------+------------------+---------+---------+-----------+------------+
   |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  |
   +----------------+------------------+---------+---------+-----------+------------+
   | 127.0.0.1:2379 | 8e9a...          | 3.5.15  |  38 MB  |   true    |     12     |
   +----------------+------------------+---------+---------+-----------+------------+
   ```

2. Medí la latencia de las escrituras a etcd desde las métricas del API server (percentil que importa: p99):

   ```console
   $ kubectl get --raw /metrics | \
       grep 'etcd_request_duration_seconds_bucket{.*operation="update".*le="0.1"'
   etcd_request_duration_seconds_bucket{operation="update",type="pods",le="0.1"} 20431
   ```

3. Observá la profundidad de la work queue de un controller: si crece y no baja, el controller no da abasto.

   ```console
   $ kubectl get --raw /metrics | grep 'workqueue_depth' | grep -i deployment
   workqueue_depth{name="deployment"} 0
   ```

4. Medí cuántos requests está rechazando/encolando el API server por priority & fairness:

   ```console
   $ kubectl get --raw /metrics | \
       grep 'apiserver_flowcontrol_rejected_requests_total' | head
   apiserver_flowcontrol_rejected_requests_total{...,reason="queue-full"} 0
   ```

5. Correlacioná: mirá la latencia end-to-end de la reconciliación disparando un cambio y midiendo tiempo real de convergencia:

   ```console
   $ time (kubectl scale deployment/web --replicas=10 && kubectl rollout status deployment/web)
   deployment.apps/web scaled
   deployment "web" successfully rolled out

   real    0m6.842s
   ```

**Preguntas de comprensión**

- 6a. `etcd_request_duration_seconds` está alto en el percentil p99 pero la CPU del API server está baja. ¿Cuál es el sospechoso número uno y por qué el disco de etcd es tan crítico? (pista: fsync, WAL, Raft).
- 6b. `workqueue_depth{name="deployment"}` crece de forma monótona durante una tormenta de deploys. ¿Qué dos flags del controller-manager modificarías, y cuál es el riesgo de subirlos sin límite?
- 6c. Un usuario reporta "kubectl responde lento y algunos comandos dan `Too Many Requests` (429)". ¿Qué subsistema del API server está actuando, y por qué ese 429 es en realidad una **protección** del control plane y no una falla?

---

## Limpieza

```console
$ kubectl delete namespace lab-4-1
namespace "lab-4-1" deleted
$ kubectl config set-context --current --namespace=default
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1a.** El API server, etcd, scheduler y controller-manager son **static pods**: los gestiona directamente el kubelet del nodo a partir de los archivos en `/etc/kubernetes/manifests/`, no a través del API server. Por eso su `ownerReference` es el **Node** (el kubelet crea un "mirror pod" en el API server solo para que sea visible, y lo atribuye al nodo). Implica que su ciclo de vida no depende de ningún controller ni del propio API server: si borrás el mirror pod con `kubectl delete`, el kubelet lo vuelve a crear porque el archivo sigue en disco. No podés escalarlos ni actualizarlos con `kubectl edit`; se cambian editando el manifiesto en el nodo.

**1b.** El kubelet no necesita al API server para arrancar un static pod: lee el manifiesto de disco y le pide directamente al container runtime (vía CRI) que corra el contenedor. Esto resuelve el **bootstrap "gallina y huevo"**: el API server no puede arrancarse a sí mismo mediante un Deployment (que requeriría un API server funcionando y un scheduler que asigne el pod). El static pod rompe esa dependencia circular. Es también la razón por la que un API server caído se auto-recupera aunque nada más funcione.

**1c.** Cuando expira el `node-monitor-grace-period` sin que el nodo actualice su estado (su Lease en `kube-node-lease`), el **node-lifecycle-controller** marca el Node como `NotReady`, le pone taints `node.kubernetes.io/not-ready` y `unreachable`, y —tras el `pod-eviction-timeout` / según las taint-based evictions— desaloja (evicta) los pods de ese nodo para que sus controllers los recreen en nodos sanos.

### Ejercicio 2

**2a.** Lo decidió el **replicaset-controller** (dentro de kube-controller-manager). Su bucle compara `spec.replicas` (desired = 3) contra la cantidad de pods vivos que _matchean_ su selector y son de su propiedad (actual = 2 tras el borrado). Al detectar `actual < desired`, crea un pod nuevo. No hubo ningún comando de "recrear": la creación es la acción de reconciliación que cierra la brecha.

**2b.** Cuando sobran réplicas, el controller ordena los candidatos a borrar con una heurística de **deletion cost / ordering**, priorizando eliminar (en este orden aproximado) los pods `Unscheduled`/`Pending` antes que los `Running`, los no-`Ready` antes que los `Ready`, los `Ready` hace menos tiempo antes que los estables, y a igualdad usa la anotación `controller.kubernetes.io/pod-deletion-cost`. El "intruso" era el más nuevo y menos estable, por eso lo eligió a él y preservó los pods sanos originales.

**2c.** **Edge-triggered** = reaccionar a la _transición_ (el evento "se borró un pod"); si perdés el evento, perdés la acción. **Level-triggered** = reaccionar al _estado actual_ ("hay 2, deberían ser 3") sin importar cómo se llegó ahí. Kubernetes es level-triggered: cada reconciliación reevalúa el estado completo, así que un evento perdido, un controller reiniciado o un watch caído no rompen la convergencia — en la próxima pasada vuelve a comparar desired vs actual y actúa igual.

### Ejercicio 3

**3a.** Con **list-watch**, el controller hace **un** LIST inicial y luego recibe solo los cambios incrementales por un stream de watch, cacheándolos localmente en un informer. Consecuencias: (1) etcd/apiserver no soportan la carga de un `GET`-de-todo repetido por cada controller cada pocos segundos (que escalaría pésimo con miles de objetos), y (2) la latencia de reacción baja a milisegundos porque el cambio se _empuja_ apenas ocurre, en vez de esperar al próximo tick de polling.

**3b.** El `resourceVersion` es opaco y proviene del **revision global de etcd**, así que sus valores **sí crecen de forma monótona a nivel cluster**, pero no debés interpretarlos ni compararlos aritméticamente entre tipos de recursos como si fueran contadores por-recurso: tratalos como tokens opacos. Un informer lo usa para **reanudar**: guarda el `resourceVersion` del último evento procesado y, si el watch se corta, reabre el watch con `resourceVersion=<último>` para recibir solo lo que se perdió, sin re-listar todo.

**3c.** Devuelve **`410 Gone`** (`Expired: too old resource version`), porque etcd ya compactó esa revisión y el API server no puede reconstruir la historia desde ahí. El informer se recupera haciendo un **re-LIST completo** (un "relist"), sincronizando su caché con el estado actual y adoptando el nuevo `resourceVersion` como punto de reanudación. Esto es, de nuevo, el modelo level-triggered salvándote: perder la secuencia exacta de eventos no importa mientras puedas re-observar el estado.

### Ejercicio 4

**4a.** El `resourceVersion` embebido en el objeto es un token de **optimistic concurrency**: la escritura le dice al API server "apliqué esto asumiendo la versión X". El API server acepta solo si la versión almacenada sigue siendo X; si alguien más escribió en el medio (versión → Y), rechaza con `409 Conflict`. Un cliente correcto **no reintenta a ciegas**: hace un GET fresco, re-aplica su cambio sobre la última versión (read-modify-write con backoff) y reintenta. Así N escritores concurrentes convergen sin locks.

**4b.** Al arrancar, el informer del replicaset-controller hace su **initial LIST**: le pide al API server el estado actual de todos los ReplicaSets y Pods. Ve que el ReplicaSet `web` declara `replicas=3` pero solo existen 2 pods vivos suyos. No necesitó jamás el evento `DELETED` perdido: reconstruyó la brecha directamente del estado presente y creó el pod faltante. Level-triggered otra vez.

**4c.** Es **eventual consistency**: tras un cambio o una falla, el sistema converge al desired state, pero no instantáneamente ni de forma transaccional. **Ventaja de producción:** sobrevive a fallas parciales — podés reiniciar el control plane, perder un watch o hacer rolling upgrade del controller-manager y el cluster se auto-repara sin intervención. **Te muerde cuando:** dependés de aplicación inmediata — p.ej. un pipeline que asume que apenas hizo `kubectl apply` el estado ya está efectivo, o cuando dos actores hacen read-modify-write sobre el mismo objeto y uno pisa la intención del otro sin manejar el conflicto (típico en operators mal escritos).

### Ejercicio 5

**5a.** El algoritmo se implementa con: `holderIdentity` (quién es el líder), `leaseDurationSeconds` (cuánto vale el liderazgo sin renovar), `renewTime` (última renovación), y `acquireTime`. El líder actualiza `renewTime` periódicamente (cada ~`leaseDuration/3`). Un candidato considera que el líder murió si `now - renewTime > leaseDurationSeconds`; entonces intenta hacer un update del Lease poniéndose como `holderIdentity` — con optimistic concurrency, solo uno gana la carrera y se convierte en líder.

**5b.** Con `leaseDurationSeconds=15`, la ventana de "sin reconciliación" durante un failover es de hasta ~15 s (más el tiempo de adquisición). Bajarlo acelera el failover, pero **aumenta el riesgo de flapping**: un pico de latencia hacia el API server (o un GC pause) puede impedir que el líder sano renueve a tiempo, provocando reelecciones innecesarias y perdiendo/ganando liderazgo en loop. Es un trade-off entre velocidad de failover y estabilidad ante jitter.

**5c.** El scheduler **asigna pods a nodos** (setea `spec.nodeName`), una operación que no es naturalmente idempotente entre réplicas: si dos schedulers activos evalúan el mismo pod `Pending` en paralelo, pueden bindear a nodos distintos, tomar decisiones de bin-packing contradictorias o doblar la carga contable de recursos, dando origen a carreras y sobre-suscripción. La leader election garantiza un único decisor. Un controller idempotente (crear un pod que "ya existe" es no-op) tolera duplicados; el binding del scheduler no.

### Ejercicio 6

**6a.** El sospechoso #1 es la **latencia de disco de etcd (fsync)**. Cada escritura en etcd debe persistirse en el **WAL** (write-ahead log) con `fsync` y ser confirmada por el quórum de Raft **antes** de responder OK. Si el disco es lento (HDD, un volumen de red congestionado, IOPS agotadas), cada write se bloquea en el fsync aunque la CPU esté ociosa — por eso etcd exige almacenamiento de baja latencia (SSD/NVMe local dedicado). Un API server con CPU baja pero `etcd_request_duration` alto apunta casi siempre al disco de etcd o a contención de I/O.

**6b.** Subirías `--concurrent-deployment-syncs` (y los `--concurrent-*-syncs` del controller relevante, p.ej. `--concurrent-replicaset-syncs`) para procesar más items de la work queue en paralelo, y podrías ajustar `--kube-api-qps` / `--kube-api-burst` del controller-manager para no ser vos mismo el cuello de botella hacia el API server. Riesgo: subirlos sin límite traslada la presión a etcd/apiserver, disparando más writes concurrentes, más contención de I/O en etcd y posibles 429 por priority & fairness — cambiás un cuello de botella por otro peor.

**6c.** Es **API Priority and Fairness (APF)**: clasifica los requests entrantes en flow schemas y priority levels con colas separadas, y cuando un nivel se satura devuelve `429 Too Many Requests` con `Retry-After`. Ese 429 es una **protección**, no una falla: impide que una tormenta de clientes (un controller en loop, un `kubectl get` masivo, un operator descontrolado) sature al API server y a etcd y tumbe todo el control plane. Prioriza el tráfico crítico (health checks, leader election, kubelets) sobre el best-effort, degradando de forma controlada en vez de colapsar.

</details>

---

### Fuentes oficiales

- Kubernetes — *Controllers* (reconciliation, desired vs current state, control loops): https://kubernetes.io/docs/concepts/architecture/controller/
- Kubernetes — *Kubernetes Components* (control plane architecture): https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes — *API Concepts* (resourceVersion semantics, watch, list-watch, `410 Gone`, efficient detection of changes): https://kubernetes.io/docs/reference/using-api/api-concepts/
- Kubernetes — *Leases* (leader election, control-plane HA): https://kubernetes.io/docs/concepts/architecture/leases/
- Kubernetes — *Operating etcd clusters for Kubernetes* (etcd como backing store, WAL/latencia de disco): https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes — *API Priority and Fairness* (429, flow control): https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes — *kube-controller-manager* reference (flags `--concurrent-*-syncs`, `--node-monitor-*`): https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- etcd — *Documentation* (Raft, revisions, compaction): https://etcd.io/docs/