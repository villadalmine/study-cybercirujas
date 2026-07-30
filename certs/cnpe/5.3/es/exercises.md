# 5.3 Using Kubernetes Operators for Platform Automation and Integration

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El **Operator Pattern** codifica el conocimiento operacional humano (backups, failover, upgrades) dentro de software automatizado que gestiona aplicaciones complejas mediante Custom Resources (CRs) y bucles de reconciliación en Kubernetes.

---

## 1. El Bucle de Reconciliación (Reconcile Loop)

Un Operador observa continuamente el estado actual del clúster a través del API Server, compara con el estado deseado declarado en la CR, y ejecuta acciones corregidoras.

$$\text{Observe} \longrightarrow \text{Analyze (Diff)} \longrightarrow \text{Act (Reconcile)}$$

---

## 2. Frameworks de Desarrollo de Operadores: Operator SDK & Kubebuilder

- **Operator SDK**: Framework de la CNCF para construir operadores en Go, Ansible o Helm.
- **Controller-runtime (Go)**: Librería estándar subyacente para implementar los controladores de reconciliación.

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Operator Pattern Architecture — https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- Operator SDK Documentation — https://sdk.operatorframework.io/