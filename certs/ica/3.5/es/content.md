# 3.5 — Conectando Workloads Dentro de la Malla con Workloads y Servicios Externos

> **Dominio:** Escenarios Avanzados · **Peso en el examen:** 5%
> **Prerrequisitos:** VirtualService / DestinationRule / Gateway (Gestión de Tráfico), PeerAuthentication y mTLS de la malla (Asegurando Workloads).

Esta competencia cubre el *límite de la malla* en **ambas direcciones**:

1. **Salida (outbound)** — un Pod dentro de la malla llamando a algo que la malla no gestiona: una API SaaS, una base de datos gestionada, un endpoint HTTPS de terceros. La primitiva es el **`ServiceEntry`**, opcionalmente enrutado a través de un **`Gateway` de egreso**.
2. **Incorporación de entrada (inbound onboarding)** — un workload que no corre en Kubernetes (una VM, un servicio bare-metal) que querés tratar como un *miembro de primera clase de la malla* — identidad mTLS, balanceo de carga, telemetría. Las primitivas son **`WorkloadGroup`** y **`WorkloadEntry`**, vinculadas a un `ServiceEntry`.

---

## 1. El problema de producción

La malla te da identidad, mTLS, reintentos, timeouts, circuit breaking y telemetría de señales doradas — pero **solo para el tráfico entre endpoints registrados**. Todo lo que el sidecar no puede resolver en el registro interno de servicios cae en uno de dos destinos por defecto:

- **`ALLOW_ANY` (el `outboundTrafficPolicy.mode` por defecto)** — el sidecar incluye un `PassthroughCluster` de tipo catch-all. Cualquier egreso a cualquier host en internet *simplemente funciona* como un túnel TCP opaco. Cómodo, y la pesadilla de un auditor de seguridad: **no hay visibilidad L7, ni política, ni allow-listing de hosts, y una ruta de exfiltración de datos completamente abierta**. Un Pod comprometido puede hacer `curl` al servidor de un atacante y la malla no reporta nada más que un conteo de bytes hacia `0.0.0.0`.
- **`REGISTRY_ONLY`** — todo lo que no esté en el registro golpea el `BlackHoleCluster` y falla cerrado. Seguro, pero ahora *cada* dependencia externa legítima debe declararse explícitamente. Esa declaración es el `ServiceEntry`.

La decisión arquitectónica es por lo tanto: **la comodidad de fallar-abierto vs. el control de fallar-cerrado**, y — una vez que elegís el control — *dónde* vive el punto de control:

- **Egreso local en el sidecar** — el propio Envoy de cada workload origina TLS y aplica el enrutamiento. Barato, sin salto extra, pero la política queda distribuida a lo largo de cada nodo y un nodo comprometido con `NET_ADMIN` puede saltearla.
- **Egress gateway centralizado** — todo el egreso se canaliza a través de un conjunto dedicado de proxies Envoy fijados a nodos etiquetados. Esto es lo que necesitás para **firewalling de egreso** (solo las IPs de egreso de los nodos del gateway están en el allow-list del firewall corporativo), **originación centralizada de TLS**, **logging de auditoría de egreso** y **cumplimiento** (PCI-DSS §1.3, controles de egreso de red de SOC2).

El problema inverso — **incorporación de VM/legacy** — existe porque las migraciones nunca son atómicas. Tenés un servicio de pagos en una VM que todavía no puede moverse, pero los nuevos servicios de Kubernetes que lo llaman siguen mereciendo mTLS, identidad mutua y balanceo de carga con conciencia de localidad. `WorkloadEntry` le da a esa VM una identidad SPIFFE de la malla y la hace direccionable exactamente como un Pod.

---

## 2. Conceptos y compensaciones comparativas

### 2.1 El `ServiceEntry` — el único punto de extensión del registro

Un `ServiceEntry` agrega hosts al registro interno de servicios de Istio para que los sidecars puedan construir clusters/rutas hacia ellos. Dos ejes dominan su comportamiento: **`location`** y **`resolution`**.

