# 2.2 — Understand Deployments and how to perform rolling updates

## ¿Qué es un Deployment?

Un **Deployment** es el objeto de Kubernetes que gestiona aplicaciones *stateless* de forma declarativa. Vos declarás el estado deseado (imagen, número de réplicas, estrategia de actualización) y el **Deployment controller** se encarga de que el estado real converja hacia ese estado deseado.

La jerarquía de objetos es clave para entender cómo funcionan las actualizaciones:

```
Deployment
   └── ReplicaSet (una por cada "revisión" del template de Pod)
          └── Pods (réplicas idénticas)
```

- El **Deployment** define el *Pod template* y la política de despliegue.
- Cada vez que cambiás el Pod template (por ejemplo, la imagen), el Deployment crea un **ReplicaSet** nuevo y migra gradualmente los Pods del ReplicaSet viejo al nuevo. Eso es un **rolling update**.
- Los ReplicaSets viejos quedan escalados a 0 pero se conservan (hasta `revisionHistoryLimit`), lo que permite hacer **rollback**.

> **Regla práctica:** nunca gestiones ReplicaSets directamente; siempre trabajá a nivel Deployment.

---

## Crear un Deployment

### Forma imperativa (rápida para el examen)

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3
```

Verificación:

```bash
kubectl get deployments
```

```
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    3/3     3            3           15s
```

Significado de las columnas:

| Columna | Qué indica |
|---|---|
| `READY` | Réplicas listas / réplicas deseadas |
| `UP-TO-DATE` | Réplicas que ya corren el template actual |
| `AVAILABLE` | Réplicas disponibles para los usuarios (pasaron `minReadySeconds`) |

Un truco esencial para el CKAD: generar el YAML sin crear el objeto, usando `--dry-run=client -o yaml`:

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3 \
  --dry-run=client -o yaml > deploy.yaml
```

### Forma declarativa (YAML)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
```

Puntos que el examen suele evaluar:

- `spec.selector.matchLabels` **debe coincidir** con `spec.template.metadata.labels`; si no, el `kubectl apply` falla.
- El `selector` es **inmutable** después de crear el Deployment.
- `apiVersion` es `apps/v1` (no `v1`).

```bash
kubectl apply -f deploy.yaml
```

---

## Escalar un Deployment

```bash
# Imperativo
kubectl scale deployment web --replicas=5

# O editando el campo replicas
kubectl edit deployment web
```

El escalado **no** crea una revisión nueva (no cambia el Pod template), por lo que no aparece en el historial de rollout.

También existe autoescalado con HPA (se ve en su propio tema, pero el comando es útil):

```bash
kubectl autoscale deployment web --min=3 --max=10 --cpu-percent=80
```

---

## Estrategias de actualización

El campo `spec.strategy` controla cómo se reemplazan los Pods viejos:

```yaml
spec:
  strategy:
    type: RollingUpdate        # valor por defecto
    rollingUpdate:
      maxSurge: 25%            # cuántos Pods extra puede crear por encima de replicas
      maxUnavailable: 25%      # cuántos Pods pueden faltar respecto de replicas
```

### `RollingUpdate` (por defecto)

Reemplaza los Pods gradualmente: sube Pods nuevos y baja viejos respetando dos límites:

- **`maxSurge`**: máximo de Pods *adicionales* sobre el número deseado durante la actualización. Puede ser un número absoluto (`1`) o un porcentaje (`25%`). Con `replicas: 4` y `maxSurge: 25%`, puede haber hasta 5 Pods en total.
- **`maxUnavailable`**: máximo de Pods que pueden estar *no disponibles* durante la actualización. Con `replicas: 4` y `maxUnavailable: 25%`, siempre habrá al menos 3 Pods disponibles.

No pueden ser ambos `0` a la vez.

Configuraciones típicas:

| Objetivo | Configuración |
|---|---|
| Cero downtime, con capacidad extra | `maxSurge: 1`, `maxUnavailable: 0` |
| Sin consumir recursos extra | `maxSurge: 0`, `maxUnavailable: 1` |
| Actualización rápida | valores altos en ambos |

### `Recreate`

```yaml
spec:
  strategy:
    type: Recreate
