# 3.7 GitOps for Multi-Environment Application Management

## Motivación y Gestión Multi-Entorno con GitOps

Gestión declarativa de entornos de aplicación (dev, staging, prod) utilizando **Kustomize** o **Helm** integrados con mallas de GitOps (**Argo CD ApplicationSets**).

---

## 1. Patrón Kustomize (Bases y Overlays)

```
apps/
├── base/
│   ├── deployment.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kustomize Documentation — https://kustomize.io/
- Argo CD ApplicationSets — https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/