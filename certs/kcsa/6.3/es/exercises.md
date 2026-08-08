# Guía de estudio KCSA: Tema 6.3 – Supply Chain Compliance

**Examen**: Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio**: Supply Chain Security  
**Tema 6.3**: Supply Chain Compliance  
**Ponderación**: 2.5%  

---

## Fuentes de referencia oficiales
* **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **CNCF Software Supply Chain Best Practices**: [https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsc-v1.pdf](https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsc-v1.pdf)
* **SLSA Framework Specification (v1.0)**: [https://slsa.dev/spec/v1.0/](https://slsa.dev/spec/v1.0/)
* **Sigstore Documentation**: [https://docs.sigstore.dev/](https://docs.sigstore.dev/)
* **in-toto Attestation Framework**: [https://in-toto.github.io/](https://in-toto.github.io/)
* **SPDX Specification (v2.3)**: [https://spdx.github.io/spdx-spec/v2.3/](https://spdx.github.io/spdx-spec/v2.3/)
* **CycloneDX Specification**: [https://cyclonedx.org/docs/1.5/json/](https://cyclonedx.org/docs/1.5/json/)
* **Kyverno Image Verification Policy**: [https://kyverno.io/docs/user-guide/image-verify/](https://kyverno.io/docs/user-guide/image-verify/)

---

## Contexto técnico y visión general de la arquitectura

El Cumplimiento de la Cadena de Suministro (Supply Chain Compliance) en entornos cloud-native garantiza que los artefactos de software desplegados en clusters de producción sean verificables, a prueba de manipulaciones (tamper-evident) y rastreables hasta su origen. El cumplimiento abarca el ciclo de vida del desarrollo de software (SDLC) a través de cuatro primitivas fundamentales:

1. **Software Bill of Materials (SBOM)**: Un inventario de componentes de código abierto y propietarios, dependencias, licencias y hashes dentro de una build. Los formatos estandarizados incluyen **SPDX** (ISO/IEC 5962:2021) y **CycloneDX** (OWASP).
2. **Provenance & Attestations**: Metadata criptográfica que se adhiere a frameworks como **SLSA** (Supply-chain Levels for Software Artifacts) e **in-toto**. Las atestaciones vinculan el hash de un artefacto con los parámetros de su entorno de build y los registros de build.
3. **Cryptographic Artifact Signing (Ecosistema Sigstore)**:
   * **Cosign**: Firma imágenes de contenedor, almacenes de blobs (blob stores) y atestaciones.
   * **Fulcio**: Autoridad de Certificación (CA) Raíz gratuita que emite certificados X.509 de corta duración vinculados a identidades OIDC (Keyless signing).
   * **Rekor**: Registro de transparencia inmutable y de solo anexión (append-only) que proporciona prueba pública de la existencia de firmas mediante raíces de Árboles de Merkle (Merkle Tree roots).
4. **In-Cluster Dynamic Enforcement**: Los Dynamic Admission Controllers de Kubernetes (por ejemplo, Kyverno u OPA Gatekeeper) interceptan solicitudes de creación de Pods, consultan registros de transparencia/registros OCI y bloquean artefactos no conformes en el momento de la admisión.

---

## Ejercicio 1: Generación, auditoría y validación del cumplimiento de SBOM

En este ejercicio, generarás SBOMs de grado de producción utilizando `syft` en formatos estándar (SPDX y CycloneDX), inspeccionarás la integridad estructural, verificarás el cumplimiento de licencias y escanearás el SBOM generado en busca de vulnerabilidades.

### Paso 1.1: Generar un SBOM JSON SPDX 2.3 a partir de una imagen OCI

Ejecutá el CLI de `syft` para inspeccionar una imagen de grado de producción (`registry.k8s.io/kube-apiserver:v1.30.0`) y exportar un artefacto JSON SPDX.

```bash
syft registry.k8s.io/kube-apiserver:v1.30.0 -o spdx-json=apiserver-spdx.json
```

**Salida esperada:**
```text
 ✔ Loaded image            registry.k8s.io/kube-apiserver:v1.30.0
 ✔ Parsed image            sha256:d8b22a0134bc5bd8e50b7b12d98d2ef071e626e5e0cf79f972b9a71db294e7df
 ✔ Cataloged packages      [142 packages]
```

### Paso 1.2: Auditar la estructura del documento SPDX y los checksums criptográficos

Usá `jq` para consultar campos críticos de cumplimiento dentro de `apiserver-spdx.json`: espacio de nombres del documento (document namespace), marca de tiempo de creación (creation timestamp), licencia de datos (data license) y checksums de los paquetes.

```bash
jq '{
  spdxVersion: .spdxVersion,
  dataLicense: .dataLicense,
  documentNamespace: .documentNamespace,
  packageCount: (.packages | length),
  samplePackage: .packages[0] | {name: .name, versionInfo: .versionInfo, checksums: .checksums}
}' apiserver-spdx.json
```

**Salida esperada:**
```json
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "https://anchore.com/syft/image/registry.k8s.io/kube-apiserver-v1.30.0-60b81e81-3c22-4467-9c6a-c2ff5d56abf2",
  "packageCount": 142,
  "samplePackage": {
    "name": "golang.org/x/net",
    "versionInfo": "v0.17.0",
    "checksums": [
      {
        "algorithm": "SHA256",
        "checksumValue": "4bc49bf55d9d70df88e89fcf2f42a1705e4922129d381014e86a074c5d6e24ee"
      }
    ]
  }
}
```

### Paso 1.3: Generar un SBOM JSON CycloneDX 1.5 y realizar un filtrado de cumplimiento de licencias

Generá una representación JSON CycloneDX del mismo artefacto, luego filtrá los paquetes que carezcan de licencias de código abierto conformes.

```bash
syft registry.k8s.io/kube-apiserver:v1.30.0 -o cyclonedx-json=apiserver-cyclonedx.json

jq '[.components[] | select(.licenses == null or (.licenses | length) == 0) | {name: .name, version: .version}]' apiserver-cyclonedx.json
```

**Salida esperada:**
```json
[]
```

---

### Preguntas – Ejercicio 1

**P1.1**: ¿Cuál es la diferencia estructural clave entre SPDX y CycloneDX con respecto a sus intenciones de diseño primarias?  
**P1.2**: En un pipeline de cadena de suministro de alta seguridad, ¿por qué generar un SBOM *dentro* de un contenedor en ejecución en el momento del despliegue se considera un antipatrón en comparación con generarlo *durante la ejecución del build*?

---

## Ejercicio 2: Firma criptográfica de imágenes y atestaciones in-toto con Sigstore Cosign

En este ejercicio, generarás claves criptográficas estáticas, adjuntarás una atestación de predicado SBOM in-toto a un artefacto OCI utilizando `cosign` y auditarás las entradas del registro de transparencia (transparency log).

### Paso 2.1: Generar un par de claves de Cosign

Generá un par de claves pública/privada utilizando `cosign`. Protegé la clave privada con una contraseña.

```bash
COSIGN_PASSWORD="KcsASecurePassword2026!" cosign generate-key-pair
```

**Salida esperada:**
```text
Private key written to cosign.key
Public key written to cosign.pub
```

### Paso 2.2: Firmar una imagen de contenedor con claves estáticas

Firmá una imagen OCI de destino (reemplazá `localhost:5000/demo/app:v1.0.0` con la ruta de tu registro de destino o registro de distribución local).

```bash
COSIGN_PASSWORD="KcsASecurePassword2026!" cosign sign --key cosign.key localhost:5000/demo/app:v1.0.0
```

**Salida esperada:**
```text
Pushing signature to: localhost:5000/demo/app:sha256-a1b2c3...sig
Enter password for private key: 
Applying signature tag to localhost:5000/demo/app:sha256-a1b2c3...sig
```

### Paso 2.3: Adjuntar el SBOM como una atestación de predicado in-toto

Adjuntá `apiserver-spdx.json` a la imagen de contenedor utilizando el tipo de predicado `spdxjson`.

```bash
COSIGN_PASSWORD="KcsASecurePassword2026!" cosign attest \
  --key cosign.key \
  --type spdxjson \
  --predicate apiserver-spdx.json \
  localhost:5000/demo/app:v1.0.0
```

**Salida esperada:**
```text
Pushing attestation to: localhost:5000/demo/app:sha256-a1b2c3...att
Uploading attestation to Rekor transparency log...
Attestation entry created with index: 89432104
```

### Paso 2.4: Verificar la atestación de la imagen y auditar el payload

Verificá la atestación utilizando `cosign verify-attestation` y decodificá el payload.

```bash
cosign verify-attestation \
  --key cosign.pub \
  --type spdxjson \
  localhost:5000/demo/app:v1.0.0 | jq -r '.[].payload' | base64 --decode | jq
```

**Salida esperada:**
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://spdx.dev/Document",
  "subject": [
    {
      "name": "localhost:5000/demo/app",
      "digest": {
        "sha256": "a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0"
      }
    }
  ],
  "predicate": {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0"
  }
}
```

---

### Preguntas – Ejercicio 2

**P2.1**: ¿Qué riesgo clave resuelve **Fulcio** de Sigstore (Keyless Signing) en comparación con la gestión de pares de claves asimétricas estáticas (`cosign.key`/`cosign.pub`) a través de plataformas de ingeniería CI/CD multitenant?  
**P2.2**: ¿Cómo previene **Rekor** que un administrador comprometido de un registro de contenedores reemplace de forma encubierta y sin ser detectado el digest de una capa de imagen OCI firmada válida?

---

## Ejercicio 3: Aplicación de políticas in-cluster con el control de admisión de Kyverno

En este ejercicio, desplegarás una `ClusterPolicy` de Kyverno sintácticamente válida y de grado de producción que exige la verificación de firma criptográfica con Cosign en todas las imágenes de Pod antes de permitir su despliegue en el cluster.

### Paso 3.1: Crear el manifiesto de la ClusterPolicy de verificación de imágenes de Kyverno

Guardá el siguiente manifiesto completo en `kyverno-supply-chain-policy.yaml`. Esta política exige comprobaciones de firma con una clave pública de Cosign designada para todas las imágenes desplegadas en namespaces etiquetados con `compliance=strict`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-supply-chain
  annotations:
    policies.kyverno.io/title: Verify Image Signatures with Cosign
    policies.kyverno.io/category: Supply Chain Compliance
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    description: >-
      Enforces that all container images deployed into compliance-monitored 
      namespaces have a valid Cosign cryptographic signature matching the 
      enterprise trusted public key.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  rules:
    - name: verify-signature-cosign
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaceSelector:
              matchLabels:
                compliance: strict
      verifyImages:
        - imageReferences:
            - "localhost:5000/*"
            - "docker.io/myorg/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless: {}
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N3f9...[YOUR_PUBLIC_KEY_PEM]...
                      -----END PUBLIC KEY-----
```

### Paso 3.2: Aplicar el manifiesto y las etiquetas del namespace

Aplicá la política y creá un namespace de destino etiquetado para el cumplimiento normativo.

```bash
kubectl apply -f kyverno-supply-chain-policy.yaml
kubectl create namespace prod-secure
kubectl label namespace prod-secure compliance=strict
```

**Salida esperada:**
```text
clusterpolicy.kyverno.io/verify-image-supply-chain created
namespace/prod-secure created
namespace/prod-secure labeled
```

### Paso 3.3: Probar el rechazo forzado de imágenes de contenedor no firmadas

Intentá desplegar una imagen de contenedor no firmada (`docker.io/myorg/untrusted-app:v1.0.0`) en el namespace `prod-secure`.

```bash
kubectl run test-unsigned \
  --image=docker.io/myorg/untrusted-app:v1.0.0 \
  -n prod-secure
```

**Salida esperada:**
```text
Error from server (Forbidden): admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: 

resource Pod/prod-secure/test-unsigned was blocked due to the following policies:

verify-image-supply-chain:
  verify-signature-cosign: 'image verification failed for docker.io/myorg/untrusted-app:v1.0.0: 
    failed to verify signature: no matching signatures found'
```

### Paso 3.4: Diagnóstico avanzado y auditoría de webhooks

Inspeccioná el estado de ejecución de la política y buscá trazas de validación de cumplimiento en los registros de auditoría de admisión.

```bash
# Check status of cluster policy
kubectl get clusterpolicy verify-image-supply-chain -o jsonpath='{.status}' | jq

# Search Kyverno webhook admission events
kubectl get events -n prod-secure --field-selector reason=PolicyViolation
```

**Salida esperada:**
```json
{
  "conditions": [
    {
      "lastTransitionTime": "2026-08-07T20:35:43Z",
      "message": "Ready",
      "reason": "Succeeded",
      "status": "True",
      "type": "Ready"
    }
  ],
  "rulecount": {
    "generate": 0,
    "mutate": 0,
    "validate": 0,
    "verifyimages": 1
  }
}
```

---

### Preguntas – Ejercicio 3

**P3.1**: En la `ClusterPolicy` de Kyverno, ¿cuál es la compensación (trade-off) funcional de establecer `mutateDigest: true` dentro del contexto de la regla `verifyImages`?  
**P3.2**: Si un nodo del cluster sufre una interrupción temporal de la red WAN que impide el acceso a registros de imágenes OCI externos o a registros de transparencia durante un evento de reinicio de un Pod, ¿cómo difiere el comportamiento del control de admisión según las configuraciones de `webhookTimeoutSeconds` y `failurePolicy` en la `ValidatingWebhookConfiguration`?

---

<details>
<summary><b>Haz clic para expandir: Respuestas y explicaciones</b></summary>

### Respuestas del Ejercicio 1

* **R1.1**: **SPDX** (System Package Data Exchange) fue originado por la Linux Foundation con un enfoque principal en el cumplimiento de licencias de software, seguimiento legal y documentación precisa del copyright de los paquetes. **CycloneDX** fue creado por OWASP adaptado específicamente para casos de uso de seguridad, pruebas de seguridad de aplicaciones (AST), divulgación de vulnerabilidades y gestión de riesgos de la cadena de suministro de software (SCRM).
* **R1.2**: Generar un SBOM dentro de un contenedor en ejecución en el momento del despliegue plantea dos problemas graves de seguridad:
  1. **Riesgo de alteración e integridad (Taint & Integrity Risk)**: Un entorno de contenedor en tiempo de ejecución podría haber sido mutado o infectado con malware transitorio antes del escaneo, generando un SBOM inexacto o manipulado.
  2. **Fallo de no repudio y atestación de build (Non-Repudiation & Build Attestation Failure)**: Un SBOM generado después de la creación de la imagen no se puede vincular de forma criptográfica y determinista a los commits del código fuente en tiempo de build, a las flags del compilador ni a la identidad del pipeline del runner de CI. El cumplimiento de SLSA exige la creación del SBOM durante la fase de build.

---

### Respuestas del Ejercicio 2

* **R2.1**: **Fulcio Keyless Signing** elimina las claves privadas estáticas de larga duración (`cosign.key`), evitando filtraciones de claves privadas, almacenamiento de contraseñas y complejas operaciones de rotación de claves entre equipos. Fulcio aprovecha los tokens de OpenID Connect (OIDC) (de GitHub Actions, GitLab CI o proveedores de identidad de Google Cloud) para emitir certificados X.509 de corta duración (validez de 10 minutos). El certificado vincula la firma directamente con la identidad efímera del trabajo de CI sin almacenar claves privadas en ningún lugar.
* **R2.2**: **Rekor** es un registro de transparencia de solo anexión (append-only) construido sobre un Árbol de Merkle criptográfico (similar a los registros de transparencia de certificados). Una vez que se registra una entrada (hash de la imagen, firma, clave pública/certificado) en Rekor, el registro genera una marca de tiempo de entrada firmada (Signed Entry Timestamp - SET) y una prueba de inclusión. Incluso si un administrador del registro reemplaza el digest de una capa de imagen OCI en el almacenamiento secundario (storage backend), el nuevo digest no coincidirá con el hash inmutable de la hoja del árbol de Merkle registrado en los logs públicos de Rekor, lo que desencadenará un fallo inmediato en la verificación de admisión.

---

### Respuestas del Ejercicio 3

* **R3.1**: Establecer `mutateDigest: true` instruye a Kyverno para que resuelva automáticamente las etiquetas de imagen mutables (por ejemplo, `:v1.0.0` o `:latest`) a su digest SHA-256 inmutable exacto (`@sha256:d8b22a0...`) durante la mutación de admisión. 
  * **Compensación (Trade-off)**: Esto elimina los vectores de vulnerabilidad Time-of-Check to Time-of-Use (TOCTOU) donde una etiqueta se modifica entre la comprobación de admisión y el estiramiento (pull) de la imagen por parte del kubelet. Sin embargo, requiere que el controlador de admisión realice llamadas de red salientes al registro OCI en el momento de la creación del pod para consultar los manifiestos de imagen, introduciendo latencia en la API y dependencias del tiempo de actividad (uptime) del registro.
* **R3.2**: Si la conectividad externa con el registro o la transparencia falla durante la admisión del pod:
  * Si la `failurePolicy` del webhook de admisión está configurada en `Fail` (predeterminado en producción por seguridad), cualquier intento de creación o reinicio de Pod será **bloqueado** por completo por el servidor de la API si el webhook agota el tiempo de espera (excede `webhookTimeoutSeconds`).
  * Si está configurada en `Ignore`, el servidor de la API omite la verificación, permitiendo que se ejecuten imágenes de contenedor potencialmente no firmadas o no verificadas. 
  * **Nota**: Las imágenes en caché del Kubelet en nodos existentes podrían reiniciarse bajo el control local del `kubelet` sin golpear el webhook de admisión del servidor de la API, pero las operaciones de escalado o las nuevas creaciones de Pod fallarán bajo `failurePolicy: Fail`.

</details>