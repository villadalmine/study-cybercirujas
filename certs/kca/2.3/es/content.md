# 2.3 Configuración de controladores mediante flags

> **Dominio 2.3 del examen — peso 3.0.** Este tema cubre el binario `kube-controller-manager` (KCM), los control loops individuales que aloja, y cómo se ajusta su comportamiento exclusivamente a través de flags de línea de comandos (no hay un verbo de `kubectl` para esto — se edita un proceso). En el nivel KCA/producción se espera que puedas razonar sobre *por qué* se eligió un valor por defecto, qué se rompe cuando lo movés, y cómo demostrar que el cambio tuvo efecto.

---

## 1. Motivación y el problema de arquitectura en producción

### 1.1 Qué es realmente el controller manager

Kubernetes es un sistema declarativo construido sobre **control loops**. Un controlador es un bucle no terminante que:

1. **Observa** el estado deseado (un spec en etcd, entregado mediante un watch de *shared informer*).
2. **Compara** contra el estado observado del clúster (status).
3. **Actúa** para llevar lo actual hacia lo deseado (crear/actualizar/eliminar objetos de la API, llamar a una API de cloud, aplicar un taint a un nodo…).

El `kube-controller-manager` es un **único binario** que ejecuta ~35 de estos bucles como goroutines dentro de **un solo proceso**, compartiendo un informer cache y un cliente hacia el API server. Es una decisión de empaquetado deliberada: co-ubicar los bucles amortiza el costo de observar el API server (un único stream de watch alimenta a muchos controladores) y les permite compartir el mismo lease de leader election.

```
                      ┌───────────────────────────────────────────────┐
                      │           kube-controller-manager             │
                      │  (single leader-elected process per cluster)  │
   API server  ◄──────┤                                               │
   (watch/list)       │  ┌──────────┐ ┌──────────┐ ┌───────────────┐  │
        ▲             │  │ node     │ │ deploy   │ │ garbage       │  │
        │  writes     │  │ lifecycle│ │ controller│ │ collector    │  │
        └─────────────┤  └──────────┘ └──────────┘ └───────────────┘  │
                      │  ┌──────────┐ ┌──────────┐ ┌───────────────┐  │
                      │  │ endpoint │ │ SA/token │ │ resourcequota │  │
                      │  │ slice    │ │ replicaset│ │ …             │  │
                      │  └──────────┘ └──────────┘ └───────────────┘  │
                      │        shared informer cache + workqueues     │
                      └───────────────────────────────────────────────┘
```

El **problema** que resuelven los flags: los valores por defecto están afinados para un clúster *genérico y mediano*. Un clúster de 2.000 nodos, un clúster sobre una WAN inestable, un clúster con 100k pods rotando por CronJobs, y un clúster edge de 3 nodos necesitan *distinta* concurrencia de reconciliación, distintas ventanas de detección de fallos y distinta presión sobre el API server. Nada de eso se puede expresar en un CRD ni en un `Deployment` — el KCM es (en un clúster kubeadm) un **static pod** cuyo comportamiento queda fijado al arrancar el proceso por su argv en `command:`. La configuración *es* el conjunto de flags.

### 1.2 Por qué "mediante flags" específicamente

Tres propiedades hacen de la configuración basada en flags una habilidad operativa distinta:

- **No hay hot reload.** Cambiar un flag implica que el proceso del KCM se reinicia. En un control plane de kubeadm, editar el manifiesto del static pod hace que el kubelet recree el pod. Durante ese hueco otra réplica debe sostener (o adquirir) el lease de líder, o *no corre ningún controlador en absoluto* — los deployments dejan de escalar, los nodos caídos dejan de expulsar pods, dejan de emitirse tokens.
- **Radio de impacto a nivel de clúster.** Un solo flag equivocado (por ejemplo `--node-monitor-grace-period=4s`) afecta a *todos* los nodos y *todas* las cargas de trabajo. No hay alcance por namespace.
- **Mala configuración silenciosa.** Un nombre de flag mal tipeado hace que el pod caiga ruidosamente (bien). Pero un valor *válido* que es incorrecto para tu topología — digamos, `--kube-api-qps=100` sobre un API server ya saturado — degrada todo el clúster en silencio. Por eso la verificación (§5) no es opcional.

### 1.3 La división: `kube-controller-manager` vs `cloud-controller-manager`

Los bucles específicos de cloud (enriquecimiento de direcciones/zonas de nodos, programación de rutas, aprovisionamiento de Services `LoadBalancer`) históricamente se compilaban dentro del KCM. Ahora están factorizados en un **`cloud-controller-manager`** (CCM) separado, para que el proveedor de cloud publique y versione su integración de forma independiente. Cuando usás `--cloud-provider=external` en el kubelet y en el KCM, tres controladores se mueven del KCM al CCM:

