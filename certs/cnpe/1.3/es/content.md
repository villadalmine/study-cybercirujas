# 1.3 Optimizing Multi-Tenancy Resource Usage

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

En plataformas cloud native corporativas, la **multitenencia (Multi-Tenancy)** permite que múltiples equipos, proyectos o aplicaciones compartan la misma infraestructura de Kubernetes garantizando aislamiento estricto, seguridad y uso optimizado de recursos. Este tema aborda los modelos de aislamiento, cuotas, límites y aislamiento jerárquico necesarios para operar una plataforma multi-tenant eficiente.

---

## 1. Modelos de Multitenencia: Hard vs Soft Multi-Tenancy

- **Soft Multi-Tenancy (Multitenencia Suave)**: Compartición de un mismo clúster entre equipos dentro de una misma organización confiable. Se logra aislando mediante `Namespaces`, `RBAC`, `ResourceQuotas` y `LimitRanges`.
- **Hard Multi-Tenancy (Multitenencia Fuerte)**: Compartición de infraestructura entre tenants no confiables o externos. Requiere aislamiento a nivel de kernel/runtime (ej. Kata Containers, gVisor) o clústeres dedicados virtuales (vcluster).

---

## 2. Aislamiento Físico y Lógico con Namespaces, ResourceQuotas y LimitRanges

### ResourceQuotas
Un `ResourceQuota` limita el consumo total acumulado de recursos (CPU, memoria, storage, número de objetos) dentro de un namespace específico.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-quota
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services.loadbalancers: "2"
```

### LimitRanges
Un `LimitRange` impone valores por defecto y rangos permitidos (mínimo y máximo) para las solicitudes de CPU/Memoria de cada contenedor individual creado en el namespace.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-a-limits
  namespace: tenant-a
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "200m"
      memory: "256Mi"
    max:
      cpu: "2"
      memory: "4Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container
```

---

## 3. Multitenencia Jerárquica (Hierarchical Namespace Controller - HNC)

El proyecto **HNC (Hierarchical Namespace Controller)** de la CNCF permite crear relaciones padre-hijo entre namespaces, propagando automáticamente políticas de seguridad (RBAC, NetworkPolicies, ResourceQuotas) desde los namespaces de la plataforma hacia los namespaces de los sub-equipos.

```bash
# Ejemplo de creación de sub-namespace con HNC CLI
kubectl hns create team-subproject -n tenant-a-parent
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Multi-tenancy Best Practices — https://kubernetes.io/docs/concepts/security/multi-tenancy/
- ResourceQuotas & LimitRanges — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Hierarchical Namespace Controller (HNC) — https://github.com/kubernetes-sigs/hierarchical-namespaces