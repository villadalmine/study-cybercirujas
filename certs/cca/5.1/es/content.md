# 5.1 Asegurar cargas de trabajo con Cilium

> **Peso del dominio: 20%** — el bloque más pesado de toda la CCA. Todo lo que sigue asume que ya sabés que el datapath de Cilium es eBPF en la capa tc/socket, y construye desde ahí hacia la pregunta que hacen tanto el examen como la producción: *¿cómo expresás, aplicás, verificás y depurás una postura de seguridad para cargas de trabajo cuyas direcciones IP no significan nada?*

---

## 1. El problema arquitectónico: por qué colapsó la seguridad basada en IP

### 1.1 El argumento de la rotación

Un firewall tradicional —iptables, un security group, una ACL de hardware— es una función de la 5-tupla. Su unidad atómica de identidad es la dirección IP. Ese modelo se apoya en una suposición que se sostuvo durante treinta años y dejó de sostenerse alrededor de 2015: **una dirección IP es un nombre estable, duradero y con significado para una carga de trabajo.**

En un clúster de Kubernetes no es nada de eso:

| Propiedad | Era bare-metal / VM | Kubernetes |
|---|---|---|
| Vida útil de la dirección | meses–años | segundos–horas (las IP de Pod se reciclan del CIDR del nodo en cada reprogramación) |
| Vínculo dirección↔carga de trabajo | 1:1, asignado administrativamente | efímero, asignado por IPAM en la admisión |
| Ritmo de cambio | gestionado por control de cambios, con ticket | continuo (HPA, rolling updates, preemption de instancias spot, drenaje de nodos) |
| Reutilización | rara, deliberada | rutinaria — una IP reciclada puede pertenecer a un *dominio de confianza distinto* segundos después |
| Cardinalidad | cientos por segmento | decenas de miles por clúster |

Lo letal es la cuarta fila. Si tu ACL dice `10.244.3.17 may reach the payments database`, y el pod frontend que tiene `10.244.3.17` es desalojado y la dirección se reasigna a un batch job de otro namespace, tu ACL ahora es **activamente incorrecta** y nadie recibe una alerta. Esto no es una condición de carrera teórica: en un clúster con entrega continua pasa muchas veces por día.

El problema secundario es la escala del estado. Un conjunto de reglas puramente IP es O(orígenes × destinos × puertos). En una implementación de `kube-proxy` + `NetworkPolicy` basada en iptables, cada cambio de política dispara la reescritura de una cadena de reglas que se recorre linealmente por paquete. Con unos pocos miles de endpoints, las corridas de `iptables-restore` tardan segundos, la latencia de convergencia de políticas pasa a medirse en minutos, y el costo en el datapath del recorrido lineal aparece como latencia p99.

### 1.2 La respuesta de Cilium: la identidad de seguridad

Cilium desacopla por completo la *política* del *direccionamiento*. A cada endpoint (Pod, host o entidad externa) se le asigna una **identidad de seguridad**: un entero pequeño derivado del conjunto de *labels relevantes para la seguridad* de ese endpoint.

```
labels {app=frontend, env=prod, ns=payments}  ──hash/allocate──▶  identity 12345
```

Dos pods con labels relevantes para la seguridad idénticos **comparten** una identidad. Ese es el truco de compresión: un Deployment de 500 réplicas es una identidad, no 500 IP. La política se expresa entonces como `identity A → identity B on port/proto/L7-verb`, y el datapath eBPF responde cada paquete con una búsqueda en un hash map indexada por `(remote identity, port, protocol, direction)` — una operación O(1), independiente del tamaño del conjunto de reglas.

La resolución de direcciones pasa a ser un asunto aparte, a cargo del **ipcache**, un mapa BPF que mantiene `IP → identity` para cada dirección sobre la que el nodo necesita razonar (pods locales, pods remotos aprendidos por el watcher de kvstore/CRD, IP de nodos e identidades derivadas de CIDR provenientes de las políticas). Cuando un pod se reprograma, la entrada del ipcache se mueve; el mapa de políticas no cambia en absoluto.

**Numeración de identidades (esto hay que saberlo de memoria para el examen):**

| Rango | Alcance | Significado |
|---|---|---|
| `0` | — | desconocida / sin especificar |
| `1`–`255` | reservado | identidades fijas y bien conocidas (abajo) |
| `256`–`65535` | todo el clúster | identidades derivadas de labels, asignadas vía CRD (`CiliumIdentity`) o kvstore |
| `≥ 2^24` (`16777216`) | local al nodo | identidades derivadas de CIDR, asignadas por el agente local para reglas `toCIDR`/FQDN; nunca salen del nodo |

Identidades reservadas que tenés que poder nombrar:

| ID | Nombre | Matchea |
|---|---|---|
| 1 | `reserved:host` | el nodo local en sí (incluidos los pods host-network de ese nodo) |
| 2 | `reserved:world` | cualquier dirección fuera del clúster |
| 3 | `reserved:unmanaged` | un pod que Cilium no gestiona |
| 4 | `reserved:health` | el endpoint cilium-health de cada nodo |
| 5 | `reserved:init` | un endpoint cuyos labels todavía no se resolvieron |
| 6 | `reserved:remote-node` | cualquier *otro* nodo del clúster (o del clustermesh) |
| 7 | `reserved:kube-apiserver` | los endpoints que respaldan el API server de Kubernetes |
| 8 | `reserved:ingress` | el endpoint de origen de Ingress/Gateway API de Cilium |
| 9 / 10 | `reserved:world-ipv4` / `world-ipv6` | división dual-stack de `world` |

Con ClusterMesh, el ID de clúster se empaqueta en los bits altos de la identidad numérica (`clusterID << 16 | localID` con el valor por defecto `max-connected-clusters=255`), de modo que las identidades siguen siendo globalmente únicas en toda la malla sin coordinar cada asignación.

### 1.3 Qué labels cuentan

No todos los labels contribuyen a la identidad. Cilium aplica un **filtro de labels** antes de la asignación, y esta es una de las perillas operativas de mayor apalancamiento de todo el sistema.

Excluidos por defecto (son por réplica y harían explotar la cardinalidad): `pod-template-hash`, `pod-template-generation`, `controller-revision-hash`, `statefulset.kubernetes.io/pod-name`, la mayoría de los labels `batch.kubernetes.io/*`, y todas las annotations.

Incluidos por defecto: los labels de usuario (`k8s:app=…`), el namespace (`k8s:io.kubernetes.pod.namespace`), la service account (`k8s:io.cilium.k8s.policy.serviceaccount`), el nombre del clúster (`k8s:io.cilium.k8s.policy.cluster`) y los labels de namespace propagados (`k8s:io.cilium.k8s.namespace.labels.*`).

> **Modo de fallo en producción.** Alguien agrega al pod template de un Deployment un label que lleva un SHA de build o un timestamp. Ahora cada rollout asigna una identidad *nueva*. El espacio de 65535 identidades de clúster se llena, los objetos `CiliumIdentity` se acumulan más rápido que el GC del operator (por defecto `identity-gc-interval` 15m, heartbeat timeout 30m), la asignación de identidades empieza a fallar y los pods nuevos quedan con identidad `init` —que la mayoría de las políticas no matchea—, así que se los deniega. Acotá el filtro explícitamente con `labels:` en Helm en lugar de confiar en la convención.

---

## 2. El pipeline de aplicación, de punta a punta

```
                     kube-apiserver
                           │  watch CNP/CCNP/KNP, Pods, Namespaces, Services
                           ▼
                  ┌──────────────────┐
                  │  cilium-agent    │
                  │  policy repo     │  ← rules, monotonically increasing revision
                  │  selector cache  │  ← selector → {identity,…}
                  │  identity alloc  │  ← CiliumIdentity CRD / kvstore
                  └────────┬─────────┘
                           │ regenerate endpoint (per-EP, incremental)
             ┌─────────────┼──────────────────────────┐
             ▼             ▼                          ▼
   cilium_policy_v2_<epid>   cilium_ipcache      cilium-envoy (L7 HTTP/Kafka)
   key: (identity, port,     key: IP/CIDR        cilium-agent DNS proxy (L7 DNS)
        proto, direction)    val: identity
   val: allow/deny, proxy
        port, auth type
             │
             ▼
   tc ingress/egress eBPF program on lxc<...> veth  ──▶  verdict
```

Por cada paquete, el datapath:

1. Resuelve la identidad **remota**: en ingress, desde el ipcache (o desde el encabezado del túnel / el SPI de IPsec cuando el origen está en otro nodo); en egress, por búsqueda en el ipcache sobre el destino.
2. Busca en `cilium_policy_v2_<epid>` empezando por la clave más específica — `(identity, port, proto)`, después `(identity, ANY)`, después `(ANY-identity/wildcard, port)`, y por último el comodín solo de L3.
3. Aplica el veredicto. Si la entrada que matcheó lleva un **proxy port**, el paquete se redirige con tproxy a Envoy o al proxy DNS para su evaluación L7. Si lleva un **auth type**, el flujo queda retenido hasta que se complete la autenticación mutua.
4. Emite una notificación `policy-verdict` al ring buffer del monitor — que es lo que consume Hubble.

Dos consecuencias que importan en lo operativo:

- **La política es por endpoint y por dirección.** No hay una cadena global. El ingress de un endpoint puede estar aplicado mientras su egress queda sin restricciones, y viceversa.
- **La regeneración es asíncrona.** Que `kubectl apply` devuelva éxito significa que el CRD fue aceptado, no que algún datapath lo esté aplicando. La convergencia se observa mediante la revisión de política (§7.2).

---

## 3. Comparación de los modelos de objetos de política

Cilium acepta tres CRD de política más el `NetworkPolicy` upstream. Elegir bien es una decisión de arquitectura, no una preferencia de estilo.

| Capacidad | `networking.k8s.io/v1` NetworkPolicy | `CiliumNetworkPolicy` (CNP) | `CiliumClusterwideNetworkPolicy` (CCNP) |
|---|---|---|---|
| Alcance | por namespace | por namespace | **de todo el clúster, sin namespace** |
| Selección por labels de pod | ✅ | ✅ | ✅ (debe incluir el label de ns explícitamente) |
| Selección por labels de namespace | ✅ `namespaceSelector` | ✅ vía `k8s:io.cilium.k8s.namespace.labels.*` | ✅ |
| CIDR en L3 | ✅ `ipBlock` (+`except`) | ✅ `toCIDR`, `toCIDRSet`, `CiliumCIDRGroup` | ✅ |
| Puertos L4 | ✅ (+ rangos con `endPort`) | ✅ (+`endPort`, + ICMP/ICMPv6 por tipo) | ✅ |
| L7 HTTP / Kafka | ❌ | ✅ | ✅ (no para políticas de host) |
| L7 DNS + egress por FQDN | ❌ | ✅ `toFQDNs` | ✅ |
| Reglas **deny** explícitas | ❌ | ✅ `ingressDeny` / `egressDeny` | ✅ |
| Entidades reservadas (`world`, `host`, `remote-node`, `kube-apiserver`, `cluster`) | ❌ | ✅ | ✅ |
| Egress a un Service de K8s por nombre | ❌ | ✅ `toServices` | ✅ |
| Firewall de nodo / host | ❌ | ❌ | ✅ `nodeSelector` |
| Autenticación mutua | ❌ | ✅ `authentication.mode` | ✅ |
| Entre clústeres (ClusterMesh) | ❌ | ✅ `io.cilium.k8s.policy.cluster` | ✅ |
| Desactivar el default-deny | ❌ | ✅ `enableDefaultDeny` (1.16+) | ✅ |
| Portable a otros CNI | ✅ | ❌ | ❌ |

**Guía arquitectónica.** Usá CCNP para los *invariantes que son propiedad de la plataforma* y que un inquilino de namespace no debe poder borrar: bloquear el endpoint de metadatos del cloud, permitir DNS, permitir kube-apiserver, aplicar el firewall de nodo. Usá CNP para las reglas *propiedad de la aplicación*, delegadas vía RBAC al equipo dueño del namespace. Usá el `NetworkPolicy` upstream solo donde la portabilidad entre CNI sea un requisito duro — y aceptá que entonces no tenés L7, ni FQDN, ni deny, ni entidades.

Los cuatro tipos de objeto se evalúan en conjunto y forman una única política fusionada por endpoint. Mezclarlos está soportado y es habitual.

### 3.1 Precedencia y semántica de fusión

**No hay orden de reglas ni campo de prioridad.** La evaluación es de álgebra de conjuntos:

1. Todas las reglas `ingressDeny`/`egressDeny` de todos los objetos se unen. **El deny siempre gana**, incondicionalmente, sobre cualquier allow.
2. Todas las reglas allow se unen. No existe el «primer match».
3. Las reglas L7 solo aplican a tráfico ya permitido en L3/L4 por el mismo bloque `toPorts`. Una regla L7 no puede abrir un puerto que L4 no haya abierto.
4. Si *cualquier* regla selecciona un endpoint para una dirección, ese endpoint pasa a ser **default-deny en esa dirección** — salvo que `enableDefaultDeny` diga lo contrario.

Las reglas deny son **solo L3/L4**. No podés escribir «denegar `POST /admin`»: expresalo como una allowlist de los verbos L7 permitidos.

---

## 4. Default-deny: la semántica que causa la mayoría de las caídas

### 4.1 Modo de aplicación a nivel de clúster

`policyEnforcementMode` (flag del agente `--enable-policy`) tiene tres valores:

| Modo | Comportamiento | Uso |
|---|---|---|
| `default` | Un endpoint no tiene restricciones en una dirección hasta que al menos una regla lo selecciona en esa dirección; entonces esa dirección pasa a default-deny. | Operación normal. |
| `always` | Todo endpoint es default-deny en ambas direcciones desde su creación. | Entornos regulados; exige cobertura completa de políticas *antes* de que aterricen las cargas de trabajo, incluido `kube-system`. |
| `never` | La política se parsea y se reporta, pero nunca se aplica. | Solo diagnóstico. Nunca en producción. |

### 4.2 La trampa

Este es el incidente de Cilium más común de todos:

```yaml
# The engineer's intent: "let this pod resolve DNS."
# The actual effect: "this pod may ONLY do DNS. Everything else is now denied."
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: settlement
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

En cuanto esto aterriza, `app=settlement` queda seleccionado para egress, por lo tanto egress default-deny, por lo tanto todo flujo de egress que no sea DNS se cae. La readiness probe del pod sigue pasando (las probes son ingress, desde el host), así que el deployment se reporta sano mientras la carga de trabajo está completamente rota.

Cilium 1.16 introdujo el arreglo quirúrgico: una política que *agrega* permisos sin dar vuelta la dirección a default-deny:

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: platform-allow-dns
spec:
  description: >
    Additive DNS allowance for every managed endpoint. enableDefaultDeny is
    false so that merely selecting an endpoint does not isolate it; namespace
    owners remain responsible for their own default-deny posture.
  endpointSelector:
    matchExpressions:
      - key: io.kubernetes.pod.namespace
        operator: Exists
  enableDefaultDeny:
    ingress: false
    egress: false
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```

Usá `enableDefaultDeny: {ingress: false, egress: false}` en toda regla *aditiva provista por la plataforma*. Usá el valor por defecto (true) solo en la política que deliberadamente establece el límite de aislamiento de una carga de trabajo.

### 4.3 Modo auditoría: usalo siempre antes de aplicar

