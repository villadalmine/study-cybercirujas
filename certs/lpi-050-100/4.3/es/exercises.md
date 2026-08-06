# LPI 050-100 | Tema 4.3: Cumplimiento y Mitigación de Riesgos

## Profundización Técnica: Cumplimiento de Código Abierto, SBOM y Seguridad de la Cadena de Suministro

En la arquitectura cloud-native moderna, el Software de Código Abierto (OSS) constituye hasta un 80–90% de un stack de software de producción típico. La gestión del riesgo del código abierto requiere una estrategia de cumplimiento y gobernanza multicapa que abarca tres pilares fundamentales: **Cumplimiento de Licencias**, **Mitigación de Riesgos de Vulnerabilidad y CVE**, y **Procedencia de la Cadena de Suministro de Software**.

```
                           [ Source Repository ]
                                     │
                                     ▼
                ┌─────────────────────────────────────────┐
                │        CI/CD Build & Packaging          │
                └────────────────────┬────────────────────┘
                                     │
             ┌───────────────────────┼───────────────────────┐
             ▼                       ▼                       ▼
   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
   │ SBOM Generation  │    │ License Audit    │    │  Vulnerability   │
   │ (SPDX / Cyclone) │    │ Compliance (OPA) │    │  Scan (Grype)    │
   └─────────┬────────┘    └─────────┬────────┘    └─────────┬────────┘
             │                       │                       │
             └───────────────────────┼───────────────────────┘
                                     ▼
                        ┌─────────────────────────┐
                        │ Cryptographic Signing   │
                        │   (Cosign / SLSA Proven)│
                        └────────────┬────────────┘
                                     ▼
                        ┌─────────────────────────┐
                        │ Kubernetes Admission    │
                        │   Control Enforcement   │
                        └─────────────────────────┘
```

### Arquitectura Central y Mecánica

1. **Software Bill of Materials (SBOM)**:
   Un SBOM es un inventario anidado de componentes de software, dependencias, metadatos e información de licencias. Las especificaciones estandarizadas incluyen:
   - **SPDX (ISO/IEC 5962)**: Estándar de la Linux Foundation que enfatiza definiciones precisas de identificadores de licencias, relaciones y derechos de autor a nivel de archivo.
   - **CycloneDX (OWASP)**: Diseñado principalmente para la automatización de la seguridad, la identificación de vulnerabilidades y el mapeo del gráfico de componentes.

2. **Mecánica de Cumplimiento de Licencias y Matriz de Compatibilidad**:
   - **Permisible (MIT, Apache-2.0, BSD-3-Clause)**: Permite la redistribución, modificación e integración en software propietario sin forzar la divulgación del código fuente derivado. Apache-2.0 agrega explícitamente protecciones de concesión de patentes.
   - **Copyleft débil (LGPL-3.0, MPL-2.0)**: Requiere que las modificaciones a la propia librería permanezcan como código abierto, pero permite la vinculación dinámica con código propietario.
   - **Copyleft fuerte (GPL-2.0, GPL-3.0)**: Requiere que cualquier trabajo derivado distribuido a los usuarios finales libere su código fuente completo bajo los mismos términos de licencia.
   - **Copyleft de red (AGPL-3.0)**: Extiende las obligaciones de copyleft fuerte al software operado a través de una red como servicio (SaaS), eliminando el "vacío legal de SaaS".

3. **Arquitecturas de Mitigación de Riesgos**:
   - **Análisis Estático y Análisis de Composición (SCA)**: Inspecciona las dependencias directas y transitivas contra bases de datos de vulnerabilidades conocidas (NVD, GHSA) y bases de datos de licencias de código abierto.
   - **Control de Acceso mediante Motores de Políticas (Policy Engine Gatekeeping)**: Políticas declarativas (por ejemplo, Open Policy Agent/Rego o Kyverno) evaluadas durante la ejecución de CI/CD y el control de admisión de contenedores para rechazar licencias prohibidas (por ejemplo, AGPL-3.0 en imágenes propietarias) o CVE críticos sin parches activos.

---

## Ejercicios Guiados

### Ejercicio 1: Generación de Software Bill of Materials (SBOM) y Auditoría de Cumplimiento de Licencias

#### Objetivo
Generar un SBOM SPDX 2.3 de nivel de producción para una aplicación contenedorizada utilizando `syft`, realizar una validación automatizada de cumplimiento de licencias contra la política de gobernanza empresarial y auditar dependencias transitivas.

#### Paso 1.1: Configuración del Entorno y Creación de Artefactos
Crear una definición de contenedor de microservicio de producción simulado con dependencias mixtas de código abierto.

```bash
mkdir -p /tmp/compliance-lab && cd /tmp/compliance-lab

cat <<'EOF' > Dockerfile
FROM alpine:3.19.1
RUN apk add --no-舆-cache bash curl openssl py3-pip
RUN pip install --no-cache-dir requests==2.31.0 flask==3.0.2
COPY app.py /app/app.py
ENTRYPOINT ["python3", "/app/app.py"]
EOF

cat <<'EOF' > app.py
import requests
from flask import Flask
app = Flask(__name__)

@app.route('/')
def health():
    return {"status": "healthy", "upstream": requests.get("https://httpbin.org/status/200").status_code}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

docker build -t microservice:v1.0.0 .
```

*Salida esperada:*
```text
[+] Building 8.4s (8/8) FINISHED
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 245B
 => [1/4] FROM docker.io/library/alpine:3.19.1
 => [2/4] RUN apk add --no-cache bash curl openssl py3-pip
 => [3/4] RUN pip install --no-cache-dir requests==2.31.0 flask==3.0.2
 => [4/4] COPY app.py /app/app.py
 => exporting to image
 => => naming to docker.io/library/microservice:v1.0.0
```

#### Paso 1.2: Generación de SBOM SPDX
Extraer un documento JSON SPDX completo legible por máquina que detalle todos los paquetes del sistema operativo y los paquetes a nivel de lenguaje.

```bash
syft microservice:v1.0.0 -o spdx-json=sbom.spdx.json
```

*Salida esperada:*
```text
 ✔ Loaded image            microservice:v1.0.0
 ✔ Parsed image           
 ✔ Cataloged packages      [74 packages]
```

#### Paso 1.3: Inspección del Gráfico de Dependencias y Declaraciones de Licencia
Usar `jq` para inspeccionar el SBOM generado en busca de licencias de componentes e IDs de SPDX.

```bash
jq '{spdxVersion: .spdxVersion, name: .name, packagesCount: (.packages | length), forbidden_licenses: [.packages[] | select(.licenseConcluded | test("AGPL|GPL-3.0"; "i")) | {name: .name, versionInfo: .versionInfo, license: .licenseConcluded}]}' sbom.spdx.json
```

*Salida esperada:*
```json
{
  "spdxVersion": "SPDX-2.3",
  "name": "microservice:v1.0.0",
  "packagesCount": 74,
  "forbidden_licenses": []
}
```

#### Paso 1.4: Escritura de una Regla de Gobernanza de Licencias Personalizada para Open Policy Agent (OPA)
Crear un archivo de política Rego (`license_policy.rego`) que bloquee imágenes que contengan licencias de Copyleft fuerte (GPL-3.0, AGPL-3.0) o licencias no aprobadas.

```bash
cat <<'EOF' > license_policy.rego
package compliance.licensing

default allow = false

forbidden_licenses := ["AGPL-3.0-only", "AGPL-3.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later"]

violations[msg] {
    pkg := input.packages[_]
    lic := pkg.licenseConcluded
    lic == forbidden_licenses[_]
    msg := sprintf("Package %s version %s uses prohibited license: %s", [pkg.name, pkg.versionInfo, lic])
}

allow {
    count(violations) == 0
}
EOF
```

#### Paso 1.5: Evaluación de la Política contra el SBOM Generado
Evaluar la política usando `opa`.

```bash
opa eval --data license_policy.rego --input sbom.spdx.json "data.compliance.licensing"
```

*Salida esperada:*
```json
{
  "result": [
    {
      "expressions": [
        {
          "value": {
            "allow": true,
            "forbidden_licenses": [
              "AGPL-3.0-only",
              "AGPL-3.0-or-later",
              "GPL-3.0-only",
              "GPL-3.0-or-later"
            ],
            "violations": []
          },
          "text": "data.compliance.licensing",
          "location": {
            "file": "",
            "row": 1,
            "col": 1
          }
        }
      ]
    }
  ]
}
```

---

### Preguntas de Verificación - Ejercicio 1

1. **¿Cuál es la diferencia funcional clave entre `licenseDeclared` y `licenseConcluded` de SPDX dentro de un payload de SBOM?**
2. **¿Por qué una licencia AGPL-3.0 plantea un riesgo de cumplimiento específico para los proveedores de SaaS que la GPL-3.0 estándar no plantea?**

---

### Ejercicio 2: Evaluación Automatizada de Vulnerabilidades, Puntuación CVSS y Aplicación de Quality Gates en CI/CD

#### Objetivo
Configurar `grype` para evaluar las vulnerabilidades de imágenes de contenedor contra las fuentes de NVD y EPSS, aplicar una interrupción automatizada por umbral de riesgo en vulnerabilidades Críticas/Altas con correcciones disponibles y exportar informes de cumplimiento estructurados.

#### Paso 2.1: Ejecutar Escaneo de Vulnerabilidades en la Imagen de Contenedor
Ejecutar `grype` en la imagen `microservice:v1.0.0` construida en el Ejercicio 1.

```bash
grype microservice:v1.0.0 -o json > vulnerability_report.json
```

*Salida esperada:*
```text
 ✔ Vulnerability DB        [updated]
 ✔ Loaded image            microservice:v1.0.0
 ✔ Parsed image           
 ✔ Cataloged packages      [74 packages]
 ✔ Scanned image           [14 vulnerabilities]
```

#### Paso 2.2: Extraer CVEs de Severidad Crítica y Alta
Filtrar vulnerabilidades utilizando `jq` para mostrar el ID del CVE, paquete, severidad y estado del parche.

```bash
jq '[.matches[] | select(.vulnerability.severity == "Critical" or .vulnerability.severity == "High") | {cve: .vulnerability.id, severity: .vulnerability.severity, package: .artifact.name, installed_ver: .artifact.version, fix_ver: .vulnerability.fix.versions[0]}]' vulnerability_report.json
```

*Salida esperada:*
```json
[
  {
    "cve": "CVE-2023-5363",
    "severity": "High",
    "package": "openssl",
    "installed_ver": "3.1.4-r1",
    "fix_ver": "3.1.4-r2"
  }
]
```

#### Paso 2.3: Configurar el Gate de Pipeline Automatizado de Fallo por Severidad en CI/CD
Crear un archivo de configuración local `.grype.yaml` para configurar fallos por umbral automatizados.

```bash
cat <<'EOF' > .grype.yaml
fail-on-severity: high
ignore:
  - vulnerability: CVE-2099-99999 # Example false positive
    reason: "Mitigated by infrastructure firewall rules"
only-fixed: true
output: table
EOF
```

#### Paso 2.4: Probar el Disparo del Quality Gate
Ejecutar `grype` con la configuración personalizada de umbral de fallo.

```bash
grype microservice:v1.0.0 -c .grype.yaml
echo "Exit Code: $?"
```

*Salida esperada:*
```text
 ✔ Vulnerability DB        [valid]
 ✔ Loaded image            microservice:v1.0.0
 ✔ Parsed image           
 ✔ Cataloged packages      [74 packages]
 ✔ Scanned image           [1 High vulnerabilities fail threshold]

NAME      INSTALLED  FIXED-IN  TYPE  VULNERABILITY  SEVERITY 
openssl   3.1.4-r1   3.1.4-r2  apk   CVE-2023-5363  High     

[ERROR] threshold fail criteria met: 1 High severity vulnerabilities found
Exit Code: 1
```

---

### Preguntas de Verificación - Ejercicio 2

1. **En el contexto de la Mitigación de Riesgos, ¿en qué se diferencia el Exploit Prediction Scoring System (EPSS) del Common Vulnerability Scoring System (CVSS) al priorizar el despliegue de parches?**
2. **¿Cuál es el riesgo de habilitar `only-fixed: true` en la aplicación del pipeline de vulnerabilidades en producción?**

---

### Ejercicio 3: Firma Criptográfica de la Cadena de Suministro, Atestación y Control de Admisión En-Cluster

#### Objetivo
Firmar una imagen de contenedor utilizando `cosign` sin llaves (keyless, arquitectura Fulcio/Rekor), adjuntar una atestación de SBOM y aplicar una política utilizando primitivas de control de admisión de Kubernetes.

#### Paso 3.1: Generar Llaves de Firma Locales
Crear un par de llaves locales utilizando `cosign` para una simulación de firma fuera de línea/aislada.

```bash
export COSIGN_PASSWORD="ProductionPassphrase123!"
cosign generate-key-pair
```

*Salida esperada:*
```text
Private key written to cosign.key
Public key written to cosign.pub
```

#### Paso 3.2: Firmar el Digest de la Imagen de Contenedor
Firmar la imagen de contenedor utilizando su digest SHA256 inmutable (asumiendo un tag de registry local `localhost:5000/microservice@sha256:...`).

```bash
# Note: Simulating tag digest extraction
IMAGE_DIGEST="microservice@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
cosign sign --key cosign.key --yes $IMAGE_DIGEST
```

*Salida esperada:*
```text
Enter password for private key: 
Signing weight for microservice@sha256:e3b0c442...
Digest signed successfully.
Pushing signature to: localhost:5000/microservice:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.sig
```

#### Paso 3.3: Adjuntar Atestación SBOM In-Toto
Adjuntar el SBOM SPDX generado como una atestación firmada criptográficamente a la referencia de la imagen en el registry.

```bash
cosign attest --key cosign.key --type spdx --predicate sbom.spdx.json $IMAGE_DIGEST
```

*Salida esperada:*
```text
Enter password for private key: 
Storing attestation in image destination: localhost:5000/microservice:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.att
```

#### Paso 3.4: Verificar la Integridad de la Firma y de la Atestación
Verificar la firma de la imagen contra la llave pública.

```bash
cosign verify --key cosign.pub $IMAGE_DIGEST
```

*Salida esperada:*
```json
Verification for microservice@sha256:e3b0c442... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims were validated against the supplied public key
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/microservice"
      },
      "image": {
        "docker-manifest-digest": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      "type": "cosign container image signature"
    },
    "optional": null
  }
]
```

#### Paso 3.5: Definir la Política Kyverno de Kubernetes para la Aplicación de Firmas de Imágenes
Crear una `ClusterPolicy` de Kyverno completa y sintácticamente válida que deniegue cualquier despliegue que ejecute imágenes no firmadas por la llave pública de la organización.

```bash
cat <<'EOF' > cluster_policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signature
  annotations:
    policies.kyverno.io/title: Verify Container Image Signature
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "localhost:5000/*"
          key: |-
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3j10/YmR+1p7Gk7N/3a/0s2uP5b1
            1x4+8bWqH0kH0N7kL+5F8c8d8e8f8g8h8i8j8k8l8m8n8o8p8q8r8s8t8u8v8w==
            -----END PUBLIC KEY-----
EOF
```

---

### Preguntas de Verificación - Ejercicio 3

1. **¿Qué vector de vulnerabilidad previene el hacer referencia a imágenes de contenedor mediante un digest SHA256 inmutable en comparación con el uso de tags mutables como `:latest` o `:v1.0.0`?**
2. **¿Cómo evita la firma sin llaves (keyless signing) utilizando Sigstore (Fulcio y Rekor) la carga operativa de la gestión de llaves privadas de larga duración?**

---

## Soluciones y Respuestas

<details>
<summary>Click to view Answers and Explanations for Exercises 1-3</summary>

### Soluciones del Ejercicio 1

1. **`licenseDeclared` vs. `licenseConcluded`**:
   - `licenseDeclared`: La cadena de licencia sin procesar tal como la declara directamente el autor del paquete ascendente (upstream) en los metadatos (por ejemplo, dentro de `package.json`, `setup.py` o `Cargo.toml`). Esto puede ser ambiguo, no estandarizado o faltar.
   - `licenseConcluded`: El identificador SPDX verificado y canónico asignado después de un análisis automatizado o curaduría manual por parte de una herramienta de cumplimiento o auditor (por ejemplo, convirtiendo "GPLv3+" a `GPL-3.0-or-later`). Los motores de políticas siempre deben evaluar contra `licenseConcluded` para garantizar la precisión legal.

2. **Riesgo de Cumplimiento de AGPL-3.0 en SaaS**:
   - Las obligaciones de copyleft estándar de GPL-3.0 se activan tras la **distribución** de software a terceros. Si una empresa ejecuta software GPL-3.0 en sus propios servidores como una plataforma SaaS sin distribuir binarios a los usuarios, no se requiere la divulgación del código fuente.
   - AGPL-3.0 (GNU Affero General Public License) introduce específicamente la Sección 13 (Interacción remota a través de la red). Ejecutar software AGPL-3.0 a través de una red (SaaS) se define legalmente como un activador de los requisitos de distribución de copyleft, obligando al operador a poner el código fuente completo a disposición de todos los usuarios de la red.

---

### Soluciones del Ejercicio 2

1. **CVSS vs. EPSS en la Mitigación de Riesgos**:
   - **CVSS (Common Vulnerability Scoring System)**: Mide la **severidad** teórica y el impacto técnico de una vulnerabilidad según sus características intrínsecas (por ejemplo, vector de ataque, complejidad, privilegios requeridos). No mide la probabilidad de explotación activa.
   - **EPSS (Exploit Prediction Scoring System)**: Proporciona una puntuación de probabilidad dinámica basada en datos (0.0 a 1.0 / 0% a 100%) de que un CVE específico sea **explotado activamente en el entorno real** dentro de los próximos 30 días. Los equipos de SRE utilizan EPSS junto con CVSS para priorizar el parcheo urgente de errores de menor severidad con alta explotación activa sobre errores de mayor severidad con cero explotación en el mundo real.

2. **Riesgo de `only-fixed: true`**:
   - Configurar `only-fixed: true` hace que el escáner ignore las vulnerabilidades que actualmente no tienen un parche provisto por el proveedor o una versión actualizada del paquete disponible.
   - **Riesgo**: Si bien evita el bloqueo de los pipelines de CI/CD por errores no parcheables del fabricante/upstream, crea un punto ciego masivo. Las vulnerabilidades críticas de día cero (zero-day) o los errores no parcheados de severidad Alta pasarán silenciosamente a producción sin mitigaciones secundarias (como reglas de WAF, microsegmentación de red o controles de seguridad compensatorios).

---

### Soluciones del Ejercicio 3

1. **Vector de Vulnerabilidad de Digest vs. Tag**:
   - Los tags de los contenedores (por ejemplo, `:latest`, `:v1.0.0`) son **punteros mutables**. Un actor malicioso con acceso al registry o un pipeline de CI comprometido puede sobrescribir un tag para apuntar a una imagen maliciosa sin alterar el nombre del tag.
   - Un digest SHA256 es una **dirección de contenido criptográfica inmutable**. Si se modifica un solo byte de la imagen del contenedor, el hash cambia por completo. Realizar un pull por digest garantiza la ejecución del código exacto que fue auditado, escaneado y firmado.

2. **Arquitectura de Firma sin Llaves (Fulcio y Rekor)**:
   - La firma sin llaves (keyless signing) elimina las llaves privadas de larga duración que pueden filtrarse o comprometerse.
   - **Fulcio**: Actúa como una Autoridad de Certificación Efímera (Ephemeral Certificate Authority). Cuando un desarrollador o pipeline de CI firma un artefacto, se autentica mediante OpenID Connect (OIDC). Fulcio emite un certificado X.509 de corta duración vinculado a la identidad OIDC (por ejemplo, la URL del workflow de GitHub Actions o el correo electrónico) válido solo por unos minutos.
   - **Rekor**: Un registro de transparencia inalterable (tamper-evident) de solo anexar (append-only). La firma, el certificado de corta duración y el hash del artefacto se registran en Rekor. La verificación comprueba la entrada del registro de Rekor para probar que la firma se generó durante el marco de tiempo válido del certificado, eliminando la necesidad de gestionar listas de revocación PKI o llaves de larga duración.

</details>

---

## Referencias Oficiales y Estándares

- **LPI Open Source Essentials Overview**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **SPDX Specification v2.3 (ISO/IEC 5962:2021)**: [https://spdx.dev/specifications/](https://spdx.dev/specifications/)
- **OWASP CycloneDX Standard**: [https://cyclonedx.org/docs/](https://cyclonedx.org/docs/)
- **OpenChain Project (ISO/IEC 5230:2020 License Compliance)**: [https://www.openchainproject.org/](https://www.openchainproject.org/)
- **Sigstore / Cosign Documentation**: [https://docs.sigstore.dev/](https://docs.sigstore.dev/)
- **FIRST EPSS Specification**: [https://www.first.org/epss/](https://www.first.org/epss/)