# 4.2 Cloud Native Community and Collaboration

## Open Source Software (OSS) como base del ecosistema cloud native

Prácticamente todo el stack cloud native (Kubernetes, Prometheus, Envoy, containerd, etc.) es **open source**. Entender los mecanismos de OSS es tan importante para el KCNA como entender la tecnología en sí, porque el examen evalúa cómo se gobiernan, mantienen y evolucionan estos proyectos.

Puntos clave:

- **Licencias comunes** en el ecosistema CNCF:
  - **Apache License 2.0**: la más usada (Kubernetes, containerd, Helm). Permite uso comercial, modificación y redistribución, exige preservar avisos de copyright y otorga una concesión explícita de patentes.
  - **MIT**: muy permisiva, mínimas restricciones.
  - **GPL/LGPL**: copyleft, menos común en el core de CNCF por ser menos "business-friendly".
- El código abierto no es solo "código gratis": implica **desarrollo colaborativo en público**, con historial de cambios auditable y decisiones discutidas abiertamente (issues, PRs, design docs).
- La sostenibilidad de un proyecto depende de su **comunidad de contribuyentes**, no solo de una empresa. Este es un criterio central que la CNCF exige para que un proyecto avance de madurez.

```bash
# Verificar la licencia de un repo antes de usarlo/contribuir
curl -s https://api.github.com/repos/kubernetes/kubernetes/license | jq '.license.spdx_id'
# "Apache-2.0"
```

## Cloud Native Computing Foundation (CNCF)

La **CNCF** es la organización que aloja ("hosts") los proyectos cloud native open source más relevantes. Es parte de la **Linux Foundation** (una organización sin fines de lucro) y su misión declarada es *"hacer que la computación cloud native sea ubicua"*.

La CNCF no escribe la mayoría del código: provee estructura neutral (legal, marca, infraestructura de CI, gobernanza, eventos) para que proyectos y competidores de la industria colaboren en un espacio vendor-neutral.

- Fundada en 2015, junto con la donación inicial de **Kubernetes** por parte de Google.
- Financiada por membresías corporativas (Platinum, Gold, Silver) y membresías de **End User** (empresas que usan, no necesariamente contribuyen código).
- Publica el **CNCF Cloud Native Landscape**, un mapa interactivo de proyectos y productos organizados por categoría (orchestration, observability, service mesh, storage, security, etc.).

```
https://landscape.cncf.io
```

## Project Maturity Levels

Todo proyecto que entra a la CNCF pasa por niveles de madurez, evaluados por el **TOC** (ver más abajo):

| Nivel | Significado | Ejemplos |
|---|---|---|
| **Sandbox** | Etapa inicial, bajo riesgo, en experimentación temprana | Backstage (antes de graduarse), Keptn |
| **Incubating** | Adopción real en producción por varios usuarios, gobernanza y prácticas de proyecto establecidas | OpenTelemetry, Argo, Cilium |
| **Graduated** | Máxima madurez: adopción amplia, diversidad de mantenedores/organizaciones, auditoría de seguridad realizada, buenas prácticas de gobernanza (OpenSSF Best Practices) | Kubernetes, Prometheus, Envoy, containerd, CoreDNS, etcd, Helm, Fluentd, Vitess |
| **Archived** | El proyecto se retira de la CNCF (falta de mantenimiento, reemplazo, etc.) | — |

Requisitos típicos para graduar incluyen: al menos dos organizaciones distintas como mantenedores principales, adopción demostrable, cumplimiento del Code of Conduct, y una auditoría de seguridad de terceros.

```bash
# Consultar el estado y categoría de un proyecto en el landscape (vía API pública)
curl -s https://raw.githubusercontent.com/cncf/landscape/master/landscape.yml \
  | grep -A3 "name: Prometheus"
```

## Estructura de gobernanza de la CNCF

- **Governing Board (GB)**: representantes de las empresas miembro; maneja presupuesto, marketing, membresías y decisiones de negocio. No decide sobre el código técnico.
- **Technical Oversight Committee (TOC)**: cuerpo técnico electo que aprueba la incorporación de nuevos proyectos y su avance entre niveles de madurez (Sandbox → Incubating → Graduated).
- **TAGs (Technical Advisory Groups)**: grupos temáticos transversales que asesoran al TOC. Ejemplos: TAG App Delivery, TAG Security, TAG Observability, TAG Runtime, TAG Network, TAG Storage, TAG Contributor Strategy.
- **End User Community**: empresas que *usan* tecnología cloud native (no necesariamente contribuyen código) y aportan feedback de adopción real (ej. adoption case studies).

Dentro de **proyectos individuales** (como Kubernetes) existe una estructura propia más granular:

- **SIGs (Special Interest Groups)**: ej. `sig-network`, `sig-storage`, `sig-apps`, `sig-node`, cada uno responsable de un área técnica del proyecto.
- **Working Groups**: grupos temporales para resolver un tema puntual entre varios SIGs.

## Roles dentro de una comunidad open source

Es común encontrar esta progresión (definida en `community/community-membership.md` de Kubernetes, tomado como referencia por muchos proyectos CNCF):

1. **Member**: firmó el CLA/DCO y tuvo al menos una contribución aceptada.
2. **Reviewer**: puede revisar (`/lgtm`) PRs en un área específica.
3. **Approver**: puede aprobar (`/approve`) merges en un área específica.
4. **Maintainer**: responsabilidad global sobre el proyecto o subsistema (roadmap, releases, gobernanza).

Estos roles suelen quedar declarados en un archivo **`OWNERS`** dentro del repo:

```yaml
# OWNERS (ejemplo simplificado, estilo Kubernetes)
approvers:
  - alice
  - bob
reviewers:
  - carol
  - dave
```

### DCO (Developer Certificate of Origin)

Muchos proyectos CNCF (Kubernetes, containerd, Helm) exigen firmar los commits para certificar que el autor tiene derecho a contribuir ese código:

```bash
git commit -s -m "fix: correct typo in kubelet flag description"
```

```
commit a1b2c3d
Author: Alice Dev <alice@example.com>
Date:   Wed Jul 16 10:00:00 2026 -0300

    fix: correct typo in kubelet flag description

    Signed-off-by: Alice Dev <alice@example.com>
```

Un PR sin `Signed-off-by:` suele ser rechazado automáticamente por un bot de CI (ej. la DCO GitHub App).

## Canales de comunicación y colaboración

- **Slack**: `kubernetes.slack.com` (proyecto Kubernetes) y `cloud-native.slack.com` (CNCF general), organizados en canales por SIG/proyecto/tema.
- **Mailing lists** (Google Groups): usadas para anuncios formales, discusiones de diseño y voting.
- **GitHub**: Issues (bugs/features), Discussions (preguntas), Pull Requests (cambios de código), todo público y auditable.
- **Community meetings**: reuniones periódicas por videollamada, con actas públicas (ej. Google Docs enlazados desde el calendario del SIG).
- **KubeCon + CloudNativeCon**: el evento insignia de la CNCF (se realiza en América del Norte, Europa y Asia cada año), donde se presentan charlas técnicas, se coordinan contribuyentes y se realizan reuniones de TOC/TAGs presenciales.

```bash
# Ejemplo de flujo típico de contribución
git clone https://github.com/cncf/foo.git
cd foo
git checkout -b fix/typo-readme
# ... editar archivos ...
git commit -s -m "docs: fix typo in README"
git push origin fix/typo-readme
# luego abrir un Pull Request desde GitHub
```

## Code of Conduct

La CNCF exige que todos sus proyectos adopten un **Code of Conduct** (basado en el *Contributor Covenant*), que define comportamiento esperado, mecanismos de reporte y consecuencias ante violaciones. Es un requisito de gobernanza, no opcional, para cualquier proyecto alojado por la fundación.

## Certificaciones relacionadas (Linux Foundation / CNCF)

Como parte de la estrategia de comunidad, la CNCF y la Linux Foundation ofrecen certificaciones que validan conocimiento y habilidades:

- **KCNA** (Kubernetes and Cloud Native Associate) — la certificación de este mismo material.
- **KCSA** (Kubernetes and Cloud Native Security Associate).
- **CKA** (Certified Kubernetes Administrator), **CKAD** (Application Developer), **CKS** (Security Specialist).
- Certificaciones de otros proyectos del landscape (ej. Prometheus Certified Associate, Istio Certified Associate).

Estas certificaciones son en sí mismas un producto de la **colaboración comunitaria**: el temario (curriculum) se define y actualiza públicamente en GitHub, con contribuciones abiertas de la comunidad.

```
https://github.com/cncf/curriculum
```

## Referencias

- CNCF Curriculum (KCNA) — https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- CNCF Charter y estructura de gobernanza — https://github.com/cncf/foundation/blob/main/charter.md
- CNCF Cloud Native Landscape — https://landscape.cncf.io
- CNCF Project Graduation Criteria — https://github.com/cncf/toc/blob/main/process/graduation_criteria.md
- Kubernetes Community Membership — https://github.com/kubernetes/community/blob/master/community-membership.md
- CNCF Code of Conduct — https://github.com/cncf/foundation/blob/main/code-of-conduct.md
- Contributor Covenant — https://www.contributor-covenant.org
- CNCF Contribute — https://contribute.cncf.io
- KubeCon + CloudNativeCon — https://www.cncf.io/kubecon-cloudnativecon-events/