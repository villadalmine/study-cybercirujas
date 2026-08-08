# Exercises — 3.5 Connecting In-Mesh Workloads to External Workloads and Services

> **Alcance.** Estos labs guiados toman un cliente in-mesh (un pod con sidecar inyectado) y lo conectan progresivamente a workloads que viven *fuera* de la malla: endpoints HTTP/TLS públicos, servicios con TLS originado, tráfico canalizado a través de un egress gateway dedicado y, por último, un workload que no es de Kubernetes (una VM) unido a la malla. Vas a registrar endpoints externos en el service registry de Istio, restringir el egress y exponer un workload externo como un servicio de malla de primera clase.
>
> **Tiempo estimado:** 60–90 min · **Peso en el examen:** 5

## Prerrequisitos del lab

- Un cluster de Kubernetes (kind/minikube/gestionado) con el contexto de `kubectl` configurado.
- `istioctl` que coincida con la versión de tu control plane (`istioctl version`).
- Istio instalado con el profile `demo` (trae el egress gateway que necesitás en el Ejercicio 4):

```bash
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled --overwrite
```

Verificá que el egress gateway exista — varios pasos posteriores dependen de él:

```bash
kubectl get deploy -n istio-system
```

```
NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
istio-egressgateway     1/1     1            1           40s
istio-ingressgateway    1/1     1            1           40s
istiod                  1/1     1            1           55s
```

> Fuentes: [Istio install profiles](https://istio.io/latest/docs/setup/additional-setup/config-profiles/) · [Accessing external services](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/)

---

## Exercise 1 — Register an external service with a `ServiceEntry`

La malla solo conoce los hosts que están en su service registry. `ServiceEntry` agrega un host externo a ese registry para que los sidecars de Envoy puedan enrutar hacia él y para que Istio pueda aplicar routing, reintentos, timeouts y telemetría — aunque el destino esté fuera del cluster.

1. Desplegá el sample `curl` como tu cliente in-mesh y capturá el nombre de su pod:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/curl/curl.yaml
export SOURCE_POD=$(kubectl get pod -l app=curl -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$SOURCE_POD"
```

```
NAME                    READY   STATUS    RESTARTS   AGE
curl-7b549f5c4-2m9pn    2/2     Running   0          20s
```

> El `2/2` confirma que el sidecar (`istio-proxy`) se inyectó junto al contenedor `curl`. Si usás un Istio más viejo, el sample equivalente es `samples/sleep/sleep.yaml` con `app=sleep`.

2. Confirmá que el sidecar **todavía no** tiene un cluster para `httpbin.org`:

```bash
istioctl proxy-config cluster "$SOURCE_POD" --fqdn httpbin.org
```

```
SERVICE FQDN     PORT     SUBSET     DIRECTION     TYPE     DESTINATION RULE
```

*(vacío — el host es desconocido para este proxy)*

3. Alcanzá el host externo de todos modos y notá que igual funciona:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.org/get
```

```
200
```

4. Creá un `ServiceEntry` para que el host se convierta en un destino de malla registrado y de primera clase:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-ext
spec:
  hosts:
    - httpbin.org
  ports:
    - number: 80
      name: http
      protocol: HTTP
    - number: 443
      name: https
      protocol: TLS
  location: MESH_EXTERNAL
  resolution: DNS
```

```bash
kubectl apply -f httpbin-se.yaml
istioctl proxy-config cluster "$SOURCE_POD" --fqdn httpbin.org
```

```
SERVICE FQDN     PORT     SUBSET     DIRECTION     TYPE     DESTINATION RULE
httpbin.org      80       -          outbound      STRICT_DNS
httpbin.org      443      -          outbound      STRICT_DNS
```

**Verificación de comprensión**

- **Q1.** En el paso 3 la solicitud a `httpbin.org` devolvió `200` *antes* de que existiera cualquier `ServiceEntry`. ¿Qué configuración a nivel de toda la malla lo hizo posible, y qué se rompería si la invirtieras?
- **Q2.** El `ServiceEntry` usa `location: MESH_EXTERNAL` y `resolution: DNS`. ¿Qué le indica cada campo al sidecar que haga?
- **Q3.** ¿Por qué importa agregar el `ServiceEntry` si la conectividad ya funcionaba? Nombrá dos capacidades que ganás.

---

## Exercise 2 — Lock down egress with `REGISTRY_ONLY`

La política de salida por defecto (`ALLOW_ANY`) permite que los pods alcancen *cualquier* dirección externa — cómodo, pero lo opuesto al menor privilegio. Cambiar a `REGISTRY_ONLY` bloquea todo lo que el registry no conoce, convirtiendo a `ServiceEntry` en una allow-list.

1. Inspeccioná la política de tráfico de salida actual:

```bash
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | grep -A1 outboundTrafficPolicy
```

Si no imprime nada, el modo es el default implícito `ALLOW_ANY`.

2. Cambiá la malla a `REGISTRY_ONLY`:

```bash
istioctl install --set profile=demo \
  --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
```

3. Probá un host externo que **no** tenga `ServiceEntry`:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://example.com
```

```
000
command terminated with exit code 56
```

> Envoy no tiene un cluster para `example.com`, así que la solicitud se enruta al `BlackHoleCluster` incorporado y se resetea. El exit code `56` / HTTP `000` es la huella de un egress bloqueado por el registry.

4. Confirmá que el host que registraste en el Ejercicio 1 sigue funcionando:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://httpbin.org/get
```

```
200
```

5. Demostrá que el bloqueo es impulsado por el registry agregando `example.com`:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: example-ext
spec:
  hosts:
    - example.com
  ports:
    - number: 80
      name: http
      protocol: HTTP
  location: MESH_EXTERNAL
  resolution: DNS
```

```bash
kubectl apply -f example-se.yaml
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://example.com
```

```
200
```

**Verificación de comprensión**

- **Q4.** Describí el camino exacto que toma una solicitud a un host no registrado bajo `REGISTRY_ONLY`. ¿Qué cluster de Envoy la maneja, y en qué se diferencia de una ruta a un `PassthroughCluster`?
- **Q5.** Un compañero dice "`REGISTRY_ONLY` es un firewall". ¿Por qué eso es solo parcialmente cierto — qué capa lo está aplicando realmente, y cómo podría eludirlo un workload si *no* estuviera en la malla?

---

## Exercise 3 — Originate TLS at the sidecar

Las aplicaciones suelen hablar HTTP plano internamente mientras que el endpoint externo requiere HTTPS. En lugar de embeber TLS en la app, dejá que el sidecar *origine* TLS: la app envía HTTP al puerto 80, y Envoy lo eleva a HTTPS sobre el cable.

1. Registrá el host externo, declarando un puerto HTTP que se redirige al puerto TLS:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: edition-cnn-com
spec:
  hosts:
    - edition.cnn.com
  ports:
    - number: 80
      name: http-port
      protocol: HTTP
      targetPort: 443
    - number: 443
      name: https-port
      protocol: HTTPS
  location: MESH_EXTERNAL
  resolution: DNS
```

2. Agregá un `DestinationRule` que le indique al sidecar que origine TLS para el tráfico que llega al puerto 80:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: edition-cnn-com
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
      - port:
          number: 80
        tls:
          mode: SIMPLE
          sni: edition.cnn.com
```

```bash
kubectl apply -f cnn-se.yaml -f cnn-dr.yaml
```

3. Enviá **HTTP plano** al puerto 80 y observá un fetch HTTPS exitoso:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sSL -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
```

```
200
```

4. Confirmá que la app nunca envió TLS ella misma — lo hizo el sidecar. Observá que una llamada `https://` cruda del lado de la app es innecesaria y que el mapeo de `targetPort` hizo la redirección:

```bash
istioctl proxy-config listener "$SOURCE_POD" --port 80 -o json | grep -i sni
```

```
"sni": "edition.cnn.com"
```

**Verificación de comprensión**

- **Q6.** La app se conecta a `http://edition.cnn.com` en el puerto 80, y sin embargo la conexión a CNN es HTTPS. Rastreá cómo se transforma la solicitud. ¿Qué rol cumple `targetPort: 443`, y qué agrega `tls.mode: SIMPLE`?
- **Q7.** ¿Cuándo pondrías `tls.mode: MUTUAL` en lugar de `SIMPLE` en este `DestinationRule`, y qué configuración extra requeriría?

---

## Exercise 4 — Funnel egress through an egress gateway

Un `ServiceEntry` permite que el sidecar de *cualquier* nodo haga egress directamente. Los entornos regulados suelen exigir que todo el tráfico de salida salga a través de un pequeño conjunto de nodos controlados y monitoreables. El egress gateway es un Envoy dedicado en el borde de la malla a través del cual se fuerza todo el egress.

1. Definí un `Gateway` en el deployment de egress para el host de destino:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - edition.cnn.com
```

2. Creá un subset de `DestinationRule` para el egress gateway, y un `VirtualService` que dirija el tráfico de la malla hacia el gateway, y luego hacia afuera a CNN:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
    - name: cnn
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
spec:
  hosts:
    - edition.cnn.com
  gateways:
    - istio-egressgateway
    - mesh
  http:
    - match:
        - gateways:
            - mesh
          port: 80
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            subset: cnn
            port:
              number: 80
          weight: 100
    - match:
        - gateways:
            - istio-egressgateway
          port: 80
      route:
        - destination:
            host: edition.cnn.com
            port:
              number: 80
          weight: 100
```

```bash
kubectl apply -f egress-gw.yaml -f egress-vs.yaml
```

3. Generá tráfico, y luego confirmá que efectivamente transitó por el egress gateway leyendo los logs del gateway:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sSL -o /dev/null -w "%{http_code}\n" http://edition.cnn.com/politics
kubectl logs -n istio-system -l istio=egressgateway --tail=1
```

```
200
[2026-08-08T12:41:07.512Z] "GET /politics HTTP/1.1" 301 - via_upstream - "-" 0 887 42 41 "10.244.0.14" "curl/8.5.0" "..." "edition.cnn.com" "151.101.65.67:80" outbound|80||edition.cnn.com ...
```

> Una línea de log en el egress gateway prueba que el salto ocurrió. Ninguna línea significa que tu `match` de `VirtualService` sobre `gateways: [mesh]` no capturó el tráfico del sidecar.

**Verificación de comprensión**

- **Q8.** El `VirtualService` lista dos `gateways` (`mesh` e `istio-egressgateway`) y dos bloques de `match` en `http`. Explicá qué enruta cada bloque y por qué *ambos* son necesarios para un único flujo lógico.
- **Q9.** La palabra clave reservada del gateway `mesh` aparece en el primer `match`. ¿Qué representa `mesh`, y qué le pasaría al salto sidecar→egress si lo quitaras de la lista de `gateways`?
- **Q10.** El egress gateway mejora el control, pero un pod todavía podría hacer `curl` a CNN directamente y saltarse el gateway. ¿Qué único cambio (cubierto antes) hace que el egress gateway sea *obligatorio* en lugar de opcional?

---

## Exercise 5 — Join a non-Kubernetes workload with `WorkloadEntry` / `WorkloadGroup`

La dirección inversa: traer un workload externo (una VM, un host bare-metal) *hacia dentro* de la malla para que los pods in-mesh lo direccionen como a cualquier Service, con identidad mTLS y telemetría. `WorkloadEntry` declara una instancia; `WorkloadGroup` es el template que auto-registra muchas.

1. Creá un namespace y una service account para la identidad de la VM:

```bash
kubectl create namespace vm-ns
kubectl create serviceaccount vm-sa -n vm-ns
```

2. Declará una única instancia externa con un `WorkloadEntry`:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: vmapp-1
  namespace: vm-ns
spec:
  address: 10.10.0.42
  labels:
    app: vmapp
    class: vm
  serviceAccount: vm-sa
  network: vm-network
```

3. Poné al frente del workload un `ServiceEntry` cuyo `workloadSelector` coincida con las labels del entry, exponiéndolo como un servicio interno de la malla:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: vmapp-svc
  namespace: vm-ns
spec:
  hosts:
    - vmapp.vm-ns.svc.cluster.local
  location: MESH_INTERNAL
  ports:
    - number: 80
      name: http
      protocol: HTTP
      targetPort: 8080
  resolution: STATIC
  workloadSelector:
    labels:
      app: vmapp
```

```bash
kubectl apply -f vm-workloadentry.yaml -f vm-serviceentry.yaml
```

4. Desde un pod in-mesh, llamá al host respaldado por la VM como si fuera un servicio normal:

```bash
kubectl exec "$SOURCE_POD" -c curl -- curl -sS -o /dev/null -w "%{http_code}\n" http://vmapp.vm-ns.svc.cluster.local
```

```
200
```

5. Para flotas, generá el bundle de configuración a partir de un `WorkloadGroup` en lugar de escribir cada entry a mano:

```yaml
apiVersion: networking.istio.io/v1
kind: WorkloadGroup
metadata:
  name: vmapp
  namespace: vm-ns
spec:
  metadata:
    labels:
      app: vmapp
      class: vm
  template:
    ports:
      http: 8080
    serviceAccount: vm-sa
    network: vm-network
  probe:
    httpGet:
      path: /ready
      port: 8080
```

```bash
kubectl apply -f vm-workloadgroup.yaml
istioctl x workload entry configure \
  -f vm-workloadgroup.yaml \
  -o /tmp/vm-files --autoregister
ls /tmp/vm-files
```

```
cluster.env  hosts  istio-token  mesh.yaml  root-cert.pem
```

> Estos archivos se copian a la VM; la VM ejecuta el sidecar de Istio, presenta `istio-token` para su identidad `vm-sa` y — gracias a `--autoregister` — se *crea automáticamente* un `WorkloadEntry` al conectarse y se elimina cuando la VM se desconecta. `class: vm` en `spec.metadata.labels` es heredado por cada instancia auto-registrada.

**Verificación de comprensión**

- **Q11.** El `ServiceEntry` de la VM usa `location: MESH_INTERNAL` y `resolution: STATIC`, mientras que el de httpbin en el Ejercicio 1 usaba `MESH_EXTERNAL` y `DNS`. Explicá cada diferencia y su consecuencia para mTLS.
- **Q12.** ¿Cómo conecta el `workloadSelector` del `ServiceEntry` con el `WorkloadEntry`? ¿Qué los une, y qué causaría una label suelta o mal emparejada?
- **Q13.** Contrastá `WorkloadEntry` y `WorkloadGroup`. Cuando ejecutás `istioctl x workload entry configure ... --autoregister`, ¿cuál objeto es el template y cuál el artefacto en runtime, y quién crea este último?
- **Q14.** La VM presenta `istio-token` para obtener su identidad. ¿La identidad de quién asume, y en qué parte de los manifests se decidió eso?

---

## Answers

<details>
<summary>Show answers</summary>

**Q1.** El default de `meshConfig.outboundTrafficPolicy.mode` es `ALLOW_ANY`. Bajo él, el tráfico a hosts desconocidos es manejado por el `PassthroughCluster` de Envoy, que reenvía al destino original sin una entrada en el registry. Cambiarlo a `REGISTRY_ONLY` (Ejercicio 2) hace que esa misma solicitud falle — solo los hosts conocidos por el registry siguen siendo alcanzables.

**Q2.** `location: MESH_EXTERNAL` marca el host como *fuera* de la malla: Istio no intentará mTLS hacia él y lo trata como un cliente externo plano desde el punto de vista de las políticas. `resolution: DNS` le indica al sidecar que resuelva él mismo la(s) IP(s) del host vía DNS en el momento de la solicitud (Envoy `STRICT_DNS`), en lugar de recibir IPs estáticas. Juntos significan "host externo, descubierto por DNS".

**Q3.** Registrar el host lo promueve de tráfico de pass-through opaco a un destino modelado. Dos ganancias concretas: (1) la telemetría de Istio ahora atribuye métricas/traces a `httpbin.org` en lugar de agruparlo dentro de `PassthroughCluster`; (2) podés adjuntar políticas de `VirtualService`/`DestinationRule` — timeouts, reintentos, circuit breaking, originación de TLS, routing por egress-gateway — ninguna de las cuales aplica al tráfico de pass-through. También es el prerrequisito para `REGISTRY_ONLY`.

**Q4.** Bajo `REGISTRY_ONLY`, una solicitud a un host no registrado no tiene un cluster de Envoy que coincida, así que el listener la enruta al `BlackHoleCluster` incorporado, que inmediatamente resetea/deniega la conexión (curl exit 56, HTTP `000`). Esto es lo opuesto a `ALLOW_ANY`, donde la misma solicitud golpearía al `PassthroughCluster` y sería reenviada de forma transparente a su destino original.

**Q5.** Se aplica en L7/L4 por el *sidecar Envoy* configurado desde el registry — no por un firewall de red. Así que solo gobierna los workloads que realmente tienen un sidecar y cuyo tráfico es capturado por la redirección iptables/CNI de Istio. Un pod sin inyección (o uno que escapa a la redirección) no está sujeto a él en absoluto; para un perímetro real todavía necesitás `NetworkPolicy`/firewall/egress-gateway-más-controles-de-red. `REGISTRY_ONLY` es una allow-list de malla a nivel de aplicación, no un sustituto de la seguridad de red.

**Q6.** La app abre HTTP plano hacia `edition.cnn.com:80`. El `ServiceEntry` mapea el `targetPort` de ese puerto a `443`, así que Envoy en realidad marca el upstream en 443. El `tls.mode: SIMPLE` (con `sni`) del `DestinationRule` luego hace que Envoy origine un handshake TLS unidireccional hacia CNN en esa conexión. Efecto neto: HTTP entrando desde la app, HTTPS saliendo hacia internet — el sidecar realizó el upgrade de TLS, la app quedó ajena a TLS. `SIMPLE` = TLS con autenticación de servidor (el cliente valida el certificado del servidor); `targetPort: 443` = a qué puerto del upstream conectarse realmente.

**Q7.** Usá `MUTUAL` cuando el servicio externo requiere autenticación por certificado de cliente (mTLS hacia una API de un partner, por ejemplo). Eso requiere suministrar las credenciales de cliente al `DestinationRule` — `clientCertificate`, `privateKey` y `caCertificates` (rutas de archivo montadas en el proxy, o un `credentialName` que referencie un secret de Kubernetes). `SIMPLE` no necesita ninguna de estas porque solo se autentica el servidor.

**Q8.** Los dos bloques son los dos saltos de un mismo flujo. El Bloque 1 coincide con `gateways: [mesh]` (tráfico desde los sidecars de las aplicaciones) en el puerto 80 y lo enruta al subset `cnn` del egress gateway. El Bloque 2 coincide con `gateways: [istio-egressgateway]` (tráfico *que llega a* el egress gateway) en el puerto 80 y lo enruta hacia afuera a `edition.cnn.com`. Ambos son necesarios porque el `VirtualService` debe describir sidecar→gateway *y* gateway→internet; omitir cualquiera rompe ese tramo.

**Q9.** `mesh` es la palabra clave reservada para todos los sidecars de la malla (el Envoy de cada workload inyectado). Es la forma en que un `VirtualService` apunta al tráfico este-oeste/egress que se origina desde los sidecars de las aplicaciones en lugar de desde un gateway con nombre. Quitalo y el Bloque 1 ya no coincide con el tráfico del sidecar, así que los pods siguen yendo *directamente* a CNN — el egress gateway se saltea por completo y su log queda vacío.

**Q10.** Poné `outboundTrafficPolicy.mode: REGISTRY_ONLY` (Ejercicio 2). Con el egress directo bloqueado por el registry, el único camino permitido hacia CNN es el que el `VirtualService` define *a través* del egress gateway, haciendo que el gateway sea obligatorio. (Cinturón y tiradores en producción: aplicá también a nivel de red para que los nodos solo puedan alcanzar internet desde las IPs de egress del egress gateway.)

**Q11.** `MESH_INTERNAL` declara al workload como parte de la malla, así que Istio emite/espera una identidad SPIFFE y puede hacer mTLS hacia él — la VM es un peer, no un endpoint foráneo (contrastá con `MESH_EXTERNAL`, donde no se asume ninguna identidad mTLS). `resolution: STATIC` significa que los endpoints son las direcciones explícitas suministradas por los objetos `WorkloadEntry` que coincidan, no resueltas por DNS — apropiado porque la identidad/labels de una VM, no una consulta de hostname, definen el backend. `DNS` haría que Envoy resuelva un nombre en lugar de usar las direcciones declaradas en `WorkloadEntry`.

**Q12.** Las `ServiceEntry.spec.workloadSelector.labels` (`app: vmapp`) se comparan contra las labels de los objetos `WorkloadEntry` en el mismo namespace. Cualquier `WorkloadEntry` que lleve `app: vmapp` se convierte en un endpoint backend de ese `ServiceEntry`. Una label mal emparejada o faltante significa que el `WorkloadEntry` nunca es seleccionado, así que el servicio tiene cero endpoints y las llamadas fallan (no hay upstream saludable) — aunque ambos objetos existan.

**Q13.** `WorkloadEntry` es el *artefacto en runtime*: una fila en el registry que representa una única instancia externa (dirección, labels, identidad). `WorkloadGroup` es el *template* que describe cómo lucen las instancias de un grupo lógico (labels, puertos, service account, readiness probe). `istioctl x workload entry configure --autoregister` inicializa una VM contra el grupo; cuando esa VM se conecta a istiod, auto-*crea* su propio `WorkloadEntry` (y lo elimina al desconectarse). Así que el grupo lo authorás vos; el entry lo crea el control plane en el momento de la conexión.

**Q14.** Asume la identidad de la ServiceAccount `vm-sa` en `vm-ns` — es decir, su SPIFFE ID es `spiffe://<trust-domain>/ns/vm-ns/sa/vm-sa`. Eso se decidió con `serviceAccount: vm-sa` en el `WorkloadEntry`/`WorkloadGroup` (y la SA creada en el paso 1). El `istio-token` es un token acotado (bound) para esa SA, que el sidecar de la VM presenta a istiod para obtener los certificados del workload.

</details>

> **Cleanup:** `kubectl delete serviceentry,destinationrule,virtualservice,gateway,workloadentry,workloadgroup --all -A` y, si lo cambiaste, revertí `outboundTrafficPolicy` a `ALLOW_ANY`.
>
> **References:** [ServiceEntry](https://istio.io/latest/docs/reference/config/networking/service-entry/) · [Egress control](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/) · [Egress TLS origination](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/) · [Egress gateway](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/) · [WorkloadEntry](https://istio.io/latest/docs/reference/config/networking/workload-entry/) · [WorkloadGroup](https://istio.io/latest/docs/reference/config/networking/workload-group/) · [Virtual Machine installation](https://istio.io/latest/docs/setup/install/virtual-machine/)