El modo auditoría de políticas evalúa la política y registra el veredicto que *habría* aplicado, mientras reenvía el tráfico. Es la única forma segura de introducir default-deny en un sistema en marcha, y es obligatorio antes de habilitar el firewall de host.

Por endpoint:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint config 2696 PolicyAuditMode=Enabled
Endpoint 2696 configuration updated successfully
```

A nivel de clúster (Helm, para un despliegue por etapas):

```yaml
policyAuditMode: true
```

Los flujos auditados aparecen con veredicto `AUDIT` en lugar de `DROPPED`:

```console
$ hubble observe --verdict AUDIT --last 5
Sep  1 12:14:03.882: payments/settlement-5f7b9c8d4-2xqmr:44120 (ID:34567) -> 34.117.59.81:443 (ID:16777231) policy-verdict:none EGRESS AUDIT (TCP Flags: SYN)
```

Recolectá la salida de auditoría durante un ciclo de negocio completo —incluidos el batch job semanal y la ventana de backup— antes de pasar a aplicar. Todo lo que corre solo una vez al mes no va a aparecer, y es exactamente eso lo que se rompe a las 03:00.

---

## 5. Escribir políticas, capa por capa

### 5.1 Un conjunto de políticas de tres capas, completo y con forma de producción

El ejemplo de abajo es un conjunto completo y listo para aplicar en un namespace `payments` con `frontend → api → db`, más un procesador de pagos externo. No se omite nada.

```yaml
---
# ─────────────────────────────────────────────────────────────────────────────
# 0. Namespace baseline: default-deny both directions, with the two allowances
#    every workload needs (DNS, and the kube-apiserver for pods that use the
#    downward/API access). Owned by the platform team.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: baseline-default-deny
  namespace: payments
spec:
  description: >
    Establishes default-deny for every endpoint in the payments namespace and
    grants the universal allowances. Application policies are additive on top.
  endpointSelector: {}          # empty selector == every endpoint in this namespace
  ingress:
    # Kubelet health/readiness probes originate from the node's host namespace.
    - fromEntities:
        - host
        - health
  egress:
    # DNS, via the L7 DNS proxy so that toFQDNs rules elsewhere can learn IPs.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    # The API server, addressed by entity rather than by IP: this survives
    # control-plane node replacement and HA VIP changes.
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
            - port: "6443"
              protocol: TCP
---
# ─────────────────────────────────────────────────────────────────────────────
# 1. frontend: accepts north-south traffic from the Ingress, talks only to api.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: frontend
      tier: web
  ingress:
    - fromEntities:
        - ingress                    # the Cilium Ingress/Gateway API source identity
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app: prometheus
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/metrics$"
  egress:
    - toEndpoints:
        - matchLabels:
            app: api
            tier: backend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
---
# ─────────────────────────────────────────────────────────────────────────────
# 2. api: L7-constrained ingress, mutually authenticated egress to db,
#    FQDN-scoped egress to the external processor.
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: api
      tier: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
            tier: web
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              # Read paths: anonymous GETs on the accounts collection.
              - method: "GET"
                path: "/v1/accounts/[0-9]+$"
              - method: "GET"
                path: "/v1/accounts/[0-9]+/transactions$"
              # Write path: POST only, and only with a JSON body and the
              # service's own tenant header present.
              - method: "POST"
                path: "/v1/payments$"
                headers:
                  - 'Content-Type: application/json'
                  - 'X-Tenant-Id: .*'
              - method: "GET"
                path: "/healthz$"
    # Deliberately NOT reachable from anywhere else, including other namespaces.
  egress:
    - toEndpoints:
        - matchLabels:
            app: postgres
            tier: data
      authentication:
        mode: "required"             # SPIFFE-based mutual authentication
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
    - toFQDNs:
        - matchName: "api.stripe.com"
        - matchPattern: "*.eu-west-1.amazonaws.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
  egressDeny:
    # Belt and braces: even if a future allow rule widens egress, the cloud
    # metadata service stays unreachable. Deny beats allow, always.
    - toCIDR:
        - 169.254.169.254/32
        - fd00:ec2::254/128
---
# ─────────────────────────────────────────────────────────────────────────────
# 3. db: ingress from api only, no egress except DNS (inherited from baseline).
# ─────────────────────────────────────────────────────────────────────────────
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: postgres
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: postgres
      tier: data
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api
            tier: backend
      authentication:
        mode: "required"
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app: postgres-exporter
      toPorts:
        - ports:
            - port: "9187"
              protocol: TCP
```

### 5.2 Notas capa por capa

**L3 — seleccionar el par.** Cinco formas mutuamente excluyentes por elemento de regla:

| Selector | Matchea | Notas |
|---|---|---|
| `fromEndpoints` / `toEndpoints` | endpoints gestionados por Cilium, por label | En una CNP con namespace, un `matchLabels` vacío queda implícitamente acotado a ese namespace. Agregá `io.kubernetes.pod.namespace` para cruzar namespaces. |
| `fromEntities` / `toEntities` | identidades reservadas | `cluster` = todos los endpoints gestionados + host + remote-node + init + health. `all` = todo, incluido `world`. |
| `fromCIDR` / `toCIDR` | prefijos literales | Asigna una identidad CIDR local al nodo por cada prefijo. |
| `fromCIDRSet` / `toCIDRSet` | prefijos con `except`, o una referencia a `CiliumCIDRGroup` | Preferido para listas de prefijos grandes o compartidas. |
| `toFQDNs` | nombres DNS (solo egress) | Requiere una regla DNS L7 acompañante. Ver §6. |
| `toServices` | un Service de Kubernetes por nombre/namespace | Se resuelve a las identidades de los backends; sobrevive a la rotación de backends. |

> **CIDR vs. IP de nodos: una trampa real.** Por defecto, una regla `toCIDR` que cubre la IP de un nodo del clúster **no** matchea el tráfico hacia ese nodo: las IP de nodo llevan identidad `remote-node`, y los selectores CIDR no matchean identidades de nodo salvo que configures `policyCIDRMatchMode: [nodes]` (flag del agente `--policy-cidr-match-mode=nodes`). Si tu regla de «permitir el rango corporativo 10.0.0.0/8» falla misteriosamente para direcciones de nodo, este es el motivo.

**L4 — puertos.** `protocol` es `TCP`, `UDP`, `SCTP` o `ANY`. Los rangos de puertos usan `endPort`:

```yaml
      toPorts:
        - ports:
            - port: "30000"
              endPort: 32767
              protocol: TCP
```

Los puertos con nombre están soportados (`port: "http"`, resuelto desde el pod spec). ICMP se expresa por tipo:

```yaml
  ingress:
    - fromEntities: [cluster]
      icmps:
        - fields:
            - type: 8                 # echo-request
              family: IPv4
            - type: 128               # echo-request
              family: IPv6
```

**L7 — la semántica cambia.** Cuando un bloque `toPorts` lleva una sección `rules:` de L7, el tráfico que matchea se redirige a un proxy en espacio de usuario. Eso cambia el comportamiento observable de maneras que hay que comunicarles a los equipos de aplicación:

| Aspecto | Denegación L3/L4 | Denegación L7 |
|---|---|---|
| Lo que ve el cliente | el SYN TCP se traga → timeout de connect / RST | el connect TCP **tiene éxito**, y después `HTTP 403 Access denied` |
| Costo de latencia | ~0 (búsqueda en un mapa eBPF) | salto por Envoy: típicamente +0,2–1 ms p50, más bajo carga |
| Dominio de fallo | solo el datapath | el proceso proxy; corré `cilium-envoy` como su propio DaemonSet para que los reinicios del agente no interrumpan los flujos L7 |
| Veredicto en Hubble | `DROPPED` en el flujo | `DROPPED` en el evento `http-request`, `FORWARDED` en el flujo L4 |
| Visibilidad de la IP de origen | n/a | preservada (proxy transparente) |
| Protocolos soportados | cualquiera | HTTP/1.1, HTTP/2, gRPC, Kafka, DNS |

Kafka, para completar:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: kafka-producers
  namespace: streaming
spec:
  endpointSelector:
    matchLabels:
      app: kafka
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: settlement-producer
      toPorts:
        - ports:
            - port: "9092"
              protocol: TCP
          rules:
            kafka:
              - role: "produce"
                topic: "payments.events.v1"
              - apiKey: "apiversions"
              - apiKey: "metadata"
```

