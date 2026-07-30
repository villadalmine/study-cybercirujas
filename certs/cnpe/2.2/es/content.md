# 2.2 Measuring and Improving Platform Efficiency Using Deployment Metrics and Performance Indicators

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El rendimiento y la eficiencia de una plataforma cloud native se miden a través de **Métricas DORA (DevOps Research and Assessment)** y métricas de infraestructura (SLIs/SLOs/SLAs). Este tema cubre los indicadores clave para evaluar la madurez de la plataforma e identificar cuellos de botella en el ciclo de entrega.

---

## 1. Las 4 Métricas Clave de DORA

Para medir la velocidad y estabilidad del ciclo de software en la plataforma:

| Métrica DORA | Definición | Meta de Alto Rendimiento |
|---|---|---|
| **Deployment Frequency (DF)** | Con qué frecuencia se despliega código a producción | Múltiples veces al día (On-demand) |
| **Lead Time for Changes (LTC)** | Tiempo transcurrido desde el commit hasta la ejecución en producción | Menos de 1 hora |
| **Change Failure Rate (CFR)** | Porcentaje de despliegues que causan fallos o degradación en producción | Menor al 5% |
| **Time to Restore Service (MTTR)** | Tiempo promedio para recuperar el servicio tras un incidente | Menos de 1 hora |

---

## 2. Definición de SLIs, SLOs y SLAs

### Service Level Indicators (SLIs)
Mediciones cuantitativas en tiempo real del estado del servicio.
- Ejemplo: Porcentaje de solicitudes HTTP exitosas (`2xx`/`3xx`) sobre el total en una ventana de 5 minutos.

$$\text{SLI}_{\text{disponibilidad}} = \frac{\sum \text{solicitudes\_exitosas}}{\sum \text{solicitudes\_totales}} \times 100$$

### Service Level Objectives (SLOs)
El objetivo o meta acordada internamente para un SLI en un período determinado (ej. 30 días).
- Ejemplo: El SLO de disponibilidad del servicio API es 99.9% durante los últimos 30 días.

### Error Budgets (Presupuesto de Error)
El margen permitido de fallos dentro de un SLO.
$$\text{Error Budget} = 100\% - \text{SLO}$$
Para un SLO de 99.9%, el Error Budget es 0.1%. Si el presupuesto de error se agota a mitad de mes, las políticas de plataforma pueden congelar los nuevos despliegues de características para priorizar la estabilización del sistema.

---

## 3. Métricas de Eficiencia de Cómputo e Infraestructura

### Resource Allocation Efficiency Ratio
Relación entre los recursos solicitados por los workloads (*requests*) y el consumo real medido por cgroups/Kubelet.

```bash
# Consulta PromQL para calcular el porcentaje de CPU realmente usado respecto al Request asignado
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) 
/ 
sum(kube_pod_container_resource_requests{resource="cpu"}) * 100
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- DORA DevOps Research & Assessment — https://cloud.google.com/blog/products/devops-sre/using-the-four-keys-to-measure-your-devops-performance
- Google SRE Book: Service Level Objectives — https://sre.google/sre-book/service-level-objectives/