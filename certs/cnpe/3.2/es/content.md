# 3.2 Applying RBAC and Security Controls Across Platform Resources

## Motivación y Gobierno de Accesos en la Plataforma

El control de acceso basado en roles (**RBAC - Role-Based Access Control**) y las políticas de hardening a nivel de Pod (Pod Security Admission) constituyen la primera línea de defensa para prevenir accesos no autorizados a las APIs de Kubernetes y movimientos laterales en el clúster.

---

## 1. Arquitectura RBAC (Roles, ClusterRoles, Bindings)

### Principio de Mínimo Privilegio (Least Privilege)
- **Role / RoleBinding**: Ámbito limitado a un namespace específico.
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

## 2. Pod Security Admission (PSA) y Pod Security Standards (PSS)

Pod Security Admission reemplaza las antiguas PSPs imponiendo niveles de seguridad mediante etiquetas en los Namespaces:

- **Privileged**: Sin restricciones (para agentes de infraestructura como CNI/Prometheus).
- **Baseline**: Previene escalamiento de privilegios conocido.
- **Restricted**: Aplica las mejores prácticas extremas de hardening (no root, read-only root filesystem, drop ALL capabilities).

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

## Verificación de Permisos RBAC (`auth can-i`)

```bash
# Verificar si una ServiceAccount puede eliminar pods en un namespace
$ kubectl auth can-i delete pods --as=system:serviceaccount:tenant-a:dev-sa -n tenant-a
yes
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Kubernetes RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/