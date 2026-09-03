# 703.1 — Arquitectura y uso de Kubernetes

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, versión 2.0.0
**Peso del tema:** 6.67
**Nivel:** Avanzado (SRE / Arquitecto de plataforma)
**Base de autoría:** Kubernetes v1.33 (se señalan las afirmaciones que dependen de una versión menor concreta)

---

## 0. Alcance y cómo leer este material

El objetivo cubre la arquitectura de un clúster de Kubernetes, el rol de cada componente del plano de control y de los nodos, el modelo de objetos de la API y la operación cotidiana de un clúster con `kubectl`. El examen espera que *reconozca y razone sobre* los componentes; producción espera que los *diagnostique a las 03:00*. Este documento está escrito para la segunda vara, porque la primera es un subconjunto de ella.

Concretamente, al terminar debe ser capaz de responder sin consultar nada:

- Qué proceso guarda el estado del clúster, qué proceso decide la ubicación, qué proceso hace real esa ubicación y qué proceso hace que el tráfico llegue hasta ahí.
- Qué ocurre exactamente entre que `kubectl apply -f deploy.yaml` devuelve `created` y que un contenedor se ejecuta en un nodo.
- Qué componente se reinicia, y cuál *jamás* debe reiniciarse a ciegas, cuando un clúster está degradado.
- Por qué `kubectl get nodes` dice `NotReady` y cuál de las seis causas plausibles es la real.

Todo lo que sigue es verificable en un clúster real. Cada bloque de terminal es un comando que puede ejecutar.

---

## 1. El problema de producción: por qué existe un orquestador

### 1.1 La línea base imperativa y exactamente dónde se rompe

Antes de la orquestación, un servicio sobre una flota de hosts Linux se desplegaba empujando un artefacto y ejecutando una unidad:

```console
$ ansible -i prod.ini web -m copy -a "src=app-2.14.0.tar.gz dest=/opt/app/"
$ ansible -i prod.ini web -m systemd -a "name=app state=restarted"
web-03 | UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh"}
web-01 | CHANGED => {"changed": true, "name": "app", "state": "started"}
web-02 | CHANGED => {"changed": true, "name": "app", "state": "started"}
```

Esa salida es todo el problema en tres líneas. La ejecución es **disparada por flanco** (*edge-triggered*): describe una transición ("reiniciar ahora"), no un estado deseado. `web-03` se perdió la transición. Nada en el sistema recuerda que `web-03` debería estar ejecutando `2.14.0`. El estado real del clúster ahora diverge de la intención del operador, y el único mecanismo para detectarlo es un humano releyendo el log.

Agregue el resto de producción y el modelo colapsa:

| Requisito | Respuesta imperativa / de gestión de configuración | Modo de fallo |
|---|---|---|
| Un host muere a las 04:12 | Un humano vuelve a ejecutar el playbook, o un autoescalador crea un host y ojalá converja | Tiempo de recuperación = tiempo de respuesta humano |
| Cambios de capacidad | Mapeo host→servicio mantenido a mano | Empaquetado hecho por planilla de cálculo; 30–60 % de capacidad ociosa |
| Actualización progresiva con control de salud | Scripts a medida por servicio | Cada equipo escribe el suyo, todos distintos, todos sutilmente mal |
| Descubrimiento de servicios | Configuración estática, o un clúster Consul aparte | Dos fuentes de verdad que se desincronizan |
| Rotación de configuración/secretos | Empujar archivos, reiniciar | Sin atomicidad, sin rollback, sin traza de auditoría |
| "¿Qué está corriendo realmente en producción?" | SSH y mirar | Irresponsable a escala |

### 1.2 La idea sobre la que está construido Kubernetes: reconciliación disparada por nivel

Kubernetes reemplaza la transición por una **declaración** almacenada en una base de datos durable y observable, más un conjunto de bucles de control independientes que llevan continuamente el estado observado hacia ella:

```
        ┌───────────────────────────────────────────────┐
        │  Desired state (spec)   —  written by humans  │
        │  stored in etcd via the API server            │
        └───────────────────┬───────────────────────────┘
                            │ WATCH
                            ▼
                 ┌──────────────────────┐
                 │  Controller loop     │   for ever:
                 │  observe → diff → act│     current := observe()
                 └───────────┬──────────┘     if current != desired:
                             │                    act()
                             ▼                 write status
        ┌───────────────────────────────────────────────┐
        │  Observed state (status) — written by machines │
        └───────────────────────────────────────────────┘
```

Se siguen dos propiedades, y ambas importan operativamente:

1. **Disparado por nivel, no por flanco.** Un controlador que se pierde un evento igualmente converge en el siguiente resync, porque relee el estado deseado completo en lugar de reproducir un delta. Por eso una caída de un controlador es sobrevivible y por eso Kubernetes tolera watches con pérdidas.
2. **`spec` lo escriben los usuarios; `status` lo escriben los controladores.** Todo objeto obedece esta división. Cuando edita `status` a mano le está mintiendo a un controlador, y él lo va a sobrescribir. Este es el modelo mental más útil para leer cualquier objeto de Kubernetes.

El corolario que sorprende a los recién llegados: **Kubernetes nunca garantiza que se alcance el estado deseado — garantiza que va a seguir intentándolo.** Un Pod `Pending` no es un error; es un bucle de control informando honestamente que todavía no puede satisfacer la declaración. La mayoría de los incidentes de "Kubernetes está roto" son en realidad "un controlador me está diciendo algo que no leí".

### 1.3 Compromisos entre orquestadores

| Dimensión | Kubernetes | Docker Swarm | HashiCorp Nomad | systemd + gestión de configuración |
|---|---|---|---|---|
| Modelo de estado | Declarativo, disparado por nivel, API extensible | Declarativo, conjunto fijo de objetos | Declarativo, centrado en jobs | Imperativo, disparado por flanco |
| Almacén de datos | etcd (Raft), proceso externo | Raft incorporado | Raft incorporado | Ninguno (archivos) |
| Extensibilidad | CRDs + controladores + webhooks de admisión + CRI/CNI/CSI | Prácticamente ninguna | Drivers basados en plugins | Arbitraria, no estructurada |
| Tipos de carga de trabajo | Contenedores, más cualquier cosa que un CRD modele | Contenedores | Contenedores, exec crudo, Java, QEMU | Cualquier cosa |
| Red | Red plana de pods vía CNI, intercambiable | Overlay (incorporada) | Host / bridge / CNI | Red del host |
| Costo operativo | Alto: más de 5 componentes, certificados, etcd, actualizaciones | Bajo | Medio | Bajo por host, alto a escala |
| Ecosistema | El panorama CNCF; habilidades portables | Prácticamente congelado | Pequeño pero coherente | N/A |
| Cuándo es la elección correcta | ≥ 3 equipos, ≥ 20 servicios, o necesita una API de plataforma | Flota pequeña y estática, operaciones mínimas | Cargas mixtas, un solo binario, sin apetito por k8s | Menos de ~5 hosts, un servicio |

El resumen honesto para un arquitecto: Kubernetes le compra una **API programable y uniforme para toda la plataforma**, y le cobra una disciplina operativa entera por ella. Elíjalo cuando la API es el punto. No lo elija para correr tres contenedores.

---

## 2. Anatomía del clúster

### 2.1 El cuadro completo

```
 ┌──────────────────────────── CONTROL PLANE NODE (xN) ──────────────────────────┐
 │                                                                               │
 │   ┌────────────┐     ┌─────────────────────────┐        ┌──────────────────┐  │
 │   │   etcd     │◄───►│     kube-apiserver      │◄──────►│ kube-scheduler   │  │
 │   │ :2379/2380 │     │        :6443            │        │     :10259       │  │
 │   └────────────┘     │  authn→authz→admission  │        └──────────────────┘  │
 │      Raft            │  →validate→persist      │        ┌──────────────────┐  │
 │      quorum          │  the ONLY etcd client   │◄──────►│ kube-controller- │  │
 │                      └───────────┬─────────────┘        │ manager :10257   │  │
 │                                  │                      └──────────────────┘  │
 │                                  │                      ┌──────────────────┐  │
 │                                  │                 ◄───►│ cloud-controller-│  │
 │                                  │                      │ manager (opt.)   │  │
 └──────────────────────────────────┼──────────────────────┴──────────────────┴──┘
                                    │  HTTPS, mTLS, WATCH streams
 ┌──────────────────────────────────┼─────────── WORKER NODE (xN) ───────────────┐
 │                                  ▼                                            │
 │   ┌──────────────┐   CRI    ┌───────────────┐   OCI    ┌────────────────┐     │
 │   │   kubelet    │─────────►│  containerd / │─────────►│ runc / crun /  │     │
 │   │   :10250     │          │    CRI-O      │          │ kata / gVisor  │     │
 │   └──────┬───────┘          └───────────────┘          └────────────────┘     │
 │          │ CNI ADD/DEL            │ CSI NodePublish                            │
 │          ▼                        ▼                                            │
 │   ┌──────────────┐        ┌────────────────┐        ┌────────────────────┐    │
 │   │ CNI plugin   │        │  CSI node dvr  │        │ kube-proxy :10249  │    │
 │   │ (Cilium…)    │        │  (EBS, Ceph…)  │        │ or eBPF replacement│    │
 │   └──────────────┘        └────────────────┘        └────────────────────┘    │
 └───────────────────────────────────────────────────────────────────────────────┘
```

Vale la pena memorizar tres invariantes arquitectónicos, porque la mayoría de los modelos mentales incorrectos violan alguno de ellos:

1. **Solo el API server habla con etcd.** Ningún otro componente tiene un cliente de etcd. Si alguien propone "el scheduler lee etcd directamente", está describiendo otro sistema.
2. **Toda la comunicación es en estrella (hub-and-spoke) a través del API server.** El scheduler no llama al kubelet. El controller manager no llama al scheduler. Se comunican escribiendo objetos que el otro observa. Por eso el API server es el único SPOF verdadero y por eso todos los componentes siguen funcionando (de forma degradada, casi de solo lectura) mientras está caído.
3. **El API server nunca inicia una conexión hacia un nodo en la operación normal.** Las excepciones son `kubectl logs`, `exec`, `attach`, `port-forward` y los webhooks/métricas — apiserver→kubelet:10250 y apiserver→webhook. Todo lo demás es nodo→apiserver. Esto importa para el diseño del firewall.

### 2.2 Componentes del plano de control

