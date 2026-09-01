# Cilium Architecture & Components — Ejercicios guiados

> **Contexto del examen:** Dominio 2.1 del CCA — *Cilium Architecture & Components* (20% del examen).
> **Formato:** cada bloque es una secuencia de pasos numerados que ejecutás contra un clúster real, seguida de preguntas de control. Las respuestas están plegadas al final — resistí la tentación de abrirlas antes de haber escrito las tuyas.
> **Línea base de versiones:** Cilium **1.17.x** sobre Kubernetes **1.32**, kernel **≥ 6.6** (para que esté disponible el modo de attach TCX). Donde el comportamiento cambió recientemente, la versión se aclara en línea.
> **Las salidas mostradas son representativas.** Los IDs de endpoint, las identidades de seguridad, las IPs y los nombres de interfaz van a ser distintos en tu clúster — de eso se tratan varias de las preguntas.

---

## Ejercicio 0 — Armar el laboratorio

Necesitás un clúster donde **vos** seas el dueño del datapath: sin CNI preinstalado y sin `kube-proxy`, de modo que los componentes propios de Cilium sean lo único entre un pod y el cable.

1. Escribí la topología de kind en `cca-lab.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  disableDefaultCNI: true      # no kindnet — Cilium will be the only CNI
  kubeProxyMode: "none"        # no kube-proxy — Cilium will own service load balancing
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. Creá el clúster y confirmá que está roto a propósito:

```bash
kind create cluster --config cca-lab.yaml
kubectl get nodes
kubectl -n kube-system get pods
```

```
NAME                        STATUS     ROLES           AGE   VERSION
cca-lab-control-plane       NotReady   control-plane   41s   v1.32.2
cca-lab-worker              NotReady   <none>          25s   v1.32.2
cca-lab-worker2             NotReady   <none>          25s   v1.32.2

NAME                       READY   STATUS    RESTARTS   AGE
coredns-668d6bf9bc-8f2qk   0/1     Pending   0          38s
coredns-668d6bf9bc-l7v9n   0/1     Pending   0          38s
etcd-cca-lab-...           1/1     Running   0          44s
```

3. Instalá Cilium con Helm. Prestá atención a los dos valores `k8sService*` — no son cosméticos:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium --version 1.17.4 \
  --namespace kube-system \
  --set k8sServiceHost=cca-lab-control-plane \
  --set k8sServicePort=6443 \
  --set kubeProxyReplacement=true \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16} \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1
```

4. Mirá cómo converge y después inventariá lo que quedó instalado:

```bash
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system get ds,deploy -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -o wide | grep -E 'cilium|hubble'
```

```
NAME                       DESIRED   CURRENT   READY   NODE SELECTOR   CONTAINERS      IMAGES
daemonset.apps/cilium          3         3       3     kubernetes.io/os=linux   cilium-agent   quay.io/cilium/cilium:v1.17.4
daemonset.apps/cilium-envoy    3         3       3     kubernetes.io/os=linux   cilium-envoy   quay.io/cilium/cilium-envoy:v1.32.6-...

NAME                                 READY   UP-TO-DATE   AVAILABLE
deployment.apps/cilium-operator          1/1           1           1
deployment.apps/hubble-relay            1/1           1           1
deployment.apps/hubble-ui               1/1           1           1
```

5. Instalá el CLI `cilium` (esto es **cilium-cli**, un binario distinto del que vive dentro de los pods) y pedí un veredicto a nivel de todo el clúster:

```bash
cilium status --wait
```

6. Creá un alias de shell que vas a usar durante el resto de este documento:

```bash
export CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=cca-lab-worker -o name | head -1)
alias cdbg="kubectl -n kube-system exec -it $CILIUM_POD -c cilium-agent -- cilium-dbg"
cdbg version
```

### Preguntas de control — Bloque 0

- **Q0.1** — Con `kubeProxyMode: none` no hay ningún `kube-proxy` que programe el ClusterIP `10.96.0.1:443` del API server. Y sin embargo `cilium-agent` tiene que llegar al API server para arrancar. ¿Cómo se rompe el problema del huevo y la gallina, y qué dos valores de Helm codifican la respuesta?
- **Q0.2** — `kubectl get pods` muestra *cinco* workloads distintos de Cilium. Clasificá cada uno como **por nodo** o **singleton de clúster**, e indicá el tipo de objeto de Kubernetes que impone esa ubicación.
- **Q0.3** — CoreDNS estaba `Pending` antes de la instalación y `Running` después, pero nunca tocaste el Deployment de CoreDNS. ¿Qué componente hizo la diferencia y a través de qué interfaz de kubelet?
- **Q0.4** — Ejecutaste `cilium status` (en el host) y `cilium-dbg version` (dentro del pod). ¿Por qué existen dos CLIs, y cómo se llamaba el binario dentro del pod antes de Cilium 1.16?

---

## Ejercicio 1 — Anatomía de `cilium-agent`

El agente es el único componente que toca el datapath. Todo lo demás lo alimenta o lee de él.

1. Leé el informe de estado completo. No lo hojees — cada línea es un subsistema:

```bash
cdbg status --verbose
```

```
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.32 (v1.32.2) [linux/amd64]
KubeProxyReplacement:    True   [eth0   172.18.0.3 (Direct Routing)]
Host firewall:           Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.17.4 (v1.17.4-a1b2c3d4)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 4/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.104 (health)
  10.244.1.148 (router)
  10.244.1.29  (default/nginx-6f8c...)
ClusterMesh:             0/0 clusters ready, 0 global-services
BandwidthManager:        Disabled
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
Controller Status:       48/48 healthy
Proxy Status:            OK, ip 10.244.1.148, 0 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Hubble:                  Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 11.72
Encryption:              Disabled
Cluster health:          3/3 reachable   (2026-09-01T12:04:11Z)
Modules Health:          Stopped(0) Degraded(0) OK(52)
```

2. Volcá la configuración efectiva en tiempo de ejecución (esto es lo que el agente realmente resolvió, no lo que pidió Helm):

```bash
cdbg config --all | head -40
kubectl -n kube-system get cm cilium-config -o yaml | head -60
```

3. Mirá los lazos de control propios del agente. Cilium modela casi cualquier tarea recurrente como un *controller* con backoff:

```bash
cdbg status --all-controllers | head -30
```

```
Controller Status:   48/48 healthy
  Name                                   Last success   Last error   Count   Message
  bpf-map-sync-cilium_lxc                4s ago         never        0       no error
  cilium-health-ep                       48s ago        never        0       no error
  endpoint-2438-regeneration-recovery    never          never        0       no error
  ipcache-inject-labels                  1m2s ago       never        0       no error
  k8s-heartbeat                          9s ago         never        0       no error
  resolve-identity-2438                  1m5s ago       never        0       no error
  sync-lb-maps-with-k8s-services         2m1s ago       never        0       no error
  template-dir-watcher                   never          never        0       no error
```

4. Inspeccioná los privilegios y los montajes del contenedor del agente — explican *por qué* puede hacer lo que hace:

```bash
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | python3 -m json.tool
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' | tr ' ' '\n'
```

```
/host/proc/sys/net
/host/proc/sys/kernel
/sys/fs/bpf
/var/run/cilium
/host/etc/cni/net.d
/host/opt/cni/bin
/run/xtables.lock
/var/lib/cilium/tls/hubble
...
```

5. Buscá los init containers — el pod del agente hace trabajo real antes de que el agente arranque:

```bash
kubectl -n kube-system get ds cilium -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}{"\n"}{end}'
```

```
config
mount-cgroup
apply-sysctl-overwrites
mount-bpf-fs
clean-cilium-state
install-cni-binaries
```

### Preguntas de control — Bloque 1

- **Q1.1** — `Modules Health: OK(52)` y `Controller Status: 48/48 healthy` son dos sistemas de salud distintos. ¿Qué cubre cada uno, y cuál mirarías primero si de golpe los pods de este nodo dejaran de recibir política nueva?
- **Q1.2** — `Proxy Status: ... Envoy: external`. ¿Qué diría este campo en un clúster instalado con `envoy.enabled=false`, y cuál es la consecuencia operativa concreta de que los dos modos difieran?
- **Q1.3** — IPAM reporta `10.244.1.148 (router)`. ¿Qué interfaz tiene esa dirección, cuál es su rol en el datapath, y por qué se asigna desde el CIDR de *pods* y no desde el CIDR de nodos?
- **Q1.4** — El init container `mount-bpf-fs` monta un filesystem BPF en `/sys/fs/bpf` **en el namespace del host**, no solo en el del pod. ¿Por qué un montaje en el namespace del host es obligatorio para que los reinicios del agente sean correctos?
- **Q1.5** — `clean-cilium-state` normalmente no hace nada. Nombrá los dos parámetros de Helm/entorno que lo activan, y describí el radio de daño de activar el destructivo en un nodo de producción.
- **Q1.6** — `Attach Mode: TCX` y `Device Mode: veth`. ¿Qué reemplaza TCX, qué versión de kernel lo introdujo, y a qué recurre Cilium en un kernel más viejo?

---

## Ejercicio 2 — Endpoints: la unidad que Cilium realmente gestiona

Kubernetes piensa en Pods. Cilium piensa en **endpoints**. El mapeo no es uno a uno.

1. Desplegá un workload repartido entre los dos workers:

```bash
kubectl create deployment nginx --image=nginx:1.27-alpine --replicas=4
kubectl create deployment client --image=nicolaka/netshoot --replicas=2 -- sleep infinity
kubectl rollout status deploy/nginx
kubectl get pods -o wide
```

2. Listá los endpoints de un nodo:

```bash
cdbg endpoint list
```

```
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                        IPv4           STATUS
           ENFORCEMENT        ENFORCEMENT
159        Disabled           Disabled          4          reserved:health                                    10.244.1.104   ready
912        Disabled           Disabled          1          k8s:node.kubernetes.io/exclude-from-external-lb
                                                           reserved:host                                                     ready
2438       Disabled           Disabled          14584      k8s:app=nginx
                                                           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
                                                           k8s:io.cilium.k8s.policy.cluster=default
                                                           k8s:io.cilium.k8s.policy.serviceaccount=default
                                                           k8s:io.kubernetes.pod.namespace=default          10.244.1.29    ready
3117       Disabled           Disabled          61203      k8s:app=client
                                                           ...                                              10.244.1.212   ready
```

3. Metete en el modelo completo de un endpoint:

```bash
cdbg endpoint get 2438 | python3 -m json.tool | head -60
cdbg endpoint log 2438
```

```
Timestamp                Code    Type      Message
2026-09-01T12:03:58Z     OK      Ready     Successfully regenerated endpoint program (Reason: updated security labels)
2026-09-01T12:03:58Z     OK      Waiting-to-regenerate  Triggering endpoint regeneration due to policy updates
2026-09-01T12:03:57Z     OK      Ready     Successfully regenerated endpoint program (Reason: Initial build)
2026-09-01T12:03:56Z     OK      Waiting-for-identity   Waiting for endpoint to obtain a security identity
```

4. Correlacioná el endpoint con su espejo visible desde Kubernetes:

```bash
kubectl get ciliumendpoints.cilium.io -A -o wide
kubectl get ciliumendpoint -n default -o jsonpath='{.items[0].status.identity.id}{"\n"}'
```

5. Encontrá el lado host del par veth del pod y los programas BPF adosados a él:

```bash
cdbg endpoint get 2438 -o jsonpath='{[0].status.networking.host-interface-name}'
# then, on the node (docker exec into the kind node):
docker exec -it cca-lab-worker bash -c 'ip -d link show type veth | grep -A2 lxc'
docker exec -it cca-lab-worker bpftool net show dev lxc1a2b3c4d5e6f
```

```
tc:
lxc1a2b3c4d5e6f(12) tcx/ingress cil_from_container prog_id 412
lxc1a2b3c4d5e6f(12) tcx/egress  cil_to_container   prog_id 418
```

6. Forzá una regeneración y mirá cómo avanza la máquina de estados:

```bash
kubectl label pod -l app=nginx tier=frontend --overwrite
cdbg endpoint list | grep nginx -A1
cdbg endpoint log 2438 | head -5
```

### Preguntas de control — Bloque 2

