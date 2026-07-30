# 5.2 Implementing Workflows for Self-Service Provisioning Using Platform APIs

## Motivación y Self-Service Provisioning

El aprovisionamiento autoservicio (**Self-Service Provisioning**) mediante herramientas como **Crossplane** permite componer infraestructura en la nube utilizando manifiestos y la API de Kubernetes.

---

## 1. Crossplane Compositions & XRDs

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgres.aws.database.example.com
spec:
  compositeTypeRef:
    apiVersion: database.example.com/v1alpha1
    kind: XPostgres
  resources:
  - name: rdsInstance
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: Instance
      spec:
        forProvider:
          region: us-east-1
          dbInstanceClass: db.t3.micro
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Crossplane — https://www.crossplane.io/