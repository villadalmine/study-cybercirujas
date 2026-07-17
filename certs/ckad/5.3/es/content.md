# 5.3 Use Ingress rules to expose applications

## ¿Qué problema resuelve Ingress?

Cuando exponés una aplicación con un `Service` de tipo `NodePort` o `LoadBalancer`, cada servicio necesita su propio puerto o su propio balanceador externo. Eso escala mal: si tenés diez aplicaciones HTTP en el cluster, no querés diez `LoadBalancer` (cada uno con su costo y su IP pública) ni diez puertos random en cada nodo.

**Ingress** es un objeto de la API de Kubernetes (`networking.k8s.io/v1`) que describe reglas de **routing HTTP/HTTPS** basadas en `host` y `path` hacia distintos `Service` internos (tipo `ClusterIP` normalmente). Un único punto de entrada (una IP, un `LoadBalancer`) puede así enrutar tráfico a muchas aplicaciones distintas.

Ingress por sí solo **no hace nada**: es solo la declaración de las reglas. Necesitás un **Ingress Controller** corriendo en el cluster (nginx-ingress, Traefik, HAProxy, Contour, etc.) que observa los objetos `Ingress` y configura el proxy real. Sin controller, el recurso `Ingress` queda "sin efecto", aunque se cree correctamente en la API.

## Componentes involucrados

| Objeto | Rol |
|---|---|
| `Ingress` | Declara las reglas de routing (qué host/path va a qué Service) |
| `IngressClass` | Indica qué Ingress Controller debe procesar ese Ingress |
| Ingress Controller | Pod(s) que leen los Ingress y programan el proxy/load balancer real |
| `Service` (ClusterIP) | Backend al que el Ingress Controller reenvía el tráfico |

En el examen CKAD normalmente el controller **ya está instalado** en el cluster (por ejemplo `ingress-nginx`); tu trabajo es crear/editar el objeto `Ingress` correctamente, no instalar el controller.

## Anatomía de un manifiesto Ingress

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
            name: web-svc
            port:
              number: 80
```

Puntos clave:

- **`spec.ingressClassName`**: reemplaza a la vieja anotación `kubernetes.io/ingress.class`. Debe coincidir con el `metadata.name` de un objeto `IngressClass` existente. Si lo omitís y hay una `IngressClass` marcada como default (anotación `ingressclass.kubernetes.io/is-default-class: "true"`), se usa esa.
- **`rules[].host`**: routing por nombre de dominio (virtual hosting). Si se omite, la regla aplica a cualquier host que llegue a la IP del Ingress Controller.
- **`pathType`**: define cómo se compara `path` contra la URL entrante.
  - `Exact`: coincide exactamente (case sensitive), sin componentes extra.
  - `Prefix`: coincide por segmentos de path (`/foo` matchea `/foo` y `/foo/bar`, pero no `/foobar`).
  - `ImplementationSpecific`: la interpretación queda a cargo del controller.
- **`backend.service.name` / `port`**: el `Service` interno de destino. El puerto puede indicarse por `number` o por `name` (si el `Service` define `ports[].name`).

## Ver la IngressClass disponible

```console
$ kubectl get ingressclass
NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       10d
```

## Crear un Ingress con `kubectl create ingress`

Para el examen, es mucho más rápido generar el YAML con el comando imperativo y ajustarlo, en vez de escribirlo a mano:

```console
$ kubectl create ingress web-ingress \
    --rule="app.example.com/*=web-svc:80" \
    --class=nginx \
    --dry-run=client -o yaml > ingress.yaml
```

Esto genera un manifiesto equivalente al de arriba. `--rule` acepta el formato `host/path=service:port[,tls=secret]`.

## Ejemplo: fan-out por path (una sola app, varios servicios)

Enrutar `/api` y `/` de un mismo host a servicios distintos:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
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
            name: api-svc
            port:
              number: 8080
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-svc
            port:
              number: 80
```

`/api/users` va a `api-svc`; cualquier otra ruta cae en `frontend-svc`. El orden de evaluación entre reglas con el mismo host lo decide el controller (nginx-ingress evalúa el path más específico primero), así que conviene no depender de coincidencias ambiguas.

## Ejemplo: name-based virtual hosting (varios hosts, un Ingress)

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
            name: blog-svc
            port:
              number: 80
  - host: shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop-svc
            port:
              number: 80
```

El controller usa el header `Host` de la petición HTTP para decidir a qué regla aplicar. Por eso, si probás con `curl`, tenés que fijar el header o resolver el DNS al `EXTERNAL-IP` del Ingress:

```console
$ curl -H "Host: shop.example.com" http://<EXTERNAL-IP>/
```

## `defaultBackend`: qué pasa si nada matchea

```yaml
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: fallback-svc
      port:
        number: 80
  rules:
  - host: app.example.com
    ...
```

Si una petición no coincide con ningún `host`/`path` de `rules`, se envía a `defaultBackend` (típicamente responde un 404 propio de la app). Si no se define, responde el 404 default del controller.

## TLS: terminación en el Ingress

```yaml
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
            name: web-svc
            port:
              number: 80
```

`secretName` apunta a un `Secret` de tipo `kubernetes.io/tls` con las claves `tls.crt` y `tls.key`:

```console
$ kubectl create secret tls app-tls-secret \
    --cert=path/to/tls.crt --key=path/to/tls.key
```

El Ingress Controller termina TLS ahí; el tráfico hacia el `Service` backend suele viajar en HTTP plano dentro del cluster.

## Verificación y troubleshooting

```console
$ kubectl get ingress
NAME          CLASS   HOSTS              ADDRESS         PORTS   AGE
web-ingress   nginx   app.example.com    192.168.49.2    80      2m

$ kubectl describe ingress web-ingress
Name:             web-ingress
...
Rules:
  Host              Path  Backends
  ----              ----  --------
  app.example.com
                     /   web-svc:80 (10.244.0.5:80)
...
Events:
  Type    Reason  Age   From                      Message
  ----    ------  ----  ----                      -------
  Normal  Sync    2m    nginx-ingress-controller  Scheduled for sync
```

Puntos de fallo típicos a chequear, en orden:

1. **`ADDRESS` vacío o sin eventos de sync**: no hay ningún controller mirando esa `ingressClassName`, o el controller no está corriendo (`kubectl get pods -n ingress-nginx`).
2. **404 del backend por defecto del controller**: el `host`/`path` de la petición no matchea ninguna regla — revisar el header `Host` enviado.
3. **502/503 desde el controller**: el `Service` backend existe pero no tiene `Endpoints` (selector de labels mal configurado, o Pods no `Ready`). Verificar con `kubectl get endpoints <service>`.
4. **`Backends` en `describe ingress` sin IP** (`<none>`): confirma el mismo problema de Endpoints — el `Service` referenciado por el Ingress no está enrutando a ningún Pod.
5. **El `Service` referenciado debe ser `ClusterIP` (o headless) y estar en el mismo namespace** que el `Ingress` — Ingress no puede apuntar a un `Service` de otro namespace.

## Referencias

- [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) — kubernetes.io
- [Ingress Controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/) — kubernetes.io
- [IngressClass](https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-class) — kubernetes.io
- [kubectl create ingress](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-ingress) — kubernetes.io
- [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf) — CNCF