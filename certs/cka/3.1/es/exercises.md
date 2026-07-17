# Ejercicios guiados — 3.1 Application deployments: rolling update y rollback

> Referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Todos los ejercicios asumen un cluster con `kubectl` configurado contra el context correcto. Se recomienda trabajar en un namespace propio para no interferir con otros recursos.

## Ejercicio 1 — Preparar el namespace de trabajo

1. Creá un namespace dedicado:
   ```bash
   kubectl create namespace deploy-lab
   ```
2. Fijalo como namespace por defecto del context actual:
   ```bash
   kubectl config set-context --current --namespace=deploy-lab
   ```
3. Confirmá el cambio:
   ```bash
   kubectl config view --minify | grep namespace
   ```

**Preguntas de verificación**
- ¿Qué diferencia hay entre pasar `-n deploy-lab` en cada comando y fijar el namespace en el context?
- ¿Qué comando usarías para volver al namespace `default`?

---

## Ejercicio 2 — Crear un Deployment de forma declarativa

1. Creá el archivo `web-deploy.yaml`:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     labels:
       app: web
   spec:
     replicas: 4
     revisionHistoryLimit: 5
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
           image: nginx:1.25.3
           ports:
           - containerPort: 80
   ```
2. Aplicalo al cluster:
   ```bash
   kubectl apply -f web-deploy.yaml
   ```
3. Dejá constancia del motivo del cambio (reemplaza al obsoleto `--record`):
   ```bash
   kubectl annotate deployment web kubernetes.io/change-cause="initial deploy nginx:1.25.3"
   ```

**Preguntas de verificación**
- ¿Por qué `kubectl apply` es preferible a `kubectl create` para manejar el ciclo de vida completo de un Deployment?
- ¿Qué controla el campo `revisionHistoryLimit` y por qué importa para los rollbacks?

---

## Ejercicio 3 — Explorar la relación Deployment → ReplicaSet → Pod

1. Listá el Deployment y su ReplicaSet:
   ```bash
   kubectl get deployment web
   kubectl get replicaset -l app=web
   ```
2. Listá los Pods y observá el sufijo de su nombre:
   ```bash
   kubectl get pods -l app=web -o wide
   ```
3. Inspeccioná el ReplicaSet en detalle:
   ```bash
   kubectl describe replicaset -l app=web
   ```

**Preguntas de verificación**
- ¿Qué objeto crea realmente los Pods: el Deployment o el ReplicaSet?
- ¿Cómo se relaciona el hash que aparece en el nombre del ReplicaSet y de los Pods con el `pod template` del Deployment?

---

## Ejercicio 4 — Escalar el Deployment

1. Escalá a 6 réplicas:
   ```bash
   kubectl scale deployment web --replicas=6
   ```
2. Verificá que el ReplicaSet ajustó su cantidad de Pods:
   ```bash
   kubectl get pods -l app=web
   ```

**Preguntas de verificación**
- ¿Un scale genera una nueva revision en el historial de rollout? ¿Por qué sí o por qué no?

---

## Ejercicio 5 — Rolling update cambiando la imagen

1. Actualizá la imagen del container:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.3
   ```
2. Dejá constancia del cambio:
   ```bash
   kubectl annotate deployment web kubernetes.io/change-cause="update to nginx:1.27.3" --overwrite
   ```
3. Seguí el progreso del rollout en tiempo real:
   ```bash
   kubectl rollout status deployment/web
   ```
4. Mientras corre, en otra terminal observá cómo aparecen y desaparecen Pods:
   ```bash
   kubectl get pods -l app=web -w
   ```

**Preguntas de verificación**
- Durante el rolling update, ¿el Deployment apaga todos los Pods viejos antes de crear los nuevos? Explicá qué garantiza la disponibilidad del servicio.
- ¿Qué comando usarías para confirmar que la imagen efectivamente cambió en el pod template del Deployment?

---

## Ejercicio 6 — Entender y ajustar la estrategy de rolling update

1. Revisá la estrategy actual:
   ```bash
   kubectl get deployment web -o jsonpath='{.spec.strategy}{"\n"}'
   ```
2. Editá el Deployment para fijar explícitamente `maxSurge` y `maxUnavailable`:
   ```bash
   kubectl patch deployment web -p '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
   ```
