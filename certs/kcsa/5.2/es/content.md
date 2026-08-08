# Guía de Estudio KCSA — Tema 5.2: Image Repository

## 1. Motivación de Producción y Problema Arquitectónico

### 1.1 El Panorama de Amenazas en la Cadena de Suministro de Contenedores
En entornos empresariales de Kubernetes, los repositorios de imágenes de contenedores sirven como la puerta de enlace entre el desarrollo de software y el runtime del clúster. Los controles de seguridad débiles en la capa del repositorio exponen a los clústeres a severos vectores de ataque en la cadena de suministro:

1. **Mutación de Floating Tags y Alteración de Imágenes**: Los tags de contenedor (por ejemplo, `:latest` o `:v1.2.0`) son punteros mutables en registros OCI. Un adversario que obtenga acceso de escritura a un repositorio interno o público puede sobrescribir un tag de imagen legítimo con una build maliciosa que contenga puertas traseras (backdoors) o minadores de criptomonedas (crypto-miners). Si Kubelet realiza el pull por tag en lugar de utilizar el digest de contenido SHA256 inmutable, las cargas de trabajo (workloads) en ejecución absorberán silenciosamente binarios comprometidos.
2. **Proliferación y Dispersión de Credenciales**: Gestionar el acceso a registros de imágenes privados utilizando objetos `corev1.Secret` estáticos de Kubernetes (`kubernetes.io/dockerconfigjson`) introduce riesgos operacionales. Estos secrets a menudo se duplican a través de múltiples namespaces, se almacenan sin encriptar en reposo en `etcd`, y quedan registrados en los logs de los pipelines de CI/CD, aumentando la superficie de ataque para el robo de credenciales.
3. **Typosquatting de Repositorios y Pulls No Controlados**: Sin políticas explícitas de restricción de registros, los desarrolladores o los manifiestos de deployment comprometidos pueden hacer referencia a registros externos no autorizados, públicos o no confiables (`docker.io/malicious-user/nginx` en lugar de `private-registry.enterprise.internal/base/nginx`).
4. **Ingesta de Artefactos Vulnerables**: Las imágenes que se descargan mediante pull sin un escaneo de vulnerabilidades obligatorio o sin la verificación de atestación criptográfica introducen CVEs conocidos y software no conforme directamente en nodos de producción con altos privilegios.

### 1.2 Mecánica Interna: Flujo de Trabajo de Pull en OCI Registry e Intercepción de Admisión
Cuando un Pod se programa (scheduled) en un nodo, el proceso sigue una secuencia estructurada:

```
[ kubectl apply ] 
       │
       ▼
[ API Server ] ──(Validating Webhook)──► [ Policy Engine: Kyverno / OPA Gatekeeper ]
       │                                     (Verifies Signature & Registry Domain)
       │ (Persisted to etcd)
       ▼
[ Kubelet ] ──(CRI gRPC)──► [ Container Runtime: containerd / CRI-O ]
                                 │
                                 ├──► [ Credential Provider Plugin / imagePullSecrets ]
                                 │      (Retrieves Ephemeral OCI Token)
                                 │
                                 └──► [ OCI Registry API v2 ]
                                        (Pulls Layers by SHA256 Digest)
```

1. **Fase de Admisión**: El API Server pasa la especificación del Pod (Pod spec) a través de Validating Admission Webhooks (por ejemplo, Kyverno o Gatekeeper). El motor de políticas intercepta la solicitud, verifica si la URL de la imagen coincide con los registros permitidos y valida las firmas criptográficas (por ejemplo, Sigstore/Cosign) contra los logs de transparencia de Rekor o claves públicas de confianza.
2. **Resolución de Credenciales**: Si es aceptado, Kubelet invoca la Container Runtime Interface (CRI) para realizar el pull de la imagen. El runtime resuelve los tokens de autorización consultando primero los `imagePullSecrets` a nivel de Pod, recurriendo a los `imagePullSecrets` de la ServiceAccount y, finalmente, ejecutando plugins dynamic Kubelet Credential Provider a nivel de Nodo.
3. **Obtención de Capas y Verificación de Manifiesto**: El runtime se comunica con la API de OCI Registry v2 a través de TLS 1.3, recupera el índice del manifiesto de la imagen, resuelve los tarballs de las capas mediante digests direccionables por contenido (`sha256:...`) y los extrae en la capa de almacenamiento (storage overlay) del nodo.

