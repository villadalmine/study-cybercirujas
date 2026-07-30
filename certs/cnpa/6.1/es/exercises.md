# Ejercicios Guiados — 6.1 Cost Optimization and FinOps for Cloud Native Infrastructure

## Ejercicio 1 — Análisis de Right-Sizing con VPA

1. Inspeccionar las recomendaciones del VPA para un deployment:
   ```bash
   kubectl get vpa platform-api-vpa -n platform-prod -o yaml
   ```
2. Comparar los requests actuales con las recomendaciones del VPA:
   ```bash
   kubectl top pods -n platform-prod
   kubectl get pods -n platform-prod -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.requests}{"\n"}{end}'
   ```
3. Calcular el ratio de eficiencia de asignación en el namespace:
   ```bash
   # Consultar en Prometheus o Grafana la query PromQL del tema
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. El VPA recomienda ajustar requests basándose en el percentil P95 del consumo histórico, reduciendo overprovisioning.
2. Un ratio de eficiencia menor al 50% indica overprovisioning significativo y oportunidad de ahorro.

</details>