| Componente | Responsabilidad | ¿Con estado? | Pierde quórum/líder → | Puerto por defecto | Radio de impacto al reiniciar |
|---|---|---|---|---|---|
| `etcd` | El único estado durable. Consenso Raft. | **Sí** | El clúster queda de solo lectura, luego no disponible | 2379 (cliente), 2380 (par) | **Severo** — reiniciar un solo miembro por vez |
| `kube-apiserver` | Front-end REST, authn/authz/admisión/validación, difusión de watches, el único cliente de etcd | No (cachea) | Nada se puede leer ni escribir; los Pods en ejecución siguen corriendo | 6443 | Moderado — seguro si hay HA; mata los watches abiertos |
| `kube-scheduler` | Asigna `spec.nodeName` a los Pods no planificados | No | Los Pods nuevos quedan `Pending`; los existentes no se ven afectados | 10259 (métricas/salud https) | Bajo |
| `kube-controller-manager` | ~40 bucles de control incorporados (Deployment, ReplicaSet, Node, Endpoint, ServiceAccount, enlazador de PV, …) | No | Nada se autorrepara; no hay ReplicaSets nuevos, ni desalojo de nodos, ni actualización de endpoints | 10257 | Bajo–moderado |
| `cloud-controller-manager` | Bucles específicos de la nube: ciclo de vida del nodo, rutas, servicio LoadBalancer | No | Los servicios LB se estancan; los metadatos del nodo quedan obsoletos | 10258 | Bajo |

Note la asimetría: **perder el scheduler o el controller manager congela el cambio; perder etcd pierde el clúster.** Su esfuerzo de HA pertenece mayormente a etcd.

### 2.3 Componentes del nodo

| Componente | Responsabilidad | Se ejecuta como | Notas |
|---|---|---|---|
| `kubelet` | El agente del nodo. Observa los Pods asignados a su nodo, maneja el CRI, ejecuta las sondas, reporta `NodeStatus`, aplica el desalojo | unidad systemd (**nunca** un Pod) | El único componente que no debe containerizarse — arranca los contenedores |
| Runtime de contenedores | Implementa CRI: descarga de imágenes, ciclo de vida del sandbox y de los contenedores | unidad systemd (`containerd`, `crio`) | Dockershim se eliminó en **v1.24**; Docker Engine solo se puede usar vía `cri-dockerd` |
| `kube-proxy` | Programa el plano de datos para los ClusterIP/NodePort de los Services | DaemonSet (normalmente) | Opcional si el CNI lo reemplaza (Cilium/Calico eBPF) |
| Plugin CNI | Red de pods: IPAM, configuración de veth/interfaces, enrutamiento, NetworkPolicy | DaemonSet + binarios en `/opt/cni/bin` | El kubelet invoca `/opt/cni/bin` usando la configuración de `/etc/cni/net.d` |
| Driver de nodo CSI | Monta volúmenes en el espacio de nombres de montaje del Pod | DaemonSet | Emparejado con un Deployment CSI del lado del controlador |

Los nodos del plano de control ejecutan *todos* los componentes de nodo también — el plano de control en sí se entrega como **static Pods** gestionados por el kubelet desde `/etc/kubernetes/manifests`. Ese es el truco de arranque: el kubelet no necesita un API server para ejecutar esos Pods, así que el API server puede ser un Pod.

```console
$ ls -1 /etc/kubernetes/manifests/
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml

$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED       STATE     NAME             ATTEMPT  POD ID         POD
1f0c9b1a4d2e7  4a1f3c8b9d21   3 weeks ago   Running   kube-apiserver   0        9a7d3e1b0c4f5  kube-apiserver-cp-1
```

Un static Pod se identifica del lado de la API por su **mirror Pod**: de solo lectura, con nombre `<pod>-<nodename>`, e imposible de borrar vía la API — borre el archivo de manifiesto en su lugar.

### 2.4 De punta a punta: qué dispara realmente `kubectl apply`

Esta secuencia es lo más examinable y lo más útil operativamente de todo el objetivo.

1. **`kubectl`** lee `~/.kube/config`, resuelve el contexto → URL del clúster + credenciales, convierte el YAML a JSON y emite `POST /apis/apps/v1/namespaces/prod/deployments` (o `PATCH` con `?fieldManager=kubectl&force=…` para server-side apply).
2. **kube-apiserver — autenticación.** El certificado de cliente / token bearer / token de ID OIDC se mapea a un nombre de usuario y grupos. Fallo → `401`.
3. **Autorización.** RBAC (habitualmente) evalúa `verb=create, group=apps, resource=deployments, namespace=prod`. Fallo → `403` con la regla exacta que faltaba.
4. **Admisión mutante.** Los plugins incorporados y luego los `MutatingAdmissionWebhook` pueden reescribir el objeto: valores por defecto, inyección de sidecars, proyección del token de `ServiceAccount`.
5. **Validación de esquema y aplicación de valores por defecto**, luego **admisión validante** (`ValidatingAdmissionWebhook`, `ValidatingAdmissionPolicy` / CEL, `ResourceQuota`).
6. **Persistencia en etcd** como protobuf, bajo `/registry/deployments/prod/web`. La escritura devuelve un nuevo `resourceVersion`.
7. **El controlador de Deployment** (en kube-controller-manager) ve el evento ADDED en su watch y crea un **ReplicaSet** con un `ownerReference` que apunta al Deployment y una etiqueta `pod-template-hash`.
8. **El controlador de ReplicaSet** ve que su ReplicaSet tiene 0/3 Pods y crea 3 Pods con `spec.nodeName` vacío.
9. **kube-scheduler** observa los Pods sin `nodeName`, ejecuta **filtrado → puntuación**, y escribe un subrecurso `Binding` que fija `spec.nodeName`.
10. **El kubelet del nodo elegido** ve un Pod asignado a sí mismo. Llama al CRI para crear el **sandbox** (el contenedor pause: mantiene los espacios de nombres de red e IPC), invoca el `ADD` del **CNI** para obtener una IP, llama a **CSI** para montar volúmenes, descarga imágenes, luego arranca los contenedores init y luego los contenedores de la aplicación.
11. **El kubelet** escribe `status.podIP`, `status.phase` y los estados de los contenedores de vuelta al API server.
12. **El controlador de EndpointSlice** ve un Pod Ready que coincide con el selector de un Service y lo agrega a un `EndpointSlice`.
13. **kube-proxy** en cada nodo ve el cambio del EndpointSlice y reprograma iptables/IPVS/nftables para que el ClusterIP del Service balancee hacia la nueva IP del Pod.

Trece pasos, seis procesos independientes, **cero llamadas directas entre ellos**. Cada flecha es un watch sobre el API server. Interiorice esto y depurar un clúster se convierte en "cuál de estos trece pasos se detuvo, y qué dice el log de ese componente".

---

## 3. El API server en profundidad

### 3.1 El modelo de recursos

Todo es un recurso REST direccionado como `/apis/<group>/<version>/namespaces/<ns>/<resource>/<name>`, con el grupo core heredado en `/api/v1/...` (sin nombre de grupo — un artefacto histórico que simplemente hay que recordar).

```console
$ kubectl api-resources --sort-by=name | head -20
NAME                     SHORTNAMES   APIVERSION                       NAMESPACED   KIND
bindings                              v1                               true         Binding
certificatesigningrequests csr         certificates.k8s.io/v1           false        CertificateSigningRequest
configmaps               cm           v1                               true         ConfigMap
controllerrevisions                   apps/v1                          true         ControllerRevision
cronjobs                 cj           batch/v1                         true         CronJob
csidrivers                            storage.k8s.io/v1                false        CSIDriver
daemonsets               ds           apps/v1                          true         DaemonSet
deployments              deploy       apps/v1                          true         Deployment
endpoints                ep           v1                               true         Endpoints
endpointslices                        discovery.k8s.io/v1              true         EndpointSlice
events                   ev           events.k8s.io/v1                 true         Event
horizontalpodautoscalers hpa          autoscaling/v2                   true         HorizontalPodAutoscaler
ingresses                ing          networking.k8s.io/v1             true         Ingress
jobs                                  batch/v1                         true         Job
leases                                coordination.k8s.io/v1           true         Lease
namespaces               ns           v1                               false        Namespace
networkpolicies          netpol       networking.k8s.io/v1             true         NetworkPolicy
nodes                    no           v1                               false        Node
persistentvolumeclaims   pvc          v1                               true         PersistentVolumeClaim
persistentvolumes        pv           v1                               false        PersistentVolume
```

`kubectl explain` se sirve desde el documento OpenAPI del clúster en vivo, así que siempre es correcto para *ese* clúster — incluidos los CRDs. Úselo en lugar de la documentación web:

```console
$ kubectl explain deployment.spec.strategy.rollingUpdate.maxUnavailable
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: maxUnavailable <IntOrString>

DESCRIPTION:
    The maximum number of pods that can be unavailable during the update.
    Value can be an absolute number (ex: 5) or a percentage of desired pods
    (ex: 10%). Absolute number is calculated from percentage by rounding down.
```

**Versión de almacenamiento vs versiones servidas.** Un objeto se almacena en etcd en exactamente una versión; el API server convierte al leer a la versión servida que usted pidió. Por eso la desaparición de `apps/v1beta1` no corrompió datos — y por eso `kubectl get deploy -o yaml` muestra `apps/v1` sin importar qué aplicó.

### 3.2 El pipeline de peticiones, y dónde mueren las peticiones

```
client
  │
  ▼ TLS (client cert / token / OIDC)
[ Authentication ]────────────────► 401 Unauthorized
  │  user=alice groups=[dev, system:authenticated]
  ▼
[ Authorization ] (RBAC → Node → Webhook, first ALLOW wins)
  │                                ► 403 Forbidden
  ▼
[ Mutating admission ]  built-ins → MutatingAdmissionWebhooks
  │                                ► 500 / webhook timeout
  ▼
[ Object schema validation + defaulting ]
  │                                ► 422 Unprocessable / 400
  ▼
[ Validating admission ] ValidatingAdmissionPolicy (CEL) → webhooks → quota
  │                                ► 403 (denied by policy/quota)
  ▼
[ etcd write ]                     ► 409 Conflict (resourceVersion mismatch)
  │
  ▼ 201 Created
```

De este diagrama se desprenden dos reglas operativas:

- **Un webhook de admisión que falla puede dejar inservible todo el clúster.** Un webhook con `failurePolicy: Fail` cuyos Pods de respaldo están caídos va a rechazar justamente las peticiones necesarias para arreglarlo. Acote siempre los webhooks con `namespaceSelector`/`objectSelector` y excluya `kube-system`.
- **El `403` le dice qué regla faltaba.** Lea el mensaje; no adivine.

```console
$ kubectl auth can-i create deployments --namespace prod --as jane
no - no RBAC policy matched

$ kubectl auth can-i --list --namespace prod --as jane | head -6
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
pods                                            []                  []               [get list watch]
configmaps                                      []                  []               [get list watch]
```

### 3.3 Watch, `resourceVersion` y concurrencia optimista

Los controladores no hacen polling. Hacen un `LIST` una vez para construir una caché, luego un `WATCH` desde el `resourceVersion` devuelto y consumen un flujo de eventos ADDED/MODIFIED/DELETED. Este es el mecanismo que hace factible un clúster de 5000 nodos.