| `location` | Significado | Comportamiento mTLS | Uso típico |
|---|---|---|---|
| `MESH_EXTERNAL` | Fuera de la malla, no confiable | Sin mTLS de Istio; el TLS debe ser *originado* explícitamente | APIs SaaS, HTTPS público, DBs externas |
| `MESH_INTERNAL` | Parte de la malla, confiable | Se aplica mTLS de Istio (con `WorkloadEntry`) | VMs / workloads no-K8s incorporados a la malla |

| `resolution` | Cómo Envoy encuentra los endpoints | ¿Requiere `endpoints`? | Notas |
|---|---|---|---|
| `NONE` | Passthrough al IP de destino original | No | Túnel L4; solo enrutamiento por SNI/host, sin LB |
| `STATIC` | Usa las IPs en `endpoints` (o `WorkloadEntry`) | Sí | Incorporación de VM, backends de IP fija |
| `DNS` | Envoy resuelve cada entrada de `hosts` vía DNS, por endpoint | No (usa `hosts`) | Estándar para FQDNs externos |
| `DNS_ROUND_ROBIN` | Resuelve **una vez**, usa una única IP devuelta hasta que expira | No | Menor carga de DNS; bueno para un único registro A estable (1.11+) |

> **Gotcha:** `resolution: NONE` te da un túnel opaco — obtenés telemetría de bytes y SNI, pero **no podés** hacer enrutamiento HTTP, reintentos ni originación de TLS, porque Envoy nunca termina L7. Si querés funcionalidades L7 necesitás `DNS` (o `STATIC`) para que Envoy sea dueño de endpoints reales.

### 2.2 Modos de control de egreso

| `meshConfig.outboundTrafficPolicy.mode` | Host desconocido → | Postura de seguridad | Costo operativo |
|---|---|---|---|
| `ALLOW_ANY` (por defecto) | `PassthroughCluster` (funciona, opaco) | Débil — exfiltración abierta | Cero |
| `REGISTRY_ONLY` | `BlackHoleCluster` (502 / conexión rechazada) | Fuerte — denegar por defecto | Cada dependencia debe declararse |

Podés sobrescribir esto **por workload** con el `outboundTrafficPolicy` del recurso `Sidecar`, permitiéndote correr `ALLOW_ANY` a nivel de malla durante la migración mientras fijás namespaces sensibles a `REGISTRY_ONLY`.

### 2.3 Local en el sidecar vs. egress gateway

| Dimensión | Originación de TLS en el sidecar | Egress gateway |
|---|---|---|
| Salto de red extra | No | Sí (Pod → egress gw → externo) |
| Superficie de allow-list del firewall | Cada IP de nodo | Solo las IPs de nodo del egress-gw |
| Auditoría central / logging L7 | Por Pod, disperso | Un único punto de estrangulamiento |
| Ubicación de originación de TLS/mTLS | El sidecar de cada app | Proxies dedicados |
| Radio de impacto de un bypass | Cualquier nodo | Aislado, nodos dedicados |
| Complejidad | Baja (1 `DestinationRule`) | Alta (`Gateway`+`VS`+2×`DR`+`Sidecar`) |
| Ajuste de cumplimiento (PCI/SOC2) | Pobre | Fuerte |

> **Punto clave del examen:** un egress gateway **no es una frontera de seguridad por sí mismo**. Un workload malicioso puede ignorar el `VirtualService` e ir directo a menos que *además* (a) establezcas `REGISTRY_ONLY`, (b) restrinjas el egreso con un recurso `Sidecar` o una `NetworkPolicy` de Kubernetes, y (c) hagas firewall del cluster de modo que solo los nodos del egress-gateway puedan alcanzar internet.

### 2.4 Modos TLS en `DestinationRule.trafficPolicy.tls`

| `mode` | Quién inicia el TLS | ¿Se envía cert del cliente? | Caso de uso |
|---|---|---|---|
| `DISABLE` | Nadie (texto plano) | No | Backend en texto claro |
| `SIMPLE` | Istio (TLS unidireccional) | No | Originar TLS hacia un endpoint HTTPS público |
| `MUTUAL` | Istio (mTLS con tus certs) | Sí (`credentialName` / archivos) | Servicio externo que requiere certs de cliente |
| `ISTIO_MUTUAL` | Istio usando sus propios certs SPIFFE | Sí (identidad de la malla) | Tramo sidecar → egress gateway |

### 2.5 Primitivas de workloads externos

| Recurso | Analogía | Propósito |
|---|---|---|
| `WorkloadEntry` | Un objeto `Pod` | Un endpoint no-K8s (VM): dirección, labels, `serviceAccount`, red |
| `WorkloadGroup` | Un `Deployment`/plantilla | Plantilla + readiness probe que habilita la **auto-registración** de VMs |
| `ServiceEntry` (`MESH_INTERNAL`, `workloadSelector`) | Un `Service` | Agrupa endpoints `WorkloadEntry` en un host direccionable para clientes dentro de la malla |

---

## 3. Manifiestos completos, sin abreviar

### 3.1 Fallar cerrado, luego declarar una dependencia externa

Habilitar el egreso denegar-por-defecto:

```yaml
# meshconfig-registry-only.yaml — applied via the IstioOperator/Helm values
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  meshConfig:
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
    accessLogFile: /dev/stdout          # make egress denials observable
```

Declarar una API HTTPS externa para que los Pods dentro de la malla puedan alcanzarla:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-payments-api
  namespace: prod
spec:
  hosts:
  - api.payments.example.com
  location: MESH_EXTERNAL
  ports:
  - number: 443
    name: https
    protocol: TLS          # TLS, not HTTPS: Envoy will not terminate, it tunnels by SNI
  resolution: DNS
  exportTo:
  - "."                    # visible only inside the prod namespace, not mesh-wide
```

### 3.2 Originación de TLS local en el sidecar (descargar TLS de la app)

La aplicación habla **HTTP plano en el puerto 80**; el sidecar lo eleva a **HTTPS en 443**:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: edition-cnn-com
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
    targetPort: 443        # sidecar connects to 443 upstream…
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
  namespace: prod
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 80         # …and originates TLS on the port the app used
      tls:
        mode: SIMPLE
        sni: edition.cnn.com
```

### 3.3 Egress gateway con originación de TLS (el patrón de producción)

Cinco objetos: el `ServiceEntry` (host externo), el `Gateway` (listener de egreso, mTLS desde los sidecars), un `DestinationRule` que define el *subset del gateway* (el tramo sidecar→gateway usa `ISTIO_MUTUAL`), el `VirtualService` que cose malla→gateway→externo, y un `DestinationRule` que origina TLS hacia el host externo.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: cnn
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: prod
spec:
  selector:
    istio: egressgateway          # matches the deployed egress gw Pods
  servers:
  - port:
      number: 443
      name: tls
      protocol: HTTPS
    hosts:
    - edition.cnn.com
    tls:
      mode: ISTIO_MUTUAL          # sidecars authenticate to the gateway with mesh identity
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
  namespace: prod
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: cnn
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
      portLevelSettings:
      - port:
          number: 443
        tls:
          mode: ISTIO_MUTUAL      # leg 1: sidecar → egress gateway
          sni: edition.cnn.com
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
  namespace: prod
spec:
  hosts:
  - edition.cnn.com
  gateways:
  - istio-egressgateway            # the Gateway above
  - mesh                           # the reserved keyword = all sidecars
  http:
  - match:
    - gateways:
      - mesh                       # leg 0: sidecar sees app request on port 80
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: cnn
        port:
          number: 443
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway        # leg 2: request arrives at the gateway on 443
      port: 443
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 443
      weight: 100
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
  namespace: prod
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE               # leg 3: egress gateway → external, real TLS origination
```

Restringir el egreso de modo que los workloads *no puedan* saltear el gateway, cerrando la brecha de seguridad señalada en §2.3:

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: prod
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  egress:
  - hosts:
    - "./*"                        # same namespace
    - "istio-system/*"            # control plane + egress gateway
```

