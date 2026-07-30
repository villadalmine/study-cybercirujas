# 4.3 Deploying Applications Using Progressive Delivery Strategies (Blue/Green, Canary)

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

**Progressive Delivery** es la evolución de la entrega continua que combina despliegues graduales (Canary, Blue/Green) con observabilidad automatizada en tiempo real para minimizar el radio de impacto de fallas (*Blast Radius*).

---

## 1. Estrategias de Progressive Delivery

- **Blue/Green Deployment**: Mantiene dos entornos idénticos (Blue = versión actual, Green = versión nueva). La conmutación de tráfico es instantánea a nivel de LoadBalancer/Ingress.
- **Canary Deployment**: Dirige un porcentaje pequeño de tráfico (ej. 5%) a la nueva versión, incrementando gradualmente el tráfico si los SLIs/SLOs de error rate y latencia permanecen estables.

---

## 2. Herramientas Principales: Argo Rollouts & Flagger

### Argo Rollouts (Rollout CRD)
Reemplaza el controlador estándar `Deployment` de Kubernetes agregando estrategias de Canary y Blue/Green con análisis automático de métricas de Prometheus.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: api-rollout
  namespace: platform-prod
spec:
  replicas: 5
  strategy:
    canary:
      steps:
      - setWeight: 20
      - pause: {duration: 10m}
      - setWeight: 50
      - pause: {duration: 30m}
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: myregistry.io/api:v2.0
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Argo Rollouts Progressive Delivery — https://argoproj.github.io/argo-rollouts/
- Flux Flagger — https://flagger.app/