```console
$ kubectl get --raw '/api/v1/namespaces/prod/pods?watch=1&resourceVersion=48210332' | head -2
{"type":"MODIFIED","object":{"kind":"Pod","apiVersion":"v1","metadata":{"name":"web-7d9f6c8b5-2xk4t","resourceVersion":"48210377",...
{"type":"ADDED","object":{"kind":"Pod","apiVersion":"v1","metadata":{"name":"web-7d9f6c8b5-9plmz","resourceVersion":"48210381",...
```

Cada objeto lleva un `metadata.resourceVersion`, una revisión opaca de etcd. Las actualizaciones son **optimistamente concurrentes**: un `PUT` con un `resourceVersion` obsoleto devuelve `409 Conflict`, y el cliente debe releer y reintentar. Por eso ve esto y por eso *no* es un error:

```console
$ kubectl edit deployment web -n prod
error: deployments.apps "web" could not be patched: Operation cannot be fulfilled on deployments.apps "web": the object has been modified; please apply your changes to the latest version and try again
```

Un `410 Gone` en un watch significa que el `resourceVersion` solicitado fue compactado en etcd; el cliente debe volver a hacer LIST. Un clúster que emite `410` constantes desde los controladores le está diciendo que la compactación de etcd es demasiado agresiva o que los controladores son demasiado lentos.

### 3.4 API Priority and Fairness

APF (GA desde **v1.29**) reemplazó al tosco `--max-requests-inflight` con encolado por nivel de prioridad, de modo que un cliente que se porta mal no pueda dejar sin recursos a los propios bucles del plano de control.

```console
$ kubectl get flowschemas
NAME                           PRIORITYLEVEL     MATCHINGPRECEDENCE   DISTINGUISHERMETHOD   AGE
exempt                         exempt            1                    <none>                61d
probes                         exempt            2                    <none>                61d
system-leader-election         leader-election   100                  ByUser                61d
workload-leader-election       leader-election   200                  ByUser                61d
system-node-high               node-high         400                  ByUser                61d
system-nodes                   system            500                  ByUser                61d
kube-controller-manager        workload-high     800                  ByNamespace           61d
kube-scheduler                 workload-high     800                  ByNamespace           61d
service-accounts               workload-low      9000                 ByUser                61d
global-default                 global-default    9900                 ByUser                61d
catch-all                      catch-all         10000                ByUser                61d

$ kubectl get --raw /metrics | grep apiserver_flowcontrol_rejected_requests_total | head -3
apiserver_flowcontrol_rejected_requests_total{flow_schema="global-default",priority_level="global-default",reason="queue-full"} 0
apiserver_flowcontrol_rejected_requests_total{flow_schema="service-accounts",priority_level="workload-low",reason="queue-full"} 147
apiserver_flowcontrol_rejected_requests_total{flow_schema="catch-all",priority_level="catch-all",reason="time-out"} 0
```

Un cliente al que se le aplica limitación recibe `429 Too Many Requests` con un `Retry-After`. Las 147 rechazadas en `workload-low` de arriba son un hallazgo real: alguna ServiceAccount está martillando el API server, y la encuentra con `apiserver_request_total` por `user_agent`.

### 3.5 Endpoints de salud — el reemplazo moderno de `componentstatuses`

`kubectl get componentstatuses` está obsoleto y miente en clústeres HA (solo revisa los endpoints locales). Use los endpoints de salud:

```console
$ kubectl get --raw '/livez?verbose'
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
[+]poststarthook/priority-and-fairness-config-consumer ok
[+]poststarthook/start-cluster-authentication-info-controller ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/apiservice-registration-controller ok
[+]autoregister-completion ok
livez check passed

$ kubectl get --raw '/readyz?verbose' | tail -4
[+]shutdown ok
[+]etcd-readiness ok
[+]informer-sync ok
readyz check passed
```

- `/livez` — "¿hay que reiniciar este proceso?" Conéctelo a la sonda de liveness del kubelet.
- `/readyz` — "¿debería esta instancia recibir tráfico?" Conéctelo al balanceador de carga.
- `/healthz` — agregado obsoleto de ambos.

El scheduler y el controller-manager exponen lo mismo en sus puertos seguros:

```console
$ curl -sk https://127.0.0.1:10259/healthz ; echo
ok
$ curl -sk https://127.0.0.1:10257/healthz ; echo
ok
```

---

## 4. etcd — lo único que realmente puede perder

### 4.1 Consenso, quórum y el costo de una escritura

etcd es un almacén clave-valor fuertemente consistente que usa **Raft**. Un miembro es el líder; todas las escrituras pasan por él y solo se confirman una vez que un **quórum** (mayoría) ha persistido la entrada en su write-ahead log — lo que implica un `fsync` en cada miembro del quórum. **La latencia de escritura de etcd es la latencia de fsync del disco**, y por eso etcd sobre almacenamiento de red o sobre un disco compartido ocupado destruye un clúster.

| Miembros | Quórum necesario | Fallos tolerados | Veredicto |
|---|---|---|---|
| 1 | 1 | 0 | Solo desarrollo |
| 2 | 2 | 0 | **Peor que 1** — nunca haga esto |
| 3 | 2 | 1 | La elección estándar de producción |
| 4 | 3 | 1 | Misma tolerancia que 3, más latencia de escritura |
| 5 | 3 | 2 | Clústeres grandes/críticos |
| 7 | 4 | 3 | Rara vez justificado; la latencia de escritura crece |

Los recuentos pares de miembros son estrictamente peores que el número impar inmediatamente inferior: la misma tolerancia a fallos, más coordinación. Siempre impar.

### 4.2 Inspeccionar etcd

A `etcdctl` hay que darle certificados de cliente; en un clúster kubeadm están en `/etc/kubernetes/pki/etcd/`.

```console
$ sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status --cluster --write-out=table
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|         ENDPOINT          |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| https://10.10.0.10:2379   | 8e9e05c52164694d |   3.5.15|  212 MB |     false |      false |        14 |   48210401 |           48210401 |        |
| https://10.10.0.11:2379   | 91bc3c398fb3c146 |   3.5.15|  212 MB |      true |      false |        14 |   48210401 |           48210401 |        |
| https://10.10.0.12:2379   | fd422379fda50e48 |   3.5.15|  213 MB |     false |      false |        14 |   48210401 |           48210401 |        |
+---------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+

$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health --cluster --write-out=table
+--------------------------+--------+-------------+-------+
|         ENDPOINT         | HEALTH |    TOOK     | ERROR |
+--------------------------+--------+-------------+-------+
| https://10.10.0.11:2379  |   true | 9.114231ms  |       |
| https://10.10.0.10:2379  |   true | 10.882712ms |       |
| https://10.10.0.12:2379  |   true | 11.409885ms |       |
+--------------------------+--------+-------------+-------+
```

Lea esa tabla como un SRE:

- **`RAFT INDEX` divergiendo** entre miembros = un miembro está rezagado o particionado.
- **`RAFT TERM` incrementándose** repetidamente = las elecciones de líder están oscilando, casi siempre por latencia de disco o de red.
- **`DB SIZE` creciendo sin límite** = la compactación/desfragmentación no da abasto. La cuota por defecto es 2 GiB; superarla pone al clúster en una **alarma de solo lectura** y el API server empieza a fallar cada escritura con `etcdserver: mvcc: database space exceeded`.

### 4.3 Copia de seguridad y restauración

Este es el único procedimiento del que todo operador de clúster debe tener memoria muscular.

```console
$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/backups/etcd-$(date +%F-%H%M).db
{"level":"info","ts":"2026-09-03T11:58:02.441Z","caller":"snapshot/v3_snapshot.go:65","msg":"created temporary db file","path":"/var/backups/etcd-2026-09-03-1158.db.part"}
{"level":"info","ts":"2026-09-03T11:58:04.902Z","caller":"snapshot/v3_snapshot.go:75","msg":"fetched snapshot","took":"2.451s"}
Snapshot saved at /var/backups/etcd-2026-09-03-1158.db

$ sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/backups/etcd-2026-09-03-1158.db
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 7b4c2f91 | 48210401 |      14872 |     212 MB |
+----------+----------+------------+------------+
```

Procedimiento de restauración (destructivo, ejecutar en cada nodo del plano de control):

```console
$ sudo mv /etc/kubernetes/manifests/*.yaml /tmp/manifests-parked/    # stops static pods
$ sudo systemctl stop kubelet
$ sudo mv /var/lib/etcd /var/lib/etcd.bak
$ sudo ETCDCTL_API=3 etcdctl snapshot restore /var/backups/etcd-2026-09-03-1158.db \
    --data-dir=/var/lib/etcd \
    --name=cp-1 \
    --initial-cluster=cp-1=https://10.10.0.10:2380,cp-2=https://10.10.0.11:2380,cp-3=https://10.10.0.12:2380 \
    --initial-advertise-peer-urls=https://10.10.0.10:2380
$ sudo mv /tmp/manifests-parked/*.yaml /etc/kubernetes/manifests/
$ sudo systemctl start kubelet
```

La trampa que atrapa a la gente: **una restauración de snapshot reescribe el ID de miembro y el ID de clúster**, así que un miembro restaurado no puede unirse a los miembros sobrevivientes. Se restaura el clúster *entero* desde un snapshot, no un solo miembro. Note además que los *datos* de los PersistentVolume no están en etcd — restaurar etcd a una revisión anterior mientras los volúmenes siguieron adelante produce un clúster que cree cosas sobre el almacenamiento que ya no son ciertas.

---

## 5. kube-scheduler

### 5.1 Dos fases, una decisión

Para cada Pod que se saca de la cola de planificación:

1. **Filtrado (predicados)** — eliminar los nodos que *no pueden* ejecutar el Pod: CPU/memoria asignable insuficiente, taints no tolerados, selectores/afinidad de nodo sin coincidencia, conflicto de zona de volumen, conflicto de puertos, nodo no planificable.
2. **Puntuación (prioridades)** — clasificar a los sobrevivientes de 0 a 100 por plugin, ponderar y sumar. Los valores por defecto favorecen la distribución entre nodos/zonas, la asignación equilibrada de CPU-memoria, la localidad de imágenes y la afinidad entre pods.
3. **Reserve → Permit → Bind** — escribir un `Binding` que fija `spec.nodeName`.

El **scheduling framework** expone estos como puntos de extensión ordenados: `PreEnqueue`, `QueueSort`, `PreFilter`, `Filter`, `PostFilter`, `PreScore`, `Score`, `NormalizeScore`, `Reserve`, `Permit`, `PreBind`, `Bind`, `PostBind`. Los schedulers personalizados son plugins en estos puntos, no forks.

