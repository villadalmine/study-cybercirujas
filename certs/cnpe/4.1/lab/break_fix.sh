# 4.1 Implementing GitOps Workflows for Application and Infrastructure Deployment

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

**GitOps** es un modelo operativo cloud native donde Git se establece como la **única fuente de verdad** (*Single Source of Truth*) para el estado deseado de las aplicaciones e infraestructura de la plataforma.

---

## 1. Principios del OpenGitOps Manifesto

1. **Declarativo**: El estado completo del sistema se expresa mediante archivos manifiestos declarativos.
2. **Versionado e Inmutable**: Todo el estado deseado vive en Git con trazabilidad y firmas de commits.
3. **PULL Automatizado**: Agentes in-cluster leen activamente el estado en Git y lo sincronizan de forma continua.
4. **Reconciliación Continua**: Detección automática de deriva (*Drift Detection*) y auto-remediación si el estado del clúster se desvía de Git.

---

## 2. Herramientas Principales: Argo CD vs Flux v2

### Argo CD Architecture & Application CRD
Argo CD opera como un controlador in-cluster que compara el estado deseado en Git con el estado en vivo de Kubernetes.

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
    syncOptions:
    - CreateNamespace=true
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenGitOps Principles — https://opengitops.dev/
- Argo CD Documentation — https://argo-cd.readthedocs.io/
- Flux v2 Documentation — https://fluxcd.io/flux/