- **Q2.1** — El endpoint `912` tiene identidad `1` y **ninguna dirección IPv4** en el listado, y sin embargo es un endpoint plenamente gestionado. ¿Qué es, y qué se rompe si escribís una política que se olvida de que existe?
- **Q2.2** — El endpoint `159` lleva `reserved:health` y una IP de pod real, pero `kubectl get pods -A` no muestra ningún pod así. ¿De dónde sale y para qué se usa?
- **Q2.3** — Dos de las cuatro réplicas de nginx aterrizaron en este nodo, pero `cilium-dbg endpoint list` las muestra compartiendo una única identidad `14584`. Explicá la relación entre *cantidad de endpoints* y *cantidad de identidades*, y dá la fórmula que determina cuándo se acuña una identidad nueva.
- **Q2.4** — Compará `cilium-dbg endpoint list` (agente) con `kubectl get ciliumendpoints` (API server). ¿Cuál es autoritativo para el datapath, cuál es autoritativo para la observabilidad a nivel de clúster, y qué le pasa a cada uno si el API server queda inalcanzable durante 10 minutos?
- **Q2.5** — En el paso 5, el ingress del **lado host** del veth se llama `cil_from_container`. ¿Desde qué perspectiva está escrito "from container", y por qué el tráfico que *sale del pod* pega en un programa adosado a *ingress*?
- **Q2.6** — En el paso 6 agregaste una etiqueta. Trazá la cadena causal desde `kubectl label` hasta la carga de un nuevo array de bytes de programa eBPF. Nombrá al menos cuatro etapas intermedias.

---

## Ejercicio 3 — Identidades, etiquetas y el ipcache

Esta es la abstracción central de Cilium y una fuente confiable de preguntas de examen.

1. Listá todas las identidades que el clúster conoce:

```bash
cdbg identity list
```

```
ID       LABELS
1        reserved:host
2        reserved:world
3        reserved:unmanaged
4        reserved:health
5        reserved:init
6        reserved:remote-node
7        reserved:kube-apiserver
8        reserved:ingress
14584    k8s:app=nginx
         k8s:io.cilium.k8s.policy.cluster=default
         k8s:io.cilium.k8s.policy.serviceaccount=default
         k8s:io.kubernetes.pod.namespace=default
61203    k8s:app=client
         ...
```

2. Mirá cómo se *almacenan* las identidades en esta instalación:

```bash
cdbg status | grep -i kvstore
kubectl get ciliumidentities.cilium.io
kubectl get ciliumidentity 14584 -o yaml | yq '.security-labels'
```

3. Leé el ipcache — el mapa que responde "¿qué identidad es dueña de esta IP, y dónde vive?":

```bash
cdbg bpf ipcache list | head -20
```

```
IP PREFIX/ADDRESS    IDENTITY
0.0.0.0/0            identity=2     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
10.244.0.0/24        identity=6     encryptkey=0 tunnelendpoint=172.18.0.2  flags=<none>
10.244.0.145/32      identity=14584 encryptkey=0 tunnelendpoint=172.18.0.4  flags=<none>
10.244.1.29/32       identity=14584 encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
10.244.1.104/32      identity=4     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
172.18.0.2/32        identity=7     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
172.18.0.3/32        identity=1     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
172.18.0.4/32        identity=6     encryptkey=0 tunnelendpoint=0.0.0.0     flags=<none>
```

4. Hacé que Cilium acuñe una identidad **local** escribiendo una política basada en CIDR:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-example-net
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: client
  egress:
    - toCIDR:
        - 93.184.216.0/24
EOF

cdbg identity list | tail -5
cdbg bpf ipcache list | grep 93.184
```

```
16777217   cidr:93.184.216.0/24
           reserved:world
```

5. Observá una identidad en uso dentro de un veredicto de política en vivo:

```bash
cdbg monitor -t policy-verdict --related-to 3117
# in another terminal:
kubectl exec deploy/client -- curl -s -o /dev/null -w '%{http_code}\n' http://nginx
```

```
Policy verdict log: flow 0x8c1d2e3f local EP ID 3117, remote ID 14584, proto 6, egress, action allow, auth: disabled, match L3-Only, 10.244.1.212:54322 -> 10.244.1.29:80 tcp SYN
```

### Preguntas de control — Bloque 3

- **Q3.1** — La identidad `14584` apareció en *ambos* workers para pods con las mismas etiquetas. ¿Qué componente garantiza ese acuerdo, y qué saldría mal, en términos de política, si dos nodos eligieran de forma independiente números distintos para el mismo conjunto de etiquetas?
- **Q3.2** — La identidad `16777217` queda muy afuera del rango global `min 256, max 65535` que reporta `cilium-dbg status`. ¿Qué clase de identidad es, por qué se asigna desde un rango distinto, y el *mismo* número está garantizado que signifique lo mismo en el otro worker?
- **Q3.3** — La entrada de ipcache para `10.244.0.145/32` tiene `tunnelendpoint=172.18.0.4`, mientras que `10.244.1.29/32` tiene `tunnelendpoint=0.0.0.0`. Explicá ambas, y predecí cómo se vería la columna `tunnelendpoint` en general si reinstalaras con `routingMode=native`.
- **Q3.4** — `172.18.0.2/32` resolvió a la identidad `7` (`reserved:kube-apiserver`) mientras que las otras IPs de nodo resolvieron a `6` (`reserved:remote-node`). ¿Qué produjo esa distinción, y por qué importa a la hora de escribir una política que permita a los pods hablar con el API server?
- **Q3.5** — La identidad `2` (`reserved:world`) está ligada a `0.0.0.0/0`. Cuando Cilium además usa `reserved:world-ipv4` (9) y `reserved:world-ipv6` (10), ¿qué cambió y por qué?
- **Q3.6** — Se borra un pod y sus etiquetas desaparecen. ¿Qué componente elimina el objeto `CiliumIdentity` ahora sin referencias, con qué disparador, y cuál es el síntoma de falla si ese componente está caído durante una semana en un clúster con mucha rotación?

---

## Ejercicio 4 — `cilium-operator`: la mitad con alcance de clúster

El operator es fácil de subestimar porque nada se rompe en el segundo en que muere.

1. Leé sus argumentos — son una lista literal de sus responsabilidades:

```bash
kubectl -n kube-system get deploy cilium-operator \
  -o jsonpath='{.spec.template.spec.containers[0].command}{"\n"}{.spec.template.spec.containers[0].args}' \
  | tr ',' '\n'
kubectl -n kube-system logs deploy/cilium-operator | head -40
```

```
level=info msg="Cilium Operator 1.17.4"
level=info msg="Leading the operator HA deployment" subsys=cilium-operator-generic
level=info msg="Starting apiserver on address :9234" subsys=cilium-operator-generic
level=info msg="Starting CNP derivative handler" subsys=cilium-operator-generic
level=info msg="Starting to synchronize CiliumNode custom resources" subsys=cilium-operator-generic
level=info msg="Starting CiliumEndpointSlice controller" subsys=cilium-operator-generic
level=info msg="Garbage collecting stale CiliumEndpoint custom resources" subsys=cilium-operator-generic
```

2. Inspeccioná el recurso que el operator escribe y que todos los agentes leen:

```bash
kubectl get ciliumnodes.cilium.io -o custom-columns=\
'NODE:.metadata.name,CIDR:.spec.ipam.podCIDRs,ROUTER:.spec.addresses[?(@.type=="CiliumInternalIP")].ip'
kubectl get ciliumnode cca-lab-worker -o yaml | yq '.spec.ipam' | head -20
```

```
NODE                    CIDR                ROUTER
cca-lab-control-plane   [10.244.0.0/24]     10.244.0.87
cca-lab-worker          [10.244.1.0/24]     10.244.1.148
cca-lab-worker2         [10.244.2.0/24]     10.244.2.63
```

3. Comprobá el dominio de falla. Escalá el operator a cero y probá tres operaciones distintas:

```bash
kubectl -n kube-system scale deploy/cilium-operator --replicas=0

# (a) existing traffic
kubectl exec deploy/client -- curl -s -o /dev/null -w 'existing-traffic:%{http_code}\n' http://nginx

# (b) a new pod on an existing node
kubectl create deployment probe --image=nginx:1.27-alpine
kubectl rollout status deploy/probe --timeout=60s

# (c) identity churn
kubectl delete deploy probe
kubectl get ciliumidentities.cilium.io --no-headers | wc -l
sleep 120
kubectl get ciliumidentities.cilium.io --no-headers | wc -l
```

4. Restauralo y mirá la reconciliación:

```bash
kubectl -n kube-system scale deploy/cilium-operator --replicas=1
kubectl -n kube-system logs deploy/cilium-operator | grep -i 'garbage\|deleted'
kubectl get ciliumidentities.cilium.io --no-headers | wc -l
```

5. Examiná el camino alternativo de escalado de endpoints:

```bash
kubectl get crd ciliumendpointslices.cilium.io
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-cilium-endpoint-slice}{"\n"}'
```

### Preguntas de control — Bloque 4

- **Q4.1** — En el paso 3, ¿cuál de (a), (b) y (c) se degradó realmente? Explicá cada resultado en términos de *quién* hace el trabajo.
- **Q4.2** — Agregás un nodo nuevo al clúster mientras el operator está escalado a cero, con `ipam.mode=cluster-pool`. ¿Cuál es el síntoma preciso en ese nodo, y qué campo queda vacío?
- **Q4.3** — Ahora respondé de nuevo la Q4.2 para `ipam.mode=kubernetes`. ¿Por qué cambia la respuesta, y cuál es el trade-off entre los dos modos?
- **Q4.4** — El operator soporta `operator.replicas=2` con elección de líder, mientras que `cilium-agent` no tiene tal concepto. Justificá ambos diseños desde primeros principios.
- **Q4.5** — En un clúster de 5.000 nodos con 100.000 pods, ¿cuál es el problema de carga sobre el API server con un `CiliumEndpoint` por pod, y cómo cambia la aritmética `CiliumEndpointSlice`? ¿Qué componente produce los slices?
- **Q4.6** — Nombrá tres tareas del operator que solo existen cuando una funcionalidad específica está habilitada (es decir, que están ausentes en esta instalación mínima).

---

## Ejercicio 5 — El plugin CNI y el camino de attach del pod

1. Encontrá el binario del plugin y la configuración, ambos colocados en el host por el pod del agente:

```bash
docker exec cca-lab-worker ls -l /opt/cni/bin/ /etc/cni/net.d/
docker exec cca-lab-worker cat /etc/cni/net.d/05-cilium.conflist
```

```json
{
  "cniVersion": "1.0.0",
  "name": "cilium",
  "plugins": [
    {
      "type": "cilium-cni",
      "enable-debug": false,
      "log-file": "/var/run/cilium/cilium-cni.log"
    }
  ]
}
```

2. Mirá un attach de pod de punta a punta. Abrí primero el log del CNI y después creá un pod:

```bash
# terminal 1
docker exec cca-lab-worker tail -f /var/run/cilium/cilium-cni.log
# terminal 2
kubectl run cnitest --image=nginx:1.27-alpine --overrides='{"spec":{"nodeName":"cca-lab-worker"}}'
```

```
level=info msg="Processing CNI ADD request" containerID=9f3c... eventUUID=...
level=info msg="Endpoint successfully created" endpointID=1204 containerID=9f3c...
```

3. Confirmá que el socket local de la API del agente es el transporte:

```bash
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- ls -l /var/run/cilium/
```

```
srw-rw---- 1 root root  0 Sep  1 12:03 cilium.sock
srw-rw---- 1 root root  0 Sep  1 12:03 health.sock
srw-rw---- 1 root root  0 Sep  1 12:03 hubble.sock
drwxr-xr-x 3 root root 60 Sep  1 12:03 state
```

4. Ahora rompelo a propósito. Borrá el agente de ese nodo y tratá de crear un pod:

```bash
kubectl -n kube-system delete pod $(basename $CILIUM_POD) --wait=false
kubectl -n kube-system patch ds cilium -p '{"spec":{"template":{"spec":{"nodeSelector":{"disabled":"true"}}}}}'
kubectl -n kube-system get pods -o wide | grep cilium