En `PostFilter` es donde ocurre la **preempción**: si ningún nodo pasa el filtrado, el scheduler busca un nodo donde desalojar Pods con menor `priorityClassName` haría lugar, y marca a las víctimas para su eliminación ordenada.

### 5.2 Una configuración completa del scheduler

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: /etc/kubernetes/scheduler.conf
leaderElection:
  leaderElect: true
  resourceNamespace: kube-system
  resourceName: kube-scheduler
percentageOfNodesToScore: 50
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: PodTopologySpread
        args:
          defaultingType: System
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: LeastAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 1
    plugins:
      score:
        enabled:
          - name: NodeResourcesFit
            weight: 2
          - name: PodTopologySpread
            weight: 4
        disabled:
          - name: ImageLocality
  - schedulerName: bin-packing-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: MostAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 3
```

Dos perfiles en un solo proceso: las cargas que fijan `spec.schedulerName: bin-packing-scheduler` obtienen empaquetado denso (bueno para batch, ahorra nodos), todo lo demás obtiene distribución (bueno para disponibilidad). Esta es la palanca estándar para el compromiso entre disponibilidad y costo.

`percentageOfNodesToScore: 50` es la palanca para clústeres grandes: el scheduler deja de filtrar una vez que encontró suficientes nodos factibles, cambiando optimalidad de ubicación por rendimiento.

### 5.3 Observar una decisión de planificación

```console
$ kubectl get events -n prod --field-selector reason=FailedScheduling
LAST SEEN   TYPE      REASON             OBJECT                        MESSAGE
2m14s       Warning   FailedScheduling   pod/analytics-6b8f9d4c7-vzq2n  0/6 nodes are available: 2 Insufficient cpu, 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }, 3 node(s) didn't match Pod's node affinity/selector. preemption: 0/6 nodes are available: 2 No preemption victims found for incoming pod, 4 Preemption is not helpful for scheduling.
```

Ese mensaje es un diagnóstico completo: enumera cada nodo y el predicado exacto que lo rechazó, y luego informa si la preempción podría ayudar. Léalo literalmente y la solución es obvia — aquí, o relaja la afinidad o agrega capacidad a los dos nodos que coinciden.

---

## 6. El patrón de controlador y kube-controller-manager

### 6.1 Anatomía de un controlador

Todo controlador — incorporado o su propio operador — tiene la misma forma:

```
  Reflector ──LIST+WATCH──► API server
      │
      ▼ push
  DeltaFIFO ──► Informer ──► Indexer (thread-safe local cache)
                   │
                   ▼ ResourceEventHandler (add/update/delete)
              Workqueue (rate-limited, deduplicating, per-key)
                   │
                   ▼
              Worker: syncHandler(namespace/name)
                   │  read desired from cache, read actual, diff, act
                   ▼
              API writes (create/update/patch status)
```

Las consecuencias que vale la pena conocer:

- **La workqueue deduplica por clave.** Cien eventos para el mismo objeto colapsan en una sola reconciliación. Por eso los controladores sobreviven a las tormentas de eventos.
- **La reconciliación es idempotente y lee el estado completo.** Nunca confía en la carga útil del evento.
- **Reintentos con limitación de tasa y retroceso exponencial** ante error, y por eso una reconciliación que falla aparece como líneas de log cada vez más escasas, no como un bucle apretado.
- **`--concurrent-deployment-syncs` y afines** son las perillas cuando la reconciliación se retrasa en un clúster grande.

### 6.2 Elección de líder

Solo una réplica del controller manager y del scheduler está activa a la vez. Compiten por un objeto `Lease`:

```console
$ kubectl get lease -n kube-system kube-controller-manager -o yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  holderIdentity: cp-2_3f9a1e0c-77b4-4f6d-9a2e-1c8b5d0e4a13
  leaseDurationSeconds: 15
  acquireTime: "2026-09-01T08:14:22.000000Z"
  renewTime: "2026-09-03T11:59:41.882000Z"
  leaseTransitions: 3
```

`leaseTransitions: 3` significa que el liderazgo cambió tres veces — normal después de actualizaciones, alarmante si crece cada hora (apunta a latencia del API server o a un nodo del plano de control saturado). El mismo mecanismo de `Lease` respalda los **heartbeats de nodo** en `kube-node-lease`, y por eso los heartbeats son lo bastante baratos para miles de nodos.

### 6.3 Propiedad y recolección de basura

Los controladores enlazan objetos con `ownerReferences`. Esto es lo que hace que `kubectl delete deployment web` elimine los ReplicaSets y los Pods sin que el controlador de Deployment lo haga explícitamente:

```console
$ kubectl get rs -n prod web-7d9f6c8b5 -o jsonpath='{.metadata.ownerReferences}' | jq
[
  {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "name": "web",
    "uid": "b1d9f0a3-5c2e-4a77-9f31-8d0c6e2b4a19",
    "controller": true,
    "blockOwnerDeletion": true
  }
]
```

Políticas de propagación de borrado: `Background` (por defecto — el propietario se borra de inmediato, los dependientes se limpian de forma asíncrona), `Foreground` (el propietario permanece en estado `deletionTimestamp` hasta que los dependientes desaparecen), `Orphan` (los dependientes sobreviven). `--cascade=orphan` es la forma segura de reemplazar un Deployment sin reiniciar sus Pods.

Los **finalizers** son la trampa relacionada: un objeto con `metadata.finalizers` no se eliminará de etcd hasta que su controlador limpie cada finalizer. Un namespace atascado en `Terminating` durante horas es casi siempre un finalizer cuyo controlador ya no existe.

```console
$ kubectl get ns legacy -o jsonpath='{.spec.finalizers}{"\n"}{.status.conditions[?(@.type=="NamespaceFinalizersRemaining")].message}{"\n"}'
["kubernetes"]
Some content in the namespace has finalizers remaining: monitoring.coreos.com/prometheus in 1 resource instances
```

---

## 7. kubelet

### 7.1 Qué hace realmente

El kubelet es el único componente que convierte objetos de la API en procesos en ejecución. Sus responsabilidades:

- Observar los Pods donde `spec.nodeName == <this node>` (más los static Pods desde disco y, opcionalmente, un endpoint HTTP).
- Manejar el CRI: `RunPodSandbox`, `PullImage`, `CreateContainer`, `StartContainer`.
- Llamar al CNI para conectar el sandbox a la red de pods; llamar a CSI para montar volúmenes.
- Ejecutar las sondas de liveness/readiness/startup y actuar en consecuencia (reiniciar / quitar de los endpoints).
- Reportar `NodeStatus` y renovar el `Lease` del nodo cada 10 s.
- Aplicar el **desalojo por presión de nodo** y gestionar cgroups, clases de QoS y puntajes de OOM.
- Servir `logs`, `exec`, `attach`, `port-forward` y los endpoints de estadísticas en el puerto 10250.

**PLEG** (Pod Lifecycle Event Generator) relista periódicamente los contenedores del runtime para detectar cambios de estado que el runtime no reportó. `PLEG is not healthy: pleg was last seen active 3m52s ago` en el log del kubelet es un síntoma canónico de un runtime de contenedores trabado, no del kubelet.

### 7.2 Una KubeletConfiguration de producción

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
serverTLSBootstrap: true
rotateCertificates: true
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
maxPods: 110
podsPerCore: 0
nodeStatusUpdateFrequency: 10s
nodeStatusReportFrequency: 5m
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
enforceNodeAllocatable:
  - pods
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
evictionSoft:
  memory.available: "1Gi"
  nodefs.available: "15%"
evictionSoftGracePeriod:
  memory.available: "1m30s"
  nodefs.available: "2m"
evictionMaxPodGracePeriod: 60
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
serializeImagePulls: false
maxParallelImagePulls: 5
protectKernelDefaults: true
readOnlyPort: 0
```

La línea `cgroupDriver` no es cosmética. **El kubelet y el runtime de contenedores deben coincidir**; si el kubelet dice `systemd` y containerd dice `cgroupfs`, obtiene dos jerarquías de cgroups, contabilidad de recursos poco confiable y nodos que oscilan bajo carga. En cualquier distribución moderna con systemd, ambos deben ser `systemd`.

`systemReserved` + `kubeReserved` + `evictionHard` se restan de la capacidad para dar el **allocatable**. Omitirlos es la causa número uno de nodos que mueren bajo presión de memoria: el kubelet y sshd son eliminados por OOM junto con la carga de trabajo, y usted pierde el nodo en lugar de un Pod.

```console
$ kubectl describe node worker-03 | sed -n '/^Capacity:/,/^System Info:/p'
Capacity:
  cpu:                16
  ephemeral-storage:  103890480Ki
  hugepages-2Mi:      0
  memory:             65806300Ki
  pods:               110
Allocatable:
  cpu:                15
  ephemeral-storage:  95723312Ki
  hugepages-2Mi:      0
  memory:             63185884Ki
  pods:               110
```

### 7.3 Clases de QoS — cómo el desalojo elige víctimas

| Clase de QoS | Condición | Ajuste de puntaje OOM | Desalojado |
|---|---|---|---|
| `Guaranteed` | Cada contenedor fija `requests == limits` para **ambos**, cpu y memoria | −997 | Último |
| `Burstable` | Al menos un request fijado, pero no igual a los limits | 2 … 999 (escalado por el request) | Segundo |
| `BestEffort` | Sin requests ni limits en ningún lado | 1000 | **Primero** |

Bajo presión de memoria del nodo, el kubelet ordena los Pods por clase de QoS, luego por cuánto excede el uso a los requests, y luego por la prioridad del Pod. Los Pods `BestEffort` en un nodo de producción son una caída autoinfligida esperando un pico de tráfico.

---

## 8. Red: el modelo y los modos de kube-proxy

### 8.1 Las cuatro reglas del modelo de red de Kubernetes

1. Cada Pod obtiene su propia dirección IP enrutable.
2. Los Pods de cualquier nodo pueden alcanzar a los Pods de cualquier nodo **sin NAT**.
3. Los agentes de un nodo (kubelet, demonios) pueden alcanzar a todos los Pods de ese nodo.
4. La IP que un Pod ve de sí mismo es la IP que otros usan para alcanzarlo.

Kubernetes no implementa *nada* de esto. Lo hace un **plugin CNI**. Por eso un clúster recién creado tiene nodos `NotReady` y Pods de CoreDNS `Pending` hasta que instala uno.

Hay tres espacios de direcciones separados, y confundirlos causa la mayoría de los incidentes de red:

| Espacio | Rango típico | Asignado por | ¿Enrutable fuera del clúster? |
|---|---|---|---|
| Red de nodos | Su LAN/VPC | Su infraestructura | Sí |
| CIDR de pods | `10.244.0.0/16` | IPAM del CNI, subdividido por nodo | Solo si el CNI está en modo enrutado |
| CIDR de servicios (ClusterIP) | `10.96.0.0/12` | kube-apiserver | **No — estas IPs son virtuales y existen solo como reglas del plano de datos** |

