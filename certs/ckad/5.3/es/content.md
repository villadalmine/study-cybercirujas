# 5.3 Use Ingress rules to expose applications

**Examen:** CKAD (versión 1.35) · **Peso:** 5

---

## 1. Qué problema resuelve un Ingress

`Service` de tipo `NodePort` o `LoadBalancer` exponen aplicaciones al exterior, pero con limitaciones prácticas: `NodePort` obliga a usar el rango `30000-32767` y a conocer la IP de algún nodo; `LoadBalancer` necesita **un balanceador externo por Service** (costoso si hay decenas de aplicaciones HTTP) y no entiende de HTTP en absoluto — balancea a nivel de conexión TCP/UDP, sin mirar el contenido.

Un **Ingress** es el objeto de la API (`networking.k8s.io/v1`) que describe reglas de **enrutamiento HTTP/HTTPS** de capa 7: a partir del **host** y/o el **path** de una request entrante, decide a qué Service (y puerto) reenviarla. Con un único punto de entrada (una IP, un LoadBalancer) se puede exponer *n* aplicaciones distintas.

```
Cliente → Ingress Controller (Pod real, LB o NodePort) → reglas del Ingress → Service → Pod
```

Punto crítico y frecuente trampa de examen: **el objeto `Ingress` por sí solo no hace nada**. Es solo la especificación declarativa; hace falta un **Ingress Controller** corriendo en el clúster (nginx-ingress, Traefik, HAProxy, Contour, Cilium, etc.) que observa esos objetos y programa el enrutamiento real. Sin controller, `kubectl apply -f ingress.yaml` funciona (el objeto se crea en el API server) pero el tráfico nunca llega a destino.

---

## 2. IngressClass: qué controller atiende cada Ingress

Un clúster puede tener **varios controllers** instalados a la vez (por ejemplo nginx para tráfico público y otro para tráfico interno). `IngressClass` es el objeto que identifica a cada controller y permite indicarle a un Ingress cuál debe atenderlo.

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
```

```bash
$ kubectl get ingressclass
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       10d
```

El Ingress referencia la clase con `spec.ingressClassName`:

```yaml
spec:
  ingressClassName: nginx
```

Si se omite `ingressClassName` y existe una `IngressClass` marcada como default (annotation `ingressclass.kubernetes.io/is-default-class: "true"`), esa se usa automáticamente. Si no hay ninguna default y se omite el campo, **ningún controller** toma el Ingress y queda sin `ADDRESS` asignada indefinidamente — otra causa común de "el Ingress no anda".

---

## 3. Anatomía de un Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  namespace: prod
spec:
  ingressClassName: nginx
  rules:
  - host: shop.ejemplo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
```

- **`rules`**: lista de reglas; cada una asocia un `host` opcional con uno o más `paths`.
- **`http.paths[].path`**: el prefijo o patrón de URL a matchear.
- **`pathType`**: obligatorio desde `networking.k8s.io/v1` (a diferencia de `v1beta1`, donde era opcional). Valores: `Exact`, `Prefix`, `ImplementationSpecific`.
- **`backend.service.name` / `backend.service.port.number`** (o `.name` si el puerto del Service tiene nombre): el Service **debe existir en el mismo Namespace** que el Ingress. Un Ingress no puede apuntar a un Service de otro Namespace.

```bash
$ kubectl apply -f web-ingress.yaml
ingress.networking.k8s.io/web-ingress created

$ kubectl get ingress -n prod
NAME          CLASS   HOSTS              ADDRESS         PORTS   AGE
web-ingress   nginx   shop.ejemplo.com   203.0.113.10    80      30s
```

`ADDRESS` la completa el controller una vez que programó las reglas; hasta entonces queda vacía. Que aparezca una IP en `ADDRESS` **no** garantiza que el backend responda — solo confirma que el controller vio el objeto.

---

## 4. `pathType`: Exact, Prefix, ImplementationSpecific

