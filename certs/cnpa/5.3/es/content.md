# 5.3 Kubernetes Networking Model and CNI Plugins

## Motivación y Modelo de Red Flat de Kubernetes

El modelo de red de Kubernetes establece que cada Pod recibe una dirección IP única y routable sin NAT, implementado mediante plugins **CNI (Container Network Interface)** como **Cilium**, **Calico** o **Flannel**.

---

## 1. Requisitos del Modelo de Red de Kubernetes

1. Cada Pod obtiene su propia dirección IP (sin compartir con otros Pods).
2. Los Pods en cualquier nodo pueden comunicarse directamente con Pods en cualquier otro nodo sin NAT.
3. Los agentes del nodo (kubelet, kube-proxy) pueden comunicarse con todos los Pods del nodo.

---

## 2. CNI Plugins y Arquitectura

| Plugin CNI | Plano de Datos | Características Principales |
|---|---|---|
| **Cilium** | eBPF (kernel) | NetworkPolicy L3-L7, cifrado WireGuard, observabilidad Hubble |
| **Calico** | iptables / eBPF | BGP peering, NetworkPolicy avanzada, IPAM flexible |
| **Flannel** | VXLAN / host-gw | Simple, overlay L2, sin NetworkPolicy nativa |

---

## 3. NetworkPolicy para Microsegmentación

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: platform-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

Esta política implementa **default deny** para todo el tráfico de entrada al namespace `platform-prod`. Los Pods solo podrán recibir tráfico si una NetworkPolicy adicional lo permite explícitamente.

---

## Verificación de Conectividad de Red

```bash
# Verificar conectividad Pod-a-Pod entre nodos
$ kubectl exec -n platform-prod deploy/frontend -- curl -s http://backend-svc:8080/health
{"status": "healthy"}

# Listar las políticas de red activas
$ kubectl get networkpolicy -n platform-prod
NAME                POD-SELECTOR   AGE
deny-all-ingress    <none>         5m
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes Network Model — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Cilium CNI Documentation — https://docs.cilium.io/