| Controlador | En el KCM (in-tree) | En el CCM (externo) |
|---|---|---|
| `cloud-node` / `cloud-node-lifecycle` | ✅ (legacy) | ✅ |
| `route` | ✅ (legacy) | ✅ |
| `service` (LB) | ✅ (legacy) | ✅ |
| Todo lo demás (deployment, node IPAM, GC, …) | ✅ | ✅ (se queda en el KCM) |

Este documento se centra en el KCM; el CCM comparte la misma gramática de flags (`--controllers`, `--leader-elect*`, `--concurrent-*`).

---

## 2. Los control loops y sus parámetros ajustables (comparación técnica)

### 2.1 El inventario completo de controladores

`--controllers` es el interruptor maestro. Su texto de ayuda enumera cada bucle:

```
--controllers strings   Default: [*]
  '*' enables all on-by-default controllers, 'foo' enables 'foo', '-foo' disables 'foo'.
  All controllers:
    attachdetach, bootstrapsigner, cloud-node-lifecycle, clusterrole-aggregation,
    cronjob, csrapproving, csrcleaner, csrsigning, daemonset, deployment,
    disruption, endpoint, endpointslice, endpointslicemirroring, ephemeral-volume,
    garbagecollector, horizontalpodautoscaling, job, namespace, nodeipam,
    nodelifecycle, persistentvolume-binder, persistentvolume-expander, podgc,
    pv-protection, pvc-protection, replicaset, replicationcontroller,
    resourcequota, root-ca-cert-publisher, route, service, serviceaccount,
    serviceaccount-token, statefulset, tokencleaner, ttl, ttl-after-finished
  Disabled-by-default controllers:
    bootstrapsigner, tokencleaner
```

`*` significa **todos los bucles activados por defecto**. `bootstrapsigner` y `tokencleaner` están **apagados** salvo que se los nombre explícitamente — existen para el flujo de TLS bootstrap de kubeadm y la mayoría de los clústeres gestionados los dejan apagados.

Reglas de composición:
- `--controllers=*` → todos los controladores activados por defecto.
- `--controllers=*,-nodeipam` → todos los predeterminados **excepto** node IPAM (lo típico cuando Calico/Cilium son dueños de la asignación de pod CIDR).
- `--controllers=*,bootstrapsigner,tokencleaner` → los predeterminados **más** los dos bucles opcionales (kubeadm configura esto).
- `--controllers=deployment,replicaset` → *solo* esos dos (raramente útil; se usa para repartir controladores entre procesos).

### 2.2 Detección de fallo de nodos — los ajustes de mayor riesgo

El controlador `nodelifecycle` decide *cuándo un nodo está muerto* y *con qué rapidez los pods lo abandonan*. Aquí se origina la mayoría de los incidentes en producción.

| Flag | Por defecto | Significado | Bajarlo → | Subirlo → |
|---|---|---|---|---|
| `--node-monitor-period` | `5s` | Cada cuánto el KCM revisa la salud de cada nodo desde el informer cache | Reacción más rápida, más CPU/lecturas a la API | Detección lenta |
| `--node-monitor-grace-period` | `40s` | Sin heartbeat durante este tiempo ⇒ el nodo se marca `NotReady` (debe ser múltiplo de `node-monitor-period`; ≈ 5× el `nodeStatusUpdateFrequency` de 10s del kubelet, para absorber 3 actualizaciones perdidas) | Failover más rápido, **más falsos positivos** ante microcortes de red → expulsiones oscilantes | Failover más lento, más estable |
| `--node-startup-grace-period` | `1m0s` | Gracia para un nodo *recién registrado* antes de que apliquen los chequeos de salud | NotReady prematuro en arranques lentos | Ventana más larga antes de marcar un nodo nuevo trabado |
| `--large-cluster-size-threshold` | `50` | Por encima de esta cantidad de nodos aplica la tasa de expulsión *secundaria* (más lenta) por zona | — | Trata clústeres más grandes como "chicos" (agresivo) |
| `--node-eviction-rate` | `0.1` | Nodos/seg desde los que se expulsan pods cuando la zona está sana (0.1 = 1 nodo cada 10s) | Drenado más lento, más suave con la tormenta de reprogramación | Drenado más rápido, riesgo de reprogramación en estampida |
| `--secondary-node-eviction-rate` | `0.01` | Tasa de expulsión una vez que una zona grande se considera no sana | — | — |
| `--unhealthy-zone-threshold` | `0.55` | Fracción de nodos NotReady en una zona que la vuelca a "no sana" y frena la expulsión | Más conservador | Menos protección ante falsos positivos a nivel de zona |