### 5.3 Listas de prefijos reutilizables con `CiliumCIDRGroup`

Duplicar un rango corporativo de 40 prefijos en doce políticas garantiza que se desincronicen. Externalizalo:

```yaml
---
apiVersion: cilium.io/v2alpha1        # promoted to cilium.io/v2 in newer releases
kind: CiliumCIDRGroup
metadata:
  name: corporate-datacentres
  labels:
    trust-zone: internal
spec:
  externalCIDRs:
    - 10.100.0.0/16
    - 10.101.0.0/16
    - 192.0.2.0/24
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-to-corporate
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: api
  egress:
    - toCIDRSet:
        # Reference a single group by name…
        - cidrGroupRef: corporate-datacentres
        # …or select any number of groups by label (1.16+):
        - cidrGroupSelector:
            matchLabels:
              trust-zone: internal
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

---

## 6. Políticas FQDN: la mecánica, y dónde muerde

`toFQDNs` es la funcionalidad que más piden los equipos y la que más incidentes genera, porque es un mecanismo de *observación de DNS*, no un mecanismo de resolución de nombres.

**Cómo funciona.**
1. Una regla DNS L7 de egress redirige las consultas DNS del pod al proxy DNS de Cilium.
2. El proxy reenvía la consulta, inspecciona la **respuesta** y compara el nombre de la respuesta contra cada selector `toFQDNs` en alcance.
3. Para los que matchean, las direcciones A/AAAA devueltas se insertan en el ipcache con una identidad CIDR local al nodo, y las entradas `/32` `/128` correspondientes se programan en el mapa de políticas del endpoint con el TTL de la respuesta DNS (con piso en `--tofqdns-min-ttl`, por defecto 3600 s).

**Por lo tanto:**

| Requisito | Consecuencia si se incumple |
|---|---|
| Debe existir una regla DNS L7 (`rules: dns: matchPattern: "*"`) para el mismo endpoint | El proxy nunca ve la consulta; no se aprende ninguna IP; la regla FQDN no matchea nada y todo el tráfico hacia ese nombre se deniega. |
| La aplicación tiene que resolver realmente el nombre al momento de conectar | Las apps que resuelven una vez al arrancar y cachean la IP para siempre se van a romper cuando la entrada expire. Las apps a las que se les pasa una IP literal por configuración nunca quedan permitidas. |
| El nombre tiene que resolver a un conjunto acotado de IP | `--tofqdns-max-ips-per-hostname` (por defecto 50) trunca; las flotas grandes de CDN/anycast rotan IP más rápido que los TTL, produciendo denegaciones intermitentes. |
| La conexión debe iniciarse *después* de la consulta | Una conexión de larga duración que sobrevive al vencimiento del TTL queda protegida por `--tofqdns-idle-connection-grace-period`; más allá de eso puede ser cortada. |

`matchName` es una coincidencia exacta (sin distinguir mayúsculas, con el punto final opcional). `matchPattern` soporta `*` como comodín de una o varias etiquetas — `*.example.com` matchea `a.example.com` **y** `a.b.example.com`, lo cual es más amplio de lo que espera la mayoría de los ingenieros. Escribí el patrón más ajustado que funcione.

**Inspeccionar lo que aprendió el proxy:**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg fqdn cache list --endpoint 2696
Endpoint   Source   FQDN                                  TTL     ExpirationTime               IPs
2696       lookup   api.stripe.com.                       3600    2026-09-01T13:07:44.000Z     54.187.174.169,54.187.205.235
2696       lookup   s3.eu-west-1.amazonaws.com.           3600    2026-09-01T13:09:02.000Z     52.218.100.42
2696       lookup   sqs.eu-west-1.amazonaws.com.          3600    2026-09-01T13:09:02.000Z     63.32.19.104,52.208.4.11
```

Si el nombre que esperás no está, o falta la regla DNS o la aplicación nunca consultó. Confirmá el segundo caso directamente:

```console
$ hubble observe --from-pod payments/api --protocol dns --last 10
Sep  1 12:09:02.118: payments/api-6b8d9c7f4-nx8vp:39220 (ID:23456) -> kube-system/coredns-668d6bf9bc-8zt4m:53 (ID:45678) dns-request proxy FORWARDED (DNS Query api.stripe.com. AAAA)
Sep  1 12:09:02.121: kube-system/coredns-668d6bf9bc-8zt4m:53 (ID:45678) -> payments/api-6b8d9c7f4-nx8vp:39220 (ID:23456) dns-response proxy FORWARDED (DNS Answer "54.187.174.169" TTL: 60 (Proxy api.stripe.com. A))
```

Fijate en el `TTL: 60` de la respuesta frente al `3600` de la caché: `--tofqdns-min-ttl` retiene deliberadamente las entradas más tiempo del que anuncia el upstream, cambiando frescura por estabilidad. Bajalo solo si tenés que seguir un DNS que se mueve rápido, y esperá más denegaciones en el borde.

**Comportamiento ante reinicios.** Habilitá el modo de proxy DNS transparente (`dnsProxy.enableTransparentMode: true`, el valor por defecto moderno) para que el proxy no sea un salto de NAT y las IP de origen sobrevivan. Durante un reinicio de `cilium-agent` el proxy DNS queda brevemente no disponible; planificá los reinicios y preferí el despliegue del proxy DNS independiente cuando tu versión lo ofrezca.

---

## 7. Cifrado y autenticación mutua

La política de red responde *quién puede hablar con quién*. No responde *si el cable es confidencial* ni *si el par es quien dice ser a nivel criptográfico*. Son tres controles separados y el examen espera que los mantengas separados.

### 7.1 Cifrado transparente: IPsec vs. WireGuard

| Dimensión | IPsec (ESP) | WireGuard |
|---|---|---|
| Helm | `encryption.type: ipsec` | `encryption.type: wireguard` |
| Granularidad | una SA por par de nodos; el tráfico pod a pod va cifrado | túnel nodo a nodo (`cilium_wg0`); el tráfico de pods viaja adentro |
| Gestión de claves | vos proveés y rotás el Secret `cilium-ipsec-keys`; la rotación es un procedimiento operativo | las claves se generan por nodo automáticamente; las públicas se distribuyen vía `CiliumNode` |
| Requisito de kernel | stack XFRM (ampliamente disponible) | kernel ≥ 5.6 o el módulo `wireguard` |
| Cifrador | AES-GCM (128/256) vía el crypto del kernel — puede ser un módulo validado FIPS | ChaCha20-Poly1305 — **no** validable por FIPS |
| Sobrecarga de MTU | ~50–60 B, según el cifrador | 60 B (IPv4) / 80 B (IPv6) |
| Costo de CPU | menor con offload AES-NI; puede usar offload de la NIC | levemente mayor sin AES-NI; muy bueno con él |
| Tráfico nodo a nodo (host) | soportado | `encryption.nodeEncryption: true` |
| Complejidad operativa | alta (estado de las SA, ventanas de rotación de claves, depuración con `ip xfrm`) | baja |
| Interacción con las políticas | ninguna — la identidad viaja en el SPI/mark | ninguna |

