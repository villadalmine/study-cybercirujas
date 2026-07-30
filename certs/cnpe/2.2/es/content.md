# 2.2 Measuring and Improving Platform Efficiency Using Deployment Metrics and Performance Indicators

## Motivación e Indicadores de Rendimiento de la Plataforma

Medir la eficiencia de una **Internal Developer Platform (IDP)** requiere una aproximación cuantitativa orientada tanto al rendimiento del software (**Métricas DORA**) como a la salud financiera y operativa de la infraestructura (**SLIs/SLOs/SLAs**).

Sin métricas claras, las decisiones de plataforma se toman por percepción subjetiva, lo que lleva a dos problemas frecuentes:
1. **Falta de visibilidad sobre los cuellos de botella**: Desconocimiento de cuánto tiempo tarda un commit en llegar a producción (*Lead Time for Changes*).
2. **Desperdicio de presupuesto cloud**: Asignación ineficiente de recursos de infraestructura sin relacionarlos con el valor aportado al negocio.

---

## 1. Las 4 Métricas Clave de DORA (DevOps Research and Assessment)

Las métricas DORA son el estándar de la industria para evaluar la madurez de la entrega de software y la efectividad de la plataforma:

| Métrica DORA | Categoría | Objetivo de Alto Rendimiento (Elite) | Medición en la Plataforma |
|---|---|---|---|
| **Deployment Frequency (DF)** | Velocidad | Múltiples despliegues por día (On-Demand) | Conteo de ejecuciones exitosas de pipelines CI/CD por día |
| **Lead Time for Changes (LTC)** | Velocidad | Menos de 1 hora | Tiempo transcurrido desde el `git commit` hasta el Pod `Running` en prod |
| **Change Failure Rate (CFR)** | Estabilidad | Menor al 5% | % de despliegues que desencadenan un rollback o hotfix en prod |
| **Failed Service Recovery Time (MTTR)** | Estabilidad | Menos de 1 hora | Tiempo promedio transcurrido desde la alerta del incidente hasta la resolución |

---

## 2. Gestión de SLIs, SLOs y Error Budgets

### 2.1 Definiciones Fundamentales

- **Service Level Indicator (SLI)**: Medición cuantitativa directa del servicio en tiempo real.
  $$\text{SLI}_{\text{disponibilidad}} = \frac{\text{Peticiones HTTP Exitosas (2xx/3xx)}}{\text{Peticiones HTTP Totales}} \times 100$$
- **Service Level Objective (SLO)**: La meta acordada para el SLI dentro de una ventana de tiempo definida (ej. 99.9% de disponibilidad en 30 días).
- **Error Budget (Presupuesto de Error)**: El margen tolerable de fallos permitido por el SLO.
  $$\text{Error Budget} = 100\% - \text{SLO} \quad (\text{Para un SLO de } 99.9\%, \text{ el Error Budget es } 0.1\%)$$

### 2.2 Implementación Declarativa de SLOs con OpenSLO / Pyrra

```yaml
apiVersion: pyrra.dev/v1alpha1
kind: ServiceLevelObjective
metadata:
  name: platform-api-latency-slo
  namespace: platform-prod
spec:
  target: "99.5"
  window: 28d
  indicator:
    ratio:
      errors:
        metric: http_request_duration_seconds_count{job="platform-api", status=~"5.."}
      total:
        metric: http_request_duration_seconds_count{job="platform-api"}
```

---

## 3. Métricas de Eficiencia de Cómputo e Infraestructura

### Ratio de Eficiencia de Asignación de Recursos (Allocation Efficiency Ratio)

Mide la diferencia entre los recursos reservados por los Pods (`requests`) y los recursos consumidos realmente a nivel de kernel/cgroups.

```bash
# PromQL: Porcentaje de uso real de CPU respecto al Request asignado en el clúster
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m]))
/
sum(kube_pod_container_resource_requests{resource="cpu"}) * 100
```

---

## Verificación y Diagnóstico de Métricas DORA y SLOs

```bash
# Consultar el estado actual del Error Budget con Prometheus API
$ curl -s "http://prometheus-k8s.platform-monitoring:9090/api/v1/query?query=pyrra_availability_remaining_error_budget{slo=\"platform-api-latency-slo\"}" | jq .data.result[0].value[1]
"0.842"  # (84.2% del Error Budget aún disponible)
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- DORA Research & Assessment Framework — https://cloud.google.com/devops
- Google SRE Book: Service Level Objectives — https://sre.google/sre-book/service-level-objectives/
- OpenSLO Specification — https://openslo.com/