| `pathType` | Comportamiento | Ejemplo |
|---|---|---|
| `Exact` | Matchea la URL **exacta**, sensible a mayúsculas, sin barra final implícita | `path: /foo` matchea `/foo` pero no `/foo/` ni `/foo/bar` |
| `Prefix` | Matchea por **segmentos de path** separados por `/`; `/foo` matchea `/foo`, `/foo/`, `/foo/bar`, pero no `/foobar` | `path: /foo` matchea `/foo/bar/baz` |
| `ImplementationSpecific` | El matching depende del controller; puede admitir wildcards o regex propios (por ejemplo nginx con la annotation `nginx.ingress.kubernetes.io/rewrite-target`) | Comportamiento no portable entre controllers |

Trampa clásica de examen: asumir que `Prefix` funciona como comparación de string. `/foo` con `Prefix` **no** matchea `/foobar` (porque el corte es por segmento `/`), aunque "foo" sea substring literal de "foobar".

```yaml
paths:
- path: /api
  pathType: Prefix
  backend:
    service:
      name: api-svc
      port:
        number: 8080
```

```bash
$ curl http://shop.ejemplo.com/api/users     # matchea (Prefix)
$ curl http://shop.ejemplo.com/apiv2/users   # NO matchea: "apiv2" no es el segmento "api"
```

Cuando **varios paths matchean** la misma request, el controller elige el más específico (el `path` más largo tiene prioridad), no el orden de declaración en el YAML.

---

## 5. Ruteo por path (fan-out) en un mismo host

Varias aplicaciones detrás de un único host, separadas por prefijo de URL:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fanout-ingress
  namespace: prod
spec:
  ingressClassName: nginx
  rules:
  - host: app.ejemplo.com
    http:
      paths:
      - path: /web
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 8080
```

```bash
$ kubectl describe ingress fanout-ingress -n prod
Rules:
  Host              Path  Backends
  ----              ----  --------
  app.ejemplo.com
                     /web   web:80 (10.244.1.5:80,10.244.2.9:80)
                     /api   api:8080 (10.244.1.6:8080)
```

`kubectl describe ingress` muestra, para cada regla, el Service resuelto **y sus Endpoints reales** — es el comando más rápido para confirmar que el Ingress efectivamente encontró Pods sanos detrás del Service.

---

## 6. Ruteo por host (name-based virtual hosting)

Varias aplicaciones distintas, cada una en su propio dominio o subdominio, compartiendo el mismo controller/IP pública:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: multi-host-ingress
  namespace: prod
spec:
  ingressClassName: nginx
  rules:
  - host: shop.ejemplo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop
            port:
              number: 80
  - host: blog.ejemplo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: blog
            port:
              number: 80
```

El controller decide qué regla aplicar mirando el header HTTP `Host` (o la SNI en TLS) de la request entrante, no la IP de destino: ambos hosts pueden resolver a la misma `ADDRESS`.

```bash
$ curl -H "Host: shop.ejemplo.com" http://203.0.113.10/
<shop homepage>
$ curl -H "Host: blog.ejemplo.com" http://203.0.113.10/
<blog homepage>
```

---

## 7. `defaultBackend`: qué pasa si nada matchea

```yaml
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: default-http-backend
      port:
        number: 80
  rules:
  - host: shop.ejemplo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop
            port:
              number: 80
```

Si una request no matchea ningún `host`/`path` de `rules`, se reenvía a `defaultBackend`. Sin `defaultBackend` definido, el comportamiento ante un miss depende del controller: la mayoría devuelve un **404** propio del controller (no de ninguna aplicación del clúster).

---

## 8. TLS: terminación en el Ingress

El Ingress puede terminar TLS antes de reenviar tráfico plano a los Services internos:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-ingress
  namespace: prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - shop.ejemplo.com
    secretName: shop-tls
  rules:
  - host: shop.ejemplo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop
            port:
              number: 80
```

- **`tls[].hosts`**: hosts para los que aplica ese certificado (debe coincidir con el `host` de alguna regla).
- **`tls[].secretName`**: nombre de un `Secret` tipo `kubernetes.io/tls` (claves `tls.crt` y `tls.key`) en el **mismo Namespace** que el Ingress.

```bash
$ kubectl create secret tls shop-tls \
    --cert=shop.crt --key=shop.key -n prod
