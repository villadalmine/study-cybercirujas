# LPI Open Source Essentials (Exam 050-100) — Tema 2.2: Licencias de Software Copyleft

**Audiencia Objetivo:** Principal Platform Architects, Senior SREs, DevSecOps Engineers y Cloud-Native Security Practitioners  
**Peso del Examen:** 7.5  
**Enfoque del Dominio:** Gobernanza de Licenciamiento Open Source, Mecánica del Copyleft, Seguridad de la Cadena de Suministro de Software y Cumplimiento de Arquitectura Empresarial  

---

## 1. Motivación y Problema de Arquitectura en Producción

### 1.1 El Dilema de la Cadena de Suministro de Software Empresarial
En la ingeniería de plataformas cloud-native moderna, más del 80% del codebase de una aplicación contenedorizada consiste en dependencias transitivas de software de código abierto (OSS), librerías de runtime, sidecars y paquetes de imágenes base del sistema operativo. Aunque la adopción de open-source acelera la velocidad de entrega, introduce obligaciones legales vinculantes gobernadas por licencias de software.

Las licencias de software operan bajo las leyes de derecho de autor (copyright). Cuando el software se distribuye o se pone a disposición a través de una red, el receptor obtiene derechos específicos (usar, modificar, redistribuir) supeditados al cumplimiento de los términos de la licencia. El incumplimiento da lugar a una infracción de copyright, exponiendo a las empresas a responsabilidad legal, órdenes judiciales para detener la distribución del producto, divulgación obligatoria del código fuente y severos daños financieros.

```
+-----------------------------------------------------------------------------------+
|                            ENTERPRISE APP DEPLOYMENT                              |
+-----------------------------------------------------------------------------------+
|  +--------------------------+  +----------------------+  +---------------------+  |
|  | Proprietary Core Logic   |  | Permissive Libs      |  | Weak Copyleft Libs  |  |
|  | (Closed Source / IP)     |  | (MIT, Apache-2.0)    |  | (LGPLv3, MPL-2.0)   |  |
|  +-------------+------------+  +----------+-----------+  +----------+----------+  |
|                |                          |                         |             |
|                +--------------------------+-------------------------+             |
|                                           |                                       |
|                                           v                                       |
|                  +-------------------------------------------------+              |
|                  | LINKING / IPC / IN-PROCESS COMPILATION          |              |
|                  +------------------------+------------------------+              |
|                                           |                                       |
|                                           v                                       |
|                  +-------------------------------------------------+              |
|                  |  CRITICAL INFECTION RISK (Strong / Network)     |              |
|                  |  - GPL-3.0-or-later (Static / Dynamic Link)     |              |
|                  |  - AGPL-3.0-only   (Network Access Trigger)   |              |
|                  +------------------------+------------------------+              |
+-------------------------------------------|---------------------------------------+
                                            v
               +--------------------------------------------------------+
               | IMPLICATION: Legal requirement to release entire core   |
               | business logic under copyleft license or face lawsuit. |
               +--------------------------------------------------------+
```

### 1.2 Mecánica del Copyleft y el Motor de "Reciprocidad"
Copyleft es un mecanismo legal que utiliza las leyes de copyright para mantener el software libre y abierto. A diferencia de las licencias *permisivas* (que permiten a los usuarios aguas abajo volver a licenciar el código modificado bajo términos cerrados/propietarios), las licencias *copyleft* exigen que cualquier obra derivada o versión modificada que se distribuya a terceros deba ser publicada bajo la **misma licencia copyleft**.

Los mecanismos técnicos clave incluyen:
*   **Reciprocidad (La Cláusula "Viral"):** Si el Componente $A$ (Copyleft) se empaqueta o combina con el Componente $B$ (Propietario) de manera que $A+B$ forme una única obra derivada, la totalidad de la obra combinada ($A+B$) debe ser publicada bajo la licencia del Componente $A$ al momento de su distribución.
*   **Disparador de Redistribución del Código Fuente (Source Code Redistribution Trigger):** A los usuarios aguas abajo se les debe proporcionar el código fuente completo y correspondiente, incluyendo scripts de build, flags de configuración e instrucciones de instalación.
*   **Vacío Legal Anti-SaaS (Network Copyleft):** El copyleft estándar (GPL) activa las obligaciones de cumplimiento tras la *distribución* (binarios enviados a un cliente). Las plataformas cloud-native que operan como Software-as-a-Service (SaaS) no "distribuyen" binarios; la ejecución ocurre en la infraestructura cloud. El Copyleft de Red (Network Copyleft: AGPL/SSPL) redefine el disparador para incluir la interacción a través de una red informática.

