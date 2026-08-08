# Dominio KCSA 1.5: Artifact Repository and Image Security — Guía Avanzada de Producción y Ejercicios Guiados

**Certificación objetivo:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio:** Overview of Cloud Native Security / Cloud Native Architecture  
**Tema 1.5:** Artifact Repository and Image Security  
**Peso:** ~2.33%  
**Documento de referencia:** [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 1. Análisis Arquitectónico Profundo y Mecánica Interna

### 1.1 Arquitectura de OCI Image y Content-Addressable Storage
Las container images en los entornos cloud-native modernos se adhieren a la [Open Container Initiative (OCI) Image Format Specification](https://github.com/opencontainers/image-spec). Una OCI image no es un archivo binario monolítico; es un árbol de blobs direccionables por contenido (content-addressable) verificables criptográficamente:

1. **Manifest (`application/vnd.oci.image.manifest.v1+json`)**: Un documento JSON que referencia el config blob y los blobs de diff de layers mediante sus hashes criptográficos (SHA-256 digests).
2. **Configuration Blob**: Contiene metadatos de ejecución (entrypoint, variables env, arquitectura) y los IDs de diff de layers (`diff_ids`).
3. **Layer Blobs (`application/vnd.oci.image.layer.v1.tar+gzip`)**: Archivos tar que contienen deltas del filesystem.

```
+---------------------------------------------------------------------------------+
|                               OCI Image Manifest                                |
|  - SchemaVersion: 2                                                             |
|  - Config: sha256:a3f12... (application/vnd.oci.image.config.v1+json)            |
|  - Layers:                                                                      |
|      * sha256:e8b31... (application/vnd.oci.image.layer.v1.tar+gzip)           |
|      * sha256:7c92a... (application/vnd.oci.image.layer.v1.tar+gzip)           |
+------------------------------------+--------------------------------------------+
                                     |
                +--------------------+--------------------+
                |                                         |
                v                                         v
+-------------------------------+       +-------------------------------+
|      Configuration Blob       |       |          Layer Blob           |
|  - Architecture: amd64        |       |  - Rootfs tarball archive     |
|  - Env, Entrypoint, Cmd       |       |  - SHA-256 match verified     |
+-------------------------------+       +-------------------------------+
```

#### Mutabilidad de Tags vs. Inmutabilidad de Digests
- **Image Tags (`v1.2.0`, `latest`)**: Punteros mutables almacenados en el índice del registry. Un actor malicioso o comprometido con privilegios de escritura puede hacer push de una image maliciosa bajo un tag existente (por ejemplo, `v1.2.0`), haciendo que nuevos deployments de Pods hagan pull de software comprometido sin cambiar la especificación del Kubernetes Deployment.
- **Image Digest (`sha256:3b94a8...`)**: Identificador criptográfico inmutable derivado del contenido. Mutar un solo byte dentro de cualquier layer blob altera el digest calculado, causando fallos de verificación a nivel del container runtime engine (CRI) durante el fetch de la image.

### 1.2 Vectores de Amenaza en la Cadena de Suministro y Defensa en Profundidad
La seguridad de las images requiere abordar múltiples vectores de amenaza a lo largo del ciclo de vida desde el build hasta el runtime:

```
[ Developer Commit ] ---> [ Build/CI Pipeline ] ---> [ OCI Registry ] ---> [ K8s Admission ] ---> [ Container Runtime ]
        |                         |                         |                     |                       |
   (Compromised              (Poisoned Build           (Typosquatting /      (Unsigned /          (Runtime Privilege
    Dependency)               Dependencies)            Tag Overwrites)       Vulnerable Image)     Escalation/CVE)
```

1. **Inyección de Vulnerabilidades (Vulnerability Injection)**: Dependencias de software que contienen CVEs conocidos empaquetadas en base images.
2. **Man-in-the-Middle (MitM) y Alteración del Registry (Registry Tampering)**: Modificación en tránsito de las layers de la image al hacer pull a través de canales no cifrados o desde registries no confiables.
3. **Suplantación de Identidad y Pérdida de Proveniencia (Impersonation & Provenance Loss)**: Incapacidad de verificar qué actor construyó y publicó un artefacto de image.
4. **Evasión de Controles de Admisión (Bypassing Admission Controls)**: Desplegar images no verificadas o no conformes directamente en un cluster de Kubernetes pasando por alto las verificaciones del CI pipeline.

### 1.3 Firma Criptográfica y Atestaciones (Framework Sigstore / Cosign)
[Sigstore](https://www.sigstore.dev/) (un proyecto de la CNCF) estandariza la firma de software de contenedores y la verificación de proveniencia.

- **Cosign**: Firma artefactos OCI utilizando claves ECDSA-P256 o firma sin clave (keyless) basada en identidad.
- **Fulcio**: Certificate Authority (CA) raíz que emite certificados X.509 de corta duración basados en identidades OpenID Connect (OIDC) (GitHub Actions, Google Cloud IAM, AWS IAM).
- **Rekor**: Registro de transparencia criptográfico (Merkle tree) inmutable y append-only que registra firmas y atestaciones.
- **Atestaciones In-Toto y SBOMs**: Documentos de proveniencia Software Bill of Materials (SBOM) y SLSA (Supply-chain Levels for Software Artifacts) firmados y adjuntados como artefactos OCI junto con la image.

---

## 2. Ejercicios Guiados de Producción

### Ejercicio 1: Inspección Profunda de OCI Manifests y Digest Pinning

#### Escenario
Como Senior SRE, debés eliminar los riesgos de mutabilidad de images en deployments de producción extrayendo digests criptográficos SHA-256 exactos directamente de registries OCI remotos y aplicando digest pinning en las especificaciones de Kubernetes Pods.

#### Paso 1.1: Obtener e inspeccionar un OCI image manifest usando `skopeo`
Ejecutá `skopeo` para inspeccionar la estructura raw del manifest de una image sin hacer pull de las layers al Docker engine local.

```bash
skopeo inspect --raw docker://registry.k8s.io/pause:3.9 | jq .
```

##### Salida Esperada
```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": 751,
    "digest": "sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867"
  },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 268048,
      "digest": "sha256:e01353272e84610fe93c72b2123c52e825000570b898236780c102a0a2eb727e"
    }
  ]
}
```

#### Paso 1.2: Calcular el digest exacto del repositorio
Calculá el digest inmutable para el tag `3.9`:

```bash
skopeo inspect docker://registry.k8s.io/pause:3.9 | jq -r '.Digest'
```

##### Salida Esperada
```text
sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867
```

#### Paso 1.3: Desplegar un Pod de Producción usando Digest Pinning estricto
Creá un manifest listo para producción `hardened-pod.yaml` utilizando digest pinning explícito.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: production-pause-pod
  namespace: default
  labels:
    app.kubernetes.io/name: pause-service
    app.kubernetes.io/sec-level: critical
spec:
  restartPolicy: Always
  containers:
  - name: pause
    image: registry.k8s.io/pause@sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        cpu: "50m"
        memory: "32Mi"
      requests:
        cpu: "10m"
        memory: "16Mi"
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 65535
      capabilities:
        drop:
        - ALL
```

Aplicá el manifest del Pod:

```bash
kubectl apply -f hardened-pod.yaml
```

##### Salida Esperada
```text
pod/production-pause-pod created
```

#### Paso 1.4: Verificar la resolución de la image en runtime del Pod desplegado
Confirmá que Kubernetes resuelve y muestra el digest en el status:

```bash
kubectl get pod production-pause-pod -o jsonpath='{.status.containerStatuses[0].imageID}'
```

##### Salida Esperada
```text
registry.k8s.io/pause@sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867
```

---

#### Preguntas de Verificación (Ejercicio 1)
1. **Pregunta 1.1**: ¿Qué sucede si un mantenedor upstream actualiza `registry.k8s.io/pause:3.9` para que apunte a una nueva layer, pero tu manifest de Kubernetes utiliza `@sha256:7031c1b2821c...`?
2. **Pregunta 1.2**: ¿Por qué configurar `imagePullPolicy: Always` no es suficiente por sí solo para prevenir el image tag poisoning?

---

### Ejercicio 2: Escaneo Automatizado de Vulnerabilidades y Generación de Software Bill of Materials (SBOM)

#### Escenario
Para cumplir con los controles de cumplimiento (compliance), debés generar SBOMs estándar SPDX/CycloneDX para container images antes del deployment, y evaluarlos contra bases de datos de vulnerabilidades usando `trivy` y `syft`.

#### Paso 2.1: Generar un SBOM usando `syft`
Generá un artefacto SBOM CycloneDX JSON para una image:

```bash
syft image alpine:3.18.0 -o cyclonedx-json=alpine-3.18.0.sbom.json
```

##### Salida Esperada
```text
 ✔ Parsed image            [1 layers]
 ✔ Cataloged packages      [17 packages]
```

Inspeccioná la estructura del schema SBOM generado:

```bash
jq '{bomFormat, specVersion, components_count: (.components | length)}' alpine-3.18.0.sbom.json
```

##### Salida Esperada
```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "components_count": 17
}
```

#### Paso 2.2: Escanear la Container Image en busca de vulnerabilidades usando `trivy`
Realizá un escaneo filtrado por severidad en la image, fallando con exit code `1` si existen vulnerabilidades de severidad `CRITICAL`:

```bash
trivy image \
  --severity CRITICAL,HIGH \
  --exit-code 1 \
  --ignore-unfixed \
  --format table \
  alpine:3.14.0
```

##### Salida Esperada
```text
alpine:3.14.0 (alpine 3.14.0)
Total: 3 (HIGH: 2, CRITICAL: 1)

+---------------+------------------+----------+-------------------+---------------+-------------------------------------+
|    LIBRARY    |  VULNERABILITY ID | SEVERITY | INSTALLED VERSION | FIXED VERSION |                TITLE                |
+---------------+------------------+----------+-------------------+---------------+-------------------------------------+
| ssl_client    | CVE-2021-36159   | CRITICAL | 1.33.1-r3         | 1.33.1-r4     | busybox: libbb/copy_file.0 in...    |
| zlib          | CVE-2022-37434   | HIGH     | 1.2.11-r4         | 1.2.12-r0     | zlib: heap-based buffer overflow... |
| apk-tools     | CVE-2021-36159   | HIGH     | 2.12.5-r0         | 2.12.7-r0     | libapk/apk_archive.c in apk-tools...|
+---------------+------------------+----------+-------------------+---------------+-------------------------------------+
```

#### Paso 2.3: Escanear el SBOM directamente en lugar de las layers de la image raw
Escaneá el documento JSON del SBOM directamente para desacoplar el acceso a la image del scanner engine de la evaluación de políticas del artefacto:

```bash
trivy sbom alpine-3.18.0.sbom.json --severity CRITICAL
```

##### Salida Esperada
```text
alpine-3.18.0.sbom.json (cyclonedx)
Total: 0 (CRITICAL: 0)
```

---

#### Preguntas de Verificación (Ejercicio 2)
1. **Pregunta 2.1**: ¿Cuál es la ventaja operacional clave de escanear un documento SBOM en comparación con ejecutar un escaneo completo del filesystem de una container image dentro de un CI pipeline?
2. **Pregunta 2.2**: ¿Por qué se utiliza `--ignore-unfixed` en los pipelines de control (gating) de deployment en producción, y qué trade-off introduce?

---

### Ejercicio 3: Firma de Images Basada en Claves y Sin Claves (Keyless) con Cosign y Adjunta de Atestaciones

#### Escenario
Debés establecer una cadena de custodia criptográfica para artefactos de aplicaciones usando `cosign`. Generarás un keypair, firmarás una container image, adjuntarás una atestación SBOM como un artefacto OCI y verificarás criptográficamente la firma.

#### Paso 3.1: Generar un Key Pair ECDSA
Generá un keypair privado/público usando `cosign`:

```bash
export COSIGN_PASSWORD="ProductionSecurePassword123!"
cosign generate-key-pair
```

##### Salida Esperada
```text
Private key written to cosign.key
Public key written to cosign.pub
```

#### Paso 3.2: Firmar un artefacto / image digest OCI local
Asumiendo una image de prueba local `localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`:

```bash
cosign sign --key cosign.key --yes localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

##### Salida Esperada
```text
Enter password for private key: 
Pushing signature to: localhost:5000/app/sec-service
```

#### Paso 3.3: Adjuntar una Atestación SBOM in-toto a la Image
Adjuntá el SBOM CycloneDX generado en el Ejercicio 2 como una layer de atestación in-toto:

```bash
cosign attest --key cosign.key \
  --type cyclonedx \
  --predicate alpine-3.18.0.sbom.json \
  localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

##### Salida Esperada
```text
Using payload from predicate file: alpine-3.18.0.sbom.json
Attestation pushed to OCI registry: localhost:5000/app/sec-service:sha256-1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef.att
```

#### Paso 3.4: Verificar Criptográficamente la Firma usando la Clave Pública
Verificá que la image remota no haya sido alterada y haya sido firmada con la clave privada correspondiente:

```bash
cosign verify --key cosign.pub localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef | jq .
```

##### Salida Esperada
```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/app/sec-service"
      },
      "image": {
        "docker-manifest-digest": "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
      },
      "type": "cosign container image signature"
    },
    "optional": null
  }
]
```

---

#### Preguntas de Verificación (Ejercicio 3)
1. **Pregunta 3.1**: ¿Dónde almacena `cosign` por defecto la firma generada para una OCI image cuando se firma con firmas basadas en claves?
2. **Pregunta 3.2**: En la firma "Keyless" usando Sigstore, ¿cómo se gestionan y verifican las claves públicas sin archivos de clave privada de larga duración?

---

### Ejercicio 4: Aplicación de Políticas de Admission Control con Kyverno

#### Escenario
Tenés la tarea de desplegar una `ClusterPolicy` de Kyverno en modo de bloqueo (`enforce`) para prevenir cualquier deployment de Pod si:
1. La image no proviene de un registry interno aprobado.
2. La image utiliza un tag mutable en lugar de un digest SHA-256 inmutable.
3. La image no está firmada criptográficamente con la clave pública de `cosign` de la empresa.

#### Paso 4.1: Escribir el Manifest Completo de la Política de Kyverno
Guardá el siguiente manifest completo y sintácticamente válido en `verify-image-policy.yaml`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-provenance-and-digests
  annotations:
    policies.kyverno.io/title: Enforce Registry, Digest Pinning, and Cosign Signatures
    policies.kyverno.io/category: Software Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    description: >-
      Requires container images to originate from approved registries, use immutable SHA-256 
      digests, and pass cryptographic Cosign signature verification before pod admission.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
  - name: verify-registry-and-digest-format
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Image must originate from 'registry.internal.net' or 'registry.k8s.io' and use a valid @sha256: digest."
      pattern:
        spec:
          containers:
          - image: "(registry.internal.net/*|registry.k8s.io/*)@sha256:*"
  - name: verify-cosign-signature
    match:
      any:
      - resources:
          kinds:
          - Pod
    imageExtractors:
      Pod:
      - name: containers
        path: /spec/containers/*
    verifyImages:
    - imageReferences:
      - "registry.internal.net/*"
      key: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEU2lnbmF0dXJlVmVyaWZpY2F0aW9u
        S2V5Rm9yS0NTQUNlcnRpZmljYXRpb25UZXN0aW5nRW52aXJvbm1lbnRPbmx5MDA9
        -----END PUBLIC KEY-----
```

#### Paso 4.2: Aplicar la ClusterPolicy de Kyverno
Aplicá el manifest de la política:

```bash
kubectl apply -f verify-image-policy.yaml
```

##### Salida Esperada
```text
clusterpolicy.kyverno.io/enforce-image-provenance-and-digests created
```

#### Paso 4.3: Probar el Deployment de un Pod No Conforme (Bloqueado por el Admission Webhook)
Intentá desplegar una image no aprobada usando un tag mutable (`nginx:latest`):

```bash
kubectl run non-compliant-test --image=nginx:latest
```

##### Salida Esperada
```text
Error from server (Forbidden): admission webhook "validate.kyverno.svc-fail" denied the request: 
resource Pod/default/non-compliant-test was blocked due to the following policy rules:
verify-registry-and-digest-format: Image must originate from 'registry.internal.net' or 'registry.k8s.io' and use a valid @sha256: digest.
```

---

#### Preguntas de Verificación (Ejercicio 4)
1. **Pregunta 4.1**: ¿Qué fallo ocurre en el control plane de Kubernetes si una `ValidatingWebhookConfiguration` para verificación de firmas de images está configurada con `failurePolicy: Fail` y el backend del webhook se vuelve inalcanzable?
2. **Pregunta 4.2**: ¿Cuál es el propósito de configurar `background: false` en políticas de Kyverno que realizan verificaciones externas criptográficas de firmas de images?

---

### Ejercicio 5: Seguridad de Registry Privado, RBAC y OCI Distribution Specification

#### Escenario
Debés configurar controles de acceso de producción y reglas de escaneo de vulnerabilidades para un container registry privado que cumpla con la [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec).

#### Paso 5.1: Configurar el RBAC de la Robot Account en Harbor Registry
Creá un payload de configuración de robot account de solo lectura `robot-reader.json` para service accounts de deployment con acceso exclusivo de pull:

```json
{
  "name": "k8s-image-puller",
  "description": "Production Kubernetes Cluster Pull-Only Robot Account",
  "secret": "ProductionSuperSecretRobotKey2026!",
  "level": "system",
  "disable": false,
  "duration": -1,
  "permissions": [
    {
      "resource": "repository",
      "action": "pull",
      "namespace": "production-apps"
    },
    {
      "resource": "artifact-addition",
      "action": "read",
      "namespace": "production-apps"
    }
  ]
}
```

#### Paso 5.2: Crear el ImagePullSecret `docker-registry` en Kubernetes
Almacená las credenciales de la robot account del registry en un secret de Kubernetes dentro del namespace `default`:

```bash
kubectl create secret docker-registry harbor-pull-secret \
  --docker-server=registry.internal.net \
  --docker-username='robot$k8s-image-puller' \
  --docker-password='ProductionSuperSecretRobotKey2026!' \
  --docker-email='sre-team@company.internal'
```

##### Salida Esperada
```text
secret/harbor-pull-secret created
```

#### Paso 5.3: Adjuntar `imagePullSecrets` a un ServiceAccount del Namespace
Vinculá el secret al ServiceAccount default para que los pods no requieran referencias individuales a secrets:

```bash
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
```

##### Salida Esperada
```text
serviceaccount/default patched
```

---

#### Preguntas de Verificación (Ejercicio 5)
1. **Pregunta 5.1**: ¿Qué riesgo de seguridad surge cuando los desarrolladores usan personal access tokens (PATs) a nivel de usuario en lugar de Robot Accounts con scope limitado dentro de pipelines CI/CD para hacer push de images?
2. **Pregunta 5.2**: En un registry conforme con OCI, ¿qué capacidad proporciona la configuración de una política de proyecto a "Immutable Tags" contra ataques a la cadena de suministro?

---

## 3. Respuestas de Verificación y Explicaciones Diagnósticas

<details>
<summary><strong>Haz clic para expandir las Respuestas y Explicaciones Técnicas Detalladas</strong></summary>

### Respuestas del Ejercicio 1
- **Respuesta 1.1**: El deployment del pod continuará ejecutándose y haciendo pull del contenido exacto de las layers originales definido por la cadena del digest `@sha256:...`. El container runtime resuelve las images mediante el hash de contenido del digest en lugar de los nombres de los tags. El cambio del tag upstream es ignorado completamente por Kubernetes, garantizando deployments deterministas y reproducibles.
- **Respuesta 1.2**: `imagePullPolicy: Always` fuerza al Kubelet a contactar al registry remoto para verificar si el digest del tag ha cambiado. Sin embargo, si un atacante sobrescribe el tag remoto `v1.2.0` con un payload malicioso, Kubelet detectará un digest actualizado bajo ese mismo nombre de tag y hará pull de la image comprometida. El digest pinning previene esto porque el propio digest especificado forma parte del filtro de la solicitud.

---

### Respuestas del Ejercicio 2
- **Respuesta 2.1**: Escanear un documento JSON de un SBOM toma milisegundos y consume CPU/RAM despreciables porque opera puramente sobre datos de texto estructurado (nombres de paquetes y cadenas de versión), evitando la sobrecarga computacional de hacer pull de layers tarball de varios gigabytes, descomprimir diffs de layers y recorrer archivos de sistema completos. También permite volver a escanear vulnerabilidades sin acceso de almacenamiento a las container images originales.
- **Respuesta 2.2**: `--ignore-unfixed` filtra los CVEs reportados que actualmente no tienen un parche publicado por los mantenedores de la distribución upstream.  
  *Trade-off Operacional*: Reduce el ruido para desarrolladores y la fricción en el pipeline al enfocarse en vulnerabilidades accionables. Sin embargo, introduce riesgos de seguridad al ocultar vulnerabilidades zero-day o no parcheadas que requieren controles de seguridad de mitigación (tales como network policies, perfiles de apparmor o reglas de WAF).

---

### Respuestas del Ejercicio 3
- **Respuesta 3.1**: Por defecto, `cosign` escribe la firma directamente de regreso en el OCI registry de destino como un artefacto OCI manifest secundario formateado con el patrón de nombre de tag: `sha256-<digest>.sig`. Esto almacena las firmas directamente junto a los blobs de la container image original sin requerir una base de datos externa para almacenamiento de firmas.
- **Respuesta 3.2**: En la firma Keyless, se generan pares de claves ECDSA de corta duración de forma efímera en memoria mediante `cosign`. `Fulcio` (la CA raíz) valida el token de identidad OIDC del desarrollador o del proceso de CI (por ejemplo, token de GitHub Actions) y emite un certificado X.509 válido por una ventana breve (por ejemplo, 10 minutos) que contiene la identidad OIDC. La firma y el certificado se envían a `Rekor` (el registro de transparencia inmutable Merkle tree). Los verificadores inspeccionan Rekor y las cadenas de certificados raíz de Fulcio para validar la identidad sin gestionar archivos de clave pública de larga duración.

---

### Respuestas del Ejercicio 4
- **Respuesta 4.1**: Si el servicio del admission webhook falla o se vuelve inalcanzable bajo `failurePolicy: Fail`, el API server de Kubernetes rechazará **todas** las solicitudes de creación y actualización de Pods en todo el cluster que coincidan con la regla del webhook. Esto protege contra deployments no validados, pero puede causar interrupciones completas del control plane si la infraestructura del admission controller falla.
- **Respuesta 4.2**: `background: false` deshabilita el controller de escaneo de auditoría en segundo plano de Kyverno para esa regla específica. Debido a que la verificación criptográfica de la image requiere realizar llamadas de red a registries remotos para obtener firmas OCI y claves públicas, ejecutar estas verificaciones de forma continua en bucles en segundo plano generaría una sobrecarga masiva de red y problemas de rate-limiting contra los registries.

---

### Respuestas del Ejercicio 5
- **Respuesta 5.1**: Los PATs a nivel de usuario poseen todos los permisos de acceso de la identidad humana (que a menudo abarcan acceso de escritura/eliminación en múltiples namespaces y capacidades administrativas). Si se filtran desde logs de CI pipelines o build runners, los atacantes obtienen un amplio acceso de escritura y eliminación. Las Robot Accounts proporcionan el menor privilegio (Least Privilege) a través de un RBAC de grano fino limitado a acciones específicas (`pull` solamente) y scopes de repositorio único.
- **Respuesta 5.2**: Las políticas de Immutable Tag aplican un comportamiento de escritura única (write-once) en la capa de la API del registry. Una vez que se hace push de un tag (por ejemplo, `v2.4.1`), el registry rechaza las solicitudes `HTTP PUT` subsiguientes que intenten sobrescribir ese tag, bloqueando eficazmente los ataques de tag-poisoning a nivel del gateway de almacenamiento.

</details>

---

## 4. Referencias Oficiales y URLs de Citación

1. **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
2. **Open Container Initiative (OCI) Image Specification**: [https://github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)
3. **OCI Distribution Specification**: [https://github.com/opencontainers/distribution-spec](https://github.com/opencontainers/distribution-spec)
4. **Sigstore Cosign Documentation**: [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
5. **Kyverno Image Verification Documentation**: [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)
6. **Aqua Security Trivy Documentation**: [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)
7. **Anchore Syft Specification**: [https://github.com/anchore/syft](https://github.com/anchore/syft)
8. **Kubernetes Image Pull Secrets Guidance**: [https://kubernetes.io/docs/concepts/containers/images/#using-a-private-registry](https://kubernetes.io/docs/concepts/containers/images/#using-a-private-registry)