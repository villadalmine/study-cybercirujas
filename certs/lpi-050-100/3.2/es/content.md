# Topic 3.2: Licencias Creative Commons y Gobernanza de Contenido Abierto en Sistemas de Producción

## 1. Motivación en Producción y Planteamiento del Problema Arquitectónico

En los contextos modernos de Platform Engineering y Site Reliability Engineering (SRE), los sistemas de software se extienden más allá de los artefactos binarios compilados y los repositorios de código fuente. Las infraestructuras enterprise cloud-native dependen en gran medida de activos de contenido heterogéneos, incluyendo:

- **Documentación Técnica y Runbooks**: Portales de desarrolladores internos/externos (Backstage, Sphinx, Hugo), registros de decisiones de arquitectura (ADRs), post-mortems y especificaciones OpenAPI/AsyncAPI.
- **Pipelines de Ingeniería de Datos y AI/ML**: Datasets de entrenamiento, embeddings de feature stores, pesos de modelos, esquemas de referencia y datasets de benchmark.
- **Activos de Diseño UI/UX y Medios Estáticos**: Gráficos vectoriales, activos de marca, modelos 3D, activos de audio y plantillas de micro-sitios front-end.
- **Especificaciones Declarativas de Infraestructura**: Helm charts, módulos de Terraform/OpenTofu y definiciones de recursos personalizados (CRDs) de Kubernetes empaquetados con documentación operativa.

### El Modo de Fallo Arquitectónico: Ambigüedad en el Licenciamiento de Software vs. No-Software

Aplicar licencias tradicionales de Open Source Software (OSS) (como MIT, Apache-2.0 o GNU GPLv3) a activos que no son software crea severas fricciones legales y técnicas:

1. **Patentes y Suposiciones de Código Fuente**: Las licencias de software contienen cláusulas que rigen la modificación del código fuente, represalias por patentes y mecanismos de compilación que no se mapean a imágenes estáticas, datasets crudos o archivos markdown de documentación.
2. **Contaminación Comercial y Derivada**: Los pipelines de software que ingieren automáticamente activos externos (ej., extraer un dataset público para un modelo de ML o empaquetar íconos de interfaz de usuario de terceros en un binario SaaS enterprise) corren el riesgo de contaminación de licencia si existen restricciones no comerciales (`NC`) o sin obras derivadas (`ND`).
3. **Violaciones de Gobernanza de Datos y IA**: Ingerir datasets licenciados bajo `CC BY-NC-SA 4.0` en pipelines comerciales de fine-tuning de LLMs puede invalidar legalmente la oferta comercial enterprise descendente y forzar la divulgación de modelos propietarios o modificaciones del dataset.
4. **Fallos en Pipelines de Cumplimiento Automatizados**: Los escáneres modernos de Software Bill of Materials (SBOM) y de la cadena de suministro (ej., Anchore Syft, Trivy, REUSE) marcan identificadores de Software Package Data Exchange (SPDX) faltantes, ambiguos o inválidos, rompiendo los gates de despliegue CI/CD en shift-left.

Las licencias Creative Commons (CC) proporcionan un marco legal estandarizado diseñado específicamente para obras creativas, documentación, datos y medios, desacoplando la gestión de derechos de contenido del licenciamiento de código.

---

## 2. Deep-Dive Técnico y Análisis Comparativo de Trade-offs

### 2.1 Los Cuatro Componentes Fundamentales de Creative Commons

La suite legal de Creative Commons está compuesta por cuatro elementos de licencia modulares:

| Elemento | Abreviatura | Significado Operativo y Legal | Impacto en SRE / Pipeline |
| :--- | :--- | :--- | :--- |
| **Attribution** | **BY** | Requiere que los usuarios descendentes den crédito al creador original, proporcionen un enlace a la licencia e indiquen si se realizaron cambios. | Requiere la preservación automatizada de metadatos (ej., etiquetas SPDX, archivos `NOTICE`, anotaciones OCI). |
| **ShareAlike** | **SA** | Requiere que las modificaciones o contribuciones basadas en la obra licenciada se distribuyan bajo la misma licencia o una compatible. | Disparador de copyleft para contenido. Modificar docs o datasets `CC BY-SA 4.0` fuerza a que los docs/datasets descendentes sean públicos bajo `CC BY-SA 4.0`. |
| **NonCommercial**| **NC** | Restringe el uso del activo únicamente a fines no comerciales. | **BANDERA ROJA CRÍTICA en pipelines SaaS/Cloud enterprise**. Ingerir contenido `NC` en productos comerciales causa un incumplimiento legal. |
| **NoDerivatives** | **ND** | Permite la redistribución comercial y no comercial, siempre que el activo se transmita sin cambios y en su totalidad. | Evita editar, transformar, remezclar o convertir formatos (ej., convertir SVG a PNG o reformatear el JSON de un dataset). |

