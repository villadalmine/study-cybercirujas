# LPI Open Source Essentials (Exam 050-100) — Topic 5.3: Community Management

## 1. Visión General de la Arquitectura y Mecánica Técnica

La gestión de comunidades en el software de código abierto (OSS) empresarial y en plataformas alojadas por la CNCF transiciona el mantenimiento de proyectos de una colaboración ad-hoc a una gobernanza estructurada y escalable, junto con pipelines de contribución automatizados.

```
                     ┌──────────────────────────────────────────────────────────┐
                     │                 CONTRIBUTOR PIPELINE                     │
                     └──────────────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────┐         ┌──────────────────────────────────┐         ┌────────────────────────┐
│  Legal Compliance    │────────>│     Automated PR Triage & CI     │────────>│   Governance & Review  │
│  - DCO (Signed-off-by)│         │ - CODEOWNERS Routing             │         │ - SIG / WG Escalation  │
│  - CLA Enforcement   │         │ - Semantic PR Validation         │         │ - Maintainer Approval  │
│  - License Header    │         │ - Labeling & Issue Templating    │         │ - Merge & Release      │
└──────────────────────┘         └──────────────────────────────────┘         └────────────────────────┘
```

### 1.1 Modelos de Gobernanza
Los proyectos de código abierto implementan distintas topologías de gobernanza para gestionar la toma de decisiones, la propiedad del código y la resolución de conflictos:

1. **Benevolent Dictator for Life (BDFL):** Un único fundador o maintainer principal conserva la autoridad final de veto sobre las decisiones arquitectónicas. (Ejemplo: el kernel de Linux inicial bajo Linus Torvalds, Python bajo Guido van Rossum).
2. **Meritocracy:** La influencia y los derechos de voto se obtienen en función de contribuciones documentadas (commits, code reviews, documentación, soporte a la comunidad). La función de maintainer se otorga mediante consenso de pares. (Ejemplo: proyectos de Apache Software Foundation).
3. **Steering Committee / Technical Oversight Committee (TOC):** Un panel electo o designado de líderes técnicos supervisa arquitecturas de múltiples repositorios, la creación de SIG (Special Interest Group) y las políticas de respuesta de seguridad. (Ejemplo: Kubernetes Steering Committee, CNCF TOC).
4. **Foundation-Hosted Governance:** La propiedad de marcas registradas, nombres de dominio y activos de PI (propiedad intelectual) se transfiere a una fundación neutral sin fines de lucro (ej., Linux Foundation, Cloud Native Computing Foundation, Eclipse Foundation), mitigando los riesgos de vendor lock-in por parte de un único proveedor.

---

### 1.2 Protección de PI de Contribuyentes: DCO vs. CLA

Para proteger los proyectos contra infracciones de derechos de autor y aclarar los derechos de patentes, los proyectos exigen ya sea un Developer Certificate of Origin (DCO) o un Contributor License Agreement (CLA).

| Dimensión | Developer Certificate of Origin (DCO) | Contributor License Agreement (CLA) |
| :--- | :--- | :--- |
| **Mecanismo** | Encabezado liviano agregado a los mensajes de commit de Git mediante `git commit -s`. | Contrato legal firmado formalmente (Corporate CLA o Individual CLA). |
| **Base Legal** | Afirmación estándar definida por la Linux Foundation (DCO 1.1). | Cesión de derechos de autor personalizada o concesión amplia de licencia no exclusiva. |
| **Fricción** | Mínima; se maneja completamente dentro del workflow de la terminal del desarrollador. | Alta; requiere revisión legal, verificación de identidad o firma corporativa. |
| **Verificación** | Verificada en CI usando parseo por regex del trailer de commit de Git. | Verificada a través de integración OAuth (ej., EasyCLA, CLA Assistant). |
| **Adopción Empresarial** | Docker, Linux Kernel, Git, proyectos de CNCF (ej., Helm). | Google CLA (Kubernetes históricamente, Chromium), OpenStack. |

---

### 1.3 Controles Automatizados de Repositorios y Mecánica de Infraestructura

La gestión de comunidades escalable se basa en formatos de archivo declarativos ubicados dentro de las rutas raíz `.github/` o `.gitlab/`:

