# Ejercicios: 4.3 — Understand requests, limits, quotas (CKAD v1.35)

> Prerrequisito: un cluster de Kubernetes accesible (`kind`, `minikube` o similar) con `kubectl` configurado, y `metrics-server` instalado si querés usar `kubectl top`.

## Ejercicio 1 — Namespace de trabajo, requests/limits y QoS class

1. Creá un namespace dedicado para los ejercicios:
   ```bash
   kubectl create namespace res-quiz
   ```

2. Creá un manifiesto `pod-guaranteed.yaml` con un Pod cuyo container defina `requests` y `limits` **iguales** para `cpu` y `memory`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-guaranteed
     namespace: res-quiz
   spec:
     containers:
     - name: app
       image: nginx
       resources:
         requests:
           cpu: "200m"
           memory: "128Mi"
         limits:
           cpu: "200m"
           memory: "128Mi"
   ```
   Aplicalo:
   ```bash
   kubectl apply -f pod-guaranteed.yaml
   ```

3. Inspeccioná la QoS class asignada:
   ```bash
   kubectl get pod pod-guaranteed -n res-quiz -o jsonpath='{.status.qosClass}'
   ```

4. Creá un segundo Pod, `pod-burstable.yaml`, con `requests` **menores** que `limits`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-burstable
     namespace: res-quiz
   spec:
     containers:
     - name: app
       image: nginx
       resources:
         requests:
           cpu: "100m"
           memory: "64Mi"
         limits:
           cpu: "300m"
           memory: "256Mi"
   ```
   Aplicalo y consultá su `qosClass` con el mismo comando del paso 3.

5. Creá un tercer Pod, `pod-besteffort.yaml`, **sin** bloque `resources`, y consultá su `qosClass`.

**Preguntas de verificación:**
- ¿Qué QoS class obtuvo cada uno de los tres Pods y por qué esa combinación de `requests`/`limits` produce esa clase?
- Si el nodo entra en presión de memoria (`memory pressure`) y el kubelet necesita desalojar Pods, ¿en qué orden los desalojaría entre estos tres?

---

## Ejercicio 2 — Exceder el límite de memory: OOMKilled

1. Creá `pod-oom.yaml`, un Pod que fuerce el uso de más memoria que su `limit`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-oom
     namespace: res-quiz
   spec:
     containers:
     - name: stress
       image: polinux/stress
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
       resources:
         requests:
           memory: "50Mi"
         limits:
           memory: "100Mi"
   ```
   Aplicalo:
   ```bash
   kubectl apply -f pod-oom.yaml
   ```

2. Esperá unos segundos y describí el Pod:
   ```bash
   kubectl describe pod pod-oom -n res-quiz
   ```

3. Revisá el campo `lastState.terminated.reason` del container:
   ```bash
   kubectl get pod pod-oom -n res-quiz -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
   ```

**Preguntas de verificación:**
- ¿Qué `reason` aparece en `lastState.terminated` y qué `exit code` está asociado a esa condición?
- ¿Qué diferencia de comportamiento hay entre exceder el `limit` de `memory` (paso 1) y exceder el `limit` de `cpu`? ¿Por qué el kubelet mata el container en un caso y no en el otro?

---

## Ejercicio 3 — LimitRange: valores por defecto y rangos permitidos

1. Creá `limitrange.yaml` en el namespace `res-quiz`:
   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: default-limits
     namespace: res-quiz
   spec:
     limits:
     - type: Container
       default:
         cpu: "250m"
         memory: "256Mi"
       defaultRequest:
         cpu: "100m"
         memory: "128Mi"
       min:
         cpu: "50m"
       max:
         cpu: "500m"
   ```
   Aplicalo:
   ```bash
   kubectl apply -f limitrange.yaml
   ```

2. Creá un Pod **sin** bloque `resources`, en el mismo namespace:
   ```bash
   kubectl run pod-sin-recursos --image=nginx -n res-quiz
   ```

3. Inspeccioná qué `requests`/`limits` terminó teniendo el container:
   ```bash
   kubectl get pod pod-sin-recursos -n res-quiz -o jsonpath='{.spec.containers[0].resources}'
   ```

4. Intentá crear un Pod que pida `cpu: "800m"` (por encima del `max` definido):
   ```bash
   kubectl run pod-excede-max --image=nginx -n res-quiz \
     --overrides='{"spec":{"containers":[{"name":"pod-excede-max","image":"nginx","resources":{"requests":{"cpu":"800m"},"limits":{"cpu":"800m"}}}]}}'
   ```

**Preguntas de verificación:**
- ¿De dónde salieron los valores de `requests`/`limits` que quedaron asignados al Pod del paso 2, si el manifiesto original no los especificaba?
- ¿Qué mensaje de error devuelve el paso 4, y qué objeto del API es responsable de rechazar la creación?

---

## Ejercicio 4 — ResourceQuota a nivel de namespace

1. Creá `resourcequota.yaml`:
   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: res-quiz-quota
     namespace: res-quiz
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: "1Gi"
       limits.cpu: "2"
       limits.memory: "2Gi"
       pods: "5"
   ```
   Aplicalo:
   ```bash
   kubectl apply -f resourcequota.yaml
   ```

2. Consultá el uso actual contra la quota:
   ```bash
   kubectl describe resourcequota res-quiz-quota -n res-quiz
   ```

3. Intentá crear un nuevo Pod **sin** bloque `resources` explícito (asumiendo que ya eliminaste el `LimitRange` del ejercicio 3, o dejalo si querés ver la interacción entre ambos):
   ```bash
   kubectl run pod-sin-quota --image=nginx -n res-quiz
   ```

4. Observá qué ocurre si el namespace tiene un `ResourceQuota` pero el Pod que intentás crear no trae `requests`/`limits` y **no** hay `LimitRange`:
   ```bash
   kubectl delete limitrange default-limits -n res-quiz
   kubectl run pod-sin-requests --image=nginx -n res-quiz
   ```

**Preguntas de verificación:**
- ¿Por qué el paso 4 falla (o tiene comportamiento distinto) cuando existe un `ResourceQuota` que incluye `requests.cpu`/`requests.memory` pero no hay `LimitRange` que asigne valores por defecto?
- ¿Qué diferencia hay entre una `ResourceQuota` y un `LimitRange` en cuanto al alcance (¿namespace completo vs. por objeto individual?) de lo que restringen?

---

## Ejercicio 5 — Diagnóstico con `kubectl top`

1. Instalá o verificá que `metrics-server` esté corriendo:
   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```

2. Consultá el consumo real de recursos por Pod en el namespace:
   ```bash
   kubectl top pods -n res-quiz
   ```

3. Consultá el consumo por nodo:
   ```bash
   kubectl top nodes
   ```

4. Compará el valor de `cpu`/`memory` reportado por `kubectl top` para `pod-guaranteed` contra el `request` definido en su manifiesto original (Ejercicio 1, paso 2).

**Preguntas de verificación:**
- ¿`kubectl top` muestra uso real instantáneo o los valores configurados de `requests`/`limits`? ¿Qué componente del cluster provee estos datos?
- Si un Pod muestra un uso de `cpu` muy por encima de su `request` pero por debajo de su `limit`, ¿es eso un problema? ¿Y si supera el `limit` de `cpu`?

---

## Limpieza

```bash
kubectl delete namespace res-quiz
```

---

**Fuente de referencia:** CNCF, *CKAD Curriculum v1.35* — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1:**
- `pod-guaranteed`: QoS **Guaranteed**, porque `requests == limits` para **cpu y memory** en **todos** los containers del Pod. `pod-burstable`: QoS **Burstable**, porque tiene `requests` y `limits` definidos pero no son iguales (o falta alguno de los dos recursos). `pod-besteffort`: QoS **BestEffort**, porque no define `requests` ni `limits` en ningún recurso.
- Ante presión de memoria, el kubelet desaloja primero los Pods **BestEffort**, luego los **Burstable** (priorizando los que más exceden su `request`), y por último los **Guaranteed** (solo se desalojan si el propio nodo está en riesgo, ya que se asume que no exceden lo que reservaron).

**Ejercicio 2:**
- El `reason` es `OOMKilled`, con `exitCode: 137` (128 + señal SIGKILL/9). Esto ocurre porque el kernel de Linux, a través de cgroups, mata al proceso cuando excede el `limit` de memoria asignado.
- La memoria es un recurso **no compresible**: si el container excede el `limit`, el kernel lo mata (OOMKilled). El cpu es un recurso **compresible**: si el container excede su `limit` de cpu, el kernel simplemente lo *throttlea* (le reduce el tiempo de CPU asignado vía CFS quota), sin terminar el proceso.

**Ejercicio 3:**
- Salieron del `LimitRange`: como el Pod no especificó `resources`, el admission controller `LimitRanger` le aplicó `defaultRequest` (`cpu: 100m`, `memory: 128Mi`) como `requests` y `default` (`cpu: 250m`, `memory: 256Mi`) como `limits`.
- El API server rechaza la creación con un error tipo `is forbidden: maximum cpu usage per Container is 500m, but limit is 800m` (o similar), generado por el admission controller `LimitRanger` al validar contra el `max` definido en el `LimitRange`.

**Ejercicio 4:**
- Falla porque cuando un namespace tiene una `ResourceQuota` que incluye `requests.cpu` o `requests.memory` (o sus equivalentes de `limits`), el API server exige que **todo** Pod creado en ese namespace especifique explícitamente `requests`/`limits` para esos recursos. Sin un `LimitRange` que los complete automáticamente, el Pod es rechazado con un error como `must specify cpu, memory`.
- `ResourceQuota` limita el **total agregado** de recursos consumibles (y la cantidad de objetos) dentro de todo el namespace; `LimitRange` actúa **por objeto individual** (Pod o Container), definiendo mínimos, máximos y valores por defecto para cada uno, sin importar cuántos objetos existan en total.

**Ejercicio 5:**
- `kubectl top` muestra el **uso real instantáneo** de cpu/memory, obtenido a partir de las métricas que expone el **metrics-server** (que a su vez las recolecta del `cAdvisor`/kubelet de cada nodo). No refleja los valores configurados de `requests`/`limits`, sino el consumo efectivo en ese momento.
- Un uso de cpu por encima del `request` pero por debajo del `limit` es normal y esperado (el `request` es solo lo garantizado, no un techo); no es un problema en sí. Superar el `limit` de cpu no mata al container, pero provoca *throttling*, lo que puede degradar el rendimiento observable de la aplicación.

</details>