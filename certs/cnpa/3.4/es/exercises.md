# Tema 3.4 — Incident Response and Remediation in Platform Engineering

## Ejercicios guiados

> **Rol del estudiante:** actuás como platform engineer de guardia (*on-call*). El objetivo de estos ejercicios es recorrer el ciclo completo de un incidente sobre una plataforma cloud native — **detección → triage → diagnóstico → remediación → verificación → post-mortem** — ejecutando comandos reales contra un cluster y razonando cada decisión con el marco SRE de *error budgets* y remediación segura.
>
> **Prerrequisitos**
> - Un cluster de práctica desechable (`kind` o `minikube`). Ejemplo con kind:
>   ```bash
>   kind create cluster --name cnpa-ir
>   kubectl cluster-info --context kind-cnpa-ir
>   ```
> - `kubectl` v1.29+ y `helm` v3.
> - (Opcional, Ejercicios 2 y 5) `kube-prometheus-stack` y Argo CD instalados. Se indican los `helm install` en cada bloque.
>
> **Fuente base del temario:** CNPA Curriculum, dominio *Incident Response and Remediation in Platform Engineering* — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
>
> Cada bloque termina con **preguntas de verificación**. Las respuestas están al final, en una sección colapsable.

---

## Ejercicio 1 — Montar el *incident sandbox*

Antes de responder a un incidente hay que tener uno. Vamos a desplegar una aplicación con tres fallos latentes deliberados que dispararemos más adelante.

1. Creá el namespace de trabajo y etiquetalo como entorno productivo simulado:
   ```bash
   kubectl create namespace shop
   kubectl label namespace shop tier=production environment=prod
   ```

2. Desplegá el servicio `checkout` con un manifiesto completo. Nota los tres puntos de fragilidad marcados en los comentarios:
   ```yaml
   # checkout.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: checkout
     namespace: shop
     labels:
       app: checkout
   spec:
     replicas: 4
     revisionHistoryLimit: 10          # necesario para poder hacer rollback
     selector:
       matchLabels:
         app: checkout
     strategy:
       type: RollingUpdate
       rollingUpdate:
         maxUnavailable: 1
         maxSurge: 1
     template:
       metadata:
         labels:
           app: checkout
       spec:
         containers:
           - name: checkout
             image: ghcr.io/cnpa-lab/checkout:1.4.0
             ports:
               - containerPort: 8080
             resources:
               requests:
                 cpu: 100m
                 memory: 64Mi
               limits:
                 cpu: 250m
                 memory: 128Mi        # límite ajustado: candidato a OOMKill (fallo #1)
             readinessProbe:            # gate real de tráfico
               httpGet:
                 path: /healthz
                 port: 8080
               initialDelaySeconds: 3
               periodSeconds: 5
               failureThreshold: 3
             livenessProbe:
               httpGet:
                 path: /livez
                 port: 8080
               initialDelaySeconds: 10
               periodSeconds: 10
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: checkout
     namespace: shop
   spec:
     selector:
       app: checkout
     ports:
       - port: 80
         targetPort: 8080
   ```
   ```bash
   kubectl apply -f checkout.yaml
   ```

3. Verificá que la línea base está sana (esto es tu *known-good state*, la referencia contra la que compararás durante el incidente):
   ```bash
   kubectl -n shop rollout status deploy/checkout
   kubectl -n shop get deploy checkout -o wide
   ```
   Salida esperada:
   ```
   deployment "checkout" successfully rolled out
   NAME       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                          SELECTOR
   checkout   4/4     4            4           40s   checkout     ghcr.io/cnpa-lab/checkout:1.4.0  app=checkout
   ```

4. Registrá la revisión actual del historial de rollout. Este número es tu "punto de retorno" seguro:
   ```bash
   kubectl -n shop rollout history deploy/checkout
   ```
   ```
   deployment.apps/checkout
   REVISION  CHANGE-CAUSE
   1         <none>
   ```

**Preguntas de verificación — Bloque 1**