**Recomendación:** WireGuard, salvo que un régimen de cumplimiento exija un cifrador validado FIPS, en cuyo caso IPsec con AES-GCM. No habilites los dos.

```yaml
# Helm values — encryption + node encryption
encryption:
  enabled: true
  type: wireguard
  nodeEncryption: true
  wireguard:
    persistentKeepalive: 0s
```

Verificación:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -A4 Encryption
Encryption:              Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: kQx9k2Fh1v0J5uWq3pR7cYt4mZbN8sLdA6eXfG1hIjk=, Port: 51871, Peers: 5)]

$ kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
        Public key: kQx9k2Fh1v0J5uWq3pR7cYt4mZbN8sLdA6eXfG1hIjk=
        Number of peers: 5
```

Para una prueba genuina de punta a punta, capturá en la NIC física y confirmá que no podés leer los payloads — `cilium connectivity test --test 'pod-to-pod-encryption'` hace exactamente eso.

### 7.2 Autenticación mutua (SPIFFE/SPIRE)

La autenticación mutua de Cilium vincula al flujo una **identidad criptográfica** (un SVID de SPIFFE emitido por SPIRE, indexado por la identidad de seguridad de Cilium). El datapath retiene el primer paquete de un flujo nuevo mientras los agentes de ambos lados completan un handshake TLS mutuo fuera de banda; una vez autenticado el par, el resultado se cachea y los flujos siguientes entre esas identidades pasan a velocidad de línea.

**La advertencia crítica, y un distractor favorito del examen: la autenticación mutua no cifra tu tráfico.** Autentica a los pares. La confidencialidad sigue requiriendo WireGuard o IPsec. Habilitá los dos.

```yaml
# Helm values
authentication:
  mutual:
    spire:
      enabled: true
      install:
        enabled: true
        namespace: cilium-spire
        server:
          dataStorage:
            enabled: true
            size: 2Gi
            storageClass: fast-ssd
```

Después, por regla:

```yaml
  egress:
    - toEndpoints:
        - matchLabels:
            app: postgres
      authentication:
        mode: "required"        # "required" | "disabled"
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

El requisito de autenticación se ve en el mapa de políticas del endpoint (columna `AUTH TYPE`, §8.3) y los fallos aparecen como drops `AUTH_REQUIRED` en Hubble.

---

## 8. Más allá de la política de pods: firewall de host y egress gateway

### 8.1 Firewall de host

El nodo en sí es un endpoint (`reserved:host`). Habilitar el firewall de host te permite reemplazar la gestión de `iptables`/`nftables` por nodo con el mismo modelo consciente de identidad — pero también es la forma más rápida de dejarte afuera de tu propio clúster.

```yaml
# Helm values
hostFirewall:
  enabled: true
devices: "eth+ ens+ bond+"      # MUST cover every NIC carrying node traffic
policyAuditMode: true           # start here. Always.
```

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: node-baseline
spec:
  description: >
    Host-level firewall for worker nodes. L3/L4 only — host policies do not
    support L7. Roll out with PolicyAuditMode enabled and only enforce after a
    full week of audit data shows no unexpected denials.
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  ingress:
    # Intra-cluster: other nodes, health checks, and all managed workloads.
    - fromEntities:
        - cluster
        - remote-node
        - health
    # Management plane: SSH and the node exporter, from the bastion range only.
    - fromCIDRSet:
        - cidr: 10.20.0.0/24
      toPorts:
        - ports:
            - port: "22"
              protocol: TCP
            - port: "9100"
              protocol: TCP
    # Kubelet API, from the control plane only.
    - fromEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "10250"
              protocol: TCP
    # Load-balancer health probes into NodePort range.
    - fromCIDRSet:
        - cidr: 10.30.0.0/24
      toPorts:
        - ports:
            - port: "30000"
              endPort: 32767
              protocol: TCP
  egress:
    - toEntities:
        - all
```

Notá el egress de host deliberadamente permisivo: acotar el egress del nodo es un proyecto aparte y mucho más riesgoso (rompe la descarga de imágenes, NTP, las API del cloud y el container runtime), y solo debería encararse una vez que el lado de ingress esté estable.

### 8.2 Egress gateway: una IP de origen estable para políticas externas

Los sistemas externos —un banco socio, un firewall heredado, una base de datos con allowlist de IP— no pueden consumir la identidad de Kubernetes. Necesitan una dirección de origen estable. `CiliumEgressGatewayPolicy` hace SNAT del tráfico de pods seleccionado a través de un nodo y una IP designados.

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: settlement-to-partner-bank
spec:
  selectors:
    - podSelector:
        matchLabels:
          io.kubernetes.pod.namespace: payments
          app: settlement
  destinationCIDRs:
    - 203.0.113.0/24
  excludedCIDRs:
    - 203.0.113.10/32          # this host must be reached directly, not via the GW
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
    interface: eth0
    # Alternatively pin the exact address:
    # egressIP: 198.51.100.42
```

Requisitos y compromisos:

- Necesita `kubeProxyReplacement: true` y `bpf.masquerade: true`.
- El nodo gateway es un **cuello de botella de ancho de banda y un punto de fallo**; etiquetá al menos dos nodos y entendé que el failover rompe las conexiones en curso.
- El egress gateway es ortogonal a la política: seguís necesitando una `CiliumNetworkPolicy` de egress que permita el destino. El gateway decide *con qué IP de origen*, la política decide *si se puede o no*.
- El SNAT colapsa la atribución por pod en el destino; mantené a Hubble como fuente de verdad de quién envió realmente qué.

---

## 9. Verificación y diagnóstico de fallos

### 9.1 La escalera de escalamiento

Recorré esta lista en orden. Cada peldaño es más barato que el siguiente y elimina toda una clase de causas.

**Peldaño 0 — ¿la plataforma está sana, siquiera?**

```console
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                  OK
 \__/¯¯\__/    Operator:                OK
 /¯¯\__/¯¯\    Envoy DaemonSet:         OK
 \__/¯¯\__/    Hubble Relay:            OK
    \__/       ClusterMesh:             disabled

DaemonSet              cilium                   Desired: 6, Ready: 6/6, Available: 6/6
DaemonSet              cilium-envoy             Desired: 6, Ready: 6/6, Available: 6/6
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 6
                       cilium-envoy             Running: 6
                       cilium-operator          Running: 2
                       hubble-relay             Running: 1
Cluster Pods:          142/142 managed by Cilium
Helm chart version:    1.17.4
```

`Cluster Pods: 142/142 managed by Cilium` importa: cualquier pod *no* gestionado lleva `reserved:unmanaged` y es invisible para las políticas basadas en identidad.

**Peldaño 1 — ¿la política fue aceptada, y convergió?**

```console
$ kubectl -n payments get cnp
NAME                    AGE   VALID
baseline-default-deny   3h    True
frontend                3h    True
api                     8m    True
postgres                3h    True

$ kubectl -n payments describe cnp api | tail -20
Status:
  Conditions:
    Last Transition Time:  2026-09-01T12:05:11Z
    Message:               Policy validation succeeded
    Status:                True
    Type:                  Valid
```

Una CNP con `VALID: False` *no se aplica, en silencio*. Este chequeo es obligatorio en cualquier gate de CI.

Después confirmá que el datapath se puso al día. Cada agente lleva una revisión de política monótona:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get --all | tail -3
Revision: 4211

$ for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
    echo -n "$p  "; kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg policy get 2>/dev/null | tail -1
  done