---

## 2. Comparativas Técnicas y Trade-offs

### Tabla 2.1: Mecanismos de Autenticación en Registros y Entrega de Credenciales

| Dimensión | Static Kubernetes `imagePullSecrets` | Kubelet Credential Provider Plugin | Cloud IAM / Workload Identity (IRSA/WI) |
| :--- | :--- | :--- | :--- |
| **Mecanismo** | `dockerconfigjson` Secrets con alcance de Namespace vinculados a Pods o ServiceAccounts. | Binario ejecutable llamado bajo demanda por Kubelet para obtener tokens efímeros. | El Nodo/Pod asume un rol de Cloud IAM mediante un intercambio de tokens OIDC para autenticarse en ECR/GAR/ACR. |
| **Tiempo de Vida de las Credenciales** | Autenticación básica estática de larga duración o tokens de API permanentes. | Tokens dinámicos de corta duración (15 min – 12 horas). | Tokens efímeros de corta duración gestionados por STS/OIDC. |
| **Sobrecarga Operacional** | Alta. Requiere la distribución de secrets entre namespaces mediante operadores o GitOps. | Media. Requiere la instalación en daemonset/AMI del binario del plugin en las imágenes de nodo. | Baja una vez que el proveedor OIDC en la nube y los roles IAM están aprovisionados. |
| **Perfil de Riesgo de Seguridad** | Alto riesgo de exposición de secrets en `etcd`, pipelines de CI/CD y acceso de lectura por RBAC. | Bajo riesgo; las credenciales permanecen en la memoria del nodo y nunca se almacenan en objetos de la API de Kubernetes. | Cero almacenamiento estático de secrets en Kubernetes; estrictamente regulado por relaciones de confianza de roles IAM. |
| **Alcance del Acceso** | Por namespace o por ServiceAccount. | A nivel de todo el nodo para patrones de dominio de imagen coincidentes. | Por nodo o por rol de IAM de Pod. |

### Tabla 2.2: Modelos de Verificación de Integridad y Proveniencia de Imágenes

| Dimensión | Verificación Basada en Claves con Cosign | Sigstore Keyless (Fulcio + Rekor) | Docker Content Trust (Notary v1) |
| :--- | :--- | :--- | :--- |
| **Ancla de Identidad** | Par de claves asimétricas (RSA/ECDSA) almacenado en KMS o gestor de secrets. | Certificado x509 de corta duración emitido por la CA Fulcio a través de un Proveedor de Identidad OIDC (GitHub/Google). | Claves X.509 estáticas gestionadas a través del estado de repositorio local de la CLI de Notary. |
| **Auditabilidad** | Limitada a la posesión de la clave; sin registro de auditoría público de solo anexo (append-only). | Alta. Las firmas se registran en el log de transparencia inmutable público/privado de Rekor. | Moderada; se basa en las marcas de tiempo (timestamps) del servidor Notary. |
| **Gestión de Claves** | Rotación manual, almacenamiento seguro y riesgo de compromiso de la clave privada. | Sin claves (Keyless). Sin gestión de claves privadas; la identidad está vinculada a las demandas (claims) de identidad OIDC. | Jerarquía de claves compleja (claves root, target, snapshot, timestamp). |
| **Integración con K8s** | Soporte nativo en Kyverno, Gatekeeper/Ratify y Connaisseur. | Integración nativa con motores de admisión modernos a través de comprobaciones del emisor OIDC. | Heredado (Legacy); obsoleto en los estándares modernos de la cadena de suministro OCI. |

---

## 3. Manifiestos Completos de Producción y Configuraciones de Infraestructura

### 3.1 ServiceAccount Segura con `imagePullSecrets` Explícitos y Especificación Restringida
Este manifiesto configura una carga de trabajo de producción restringida a utilizar una ServiceAccount explícita que contiene las credenciales para el pull de imágenes, al tiempo que impone la fijación por digest (digest pinning) y `imagePullPolicy: Always`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-processing
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Secret
metadata:
  name: internal-registry-creds
  namespace: payment-processing
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ewogICJhdXRocyI6IHsKICAgICJyZWdpc3RyeS5wcm9kdWN0aW9uLmludGVybmFsIjogewogICAgICAiYXV0aCI6ICJZbVZrY21sdGFXNWxYM05sWTNKbGRGOTBZV3A1T25OMFlXMWxYMEU9IgogICAgfQogIH0KfQ==
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-service-sa
  namespace: payment-processing
imagePullSecrets:
  - name: internal-registry-creds
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payment-processing
  labels:
    app.kubernetes.io/name: payment-api
    app.kubernetes.io/part-of: checkout-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      serviceAccountName: payment-service-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-server
          image: registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "128Mi"
          ports:
            - containerPort: 8443
              name: https
```

### 3.2 Configuración de Credential Provider Dinámico de Kubelet
Esta configuración se despliega directamente en los nodos de Kubelet (`/etc/kubernetes/credential-provider-config.yaml`) para permitir la obtención de tokens IAM de corta duración fuera de banda (out-of-band) para AWS ECR sin utilizar secrets estáticos en etcd.

```yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr-fips.*.amazonaws.com"
      - "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - get-credentials
    env:
      - name: AWS_STS_REGIONAL_ENDPOINTS
        value: regional
```

### 3.3 Kyverno ClusterPolicy: Imponiendo la Fuente del Registro y la Verificación de Imágenes Keyless de Cosign
Esta política a nivel de clúster aplica dos controles de producción no negociables:
1. Rechaza cualquier imagen de contenedor que provenga de fuera del dominio del registro interno de confianza.
2. Verifica que las imágenes descargadas por pull desde el dominio de confianza contengan una firma keyless válida generada mediante Sigstore/Fulcio vinculada a la identidad OIDC del repositorio empresarial de GitHub Actions.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-provenance-and-registry
  annotations:
    policies.kyverno.io/title: Enforce Image Provenance and Registry Lockdown
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Container
    kyverno.io/kyverno-version: 1.10.0
    kyverno.io/kubernetes-version: "1.26-1.28"
    description: >-
      Blocks untrusted registries and verifies Cosign keyless signatures via Fulcio/Rekor.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  failurePolicy: Fail
  rules:
    - name: restrict-registry-source
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Container image source is untrusted. Images must originate from registry.production.internal."
        pattern:
          spec:
            containers:
              - image: "registry.production.internal/*"
            =(initContainers):
              - image: "registry.production.internal/*"
            =(ephemeralContainers):
              - image: "registry.production.internal/*"

    - name: verify-cosign-keyless-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "registry.production.internal/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/enterprise-org/secure-repo/.github/workflows/build-pipeline.yml@refs/heads/main"
                    rekor:
                      url: "https://rekor.sigstore.dev"
```

---

## 4. Comandos Reales de CLI y Salidas de Terminal

### 4.1 Firma Keyless de Imágenes de Contenedor con Cosign
Generando una firma keyless autenticada con OIDC para un digest de imagen utilizando Google Cloud Identity / OpenID Connect:

```bash
$ cosign sign --yes registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```text
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
Successfully obtained OIDC token for identity: developer@enterprise.com
Issuer: https://accounts.google.com
Url: https://fulcio.sigstore.dev
Creating signature with ephemeral key...
Uploading signature to registry...
Logging entry to Rekor transparency log...
Rekor entry created at index: 29481048
Signature uploaded to: registry.production.internal/finance/payment-api:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.sig
```

### 4.2 Verificación Manual de Firma con Cosign
Verificando la firma keyless contra Fulcio y la CLI del log de transparencia de Rekor antes del despliegue:

```bash
$ cosign verify \
  --certificate-identity "https://github.com/enterprise-org/secure-repo/.github/workflows/build-pipeline.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```text
Verification for registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The claims were verified against the signature: true
  - Certificate is trusted by Fulcio Root CA
  - Certificate log entry was verified in Rekor transparency log
  - Certificate identity matches policy specification

[{"critical":{"identity":{"docker-reference":"registry.production.internal/finance/payment-api"},"image":{"docker-manifest-digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"type":"cosign container image signature"},"optional":{"GitHubWorkflowTrigger":"push","GitHubWorkflowSha":"a1b2c3d4e5f67890123456789abcdef012345678"}}]
```

### 4.3 Escaneo Estático de Vulnerabilidades mediante Trivy con Control de Severidad
Ejecutando un escaneo estático de vulnerabilidades estricto local/CI en la imagen de destino, fallando en caso de vulnerabilidades `CRITICAL` o `HIGH`:

```bash
$ trivy image \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  --ignore-unfixed \
  --format table \
  registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```text
2026-08-07T20:15:00.123Z	INFO	Vulnerability scanning is enabled
2026-08-07T20:15:00.456Z	INFO	Loaded 12415 vulnerabilities from DB

registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 (debian 12.1)
========================================================================================================================
+-------------+------------------+----------+-------------------+---------------+---------------------------------------+
|   LIBRARY   | VULNERABILITY ID | SEVERITY | INSTALLED VERSION | FIXED VERSION |                 TITLE                 |
+-------------+------------------+----------+-------------------+---------------+---------------------------------------+
| libssl3     | CVE-2023-3817    | HIGH     | 3.0.9-1           | 3.0.9-2       | OpenSSL: excessive time spending in   |
|             |                  |          |                   |               | DH check functions                    |
+-------------+------------------+----------+-------------------+---------------+---------------------------------------+

Error: exit status 1 (vulnerabilities found matching severity criteria)
```

### 4.4 Log de Rechazo por Política del Admission Controller
Intentando desplegar una imagen no autorizada (`docker.io/library/nginx:latest`) que viola la política:

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-nginx
  namespace: payment-processing
spec:
  containers:
    - name: nginx
      image: docker.io/library/nginx:latest
EOF
```

```text
Error from server (Forbidden): error when creating "STDIN": pods "untrusted-nginx" is forbidden: admission webhook "kyverno-resource-validating-webhook" denied the request:

resource Pod/payment-processing/untrusted-nginx was blocked due to the following policies:

enforce-image-provenance-and-registry:
  restrict-registry-source: 'Container image source is untrusted. Images must originate
    from registry.production.internal.'
  verify-cosign-keyless-signature: 'failed to verify image signature for docker.io/library/nginx:latest:
    no matching signatures found'
```

---

## 5. Guía de Diagnóstico y Resolución de Fallos

### 5.1 Árbol de Decisión de Diagnóstico: Fallos en el Repositorio y Pull de Imágenes

```
                    Image Pull / Pod Deployment Failure
                                     │
             ┌───────────────────────┴───────────────────────┐
             ▼                                               ▼
   Admission Phase Error                           Runtime Node Error
(Failed at API Server apply)                     (Pod state: ImagePullBackOff)
             │                                               │
   ┌─────────┴─────────┐                           ┌─────────┴─────────┐
   ▼                   ▼                           ▼                   ▼
Webhook Rejection   Policy Error               Authentication       Image/Digest
 (Kyverno/OPA)     (Timeout/Failure)              (401/403)           (404 Not Found)
   │                   │                           │                   │
 Check policy        Verify Admission            Check Secret /      Verify exact hash
 signatures /        Webhook service             Kubelet Credential  & registry network
 registry rules      latency & certs             Provider & Token    route (DNS/VPC)
```

### 5.2 Modos de Fallo Comunes en Producción y Análisis de Causa Raíz

#### Modo de Fallo 1: `ImagePullBackOff` debido a `imagePullSecrets` Faltantes o Mal Formados
* **Síntomas**: El estado del Pod muestra `ErrImagePull` o `ImagePullBackOff`. Al ejecutar `kubectl describe pod <pod-name>` se muestra:
  `Failed to pull image "registry.production.internal/finance/payment-api:v1.0.0": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference: unexpected status code 401 Unauthorized`.
* **Análisis de Causa Raíz**:
  1. El Secret de destino no existe en el namespace local del Pod (`payment-processing`). `imagePullSecrets` no puede hacer referencia a Secrets a través de límites de namespace.
  2. La clave `.dockerconfigjson` dentro del payload del Secret contiene JSON no válido o errores de decodificación en base64.
  3. La ServiceAccount carece de la vinculación (binding) al secret.
* **Pasos de Resolución**:
  1. Verificar la presencia del Secret en el namespace:
     ```bash
     $ kubectl get secret internal-registry-creds -n payment-processing -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode
     ```
  2. Validar los tokens de autenticación y asegurarse de que el hostname del registro en `.dockerconfigjson` coincida exactamente con la cadena de la imagen (`registry.production.internal` vs `http://registry.production.internal`).

#### Modo de Fallo 2: Fallo de Ejecución del Credential Provider de Kubelet
* **Síntomas**: El Pod falla al realizar el pull de imágenes desde repositorios en la nube (por ejemplo, ECR/GAR) a pesar de tener roles de IAM correctos. El log de Kubelet (`/var/log/journal/kubelet.service` o `journalctl -u kubelet`) muestra:
  `Credential provider plugin "ecr-credential-provider" failed with exit code 127` o `plugin timed out after 30s`.
* **Análisis de Causa Raíz**:
  1. La ruta del binario del proveedor de credenciales `/usr/libexec/kubernetes/kubelet-plugins/credentialprovider/exec/ecr-credential-provider` no es ejecutable (`chmod +x`) o falta en el disco del nodo.
  2. El perfil de instancia IAM del nodo carece de permisos para emitir `ecr:GetAuthorizationToken` o `sts:AssumeRole`.
  3. La NetworkPolicy o el grupo de seguridad bloquea la salida (egress) del nodo hacia el endpoint STS/IAM de la nube.
* **Pasos de Resolución**:
  1. Acceder por SSH al nodo afectado y ejecutar manualmente el binario del plugin para verificar el stderr:
     ```bash
     $ /usr/libexec/kubernetes/kubelet-plugins/credentialprovider/exec/ecr-credential-provider get-credentials
     ```
  2. Inspeccionar las asociaciones de roles IAM del nodo a través de la CLI de la nube (`aws sts get-caller-identity` o `gcloud auth list`).

#### Modo de Fallo 3: Tiempo de Espera Agotado en la Verificación de Admisión de Cosign o Rekor No Disponible
* **Síntomas**: La creación del Pod se bloquea durante 15 segundos durante `kubectl apply`, luego falla con:
  `Internal error occurred: failed calling webhook "verify-images.kyverno.svc": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/mutate?timeout=15s": context deadline exceeded`.
* **Análisis de Causa Raíz**:
  1. El admission controller de Kyverno está configurado con `failurePolicy: Fail` y no puede alcanzar el log de transparencia público de Rekor (`https://rekor.sigstore.dev`) debido a reglas de egress en entornos aislados (air-gapped) o bloqueos de firewall.
  2. Alta latencia o interrupciones en la infraestructura pública de Sigstore.
* **Pasos de Resolución**:
  1. Verificar la conectividad de red desde el pod del motor de políticas hacia Rekor:
     ```bash
     $ kubectl exec -n kyverno -it deployment/kyverno -- curl -iv https://rekor.sigstore.dev/api/v1/log/publicKey
     ```
  2. Para entornos de producción aislados (air-gapped), desplegar una instancia interna de Rekor y Fulcio, y actualizar el campo `rekor.url` de la política de Kyverno para que apunte a los servicios internos (`https://rekor.internal.domain`).

---

## 6. Referencias

* **CNCF KCSA Exam Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Official Documentation — Images**: [https://kubernetes.io/docs/concepts/containers/images/](https://kubernetes.io/docs/concepts/containers/images/)
* **Kubernetes Official Documentation — Kubelet Credential Provider**: [https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
* **Sigstore Cosign Documentation**: [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
* **Kyverno Image Verification Reference**: [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)
* **NIST SP 800-190 (Application Container Security Guide)**: [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **CNCF TAG Security — Supply Chain Security Best Practices**: [https://github.com/cncf/tag-security/tree/main/supply-chain-security](https://github.com/cncf/tag-security/tree/main/supply-chain-security)