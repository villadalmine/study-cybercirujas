# 1.1 Platform Architecture Best Practices for Networking, Storage, and Compute

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El diseño de una **Internal Developer Platform (IDP)** sobre Kubernetes requiere tomar decisiones de arquitectura en tres capas fundamentales: **Networking**, **Storage** y **Compute**. El objetivo principal es ofrecer **Golden Paths** (rutas automatizadas y opinadas) sin sacrificar flexibilidad ni el cumplimiento de las mejores prácticas de infraestructura cloud native.

---

## 1. Networking de Plataforma

- **Elección del CNI**: Uso de plugins CNI modernos como **Cilium** (basado en eBPF para alto rendimiento, visibilidad L3-L7 y encriptación transparente con WireGuard) o **Calico** (basado en IPTables/IPVS con soporte estricto de NetworkPolicies).
- **Ingress Controller y Service Mesh**: Implementación de controladores Ingress (como Ingress-Nginx o Envoy Gateway) combinados con Service Mesh (Istio o Linkerd) para mTLS automático y observabilidad entre microservicios.

---

## 2. Storage de Plataforma

- **Dynamic Provisioning con CSI**: Configuración de `StorageClasses` predefinidas clasificadas por niveles de servicio (`fast-ssd`, `standard-hdd`).
- **Políticas de Retención**: Aplicación de `reclaimPolicy: Retain` para volúmenes de datos críticos (bases de datos) y `volumeBindingMode: WaitForFirstConsumer` para optimizar la topología multizona.

---

## 3. Compute y Aislamiento de Cargas de Trabajo

- **Taints y Tolerations**: Aislar nodos dedicados (ej. nodos GPU o nodos de infraestructura de control).
- **NodeAffinity y TopologySpreadConstraints**: Distribuir los Pods de forma uniforme entre zonas de disponibilidad para alta disponibilidad.

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes Networking & CNI Docs — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Cilium eBPF Architecture — https://cilium.io/