Un ClusterIP no responde a ping y no tiene interfaz. Es una regla en iptables/IPVS/nftables/eBPF, en cada nodo.

### 8.2 Comparación de los modos de kube-proxy

| Modo | Mecanismo | Complejidad de reglas | Costo de actualización con 10 000 servicios | Algoritmos de LB | Notas |
|---|---|---|---|---|---|
| `iptables` | Cadenas de `KUBE-SVC-*` / `KUBE-SEP-*` con el módulo statistic | Coincidencia lineal O(n) | O(n) — reescritura completa de la tabla, segundos de latencia | Solo aleatorio | Por defecto durante años; se degrada mal por encima de unos pocos miles de servicios |
| `ipvs` | Balanceador de carga L4 del kernel, tabla hash | Búsqueda O(1) | Incremental, milisegundos | rr, wrr, lc, wlc, sh, dh, sed, nq | Requiere los módulos `ip_vs`; sigue usando algo de iptables para masquerade/NodePort |
| `nftables` | Sets y maps nativos de nftables | O(1) vía verdict maps | Incremental | Aleatorio | Alpha en v1.29, beta en v1.31, **GA en v1.33**; el sucesor previsto del modo `iptables` |
| `kernelspace` | HNS/VFP de Windows | — | — | — | Solo nodos Windows |
| *(reemplazo eBPF)* | Cilium/Calico reemplazan por completo a kube-proxy | Mapas eBPF O(1) | Incremental | Maglev/aleatorio | **No es un modo de kube-proxy** — kube-proxy se elimina; además da DSR y mejor observabilidad |

```console
$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^(mode|ipvs:)' -A3
mode: "ipvs"
ipvs:
  excludeCIDRs: null
  minSyncPeriod: 0s
  scheduler: "rr"

$ sudo ipvsadm -Ln | head -12
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.0.1:443 rr
  -> 10.10.0.10:6443              Masq    1      4          0
  -> 10.10.0.11:6443              Masq    1      3          0
  -> 10.10.0.12:6443              Masq    1      5          0
TCP  10.96.0.10:53 rr
  -> 10.244.1.7:53                Masq    1      0          0
  -> 10.244.2.9:53                Masq    1      0          0
TCP  10.98.14.201:80 rr
  -> 10.244.3.15:8080             Masq    1      12         3
  -> 10.244.4.22:8080             Masq    1      11         4
```

Para el equivalente en `iptables`:

```console
$ sudo iptables -t nat -L KUBE-SERVICES -n | head -8
Chain KUBE-SERVICES (2 references)
target     prot opt source     destination
KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  0.0.0.0/0  10.96.0.1      /* default/kubernetes:https cluster IP */ tcp dpt:443
KUBE-SVC-TCOU7JCQXEZGVUNU  udp  --  0.0.0.0/0  10.96.0.10     /* kube-system/kube-dns:dns cluster IP */ udp dpt:53
KUBE-SVC-ERIFXISQEP7F7OF4  tcp  --  0.0.0.0/0  10.96.0.10     /* kube-system/kube-dns:dns-tcp cluster IP */ tcp dpt:53
KUBE-SVC-XGLOHA7QRQ3V22RZ  tcp  --  0.0.0.0/0  10.98.14.201   /* prod/web:http cluster IP */ tcp dpt:80
```

### 8.3 DNS del clúster

CoreDNS se ejecuta como un Deployment, expuesto por el Service `kube-dns` en la décima dirección del CIDR de servicios por convención. El kubelet lo inyecta en el `/etc/resolv.conf` de cada Pod:

```console
$ kubectl run -it --rm dnstest --image=busybox:1.36 --restart=Never -- cat /etc/resolv.conf
search prod.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

`ndots:5` significa que cualquier nombre con menos de 5 puntos se prueba primero contra cada dominio de búsqueda — así que `api.example.com` genera cuatro consultas fallidas antes de la correcta. En cargas intensivas en DNS esto es un problema medible de latencia y QPS; la solución es un punto final (`api.example.com.`) o un `dnsConfig` por Pod con un `ndots` menor.

El esquema de FQDN que debe saber de memoria: `<service>.<namespace>.svc.<cluster-domain>`, y para servicios headless `<pod-hostname>.<service>.<namespace>.svc.<cluster-domain>`.

---

## 9. Runtime de contenedores y CRI

El kubelet habla **CRI**, una API gRPC sobre un socket Unix, dividida en `RuntimeService` e `ImageService`. Docker Engine nunca implementó CRI; el kubelet llevaba un adaptador llamado dockershim, que fue **eliminado en v1.24**.

| Runtime | CRI nativo | Socket | Posicionamiento |
|---|---|---|---|
| `containerd` | Sí (plugin CRI) | `/run/containerd/containerd.sock` | El valor por defecto casi en todas partes; proyecto CNCF graduado |
| `CRI-O` | Sí (construido solo para Kubernetes) | `/run/crio/crio.sock` | Superficie mínima, versionado al mismo ritmo que Kubernetes |
| Docker Engine | No — necesita `cri-dockerd` | `/run/cri-dockerd.sock` | Un salto extra; solo por restricciones heredadas |
| Kata Containers | Vía `RuntimeClass` de containerd/CRI-O | — | VM aislada por hardware para cada Pod, para multitenencia hostil |
| gVisor (`runsc`) | Vía `RuntimeClass` | — | Kernel en espacio de usuario; filtrado de llamadas al sistema con un costo de rendimiento |

`crictl` es la herramienta de depuración a nivel de nodo. Habla directamente con el socket CRI, así que funciona cuando el API server está caído — que es exactamente cuando lo necesita.

```console
$ sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a | head -6
CONTAINER      IMAGE          CREATED         STATE      NAME                     ATTEMPT  POD ID         POD
7c1e9a4b2f08d  b19406328e70   4 minutes ago   Running    web                      0        3a8e0d7c1b9f2  web-7d9f6c8b5-2xk4t
0a4d2c8e91b73  8c811b4aec35   9 minutes ago   Exited     migrate                  2        3a8e0d7c1b9f2  web-7d9f6c8b5-2xk4t
1f0c9b1a4d2e7  4a1f3c8b9d21   3 weeks ago     Running    kube-apiserver           0        9a7d3e1b0c4f5  kube-apiserver-cp-1

$ sudo crictl logs --tail 5 0a4d2c8e91b73
2026/09/03 11:52:10 connecting to postgres://db.prod.svc.cluster.local:5432
2026/09/03 11:52:40 dial tcp: i/o timeout
2026/09/03 11:52:40 migration failed: cannot reach database
$ sudo crictl imagefsinfo
{"status":{"timestamp":"1756901940000000000","fsId":{"mountpoint":"/var/lib/containerd"},"usedBytes":{"value":"18374912000"},"inodesUsed":{"value":"284431"}}}
```

Use `crictl`, nunca `docker`, en un nodo con containerd — y note que `crictl` es una herramienta de *depuración*: los contenedores que crea no son gestionados por el kubelet y serán recolectados como basura.

---

## 10. El modelo de objetos en la práctica

### 10.1 Pod → ReplicaSet → Deployment

El Pod es la unidad de planificación y de red: uno o más contenedores que comparten un espacio de nombres de red, un espacio de nombres IPC y volúmenes. Los Pods deliberadamente **no** se autorreparan — un controlador se ocupa de eso.

Un Deployment completo, con forma de producción, con todo lo que un SRE realmente exige:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: web
  namespace: prod
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: prod
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/component: frontend
    app.kubernetes.io/part-of: storefront
spec:
  replicas: 6
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  minReadySeconds: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
        app.kubernetes.io/component: frontend
    spec:
      serviceAccountName: web
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: web
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: web
      initContainers:
        - name: schema-migrate
          image: registry.example.com/storefront/migrate:2.14.0
          args: ["--wait-for-db=60s"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
      containers:
        - name: web
          image: registry.example.com/storefront/web:2.14.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: web-db
                  key: password
          envFrom:
            - configMapRef:
                name: web-config
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 15
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/web
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: prod
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  internalTrafficPolicy: Cluster
  sessionAffinity: None
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
  namespace: prod
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app.kubernetes.io/name: web
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 6
  maxReplicas: 30
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
          value: 20
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 4
          periodSeconds: 30
      selectPolicy: Max
```

Notas de diseño que se espera que un arquitecto justifique:

- **`maxUnavailable: 0` con `maxSurge: 2`** — nunca bajar de la capacidad durante un despliegue; cuesta el recurso de dos Pods extra mientras dura.
- **Límite de `memory` == request, sin límite de CPU** — la memoria es incompresible, así que el límite evita que un vecino ruidoso mate el nodo; un límite de CPU solo introduce estrangulamiento CFS y latencia de cola. Este es el consenso SRE mayoritario actual, y hace que el Pod sea `Burstable`, no `Guaranteed` — un compromiso deliberado.
- **`preStop: sleep 10` más `terminationGracePeriodSeconds: 45`** — el borrado del Pod elimina el endpoint y envía SIGTERM *de forma concurrente*. Sin el sleep, kube-proxy en algún nodo va a seguir enviando tráfico a un Pod que se está apagando. Esta es la solución para "recibimos 502 en cada despliegue".
- **`startupProbe` con `failureThreshold: 30`** — desacopla el arranque lento (hasta 150 s) de una sonda de liveness agresiva. Sin ella, una aplicación de arranque lento queda eliminada en un bucle de reinicios para siempre.
- **PDB `minAvailable: 4` de 6** — acota la disrupción *voluntaria* (`kubectl drain`, actualizaciones de nodos). **No** protege contra caídas de nodos.

### 10.2 Services y EndpointSlices

```console
$ kubectl -n prod get svc web -o wide
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web    ClusterIP   10.98.14.201   <none>        80/TCP    31d   app.kubernetes.io/name=web

$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                                       AGE
web-8k4mz   IPv4          8080    10.244.3.15,10.244.4.22,10.244.5.31 + 3 more   31d

$ kubectl -n prod get endpointslice web-8k4mz -o jsonpath='{range .endpoints[*]}{.addresses[0]}{"\t"}{.conditions.ready}{"\t"}{.nodeName}{"\n"}{end}'
10.244.3.15	true	worker-01
10.244.4.22	true	worker-02
10.244.5.31	true	worker-03
10.244.3.19	true	worker-01
10.244.4.27	false	worker-02
10.244.5.33	true	worker-03
```

**`ready: false` en un endpoint es todo el diagnóstico** de "una de cada seis peticiones falla" — ese Pod está fallando su sonda de readiness y queda correctamente excluido del balanceo de carga. Los EndpointSlices reemplazaron al objeto único `Endpoints` precisamente porque un Service con 5000 endpoints producía un objeto enorme reescrito en cada cambio, saturando el API server.

