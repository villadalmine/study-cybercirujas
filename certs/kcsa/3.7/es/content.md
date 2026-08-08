# 3.7 Network Policy

## 1. Motivación: el problema arquitectónico de la red plana

El modelo de red de Kubernetes parte de un axioma explícito, documentado en el propio proyecto: **todo Pod puede comunicarse con todo Pod, en cualquier Namespace, sin NAT**. El CNI provee una red L3 plana donde cada Pod recibe una IP enrutable dentro del cluster. Este diseño simplifica el descubrimiento de servicios y elimina traducciones de puertos, pero desde la perspectiva de seguridad —la que evalúa el KCSA— es una superficie de ataque *east-west* sin fronteras internas.

El problema concreto de producción es el **movimiento lateral (lateral movement)** y el **blast radius**. Un atacante que compromete un solo Pod —vía una dependencia vulnerable, un SSRF, un secret filtrado— hereda la conectividad total de la red plana:

- Puede alcanzar la base de datos de otro equipo aunque ese servicio no esté expuesto por un `Service` de tipo `LoadBalancer`.
- Puede escanear el rango de Pods completo y enumerar servicios internos (`/metrics`, endpoints de admin, dashboards).
- Puede llegar al endpoint de metadata del cloud provider (`169.254.169.254`) y robar credenciales de IAM del nodo (SSRF → cloud takeover).
- Puede exfiltrar datos hacia Internet sin restricción de egress.
- Puede intentar alcanzar el API server o `kubelet` (`:10250`) desde dentro del cluster.

`NetworkPolicy` es el control nativo de **microsegmentación L3/L4** que transforma esa red plana en una arquitectura *zero-trust* de segmento por carga de trabajo. Es la respuesta de Kubernetes a "un firewall interno por Pod, definido declarativamente por labels en lugar de por IPs". En el threat model del KCSA, es el mecanismo primario para contener el compromiso de un Pod dentro de su propio segmento y evitar que se propague.

> **Punto clave de examen (y de producción):** la ausencia de NetworkPolicies **no es un "default seguro"**. Es "*allow-all* implícito". La segmentación es un *opt-in* explícito que el Platform team debe imponer, idealmente con una postura `default-deny` por Namespace.

---

## 2. Modelo conceptual: cómo evalúa Kubernetes una NetworkPolicy

Entender la semántica exacta es lo que separa una política que funciona de una que da falsa sensación de seguridad.

**Propiedades del recurso `NetworkPolicy` (`networking.k8s.io/v1`):**

1. **Es namespaced.** Una política solo afecta a Pods de su propio Namespace (los que su `podSelector` seleccione).
2. **Es aditiva y allow-only.** No existe una regla "deny" explícita en la API v1. Las políticas solo *permiten*. La negación surge por omisión: si algún tráfico no coincide con ninguna regla `allow` de una política que selecciona al Pod, se descarta. La unión (OR lógico) de todas las políticas que seleccionan a un Pod define lo permitido.
3. **Actúa en L3/L4.** Selecciona por IP (`ipBlock`), por identidad de Pod (`podSelector`), por Namespace (`namespaceSelector`) y por puerto/protocolo (TCP/UDP/SCTP). **No entiende L7**: no filtra por path HTTP, método, header ni por nombre DNS (FQDN).
4. **Requiere un CNI que la implemente.** El objeto es inerte sin un plugin que lo aplique (`kube-proxy` **no** aplica NetworkPolicies). Este es el error más caro y el gotcha número uno del examen.

**La regla de conmutación default-allow → default-deny:**

- Mientras **ninguna** política seleccione a un Pod en una dirección (Ingress o Egress), esa dirección permanece en *allow-all*.
- En cuanto **al menos una** política selecciona al Pod para `Ingress`, todo el Ingress no permitido explícitamente se deniega. Ídem para `Egress`.
- El campo `policyTypes` declara qué direcciones "activa" la política. **Si omitís `Egress` en `policyTypes`, la política no restringe egress aunque escribas reglas de egress** (y viceversa). Un `podSelector: {}` (vacío) selecciona **todos los Pods del Namespace**.

