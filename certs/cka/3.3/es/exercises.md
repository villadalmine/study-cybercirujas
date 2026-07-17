# CKA 1.35 — Tema 3.3: Configure workload autoscaling (peso 2.5)

> Referencia de curriculum: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Estos ejercicios asumen un cluster con al menos un control-plane node y un worker node, `kubectl` configurado, y permisos de administrador. Se trabaja principalmente con `HorizontalPodAutoscaler` (HPA), que es el mecanismo de autoscaling que sí se puede ejercitar íntegramente con `kubectl` sin componentes externos. También se cubre `VerticalPodAutoscaler` (VPA) a nivel de manifiesto, ya que sus componentes (recommender, updater, admission-controller) no vienen instalados por defecto en un cluster estándar.

---

## Bloque 1 — Verificar metrics-server y desplegar la carga de prueba

El HPA basado en CPU/memoria depende de la Metrics API (`metrics.k8s.io`), que expone `metrics-server`. Sin esto, el HPA no tiene de dónde leer utilización de recursos.

1. Verificá si `metrics-server` está corriendo en el cluster:
   ```bash
   kubectl get deployment metrics-server -n kube-system
   ```
2. Confirmá que la Metrics API responde:
   ```bash
   kubectl top nodes
   kubectl top pods -A
   ```
   Si ninguno de los dos comandos devuelve datos (error `metrics not available yet` o similar), esperá unos segundos y reintentá; recién tras el arranque puede tardar en recolectar la primera muestra.
3. Creá un deployment de prueba que **defina `resources.requests`**, condición obligatoria para que el HPA calcule porcentaje de utilización:
   ```bash
   kubectl create deployment php-apache --image=registry.k8s.io/hpa-example
   kubectl set resources deployment php-apache --requests=cpu=200m,memory=100Mi --limits=cpu=500m,memory=200Mi
   kubectl expose deployment php-apache --port=80
   ```
4. Verificá que el pod esté `Running` y que reporte métricas:
   ```bash
   kubectl get pods -l app=php-apache
   kubectl top pod -l app=php-apache
   ```

**Preguntas de comprensión**
1. ¿Por qué el HPA no puede calcular un porcentaje de utilización de CPU si el pod no tiene `resources.requests.cpu` definido?
2. ¿Qué componente del cluster expone la `metrics.k8s.io` API que consume el HPA controller?

---

## Bloque 2 — Crear un HPA de forma imperativa

5. Creá un HPA que escale el deployment `php-apache` en base a CPU:
   ```bash
   kubectl autoscale deployment php-apache --cpu-percent=50 --min=1 --max=5
   ```
6. Verificá el estado inicial:
   ```bash
   kubectl get hpa php-apache
   ```
7. Inspeccioná el objeto completo generado:
   ```bash
   kubectl describe hpa php-apache
   ```
   Prestá atención a los campos `Reference`, `Metrics`, `Min/Max replicas` y la sección `Conditions`.

**Preguntas de comprensión**
1. ¿A qué apiVersion pertenece el objeto que crea `kubectl autoscale` en un cluster 1.35?
2. En la salida de `kubectl describe hpa`, ¿qué indica una condición `ScalingActive=False`?

---

## Bloque 3 — HPA declarativo con `autoscaling/v2` y múltiples métricas

El `kubectl autoscale` solo permite CPU. Para combinar CPU y memoria (o métricas custom/external) hace falta el manifiesto `autoscaling/v2`.

8. Borrá el HPA imperativo para reemplazarlo por uno declarativo:
   ```bash
   kubectl delete hpa php-apache
   ```
9. Creá el archivo `hpa-php-apache.yaml`:
   ```yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: php-apache
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: php-apache
     minReplicas: 1
     maxReplicas: 5
     metrics:
     - type: Resource
       resource:
         name: cpu
         target:
           type: Utilization
           averageUtilization: 50
     - type: Resource
       resource:
         name: memory
         target:
           type: Utilization
           averageUtilization: 70
   ```
10. Aplicá el manifiesto y verificá:
    ```bash
    kubectl apply -f hpa-php-apache.yaml
    kubectl get hpa php-apache -o yaml
    ```

**Preguntas de comprensión**
1. Cuando un HPA define varias métricas simultáneamente (CPU y memoria), ¿con qué criterio decide el controller cuántas réplicas finales usar?
2. ¿Qué diferencia hay entre `target.type: Utilization` y `target.type: AverageValue` en una métrica de tipo `Resource`?

---

## Bloque 4 — Configurar `behavior` (políticas de scale up/down)

Desde `autoscaling/v2` se puede controlar la velocidad y las ventanas de estabilización del escalado, evitando "flapping" de réplicas.

11. Editá `hpa-php-apache.yaml` agregando la sección `behavior`:
    ```yaml
    spec:
      # ...campos anteriores...
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 120
          policies:
          - type: Pods
            value: 1
            periodSeconds: 60
        scaleUp:
          stabilizationWindowSeconds: 0
          policies:
          - type: Percent
            value: 100
            periodSeconds: 15
    ```
12. Aplicá los cambios y confirmá que se reflejan en el objeto:
    ```bash
    kubectl apply -f hpa-php-apache.yaml
    kubectl get hpa php-apache -o jsonpath='{.spec.behavior}' 
    ```

**Preguntas de comprensión**
1. ¿Qué problema previene `stabilizationWindowSeconds` en `scaleDown` y por qué normalmente se configura más alto que en `scaleUp`?
2. En la policy `type: Percent, value: 100, periodSeconds: 15` del `scaleUp`, ¿qué significa en términos de cuántas réplicas puede agregar el controller en 15 segundos?

---

## Bloque 5 — Generar carga y observar el escalado en vivo

13. En una terminal, dejá corriendo un watch sobre el HPA:
    ```bash
    kubectl get hpa php-apache --watch
    ```
14. En otra terminal, generá carga contra el servicio `php-apache` usando un pod temporal:
    ```bash
    kubectl run -i --tty load-generator --rm --image=busybox:1.36 --restart=Never -- \
      /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
    ```
15. Observá cómo `TARGETS` (utilización actual/deseada) sube y el número de réplicas se ajusta en la ventana de `kubectl get hpa --watch`.
16. Detené la carga con `Ctrl+C` y salí del pod (`exit`), y seguí observando cómo, tras el `stabilizationWindowSeconds` configurado, las réplicas bajan gradualmente.
17. Revisá los eventos generados por el controller:
    ```bash
    kubectl describe hpa php-apache
    ```
    (sección `Events`, con mensajes tipo `SuccessfulRescale`).

**Preguntas de comprensión**
1. ¿Por qué el número de réplicas no baja inmediatamente al cortar la carga, sino recién después de un tiempo?
2. Si `kubectl top pod` no reporta valores de CPU durante la prueba de carga, ¿qué dos causas raíz deberías descartar primero?

---

## Bloque 6 — VerticalPodAutoscaler (VPA): concepto y manifiesto