secret/shop-tls created

$ kubectl get secret shop-tls -n prod -o jsonpath='{.type}'
kubernetes.io/tls
```

Trampa de examen: si el `Secret` no existe, no tiene el `type` correcto, o vive en otro Namespace, el controller no puede servir TLS para ese host — algunos controllers caen a un certificado *default* autofirmado, otros simplemente rechazan la conexión TLS.

---

## 9. Annotations: dónde vive lo específico de cada controller

La especificación `networking.k8s.io/v1` cubre solo el comportamiento **común** (rules, paths, tls, defaultBackend). Funcionalidad extra — rewrite de URL, redirect HTTP→HTTPS forzado, rate limiting, tamaño máximo de body, autenticación básica, *session affinity*, etc. — se controla vía **annotations en `metadata.annotations`**, con prefijo propio de cada controller. No son portables entre controllers.

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: shop.ejemplo.com
    http:
      paths:
      - path: /old(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: shop
            port:
              number: 80
```

Para el examen alcanza con reconocer el **patrón** (annotation con prefijo del controller + `pathType: ImplementationSpecific` cuando hay regex/captura), no con memorizar cada annotation de cada controller.

---

## 10. Troubleshooting paso a paso

### Paso 1 — ¿Existe el Ingress y tiene `ADDRESS`?

```bash
$ kubectl get ingress web-ingress -n prod
NAME          CLASS   HOSTS              ADDRESS   PORTS   AGE
web-ingress   nginx   shop.ejemplo.com             80      2m
```

`ADDRESS` vacía después de varios minutos casi siempre significa que **ningún controller** está atendiendo esa `IngressClass` (controller caído, `ingressClassName` mal escrito, o ninguna clase default y el campo quedó vacío).

```bash
$ kubectl get pods -n ingress-nginx
NAME                                       READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-7d8f9c-abc12      1/1     Running   0          10d
```

### Paso 2 — `describe ingress`: reglas, backends y Endpoints

```bash
$ kubectl describe ingress web-ingress -n prod
Rules:
  Host              Path  Backends
  ----              ----  --------
  shop.ejemplo.com
                     /   frontend:80 (<error: endpoints "frontend" not found>)
```

Un backend marcado como error o sin IPs es prácticamente siempre un **Service mal referenciado** (nombre/puerto equivocado) o un **Service sin Endpoints** (mismo troubleshooting que en 5.2: selector desalineado o Pods no Ready).

### Paso 3 — Confirmar que el Service detrás funciona de forma aislada

```bash
$ kubectl port-forward svc/frontend 8080:80 -n prod
$ curl localhost:8080/
```

Si esto falla, el problema está en el Service/Pod, no en el Ingress — conviene resolverlo primero (ver 5.2) antes de seguir investigando la capa de Ingress.

### Paso 4 — `host` header incorrecto o ausente

```bash
$ curl http://203.0.113.10/            # sin Host header correcto
404 Not Found: nginx

$ curl -H "Host: shop.ejemplo.com" http://203.0.113.10/
<home page>
```

Si el Ingress define `host: shop.ejemplo.com` y la request llega sin ese header (por ejemplo `curl` directo a la IP, sin DNS ni `-H "Host: ..."`), no matchea ninguna regla y cae al comportamiento por defecto del controller (o a `defaultBackend` si existe).

### Paso 5 — Revisar logs del Ingress Controller

```bash
$ kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=20
...
"GET /api/users HTTP/1.1" 502 ...
```

Un `502`/`503` en los logs del controller (a diferencia de un 404 de la app) suele indicar que el controller sí matcheó la regla pero **no pudo conectar al backend** (Endpoints vacíos, `targetPort` mal configurado en el Service, o Pod caído).

### Paso 6 — `pathType` o precedencia de paths mal entendida

```bash
$ kubectl get ingress web-ingress -n prod -o yaml | grep -A2 pathType
```

