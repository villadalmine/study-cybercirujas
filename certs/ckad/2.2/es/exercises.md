# Ejercicios guiados — 2.2 Understand Deployments and how to perform rolling updates

> **Requisitos:** un cluster de práctica (minikube, kind o killercoda) y `kubectl` configurado. Trabajá en un namespace limpio:
>
> ```bash
> kubectl create namespace ejercicios-22
> kubectl config set-context --current --namespace=ejercicios-22
> ```

---

## Ejercicio 1 — Crear un Deployment y explorar su jerarquía

1. Creá un Deployment de forma imperativa:

   ```bash
   kubectl create deployment web --image=nginx:1.25 --replicas=3
   ```

2. Observá los tres niveles de objetos que se crearon:

   ```bash
   kubectl get deployments
   kubectl get replicasets
   kubectl get pods
   ```

3. Mirá los nombres con atención: el ReplicaSet se llama `web-<hash>` y los Pods se llaman `web-<hash>-<sufijo>`.

4. Inspeccioná el Deployment completo:

   ```bash
   kubectl describe deployment web
   ```

   Fijate en los campos `StrategyType`, `RollingUpdateStrategy` y la sección `Events`.

5. Confirmá quién es el "dueño" de un Pod:

   ```bash
   kubectl get pod <nombre-de-un-pod> -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
   ```

**Preguntas:**

- **1a.** ¿Qué objeto crea y gestiona directamente los Pods: el Deployment o el ReplicaSet?
- **1b.** ¿Qué representa el `<hash>` en el nombre del ReplicaSet y para qué sirve?
- **1c.** Si borrás un Pod con `kubectl delete pod <nombre>`, ¿qué pasa y por qué?

---

## Ejercicio 2 — Escalar el Deployment

1. Escalá a 5 réplicas de forma imperativa:

   ```bash
   kubectl scale deployment web --replicas=5
   kubectl get pods
   ```

2. Ahora bajá a 2 réplicas editando el objeto en vivo:

   ```bash
   kubectl edit deployment web
   ```

   Buscá `spec.replicas`, cambialo a `2`, guardá y salí.

3. Verificá el resultado y mirá el ReplicaSet:

   ```bash
   kubectl get pods
   kubectl get rs
   ```

**Preguntas:**

- **2a.** Al escalar de 5 a 2, ¿se creó un ReplicaSet nuevo? ¿Por qué sí o por qué no?
- **2b.** En el examen, ¿qué comando es más rápido para escalar: `kubectl scale` o `kubectl edit`? ¿Cuándo conviene cada uno?

---

## Ejercicio 3 — Rolling update: cambiar la imagen

1. Antes de actualizar, dejá una terminal mirando los Pods en tiempo real (o usá `watch`):

   ```bash
   kubectl get pods -w
   ```

2. En otra terminal, volvé a 4 réplicas y actualizá la imagen:

   ```bash
   kubectl scale deployment web --replicas=4
   kubectl set image deployment/web nginx=nginx:1.26
   ```

   > El formato es `kubectl set image deployment/<nombre> <nombre-del-container>=<imagen-nueva>`. El container se llama `nginx` porque `kubectl create deployment` le puso el nombre de la imagen.

3. Seguí el progreso del rollout hasta que termine:

   ```bash
   kubectl rollout status deployment/web
   ```

4. Mirá los ReplicaSets ahora:

   ```bash
   kubectl get rs
   ```

   Deberías ver **dos**: el viejo con `DESIRED 0` y el nuevo con `DESIRED 4`.

5. Confirmá la imagen que corre:

   ```bash
   kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

**Preguntas:**

- **3a.** Durante el rollout, ¿en algún momento hubo 0 Pods disponibles? ¿Qué mecanismo lo evita?
- **3b.** ¿Por qué Kubernetes conserva el ReplicaSet viejo con 0 réplicas en vez de borrarlo?
- **3c.** ¿Qué campo del Deployment dispara un rollout cuando cambia: `spec.replicas` o `spec.template`?

---

## Ejercicio 4 — Controlar la estrategia: `maxSurge` y `maxUnavailable`

1. Mirá la estrategia actual:

   ```bash
   kubectl get deployment web -o jsonpath='{.spec.strategy}' ; echo
   ```

   Por defecto: `RollingUpdate` con `maxSurge: 25%` y `maxUnavailable: 25%`.

2. Editá el Deployment y configurá una estrategia más conservadora:

   ```bash
   kubectl edit deployment web
   ```

   Dejá la sección así:

   ```yaml
   strategy:
     type: RollingUpdate
     rollingUpdate:
       maxSurge: 1
       maxUnavailable: 0
   ```

3. Lanzá otra actualización y observá el comportamiento:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27
   kubectl get pods -w
   ```

   Notá que primero **aparece** un Pod nuevo y recién cuando está `Ready` se **termina** uno viejo.

**Preguntas:**

- **4a.** Con 4 réplicas, `maxSurge: 1` y `maxUnavailable: 0`, ¿cuál es el máximo de Pods simultáneos durante el rollout? ¿Y el mínimo de Pods disponibles?
- **4b.** ¿Qué combinación de `maxSurge`/`maxUnavailable` usarías si tu cluster no tiene recursos para ni un Pod extra, y qué costo tiene?
- **4c.** ¿Qué hace la estrategia `Recreate` y en qué caso es la única opción viable?

---

## Ejercicio 5 — Historial de rollouts y rollback

1. Mirá el historial de revisiones:

   ```bash
   kubectl rollout history deployment/web
   ```

2. La columna `CHANGE-CAUSE` probablemente diga `<none>`. Anotá la causa del próximo cambio:

   ```bash
   kubectl annotate deployment/web kubernetes.io/change-cause="upgrade a nginx:1.27-alpine"
   kubectl set image deployment/web nginx=nginx:1.27-alpine
   kubectl rollout history deployment/web
   ```

3. Inspeccioná una revisión puntual (usá un número que exista en tu historial):

   ```bash
   kubectl rollout history deployment/web --revision=3
   ```

4. Simulá un despliegue roto:

   ```bash
   kubectl set image deployment/web nginx=nginx:no-existe
   kubectl rollout status deployment/web --timeout=30s
   kubectl get pods
   ```

   Vas a ver Pods nuevos en `ErrImagePull`/`ImagePullBackOff`, pero los Pods viejos siguen sirviendo.

5. Volvé atrás:

   ```bash
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web
   kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

6. (Opcional) Volvé a una revisión específica:

   ```bash
   kubectl rollout undo deployment/web --to-revision=2
   ```

**Preguntas:**

- **5a.** En el paso 4, ¿por qué la aplicación siguió disponible aunque la imagen nueva era inválida?
- **5b.** `kubectl rollout undo` sin `--to-revision`, ¿a qué revisión vuelve?
- **5c.** ¿Qué campo del Deployment limita cuántas revisiones viejas se guardan?
- **5d.** Después de un `undo`, ¿la revisión a la que volviste conserva su número original en el historial?

---

## Ejercicio 6 — Pausar y reanudar un rollout

1. Pausá el Deployment:

   ```bash
   kubectl rollout pause deployment/web
   ```

2. Aplicá **varios** cambios mientras está pausado:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.28
   kubectl set resources deployment/web -c nginx --limits=cpu=200m,memory=128Mi
   kubectl get rs
   ```

   Fijate que **no** se creó ningún ReplicaSet nuevo todavía.

3. Reanudá y observá:

   ```bash
   kubectl rollout resume deployment/web
   kubectl rollout status deployment/web
   kubectl get rs
   ```

**Preguntas:**

- **6a.** ¿Cuál es la ventaja de pausar antes de hacer varios cambios seguidos?
- **6b.** Mientras el Deployment está pausado, ¿funciona `kubectl scale`? ¿Y `kubectl rollout undo`?

---

## Limpieza

```bash
kubectl delete namespace ejercicios-22
kubectl config set-context --current --namespace=default
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**1a.** El **ReplicaSet**. El Deployment gestiona ReplicaSets, y cada ReplicaSet crea y mantiene los Pods. La cadena es: Deployment → ReplicaSet → Pods.

**1b.** El hash se calcula sobre el **pod template** (`spec.template`) del Deployment (es el `pod-template-hash`). Sirve para que cada versión del template tenga su propio ReplicaSet: si el template cambia, cambia el hash y se crea un ReplicaSet nuevo; los Pods llevan ese hash como label para que cada ReplicaSet seleccione solo los suyos.

**1c.** El ReplicaSet detecta que hay menos Pods que `replicas` deseadas y crea uno nuevo de inmediato. Es el bucle de reconciliación: el estado deseado (3 réplicas) se restaura solo.

**2a.** No. Escalar solo modifica `spec.replicas`, no toca el pod template, así que el ReplicaSet existente ajusta su cantidad de Pods. Solo los cambios en `spec.template` generan un ReplicaSet nuevo.

**2b.** `kubectl scale` es más rápido y menos propenso a errores para ese cambio puntual; `kubectl edit` conviene cuando hay que tocar varios campos a la vez (por ejemplo, réplicas + estrategia). En el examen, para escalar, usá `kubectl scale`.

**3a.** No, nunca hubo 0 disponibles. La estrategia `RollingUpdate` reemplaza Pods de forma gradual respetando `maxUnavailable` (cuántos pueden faltar) y `maxSurge` (cuántos extra puede haber), de modo que siempre queda capacidad sirviendo.

**3b.** Para poder hacer **rollback**. Cada ReplicaSet viejo representa una revisión del historial; `kubectl rollout undo` simplemente re-escala el ReplicaSet de la revisión elegida.

**3c.** `spec.template`. Cambios de imagen, env vars, resources, labels del template, etc. disparan un rollout. `spec.replicas` solo escala el ReplicaSet actual.

**4a.** Máximo **5** Pods simultáneos (4 deseados + 1 de surge). Mínimo **4** disponibles (`maxUnavailable: 0` garantiza que nunca falte ninguno).

**4b.** `maxSurge: 0` con `maxUnavailable: 1` (o más). No consume recursos extra porque nunca hay Pods de más, pero el costo es capacidad reducida durante el rollout: se termina un Pod viejo antes de crear el nuevo. Nota: `maxSurge` y `maxUnavailable` no pueden ser 0 a la vez.

**4c.** `Recreate` termina **todos** los Pods viejos antes de crear los nuevos, con downtime garantizado. Es la única opción cuando dos versiones no pueden coexistir: por ejemplo, un volumen `ReadWriteOnce` que solo un Pod puede montar, o una migración de esquema incompatible entre versiones.

**5a.** El rollout quedó **atascado, no avanzó**: los Pods nuevos nunca llegaron a `Ready` (imagen inexistente), y con `maxUnavailable` respetado los Pods viejos no se terminan hasta que haya reemplazos disponibles. Por eso el servicio siguió arriba con la versión anterior.

**5b.** A la revisión **inmediatamente anterior** (la penúltima del historial).

**5c.** `spec.revisionHistoryLimit` (por defecto 10). Controla cuántos ReplicaSets viejos con 0 réplicas se conservan; los que exceden el límite se borran y esas revisiones ya no admiten rollback.

**5d.** No: la revisión a la que volvés se **renumera** como la más nueva. Si estabas en la 5 y volvés a la 3, la 3 desaparece del historial y reaparece como revisión 6.

**6a.** Que todos los cambios se apliquen en **un solo rollout**. Sin pausa, cada `kubectl set ...` dispara su propio rollout (un ReplicaSet nuevo por cambio); pausando, acumulás cambios en el template y al hacer `resume` se despliegan juntos, con una sola revisión.

**6b.** `kubectl scale` sí funciona (escalar no pasa por el mecanismo de rollout). `kubectl rollout undo` **no**: un Deployment pausado no puede hacer rollback hasta que se reanude.

</details>

---

**Fuentes:**

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes docs — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes docs — Performing a Rolling Update: https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/