pod/cilium-4gk9t  Revision: 4211
pod/cilium-8mzq2  Revision: 4211
pod/cilium-b7xrl  Revision: 4211
pod/cilium-jw5nd  Revision: 4209     ◀── lagging: investigate this agent
pod/cilium-p2vch  Revision: 4211
pod/cilium-t9hks  Revision: 4211
```

**Peldaño 2 — ¿el endpoint está aplicando política, y qué identidad tiene?**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                        IPv6   IPv4          STATUS
           ENFORCEMENT        ENFORCEMENT
254        Disabled           Disabled          4          reserved:health                                           10.244.2.87   ready
1187       Enabled            Enabled           23456      k8s:app=api                                               10.244.2.31   ready
                                                           k8s:io.cilium.k8s.policy.cluster=prod-eu
                                                           k8s:io.cilium.k8s.policy.serviceaccount=api
                                                           k8s:io.kubernetes.pod.namespace=payments
                                                           k8s:tier=backend
2696       Enabled            Enabled           34567      k8s:app=settlement                                        10.244.2.44   ready
                                                           k8s:io.kubernetes.pod.namespace=payments
3312       Disabled           Disabled          16777220   reserved:host                                             10.0.1.12     ready
```

`POLICY ENFORCEMENT: Disabled` en un pod que creés protegido significa que **ninguna regla lo selecciona**. El noventa por ciento de las veces es un typo en un label o un namespace que no coincide, no un bug de Cilium.

**Peldaño 3 — ¿qué cree realmente el datapath?**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf policy get 1187
POLICY   DIRECTION   IDENTITY   LABELS (source:key[=value])                     PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES     PACKETS   PREFIX
Allow    Ingress     1          reserved:host                                   ANY          NONE         disabled    18244     212       0
Allow    Ingress     12345      k8s:app=frontend                                TCP/8080     16403        disabled    9812445   14022     0
                                k8s:io.kubernetes.pod.namespace=payments
                                k8s:tier=web
Allow    Egress      45678      k8s:io.kubernetes.pod.namespace=kube-system     ANY/53       16401        disabled    41220     388       0
                                k8s:k8s-app=kube-dns
Allow    Egress      56789      k8s:app=postgres                                TCP/5432     NONE         spire       2244109   6712      0
                                k8s:io.kubernetes.pod.namespace=payments
                                k8s:tier=data
Allow    Egress      16777231   cidr:54.187.174.169/32                          TCP/443      NONE         disabled    884210    1204      0
                                reserved:world
Deny     Egress      16777244   cidr:169.254.169.254/32                         ANY          NONE         disabled    0         0         0
```

Leé esta tabla con atención: es la verdad de fondo.
- El `PROXY PORT` distinto de cero en la entrada frontend→api confirma que la redirección HTTP L7 está programada.
- `AUTH TYPE: spire` en la entrada de postgres confirma que la autenticación mutua está activa para ese par.
- `IDENTITY 16777231` es una identidad CIDR local al nodo acuñada por la regla FQDN — prueba de que `api.stripe.com` se resolvió y se programó.
- `BYTES`/`PACKETS` por entrada te dicen qué reglas se usan *realmente*. Las entradas con contadores en cero después de una semana son candidatas a eliminarse, y un contador `Deny` sospechosamente activo es un incidente.

**Peldaño 4 — mirá el veredicto en vivo.**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor -t policy-verdict --related-to 1187
Listening for events on 6 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
Policy verdict log: flow 0x3f9a21b4 local EP ID 1187, remote ID 12345, proto 6, ingress, action allow, match L3-L4, 10.244.1.57:41022 -> 10.244.2.31:8080 tcp SYN
Policy verdict log: flow 0x7c14e88d local EP ID 1187, remote ID 34567, proto 6, ingress, action deny, match none, 10.244.2.44:52344 -> 10.244.2.31:8080 tcp SYN
Policy verdict log: flow 0x9b02fa31 local EP ID 1187, remote ID 56789, proto 6, egress, action allow, match L3-L4, 10.244.2.31:38812 -> 10.244.3.19:5432 tcp SYN
```

El campo `match` es el diagnóstico:

| Valor de `match` | Significado |
|---|---|
| `none` | Ninguna regla matcheó → se disparó el default-deny. Tu selector está mal o no existe. |
| `L3-Only` | Matcheó solo por identidad (la regla no tenía `toPorts`). |
| `L3-L4` | Matcheó identidad + puerto/protocolo. |
| `L4-Only` | Matcheó una regla de puerto con identidad comodín. |
| `all` | Matcheó un comodín de permitir todo — suele ser señal de una regla demasiado amplia. |

A nivel de clúster, lo mismo mediante Hubble:

```console
$ hubble observe --verdict DROPPED --namespace payments --last 20
Sep  1 12:14:03.882: payments/settlement-5f7b9c8d4-2xqmr:52344 (ID:34567) -> payments/api-6b8d9c7f4-nx8vp:8080 (ID:23456) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 12:14:03.882: payments/settlement-5f7b9c8d4-2xqmr:52344 (ID:34567) <> payments/api-6b8d9c7f4-nx8vp:8080 (ID:23456) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:14:07.114: payments/api-6b8d9c7f4-nx8vp:41560 (ID:23456) -> 169.254.169.254:80 (ID:16777244) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep  1 12:14:19.443: payments/frontend-7c9f4d5b6-4kq2z:41022 (ID:12345) -> payments/api-6b8d9c7f4-nx8vp:8080 (ID:23456) http-request DROPPED (HTTP/1.1 DELETE http://api.payments.svc.cluster.local:8080/v1/accounts/42)
```

La última línea es el caso L7: el flujo L4 se reenvió, la petición HTTP se denegó y el cliente recibió un 403. Notá además el emparejamiento de las dos primeras líneas: Hubble emite tanto el evento policy-verdict como el evento de drop para el mismo paquete.

Consultas dirigidas que vas a usar todo el tiempo:

```console
# Everything between two workloads, both directions, following new flows
$ hubble observe --from-pod payments/frontend --to-pod payments/api -f

# Only what a given identity is being denied
$ hubble observe --identity 34567 --verdict DROPPED

# Only drops attributable to policy, cluster-wide
$ hubble observe --verdict DROPPED --type drop --last 200 -o json \
    | jq -r 'select(.drop_reason_desc=="POLICY_DENIED")
             | [.source.namespace+"/"+.source.pod_name,
                .destination.namespace+"/"+.destination.pod_name,
                (.l4.TCP.destination_port // .l4.UDP.destination_port | tostring)]
             | @tsv' | sort | uniq -c | sort -rn
     47  payments/settlement-5f7b9c8d4-2xqmr   payments/api-6b8d9c7f4-nx8vp   8080
     12  observability/loki-0                  payments/api-6b8d9c7f4-nx8vp   3100
```

Ese último pipeline es el caballo de batalla para una revisión de «qué se va a romper si aplico esto»: corrélo contra los datos del modo auditoría y obtenés una lista de trabajo priorizada.

**Peldaño 5 — introspección de selectores, cuando los sospechosos son los labels.**

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg policy selectors
SELECTOR                                                                                        LABELS                        USERS   IDENTITIES
&LabelSelector{MatchLabels:{any.app: frontend,any.tier: web,k8s.io.kubernetes.pod.namespace: payments,},}   payments/api        1       12345
&LabelSelector{MatchLabels:{any.app: postgres,any.tier: data,k8s.io.kubernetes.pod.namespace: payments,},}  payments/api        1       56789
&LabelSelector{MatchLabels:{any.app: settlement,k8s.io.kubernetes.pod.namespace: payments,},}               payments/legacy     1
MatchName: api.stripe.com, MatchPattern:                                                        payments/api                  1       16777231
```

Una columna `IDENTITIES` **vacía** es la prueba incriminatoria: el selector no matchea nada. Compará contra los labels reales:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list | head -20
ID         LABELS
1          reserved:host
2          reserved:world
3          reserved:unmanaged
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
12345      k8s:app=frontend
           k8s:io.cilium.k8s.policy.cluster=prod-eu
           k8s:io.cilium.k8s.policy.serviceaccount=frontend
           k8s:io.kubernetes.pod.namespace=payments
           k8s:tier=web
23456      k8s:app=api
           k8s:io.cilium.k8s.policy.cluster=prod-eu
           k8s:io.cilium.k8s.policy.serviceaccount=api
           k8s:io.kubernetes.pod.namespace=payments
           k8s:tier=backend
```