- **`CODEOWNERS`**: Automatiza la asignación de revisores según la coincidencia de rutas (path matching).
- **`SECURITY.md`**: Define las políticas de Responsible Disclosure (divulgación responsable), claves PGP y SLAs de reporte de vulnerabilidades.
- **`CODE_OF_CONDUCT.md`**: Establece los estándares de comportamiento de la comunidad (típicamente basados en Contributor Covenant v2.1) y contactos para el manejo de incidentes.
- **Plantillas de Issue & PR**: Formularios YAML estructurados que requieren especificaciones de entorno, pasos de reproducción y confirmaciones de checklist.

---

## 2. Ejercicios Guiados de Producción

### Ejercicio 1: Aplicar la Verificación de DCO (Developer Certificate of Origin) en Git Mediante Automatización de CI

#### Escenario
Como SRE que mantiene un repositorio de plataforma compatible con la CNCF, debés bloquear los commits de Git no conformes que carezcan de un trailer `Signed-off-by:` válido que cumpla con las especificaciones de DCO 1.1.

#### Pasos de Ejecución

1. Creá un repositorio local de Git y la estructura de directorios para GitHub Actions:
```bash
mkdir -p platform-engine/.github/workflows
cd platform-engine
git init -b main
```

2. Creá el archivo declarativo del workflow de linting de DCO `.github/workflows/dco-check.yaml`:
```yaml
name: DCO Verification

on:
  pull_request:
    branches: [ "main" ]

jobs:
  dco-lint:
    name: Verify DCO Sign-off
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Validate Git Commit Sign-offs
        run: |
          echo "==> Inspecting commit log for DCO compliance..."
          MISSING_DCO=0
          
          # Fetch all commits introduced by this PR relative to main target
          TARGET_BRANCH="origin/${{ github.base_ref }}"
          
          for SHA in $(git rev-list HEAD ^$TARGET_BRANCH); do
            COMMIT_MSG=$(git log -1 --format="%B" $SHA)
            AUTHOR_EMAIL=$(git log -1 --format="%ae" $SHA)
            
            if echo "$COMMIT_MSG" | grep -Eq "^Signed-off-by: .* <$AUTHOR_EMAIL>"; then
              echo "SUCCESS: Commit $SHA has valid DCO trailer matching author <$AUTHOR_EMAIL>."
            else
              echo "ERROR: Commit $SHA lacks valid DCO trailer for author <$AUTHOR_EMAIL>."
              MISSING_DCO=$((MISSING_DCO + 1))
            fi
          done

          if [ $MISSING_DCO -gt 0 ]; then
            echo "FAILED: $MISSING_DCO commit(s) missing DCO sign-off. Use 'git commit -s --amend'."
            exit 1
          fi
```

3. Probar la creación local de un commit firmado conforme utilizando flags nativos de `git`:
```bash
echo "module platform-engine" > go.mod
git add go.mod
git commit -s -m "feat(core): initialize core platform module"
```

4. Inspeccioná el log de Git para verificar la generación del trailer:
```bash
git log -1 --format=fuller
```

**Salida Esperada:**
```text
commit 3f8a109b2a64c8d5e110b42f6d901002f1a2384a
Author:     SRE Lead <sre@enterprise.internal>
AuthorDate: Thu Aug 6 19:20:14 2026 -0400
Commit:     SRE Lead <sre@enterprise.internal>
CommitDate: Thu Aug 6 19:20:14 2026 -0400

    feat(core): initialize core platform module

    Signed-off-by: SRE Lead <sre@enterprise.internal>
```

#### Preguntas de Comprensión (Ejercicio 1)

1. ¿Por qué el script de verificación de DCO compara la dirección de correo electrónico en `Signed-off-by: Nombre <email>` con el correo electrónico del autor del commit de Git (`%ae`)?
2. ¿Qué comando y flag específicos de git debe ejecutar un contribuyente para corregir un PR que contiene tres commits históricos donde al segundo commit le faltaba la firma `-s`?

---

### Ejercicio 2: Implementar CODEOWNERS Empresarial y Triaje Automatizado de Issues

#### Escenario
Para evitar el agotamiento de los maintainers (burnout) y garantizar un estricto cumplimiento de los SLA, tu equipo necesita la asignación de revisores basada en rutas a través de `CODEOWNERS` combinada con plantillas de issues en formato YAML para el seguimiento de errores (bug tracking).

#### Pasos de Ejecución

1. Creá las estructuras de directorios para la gobernanza del repositorio:
```bash
mkdir -p .github/ISSUE_TEMPLATE
```