# existing pods:
kubectl exec deploy/client -- curl -s -o /dev/null -w 'existing:%{http_code}\n' http://nginx
# new pod on the agent-less node:
kubectl run orphan --image=nginx:1.27-alpine --overrides='{"spec":{"nodeName":"cca-lab-worker"}}'
kubectl describe pod orphan | tail -8
```

```
Warning  FailedCreatePodSandBox  8s  kubelet  Failed to create pod sandbox: plugin type="cilium-cni"
failed (add): unable to connect to Cilium daemon: failed to create cilium agent client after 30.000000
seconds timeout: Get "http://localhost/v1/config": dial unix /var/run/cilium/cilium.sock: connect:
no such file or directory
```

5. Restaurá:

```bash
kubectl -n kube-system patch ds cilium --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/disabled"}]'
kubectl -n kube-system rollout status ds/cilium
kubectl delete pod orphan cnitest --ignore-not-found
```

### Preguntas de control — Bloque 5

- **Q5.1** — En el paso 4, los pods existentes siguieron sirviendo tráfico mientras que no se pudieron crear pods nuevos. Explicá las dos mitades en términos de dónde vive el estado de forwarding versus dónde vive el plano de control.
- **Q5.2** — `cilium-cni` es un proceso de vida corta invocado por el container runtime, no un daemon. ¿Cuáles son las dos cosas que debe hacer y que requieren al agente, y por qué *no* embeber esa lógica en el plugin es el diseño correcto?
- **Q5.3** — El archivo se llama `05-cilium.conflist`. ¿Cuál es el significado del prefijo numérico, y cuál es el modo de falla si un segundo CNI dejó atrás un `00-something.conflist`?
- **Q5.4** — Distinguí el **encadenamiento de CNI** (`cni.chainingMode=aws-cni` / `generic-veth`) del modo autónomo en el que estás corriendo. ¿Qué muestra `cilium-dbg status` en cada caso, y qué funcionalidades de Cilium no están disponibles cuando está encadenado?
- **Q5.5** — Un nodo se reinicia. Entre el arranque del kernel y el momento en que `cilium-agent` queda listo, kubelet puede intentar arrancar pods. ¿Qué dos mecanismos evitan que los pods levanten con la red rota?

---

## Ejercicio 6 — El datapath eBPF: programas y mapas

1. Enumerá los mapas pineados. Esto es todo el estado de forwarding de Cilium:

```bash
docker exec cca-lab-worker ls /sys/fs/bpf/tc/globals/
cdbg map list --verbose | head -40
```

```
Name                       Num entries   Num errors   Cache enabled
cilium_lxc                 4             0            true
cilium_ipcache_v2          21            0            true
cilium_policy_v2_02438     3             0            true
cilium_lb4_services_v2     14            0            true
cilium_lb4_backends_v3     9             0            true
cilium_lb4_reverse_nat     7             0            true
cilium_ct4_global          312           0            false
cilium_ct_any4_global      44            0            false
cilium_snat_v4_external    18            0            false
cilium_tunnel_map          2             0            true
cilium_metrics             6             0            false
cilium_node_map            3             0            true
cilium_runtime_config      1             0            false
```

2. Leé tres de ellos a mano:

```bash
cdbg bpf endpoint list      # cilium_lxc: local IP -> endpoint metadata
cdbg bpf tunnel list        # cilium_tunnel_map: remote pod CIDR -> node underlay IP
cdbg bpf ct list global | head -10
```

```
IP ADDRESS       LOCAL ENDPOINT INFO
10.244.1.29:0    id=2438  sec_id=14584  flags=0x0000 ifindex=12  mac=1A:2B:3C:4D:5E:6F  nodemac=AE:BF:C0:D1:E2:F3

TUNNEL           VALUE
10.244.0.0/24    172.18.0.2
10.244.2.0/24    172.18.0.4

TCP OUT 10.244.1.212:54322 -> 10.244.1.29:80 expires=17284 RxPackets=6 TxPackets=5 Flags=0x0013 ...
```

3. Mirá los programas, no solo los mapas:

```bash
docker exec cca-lab-worker bpftool prog show | grep -c 'sched_cls\|cgroup'
docker exec cca-lab-worker bpftool net show | head -20
```

```
tc:
eth0(2)     tcx/ingress cil_from_netdev  prog_id 388
eth0(2)     tcx/egress  cil_to_netdev    prog_id 391
cilium_host(9)  tcx/ingress cil_to_host  prog_id 372
cilium_net(8)   tcx/ingress cil_from_host prog_id 366
cilium_vxlan(10) tcx/ingress cil_from_overlay prog_id 379
lxc1a2b3c4d5e6f(12) tcx/ingress cil_from_container prog_id 412

cgroup:
/run/cilium/cgroupv2  connect4  cil_sock4_connect  prog_id 340
/run/cilium/cgroupv2  sendmsg4  cil_sock4_sendmsg  prog_id 344
```

4. Mapeá cada interfaz que acabás de ver:

```bash
docker exec cca-lab-worker ip -br addr show
docker exec cca-lab-worker ip route show
```

```
lo               UNKNOWN  127.0.0.1/8
eth0             UP       172.18.0.3/16
cilium_net@cilium_host  UP
cilium_host@cilium_net  UP  10.244.1.148/32
cilium_vxlan     UNKNOWN
lxc_health@if11  UP
lxc1a2b3c4d5e6f@if3  UP
```

5. Verificá la propiedad de persistencia que hace que los reinicios del agente no sean disruptivos:

```bash
docker exec cca-lab-worker stat -c '%i %n' /sys/fs/bpf/tc/globals/cilium_lxc
kubectl -n kube-system delete pod $(basename $CILIUM_POD)
sleep 5
# during the restart window, from another pod:
kubectl exec deploy/client -- curl -s -o /dev/null -w 'during-restart:%{http_code}\n' http://nginx
kubectl -n kube-system rollout status ds/cilium
docker exec cca-lab-worker stat -c '%i %n' /sys/fs/bpf/tc/globals/cilium_lxc
```

6. Mirá lo que el agente dejó en disco para que eso fuera posible:

```bash
docker exec cca-lab-worker ls /var/run/cilium/state/
docker exec cca-lab-worker ls /var/run/cilium/state/2438/
```

```
2438/  3117/  159/  912/  globals/  templates/
ep_config.h  lxc_config.h  bpf_lxc.o
```

### Preguntas de control — Bloque 6

- **Q6.1** — `cilium_ct4_global` muestra `Cache enabled: false` mientras que `cilium_lxc` muestra `true`. ¿Qué hace la caché en espacio de usuario del agente, y por qué se excluye conntrack?
- **Q6.2** — Hay programas en `cilium_host`, `cilium_net`, `eth0`, `cilium_vxlan` y en cada `lxc*`. Trazá un paquete desde `client` en worker hasta `nginx` en worker2, nombrando cada programa que atraviesa en orden, e indicá dónde ocurre el encapsulado VXLAN.
- **Q6.3** — Dos programas están adosados a un **cgroup**, no a `tc`: `cil_sock4_connect` y `cil_sock4_sendmsg`. ¿Qué funcionalidad implementan, qué le hacen al camino del paquete, y cuál es el efecto secundario observable dentro del pod cuando ejecutás `tcpdump`?
- **Q6.4** — En el paso 5, el inodo de `cilium_lxc` fue idéntico antes y después del reinicio del agente, y el tráfico nunca se cortó. Explicá el mecanismo con precisión, y nombrá el único cambio de configuración que *sí* habría causado una interrupción del datapath al reiniciar.
- **Q6.5** — `/var/run/cilium/state/2438/` contiene `lxc_config.h` y un `bpf_lxc.o` compilado. ¿Qué hace Cilium en el momento de la regeneración de un endpoint, del cual estos archivos son los artefactos, y cómo reduce ese costo el directorio `templates/`?
- **Q6.6** — `cilium_host` tiene `10.244.1.148/32` — la IP del router — y `cilium_net` no tiene nada. ¿Por qué es un *par* veth y no una única interfaz dummy?

---

## Ejercicio 7 — Reemplazo de kube-proxy: services en BPF

1. Confirmá en qué modo estás y sobre qué dispositivos:

```bash
cdbg status --verbose | grep -A3 KubeProxyReplacement
docker exec cca-lab-worker iptables-save | grep -c KUBE-SVC || echo "0 kube-proxy chains"
```

2. Creá un service y encontralo en los mapas LB de BPF:

```bash
kubectl expose deploy/nginx --port=80 --name=nginx
kubectl expose deploy/nginx --port=80 --name=nginx-np --type=NodePort
kubectl get svc

cdbg service list
cdbg bpf lb list
```

```
ID   Frontend             Service Type   Backend
1    10.96.0.1:443/TCP    ClusterIP      1 => 172.18.0.2:6443/TCP (active)
3    10.96.0.10:53/UDP    ClusterIP      1 => 10.244.0.87:53/UDP (active)
                                         2 => 10.244.2.19:53/UDP (active)
9    10.101.44.7:80/TCP   ClusterIP      1 => 10.244.1.29:80/TCP (active)
                                         2 => 10.244.2.55:80/TCP (active)
                                         ...
10   0.0.0.0:31654/TCP    NodePort       1 => 10.244.1.29:80/TCP (active)
                                         ...
11   172.18.0.3:31654/TCP NodePort       ...
```

3. Comprobá dónde ocurre la traducción para una conexión originada en un pod:

```bash
kubectl exec -it deploy/client -- bash -c \
  'timeout 5 tcpdump -ni any -c 4 "tcp port 80" & sleep 1; curl -s -o /dev/null http://nginx; wait'
```

4. Compará con una conexión que entra desde fuera del nodo:

```bash
NODE_IP=$(docker inspect cca-lab-worker -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
curl -s -o /dev/null -w '%{http_code}\n' http://$NODE_IP:31654
cdbg bpf lb list --revnat
cdbg bpf nat list | head -5
```

5. Mirá el mapa a nivel de socket y las estructuras de maglev/afinidad:

```bash
cdbg map get cilium_lb4_reverse_sk 2>/dev/null | head -5
cdbg bpf lb maglev list 2>/dev/null || echo "maglev not enabled (default: random)"
```

### Preguntas de control — Bloque 7

- **Q7.1** — En el paso 3, `tcpdump` dentro del pod cliente mostró como destino una **IP de pod**, no el ClusterIP. ¿Qué programa eBPF hizo esa sustitución, en qué hook, y cuál es la consecuencia de rendimiento frente a un DNAT a nivel de `tc`?
- **Q7.2** — Una conexión NodePort que llega por `eth0` no puede usar el hook de socket. ¿Dónde se traduce en su lugar, y qué mapa provee la des-traducción en el camino de respuesta?
- **Q7.3** — `cilium-dbg service list` y `cilium-dbg bpf lb list` presentan datos que se solapan. ¿Cuál es la vista de espacio de usuario y cuál la del kernel, y qué te dice una discrepancia entre ambas?
- **Q7.4** — `kubeProxyReplacement=true` versus `false` con `nodePort.enabled=true`: describí qué hace cada uno, y nombrá una cosa que solo te da el reemplazo completo.
- **Q7.5** — Explicá por qué `k8sServiceHost`/`k8sServicePort` se vuelven **obligatorios** en modo de reemplazo completo en un clúster sin kube-proxy, y qué pasa si los apuntás a un ClusterIP.
- **Q7.6** — La selección de backend de un service es `random` por defecto. Nombrá la alternativa, el mapa que puebla, y el escenario en el que la alternativa es estrictamente mejor.

---

## Ejercicio 8 — Hubble: el plano de observabilidad

Hubble no es un agente aparte. Entender *dónde* corre es el punto de examen.

1. Localizá el servidor de Hubble:

```bash
cdbg status | grep -i hubble
kubectl -n kube-system get ds cilium -o yaml | grep -A2 'name: hubble'
kubectl -n kube-system get svc hubble-peer hubble-relay
```

```
Hubble:   Ok   Current/Max Flows: 4095/4095 (100.00%), Flows/s: 11.72

NAME           TYPE        CLUSTER-IP       PORT(S)
hubble-peer    ClusterIP   10.96.201.14     443/TCP
hubble-relay   ClusterIP   10.99.7.60       80/TCP
```

2. Consultá flujos de **un solo nodo**, usando el socket local del agente:

```bash
kubectl -n kube-system exec -it $CILIUM_POD -c cilium-agent -- \
  hubble observe --server unix:///var/run/cilium/hubble.sock --last 5
```

```
Sep  1 12:22:41.115: default/client-7f9d-abc:54322 (ID:61203) -> default/nginx-6f8c-xyz:80 (ID:14584) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:22:41.115: default/nginx-6f8c-xyz:80 (ID:14584) <- default/client-7f9d-abc:54322 (ID:61203) to-stack FORWARDED (TCP Flags: SYN, ACK)
```

3. Consultá flujos de **todo el clúster** a través de Relay:

```bash
cilium hubble port-forward &
hubble status
hubble observe --namespace default --last 20
hubble observe --namespace default --type drop
```

```
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 12,285/12,285 (100.00%)
Flows/s: 34.19
Connected Nodes: 3/3
```

4. Hacé explícita la dependencia de Relay — cortá el agente de un nodo y volvé a chequear:

```bash
kubectl -n kube-system delete pod $(basename $CILIUM_POD)
hubble status
```

```
Connected Nodes: 2/3
Unavailable Nodes: 1
  cca-lab-worker: rpc error: code = Unavailable desc = connection error
```

5. Inspeccioná cómo Relay descubre a los agentes:

```bash
kubectl -n kube-system get svc hubble-peer -o yaml | yq '.spec'
kubectl -n kube-system logs deploy/hubble-relay | grep -i peer | head -5
```

6. Habilitá métricas y mirá quién las expone:

```bash
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.hubble-metrics}{"\n"}'
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].ports}' \
  | python3 -m json.tool
```

### Preguntas de control — Bloque 8

- **Q8.1** — `Current/Max Flows: 4095/4095 (100.00%)` parece una alarma de saturación. ¿Qué está reportando en realidad, y cuál es la estructura de datos detrás?
- **Q8.2** — Dibujá el camino de consulta de un `hubble observe --namespace default` ejecutado desde tu laptop. Nombrá cada proceso y cada salto de puerto, e indicá cuál de ellos es sin estado.
- **Q8.3** — En el paso 4, Relay reportó `2/3` mientras el agente se reiniciaba, pero los dos nodos sobrevivientes siguieron respondiendo. ¿Cuál es el modelo de disponibilidad, y los flujos *históricos* del nodo faltante eran recuperables después de que volvió?
- **Q8.4** — `hubble-peer` es un Service sin ningún Deployment detrás. ¿Qué selecciona, por qué hace falta un Service dedicado, y qué se rompería si lo borraras?
- **Q8.5** — Los flujos de Hubble se derivan de un perf ring buffer escrito por el datapath. Nombrá el mapa y explicá la característica de muestreo/pérdida que hace que Hubble no sirva como fuente de facturación o de auditoría de registro.
- **Q8.6** — ¿De dónde vienen las *métricas* de Hubble — de Relay o de los agentes — y cuál es el riesgo de cardinalidad de habilitar `hubble-metrics: "flow:sourceContext=pod;destinationContext=pod"` en un clúster grande?

---

## Ejercicio 9 — El proxy L7: `cilium-envoy`

1. Establecé la forma del despliegue:

```bash
kubectl -n kube-system get ds cilium-envoy -o wide
kubectl -n kube-system get cm cilium-envoy-config -o yaml | head -30
cdbg status --verbose | grep -i 'proxy status'
```

2. Aplicá una política L7 y mirá aparecer un redirect:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-http
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/$"
EOF

cdbg status | grep -i 'proxy status'
cdbg bpf proxy list
```

```
Proxy Status:   OK, ip 10.244.1.148, 1 redirects active on ports 10000-20000, Envoy: external
```

3. Generá una petición permitida y una denegada y leé el veredicto L7:

```bash
kubectl exec deploy/client -- curl -s -o /dev/null -w 'GET /   -> %{http_code}\n' http://nginx/
kubectl exec deploy/client -- curl -s -o /dev/null -w 'POST /  -> %{http_code}\n' -X POST http://nginx/
hubble observe --namespace default --protocol http --last 5
```

```
Sep  1 12:31:02.771: default/client-...:41002 -> default/nginx-...:80 http-request FORWARDED (HTTP/1.1 GET http://nginx/)
Sep  1 12:31:03.118: default/client-...:41004 -> default/nginx-...:80 http-request DROPPED (HTTP/1.1 POST http://nginx/)
```

4. Inspeccioná la propia vista de Envoy:

```bash
cdbg envoy admin listeners 2>/dev/null | head -20 \
  || kubectl -n kube-system exec ds/cilium-envoy -- \
       curl -s --unix-socket /var/run/cilium/envoy/sockets/admin.sock http://admin/listeners | head -20
```

5. Mirá el CRD que te permite manejar Envoy directamente:

```bash
kubectl get crd ciliumenvoyconfigs.cilium.io ciliumclusterwideenvoyconfigs.cilium.io
kubectl explain ciliumenvoyconfig.spec --recursive | head -20
```

### Preguntas de control — Bloque 9

- **Q9.1** — Antes de la política L7, `Proxy Status` reportaba `0 redirects`. ¿Qué es exactamente un "redirect" acá, qué mapa lo contiene, y qué hace distinto el datapath con un paquete que coincide con uno?
- **Q9.2** — El POST fue `DROPPED` en `http-request`, no en `to-endpoint`. ¿Qué componente tomó esa decisión, y en qué punto del camino respecto del mapa de política eBPF?
- **Q9.3** — Desde Cilium 1.16 el default es un DaemonSet `cilium-envoy` autónomo en lugar de Envoy embebido en el proceso del agente. Dá dos ventajas operativas concretas, y un nuevo modo de falla que esto introduce.
- **Q9.4** — Una política L7 cuesta medibemente más que una L3/L4. Explicá la razón mecánica, e indicá qué le pasa al tráfico que *no* coincide en el mismo endpoint.
- **Q9.5** — ¿Para qué sirve `CiliumEnvoyConfig`, y qué dos funcionalidades nativas de Cilium están implementadas encima de él en lugar de con código a medida?
- **Q9.6** — Si `cilium-envoy` no está disponible en un nodo donde rige una política L7, ¿qué le pasa al tráfico afectado — fail-open o fail-closed? Justificalo a partir del mecanismo de redirect.

---

## Ejercicio 10 — Salud del clúster y un barrido diagnóstico completo

1. Leé la malla de salud nodo-a-nodo propia de Cilium:

```bash
cdbg status --all-health | head -30
```

```
Cluster health:                   3/3 reachable   (2026-09-01T12:35:00Z)
Name                              IP              Node        Endpoints
cca-lab/cca-lab-worker (localhost)
  Host connectivity to 172.18.0.3:
    ICMP to stack:   OK, RTT=241.9µs
    HTTP to agent:   OK, RTT=189.4µs
  Endpoint connectivity to 10.244.1.104:
    ICMP to stack:   OK, RTT=255.1µs
    HTTP to agent:   OK, RTT=203.7µs
cca-lab/cca-lab-worker2
  Host connectivity to 172.18.0.4:
    ICMP to stack:   OK, RTT=612.3µs
    HTTP to agent:   OK, RTT=744.0µs
  Endpoint connectivity to 10.244.2.63:
    ICMP to stack:   OK, RTT=655.8µs
    HTTP to agent:   OK, RTT=781.2µs
```

2. Ejecutá la suite de punta a punta que viene empaquetada:

```bash
cilium connectivity test --test-concurrency 2
```

3. Recolectá un bundle de soporte y leé su estructura — esto es lo que adjuntás a un reporte de bug:

```bash
cilium sysdump --output-filename cca-sysdump
mkdir -p /tmp/sd && tar xzf cca-sysdump.zip -C /tmp/sd 2>/dev/null || unzip -q cca-sysdump.zip -d /tmp/sd
find /tmp/sd -maxdepth 2 -type d | head -20
```

4. Hacé una investigación puntual de drops:

```bash
cdbg monitor -t drop --numeric &
kubectl exec deploy/client -- curl -s --max-time 3 -X POST http://nginx/ || true
cdbg metrics list | grep -i drop
```

```
xx drop (Policy denied) flow 0x0 to endpoint 2438, ID 61203->14584, identity 61203->14584: 10.244.1.212:41008 -> 10.244.1.29:80 tcp SYN
```

5. Limpiá:

```bash
kubectl delete cnp l7-http allow-example-net --ignore-not-found
kubectl delete deploy nginx client --ignore-not-found
kubectl delete svc nginx nginx-np --ignore-not-found
kind delete cluster --name cca-lab
```

### Preguntas de control — Bloque 10

- **Q10.1** — Las sondas de salud reportan tanto "Host connectivity" como "Endpoint connectivity" para cada nodo. ¿Por qué dos? ¿Qué significa que host esté OK y endpoint no?
- **Q10.2** — ¿Qué endpoint origina las sondas de "Endpoint connectivity", y qué identidad reservada lleva? ¿Qué implica eso para una política `default-deny` a nivel de todo el clúster?
- **Q10.3** — `cilium sysdump` junta datos de todos los componentes. Nombrá cuatro clases de artefacto que recolecta y que **no** podrías reconstruir después del hecho desde un clúster en marcha.
- **Q10.4** — Ves drops con `Policy denied` e `identity 61203->14584`. Listá, en orden, los tres comandos que ejecutarías para convertir esos números en una causa raíz.
- **Q10.5** — Ordená estos cinco componentes por radio de daño si falla una única instancia: `cilium-agent`, `cilium-operator`, `cilium-envoy`, `hubble-relay`, `hubble-ui`. Para cada uno, indicá qué deja de funcionar *inmediatamente* versus *con el tiempo*.

---

<details>
<summary><strong>Respuestas — expandir solo después de intentar todos los bloques</strong></summary>

### Bloque 0

**A0.1** — Sin kube-proxy nada programa `10.96.0.1:443`, y Cilium es justamente lo que *lo programaría* — pero necesita el API server primero. La ruptura consiste en que a `cilium-agent` se le indica la **dirección real** del API server directamente, salteando la resolución de services: `k8sServiceHost=cca-lab-control-plane` y `k8sServicePort=6443`. El agente se conecta a ese endpoint, aprende el estado del clúster, y recién entonces instala la entrada de ClusterIP que usa todo lo demás. De forma equivalente podés usar `k8sServiceHost=auto` en releases más nuevas, o una variable de entorno `KUBERNETES_SERVICE_HOST`. Apuntar estos valores a un ClusterIP es un deadlock de arranque.

**A0.2** —
| Workload | Ubicación | Tipo de objeto |
|---|---|---|
| `cilium` (agente) | por nodo | DaemonSet |
| `cilium-envoy` | por nodo | DaemonSet |
| `cilium-operator` | singleton de clúster (con capacidad HA, elección de líder) | Deployment |
| `hubble-relay` | singleton de clúster | Deployment |
| `hubble-ui` | singleton de clúster | Deployment |

La regla: todo lo que toca el datapath del kernel de un nodo tiene que ser un DaemonSet; todo lo que reconcilia estado con alcance de clúster o agrega datos es un Deployment.

**A0.3** — `cilium-agent` — específicamente su init container `install-cni-binaries` más el agente escribiendo `/etc/cni/net.d/05-cilium.conflist`. La implementación de CRI de kubelet consulta `/etc/cni/net.d`; un nodo sin configuración CNI válida reporta `NetworkPluginNotReady` y queda `NotReady`, que es la razón por la que CoreDNS no era schedulable. La interfaz es **CNI** (Container Network Interface), invocada por el container runtime, no por Cilium.

**A0.4** — Dos audiencias:
- `cilium` (**cilium-cli**) corre en tu estación de trabajo, habla con la **API de Kubernetes**, y hace operaciones a nivel de clúster: install, upgrade, `status`, `connectivity test`, `sysdump`, `hubble port-forward`.
- `cilium-dbg` corre **dentro del pod del agente**, habla con el socket unix local del agente `/var/run/cilium/cilium.sock`, e inspecciona el datapath de **un solo nodo**: endpoints, identidades, mapas BPF, monitor.

Antes de Cilium **1.16** el binario dentro del pod también se llamaba `cilium`, lo que hacía ambigua cada pieza de documentación. Fue renombrado a `cilium-dbg`; queda en la imagen un shim `cilium` deprecado por compatibilidad.

---

### Bloque 1

**A1.1** — Son dos generaciones distintas de la misma idea.
- Los **controllers** son los lazos de reintento por tarea de toda la vida (`resolve-identity-2438`, `sync-lb-maps-with-k8s-services`, `bpf-map-sync-*`). Cada uno tiene un timestamp de último éxito, un último error y un contador de fallas consecutivas.
- **Modules Health** es el árbol de estado del framework más nuevo de inyección de dependencias Hive/cell, que reporta cada *módulo* como OK / Degraded / Stopped.

Para "la política dejó de actualizarse en este nodo", andá **primero a los controllers**: `cilium-dbg status --all-controllers` te va a mostrar un lazo específico con un `Count` en aumento y un `Last error`, que nombra la operación que falla. Modules Health te dice que un subsistema está mal; los controllers te dicen qué tarea y por qué.

**A1.2** — Con `envoy.enabled=false` dice `Envoy: embedded`. Envoy corre entonces como un grupo de hilos *dentro del proceso `cilium-agent`*.
Consecuencia: **reiniciar el agente reinicia Envoy**, así que cada conexión proxeada en L7 se corta ante cualquier upgrade, cambio de configuración o crash del agente — y la huella de memoria del agente incluye la de Envoy. Con `Envoy: external`, el DaemonSet `cilium-envoy` tiene su propio ciclo de vida: podés reiniciar el agente sin tirar abajo conexiones L7, y podés actualizar Envoy por un CVE sin tocar el datapath.