**Mecánica crítica — expulsión basada en taints.** Cuando un nodo supera el grace period, el controlador **no** borra pods directamente. Aplica un taint:

- `node.kubernetes.io/not-ready` (el kubelet reportó problemas), o
- `node.kubernetes.io/unreachable` (el KCM perdió el heartbeat).

Los pods llevan una **toleration por defecto** `tolerationSeconds: 300` inyectada por el plugin de admisión `DefaultTolerationSeconds`. Así que el tiempo *observable* hasta la expulsión ante un fallo duro de nodo es:

```
T_evict ≈ node-monitor-grace-period (40s)  +  tolerationSeconds (300s)  ≈ 340s
```

Ajustar `--node-monitor-grace-period` por sí solo, entonces, solo mueve los *primeros* 40s. Para que las cargas stateless se reprogramen más rápido tenés que **además** bajar la toleration a nivel de pod (por pod, no es un flag del KCM):

```yaml
tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
```

> **Nota sobre deprecación.** El flag temporizador heredado `--pod-eviction-timeout` y `--enable-taint-manager` pertenecían al viejo camino de expulsión sin taints. La expulsión basada en taints es hoy el único mecanismo (`TaintBasedEvictions` llegó a GA hace mucho); en las versiones actuales `--pod-eviction-timeout` es un no-op / fue eliminado. No lo ajustes. Fuente: documentación "Taints and Tolerations" de Kubernetes.

### 2.3 Concurrencia de reconciliación — throughput vs presión sobre la API

Cada controlador ejecuta *N* goroutines worker drenando su workqueue. Más workers = recuperación más rápida tras una ráfaga, a costa de QPS contra el API server y memoria del KCM.

| Flag | Por defecto | Gobierna |
|---|---|---|
| `--concurrent-deployment-syncs` | `5` | Rollouts de Deployment |
| `--concurrent-replicaset-syncs` | `5` | Escalado de ReplicaSet |
| `--concurrent-statefulset-syncs` | `5` | Operaciones ordenadas de StatefulSet |
| `--concurrent-daemonset-syncs` | `2` | Rollouts de DaemonSet |
| `--concurrent-job-syncs` | `5` | Finalización de Jobs |
| `--concurrent-cron-job-syncs` | `5` | Planificación de CronJobs |
| `--concurrent-endpoint-syncs` | `5` | `Endpoints` legacy |
| `--concurrent-endpointslice-syncs` | `5` | `EndpointSlice` (el camino escalable) |
| `--concurrent-service-syncs` | `1` | Reconciliación de Service (LB) — deliberadamente serial |
| `--concurrent-namespace-syncs` | `10` | Borrado de Namespace/finalizers |
| `--concurrent-resource-quota-syncs` | `5` | Contabilidad de cuotas |
| `--concurrent-gc-syncs` | `20` | Garbage collection por owner-reference |
| `--concurrent-serviceaccount-token-syncs` | `5` | Emisión de tokens de SA |
| `--concurrent-horizontal-pod-autoscaler-syncs` | `5` | Evaluación del HPA |

**La restricción que gobierna todo** es el rate limiter del cliente hacia el API server:

| Flag | Por defecto | Efecto |
|---|---|---|
| `--kube-api-qps` | `20` | Peticiones/seg sostenidas que emitirá el cliente del KCM |
| `--kube-api-burst` | `30` | Techo de ráfaga del token bucket |

Subir `--concurrent-*-syncs` sin subir `--kube-api-qps`/`--kube-api-burst` logra poco: los workers extra simplemente se bloquean en el limitador compartido del cliente. En clústeres grandes un emparejamiento común es `--kube-api-qps=100 --kube-api-burst=100`, **solo después** de confirmar que el API server y etcd pueden absorberlo (observá `apiserver_flowcontrol_*` y la latencia de `wal_fsync` de etcd). Es un ajuste **acoplado**: concurrencia y QPS se mueven juntas, y ambas están acotadas por la capacidad del API server, no por el KCM.

### 2.4 Limpieza de basura / ciclo de vida