2. Configurá las reglas de propiedad basadas en rutas en `.github/CODEOWNERS`:
```text
# Default global maintainers
*       @infra-core-team

# Core architecture and security critical paths
/security/              @security-response-team
/pkg/crypto/            @security-response-team @crypto-leads

# Operations & Kubernetes Deployment Manifests
/deploy/helm/           @devops-maintainers
/*.go                   @golang-reviewers
```

3. Construí una plantilla de Issue YAML sintácticamente válida en `.github/ISSUE_TEMPLATE/bug_report.yml`:
```yaml
name: "Bug Report"
description: "Submit a production defect report"
title: "[BUG]: "
labels: ["triage/needs-investigation", "kind/bug"]
body:
  - type: markdown
    attributes:
      value: |
        Thank you for reporting an issue! Please fill out the technical details below.
  - type: input
    id: environment
    attributes:
      label: Kubernetes Version & OS Environment
      placeholder: "e.g. v1.30.2 on Ubuntu 24.04 LTS"
    validations:
      required: true
  - type: textarea
    id: reproduction
    attributes:
      label: Steps to Reproduce
      description: Provide precise steps or shell scripts to recreate the failure.
      placeholder: |
        1. kubectl apply -f manifest.yaml
        2. Inspect pod log output...
    validations:
      required: true
  - type: dropdown
    id: severity
    attributes:
      label: Production Severity Impact
      options:
        - Critical (P0 - Outage)
        - Major (P1 - Component Degradation)
        - Minor (P2 - Non-blocking Issue)
    validations:
      required: true
```

4. Verificá la validez del esquema de la plantilla de issue utilizando la herramienta GitHub CLI (`gh`):
```bash
gh issue create --template "bug_report.yml" --dry-run
```

**Salida Esperada:**
```json
{
  "title": "[BUG]: ",
  "labels": ["triage/needs-investigation", "kind/bug"],
  "body": "### Kubernetes Version & OS Environment\n\n\n### Steps to Reproduce\n\n\n### Production Severity Impact\n\n"
}
```

#### Preguntas de Comprensión (Ejercicio 2)

1. Si un PR modifica tanto `/security/tls.go` como `/deploy/helm/values.yaml`, ¿a qué equipos se les solicitará automáticamente la revisión de acuerdo con el archivo `.github/CODEOWNERS` creado anteriormente?
2. ¿Cuál es el riesgo operativo de colocar entradas en `.github/CODEOWNERS` sin barras diagonales iniciales (ej., `security/` en lugar de `/security/`)?

---

### Ejercicio 3: Análisis de Métricas de la Comunidad y Diagnóstico de Salud de la Gobernanza

#### Escenario
Estás auditando un proyecto de código abierto para cuantificar la salud de la comunidad, la velocidad de los maintainers y el riesgo de centralización (Bus Factor / Elephant Factor) antes de adoptarlo en producción.

#### Pasos de Ejecución

1. Cloná un repositorio de la comunidad y ejecutá cálculos de métricas locales mediante el análisis del historial de Git:
```bash
git log --format='%aN' --since="1 year ago" | sort | uniq -c | sort -nr | head -n 10
```

**Salida Esperada:**
```text
    482 Alice Developer
    310 Bob Engineer
     45 Charlie Contributor
     12 Dave User
      3 Eve Tester
```

2. Calculá el **Bus Factor (Bust Out Score)** y el **Elephant Factor** a partir del resultado de la distribución de commits:
   - **Total de Commits en el Período**: 852
   - **Commits de Alice**: 482 (56.5%)
   - **Commits de Bob**: 310 (36.3%)
   - **Top 2 Combinados**: 792 / 852 = 92.9% de todos los commits.

3. Calculá las métricas clave de la comunidad utilizando las definiciones estándar de CHAOSS:

```
Metric Definitions:
  - Bus Factor: Min number of key contributors who, if absent, stall project progress.
  - Elephant Factor: Min number of organizations accounting for >50% of contributions.
```

#### Preguntas de Comprensión (Ejercicio 3)

1. Dada la distribución de commits en el Paso 2, ¿cuál es el Bus Factor de este proyecto? ¿Qué riesgo operativo representa esto para un usuario empresarial?
2. Definí "Elephant Factor" en el contexto de la gobernanza de código abierto alojada en fundaciones (ej., CNCF) y por qué un Elephant Factor bajo (ej., 1) representa un riesgo corporativo.

---

## 3. Respuestas y Soluciones Técnicas en Profundidad

<details>
<summary>Hacé clic para desplegar las respuestas para el Ejercicio 1, Ejercicio 2 y Ejercicio 3</summary>

### Soluciones del Ejercicio 1

1. **Justificación de la Coincidencia de Correo Electrónico**:
   - El Developer Certificate of Origin (DCO) es una declaración legalmente vinculante realizada por la persona específica identificada por la dirección de correo electrónico.
   - Hacer coincidir el correo electrónico de `Signed-off-by:` con `%ae` (Author Email) garantiza que los contribuyentes no envíen código bajo identidades de terceros ni omitan el seguimiento de cumplimiento de licencias corporativas.

2. **Remediación de Commits Históricos Sin Firma**:
   - Para corregir el historial interactivo donde los commits carecen de firma, el desarrollador ejecuta un rebase interactivo:
     ```bash
     git rebase -i HEAD~3
     ```
   - Cambiá `pick` por `edit` (o `e`) para los commits no conformes.
   - Para cada commit detenido, ejecutá:
     ```bash
     git commit --amend -s --no-edit
     git rebase --continue
     ```
   - Finalmente, actualizá la rama de feature remota con:
     ```bash
     git push --force-with-lease
     ```

---

### Soluciones del Ejercicio 2

1. **Asignación de Revisión de CODEOWNERS**:
   - Para `/security/tls.go`: Coincide tanto con `/security/` (`@security-response-team`) como con `/*.go` (`@golang-reviewers`). Ambos equipos son asignados.
   - Para `/deploy/helm/values.yaml`: Coincide con `/deploy/helm/` (`@devops-maintainers`).
   - Revisores asignados totales: `@security-response-team`, `@crypto-leads` (si las rutas anidadas coinciden), `@golang-reviewers` y `@devops-maintainers`.

2. **Semántica de Coincidencia de Barra Diagonal Inicial (`/`)**:
   - Una regla que comienza con una barra diagonal inicial `/security/` ancla la coincidencia estrictamente a la raíz del repositorio.
   - Sin una barra diagonal inicial (`security/`), el patrón coincide de forma recursiva con cualquier subdirectorio a cualquier profundidad que coincida con `*/security/` (ej., `pkg/submodule/security/` o `vendor/third_party/security/`), lo que genera spam no deseado de solicitudes de revisión para modificaciones de código no relacionadas.

---

### Soluciones del Ejercicio 3

1. **Bus Factor y Riesgo Operativo Empresarial**:
   - **Bus Factor = 2** (Alice y Bob combinados escriben el 92.9% de todo el código).
   - **Riesgo**: Si Alice o Bob abandonan el proyecto o cambian de empleo, el proyecto enfrenta cuellos de botella severos en el mantenimiento, acumulaciones de PRs sin revisar, demoras en el lanzamiento de parches de seguridad y un potencial abandono.

2. **Análisis del Elephant Factor**:
   - El **Elephant Factor** mide la diversidad corporativa dentro de una comunidad. Es el número mínimo de empresas que contribuyen con más del 50% de los commits/reviews.
   - Un Elephant Factor de 1 significa que una sola empresa controla la velocidad de desarrollo y la dirección técnica. Si ese único patrocinador corporativo cambia la licencia (ej., cambiando de licencia de Apache 2.0 a BUSL/SSPL), las prioridades estratégicas, o abandona el proyecto, los usuarios aguas abajo (downstream) enfrentan altos costos de migración o una exposición repentina en el cumplimiento de licencias.

</details>

---

## 4. Fuentes de Referencia Oficiales y Enlaces

- **LPI Open Source Essentials Exam Objectives (050-100)**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **Developer Certificate of Origin (DCO 1.1 Text)**: [https://developercertificate.org/](https://developercertificate.org/)
- **Contributor Covenant Code of Conduct (v2.1)**: [https://www.contributor-covenant.org/](https://www.contributor-covenant.org/)
- **CNCF Community Governance Guidelines**: [https://github.com/cncf/foundation/blob/main/governance-guidelines.md](https://github.com/cncf/foundation/blob/main/governance-guidelines.md)
- **CHAOSS Community Metrics & Analytics Project**: [https://chaoss.community/metrics/](https://chaoss.community/metrics/)