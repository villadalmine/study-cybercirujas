# 5.4 Use the Gateway API to manage Ingress traffic

## Qué es la Gateway API y por qué existe

La **Gateway API** es un conjunto de recursos de Kubernetes (grupo de APIs `gateway.networking.k8s.io`) que reemplaza y extiende el modelo de `Ingress` para exponer tráfico HTTP, HTTPS, TCP, UDP, TLS y gRPC hacia servicios del cluster. No forma parte del *core* de Kubernetes: se instala como un conjunto de **CRDs** y necesita un **controller** (un *implementation*) que las reconcilie — por ejemplo NGINX Gateway Fabric, Envoy Gateway, Istio, Cilium, Kgateway, etc.

Los problemas que resuelve respecto de `Ingress`:

- `Ingress` mezcla en un único objeto la configuración de infraestructura (load balancer), el enrutamiento y las políticas, obligando a usar *annotations* propietarias y no portables entre controllers.
- `Ingress` solo modela HTTP/HTTPS. No hay soporte nativo para TCP, UDP, TLS passthrough o gRPC.
- No hay un modelo de roles claro entre quien administra la infraestructura, quien administra el cluster y quien despliega aplicaciones.

La Gateway API separa estas responsabilidades en recursos distintos, es **role-oriented**, **portable** (mismo YAML funciona con distintos controllers) y **type-safe/extensible** por protocolo.

## Modelo de roles

| Rol | Recurso que gestiona | Responsabilidad |
|---|---|---|
| Infrastructure Provider | `GatewayClass` | Define qué controller implementa el balanceo (cloud provider, plataforma) |
| Cluster Operator | `Gateway` | Instancia puntos de entrada (listeners, puertos, TLS) sobre una `GatewayClass` |
| Application Developer | `HTTPRoute` / `GRPCRoute` / `TCPRoute` / `TLSRoute` | Define reglas de enrutamiento hacia sus `Service` |

## Recursos principales

- **GatewayClass** (cluster-scoped): análogo a `IngressClass`. Referencia un `controllerName` que un controller externo reconcilia.
- **Gateway** (namespaced): declara uno o más *listeners* (protocolo, puerto, hostname, TLS). Al crearse, el controller provisiona un load balancer y publica su dirección en `status.addresses`.
- **HTTPRoute**: reglas de enrutamiento HTTP (`matches` por path, header, method, query param) hacia uno o más `backendRefs`, con soporte de `weight` para traffic splitting y `filters` para reescritura de headers/paths, redirects, etc.
- **GRPCRoute**: equivalente para tráfico gRPC (alcanzó GA en la versión v1.1 de la API).
- **TCPRoute / UDPRoute / TLSRoute**: enrutamiento de capa 4 y TLS passthrough (canal *experimental* en la mayoría de las versiones — verificar el release notes de cada implementación).
- **ReferenceGrant** (namespaced): habilita explícitamente referencias cross-namespace (por ejemplo un `HTTPRoute` en el namespace `default` apuntando a un `Service` en otro namespace).

## Instalación de los CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

```
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io created
```

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

```
gatewayclasses.gateway.networking.k8s.io    2026-07-10T10:00:00Z
gateways.gateway.networking.k8s.io          2026-07-10T10:00:00Z
httproutes.gateway.networking.k8s.io        2026-07-10T10:00:00Z
referencegrants.gateway.networking.k8s.io   2026-07-10T10:00:00Z
```

En el examen, el controller (implementation) ya suele venir instalado; lo que se evalúa es la creación y el troubleshooting de `GatewayClass`, `Gateway` y `*Route`.

## Ejemplo: exponer un Service HTTP básico

**GatewayClass** (normalmente ya provista por la implementation):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx-gateway
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller
```

**Gateway**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: default
spec:
  gatewayClassName: nginx-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

```bash
kubectl apply -f gateway.yaml
kubectl get gateway web-gateway
```

```
NAME          CLASS           ADDRESS         PROGRAMMED   AGE
web-gateway   nginx-gateway   10.96.200.15    True         30s
```

**HTTPRoute**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
  namespace: default
spec:
  parentRefs:
    - name: web-gateway
  hostnames:
    - "shop.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend-svc
          port: 80
```

```bash
kubectl get httproute web-route -o wide
```

```
NAME        HOSTNAMES                PARENT REFS   AGE
web-route   ["shop.example.com"]     web-gateway   10s
```

## Ejemplo: path-based routing hacia múltiples backends

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: default
spec:
  parentRefs:
    - name: web-gateway
  hostnames:
    - "shop.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: api-svc
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend-svc
          port: 80