| Flag | Por defecto | Significado | Compromiso |
|---|---|---|---|
| `--terminated-pod-gc-threshold` | `12500` | `podgc` empieza a borrar pods terminados cuando existen tantos | Más bajo ⇒ etcd más liviano y `kubectl get pods` más limpio, pero más churn de borrados; `0` desactiva el GC (los pods se acumulan) |
| `--horizontal-pod-autoscaler-sync-period` | `15s` | Intervalo de recálculo del HPA | Más bajo ⇒ autoescalado más ágil, más carga sobre la metrics API |
| `--horizontal-pod-autoscaler-downscale-stabilization` | `5m0s` | Ventana durante la cual el HPA recuerda recomendaciones pasadas para evitar oscilación al bajar | Más bajo ⇒ escalado hacia abajo más rápido, riesgo de oscilación |
| `--horizontal-pod-autoscaler-tolerance` | `0.1` | Banda muerta de ±10% antes de que el HPA actúe | — |
| `--cluster-signing-duration` | `8760h0m0s` (1 año) | TTL de los certificados firmados por `csrsigning` (certificados serving/client del kubelet) | Más corto ⇒ rotación más estricta, más tráfico de CSR |
| `--attach-detach-reconcile-sync-period` | `1m0s` | Cadencia de reconciliación de attach/detach de volúmenes | — |

### 2.5 Identidad, seguridad, IPAM

| Flag | Por defecto | Propósito |
|---|---|---|
| `--use-service-account-credentials` | `false` | Cada controlador usa su **propia** ServiceAccount (`system:serviceaccount:kube-system:<controller>`) en vez de una identidad compartida → RBAC por controlador y atribución en la auditoría. **Ponelo en `true` en producción.** |
| `--service-account-private-key-file` | — | Clave privada que usa `serviceaccount-token` para firmar los JWT de SA (debe emparejar con la mitad pública `--service-account-key-file` del API server) |
| `--root-ca-file` | — | Bundle de CA que `root-ca-cert-publisher` inyecta en el ConfigMap `kube-root-ca.crt` de cada namespace |
| `--cluster-signing-cert-file` / `--cluster-signing-key-file` | — | CA que el controlador `csrsigning` usa para firmar CSRs |
| `--allocate-node-cidrs` | `false` | `nodeipam` talla los pod CIDR desde `--cluster-cidr` para cada nodo |
| `--cluster-cidr` | — | Red agregada de pods |
| `--node-cidr-mask-size` | `24` (IPv4) | Tamaño de la subred de pods por nodo (24 ⇒ espacio de direcciones para 254 pods/nodo) |
| `--service-cluster-ip-range` | — | Debe coincidir con el valor del API server (usado por parte de la lógica de rutas de cloud) |

### 2.6 Leader election — disponibilidad de los propios control loops

Como el KCM no es un Deployment con N réplicas activas, la HA se logra ejecutando varios procesos KCM (uno por nodo del control plane) que **compiten por un `Lease`**. Exactamente uno está activo; el resto queda en hot standby. Si el líder muere, un standby adquiere el lease y retoma la reconciliación.

| Flag | Por defecto | Significado | Tensión de ajuste |
|---|---|---|---|
| `--leader-elect` | `true` | Habilita la competencia | Apagalo **solo** en un clúster de desarrollo de una sola réplica |
| `--leader-elect-lease-duration` | `15s` | Cuánto espera un no-líder antes de poder reclamar un lease no renovado | Más corto ⇒ failover más rápido, pero un líder lento puede perder el lease bajo una pausa de GC → churn de división |
| `--leader-elect-renew-deadline` | `10s` | El líder debe renovar dentro de este plazo o se autodegrada (**debe ser < lease-duration**) | — |
| `--leader-elect-retry-period` | `2s` | Intervalo entre intentos de adquisición/renovación | — |
| `--leader-elect-resource-lock` | `leases` | Tipo de objeto de bloqueo (`leases` — no uses los locks eliminados `endpoints`/`configmaps`) | — |
| `--leader-elect-resource-name` | `kube-controller-manager` | Nombre del objeto Lease en `kube-system` | — |

La relación segura es `retry-period < renew-deadline < lease-duration`. Comprimir las tres acelera el failover a unos pocos segundos, pero vuelve al líder frágil ante pausas stop-the-world; un líder pausado que incumple `renew-deadline` se degrada, y sigue un breve período *sin ningún controlador activo* hasta que un standby gana.

---

## 3. Manifiestos completos, sin recortes, e infraestructura

### 3.1 El static pod del KCM (layout de kubeadm, `/etc/kubernetes/manifests/kube-controller-manager.yaml`)

Este es el archivo real que observa el kubelet. Toda la superficie de configuración es el argv de `command:`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
  labels:
    component: kube-controller-manager
    tier: control-plane
  annotations:
    kubernetes.io/config.hash: 9c3f7b2a1e5d4c8b0a6f2d9e7c1b3a4f
    kubernetes.io/config.seen: "2026-08-13T09:14:22.113847Z"
    kubernetes.io/config.source: file
spec:
  priorityClassName: system-node-critical
  priority: 2000001000
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - name: kube-controller-manager
      image: registry.k8s.io/kube-controller-manager:v1.31.1
      command:
        - kube-controller-manager
        - --allocate-node-cidrs=true
        - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
        - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
        - --bind-address=127.0.0.1
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        - --cluster-cidr=10.244.0.0/16
        - --cluster-name=kubernetes
        - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
        - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
        - --controllers=*,bootstrapsigner,tokencleaner
        - --kubeconfig=/etc/kubernetes/controller-manager.conf
        - --leader-elect=true
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
        - --root-ca-file=/etc/kubernetes/pki/ca.crt
        - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
        - --service-cluster-ip-range=10.96.0.0/12
        - --use-service-account-credentials=true
        # --- production tuning overlay (added by the operator) ---
        - --node-monitor-grace-period=40s
        - --node-monitor-period=5s
        - --kube-api-qps=50
        - --kube-api-burst=75
        - --concurrent-deployment-syncs=10
        - --concurrent-endpointslice-syncs=10
        - --terminated-pod-gc-threshold=2000
        - --leader-elect-lease-duration=15s
        - --leader-elect-renew-deadline=10s
        - --leader-elect-retry-period=2s
      resources:
        requests:
          cpu: 200m
      livenessProbe:
        httpGet:
          host: 127.0.0.1
          path: /healthz
          port: 10257
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 8
      startupProbe:
        httpGet:
          host: 127.0.0.1
          path: /healthz
          port: 10257
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 24
      volumeMounts:
        - name: ca-certs
          mountPath: /etc/ssl/certs
          readOnly: true
        - name: flexvolume-dir
          mountPath: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: kubeconfig
          mountPath: /etc/kubernetes/controller-manager.conf
          readOnly: true
  hostAliases:
    - ip: 127.0.0.1
      hostnames: [localhost]
  volumes:
    - name: ca-certs
      hostPath:
        path: /etc/ssl/certs
        type: DirectoryOrCreate
    - name: flexvolume-dir
      hostPath:
        path: /usr/libexec/kubernetes/kubelet-plugins/volume/exec
        type: DirectoryOrCreate
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/controller-manager.conf
        type: FileOrCreate
status: {}
```

> **Nota sobre `--bind-address=127.0.0.1`.** El puerto seguro del KCM (`10257`, que sirve `/metrics` y `/healthz`) queda ligado a loopback para que no esté expuesto en la red del nodo. Para hacer scraping de métricas desde Prometheus, o bien lo cambiás a `0.0.0.0` (y confiás en RBAC + TLS), o bien scrapeás mediante un sidecar/kube-rbac-proxy. **No** lo abras a ciegas sin authn/authz.

### 3.2 Declarar los flags a la manera de kubeadm (`ClusterConfiguration`)

Editar el static pod a mano no es duradero — un `kubeadm upgrade` lo regenera. Codificá el tuning en la configuración del clúster para que sobreviva a las actualizaciones:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.1
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
controllerManager:
  extraArgs:
    # kubeadm v1beta4 uses a list of name/value pairs (repeatable flags supported)
    - name: node-monitor-grace-period
      value: 40s
    - name: node-monitor-period
      value: 5s
    - name: kube-api-qps
      value: "50"
    - name: kube-api-burst
      value: "75"
    - name: concurrent-deployment-syncs
      value: "10"
    - name: concurrent-endpointslice-syncs
      value: "10"
    - name: terminated-pod-gc-threshold
      value: "2000"
    - name: use-service-account-credentials
      value: "true"
    - name: controllers
      value: "*,bootstrapsigner,tokencleaner,-nodeipam"   # Cilium owns IPAM
```

Aplicar sobre un control plane existente:

```bash
$ sudo kubeadm init phase control-plane controller-manager \
    --config /etc/kubernetes/kubeadm-config.yaml
```

### 3.3 Archivo de component config en lugar de flags sueltos (`KubeControllerManagerConfiguration`)

Muchos de los ajustes `--concurrent-*` y de leader election también existen como configuración estructurada, referenciada con un único flag `--config`. Esta es la dirección hacia la que se mueve Kubernetes (menos flags pelados):

```yaml
apiVersion: kubecontrollermanager.config.k8s.io/v1alpha1
kind: KubeControllerManagerConfiguration
generic:
  leaderElection:
    leaderElect: true
    leaseDuration: 15s
    renewDeadline: 10s
    retryPeriod: 2s
    resourceLock: leases
    resourceName: kube-controller-manager
    resourceNamespace: kube-system
  controllers:
    - "*"
    - "bootstrapsigner"
    - "tokencleaner"
kubeControllerManagerClientConnection:
  qps: 50
  burst: 75
nodeLifecycleController:
  nodeMonitorGracePeriod: 40s
  nodeStartupGracePeriod: 1m0s
deploymentController:
  concurrentDeploymentSyncs: 10
podGCController:
  terminatedPodGCThreshold: 2000
serviceAccountController:
  concurrentSATokenSyncs: 10
```

