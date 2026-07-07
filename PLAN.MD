# Plataforma Educativa

## Objetivo

Plataforma educativa self-service que trackea las certificaciones mainstream, baja sus temarios públicos y genera con AI un curso completo por certificación: contenido, ejercicios y laboratorios on-demand. El estudiante entra a su catálogo, elige una certificación y tiene todo listo para estudiar y certificar.

**Yo nunca genero contenido a mano.** La AI arma todo a partir del catálogo (temario + enlaces de ejercicios + data extra). El contenido se genera una vez y queda; solo se regenera cuando yo lo decido.

## Principios de diseño

- **Snapshot, no dependencia en vivo**: el temario se baja una vez y queda congelado en el repo. Si la certificación cambia upstream, nada se rompe — un proceso aparte detecta el cambio y yo decido si actualizo.
- **El estado vive en archivos** (MD + YAML), versionable en git. Si una regeneración sale mal, `git diff` y vuelvo atrás.
- **Generar una vez**: el contenido generado es estático para el estudiante. Nunca hay generación ni scraping en caliente durante el estudio.
- **CLI primero**: todo lo que hace la web se puede hacer por CLI. La web es solo una vista del mismo catálogo de archivos.
- **Roles separados que no se pisan**: el tracker escribe versiones, el generador escribe contenido, la web/CLI solo leen.

## Arquitectura — 3 piezas

### 1. Tracker del catálogo (scraper — nada es estático)

Principio: **todo dato del catálogo se deriva de una fuente oficial scrapeada**;
nada se mantiene a mano (a mano solo se *enriquece*, con `edited` para que no
se pise). Implementado en `core/tracker.py`:

- `teach tracker sync --provider cncf` — determinístico, sin AI: API de GitHub
  sobre cncf/curriculum; fecha del último commit de cada PDF = versión del
  curriculum; marca `new-version-available` si upstream cambió.
- `teach tracker sync --provider lpi --backend <ai>` — scrapea lpi.org y la AI
  convierte la página en updates estructurados (nivel/validez/requires).
- `teach cert snapshot <id> --backend <ai>` — baja los objetivos oficiales
  (HTML o **PDF**, con pypdf) y la AI los convierte en topics YAML congelados
  en el MD. Statuses existentes se preservan; `--force` para re-snapshotear.
- `teach paths generate --backend <ai>` — la AI propone los paths de carrera
  desde el catálogo (respetando `requires`); paths con `edited: true` (ej. los
  que encodean datos scrapeados de Kubestronaut/CARE) nunca se pisan.
- Corre periódicamente (cron); nunca toca el contenido generado — solo el
  catálogo, y avisa qué cambió.

### 2. Generador (AI, bajo demanda)

Backends intercambiables (`TEACH_BACKEND` / `--backend` / `make generate BACKEND=`):

- **litellm** (default): el LiteLLM que ya está en el cluster (API compatible
  OpenAI: `LITELLM_BASE_URL` + `LITELLM_API_KEY` + `LITELLM_MODEL`).
- **claude / codex / gemini / custom**: agentes CLI locales (Claude Code,
  Codex CLI, Gemini CLI, o cualquier comando vía `TEACH_AGENT_CMD`). Flujo:
  generar local → revisar → `make publish` (commit + push al repo que publica
  la página).

Con la info del catálogo (temario, enlaces de ejercicios, data extra), la AI estudia cómo armar el aprendizaje de cada tema y genera:

- **Texto con ejemplos** del tema, con referencias a la documentación oficial.
- **Ejercicios guiados**: pasos con preguntas.
- **Scripts de laboratorio** tipo *break & fix*: romper algo y que el estudiante lo arregle.
- **Video** del tema (fase posterior — ver Roadmap).
- **Definición del lab**: qué recursos necesita el tema (para terraform).

Reglas del generador:
- Si acepto una actualización de temario, regenera **solo los temas que cambiaron**.
- Los temas con `status: edited` (enriquecidos a mano) **nunca se pisan** al regenerar.
- Cada contenido generado guarda con qué modelo/prompt se generó, para trazabilidad al regenerar o cambiar de modelo.
- El contenido generado es original; siempre con atribución de fuentes. No se copia texto literal de materiales de terceros — el temario es el índice, el contenido es nuestro.

### 3. Web: landing pública + zona de estudio paga

**Landing pública (sin login)** — la página es referente de qué certificaciones
existen, publicable e indexable:
- Landscape completo por categoría y nivel, con vencimientos, dependencias,
  reglas CARE y versión de curriculum de cada cert.
- Temario oficial de cada cert (temas + pesos + disponibilidad). El estado
  interno de generación NO se expone: se traduce a "disponible/próximamente".
- Paths de carrera con gráfico de dependencias, Kubestronaut/Golden y CARE.

**Zona de estudio (login + plan pago)**:
- El contenido (teoría, ejercicios, labs) exige sesión + suscripción activa
  (HTTP 402 sin plan).