---

### 2.2 Las Seis Licencias Estándar de Creative Commons + Espectro CC0

La combinación de estos cuatro elementos da como resultado seis licencias CC oficiales, ordenadas aquí de la más permisiva a la más restrictiva, junto con **CC0** (Dedicación al Dominio Público):

```
[ Least Restrictive / Maximum Freedom ]
┌─────────────────────────────────────────────────────────────────────────┐
│ CC0 (Public Domain Dedication - No Rights Reserved)                      │
├─────────────────────────────────────────────────────────────────────────┤
│ CC BY 4.0 (Attribution)                                                 │
├─────────────────────────────────────────────────────────────────────────┤
│ CC BY-SA 4.0 (Attribution-ShareAlike) [Copyleft for Content]            │
├─────────────────────────────────────────────────────────────────────────┤
│ CC BY-NC 4.0 (Attribution-NonCommercial)                                │
├─────────────────────────────────────────────────────────────────────────┤
│ CC BY-NC-SA 4.0 (Attribution-NonCommercial-ShareAlike)                  │
├─────────────────────────────────────────────────────────────────────────┤
│ CC BY-ND 4.0 (Attribution-NoDerivatives)                                │
├─────────────────────────────────────────────────────────────────────────┤
│ CC BY-NC-ND 4.0 (Attribution-NonCommercial-NoDerivatives)               │
└─────────────────────────────────────────────────────────────────────────┘
[ Most Restrictive / Commercial Pipeline Risk ]
```

#### Matriz Comparativa Detallada de Licencias

| Licencia | Identificador de Licencia SPDX | ¿Uso Comercial Permitido? | ¿Modificaciones Permitidas? | ¿Cumplimiento de Copyleft / ShareAlike? | Caso de Uso SRE Recomendado |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **CC0 1.0** | `CC0-1.0` | Sí | Sí | No | Datos de dominio público, configuraciones de referencia, esquemas públicos. |
| **CC BY 4.0** | `CC-BY-4.0` | Sí | Sí | No | Docs técnicos internos/externos, especificaciones públicas de REST API. |
| **CC BY-SA 4.0** | `CC-BY-SA-4.0` | Sí | Sí | **Sí** (Se requiere la misma licencia CC BY-SA) | Wikis comunitarias, documentación de proyectos open-source. |
| **CC BY-NC 4.0** | `CC-BY-NC-4.0` | **No** | Sí | No | Artículos de investigación sin fines de lucro, benchmarks internos no comerciales. |
| **CC BY-NC-SA 4.0** | `CC-BY-NC-SA-4.0` | **No** | Sí | **Sí** (No comercial + ShareAlike) | Materiales educativos destinados a la reutilización no comercial. |
| **CC BY-ND 4.0** | `CC-BY-ND-4.0` | Sí | **No** | No | Logos corporativos oficiales, PDFs inalterables de cumplimiento normativo. |
| **CC BY-NC-ND 4.0** | `CC-BY-NC-ND-4.0` | **No** | **No** | No | Medios promocionales estáticos de marca, whitepapers externos de solo lectura. |

---

### 2.3 Matriz de Licenciamiento de Software vs. Contenido

El uso de licencias Creative Commons para el código fuente de software ejecutable está explícitamente desaconsejado tanto por Creative Commons como por la Free Software Foundation (FSF). La siguiente tabla detalla los trade-offs:

| Métrica Arquitectónica | Licencias de Software (ej., Apache-2.0, MIT, GPL-3.0) | Licencias Creative Commons (ej., CC BY 4.0, CC BY-SA 4.0) |
| :--- | :--- | :--- |
| **Artefacto Objetivo** | Binarios de código fuente, scripts, librerías compiladas, módulos del kernel. | Documentación técnica, activos de diseño, datasets, medios, especificaciones OpenAPI. |
| **Disposiciones de Concesión de Patentes** | Concesiones expresas de patentes incluidas (ej., Apache 2.0 sección 3). | **No se incluyen concesiones de patentes**. Exponer código bajo CC crea vulnerabilidad de patentes. |
| **Disponibilidad del Código Fuente** | Exige el acceso al código fuente compilable (ej., Copyleft de GPL). | Sin concepto de "código fuente" o instrucciones de compilación. |
| **Cláusulas DRM / TPM** | Varía (GPLv3 restringe explícitamente la Anti-Circunvención/Tivoización). | CC 4.0 prohíbe explícitamente medidas tecnológicas de protección (DRM) en copias redistribuidas. |
| **Estandarización SPDX** | Mapeo nativo en manifiestos de dependencias (`package.json`, `Cargo.toml`). | Mapeo nativo en especificaciones de metadatos y documentación (`.reuse/dep5`, anotaciones OCI). |

---

## 3. Manifiestos de Producción y Configuraciones Declarativas

Para garantizar el cumplimiento a través de los flujos de GitOps, los artefactos deben declarar explícitamente sus licencias CC utilizando estándares reconocidos como **SPDX** y la **Especificación REUSE (v3.0)**.

### 3.1 Manifiesto Dep5 de la Especificación REUSE (`.reuse/dep5`)

```yaml
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Cloud-Native Platform Engine
Upstream-Contact: Site Reliability Engineering Team <sre@platform.internal>
Source: https://github.com/enterprise/platform-engine

Files: docs/* architecture/*.png schemas/*.json
Copyright: 2026 Enterprise Cloud Solutions Corp. <legal@platform.internal>
License: CC-BY-4.0

Files: datasets/ml-benchmark/*
Copyright: 2026 Enterprise Data Science Labs <datascience@platform.internal>
License: CC0-1.0

Files: branding/logos/*
Copyright: 2026 Corporate Marketing Team <brand@platform.internal>
License: CC-BY-ND-4.0

Files: src/*.go deploy/helm/* deploy/terraform/*
Copyright: 2026 Enterprise Engineering Team <devs@platform.internal>
License: Apache-2.0
```

---

### 3.2 Manifiesto de Metadatos de Helm Chart (`Chart.yaml`)

```yaml
apiVersion: v2
name: platform-observability-stack
description: Production-grade SRE Observability Stack helm chart and embedded runbooks
type: application
version: 2.14.0
appVersion: 1.28.2
kubeVersion: ">=1.26.0"
keywords:
  - observability
  - prometheus
  - grafana
  - sre
home: https://platform.internal/docs/observability
sources:
  - https://github.com/enterprise/platform-observability-stack
maintainers:
  - name: SRE Core Team
    email: sre-core@platform.internal
    url: https://platform.internal/teams/sre
annotations:
  org.opencontainers.image.licenses: "Apache-2.0 AND CC-BY-4.0"
  org.opencontainers.image.authors: "SRE Platform Team <sre-core@platform.internal>"
  org.opencontainers.image.documentation: "https://platform.internal/docs/observability/runbook.md"
  platform.internal/documentation-license: "CC-BY-4.0"
  platform.internal/code-license: "Apache-2.0"
```

---

### 3.3 Especificación OpenAPI v3.1 con Metadatos de Licencia CC Embebidos (`openapi.yaml`)

```yaml
openapi: 3.1.0
info:
  title: Enterprise Service Mesh Telemetry API
  description: >
    Production control-plane API for querying internal latency metrics, egress 
    traffic, and SRE error budgets. The documentation and schema are licensed under CC-BY-4.0.
  termsOfService: https://platform.internal/legal/terms
  contact:
    name: API Governance Team
    url: https://platform.internal/support
    email: api-governance@platform.internal
  license:
    name: Creative Commons Attribution 4.0 International
    url: https://creativecommons.org/licenses/by/4.0/
    identifier: CC-BY-4.0
  version: 3.4.1
paths:
  /api/v1/healthz:
    get:
      summary: Health check endpoint
      operationId: getHealthStatus
      responses:
        '200':
          description: System operational status
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/HealthStatus'
components:
  schemas:
    HealthStatus:
      type: object
      properties:
        status:
          type: string
          example: "healthy"
        uptime_seconds:
          type: integer
          example: 864000
```

---

### 3.4 ConfigMap de Kubernetes con Encabezado SPDX Inline (`configmap.yaml`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sre-runbook-incident-triage
  namespace: sre-system
  labels:
    app.kubernetes.io/name: incident-triage-guide
    app.kubernetes.io/part-of: platform-operations
  annotations:
    spdx.org/license-identifier: "CC-BY-4.0"
    copyright.holder: "Enterprise Cloud Solutions Corp."