### 3.4 Originación de mTLS hacia un servicio que requiere certs de cliente

Montá las credenciales del cliente como un secret de Kubernetes y referencialas por `credentialName` (servidas vía SDS — sin reinicio del proxy):

```yaml
# kubectl create secret generic client-credential -n istio-system \
#   --from-file=tls.key=client.key \
#   --from-file=tls.crt=client.crt \
#   --from-file=ca.crt=ca.crt
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-mtls-for-partner
  namespace: prod
spec:
  host: api.partner.example.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: MUTUAL
        credentialName: client-credential   # must live where the proxy runs (egress gw ns)
        sni: api.partner.example.com
```

### 3.5 Incorporando una VM: `WorkloadGroup` + `WorkloadEntry` auto-registrado

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: forecast
  namespace: forecast
spec:
  metadata:
    labels:
      app: forecast
      class: vm
  template:
    ports:
      http: 8080
    serviceAccount: forecast
    network: vm-network
  probe:
    periodSeconds: 5
    initialDelaySeconds: 1
    httpGet:
      port: 8080
      path: /healthz         # VM is only registered/Ready when this passes
```

Exponé los endpoints de la VM a los clientes dentro de la malla como un host estable (notá `MESH_INTERNAL` — se aplica mTLS):

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: forecast
  namespace: forecast
spec:
  hosts:
  - forecast.forecast.svc.cluster.local
  location: MESH_INTERNAL
  ports:
  - number: 8080
    name: http
    protocol: HTTP
    targetPort: 8080
  resolution: STATIC
  workloadSelector:
    labels:
      app: forecast          # selects the auto-registered WorkloadEntry objects
```

Un endpoint de VM declarado **manualmente** (sin auto-registración) se ve así:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: forecast-vm-1
  namespace: forecast
spec:
  address: 10.128.0.13
  labels:
    app: forecast
    class: vm
  serviceAccount: forecast
  network: vm-network
  ports:
    http: 8080
  weight: 1
```

---

## 4. Flujo de trabajo de CLI y salida real de terminal

### 4.1 Probar el comportamiento de fallar-cerrado

```console
$ export SOURCE_POD=$(kubectl get pod -n prod -l app=sleep -o jsonpath='{.items[0].metadata.name}')

# Before any ServiceEntry, with REGISTRY_ONLY — plain HTTP is black-holed:
$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -sIL http://edition.cnn.com/politics -o /dev/null -w "%{http_code}\n"
502

# HTTPS passthrough is refused at the TLS layer (curl exit 35 = SSL connect error):
$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -sIL https://edition.cnn.com/politics -o /dev/null -w "%{http_code}\n"
command terminated with exit code 35
```

Después de aplicar los objetos `ServiceEntry` + egress gateway de §3.3:

```console
$ kubectl apply -f cnn-egress-gateway.yaml
serviceentry.networking.istio.io/cnn created
gateway.networking.istio.io/istio-egressgateway created
destinationrule.networking.istio.io/egressgateway-for-cnn created
virtualservice.networking.istio.io/direct-cnn-through-egress-gateway created
destinationrule.networking.istio.io/originate-tls-for-edition-cnn-com created

$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -sIL http://edition.cnn.com/politics -o /dev/null -w "%{http_code}\n"
200
```

### 4.2 Confirmar que el tráfico realmente atravesó el egress gateway

```console
$ kubectl logs -n istio-system -l istio=egressgateway | tail -1
[2026-08-08T14:22:07.913Z] "GET /politics HTTP/2" 200 - via_upstream -
  "-" 0 1150631 412 411 "10.244.2.19"
  "curl/8.5.0" "b6f2a1c8-..." "edition.cnn.com"
  "outbound|443||edition.cnn.com" 10.244.1.4:41284 10.244.1.4:8443
  10.244.2.19:52180 edition.cnn.com -
