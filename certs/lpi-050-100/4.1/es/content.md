# LPI 050-100 Guía de Estudio | Tema 4.1: Modelos de Negocio de Desarrollo de Software
**Nivel Objetivo:** Principal Platform Architect / Senior SRE  
**Peso del Examen:** 5  
**Dominio:** Open Source Essentials (LPI 050-100)

---

## 1. Motivación y Problema de Arquitectura en Producción

### 1.1 La Cadena de Suministro de Software Empresarial y la Dinámica de Monetización
En la arquitectura moderna de plataformas cloud-native, el software de código abierto (OSS) constituye el sustrato de runtime fundamental, abarcando desde kernels de sistemas operativos (Linux) y orquestadores de contenedores (Kubernetes) hasta motores de bases de datos (PostgreSQL) y stacks de observabilidad (Prometheus). Sin embargo, la economía del desarrollo de software requiere modelos de financiamiento sostenibles. La estrategia elegida por un proyecto o proveedor para monetizar el software influye directamente en:

1. **Acoplamiento Arquitectónico y Riesgo de Lock-in**: Cómo se dividen las funcionalidades entre las ediciones de la comunidad (FLOSS) y los add-ons empresariales (propietarios).
2. **Cumplimiento de Licencias y Exposición Legal**: Implicaciones de Copyleft (GPL, AGPL) vs. Permisivas (Apache 2.0, MIT) vs. Source-Available (BSL/BUSL, SSPL) para imágenes de contenedores empresariales y wrappers de SaaS.
3. **Viabilidad Operativa y Contingencia de Fork**: La probabilidad de eventos repentinos de cambio de licencia (p. ej., de Terraform a OpenTofu bajo BUSL 1.1; de Redis a dual RSALv2/SSPLv1; de Elasticsearch a SSPL).

```
                      +-------------------------------------------------+
                      |     Enterprise Software Supply Chain Intake      |
                      +-------------------------------------------------+
                                               |
                                               v
                      +-------------------------------------------------+
                      |      License & Business Model Classifier        |
                      +-------------------------------------------------+
                               /               |               \
                              /                |                \
                             v                 v                 v
               +-------------------+  +-----------------+  +-------------------+
               | Permissive/FLOSS  |  |   Open Core     |  | Source-Available  |
               | (MIT, Apache 2.0) |  | (Proprietary    |  | (BSL, SSPL, AGPL) |
               |                   |  | Extensions)     |  |                   |
               +-------------------+  +-----------------+  +-------------------+
                         |                     |                     |
                         v                     v                     v
               +-------------------+  +-----------------+  +-------------------+
               | Unrestricted      |  | Audit Features &|  | SRE Isolation &   |
               | Cloud Deployment  |  | Feature Gates   |  | Legal Gatekeeping |
               +-------------------+  +-----------------+  +-------------------+
```

### 1.2 El Desafío de SRE en Producción: Aplicación del Cumplimiento de Licencias a Escala
Los equipos de platform engineering deben inspeccionar automáticamente cada binario, imagen de contenedor y dependencia de terceros que se incorpore a los pipelines de entrega continua (CD). Permitir una licencia incompatible o source-available en una aplicación cloud multitenant puede desencadenar el contagio por copyleft (requiriendo la divulgación de código propietario) o la violación legal de los términos de servicio del proveedor.

Desde un punto de vista arquitectónico, los SREs deben diseñar admission controllers automatizados y escáneres estáticos en tiempo de compilación (build-time) que intercepten el software no conforme antes de que sea programado en los clusters de Kubernetes de producción.

---

## 2. Comparaciones Técnicas y Matriz de Compromisos (Trade-Offs)

### 2.1 Desglose de los Modelos de Negocio de Desarrollo de Software

1. **Modelo Open Core**:
   - *Mecánica*: La lógica central de la aplicación se licencia bajo una licencia permisiva (p. ej., Apache 2.0) o copyleft, mientras que las capacidades empresariales avanzadas (RBAC, SSO, replicación multirregión, registros de auditoría, clustering) se mantienen como código cerrado bajo una licencia propietaria.
   - *Impacto Arquitectónico*: Requiere ejecutar binarios empresariales independientes o cargar plugins/sidecars propietarios junto con el motor central.

2. **Modelo de Licenciamiento Dual (Dual Licensing)**:
   - *Mecánica*: El proveedor publica el software bajo una licencia de copyleft fuerte (p. ej., AGPLv3 o GPLv2) para evitar que competidores comerciales lo embeban en productos propietarios sin liberar su código. Simultáneamente, el proveedor vende licencias comerciales a compradores empresariales que desean mantener su trabajo derivado como propietario.
   - *Impacto Arquitectónico*: Se requieren guardrails legales sólidos en CI/CD para evitar la mezcla de dependencias GPL/AGPL en microservicios propietarios.

3. **Software como Servicio (SaaS) / Servicios Administrados (Managed Services)**:
   - *Mecánica*: El software central permanece como código abierto, pero la entidad comercial aloja, administra, escala y asegura el software como una oferta cloud (p. ej., Managed Grafana, AWS Aurora). La monetización se basa en la eficiencia operativa, los SLAs de tiempo de actividad (uptime) y la abstracción de la infraestructura.
   - *Impacto Arquitectónico*: Los equipos de SRE deben evaluar el "TCO de Código Abierto Self-Hosted" (infraestructura + toil operativo de los ingenieros) frente al "TCO de SaaS Administrado" (egreso de red + costos de suscripción del proveedor).

4. **Modelo de Servicios, Soporte y Suscripción**:
   - *Mecánica*: Base de código puramente de código abierto (100% FLOSS). Los ingresos se generan a través de SLAs empresariales, parches de seguridad, versiones de soporte a largo plazo (LTS), ingeniería de integración personalizada y capacitación de certificación (p. ej., Red Hat Enterprise Linux, SUSE).
   - *Impacto Arquitectónico*: Portabilidad completa de proveedores con cero bloqueo a nivel de código; dependencia de repositorios externos para parches de seguridad empresariales certificados.

5. **Source-Available / Licencia de Fuente de Negocio (BSL/BUSL / SSPL)**:
   - *Mecánica*: Licencias no aprobadas por la OSI diseñadas para bloquear que los proveedores de servicios cloud (CSPs) revendan el software como un servicio administrado sin aportar ingresos. El código se puede visualizar, pero la competencia comercial o el alojamiento están restringidos hasta que una fecha de cambio (change-date, p. ej., 4 años) lo convierte de nuevo a Apache 2.0 / MIT.
   - *Impacto Arquitectónico*: Los SREs deben hacer un seguimiento de las cronologías de la fecha de cambio y auditar los servicios internos de la plataforma cloud para evitar infracciones de marcas registradas o de licencias al alojar plataformas de desarrolladores internas.

### 2.2 Análisis Profundo de Compromisos (Trade-Offs)

| Modelo de Negocio | Motor Principal de Ingresos | Perfil de Licencia | Complejidad Operativa de SRE | Riesgo de Seguridad de la Cadena de Suministro | Riesgo de Lock-in de Licencia |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Open Core** | Funcionalidades add-on propietarias (SSO, Cifrado, Auditoría) | Mixto (Core Apache 2.0 + Comercial Enterprise) | **Medio-Alto**: Requiere gestionar builds upstream independientes y claves de licencia. | **Bajo**: El proveedor gestiona parches de seguridad para builds empresariales. | **Alto**: Las funcionalidades empresariales crean una dependencia estricta con el proveedor. |
| **Dual Licensing** | Ventas de exención comercial a desarrolladores propietarios | Copyleft Fuerte (GPL/AGPL) o Comercial Propietaria | **Bajo**: Build binario unificado. | **Medio**: Requiere rastrear la redistribución interna de código enlazado. | **Medio**: El relicenciamiento de código requiere Acuerdos de Licencia de Contribuidor (CLAs). |
| **SaaS / Hosted** | Facturación de infraestructura basada en uso y SLA de gestión | Permisiva (MIT, Apache 2.0, BSD) | **El más bajo (Managed)** / **Alto (Self-Hosted)** | **Bajo**: El CSP gestiona la administración de parches y guardrails operativos. | **Medio**: Desviación de compatibilidad de API entre proveedores cloud. |
| **Soporte/Suscripción** | Soporte SLA, binarios certificados, backports de seguridad | 100% FLOSS (GPL, Apache 2.0) | **Medio**: Gestión estándar del ciclo de vida del SO/middleware. | **El más bajo**: Fe de erratas de seguridad con respaldo empresarial (remediación de CVE). | **El más bajo**: Libertad absoluta de código; posibilidad de hacer fork si el proveedor se desvía. |
| **Source-Available** | Monetización de protección contra proveedores cloud | No-OSI (BSL 1.1, SSPL, RSALv2) | **Medio**: Se requiere un seguimiento de uso estricto para escenarios de alojamiento. | **Medio**: Dependiente de los pipelines de parches de un único proveedor. | **El más alto**: Riesgo de términos de relicenciamiento restrictivos repentinos. |

---

## 3. Infraestructura de Producción y Manifiestos de Cumplimiento

Para hacer cumplir el modelo de negocio y el cumplimiento de licencias en plataformas cloud-native, los arquitectos despliegan analizadores de Lista de Materiales de Software (SBOM) en tiempo de compilación junto con políticas de admisión en los clusters.

Los manifiestos a continuación ilustran un guardrail completo y de nivel de producción para la cadena de suministro:
1. **Tekton PipelineRun**: Genera un SBOM SPDX usando `syft` y audita licencias usando `trivy` durante la compilación de la imagen del contenedor.
2. **Kyverno ClusterPolicy**: Intercepta la creación de `Pod` en Kubernetes para evitar el despliegue de imágenes de contenedor etiquetadas con licencias restringidas (p. ej., AGPL-3.0, BSL-1.1) o a las que les falten anotaciones de cumplimiento verificadas.

### 3.1 Cumplimiento en Tiempo de Compilación (Build-Time): Tekton PipelineRun (`license-audit-pipeline.yaml`)

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: supply-chain-license-audit-run
  namespace: cicd-pipelines
  labels:
    app.kubernetes.io/name: license-audit
    app.kubernetes.io/part-of: platform-governance
spec:
  pipelineSpec:
    tasks:
      - name: generate-sbom-and-audit-license
        taskSpec:
          steps:
            - name: extract-sbom
              image: anchore/syft:v1.3.0
              script: |
                #!/usr/bin/env sh
                set -euo pipefail
                echo "[+] Scanning container image for dependency SBOM generation..."
                syft registry:quay.io/prometheus/prometheus:v2.51.0 \
                  -o spdx-json=/workspace/sbom.spdx.json \
                  -o table=/workspace/sbom-summary.txt
                echo "[+] SBOM generation complete."
                cat /workspace/sbom-summary.txt
            - name: evaluate-license-compliance
              image: aquasec/trivy:0.50.1
              script: |
                #!/usr/bin/env sh
                set -euo pipefail
                echo "[+] Executing Trivy License Compliance Evaluation..."
                trivy image \
                  --severity HIGH,CRITICAL \
                  --scanners license \
                  --ignored-licenses "MIT,Apache-2.0,BSD-3-Clause,BSD-2-Clause,MPL-2.0" \
                  --exit-code 1 \
                  quay.io/prometheus/prometheus:v2.51.0
                echo "[+] Image passed software license compliance policies."
---
```

### 3.2 Guardrail de Admisión en Tiempo de Ejecución (Runtime): Kyverno ClusterPolicy (`enforce-license-guardrail.yaml`)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-approved-software-licenses
  annotations:
    policies.kyverno.io/title: Enforce Approved Open Source Licenses
    policies.kyverno.io/category: Software Supply Chain Governance
    policies.kyverno.io/severity: High
    policies.kyverno.io/subject: Pod, Container
    description: >-
      Blocks pod deployment if container images contain restricted licenses
      (e.g., AGPL-3.0, SSPL-1.0, BUSL-1.1) or lack verified supply-chain metadata.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: block-restricted-licenses-annotation
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Pod deployment rejected: Container image contains prohibited or non-compliant license terms (AGPL/SSPL/BUSL)."
        pattern:
          metadata:
            annotations:
              compliance.platform.io/license-audit: "APPROVED"
              compliance.platform.io/license-classification: "!AGPL-3.0 & !SSPL-1.0 & !BUSL-1.1"
    - name: require-sbom-attestation
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Pod deployment rejected: Missing mandatory SBOM attestation metadata."
        pattern:
          metadata:
            annotations:
              compliance.platform.io/sbom-spdx-hash: "?*"
```

---

## 4. Comandos de CLI Reales y Salidas Reales de Terminal

### 4.1 Comando CLI 1: Generación de un SBOM de Producción y Auditoría de Licencias con Syft
Los SREs usan `syft` para catalogar todos los paquetes y licencias de software embebidos dentro de una imagen de contenedor de producción.

```bash
$ syft quay.io/keycloak/keycloak:24.0.2 -o json | jq '.artifacts[] | {name: .name, version: .version, licenses: .licenses[].value}' | head -n 30
```

**Salida Real Esperada:**
```json
{
  "name": "microprofile-openapi-api",
  "version": "3.1.1",
  "licenses": "Apache-2.0"
}
{
  "name": "netty-buffer",
  "version": "4.1.108.Final",
  "licenses": "Apache-2.0"
}
{
  "name": "hibernate-core",
  "version": "6.4.4.Final",
  "licenses": "LGPL-2.1-or-later"
}
{
  "name": "jackson-databind",
  "version": "2.16.1",
  "licenses": "Apache-2.0"
}
{
  "name": "quarkus-core",
  "version": "3.8.3",
  "licenses": "Apache-2.0"
}
```

### 4.2 Comando CLI 2: Evaluación de Violaciones de Licencia a través de Trivy
Este comando ejecuta una verificación de licencia estricta contra una imagen objetivo, asegurando un código de salida `1` al descubrir licencias prohibidas o copyleft.

```bash
$ trivy image --scanners license --ignored-licenses "MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause" --exit-code 1 redis:7.2.4-alpine
```

**Salida Real Esperada:**
```text
2026-08-06T19:15:22.412Z	[INFO]	License scanner progress: 100%
2026-08-06T19:15:22.891Z	[INFO]	Number of language-specific files: 1

redis:7.2.4-alpine (alpine 3.19.1)
==================================
Total: 2 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 2, CRITICAL: 0)

┌──────────┬──────────────────┬──────────┬───────────────────┬──────────────────────────────────────────┐
│ Package  │ Classification   │ Severity │ License           │ Resource Path                            │
├──────────┼──────────────────┼──────────┼───────────────────┼──────────────────────────────────────────┤
│ redis    │ Restricted       │ HIGH     │ RSALv2            │ usr/local/bin/redis-server               │
│ redis    │ Restricted       │ HIGH     │ SSPL-1.0          │ usr/local/bin/redis-server               │
└──────────┴──────────────────┴──────────┴───────────────────┴──────────────────────────────────────────┘

Error: exit status 1
```

### 4.3 Comando CLI 3: Prueba de la Aplicación de Políticas de Kyverno en Kubernetes
Verificación del bloqueo en tiempo de ejecución de manifiestos no conformes contra un control plane activo de Kubernetes.

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unverified-redis-workload
  namespace: production
  annotations:
    compliance.platform.io/license-audit: "REJECTED"
    compliance.platform.io/license-classification: "SSPL-1.0"
spec:
  containers:
  - name: redis
    image: redis:7.2.4
EOF
```

**Salida Real Esperada:**
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/production/unverified-redis-workload was blocked due to the following policies:

enforce-approved-software-licenses:
  block-restricted-licenses-annotation: 'Pod deployment rejected: Container image contains prohibited or non-compliant license terms (AGPL/SSPL/BUSL).'
```

---

## 5. Guía de Verificación y Diagnóstico de Fallas

### 5.1 Flujo de Trabajo de Diagnóstico para Fallas de Cumplimiento de Licencias y Modelos de Negocio

```
                          [ Deployment Pipeline Failure ]
                                         |
                                         v
                         +-------------------------------+
                         | Check CI/CD Stage Exit Code   |
                         +-------------------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
             [ Exit Code 1: Trivy ]               [ Admission Blocked ]
                       |                                   |
                       v                                   v
         +---------------------------+       +---------------------------+
         | Inspect Scanner Output    |       | Check Kyverno Event Logs  |
         | Identify Forbidden SPDX   |       | Verify Pod Annotations    |
         +---------------------------+       +---------------------------+
                       |                                   |
                       v                                   v
         +---------------------------+       +---------------------------+
         | Perform Dependency Trace  |       | Audit Registry Signatures |
         | (Transitive vs Direct)    |       | & Cosign Attestations     |
         +---------------------------+       +---------------------------+
                       |                                   |
                       +-----------------+-----------------+
                                         |
                                         v
                         +-------------------------------+
                         | Apply Remediation Decision    |
                         | (Replace/Isolate/Dual License)|
                         +-------------------------------+
```

### 5.2 Fallas Comunes en Producción y Matriz de Solución de Problemas (Troubleshooting) de SRE

#### Escenario de Falla 1: Contagio de Copyleft Transitivo (Fuga de AGPL/GPL)
* **Síntoma**: El pipeline de build falla en el gate de seguridad con `Exit Code 1`. Trivy señala una subdependencia oculta en lo profundo de `node_modules` o `go.mod` (p. ej., `github.com/marten-seemann/qtls-go1-19` licenciada bajo BSD, pero incorporando un módulo auxiliar GPL).
* **Comando de Diagnóstico**:
  ```bash
  $ go mod why -m <dependency_name>
  # For Node.js platforms:
  $ npm ls <package-name>
  ```
* **Remediación**:
  1. Reemplazar la librería upstream con una alternativa con licencia permisiva (p. ej., MIT/Apache 2.0).
  2. Si la dependencia es estrictamente necesaria, aislar el componente en un microservicio separado delimitado por una barrera de red HTTP/gRPC (evitando el contagio legal por enlace dinámico/estático dentro del mismo proceso).

#### Escenario de Falla 2: Cambio Repentino de Licencia Upstream (Cambio a BSL / SSPL)
* **Síntoma**: El escáner de seguridad activa alertas en componentes de infraestructura base después de actualizaciones automáticas de parches (p. ej., al descargar las últimas versiones de imágenes de motores stateful empresariales).
* **Comando de Diagnóstico**:
  ```bash
  $ syft diff registry:myrepo/engine:v1.0.0 registry:myrepo/engine:v2.0.0
  ```
* **Remediación**:
  1. Fijar las imágenes de infraestructura a la última versión permisiva conocida (p. ej., Terraform `1.5.7`, build de Redis `7.2.4` previo al cambio de licencia).
  2. Migrar la infraestructura de plataforma a forks respaldados por la comunidad de la Linux Foundation / CNCF (p. ej., migrar de Terraform a OpenTofu; migrar de Redis a Valkey).

#### Escenario de Falla 3: Clave de Derecho (Entitlement Key) de Licenciamiento Dual Faltante en el Stack Open Core
* **Síntoma**: Los pods de producción entran en crash-loop con `Error: Enterprise Feature Requested (SSO/RBAC) but no valid license key found`.
* **Comando de Diagnóstico**:
  ```bash
  $ kubectl logs -n platform deployment/identity-service --tail=100 | grep -i "license"
  ```
* **Remediación**:
  1. Verificar el `Secret` de Kubernetes que monta la cadena de la clave de derecho (entitlement key) comercial.
  2. Inspeccionar los metadatos de expiración de la clave a través de la herramienta CLI o el endpoint de la API expuesto por el runtime del proveedor.

---

## 6. Referencias

* **LPI Open Source Essentials Overview**:  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
* **Open Source Initiative (OSI) Licenses & Standards**:  
  https://opensource.org/licenses
* **Linux Foundation Software Supply Chain Security & SPDX Specification**:  
  https://spdx.dev/
* **CNCF Software Supply Chain Best Practices**:  
  https://github.com/cncf/tag-security/tree/main/supply-chain-security
* **Kyverno Cluster Policy Manual & Software Compliance**:  
  https://kyverno.io/docs/policies/
* **Anchore Syft SBOM Specification**:  
  https://github.com/anchore/syft
* **Aqua Security Trivy Vulnerability & License Scanner**:  
  https://aquasecurity.github.trivy.dev/

---

### Fin de la Guía de Estudio — LPI 050-100 Tema 4.1