**A1.3** — Está en **`cilium_host`**, el extremo host del par veth `cilium_host`/`cilium_net`. Es la *IP interna de cilium* del nodo, o IP de router: el próximo salto para el tráfico que entra al datapath de Cilium desde el stack del host, la dirección de origen que usa el proxy L7, y la dirección que los otros nodos ven como gateway intra-clúster de este nodo.
Viene del CIDR de pods porque tiene que ser ruteable **dentro** de la red de pods — es un participante de primera clase de esa red, no una dirección de la red de nodos. Se registra en el objeto `CiliumNode` como `CiliumInternalIP` para que los agentes remotos la puedan aprender.

**A1.4** — Porque los mapas y programas BPF deben **sobrevivir al proceso del agente**. Pinear en un bpffs que vive en el mount namespace del host significa que los descriptores de archivo de los mapas sobreviven a la salida de `cilium-agent`; al reiniciar, el agente vuelve a abrir las rutas pineadas y reutiliza los mapas existentes en lugar de crear otros vacíos. Si bpffs estuviera montado solo en el mount namespace del pod, desaparecería al borrarse el pod, todos los mapas se recrearían vacíos, y cada reinicio del agente haría un blackhole del tráfico hasta que se regenerara cada endpoint.

**A1.5** — Variantes de `cleanState`:
- `cilium.cleanState` / env `CLEAN_CILIUM_STATE=true` — la **destructiva**: descarga los programas BPF, borra los mapas pineados, elimina las interfaces `cilium_host`/`cilium_net`/`cilium_vxlan` y limpia `/var/run/cilium/state`.
- `cilium.cleanBpfState` / `CLEAN_CILIUM_BPF_STATE=true` — más acotada: solo el estado BPF.

Activar la destructiva en un nodo de producción significa que **todos los pods existentes en ese nodo pierden conectividad** en el momento en que corre el init container, y se quedan caídos hasta que el agente restaure cada endpoint desde cero. Es una herramienta de recuperación para estado corrupto, no una opción de rutina.

**A1.6** — **TCX** (`tcx/ingress`, `tcx/egress`) es un mecanismo de attach basado en BPF links para la capa tc, agregado en **Linux 6.6**. Reemplaza el attach clásico de qdisc clsact + filtro `bpf` (`tc filter add dev ... bpf da obj ...`). Aporta: attach de múltiples programas con orden, sin robarle el programa a otro agente; reemplazo atómico; y propiedad basada en links, de modo que los programas de un loader que crashea se reclaman. En kernels < 6.6 Cilium cae a `Attach Mode: Legacy TC`. `Device Mode: veth` se refiere al tipo de interfaz del pod — la alternativa es `netkit` (Linux 6.7+), que elimina una capa más de overhead.

---

### Bloque 2

**A2.1** — Es el **host endpoint**: el nodo mismo, identidad `1` (`reserved:host`), que representa todos los procesos del namespace del host (kubelet, sshd, el container runtime). No tiene IP de pod dedicada porque *es* el namespace de red del nodo — es dueño de las IPs del nodo.
Si escribís una política `default-deny` sin tenerlo en cuenta, y habilitás el **host firewall** (`hostFirewall.enabled=true`), podés dejarte afuera del nodo: las sondas de salud de kubelet hacia los pods, y el SSH al nodo, son tráfico desde `reserved:host`. Incluso sin host firewall, olvidarse de `reserved:host` en una regla de ingress rompe las **sondas de liveness/readiness de kubelet**, porque se originan en el nodo, no en un pod.

**A2.2** — Es el **endpoint de cilium-health** (interfaz `lxc_health`), creado por el propio agente en cada nodo. No es un pod de Kubernetes, así que `kubectl get pods` no lo puede ver. Es un extremo de la malla de conectividad incorporada de Cilium: cada agente sondea el endpoint de salud de cada otro nodo por ICMP y HTTP, a través del datapath real (túnel/cifrado incluidos), que es lo que puebla `Cluster health: 3/3 reachable`. Mide alcanzabilidad pod a pod, no solamente nodo a nodo.

**A2.3** — Los endpoints son **por instancia de workload**; las identidades son **por conjunto único de etiquetas**. Las dos réplicas de nginx tienen etiquetas idénticas relevantes para Cilium, así que comparten la identidad `14584` — 2 endpoints, 1 identidad.
Se acuña una identidad nueva cuando aparece un nuevo **conjunto de etiquetas relevantes para la seguridad**. Qué etiquetas cuentan lo controla el filtro de etiquetas (opción `labels` / `--labels`, por defecto `k8s:!io.kubernetes.pod-template-hash` y compañía): namespace, service account, nombre de clúster y etiquetas de usuario son relevantes para la seguridad; `pod-template-hash`, `controller-revision-hash` y las anotaciones se excluyen — si no, cada rollout de un Deployment duplicaría la cantidad de identidades. Por esto exactamente la cantidad de identidades escala con la *diversidad relevante para la política*, no con la cantidad de pods, y por eso un clúster de 100.000 pods puede tener solo unos pocos miles de identidades.

**A2.4** —
- `cilium-dbg endpoint list` es **autoritativo para el datapath**. Refleja lo que efectivamente está cargado en el kernel en este nodo.
- Los CRDs `CiliumEndpoint` son **autoritativos para la observabilidad a nivel de clúster**: permiten que otros nodos, Hubble y los operators aprendan sobre endpoints que no alojan.

Si el API server queda inalcanzable 10 minutos: la lista local de endpoints sigue funcionando y el tráfico existente sigue fluyendo (el datapath ya está programado), pero el agente no puede crear/actualizar CRDs, no puede aprender sobre endpoints remotos *nuevos*, y no puede resolver identidades para etiquetas que recién aparecen. Los objetos `CiliumEndpoint` quedan obsoletos; el GC del operator después limpiará los que hayan quedado huérfanos.

**A2.5** — Desde la perspectiva del **kernel / del host** sobre la interfaz `lxc*`. `lxc1a2b…` es la pata *del lado host* del par veth; la pata *del lado pod* es `eth0` dentro del contenedor. Un paquete que el pod envía por su `eth0` **llega** a la `lxc*` del lado host — eso es un evento de ingress en esa interfaz. Por eso `cil_from_container` en `tcx/ingress` implementa la política de **egress** del pod, y `cil_to_container` en `tcx/egress` implementa la política de **ingress** del pod. Invertir esto es la lectura errónea más común de la salida de `bpftool net show`.

**A2.6** —
1. `kubectl label` muta el objeto Pod; el API server emite un evento de watch.
2. El watcher de Kubernetes del agente lo recibe y actualiza el conjunto de etiquetas del endpoint.
3. El endpoint entra en `waiting-for-identity`; el asignador de identidades resuelve el nuevo conjunto de etiquetas — o encuentra un `CiliumIdentity` existente o crea uno nuevo (modo CRD) / una nueva clave en el kvstore.
4. El endpoint entra en `waiting-to-regenerate` y después en `regenerating`: el motor de políticas recalcula el conjunto de identidades pares permitidas para este endpoint.
5. El agente escribe `lxc_config.h`, compila (o instancia desde `templates/`) `bpf_lxc.o`, y **reemplaza atómicamente** el programa adosado; el mapa de política por endpoint `cilium_policy_v2_02438` se actualiza con los nuevos pares clave/valor.
6. El endpoint vuelve a `ready`; el CRD `CiliumEndpoint` se actualiza con la nueva identidad.

Crucialmente, las conexiones existentes no se cortan: el swap de programa es atómico y el estado de conntrack persiste en `cilium_ct4_global`.

---

### Bloque 3

**A3.1** — Un **almacén de identidades compartido**. En el modo CRD por defecto, los objetos `CiliumIdentity` en el API server de Kubernetes son ese almacén: el primer agente que ve un conjunto de etiquetas crea el objeto con un ID asignado; todos los demás agentes lo buscan y lo reutilizan. En modo kvstore, un clúster etcd cumple el mismo rol.
Si dos nodos no estuvieran de acuerdo, la política sería silenciosamente incorrecta: el nodo A codificaría "permitir identidad 14584" en los mapas de política de sus endpoints, mientras que el nodo B etiqueta el mismo workload como 14585. El tráfico desde el nginx de B hacia un endpoint protegido de A llevaría la identidad 14585 en los metadatos del paquete, fallaría el lookup en el mapa de política, y sería **descartado como Policy denied** — una falla no determinista y dependiente del nodo. El acuerdo global sobre el número es toda la premisa de corrección de la política basada en identidades.

**A3.2** — Es una identidad **local (con alcance de nodo)**, asignada para un CIDR que solo aparece en la política y no está adosado a ningún workload. Cilium reserva todo lo que está en o por encima de `1 << 24` = **16777216** para estas; el bit de bandera las distingue de las identidades globales de clúster.
Se asignan localmente porque las identidades de CIDR son un *detalle de compilación de la política*: nada necesita mandarlas por el cable como identidad transportada en el paquete para un lookup remoto, como sí ocurre con las identidades de workload, y forzar cada CIDR de cada política a pasar por el asignador global del clúster sería un costo innecesario de escalado y coordinación.
**No** — `16777217` en este nodo y `16777217` en worker2 no tienen garantía de significar el mismo CIDR. Nunca compares números de identidad local entre nodos; resolvelos siempre con `cilium-dbg identity get <id>` en el nodo que los reportó.

**A3.3** —
- `tunnelendpoint=172.18.0.4` — ese pod vive en un nodo **remoto**, y para llegar a él este nodo debe encapsular el paquete en VXLAN con destino a la IP de underlay del nodo remoto, `172.18.0.4`.
- `tunnelendpoint=0.0.0.0` — el destino es **local** (o alcanzable sin encapsulación); entregar directamente.

Con `routingMode=native`, la columna de túnel pasa a ser `0.0.0.0` para prácticamente todo, porque se espera que la red de underlay rutee los CIDRs de pods de forma nativa (vía BGP, tablas de rutas del cloud, o una L2 plana). `cilium_tunnel_map` estaría vacío, `cilium_vxlan` no existiría, y ganarías MTU y perderías el requisito de que el underlay no sepa nada de las IPs de pods — el clásico trade-off túnel vs. nativo.

**A3.4** — La identidad `kube-apiserver` la produce el agente observando los Endpoints/EndpointSlice de `default/kubernetes` e inyectando la etiqueta `reserved:kube-apiserver` en las entradas de ipcache de esas IPs. Acá `172.18.0.2` es el nodo de control-plane que aloja el API server, así que obtiene la identidad `7` en lugar del `6` liso.
Importa porque te da un **selector estable e independiente de la dirección** para el tráfico al API server:
```yaml
egress:
  - toEntities:
      - kube-apiserver
```
Sin eso tendrías que hardcodear las IPs del control-plane en un `toCIDR` — lo que se rompe en cada reemplazo de control-plane, y en clústeres administrados donde el endpoint del API server está enteramente fuera del clúster (ahí, la misma identidad se adosa a esa IP externa).

**A3.5** — Originalmente `reserved:world` (2) cubría *todo* el tráfico fuera del clúster, para ambas familias de direcciones. En un clúster dual-stack eso es demasiado grueso: una regla pensada para permitir "toda la internet IPv4" no se podía expresar de forma distinta a la de IPv6. Por eso Cilium agregó `reserved:world-ipv4` (**9**) y `reserved:world-ipv6` (**10**), usadas cuando IPv6 está habilitado; la identidad `2` permanece como el comodín agnóstico de familia usado en despliegues single-stack IPv4. Las reglas escritas contra `toEntities: world` siguen matcheando ambas.

**A3.6** — **`cilium-operator`**, mediante su recolector de basura de identidades. Escanea periódicamente los objetos `CiliumIdentity` y borra los que no tienen ningún `CiliumEndpoint` que los referencie tras un intervalo de gracia (`identity-gc-interval`, `identity-heartbeat-timeout`).
Con el operator caído una semana en un clúster de mucha rotación: los objetos `CiliumIdentity` se acumulan sin límite. Los síntomas escalan desde crecimiento del almacenamiento de etcd/API server y arranque más lento de los agentes (cada agente lista todas las identidades al bootear), hasta el **agotamiento del rango global 256–65535 de identidades** — tras lo cual los workloads nuevos no pueden obtener identidad, los endpoints quedan trabados en `waiting-for-identity`, y sus pods nunca llegan a estar listos.

---

### Bloque 4