| Tipo de Service | Alcanzable desde | Implementado por | Usar para |
|---|---|---|---|
| `ClusterIP` | Solo dentro del clúster | plano de datos de kube-proxy | Tráfico este-oeste (el valor por defecto, y correcto el 90 % de las veces) |
| `NodePort` | `<any-node-ip>:30000-32767` | plano de datos de kube-proxy | LB externo que usted mismo gestiona; bare metal |
| `LoadBalancer` | VIP del LB de la nube | cloud-controller-manager o MetalLB | Entrada norte-sur en la nube |
| `ExternalName` | CNAME en el DNS del clúster | Solo CoreDNS — sin proxy | Alias de una dependencia fuera del clúster |
| Headless (`clusterIP: None`) | El DNS devuelve las IPs de los Pods directamente | Solo CoreDNS | StatefulSets, LB del lado del cliente, gRPC |

---

## 11. `kubectl`: la interfaz del operador

### 11.1 kubeconfig

```yaml
apiVersion: v1
kind: Config
preferences: {}
current-context: prod-admin
clusters:
  - name: prod
    cluster:
      server: https://api.prod.example.com:6443
      certificate-authority: /home/sre/.kube/prod-ca.crt
  - name: staging
    cluster:
      server: https://api.staging.example.com:6443
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
contexts:
  - name: prod-admin
    context:
      cluster: prod
      user: sre-oidc
      namespace: prod
  - name: staging-admin
    context:
      cluster: staging
      user: staging-admin
      namespace: default
users:
  - name: sre-oidc
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl-oidc_login
        args:
          - get-token
          - --oidc-issuer-url=https://sso.example.com/realms/platform
          - --oidc-client-id=kubernetes
        interactiveMode: IfAvailable
  - name: staging-admin
    user:
      client-certificate: /home/sre/.kube/staging-admin.crt
      client-key: /home/sre/.kube/staging-admin.key
```

Tres listas separadas — clusters, users, contexts — unidas por un contexto. El plugin de credenciales `exec` es la forma en que se autentica toda organización real: tokens OIDC de corta duración, sin certificados de larga duración en las laptops. Precedencia: `--kubeconfig` > `$KUBECONFIG` (separado por dos puntos, fusionado) > `~/.kube/config`.

```console
$ kubectl config get-contexts
CURRENT   NAME            CLUSTER   AUTHINFO        NAMESPACE
*         prod-admin      prod      sre-oidc        prod
          staging-admin   staging   staging-admin   default

$ kubectl config use-context staging-admin
Switched to context "staging-admin".

$ kubectl config set-context --current --namespace=payments
Context "staging-admin" modified.
```

### 11.2 Imperativo, declarativo y server-side apply

| Enfoque | Comando | Dónde corresponde |
|---|---|---|
| Imperativo | `kubectl create deployment web --image=…` | Exploración interactiva, velocidad en el examen, nunca en Git |
| Imperativo con archivo local | `kubectl create -f web.yaml` | Falla al reejecutarse; no es idempotente |
| Declarativo (client-side apply) | `kubectl apply -f manifests/` | El valor por defecto de siempre; fusiona vía la anotación `last-applied-configuration` |
| **Server-side apply** | `kubectl apply --server-side -f …` | Varios controladores son dueños de distintos campos de un mismo objeto; los conflictos se reportan, no se sobrescriben en silencio |

Los generadores siguen siendo la forma más rápida de producir un esqueleto correcto:

```console
$ kubectl create deployment web --image=nginx:1.27 --replicas=3 --dry-run=client -o yaml > web.yaml
$ kubectl create service clusterip web --tcp=80:8080 --dry-run=client -o yaml >> web.yaml
$ kubectl apply --server-side -f web.yaml
deployment.apps/web serverside-applied
service/web serverside-applied
```

Server-side apply registra los **field managers**, que es como descubre quién le está peleando un campo:

```console
$ kubectl -n prod get deploy web -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
kubectl	Apply
kube-controller-manager	Update
flux	Apply
```

Dos managers `Apply` sobre el mismo objeto son exactamente el bug de "alguien revierte mi cambio cada 5 minutos".

### 11.3 Los comandos que importan bajo presión

```console
$ kubectl -n prod get pods -o wide --sort-by=.status.startTime | tail -4
NAME                    READY   STATUS             RESTARTS        AGE     IP            NODE        NOMINATED NODE   READINESS GATES
web-7d9f6c8b5-9plmz     1/1     Running            0               4m12s   10.244.5.33   worker-03   <none>           <none>
web-7d9f6c8b5-2xk4t     0/1     CrashLoopBackOff   6 (2m11s ago)   9m48s   10.244.3.19   worker-01   <none>           <none>

$ kubectl -n prod get pods --field-selector status.phase!=Running
NAME                    READY   STATUS             RESTARTS        AGE
web-7d9f6c8b5-2xk4t     0/1     CrashLoopBackOff   6 (2m11s ago)   9m48s

$ kubectl -n prod logs web-7d9f6c8b5-2xk4t --previous --tail=20
panic: open /var/run/secrets/db/password: permission denied

goroutine 1 [running]:
main.mustReadSecret(...)

$ kubectl -n prod describe pod web-7d9f6c8b5-2xk4t | tail -12
Events:
  Type     Reason     Age                    From               Message
  ----     ------     ----                   ----               -------
  Normal   Scheduled  9m50s                  default-scheduler  Successfully assigned prod/web-7d9f6c8b5-2xk4t to worker-01
  Normal   Pulled     9m48s                  kubelet            Container image "registry.example.com/storefront/web:2.14.0" already present on machine
  Normal   Created    8m11s (x4 over 9m48s)  kubelet            Created container: web
  Normal   Started    8m11s (x4 over 9m48s)  kubelet            Started container web
  Warning  BackOff    4m30s (x21 over 9m2s)  kubelet            Back-off restarting failed container web in pod web-7d9f6c8b5-2xk4t_prod

$ kubectl -n prod get events --sort-by=.lastTimestamp | tail -5
9m50s   Normal    Scheduled          pod/web-7d9f6c8b5-2xk4t   Successfully assigned prod/web-7d9f6c8b5-2xk4t to worker-01
8m11s   Normal    Created            pod/web-7d9f6c8b5-2xk4t   Created container: web
4m30s   Warning   BackOff            pod/web-7d9f6c8b5-2xk4t   Back-off restarting failed container web
2m14s   Warning   FailedScheduling   pod/analytics-6b8f9d4c7-vzq2n  0/6 nodes are available: 2 Insufficient cpu...
1m02s   Normal    ScalingReplicaSet  deployment/web            Scaled up replica set web-7d9f6c8b5 to 7
```

Depurar un contenedor distroless sin shell es para lo que están los **contenedores efímeros**:

```console
$ kubectl -n prod debug -it web-7d9f6c8b5-9plmz --image=nicolaka/netshoot --target=web -- bash
Defaulting debug container name to debugger-x7k2p.
If you don't see a command prompt, try pressing enter.
netshoot:~# nslookup db.prod.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	db.prod.svc.cluster.local
Address: 10.99.201.14
netshoot:~# curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://localhost:8080/readyz
200 0.004131s
```

`--target=web` comparte el espacio de nombres de procesos del contenedor objetivo, así que `ps`, `/proc/<pid>` y `nsenter` funcionan todos contra la carga de trabajo real. Para depurar un nodo en sí:

```console
$ kubectl debug node/worker-01 -it --image=busybox:1.36
Creating debugging pod node-debugger-worker-01-4xp2m with container debugger on node worker-01.
/ # chroot /host journalctl -u kubelet -n 5 --no-pager
Sep 03 12:02:19 worker-01 kubelet[1184]: E0903 12:02:19.774112 1184 pod_workers.go:1301] "Error syncing pod" err="failed to \"StartContainer\" for \"web\" with CrashLoopBackOff: \"back-off 5m0s restarting failed container=web pod=web-7d9f6c8b5-2xk4t_prod(9c1d...)\""
```

Control del despliegue:

```console
$ kubectl -n prod rollout status deployment/web --timeout=5m
Waiting for deployment "web" rollout to finish: 4 out of 6 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 5 of 6 updated replicas are available...
deployment "web" successfully rolled out

$ kubectl -n prod rollout history deployment/web
deployment.apps/web
REVISION  CHANGE-CAUSE
3         Update image to 2.13.4
4         Update image to 2.14.0

$ kubectl -n prod rollout undo deployment/web --to-revision=3
deployment.apps/web rolled back
```

La salida personalizada es cómo se convierte `kubectl` en una herramienta de consulta en lugar de canalizar hacia `awk`:

```console
$ kubectl get nodes -o custom-columns='NODE:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KERNEL:.status.nodeInfo.kernelVersion'
NODE        VERSION   RUNTIME                 KERNEL
cp-1        v1.33.2   containerd://1.7.22     6.8.0-45-generic
cp-2        v1.33.2   containerd://1.7.22     6.8.0-45-generic
cp-3        v1.33.2   containerd://1.7.22     6.8.0-45-generic
worker-01   v1.33.2   containerd://1.7.22     6.8.0-45-generic
worker-02   v1.32.6   containerd://1.7.20     6.8.0-40-generic
worker-03   v1.33.2   containerd://1.7.22     6.8.0-45-generic

$ kubectl get pods -A -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sort -rn
     34 worker-01
     31 worker-03
     28 worker-02
     11 cp-1
```

---

## 12. Construir el clúster: kubeadm y topologías HA

### 12.1 Compromisos de las topologías HA

| Topología | Ubicación de etcd | Nodos para tolerar 1 fallo | Radio de impacto de perder un nodo del plano de control | Cuándo |
|---|---|---|---|---|
| Nodo único (`k3s`, `kind`, `minikube`) | Local | 1 | Total | Desarrollo, CI |
| etcd apilado (stacked) | En los nodos del plano de control | 3 | Pierde un API server **y** un miembro de etcd simultáneamente | Por defecto; la respuesta correcta para la mayoría de los clústeres |
| etcd externo | Clúster etcd separado | 3 CP + 3 etcd = 6 | Pierde solo un API server | Clústeres grandes, o cuando etcd debe ajustarse/respaldarse de forma independiente |

### 12.2 Configuración completa de kubeadm

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.10.0.10
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: 10.10.0.10
  taints:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.2
clusterName: prod-eu-west
controlPlaneEndpoint: "api.prod.example.com:6443"
imageRepository: registry.k8s.io
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: quota-backend-bytes
        value: "8589934592"
      - name: auto-compaction-mode
        value: periodic
      - name: auto-compaction-retention
        value: "8h"
apiServer:
  certSANs:
    - api.prod.example.com
    - 10.10.0.10
    - 10.10.0.11
    - 10.10.0.12
    - 127.0.0.1
  extraArgs:
    - name: audit-log-path
      value: /var/log/kubernetes/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-policy-file
      value: /etc/kubernetes/audit-policy.yaml
    - name: enable-admission-plugins
      value: NodeRestriction,ResourceQuota,PodSecurity
    - name: request-timeout
      value: 300s
  extraVolumes:
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
      pathType: File
    - name: audit-log
      hostPath: /var/log/kubernetes
      mountPath: /var/log/kubernetes
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
    - name: node-monitor-grace-period
      value: 40s
    - name: terminated-pod-gc-threshold
      value: "500"
scheduler:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: true
rotateCertificates: true
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: rr
  strictARP: true
```

```console
$ sudo kubeadm init --config kubeadm-config.yaml --upload-certs
[init] Using Kubernetes version: v1.33.2
[preflight] Running pre-flight checks
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [api.prod.example.com cp-1 kubernetes kubernetes.default ...] and IPs [10.96.0.1 10.10.0.10 10.10.0.11 10.10.0.12 127.0.0.1]
[kubeconfig] Writing "admin.conf" kubeconfig file
[control-plane] Creating static Pod manifest for "kube-apiserver"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests"
[apiclient] All control plane components are healthy after 8.502341 seconds
[upload-certs] Using certificate key:
7a1c9e0b4d3f5a82c6e1b0d94f7a2c38e5b6d1092f4a7c30b8e1d6f5a290c4b3

Your Kubernetes control-plane has initialized successfully!

You can now join any number of control-plane nodes by running:

  kubeadm join api.prod.example.com:6443 --token 9x2k4d.8fj3ka0dm2nvq1zx \
    --discovery-token-ca-cert-hash sha256:e91b0c2a7d4f8e35b16a9c0d7f2e4b8a35c1d9e0f7a2b4c6d8e1f0a3b5c7d9e1 \
    --control-plane --certificate-key 7a1c9e0b4d3f5a82c6e1b0d94f7a2c38e5b6d1092f4a7c30b8e1d6f5a290c4b3

Then you can join any number of worker nodes by running:

  kubeadm join api.prod.example.com:6443 --token 9x2k4d.8fj3ka0dm2nvq1zx \
    --discovery-token-ca-cert-hash sha256:e91b0c2a7d4f8e35b16a9c0d7f2e4b8a35c1d9e0f7a2b4c6d8e1f0a3b5c7d9e1
```

`--discovery-token-ca-cert-hash` es la parte mutua de la confianza: el token prueba el nodo ante el clúster, el hash prueba la CA del clúster ante el nodo. Omitirlo (`--discovery-token-unsafe-skip-ca-verification`) hace que las incorporaciones sean vulnerables a un MITM.

### 12.3 Desfase de versiones (skew) — la regla que gobierna las actualizaciones

| Componente | Desfase permitido respecto de `kube-apiserver` |
|---|---|
| Otras instancias de `kube-apiserver` (HA) | Dentro de 1 versión menor entre sí |
| `kube-controller-manager`, `kube-scheduler`, `cloud-controller-manager` | Hasta 1 versión menor más antigua; **nunca más nueva** |
| `kubelet`, `kube-proxy` | Hasta 3 versiones menores más antiguas (desde v1.28); **nunca más nueva** |
| `kubectl` | Una versión menor más nueva o más antigua |

El orden es fijo y no negociable: **etcd → kube-apiserver (todos) → controller-manager/scheduler → kubelets → kube-proxy → addons**, y de a una versión menor por vez. Nunca saltee una versión menor.

```console
$ sudo kubeadm upgrade plan
[upgrade/config] Reading configuration from the cluster...
COMPONENT                 CURRENT   TARGET
kubelet                   6 x v1.33.2   v1.34.1
kube-apiserver            v1.33.2   v1.34.1
kube-controller-manager   v1.33.2   v1.34.1
kube-scheduler            v1.33.2   v1.34.1
kube-proxy                v1.33.2   v1.34.1
CoreDNS                   v1.11.3   v1.11.3
etcd                      3.5.15    3.5.16

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.34.1
```

---

## 13. Verificación y diagnóstico de fallos

### 13.1 La escalera de salud — ejecútela de arriba abajo, siempre en este orden

```console
# 1. Can I reach the API at all?
$ kubectl cluster-info
Kubernetes control plane is running at https://api.prod.example.com:6443
CoreDNS is running at https://api.prod.example.com:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy

# 2. Is the API server itself healthy?
$ kubectl get --raw '/readyz?verbose' | grep -v ' ok$'
readyz check passed

# 3. Is etcd healthy and does it have quorum?  (see §4.2)

# 4. Are the nodes healthy?
$ kubectl get nodes
NAME        STATUS     ROLES           AGE   VERSION
cp-1        Ready      control-plane   61d   v1.33.2
cp-2        Ready      control-plane   61d   v1.33.2
cp-3        Ready      control-plane   61d   v1.33.2
worker-01   Ready      <none>          61d   v1.33.2
worker-02   NotReady   <none>          61d   v1.32.6
worker-03   Ready      <none>          61d   v1.33.2

# 5. Is the control plane's own workload healthy?
$ kubectl -n kube-system get pods
NAME                            READY   STATUS    RESTARTS      AGE
coredns-668d6bf9bc-4mvxs        1/1     Running   0             12d
coredns-668d6bf9bc-tq7lk        1/1     Running   0             12d
etcd-cp-1                       1/1     Running   2 (21d ago)   61d
kube-apiserver-cp-1             1/1     Running   2 (21d ago)   61d
kube-controller-manager-cp-1    1/1     Running   4 (21d ago)   61d
kube-proxy-9dk2m                1/1     Running   0             61d
kube-scheduler-cp-1             1/1     Running   4 (21d ago)   61d

# 6. What is the cluster complaining about, cluster-wide?
$ kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -10

# 7. Is anything under resource pressure?
$ kubectl top nodes
NAME        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
cp-1        412m         5%     3120Mi          19%
worker-01   11204m       74%    48210Mi         78%
worker-03   9880m        65%    41022Mi         66%
```

### 13.2 Manual de campo: nodo `NotReady`

`NotReady` significa que el kubelet dejó de renovar su Lease o está reportando una condición mala. Seis causas candidatas, en el orden en que debería eliminarlas:

```console
$ kubectl describe node worker-02 | sed -n '/^Conditions:/,/^Addresses:/p'
Conditions:
  Type             Status    LastHeartbeatTime                 Reason                       Message
  ----             ------    -----------------                 ------                       -------
  MemoryPressure   Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
  DiskPressure     Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
  PIDPressure      Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
  Ready            Unknown   Wed, 03 Sep 2026 11:41:07 +0000   NodeStatusUnknown            Kubelet stopped posting node status.
```

`Unknown` = sin heartbeat, así que el problema está en el nodo o en la red. Vaya al nodo:

```console
$ ssh worker-02 'systemctl is-active kubelet containerd; journalctl -u kubelet -p err -n 5 --no-pager'
active
active
Sep 03 11:40:58 worker-02 kubelet[1184]: E0903 11:40:58.221009 1184 kubelet_node_status.go:544] "Error updating node status, will retry" err="error getting node \"worker-02\": Get \"https://api.prod.example.com:6443/api/v1/nodes/worker-02\": dial tcp 10.10.0.5:6443: i/o timeout"
Sep 03 11:41:07 worker-02 kubelet[1184]: E0903 11:41:07.884213 1184 controller.go:145] "Failed to ensure lease exists, will retry" err="Get \"https://api.prod.example.com:6443/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases/worker-02\": dial tcp 10.10.0.5:6443: i/o timeout"
```

| Causa candidata | Cómo confirmarla | Solución |
|---|---|---|
| kubelet muerto | `systemctl is-active kubelet` | `systemctl start kubelet`; lea `journalctl -xeu kubelet` primero |
| Runtime de contenedores trabado | `crictl info` se cuelga; `PLEG is not healthy` en el log | Reinicie containerd; revise el disco |
| Ruta de red hacia el API server rota | `curl -k https://<endpoint>:6443/livez` desde el nodo — como arriba | Firewall / ruta / salud del LB |
| CNI no instalado o caído | La condición `Ready` dice `network plugin returns error: cni plugin not initialized` | Revise el Pod del DaemonSet del CNI en ese nodo |
| Disco lleno | `df -h /var/lib/kubelet /var/lib/containerd`; `DiskPressure=True` | GC de imágenes, rotación de logs, agrandar el volumen |
| Certificado de cliente del kubelet vencido | `openssl x509 -enddate -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem` | Rehacer el bootstrap; habilitar `rotateCertificates` |

Después del `node-monitor-grace-period` (40 s) el controlador de nodos lo marca como `Unknown`; después de los `tolerationSeconds` de los Pods (300 s por defecto para `node.kubernetes.io/unreachable:NoExecute`) sus Pods son desalojados y replanificados. Tiempo total hasta la recuperación ≈ 5,5 minutos por defecto. Ese número es un parámetro de diseño — conózcalo antes de que alguien pregunte por qué la conmutación tardó tanto.

### 13.3 Manual de campo: Pod que no arranca

```
STATUS?
├─ Pending ──────► kubectl describe pod → Events
│                  ├─ FailedScheduling: no resources / taints / affinity / topology → §5.3
│                  ├─ no Events at all → scheduler down? kubectl -n kube-system logs kube-scheduler-cp-1
│                  └─ scheduled but stuck → volume not bound: kubectl get pvc
├─ ContainerCreating ► describe → Events
│                  ├─ FailedCreatePodSandBox / CNI error → CNI DaemonSet on that node
│                  ├─ FailedMount / timeout waiting for attach → CSI driver, node logs
│                  └─ FailedToRetrieveImagePullSecret → imagePullSecrets, SA
├─ ImagePullBackOff ► describe → Events → "manifest unknown" (bad tag) |
│                     "unauthorized" (registry creds) | "no such host" (DNS/proxy on node)
├─ CrashLoopBackOff ► kubectl logs --previous
│                  ├─ app error in logs → application bug / config
│                  ├─ exit code 137 → OOMKilled: kubectl get pod -o jsonpath='{..lastState.terminated}'
│                  ├─ exit code 1 immediately, no logs → bad command/args, missing file
│                  └─ liveness probe killing a slow starter → add startupProbe
├─ Running 0/1 ────► readiness probe failing: kubectl describe → "Readiness probe failed:"
│                    kubectl exec into the Pod and curl the probe path yourself
├─ Terminating ────► stuck finalizer, or preStop/SIGTERM not honoured
│                    kubectl get pod -o jsonpath='{.metadata.finalizers}'
└─ Evicted ────────► node pressure: describe node → DiskPressure/MemoryPressure; §7.3
```

Confirmación concreta de OOM, que la gente rutinariamente adivina en lugar de verificar:

```console
$ kubectl -n prod get pod web-7d9f6c8b5-2xk4t -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq
{
  "containerID": "containerd://0a4d2c8e91b73...",
  "exitCode": 137,
  "finishedAt": "2026-09-03T12:01:44Z",
  "reason": "OOMKilled",
  "startedAt": "2026-09-03T11:59:12Z"
}
```

`exitCode: 137` = 128 + SIGKILL(9). `reason: OOMKilled` es autoritativo: suba el límite de memoria o arregle la fuga. No suba la CPU.

### 13.4 Manual de campo: un Service sin endpoints

```console
$ kubectl -n prod get endpointslices -l kubernetes.io/service-name=api
NAME        ADDRESSTYPE   PORTS    ENDPOINTS   AGE
api-2f8kq   IPv4          <unset>  <unset>     6m
```

Vacío. Exactamente tres causas, verificadas en orden:

```console
# 1. Does the selector match any Pod?
$ kubectl -n prod get svc api -o jsonpath='{.spec.selector}{"\n"}'
{"app":"api"}
$ kubectl -n prod get pods -l app=api
No resources found in prod namespace.
$ kubectl -n prod get pods --show-labels | grep api
api-5f7d8c9b4-lm2xp   1/1   Running   0   6m   app.kubernetes.io/name=api,pod-template-hash=5f7d8c9b4
```

Desajuste de etiquetas — el Service selecciona `app=api`, los Pods llevan `app.kubernetes.io/name=api`. Si el selector hubiera coincidido, las dos verificaciones siguientes son: ¿están los Pods `Ready` (un Pod no listo queda excluido por diseño), y coincide `targetPort` con un nombre o número de `containerPort` real?

Luego verifique el plano de datos de punta a punta desde dentro del clúster:

```console
$ kubectl -n prod run curl --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
    curl -sS -o /dev/null -w 'code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s total=%{time_total}s\n' http://api.prod.svc.cluster.local/healthz
code=200 dns=0.003114s connect=0.004902s total=0.011776s
pod "curl" deleted
```

### 13.5 Manual de campo: vencimiento de certificados

Silencioso hasta que es catastrófico. Los certificados de cliente/servidor emitidos por kubeadm duran **un año**; la CA dura diez.

```console
$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Nov 12, 2026 09:14 UTC   70d             no
apiserver                  Nov 12, 2026 09:14 UTC   70d             no
apiserver-etcd-client      Nov 12, 2026 09:14 UTC   70d             no
apiserver-kubelet-client   Nov 12, 2026 09:14 UTC   70d             no
controller-manager.conf    Nov 12, 2026 09:14 UTC   70d             no
etcd-healthcheck-client    Nov 12, 2026 09:14 UTC   70d             no
etcd-peer                  Nov 12, 2026 09:14 UTC   70d             no
etcd-server                Nov 12, 2026 09:14 UTC   70d             no
front-proxy-client         Nov 12, 2026 09:14 UTC   70d             no
scheduler.conf             Nov 12, 2026 09:14 UTC   70d             no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME
ca                      Aug 30, 2035 09:14 UTC   3283d
etcd-ca                 Aug 30, 2035 09:14 UTC   3283d
front-proxy-ca          Aug 30, 2035 09:14 UTC   3283d

$ sudo kubeadm certs renew all
certificate embedded in the kubeconfig file for the admin to use and for kubeadm itself renewed
certificate for serving the Kubernetes API renewed
[...]
Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.
```

`kubeadm upgrade` los renueva implícitamente, y por eso los clústeres que se actualizan con regularidad nunca chocan con esto — y los clústeres abandonados durante 13 meses mueren un domingo. Los certificados del kubelet son la excepción: `rotateCertificates: true` los renueva automáticamente vía la API de CSR.

### 13.6 Leer la ruta de la petición de punta a punta

Cuando el fallo es "kubectl se comporta raro", deje de adivinar y mire el cable:

```console
$ kubectl -v=8 get pods -n prod 2>&1 | head -12
I0903 12:06:07.113455   28417 loader.go:395] Config loaded from file:  /home/sre/.kube/config
I0903 12:06:07.118902   28417 round_trippers.go:463] GET https://api.prod.example.com:6443/api/v1/namespaces/prod/pods?limit=500
I0903 12:06:07.118931   28417 round_trippers.go:469] Request Headers:
I0903 12:06:07.118942   28417 round_trippers.go:473]     Accept: application/json;as=Table;v=v1;g=meta.k8s.io,application/json
I0903 12:06:07.118951   28417 round_trippers.go:473]     User-Agent: kubectl/v1.33.2 (linux/amd64) kubernetes/0d8f1cb
I0903 12:06:07.118958   28417 round_trippers.go:473]     Authorization: Bearer <masked>
I0903 12:06:07.331204   28417 round_trippers.go:574] Response Status: 403 Forbidden in 212 milliseconds
I0903 12:06:07.331512   28417 request.go:1212] Response Body: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods is forbidden: User \"jane@example.com\" cannot list resource \"pods\" in API group \"\" in the namespace \"prod\"","reason":"Forbidden","code":403}
Error from server (Forbidden): pods is forbidden: User "jane@example.com" cannot list resource "pods" in API group "" in the namespace "prod"
```

Niveles de verbosidad que vale la pena recordar: `-v=6` URLs y estado, `-v=7` cabeceras de la petición, `-v=8` cuerpos de petición/respuesta, `-v=9` cuerpos sin truncar.

---

## 14. Autoevaluación: demuestre que domina el objetivo

Ejecute cada uno de estos en un clúster real (`kind`, `minikube` o kubeadm sobre tres VMs). Si no puede hacer alguno de memoria, relea la sección correspondiente.

1. Nombre cada proceso de un nodo del plano de control y el puerto en el que escucha; verifique con `ss -lntp`.
2. Explique, sin notas, los trece pasos desde `kubectl apply` hasta un contenedor en ejecución (§2.4).
3. Borre `/etc/kubernetes/manifests/kube-scheduler.yaml`, cree un Pod, observe que queda `Pending`, restaure el archivo y vea cómo se planifica.
4. Tome un snapshot de etcd, cree un Deployment, restaure el snapshot y demuestre que el Deployment desapareció.
5. Rompa un Service editando su selector; encuentre el EndpointSlice vacío; arréglelo.
6. Fije un límite de memoria de `10Mi` en una aplicación Java o Node; identifique `exitCode 137 / OOMKilled` desde `lastState`.
7. Cambie `kube-proxy` de `iptables` a `ipvs`; verifique con `ipvsadm -Ln` que los ClusterIP aparecen como servidores virtuales.
8. Drene un nodo con un PDB activo; observe `Cannot evict pod as it would violate the pod's disruption budget`.
9. Desde un contenedor efímero `netshoot`, resuelva el FQDN de un Service, un Service headless y un `ExternalName`.
10. Ejecute `kubeadm certs check-expiration` y explique qué certificado, si venciera, impediría que el API server hablara con etcd.

**Términos y utilidades con los que debe tener fluidez:** `kubectl` (`get`, `describe`, `logs`, `exec`, `apply`, `delete`, `explain`, `api-resources`, `top`, `drain`, `cordon`, `rollout`, `debug`, `auth can-i`, `config`), `kubeadm`, `kubelet`, `kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, `kube-proxy`, `etcd`/`etcdctl`, `crictl`, `containerd`/`CRI-O`, `~/.kube/config`, `/etc/kubernetes/manifests`, Pod, ReplicaSet, Deployment, DaemonSet, StatefulSet, Job, Service, EndpointSlice, Namespace, ConfigMap, Secret, PersistentVolume(Claim), Node, Label, Selector, Annotation, Taint, Toleration.

---

## 15. Referencias

**Objetivos del examen**
- LPI Exam 701 objectives (DevOps Tools Engineer) — https://www.lpi.org/our-certifications/exam-701-objectives/

**Arquitectura y componentes**
- Kubernetes Components — https://kubernetes.io/docs/concepts/overview/components/
- Cluster Architecture — https://kubernetes.io/docs/concepts/architecture/
- Nodes — https://kubernetes.io/docs/concepts/architecture/nodes/
- Communication between Nodes and the Control Plane — https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/
- Controllers — https://kubernetes.io/docs/concepts/architecture/controller/
- Leases — https://kubernetes.io/docs/concepts/architecture/leases/
- Garbage Collection — https://kubernetes.io/docs/concepts/architecture/garbage-collection/

**Maquinaria de la API**
- The Kubernetes API — https://kubernetes.io/docs/concepts/overview/kubernetes-api/
- API Concepts (watch, resourceVersion, pagination) — https://kubernetes.io/docs/reference/using-api/api-concepts/
- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/
- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- API Priority and Fairness — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Kubernetes API health endpoints — https://kubernetes.io/docs/reference/using-api/health-checks/
- Server-Side Apply — https://kubernetes.io/docs/reference/using-api/server-side-apply/

**etcd**
- Operating etcd clusters for Kubernetes — https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- etcd documentation — https://etcd.io/docs/
- etcd FAQ (cluster size, quorum) — https://etcd.io/docs/v3.5/faq/

**Planificación**
- kube-scheduler — https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/
- Scheduling Framework — https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/
- Scheduler Configuration — https://kubernetes.io/docs/reference/scheduling/config/
- Pod Priority and Preemption — https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- Pod Topology Spread Constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Node-pressure Eviction — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/

**kubelet, runtime y recursos**
- kubelet reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- KubeletConfiguration (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Container Runtimes — https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Container Runtime Interface (CRI) — https://kubernetes.io/docs/concepts/architecture/cri/
- Reserve Compute Resources for System Daemons — https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/
- Pod QoS Classes — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Debugging Kubernetes nodes with crictl — https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- containerd — https://containerd.io/docs/
- CRI-O — https://cri-o.io/

**Red**
- Cluster Networking — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service — https://kubernetes.io/docs/concepts/services-networking/service/
- Virtual IPs and Service Proxies (proxy modes) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- EndpointSlices — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- DNS for Services and Pods — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Network Plugins — https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/

**Cargas de trabajo**
- Pods — https://kubernetes.io/docs/concepts/workloads/pods/
- Deployments — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Configure Liveness, Readiness and Startup Probes — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Disruptions and PodDisruptionBudget — https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Horizontal Pod Autoscaling — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

**kubectl y ciclo de vida del clúster**
- kubectl reference — https://kubernetes.io/docs/reference/kubectl/
- Organizing Cluster Access Using kubeconfig Files — https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- kubeadm init — https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/
- Creating Highly Available Clusters with kubeadm — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- Certificate Management with kubeadm — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Version Skew Policy — https://kubernetes.io/releases/version-skew-policy/

**Depuración**
- Troubleshooting Clusters — https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Debug Running Pods (ephemeral containers) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Determine the Reason for Pod Failure — https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/