1. ¿Por qué `revisionHistoryLimit: 10` es un requisito de *incident readiness* y no un simple detalle cosmético?
2. Diferenciá el rol de la `readinessProbe` y la `livenessProbe` durante un incidente: ¿cuál protege a los usuarios de recibir errores y cuál recupera un pod colgado?
3. ¿Qué significa "known-good state" y por qué registrarlo *antes* del incidente reduce el MTTR (*Mean Time To Recovery*)?

---

## Ejercicio 2 — Detección y triage: de la alerta al síntoma

Un incidente no empieza cuando algo se rompe, sino cuando lo *detectás*. El triage decide severidad, prioridad y si consumís *error budget*.

1. (Si tenés Prometheus) Instalá la stack de observabilidad:
   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
   ```

2. Definí un SLO explícito para `checkout` y la alerta que lo respalda. Sin SLO no hay forma objetiva de decir si esto "amerita" despertar a alguien:
   ```yaml
   # checkout-slo.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: checkout-slo
     namespace: monitoring
     labels:
       release: kps
   spec:
     groups:
       - name: checkout.slo
         rules:
           # Objetivo: 99.5% de requests exitosas en ventana de 30 días.
           # Fast burn: quema del error budget 14.4x más rápido de lo tolerable.
           - alert: CheckoutErrorBudgetFastBurn
             expr: |
               (
                 sum(rate(http_requests_total{job="checkout",code=~"5.."}[5m]))
                 /
                 sum(rate(http_requests_total{job="checkout"}[5m]))
               ) > (14.4 * 0.005)
             for: 2m
             labels:
               severity: page          # dispara paging (P1)
             annotations:
               summary: "checkout quemando error budget a 14.4x"
               runbook_url: "https://runbooks.internal/checkout/error-budget-burn"
   ```
   ```bash
   kubectl apply -f checkout-slo.yaml
   ```

3. Provocá el **primer incidente** (fallo #2, un despliegue defectuoso). Simulás un *bad deploy*, la causa raíz más común de incidentes en plataformas:
   ```bash
   kubectl -n shop set image deploy/checkout checkout=ghcr.io/cnpa-lab/checkout:1.5.0-broken
   ```

4. Observá la propagación del síntoma. Empezá siempre por el estado agregado antes de bajar a un pod:
   ```bash
   kubectl -n shop get deploy checkout
   kubectl -n shop rollout status deploy/checkout --timeout=60s
   ```
   Salida esperada (el rollout se atasca):
   ```
   NAME       READY   UP-TO-DATE   AVAILABLE   AGE
   checkout   3/5     2            3           12m
   Waiting for deployment "checkout" rollout to finish: 2 out of 4 new replicas have been updated...
   error: timed out waiting for the condition
   ```

5. Hacé el triage con tres preguntas y anotá tus respuestas:
   - **Blast radius:** ¿cuántas réplicas afectadas? (`READY 3/5` — todavía hay capacidad sana)
   - **User impact:** ¿el `RollingUpdate` con `maxUnavailable: 1` protegió el tráfico?
   - **Severidad:** con capacidad parcial y sin caída total, ¿es P1 (page) o P2 (degradado)?

**Preguntas de verificación — Bloque 2**

1. El SLO es 99.5% (error budget = 0.5%). Explicá qué significa concretamente el multiplicador `14.4` en la alerta *fast burn* y por qué se usa una estrategia *multi-window multi-burn-rate* en vez de alertar ante el primer 5xx.
2. Durante el `RollingUpdate`, `maxUnavailable: 1` mantuvo `AVAILABLE 3`. ¿Cómo limita esto el *blast radius* y por qué es una decisión de diseño que reduce la severidad del incidente antes de que ocurra?
3. Diferenciá **síntoma** (lo que dispara la alerta) de **causa raíz**. ¿Cuál de los dos hay que atacar primero durante la fase de *remediación táctica* y por qué?

---

## Ejercicio 3 — Diagnóstico con las tres señales

El triage dijo "hay un problema". El diagnóstico dice *qué* problema. Recorremos eventos, estado del pod y logs — sin adivinar.

1. Identificá el pod atascado. El estado te da la primera hipótesis:
   ```bash
   kubectl -n shop get pods -l app=checkout
   ```
   ```
   NAME                        READY   STATUS             RESTARTS   AGE
   checkout-7c9f8b6d54-2xk9p   1/1     Running            0          13m
   checkout-7c9f8b6d54-9jf2l   1/1     Running            0          13m
   checkout-7c9f8b6d54-dp4rt   1/1     Running            0          13m
   checkout-6b5d47f9c8-q7w2z   0/1     CrashLoopBackOff   4          2m
   checkout-6b5d47f9c8-vh8mn   0/1     CrashLoopBackOff   4          2m
   ```

2. Leé los eventos del pod fallido. `describe` es tu primera herramienta forense, no los logs:
   ```bash
   kubectl -n shop describe pod checkout-6b5d47f9c8-q7w2z
   ```
   Fragmento relevante de la sección `Events`:
   ```
   Events:
     Type     Reason     Age                 From     Message
     ----     ------     ----                ----     -------
     Normal   Pulled     2m (x5 over 2m)     kubelet  Successfully pulled image "ghcr.io/cnpa-lab/checkout:1.5.0-broken"
     Normal   Created    2m (x5 over 2m)     kubelet  Created container checkout
     Warning  Unhealthy  90s (x9 over 2m)    kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
     Warning  BackOff    30s (x8 over 2m)    kubelet  Back-off restarting failed container
   ```

3. Confirmá con los logs del contenedor. Usá `--previous` para ver el contenedor que ya murió, no el que está arrancando:
   ```bash
   kubectl -n shop logs checkout-6b5d47f9c8-q7w2z --previous --tail=20
   ```
   ```
   {"level":"info","msg":"starting checkout v1.5.0-broken"}
   {"level":"fatal","msg":"config schema migration failed: unknown field 'legacy_gateway'"}
   ```

4. Correlacioná el estado del contenedor con el motivo de salida a nivel de kernel/kubelet:
   ```bash
   kubectl -n shop get pod checkout-6b5d47f9c8-q7w2z \
     -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
   ```
   ```
   Error
   ```

5. Formulá la hipótesis en una frase falsable, con evidencia: *"El release `1.5.0-broken` falla al migrar el schema de config (`config schema migration failed`), el proceso sale con código de error, la readiness devuelve 500 y el pod entra en CrashLoopBackOff. Los pods de la revisión anterior siguen sanos."*

**Preguntas de verificación — Bloque 3**

1. Ordená la secuencia de estados que llevó a `CrashLoopBackOff` y explicá qué es exactamente el "back-off" (¿por qué los `RESTARTS` no crecen instantáneamente?).
2. ¿Por qué `kubectl logs --previous` es imprescindible en un `CrashLoopBackOff` y qué verías si omitieras la bandera?
3. Distinguí los tres motivos de terminación que un platform engineer debe reconocer de inmediato: `Error`, `OOMKilled` y `Completed`. ¿Cuál de ellos apuntaría a un problema de `resources.limits` y no a un bug de código?

---

## Ejercicio 4 — Remediación táctica: *stop the bleeding*

Regla SRE: **mitigá primero, investigá la causa raíz después.** En un incidente en curso, restaurar el servicio tiene prioridad sobre entender por qué falló.

1. La causa es un *bad deploy*; el antídoto más rápido y seguro es volver a la última revisión sana. Inspeccioná el historial:
   ```bash
   kubectl -n shop rollout history deploy/checkout
   ```
   ```
   REVISION  CHANGE-CAUSE
   1         <none>
   2         <none>
   ```

2. Ejecutá el **rollback** a la revisión 1 (tu known-good):
   ```bash
   kubectl -n shop rollout undo deploy/checkout --to-revision=1
   ```
   ```
   deployment.apps/checkout rolled back
   ```

3. Verificá la recuperación con evidencia, no por fe:
   ```bash
   kubectl -n shop rollout status deploy/checkout
   kubectl -n shop get pods -l app=checkout
   ```
   ```
   deployment "checkout" successfully rolled out
   NAME                        READY   STATUS    RESTARTS   AGE
   checkout-7c9f8b6d54-2xk9p   1/1     Running   0          20m
   checkout-7c9f8b6d54-9jf2l   1/1     Running   0          20m
   checkout-7c9f8b6d54-dp4rt   1/1     Running   0          20m
   checkout-7c9f8b6d54-kk7bx   1/1     Running   0          25s
   checkout-7c9f8b6d54-r2m9d   1/1     Running   0          25s
   ```

4. Ahora simulá un **segundo incidente** de naturaleza distinta (fallo #1, presión de memoria). Forzá OOM reduciendo aún más el límite y metiendo carga:
   ```bash
   kubectl -n shop set resources deploy/checkout \
     --limits=memory=24Mi --requests=memory=16Mi
   kubectl -n shop get pods -l app=checkout -w
   ```
   Verás:
   ```
   checkout-5f7c9d8b64-abc12   0/1   OOMKilled   1   15s
   checkout-5f7c9d8b64-abc12   0/1   CrashLoopBackOff   2   40s
   ```

5. Este fallo **no** es un bad deploy: es un límite mal dimensionado. El rollback no aplica. La remediación táctica correcta es corregir el recurso:
   ```bash
   kubectl -n shop set resources deploy/checkout \
     --limits=memory=128Mi --requests=memory=64Mi
   kubectl -n shop rollout status deploy/checkout
   ```

6. Cuando un *nodo* completo está enfermo (disco, kernel, hardware), la remediación no es sobre pods sino sobre el nodo. Practicá el patrón *cordon + drain* (en un cluster real de varios nodos):
   ```bash
   # 1) marcar el nodo como no-schedulable (deja de recibir pods nuevos)
   kubectl cordon <node-name>
   # 2) evacuar respetando PodDisruptionBudgets, ignorando DaemonSets
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   # 3) tras la reparación, reincorporarlo
   kubectl uncordon <node-name>
   ```

**Preguntas de verificación — Bloque 4**

1. `rollout undo` fue correcto para el incidente del Bloque 3 pero **incorrecto** para el OOMKill del paso 4. Explicá el principio: ¿por qué la remediación debe corresponderse con la *clase* de causa raíz y no ser un reflejo único?
2. ¿Qué hace `kubectl cordon` que `kubectl drain` no hace, y por qué el orden `cordon → drain` importa? ¿Qué rol juega el `PodDisruptionBudget` durante el `drain`?
3. Definí **MTTR** y explicá cómo un rollback preparado de antemano (Bloque 1) lo reduce frente a tener que hotfixear código en caliente durante el incidente.

---

## Ejercicio 5 — Remediación declarativa vía GitOps

En una plataforma madura, `kubectl` en caliente es la excepción. El estado deseado vive en Git; la remediación es un revert de commit y la máquina converge sola. Esto elimina el *drift* que dejan las correcciones manuales.

1. (Si tenés Argo CD) Instalalo:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Definí la `Application` con **auto-heal** activado. Este es el guardrail que revierte cambios manuales fuera de banda:
   ```yaml
   # checkout-app.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: checkout
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://git.internal/shop/checkout-config.git
       targetRevision: main
       path: deploy/overlays/prod
     destination:
       server: https://kubernetes.default.svc
       namespace: shop
     syncPolicy:
       automated:
         prune: true          # borra recursos que ya no están en Git
         selfHeal: true       # revierte drift respecto al estado en Git
       retry:
         limit: 5
         backoff:
           duration: 10s
           factor: 2
           maxDuration: 3m
   ```
   ```bash
   kubectl apply -f checkout-app.yaml
   ```

3. Simulá *config drift* — alguien "arregla" algo a mano en producción durante un incidente:
   ```bash
   kubectl -n shop scale deploy/checkout --replicas=1
   ```

4. Observá cómo Argo CD detecta el `OutOfSync` y, con `selfHeal`, lo revierte al estado de Git:
   ```bash
   kubectl -n argocd get application checkout \
     -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
   ```
   ```
   Synced / Healthy
   ```
   (transitoriamente habrás visto `OutOfSync` antes de que reconcilie a 4 réplicas.)

5. Ahora la remediación GitOps de un bad deploy: en vez de `rollout undo`, se revierte el commit que subió `1.5.0-broken`:
   ```bash
   # en el repo de config
   git revert <sha-del-bump-a-1.5.0-broken>
   git push origin main
   # Argo CD sincroniza main y el cluster vuelve a la imagen sana, con auditoría en el historial de Git
   ```

**Preguntas de verificación — Bloque 5**

1. Un `kubectl rollout undo` (Bloque 4) y un `git revert` (este bloque) recuperan el servicio. Con `selfHeal: true` activo, ¿por qué el `rollout undo` manual sería revertido por Argo CD y por qué eso es *deseable* en incident response?
2. ¿Qué diferencia hay entre `prune: true` y `selfHeal: true`? Dá un ejemplo de incidente que cada uno remedia.
3. GitOps convierte cada remediación en un artefacto auditable. ¿Cómo alimenta esto directamente el *timeline* del post-mortem del Ejercicio 7?

---

## Ejercicio 6 — Automatizar el runbook y poner guardrails

Un runbook ejecutado a mano a las 3 AM es propenso a error. Convertí la respuesta en algo verificable y protegé la plataforma para que el próximo incidente sea menos grave.

1. Añadí un `PodDisruptionBudget`: garantiza que ni un `drain` ni un rollout puedan dejar `checkout` por debajo de capacidad mínima. Es un guardrail que limita el blast radius de *toda* operación futura:
   ```yaml
   # checkout-pdb.yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: checkout
     namespace: shop
   spec:
     minAvailable: 3        # nunca menos de 3 pods disponibles simultáneamente
     selector:
       matchLabels:
         app: checkout
   ```
   ```bash
   kubectl apply -f checkout-pdb.yaml
   kubectl -n shop get pdb checkout
   ```
   ```
   NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
   checkout   3               N/A               1                     5s
   ```

2. Escribí el runbook como un script idempotente y verificable, no como prosa. Cada paso comprueba su propio resultado:
   ```bash
   #!/usr/bin/env bash
   # runbook: checkout-bad-deploy-rollback.sh
   set -euo pipefail
   NS=shop; DEP=checkout

   echo "[1/3] Confirmando síntoma (pods no-Ready)..."
   NOT_READY=$(kubectl -n "$NS" get pods -l app=$DEP \
     -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
     | grep -c false || true)
   echo "    pods no-Ready: $NOT_READY"

   echo "[2/3] Ejecutando rollback a la revisión previa..."
   kubectl -n "$NS" rollout undo deploy/$DEP

   echo "[3/3] Verificando recuperación..."
   kubectl -n "$NS" rollout status deploy/$DEP --timeout=120s
   echo "OK: servicio restaurado"
   ```

3. Cerrá el loop de detección → acción con una `livenessProbe` bien calibrada, para que Kubernetes auto-remedie un cuelgue sin intervención humana. Verificá que la que ya pusiste en el Ejercicio 1 tiene `failureThreshold` y `periodSeconds` que no reinicien en falsos positivos durante picos de latencia.

**Preguntas de verificación — Bloque 6**

1. Con `minAvailable: 3` sobre un deployment de 4 réplicas, ¿cuántas disrupciones voluntarias permite el PDB a la vez? ¿Qué pasa si intentás `drain` de dos nodos que juntos alojan 3 de los 4 pods?
2. ¿Por qué un runbook *idempotente* y con verificación de cada paso es superior a uno en prosa durante un incidente real? Relacionalo con reducir MTTR y error humano.
3. Un `PodDisruptionBudget` mal configurado (`minAvailable` igual al total de réplicas) puede convertirse *él mismo* en la causa de un incidente. Explicá cómo bloquearía un `drain` legítimo.

---

## Ejercicio 7 — Post-incident: timeline y post-mortem blameless

El incidente no termina cuando el servicio se recupera, sino cuando aprendiste de él. La cultura *blameless* es lo que hace que la gente reporte errores en vez de esconderlos.

1. Reconstruí el *timeline* con timestamps objetivos. Los eventos de Kubernetes y el historial de Git (Ejercicio 5) son tus fuentes de verdad:
   ```bash
   kubectl -n shop get events --sort-by=.lastTimestamp \
     --field-selector involvedObject.name=checkout
   ```

2. Completá esta plantilla de post-mortem con los datos de los ejercicios anteriores:
   ```markdown
   # Post-mortem: checkout 5xx burn — 2026-08-07

   ## Resumen
   Un release defectuoso (checkout:1.5.0-broken) falló la migración de schema,
   provocando CrashLoopBackOff en 2/4 réplicas y quema de error budget.

   ## Impacto
   - Duración: T0 (deploy) → T+8min (rollback confirmado)
   - Blast radius: 2 de 4 réplicas; RollingUpdate protegió disponibilidad parcial.
   - Error budget consumido: __% de la ventana de 30 días.

   ## Timeline (UTC)
   - T0     — `kubectl set image` a 1.5.0-broken
   - T+2m   — alerta CheckoutErrorBudgetFastBurn (severity=page)
   - T+4m   — triage: P2, capacidad parcial sana
   - T+5m   — diagnóstico: config schema migration failed (logs --previous)
   - T+6m   — `rollout undo --to-revision=1`
   - T+8m   — rollout status: recuperado

   ## Causa raíz
   El release omitió el paso de migración de config; CI no ejecuta el arranque
   contra la config de prod.

   ## Qué funcionó
   - RollingUpdate + maxUnavailable:1 contuvo el blast radius.
   - Rollback preparado (revisionHistoryLimit) → MTTR bajo.

   ## Action items (con dueño y fecha)
   - [ ] Añadir smoke-test de arranque contra config de prod en CI — @owner, +7d
   - [ ] Progressive delivery (canary) para checkout — @owner, +14d
   - [ ] Automatizar el runbook de rollback en el pipeline — @owner, +7d
   ```

3. Clasificá cada action item por su tipo de defensa en profundidad: **prevención** (evita que vuelva a ocurrir), **detección** (lo detecta antes/más rápido) o **mitigación** (reduce el impacto cuando ocurra).

**Preguntas de verificación — Bloque 7**

1. ¿Qué significa *blameless* en un post-mortem y por qué culpar a la persona que hizo `set image` degrada la fiabilidad de la plataforma a largo plazo?
2. Distinguí **causa raíz** de **factores contribuyentes**. En el incidente, ¿fue la causa raíz "el deploy" o "la ausencia de un smoke-test contra la config de prod"?
3. Clasificá los tres action items del post-mortem en prevención / detección / mitigación. ¿Por qué un buen post-mortem debe producir al menos uno de cada tipo?

---

<details>
<summary><strong>Respuestas — soluciones y explicaciones</strong></summary>

### Bloque 1

1. **`revisionHistoryLimit`** define cuántas `ReplicaSet` antiguas conserva Kubernetes. Si es `0`, `kubectl rollout undo` no tiene a qué volver: perdés tu vía de remediación más rápida ante un bad deploy. Mantener ≥10 revisiones es una decisión de *incident readiness* — el rollback existe solo si el historial existe.
2. La **`readinessProbe`** saca al pod del `Endpoints` del Service cuando falla: protege a los **usuarios**, porque el tráfico deja de enrutarse a un pod que devolvería errores (no lo reinicia). La **`livenessProbe`** **reinicia** el contenedor cuando se cuelga: recupera un proceso trabado. Regla: readiness = "¿puedo recibir tráfico?", liveness = "¿estoy vivo o hay que matarme?".
3. El **known-good state** es la configuración/imagen/revisión verificada como sana. Registrarlo antes reduce el **MTTR** porque durante el incidente no perdés tiempo averiguando "¿a qué versión vuelvo?": ya tenés el número de revisión y la evidencia de que funcionaba.

### Bloque 2

1. El error budget es 0.5% de la ventana de 30 días. El multiplicador **14.4** es el *burn rate*: quemar el presupuesto 14.4x más rápido de lo sostenible consume el budget de 30 días en ~2 días — umbral clásico de la ventana de 1h del enfoque **multi-window multi-burn-rate** (Google SRE Workbook). Se usa multi-ventana (p. ej. 5m + 1h) para exigir que la quema sea rápida **y** sostenida: así evitás paginar por un pico transitorio de 5xx (poca ventana) y evitás perder una degradación lenta (mucha ventana). Alertar ante el primer 5xx genera fatiga de alertas.
2. `maxUnavailable: 1` obliga al `RollingUpdate` a no bajar nunca más de 1 pod por debajo del deseado; por eso quedó `AVAILABLE 3`. Los pods nuevos y defectuosos nunca pasan la readiness, así que **no reciben tráfico**, y los viejos sanos siguen sirviendo. El *blast radius* queda acotado a "sin capacidad plena" en lugar de "caída total": el diseño degradó la severidad antes del incidente.
3. El **síntoma** es lo observable (5xx, rollout atascado, alerta). La **causa raíz** es el mecanismo subyacente (la migración de schema fallida). En la fase de **remediación táctica** se ataca primero el **síntoma/impacto** (restaurar servicio con un rollback), porque el objetivo inmediato es dejar de quemar error budget; la causa raíz se corrige después, en calma.

### Bloque 3

1. Secuencia: contenedor arranca → el proceso sale con error (o la probe falla) → `kubelet` lo reinicia → vuelve a fallar → `kubelet` aplica **back-off exponencial** (10s, 20s, 40s… hasta 5min tope) antes de cada reintento → estado `CrashLoopBackOff`. Los `RESTARTS` **no crecen instantáneamente** justamente por ese back-off: entre reinicios hay una espera creciente, para no martillar el sistema.
2. En `CrashLoopBackOff` el contenedor "actual" acaba de arrancar (o está en back-off), así que `kubectl logs` sin bandera muestra poco o nada útil. **`--previous`** muestra los logs del contenedor **que ya murió** — donde está el error real (`config schema migration failed`). Sin la bandera perderías la línea `fatal` que da el diagnóstico.
3. `Error` = el proceso salió con código ≠ 0 → típicamente **bug de código/config**. `OOMKilled` = el kernel mató el contenedor por exceder `resources.limits.memory` → problema de **límites/dimensionamiento**. `Completed` = salió con código 0, esperado en Jobs. El que apunta a `resources.limits` es **`OOMKilled`**.

### Bloque 4

1. Cada clase de causa raíz tiene su antídoto. El Bloque 3 era un **bad deploy** → `rollout undo` restaura la versión sana. El OOMKill del paso 4 es un **límite mal dimensionado**: revertir el deploy no cambia el límite, seguiría muriendo. El principio: la remediación debe **corresponderse con la clase de causa** (deploy → rollback; recurso → reajuste; nodo → cordon/drain). Aplicar el mismo reflejo a todo alarga el incidente.
2. **`cordon`** marca el nodo como `SchedulingDisabled`: deja de **recibir pods nuevos**, pero **no** desaloja los existentes. **`drain`** además **evacúa** los pods actuales. El orden importa: cordon primero evita que un pod recién evacuado sea re-agendado en el mismo nodo enfermo. Durante el `drain`, el **`PodDisruptionBudget`** frena la evacuación si desalojar violaría `minAvailable` — el drain espera en vez de romper disponibilidad.
3. **MTTR** = *Mean Time To Recovery*, tiempo medio desde la detección hasta la restauración del servicio. Un rollback preparado (historial de revisiones + known-good conocido) lo reduce porque la recuperación es un solo comando determinista (`rollout undo`), en segundos, frente a escribir/probar/desplegar un hotfix en caliente, que puede tomar decenas de minutos y arriesga introducir un segundo fallo.

### Bloque 5

1. Con `selfHeal: true`, Argo CD reconcilia continuamente el cluster contra Git. Un `rollout undo` manual crea **drift** (el cluster deja de coincidir con Git), así que Argo CD lo revertiría y re-desplegaría la imagen de Git — incluso la rota. Esto es **deseable** porque fuerza a que la remediación pase por Git (`git revert`): así queda **auditada, revisable y reproducible**, y no hay "arreglos fantasma" que se pierdan en el próximo sync.
2. **`prune: true`** borra del cluster los recursos que ya no existen en Git (remedia recursos huérfanos/zombis). **`selfHeal: true`** revierte modificaciones a recursos que *sí* existen en Git pero difieren (remedia drift de config, p. ej. alguien escaló a mano). Ejemplo prune: un `Service` viejo que quedó tras renombrar. Ejemplo selfHeal: el `scale --replicas=1` del paso 3.
3. Cada remediación es un commit con autor, timestamp y mensaje. Ese historial de Git **es** el timeline auditable: quién cambió qué y cuándo, sin reconstruirlo de memoria. Alimenta directamente la sección *Timeline* del post-mortem con datos objetivos.

### Bloque 6

1. `minAvailable: 3` sobre 4 réplicas → **1 disrupción voluntaria** permitida a la vez (`ALLOWED DISRUPTIONS: 1`). Si intentás `drain` de dos nodos que juntos alojan 3 de los 4 pods, el segundo `drain` **se bloquea** (espera) porque completarlo dejaría solo 1 pod disponible, violando `minAvailable: 3`. El PDB protege la capacidad mínima.
2. Un runbook **idempotente y verificado** se puede re-ejecutar sin efectos colaterales y cada paso confirma su resultado, así que a las 3 AM y con estrés no dependés de recordar el orden ni de interpretar prosa ambigua. Reduce **MTTR** (acción rápida y repetible) y **error humano** (menos decisiones ad-hoc). La prosa hay que leerla, interpretarla y ejecutarla a mano — tres puntos de fallo.
3. Si `minAvailable` = total de réplicas (p. ej. 4 de 4), el PDB permite **0 disrupciones**. Cualquier `drain` legítimo (mantenimiento, upgrade de nodo) se **bloquea indefinidamente**, porque evacuar cualquier pod violaría el presupuesto. El guardrail se vuelve el incidente: usá siempre `minAvailable < réplicas` (o `maxUnavailable`).

### Bloque 7

1. **Blameless** significa que el post-mortem analiza *sistemas y procesos*, no personas: se asume que quien actuó lo hizo razonablemente con la información que tenía. Culpar a quien hizo `set image` hace que la gente **oculte errores y contexto** por miedo, lo que degrada la fiabilidad: perdés la información necesaria para arreglar el sistema. La pregunta correcta no es "¿quién?" sino "¿qué permitió que un error humano llegara a producción?".
2. La **causa raíz** es la condición sistémica cuya corrección evita la recurrencia; los **factores contribuyentes** empeoran o facilitan el incidente pero no son la raíz. Aquí la causa raíz es **la ausencia de un smoke-test de arranque contra la config de prod en CI** (que dejó pasar un release que no podía migrar el schema). "El deploy" fue el disparador; el bug de migración, un factor contribuyente.
3. Clasificación: *smoke-test en CI* = **prevención** (evita que el release roto llegue a prod); *canary / progressive delivery* = **mitigación** (si vuelve a pasar, afecta a un % chico antes de propagar) — y también aporta **detección** temprana; *automatizar el runbook de rollback* = **mitigación** (reduce MTTR). Un buen post-mortem produce items de los tres tipos porque ninguna capa es infalible: **prevención** reduce frecuencia, **detección** reduce tiempo de descubrimiento, **mitigación** reduce impacto — defensa en profundidad.

</details>