# Ejercicios guiados — 4.4 Define resource requirements

> **Requisitos previos:** un cluster de práctica (minikube, kind o similar) y `kubectl` configurado. Para el Ejercicio 3 conviene tener `metrics-server` instalado (en minikube: `minikube addons enable metrics-server`), aunque no es obligatorio.

---

## Ejercicio 1 — Requests y limits básicos

Un container puede declarar cuántos recursos **pide** (`requests`) y cuánto es lo **máximo** que puede usar (`limits`). El scheduler usa los `requests` para decidir en qué node ubicar el Pod; los `limits` los aplica el kubelet en tiempo de ejecución.

1. Creá un namespace de trabajo para no ensuciar el cluster:

   ```bash
   kubectl create namespace recursos
   kubectl config set-context --current --namespace=recursos
   ```

2. Creá el archivo `pod-recursos.yaml` con un Pod que declara requests y limits:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: app-medida
   spec:
     containers:
     - name: web
       image: nginx:1.27
       resources:
         requests:
           cpu: "250m"
           memory: "64Mi"
         limits:
           cpu: "500m"
           memory: "128Mi"
   ```

3. Aplicalo y verificá que quedó `Running`:

   ```bash
   kubectl apply -f pod-recursos.yaml
   kubectl get pod app-medida
   ```

4. Inspeccioná cómo quedaron registrados los recursos:

   ```bash
   kubectl describe pod app-medida | grep -A 6 "Limits\|Requests"
   ```

5. Miralo también en el node: buscá la sección **Allocated resources** para ver cuánto de la capacidad del node está comprometida por requests:

   ```bash
   kubectl describe node $(kubectl get pod app-medida -o jsonpath='{.spec.nodeName}') | grep -A 8 "Allocated resources"
   ```

**Preguntas**

1. ¿Qué significa exactamente `cpu: "250m"`? ¿Y cuál es la diferencia entre `64Mi` y `64M`?
2. Si el container de `app-medida` intenta usar `600m` de CPU sostenidos, ¿qué le pasa? ¿Y si intenta usar `200Mi` de memoria?
3. ¿Cuál de los dos valores (`requests` o `limits`) usa el scheduler para elegir node?

---

## Ejercicio 2 — Las tres clases de QoS

Según cómo declares recursos, Kubernetes asigna al Pod una **QoS class** (`Guaranteed`, `Burstable` o `BestEffort`) que determina el orden de eviction cuando el node se queda sin memoria.

1. Creá un Pod **sin ninguna** declaración de recursos:

   ```bash
   kubectl run sin-recursos --image=nginx:1.27
   ```

2. Creá el archivo `pod-garantizado.yaml`, donde `requests` y `limits` son **idénticos** en CPU y memoria:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: garantizado
   spec:
     containers:
     - name: web
       image: nginx:1.27
       resources:
         requests:
           cpu: "200m"
           memory: "100Mi"
         limits:
           cpu: "200m"
           memory: "100Mi"
   ```

   ```bash
   kubectl apply -f pod-garantizado.yaml
   ```

3. Consultá la QoS class de los tres Pods que tenés hasta ahora:

   ```bash
   kubectl get pods -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass'
   ```

4. Verificá que un solo campo alcanza para cambiar de clase: agregale a `sin-recursos` un request por vía imperativa y mirá que el cambio exige recrear el Pod (los recursos de un Pod "suelto" no se pueden editar en vivo, salvo que el cluster tenga habilitado el resize in-place):

   ```bash
   kubectl delete pod sin-recursos
   kubectl run sin-recursos --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"sin-recursos","image":"nginx:1.27","resources":{"requests":{"memory":"32Mi"}}}]}}'
   kubectl get pod sin-recursos -o jsonpath='{.status.qosClass}{"\n"}'
   ```

**Preguntas**

