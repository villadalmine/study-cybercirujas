# 1.2 Using Cost Management Solutions for Right-Sizing and Scaling

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

La gestión de costos en entornos cloud native (**FinOps**) es una disciplina que combina prácticas financieras, operativas y de ingeniería para optimizar el gasto en infraestructura sin sacrificar performance ni disponibilidad. En Kubernetes, el desafío principal es que los recursos (CPU, memoria) se definen mediante `requests` y `limits`, pero frecuentemente existe una brecha entre lo solicitado y lo consumido. Esto se traduce en costo ocioso (**overprovisioning**) o en riesgo de *throttling*/OOMKill (**underprovisioning**).

Este tema cubre herramientas y prácticas para **right-sizing** (ajustar recursos al uso real) y **scaling** (ajustar la cantidad de réplicas/nodos según demanda), integradas con soluciones de observabilidad de costos.

---

## 1. Visibilidad y Atribución de Costos (FinOps en Kubernetes)

Para tomar decisiones de optimización, el primer paso es visibilizar el consumo por tenant, namespace, servicio o etiqueta (*allocation*).

### Kubecost & OpenCost
- **OpenCost** (proyecto de la CNCF) y **Kubecost** miden el consumo de recursos de Kubernetes y lo mapean contra precios de nube pública (AWS, GCP, Azure) o costos personalizados en instalaciones on-premise.
- Calculan el costo de almacenamiento persistent volume (PV), balanceadores de carga y cómputo (*idle vs requested vs used*).

---

## 2. Estrategias de Autoscaling en Kubernetes

### Horizontal Pod Autoscaler (HPA) y KEDA
HPA escala la cantidad de réplicas de un Deployment/StatefulSet según métricas de CPU/Memoria o métricas personalizadas (Custom Metrics via Prometheus).

- **KEDA (Kubernetes Event-driven Autoscaling)**: Permite autoscaling basado en eventos (ej: tamaño de cola en RabbitMQ, Kafka o AWS SQS), incluyendo el escalado a cero réplicas (`scale to 0`).

### Vertical Pod Autoscaler (VPA)
VPA analiza el consumo histórico de CPU y memoria de los contenedores y ajusta automáticamente las secciones `requests` y `limits` del Pod.

### Cluster Autoscaler y Karpenter
- **Cluster Autoscaler**: Agrega o elimina nodos del pool del proveedor cloud cuando existen Pods en estado `Pending`.
- **Karpenter** (AWS Open Source): Autoscaler de nodos ultra-rápido que aprovisiona directamente la instancia justa necesaria (*just-in-time node provisioning*).

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenCost Specification — https://www.opencost.io/
- Kubernetes Autoscaling Architecture — https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Karpenter Node Autoscaler — https://karpenter.sh/