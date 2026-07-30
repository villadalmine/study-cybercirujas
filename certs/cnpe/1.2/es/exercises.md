# Ejercicios Guiados — 1.2 Using Cost Management Solutions for Right-Sizing and Scaling

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

Requisitos previos: Acceso a un clúster Kubernetes con `metrics-server` habilitado.

---

## Ejercicio 1 — Análisis de consumo de CPU/Memoria y detección de Over-provisioning

1. Consultar las métricas de nodos e identificar el consumo actual:
   ```bash
   kubectl top nodes
   ```
2. Consultar el consumo de pods en todos los namespaces:
   ```bash
   kubectl top pods -A --sort-by=cpu
   ```

---

## Ejercicio 2 — Configuración de VerticalPodAutoscaler en modo Recomendación

1. Crear un manifiesto VPA en modo `Off` para monitorear un Deployment existente:
   ```yaml
   apiVersion: autoscaling.k8s.io/v1
   kind: VerticalPodAutoscaler
   metadata:
     name: sample-vpa
     namespace: default
   spec:
     targetRef:
       apiVersion: "apps/v1"
       kind: Deployment
       name: sample-app
     updatePolicy:
       updateMode: "Off"
   ```
2. Consultar las recomendaciones generadas por el VPA:
   ```bash
   kubectl get vpa sample-vpa -o yaml
   ```

---

## Ejercicio 3 — Configuración de HorizontalPodAutoscaler (HPA v2)

1. Crear un HPA enfocado en mantener el target de CPU al 70%:
   ```bash
   kubectl autoscale deployment sample-app --cpu-percent=70 --min=2 --max=8
   ```
2. Inspeccionar la métrica actual del HPA:
   ```bash
   kubectl get hpa sample-app
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. La diferencia entre HPA y VPA es que HPA escala en la dimensión horizontal (agregando/quitando réplicas de Pods), mientras que VPA ajusta los límites verticales de CPU/Memoria del contenedor existente.
2. `updateMode: "Off"` permite obtener recomendaciones de right-sizing sin reiniciar los Pods de producción.

</details>
