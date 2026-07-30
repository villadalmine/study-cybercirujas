# 1.1 Declarative Resource Management and Infrastructure Concepts

> Referencia: [CNCF CNPA Curriculum](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

El **Gestión Declarativa de Recursos (Declarative Resource Management)** es la piedra angular de la ingeniería de plataformas cloud native. A diferencia del modelo imperativo (donde se especifican los pasos paso a paso para configurar un sistema), el modelo declarativo describe el **estado deseado** (*Desired State*) mediante archivos manifiestos (YAML/JSON) y delega a un bucle de control la tarea de reconciliar continuamente el estado real del sistema.

---

## 1. Modelo Imperativo vs Declarativo

| Aspecto | Modelo Imperativo | Modelo Declarativo (Cloud Native) |
|---|---|---|
| **Enfoque** | "¿Cómo hacerlo?" (instrucciones paso a paso) | "¿Qué se desea obtener?" (estado final deseado) |
| **Tolerancia a fallos** | Baja; si falla un paso intermedio, el estado queda inconsistente | Alta; el sistema busca y corrige automáticamente las desviaciones |
| **Herramientas representativas** | Shell scripts (`docker run`, `systemctl`) | Kubernetes Manifiests, Terraform, Crossplane |

---

## 2. Manifiestos Declarativos en Kubernetes

Un manifiesto declarativo en Kubernetes especifica la versión de la API (`apiVersion`), el tipo de recurso (`kind`), metadatos (`metadata`) y el estado deseado (`spec`).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: platform-web
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: platform-web
  template:
    metadata:
      labels:
        app: platform-web
    spec:
      containers:
      - name: web
        image: nginx:alpine
```

Al aplicar este manifiesto con `kubectl apply -f deployment.yaml`, el API Server almacena la definición en `etcd` y el controlador de Deployment asegura que existan exactamente 3 réplicas ejecutándose.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes Declarative Management — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/