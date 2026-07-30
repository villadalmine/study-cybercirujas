# 1.3 Optimizing Multi-Tenancy Resource Usage

## Motivación y Arquitectura de Multitenencia en Kubernetes

En plataformas cloud native empresariales, la **multitenencia (Multi-Tenancy)** permite que múltiples equipos, proyectos o aplicaciones de negocio compartan la misma infraestructura de Kubernetes garantizando aislamiento estricto, seguridad y un empaquetado de recursos optimizado (*Bin-Packing*).

Sin una estrategia de multitenencia adecuada, las organizaciones sufren dos extremos ineficientes:
1. **Proliferación de Clústeres (Cluster Sprawl)**: Cada equipo opera su propio clúster de Kubernetes, multiplicando los costos fijos de planos de control, nodos worker ociosos y sobrecarga operacional de mantenimiento.
2. **"Noisy Neighbor" (Vecino Ruidoso)**: Un tenant dentro de un clúster compartido agota la memoria o CPU de un nodo, provocando la caída o degradación imprevista de las aplicaciones adyacentes.

---

## 1. Modelos de Aislamiento: Soft vs Hard Multi-Tenancy

| Criterio | Soft Multi-Tenancy (Multitenencia Suave) | Hard Multi-Tenancy (Multitenencia Fuerte) |
|---|---|---|
| **Público Objetivo** | Equipos o departamentos dentro de la misma organización confiable | Clientes externos o tenants no confiables (SaaS) |
| **Mecanismo Principal** | Lógico: `Namespaces`, `RBAC`, `ResourceQuotas`, `LimitRanges`, `NetworkPolicies` | Cómputo/Kernel: Runtimes aislados (Kata Containers, gVisor) o clústeres virtuales (`vcluster`) |
| **Sobrecarga Operacional** | Mínima; un solo plano de control y un pool común de nodos | Media-Alta; virtualización de kernel o múltiples apiservers |
| **Superficie de Ataque** | El kernel del nodo se comparte entre todos los Pods | El kernel del nodo está protegido por microVMs o aislamiento estricto |

---

## 2. Aislamiento Lógico y Gobernanza de Recursos en el Namespace

### 2.1 ResourceQuotas: Control de Consumo Agregado

Un `ResourceQuota` limita el consumo total de recursos físicos y la cantidad de objetos creados dentro de un namespace específico.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-finance-quota
  namespace: tenant-finance
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    pods: "30"
    services.loadbalancers: "2"
    persistentvolumeclaims: "10"
    requests.storage: 200Gi
```

### 2.2 LimitRanges: Inyección de Valores por Defecto y Rangos de Contenedor

Un `LimitRange` aplica restricciones a nivel de contenedor individual, impidiendo que un desarrollador cree Pods sin especificar `requests`/`limits` o intente solicitar recursos excesivos que monopolicen el namespace.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-finance-limits
  namespace: tenant-finance
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "200m"
      memory: "256Mi"
    max:
      cpu: "4"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container
```

---

## 3. Multitenencia Jerárquica (Hierarchical Namespace Controller - HNC)

El proyecto **HNC (Hierarchical Namespace Controller)** de la CNCF introduce el concepto de relaciones padre-hijo entre namespaces. Permite definir una estructura organizacional donde las políticas de seguridad (RBAC, NetworkPolicies, ResourceQuotas) del namespace padre se heredan automáticamente en los sub-namespaces creados por los equipos.

```
       [platform-org-parent]  <-- HNC Parent (Administrado por Infra)
                |
     +----------+----------+
     |                     |
[tenant-team-a]       [tenant-team-b]  <-- HNC Sub-namespaces (Heredan RBAC y Cuotas)
```

Instalación de HNC CLI y creación de relaciones jerárquicas:

```bash
# Crear un sub-namespace hijo que hereda las políticas del padre
kubectl hns create team-subproject -n tenant-finance
```

---

## 4. Virtual Clusters (vcluster): Aislamiento Control Plane Independiente

`vcluster` crea un clúster virtual ligero de Kubernetes dentro de un namespace de un clúster anfitrión. Cada tenant obtiene su propio `kube-apiserver` y `etcd` dedicados, mientras que los Pods reales se ejecutan en los nodos del clúster físico base.

```bash
# Creación de un vcluster aislado para un tenant
vcluster create tenant-alpha-cluster -n tenant-alpha-ns

# Conexión al apiserver virtual del tenant
vcluster connect tenant-alpha-cluster -n tenant-alpha-ns
```

---

## Verificación y Diagnóstico de Cuotas Multi-Tenant

### Comandos de Inspección de Cuotas y Límites

```bash
# Consultar el consumo actual de ResourceQuotas en un namespace
$ kubectl get quota -n tenant-finance
NAME                   REQUESTS                                    LIMITS
tenant-finance-quota   requests.cpu: 4200m/8, requests.memory: 8Gi/16Gi   limits.cpu: 8/16, limits.memory: 16Gi/32Gi

# Verificar detalles de un pod que heredó valores por defecto del LimitRange
$ kubectl get pod test-pod -n tenant-finance -o jsonpath='{.spec.containers[0].resources}'
{"default":{"cpu":"500m","memory":"512Mi"},"defaultRequest":{"cpu":"200m","memory":"256Mi"}}
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Multi-Tenancy Guide — https://kubernetes.io/docs/concepts/security/multi-tenancy/
- Hierarchical Namespace Controller (HNC) — https://github.com/kubernetes-sigs/hierarchical-namespaces
- Loft vcluster Virtual Kubernetes — https://www.vcluster.com/docs/