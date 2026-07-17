# 5.5 — Ingress controllers e Ingress resources

## 1. ¿Qué problema resuelve Ingress?

Cuando exponés una aplicación con un `Service` de tipo `NodePort` o `LoadBalancer`, cada servicio necesita su propio puerto o su propio balanceador externo. Esto se vuelve costoso e inmanejable cuando tenés decenas de aplicaciones HTTP/HTTPS corriendo en el cluster.

**Ingress** es un objeto de la API de Kubernetes que define reglas de enrutamiento HTTP/HTTPS hacia `Services` internos, basándose en:

- **host** (nombre de dominio, ej. `app.example.com`)
- **path** (ruta URL, ej. `/api`, `/web`)

Con un único punto de entrada (una IP o un `LoadBalancer`), podés enrutar tráfico a múltiples servicios según el host o el path solicitado — similar a un reverse proxy (nginx, Traefik, HAProxy) pero configurado de forma declarativa como un recurso más de Kubernetes.

Importante: **Ingress no reemplaza al Service**. El recurso `Ingress` define las reglas, pero es el **Ingress Controller** el que efectivamente implementa esas reglas y balancea tráfico hacia los `Services` (que en general son de tipo `ClusterIP`).

## 2. Ingress Controller

Kubernetes **no incluye un Ingress Controller por defecto**. El recurso `Ingress` es solo una API; sin un controller corriendo en el cluster que la observe (watch) y actúe, el objeto `Ingress` no tiene ningún efecto.

Controllers habituales:

- **ingress-nginx** (comunidad Kubernetes, el más usado en el examen y en la práctica)
- **NGINX Inc. Ingress Controller** (versión distinta, cuidado con no confundir)
- Traefik
- HAProxy Ingress
- Istio Gateway / Contour / Kong, etc. (basados en Gateway API o Ingress)

El controller corre normalmente como un `Deployment` en el namespace `ingress-nginx` (o similar), expuesto a su vez mediante un `Service` de tipo `LoadBalancer` o `NodePort`, y es el punto de entrada real del tráfico externo.

```bash
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

Salida típica:

```
NAME                                       READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-7d9f8c9c5-abcde   1/1     Running   0          3d

NAME                                 TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)
ingress-nginx-controller             LoadBalancer   10.96.10.10    203.0.113.10    80:31234/TCP,443:31235/TCP
```

## 3. IngressClass

Desde `networking.k8s.io/v1`, cada `Ingress` debe indicar qué controller debe atenderlo mediante el campo `spec.ingressClassName`, que referencia un recurso `IngressClass`.

```bash
kubectl get ingressclass
```

```
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       3d
```

Si hay una `IngressClass` marcada como default (anotación `ingressclass.kubernetes.io/is-default-class: "true"`), un `Ingress` sin `ingressClassName` la usa automáticamente.

## 4. Anatomía de un recurso Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

Campos clave:

- **`rules`**: lista de reglas `host` + `http.paths`.
- **`pathType`**: define cómo se matchea el path.
  - `Exact`: coincidencia exacta (case sensitive).
  - `Prefix`: coincide por segmentos de path (`/foo` matchea `/foo`, `/foo/`, `/foo/bar`, pero no `/foobar`).
  - `ImplementationSpecific`: la interpretación queda a cargo del controller.
- **`backend.service`**: `Service` + puerto destino (por nombre `port.name` o número `port.number`).
- **`defaultBackend`**: backend usado cuando ninguna regla matchea (fallback / página 404 personalizada).
- **`annotations`**: gran parte del comportamiento avanzado (rewrite, rate limiting, autenticación, CORS, tamaño máximo de body, etc.) se configura vía anotaciones **específicas del controller**, no de la API genérica de Ingress. Esto es una fuente común de confusión: dos controllers distintos usan anotaciones distintas para el mismo comportamiento.

## 5. Enrutamiento por path (fan-out) en un mismo host

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fanout-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 8080
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-service
            port:
              number: 80
```

Acá `shop.example.com/api/*` va al `Service` `api-service`, y cualquier otro path va a `frontend-service`.

## 6. Enrutamiento por host (name-based virtual hosting)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-host-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: blog.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: blog-service
            port:
              number: 80
  - host: shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop-service
            port:
              number: 80
```

Un mismo Ingress Controller (misma IP externa) enruta según el header `Host` de la petición HTTP hacia dos `Services` distintos.

## 7. TLS/HTTPS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-ingress
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    secretName: app-tls-secret
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

El `Secret` referenciado debe ser de tipo `kubernetes.io/tls`, con las claves `tls.crt` y `tls.key`:

```bash
kubectl create secret tls app-tls-secret --cert=tls.crt --key=tls.key
```

## 8. Creación imperativa

`kubectl` permite generar un Ingress básico sin escribir YAML:

```bash
kubectl create ingress simple-ingress \
  --class=nginx \
  --rule="app.example.com/*=web-service:80"
```

Útil para el examen cuando el tiempo apremia; después se puede editar/exportar con `kubectl get ingress simple-ingress -o yaml`.

## 9. Verificación y troubleshooting

```bash
kubectl get ingress
```

```
NAME           CLASS   HOSTS               ADDRESS         PORTS   AGE
web-ingress    nginx   app.example.com     203.0.113.10    80      2d
```

```bash
kubectl describe ingress web-ingress
```

Muestra las reglas, los backends resueltos y, muy importante, la sección `Events`, donde el controller reporta errores de sincronización (por ejemplo, un `Service` inexistente o un puerto mal referenciado).

Puntos comunes de fallo en el examen:

1. **`ADDRESS` vacío**: el Ingress Controller no está corriendo, o el `Ingress` no tiene `ingressClassName` correcto y no hay clase default.
2. **404 del controller**: el `Service` de backend no existe, el puerto no coincide, o los `selector` del `Service` no matchean ningún `Pod` (`kubectl get endpoints <service>` debe mostrar IPs).
3. **`pathType` mal elegido**: `Exact` en vez de `Prefix` hace que sub-rutas no matcheen.
4. Namespace: el `Ingress` y el `Service` que referencia deben estar en el **mismo namespace**.
5. DNS/hosts: en un cluster de práctica sin DNS real, hay que resolver el host manualmente (`/etc/hosts` o `curl --resolve host:80:<IP>`).

```bash
curl --resolve app.example.com:80:203.0.113.10 http://app.example.com/
```

## 10. Ingress vs Gateway API

Vale la pena saber que la comunidad de Kubernetes está migrando hacia la **Gateway API** (`Gateway`, `HTTPRoute`, etc.) como sucesora más expresiva de `Ingress`, pero para CKA v1.35 el foco sigue siendo el recurso `Ingress` clásico y su controller.

## Referencias

- Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Ingress Controllers: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- IngressClass: https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-class
- ingress-nginx (proyecto de referencia): https://kubernetes.github.io/ingress-nginx/
- kubectl create ingress: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-ingress
- Gateway API (contexto/futuro): https://kubernetes.io/docs/concepts/services-networking/gateway/
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf