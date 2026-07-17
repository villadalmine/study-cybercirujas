# 3.5 Security

## Los 4Cs de Cloud Native Security

La seguridad en un entorno cloud native se modela como capas concéntricas, donde cada capa depende de que las capas que la rodean estén correctamente aseguradas:

1. **Cloud (o Co-lo/Corporate datacenter)**: la infraestructura subyacente (proveedor cloud, datacenter propio). Incluye IAM del proveedor, seguridad de red perimetral, cifrado de discos.
2. **Cluster**: la configuración del cluster de Kubernetes en sí (API server, etcd, kubelet, políticas de admisión).
3. **Container**: la seguridad de la imagen de contenedor y su runtime (vulnerabilidades, privilegios, superficie de ataque).
4. **Code**: la seguridad del código de la aplicación (dependencias, secretos hardcodeados, vulnerabilidades propias).

Una falla en una capa interna no puede compensarse solo con seguridad en las capas externas: si el código de la aplicación tiene una vulnerabilidad crítica, un cluster bien configurado reduce el impacto pero no lo elimina.

## Seguridad a nivel de Cluster

### API Server: autenticación y autorización

Todo request al API server pasa por tres fases:

1. **Authentication**: verifica *quién* hace el request (certificados de cliente, tokens de service account, OIDC, etc.).
2. **Authorization**: verifica *qué puede hacer* ese usuario/service account. El modo más usado es **RBAC** (Role-Based Access Control).
3. **Admission Control**: intercepta el request después de autenticar/autorizar pero antes de persistirlo en etcd, permitiendo validar o mutar el objeto.

### RBAC

RBAC se define con cuatro objetos:

- `Role`: permisos dentro de un namespace.
- `ClusterRole`: permisos a nivel de cluster (o reutilizable en varios namespaces).
- `RoleBinding`: asocia un `Role` (o `ClusterRole`) a un usuario/grupo/service account, dentro de un namespace.
- `ClusterRoleBinding`: asocia un `ClusterRole` a nivel de todo el cluster.

Ejemplo: un `Role` que solo permite leer Pods en el namespace `dev`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: dev
subjects:
- kind: User
  name: jane
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Verificar permisos de un usuario o service account:

```console
$ kubectl auth can-i list pods --namespace dev --as jane
yes

$ kubectl auth can-i delete deployments --namespace dev --as jane
no
```

El principio rector es **least privilege**: otorgar solo los verbs y resources estrictamente necesarios.

### Service Accounts

Cada Pod se ejecuta con una identidad de **ServiceAccount** (por defecto, `default` en su namespace). El token de la ServiceAccount se monta automáticamente en el Pod y se usa para autenticarse contra el API server.

```console
$ kubectl create serviceaccount ci-bot -n dev
$ kubectl get sa ci-bot -n dev -o yaml
```

Buenas prácticas:
- Deshabilitar el automount del token si el Pod no necesita hablar con el API server (`automountServiceAccountToken: false`).
- Crear ServiceAccounts dedicadas por aplicación en lugar de usar `default`.

### Secrets

Los `Secret` almacenan datos sensibles (contraseñas, tokens, llaves) codificados en base64 (no cifrados por defecto en etcd, salvo que se habilite **encryption at rest**).

```console
$ kubectl create secret generic db-creds \
  --from-literal=username=admin \
  --from-literal=password=S3cr3t!

$ kubectl get secret db-creds -o jsonpath='{.data.username}' | base64 -d
admin
```

Consideraciones:
- Base64 **no es cifrado**, es solo codificación reversible.
- Habilitar `EncryptionConfiguration` para cifrar Secrets en etcd.
- Restringir vía RBAC quién puede hacer `get`/`list` sobre Secrets.
- Considerar soluciones externas de gestión de secretos (HashiCorp Vault, cloud KMS) integradas vía CSI driver o external-secrets.

### Admission Control

Los **admission controllers** interceptan requests luego de authN/authZ. Se dividen en:

- **Mutating**: pueden modificar el objeto (ej. inyectar un sidecar).
- **Validating**: solo aceptan o rechazan el objeto.

Kubernetes permite webhooks dinámicos (`MutatingAdmissionWebhook`, `ValidatingAdmissionWebhook`) para lógica custom. Proyectos como **OPA/Gatekeeper** y **Kyverno** se usan para aplicar políticas (ej. "no se permiten imágenes sin tag específico", "todo Pod debe tener `resources.limits`").

### Network Policies

Por defecto, todos los Pods de un cluster pueden comunicarse entre sí sin restricción. `NetworkPolicy` permite definir reglas de ingreso/egreso a nivel de Pod, pero requiere que el **CNI plugin** las soporte (ej. Calico, Cilium; el CNI básico de algunos providers no las implementa).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: dev
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

Este manifiesto bloquea todo el tráfico entrante hacia los Pods del namespace `dev`, salvo que otra `NetworkPolicy` lo permita explícitamente.

## Seguridad a nivel de Container

### Pod Security Standards

Kubernetes define tres perfiles de seguridad para Pods (reemplazan a los deprecated PodSecurityPolicies):

- **Privileged**: sin restricciones.
- **Baseline**: bloquea escalamientos de privilegios conocidos, permite configuraciones por defecto razonables.
- **Restricted**: fuertemente restringido, sigue hardening best practices (no root, no privilege escalation, filesystem read-only, etc.).

Se aplican vía labels en el namespace, usando el **Pod Security Admission** controller (built-in desde v1.25):

```console
$ kubectl label namespace dev \
  pod-security.kubernetes.io/enforce=restricted
```

### securityContext

Define restricciones de seguridad a nivel de Pod o container:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
  - name: app
    image: myapp:1.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

Puntos clave: correr como usuario no-root, deshabilitar escalamiento de privilegios, sistema de archivos raíz de solo lectura, y quitar Linux capabilities innecesarias.

## Seguridad a nivel de Code (imagen y supply chain)

- **Escaneo de vulnerabilidades**: herramientas como Trivy o Grype analizan imágenes buscando CVEs conocidos antes de desplegarlas.
- **Imágenes mínimas**: usar distroless o Alpine reduce la superficie de ataque.
- **Firma de imágenes**: proyectos como **Sigstore/Cosign** permiten firmar y verificar la procedencia de una imagen (supply chain security).
- **SBOM (Software Bill of Materials)**: inventario de componentes de una imagen, útil para auditar dependencias.

```console
$ trivy image myapp:1.0
```

## Otros conceptos relevantes

- **kube-bench**: herramienta del CIS (Center for Internet Security) que audita la configuración del cluster contra el CIS Kubernetes Benchmark.
- **Falco**: detección de comportamiento anómalo en runtime (ej. un proceso inesperado dentro de un contenedor).
- **mTLS entre servicios**: los service mesh (Istio, Linkerd) pueden cifrar automáticamente el tráfico este-oeste entre Pods.

## Referencias

- CNCF Curriculum — KCNA: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Docs — Controlling Access to the Kubernetes API: https://kubernetes.io/docs/concepts/security/controlling-access/
- Kubernetes Docs — RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes Docs — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes Docs — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes Docs — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes Docs — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes Docs — Security Context: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Sigstore: https://www.sigstore.dev/
- CIS Kubernetes Benchmark / kube-bench: https://github.com/aquasecurity/kube-bench
- Falco: https://falco.org/docs/