### 1.3 Impacto Arquitectónico en SRE e Ingeniería de Plataformas
Los equipos de plataforma que construyen plataformas internas para desarrolladores (IDPs), mallas de microservicios y pipelines de CI/CD deben aplicar gates de gobernanza automatizados. Un `npm install`, `go get` o la inclusión de una imagen base de contenedor no evaluados que contengan una licencia de Copyleft Fuerte o de Red (Strong o Network Copyleft) pueden comprometer la propiedad intelectual (IP) propietaria de la empresa.

Preocupaciones clave de SRE:
1.  **Linking Estático vs. Dinámico (Static vs. Dynamic Linking):** El linking estático combina código máquina en un solo binario ejecutable, creando inequívocamente una obra derivada bajo GPL. El linking dinámico (`.so`, `.dll`) vincula librerías compartidas en tiempo de ejecución; GPL estándar considera los binarios vinculados dinámicamente como obras derivadas, mientras que LGPL permite explícitamente el linking dinámico con código propietario.
2.  **Límites de Proceso vs. Memoria Compartida (Process Boundaries vs. Shared Memory):** Los microservicios que se comunican mediante RPCs de red (gRPC, REST, JSON-HTTP) a través de sockets de red están generalmente aislados de la reciprocidad del GPL estándar. Sin embargo, compartir estructuras de datos en memoria, sockets de dominio UNIX IPC con acoplamiento estrecho o segmentos de memoria compartida puede desencadenar argumentos legales de obras derivadas.
3.  **Tivoización y Bloqueo de Hardware (Tivoization & Hardware Lock-In):** GPLv3 prohíbe específicamente la "Tivoización": distribuir software copyleft en dispositivos de hardware que restringen a los usuarios la ejecución de versiones modificadas del software mediante verificación de firmas criptográficas.

---

## 2. Comparación Técnica y Matriz de Compromisos (Trade-off Matrix)

La siguiente matriz contrasta las categorías de licenciamiento open-source a través de dimensiones técnicas clave:

| Familia de Licencia | Licencias de Ejemplo | Disparador de Obra Derivada | Alcance de Liberación de Código Fuente | Cláusula de Derechos de Patente | Protección contra Tivoización | Disparador de Red SaaS / Cloud | Nivel de Riesgo SRE Empresarial |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Strong Copyleft** | GPL-2.0-only, GPL-3.0-or-later | Linking estático y dinámico, compilación in-process | Programa completo + herramientas de build + scripts | Explícita en v3; implícita/no clara en v2 | Protegido en v3 (Sección 6); Ninguna en v2 | **No** (Requiere distribución de binarios) | **CRÍTICO** para código propietario interno |
| **Weak Copyleft** | LGPL-2.1-only, LGPL-3.0-only, MPL-2.0 | Modificación a nivel de archivo (MPL); Linking estático sin mecanismo de relinking (LGPL) | Archivos de librería modificados / Archivos objeto para relinking | Explícita en LGPLv3 / MPL-2.0 | Protegido en LGPLv3 | **No** | **MEDIO** (Requiere higiene de linking dinámico) |
| **Network Copyleft** | AGPL-3.0-only, EUPL-1.2 | Acceso a red, llamadas a API, interacción remota | Aplicación completa + modificaciones de servicios de red | Explícita | Protegido | **SÍ** (La interacción a través de la red dispara la liberación) | **MÁXIMO** para SaaS y plataformas alojadas |
| **Permissive** | MIT, Apache-2.0, BSD-3-Clause | Sublicenciamiento permitido; sin requisito recíproco de copyleft | Ninguno requerido (Solo retención del aviso) | Concesión explícita de patentes en Apache-2.0 | Ninguna | **No** | **BAJO** (Seguro para adopción empresarial) |
| **Source Available** *(Non-OSI)* | SSPL-1.0, BSL-1.1 | Proveer el software como un servicio comercial administrado en la nube | Stack completo de infraestructura de gestión (SSPL) | Varía según el proveedor | N/A | **SÍ** (Restricción estricta de hosting comercial) | **ALTO / PROPIETARIO** (Riesgo de vendor lock-in) |

