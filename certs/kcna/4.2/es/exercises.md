# Ejercicios Guiados: Cloud Native Community and Collaboration (KCNA 4.2)

> Fuente de referencia: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

Estos ejercicios te llevan a explorar de primera mano cómo está organizada la comunidad cloud native: el rol de la CNCF, la madurez de los proyectos, los modelos de governance, las personas involucradas y las licencias open source. No requieren cluster ni terminal: usás un navegador y, en algunos casos, `git`/`curl`.

---

## Ejercicio 1: El CNCF Landscape

1. Abrí [landscape.cncf.io](https://landscape.cncf.io) en tu navegador.
2. Ubicá la categoría **"Orchestration & Management"** y dentro de ella la subcategoría **"Scheduling & Orchestration"**.
3. Identificá cuál es el único proyecto marcado como **Graduated** en esa subcategoría.
4. Cambiá el filtro superior de "Card" a "Landscape" (o usá el toggle de vista) y contá cuántas categorías principales tiene el landscape completo.
5. Filtrá por **"CNCF Graduated"** en el menú de filtros y anotá cuántos proyectos aparecen en total.

**Preguntas de comprensión:**
- ¿Qué diferencia hay entre un proyecto que aparece en el landscape y un proyecto que es un **CNCF project** (Sandbox, Incubating o Graduated)?
- ¿Por qué la CNCF mantiene un landscape tan amplio en vez de limitarse a listar solo sus propios proyectos?

---

## Ejercicio 2: Niveles de madurez de un proyecto

1. Andá al repositorio [github.com/cncf/toc](https://github.com/cncf/toc).
2. Abrí el archivo `process/graduation_criteria.md` (o buscalo con la búsqueda del repo si cambió de ubicación).
3. Identificá los tres niveles de madurez que define la CNCF: **Sandbox**, **Incubating** y **Graduated**.
4. Para cada nivel, anotá al menos un requisito formal (ejemplo: número mínimo de committers de organizaciones distintas, adopción documentada por al menos 3 end users en producción, superar una security audit, etc.).
5. Volvé a [landscape.cncf.io](https://landscape.cncf.io), buscá **Argo** y **etcd**, y determiná en qué nivel de madurez está cada uno actualmente.

**Preguntas de comprensión:**
- ¿Qué organismo dentro de la CNCF es responsable de aprobar el paso de un proyecto de un nivel de madurez a otro?
- Un proyecto Sandbox recién aceptado, ¿ya es un "CNCF project" o todavía no?

---

## Ejercicio 3: Governance de un proyecto real

1. Abrí [github.com/kubernetes/community](https://github.com/kubernetes/community).
2. Buscá el archivo `governance.md` en la raíz del repo y abrilo.
3. Identificá qué rol cumple el **Steering Committee** de Kubernetes.
4. Dentro del mismo repo, navegá a la carpeta `sig-list.md` y contá cuántos **SIGs (Special Interest Groups)** activos aparecen listados (ejemplo: sig-network, sig-storage, sig-cli).
5. Elegí un SIG (por ejemplo `sig-node`) y ubicá su `README.md` para ver su charter (alcance de responsabilidad).

**Preguntas de comprensión:**
- ¿Qué diferencia hay entre un SIG y un **Working Group** dentro de la governance de Kubernetes?
- ¿Por qué un proyecto de la escala de Kubernetes necesita subdividir su comunidad en SIGs en vez de tener un único grupo de decisión?

---

## Ejercicio 4: Personas de la comunidad cloud native

1. Andá a [github.com/cncf/toc/blob/main/process/dei-glossary.md](https://github.com/cncf/toc) (o buscá "personas" en la documentación de cualquier CNCF project, por ejemplo en `CONTRIBUTING.md` de Kubernetes).
2. Abrí [kubernetes.io/community](https://kubernetes.io/community) y ubicá la sección que describe cómo empezar a contribuir.
3. Distinguí, según lo que leas, al menos tres personas típicas en un proyecto open source cloud native: **end user**, **contributor** y **maintainer**.
4. Buscá en el repo de Kubernetes el archivo `OWNERS` de cualquier subdirectorio (por ejemplo `staging/src/k8s.io/api/OWNERS`) y observá las secciones `approvers` y `reviewers`.

**Preguntas de comprensión:**
- ¿Qué diferencia de responsabilidad hay entre un `reviewer` y un `approver` según el archivo `OWNERS`?
- ¿Puede un end user convertirse en maintainer sin pasar por el rol de contributor? Justificá según el flujo típico que observaste.

---

## Ejercicio 5: Licencias open source

1. Elegí tres repositorios de proyectos CNCF: [github.com/kubernetes/kubernetes](https://github.com/kubernetes/kubernetes), [github.com/prometheus/prometheus](https://github.com/prometheus/prometheus) y [github.com/envoyproxy/envoy](https://github.com/envoyproxy/envoy).
2. En cada uno, abrí el archivo `LICENSE` desde la raíz del repositorio.
3. Identificá qué licencia usa cada proyecto.
4. Con `curl`, descargá el archivo de licencia de uno de ellos y contá cuántas líneas tiene:
   ```bash
   curl -s https://raw.githubusercontent.com/kubernetes/kubernetes/master/LICENSE | wc -l
   ```
5. Buscá en esa licencia la cláusula relacionada con **patent grant** (cesión de patentes).

**Preguntas de comprensión:**
- ¿Por qué la CNCF exige que todos sus proyectos Graduated e Incubating usen la **Apache License 2.0** (o una licencia compatible) en vez de dejar la elección libre?
- ¿Qué diferencia práctica tiene una licencia permisiva como Apache 2.0 frente a una copyleft como GPL, en el contexto de adopción empresarial?

---

## Ejercicio 6: Eventos y certificaciones de la comunidad

1. Andá a [community.cncf.io](https://community.cncf.io) o a la página de eventos en [cncf.io](https://www.cncf.io/).
2. Ubicá información sobre **KubeCon + CloudNativeCon**, el evento insignia de la CNCF.
3. Andá a [training.linuxfoundation.org](https://training.linuxfoundation.org) y buscá el listado de certificaciones cloud native ofrecidas por la Linux Foundation en conjunto con la CNCF (por ejemplo KCNA, CKA, CKAD, CKS).
4. Identificá qué organización emite estas certificaciones: ¿la CNCF directamente o la Linux Foundation?

**Preguntas de comprensión:**
- ¿Qué rol cumple un evento como KubeCon en el modelo de colaboración de la comunidad, más allá de ser una conferencia?
- ¿Qué relación institucional existe entre la CNCF y la Linux Foundation?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- El landscape incluye proyectos CNCF y también software de terceros (open source o comercial) relevante para el ecosistema cloud native, aunque no sea propiedad ni esté bajo governance de la CNCF. Un "CNCF project" es específicamente aquel que fue donado formalmente a la fundación y tiene un nivel de madurez asignado (Sandbox, Incubating, Graduated).
- Porque el objetivo del landscape es ayudar a usuarios y arquitectos a orientarse en todo el ecosistema cloud native, no solo en el catálogo propio de la fundación — es una herramienta de referencia de mercado, no un catálogo de propiedad.

**Ejercicio 2**
- El **TOC (Technical Oversight Committee)** es el organismo que evalúa y aprueba las transiciones de madurez de un proyecto (aceptación a Sandbox, promoción a Incubating, promoción a Graduated).
- Sí, ya es un CNCF project desde el momento en que es aceptado en Sandbox, aunque con el nivel de madurez y garantías más bajo de los tres.

**Ejercicio 3**
- Un SIG (Special Interest Group) tiene una responsabilidad permanente y de largo plazo sobre un área del proyecto (ejemplo: sig-storage). Un Working Group es temporal, se crea para resolver un problema específico que suele cruzar varios SIGs, y se disuelve al completar su objetivo.
- Porque a esa escala ningún grupo único puede tener el contexto técnico necesario para revisar cambios en todas las áreas (networking, storage, API machinery, etc.); dividir en SIGs permite que expertos de cada dominio tomen decisiones informadas y distribuye la carga de revisión y mantenimiento.

**Ejercicio 4**
- El `reviewer` puede revisar y aprobar la calidad técnica de un cambio (`/lgtm`), pero no tiene autoridad para fusionarlo. El `approver` tiene la autoridad final para aprobar el merge (`/approve`), asumiendo responsabilidad sobre el impacto del cambio en esa parte del código.
- Sí puede, pero normalmente sigue una progresión: primero contribuye (PRs, issues, revisiones), gana confianza y visibilidad en el SIG correspondiente, y eventualmente es propuesto como reviewer y luego approver/maintainer. Saltar directamente de end user a maintainer sin pasar por contribuciones sería atípico y no sigue el flujo de meritocracia que usan estos proyectos.

**Ejercicio 5**
- Porque Apache 2.0 es una licencia permisiva que incluye una cesión explícita de patentes (patent grant), lo cual da certeza legal a empresas que quieren adoptar y contribuir sin riesgo de litigios de patentes. Uniformar la licencia en todos los proyectos CNCF reduce la fricción legal para adoptantes empresariales y facilita la combinación de código entre proyectos.
- Apache 2.0 permite usar, modificar y redistribuir el código (incluso en productos comerciales cerrados) sin obligación de liberar el código derivado. GPL es copyleft: cualquier trabajo derivado distribuido debe heredar la misma licencia y liberar su código fuente. Las empresas suelen preferir licencias permisivas como Apache 2.0 porque no las obliga a abrir su propio código.

**Ejercicio 6**
- KubeCon + CloudNativeCon funciona como punto de encuentro presencial de la comunidad: ahí se coordinan SIGs, se hacen anuncios de graduación de proyectos, se dictan talks técnicos y contributor summits, y se fortalece la colaboración entre maintainers, contributors y end users que normalmente interactúan solo de forma asincrónica por GitHub/Slack.
- La CNCF es una fundación bajo el paraguas de la Linux Foundation. La Linux Foundation es la entidad legal que administra la infraestructura, los programas de certificación y los eventos, mientras que la CNCF es la fundación específica enfocada en el ecosistema cloud native dentro de ese paraguas mayor.

</details>