- v1: `authenticate()` con admin/admin y `has_subscription()` stub que siempre
  aprueba al admin — interfaces mínimas para enchufar usuarios reales/OIDC y
  una pasarela de pago (Stripe o similar) sin tocar el resto.
- Solo lee lo ya generado; experiencia instantánea.

## Arquitectura de código

Una sola capa `core` (Python) con toda la lógica, y entradas finas que solo parsean argumentos/HTTP:

```
teach/
  core/          # TODA la lógica: catálogo, certs, generador (LiteLLM), labs
    catalog.py
    certs.py
    generator.py
    labs.py
    auth.py      # authenticate(user, pass) — hoy admin/admin, mañana OIDC
  cli.py         # typer  → llama a core directo (archivos locales, sin API)
  api.py         # FastAPI → llama a core; login por sesión; sirve la web
  web/           # frontend estático que consume la API
```

- La CLI **no pasa por la API**: opera sobre los mismos archivos locales.
- FastAPI expone OpenAPI (`/docs`) gratis → el frontend consume endpoints ya documentados.
- Python alcanza y sobra: la API es I/O-bound (archivos + esperar LLM/terraform);
  10k req/h ≈ 2,8 req/s, <1% de la capacidad de un proceso uvicorn. El camino del
  estudiante sirve contenido estático ya generado — lo más barato posible.

### Lab runner desacoplado (futuro, Go)

La ejecución de infra se desacopla del core por un **contrato declarativo**:

```
teach/core (Python)          lab-runner (Go, desacoplado)
  genera contenido      →      lee lab specs
  escribe lab specs     →      ejecuta terraform (up/down)
  lee estado de labs    ←      escribe estado (running/failed/destroyed)
        └── contrato: lab.yaml + terraform files + status.yaml ──┘
```

- v1: `core/labs.py` ejecuta terraform con subprocess (un solo usuario). El
  contrato (lab spec + status) queda definido desde el día uno.
- Con carga real: runner en Go (`terraform-exec` de Hashicorp) contra el mismo
  contrato; el core solo deja de ejecutar y pasa a leer el estado. Candidato a
  operator de Kubernetes en el cluster.
- Comunicación por etapas: (a) archivos compartidos, (b) mini API HTTP del
  runner, (c) cola (NATS/Redis) cuando haya volumen.

## Idiomas (IMPLEMENTADO)

Idiomas: **es (default), en, fr, de, zh, ja, pt**.

- Contenido por idioma: `certs/<cert>/<topic>/<lang>/{content,exercises,meta}`.
  El **lab es compartido** entre idiomas (spec/terraform/scripts).
- `teach cert generate <cert> --lang en` genera en ese idioma; disponibilidad
  por idioma = existencia del archivo (la API expone `langs` por tema).
  `status` del MD sigue al idioma default.
- API: `?lang=` en contenido y preview, con **fallback al español** (marcado
  con `lang_fallback` y aviso en la web).
- Web: selector de idioma en el header (persistido en localStorage, detecta el
  idioma del browser); toda la UI traducida a los 7 idiomas.
- Pendiente: generar las traducciones del contenido existente (`--lang en`, …).

## Modelo de datos

`catalog.yaml` — el catálogo global:

```yaml
certs:
  lpi-010-160:
    name: LPI Linux Essentials
    tracked_version: "1.6"
    upstream_status: current | new-version-available
    sources:
      objectives: https://www.lpi.org/our-certifications/exam-010-objectives/
```

Un MD por certificación, con frontmatter — el esqueleto genérico que aplica a cualquier cert:

```markdown
---
cert: lpi-linux-essentials
exam: "010-160"
version: "1.6"
sources:
  - https://www.lpi.org/our-certifications/exam-010-objectives/
  - https://learning.lpi.org/en/learning-materials/010-160/
topics:
  - id: "1.1"
    title: "Linux Evolution and Popular Operating Systems"
    weight: 2
    sources: [...]        # links específicos del tema, enriquecibles a mano
    status: generated | edited | stale
---
```

Los links de fuentes cambian según el tema; se pueden enriquecer a mano y el curso se puede volver a generar sin perder eso.

## CLI

```
teach cert add lpi-010-160        # baja y congela el temario (snapshot)
teach cert diff lpi-010-160       # muestra qué cambió upstream vs mi snapshot
teach cert update lpi-010-160     # acepto la versión nueva (tema por tema)
teach cert generate lpi-010-160   # genera contenido vía LiteLLM (respeta edited)
teach lab up lpi-010-160/1.2      # levanta el lab del tema
teach lab down lpi-010-160/1.2
teach serve                       # levanta la web sobre el mismo catálogo
```

## Labs

- Lab por tema con **terraform**, conectable a distintos targets: clouds, on-prem (proxmox, libvirt/baremetal) o la máquina local.
- v1: **un solo provider** (el más barato de probar: máquina local con libvirt, o proxmox). El contrato del lab (recursos + script de setup) se define en el MD del tema; agregar providers después es mecánico.
- Tipos de lab: break & fix (scripts que rompen, el estudiante arregla) y guiados (pasos con preguntas).

## Niveles, vencimientos y paths de carrera

Datos de documentación oficial (lpi.org, cncf.io, docs.linuxfoundation.org):

**LPI** — 3 tracks:
- *Essentials* (sin prerequisitos, **no vencen**): Linux Essentials 010,
  Security Essentials 020, Web Development Essentials 030, Open Source
  Essentials 050.
- *Professional* (**5 años**, cadena de prerequisitos activos):
  LPIC-1 → LPIC-2 → LPIC-3 (300 Mixed Env / 303 Security / 305 Virtualization
  / 306 High Availability).
- *Open Technology* (**5 años**, sin prerequisitos): DevOps Tools Engineer 701,
  BSD Specialist 702.

**CNCF / Linux Foundation**:
- *Associate* (**3 años**): KCNA, KCSA, CGOA, CAPA, CBA, CNPA, CCA, ICA, KCA,
  OTCA, PCA.
- *Professional* (**2 años** desde 2024-04): CKA, CKAD, CKS (exige CKA
  aprobada), CNPE.
- LFCS (**2 años**) — necesaria para Golden Kubestronaut.

**Programas** (todas las certs deben estar vigentes a la vez; al aprobar todas,
CNCF contacta por email en la semana hábil):
- **Kubestronaut**: CKA + CKAD + CKS + KCNA + KCSA.
- **Golden Kubestronaut**: las 15 CNCF + LFCS. Título de por vida.

**Programa CARE** (Certification Advancement & Recertification Experience,
vigente desde 2026-01-01, expandido 2026-06-17): aprobar/recertificar una cert
superior renueva las inferiores igualando vencimientos:
- CKA o CKAD → renueva KCNA
- CKS → renueva KCSA
- CKS → reinstala y extiende CKA, incluso ya vencida (desde 2026-06-18)
Con CARE, 3 exámenes (CKS + CKAD + una associate) mantienen las 5 certs
Kubestronaut. En catalog.yaml: campo `renewed_by` por cert + entrada `care`
en paths.

**Versionado "current" de CNCF**: los PDFs sin versión semántica se versionan
por la **fecha del último cambio del PDF en git** (campo `curriculum_updated`;
el tracker vigila commits del repo cncf/curriculum). CKA/CKAD/CKS además traen
versión propia que sigue a Kubernetes (v1.35 = K8s 1.35).

Todo esto vive en `catalog.yaml`: `level`, `validity`, `requires` por cert, y
sección `paths` (carreras con steps + achievements con requires_all). La web
agrupa por categoría → nivel y tiene vista "Paths de carrera" con el gráfico
de dependencias.

## Catálogo por categorías

La página principal agrupa por categoría (`category` en catalog.yaml):

- **Cursos Linux**: LPI completo — Essentials (010/020/021), LPIC-1, LPIC-2,
  LPIC-3 (300/303/305/306), DevOps Tools Engineer.
- **Cloud Native (CNCF)**: las 15 certs de https://github.com/cncf/curriculum
  (CKA, CKAD, CKS, KCNA, KCSA, CGOA, CAPA, CBA, CNPA, CNPE, CCA, ICA, KCA,
  OTCA, PCA). Ese repo es la fuente de verdad: un PDF versionado por cert
  (ej. CKA v1.35), licencia **CC-BY 4.0**, y CNCF invita explícitamente a
  alinear trainings al curriculum. El tracker puede vigilar el repo por
  versiones nuevas de los PDFs.
- Todas cargadas sin temario todavía (topics vacíos); el snapshot de objetivos
  de cada una se congela al momento de armar el curso. Para CNCF el temario
  sale del PDF (extraer topics + pesos del curriculum).

## Primera versión de prueba

Primer ejemplo: **LPI Linux Essentials (010-160)**

- https://www.lpi.org/
- https://www.lpi.org/our-certifications/linux-essentials-overview/
- https://www.lpi.org/our-certifications/exam-010-objectives/
- https://learning.lpi.org/en/learning-materials/010-160/

Nota: los learning materials de LPI están bajo Creative Commons — chequear la licencia de cada fuente que se use como referencia.

## Roadmap

1. Esqueleto de datos (catalog.yaml + MD con frontmatter) con LPI 010-160 como primer caso real.
2. CLI: `cert add` + `cert generate` contra LiteLLM (texto + ejercicios + scripts break & fix).
3. Tracker de versiones (`cert diff` / `cert update`) como proceso periódico.
4. `lab up/down` con un solo provider.
5. Web con login admin/admin leyendo el mismo catálogo.
6. Video por tema (requiere pipeline aparte de LiteLLM texto — ej. guion generado + TTS + slides; evaluar herramientas cuando lleguemos).
7. Multi-idioma (en/es/fr/de/zh/ja/pt): contenido por `<topic>/<lang>/`, status por idioma, selector en la web.
   - Mejorar la presentación de la web: hoy muestra el contenido crudo (sin
     formato); falta render de Markdown, estilos, navegación entre temas.
     No es prioridad — el core es el contenido en sí.
8. Multi-provider de labs, usuarios reales, lab-runner en Go contra el contrato lab.yaml.
