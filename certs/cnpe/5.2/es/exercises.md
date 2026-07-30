# 5.2 Implementing Workflows for Self-Service Provisioning Using Platform APIs

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El aprovisionamiento autoservicio (**Self-Service Provisioning**) abstrae la complejidad de la infraestructura para que los equipos de desarrollo puedan solicitar recursos (bases de datos, colas de mensajes, entornos) de forma declarativa e independiente a través de las APIs de la plataforma.

---

## 1. Patrón de Control Planes de Plataforma (Crossplane vs Kratix)

### Crossplane (CNCF Incubating)
Crossplane extiende Kubernetes convirtiéndolo en un Control Plane universal que compone infraestructura cloud (AWS, GCP, Azure) como recursos Kubernetes nativos (`Compositions` y `Composite Resource Definitions - XRDs`).

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
- Crossplane Documentation — https://www.crossplane.io/