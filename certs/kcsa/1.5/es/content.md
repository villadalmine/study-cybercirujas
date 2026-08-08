# Guía de Estudio KCSA: Dominio 1.5 – Seguridad de Repositorios de Artefactos e Imágenes

**Examen:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** Cloud Native Security Architecture  
**Tema 1.5:** Artifact Repository and Image Security  
**Peso:** 2.33%  

---

## 1. Motivación y Problema Arquitectónico en Producción

En un entorno de producción cloud-native, el registry de contenedores y el pipeline de artefactos funcionan como el punto de entrada primario de código externo hacia la infraestructura interna. La seguridad moderna de la cadena de suministro de contenedores opera bajo un modelo de amenaza zero-trust, asumiendo que las imágenes base públicas, los runners de CI/CD, las dependencias de terceros y las capas de almacenamiento del registry están constantemente expuestos a vectores de compromiso.

```
+------------------+      +-------------------+      +----------------------+      +-----------------------+
|  Developer Code  | ---> |   CI/CD Pipeline  | ---> |   OCI Artifact Reg.  | ---> |  K8s Admission Ctrl  |
| (Dep. Confusion) |      | (Runner Takeover) |      | (Tag Re-pointing/MITM|      | (Unsigned / CVE Pod)  |
+------------------+      +-------------------+      +----------------------+      +-----------------------+
```

### Fallos Arquitectónicos Principales en Producción

1. **Etiquetado de Imágenes Mutable y Builds No Deterministas**  
   Confiar en tags flotantes (ej. `:latest`, `:v1.2`) introduce no determinismo en tiempo de ejecución. Un atacante con acceso de escritura a un OCI registry puede sobrescribir un tag sin alterar el string del tag, haciendo que los nodos que ejecutan `imagePullPolicy: Always` descarguen capas maliciosas. Además, `imagePullPolicy: IfNotPresent` en tags mutables provoca un drift silencioso del estado del cluster entre nodos dependiendo de los timestamps de la cache local.

2. **Ausencia de Proveniencia y Atestación Criptográfica de Imágenes**  
   Sin firmas criptográficas verificables adjuntas directamente a los artefactos OCI, los nodos de Kubernetes no pueden distinguir entre una imagen compilada por un runner de build de CI autorizado y una imagen maliciosa inyectada a través de un registry comprometido, credenciales robadas o ataques de Man-in-the-Middle (MitM).

3. **Vulnerabilidades No Detectadas y Cadenas de Suministro de Software Opacas**  
   Las imágenes de contenedores modernas empaquetan paquetes del sistema operativo (deb/rpm/apk) junto con dependencias específicas del lenguaje (npm, PyPI, módulos de Go). Desplegar imágenes sin un Software Bill of Materials (SBOM) explícito y legible por máquina, y sin un escaneo continuo del índice de vulnerabilidades, expone a los clusters a vectores conocidos de Remote Code Execution (RCE) (ej. Log4Shell, heartbleed, exploits de glibc).

4. **Autenticación Insegura de Registries y Enrutamiento de Red**  
   Exponer registries de contenedores sin un Role-Based Access Control (RBAC) granular, aplicación de tags inmutables, autenticación mutua TLS o endpoints de red privados (ej. Cloud Provider Private Endpoints, VPC Peering) permite la fuga de credenciales, pushes de imágenes no autorizados e intercepción a nivel de red.

---

## 2. Comparaciones Técnicas y Tablas de Balance (Trade-offs)

### 2.1 Frameworks de Firma Criptográfica de Imágenes: Cosign (Sigstore) vs. Notary v2 (Notation) vs. Notary v1 (TUFR)

| Parámetro / Característica | Sigstore / Cosign | Notary v2 (Notation / ORAS) | Notary v1 (Docker Content Trust) |
| :--- | :--- | :--- | :--- |
| **Arquitectura** | Keyless (OIDC + Fulcio PKI + Rekor log) o pares de claves estáticas | Estándar X.509 PKI (Certificados, Certificados de Firma de Código) | The Update Framework (TUF) con claves del lado del cliente |
| **Mecanismo de Almacenamiento** | OCI Artifact Spec (atestaciones/firmas almacenadas como capas OCI junto a la imagen) | OCI Artifact Manifest & Reference Spec | Server Notary externo (base de datos / API server separados) |
| **Raíz de Confianza (Root of Trust)** | Instancia Sigstore Public Good o Stack privado de Sigstore (Fulcio, Rekor) | Root CA empresarial / Infraestructura PKI (ej. AWS KMS, Azure Key Vault) | Server Notary autogestionado y Jerarquía de Claves TUF |
| **Integración con Log de Transparencia** | Nativa (Ledger de Rekor inmutable append-only) | Opcional / Específica del proveedor | Ninguna |
| **Adopción en el Ecosistema K8s** | Alta (Integración nativa con Kyverno, Gatekeeper, Connaisseur) | Media (Soportado a través de plugins de Notation para K8s) | Baja / Legacy (Obsoleto en pipelines modernos de Kubernetes) |
| **Sobrecarga Operativa (Operational Overhead)** | Baja (Keyless elimina la gestión de claves privadas estáticas) | Media (Requiere gestionar el ciclo de vida de certificados X.509 y CRLs/OCSP) | Alta (Gestión compleja de múltiples claves: root, targets, snapshot, timestamp) |

### 2.2 Arquitecturas de Escaneo de Vulnerabilidades en Imágenes

| Estrategia | Punto de Ejecución | Pros | Contras / Trade-offs |
| :--- | :--- | :--- | :--- |
| **Escaneo en Pipeline de CI/CD** *(ej. Trivy, Grype)* | Pre-push (GitHub Actions, GitLab CI, Tekton) | Falla tempranamente en el ciclo de vida de desarrollo; cero sobrecarga en runtime. | No puede detectar zero-days descubiertos *después* del despliegue; depende del cumplimiento del desarrollador. |
| **Escaneo en Registry** *(ej. Harbor + Trivy/Clair)* | En el registry (Al hacer push o mediante programación cron) | Control centralizado; previene la distribución de imágenes comprometidas. | Alta carga de CPU/IO en nodos de almacenamiento; visibilidad limitada del contexto de runtime del cluster. |
| **Escaneo mediante Operador In-Cluster** *(ej. Trivy Operator)* | Post-despliegue (Sondeo continuo del cluster) | Proporciona visibilidad en tiempo real de los perfiles de riesgo de CVE de las cargas de trabajo en ejecución. | Consumo de recursos en nodos de control plane/worker; la remediación requiere rolling updates del lado del cluster. |

### 2.3 Mecanismos de Control de Admisión en Kubernetes para la Aplicación de Políticas de Imágenes

| Característica | Kyverno `ClusterPolicy` | OPA Gatekeeper (`ConstraintTemplate`) | `ImagePolicyWebhook` Nativo |
| :--- | :--- | :--- | :--- |
| **Lenguaje Específico del Dominio (DSL)** | YAML declarativo (Patrón nativo de K8s) | Rego (Lenguaje declarativo de consulta lógica) | Go (Requiere HTTP Webhook Server personalizado) |
| **Soporte de Verificación de Imágenes** | Bloque `verifyImages` nativo (Cosign, Notary, Keyless) | Requiere extensión personalizada de Rego / características de External Data | Interfaz de API nativa, pero la lógica personalizada debe construirse dentro del webhook |
| **Modo de Fallo (`failurePolicy`)** | Configurable como `Fail` e `Ignore` por política | Configurable como `Fail` e `Ignore` por política | Configurado en el archivo de configuración de admisión del kube-apiserver |
| **Complejidad de Mantenimiento** | Baja | Media (Requiere dominio de Rego) | Alta (Requiere construir, parchear y escalar microservicios personalizados) |

---

## 3. Manifiestos YAML de Producción

### Manifiesto 1: Kyverno `ClusterPolicy` que Aplica Verificación Keyless de Cosign e Inmutabilidad por Digest SHA256

Este manifiesto aplica dos controles de producción críticos:
1. Cada imagen de contenedor debe referenciarse mediante un digest `sha256` inmutable en lugar de un tag mutable.
2. Cada imagen debe contener una firma criptográfica válida firmada por el flujo keyless de Sigstore (verificación con Fulcio OIDC + Log de Transparencia Rekor).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-signature-and-digest
  annotations:
    policies.kyverno.io/title: Enforce Cosign Keyless Signature and Immutable Digest
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Deployment, StatefulSet, DaemonSet
    description: >-
      Blocks any pod creation if images are not pinned to an immutable digest (sha256)
      or if images fail Cosign keyless signature verification against the corporate OIDC issuer.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  rules:
    - name: reject-mutable-tags
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "Image tag must use immutable digest reference (@sha256:...)."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: NotRegexMatch
                    value: "^.*@sha256:[a-fA-F0-9]{64}$"
    - name: verify-cosign-keyless-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "cr.enterprise.io/production/*"
            - "docker.io/enterprise/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/enterprise-org/core-services/.github/workflows/build-pipeline.yml@refs/heads/main"
            rekor:
              url: "https://rekor.sigstore.dev"
```

---

### Manifiesto 2: OPA Gatekeeper `ConstraintTemplate` y `Constraint` que Aplican Registries de Contenedores Permitidos

Esta plantilla verifica que los contenedores de los pods solo carguen imágenes de registries empresariales OCI internos y aprobados.

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedregistries
  annotations:
    metadata.gatekeeper.sh/title: Allowed Registries
    description: Requires container images to originate from an approved list of corporate registries.
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.io/genericadmissionwebhook
      rego: |
        package k8sallowedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("Container image '%v' comes from an unauthorized registry. Allowed registries: %v", [container.image, input.parameters.registries])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("InitContainer image '%v' comes from an unauthorized registry. Allowed registries: %v", [container.image, input.parameters.registries])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRegistries
metadata:
  name: restrict-pod-registries
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
  parameters:
    registries:
      - "cr.enterprise.io/"
      - "777123456789.dkr.ecr.us-east-1.amazonaws.com/"
```

---

### Manifiesto 3: `ServiceAccount` de Producción con `imagePullSecrets` Privados y Política de Pull Local Restringida

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: enterprise-registry-credentials
  namespace: production
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e3ogImF1dGhzIjogeyAiY3IuZW50ZXJwcmlzZS5pbyI6IHsgImF1dGgiOiAiWTI5dWRISnBaMjh6TVROaFkyTnZNV1V6TW1VPSIgfSB9IH0=
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secure-workload-sa
  namespace: production
imagePullSecrets:
  - name: enterprise-registry-credentials
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      serviceAccountName: secure-workload-sa
      containers:
        - name: processor
          image: cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
```

---

### Manifiesto 4: Configuración de Admisión `ImagePolicyWebhook` en el Control Plane de Kubernetes

Para habilitar la evaluación de imágenes a nivel de API Server, configure `--admission-control-config-file` en `kube-apiserver`.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
        allowTTL: 50
        denyTTL: 50
        retryBackoff: 500
        defaultAllow: false
```

Kubeconfig de soporte para el servidor de webhook de admisión:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: image-checker
    cluster:
      certificate-authority: /etc/kubernetes/admission/certs/ca.crt
      server: https://image-verifier.security.svc.cluster.local:8443/check-image
users:
  - name: apiserver
    user:
      client-certificate: /etc/kubernetes/admission/certs/apiserver-client.crt
      client-key: /etc/kubernetes/admission/certs/apiserver-client.key
contexts:
  - name: image-checker-context
    context:
      cluster: image-checker
      user: apiserver
current-context: image-checker-context
```

---

## 4. Comandos de Ejecución y Salidas Reales de Terminal

### 4.1 Generación de Par de Claves y Firma de Imagen de Contenedor con Cosign

```bash
$ cosign generate-key-pair
Enter password for private key: 
Confirm password for private key: 
Private key written to cosign.key
Public key written to cosign.pub

$ cosign sign --key cosign.key cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Enter password for private key:
Pushing signature to: cr.enterprise.io/production/payment-service

$ cosign verify --key cosign.pub cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "cr.enterprise.io/production/payment-service"
      },
      "image": {
        "docker-manifest-digest": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      "type": "cosign container image signature"
    },
    "optional": {
      "Bundle": {
        "SignedEntryTimestamp": "MEUCIQD..."
      }
    }
  }
]
```

---

### 4.2 Generación de un Software Bill of Materials (SBOM) en formato SPDX con Syft y Atestación mediante Cosign

```bash
$ syft cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 -o spdx-json > sbom.spdx.json
 ✔ Loaded image                                
 ✔ Parsed image                                
 ✔ Cataloged packages      [142 packages]

$ cosign attest --key cosign.key --type spdx --predicate sbom.spdx.json cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Enter password for private key: 
Uploading attestation to cr.enterprise.io/production/payment-service
```

---

### 4.3 Escaneo de Vulnerabilidades con Trivy y Aplicación de Gates en CI/CD

```bash
$ trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed cr.enterprise.io/production/payment-service:v1.2.0
```

```
2026-08-07T19:30:11.102Z    INFO    Vulnerability scanning is enabled
2026-08-07T19:30:11.102Z    INFO    Identified OS: alpine 3.18.2
2026-08-07T19:30:11.103Z    INFO    Detecting Alpine vulnerabilities...

cr.enterprise.io/production/payment-service:v1.2.0 (alpine 3.18.2)
===================================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬-------------------┬---------------+----------------------------------┐
│   Library    │ Vulnerability  │ Severity │ Installed Version │ Fixed Version │              Title               │
├──────────────┼────────────────┼──────────┼-------------------┼---------------+----------------------------------┤
│ libcrypto3   │ CVE-2023-3817  │ HIGH     │ 3.1.1-r1          │ 3.1.1-r3      │ openssl: excessive time spent    │
│              │                │          │                   │               │ checking DH keys                 │
│ libssl3      │ CVE-2023-44487 │ CRITICAL │ 3.1.1-r1          │ 3.1.1-r4      │ HTTP/2 Rapid Reset Attack        │
└──────────────┴────────────────┴──────────┴-------------------┴---------------+----------------------------------┤

Error: exit status 1
```

---

### 4.4 Activación e Inspección del Bloqueo del Control de Admisión de Kubernetes

Intento de ejecutar una imagen sin un tag de digest cuando la política está activa:

```bash
$ kubectl run untrusted-pod --image=docker.io/library/nginx:latest -n production
Error from server (Forbidden): admission webhook "validate.kyverno.svc-fail" denied the request: 

policy Pod/production/untrusted-pod error:

enforce-image-signature-and-digest:
  reject-mutable-tags:
    element.image: Image tag must use immutable digest reference (@sha256:...).
```

Intento de ejecutar una imagen desde un registry no autorizado:

```bash
$ kubectl run untrusted-reg-pod --image=docker.io/untrusteduser/app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 -n production
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [restrict-pod-registries] Container image 'docker.io/untrusteduser/app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' comes from an unauthorized registry. Allowed registries: ["cr.enterprise.io/", "777123456789.dkr.ecr.us-east-1.amazonaws.com/"]
```

---

## 5. Guía de Verificación y Diagnóstico

### 5.1 Matriz de Diagnóstico de Fallos

```
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| Symptom                            | Root Cause                            | Verification & Resolution Step                              |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| ImagePullBackOff (401 Unauthorized)| SA missing `imagePullSecrets` or RBAC | `kubectl get sa <sa-name> -o yaml`; verify dockerconfigjson  |
|                                    | token expired.                        | secret payload and test via `docker login`.                 |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| Admission Webhook Timeout (504)    | Policy Webhook server deadlocked or   | Check webhook `failurePolicy`. Inspect logs of Kyverno/OPA  |
|                                    | network policy blocking port 9443.    | controller pods. Verify control plane egress to webhook.    |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| Cosign Verification Failure        | Signature artifact missing in registry| Confirm OCI spec compatibility. Run `cosign tree <image>`   |
|                                    | or Rekor log network offline.         | to verify `.sig` and `.att` OCI layer existence.            |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| ImagePolicyWebhook Rejected        | `allowTTL` cache expired or backend   | Tail `kube-apiserver` logs filtering for `ImagePolicy`;     |
|                                    | returned `allow: false`.              | verify webhook server TLS cert validity.                    |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
```

### 5.2 Flujo de Trabajo Paso a Paso para Resolución de Problemas en Producción

#### Paso 1: Verificar la Estructura del Manifiesto de la Imagen OCI y las Capas de Firma
Cuando `cosign verify` falla dentro de los controladores de admisión del cluster, verifique manualmente el layout de los tags OCI:

```bash
$ cosign tree cr.enterprise.io/production/payment-service:v1.2.0
📦 Supply Chain Security Tree
└── 🐳 Image: cr.enterprise.io/production/payment-service:v1.2.0
    ├── 🎨 Signature: cr.enterprise.io/production/payment-service:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.sig
    └── 📜 Attestation: cr.enterprise.io/production/payment-service:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.att
```

#### Paso 2: Depurar Fallos en el Webhook de Admisión de Kyverno
Si las operaciones del API server se cuelgan o rechazan despliegues válidos, consulte el estado del Webhook de Admisión de Kyverno:

```bash
$ kubectl get clusterpolicies.kyverno.io enforce-image-signature-and-digest -o jsonpath='{.status}' | jq .

$ kubectl logs -n kyverno -l app=kyverno --tail=100 | grep -i "signature verification failed"
2026-08-07T19:35:22Z ERROR EngineMutate "failed to verify signature" logger="kyverno.verify-images" error="no matching signatures found for image cr.enterprise.io/production/payment-service@sha256:e3b0c442..."
```

#### Paso 3: Inspeccionar los Logs del API Server del Control Plane para ImagePolicyWebhook
Si se utiliza `ImagePolicyWebhook` nativo de Kubernetes:

```bash
$ kubectl logs -n kube-system kube-apiserver-control-plane-0 | grep -i "imagepolicywebhook"
2026-08-07T19:36:01.123Z [IMAGE-POLICY] Image cr.enterprise.io/production/payment-service:latest rejected by webhook backend: Image tag 'latest' violates policy: forbidden-floating-tag.
```

---

## 6. Referencias

* **CNCF KCSA Exam Curriculum**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Official Documentation – Image Policy Webhook**:  
  https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook
* **Kubernetes Official Documentation – Pulling Images from Private Registries**:  
  https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
* **Sigstore Cosign Documentation**:  
  https://docs.sigstore.dev/cosign/overview/
* **Kyverno Image Verification Documentation**:  
  https://kyverno.io/docs/writing-policies/verify-images/
* **OPA Gatekeeper Documentation**:  
  https://open-policy-agent.github.io/gatekeeper/website/docs/
* **NIST SP 800-190 (Application Container Security Guide)**:  
  https://csrc.nist.gov/publications/detail/sp/800-190/final
* **Anchore Syft (SBOM Generator)**:  
  https://github.com/anchore/syft
* **Aqua Security Trivy (Vulnerability Scanner)**:  
  https://github.com/aquasecurity/trivy