# 3.2 Applying RBAC and Security Controls Across Platform Resources

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

El control de acceso basado en roles (**RBAC**) y las medidas de hardened de seguridad son fundamentales para controlar qué usuarios y ServiceAccounts pueden interactuar con los recursos de la API de Kubernetes.

---

## 1. Arquitectura RBAC (Role, ClusterRole, RoleBinding, ClusterRoleBinding)

### Principio de Mínimo Privilegio (Least Privilege)
- **Role / RoleBinding**: Ámbito limitado a un único namespace.
- **ClusterRole / ClusterRoleBinding**: Ámbito global del clúster (nodos, PVs, namespaces).

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-developer-role
rules:
- apiGroups: ["", "apps"]
  resources: ["pods", "deployments", "services"]
  verbs: ["get", "list", "watch", "create", "update"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
```

---

## 2. Pod Security Standards (PSS) y Pod Security Admission (PSA)

Reemplazo nativo de PodSecurityPolicies (PSP). PSA aplica niveles de seguridad mediante labels en los Namespaces:

- **Privileged**: Sin restricciones (para agentes de infraestructura como CNI/Prometheus).
- **Baseline**: Previene escalamiento de privilegios conocido.
- **Restricted**: Aplica las mejores prácticas extremas de hardened (no root, read-only root filesystem, drop ALL capabilities).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-secure
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/