**Semántica AND vs OR de los selectores (fuente número uno de agujeros de seguridad):**

En una entrada `from`/`to`, los selectores dentro del **mismo elemento de lista** se combinan con **AND**; elementos separados de la lista se combinan con **OR**.

```yaml
# AND — Pods con label role=frontend QUE ESTÉN en namespaces con label env=prod
  - from:
    - namespaceSelector:
        matchLabels: { env: prod }
      podSelector:
        matchLabels: { role: frontend }
```

```yaml
# OR — (cualquier Pod en namespaces env=prod) O (Pods role=frontend del MISMO namespace)
  - from:
    - namespaceSelector:
        matchLabels: { env: prod }
    - podSelector:
        matchLabels: { role: frontend }
```

La diferencia es un solo guion. La segunda variante, escrita por error, abre el ingress a **todos** los Pods de los namespaces `env=prod`, no solo a los frontends: un agujero silencioso.

> **Regla del `podSelector` sin `namespaceSelector`:** un `podSelector` dentro de `from`/`to` sin `namespaceSelector` solo referencia Pods del **mismo Namespace** que la política. Para permitir tráfico cross-namespace, `namespaceSelector` es obligatorio.

---

## 3. Comparativas técnicas y trade-offs

### 3.1 Controles de segmentación: dónde encaja NetworkPolicy

| Dimensión | NetworkPolicy (v1) | Cloud Security Groups | Service Mesh (mTLS + AuthZ L7) | AdminNetworkPolicy (ANP/BANP) |
|---|---|---|---|---|
| Capa OSI | L3/L4 | L3/L4 | L7 (+ identidad mTLS) | L3/L4 |
| Alcance | Namespaced | Por instancia/ENI | Por workload (sidecar/eBPF) | Cluster-scoped |
| Modelo | Allow-only, aditivo | Allow-only | Allow/Deny por regla | Allow / Deny / Pass con prioridad |
| Identidad | Labels de Pod/NS | IP / tag de VM | SPIFFE / ServiceAccount | Labels de Pod/NS |
| Filtra por FQDN | No | No (salvo add-ons) | Sí | No |
| Filtra por path/método HTTP | No | No | Sí | No |
| Quién lo gobierna | Dev/App team | Cloud/Infra team | Platform/Mesh team | **Cluster admin** |
| Sobrevive a reprogramación de IP | Sí (identidad por label) | No (atado a IP/ENI) | Sí | Sí |
| Enforcement | CNI (iptables/eBPF) | Hypervisor/nube | Proxy (Envoy) / eBPF | CNI |

**Trade-off central:** NetworkPolicy es portable, nativa y barata en overhead, pero se detiene en L4. Todo lo que sea "permitir `GET /api` pero no `DELETE`", o "permitir egress a `api.stripe.com`" (cuyas IPs rotan), queda fuera de su alcance y empuja a un service mesh o a un CNI con capacidades L7 (Cilium).

### 3.2 CNIs y soporte de enforcement

| CNI | ¿Aplica NetworkPolicy v1? | Egress por FQDN | Reglas L7 | Data plane | Nota de seguridad |
|---|---|---|---|---|---|
| Calico | Sí | Vía `GlobalNetworkPolicy`/DNS policy (Enterprise) | Limitado | iptables / eBPF | `GlobalNetworkPolicy` añade orden y deny explícito |
| Cilium | Sí | Sí (`toFQDNs`) | Sí (`CiliumNetworkPolicy` HTTP/Kafka/DNS) | eBPF | Identidad por label, visibilidad Hubble |
| Antrea | Sí | Sí (Antrea-native) | Sí (`ClusterNetworkPolicy`) | OVS | Tiers y prioridades |
| Weave Net | Sí | No | No | Deprecado — sin mantenimiento activo |
| **Flannel** | **No** | — | — | VXLAN | **Escribís la policy y no pasa nada** |
| AWS VPC CNI | Sí (con `enableNetworkPolicy`) | No | No | eBPF | Requiere flag explícito en el agente |

> **Gotcha de examen y de producción:** Flannel **no** implementa NetworkPolicy. En un cluster con Flannel, `kubectl apply` de una política default-deny se acepta por la API y **no bloquea nada**. Es la peor combinación: el objeto existe, el dashboard lo muestra, y el enforcement no ocurre. Verificá siempre el CNI antes de confiar en una política.

### 3.3 NetworkPolicy v1 vs AdminNetworkPolicy (ANP/BANP)

El límite estructural de `NetworkPolicy` v1 es que **no puede expresar un deny explícito ni un orden de evaluación**, y es namespaced (un dev puede borrar la suya). SIG-Network introdujo la API `policy.networking.k8s.io` con `AdminNetworkPolicy` (ANP) y `BaselineAdminNetworkPolicy` (BANP), cluster-scoped y con acciones `Allow`/`Deny`/`Pass` y `priority`. Es el mecanismo pensado para que el **cluster admin** imponga guardrails que el usuario de Namespace no puede sobreescribir. Requiere un CNI que la soporte (Cilium, Antrea, Calico en versiones recientes).

---

## 4. Manifiestos completos

### 4.1 Baseline: default-deny de Ingress y Egress por Namespace

La piedra angular de zero-trust. Aplicada a un Namespace, cierra ambas direcciones para **todos** los Pods; a partir de ahí se abre lo mínimo necesario.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}            # selecciona TODOS los Pods del namespace
  policyTypes:
    - Ingress
    - Egress
  # sin reglas ingress/egress => se deniega todo en ambas direcciones
```

### 4.2 Permitir egress a DNS (obligatorio tras un default-deny egress)

Un `default-deny` de egress **rompe la resolución DNS**, y con ella casi todo el cluster (los Service se resuelven por nombre). Este es el primer allow que debe acompañar a cualquier egress deny. Nótese `podSelector: {}` y el selector del Namespace de kube-dns.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

> El label `kubernetes.io/metadata.name` lo aplica automáticamente el control plane a cada Namespace (`NamespaceDefaultLabelName`), y es la forma robusta de seleccionar un Namespace por nombre sin depender de labels custom.

### 4.3 Segmentación three-tier: frontend → backend → database

Modelo canónico de producción. El backend solo acepta ingress del frontend; la base de datos solo acepta ingress del backend. Se muestra el conjunto completo para el tier de base de datos, que es el más sensible.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-backend-only
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: postgres
      tier: database
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: orders-api
              tier: backend
      ports:
        - protocol: TCP
          port: 5432
  egress:
    # la DB solo necesita DNS; no debe originar tráfico hacia afuera
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: orders-api
      tier: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: web
              tier: frontend
      ports:
        - protocol: TCP
          port: 8080
```

### 4.4 Ingress cross-namespace controlado: solo desde monitoring

Permite que Prometheus (en el Namespace `monitoring`) haga scraping del puerto `/metrics`, usando AND entre `namespaceSelector` y `podSelector`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-metrics-scrape-from-monitoring
  namespace: payments
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:                     # AND: mismo bloque de lista
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 9090
```

### 4.5 Egress a Internet con bloqueo del endpoint de metadata (anti-SSRF)

Permite salida a Internet pero **excluye** el link-local del metadata del cloud (`169.254.169.254`) y los rangos RFC1918 internos, mitigando SSRF hacia credenciales de IAM del nodo. `ipBlock` es la única forma de filtrar por IP externa en la API v1.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-internet-block-metadata
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: orders-api
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32   # cloud metadata (SSRF → robo de credenciales IAM)
              - 10.0.0.0/8           # red interna / VPC
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

> **Límite de la API v1:** no podés escribir "egress a `api.stripe.com`". Solo CIDRs. Si las IPs del destino rotan, necesitás Cilium `toFQDNs` o un egress gateway. Esta es la razón técnica principal por la que muchos equipos migran a un CNI con capacidades de FQDN.

### 4.6 Extensión con Cilium (L7 y FQDN) — fuera de la API v1

Para contrastar el techo de NetworkPolicy, un `CiliumNetworkPolicy` que sí filtra por FQDN y por path HTTP:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: orders-api-l7-egress
  namespace: payments
spec:
  endpointSelector:
    matchLabels:
      app: orders-api
  egress:
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app: postgres
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

### 4.7 Guardrail cluster-wide: BaselineAdminNetworkPolicy

Postura por defecto impuesta por el cluster admin, con deny explícito que el usuario de Namespace **no puede** sobrescribir (solo puede *añadir* allows sobre ella vía NetworkPolicy v1).

```yaml
apiVersion: policy.networking.k8s.io/v1alpha1
kind: BaselineAdminNetworkPolicy
metadata:
  name: default
spec:
  subject:
    namespaces: {}            # todos los namespaces
  ingress:
    - name: "deny-cross-namespace"
      action: Deny
      from:
        - namespaces:
            notSameLabels:
              - kubernetes.io/metadata.name
```

---

## 5. Comandos CLI y salidas reales

**Verificar que el CNI aplica políticas (paso cero):**

```console
$ kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|antrea|weave|flannel'
calico-node-7fk2p        1/1   Running   0   6d   10.0.1.4   ip-10-0-1-4    <none> <none>
calico-node-q8m4z        1/1   Running   0   6d   10.0.2.9   ip-10-0-2-9    <none> <none>
calico-kube-controllers-6b9c4  1/1  Running  0  6d  192.168.1.3  ip-10-0-1-4  <none> <none>
```

**Listar y describir políticas:**

```console
$ kubectl get networkpolicy -n payments
NAME                                   POD-SELECTOR                  AGE
default-deny-all                       <none>                        3d
allow-dns-egress                       <none>                        3d
db-allow-backend-only                  app=postgres,tier=database    3d
backend-allow-frontend                 app=orders-api,tier=backend   3d
```

```console
$ kubectl describe networkpolicy db-allow-backend-only -n payments
Name:         db-allow-backend-only
Namespace:    payments
Created on:   2026-08-04 11:22:07 +0000 UTC
Spec:
  PodSelector:     app=postgres,tier=database
  Allowing ingress traffic:
    To Port: 5432/TCP
    From:
      PodSelector: app=orders-api,tier=backend
  Allowing egress traffic:
    To Port: 53/UDP
    To Port: 53/TCP
    To:
      NamespaceSelector: kubernetes.io/metadata.name=kube-system
      PodSelector: k8s-app=kube-dns
  Policy Types: Ingress, Egress
```

**Probar la conectividad (test empírico, la única prueba que vale):**

```console
$ kubectl run tester --rm -it --image=nicolaka/netshoot \
    -n payments --labels="app=web,tier=frontend" -- /bin/sh

# desde un frontend legítimo → backend: DEBE funcionar
/ # nc -zv -w 3 orders-api 8080
Connection to orders-api 8080 port [tcp/http-alt] succeeded!

# desde el frontend → base de datos: DEBE fallar (no hay allow)
/ # nc -zv -w 3 postgres 5432
nc: connect to postgres port 5432 (tcp) timed out: Operation now in progress
```

```console
# Pod SIN los labels permitidos → backend: DEBE fallar
$ kubectl run rogue --rm -it --image=nicolaka/netshoot \
    -n payments --labels="app=malware" -- /bin/sh
/ # nc -zv -w 3 orders-api 8080
nc: connect to orders-api port 8080 (tcp) timed out: Operation now in progress
```

> **Firma diagnóstica clave:** una política L3/L4 que bloquea produce **timeout** (el paquete se descarta silenciosamente), no `connection refused`. Un `connection refused` significa que el paquete **llegó** y el destino no escucha en ese puerto — la política **no** está bloqueando. Distinguir timeout de refused es lo primero al diagnosticar.

**Herramientas del CNI (Calico / Cilium):**

```console
$ calicoctl get networkpolicy -n payments -o wide
NAME                              ORDER   SELECTOR
knp.default.db-allow-backend-only 1000    (projectcalico.org/orchestrator == 'k8s') ...
```

```console
$ cilium connectivity test --namespace payments
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✅ [payments] frontend -> backend:8080 (allowed)
❌ [payments] frontend -> database:5432 (denied by policy) 
✅ 42/42 tests successful (0 warnings)
```

```console
# ver en vivo qué está descartando Cilium (identidad, verdict DROPPED)
$ kubectl exec -n kube-system ds/cilium -- cilium monitor --type drop
xx drop (Policy denied) flow 0x0 to endpoint 1834, \
  identity 4021->1990: 10.0.3.11:51824 -> 10.0.2.7:5432 tcp SYN
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Modos de falla más comunes

| Síntoma | Causa raíz | Diagnóstico | Corrección |
|---|---|---|---|
| La política "no bloquea nada" | CNI no aplica NetworkPolicy (Flannel) o AWS CNI sin `enableNetworkPolicy` | `kubectl get pods -n kube-system` por el CNI | Instalar/activar un CNI con enforcement |
| Egress se rompe todo tras default-deny | DNS bloqueado | Los Pods fallan con "name resolution error", no timeout de IP | Añadir `allow-dns-egress` (§4.2) |
| Más tráfico del esperado pasa | AND escrito como OR (guion de más) | `kubectl describe` muestra `From:` con dos bloques separados | Unir selectores en un solo elemento de lista |
| Reglas de egress ignoradas | `Egress` falta en `policyTypes` | `describe` muestra `Policy Types: Ingress` únicamente | Añadir `Egress` a `policyTypes` |
| Cross-namespace no funciona | `podSelector` sin `namespaceSelector` | El from solo referencia el namespace propio | Añadir `namespaceSelector` |
| Política aplicada, sin efecto | Namespace equivocado (recurso namespaced) | `kubectl get netpol -A` | Reaplicar en el namespace correcto |
| Puerto correcto, bloqueado igual | Named port sin resolver o protocolo (UDP vs TCP) errado | `describe` del Pod y de la policy | Usar número de puerto o alinear `protocol` |

### 6.2 Flujo de diagnóstico

1. **¿El CNI aplica?** Si es Flannel o AWS CNI sin el flag, ninguna política funciona. Este chequeo va primero, siempre.
2. **¿La política selecciona al Pod?** Comparar los labels del Pod (`kubectl get pod --show-labels`) con el `podSelector` de la policy.
3. **¿La dirección está activada?** `policyTypes` debe incluir `Ingress`/`Egress` según el caso.
4. **¿Timeout o refused?** Timeout → lo descarta la política (o falta un allow). Refused → el paquete pasa; el problema no es la NetworkPolicy.
5. **¿DNS?** Si es egress y falla la resolución de nombres, es el gotcha de DNS.
6. **AND vs OR:** revisar la estructura de la lista `from`/`to` con `kubectl describe` (no confiar en el YAML fuente).
7. **Traza del data plane:** `cilium monitor --type drop` o los logs de `calico-node` muestran el verdict real con identidad y puerto.

### 6.3 Verificación como código

La única prueba válida es empírica: Pods de test con y sin los labels permitidos, verificando que el permitido conecta y el no permitido hace timeout (`kubectl run` de §5). Automatizado en CI, `cilium connectivity test` (o un conjunto de `nc` con `--labels`) convierte la postura de red en una aserción reproducible que corre en cada cambio de política.

---

## 7. Referencias

- Network Policies — Kubernetes Documentation: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- The Kubernetes network model: https://kubernetes.io/docs/concepts/services-networking/
- Declare Network Policy (walkthrough): https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- NetworkPolicy API reference (`networking.k8s.io/v1`): https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Admin Network Policy (ANP/BANP), SIG-Network: https://network-policy-api.sigs.k8s.io/
- Kubernetes NetworkPolicy recipes: https://github.com/ahmetb/kubernetes-network-policy-recipes
- Calico — Kubernetes network policy: https://docs.tigera.io/calico/latest/network-policy/
- Cilium — Network Policy (L3/L4/L7, FQDN): https://docs.cilium.io/en/stable/security/policy/
- Amazon VPC CNI — Network Policy: https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html
- KCSA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf