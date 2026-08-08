# Guía de Estudio KCSA: Tema 5.1 - Seguridad de la Cadena de Suministro

**Rol:** Arquitecto Principal de Plataforma e Instructor Senior de SRE  
**Certificación Objetivo:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** Seguridad de la Plataforma / Seguridad de la Cadena de Suministro (Dominio 5.1, Peso ~2.29%)  
**Fuente de Referencia:** [CNCF KCSA Curriculum (Official PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 1. Análisis Arquitectónico Profundo: La Superficie de Ataque de la Cadena de Suministro Cloud-Native

La seguridad moderna de la cadena de suministro cloud-native desplaza los límites de confianza de las verificaciones perimetrales de direcciones IP a pruebas criptográficas de identidad. Las imágenes de contenedores ya no se tratan como salidas de compilación estáticas; son paquetes verificables de código, metadatos, atestaciones firmadas criptográficamente y Lista de Materiales de Software (SBOM).

```
 +------------------+     +-------------------+     +---------------------+
 |   Source Code    | --> | Ephemeral Builder | --> | OCI Image Registry  |
 | (Git Commit Hash)|     |  (SLSA Level 3)   |     | (Container + SBOM)  |
 +------------------+     +-------------------+     +---------------------+
                                   |                           |
                                   v                           v
                           +---------------+         +-------------------+
                           |  Sigstore /   |         | Admission Controller|
                           | Fulcio/Rekor  |         | (Kyverno / OPA)   |
                           +---------------+         +-------------------+
                                                               |
                                                               v
                                                     +-------------------+
                                                     | Kubernetes Worker |
                                                     |  (Kubelet Engine) |
                                                     +-------------------+
```

### Los 4 Vectores de Ataque Principales y Mecánicas de Mitigación
1. **Compromiso de Código Fuente y Dependencias (Typosquatting / Dependency Confusion):** Un atacante inyecta código malicioso aguas arriba (upstream). *Mitigación:* Generación de SBOM, lockfiles, fijado (pinning) de dependencias por commit hash.
2. **Manipulación del Sistema de Compilación (Vector de Amenaza SLSA):** Build runners compromised modifican los binarios antes de la contenedorización. *Mitigación:* Nodos de compilación herméticos efímeros, atestaciones de procedencia in-toto ([SLSA v1.0 Specification](https://slsa.dev/spec/v1.0/provenance)).
3. **Sustitución de Imagen de Contenedor en el Registry (Ataques de Tag Sliding):** Un atacante reemplaza `my-app:v1.0.0` en el registry sin cambiar la etiqueta (tag). *Mitigación:* Image digests inmutables (`@sha256:...`) y firmas criptográficas de Cosign ([Sigstore Documentation](https://docs.sigstore.dev/cosign/overview/)).
4. **Ingesta en Tiempo de Ejecución del Cluster de Artefactos No Verificados:** Los nodos de Kubernetes obtienen imágenes de terceros no revisadas. *Mitigación:* Admission Controllers que validan identidades OIDC y firmas criptográficas antes de la persistencia en el API server.

---

## 2. Ejercicio Guiado 1: Generación y Atestación Criptográfica de SBOMs con Syft y Cosign

### Visión General Arquitectónica
Una Lista de Materiales de Software (SBOM) proporciona un inventario legible por máquina (SPDX o CycloneDX) que enumera cada binario, librería y paquete de sistema operativo dentro de una imagen de contenedor. Para evitar que un adversario manipule el SBOM en tránsito, el SBOM se adjunta al OCI registry como una atestación in-toto firmada con Cosign.

### Ejecución Práctica Paso a Paso

#### Paso 1.1: Construir una Imagen y Generar un SBOM CycloneDX
Cree una imagen de contenedor alpine minimalista, constrúyala localmente y genere un SBOM CycloneDX JSON utilizando `syft`.

```bash
# 1. Create directory and Dockerfile
mkdir -p /tmp/kcsa-supply-chain && cd /tmp/kcsa-supply-chain

cat <<'EOF' > Dockerfile
FROM alpine:3.19.0
RUN apk add --no-cache curl=8.9.1-r0 bash=5.2.21-r0
ENTRYPOINT ["/bin/bash", "-c", "echo Security Pipeline Active"]
EOF

# 2. Build local image tag
docker build -t localhost:5000/sec-ops/app:v1.0.0 .

# 3. Generate CycloneDX JSON SBOM using Syft
syft localhost:5000/sec-ops/app:v1.0.0 -o cyclonedx-json=sbom.json
```

**Salida de Terminal Esperada (ejecución de `syft`):**
```text
 ✔ Parsed image                    localhost:5000/sec-ops/app:v1.0.0
 ✔ Cataloged packages              [18 packages]
  ├── alpine-baselayout            3.4.3-r2   apk
  ├── bash                         5.2.21-r0  apk
  ├── curl                         8.9.1-r0   apk
  └── zlib                         1.3.1-r0   apk
[INFO] SBOM successfully written to sbom.json
```

#### Paso 1.2: Generar el Par de Claves de Cosign y Atestar el SBOM en el Registry
Firme el SBOM utilizando pares de claves de Cosign y envíe el payload de atestación al OCI registry vinculado directamente al image digest.

```bash
# 1. Generate local ECDSA key pair (Non-interactive mode)
COSIGN_PASSWORD="KCSA_Production_Password_2026" cosign generate-key-pair

# 2. Inspect the generated keys
ls -l cosign.key cosign.pub

# 3. Obtain precise image digest to prevent tag mutation attacks
IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' localhost:5000/sec-ops/app:v1.0.0 2>/dev/null || echo "localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612")

# 4. Attach signed attestation to OCI Artifact layer
COSIGN_PASSWORD="KCSA_Production_Password_2026" cosign attest \
  --key cosign.key \
  --type cyclonedx \
  --predicate sbom.json \
  ${IMAGE_DIGEST}
```

**Salida de Terminal Esperada (ejecución de `cosign attest`):**
```text
Using payload at sbom.json
Uploading attestation for [localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612] to OCI registry...
Signature verification succeeded for digest localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612
Attestation attached: localhost:5000/sec-ops/app:sha256-d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612.att
```

#### Paso 1.3: Verificar Criptográficamente la Atestación del SBOM
Extraiga y verifique la integridad criptográfica de la atestación desde el registry utilizando `cosign verify-attestation`.

```bash
cosign verify-attestation \
  --key cosign.pub \
  --type cyclonedx \
  ${IMAGE_DIGEST} | jq .
```

**Salida de Terminal Esperada:**
```json
{
  "critical": {
    "identity": {
      "docker-reference": "localhost:5000/sec-ops/app"
    },
    "image": {
      "docker-manifest-digest": "sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612"
    },
    "type": "cosign container image attestation"
  },
  "optional": {
    "PredicateType": "https://cyclonedx.org/schema/bom-1.4.json"
  }
}
```

---

### Verificación de Comprensión: Ejercicio 1

#### Pregunta 1.1
¿Por qué hacer referencia a una etiqueta de imagen (ej. `app:v1.0.0`) es insuficiente al ejecutar `cosign verify-attestation` en producción, y por qué se debe utilizar en su lugar el digest inmutable (`app@sha256:...`)?

#### Pregunta 1.2
¿Qué mecanismo evita que un actor malicioso que haya comprometido el OCI registry reemplace el payload `sbom.json` dentro de un artefacto de atestación existente sin ser detectado?

---

## 3. Ejercicio Guiado 2: Aplicación de Verificación de Firma y SBOM en Admission Control mediante Kyverno

### Visión General Arquitectónica
Asegurar el pipeline de CI/CD está incompleto sin una aplicación en tiempo de ejecución (runtime enforcement). Si se envía un Deployment al API server de Kubernetes, el interceptor del Kubernetes Admission Controller (específicamente un Validating Webhook) debe bloquear la creación de Pods si:
1. La imagen de contenedor no está firmada criptográficamente por la clave pública de la organización.
2. El digest de la imagen no coincide con el manifiesto firmado.

Desplegaremos un recurso [`ClusterPolicy` de Kyverno](https://kyverno.io/docs/writing-policies/verify-images/) de nivel de producción para aplicar una verificación de imagen estricta.

```
 +----------------------+      +----------------------+      +-----------------------+
 | kubectl apply -f pod | ---> | Kubernetes API Server| ---> |  Kyverno Admission    |
 +----------------------+      +----------------------+      |  Webhook Controller   |
                                                             +-----------------------+
                                                                         |
                                                                         v
                                                              Verify Cosign Signature
                                                              against public key/digest
                                                                         |
                                                 +-----------------------+-----------------------+
                                                 |                                               |
                                                 v                                               v
                                        [ Signature Valid ]                    [ Invalid / Missing ]
                                                 |                                               |
                                                 v                                               v
                                          Allow Pod Creation                     Deny Request (403)
```

### Ejecución Práctica Paso a Paso

#### Paso 2.1: Desplegar la Política de Verificación de Imagen de Kyverno Sintácticamente Válida
Cree un archivo llamado `verify-image-policy.yaml` que contenga el manifiesto del `ClusterPolicy`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-container-signature
  annotations:
    policies.kyverno.io/title: Enforce Cosign Image Signature Verification
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Blocks any Pod creation if the container image is not cryptographically signed
      by the SecOps trusted public key.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  failurePolicy: Fail
  rules:
    - name: verify-signature-rule
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaces:
              - production
      verifyImages:
        - imageReferences:
            - "localhost:5000/sec-ops/*"
          key: |-
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7+rT4FqUuN22QhR90O+hU0VzR5Ew
            w4R3lM3XlY1qU0O91M3wQ4V5X6Y7Z8A9B0C1D2E3F4G5H6I7J8K9L0M1N2==
            -----END PUBLIC KEY-----
          mutateDigest: true
          required: true
          verifyDigest: true
```

Aplique el manifiesto a su cluster:
```bash
kubectl apply -f verify-image-policy.yaml
```

**Salida de Terminal Esperada:**
```text
clusterpolicy.kyverno.io/verify-container-signature created
```

#### Paso 2.2: Prueba 1 - Intentar Desplegar una Imagen No Firmada (Se Espera Bloqueo)
Cree un namespace de destino `production` e intente ejecutar una imagen de contenedor no firmada (`localhost:5000/sec-ops/untrusted-app:v1.0.0`).

```bash
# 1. Create production namespace
kubectl create namespace production

# 2. Attempt deployment of unsigned container
kubectl run rogue-workload \
  --image=localhost:5000/sec-ops/untrusted-app:v1.0.0 \
  -n production
```

**Salida de Terminal Esperada (Rechazo del API de Kubernetes):**
```text
Error from server (Forbidden): admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: 

policy ClusterPolicy/verify-container-signature error:
  verify-signature-rule: imageVerification failed for localhost:5000/sec-ops/untrusted-app:v1.0.0: 
  failed to verify image signature against provided key: no signatures found for image digest
```

#### Paso 2.3: Prueba 2 - Desplegar una Imagen de Contenedor Válida y Firmada (Se Espera Éxito)
Ahora despliegue la imagen de contenedor firmada generada en el Ejercicio 1 utilizando su digest verificado criptográficamente.

```bash
kubectl run secure-workload \
  --image=localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612 \
  -n production
```

**Salida de Terminal Esperada:**
```text
pod/secure-workload created
```

Verifique el estado del Pod:
```bash
kubectl get pod secure-workload -n production -o wide
```

**Salida Esperada:**
```text
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
secure-workload   1/1     Running   0          12s   10.244.0.15  node-01    <none>           <none>
```

---

### Verificación de Comprensión: Ejercicio 2

#### Pregunta 2.1
En el manifiesto `ClusterPolicy` de Kyverno, ¿cuál es el propósito operativo de `mutateDigest: true`? ¿Qué riesgo de seguridad mitiga a nivel del cluster de Kubernetes?

#### Pregunta 2.2
Si la `failurePolicy` del admission controller se establece en `Ignore` en lugar de `Fail`, ¿qué sucede con la postura de seguridad de la cadena de suministro si el pod del controlador de Kyverno falla o sufre un evento de OOMKill?

---

## 4. Ejercicio Guiado 3: Firmas sin Clave (Keyless), Registros de Transparencia (Rekor) y Atestación de Identidad OIDC

### Visión General Arquitectónica
La gestión tradicional de pares de claves introduce dispersión de secretos (secret sprawl), sobrecarga de rotación de claves y riesgo de filtración de claves privadas. Sigstore resuelve esto con la **Firma sin Clave (Keyless Signing)**:
1. El builder se autentica ante Fulcio (una Autoridad Certificadora de vida corta) a través de un **Proveedor de Identidad OIDC** (ej., GitHub Actions, OIDC Token).
2. Fulcio emite un certificado X.509 de vida corta vinculado a la identidad del builder (ej., `https://github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main`).
3. La firma y el certificado se publican en **Rekor**, un Registro de Transparencia (Transparency Log) inmutable y de solo anexado (append-only) basado en una arquitectura de Árbol de Merkle ([Sigstore Architecture Docs](https://docs.sigstore.dev/)).

```
 +------------------+   1. OIDC Token    +--------------------+
 | Ephemeral CI/CD  | -----------------> | Fulcio CA          |
 | (GitHub Actions) | <----------------- | (Short-lived Cert) |
 +------------------+   2. X.509 Cert    +--------------------+
          |
          | 3. Sign Image & Log Entry
          v
 +------------------------------------------------------------+
 |                       Rekor Log                            |
 | (Immutable Merkle Tree Transparency Log - Proof of Entry) |
 +------------------------------------------------------------+
```

### Ejecución Práctica Paso a Paso

#### Paso 3.1: Ejecutar Firma sin Clave (Entorno de CI Simulado)
En un entorno con capacidad OIDC (ej., un runner de GitHub Actions o una sesión OIDC ambiente local):

```bash
# Execute keyless image signing
cosign sign \
  --yes \
  localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612
```

**Salida de Terminal Esperada:**
```text
Generating ephemeral key pair...
Retrieving signed certificate from Fulcio...
Successfully obtained X.509 certificate!
Issuer: https://token.actions.githubusercontent.com
Subject: https://github.com/secops-org/core-pipeline/.github/workflows/build.yml@refs/heads/main
Submitting signature to Rekor transparency log...
Successfully logged entry to Rekor transparency log with index: 10842910
Signing complete!
```

#### Paso 3.2: Verificar Firmas sin Clave Utilizando las Banderas de Identidad y Emisor
En lugar de proporcionar un archivo de clave pública estático (`--key cosign.pub`), la verificación aplica atributos de identidad: `--certificate-identity` y `--certificate-oidc-issuer`.

```bash
cosign verify \
  --certificate-identity="https://github.com/secops-org/core-pipeline/.github/workflows/build.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612 | jq .
```

**Salida de Terminal Esperada:**
```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/sec-ops/app"
      },
      "image": {
        "docker-manifest-digest": "sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612"
      },
      "type": "cosign container image signature"
    },
    "optional": {
      "Bundle": {
        "SignedEntryTimestamp": "MEQCIFx...==",
        "Payload": {
          "body": "..."
        }
      },
      "Issuer": "https://token.actions.githubusercontent.com",
      "Subject": "https://github.com/secops-org/core-pipeline/.github/workflows/build.yml@refs/heads/main"
    }
  }
]
```

#### Paso 3.3: Diagnósticos Avanzados: Inspección de Entradas del Registro de Transparencia Rekor
Si una auditoría requiere prueba de la marca de tiempo de la firma o la verificación del hash raíz del Árbol de Merkle, consulte directamente a Rekor utilizando `rekor-cli`.

```bash
# Query Rekor log by image digest
rekor-cli search --sha256 d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612
```

**Salida de Terminal Esperada:**
```text
Found matching entries:
  10842910
```

Obtenga detalles de la entrada `10842910`:
```bash
rekor-cli get --log-index 10842910
```

**Salida de Terminal Esperada:**
```text
Log Index: 10842910
Integrated Time: 2026-08-07T20:15:00Z
Body: {
  "spec": {
    "signature": {
      "content": "MEUCIQC...",
      "format": "x509",
      "publicKey": {
        "content": "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t..."
      }
    }
  }
}
Verification:
  Integrated Time: 2026-08-07T20:15:00Z
  Signed Entry Timestamp (SET): MEQCIDy4...==
```

---

### Verificación de Comprensión: Ejercicio 3

#### Pregunta 3.1
¿Cómo garantiza el registro de transparencia Rekor de Sigstore que una entrada de firma no pueda ser modificada o eliminada retroactivamente por un administrador que obtenga acceso root a la infraestructura del servidor de Rekor?

#### Pregunta 3.2
En una configuración sin clave (keyless), los certificados de Fulcio expiran en minutos (ej., 10 minutos). ¿Por qué una firma de Cosign sigue siendo válida días o años después cuando la verifican los admission controllers de Kubernetes?

---

## 5. Playbook Avanzado de Diagnóstico y Solución de Problemas

### Matriz Diagnóstica para Fallas de Verificación en la Cadena de Suministro

| Escenario de Falla / Mensaje de Error | Análisis de Causa Raíz | Comando / Procedimiento de Remediación |
| :--- | :--- | :--- |
| `error: no matching signatures found` | La imagen fue construida o re-etiquetada después de firmar, cambiando su digest. | Vuelva a firmar el nuevo digest de imagen usando `cosign sign --key ... <DIGEST>` |
| `error: certificate expired and SET missing` | La verificación sin clave falló porque se omitió la prueba de entrada de Rekor (Signed Entry Timestamp). | Asegúrese de que `--rekor-url` sea accesible y la verificación incluya `--attachment-tag-prefix` o el contexto del bundle. |
| `admission webhook denied request: x509: certificate signed by unknown authority` | Kyverno/API Server no puede validar los certificados raíz de Fulcio/CA personalizada. | Monte el bundle de CA personalizada dentro del deployment del admission controller o defina `certManager` en la política. |
| `ImagePullBackOff` post-admisión | La política mutó la etiqueta de imagen a digest, pero el registry requiere autenticación para consultas de digest. | Verifique que los `imagePullSecrets` tengan permiso para lecturas de `application/vnd.oci.image.manifest.v1+json`. |

### Lista de Verificación de Comandos CLI de Diagnóstico

```bash
# 1. Check Kyverno Webhook Execution Logs for Admission Rejections
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep -i "imageVerification"

# 2. Inspect Raw Kubernetes Admission Review Audit Events
kubectl get events -n production --field-selector reason=FailedCreate --sort-by='.metadata.creationTimestamp'

# 3. Manually Extract Image Digest from Remote OCI Registry (No local pull needed)
crane digest localhost:5000/sec-ops/app:v1.0.0

# 4. Dump OCI Attestation Layer directly from Registry
cosign download attestation --type cyclonedx localhost:5000/sec-ops/app:v1.0.0 | jq .payload | base64 -d | jq .
```

---

## 6. Trade-offs Arquitectónicos del Mundo Real: Verificación In-Tree vs Out-of-Tree

| Métrica / Dimensión | Native `ImagePolicyWebhook` (In-Tree) | Admission Controller (Out-of-Tree ej. Kyverno/OPA) |
| :--- | :--- | :--- |
| **Capa de Control** | Configurada a través de flags estáticas del `kube-apiserver` (`--admission-control-config-file`). | Desplegada como CRDs y controladores estándares dentro del cluster. |
| **Flexibilidad** | Esquema de backend rígido; requiere implementación personalizada de servidor webhook. | Soporte nativo para Cosign keyless, Fulcio OIDC, logs de transparencia de Rekor y políticas CEL. |
| **Fricción para el Administrador del Cluster** | Requiere reinicio del API server del control plane para actualizaciones de configuración. | Actualizaciones dinámicas de políticas aplicadas al instante sin reinicios de nodos o control plane. |
| **Riesgo Fail-Open/Fail-Closed** | Codificado en duro (hardcoded) en los flags de inicio del API server. El API server se bloquea si el webhook no es accesible. | Controlado a través de la política `failurePolicy: Fail \| Ignore` a niveles granulares de CRD. |

---

<details>
<summary><b>Respuestas y Explicaciones a las Preguntas de Verificación</b></summary>

### Respuestas del Ejercicio 1

#### Respuesta 1.1
**Explicación:** Las etiquetas de imágenes de contenedor (ej., `v1.0.0`) son punteros mutables en los OCI registries. Un administrador de registry malicioso o un atacante podría realizar un "Ataque de Tag Sliding" sobrescribiendo `app:v1.0.0` con un payload malicioso manteniendo el nombre de la etiqueta sin cambios. Las firmas criptográficas y las atestaciones se calculan sobre el digest SHA-256 inmutable del manifiesto OCI. Verificar contra la etiqueta deja una ventana donde la etiqueta podría resolverse a un digest diferente entre la verificación y la ejecución del pod.

#### Respuesta 1.2
**Explicación:** El payload del SBOM está encapsulado dentro de un payload **in-toto statement** firmado por la clave privada secreta (`cosign.key`). La firma cubre tanto los metadatos de la declaración como el hash del payload predicado (`sbom.json`). Si un atacante altera cualquier byte en `sbom.json`, la verificación del hash de la firma fallará durante `cosign verify-attestation`.

---

### Respuestas del Ejercicio 2

#### Respuesta 2.1
**Explicación:** `mutateDigest: true` le indica a Kyverno que intercepte el envío del Pod (que podría usar una etiqueta como `image: app:v1.0.0`) y lo resuelva a su digest inmutable actual (ej., `image: app@sha256:d875...`), mutando la especificación del Pod antes de persistirla en `etcd`. Esto evita ataques de **Time-of-Check to Time-of-Use (TOCTOU)** donde el Kubelet obtiene un digest de imagen diferente al validado por el admission controller durante la transmisión al API.

#### Respuesta 2.2
**Explicación:** Si `failurePolicy` se establece en `Ignore`, cualquier falla del admission controller (como tiempos de espera del webhook, caídas de pods, particiones de red o eventos de OOMKill) hace que el API server **omita la validación** y permita la creación de Pods. Esto rompe el límite de seguridad, permitiendo que imágenes no verificadas o maliciosas se ejecuten en producción. Las políticas de cadena de suministro en producción deben aplicar `failurePolicy: Fail`.

---

### Respuestas del Ejercicio 3

#### Respuesta 3.1
**Explicación:** Rekor utiliza una estructura de datos de **Árbol de Merkle** de solo anexado (similar a los registros de Certificate Transparency). El hash de cada entrada se incorpora a los nodos primarios hasta el Root Hash (Signed Tree Head). Modificar o eliminar una entrada existente invalida todos los nodos subsiguientes y cambia el Tree Head público. Auditores externos monitorean y archivan continuamente los Signed Tree Heads; cualquier manipulación por parte de un administrador del servidor provocaría discrepancias en las pruebas criptográficas (Inclusion and Consistency Proofs) que son inmediatamente detectables.

#### Respuesta 3.2
**Explicación:** Aunque el certificado X.509 de Fulcio emitido para el builder expira en minutos, la verificación de la firma sin clave se basa en la marca de tiempo de entrada firmada (**Signed Entry Timestamp - SET**) emitida por Rekor. Durante la verificación, `cosign` comprueba que:
1. La firma fue creada mientras el certificado X.509 de vida corta era válido.
2. La marca de tiempo exacta de creación está demostrada criptográficamente por la Signed Entry Timestamp de Rekor.  
Debido a que la marca de tiempo prueba que la firma ocurrió *durante* el período de validez del certificado, la firma sigue siendo válida indefinidamente.

</details>