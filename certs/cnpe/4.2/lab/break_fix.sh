# 4.2 Building and Configuring CI/CD Pipelines Integrated with Kubernetes

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El diseño de pipelines de **Integración Continua y Entrega Continua (CI/CD)** verdaderamente integrados con Kubernetes se basa en motores de ejecución cloud native como **Tekton Pipelines** y herramientas de build daemonless como **Kaniko** o **Buildpack**.

---

## 1. Tekton Pipelines (Task, Pipeline, PipelineRun)

Tekton es un framework de CI/CD nativo de Kubernetes que define tareas de build como CRDs ejecutadas en Pods aislados.

```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: kaniko-build
  namespace: tekton-tasks
spec:
  params:
  - name: image
    type: string
  steps:
  - name: build-and-push
    image: gcr.io/kaniko-project/executor:v1.9.0
    command:
    - /kaniko/executor
    args:
    - --dockerfile=Dockerfile
    - --context=dir://$(workspaces.source.path)
    - --destination=$(params.image)
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Tekton Pipelines Documentation — https://tekton.dev/docs/pipelines/
- Kaniko Container Build — https://github.com/GoogleContainerTools/kaniko