3. Repetí un cambio de imagen para observar el efecto:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.4
   kubectl get pods -l app=web -w
   ```

**Preguntas de verificación**
- Con `maxUnavailable: 0` y `maxSurge: 1`, ¿cuántos Pods como máximo puede haber corriendo simultáneamente durante el update si `replicas: 6`?
- ¿Qué combinación de `maxSurge`/`maxUnavailable` prioriza velocidad del rollout sobre uso de recursos, y cuál prioriza lo contrario?

---

## Ejercicio 7 — Revisar el historial de revisiones

1. Listá el historial de rollouts:
   ```bash
   kubectl rollout history deployment/web
   ```
2. Inspeccioná el detalle de una revision específica (reemplazá `N` por un número listado):
   ```bash
   kubectl rollout history deployment/web --revision=N
   ```

**Preguntas de verificación**
- ¿Qué información puntual muestra `--revision=N` que no aparece en el listado general?
- Si no anotás `kubernetes.io/change-cause` en cada cambio, ¿qué columna del historial queda vacía o poco útil?

---

## Ejercicio 8 — Provocar un rollout fallido

1. Aplicá una imagen inexistente para simular un error de deploy:
   ```bash
   kubectl set image deployment/web nginx=nginx:1.99-does-not-exist
   ```
2. Observá que el rollout no progresa:
   ```bash
   kubectl rollout status deployment/web --timeout=30s
   ```
3. Investigá la causa del bloqueo:
   ```bash
   kubectl get pods -l app=web
   kubectl describe pod -l app=web | grep -A5 Events
   ```

**Preguntas de verificación**
- ¿Por qué los Pods viejos siguen sirviendo tráfico aunque el rollout esté "colgado"?
- ¿Qué `reason` esperás ver en los `Events` del Pod nuevo (por ejemplo `ImagePullBackOff` o `ErrImagePull`)?

---

## Ejercicio 9 — Rollback a la revision anterior

1. Revertí el Deployment a la revision previa:
   ```bash
   kubectl rollout undo deployment/web
   ```
2. Confirmá que el rollout se completa correctamente:
   ```bash
   kubectl rollout status deployment/web
   ```
3. Verificá la imagen resultante:
   ```bash
   kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

**Preguntas de verificación**
- ¿`kubectl rollout undo` crea una revision nueva o reutiliza el número de la revision anterior?
- ¿Qué pasaría si intentás el `undo` cuando `revisionHistoryLimit` ya descartó la revision que necesitás?

---

## Ejercicio 10 — Rollback a una revision específica

1. Revisá nuevamente el historial disponible:
   ```bash
   kubectl rollout history deployment/web
   ```
2. Elegí una revision anterior a la última (por ejemplo la del `nginx:1.25.3` inicial) y aplicá el rollback dirigido:
   ```bash
   kubectl rollout undo deployment/web --to-revision=1
   ```
3. Confirmá el resultado:
   ```bash
   kubectl rollout status deployment/web
   kubectl describe deployment web | grep Image
   ```

**Preguntas de verificación**
- ¿Qué ventaja tiene `--to-revision` frente a un `undo` simple cuando hubo varios rollouts fallidos intermedios?

---

## Ejercicio 11 — Pausar y reanudar un rollout

1. Pausá el Deployment antes de aplicar varios cambios:
   ```bash
   kubectl rollout pause deployment/web
   ```
2. Aplicá dos cambios seguidos (no deberían disparar rollout todavía):
   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.5
   kubectl set resources deployment/web -c nginx --limits=cpu=200m,memory=256Mi
   ```
3. Verificá que los Pods siguen sin cambios:
   ```bash
   kubectl get pods -l app=web
   ```
4. Reanudá el rollout para aplicar ambos cambios juntos:
   ```bash
   kubectl rollout resume deployment/web
   kubectl rollout status deployment/web
   ```

**Preguntas de verificación**
- ¿Qué ventaja concreta da pausar el rollout antes de hacer varios cambios relacionados (imagen + resources)?
- Mientras el Deployment está pausado, ¿`kubectl rollout status` reporta el Deployment como "progresando"?

---

## Ejercicio 12 — Limpieza

1. Eliminá el Deployment:
   ```bash
   kubectl delete deployment web
   ```
2. Eliminá el namespace de trabajo:
   ```bash
   kubectl delete namespace deploy-lab
   ```
3. Volvé al namespace `default`:
   ```bash
   kubectl config set-context --current --namespace=default
   ```

**Preguntas de verificación**
- Al eliminar el Deployment, ¿qué pasa automáticamente con su ReplicaSet y sus Pods, y por qué?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- Fijar el namespace en el context evita repetir `-n deploy-lab` en cada comando y reduce el riesgo de operar por error sobre otro namespace; pasar `-n` explícito es más seguro en scripts porque no depende de un estado de configuración externo.
- `kubectl config set-context --current --namespace=default`.

**Ejercicio 2**
- `kubectl apply` es declarativo: calcula el diff contra el estado actual y permite reaplicar el mismo manifiesto de forma idempotente, además de habilitar `kubectl diff`. `kubectl create` es imperativo y falla si el recurso ya existe.
- `revisionHistoryLimit` define cuántos ReplicaSets viejos (revisiones) se conservan para poder hacer rollback; si es muy bajo, se pierden revisiones antiguas y `rollout undo --to-revision` deja de tener a dónde volver.

**Ejercicio 3**
- El ReplicaSet crea y gestiona los Pods; el Deployment gestiona ReplicaSets (crea uno nuevo por cada cambio en el pod template y ajusta réplicas en los existentes).
- El hash (`pod-template-hash`) se calcula a partir del contenido del `template` del Deployment; cada vez que el template cambia, se genera un hash distinto, lo que produce un ReplicaSet nuevo y Pods con ese mismo sufijo como label.

**Ejercicio 4**
- No genera una nueva revision porque el `pod template` no cambió; el rollout history sólo registra cambios en el template (imagen, env vars, resources, etc.), no cambios de `replicas`.

**Ejercicio 5**
- No: el Deployment reemplaza Pods de forma incremental respetando `maxUnavailable`/`maxSurge`, manteniendo siempre un mínimo de Pods disponibles para no interrumpir el servicio.
- `kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}'` o `kubectl describe deployment web`.

**Ejercicio 6**
- Con `maxUnavailable: 0` nunca baja de 6 Pods disponibles, y con `maxSurge: 1` puede haber hasta 1 Pod extra por encima de `replicas`, es decir, hasta 7 Pods corriendo simultáneamente en el pico.
- `maxSurge` alto y `maxUnavailable` alto (o igual a la cantidad de réplicas) prioriza velocidad a costa de más uso de recursos; `maxSurge: 0` con `maxUnavailable` bajo prioriza ahorro de recursos a costa de un rollout más lento (y requiere al menos algo de `maxUnavailable` para poder progresar).

**Ejercicio 7**
- El detalle por revision muestra el pod template completo de esa revision (imagen, labels, containers) y la anotación `change-cause`, algo que el listado general no expone.
- La columna `CHANGE-CAUSE` queda vacía (`<none>`) si no se anotó `kubernetes.io/change-cause` en ese cambio.

**Ejercicio 8**
- Porque la estrategy de rolling update por defecto no elimina Pods viejos hasta que los nuevos estén `Ready`; como los nuevos nunca llegan a `Ready` (no pueden hacer pull de la imagen), los viejos permanecen sirviendo tráfico indefinidamente.
- `ErrImagePull` seguido de `ImagePullBackOff` en los `Events` del Pod.

**Ejercicio 9**
- Crea una revision nueva (con un número de revision incremental), cuyo contenido coincide con el de la revision anterior; no "reutiliza" el número viejo.
- El `undo` falla (no encuentra la revision de destino) porque ya fue descartada del historial; en ese caso no hay forma de volver automáticamente a ese estado y hay que reconstruirlo manualmente o desde el manifiesto versionado en git.

**Ejercicio 10**
- Permite saltar directamente a una revision conocida y válida sin depender de que la "anterior inmediata" (que puede ser justamente la fallida) sea la deseada.

**Ejercicio 11**
- Evita que cada `kubectl set image` / `kubectl set resources` dispare su propio rolling update; al pausar, los cambios se acumulan en el Deployment y se aplican en un único rollout al hacer `resume`, ahorrando ciclos de Pods intermedios.
- No: mientras está pausado, `kubectl rollout status` no considera que haya un rollout en curso (los cambios están pendientes pero no se están propagando a los Pods).

**Ejercicio 12**
- Kubernetes usa `garbage collection` basado en `ownerReferences`: al borrar el Deployment, sus ReplicaSets (que lo referencian como owner) se eliminan en cascada, y a su vez los Pods (que referencian al ReplicaSet) también se eliminan.

</details>