Se referencia desde el pod como `--config=/etc/kubernetes/kcm-config.yaml` (montado de solo lectura). Los flags y `--config` pueden coexistir; para un mismo campo, los flags explícitos ganan sobre los valores del archivo de configuración.

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Confirmar que el pod está arriba y ver el argv exacto que tuvo efecto

```bash
$ kubectl -n kube-system get pod -l component=kube-controller-manager -o wide
NAME                                    READY   STATUS    RESTARTS      AGE    IP              NODE
kube-controller-manager-cp-1            1/1     Running   0             3h12m  10.0.0.11       cp-1
kube-controller-manager-cp-2            1/1     Running   1 (2h ago)    3h12m  10.0.0.12       cp-2
kube-controller-manager-cp-3            1/1     Running   0             3h12m  10.0.0.13       cp-3
```

La única fuente de verdad sobre *qué está usando realmente el proceso en ejecución* es su argv, no el manifiesto en disco (pueden divergir):

```bash
$ ps -C kube-controller-manager -o args --no-headers | tr ' ' '\n' | grep -E 'monitor|qps|burst|controllers|leader'
--controllers=*,bootstrapsigner,tokencleaner
--leader-elect=true
--node-monitor-grace-period=40s
--node-monitor-period=5s
--kube-api-qps=50
--kube-api-burst=75
--leader-elect-lease-duration=15s
--leader-elect-renew-deadline=10s
--leader-elect-retry-period=2s
```

### 4.2 Demostrar qué control loops arrancaron realmente

Cada bucle escribe una línea `Starting controller`/`Started` en el arranque. Así es como verificás que `--controllers` hizo lo que querías:

```bash
$ kubectl -n kube-system logs kube-controller-manager-cp-1 | grep -iE 'Started controller|Starting .* controller' | head
I0813 09:14:31.882014       1 controllermanager.go:337] "Started controller" controller="deployment"
I0813 09:14:31.884771       1 controllermanager.go:337] "Started controller" controller="replicaset"
I0813 09:14:31.889902       1 controllermanager.go:337] "Started controller" controller="node-lifecycle"
I0813 09:14:31.893310       1 controllermanager.go:337] "Started controller" controller="endpointslice"
I0813 09:14:31.897655       1 controllermanager.go:337] "Started controller" controller="garbage-collector"
I0813 09:14:31.902118       1 controllermanager.go:337] "Started controller" controller="serviceaccount-token"
I0813 09:14:31.905540       1 controllermanager.go:337] "Started controller" controller="resourcequota"
I0813 09:14:31.9081...
```

Un bucle deshabilitado también se anuncia:

```bash
$ kubectl -n kube-system logs kube-controller-manager-cp-1 | grep -i 'not enabled'
I0813 09:14:31.774213       1 controllermanager.go:322] "Warning: controller is disabled" controller="nodeipam"
```

### 4.3 Inspeccionar el Lease de leader election

```bash
$ kubectl -n kube-system get lease kube-controller-manager
NAME                      HOLDER                                            AGE
kube-controller-manager   cp-1_3f6c1d9a-8b02-4e77-9c1a-1d2e3f4a5b6c         3h13m

$ kubectl -n kube-system get lease kube-controller-manager -o yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  holderIdentity: cp-1_3f6c1d9a-8b02-4e77-9c1a-1d2e3f4a5b6c
  leaseDurationSeconds: 15
  acquireTime: "2026-08-13T06:01:44.882000Z"
  renewTime: "2026-08-13T09:15:02.114000Z"      # updated every ~retry-period
  leaseTransitions: 4                             # how many times leadership moved
```

Un `leaseTransitions` que sube de forma sostenida es una señal de alarma (líder oscilante — habitualmente un renew-deadline demasiado ajustado o un KCM con hambre de CPU).

### 4.4 Scrapear las métricas que reflejan el comportamiento de los flags

```bash
$ TOKEN=$(kubectl -n kube-system create token default)
$ kubectl -n kube-system exec kube-controller-manager-cp-1 -- \
    curl -sk -H "Authorization: Bearer $TOKEN" https://127.0.0.1:10257/metrics \
  | grep -E 'workqueue_depth|leader_election_master_status|node_collector_evictions_total' | head
# HELP workqueue_depth [ALPHA] Current depth of workqueue
workqueue_depth{name="deployment"} 0
workqueue_depth{name="endpoint_slice"} 3
workqueue_depth{name="garbage_collector_attempt_to_delete"} 0
# HELP leader_election_master_status Gauge of if the reporting system is master
leader_election_master_status{name="kube-controller-manager"} 1
# HELP node_collector_evictions_total Number of Node evictions that happened since ...
node_collector_evictions_total{zone=""} 0
```