Confirmar que `pathType` es el esperado (`Prefix` vs `Exact`) y que no hay otro path más específico "robándose" el tráfico antes de asumir que el Ingress está mal configurado.

### Paso 7 — TLS: certificado o Secret

```bash
$ curl -v https://shop.ejemplo.com/ 2>&1 | grep -i "SSL certificate"
$ kubectl get secret shop-tls -n prod
Error from server (NotFound): secrets "shop-tls" not found
```

`Secret` inexistente, con `type` incorrecto, o en otro Namespace → el controller no puede terminar TLS para ese host correctamente.

---

## 11. Errores comunes (frecuentes en el examen)

1. **Olvidar que un Ingress necesita un controller instalado**: el objeto se crea sin error aunque no haya ningún controller corriendo; no hay tráfico real hasta que uno lo atienda.
2. **`ingressClassName` mal escrito o ausente sin clase default**: el Ingress queda sin `ADDRESS` para siempre — no es un problema del backend.
3. **Apuntar a un Service en otro Namespace**: no es válido; el `backend.service.name` se resuelve siempre en el Namespace del Ingress.
4. **Omitir `pathType`**: obligatorio en `networking.k8s.io/v1`; sin él, `kubectl apply` rechaza el manifiesto.
5. **Confundir `Prefix` con matching de substring**: `/foo` con `Prefix` no matchea `/foobar`, matchea por segmento de path.
6. **Asumir que el `path` más arriba en el YAML gana**: el controller prioriza el path **más específico**, no el orden de declaración.
7. **Olvidar el header `Host`** al probar con `curl` directo a una IP: sin el header (o sin DNS resuelto), la regla por `host` no matchea.
8. **Poner annotations de un controller distinto al que realmente atiende el Ingress** (por ejemplo annotations de nginx en un clúster con Traefik): se ignoran silenciosamente, no dan error.
9. **Secret de TLS con `type` incorrecto o en el Namespace equivocado**: el Ingress lo referencia por nombre pero el controller no puede usarlo para ese host.
10. **Diagnosticar el Ingress antes que el Service**: si el Service detrás no tiene Endpoints sanos, ningún ajuste al Ingress lo va a arreglar — conviene aislar con `port-forward` primero.

---

## Resumen para el examen

- Un **Ingress** define reglas HTTP/HTTPS de capa 7 (`host` + `path` → Service:puerto); necesita un **Ingress Controller** corriendo para tener efecto real — el objeto solo declara intención.
- **`IngressClass`** identifica qué controller atiende un Ingress (`spec.ingressClassName`); sin clase válida ni default, el Ingress no recibe `ADDRESS`.
- **`pathType`** es obligatorio: `Exact` (match exacto), `Prefix` (match por segmento de path), `ImplementationSpecific` (depende del controller, típico con regex/annotations).
- El path más **específico** gana cuando varios matchean, no el orden del YAML.
- **`defaultBackend`** atiende requests que no matchean ninguna regla; sin él, el controller responde con su propio 404.
- **TLS** se termina en el Ingress vía `spec.tls[].secretName`, apuntando a un `Secret` tipo `kubernetes.io/tls` en el mismo Namespace.
- Las **annotations** cubren todo lo específico del controller (rewrite, redirect, rate limit); no son portables entre nginx/Traefik/etc.
- El backend del Ingress **debe ser un Service en el mismo Namespace**; el Ingress nunca apunta directo a un Pod.
- Troubleshooting en orden: `get ingress` (¿tiene `ADDRESS`?) → `describe ingress` (reglas + Endpoints resueltos) → aislar el Service con `port-forward` → header `Host` correcto en las pruebas → logs del controller → `pathType`/precedencia → Secret de TLS.
- Un `404` en los logs del controller suele ser regla no matcheada (host/path); un `502`/`503` suele ser backend sin Endpoints sanos.

---

## Referencias

- Kubernetes — Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Kubernetes — Ingress Controllers: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Kubernetes — IngressClass: https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-class
- Kubernetes API Reference — Ingress v1: https://kubernetes.io/docs/reference/kubernetes-api/service-resources/ingress-v1/
- ingress-nginx — Annotations: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
