# Tema 1.3: Optimizing Multi-Tenancy Resource Usage

En este tema trabajamos sobre cómo un cluster de Kubernetes puede alojar múltiples tenants (equipos, aplicaciones o clientes) de forma segura y eficiente, evitando el "noisy neighbor problem" mediante `ResourceQuota`, `LimitRange`, `PriorityClass`, `taints/tolerations`, `node affinity` y <PERSON>.

---

## Ejercicio 1: Aislamiento lógico con Namespace y ResourceQuota

1. Crear dos namespaces que representen dos tenants distintos:
   ```bash
   kubectl create namespace tenant-a
   kubectl create namespace tenant-b
   ```

2. Aplicar un `ResourceQuota` al namespace `tenant-a` limitando CPU, memoria y cantidad de Pods:
   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-a-quota
     namespace: tenant-a
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
       pods: "10"
   ```
   ```bash
   kubectl apply -f tenant-a-quota.yaml
   ```

3. Verificar el estado de la cuota:
   ```bash
   kubectl describe resourcequota tenant-a-quota -n tenant-a
   ```

4. Intentar desplegar un Deployment sin `requests`/`limits` definidos en `tenant-a` y observar el error:
   ```bash
   kubectl create deployment nginx --image=nginx -n tenant-a
   kubectl get events -n tenant-a --sort-by=.lastTimestamp
   ```

**Preguntas de comprensión:**
- ¿Por qué falla la creación del Deployment del paso 4 aunque la cuota tenga espacio disponible en `pods`?
- ¿Qué diferencia práctica existe entre limitar `requests.cpu` y <PERSON> `limits.cpu` en un `ResourceQuota`?

---

## Ejercicio 2: Defaults automáticos con LimitRange

1. Crear un `LimitRange` en `tenant-a` que asigne valores por defecto a los contenedores:
   ```yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: tenant-a-limits
     namespace: tenant-a
   spec:
     limits:
     - default:
         cpu: "500m"
         memory: "256Mi"
       defaultRequest:
         cpu: "250m"
         memory: "128Mi"
       type: Container
   ```
   ```bash
   kubectl apply -f tenant-a-limits.yaml
   ```

2. Repetir la creación del Deployment del Ejercicio 1 y confirmar que ahora sí se crea:
   ```bash
   kubectl create deployment nginx --image=nginx -n tenant-a
   kubectl get pods -n tenant-a
   ```

3. Inspeccionar los `requests`/`limits` que quedaron asignados automáticamente al Pod:
   ```bash
   kubectl get pod -n tenant-a -o jsonpath='{.items[0].spec.containers[0].resources}'
   ```

4. Intentar crear un Pod que solicite más recursos que el `max` permitido (agregar `max.cpu: "1"` al `LimitRange` y probar con un Pod que pida `2` CPU).

**Preguntas de comprensión:**
- ¿Qué problema de multi-tenancy resuelve `LimitRange` que `ResourceQuota` por sí solo no resuelve?
- ¿En qué <PERSON> aplican `LimitRange` y `ResourceQuota` cuando se crea un Pod?

---

## Ejercicio 3: <PERSON> tenants con PriorityClass

1. Crear dos `PriorityClass`, una para tenants críticos y otra para tenants best-effort:
   ```yaml
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata:
     name: tenant-critical
   value: 1000000
   globalDefault: false
   ---
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata:
     name: tenant-lowprio
   value: 1000
   globalDefault: false
   ```
   ```bash
   kubectl apply -f priorityclasses.yaml
   ```

2. Desplegar un Pod de baja prioridad que consuma casi todo un <PERSON> (simulando saturación de recursos).

3. Desplegar un Pod de alta prioridad (`tenant-critical`) que requiera recursos equivalentes en el mismo nodo:
   ```bash
   kubectl get events -n tenant-b --sort-by=.lastTimestamp
   ```

4. Observar en los eventos cómo el scheduler realiza *preemption* del Pod de baja prioridad para liberar espacio.

**Preguntas de comprensión:**
- ¿Qué riesgo introduce el uso agresivo de `PriorityClass` en un ambiente multi-tenant si no <PERSON> con `ResourceQuota`?
- ¿Qué mecanismo de Kubernetes ejecuta la eliminación del Pod de menor prioridad y qué garantías de gracia ofrece?

---

## Ejercicio 4: Aislamiento físico con <PERSON>, <PERSON> y Node Affinity

1. Etiquetar y taintear un grupo de nodos dedicados al `tenant-a`:
   ```bash
   kubectl label nodes node-1 tenant=tenant-a
   kubectl taint nodes node-1 tenant=tenant-a:<PERSON>2. Definir un Pod con `toleration` y `nodeAffinity` que le permita programarse solo en esos nodos:
   ```yaml
   spec:
     tolerations:
     - key: "tenant"
       operator: "Equal"
       value: "tenant-a"
       effect: "NoSchedule"
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
           - matchExpressions:
             - key: tenant
               operator: In
               values:
               - tenant-a
   ```

3. <PERSON> y confirmar que se programó en `node-1`:
   ```bash
   kubectl get pod -o wide -n tenant-a
   ```

4. Intentar desplegar un Pod de `tenant-b` (sin la `toleration`) apuntando <PERSON> y verificar que queda `Pending`.

**Preguntas de comprensión:**
- ¿Por qué es necesario combinar `taint`/`toleration` con `nodeAffinity` para lograr aislamiento real, en lugar de usar solo uno de los dos?
- ¿Qué diferencia hay entre `NoSchedule` y `NoExecute` en el contexto de aislamiento de tenants?

---

## Ejercicio 5: <PERSON> y <PERSON> continuo con metrics-server

1. Verificar que `metrics-server` esté instalado y operativo:
   ```bash
   kubectl get deployment metrics-server -n kube-system
   kubectl top nodes
   ```

2. Consultar el consumo real de recursos por tenant:
   ```bash
   kubectl top pods -n tenant-a
   kubectl top pods -n tenant-b
   ```

3. <PERSON> real (`kubectl top`) contra la cuota asignada (`kubectl describe resourcequota`) para detectar sobre-provisión o sub-provisión.

4. Ajustar el `ResourceQuota` de `tenant-a` en base a los datos observados y volver a aplicar:
   ```bash
   kubectl edit resourcequota tenant-a-quota -n tenant-a
   ```

**Preguntas de comprensión:**
- ¿Por qué el uso de `kubectl top` no es suficiente por sí solo para tomar decisiones de largo plazo sobre sizing de tenants?
- ¿Qué otra fuente de datos (fuera de `metrics-server`) se recomienda para optimizar continuamente las cuotas en producción?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- Falla porque el `ResourceQuota` incluye `requests.cpu`/`requests.memory`, y cuando una cuota define recursos de compute, Kubernetes exige que **todos** los Pods del namespace especifiquen explícitamente `requests`/`limits` en cada contenedor; si no los especifican, el API server <PERSON> creación <PERSON>pods`.
- `requests.cpu` limita la suma de recursos "garantizados" (usados por el scheduler <PERSON>), mientras que `limits.cpu` limita el techo máximo que los contenedores pueden consumir en burst. <PERSON> solo `requests` permite bursts descontrolados; controlar solo `limits` puede sub-utilizar la capacidad reservada.

**Ejercicio 2**
- `LimitRange` resuelve el problema de que los tenants (o sus Pods) no <PERSON> `requests`/`limits`, aplicando valores por defecto y validando rangos mínimos/máximos por contenedor. `ResourceQuota` solo agrega totales a nivel namespace, pero no obliga ni completa valores a nivel Pod/contenedor individual.
- Primero se aplican los defaults de `LimitRange` (mutando el Pod antes de la validación), <PERSON> valida el resultado contra los totales agregados definidos en `ResourceQuota`.

**Ejercicio 3**
- Sin `ResourceQuota`, un tenant con `PriorityClass` alta puede monopolizar todos los recursos del cluster desplazando continuamente a tenants <PERSON> prioridad, generando inanición (*starvation*) para estos últimos.
- El **scheduler** ejecuta la preemption, eliminando Pods de menor prioridad para liberar recursos. Kubernetes respeta el `terminationGracePeriodSeconds` del Pod expulsado, <PERSON>.

**Ejercicio 4**
- El `taint` solo evita que Pods **sin toleration** se programen en el nodo, pero no impide que un Pod **con toleration** de otro tenant también sea programado ahí. <PERSON> `nodeAffinity<PERSON> los Pods del tenant correcto hacia esos nodos específicos. Combinados, se logra exclusividad en ambos sentidos.
- `NoSchedule` impide nuevas asignaciones al nodo pero no afecta Pods ya corriendo; `<PERSON>` además expulsa (evict) los Pods que ya están corriendo y no toleran el taint, siendo más estricto para reforzar el aislamiento en caliente.

**Ejercicio 5**
- `kubectl top` solo muestra <PERSON> (snapshot), sin histórico ni tendencias; no permite detectar patrones de uso a lo largo del tiempo (picos, estacionalidad) necesarios para dimensionar cuotas correctamente.
- Se recomienda usar un sistema de métricas históricas como **Prometheus** (con `kube-state-metrics` y `cAdvisor`) para analizar tendencias de consumo y ajustar `ResourceQuota`/`LimitRange` de forma basada en datos a largo plazo.

</details>