```

Mata **todos** los Pods viejos antes de crear los nuevos. Implica downtime, pero es necesaria cuando dos versiones no pueden convivir (por ejemplo, si comparten un volumen `ReadWriteOnce` o hay migraciones de esquema incompatibles).

---

## Realizar un rolling update

Cualquier cambio en `spec.template` dispara un rollout. Las tres formas más comunes:

### 1. `kubectl set image` (la más rápida en el examen)

```bash
kubectl set image deployment/web nginx=nginx:1.26
```

La sintaxis es `deployment/<nombre> <nombre-del-container>=<imagen-nueva>`. Ojo: es el nombre del **container** dentro del Pod template, no el del Deployment.

### 2. `kubectl edit`

```bash
kubectl edit deployment web
# modificar spec.template.spec.containers[0].image y guardar
```

### 3. `kubectl apply` con el YAML modificado (enfoque GitOps)

```bash
# editar deploy.yaml con la imagen nueva
kubectl apply -f deploy.yaml
```

### Observar el progreso

```bash
kubectl rollout status deployment/web
```

```
Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 2 of 3 updated replicas are available...
deployment "web" successfully rolled out
```

Mientras tanto, se puede ver la convivencia de los dos ReplicaSets:

```bash
kubectl get rs
```

```
NAME             DESIRED   CURRENT   READY   AGE
web-5d9c7b8f6d   1         1         1       10m   # viejo, bajando
web-7f6b4c9d8e   3         3         2       20s   # nuevo, subiendo
```

### Registrar la causa del cambio

Para que el historial sea útil, anotá cada revisión:

```bash
kubectl annotate deployment/web kubernetes.io/change-cause="upgrade a nginx:1.26"
```

---

## Historial y rollback

### Ver el historial de revisiones

```bash
kubectl rollout history deployment/web
```

```
deployment.apps/web
REVISION  CHANGE-CAUSE
1         <none>
2         upgrade a nginx:1.26
```

Detalle de una revisión concreta (muestra el Pod template de esa revisión):

```bash
kubectl rollout history deployment/web --revision=2
```

### Volver atrás (rollback)

```bash
# A la revisión inmediatamente anterior
kubectl rollout undo deployment/web

# A una revisión específica
kubectl rollout undo deployment/web --to-revision=1
```

El rollback es en sí mismo un rolling update: el Deployment vuelve a escalar el ReplicaSet de la revisión elegida. La revisión restaurada pasa a ser la más nueva del historial.

La cantidad de revisiones conservadas se controla con:

```yaml
spec:
  revisionHistoryLimit: 10   # por defecto 10; con 0 no hay rollback posible
```

---

## Pausar y reanudar un rollout

Útil para acumular varios cambios y aplicarlos en un único rollout:

```bash
kubectl rollout pause deployment/web

kubectl set image deployment/web nginx=nginx:1.27
kubectl set resources deployment/web -c nginx --limits=cpu=200m,memory=256Mi

kubectl rollout resume deployment/web
```

Mientras está pausado, los cambios al template se registran pero **no** disparan Pods nuevos.

Para reiniciar los Pods sin cambiar el template (por ejemplo, para recargar un ConfigMap montado):

```bash
kubectl rollout restart deployment/web
```

---

## Detectar rollouts fallidos

Dos campos afinan la detección de fallas:

```yaml
spec:
  minReadySeconds: 10            # un Pod debe estar Ready 10s antes de contar como disponible
  progressDeadlineSeconds: 600   # tras 600s sin progreso, el rollout se marca como fallido
```

Si superás el `progressDeadlineSeconds` (imagen inexistente, crash loop, etc.), el Deployment reporta la condición `Progressing=False` con razón `ProgressDeadlineExceeded`:

```bash
kubectl rollout status deployment/web
```

```
error: deployment "web" exceeded its progress deadline
```

Diagnóstico típico:

```bash
kubectl describe deployment web      # ver Conditions y Events
kubectl get pods                     # buscar ImagePullBackOff / CrashLoopBackOff
kubectl rollout undo deployment/web  # volver a la versión estable
```

Importante: Kubernetes **no revierte automáticamente** un rollout fallido; el `undo` es responsabilidad tuya.

---

## Resumen de comandos para el examen

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3
kubectl create deployment web --image=nginx:1.25 --dry-run=client -o yaml > d.yaml
kubectl scale deployment web --replicas=5
kubectl set image deployment/web nginx=nginx:1.26
kubectl rollout status deployment/web
kubectl rollout history deployment/web [--revision=N]
kubectl rollout undo deployment/web [--to-revision=N]
kubectl rollout pause|resume|restart deployment/web
kubectl annotate deployment/web kubernetes.io/change-cause="..."
```

---

## Referencias

- Deployments — documentación oficial de Kubernetes: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Performing a Rolling Update (tutorial interactivo): https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/
- ReplicaSet: https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Referencia de `kubectl rollout`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout
- Referencia de `kubectl set image`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#set
- CKAD Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf