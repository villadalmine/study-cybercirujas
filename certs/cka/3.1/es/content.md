# 3.1 — Application Deployments: rolling updates y rollbacks (CKA v1.35)

## ¿Qué es un Deployment?

Un **Deployment** es el controlador estándar de Kubernetes para gestionar aplicaciones stateless. No maneja Pods directamente: crea y administra un **ReplicaSet**, y ese ReplicaSet es quien mantiene el número deseado de Pods corriendo. Esta capa extra (Deployment → ReplicaSet → Pod) es justamente lo que permite hacer actualizaciones controladas y volver atrás si algo sale mal.

```
Deployment
   └── ReplicaSet (revisión actual)
          └── Pod, Pod, Pod...
```

Cada vez que cambiás el `spec.template` de un Deployment (por ejemplo, la imagen del container), Kubernetes no modifica los Pods existentes in-place: crea un **nuevo ReplicaSet** con esa versión del template y va migrando réplicas del ReplicaSet viejo al nuevo. El ReplicaSet anterior no se borra, queda en 0 réplicas — ahí es donde vive el historial para el rollback.

## Crear un Deployment

```bash
kubectl create deployment nginx --image=nginx:1.25 --replicas=3
```

O declarativo, que es lo recomendado para producción:

```yaml
# nginx-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 5
```

```bash
kubectl apply -f nginx-deploy.yaml
kubectl get deployments
```

```
NAME    READY   UP-TO-DATE   AVAILABLE   AGE
nginx   3/3     3            3           12s
```

`selector.matchLabels` **debe** coincidir con `template.metadata.labels`. Es inmutable una vez creado el Deployment — si necesitás cambiarlo hay que recrear el objeto.

## Estrategias de deployment: `RollingUpdate` vs `Recreate`

`spec.strategy.type` define cómo se pasa de la versión vieja a la nueva:

- **`Recreate`**: mata todos los Pods viejos y después crea los nuevos. Hay downtime garantizado. Se usa cuando la app no soporta dos versiones corriendo a la vez (ej. no puede haber dos réplicas escribiendo a la misma migración de base de datos).
- **`RollingUpdate`** (default): reemplaza Pods de forma incremental, sin downtime si está bien configurado. Es la estrategia relevante para este tema.

### Parámetros de `rollingUpdate`

- **`maxUnavailable`**: cuántos Pods pueden estar no disponibles durante la actualización, respecto al valor deseado (número absoluto o `%`). Default `25%`.
- **`maxSurge`**: cuántos Pods extra por encima del valor deseado se pueden crear durante la actualización (número absoluto o `%`). Default `25%`.

Ejemplo con `replicas: 4`, `maxSurge: 1`, `maxUnavailable: 0`: Kubernetes primero crea 1 Pod nuevo (llega a 5 Pods total), espera a que pase su `readinessProbe`, recién ahí baja un Pod viejo (vuelve a 4), y repite el ciclo hasta reemplazar todos. Nunca hay menos de 4 Pods disponibles → cero downtime.

Si en cambio ponés `maxSurge: 0` y `maxUnavailable: 1`, nunca se crean Pods extra: primero baja uno viejo y después sube uno nuevo. Más lento, pero usa menos recursos.

> El **readinessProbe** es clave acá: un Pod nuevo no cuenta como "disponible" para el rolling update hasta que pasa su readiness check. Sin probes bien configuradas, Kubernetes puede considerar "listo" un Pod que en realidad todavía no puede servir tráfico.

## Disparar una actualización

Cualquier cambio al `pod template` dispara un rollout. Las formas más comunes:

```bash
# Cambiar solo la imagen
kubectl set image deployment/nginx nginx=nginx:1.27

# Editar el manifiesto completo
kubectl edit deployment nginx

# Re-aplicar un YAML modificado
kubectl apply -f nginx-deploy.yaml
```

⚠️ Cambiar `replicas` con `kubectl scale` **no** genera una nueva revisión ni dispara rolling update — solo modifica la cantidad de réplicas del ReplicaSet activo.

## Monitorear el rollout

```bash
kubectl rollout status deployment/nginx
```

```
Waiting for deployment "nginx" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx" rollout to finish: 1 old replicas are pending termination...
deployment "nginx" successfully rolled out
```

Ver el detalle del evento (útil para debugging):

```bash
kubectl describe deployment nginx
```

```
...
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    True    NewReplicaSetAvailable
OldReplicaSets:  <none>
NewReplicaSet:   nginx-7d9f8c9b6d (3/3 replicas created)
Events:
  Normal  ScalingReplicaSet  2m  deployment-controller  Scaled up replica set nginx-7d9f8c9b6d to 1
  Normal  ScalingReplicaSet  2m  deployment-controller  Scaled down replica set nginx-6c7f5d8b9c to 2
  ...
```

Si el nuevo Pod nunca queda `Ready` (por ejemplo, imagen mal tagueada), el rollout queda colgado indefinidamente en `Progressing`. Se detecta con:

```bash
kubectl rollout status deployment/nginx --timeout=30s
```

```
error: timed out waiting for the condition
```

`spec.progressDeadlineSeconds` (default 600s) marca el Deployment como `ProgressDeadlineExceeded` si no avanza en ese tiempo — no cancela el rollout automáticamente, pero deja la condición visible en `describe`.

## Historial de revisiones

Cada revisión queda registrada gracias a `revisionHistoryLimit` (default 10 en `apps/v1`, aunque conviene fijarlo explícitamente).

```bash
kubectl rollout history deployment/nginx
```

```
deployment.apps/nginx
REVISION  CHANGE-CAUSE
1         <none>
2         kubectl set image deployment/nginx nginx=nginx:1.27
```

La columna `CHANGE-CAUSE` se completa si usás `--record` (deprecado desde 1.28, pero todavía puede aparecer en el examen) o si le agregás la anotación manualmente:

```bash
kubectl annotate deployment/nginx kubernetes.io/change-cause="bump nginx to 1.27" --overwrite
```

Ver el detalle de una revisión puntual:

```bash
kubectl rollout history deployment/nginx --revision=2
```

```
deployment.apps/nginx with revision #2
Pod Template:
  Labels:       app=nginx
                pod-template-hash=7d9f8c9b6d
  Containers:
   nginx:
    Image:      nginx:1.27
    ...
```

Cada revisión corresponde a un ReplicaSet distinto:

```bash
kubectl get replicasets -l app=nginx
```

```
NAME               DESIRED   CURRENT   READY   AGE
nginx-6c7f5d8b9c   0         0         0       10m
nginx-7d9f8c9b6d   3         3         3       2m
```

## Rollback

Volver a la revisión anterior:

```bash
kubectl rollout undo deployment/nginx
```

Volver a una revisión específica:

```bash
kubectl rollout undo deployment/nginx --to-revision=1
```

```
deployment.apps/nginx rolled back
```

El rollback se ejecuta también como un rolling update (respeta `maxSurge`/`maxUnavailable`), no es instantáneo. Internamente, Kubernetes vuelve a escalar el ReplicaSet viejo hacia arriba y el actual hacia abajo.

> Importante para el examen: si borrás el ReplicaSet correspondiente a una revisión vieja, esa revisión desaparece del historial y ya no se puede hacer rollback a ella, aunque siga en `rollout history`.

## Pausar y reanudar rollouts

Útil para hacer varios cambios (imagen + resources + env vars) y que se apliquen como una sola revisión en vez de disparar un rollout por cada cambio:

```bash
kubectl rollout pause deployment/nginx
kubectl set image deployment/nginx nginx=nginx:1.27
kubectl set resources deployment/nginx -c=nginx --limits=cpu=200m,memory=256Mi
kubectl rollout resume deployment/nginx
```

Mientras está pausado, `kubectl rollout status` no reporta cambios y no se crea un nuevo ReplicaSet hasta el `resume`.

## Escalado manual

No es parte de rolling update en sí, pero suele combinarse en el examen:

```bash
kubectl scale deployment/nginx --replicas=5
```

## Comandos clave — resumen rápido

| Acción | Comando |
|---|---|
| Crear | `kubectl create deployment <name> --image=<img>` |
| Actualizar imagen | `kubectl set image deployment/<name> <container>=<img>` |
| Ver estado del rollout | `kubectl rollout status deployment/<name>` |
| Ver historial | `kubectl rollout history deployment/<name>` |
| Ver revisión puntual | `kubectl rollout history deployment/<name> --revision=N` |
| Rollback a la anterior | `kubectl rollout undo deployment/<name>` |
| Rollback a revisión N | `kubectl rollout undo deployment/<name> --to-revision=N` |
| Pausar | `kubectl rollout pause deployment/<name>` |
| Reanudar | `kubectl rollout resume deployment/<name>` |
| Escalar | `kubectl scale deployment/<name> --replicas=N` |

## Errores comunes a tener en cuenta para el examen

- Cambiar solo `metadata.labels` del Deployment (no del `template`) **no** dispara un rollout.
- Un `imagePullBackOff` en la revisión nueva deja el rollout colgado — el Deployment sigue mostrando la versión vieja como `AVAILABLE` porque `maxUnavailable` protege esos Pods.
- `revisionHistoryLimit: 0` elimina el historial apenas termina el rollout: sin ReplicaSets viejos, no hay rollback posible.
- `kubectl rollout restart deployment/<name>` fuerza un rolling restart de todos los Pods sin cambiar el spec (útil para forzar re-pull de `imagePullPolicy: Always`, o rotar Secrets montados como env vars que no se actualizan solos).

## Referencias

- [Deployments — Kubernetes Concepts](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [kubectl rollout — Reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout)
- [Performing a Rolling Update — Tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/)
- [ReplicaSet — Kubernetes Concepts](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/)
- [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)