Un `workqueue_depth` persistentemente distinto de cero para un controlador significa que su `--concurrent-*-syncs` (y/o `--kube-api-qps`) es demasiado bajo para el churn — es la señal accionable para subir la concurrencia.

### 4.5 Observar los tiempos de fallo de nodo que gobiernan los flags

```bash
# Kill the kubelet on a worker to simulate a hard node failure
$ ssh worker-3 'sudo systemctl stop kubelet'

# ~40s later (node-monitor-grace-period) the node flips NotReady:
$ kubectl get nodes -w
NAME       STATUS   ROLES    AGE   VERSION
worker-3   Ready    <none>   9d    v1.31.1
worker-3   NotReady <none>   9d    v1.31.1        # T+40s

# The controller applies the unreachable taint (NoExecute):
$ kubectl describe node worker-3 | grep -A2 Taints
Taints:  node.kubernetes.io/unreachable:NoExecute
         node.kubernetes.io/unreachable:NoSchedule

# Pods without a shorter toleration are evicted at T+40s+300s (default tolerationSeconds):
$ kubectl get events --field-selector reason=TaintManagerEviction -A
LAST SEEN   TYPE     REASON                 OBJECT              MESSAGE
2s          Normal   TaintManagerEviction   pod/web-7c9f-abcde  Marking for deletion Pod default/web-7c9f-abcde
```

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Procedimiento seguro de cambio (editar → auto-recuperación → verificar)

```bash
# 1. Snapshot before touching anything
$ sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml /root/kcm.yaml.bak

# 2. Edit the static pod manifest (kubelet detects the write and recreates the pod)
$ sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml

# 3. Watch the kubelet recreate it — mirror pod bounces:
$ kubectl -n kube-system get pod kube-controller-manager-cp-1 -w
NAME                           READY   STATUS    RESTARTS   AGE
kube-controller-manager-cp-1   0/1     Pending   0          0s
kube-controller-manager-cp-1   0/1     Running   0          2s
kube-controller-manager-cp-1   1/1     Running   0          12s

# 4. Verify the new argv is live (§4.1) and no crash loop
$ kubectl -n kube-system get pod kube-controller-manager-cp-1 -o jsonpath='{.status.containerStatuses[0].state}{"\n"}'
{"running":{"startedAt":"2026-08-13T09:20:14Z"}}
```

Si el pod no reaparece en ~30s, el kubelet rechazó el manifiesto — revisá `journalctl -u kubelet`.

### 5.2 Fallo: un flag inválido deja el pod en crash loop

```bash
# You typo'd --node-monitor-grace-period=40  (missing the unit)
$ kubectl -n kube-system get pod kube-controller-manager-cp-1
NAME                           READY   STATUS             RESTARTS      AGE
kube-controller-manager-cp-1   0/1     CrashLoopBackOff   4 (23s ago)   96s

# The container writes the parse error to stderr, then exits 1:
$ kubectl -n kube-system logs kube-controller-manager-cp-1 --previous | tail -3
E0813 09:24:02.118      1 run.go:74] "command failed" err="invalid argument \"40\" for \"--node-monitor-grace-period\" flag: time: missing unit in duration \"40\""
```

Arreglo: las duraciones necesitan unidades (`40s`). Restaurá desde el backup si no llegás a editar a tiempo — el clúster corre *sin controller manager* mientras está en crash loop (otras réplicas lo cubren si hay HA).

### 5.3 Fallo: flag desconocido (regresión después de una actualización)

```bash
$ kubectl -n kube-system logs kube-controller-manager-cp-2 --previous | tail -2
Error: unknown flag: --pod-eviction-timeout
```

Un flag eliminado (como `--pod-eviction-timeout`) sobrevive en un manifiesto editado a mano a través de una actualización y entonces rompe todo. Reconciliá siempre tus flags personalizados contra `kube-controller-manager --help` de la versión destino antes de actualizar.

### 5.4 Fallo: split-brain / liderazgo oscilante

```bash
$ kubectl -n kube-system get lease kube-controller-manager \
    -o jsonpath='{.spec.leaseTransitions}{"\n"}'
37                       # climbing fast → leadership is bouncing

$ kubectl -n kube-system logs kube-controller-manager-cp-1 | grep -i 'lost lease\|stopped leading'
I0813 09:31:10.4471  1 leaderelection.go:285] "failed to renew lease kube-system/kube-controller-manager: timed out waiting for the condition"
E0813 09:31:10.4479  1 controllermanager.go:305] "leaderelection lost"
```

