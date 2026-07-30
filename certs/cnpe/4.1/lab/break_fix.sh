# 4.1 Implementing GitOps Workflows for Application and Infrastructure Deployment

## Motivación y Principios de GitOps

**GitOps** es un modelo operativo cloud native donde Git actúa como la **única fuente de verdad (Single Source of Truth)** para el estado deseado de las aplicaciones e infraestructura de la plataforma.

---

## 1. Principios del OpenGitOps Manifesto

1. **Declarativo**: El estado completo del sistema se expresa mediante archivos de manifiesto.
2. **Versionado e Inmutable**: El estado deseado vive en Git con firmas de commits y auditoría.
3. **PULL Automatizado**: Agentes in-cluster leen activamente el estado en Git y lo sincronizan de forma continua.
4. **Reconciliación Continua**: Detección de deriva (*Drift Detection*) y auto-remediación si el estado en vivo se desvía de Git.

---

## 2. Herramientas: Argo CD & Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-ingress-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/my-org/platform-manifests.git
    targetRevision: HEAD
    path: infra/ingress-nginx
  destination:
    server: https://kubernetes.default.svc
    namespace: ingress-nginx
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenGitOps Principles — https://opengitops.dev/
- Argo CD Documentation — https://argo-cd.readthedocs.io/