data:
  # SPDX-License-Identifier: CC-BY-4.0
  # Copyright (0) 2026 Enterprise SRE Team <sre@platform.internal>
  triage_guide.md: |
    # Incident Triage Standard Operating Procedure (SOP)
    
    ## 1. Initial Severity Assessment
    - SEV-1: Outage affecting > 5% of active user sessions.
    - SEV-2: Degraded latency (P99 > 2000ms) across core microservices.
    
    ## 2. Escalation Matrix
    Execute the on-call pager sequence via PagerDuty API integration.
```

---

## 4. Workflows de Inspección y Verificación en la CLI de la Terminal

Los SREs deben hacer cumplir el cumplimiento automatizado de licencias durante los pull requests y pipelines de CI/CD.

### 4.1 Validando el Cumplimiento del Repositorio usando `reuse lint`

```bash
$ reuse lint
```

**Expected Terminal Output:**

```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: Apache-2.0, CC-BY-4.0, CC0-1.0, CC-BY-ND-4.0
* Status: OK

Congratulations! Your project is compliant with the REUSE specification version 3.0.
```

---

### 4.2 Escaneando Artefactos de Contenedor OCI para Licencias CC usando `syft` y `jq`

```bash
$ syft quay.io/enterprise/platform-docs-portal:v2.1.0 -o json | jq '.artifacts[] | select(.licenses[]? | contains("CC-BY")) | {name: .name, version: .version, licenses: .licenses}'
```

**Expected Terminal Output:**

```json
{
  "name": "hugo-theme-docdock",
  "version": "1.2.0",
  "licenses": [
    "CC-BY-4.0"
  ]
}
{
  "name": "font-awesome-free",
  "version": "6.4.0",
  "licenses": [
    "OFL-1.1",
    "MIT",
    "CC-BY-4.0"
  ]
}
```

---

### 4.3 License Gate Automatizado en CI/CD usando `trivy`

```bash
$ trivy fs --scanners license --severity HIGH,CRITICAL --exit-code 1 ./
```

**Expected Terminal Output (Clean Pass):**

```text
2026-08-06T19:15:02.124Z	INFO	[license] Scanning target directory...
2026-08-06T19:15:02.842Z	INFO	Number of language-specific files: 4
2026-08-06T19:15:02.843Z	INFO	Detecting vulnerabilities and license violations...

Target: ./
Total: 0 (HIGH: 0, CRITICAL: 0)
```

**Expected Terminal Output (Violation Detected - Non-Commercial Breach):**

```text
2026-08-06T19:16:10.011Z	INFO	[license] Scanning target directory...
2026-08-06T19:16:11.230Z	INFO	License classification complete.

Target: ./datasets/market_trends.json
Total: 1 (HIGH: 1, CRITICAL: 0)

┌──────────────────────────────┬──────────────────┬──────────┬───────────────────┬──────────────────────────────────────────┐
│           PACKAGE            │     LICENSE      │ SEVERITY │   VIOLATION TYPE  │               DESCRIPTION                │
├──────────────────────────────┼──────────────────┼──────────┼───────────────────┼──────────────────────────────────────────┤
│ market_trends.json           │ CC-BY-NC-SA-4.0  │ HIGH     │ Forbidden License │ NonCommercial clause violates commercial │
│                              │                  │          │                   │ SaaS distribution policy                 │
└──────────────────────────────┴──────────────────┴──────────┴───────────────────┴──────────────────────────────────────────┘

Error: License violation detected. Exiting with status code 1.
```

---

### 4.4 Verificando Anotaciones de Metadatos OCI vía `skopeo`

```bash
$ skopeo inspect docker://quay.io/enterprise/platform-docs-portal:v2.1.0 | jq '.Labels["org.opencontainers.image.licenses"]'
```

**Expected Terminal Output:**

```json
"Apache-2.0 AND CC-BY-4.0"
```

---

## 5. Playbook de Diagnóstico y Remediación para SRE

### Escenario 1: Fallos en el Pipeline debido a la Ingestión No Comercial (`NC`)

#### Síntoma:
El pipeline de build de CI/CD se detiene en la etapa `license-check-gate` con el error: `CRITICAL_LICENSE_VIOLATION: CC-BY-NC-4.0 detected in static payload`.

#### Causa Raíz:
Un desarrollador front-end incorporó un dataset de documentación o una plantilla de micro-sitio que contiene una licencia `CC BY-NC 4.0` en una imagen de contenedor SaaS comercial.

#### Protocolo de Remediación:
1. **Aislar el Artefacto**: Identificar la ruta exacta del archivo usando `grep` o `reuse`:
   ```bash
   $ grep -rn "CC-BY-NC" ./
   ```
2. **Determinar la Cadena de Dependencias**: Verificar si el activo es una dependencia externa de NPM/Git o un commit directo de archivos.
3. **Reemplazar o Relicenciar**:
   - *Opción A*: Reemplazar el activo `CC BY-NC 4.0` por una alternativa `CC BY 4.0` o `CC0 1.0`.
   - *Opción B*: Contactar al titular de los derechos de autor para solicitar una excepción explícita de licencia comercial (acuerdo de Doble Licenciamiento).
4. **Purgar el Historial de Git** (si se realizó el commit directamente): Usar `git-filter-repo` para eliminar permanentemente el activo no conforme del historial de versiones para eliminar la responsabilidad legal.
   ```bash
   $ git filter-repo --invert-paths --path-glob 'path/to/nc-asset/*'
   ```

---

### Escenario 2: Ruptura del Pipeline de Derivados bajo `CC BY-ND`

#### Síntoma:
El paso de procesamiento de imágenes o build de activos falla debido a una bandera de legal/cumplimiento al convertir íconos `.svg` licenciados bajo `CC BY-ND 4.0` en sprites dinámicos `.png` o activos CSS escalados.

#### Causa Raíz:
La cláusula `ND` (NoDerivatives) prohíbe distribuir versiones modificadas, conversiones de formato, variantes recortadas u obras compuestas derivadas del activo original.

#### Protocolo de Remediación:
1. **Detener Transformaciones Automatizadas**: Configurar los scripts de build (Webpack, Vite, ImageMagick) para omitir el escalado o la compilación automatizada de archivos etiquetados como `ND`.
2. **Sustitución de Activos**: Sustituir elementos de diseño `CC BY-ND 4.0` con activos permisivos licenciados bajo `CC BY 4.0` o `MIT` (ej., FontAwesome Free, Lucide Icons).
3. **Validar Pipelines**: Actualizar las reglas de build para aislar los activos `ND` como descargas externas estáticas, no comprimidas y no modificadas.

---

### Escenario 3: Propagación de Copyleft vía `CC BY-SA 4.0`

#### Síntoma:
Una auditoría legal marca el repositorio de build de documentación técnica interna. La documentación propietaria interna de la plataforma se mezcló con runbooks comunitarios licenciados bajo `CC BY-SA 4.0`.

#### Causa Raíz:
El elemento `SA` (ShareAlike) impone que cualquier obra derivada (incluyendo sitios de documentación compilados, páginas de wiki o manuales combinados) debe heredar la licencia `CC BY-SA 4.0` en su totalidad, arriesgando la divulgación pública obligatoria de detalles internos de la infraestructura operativa.

#### Protocolo de Remediación:
1. **Desacoplar Repositorios de Documentación**: Separar los runbooks de infraestructura propietaria en un repositorio aislado.
2. **Refactorizar Inclusiones**: No copiar y pegar contenido `CC BY-SA 4.0` directamente en ADRs o runbooks internos. En su lugar, vincular mediante referencias URI.
3. **Auditar la Salida**: Asegurar que los activos publicados del portal de desarrolladores aíslen los componentes `ShareAlike` de la documentación propietaria de la plataforma.

---

## 6. Referencias

- Visión General de Esenciales Open Source de Linux Professional Institute (LPI):  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- Descripciones Oficiales de Licencias y Códigos Legales de Creative Commons:  
  [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
- Preguntas Frecuentes de Creative Commons - Recomendaciones de Licenciamiento de Software:  
  [https://creativecommons.org/faq/#can-i-apply-a-creative-commons-license-to-software](https://creativecommons.org/faq/#can-i-apply-a-creative-commons-license-to-software)
- Lista de Licencias de Software Package Data Exchange (SPDX):  
  [https://spdx.org/licenses/](https://spdx.org/licenses/)
- Especificación REUSE 3.0 de la Free Software Foundation Europe (FSFE):  
  [https://reuse.software/spec/](https://reuse.software/spec/)
- Especificación de Formato de Imagen de la Open Container Initiative (OCI) - Anotaciones:  
  [https://github.com/opencontainers/image-spec/blob/main/annotations.md](https://github.com/opencontainers/image-spec/blob/main/annotations.md)