Causas y soluciones:
- **`renew-deadline` demasiado ajustado frente al throttling de CPU del KCM** → dale más CPU al KCM (subí los `requests` del pod) o relajá `--leader-elect-renew-deadline`.
- **Picos de latencia de etcd/API server** → la escritura del Lease no llega a tiempo; arreglá el datastore, no lo tapes ensanchando los timeouts.
- **Desfase de reloj entre los nodos del control plane** → usá NTP.

### 5.5 Fallo: un controlador silenciosamente no está corriendo

Síntoma: las ServiceAccounts no obtienen secret de token, o los pods terminados nunca pasan por el GC, y sin embargo el KCM está `Running`.

```bash
# Did the loop start?  (empty output = it never started → check --controllers)
$ kubectl -n kube-system logs kube-controller-manager-cp-1 \
    | grep -i 'Started controller' | grep -i 'serviceaccount-token'
                                    # <-- nothing: the loop is disabled

$ ps -C kube-controller-manager -o args --no-headers | grep -o -- '--controllers=[^ ]*'
--controllers=deployment,replicaset       # someone pinned an allow-list and dropped the rest
```

Arreglo: restaurá `--controllers=*,...` salvo que estés repartiendo controladores entre procesos *intencionalmente* (avanzado; cada shard debe ser dueño de un conjunto disjunto y la unión debe ser completa).

### 5.6 Fallo: subir la concurrencia empeoró las cosas

Subir `--concurrent-*-syncs` y `--kube-api-qps` sin verificar la capacidad del API server termina throttleando a todo el mundo vía API Priority & Fairness:

```bash
$ kubectl -n kube-system exec kube-controller-manager-cp-1 -- \
    curl -sk -H "Authorization: Bearer $TOKEN" https://127.0.0.1:10257/metrics \
  | grep -E 'rest_client_rate_limiter_duration_seconds_sum'
rest_client_rate_limiter_duration_seconds_sum{...} 812.4     # client is self-throttling heavily
```

Que `rest_client_rate_limiter_duration_seconds` suba significa que el cuello de botella es el limitador del cliente *propio* del KCM (`--kube-api-qps`); pero si además `apiserver_flowcontrol_rejected_requests_total` en el API server también está subiendo, te pasaste de la capacidad del servidor — bajá la concurrencia **y** el QPS, o escalá primero el API server/etcd. Concurrencia sin margen es trabajo negativo.

### 5.7 Checklist rápido de verificación

| Afirmación | Prueba de una línea |
|---|---|
| El flag X tuvo efecto | `ps -C kube-controller-manager -o args` lo muestra |
| El bucle Y está corriendo | `logs … | grep 'Started controller'` lo nombra |
| Somos el líder acá | `/metrics` → `leader_election_master_status … 1` |
| El liderazgo es estable | `lease … .spec.leaseTransitions` no sube |
| La concurrencia alcanza | `workqueue_depth{name="…"}` ≈ 0 en régimen estable |
| No hay auto-throttling | `rest_client_rate_limiter_duration_seconds` plano |
| Los tiempos de nodo son los diseñados | el nodo pasa a `NotReady` a ≈ `node-monitor-grace-period` |

---

## Referencias

- Referencia de flags de kube-controller-manager: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- Concepto de controladores (modelo de control loop): https://kubernetes.io/docs/concepts/architecture/controller/
- Cloud Controller Manager (división KCM/CCM): https://kubernetes.io/docs/concepts/architecture/cloud-controller/
- Ciclo de vida del nodo, salud y expulsión basada en taints: https://kubernetes.io/docs/concepts/architecture/nodes/
- Taints and Tolerations (expulsión NoExecute, tolerationSeconds): https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Leader election / Leases de coordinación: https://kubernetes.io/docs/concepts/cluster-administration/coordinated-leader-election/
- Configurar las opciones de agregación y del controller manager vía kubeadm (`ClusterConfiguration.controllerManager.extraArgs`): https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/
- KubeControllerManagerConfiguration (component config v1alpha1): https://kubernetes.io/docs/reference/config-api/kube-controller-manager-config.v1alpha1/
- API Priority and Fairness (interacción con `--kube-api-qps`/`--kube-api-burst`): https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Métricas de componentes del sistema (`workqueue_depth`, `leader_election_master_status`, `rest_client_rate_limiter_duration_seconds`): https://kubernetes.io/docs/reference/instrumentation/metrics/
- Currículum KCA (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf