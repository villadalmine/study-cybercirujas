# 2.4 Kubernetes Security Essentials and Hardening

## Motivación y Hardening de Seguridad en Kubernetes

El control de acceso basado en roles (**RBAC**) y las políticas de hardening a nivel de Pod (**Pod Security Admission**) constituyen la primera línea de defensa para prevenir accesos no autorizados a las APIs de Kubernetes.

---

## 1. Arquitectura RBAC

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

## 2. Pod Security Admission (PSA)

- **Privileged**: Sin restricciones.
- **Baseline**: Previene escalamiento de privilegios conocido.
- **Restricted**: Hardening extremo (no root, read-only root filesystem, drop ALL capabilities).

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-secure
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Kubernetes RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/