---

## 3. Infraestructura de Producción y Manifiestos de Políticas

Para proteger las plataformas de producción contra la exposición no autorizada al copyleft, los equipos de plataforma despliegan la aplicación automatizada de políticas utilizando Open Policy Agent (OPA) Gatekeeper, Kyverno y trabajos de escaneo de SBOM de imágenes de contenedores dentro de Kubernetes.

### 3.1 Política de OPA Gatekeeper: Restringir Imágenes que Contengan Paquetes AGPL/GPL

Los siguientes `ConstraintTemplate` y `Constraint` de Kubernetes, completos y sintácticamente válidos, inspeccionan las anotaciones de deployment que contienen metadatos SPDX del Software Bill of Materials (SBOM) y deniegan pods que contengan licencias copyleft prohibidas (`AGPL-3.0-only`, `GPL-3.0-or-later`).

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sdisallowcopyleftlicenses
  annotations:
    description: >-
      Enforces software supply chain license compliance by blocking container images
      annotated with restricted Copyleft (GPL/AGPL) SPDX license identifiers.
spec:
  crd:
    spec:
      names:
        kind: K8sDisallowCopyleftLicenses
      validation:
        openAPIV3Schema:
          type: object
          properties:
            bannedLicenses:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sdisallowcopyleftlicenses

        violation[{"msg": msg}] {
          container := input.review.object.spec.template.spec.containers[_]
          sbom_license := input.review.object.metadata.annotations[sprintf("sbom.spdx.org/license-%s", [container.name])]
          banned := input.parameters.bannedLicenses[_]
          contains(lower(sbom_license), lower(banned))
          msg := sprintf("CONTAINER REJECTED: Container '%s' in Pod '%s' uses restricted Copyleft license '%s' (Banned policy match: '%s')", [container.name, input.review.object.metadata.name, sbom_license, banned])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.template.spec.containers[_]
          not input.review.object.metadata.annotations[sprintf("sbom.spdx.org/license-%s", [container.name])]
          msg := sprintf("CONTAINER REJECTED: Container '%s' in Pod '%s' lacks mandatory SPDX license annotation 'sbom.spdx.org/license-%s'", [container.name, input.review.object.metadata.name, container.name])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDisallowCopyleftLicenses
metadata:
  name: enforce-no-agpl-gpl-in-prod
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
    namespaces:
      - "production"
      - "payments-service"
  parameters:
    bannedLicenses:
      - "AGPL-3.0-only"
      - "AGPL-3.0-or-later"
      - "GPL-3.0-only"
      - "GPL-3.0-or-later"
      - "SSPL-1.0"
```

### 3.2 ClusterPolicy de Kyverno: Verificar SBOM de Imagen y Aplicar Atestación de Licencias

Esta `ClusterPolicy` de Kyverno valida que las imágenes desplegadas en producción hayan pasado la verificación de cumplimiento de licencias a través de atestaciones firmadas por Cosign/In-Toto.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: audit-and-enforce-license-compliance
  annotations:
    policies.kyverno.io/title: Enforce Signed License Attestation
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, ImageAttestation
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-license-attestation
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaces:
              - production
      verifyImages:
        - imageReferences:
            - "cr.enterprise.internal/apps/*"
          key: |
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N1a/j5+6z1j/QnJ6eY6N+wV7vM9
            5gL4W1pDkFzX0bQ4fH9Y8uKz3Z9xW7vM95gL4W1pDkFzX0bQ4fH9Y8uKz3Z==
            -----END PUBLIC KEY-----
          attestations:
            - predicateType: https://spdx.dev/Document
              attestors:
                - entries:
                    - keys:
                        publicKeys: |
                          -----BEGIN PUBLIC KEY-----
                          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N1a/j5+6z1j/QnJ6eY6N+wV7vM9
                          5gL4W1pDkFzX0bQ4fH9Y8uKz3Z9xW7vM95gL4W1pDkFzX0bQ4fH9Y8uKz3Z==
                          -----END PUBLIC KEY-----
              conditions:
                - all:
                    - key: "{{ request.object.spec.containers[*].image }}"
                      operator: Defined
```

### 3.3 Job Automatizado de CI/CD en Kubernetes para Escaneo de SBOM y Licencias

Este `Job` de Kubernetes completo y de nivel de producción ejecuta Anchore Syft y Trivy dentro de un runner del pipeline de CI para generar un informe JSON SPDX 2.3, evaluarlo contra las políticas de licencias y emitir métricas de cumplimiento.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: license-compliance-audit-job
  namespace: cicd-runners
spec:
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: license-auditor
    spec:
      restartPolicy: Never
      containers:
        - name: sbom-generator-syft
          image: docker.io/anchore/syft:v1.3.0
          command:
            - "/syft"
          args:
            - "packages"
            - "registry.internal.net/payment/processor:v3.1.0"
            - "-o"
            - "spdx-json=/workspace/sbom.spdx.json"
          volumeMounts:
            - name: shared-workspace
              mountPath: /workspace
            - name: docker-config
              mountPath: /root/.docker/config.json
              subPath: config.json

        - name: license-policy-checker
          image: aquasec/trivy:0.50.1
          command:
            - "trivy"
          args:
            - "sbom"
            - "/workspace/sbom.spdx.json"
            - "--scanners"
            - "license"
            - "--severity"
            - "HIGH,CRITICAL"
            - "--exit-code"
            - "1"
            - "--ignored-licenses"
            - "MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,MPL-2.0,LGPL-3.0-only"
          volumeMounts:
            - name: shared-workspace
              mountPath: /workspace

      volumes:
        - name: shared-workspace
          emptyDir: {}
        - name: docker-config
          secret:
            secretName: internal-registry-creds
```

---

## 4. Comandos CLI del Mundo Real y Salidas de Terminal ($)

Comandos prácticos para platform architects y SREs para inspeccionar binarios, repositorios e imágenes de contenedores para el cumplimiento de licencias.

### 4.1 Generación de SBOM SPDX 2.3 con Syft
Generar un Software Bill of Materials (SBOM) completo en formato SPDX para una imagen de contenedor de producción:

```bash
$ syft registry.internal.net/finance/billing-service:v1.4.2 -o spdx-json=billing-sbom.spdx.json
```

**Expected Output:**
```
[0000]  INFO Parsing image "registry.internal.net/finance/billing-service:v1.4.2"
[0002]  INFO Cataloging packages 
[0004]  INFO PyPI: 42 packages discovered
[0005]  INFO Go Module: 128 packages discovered
[0006]  INFO dpkg: 112 packages discovered
[0007]  INFO Finalizing SBOM report...
 ✔ Cataloged packages      [282 packages]
 ✔ Created SPDX JSON document -> billing-sbom.spdx.json
```

### 4.2 Consulta de Metadatos de Licencias mediante Filtro `jq`
Extraer todos los paquetes identificados con licencias GPL o AGPL del documento SPDX:

```bash
$ jq '.packages[] | select(.licenseConcluded | test("GPL|AGPL")) | {name: .name, versionInfo: .versionInfo, licenseConcluded: .licenseConcluded}' billing-sbom.spdx.json
```

**Expected Output:**
```json
{
  "name": "github.com/mewmew/goplugin",
  "versionInfo": "v1.2.0",
  "licenseConcluded": "GPL-3.0-only"
}
{
  "name": "github.com/db-driver/agpl-connector",
  "versionInfo": "v0.9.4",
  "licenseConcluded": "AGPL-3.0-or-later"
}
```

### 4.3 Aplicación de Políticas de Licencias con Trivy CLI
Ejecutar un escaneo automatizado de cumplimiento de licencias en una imagen de contenedor OCI con un código de salida distinto de cero en caso de violación:

```bash
$ trivy image --scanners license --license-full --severity CRITICAL --exit-code 1 registry.internal.net/finance/billing-service:v1.4.2
```

**Expected Output (Violation Detected):**
```
2026-08-06T19:12:04.112Z	INFO	License scanning enabled
2026-08-06T19:12:05.421Z	INFO	Detected OS: alpine 3.19.1
2026-08-06T19:12:06.890Z	INFO	Number of language-specific files: 2

billing-service:v1.4.2 (gobinary)
==================================
Total: 2 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 2)

CRITICAL: AGPL-3.0-only
────────────────────────────────────────────────────────────────────────────────
PkgName: github.com/db-driver/agpl-connector
Category: Network Copyleft
Classification: Restricted for Commercial Hosted SaaS
File: /usr/local/bin/billing-service

CRITICAL: GPL-3.0-only
────────────────────────────────────────────────────────────────────────────────
PkgName: github.com/mewmew/goplugin
Category: Strong Copyleft
Classification: Forbidden in Proprietary Compiled Executable
File: /usr/local/bin/billing-service

Error: License compliance check failed. Exited with code 1.
```

### 4.4 Verificación de Cumplimiento de Licencias Go en Repositorio Usando `golicense`
Ejecutar `golicense` contra un binario de Go compilado para verificar las licencias de los módulos compilados en él:

```bash
$ golicense -config .license-policy.hcl ./bin/payment-gateway
```

**Content of `.license-policy.hcl`:**
```hcl
allow = [
  "MIT",
  "Apache-2.0",
  "BSD-3-Clause",
  "MPL-2.0"
]

deny = [
  "GPL-2.0-only",
  "GPL-3.0-only",
  "AGPL-3.0-only"
]
```

**Expected Output:**
```
Loading binary...
Analyzing dependency graph (142 modules)...

[FAIL] Forbidden license detected!
  Module: github.com/gorilla/gpl-component
  License: GPL-2.0-only
  Path: main -> github.com/enterprise/core -> github.com/gorilla/gpl-component

Summary: 141 Allowed, 1 Denied, 0 Unspecified.
Process terminated with status code 1.
```

---

## 5. Guía de Verificación y Resolución de Problemas (Troubleshooting) Diagnóstico

Cuando falla un build o una auditoría legal señala una violación de licencia copyleft en producción, los SREs de plataforma deben seguir un flujo de trabajo de diagnóstico y remediación sistemático.

```
+-----------------------------------------------------------------------------------+
|                        COPYLEFT VIOLATION DIAGNOSTIC FLOW                         |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [ CI/CD Gate / Security Alert ] --> Copyleft Violation Detected                  |
|                                            |                                      |
|                                            v                                      |
|  [ STEP 1: Identification ] --------> Trace Package via Dependency Tree           |
|                                       (e.g., `go mod why`, `npm ls`)              |
|                                            |                                      |
|                                            v                                      |
|  [ STEP 2: Linkage Analysis ] ------> Determine Binding Mode                      |
|                                       - Direct Static In-Process Compile?         |
|                                       - Dynamic Shared Library (.so)?             |
|                                       - Separate Process IPC / gRPC?              |
|                                            |                                      |
|                                            +-------------------+                  |
|                                            |                   |                  |
|                                  Direct / In-Process      Process Boundary        |
|                                            | (GPL Reciprocity) | (No Reciprocity) |
|                                            v                   v                  |
|  [ STEP 3: Action Path ] ---------> [ REFACTOR TO RPC ]   [ DOCUMENT ISOLATION ]  |
|                                       or REPLACE LIB       Create Architecture     |
|                                                            Compliance Record      |
|                                            |                                      |
|                                            v                                      |
|  [ STEP 4: Verification ] ---------> Re-generate SBOM & Re-run Trivy/Syft Gate     |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

### 5.1 Aislamiento de la Causa Raíz: Rastreo del Árbol de Dependencias

#### Escenario A: Ingesta de Módulos Go
Un desarrollador importó `github.com/some/helper`, el cual importa transitivamente una librería GPL-3.0.

```bash
# Trace why the GPL package is in the build graph
$ go mod why github.com/mewmew/goplugin

# Output:
# # github.com/mewmew/goplugin
# main.val
# github.com/enterprise/core/pkg/processor
# github.com/mewmew/goplugin
```

#### Escenario B: Dependencia Transitiva de Node.js / NPM
```bash
# Locate AGPL package in NPM tree
$ npm ls agpl-connector --all

# Output:
# payment-ui@2.1.0 /home/sre/src/payment-ui
# └─┬ analytics-tracker@1.0.4
#   └── agpl-connector@0.9.4
```

### 5.2 Patrones de Aislamiento Arquitectónico

Si reemplazar el paquete copyleft es técnicamente imposible o de costo prohibitivo, los SREs y Arquitectos deben desacoplar el software a través de límites legales:

#### Patrón 1: Aislamiento por Límite de Red en Microservicios (gRPC / REST Sidecar)
*   **Problema:** Usar una librería de C++ licenciada bajo GPL para cálculo de grafos dentro de un motor de facturación propietario en Go directamente a través de CGO crea un único binario combinado (violación de GPL).
*   **Remediación:** Envolver la librería C++ GPL dentro de un daemon contenedorizado independiente que exponga una interfaz de API gRPC.

```
BEFORE (NON-COMPLIANT):
+-----------------------------------------------------------------+
| PROPRIETARY GO BINARY (In-Process CGO Calls)                    |
|  [ Go Core Code ] <---> [ GPL C++ Library ]  <-- INFECTION RISK |
+-----------------------------------------------------------------+

AFTER (COMPLIANT ARCHITECTURE):
+-----------------------------+          +----------------------------------+
| PROPRIETARY SERVICE         |  gRPC    | STANDALONE GPL DAEMON CONTAINER  |
| [ Go Core Code ]            | -------- | [ gRPC Server (GPL Wrappers) ]   |
| (Proprietary / Closed)      |  over    | [ GPL C++ Library ]              |
|                             |  TCP     | (Source Released on Request)     |
+-----------------------------+          +----------------------------------+
```

*   **Fundamento Legal:** Los procesos que se comunican a través de IPC por sockets de red estándar (gRPC/HTTP) son programas independientes bajo las directrices de aplicación de la GPL de la FSF. La reciprocidad no cruza los límites de proceso de sockets de red para GPLv2/GPLv3 estándar (Nota: AGPL sí cruza los límites de red si se proporciona interacción a través de la red).

#### Patrón 2: Negociación de Doble Licencia y Sala Limpia (Clean-Room Dual License Negotiation)
Para dependencias críticas donde el aislamiento por RPC introduce una latencia inaceptable:
1.  Contactar al titular del copyright para obtener una **Doble Licencia Comercial** (pagando una tarifa para recibir el código bajo términos que no sean copyleft).
2.  Realizar una **Reimplementación en Sala Limpia (Clean-Room)**: El Grupo de Desarrolladores A escribe las especificaciones funcionales sin consultar el código copyleft; el Grupo de Desarrolladores B implementa el código estrictamente a partir de la especificación.

### 5.3 Flujo de Trabajo Automatizado de Auditoría y Verificación

Verificar el éxito de la remediación antes de hacer merge de los pull requests:

```bash
# Step 1: Clean build environment & purge cache
$ go clean -modcache
$ npm cache clean --force

# Step 2: Re-generate fresh SBOM
$ syft dir:. -o spdx-json=remediation-check.spdx.json

# Step 3: Run Policy Engine Check
$ trivy sbom remediation-check.spdx.json --scanners license --severity CRITICAL --exit-code 1

# Expected Output upon successful isolation:
# 2026-08-06T19:25:00.000Z INFO License scan passed cleanly. 0 CRITICAL violations found.
```

---

## 6. Referencias

*   **Visión General Oficial de LPI Open Source Essentials:**  
    [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
*   **Proyecto GNU — Preguntas Frecuentes sobre las Licencias GNU:**  
    [https://www.gnu.org/licenses/gpl-faq.html](https://www.gnu.org/licenses/gpl-faq.html)
*   **Licencias y Estándares de la Open Source Initiative (OSI):**  
    [https://opensource.org/licenses](https://opensource.org/licenses)
*   **Especificación y Lista de Licencias de Software Package Data Exchange (SPDX):**  
    [https://spdx.org/licenses/](https://spdx.org/licenses/)  
    [https://spdx.dev/](https://spdx.dev/)
*   **Mejores Prácticas de la Cadena de Suministro de Software de la CNCF:**  
    [https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/gaps-and-future-trends.md](https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/gaps-and-future-trends.md)
*   **Open Policy Agent (OPA) Gatekeeper:**  
    [https://open-policy-agent.github.io/gatekeeper/website/docs/](https://open-policy-agent.github.io/gatekeeper/website/docs/)
*   **Herramienta SBOM Anchore Syft:**  
    [https://github.com/anchore/syft](https://github.com/anchore/syft)
*   **Escáner Aqua Security Trivy:**  
    [https://aquasecurity.github.io/trivy/](https://aquasecurity.github.io/trivy/)