El VPA no viene instalado por defecto (requiere desplegar `recommender`, `updater` y `admission-controller` del proyecto [kubernetes/autoscaler](https://github.com/kubernetes/autoscaler)). Para el examen alcanza con poder escribir y razonar el manifiesto, incluso si el CRD no está presente en el cluster de práctica.

18. Redactá `vpa-php-apache.yaml`:
    ```yaml
    apiVersion: autoscaling.k8s.io/v1
    kind: VerticalPodAutoscaler
    metadata:
      name: php-apache-vpa
    spec:
      targetRef:
        apiVersion: apps/v1
        kind: Deployment
        name: php-apache
      updatePolicy:
        updateMode: "Auto"
    ```
19. Validá la sintaxis sin necesidad de que el CRD exista, usando validación del lado del cliente:
    ```bash
    kubectl apply -f vpa-php-apache.yaml --dry-run=client
    ```
    Si el CRD `verticalpodautoscalers.autoscaling.k8s.io` no está instalado, este comando puede fallar igual porque `--dry-run=client` no siempre evita el chequeo de schema; en ese caso alcanza con revisar visualmente la estructura del YAML.

**Preguntas de comprensión**
1. ¿Por qué HPA y VPA no deberían apuntar simultáneamente a la misma métrica (CPU) del mismo deployment?
2. ¿Qué diferencia de comportamiento hay entre `updateMode: "Auto"` y `updateMode: "Initial"` en un VPA?

---

## Bloque 7 — Cluster Autoscaler: alcance conceptual

El Cluster Autoscaler (CA) ajusta la **cantidad de nodos** del cluster (no de pods), típicamente integrado con el autoscaling group del proveedor cloud. No se ejercita con `kubectl` puro porque depende de la infraestructura subyacente (cloud provider API), por lo que en el examen se evalúa a nivel conceptual y de troubleshooting, no de instalación.

20. Revisá, sin aplicarlo, cómo se referencia un nodo "no escalable" mediante anotación (útil para troubleshooting):
    ```bash
    kubectl get nodes -o jsonpath='{.items[*].metadata.annotations.cluster-autoscaler\.kubernetes\.io/scale-down-disabled}'
    ```

**Preguntas de comprensión**
1. Si un Pod tiene un `PodDisruptionBudget` muy restrictivo, ¿cómo puede eso bloquear al Cluster Autoscaler de reducir un nodo?
2. ¿Cuál es la diferencia de nivel de escalado entre HPA/VPA y Cluster Autoscaler?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Bloque 1**
1. El HPA calcula `currentUtilization` como `uso actual / request` expresado en porcentaje; sin un `request` definido no hay denominador, por lo que el controller no puede computar la métrica y la marca como no disponible.
2. `metrics-server`, que agrega uso de CPU/memoria por pod y nodo (via kubelet `/stats/summary`) y lo expone en la `metrics.k8s.io` API, consumida tanto por el HPA controller como por `kubectl top`.

**Bloque 2**
1. `autoscaling/v2` (en versiones recientes de Kubernetes, `autoscaling/v2` es la versión estable; `v1` sigue existiendo solo para CPU y compatibilidad histórica).
2. Indica que el HPA controller no pudo obtener o calcular la métrica configurada (por ejemplo, `metrics-server` no responde, o el pod no tiene `requests` definidos), y por lo tanto no está tomando decisiones activas de escalado.

**Bloque 3**
1. El controller calcula, para cada métrica, la cantidad de réplicas deseada de forma independiente y luego toma el **valor más alto** entre todas ellas (el que exige más recursos), garantizando que ninguna métrica quede por encima de su target.
2. `Utilization` expresa el uso como porcentaje del `request` del pod (requiere que el `request` esté definido); `AverageValue` expresa un valor absoluto promedio por pod (por ejemplo, `500m` de CPU o `200Mi` de memoria) sin depender de los `requests`.

**Bloque 4**
1. Previene el "flapping": bajar réplicas apenas la carga cae un instante para volver a subirlas segundos después. Se configura una ventana más alta en `scaleDown` que en `scaleUp` porque es preferible reaccionar rápido ante un pico de carga (evitar degradar el servicio) pero ser conservador al liberar capacidad (evitar quedarse corto de recursos si la carga vuelve).
2. Permite duplicar (100%) la cantidad de réplicas actuales dentro de una ventana de 15 segundos; es la policy más agresiva disponible junto con `type: Pods` con un valor absoluto, y el controller aplica la que permita escalar más rápido salvo que se indique `selectPolicy: Min`.

**Bloque 5**
1. Por el `stabilizationWindowSeconds` configurado en `scaleDown` (120s en este ejercicio): el controller usa el máximo de réplicas recomendadas dentro de esa ventana antes de decidir bajar, para no reaccionar a caídas momentáneas de carga.
2. (a) que `metrics-server` esté corriendo y accesible (`kubectl get apiservices | grep metrics`), y (b) que el pod objetivo tenga `resources.requests.cpu` definido; sin cualquiera de las dos, no hay porcentaje de utilización que calcular.

**Bloque 6**
1. Porque competirían por controlar el mismo recurso: VPA modificaría los `requests` del pod (potencialmente recreándolo) mientras HPA escala réplicas en base a la utilización relativa a esos mismos `requests`, generando decisiones contradictorias o ciclos de reajuste.
2. `Auto` aplica las recomendaciones recreando los pods existentes cuando cambian los recursos recomendados; `Initial` solo asigna los `requests`/`limits` recomendados al momento de la creación del pod, sin modificar pods ya en ejecución.

**Bloque 7**
1. Un PDB restrictivo (por ejemplo, `minAvailable` alto) puede impedir que el Cluster Autoscaler evict/drenee los pods de un nodo candidato a eliminarse, ya que el drain respetaría el PDB y fallaría o quedaría bloqueado, evitando que el nodo se retire.
2. HPA y VPA operan a nivel de **pod/workload** (número de réplicas o recursos asignados a cada pod), mientras que el Cluster Autoscaler opera a nivel de **infraestructura** (cantidad de nodos del cluster), reaccionando a pods en estado `Pending` por falta de capacidad o a nodos subutilizados.

</details>