**A4.1** —
- **(a) tráfico existente — sin afectar.** El forwarding vive enteramente en mapas eBPF en cada nodo; el operator no está en ningún camino de paquetes.
- **(b) pod nuevo en un nodo existente — funcionó.** El nodo ya tenía su PodCIDR desde `CiliumNode.spec.ipam.podCIDRs`; el *agente* asigna las IPs individuales dentro de ese rango, y el *agente* crea el objeto `CiliumIdentity`. Ninguno necesita al operator.
- **(c) rotación de identidades — degradado en silencio.** La identidad del Deployment `probe` borrado nunca fue recolectada; el conteo se mantuvo plano durante los dos minutos en lugar de bajar. Esto es lo único que se rompió, y se rompió de forma invisible.

La lección: el modo de falla del operator es **fuga lenta, no caída inmediata** — que es exactamente la razón por la que está poco monitoreado.

**A4.2** — El objeto `CiliumNode` del nodo nuevo se crea (por el agente), pero `spec.ipam.podCIDRs` queda **vacío**, porque en modo `cluster-pool` el operator es el asignador que talla los /24 por nodo desde `clusterPoolIPv4PodCIDRList`. El agente loguea "waiting for IPAM pool" y nunca queda listo; cada pod planificado en ese nodo se queda en `ContainerCreating` con una falla de CNI ADD. Los nodos existentes no se ven afectados.

**A4.3** — En `ipam.mode=kubernetes` el PodCIDR viene de `node.Spec.PodCIDR`, escrito por el controlador de IPAM de nodos del **kube-controller-manager** — no por el operator de Cilium. Así que el nodo nuevo levanta bien con el operator caído.
Trade-off: el modo `kubernetes` hereda el `--node-cidr-mask-size` fijo del kube-controller-manager y requiere que `--allocate-node-cidrs` esté habilitado en el control plane, algo que a menudo no controlás en clústeres administrados. `cluster-pool` le da a Cilium la propiedad completa: tamaños de máscara variables, múltiples pools, IPv6 junto a IPv4, y `CiliumPodIPPool` para configuraciones multi-pool — al costo de meter al operator en el camino crítico del bootstrap de un nodo.

**A4.4** — El operator realiza **reconciliación con alcance de clúster y mutuamente excluyente**: asignar un PodCIDR a un nodo, o decidir que una identidad no está referenciada, debe hacerlo exactamente un actor o tenés doble asignación y borrados prematuros. La elección de líder sobre N réplicas da failover rápido sin concurrencia. Está fuera del camino de datos, así que un hueco en la elección no cuesta más que latencia en la reconciliación.
El agente, en cambio, hace trabajo **local al nodo y exclusivo del nodo**: hay exactamente un kernel por nodo y exactamente un dueño correcto de sus mapas BPF. Dos agentes en un nodo se pelearían por los mismos mapas pineados y los mismos attach de tc/tcx. Un DaemonSet ya garantiza uno por nodo, así que la elección de líder sería maquinaria redundante.

**A4.5** — Cada `CiliumEndpoint` es un objeto que el API server debe almacenar y observar. Con 100.000 pods, **cada uno de los 5.000 agentes** observa los 100.000 objetos, y cada evento de rotación de pods se abanica 5.000 veces. Eso es tráfico de watch O(nodos × endpoints) y puede saturar el API server y etcd antes de que el workload haga nada.
`CiliumEndpointSlice` agrupa muchos endpoints en un solo objeto (agrupación por defecto por namespace/identidad), colapsando tanto la cantidad de objetos como la de eventos aproximadamente por el factor de lote — la misma aritmética que motivó el `EndpointSlice` propio de Kubernetes. El **`cilium-operator`** observa los `CiliumEndpoint` y produce los slices; los agentes entonces observan slices en lugar de endpoints. Se habilita con `enable-cilium-endpoint-slice: "true"`.

**A4.6** — Tres cualesquiera de:
- **Ingress / Gateway API**: traducir recursos `Ingress` y `Gateway`/`HTTPRoute` a `CiliumEnvoyConfig`, y sincronizar Secrets de TLS hacia el namespace de Cilium.
- **IPAM de cloud**: asignar ENIs/IPs en modo `eni` (AWS), `azure` o `alibabacloud` — un subsistema sustancial que llama a APIs del cloud.
- **Modo kvstore**: escrituras de heartbeat y gestión de identidades contra etcd cuando `kvstore=etcd`.
- Producción de **`CiliumEndpointSlice`** (como arriba).
- **`CiliumBGPClusterConfig` / LB-IPAM**: asignar IPs desde `CiliumLoadBalancerIPPool` a Services de tipo `LoadBalancer`.
- **Manejo de derivadas de CNP**: expandir `toGroups` (por ejemplo, selectores de security groups de AWS) a CIDRs concretos.
- **IPAM multi-pool** vía `CiliumPodIPPool`.

---

### Bloque 5

**A5.1** — **El estado de forwarding está en el kernel; el estado del plano de control está en el agente.** Los pods existentes siguen funcionando porque sus interfaces veth todavía existen, sus programas tc/tcx siguen adosados, y sus mapas (`cilium_lxc`, `cilium_ipcache`, `cilium_policy_v2_*`, `cilium_ct4_global`) siguen pineados bajo `/sys/fs/bpf`. Nada de eso requiere un proceso corriendo.
Los pods nuevos fallan porque el attach de un pod es una operación del *plano de control*: `cilium-cni` debe pedirle al agente que asigne una IP, cree el par veth, asigne/resuelva una identidad, construya y adose el programa BPF del endpoint, y escriba las entradas en los mapas. Con el socket ausente, `cilium-cni` hace timeout y el CNI ADD falla, así que kubelet no puede crear el sandbox.

**A5.2** — Debe (1) **asignar una IP** del pool del nodo y (2) **crear el endpoint**, lo que implica resolver una identidad de seguridad y compilar/adosar el programa de datapath de ese endpoint.
Embeber eso en el plugin sería un error porque el plugin es un **proceso de vida corta y sin estado**. La asignación de IPs debe serializarse contra todas las demás asignaciones del nodo; la resolución de identidades requiere la vista del estado del clúster respaldada por watches; los programas de endpoint deben ser rastreados para su posterior regeneración cuando cambian etiquetas o políticas. Todo eso requiere un dueño de larga vida y con estado. El plugin es deliberadamente un cliente RPC delgado sobre `/var/run/cilium/cilium.sock`.

**A5.3** — El container runtime lee `/etc/cni/net.d` en **orden lexicográfico y usa el primer archivo de configuración válido**. El prefijo `05-` posiciona a Cilium por delante de la mayoría de los defaults.
Si un CNI anterior dejó un `00-something.conflist`, ese archivo ordena primero y gana: los pods obtienen IPs del *otro* plugin, Cilium nunca los ve, y aparecen como `reserved:unmanaged` (identidad 3) o directamente no aparecen — mientras que `cilium-dbg status` sigue viéndose perfectamente sano. Por esto desinstalar un CNI previo implica borrar su configuración de `/etc/cni/net.d` en cada nodo, no solo borrar su DaemonSet.

**A5.4** — En modo **autónomo** Cilium es el único plugin: es dueño del IPAM, el veth, el ruteo y la política de punta a punta. `cilium-dbg status` muestra `CNI Chaining: none`.
En modo **encadenado**, otro plugin (AWS VPC CNI, Calico, `generic-veth`) crea la interfaz y asigna la IP, y Cilium se agrega al array `plugins` para adosar sus programas eBPF a la interfaz ya creada. El estado muestra `CNI Chaining: aws-cni` (o `generic-veth`, `portmap`, …).
El modo encadenado te da política basada en identidades y Hubble, pero **pierde** las funcionalidades que dependen de ser dueño del datapath de punta a punta: notablemente `kubeProxyReplacement` (completo), el LB a nivel de socket, el bandwidth manager, el egress gateway, y en general cualquier cosa que requiera el ruteo/masquerading propios de Cilium. Por eso el camino de encadenamiento con AWS VPC CNI está documentado como restringido en funcionalidades.

**A5.5** —
1. **El archivo de configuración de CNI lo escribe el agente, y tarde.** Hasta que `cilium-agent` alcanza un estado ready y escribe `05-cilium.conflist`, no hay configuración CNI válida, así que el CRI reporta el plugin de red como no listo y el nodo queda `NotReady` — kubelet no arrancará pods que no sean host-network. (De forma correspondiente, en algunas configuraciones el agente *elimina*/renombra la configuración al apagarse.)
2. **Restauración de endpoints.** Al arrancar, el agente lee `/var/run/cilium/state/` y restablece cada endpoint previamente conocido antes de atender pedidos CNI nuevos, así un pod que sobrevivió al reinicio no queda a medio configurar.

Además, la sonda de readiness del agente (`cilium-health` / el `/healthz` del agente) condiciona que el pod del DaemonSet quede Ready, algo de lo que el tooling a nivel de nodo puede depender.

---

### Bloque 6

**A6.1** — El agente mantiene un **espejo en espacio de usuario** de los mapas que posee y reconcilia, para poder responder consultas y detectar deriva sin volcar el mapa del kernel; los controllers `bpf-map-sync-*` periódicamente re-sincronizan la caché contra el kernel y reparan discrepancias. Eso es apropiado para mapas cuyo contenido escribió el *agente*: `cilium_lxc`, `cilium_ipcache`, los mapas de LB, los mapas de política.
Conntrack queda excluido porque lo escribe el **datapath**, no el agente: las entradas las crea por flujo el programa eBPF en el camino rápido, a tasas de cientos de miles por segundo, con desalojo del lado del kernel. Cachear eso en espacio de usuario sería puro overhead y estaría desactualizado en el instante mismo en que se escribe. En su lugar, conntrack se gestiona con un GC periódico que recorre el mapa directamente.

**A6.2** — Client en worker → nginx en worker2, en modo túnel:
1. `eth0` del pod → `lxc*` del lado host, **ingress** → **`cil_from_container`**. Acá: conntrack, lookup de política de egress contra `cilium_policy_v2_<ep-del-client>`, lookup del destino en `cilium_ipcache` → identidad `14584`, `tunnelendpoint=172.18.0.4`.
2. Redirección a `cilium_vxlan` para la **encapsulación**. El paquete original se envuelve en VXLAN/UDP 8472 con la identidad de seguridad de origen transportada en el VNI/metadatos, para que el otro extremo pueda aplicar política de ingress sin volver a derivarla.
3. Salida por `eth0` **egress** → **`cil_to_netdev`** (decisiones de masquerading, egress del host firewall).
4. En worker2: `eth0` **ingress** → **`cil_from_netdev`** reconoce el destino VXLAN.
5. Desencapsulación en `cilium_vxlan` **ingress** → **`cil_from_overlay`**. La identidad se extrae de la encapsulación.
6. Entrega a la `lxc*` del endpoint destino, **egress** → **`cil_to_container`**, que realiza el lookup de política de **ingress** contra el `cilium_policy_v2_02438` de nginx usando la identidad del paso 5.

La encapsulación ocurre en el paso 2, la desencapsulación en el paso 5. Notá que el paquete puede no entrar nunca al stack IP del host — de eso se trata el ruteo `Host: BPF`.

**A6.3** — **Balanceo de carga a nivel de socket** (socket LB / "host-reachable services"), parte de `kubeProxyReplacement`. `cil_sock4_connect` engancha el `connect(2)` de cualquier proceso en la jerarquía cgroup v2; si el destino es un ClusterIP conocido, **reescribe el destino en el socket mismo** hacia una IP de pod backend elegida, antes de que se construya un solo paquete. `cil_sock4_sendmsg` hace lo equivalente para el `sendmsg(2)` de UDP sin conexión — que es lo que hace funcionar el DNS al ClusterIP de CoreDNS.
Efectos: no hay DNAT por paquete ni lookup de NAT inverso en el camino de vuelta para estas conexiones — la traducción ocurre una sola vez, al establecer el socket, lo que es medibemente más barato que iptables o que un DNAT BPF por paquete.
Efecto secundario observable: **`tcpdump` dentro del pod nunca muestra el ClusterIP.** Para cuando existe un paquete, el destino ya es la IP del pod backend. Los ingenieros reportan bugs por esto todo el tiempo; es el comportamiento correcto.

**A6.4** — El mapa está **pineado** en bpffs en `/sys/fs/bpf/tc/globals/cilium_lxc`, en el mount namespace del host. La vida de un objeto pineado la posee el filesystem, no el proceso que lo creó. Cuando `cilium-agent` sale, el kernel conserva el mapa (y los programas adosados vía tc/tcx que lo referencian), así que los paquetes se siguen clasificando, policiando y reenviando sin ninguna participación del espacio de usuario. Al reiniciar, el agente abre las mismas rutas pineadas, compara el contenido contra el estado deseado y repara los deltas — de ahí el inodo idéntico.
El cambio que **sí** lo rompería: poner `CLEAN_CILIUM_BPF_STATE=true` (o `cilium.cleanState`), que explícitamente despinea y borra los mapas y descarga los programas antes de que arranque el agente. Un upgrade de versión mayor que cambie la estructura de valores de un mapa también fuerza la recreación de ese mapa específico — por eso Cilium versiona los nombres de mapas (`_v2`, `_v3`) y, para los casos disruptivos, documenta una migración.

**A6.5** — Cilium **compila un programa eBPF por endpoint**. `lxc_config.h` / `ep_config.h` contienen las constantes de ese endpoint — su ID, MAC, IPs, identidad de seguridad, índice del descriptor del mapa de política, funcionalidades habilitadas — y `bpf_lxc.o` es el objeto construido con esas constantes horneadas como valores de tiempo de compilación. Hornearlas permite que el verificador pode ramas imposibles y elimina lookups de mapa en tiempo de ejecución para invariantes por endpoint, que es de donde viene buena parte del rendimiento por paquete de Cilium.
El costo es una invocación de clang por regeneración. `templates/` guarda **plantillas precompiladas indexadas por la combinación de banderas de funcionalidad**: los endpoints que difieren solo en ID/MAC/IP reutilizan una plantilla existente y sus constantes se parchean vía reescritura del ELF en lugar de recompilarse. Por eso el primer endpoint de un nodo es lento y el centésimo es rápido, y por eso un nodo con muchos endpoints de *configuración idéntica* regenera mucho más rápido que uno con muchos conjuntos distintos de funcionalidades.

**A6.6** — Hace falta un par veth porque Cilium necesita un punto donde los paquetes **crucen entre el stack del host y el datapath de Cilium** de forma controlable y enganchable. `cilium_host` es el extremo que mira al stack del host y lleva la IP de router; `cilium_net` es el par que mira al datapath. Hay programas BPF adosados en ambos (`cil_to_host` en `cilium_host`, `cil_from_host` en `cilium_net`), dándole a Cilium un hook sobre el tráfico en cada dirección entre ambos mundos — para aplicación del host firewall, atribución de identidad al tráfico del host, y ruteo correcto del tráfico originado en el proxy. Una única interfaz dummy tendría un solo punto de enganche y ninguna manera de representar la dirección a través del límite.

---

### Bloque 7

**A7.1** — **`cil_sock4_connect`**, adosado al **hook `connect4` de cgroup v2** (ver A6.3). Reescribe la dirección de destino del socket antes de que la conexión se establezca.
Rendimiento: kube-proxy basado en iptables hace DNAT por paquete recorriendo una cadena que es O(cantidad de services) en el peor caso, más una entrada de conntrack y una traducción inversa en cada paquete de respuesta. El socket LB de Cilium hace **una traducción por conexión** en el momento del `connect()`, con un lookup hash O(1) en `cilium_lb4_services_v2`, y ningún trabajo de NAT inverso para el caso local al pod. La brecha se ensancha linealmente con la cantidad de services, que es el argumento estrella para reemplazar kube-proxy en clústeres grandes.

**A7.2** — En la **capa tc/tcx del dispositivo de ingreso**: `cil_from_netdev` en `eth0` busca el frontend NodePort `172.18.0.3:31654` (y el comodín `0.0.0.0:31654`) en `cilium_lb4_services_v2`, elige un backend de `cilium_lb4_backends_v3`, y hace DNAT del paquete. El cliente externo no hizo ningún `connect()` dentro de la jerarquía de cgroups de este nodo, así que no había socket que reescribir.
El camino de respuesta usa **`cilium_lb4_reverse_nat`** (indexado por el `REVNAT_ID` que viste en `cilium-dbg bpf lb list`) para restaurar el frontend NodePort original como dirección de origen, de modo que el cliente vea una respuesta desde la dirección que marcó. Cuando el backend elegido está en un nodo *distinto*, `cilium_snat_v4_external` además guarda el estado de SNAT que hace que la respuesta vuelva ruteada por el nodo de ingreso (a menos que `externalTrafficPolicy: Local` evite el salto extra, o que DSR esté habilitado).

**A7.3** — `cilium-dbg service list` es el **modelo de services en espacio de usuario del agente**, construido a partir de los objetos `Service`/`EndpointSlice` observados en Kubernetes. `cilium-dbg bpf lb list` vuelca los **mapas reales del kernel** que lee el datapath.
Una discrepancia significa que la reconciliación entre ambos falló: el agente conoce un service pero no lo programó (o no pudo). Revisá `cilium-dbg status --all-controllers` buscando `sync-lb-maps-with-k8s-services`, y verificá si los mapas de LB están llenos (`cilium-dbg map list --verbose` — `Num errors` distinto de cero, o entradas al tamaño máximo del mapa). El agotamiento de mapas bajo `bpf-lb-map-max` es una falla real de producción y se presenta exactamente así: services listados, tráfico en blackhole.

**A7.4** —
- `kubeProxyReplacement=false` **+ `nodePort.enabled=true`** (y compañía, como `socketLB.enabled`, `externalIPs.enabled`, `hostPort.enabled`): un reemplazo **parcial**. Cilium maneja la(s) funcionalidad(es) específicamente habilitada(s) y **kube-proxy sigue corriendo** y maneja el resto, notablemente ClusterIP para el tráfico del namespace del host, según la configuración.
- `kubeProxyReplacement=true`: reemplazo **completo**. Cilium maneja ClusterIP, NodePort, LoadBalancer, ExternalIPs, HostPort, afinidad de sesión y el socket LB. kube-proxy no debe correr.

El reemplazo completo te da de forma exclusiva el **socket LB por cgroup** sin DNAT por paquete para el tráfico intra-clúster, y habilita los modos DSR / Maglev / híbrido y la eliminación total de las cadenas de iptables de services. También requiere un kernel suficientemente reciente y `k8sServiceHost`/`k8sServicePort` correctos.

**A7.5** — En modo de reemplazo completo, **Cilium es lo que programa los ClusterIPs**. Antes de que el agente se sincronice con el API server, `10.96.0.1:443` no resuelve a nada. Si el agente intentara alcanzar el API server a través de ese ClusterIP estaría pidiendo un service que solo él puede crear — un deadlock de arranque duro, y tras un reinicio de todo el clúster este quedaría irrecuperable por completo.
Apuntar `k8sServiceHost` a un ClusterIP produce exactamente eso: los agentes loguean timeouts de conexión al API server, nunca quedan listos, nunca escriben la configuración de CNI, y todos los nodos quedan `NotReady`. El valor debe ser una **IP de nodo, la dirección de un balanceador externo, o un nombre DNS que resuelva sin resolución de services intra-clúster**.

**A7.6** — La alternativa es **Maglev** (`loadBalancer.algorithm=maglev`), que puebla **`cilium_lb4_maglev`** — una tabla de lookup de hashing consistente por service (tamaño controlado por `maglev.tableSize`, un primo, por defecto 16381).
Es estrictamente mejor cuando **la selección de backend debe coincidir entre nodos**: con DSR o `externalTrafficPolicy: Cluster`, un paquete puede llegar a cualquier nodo, y con `random` cada nodo elegiría de forma independiente, rompiendo las conexiones que sean re-ruteadas. El hash consistente de Maglev hace que todos los nodos elijan el mismo backend para la misma 5-tupla y — su propiedad definitoria — que quitar un backend solo remapee la porción de flujos de ese backend en lugar de barajar todo. Costo: memoria proporcional a `tableSize × services`.

---

### Bloque 8

**A8.1** — Es una **ocupación de ring buffer**, no un error. Cada agente guarda los últimos N flujos en memoria (`hubble.eventBufferCapacity`, por defecto 4095); apenas el clúster lleva unos segundos corriendo, el buffer naturalmente se llena y se queda al 100% para siempre, desalojando el flujo más viejo por cada uno nuevo. Reporta "el buffer contiene su máximo de flujos recientes", no "se están perdiendo flujos por sobrecarga".
La estructura de datos es un **buffer circular en memoria de tamaño fijo por agente**. La señal real de capacidad es `Flows/s` versus tu necesidad de retención: con 4095 entradas y 3.000 flujos/s retenés aproximadamente 1,4 segundos de historia. Si necesitás más, agrandá el buffer, o exportá a un destino persistente vía métricas/exporter de Hubble — no trates el porcentaje como una alerta.

**A8.2** —
1. CLI `hubble` en tu laptop → **localhost:4245**, el extremo local de `cilium hubble port-forward` (un kubectl port-forward).
2. → API server de Kubernetes → kubelet → el **pod `hubble-relay`, puerto 4245** (gRPC, mTLS opcional).
3. Relay → para cada peer, el **servidor Hubble del agente en el puerto 4244**, descubierto vía el Service `hubble-peer`.
4. Cada agente lee su **ring buffer local en memoria** y devuelve en streaming los flujos que coinciden.
5. Relay fusiona los N streams y devuelve un único stream al CLI.

**`hubble-relay` es el componente sin estado.** No almacena flujos; es puramente un proxy gRPC de fan-out/fan-in. Por eso se puede reiniciar sin problema y por eso perderlo te cuesta las consultas a nivel de clúster pero ningún dato.

**A8.3** — El modelo es de **disponibilidad parcial con independencia por nodo**. Relay consulta a cada peer, devuelve lo que respondan, y reporta las fallas explícitamente en lugar de hacer fallar toda la consulta. Perder un agente degrada la cobertura de ese nodo solamente.
Los flujos históricos **no** eran recuperables. El ring buffer está en la memoria del proceso del agente; cuando se borró el pod, el buffer murió con él. Los flujos del nodo arrancan desde cero cuando arranca el nuevo agente. Esta es la propiedad operativa más importante de Hubble: **es una herramienta de live-tail y depuración de ventana corta, no un almacén**. Si necesitás historia durable tenés que exportarla — `hubble-export` a un archivo, o métricas de Hubble hacia Prometheus.

**A8.4** — Selecciona los **propios pods del agente `cilium`** (`k8s-app: cilium`), apuntando al puerto 4244. Es un Service de estilo *headless* usado puramente para el **descubrimiento de peers**: Relay observa su EndpointSlice para aprender el conjunto actual de agentes y sus direcciones, y reacciona a nodos que entran y salen sin ninguna configuración estática ni un watch propio de nodos.
Borralo y `hubble-relay` pierde su lista de peers: `hubble status` reporta 0 nodos conectados y toda consulta a nivel de clúster devuelve vacío. Las consultas por nodo vía `cilium-dbg`/socket local siguen funcionando y — importante — **el datapath no se ve afectado en absoluto**, porque Hubble es solo observabilidad.

**A8.5** — **`cilium_events`**, un `BPF_MAP_TYPE_PERF_EVENT_ARRAY` (perf ring buffer por CPU) escrito por los programas del datapath y leído por el NodeMonitor del agente — a eso se refiere el `Listening for events on 8 CPUs with 64x4096 of shared memory` de `cilium-dbg status`.
Los perf buffers son **lossy por diseño**: si el datapath produce eventos más rápido de lo que el espacio de usuario los consume, el kernel los descarta e incrementa un contador de eventos perdidos. Combinado con el ring buffer finito en memoria aguas abajo, esto significa que Hubble te da una vista estadísticamente excelente pero **no completa**. Para facturación, evidencia de cumplimiento o auditoría de registro necesitás una fuente con garantías de entrega; la garantía de Hubble es de mejor esfuerzo. (Podés observar las pérdidas — el monitor reporta eventos perdidos, y el nivel de agregación `monitorAggregation` suprime eventos deliberadamente para reducir la presión.)

**A8.6** — De los **agentes**. Cada `cilium-agent` calcula las métricas de Hubble a partir de su propio stream de flujos y las expone en su propio puerto de métricas de Hubble (por defecto **9965**); Prometheus scrapea a los agentes, no a Relay. Relay no está en el camino de métricas en absoluto.
El riesgo de cardinalidad: `sourceContext=pod;destinationContext=pod` crea una serie temporal por tupla **(pod origen, pod destino, veredicto, protocolo, …)**. En un clúster con 10.000 pods con un patrón de comunicación tipo malla, eso son potencialmente millones de series — va a destruir una instancia de Prometheus mucho antes de decirte nada útil, y además cuesta CPU y memoria del agente en cada nodo. Usá contextos más gruesos (`namespace`, `workload`, `identity`) y agregá granularidad a nivel de pod solo para una investigación acotada y temporal.

---

### Bloque 9

**A9.1** — Un **redirect** es una instrucción en el datapath para desviar el tráfico que coincide hacia el proxy L7 local en lugar de entregarlo al endpoint. Se almacena en **`cilium_proxy4`** (volcado por `cilium-dbg bpf proxy list`), y el puerto de proxy asignado viene del rango 10000–20000 que reporta la línea de estado.
Para un paquete que coincide, `cil_to_container` (ingress) no entrega al pod. Reescribe el destino hacia el puerto del proxy local en la IP de `cilium_host` y entrega el paquete al stack del host, donde Envoy lo acepta, parsea HTTP, aplica las reglas L7 y — si está permitido — abre/reutiliza una conexión al backend real. Los metadatos de la conexión original se preservan para que Envoy conozca la verdadera identidad de origen y el destino, y para que el camino de respuesta se restaure correctamente.

**A9.2** — La tomó **`cilium-envoy`**, y ocurrió **después** del veredicto de política eBPF, no en su lugar. El lookup L3/L4 en `cilium_policy_v2_02438` coincidió — client→nginx en el puerto 80 está permitido — pero la entrada que coincide está marcada como *que requiere redirect al proxy* en lugar de *permitir y entregar*. Así que el paquete fue aceptado por eBPF, redirigido a Envoy, y Envoy entonces evaluó el método y la ruta HTTP y rechazó el POST (devolviendo `403` al cliente, que es la razón por la que obtenés un código de estado y no un timeout).
Esta estratificación es por la que Hubble reporta dos tipos de veredicto distintos: `to-endpoint`/`policy-verdict` para la decisión de eBPF y `http-request` para la decisión de Envoy. Una regla L7 solo puede *acotar* lo que una regla L4 ya permitió.

**A9.3** — Ventajas (dos cualesquiera):
- **Ciclo de vida independiente**: reiniciar o actualizar `cilium-agent` ya no derriba todas las conexiones proxeadas en L7. Los upgrades del agente se vuelven mucho menos disruptivos en clústeres que usan política L7, Ingress o Gateway API.
- **Respuesta independiente a CVEs**: Envoy tiene una tasa alta de CVEs; podés subir la imagen de `cilium-envoy` sin tocar el datapath.
- **Aislamiento de recursos**: la memoria y el CPU de Envoy se contabilizan y limitan por separado, así que una fuga en Envoy no puede hacer OOM al proceso dueño del datapath eBPF.
- Imagen del agente y huella de proceso más chicas en nodos que nunca usan L7.

Nuevo modo de falla: **hay una segunda cosa que puede estar insana de forma independiente**. `cilium-agent` puede estar perfectamente Ready en un nodo donde `cilium-envoy` está en CrashLoop o todavía no fue planificado, así que el tráfico con política L7 se rompe mientras todas las señales de salud a nivel de agente están en verde. También introduce una preocupación por el orden de arranque y una nueva dependencia entre procesos sobre `/var/run/cilium/envoy/sockets/`.

**A9.4** — Mecánicamente, una regla L7 fuerza al paquete a **salir del camino rápido eBPF y entrar al espacio de usuario**: redirect al proxy, terminación TCP completa, parseo HTTP, evaluación de reglas y luego una *segunda* conexión desde Envoy al backend. Eso son dos stacks TCP, una copia en espacio de usuario y parseo de protocolo por petición, contra un único lookup hash O(1) para una regla L4.
El tráfico que **no** coincide en el mismo endpoint no se ve afectado: el redirect se instala por (endpoint, puerto, protocolo, dirección) en `cilium_proxy4`. El tráfico a otro puerto del mismo pod, o el tráfico desde una identidad par no cubierta por la regla L7, sigue por el camino eBPF puro a velocidad plena. Esto es lo que hace práctica la política L7 selectiva — pagás solo donde pediste semántica L7.

**A9.5** — `CiliumEnvoyConfig` (con namespace) y `CiliumClusterwideEnvoyConfig` (con alcance de clúster) te permiten inyectar **configuración xDS cruda de Envoy** — listeners, clusters, routes, cadenas de filtros — en las instancias de Envoy que Cilium gestiona, y ligarlas a Services de Kubernetes. Es la vía de escape para capacidades que los propios CRDs de política de Cilium no modelan.
Construidos encima de él: el **Cilium Ingress Controller** y **Cilium Gateway API** (el operator traduce `Ingress`/`Gateway`+`HTTPRoute` a `CiliumEnvoyConfig`), y la **gestión de tráfico consciente de L7 / balanceo de carga L7 para Services** (por ejemplo, balanceo consciente de gRPC vía una anotación en el service). La aplicación de **política de red L7** basada en Envoy de Cilium usa la misma infraestructura.

**A9.6** — **Fail-closed.** La entrada de redirect en `cilium_proxy4` se instala como parte del programa de política del endpoint; la acción del datapath para el tráfico que coincide es "mandar al puerto del proxy", no "entregar al pod". Si nada escucha en ese puerto de proxy, la conexión se rechaza o expira — el paquete nunca se entrega a la aplicación.
Esta es la postura de seguridad correcta (un aplicador de políticas no disponible no debe convertirse en un permitir implícito), pero significa que `cilium-envoy` es una **dependencia dura para la disponibilidad** de cualquier workload bajo política L7. Monitoreá el DaemonSet `cilium-envoy` con la misma seriedad que al agente.

---

### Bloque 10

**A10.1** — Sondean dos caminos distintos a propósito:
- **Host connectivity** apunta a la **IP de nodo** del nodo remoto — el camino del underlay, stack del host a stack del host.
- **Endpoint connectivity** apunta a la **IP de pod del endpoint de salud** del nodo remoto — el datapath completo de Cilium: encapsulación (o ruteo nativo), manejo de identidades, cifrado si está habilitado, y entrega dentro del namespace de un pod.

Host OK + endpoint fallando es una señal precisa y muy útil: **la red de underlay está bien, el overlay no.** Mirá la MTU (VXLAN agrega 50 bytes; una MTU de underlay que no lo acomoda descarta silenciosamente paquetes grandes mientras que las sondas del tamaño de un ICMP pueden pasar), un firewall bloqueando UDP 8472/6081 o WireGuard 51871, una entrada de `cilium_tunnel_map` faltante u obsoleta, o un desajuste de claves de IPsec/WireGuard.

**A10.2** — El **endpoint de cilium-health** (`lxc_health`, visto como endpoint `159` en el Bloque 2), que lleva la identidad **`4` / `reserved:health`**.
Implicancia: bajo una política default-deny a nivel de todo el clúster, las sondas de salud son tráfico sujeto a política como cualquier otro. Cilium trata `reserved:health` como caso especial para que la malla incorporada siga funcionando, pero tenés que tenerlo presente cuando razonás sobre "todo está denegado" — y si deshabilitás el chequeo de salud (`healthChecking=false`) para acallar el ruido, perdés la señal más temprana y más barata de que tu overlay se rompió. Dejalo, y alertá cuando `Cluster health` se degrade.

**A10.3** — Cuatro cualesquiera de:
- **Logs de pods** de `cilium`, `cilium-operator`, `cilium-envoy`, `hubble-relay` — incluyendo los logs `--previous` de **contenedores que crashearon**, que desaparecen una vez que el contenedor es recolectado.
- **Volcados puntuales de mapas BPF** (`cilium-dbg bpf * list`) y estado de endpoints — conntrack y las tablas de LB cambian continuamente; el estado en el momento de la falla es irrecuperable minutos después.
- **Una captura de flujos de Hubble** desde el ring buffer en memoria, que se sobrescribe en segundos a cualquier tasa real de flujos.
- **`cilium-dbg status --verbose`, el estado de los controllers y los logs por endpoint** en el momento del incidente, incluidos contadores de error que un reinicio pone en cero.
- **Eventos de Kubernetes**, que expiran (TTL por defecto de 1 hora).
- **Volcados de stack/heap/goroutines vía `gops`** del proceso del agente, que se van con el proceso.

El principio general: ejecutá `cilium sysdump` **antes** de reiniciar nada. Reiniciar el agente para "arreglar" el problema destruye la mayor parte de la evidencia.

**A10.4** —
1. `cilium-dbg identity get 61203` y `cilium-dbg identity get 14584` — convertí los números en conjuntos de etiquetas, para saber *qué workloads* son. (Ejecutalo en el nodo que emitió el drop, por si alguna es una identidad local.)
2. `cilium-dbg endpoint get <id-del-endpoint-destino>` — o `cilium-dbg policy get` — para ver la política materializada del destino y confirmar si la identidad de origen realmente está ausente del conjunto permitido. `cilium-dbg bpf policy get <endpoint-id>` muestra la verdad del lado del kernel.
3. `hubble observe --from-identity 61203 --to-identity 14584 --verdict DROPPED -o json` (o `cilium-dbg monitor -t policy-verdict`) para obtener el contexto completo del flujo — puerto, dirección, y si el drop es L3/L4 o un `http-request` de L7 — y cruzarlo con los objetos `CiliumNetworkPolicy` que seleccionan el destino.

Las causas raíz frecuentes que esta secuencia saca a la luz: se introdujo un `default-deny` sin un allow correspondiente; la política selecciona por una etiqueta que el pod en realidad no lleva (typo, o etiqueta de namespace faltante); la dirección está equivocada (una regla de ingress escrita donde hacía falta egress); o la política basada en DNS está fallando porque el proxy DNS no observó la consulta.

**A10.5** — Ordenados por radio de daño, peor primero:

| Componente | Inmediatamente | Con el tiempo |
|---|---|---|
| **`cilium-agent`** (un nodo) | No hay pods nuevos en ese nodo (el CNI ADD falla); no hay actualizaciones de política, identidad, services ni ipcache en ese nodo; los flujos locales de Hubble se detienen | La vista del clúster que tiene el nodo queda obsoleta — pods remotos nuevos inalcanzables, política revocada que se sigue aplicando, el GC de conntrack se detiene. El tráfico existente sigue fluyendo todo el tiempo. |
| **`cilium-envoy`** (un nodo) | Todo el tráfico con política L7, Ingress y Gateway API en ese nodo **falla cerrado** | Sin cambios — no se auto-repara sin que el pod vuelva |
| **`cilium-operator`** (clúster) | Nada visible para el usuario | Se detiene la recolección de identidades y `CiliumEndpoint` (fuga → eventual agotamiento del rango de identidades); los nodos nuevos no obtienen PodCIDR con IPAM `cluster-pool`; se detienen la traducción de Ingress/Gateway y LB-IPAM; el IPAM de cloud deja de emitir IPs |
| **`hubble-relay`** (clúster) | `hubble observe` a nivel de clúster y la Hubble UI dejan de funcionar | Nada más — la observabilidad por nodo vía `cilium-dbg`/socket local y todas las métricas siguen funcionando; **sin impacto en el data path** |
| **`hubble-ui`** (clúster) | La UI web no está disponible | Nada — el CLI `hubble` no se ve afectado |

La forma a recordar para el examen: **agente = plano de datos local al nodo + plano de control local al nodo; operator = plano de control con alcance de clúster y síntomas diferidos; envoy = plano de datos L7, fail-closed; Hubble = solo observabilidad, nunca plano de datos.**

</details>

---

## Fuentes

- Cilium — *Component Overview*: <https://docs.cilium.io/en/stable/overview/component-overview/>
- Cilium — *Introduction to Cilium & Hubble*: <https://docs.cilium.io/en/stable/overview/intro/>
- Cilium — *eBPF Datapath*: <https://docs.cilium.io/en/stable/network/ebpf/>
- Cilium — *Routing (Encapsulation / Native)*: <https://docs.cilium.io/en/stable/network/concepts/routing/>
- Cilium — *IP Address Management*: <https://docs.cilium.io/en/stable/network/concepts/ipam/>
- Cilium — *Kubernetes Without kube-proxy*: <https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- Cilium — *Network Policy*: <https://docs.cilium.io/en/stable/security/policy/>
- Cilium — *Hubble Observability*: <https://docs.cilium.io/en/stable/observability/hubble/>
- Cilium — *Troubleshooting*: <https://docs.cilium.io/en/stable/operations/troubleshooting/>
- Cilium — *System Requirements* (versiones de kernel, puertos requeridos): <https://docs.cilium.io/en/stable/operations/system_requirements/>
- Cilium — *Helm Reference*: <https://docs.cilium.io/en/stable/helm-reference/>
- Cilium — *`cilium-dbg` command reference*: <https://docs.cilium.io/en/stable/cmdref/cilium-dbg/>
- Cilium — *Cluster Mesh*: <https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/>
- Código fuente de Cilium (numeración de identidades reservadas, definiciones de mapas): <https://github.com/cilium/cilium>
- CNCF — *Cilium Certified Associate (CCA) curriculum*: <https://github.com/cncf/curriculum> · <https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md>