Y, para un problema entre nodos, verificá que el ipcache realmente conozca la dirección remota:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ipcache get 10.244.3.19
10.244.3.19 maps to identity identity=56789 encryptkey=0 tunnelendpoint=10.0.1.14 flags=<none>
```

Que la IP de un pod remoto resuelva a la identidad `2` (`world`) o `0` significa que la identidad no se propagó — revisá el operator, la sincronización de kvstore/CRD y (en ClusterMesh) la conectividad del clúster remoto.

### 9.2 Catálogo de modos de fallo

| Síntoma | Causa raíz | Confirmar con | Remedio |
|---|---|---|---|
| Todo se rompe en cuanto aterriza la primera política | La regla seleccionó el endpoint y dio vuelta esa dirección a default-deny | `cilium-dbg endpoint list` muestra `Enabled`; `hubble observe --verdict DROPPED` muestra drops hacia kube-dns | Agregar los permisos de DNS + kube-apiserver, o poner `enableDefaultDeny: {egress: false}` en las políticas aditivas |
| El DNS funciona, todo lo demás da timeout | La política solo permite el puerto 53 | Hubble muestra `EGRESS DENIED match none` en 443 | Agregar las reglas de egress previstas |
| La regla `toFQDNs` deniega tráfico | No hay regla DNS L7 acompañante, así que el proxy nunca vio la respuesta | `cilium-dbg fqdn cache list` está vacío para ese nombre | Agregar `rules: dns: - matchPattern: "*"` a la regla de egress DNS |
| La política FQDN funciona y después falla de forma intermitente | La app cachea la IP más allá del TTL, o el nombre devuelve más de `max-ips-per-hostname` direcciones | `cilium-dbg fqdn cache list` muestra rotación; drops hacia `world` | Subir `--tofqdns-min-ttl`, corregir el cacheo del resolver de la app, o replegarse a un CIDR/CIDRGroup |
| El cliente recibe `403 Access denied` en lugar de un timeout | Funciona según lo diseñado: la denegación L7 la responde Envoy | `hubble observe --protocol http` muestra `http-request DROPPED` | Ampliar la regla L7, o explicarle la semántica al equipo |
| La política se aplicó pero no se hace cumplir en ningún lado | `policyEnforcementMode: never`, o la CNP está en `VALID: False` | `cilium-dbg status`; `kubectl get cnp -o wide` | Corregir el modo; corregir el error de esquema |
| La aplicación es inconsistente de nodo a nodo | Un agente está atrasado en la revisión de política, o se está reiniciando | el bucle de revisiones del peldaño 1 de §9.1 | Inspeccionar los logs de ese agente; revisar `cilium_policy_import_errors_total` |
| Se deniega tráfico entre nodos para pods que deberían estar permitidos | ipcache desactualizado / identidad no propagada | `cilium-dbg bpf ipcache get <ip>` devuelve `world` o `0` | Revisar el operator, la sincronización kvstore/CRD, y en ClusterMesh `cilium clustermesh status` |
| Un `toCIDR` que cubre IP de nodos no matchea | Las IP de nodo llevan identidad `remote-node` | `cilium-dbg bpf ipcache get <node-ip>` | Configurar `policyCIDRMatchMode: [nodes]` |
| Nodo inalcanzable tras habilitar el firewall de host | Ingress de host en default-deny; SSH/kubelet no permitidos | Acceso por consola; `cilium-dbg endpoint list` para el endpoint `reserved:host` | Volver a habilitar `policyAuditMode` y escribir los permisos antes de aplicar |
| Denegaciones esporádicas a escala; algunos endpoints dejan de aplicar correctamente | Mapa de políticas por endpoint lleno (`bpf-policy-map-max`, por defecto 16384) | `cilium_bpf_map_pressure{map_name=~"cilium_policy.*"}` acercándose a 1.0 | Reducir la cardinalidad de identidades/CIDR; consolidar CIDR en grupos; subir el límite y reiniciar |
| La cantidad de identidades crece sin límite; los pods nuevos quedan trabados en `init` | Un label de pod de alta cardinalidad alimentando la asignación de identidades | `cilium-dbg identity list \| wc -l`; `kubectl get ciliumid \| wc -l` | Acotar el filtro `labels:` de Helm; quitar el label culpable |
| Un flujo denegado sigue funcionando después de aplicar una política deny | El flujo ya está establecido en conntrack | `cilium-dbg bpf ct list global \| grep <ip>` | Verificar el comportamiento de tu versión y después forzarlo con `cilium-dbg bpf ct flush --endpoint <id>` y reiniciar el cliente |
| Los flujos L7 parpadean durante una actualización de Cilium | Envoy corriendo dentro del pod del agente | revisar si existe el DaemonSet `cilium-envoy` | Poner `envoy.enabled: true` para que el proxy tenga un ciclo de vida independiente |
| `authentication.mode: required` deniega todo | SPIRE no instalado, o SVID no emitidos | `kubectl -n cilium-spire get pods`; motivo de drop `AUTH_REQUIRED` en Hubble | Instalar/reparar SPIRE; verificar el registro agente↔servidor |

### 9.3 Verificación automatizada

Cilium incluye una suite completa de conformidad de conectividad. Corréla después de cada instalación, actualización o cambio del modelo de políticas: crea su propio namespace, ejercita los caminos pod a pod, pod a service, pod a mundo, DNS, L7 y cifrado, y limpia todo al terminar.

```console
$ cilium connectivity test --test-namespace cilium-test --test-concurrency 4
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [prod-eu] Creating namespace cilium-test for connectivity check...
✨ [prod-eu] Deploying echo-same-node service...
✨ [prod-eu] Deploying DNS test server configmap...
⌛ [prod-eu] Waiting for deployments [client client2 echo-same-node] to become ready...
🏃 Running 78 tests ...
[=] Test [no-policies] .........................
[=] Test [allow-all-except-world] ..............
[=] Test [client-ingress] ......................
[=] Test [echo-ingress] ........................
[=] Test [client-egress-l7] ....................
[=] Test [to-fqdns] ............................
[=] Test [pod-to-pod-encryption] ...............
✅ All 78 tests (312 actions) successful, 6 tests skipped, 0 scenarios skipped.
```

Validá los CRD de política antes de que lleguen al clúster — este es además el paso de preflight de una actualización:

```console
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg preflight validate-cnp
level=info msg="Setting up client to access Kubernetes API"
level=info msg="Validating CiliumNetworkPolicy 'payments/api'"
level=info msg="Validating CiliumNetworkPolicy 'payments/frontend'"
level=info msg="Validating CiliumClusterwideNetworkPolicy 'node-baseline'"
level=info msg="All CCNPs and CNPs valid!"
```

### 9.4 Alertar sobre lo que falla en silencio

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-policy-health
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: cilium-policy
      rules:
        - alert: CiliumPolicyMapPressureHigh
          # A full per-endpoint policy map silently stops enforcing correctly.
          expr: max by (node, map_name) (cilium_bpf_map_pressure{map_name=~"cilium_policy.*"}) > 0.85
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Policy map pressure {{ $value | humanizePercentage }} on {{ $labels.node }}"
            runbook: "Reduce identity/CIDR cardinality or raise bpf-policy-map-max."

        - alert: CiliumPolicyImportErrors
          # A rejected policy is a policy that is not protecting anything.
          expr: increase(cilium_policy_import_errors_total[15m]) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Cilium rejected {{ $value }} policy imports on {{ $labels.pod }}"

        - alert: CiliumIdentityCardinalityGrowth
          # Runaway identity allocation exhausts the 65535 cluster-local space.
          expr: predict_linear(cilium_identity[6h], 24 * 3600) > 55000
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Cluster-local identity space projected to exhaust within 24h"

        - alert: CiliumPolicyDropSpike
          # A step change in policy drops after a deploy is almost always a regression.
          expr: |
            sum by (namespace) (
              rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])
            ) > 5
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $value | printf \"%.1f\" }} policy drops/s in namespace {{ $labels.namespace }}"

        - alert: CiliumAgentPolicyRevisionLag
          expr: |
            max(cilium_policy_max_revision) - min(cilium_policy_max_revision) > 2
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Cilium agents are not converged on the same policy revision"
```

