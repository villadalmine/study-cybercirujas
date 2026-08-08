# Ejercicios guiados — CNPE 1.1: Applying Platform Architecture Best Practices for Networking, Storage, and Compute

> **Enfoque de plataforma.** En CNPE no operás *una* aplicación: diseñás las *capabilities* que cientos de equipos consumirán por *self-service*. Cada ejercicio parte de la mirada del platform engineer: definir el *default* correcto, hacerlo *golden path*, y dejar la vía de escape para el caso excepcional. La referencia conceptual es el *CNCF Platform Engineering Maturity Model* y el *Platforms White Paper* del TAG App Delivery (<https://tag-app-delivery.cncf.io/whitepapers/platforms/>).

## Requisitos del entorno de laboratorio

Necesitás un cluster donde tengas permisos de administrador. Un `kind` multi-nodo alcanza para casi todo; para las secciones de NetworkPolicy y StorageClass real, indicaré la advertencia cuando el CNI/CSI por defecto no sea suficiente.

```bash
# 1. Cluster de 1 control-plane + 3 workers, simulando 2 zonas de disponibilidad
cat > kind-cnpe.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    labels:
      topology.kubernetes.io/zone: zone-a
      node-pool: general
  - role: worker
    labels:
      topology.kubernetes.io/zone: zone-b
      node-pool: general
  - role: worker
    labels:
      topology.kubernetes.io/zone: zone-b
      node-pool: memory-optimized
EOF

kind create cluster --name cnpe --config kind-cnpe.yaml
```

Salida esperada (resumida):

```
Creating cluster "cnpe" ...
 ✓ Ensuring node image (kindest/node:v1.31.0) 🖼
 ✓ Preparing nodes 📦 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-cnpe"
```

Verificá que el `metrics-server` esté disponible (necesario para `kubectl top` y HPA). En `kind` no viene instalado:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# En kind, el kubelet usa certificados self-signed; el metrics-server los rechaza por defecto
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system
```

---

## Ejercicio 1 — Compute: gobernanza de recursos, QoS y reparto topológico

**Objetivo:** establecer los *defaults* de compute que toda plataforma debe imponer — requests/limits sensatos, clases de QoS predecibles, y alta disponibilidad por *spread* topológico — sin que el desarrollador tenga que pensarlos.

1. Observá qué recursos *reales* tiene cada nodo y cuántos ya están reservados. `Capacity` es el hardware; `Allocatable` es lo que queda tras restar lo reservado para kubelet, runtime y OS:

   ```bash
   kubectl describe node cnpe-worker | sed -n '/Capacity:/,/System Info:/p'
   ```

   Salida esperada (recortada):

   ```
   Capacity:
     cpu:                8
     ephemeral-storage:  61202244Ki
     memory:             16093816Ki
     pods:               110
   Allocatable:
     cpu:                8
     ephemeral-storage:  56403987978
     memory:             15991416Ki
     pods:               110
   ```

2. Creá un namespace de laboratorio y aplicá un `LimitRange` (defaults por contenedor) y un `ResourceQuota` (techo del namespace). Éste es el mecanismo con el que la plataforma evita que un Pod sin `requests` colapse un nodo:

   ```bash
   kubectl create namespace team-a
   ```

   ```yaml
   # governance.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: defaults
     namespace: team-a
   spec:
     limits:
       - type: Container
         default:            # se aplica como 'limits' si el Pod no los declara
           cpu: 500m
           memory: 256Mi
         defaultRequest:     # se aplica como 'requests' si el Pod no los declara
           cpu: 100m
           memory: 128Mi
         max:
           cpu: "2"
           memory: 2Gi
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-a-quota
     namespace: team-a
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
       pods: "50"
   ```

   ```bash
   kubectl apply -f governance.yaml
   ```

3. Desplegá un Pod **sin** declarar recursos y comprobá que el `LimitRange` los inyectó:

   ```bash
   kubectl run probe --image=registry.k8s.io/pause:3.9 -n team-a
   kubectl get pod probe -n team-a -o jsonpath='{.spec.containers[0].resources}' | jq
   ```

   Salida esperada:

   ```json
   {
     "limits":   { "cpu": "500m", "memory": "256Mi" },
     "requests": { "cpu": "100m", "memory": "128Mi" }
   }
   ```

4. Consultá la clase de QoS que Kubernetes le asignó. La QoS **no** se declara: se *deriva* de la relación entre requests y limits, y decide el orden de *eviction* bajo presión de memoria:

   ```bash
   kubectl get pod probe -n team-a -o jsonpath='{.status.qosClass}{"\n"}'
   ```

   Salida esperada:

   ```
   Burstable
   ```

**Preguntas de verificación (bloque 1):**
- 1a. ¿Por qué la plataforma debe distinguir `Capacity` de `Allocatable` al dimensionar node pools, y qué pasaría si un equipo asumiera que dispone del `Capacity` completo?
- 1b. ¿Qué combinación exacta de `requests` y `limits` produce QoS `Guaranteed`, y por qué querés esa clase para cargas *latency-sensitive*?
- 1c. Un desarrollador declara `requests.memory: 128Mi` pero omite el `limit`. ¿Qué QoS obtiene y qué riesgo introduce eso en un nodo compartido?

---

5. Ahora garantizá alta disponibilidad. Desplegá una app con `topologySpreadConstraints` para que no queden todas las réplicas en una zona, más una `PriorityClass` para que sea *no-desalojable* frente a cargas batch:

   ```yaml
   # ha-workload.yaml
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata:
     name: platform-critical
   value: 1000000
   globalDefault: false
   description: "Servicios de plataforma que no deben ser preemptidos por batch."
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: team-a
   spec:
     replicas: 4
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         priorityClassName: platform-critical
         topologySpreadConstraints:
           - maxSkew: 1
             topologyKey: topology.kubernetes.io/zone
             whenUnsatisfiable: DoNotSchedule
             labelSelector:
               matchLabels: { app: web }
         containers:
           - name: web
             image: registry.k8s.io/e2e-test-images/agnhost:2.47
             args: ["netexec", "--http-port=8080"]
             resources:
               requests: { cpu: 100m, memory: 128Mi }
               limits:   { cpu: 250m, memory: 256Mi }
   ```

   ```bash
   kubectl apply -f ha-workload.yaml
   kubectl get pods -n team-a -l app=web \
     -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,ZONE:'.metadata.labels' --no-headers
   # Reparto por zona (forma robusta):
   kubectl get pods -n team-a -l app=web -o json \
     | jq -r '.items[].spec.nodeName' | sort | uniq -c
   ```

   Salida esperada (el reparto respeta `maxSkew: 1` entre zonas):

   ```
     1 cnpe-worker
     1 cnpe-worker2
     1 cnpe-worker3
     1 cnpe-worker
   ```

6. Provocá el fallo instructivo: subí `replicas` a 20. Con `whenUnsatisfiable: DoNotSchedule` y solo 3 workers, algunos Pods quedarán `Pending` si no se puede respetar el skew *y* la capacidad:

   ```bash
   kubectl scale deployment/web -n team-a --replicas=20
   kubectl get pods -n team-a -l app=web --field-selector=status.phase=Pending -o name | head
   kubectl describe pod -n team-a $(kubectl get pods -n team-a -l app=web \
     --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}') \
     | sed -n '/Events:/,$p'
   ```

   Salida esperada (el *scheduler* explica el motivo):

   ```
   Events:
     Type     Reason            Message
     ----     ------            -------
     Warning  FailedScheduling  0/4 nodes are available: 1 node(s) had untolerated
              taint {node-role.kubernetes.io/control-plane}, 3 node(s) didn't match
              pod topology spread constraints. preemption: 0/4 nodes are available.
   ```

**Preguntas de verificación (bloque 2):**
- 2a. ¿Cuál es la diferencia práctica entre `whenUnsatisfiable: DoNotSchedule` y `ScheduleAnyway`, y cuál elegirías para un servicio *stateless* de frontend versus un job de *reporting* nocturno?
- 2b. La `PriorityClass` con valor alto habilita *preemption*. Explicá qué Pod desaloja a cuál cuando no hay capacidad, y por qué asignar prioridades altas indiscriminadamente rompe la plataforma.
- 2c. ¿Por qué `topologySpreadConstraints` es superior a `podAntiAffinity` con `requiredDuringScheduling` para HA por zonas cuando querés tolerar el escalado?

---

## Ejercicio 2 — Storage: la StorageClass como capability de self-service

**Objetivo:** exponer almacenamiento persistente como un menú de *tiers* (`fast`, `standard`) con las decisiones correctas ya tomadas — *binding* diferido, expansión habilitada, *reclaim* seguro — y probar el ciclo StatefulSet + snapshot.

1. Inspeccioná la StorageClass por defecto del cluster y detectá los tres flags que definen el comportamiento de producción:

   ```bash
   kubectl get storageclass
   kubectl get storageclass standard -o yaml | grep -E 'provisioner|reclaimPolicy|volumeBindingMode|allowVolumeExpansion'
   ```

   Salida esperada en `kind` (nótese lo que *falta*):

   ```
   NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
   standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false
   ```

2. Definí una StorageClass de *tier* premium con los defaults que una plataforma seria impone. `WaitForFirstConsumer` evita provisionar el volumen en una zona donde el Pod nunca podrá correr; `allowVolumeExpansion` permite crecer sin recrear; `Retain` protege datos ante borrados accidentales de PVC:

   ```yaml
   # storageclass-fast.yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: fast
   provisioner: rancher.io/local-path   # en producción: ebs.csi.aws.com, pd.csi.storage.gke.io, etc.
   reclaimPolicy: Retain
   volumeBindingMode: WaitForFirstConsumer
   allowVolumeExpansion: true
   ```

   ```bash
   kubectl apply -f storageclass-fast.yaml
   ```

3. Desplegá un StatefulSet que consume la clase vía `volumeClaimTemplates` (cada réplica obtiene su PVC propio y estable), y observá el *binding* diferido:

   ```yaml
   # stateful.yaml
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: cache
     namespace: team-a
   spec:
     serviceName: cache
     replicas: 2
     selector:
       matchLabels: { app: cache }
     template:
       metadata:
         labels: { app: cache }
       spec:
         containers:
           - name: redis
             image: redis:7.4-alpine
             ports: [{ containerPort: 6379 }]
             volumeMounts:
               - name: data
                 mountPath: /data
     volumeClaimTemplates:
       - metadata:
           name: data
         spec:
           accessModes: ["ReadWriteOnce"]
           storageClassName: fast
           resources:
             requests:
               storage: 1Gi
   ```

   ```bash
   kubectl apply -f stateful.yaml
   kubectl get pvc -n team-a -l app=cache
   ```

   Salida esperada (los PVC se llaman `<template>-<statefulset>-<ordinal>` y quedan `Bound` recién cuando su Pod se agenda):

   ```
   NAME             STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS
   data-cache-0     Bound    pvc-a1b2...  1Gi        RWO            fast
   data-cache-1     Bound    pvc-c3d4...  1Gi        RWO            fast
   ```

4. Probá la expansión en caliente. Editá el PVC del ordinal 0 y comprobá que crece sin recrear el Pod:

   ```bash
   kubectl patch pvc data-cache-0 -n team-a --type merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
   kubectl get pvc data-cache-0 -n team-a -o jsonpath='{.status.capacity.storage}{"\n"}'
   ```

**Preguntas de verificación (bloque 3):**
- 3a. Con `reclaimPolicy: Retain`, ¿qué le pasa al PV y al dato subyacente cuando borrás el PVC, y qué paso manual queda pendiente? ¿Por qué `Delete` es peligroso como *default* de plataforma?
- 3b. Explicá un escenario concreto en un cluster multi-zona donde `volumeBindingMode: Immediate` deja un Pod `Pending` para siempre y `WaitForFirstConsumer` lo evita.
- 3c. ¿Por qué un StatefulSet usa `volumeClaimTemplates` en lugar de un único PVC compartido con `ReadWriteMany`? Enumerá los cuatro *access modes* (RWO, ROX, RWX, RWOP) y un caso de uso para cada uno.

---

5. Implementá *backup* como capability con la API de snapshots. Requiere un CSI driver con soporte de snapshots y los CRDs `snapshot.storage.k8s.io` instalados (en `kind` con `local-path` esto **no** está soportado — reconocé la limitación y anotá el manifiesto que usarías en producción):

   ```yaml
   # snapshot.yaml  (aplicable en un cluster con CSI + external-snapshotter)
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshotClass
   metadata:
     name: csi-snapclass
   driver: ebs.csi.aws.com            # el mismo driver que la StorageClass origen
   deletionPolicy: Retain
   ---
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshot
   metadata:
     name: cache-0-snap
     namespace: team-a
   spec:
     volumeSnapshotClassName: csi-snapclass
     source:
       persistentVolumeClaimName: data-cache-0
   ```

   Verificación esperada en un cluster capaz:

   ```bash
   kubectl get volumesnapshot cache-0-snap -n team-a
   # NAME           READYTOUSE   SOURCEPVC      RESTORESIZE   SNAPSHOTCONTENT
   # cache-0-snap   true         data-cache-0   1Gi           snapcontent-...
   ```

   La *restore* se hace creando un PVC nuevo cuyo `dataSource` apunta al snapshot:

   ```yaml
   # restore.yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: data-cache-0-restored
     namespace: team-a
   spec:
     accessModes: ["ReadWriteOnce"]
     storageClassName: fast
     resources:
       requests:
         storage: 1Gi
     dataSource:
       name: cache-0-snap
       kind: VolumeSnapshot
       apiGroup: snapshot.storage.k8s.io
   ```

**Preguntas de verificación (bloque 4):**
- 4a. ¿Por qué el `driver` del `VolumeSnapshotClass` debe coincidir con el provisioner de la StorageClass origen? ¿Qué falla si no coinciden?
- 4b. Un snapshot CSI de un volumen de base de datos activo puede ser *crash-consistent* pero no *application-consistent*. Explicá la diferencia y qué mecanismo (por ejemplo `fsfreeze` o un *pre/post-hook*) usarías para cerrar la brecha.

---

## Ejercicio 3 — Networking: aislamiento por defecto y exposición controlada

**Objetivo:** aplicar el principio de *zero-trust* dentro del cluster (default-deny + allow explícito) y exponer un servicio con Ingress/Gateway API, entendiendo la cadena Service → kube-proxy → CNI.

> **Advertencia de CNI.** El CNI por defecto de `kind` (`kindnet`) **no** enforcea NetworkPolicy: los objetos se crean pero el tráfico nunca se bloquea. Para este ejercicio instalá Calico o Cilium, o reconocé que la política es declarativa pero inerte con `kindnet`. En producción, la elección de CNI *es* una decisión de arquitectura de plataforma.

```bash
# Reemplazar kindnet por Cilium (opcional, para que las NetworkPolicy realmente apliquen)
cilium install --version 1.16.3
cilium status --wait
```

1. Recorré la cadena de resolución de un Service. Creá dos deployments y expone uno como `ClusterIP`:

   ```bash
   kubectl create deployment api --image=registry.k8s.io/e2e-test-images/agnhost:2.47 \
     -n team-a -- /agnhost netexec --http-port=8080
   kubectl expose deployment api -n team-a --port=80 --target-port=8080
   kubectl create deployment client --image=registry.k8s.io/e2e-test-images/agnhost:2.47 \
     -n team-a -- /agnhost pause
   ```

   ```bash
   # El Service es una IP virtual; los Endpoints/EndpointSlices son los Pods reales detrás
   kubectl get endpointslices -n team-a -l kubernetes.io/service-name=api
   ```

   Salida esperada:

   ```
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS      AGE
   api-x7k2q   IPv4          8080    10.244.1.5     30s
   ```

2. Comprobá conectividad *antes* de aplicar políticas (todo abierto por defecto):

   ```bash
   kubectl exec -n team-a deploy/client -- /agnhost connect --timeout=3s api.team-a.svc.cluster.local:80
   echo "exit=$?"
   ```

   Salida esperada (conexión exitosa, sin salida y `exit=0`):

   ```
   exit=0
   ```

3. Aplicá el patrón *default-deny* de ingreso para todo el namespace, y luego un *allow* selectivo solo desde Pods con la etiqueta `role: client`:

   ```yaml
   # netpol.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: team-a
   spec:
     podSelector: {}          # selecciona TODOS los Pods del namespace
     policyTypes: ["Ingress"]
     # sin reglas 'ingress' => se niega todo el tráfico entrante
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-client-to-api
     namespace: team-a
   spec:
     podSelector:
       matchLabels:
         app: api
     policyTypes: ["Ingress"]
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 role: client
         ports:
           - protocol: TCP
             port: 8080
   ```

   ```bash
   kubectl apply -f netpol.yaml
   # El cliente todavía NO tiene la etiqueta role=client -> debe fallar
   kubectl exec -n team-a deploy/client -- /agnhost connect --timeout=3s api.team-a.svc.cluster.local:80
   echo "exit=$?"
   ```

   Salida esperada (con un CNI que enforcea, la conexión expira):

   ```
   TIMEOUT
   exit=1
   ```

4. Etiquetá al cliente y verificá que el *allow* selectivo lo habilita:

   ```bash
   kubectl label pod -n team-a -l app=client role=client --overwrite
   kubectl exec -n team-a deploy/client -- /agnhost connect --timeout=3s api.team-a.svc.cluster.local:80
   echo "exit=$?"
   ```

   Salida esperada:

   ```
   exit=0
   ```

**Preguntas de verificación (bloque 5):**
- 5a. Una NetworkPolicy `default-deny-ingress` con `podSelector: {}` no rompe el tráfico *saliente* (egress). ¿Por qué, y qué segunda política escribirías para cerrar egress sin dejar sin DNS a los Pods?
- 5b. Las NetworkPolicy son *aditivas* (whitelist): explicá qué significa que "si algún selector permite un flujo, ese flujo se permite" y por qué no existe una regla de "deny" explícita.
- 5c. En el paso 3 la conexión dio `TIMEOUT` en vez de `connection refused`. ¿Qué te dice esa distinción sobre *dónde* se dropeó el paquete?

---

5. Exponé el servicio al exterior. Compará el modelo clásico (Ingress) con Gateway API, la dirección hacia la que la comunidad está migrando (rol-oriented, extensible). Manifiesto de Ingress:

   ```yaml
   # ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: api
     namespace: team-a
   spec:
     ingressClassName: nginx
     rules:
       - host: api.team-a.example.com
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: api
                   port:
                     number: 80
   ```

   Equivalente en Gateway API (separa la infraestructura, `Gateway`, del *routing* que el equipo controla, `HTTPRoute`):

   ```yaml
   # gateway.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: platform-gw
     namespace: infra
   spec:
     gatewayClassName: nginx
     listeners:
       - name: http
         protocol: HTTP
         port: 80
         allowedRoutes:
           namespaces:
             from: All
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: api
     namespace: team-a
   spec:
     parentRefs:
       - name: platform-gw
         namespace: infra
     hostnames: ["api.team-a.example.com"]
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: api
             port: 80
   ```

**Preguntas de verificación (bloque 6):**
- 6a. Enumerá los tres tipos de Service (`ClusterIP`, `NodePort`, `LoadBalancer`) y explicá por qué exponer cada microservicio como `LoadBalancer` es un antipatrón de plataforma frente a un Ingress/Gateway compartido.
- 6b. ¿Qué problema del modelo Ingress (anotaciones propietarias por controlador, un solo dueño del recurso) resuelve la separación `Gateway`/`HTTPRoute` de Gateway API, y por qué eso importa en una organización multi-tenant?

---

## Ejercicio 4 — Integración: golden path con autoscaling y presupuesto de disrupción

**Objetivo:** unir compute + storage + networking en el *golden path* que la plataforma le entrega al equipo, agregando escalado horizontal automático y una garantía de disponibilidad durante mantenimiento.

1. Aplicá un `HorizontalPodAutoscaler` (API `autoscaling/v2`) sobre el deployment `api`, con métricas de CPU y comportamiento de *scale-down* estabilizado para evitar *flapping*:

   ```yaml
   # hpa.yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: api
     namespace: team-a
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: api
     minReplicas: 2
     maxReplicas: 10
     metrics:
       - type: Resource
         resource:
           name: cpu
           target:
             type: Utilization
             averageUtilization: 70
     behavior:
       scaleDown:
         stabilizationWindowSeconds: 300
         policies:
           - type: Percent
             value: 50
             periodSeconds: 60
   ```

   ```bash
   # El HPA necesita que el deployment declare requests.cpu; asegurate de ello
   kubectl set resources deployment/api -n team-a --requests=cpu=100m,memory=128Mi
   kubectl apply -f hpa.yaml
   kubectl get hpa api -n team-a
   ```

   Salida esperada (una vez que metrics-server reporta):

   ```
   NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
   api    Deployment/api   cpu: 3%/70%   2         10        2          45s
   ```

2. Generá carga y observá el escalado hacia arriba:

   ```bash
   kubectl run load -n team-a --image=busybox:1.36 --restart=Never -- \
     /bin/sh -c "while true; do wget -q -O- http://api.team-a.svc.cluster.local/; done"
   kubectl get hpa api -n team-a --watch
   ```

   Salida esperada (las réplicas suben al superar el 70 %):

   ```
   NAME   REFERENCE        TARGETS         REPLICAS
   api    Deployment/api   cpu: 145%/70%   2
   api    Deployment/api   cpu: 145%/70%   4
   api    Deployment/api   cpu: 78%/70%    6
   ```

3. Protegé la disponibilidad durante *node drains* con un `PodDisruptionBudget`. Es la garantía que la plataforma da: "nunca menos de N réplicas listas, aun cuando yo parchee nodos":

   ```yaml
   # pdb.yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: api
     namespace: team-a
   spec:
     minAvailable: 2
     selector:
       matchLabels:
         app: api
   ```

   ```bash
   kubectl apply -f pdb.yaml
   # Simulá un mantenimiento: drenar un worker respeta el PDB
   kubectl drain cnpe-worker2 --ignore-daemonsets --delete-emptydir-data --force
   ```

   Salida esperada (el drain espera / bloquea si violaría el mínimo):

   ```
   evicting pod team-a/api-6c9...
   error when evicting pods/"api-6c9..." -n "team-a" (will retry after 5s):
   Cannot evict pod as it would violate the pod's disruption budget.
   ```

   Volvé a poner el nodo en servicio al terminar:

   ```bash
   kubectl uncordon cnpe-worker2
   ```

**Preguntas de verificación (bloque 7):**
- 7a. El HPA requiere `requests.cpu` declarado. Explicá por qué `averageUtilization` no tiene sentido sin un `request` y cómo interactúa esto con el `LimitRange` del Ejercicio 1.
- 7b. HPA (más Pods), VPA (Pods más grandes) y Cluster Autoscaler/Karpenter (más nodos) operan en tres niveles. Describí un pipeline donde los tres actúan en cascada ante un pico de tráfico, y por qué HPA y VPA sobre la *misma* métrica de CPU entran en conflicto.
- 7c. Un `PDB` con `minAvailable: 2` sobre un deployment de `replicas: 2` puede bloquear indefinidamente un `drain`. ¿Por qué, y cómo lo previene combinar PDB con HPA (o expresar el PDB con `maxUnavailable`)?

---

## Respuestas

<details>
<summary>Ver soluciones y explicaciones</summary>

**1a.** `Capacity` es el total del hardware; `Allocatable` es lo que queda tras `--system-reserved`, `--kube-reserved` y el *eviction threshold* del kubelet. El scheduler agenda contra `Allocatable`, no contra `Capacity`. Si dimensionás node pools asumiendo el `Capacity` completo, sobrevendés el nodo: los Pods entran contablemente pero, bajo carga real, el kubelet dispara *evictions* por presión de memoria/disco y el nodo se vuelve `NotReady`. La regla de plataforma es dimensionar sobre `Allocatable` y dejar *headroom* explícito.

**1b.** QoS `Guaranteed` exige que **cada** contenedor del Pod declare `requests` **y** `limits`, y que para cada recurso (CPU y memoria) `requests == limits`. Es la clase que se desaloja *última* ante presión de memoria y la única elegible para CPU pinning / *static CPU manager policy*; por eso la querés en cargas *latency-sensitive* (bases de datos, ingest en tiempo real): recursos reservados, comportamiento predecible, sin *throttling* sorpresivo por vecinos ruidosos.

**1c.** Obtiene `Burstable` (tiene al menos un `request` pero no cumple la igualdad de `Guaranteed`). El riesgo: sin `limit` de memoria, el contenedor puede consumir toda la memoria del nodo; como es `Burstable`, es candidato a *eviction* antes que un `Guaranteed`, pero antes de ser desalojado puede empujar al nodo a presión de memoria y arrastrar a otros Pods. Por eso el `LimitRange` con `default` (limits) del Ejercicio 1 es una defensa clave: garantiza que ningún Pod quede sin techo.

**2a.** `DoNotSchedule` es una restricción *dura*: si respetar el `maxSkew` es imposible, el Pod queda `Pending`. `ScheduleAnyway` es *blanda*: el scheduler prefiere respetar el skew pero, si no puede, agenda igual. Para un frontend *stateless* crítico querés `DoNotSchedule` por zona (perder una zona no debe tumbar el servicio). Para un job de *reporting* nocturno preferís `ScheduleAnyway`: importa más que corra a que quede perfectamente balanceado.

**2b.** Cuando un Pod nuevo de prioridad alta no encuentra nodo, el scheduler puede *preemptar* (desalojar) Pods de prioridad **menor** en un nodo para hacerle lugar. El de prioridad alta entra; los víctimas de prioridad baja vuelven a la cola (respetando sus PDB en lo posible). Asignar prioridades altas indiscriminadamente destruye la señal: si todo es "crítico", nada lo es, y el sistema vuelve a un desempate arbitrario, además de habilitar *preemption* en cascada que desestabiliza el cluster.

**2c.** `podAntiAffinity` con `requiredDuringScheduling` es binario ("nunca dos réplicas en el mismo dominio"): al escalar más allá del número de dominios, los Pods extra quedan `Pending` para siempre. `topologySpreadConstraints` con `maxSkew` expresa *cuán desbalanceado* tolerás, permitiendo múltiples réplicas por zona mientras el reparto siga siendo parejo — escala con gracia en vez de bloquearse.

**3a.** Con `Retain`, al borrar el PVC el PV pasa a fase `Released` pero **no** se borra: el dato subyacente sobrevive. Queda pendiente el paso manual de recuperar/limpiar el PV (borrar su `claimRef` para reusarlo, o borrarlo explícitamente tras respaldar). `Delete` como default es peligroso porque un `kubectl delete pvc` accidental — o un `helm uninstall` — destruye el volumen y el dato de forma irreversible; la plataforma debería exponer `Retain` (o *snapshots* + `Delete`) para los tiers con datos valiosos.

**3b.** Con `Immediate`, el volumen se provisiona apenas se crea el PVC, **antes** de saber en qué nodo/zona correrá el Pod. En un cluster multi-zona, el volumen puede nacer en `zone-a` mientras el scheduler, por capacidad o afinidad, solo puede ubicar el Pod en `zone-b`; como un volumen zonal no cruza zonas, el Pod queda `Pending` indefinidamente. `WaitForFirstConsumer` difiere el provisioning hasta que el scheduler elige nodo, y crea el volumen en la zona correcta.

**3c.** Un StatefulSet da a cada réplica identidad y almacenamiento *propios y estables*: un `mysql-0` con su disco no debe compartir estado con `mysql-1`. `volumeClaimTemplates` materializa eso (un PVC por ordinal). Un único PVC `ReadWriteMany` compartido implicaría que todas las réplicas escriben el mismo volumen, lo que rompe la mayoría de motores de estado. Access modes: **RWO** (ReadWriteOnce, montable RW por un solo nodo — típico de discos por bloque; el default), **ROX** (ReadOnlyMany, muchos nodos en solo-lectura — p.ej. assets estáticos), **RWX** (ReadWriteMany, muchos nodos RW — requiere NFS/CephFS, p.ej. un *shared upload dir*), **RWOP** (ReadWriteOncePod, RW por un único *Pod* — más estricto que RWO, garantiza exclusividad a nivel Pod).

**4a.** El snapshot lo ejecuta el *mismo* CSI driver que creó el volumen: opera sobre el backend de almacenamiento concreto (EBS, PD, Ceph…). Si el `driver` del `VolumeSnapshotClass` no coincide con el provisioner de la StorageClass origen, el *external-snapshotter* no encuentra un driver capaz de fotografiar ese volumen y el `VolumeSnapshot` queda con `readyToUse: false` / error. No existe un formato de snapshot portable entre drivers a este nivel.

**4b.** *Crash-consistent*: la foto captura el estado del disco como si el sistema se hubiera cortado de golpe — recuperable, pero pueden faltar escrituras en buffers/WAL no *flusheadas*. *Application-consistent*: la aplicación quedó en un estado coherente y quiescente al momento de la foto. Para cerrar la brecha usás *pre/post-freeze hooks*: antes del snapshot, un hook hace `fsfreeze` del filesystem o pone la DB en modo backup (`FLUSH TABLES WITH READ LOCK`, `pg_start_backup`/`CHECKPOINT`); tras disparar el snapshot, un post-hook lo libera. Así el snapshot es restaurable sin *replay* incierto.

**5a.** Una NetworkPolicy solo afecta las direcciones listadas en `policyTypes`. `default-deny-ingress` declara únicamente `Ingress`, así que el egress sigue totalmente abierto. Para cerrar egress agregás una política con `policyTypes: ["Egress"]` y `podSelector: {}` — pero debés permitir explícitamente el DNS, o los Pods no resuelven nombres: un `egress` allow hacia `kube-system`/`kube-dns` en puertos `UDP 53` y `TCP 53`. Omitir eso es el error clásico que "rompe todo" al activar egress default-deny.

**5b.** Aditivas/whitelist significa que el conjunto de flujos permitidos es la *unión* de lo que habilita cada política que selecciona a un Pod. Si al menos una política permite un flujo, ese flujo pasa; ninguna política puede *quitar* lo que otra concede. Por eso no hay regla "deny" explícita: el "deny" se logra por *ausencia* — seleccionás un Pod con una política que no incluye una regla para cierto tráfico, y todo lo no permitido queda implícitamente denegado.

**5c.** `TIMEOUT` (el paquete se *dropea* silenciosamente y el cliente espera hasta expirar) indica que un firewall — la NetworkPolicy enforceada por el CNI — descartó el paquete en la ruta. `connection refused` (RST inmediato) indicaría en cambio que el paquete *llegó* a un host donde nada escuchaba en ese puerto. El timeout confirma que el drop ocurrió en la capa de política de red, no en el destino.

**6a.** `ClusterIP`: IP virtual interna, solo alcanzable dentro del cluster (el default). `NodePort`: abre el mismo puerto alto en *todos* los nodos y lo enruta al Service. `LoadBalancer`: pide al proveedor cloud un balanceador externo (con IP pública) por Service. Un `LoadBalancer` por microservicio es antipatrón porque cada uno cuesta dinero y una IP pública, multiplica la superficie de ataque, y dispersa TLS/routing/observabilidad. Un Ingress/Gateway compartido concentra un único punto de entrada (un solo LB) que hace *host/path routing*, TLS y políticas de forma central.

**6b.** El modelo Ingress mete todo en un recurso cuyo comportamiento avanzado (rewrites, timeouts, auth) depende de *anotaciones propietarias* de cada controlador — no portables y con un único dueño del objeto. Gateway API separa responsabilidades por rol: el equipo de plataforma/infra posee el `Gateway` y el `GatewayClass` (puertos, TLS, qué namespaces pueden colgar rutas), y cada equipo posee sus `HTTPRoute` en su propio namespace. En multi-tenant esto permite *self-service* del routing sin dar acceso a la infraestructura compartida, con un modelo tipado y portable en vez de anotaciones mágicas.

**7a.** El HPA calcula utilización como `uso_actual / requests`. Sin `requests.cpu` no hay denominador y la métrica de `Utilization` es indefinida (el HPA reporta `<unknown>` y no escala). Interactúa con el `LimitRange`: éste garantiza que aunque el desarrollador omita `requests`, el Pod reciba un `defaultRequest` — dándole al HPA una base válida sobre la cual medir. Es decir, la gobernanza del Ejercicio 1 es precondición del autoscaling del Ejercicio 4.

**7b.** Cascada ante un pico: (1) el **HPA** detecta CPU > 70 % y agrega réplicas; (2) las nuevas réplicas no encuentran capacidad y quedan `Pending`; (3) el **Cluster Autoscaler / Karpenter** ve los Pods `Pending` y provisiona nodos nuevos, donde los Pods se agendan. El **VPA** actúa en otra dimensión: ajusta `requests/limits` de cada Pod según su consumo histórico (para *right-sizing*). HPA y VPA sobre la **misma** métrica de CPU entran en conflicto porque ambos reaccionan a ella en direcciones acopladas: el VPA sube los `requests`, lo que baja la utilización calculada, lo que hace al HPA reducir réplicas… un lazo inestable. La práctica recomendada es VPA en memoria + HPA en CPU, o VPA solo en modo `recommendation`.

**7c.** El PDB garantiza `minAvailable: 2`; con `replicas: 2` no hay margen: desalojar cualquiera de los dos violaría el presupuesto, así que el `drain` bloquea indefinidamente (no puede evacuar el nodo sin bajar de 2 disponibles). Se previene de dos formas: (a) combinar con HPA/más réplicas para que `minAvailable` deje margen (p.ej. `replicas` mínimo 3 con `minAvailable: 2`), de modo que siempre haya un Pod sacrificable; o (b) expresar el presupuesto como `maxUnavailable: 1`, que escala con el número de réplicas y siempre permite evacuar de a uno.

</details>

## Fuentes oficiales

- CNCF — CNPE Curriculum: <https://github.com/cncf/curriculum> · TAG App Delivery, *Platform Engineering Maturity Model* y *Platforms White Paper*: <https://tag-app-delivery.cncf.io/whitepapers/platforms/>
- Manejo de recursos y QoS: <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/> · <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/>
- LimitRange / ResourceQuota: <https://kubernetes.io/docs/concepts/policy/limit-range/> · <https://kubernetes.io/docs/concepts/policy/resource-quotas/>
- Topology spread / Priority & Preemption: <https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/> · <https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/>
- StorageClass / PV / dynamic provisioning / snapshots: <https://kubernetes.io/docs/concepts/storage/storage-classes/> · <https://kubernetes.io/docs/concepts/storage/persistent-volumes/> · <https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/> · <https://kubernetes.io/docs/concepts/storage/volume-snapshots/>
- NetworkPolicy / Services / Ingress / Gateway API: <https://kubernetes.io/docs/concepts/services-networking/network-policies/> · <https://kubernetes.io/docs/concepts/services-networking/service/> · <https://kubernetes.io/docs/concepts/services-networking/ingress/> · <https://gateway-api.sigs.k8s.io/>
- Autoscaling / PodDisruptionBudget: <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/> · <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/> · Karpenter: <https://karpenter.sh/>