4. Escribí la regla que define cada una de las tres QoS classes.
5. Si el node entra en presión de memoria, ¿en qué orden tienden a ser evicted los Pods según su QoS class?
6. Un Pod declara `requests` y `limits` iguales para memoria, pero solo `requests` (sin `limits`) para CPU. ¿Qué QoS class recibe?

---

## Ejercicio 3 — Qué pasa cuando se excede el limit: OOMKilled vs throttling

CPU y memoria se comportan distinto al superar el limit: la CPU es **compresible** (se estrangula) y la memoria **no** (el proceso muere).

1. Creá el archivo `pod-glotón.yaml` con un container que intenta reservar más memoria que su limit:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: gloton
   spec:
     containers:
     - name: stress
       image: polinux/stress
       command: ["stress"]
       args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
       resources:
         requests:
           memory: "50Mi"
         limits:
           memory: "100Mi"
   ```

2. Aplicalo y observá el estado durante un minuto:

   ```bash
   kubectl apply -f pod-glotón.yaml
   kubectl get pod gloton --watch
   ```

   Vas a ver el Pod pasar por `OOMKilled` y `CrashLoopBackOff` a medida que el kubelet lo reinicia.

3. Confirmá la causa exacta de la última terminación:

   ```bash
   kubectl describe pod gloton | grep -A 3 "Last State"
   kubectl get pod gloton -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
   ```

4. Si tenés `metrics-server`, comprobá el consumo real de los Pods sanos del namespace:

   ```bash
   kubectl top pod
   ```

5. Limpiá el Pod que está en crash loop:

   ```bash
   kubectl delete pod gloton
   ```

**Preguntas**

7. ¿Qué `reason` y qué `exit code` reporta el container terminado por exceso de memoria?
8. ¿Por qué el Pod entra en `CrashLoopBackOff` en lugar de quedar muerto de una vez?
9. Si en lugar de memoria el container excediera su limit de **CPU**, ¿el kubelet también lo mataría? Justificá.

---

## Ejercicio 4 — Requests imposibles: el Pod queda Pending

Si ningún node tiene capacidad **libre según requests** para alojar el Pod, el scheduler no lo ubica y el Pod queda `Pending`. Esto es una pregunta clásica de troubleshooting en el examen.

1. Creá el archivo `pod-imposible.yaml` pidiendo una CPU absurda:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: imposible
   spec:
     containers:
     - name: web
       image: nginx:1.27
       resources:
         requests:
           cpu: "64"
   ```

2. Aplicalo y mirá su estado:

   ```bash
   kubectl apply -f pod-imposible.yaml
   kubectl get pod imposible
   ```

3. Diagnosticá el motivo con `describe` — fijate en los **Events** del final:

   ```bash
   kubectl describe pod imposible
   ```

   Deberías ver un evento `FailedScheduling` con un mensaje del estilo `Insufficient cpu`.

4. Corregí el Pod bajando el request a algo razonable. Como `spec.containers[].resources` de un Pod existente no es editable (en clusters sin resize in-place), reemplazalo:

   ```bash
   kubectl get pod imposible -o yaml > imposible-fix.yaml
   # editá imposible-fix.yaml: cambiá cpu: "64" por cpu: "100m"
   kubectl replace --force -f imposible-fix.yaml
   kubectl get pod imposible
   ```

5. Para Deployments el flujo es más simple y es el que conviene en el examen:

   ```bash
   kubectl create deployment api --image=nginx:1.27 --replicas=2
   kubectl set resources deployment api --requests=cpu=100m,memory=64Mi --limits=cpu=250m,memory=128Mi
   kubectl get pods -l app=api -o custom-columns='NAME:.metadata.name,CPU-REQ:.spec.containers[0].resources.requests.cpu'
   ```

**Preguntas**

10. Un Pod está `Pending` y `describe` muestra `0/3 nodes are available: 3 Insufficient memory`. Nombrá dos maneras válidas de destrabarlo.
11. ¿Por qué un Pod puede quedar `Pending` por requests aunque el uso **real** de los nodes sea bajo?
12. ¿Qué hace `kubectl set resources` sobre un Deployment: edita los Pods existentes o crea Pods nuevos? ¿Por qué?

---

## Ejercicio 5 — Defaults y topes por namespace: LimitRange y ResourceQuota

En un namespace compartido, el administrador puede imponer defaults y máximos por container (`LimitRange`) y un presupuesto agregado (`ResourceQuota`). Como developer, tenés que saber leerlos y convivir con ellos.

1. Creá el archivo `politicas.yaml` con ambos objetos:

   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: defaults-container
     namespace: recursos
   spec:
     limits:
     - type: Container
       default:            # limit que se asigna si el container no declara uno
         cpu: "500m"
         memory: "256Mi"
       defaultRequest:     # request que se asigna si el container no declara uno
         cpu: "100m"
         memory: "64Mi"
       max:
         cpu: "1"
         memory: "512Mi"
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: presupuesto
     namespace: recursos
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: "1Gi"
       limits.cpu: "2"
       limits.memory: "2Gi"
       pods: "10"
   ```

   ```bash
   kubectl apply -f politicas.yaml
   ```

2. Creá un Pod **sin declarar recursos** y mirá qué le asignó el LimitRange:

   ```bash
   kubectl run heredero --image=nginx:1.27
   kubectl get pod heredero -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
   ```

3. Intentá violar el `max` del LimitRange y leé el error:

   ```bash
   kubectl run excesivo --image=nginx:1.27 \
     --overrides='{"spec":{"containers":[{"name":"excesivo","image":"nginx:1.27","resources":{"limits":{"memory":"1Gi"}}}]}}'
   ```

4. Consultá cuánto presupuesto de la quota está consumido:

   ```bash
   kubectl describe resourcequota presupuesto
   ```

5. Comprobá un efecto sutil de las quotas: con una `ResourceQuota` activa sobre `requests.*`/`limits.*`, un Pod que no declara recursos sería **rechazado**… salvo que un LimitRange le asigne defaults, como acá. Verificalo borrando primero el LimitRange:

   ```bash
   kubectl delete limitrange defaults-container
   kubectl run huerfano --image=nginx:1.27
   ```

   Leé el mensaje de error: la quota exige que cada Pod declare (o herede) requests y limits.

6. Limpieza final:

   ```bash
   kubectl delete namespace recursos
   kubectl config set-context --current --namespace=default
   ```

**Preguntas**

13. ¿Sobre qué actúa cada objeto: `LimitRange` vs `ResourceQuota`? Marcá la diferencia de alcance.
14. En el paso 2, ¿qué requests y limits terminó teniendo el Pod `heredero` y de dónde salieron?
15. ¿En qué momento se rechaza un Pod que viola una quota: al hacer `kubectl apply`, al schedularlo, o en runtime?

---

## Respuestas

<details>
<summary>Ver respuestas</summary>

1. `cpu: "250m"` son 250 **millicores**, es decir 0,25 de un core (una CPU virtual del node). `64Mi` usa el sufijo binario **mebibyte** (64 × 1024² bytes ≈ 67,1 MB), mientras que `64M` es el sufijo decimal **megabyte** (64 × 1000² bytes). `Mi` es un poco más grande que `M`; en Kubernetes lo habitual es usar los sufijos binarios (`Ki`, `Mi`, `Gi`). Cuidado en el examen: `64m` en minúscula en el campo memory significa 64 **mili-bytes**, un error clásico.

2. Con CPU sostenida por encima del limit de `500m`, el container es **throttled** (estrangulado): el kernel le recorta tiempo de CPU pero el proceso sigue vivo. Con memoria por encima de `128Mi`, el kernel lo termina con **OOM kill**: el container muere y el kubelet lo reinicia según la `restartPolicy`.

3. El scheduler usa **solo los `requests`**. Compara los requests del Pod contra la capacidad *allocatable* del node menos la suma de requests de los Pods ya asignados. Los `limits` no participan del scheduling; los aplica el kubelet/kernel en runtime.

4. - **Guaranteed**: todos los containers del Pod declaran `requests` y `limits` para CPU **y** memoria, y en cada recurso `requests == limits`.
   - **Burstable**: no califica como Guaranteed, pero al menos un container declara algún `request` o `limit`.
   - **BestEffort**: ningún container del Pod declara ni requests ni limits.

5. Ante presión de memoria en el node, el kubelet tiende a evictear primero los **BestEffort**, después los **Burstable** que exceden sus requests, y deja para el final los **Guaranteed**. (El criterio fino ordena por cuánto excede cada Pod su request y por priority, pero la regla práctica por QoS class es la que se evalúa en el examen.)

6. **Burstable.** Para ser Guaranteed necesitaría requests == limits en CPU *y* memoria en todos los containers; con CPU sin limit no alcanza, pero como declaró algo, tampoco es BestEffort.

7. `Reason: OOMKilled` con **exit code 137** (128 + 9, porque el proceso recibe `SIGKILL` del OOM killer del kernel).

8. Porque la `restartPolicy` por defecto de un Pod es `Always`: el kubelet reinicia el container cada vez que muere, y ante fallos repetidos aplica un **backoff exponencial** entre reinicios — ese estado de espera creciente es `CrashLoopBackOff`. El Pod no queda "muerto": queda ciclando entre reinicio y espera.

9. No. La CPU es un recurso **compresible**: cuando el container llega a su limit, el kernel simplemente lo estrangula (CPU throttling) y el proceso corre más lento. Nunca se mata un container por exceso de CPU; solo la memoria (recurso **incompresible**) provoca OOM kill.

10. Cualquiera de estas: (a) **bajar los `requests`** del Pod/Deployment a valores que entren en algún node; (b) **liberar capacidad** eliminando o reduciendo otros Pods del node; (c) **agregar nodes** o usar un node con más recursos. Lo que no sirve es bajar los `limits`: el scheduler no los mira.

11. Porque el scheduling se hace por **requests declarados, no por uso real**. Si los Pods existentes reservaron (requests) casi toda la capacidad del node, el node figura "lleno" para el scheduler aunque los procesos estén ociosos. La reserva es contractual, no medida.

12. Crea **Pods nuevos**. `kubectl set resources` modifica el Pod template del Deployment (`spec.template.spec.containers[].resources`); como cambió el template, el Deployment dispara un **rolling update** que reemplaza los Pods viejos por nuevos con los recursos actualizados. Los Pods en sí son inmutables en ese campo (salvo clusters con in-place resize habilitado).

13. `LimitRange` actúa a nivel de **cada container/Pod individual** dentro del namespace: fija defaults (`default`, `defaultRequest`) y topes por objeto (`max`, `min`). `ResourceQuota` actúa sobre el **agregado del namespace**: la suma de requests/limits de todos los Pods, y también la cantidad de objetos (Pods, Services, etc.). Uno pone reglas por unidad; el otro, un presupuesto total.

14. Recibió `requests: cpu=100m, memory=64Mi` (del campo `defaultRequest`) y `limits: cpu=500m, memory=256Mi` (del campo `default`) del LimitRange. La mutación la hace el **admission controller** `LimitRanger` en el momento de crear el Pod; el YAML original que enviaste no tenía nada.

15. En el **admission**, es decir al crear el objeto (`kubectl apply`/`run`): el API server rechaza la creación con un error `exceeded quota` o `must specify requests/limits` antes de que exista el Pod. No llega ni al scheduler ni al runtime.

</details>

---

## Fuentes

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Resource Management for Pods and Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes — Pod Quality of Service Classes: https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes — Limit Ranges: https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes — Resource Quotas: https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes — Assign Memory Resources to Containers and Pods: https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/