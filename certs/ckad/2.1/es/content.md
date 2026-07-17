# 2.1 Use Kubernetes primitives to implement common deployment strategies

## Introducción

Kubernetes no tiene un objeto nativo llamado "Blue/Green" o "Canary". Estas estrategias se implementan combinando primitivas ya existentes: `Deployment`, `ReplicaSet`, `Service` (mediante `selector`/`labels`) y, opcionalmente, un `Ingress`. Entender cómo combinar estas piezas es el objetivo de este tema.

Las tres estrategias que hay que dominar para el examen son:

- **Rolling Update**: la estrategia por defecto de un `Deployment`.
- **Recreate**: alternativa simple que apaga todo antes de levantar la nueva versión.
- **Blue/Green**: dos entornos completos (versiones) conviviendo, con el `Service` apuntando a uno u otro.
- **Canary**: una fracción pequeña del tráfico va a la versión nueva mientras el resto sigue en la versión estable.

## Rolling Update

Es el `strategy.type` por defecto de un `Deployment`. Kubernetes reemplaza Pods de a poco, respetando `maxSurge` (cuántos Pods extra puede crear por encima del `replicas` deseado) y `maxUnavailable` (cuántos Pods puede tener no disponibles durante la actualización).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 6
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
        version: v1
    spec:
      containers:
        - name: web
          image: myregistry/web:v1
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
```

Actualizar la imagen y seguir el progreso:

```bash
kubectl set image deployment/web web=myregistry/web:v2 --record
kubectl rollout status deployment/web
```

Salida típica:

```
Waiting for deployment "web" rollout to finish: 2 out of 6 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 5 out of 6 new replicas have been updated...
deployment "web" successfully rolled out
```

El `readinessProbe` es clave: sin él, Kubernetes considera un Pod "listo" apenas arranca el contenedor, y podría enrutar tráfico a una réplica que todavía no puede atenderlo.

Rollback a la revisión anterior:

```bash
kubectl rollout undo deployment/web
kubectl rollout history deployment/web
```

## Recreate

`strategy.type: Recreate` termina todos los Pods existentes antes de crear los nuevos. Implica downtime, pero es útil cuando la aplicación no soporta tener dos versiones corriendo en simultáneo (por ejemplo, migraciones de esquema incompatibles).

```yaml
spec:
  strategy:
    type: Recreate
```

## Blue/Green Deployment

La idea es tener **dos Deployments independientes** (uno "blue" con la versión estable, otro "green" con la versión nueva) y usar el `selector` de un `Service` para decidir cuál recibe el tráfico. El corte es instantáneo (todo o nada), a diferencia del Rolling Update.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-blue
spec:
  replicas: 4
  selector:
    matchLabels:
      app: web
      version: blue
  template:
    metadata:
      labels:
        app: web
        version: blue
    spec:
      containers:
        - name: web
          image: myregistry/web:v1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-green
spec:
  replicas: 4
  selector:
    matchLabels:
      app: web
      version: green
  template:
    metadata:
      labels:
        app: web
        version: green
    spec:
      containers:
        - name: web
          image: myregistry/web:v2
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
    version: blue   # tráfico va a "blue"
  ports:
    - port: 80
      targetPort: 8080
```

Ambos Deployments existen y corren al mismo tiempo (con `green` ya validado internamente, por ejemplo con `kubectl port-forward` o un Service temporal apuntando solo a `green`). El corte se hace editando el `selector` del `Service`:

```bash
kubectl patch service web -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
```

Verificar el cambio:

```bash
kubectl get service web -o jsonpath='{.spec.selector}'
```

```
{"app":"web","version":"green"}
```

Ventaja: rollback inmediato (basta con volver a apuntar el `selector` a `blue`). Desventaja: se necesita el doble de recursos mientras ambas versiones conviven, y no hay una migración gradual de tráfico.

## Canary Deployment

En canary, ambas versiones reciben tráfico simultáneamente, pero en proporciones distintas. Con primitivas puras de Kubernetes (sin un service mesh ni un Ingress controller avanzado), esto se logra manipulando el **número de réplicas** de dos Deployments que comparten las mismas labels que selecciona un único `Service`. Como el balanceo entre endpoints es aproximadamente uniforme, la proporción de réplicas define la proporción de tráfico.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-stable
spec:
  replicas: 9      # ~90% del tráfico
  selector:
    matchLabels:
      app: web
      track: stable
  template:
    metadata:
      labels:
        app: web
        track: stable
    spec:
      containers:
        - name: web
          image: myregistry/web:v1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-canary
spec:
  replicas: 1      # ~10% del tráfico
  selector:
    matchLabels:
      app: web
      track: canary
  template:
    metadata:
      labels:
        app: web
        track: canary
    spec:
      containers:
        - name: web
          image: myregistry/web:v2
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web        # sin "track": matchea ambos Deployments
  ports:
    - port: 80
      targetPort: 8080
```

Notar que el `Service` selecciona solo por `app: web`, ignorando `track`, por lo que sus Endpoints incluyen Pods de ambas versiones:

```bash
kubectl get endpoints web -o wide
```

```
NAME   ENDPOINTS                                               AGE
web    10.244.1.5:8080,10.244.1.6:8080,10.244.2.9:8080 + 7 more 3m
```

Escalar el canary gradualmente (10% → 30% → 50% → 100%) y luego eliminar `web-stable` cuando la validación es exitosa:

```bash
kubectl scale deployment web-canary --replicas=3
kubectl scale deployment web-stable --replicas=7
```

Si algo falla, alcanza con escalar `web-canary` a 0 o borrarlo:

```bash
kubectl scale deployment web-canary --replicas=0
```

Este método basado en proporción de réplicas es una aproximación razonable para el examen porque no depende de un Ingress o service mesh específico, pero conviene tener presente sus límites: el balanceo por `kube-proxy` (modo `iptables`/`ipvs`) no garantiza una distribución exacta de tráfico, especialmente con pocas réplicas o conexiones persistentes (keep-alive), y no permite segmentar por otros criterios (headers, cookies, geolocalización). En un entorno productivo real, canary suele delegarse a un Ingress controller (p. ej. NGINX con anotaciones de `canary-weight`) o a un service mesh (Istio, Linkerd), que quedan fuera del alcance de las primitivas puras del curriculum.

## Resumen comparativo

| Estrategia     | Downtime | Rollback | Tráfico mixto | Costo de recursos |
|----------------|----------|----------|----------------|--------------------|
| Recreate       | Sí       | Rápido (nuevo apply) | No | Bajo (1 versión a la vez) |
| RollingUpdate  | No       | `kubectl rollout undo` | Sí, transitorio | Medio (`maxSurge`) |
| Blue/Green     | No (corte instantáneo) | Inmediato (cambiar `selector`) | No | Alto (2 entornos completos) |
| Canary         | No       | Escalar a 0 / borrar Deployment | Sí, controlado | Medio-alto |

## Referencias

- CNCF, *CKAD Curriculum v1.35*: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes Docs, *Deployments*: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes Docs, *Performing a Rolling Update*: https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/
- Kubernetes Docs, *Service*: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes Docs, *Managing Resources / Rolling Updates and Rollbacks*: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment
- Kubernetes Blog, *Canary Deployments*: https://kubernetes.io/blog/2018/04/30/zero-downtime-deployment-kubernetes-jenkins/