```

La línea prueba ambos tramos: la solicitud entró al gateway (`:8443`) y el cluster upstream es `outbound|443||edition.cnn.com`.

### 4.3 Inspeccionar la configuración de Envoy generada

```console
$ istioctl proxy-config clusters "$SOURCE_POD.prod" | grep -E 'cnn|Passthrough|BlackHole'
edition.cnn.com                          443  -   outbound   DNS
BlackHoleCluster                         -    -   -          STATIC
# (No PassthroughCluster line — because outboundTrafficPolicy is REGISTRY_ONLY)

$ istioctl proxy-config endpoints deploy/istio-egressgateway -n istio-system \
    --cluster "outbound|443||edition.cnn.com"
ENDPOINT             STATUS   OUTLIER CHECK   CLUSTER
151.101.3.5:443      HEALTHY  OK              outbound|443||edition.cnn.com
151.101.67.5:443     HEALTHY  OK              outbound|443||edition.cnn.com
```

### 4.4 Incorporar una VM de punta a punta

```console
$ istioctl x workload group create \
    --name forecast --namespace forecast \
    --labels app=forecast --serviceAccount forecast \
    --network vm-network > workloadgroup.yaml
$ kubectl apply -f workloadgroup.yaml
workloadgroup.networking.istio.io/forecast created

# Generate the artifacts the VM needs to join the mesh:
$ istioctl x workload entry configure \
    --file workloadgroup.yaml \
    --output /tmp/vmfiles \
    --clusterID Kubernetes \
    --autoregister
Warning: a security token for namespace "forecast" and service account
"forecast" has been generated and stored at "/tmp/vmfiles/istio-token"
Configuration generation into directory /tmp/vmfiles was successful

$ ls /tmp/vmfiles
cluster.env  hosts  istio-token  mesh.yaml  root-cert.pem
```

Copiá esos archivos a la VM, instalá el sidecar, luego iniciá (`systemctl start istio`). Como se usó `--autoregister` con un `WorkloadGroup`, la VM se registra a sí misma una vez que su probe pasa:

```console
$ kubectl get workloadentry -n forecast
NAME                                AGE   ADDRESS       
forecast-10.128.0.13-vm-network     47s   10.128.0.13   

$ kubectl exec -n prod "$SOURCE_POD" -c sleep -- \
    curl -s http://forecast.forecast.svc.cluster.local:8080/api/v1/forecast
{"city":"buenos-aires","tempC":19,"served-by":"vm-10.128.0.13"}
```

Verificá que el tramo de la VM esté genuinamente cifrado con mTLS (identidad, no solo alcanzabilidad):

```console
$ istioctl x workload entry configure --help >/dev/null   # sanity: version has the subcommand
$ istioctl proxy-config secret "$SOURCE_POD.prod" -o json \
    | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
    | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
    X509v3 Subject Alternative Name: critical
        URI:spiffe://cluster.local/ns/prod/sa/sleep
