# 4.3 Deploying Applications Using Progressive Delivery Strategies

## Motivación y Progressive Delivery

**Progressive Delivery** combina despliegues graduales (Canary, Blue/Green) con observabilidad automatizada en tiempo real para minimizar el radio de impacto de fallas (*Blast Radius*).

---

## 1. Argo Rollouts (Rollout CRD)

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
- Argo Rollouts — https://argoproj.github.io/argo-rollouts/