Habilitá las métricas de Hubble que alimentan esto:

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  metrics:
    enableOpenMetrics: true
    enabled:
      - "dns:query;ignoreAAAA"
      - "drop:sourceContext=pod;destinationContext=pod"
      - "flow:sourceContext=pod;destinationContext=pod"
      - "tcp"
      - "httpV2:exemplars=true;labelsContext=source_namespace,destination_namespace"
    serviceMonitor:
      enabled: true
```

> **Advertencia de cardinalidad.** `sourceContext=pod;destinationContext=pod` produce una serie temporal por par de pods. En un clúster grande esto va a desbordar Prometheus. Usá `sourceContext=namespace;destinationContext=namespace` como valor por defecto y habilitá el contexto a nivel de pod solo para una investigación puntual.

---

## 10. Método de despliegue en un clúster existente

El orden importa, y saltear pasos es la forma en que se rompen los clústeres:

1. **Observar primero.** Desplegá Hubble sin ninguna política. Exportá dos semanas de flujos. Esa es tu verdad de fondo sobre qué se comunica realmente: el diagrama de arquitectura de nadie es exacto.
2. **Derivá políticas candidatas** a partir de los flujos observados, por namespace, empezando por las cargas de trabajo menos conectadas.
3. **Aplicá en modo auditoría.** `policyAuditMode: true` a nivel de clúster, o por endpoint. No se descarta nada.
4. **Mineá el stream de auditoría** con el pipeline de `jq` de §9.1 durante un ciclo de negocio completo, incluidos los jobs mensuales. Cada veredicto `AUDIT` es o bien una regla que falta o bien un hallazgo genuino.
5. **Aplicá namespace por namespace**, empezando por el de menor riesgo, con un rollback documentado (`kubectl delete cnp <name>` restaura la postura previa en una revisión de política).
6. **Agregá L7 de forma selectiva.** L7 es un salto de proxy y un nuevo dominio de fallo: aplicalo donde el valor de seguridad sea real (un límite de API, un topic de Kafka), no en todos lados.
7. **Habilitá el cifrado**, y después la **autenticación mutua**, como cambios separados con verificación separada.
8. **El firewall de host al final**, en modo auditoría, sobre un solo node pool, y con el acceso por consola confirmado como funcional antes de aplicar.

---

## 11. Puntos clave

- La política apunta a la **identidad**, no a la IP. La identidad se deriva de un conjunto filtrado de labels; controlar ese filtro es una responsabilidad operativa de primer orden.
- Seleccionar un endpoint en una dirección lo vuelve **default-deny en esa dirección**. `enableDefaultDeny: false` es la herramienta para las políticas aditivas de plataforma.
- **El deny le gana al allow, siempre**, y el deny es solo L3/L4.
- `toFQDNs` requiere una **regla DNS L7** acompañante; sin ella el selector FQDN no matchea nada.
- La denegación L7 devuelve **HTTP 403**; la denegación L3/L4 **descarta el paquete**. Síntomas distintos, depuración distinta.
- La autenticación mutua **autentica**; WireGuard/IPsec **cifran**. Son controles independientes y en general querés los dos.
- `CCNP` para los invariantes de plataforma y el firewall de host; `CNP` para las reglas de aplicación; el `NetworkPolicy` upstream solo cuando la portabilidad es obligatoria.
- El camino de depuración es fijo: `cilium status` → `VALID` de la CNP → convergencia de la revisión de política → `cilium-dbg endpoint list` → `cilium-dbg bpf policy get` → `hubble observe` / `cilium-dbg monitor -t policy-verdict`. El campo `match` de un veredicto te dice *por qué*.
- **Modo auditoría antes de aplicar. Siempre.** Sobre todo para el firewall de host.

---

## 12. Referencias

**Cilium — documentación oficial**
- Visión general y conceptos de Network Policy — https://docs.cilium.io/en/stable/security/policy/
- Modos de aplicación de políticas y default deny — https://docs.cilium.io/en/stable/security/policy/intro/
- Política de capa 3 (endpoints, entidades, CIDR, services) — https://docs.cilium.io/en/stable/security/policy/language/#layer-3-examples
- Política de capa 4 — https://docs.cilium.io/en/stable/security/policy/language/#layer-4-examples
- Política de capa 7 (HTTP, Kafka, DNS) — https://docs.cilium.io/en/stable/security/policy/language/#layer-7-examples
- Políticas basadas en DNS (FQDN) — https://docs.cilium.io/en/stable/security/policy/language/#dns-based
- Restringir el acceso externo con políticas basadas en DNS — https://docs.cilium.io/en/stable/security/dns/
- Políticas de denegación — https://docs.cilium.io/en/stable/security/policy/language/#deny-policies
- Referencia de la API de CiliumNetworkPolicy — https://docs.cilium.io/en/stable/network/kubernetes/policy/
- Soporte de NetworkPolicy de Kubernetes y diferencias — https://docs.cilium.io/en/stable/security/policy/kubernetes/
- Identidad y gestión de identidades — https://docs.cilium.io/en/stable/internals/security-identities/
- Firewall de host — https://docs.cilium.io/en/stable/security/host-firewall/
- Cifrado transparente (IPsec y WireGuard) — https://docs.cilium.io/en/stable/security/network/encryption/
- Cifrado transparente con WireGuard — https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
- Cifrado transparente con IPsec — https://docs.cilium.io/en/stable/security/network/encryption-ipsec/
- Autenticación mutua con SPIFFE/SPIRE — https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/
- Egress gateway — https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- Diagnóstico de problemas de políticas — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Referencia de monitoreo y métricas — https://docs.cilium.io/en/stable/observability/metrics/
- Referencia de Helm (`policyEnforcementMode`, `policyAuditMode`, `hostFirewall`, `encryption`, `authentication`) — https://docs.cilium.io/en/stable/helm-reference/
- Referencia de comandos de `cilium-dbg` — https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Internals del datapath eBPF — https://docs.cilium.io/en/stable/network/ebpf/

**Hubble**
- Visión general de la observabilidad con Hubble — https://docs.cilium.io/en/stable/observability/
- Referencia de la CLI de Hubble — https://docs.cilium.io/en/stable/observability/hubble/
- Métricas de Hubble — https://docs.cilium.io/en/stable/observability/metrics/#hubble-exported-metrics

**Kubernetes upstream**
- Concepto de Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Referencia de la API de NetworkPolicy — https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/

**CNCF / examen**
- Currícula de Cilium Certified Associate (CCA) — https://github.com/cncf/curriculum/blob/master/cca/README.md
- Página del programa Cilium Certified Associate — https://training.linuxfoundation.org/certification/cilium-certified-associate-cca/

**Especificaciones relacionadas**
- Especificación SPIFFE (identidad de carga de trabajo usada por la autenticación mutua de Cilium) — https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE.md
- Protocolo WireGuard — https://www.wireguard.com/protocol/
- RFC 4303, IP Encapsulating Security Payload (ESP) — https://www.rfc-editor.org/rfc/rfc4303