# LPI 050-100: Tema 2.3 – Licencias de Software Permisivas
**Certificación objetivo:** LPI Open Source Essentials (Examen 050-100)  
**Tema:** 2.3 Licencias de software permisivas  
**Ponderación:** 7.5  
**Audiencia:** Senior Site Reliability Engineers (SREs), Principal Platform Architects y DevSecOps Engineers  

---

## 1. Motivación y problema arquitectónico en producción

En la práctica moderna de ingeniería de plataformas cloud-native y SRE, la selección de componentes de software rara vez está limitada únicamente por el rendimiento en tiempo de ejecución. El marco legal que gobierna el código fuente—específicamente las licencias de código abierto—impacta directamente en la sostenibilidad arquitectónica, la responsabilidad legal empresarial, la automatización del cumplimiento (compliance) y la seguridad de la cadena de suministro (supply chain).

### El problema arquitectónico empresarial
Las plataformas de infraestructura modernas dependen en gran medida de bloques de construcción modulares de código abierto (frameworks de microservicios, runtimes de contenedores, drivers de bases de datos y sidecars de service mesh). Al ensamblar un plano de control (control plane) empresarial o distribuir soluciones de plataforma propietarias, los ingenieros enfrentan tres riesgos legal-arquitectónicos críticos:

1. **Contaminación por licencia viral (Spillover de Copyleft):** Enlazar inadvertidamente módulos propietarios con librerías recíprocas/copyleft (por ejemplo, GNU GPLv3 o AGPLv3) fuerza la obligación legal de publicar el código fuente propietario circundante bajo los mismos términos de licencia.
2. **Deriva de licencias y volatilidad de relicenciamiento (License Drift):** Que los proyectos upstream cambien de licencias permisivas a licencias restrictivas o source-available (por ejemplo, Redis cambiando de BSD 3-Clause a RSALv2/SSPLv1, o Terraform pasando de Apache 2.0 a BSL 1.1) genera fricción operativa, gestión de forks de emergencia y auditorías de compliance a través de los microservicios internos.
3. **Cumplimiento de la cadena de suministro de software y propagación de avisos:** Las licencias permisivas exigen una retención estricta de avisos (avisos de copyright, renuncias de responsabilidad y archivos `NOTICE`). En pipelines de contenedorización automatizados, no preservar estos avisos durante las construcciones de imágenes multi-stage genera vulnerabilidades de incumplimiento durante las auditorías de due diligence de PI (Propiedad Intelectual) empresarial y SBOM (Software Bill of Materials).

```
       +-----------------------------------------------------------------------+
       |                   Enterprise Software Supply Chain                    |
       +-----------------------------------------------------------------------+
                                           |
           +-------------------------------+-------------------------------+
           |                                                               |
           v                                                               v
+----------------------+                                 +----------------------+
|  Permissive Stack    |                                 |   Copyleft Stack     |
| (MIT, BSD, Apache2)  |                                 |    (GPL, AGPL)       |
+----------------------+                                 +----------------------+
           |                                                               |
  [Notice Preservation]                                          [Viral Source Code]
           |                                                     [ Disclosure Req. ]
           v                                                               |
+-----------------------------------------------------------------------+  |
| Proprietary Enterprise Control Plane & Cloud Platform Distros         |<-+
+-----------------------------------------------------------------------+
```

### Valor estratégico de las licencias permisivas
Las licencias de software permisivas (a menudo llamadas licencias "Académicas" o de estilo "BSD") otorgan la máxima libertad operativa a los usuarios downstream. Permiten la explotación comercial, modificación, sublicenciamiento, integración en código cerrado y redistribución sin requerir que las modificaciones downstream se aporten de regreso al dominio público. Para los arquitectos de plataforma que construyen ofertas de PaaS empresariales, las licencias permisivas reducen la barrera de adopción, minimizan la fricción legal y permiten una integración sin complicaciones en productos propietarios.

---

## 2. Mecánica técnica y análisis comparativo

Las licencias permisivas comparten una filosofía central común: **máxima libertad de uso con mínimas condiciones**. Sin embargo, existen matices técnicos clave con respecto a la protección de patentes, derechos de marcas registradas, cláusulas de publicidad y manejo de atribuciones.

### Desglose detallado de las licencias permisivas clave

*   **Licencia MIT (variantes Expat / X11):** El estándar mínimo para licenciamiento permisivo. Otorga derechos para usar, copiar, modificar, fusionar, publicar, distribuir, sublicenciar y vender copias del software. El único requisito es preservar el aviso de copyright original y el bloque de permiso/renuncia de responsabilidad en todas las copias o partes sustanciales. *No* contiene concesiones explícitas de patentes.
*   **BSD de 2 cláusulas (Licencia "Simplificada" o "FreeBSD"):** Elimina las restricciones de publicidad y respaldo de las variantes de BSD más antiguas. Requiere la retención del aviso de copyright, la lista de condiciones y la renuncia de garantía.
*   **BSD de 3 cláusulas (Licencia "Nueva" o "Revisada"):** Agrega una **cláusula explícita de No Respaldo (Non-Endorsement)**: los usuarios downstream no pueden usar los nombres de los autores o colaboradores originales para respaldar o promover productos derivados sin permiso previo por escrito.
*   **BSD de 4 cláusulas (Licencia "Original" o "Antigua"):** Incluye una **cláusula de publicidad** heredada que requiere que todos los materiales publicitarios que mencionen características del software reconozcan al autor original. *Nota crítica para SRE:* El requisito de publicidad de la 4-Clause crea una incompatibilidad directa con la GNU GPL, lo que la vuelve peligrosa en stacks mixtos de código abierto.
*   **Apache License 2.0:** Una licencia permisiva modernizada de nivel corporativo diseñada para ecosistemas de software empresarial (por ejemplo, Kubernetes, Apache HTTPd).
    *   *Concesión explícita de patentes (Sección 3):* Otorga a los usuarios downstream una licencia de patentes perpetua, mundial, no exclusiva, sin cargo y libre de regalías para reclamaciones aplicables a la contribución. Incluye una **cláusula de represalia de patentes**: si un usuario inicia un litigio de patentes contra cualquier entidad alegando que el software infringe una patente, su licencia bajo Apache 2.0 se rescinde automáticamente.
    *   *Propagación del archivo `NOTICE` (Sección 4d):* Si la obra original incluye un archivo de texto `NOTICE`, los redistribuidores downstream deben incluir una copia legible de dicho aviso en su distribución.
    *   *Protección de marcas registradas (Sección 6):* Explícitamente *no* otorga derechos para usar nombres comerciales, marcas registradas o marcas de servicio del Licenciante.
*   **Licencia ISC:** Funcionalmente equivalente a BSD 2-Clause y MIT, pero utiliza un lenguaje simplificado definido por el Internet Systems Consortium.

### Matriz de balance técnico (Trade-Off Matrix)

| Característica de la licencia | MIT | BSD 2-Clause | BSD 3-Clause | BSD 4-Clause | Apache 2.0 | ISC | GPLv3 (Contexto Copyleft) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Uso comercial permitido** | Sí | Sí | Sí | Sí | Sí | Sí | Sí |
| **Sublicenciamiento en código cerrado** | Sí | Sí | Sí | Sí | Sí | Sí | **No** |
| **Retención de avisos requerida** | Sí | Sí | Sí | Sí | Sí | Sí | Sí |
| **Cláusula de no respaldo** | No | No | **Sí** | **Sí** | **Sí** | No | N/A |
| **Reconocimiento en publicidad** | No | No | No | **Sí (Incompatible con GPL)** | No | No | No |
| **Concesión explícita de patentes** | No | No | No | No | **Sí** | No | Sí |
| **Cláusula de represalia de patentes** | No | No | No | No | **Sí** | No | Sí |
| **Archivo `NOTICE` obligatorio** | No | No | No | No | **Sí (Si existe)** | No | No |
| **Alcance recíproco / Copyleft** | Ninguno | Ninguno | Ninguno | Ninguno | Ninguno | Ninguno | **Fuertemente viral** |

---

## 3. Infraestructura de producción y manifiestos CI/CD

Para hacer cumplir las políticas de licencias permisivas a escala, los pipelines de DevSecOps deben escanear continuamente los repositorios de código fuente, las capas de contenedores y los binarios. A continuación se presentan configuraciones completamente funcionales para el escaneo de licencias, la generación de SBOM y la aplicación de admisiones en Kubernetes.

### 3.1 Workflow de GitHub Actions: Auditoría de licencias en la cadena de suministro y generación de SBOM
Este workflow escanea las dependencias de un repositorio, genera un SBOM compatible con SPDX a través de `syft`, verifica el cumplimiento frente a las licencias permisivas permitidas utilizando `trivy`, y hace fallar el pipeline si se detectan licencias no aprobadas (por ejemplo, AGPL-3.0, GPL-3.0) o estados de `NOTICE` no válidos.

```yaml
name: Supply Chain License Compliance Guard

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

jobs:
  license-compliance-audit:
    name: Audit Software Licenses & Generate SBOM
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Install Syft CLI
        run: |
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin v1.3.0
          syft --version

      - name: Install Trivy CLI
        run: |
          wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
          echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list
          sudo apt-get update && sudo apt-get install -y trivy

      - name: Generate SPDX JSON Software Bill of Materials (SBOM)
        run: |
          syft dir:. -o spdx-json=sbom.spdx.json
          ls -lh sbom.spdx.json

      - name: Audit Licenses via Trivy Policy Engine
        run: |
          cat << 'EOF' > trivy-license-config.yaml
          license:
            severities:
              - UNKNOWN
              - HIGH
              - CRITICAL
            ignored:
              - MIT
              - Apache-2.0
              - BSD-2-Clause
              - BSD-3-Clause
              - ISC
            forbidden:
              - GPL-1.0
              - GPL-2.0
              - GPL-3.0
              - AGPL-1.0
              - AGPL-3.0
              - LGPL-2.1
              - LGPL-3.0
              - SSPL-1.0
              - BUSL-1.1
          EOF
          trivy sbom --config trivy-license-config.yaml sbom.spdx.json

      - name: Upload SPDX SBOM Artifact
        uses: actions/upload-artifact@v4
        with:
          name: sbom-spdx-json
          path: sbom.spdx.json
```

---

### 3.2 Restricción de OPA Gatekeeper: Aplicación de metadatos de licencias permisivas en imágenes de contenedor
Esta `ConstraintTemplate` y `Constraint` de Open Policy Agent (OPA) Gatekeeper bloquean los recursos `Deployment` de Kubernetes si las anotaciones de la imagen del contenedor declaran licencias de software no conformes.

```yaml
apiVersion: templates.gatekeeper.sh/v1beta1
kind: ConstraintTemplate
metadata:
  name: k8spermissivelicensepolicy
spec:
  crd:
    spec:
      names:
        kind: K8sPermissiveLicensePolicy
      validation:
        openAPIV3Schema:
          type: object
          properties:
            allowedLicenses:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8spermissivelicensepolicy

        violation[{"msg": msg}] {
          provided_license := input.review.object.metadata.annotations["org.opencontainers.image.licenses"]
          allowed_licenses := input.parameters.allowedLicenses
          not license_is_allowed(provided_license, allowed_licenses)
          msg := sprintf("Deployment blocked: Image license '%v' is not in approved permissive license list %v", [provided_license, allowed_licenses])
        }

        license_is_allowed(target, allowed_list) {
          target == allowed_list[_]
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sPermissiveLicensePolicy
metadata:
  name: enforce-permissive-licenses-only
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
  parameters:
    allowedLicenses:
      - "MIT"
      - "Apache-2.0"
      - "BSD-2-Clause"
      - "BSD-3-Clause"
      - "ISC"
```

---

## 4. Comandos CLI reales y salidas de terminal ($)

Las siguientes sesiones de terminal del mundo real demuestran cómo los SREs verifican, extraen y solucionan problemas de licencias de software en sistemas de producción modernos.

### Escenario A: Extracción y análisis de licencias en un binario de Go en producción
Utilizando `go-licenses` para analizar las dependencias compiladas en un microservicio cloud-native.

```bash
$ go install github.com/google/go-licenses@latest
$ go-licenses csv github.com/prometheus/prometheus/cmd/prometheus
```

**Salida de terminal esperada:**
```text
github.com/prometheus/prometheus/cmd/prometheus,https://github.com/prometheus/prometheus/blob/main/LICENSE,Apache-2.0
github.com/beorn7/perks/quantile,https://github.com/beorn7/perks/blob/master/LICENSE,MIT
github.com/cespare/xxhash/v2,https://github.com/cespare/xxhash/blob/master/LICENSE,MIT
github.com/prometheus/client_golang/prometheus,https://github.com/prometheus/client_golang/blob/main/LICENSE,Apache-2.0
github.com/prometheus/client_model/go,https://github.com/prometheus/client_model/blob/main/LICENSE,Apache-2.0
golang.org/x/sys/unix,https://github.com/golang/sys/blob/master/LICENSE,BSD-3-Clause
gopkg.in/yaml.v2,https://github.com/go-yaml/yaml/blob/v2/LICENSE,Apache-2.0
```

---

### Escenario B: Inspección del cumplimiento de licencias en imágenes de contenedor con `syft` y `jq`
Analizando una imagen de contenedor OCI empresarial empaquetada para confirmar que todos los paquetes de SO y aplicaciones de terceros utilicen licencias permisivas aceptadas.

```bash
$ syft alpine:3.19 -o json | jq '.artifacts[] | {name: .name, version: .version, licenses: .licenses[].value}' | head -n 25
```

**Salida de terminal esperada:**
```json
{
  "name": "alpine-baselayout",
  "version": "3.4.3-r2",
  "licenses": "GPL-2.0-only"
}
{
  "name": "alpine-baselayout-data",
  "version": "3.4.3-r2",
  "licenses": "GPL-2.0-only"
}
{
  "name": "apk-tools",
  "version": "2.14.0-r5",
  "licenses": "GPL-2.0-only"
}
{
  "name": "busybox",
  "version": "1.36.1-r15",
  "licenses": "GPL-2.0-only"
}
{
  "name": "ca-certificates-bundle",
  "version": "20230506-r0",
  "licenses": "MPL-2.0"
}
{
  "name": "musl",
  "version": "1.2.4-r2",
  "licenses": "MIT"
}
```

---

### Escenario C: Validación programática de avisos de licencias en microservicios Node.js
Verificando `node_modules` para el cumplimiento con los requisitos de aviso de MIT/BSD/Apache-2.0 antes de construir imágenes de contenedor.

```bash
$ npx license-checker --summary
```

**Salida de terminal esperada:**
```text
├─ MIT: 482
├─ Apache-2.0: 114
├─ BSD-3-Clause: 31
├─ BSD-2-Clause: 12
├─ ISC: 9
└─ CC0-1.0: 2
```

Para generar el texto explícito del aviso legal `NOTICE` para las atribuciones de Apache 2.0 / BSD:

```bash
$ npx license-checker --production --out ./THIRD_PARTY_NOTICES.txt
$ head -n 20 ./THIRD_PARTY_NOTICES.txt
```

**Salida de terminal esperada:**
```text
└── express@4.18.2
    ├─ licenses: MIT
    ├─ repository: https://github.com/expressjs/express
    ├─ publisher: TJ Holowaychuk
    └─ licenseFile: /app/node_modules/express/LICENSE

└── body-parser@1.20.1
    ├─ licenses: MIT
    ├─ repository: https://github.com/expressjs/body-parser
    ├─ publisher: Douglas Christopher Wilson
    └─ licenseFile: /app/node_modules/body-parser/LICENSE
```

---

## 5. Guía de verificación, diagnóstico y resolución de fallas

Al gestionar licencias permisivas dentro de plataformas empresariales, los SREs enfrentan modos de falla específicos durante las fases de entrega de software y construcción.

### Flujo de trabajo de diagnóstico 1: Remediación de licencias incompatibles BSD de 4 cláusulas

#### Síntoma / Falla
Un componente de la plataforma empaqueta una librería de Go o un módulo de C bajo la licencia **BSD 4-Clause** (Original BSD) junto con un componente recíproco bajo **GPLv2**. El pipeline de CI/CD señala un conflicto legal en la compilación.

#### Análisis de causa raíz
La licencia BSD 4-Clause contiene la "cláusula de publicidad":
> *"All advertising materials mentioning features or use of this software must display the following acknowledgement: This product includes software developed by the organization."*

La Sección 6 de GPLv2 prohíbe explícitamente agregar "restricciones adicionales" a los usuarios downstream. Dado que la cláusula de publicidad impone una condición que no está presente en GPLv2, las dos licencias son **legalmente incompatibles**. No se pueden combinar en un único binario ejecutable.

#### Protocolo de remediación
1. Identificar la dependencia conflictiva bajo BSD 4-Clause utilizando `syft` o `trivy`:
   ```bash
   $ syft dir:. -o json | jq '.artifacts[] | select(.licenses[].value == "BSD-4-Clause")'
   ```
2. Verificar si upstream ha publicado una versión relicenciada bajo **BSD 3-Clause** o **MIT** (precedente histórico: la Universidad de California rescindió la cláusula de publicidad en 1999, creando BSD 3-Clause).
3. Si no existe una versión actualizada, refactorizar la arquitectura del código hacia una ejecución dinámica de procesos (límite IPC/gRPC) en lugar de un enlace estático en el binario, aislando el componente GPL del componente BSD 4-Clause.

---

### Flujo de trabajo de diagnóstico 2: Propagación faltante del archivo `NOTICE` de Apache 2.0

#### Síntoma / Falla
Durante una auditoría de seguridad de PI, el asesor legal downstream reporta un incumplimiento en una imagen de contenedor empresarial que contiene componentes Apache 2.0.

#### Análisis de causa raíz
La Sección 4d de la Licencia Apache 2.0 establece:
> *"If the Work includes a 'NOTICE' text file as part of its distribution, then any Derivative Works that You distribute must include a readable copy of such NOTICE file..."*

Las definiciones de `Dockerfile` multi-stage frecuentemente copian solo los binarios finales resultantes mientras descartan el espacio de trabajo de código fuente y los archivos `NOTICE` o `LICENSE` asociados, rompiendo la cadena legal de atribución.

#### Patrón de Dockerfile incorrecto:
```dockerfile
# BAD: Discards legal NOTICE and LICENSE files
FROM golang:1.22 AS builder
WORKDIR /app
COPY . .
RUN go build -o platform-api .

FROM gcr.io/distroless/static-debian12
COPY --from=builder /app/platform-api /platform-api
ENTRYPOINT ["/platform-api"]
```

#### Patrón de Dockerfile de producción remediado:
```dockerfile
# GOOD: Preserves Apache 2.0 NOTICE and LICENSE files in final image layer
FROM golang:1.22 AS builder
WORKDIR /app
COPY . .
RUN go build -o platform-api .

FROM gcr.io/distroless/static-debian12
WORKDIR /licenses
# Extract and preserve all upstream licenses & NOTICE files
COPY --from=builder /app/LICENSE /licenses/LICENSE
COPY --from=builder /app/NOTICE* /licenses/
COPY --from=builder /app/platform-api /usr/local/bin/platform-api

ENTRYPOINT ["/usr/local/bin/platform-api"]
```

---

### Flujo de trabajo de diagnóstico 3: Detección de trampas inadvertidas de doble licenciamiento o relicenciamiento

#### Síntoma / Falla
El despliegue de una plataforma falla tras obtener una actualización de versión menor de una dependencia (por ejemplo, un cliente de base de datos o una utilidad de plataforma) que cambió su licencia de Apache 2.0 / BSD a BSL 1.1 o SSPL 1.0.

#### Análisis de causa raíz
Los proveedores upstream pueden actualizar repositorios hacia licencias no permisivas o source-available manteniendo los mismos nombres de paquetes. Las herramientas de construcción sin lockfiles estrictos o escaneo de licencias descargan a ciegas el código relicenciado en pipelines de producción propietarios.

#### Protocolo de remediación
1. Implementar el congelamiento de lockfiles (`package-lock.json`, `go.sum`, `Cargo.lock`).
2. Agregar pasos automatizados de verificación de licencias previos al envío (pre-submit) en CI utilizando `trivy` o `licensefinder`.
3. Configurar un pipeline de alertas para rastrear cambios en los metadatos de licencias upstream utilizando identificadores SPDX:

```bash
# Automated bash check to verify no non-permissive license entered git diff
$ git diff HEAD~1 HEAD -- **/package.json | grep '"license":' | grep -vE '(MIT|Apache-2.0|BSD-2-Clause|BSD-3-Clause|ISC)' && exit 1 || echo "License check passed."
```

---

## 6. Referencias

*   **Linux Professional Institute (LPI) Open Source Essentials:**  
    [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
*   **Open Source Initiative (OSI) - The MIT License:**  
    [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)
*   **Open Source Initiative (OSI) - The 2-Clause BSD License:**  
    [https://opensource.org/licenses/BSD-2-Clause](https://opensource.org/licenses/BSD-2-Clause)
*   **Open Source Initiative (OSI) - The 3-Clause BSD License:**  
    [https://opensource.org/licenses/BSD-3-Clause](https://opensource.org/licenses/BSD-3-Clause)
*   **Apache Software Foundation - Apache License, Version 2.0:**  
    [https://www.apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)
*   **SPDX License List & Specification:**  
    [https://spdx.org/licenses/](https://spdx.org/licenses/)
*   **CNCF Software Supply Chain Best Practices:**  
    [https://github.com/cncf/tag-security/tree/main/supply-chain-security](https://github.com/cncf/tag-security/tree/main/supply-chain-security)