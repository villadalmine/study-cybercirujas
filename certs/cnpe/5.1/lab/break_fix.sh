# 5.1 Designing and Creating Custom Resource Definitions (CRDs) for Platform Services

## Motivación y Extensión de las APIs de Kubernetes

Las **Custom Resource Definitions (CRDs)** permiten extender la API de Kubernetes para crear abstraer servicios de plataforma propios (Internal Developer Platforms - IDP) como si fueran recursos nativos.

---

## 1. Estructura de una Custom Resource Definition (apiextensions.k8s.io/v1)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.platform.example.com
spec:
  group: platform.example.com
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              engine:
                type: string
                enum: ["postgres", "mysql"]
              storageGb:
                type: integer
                minimum: 5
          status:
            type: object
            properties:
              ready:
                type: boolean
  scope: Namespaced
  names:
    plural: databases
    singular: database
    kind: Database
    shortNames:
    - db
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Custom Resources — https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/