```

## Ejemplo: canary release con traffic splitting por weight

`backendRefs` acepta un campo `weight` — el controller reparte el tráfico proporcionalmente (`weight` es relativo a la suma total de la regla):

```yaml
  rules:
    - backendRefs:
        - name: web-v1
          port: 80
          weight: 90
        - name: web-v2
          port: 80
          weight: 10
```

Con esto, aproximadamente el 10% de las requests que matchean la regla van a `web-v2`, sin necesidad de *annotations* propietarias como se requería con `Ingress`.

## Ejemplo: routing condicional por header

```yaml
  rules:
    - matches:
        - headers:
            - type: Exact
              name: X-Canary
              value: "true"
      backendRefs:
        - name: web-v2
          port: 80
    - backendRefs:
        - name: web-v1
          port: 80
```

## Ejemplo: TLS termination

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: default
spec:
  gatewayClassName: nginx-gateway
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: web-tls-cert
```

El `Secret` referenciado debe existir en el mismo namespace del `Gateway` (o habilitarse cross-namespace vía `ReferenceGrant`) y ser de tipo `kubernetes.io/tls`.

## Cross-namespace routing con ReferenceGrant

Si un `HTTPRoute` en el namespace `default` necesita apuntar a un `Service` en el namespace `backend-ns`, ese `Service` debe estar habilitado explícitamente mediante `ReferenceGrant` en el namespace destino:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-route-to-svc
  namespace: backend-ns
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: default
  to:
    - group: ""
      kind: Service
```

Sin este `ReferenceGrant`, el `HTTPRoute` queda con la condición `ResolvedRefs=False` y el backend no recibe tráfico.

## Troubleshooting: status y conditions

El estado de reconciliación se lee en `status.conditions` de cada recurso, no en logs — es la primera fuente de diagnóstico en el examen.

```bash
kubectl describe gateway web-gateway
```

```
Status:
  Addresses:
    Type:   IPAddress
    Value:  10.96.200.15
  Conditions:
    Type:    Accepted
    Status:  True
    Reason:  Accepted
    Type:    Programmed
    Status:  True
    Reason:  Programmed
```

```bash
kubectl describe httproute web-route
```

```
Status:
  Parents:
    Conditions:
      Type:    Accepted
      Status:  True
      Reason:  Accepted
      Type:    ResolvedRefs
      Status:  False
      Reason:  BackendNotFound
      Message: Service "frontend-svc" not found in namespace "default"
```

Causas típicas de fallas:

- `GatewayClass` sin `Accepted=True`: no hay controller que implemente `controllerName`, o el controller no está corriendo.
- `Gateway` sin `Programmed=True`: el controller no pudo provisionar el load balancer (revisar logs del controller, no de kube-system genérico).
- `HTTPRoute` con `ResolvedRefs=False`: el `Service`/`backendRef` no existe, el puerto no coincide, o falta un `ReferenceGrant` para una referencia cross-namespace.
- `HTTPRoute` con `Accepted=False` y reason `NoMatchingParent`: el `parentRefs` no coincide con ningún listener del `Gateway` (hostname o protocolo distintos).

## Ingress vs Gateway API

| Aspecto | Ingress | Gateway API |
|---|---|---|
| Extensibilidad | *Annotations* propietarias por controller | Campos tipados y portables (`filters`, `weight`, `matches`) |
| Roles | Un solo objeto para todo | Separado en `GatewayClass` / `Gateway` / `*Route` |
| Protocolos | Solo HTTP/HTTPS | HTTP, HTTPS, gRPC, TCP, UDP, TLS passthrough |
| Traffic splitting | Vía anotaciones no estándar | Nativo con `weight` en `backendRefs` |
| Cross-namespace | No modelado explícitamente | `ReferenceGrant` |

Ambas APIs pueden convivir en el mismo cluster; la Gateway API no obsoleta a `Ingress` de forma inmediata pero es el camino recomendado para nuevas implementaciones.

## Referencias

- CNCF, *CKA Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
- Gateway API — documentación oficial: https://gateway-api.sigs.k8s.io/
- Gateway API — API reference (Gateway, GatewayClass, HTTPRoute, GRPCRoute, ReferenceGrant): https://gateway-api.sigs.k8s.io/reference/spec/
- Gateway API — releases e instalación de CRDs: https://github.com/kubernetes-sigs/gateway-api/releases
- Kubernetes docs, *Gateway API*: https://kubernetes.io/docs/concepts/services-networking/gateway/
- Kubernetes docs, *Ingress* (comparación): https://kubernetes.io/docs/concepts/services-networking/ingress/
- Gateway API — guía de TLS: https://gateway-api.sigs.k8s.io/guides/tls/
- Gateway API — guía de traffic splitting: https://gateway-api.sigs.k8s.io/guides/traffic-splitting/