```

---

## 5. Verificación y diagnóstico de fallos

**Primer reflejo ante cualquier problema de egreso:** leé el access log del *sidecar de origen* y los flags de respuesta, luego confirmá la configuración con `istioctl proxy-config`.

```console
$ kubectl logs -n prod "$SOURCE_POD" -c istio-proxy | tail -3
```

| Síntoma / señal | Causa probable | Confirmar | Solución |
|---|---|---|---|
| `502` en HTTP externo, cluster `BlackHoleCluster` en el log | `REGISTRY_ONLY` y no hay `ServiceEntry` para el host | `istioctl pc clusters $POD \| grep <host>` no devuelve nada | Agregar un `ServiceEntry` (o acotar con `exportTo`) |
| curl **exit 35** a un host HTTPS | Igual que arriba, pero en el passthrough de TLS | el log no muestra ruta para el SNI | Declarar el host con `protocol: TLS`/`HTTPS` |
| Flag de respuesta **`NR`** (no route) | Desajuste de ruta en `VirtualService` (puerto o gateway match incorrecto) | `istioctl pc routes $POD` | Corregir el bloque `match.port`/`gateways` |
| Flag de respuesta **`UH`** (no healthy upstream) | Endpoints sin resolver | `istioctl pc endpoints` vacío | `resolution: DNS` para FQDN, o corregir la dirección del `WorkloadEntry` |
| Doble cifrado / basura en el handshake TLS | La app **ya** hace HTTPS *y* el `DestinationRule` origina TLS de nuevo | la app envía a `:443` en lugar de `:80` | Apuntar la app al puerto HTTP; originar solo en ese puerto |
| Egress gateway ignorado, el tráfico va directo | Falta el match de gateway `mesh`, o no hay bloqueo con `Sidecar`/`REGISTRY_ONLY` | el log muestra `outbound|…|<host>` en el sidecar de la *app*, no en el gw | Agregar el tramo de match `mesh` **y** `REGISTRY_ONLY` + `Sidecar egress` |
| Secret de `credentialName` no encontrado | El secret está en el namespace incorrecto | log de error del egress gw `SDS: failed to fetch` | Poner el secret en el namespace del **proxy** (`istio-system`) |
| El `WorkloadEntry` de la VM nunca aparece | Probe fallando o token expirado | `kubectl get we -n <ns>` vacío; logs del `istio-proxy` de la VM | Corregir el `probe`, re-copiar el `istio-token` |
| VM alcanzable pero en texto plano (sin mTLS) | El `ServiceEntry` es `MESH_EXTERNAL` | el tráfico funciona pero sin SAN SPIFFE | Establecer `location: MESH_INTERNAL` |

**Trampas de alcance que vale la pena memorizar:**

- **`exportTo`** en un `ServiceEntry`/`DestinationRule`: `"."` = solo el namespace actual, `"*"` = a nivel de malla (por defecto). Un `ServiceEntry` que "funciona en dev pero no en prod" es casi siempre un desajuste de `exportTo`.
- Una lista `egress.hosts` de un `Sidecar` que omite `istio-system/*` romperá el tráfico sidecar→egress-gateway y del control plane.
- `resolution: NONE` **no puede** llevar una originación de TLS de un `DestinationRule` — Envoy no tiene endpoints de cluster contra los cuales originar. Cambiá a `DNS`.

**Nota sobre modo ambient:** en el dataplane ambient, `ServiceEntry` todavía registra hosts externos, pero el egreso se origina desde el **waypoint proxy** (para L7) o **ztunnel** (L4); no hay un sidecar de egreso por Pod, y el patrón `istio-egressgateway` se reemplaza por un **waypoint** de namespace/servicio. El modelo `WorkloadEntry`/`WorkloadGroup` no cambia.

---

## 6. Referencias

- Istio — *Accessing External Services* (`outboundTrafficPolicy`, `ServiceEntry`): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio — *Egress TLS Origination* (sidecar-local): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- Istio — *Egress Gateway TLS Origination*: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/
- Istio — *Egress Gateways*: https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/
- Istio — *Use an egress gateway to enforce egress traffic* (`Sidecar`, `REGISTRY_ONLY`): https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/
- Istio — `ServiceEntry` API reference (`location`, `resolution`, `exportTo`, `workloadSelector`): https://istio.io/latest/docs/reference/config/networking/service-entry/
- Istio — `WorkloadEntry` API reference: https://istio.io/latest/docs/reference/config/networking/workload-entry/
- Istio — `WorkloadGroup` API reference: https://istio.io/latest/docs/reference/config/networking/workload-group/
- Istio — `Sidecar` API reference (`egress`, `outboundTrafficPolicy`): https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio — `DestinationRule` `ClientTLSSettings` (TLS modes): https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings
- Istio — *Virtual Machine Installation* (VM onboarding, `istioctl x workload`): https://istio.io/latest/docs/setup/install/virtual-machine/
- Istio — *Bookinfo with a Virtual Machine* (auto-registration walkthrough): https://istio.io/latest/docs/examples/virtual-machines/
- Istio — *Ambient egress / waypoints*: https://istio.io/latest/docs/ambient/usage/
- CNCF — *Istio Certified Associate (ICA) Curriculum*: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf