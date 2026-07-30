# 4.2 Building and Configuring CI/CD Pipelines Integrated with Kubernetes

## Motivación y Pipelines Cloud Native

Pipelines de CI/CD nativos de Kubernetes ejecutados con **Tekton Pipelines** y herramientas de construcción de imágenes daemonless como **Kaniko**.

---

## 1. Tekton Task & Pipeline CRDs

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
- Tekton Pipelines Docs — https://tekton.dev/docs/