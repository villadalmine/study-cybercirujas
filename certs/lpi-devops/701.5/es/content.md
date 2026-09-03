# 701.5 — Composición de software, licenciamiento y open source

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, versión 2.0.0
**Peso del tema:** 3.34
**Perfil:** Principal Platform Architect / Senior SRE
**Idioma de autoría:** inglés (términos técnicos sin traducir)

---

## 1. El problema en producción: no se puede parchear lo que no se puede enumerar

### 1.1 El incidente que define este objetivo

A las 17:26 UTC del 9 de diciembre de 2021, CVE-2021-44228 (Log4Shell) se hizo público. El artefacto vulnerable era `org.apache.logging.log4j:log4j-core` en las versiones `2.0-beta9` a `2.14.1`. Casi ninguna organización lo tenía como dependencia **directa**. Llegaba como dependencia transitiva de clientes de Elasticsearch, productores de Kafka, starters de Spring Boot, Solr, appenders de Logstash y —lo peor de todo— como clases *shaded* dentro de fat JARs, donde la coordenada `log4j-core` ya no aparece en ningún lado del disco.

La pregunta de ingeniería era trivial de enunciar y, para la mayoría de las organizaciones, llevó **días o semanas** responderla:

> ¿Cuáles de las 1.400 imágenes de contenedor que hoy corren en nuestros clústeres contienen `log4j-core` en una versión inferior a 2.17.1, y cuáles de ellas son alcanzables desde internet?

Dos años después, CVE-2024-3094 (el backdoor de `xz-utils` / `liblzma`, versiones 5.6.0 y 5.6.1) repitió el ejercicio en la capa de paquetes del sistema operativo en lugar de la capa del lenguaje, y las mismas organizaciones descubrieron que tenían inventario de una capa pero no de la otra.

La falla arquitectónica no es «no parcheamos lo bastante rápido». Es que **el inventario se calculó en el momento del incidente en lugar de en el momento de la compilación**. Responder la pregunta exigía volver a derivar, para cada artefacto, una resolución de dependencias que el sistema de build ya había realizado y luego descartado.

### 1.2 El segundo modo de falla: licenciamiento

El mismo inventario faltante produce una segunda clase de incidente en producción, con una mecha más lenta y un radio de daño mayor:

* Un equipo de plataforma incorpora (vendoriza) una librería AGPL-3.0 dentro de un control plane SaaS. La GPL-3.0 §13, tal como la incorpora la AGPL-3.0, exige que a los usuarios **que interactúan con el programa a través de una red** se les ofrezca el Corresponding Source, incluidas tus modificaciones. No existe la defensa de «no distribuimos un binario».
* Un equipo entrega una imagen de appliance instalable por el cliente, basada en `debian:bookworm-slim`. Esa imagen transmite `bash`, `coreutils`, `util-linux`, `libc6` — obras GPL-2.0/GPL-3.0 y LGPL-2.1. La GPL-2.0 §3 exige que la transmisión vaya acompañada del código fuente o de una **oferta escrita válida por tres años**. Nadie escribió la oferta.
* Un proveedor relicencia bajo BUSL-1.1 o SSPL-1.0. Ninguna de las dos es una licencia open source aprobada por la OSI. La rama `main` a la que te habías fijado sigue compilando; las obligaciones de licencia cambiaron en silencio en la frontera de un tag.

La exposición legal y la exposición a vulnerabilidades se responden con **el mismo artefacto**: un inventario resuelto, firmado y legible por máquina de todo lo que hay dentro de aquello que entregaste. Ese artefacto es el **SBOM** (Software Bill of Materials), y producirlo, firmarlo, almacenarlo y consultarlo es lo que evalúa 701.5.

### 1.3 El objetivo arquitectónico

```
                 ┌────────────────────────────────────────────────────┐
   source        │  BUILD (the only place resolution is authoritative)│
   + lockfile ──►│  compile ─► SBOM(build) ─► sign ─► attest          │
                 └───────────────┬────────────────────────────────────┘
                                 │  OCI artifact + in-toto/DSSE attestations
                                 ▼
                 ┌────────────────────────────────────────────────────┐
   registry      │  image@sha256:…                                     │
                 │    ├─ .sbom      (SPDX / CycloneDX)                 │
                 │    ├─ .att       (SLSA provenance)                  │
                 │    └─ .vex       (OpenVEX statements)               │
                 └───────────────┬────────────────────────────────────┘
                                 │
              ┌──────────────────┼────────────────────┐
              ▼                  ▼                    ▼
   ┌────────────────┐  ┌──────────────────┐  ┌─────────────────────┐
   │ Dependency-Track│  │ Admission control│  │ Continuous re-scan  │
   │ (queryable      │  │ (Kyverno verify  │  │ (new CVE ⇒ re-match │
   │  inventory DB)  │  │  attestations)   │  │  old SBOMs)         │
   └────────────────┘  └──────────────────┘  └─────────────────────┘
```

La propiedad que importa: en el momento del incidente la consulta es **O(1) contra una base de datos**, no O(N) contra N pipelines de build. El SBOM se genera una sola vez, en el momento en que los hechos se conocen, y a partir de ahí es inmutable y firmado.

### 1.4 Dónde generar el SBOM — el compromiso central

| Punto de generación | Mecanismo | Ve deps directas | Ve deps transitivas | Ve paquetes de OS | Ve lo que realmente se entrega | Ve deps solo de build | Herramientas típicas |
|---|---|---|---|---|---|---|---|
| **Fuente / manifiesto** | parsear `package.json`, `pom.xml`, `go.mod` | ✅ | ⚠️ solo si hay lockfile | ❌ | ❌ (declarado ≠ resuelto) | ✅ | `osv-scanner`, `cdxgen`, Dependabot |
| **Lockfile** | parsear `package-lock.json`, `poetry.lock`, `go.sum`, `Cargo.lock` | ✅ | ✅ versiones exactas | ❌ | ⚠️ incluye dev deps | ✅ | `osv-scanner`, `syft`, `trivy fs` |
| **Sistema de build** | plugin dentro de Maven/Gradle/Bazel | ✅ | ✅ con scopes y classifiers | ❌ | ✅ para ese lenguaje | ✅ | `cyclonedx-maven-plugin`, `cyclonedx-gradle-plugin`, `cdxgen` |
| **Binario / imagen** | catalogación de filesystem + DB de paquetes | ✅ | ✅ | ✅ | ✅ **la verdad tal como se entrega** | ❌ | `syft`, `trivy image` |
| **Runtime** | eBPF / introspección de procesos | ✅ | ✅ | ✅ | ✅ + solo lo cargado | ❌ | Trivy Operator, herramientas del estilo de Falco |

**Recomendación para producción:** generar **dos** SBOM y adjuntar ambos.

1. Un **SBOM de build** producido por el sistema de build: es la única fuente que conoce el *scope* de las dependencias (compile vs test vs provided), los classifiers resueltos y las coordenadas shaded/relocalizadas.
2. Un **SBOM de imagen** producido por `syft`/`trivy` sobre el artefacto final: es la única fuente que sabe qué arrastró la imagen base.

Fusionarlos es un problema resuelto (`cyclonedx-cli merge`, `syft ... --catalogers`); pretender que uno sustituye al otro es el error arquitectónico más común en este terreno. Un SBOM de build se pierde `libssl3`; un SBOM de imagen se pierde las clases de `log4j-core` shaded.

---

## 2. Licenciamiento open source para ingenieros de plataforma

### 2.1 La Open Source Definition no es «podés ver el código»

La **Open Source Definition** de la OSI tiene diez criterios; los que generan decisiones en producción son:

1. Redistribución libre (sin regalías por la venta de agregados)
3. Deben permitirse las obras derivadas, redistribuibles bajo los mismos términos
5. Sin discriminación contra personas o grupos
6. **Sin discriminación contra campos de actividad** — esta es la cláusula que SSPL-1.0, BUSL-1.1 y Elastic-2.0 incumplen
7. La licencia viaja con el programa, sin necesidad de un NDA aparte
9. La licencia no debe restringir otro software distribuido junto a ella

«Source-available» ≠ «open source». Un archivo `LICENSE` no es evidencia de una licencia aprobada por la OSI; el identificador SPDX sí.

### 2.2 Taxonomía de licencias con consecuencias en producción

| Identificador SPDX | Clase | Alcance del copyleft | Disparador | Concesión explícita de patentes | Riesgo práctico en una imagen de contenedor | Riesgo práctico en SaaS |
|---|---|---|---|---|---|---|
| `MIT`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC` | Permisiva | ninguno | — | ❌ (implícita como mucho) | Deben entregarse el aviso y el copyright | ninguno |
| `Apache-2.0` | Permisiva | ninguno | — | ✅ §3, con terminación por represalia | Aviso + archivo `NOTICE` + registro de cambios (§4) | ninguno |
| `MPL-2.0` | Copyleft débil | **por archivo** | distribución de archivos modificados | ✅ §2.1(b) | hay que publicar solo los archivos modificados | ninguno (no hay cláusula de red) |
| `EPL-2.0` | Copyleft débil | por módulo | distribución | ✅ | fuente del módulo modificado | ninguno, salvo aviso de licencia secundaria GPL |
| `LGPL-2.1-only` / `LGPL-3.0-only` | Copyleft débil | frontera de la librería | distribución | 3.0 ✅ / 2.1 ❌ | enlace **dinámico** OK; enlace **estático** exige entregar objetos re-enlazables | ninguno |
| `GPL-2.0-only` | Copyleft fuerte | toda la obra derivada | transmisión (conveying) | ❌ | la imagen transmite GPL ⇒ oferta de fuente §3 | ninguno |
| `GPL-3.0-only` | Copyleft fuerte | toda la obra derivada | transmisión | ✅ §11 | + §6 información de instalación para «User Products» | ninguno |
| `AGPL-3.0-only` | Copyleft de red | toda la obra derivada | transmisión **o interacción por red** | ✅ | igual que GPL-3.0 | 🔴 **§13: fuente para los usuarios remotos** |
| `CDDL-1.0` | Copyleft débil | por archivo | distribución | ✅ | ⚠️ FSF: incompatible con GPL-2.0 | ninguno |
| `SSPL-1.0` | No OSI | todo el servicio | ofrecerlo como servicio | ✅-ish | 🔴 | 🔴 §13: todo el código de gestión del servicio |
| `BUSL-1.1` | No OSI (source-available) | n/a | uso en producción | ❌ | 🔴 restricción de campo de uso hasta la Change Date | 🔴 |
| `Elastic-2.0` | No OSI | n/a | proveerlo como servicio gestionado | ❌ | 🔴 | 🔴 |

### 2.3 Compatibilidad: la dirección importa

La compatibilidad de licencias es **direccional**. «¿Puedo combinar A y B y distribuir el resultado bajo B?» es una pregunta distinta de «…bajo A?».

| Componente entrante | Obra combinada distribuida bajo → | `MIT` | `Apache-2.0` | `MPL-2.0` | `GPL-2.0-only` | `GPL-3.0-or-later` | `AGPL-3.0` | Propietaria |
|---|---|---|---|---|---|---|---|---|
| `MIT` | | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `Apache-2.0` | | ❌ | ✅ | ✅ | ❌ ¹ | ✅ | ✅ | ✅ |
| `MPL-2.0` | | ❌ | ❌ | ✅ | ✅ ² | ✅ ² | ✅ ² | ✅ ³ |
| `LGPL-2.1-only` | | ❌ | ❌ | ❌ | ✅ | ❌ ⁴ | ❌ ⁴ | ✅ ³ |
| `GPL-2.0-only` | | ❌ | ❌ | ❌ | ✅ | ❌ ⁵ | ❌ ⁵ | ❌ |
| `GPL-2.0-or-later` | | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ❌ |
| `GPL-3.0-only` | | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| `CDDL-1.0` | | ❌ | ❌ | ❌ | ❌ ⁶ | ❌ ⁶ | ❌ ⁶ | ✅ ³ |

¹ Posición de la FSF: los términos de terminación de patentes e indemnización de Apache-2.0 son restricciones adicionales bajo la GPL-2.0 §6. Es compatible con GPL-3.0 porque su §7 permite esos términos adicionales.
² Vía la cláusula de «Secondary Licenses» de MPL-2.0 §3.3 — **salvo** que el archivo lleve el aviso «Incompatible With Secondary Licenses» (Exhibit B).
³ Copyleft débil: la combinación propietaria está bien siempre que el código de los archivos cubiertos esté disponible y (para el enlace estático LGPL) el re-enlazado sea posible.
⁴ LGPL-2.1-**only** carece de la vía de actualización «or later»; `LGPL-2.1-or-later` sube limpiamente a LGPL-3.0/GPL-3.0.
⁵ La razón por la que `GPL-2.0-only` vs `GPL-2.0-or-later` es un **identificador SPDX distinto** y no un detalle de formato. Linux es GPL-2.0-only.
⁶ La situación de ZFS-on-Linux: copyleft por archivo con términos que la GPL considera restricciones adicionales.

> **Nota de examen y de producción:** los identificadores SPDX obsoletos `GPL-2.0` y `GPL-2.0+` todavía aparecen en metadatos antiguos. Son ambiguos. Los identificadores actuales son `GPL-2.0-only` y `GPL-2.0-or-later`.

### 2.4 Expresiones de licencia SPDX

Los motores de políticas sobre SBOM hacen matching sobre **expresiones**, no sobre texto libre. La gramática:

```
expression   := simple | compound
simple       := <SPDX-id> | <SPDX-id>"+" | "LicenseRef-"<idstring>
compound     := simple "WITH" <exception-id>
              | expression "AND" expression
              | expression "OR" expression
              | "(" expression ")"
```

Expresiones del mundo real que vas a encontrar y tenés que manejar:

| Expresión | Significado | Tratamiento en la política |
|---|---|---|
| `Apache-2.0` | licencia única | trivial |
| `MIT OR Apache-2.0` | **elige el licenciatario** — el default del ecosistema Rust/Go | la política puede quedarse con la rama permitida |
| `GPL-2.0-only AND MIT` | aplican **ambas** simultáneamente | hay que satisfacer la más estricta |
| `GPL-2.0-only WITH Classpath-exception-2.0` | OpenJDK: la excepción de enlace elimina el alcance del copyleft sobre el classpath | ⚠️ una regla ingenua de `contains("GPL")` bloquea el JDK por error |
| `LGPL-2.1-or-later WITH LLVM-exception` | | ídem |
| `GPL-3.0-or-later WITH GCC-exception-3.1` | runtime de libgcc/libstdc++ | ídem |
| `LicenseRef-Proprietary-Acme` | licencia no SPDX, definida en `hasExtractedLicensingInfos` del SBOM | debe estar explícitamente en lista de permitidas o denegadas |
| `NOASSERTION` | la herramienta no pudo determinarla | **no** es «permisiva»; tratala como desconocido bloqueante |

El bug de política más dañino de este dominio es tratar `OR` como `AND` (bloquear `MIT OR Apache-2.0` porque una de las ramas no está permitida) o hacer matching por subcadena sobre `GPL` (bloquear toda imagen con JVM por culpa de la Classpath Exception).

### 2.5 Transmitir una imagen de contenedor *es* distribución

Una imagen `FROM debian:bookworm-slim` publicada en un registry público o de cara al cliente transmite binarios licenciados bajo GPL. Obligaciones que hay que implementar de verdad:

* **Los avisos deben viajar con el artefacto.** Debian los guarda en `/usr/share/doc/<pkg>/copyright`; las imágenes `debian:*-slim` los **conservan**, pero muchos Dockerfiles «optimizados» borran `/usr/share/doc`. Ese borrado es una regresión de cumplimiento, no una optimización de tamaño.
* **Oferta de código fuente.** La GPL-2.0 §3(b) permite una oferta escrita válida por tres años; la GPL-3.0 §6(b) igual, o §6(d) un servidor de descarga de acceso equivalente. Apoyarse en «Debian publica el código» es común, pero la oferta es *tuya*, no de Debian.
* **Apache-2.0 §4(d):** si la obra upstream tiene un archivo `NOTICE`, su contenido debe reproducirse en tu distribución.

Implementación práctica: hornear los avisos dentro de la imagen en tiempo de build:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim AS licenses
RUN set -eu; \
    mkdir -p /out/licenses; \
    for d in /usr/share/doc/*/copyright; do \
        pkg="$(basename "$(dirname "$d")")"; \
        install -Dm0444 "$d" "/out/licenses/os/$pkg.copyright"; \
    done; \
    dpkg-query -W -f='${Package}\t${Version}\t${Source}\n' > /out/licenses/os/packages.tsv

FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=true \
      -ldflags="-s -w -X main.version=${VERSION:-dev}" \
      -o /out/payments-api ./cmd/payments-api
# go-licenses emits the full text of every module's licence
RUN go install github.com/google/go-licenses@latest && \
    go-licenses save ./cmd/payments-api --save_path=/out/licenses/go && \
    go-licenses report ./cmd/payments-api --template=/dev/null > /out/licenses/go/report.csv 2>/dev/null || \
    go-licenses csv ./cmd/payments-api > /out/licenses/go/report.csv

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build  /out/payments-api          /usr/local/bin/payments-api
COPY --from=build  /out/licenses/go           /usr/share/licenses/go
COPY --from=licenses /out/licenses/os         /usr/share/licenses/os
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/payments-api"]
```

### 2.6 Política de contribuciones entrantes: DCO vs CLA

| | **DCO** (Developer Certificate of Origin 1.1) | **CLA** (Contributor Licence Agreement) |
|---|---|---|
| Instrumento | Una certificación de ~200 palabras, firmada por commit | Un contrato firmado una vez por contribuyente/empleador |
| Mecanismo | `git commit -s` → trailer `Signed-off-by:` | Formulario web / bot de CLA, fuera de banda |
| Concede | Nada más allá de la licencia del proyecto — *afirma la procedencia* | Licencia de copyright (a menudo amplia) ± concesión de patentes; variantes ICLA/CCLA |
| Habilita relicenciar | ❌ | ✅ (normalmente ese es el punto) |
| Fricción para el contribuyente | Muy baja | Alta — revisión legal, CCLA corporativo |
| Aplicación | `git interpret-trailers`, DCO GitHub App, `gitlint` | bot CLA-assistant bloqueando el PR |
| Usado por | Kernel de Linux, Kubernetes/CNCF, Docker, GitLab | Apache Software Foundation (ICLA/CCLA), muchos proyectos liderados por proveedores |

Aplicar DCO en CI sin una app de terceros:

```bash
$ git log --format='%H %s%n%b' origin/main..HEAD | grep -c '^Signed-off-by: '
0
$ git rebase --signoff origin/main
Successfully rebased and updated refs/heads/feature/sbom-attest.
$ git log -1 --format='%B'
feat(ci): attach CycloneDX SBOM as a cosign attestation

Signed-off-by: Ada Lovelace <ada@example.org>
```

### 2.7 REUSE: hacer el licenciamiento legible por máquina a nivel de archivo

La Especificación REUSE de la FSFE exige que cada archivo declare `SPDX-FileCopyrightText` y `SPDX-License-Identifier`, ya sea en línea, en un archivo `.license` adjunto o en `REUSE.toml`.

```toml
# REUSE.toml
version = 1
SPDX-PackageName = "payments-api"
SPDX-PackageSupplier = "Acme Platform Team <platform@acme.example>"
SPDX-PackageDownloadLocation = "https://github.com/acme/payments-api"

[[annotations]]
path = "vendor/**"
precedence = "aggregate"
SPDX-FileCopyrightText = "NONE"
SPDX-License-Identifier = "NOASSERTION"

[[annotations]]
path = ["docs/**", "**.md"]
precedence = "aggregate"
SPDX-FileCopyrightText = "2026 Acme Corp"
SPDX-License-Identifier = "CC-BY-SA-4.0"

[[annotations]]
path = ["deploy/**.yaml", "**.go", "Makefile"]
precedence = "aggregate"
SPDX-FileCopyrightText = "2026 Acme Corp"
SPDX-License-Identifier = "Apache-2.0"
```

```bash
$ reuse lint
# MISSING COPYRIGHT AND LICENSING INFORMATION

The following files have no copyright and licensing information:
* scripts/rotate-keys.sh
* internal/telemetry/otel.go

# SUMMARY

* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: Apache-2.0, CC-BY-SA-4.0
* Read errors: 0
* Files with copyright information: 214 / 216
* Files with license information: 214 / 216

Unfortunately, your project is not compliant with version 3.3 of the REUSE Specification :-(

$ reuse annotate --copyright="2026 Acme Corp" --license="Apache-2.0" \
      scripts/rotate-keys.sh internal/telemetry/otel.go
Successfully changed header of scripts/rotate-keys.sh
Successfully changed header of internal/telemetry/otel.go

$ reuse lint && echo "REUSE OK"
...
Congratulations! Your project is compliant with version 3.3 of the REUSE Specification :-)
REUSE OK
```

---

## 3. Formatos de SBOM

### 3.1 Comparación de formatos

| | **SPDX** | **CycloneDX** | **SWID** |
|---|---|---|---|
| Custodio | Linux Foundation / proyecto SPDX | OWASP Foundation | ISO/IEC 19770-2:2015 |
| Estándar | **ISO/IEC 5962:2021** (SPDX 2.2.1) | **ECMA-424** (CycloneDX 1.6) | ISO/IEC |
| Versiones actuales | 2.3 (JSON/tag-value/RDF/YAML/xlsx), 3.0 (JSON-LD) | 1.5 / 1.6 (JSON, XML, Protobuf) | tags XML |
| Sesgo de origen | Cumplimiento de licencias primero | Seguridad / cadena de suministro primero | Gestión de activos |
| Modelo de expresión de licencia | Rico: `licenseConcluded` vs `licenseDeclared`, `hasExtractedLicensingInfos` | `licenses[]` con `expression` o `id`/`name` | limitado |
| Grafo de dependencias | `relationships[]` — más de 40 relaciones tipadas | `dependencies[]` — `dependsOn` / `provides` | ❌ |
| Vulnerabilidades dentro del BOM | ❌ (perfil de seguridad SPDX aparte en 3.0) | ✅ `vulnerabilities[]` desde 1.4 | ❌ |
| VEX | externo (OpenVEX / CSAF) | ✅ perfil VEX nativo | ❌ |
| Inventario de servicios | ❌ | ✅ `services[]` | ❌ |
| Formulación / procedencia de build | parcial | ✅ `formulation` (1.5+) | ❌ |
| Activos criptográficos (CBOM) | ❌ | ✅ 1.6 | ❌ |
| Modelos de ML (MLBOM) | parcial | ✅ 1.5 `modelCard` | ❌ |
| Atestaciones / declaraciones | ❌ | ✅ 1.6 `declarations` | ❌ |
| Tamaño típico (imagen de 500 paquetes) | ~1,4 MB JSON | ~600 KB JSON | n/a |
| Mejor encaje | legal/OSPO, gobierno (elementos mínimos NTIA) | herramientas de seguridad, Dependency-Track | inventario de activos en endpoints |

**Decisión:** emitir **ambos**. `syft` produce los dos con una sola pasada de catalogación, a costo marginal esencialmente nulo, y los consumidores difieren: Dependency-Track y Trivy prefieren CycloneDX; compras, el ámbito federal de EE. UU. (EO 14028) y los flujos del CRA europeo prefieren SPDX.

### 3.2 Los elementos mínimos de la NTIA (qué debe contener un SBOM conforme)

| Elemento | Campo SPDX 2.3 | Campo CycloneDX 1.6 |
|---|---|---|
| Nombre del proveedor | `packages[].supplier` | `components[].supplier.name` |
| Nombre del componente | `packages[].name` | `components[].name` |
| Versión del componente | `packages[].versionInfo` | `components[].version` |
| Otros identificadores únicos | `packages[].externalRefs` (purl, cpe23Type) | `components[].purl`, `.cpe`, `.bom-ref` |
| Relación de dependencia | `relationships[]` | `dependencies[]` |
| Autor de los datos del SBOM | `creationInfo.creators` | `metadata.tools`, `metadata.authors` |
| Marca de tiempo | `creationInfo.created` | `metadata.timestamp` |

### 3.3 Package URL (purl) — la clave de join de todo el ecosistema

```
pkg:type/namespace/name@version?qualifiers#subpath
```

| purl | Capa |
|---|---|
| `pkg:golang/github.com/gorilla/mux@v1.8.1` | módulo Go |
| `pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1` | Maven |
| `pkg:npm/%40acme/telemetry@3.2.0` | npm con scope (`@` va percent-encoded) |
| `pkg:pypi/urllib3@2.2.1` | PyPI |
| `pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12` | paquete Debian |
| `pkg:apk/alpine/busybox@1.36.1-r29?arch=x86_64&distro=alpine-3.20` | paquete Alpine |
| `pkg:oci/payments-api@sha256:9f2b…?repository_url=ghcr.io/acme/payments-api&tag=1.24.3` | la imagen en sí |
| `pkg:generic/openssl@3.0.15?download_url=https://…&checksum=sha256:…` | tarball vendorizado |

**CPE** (`cpe:2.3:a:apache:log4j:2.14.1:*:*:*:*:*:*:*`) es el identificador de la NVD. Es con pérdida, se asigna de forma ambigua y falta con frecuencia — pero el matching basado en la NVD lo requiere. Esta es la causa raíz de toda una clase de falsos negativos (§8.6).

### 3.4 Un documento SPDX 2.3 real (abreviado a dos paquetes, estructuralmente completo)

```json
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "ghcr.io/acme/payments-api:1.24.3",
  "documentNamespace": "https://acme.example/spdx/payments-api-1.24.3-4c1f9b2e-6a77-4f0b-9b3a-8d2c1e5f7a10",
  "creationInfo": {
    "created": "2026-09-03T09:14:22Z",
    "creators": [
      "Tool: syft-1.29.0",
      "Organization: Acme Corp",
      "Person: Acme Platform Team (platform@acme.example)"
    ],
    "licenseListVersion": "3.25"
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-golang-github.com-gorilla-mux-1b3f0c9d2a44e517",
      "name": "github.com/gorilla/mux",
      "versionInfo": "v1.8.1",
      "supplier": "NOASSERTION",
      "downloadLocation": "https://proxy.golang.org/github.com/gorilla/mux/@v/v1.8.1.zip",
      "filesAnalyzed": false,
      "licenseConcluded": "BSD-3-Clause",
      "licenseDeclared": "BSD-3-Clause",
      "copyrightText": "NOASSERTION",
      "checksums": [
        { "algorithm": "SHA256",
          "checksumValue": "9dc7f6d21e4d1b9ce8e1a1e4a4a0f9a0a3c5f9e2b7c1d0a8f3e6b4c2d1a0f9e8" }
      ],
      "externalRefs": [
        { "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:golang/github.com/gorilla/mux@v1.8.1" }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-deb-libssl3-7ad2e91c4b60fa38",
      "name": "libssl3",
      "versionInfo": "3.0.15-1~deb12u1",
      "supplier": "Organization: Debian OpenSSL Team <pkg-openssl-devel@lists.alioth.debian.org>",
      "originator": "Organization: Debian",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "NOASSERTION",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "NOASSERTION",
      "sourceInfo": "acquired package info from DPKG DB: /var/lib/dpkg/status.d/libssl3",
      "externalRefs": [
        { "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12" },
        { "referenceCategory": "SECURITY",
          "referenceType": "cpe23Type",
          "referenceLocator": "cpe:2.3:a:openssl:openssl:3.0.15-1~deb12u1:*:*:*:*:*:*:*" }
      ]
    }
  ],
  "relationships": [
    { "spdxElementId": "SPDXRef-DOCUMENT",
      "relationshipType": "DESCRIBES",
      "relatedSpdxElement": "SPDXRef-Package-oci-payments-api" },
    { "spdxElementId": "SPDXRef-Package-oci-payments-api",
      "relationshipType": "CONTAINS",
      "relatedSpdxElement": "SPDXRef-Package-golang-github.com-gorilla-mux-1b3f0c9d2a44e517" },
    { "spdxElementId": "SPDXRef-Package-oci-payments-api",
      "relationshipType": "CONTAINS",
      "relatedSpdxElement": "SPDXRef-Package-deb-libssl3-7ad2e91c4b60fa38" }
  ],
  "hasExtractedLicensingInfos": [
    { "licenseId": "LicenseRef-Acme-Internal",
      "extractedText": "Copyright 2026 Acme Corp. Internal use only. Redistribution prohibited.",
      "name": "Acme Internal Licence" }
  ]
}
```

### 3.5 El mismo inventario como CycloneDX 1.6

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "serialNumber": "urn:uuid:4c1f9b2e-6a77-4f0b-9b3a-8d2c1e5f7a10",
  "version": 1,
  "metadata": {
    "timestamp": "2026-09-03T09:14:22Z",
    "lifecycles": [ { "phase": "build" } ],
    "tools": {
      "components": [
        { "type": "application", "author": "anchore", "name": "syft", "version": "1.29.0" }
      ]
    },
    "authors": [ { "name": "Acme Platform Team", "email": "platform@acme.example" } ],
    "supplier": { "name": "Acme Corp", "url": [ "https://acme.example" ] },
    "component": {
      "bom-ref": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e",
      "type": "container",
      "name": "ghcr.io/acme/payments-api",
      "version": "1.24.3",
      "purl": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api",
      "hashes": [
        { "alg": "SHA-256",
          "content": "9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e" }
      ],
      "licenses": [ { "license": { "id": "Apache-2.0" } } ]
    }
  },
  "components": [
    {
      "bom-ref": "pkg:golang/github.com/gorilla/mux@v1.8.1",
      "type": "library",
      "name": "github.com/gorilla/mux",
      "version": "v1.8.1",
      "scope": "required",
      "purl": "pkg:golang/github.com/gorilla/mux@v1.8.1",
      "licenses": [ { "license": { "id": "BSD-3-Clause" } } ],
      "externalReferences": [
        { "type": "vcs", "url": "https://github.com/gorilla/mux" }
      ]
    },
    {
      "bom-ref": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
      "type": "library",
      "group": "org.apache.logging.log4j",
      "name": "log4j-core",
      "version": "2.14.1",
      "scope": "required",
      "purl": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
      "licenses": [ { "expression": "Apache-2.0" } ]
    },
    {
      "bom-ref": "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12",
      "type": "library",
      "name": "libssl3",
      "version": "3.0.15-1~deb12u1",
      "purl": "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12",
      "cpe": "cpe:2.3:a:openssl:openssl:3.0.15:*:*:*:*:*:*:*",
      "licenses": [ { "license": { "id": "Apache-2.0" } } ]
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e",
      "dependsOn": [
        "pkg:golang/github.com/gorilla/mux@v1.8.1",
        "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1",
        "pkg:deb/debian/libssl3@3.0.15-1~deb12u1?arch=amd64&distro=debian-12"
      ]
    },
    { "ref": "pkg:golang/github.com/gorilla/mux@v1.8.1", "dependsOn": [] }
  ],
  "compositions": [
    {
      "aggregate": "complete",
      "bom-ref": "composition-os-layer",
      "assemblies": [
        "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"
      ]
    }
  ]
}
```

> `compositions[].aggregate` es el campo de la honestidad: `complete`, `incomplete`, `incomplete_first_party_only`, `incomplete_third_party_only`, `unknown`, `not_specified`. Un SBOM que lo omite reclama en silencio una completitud que no puede demostrar.

---

## 4. El panorama de herramientas

### 4.1 Comparación

| Herramienta | Trabajo principal | Entrada | Salida | Detección de licencias | DB de vulnerabilidades | Modo offline | Dónde encaja |
|---|---|---|---|---|---|---|---|
| **syft** | generación de SBOM | imagen, directorio, archivo, OCI layout | SPDX 2.3/3.0, CycloneDX 1.x, syft-json, tabla | solo declaradas, a nivel de metadatos de paquete | ❌ | ✅ | etapa de build |
| **grype** | matching de vulnerabilidades | SBOM, imagen, directorio | tabla, JSON, SARIF, CycloneDX | ❌ | feeds de GitHub/NVD/distros, DB local | ✅ `grype db import` | etapa de gate |
| **trivy** | escáner todo en uno | imagen, fs, repo, SBOM, K8s, IaC | tabla, JSON, SARIF, SPDX, CycloneDX, GitHub | ✅ clasificadas (forbidden…unknown) | DB propia vía OCI | ✅ `--skip-db-update` + espejo | gate + clúster |
| **osv-scanner** | matching de vulnerabilidades sobre lockfile/fuente | lockfiles, directorios, SBOM, imagen, Debian/Alpine | tabla, JSON, SARIF, markdown | ✅ (v2, resumen de licencias) | OSV.dev | ✅ `--offline-vulnerabilities` | pre-commit, check de PR |
| **cdxgen** | SBOM consciente del build | más de 30 ecosistemas, consciente del sistema de build | CycloneDX | declaradas | vía depscan | ⚠️ | etapa de build (JVM/Node) |
| **scancode-toolkit** | forense de licencias/copyright a nivel de archivo | árbol de fuentes | JSON, SPDX, CSV | ✅ **matching de texto**, ~2000 detecciones | ❌ | ✅ | revisión profunda de la OSPO |
| **ORT** | pipeline completo de cumplimiento | fuente + gestores de paquetes | resultados evaluados, SPDX, avisos | ✅ + curations + reglas de política | vía advisors | ⚠️ | OSPO / gate de release |
| **FOSSology** | flujo de revisión de licencias | uploads | reportes, SPDX | ✅ + curación humana | ❌ | ✅ | revisión legal |
| **Dependency-Track** | plataforma de análisis continuo de SBOM | CycloneDX (SPDX vía conversión) | UI, REST, violaciones de política | ✅ política | OSV, NVD, GitHub, VulnDB | ✅ feeds espejados | plataforma central |
| **Renovate / Dependabot** | actualización de dependencias | lockfiles | PRs | ⚠️ | advisories | ❌ | automatización del repositorio |
| **cosign** | firma y atestación | artefactos, predicados | DSSE / bundles de Sigstore | ❌ | ❌ | ✅ con claves | etapa de release |
| **OpenSSF Scorecard** | salud del proyecto upstream | URL del repo | JSON, tabla | ❌ | ❌ | ❌ | revisión de admisión de dependencias |

### 4.2 Generar SBOM con syft

```bash
$ syft version
Application:        syft
Version:            1.29.0
BuildDate:          2026-08-14T11:02:41Z
GitCommit:          8f3a1c4d7b09e2a6f5c8d1b4e7a0c3f6d9b2e5a8
Platform:           linux/amd64
GoVersion:          go1.23.6

$ syft scan registry:ghcr.io/acme/payments-api:1.24.3 \
        -o spdx-json=sbom.spdx.json \
        -o cyclonedx-json=sbom.cdx.json \
        -o table
 ✔ Pulled image
 ✔ Loaded image                                       ghcr.io/acme/payments-api:1.24.3
 ✔ Parsed image                sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
 ✔ Cataloged contents          sha256:1a4dcbf29e0d7c6b5a83f210e4d97c6b8a5f3e1d0c9b7a6f4e2d1c0b9a8f7e6d
   ├── ✔ Packages                        [312 packages]
   ├── ✔ Executables                     [41 executables]
   ├── ✔ File metadata                   [2184 locations]
   └── ✔ File digests                    [2184 files]
NAME                        VERSION                TYPE
base-files                  12.4+deb12u7           deb
ca-certificates             20230311               deb
github.com/gorilla/mux      v1.8.1                 go-module
libc6                       2.36-9+deb12u8         deb
libssl3                     3.0.15-1~deb12u1       deb
log4j-core                  2.14.1                 java-archive
payments-api                1.24.3                 go-module
...

$ jq '.packages | length' sbom.spdx.json
312
$ jq -r '.creationInfo.created, .documentNamespace' sbom.spdx.json
2026-09-03T09:14:22Z
https://anchore.com/syft/image/ghcr.io/acme/payments-api-1.24.3-4c1f9b2e-6a77-4f0b-9b3a-8d2c1e5f7a10
```

Fijá el comportamiento de catalogación para que los SBOM sean reproducibles entre ejecuciones:

```yaml
# .syft.yaml
output:
  - "spdx-json=sbom.spdx.json"
  - "cyclonedx-json=sbom.cdx.json"
quiet: false
check-for-app-update: false

# Deterministic output: no timestamps that change between identical builds.
format:
  pretty: true
  spdx-json:
    deterministic-uuid: true
  cyclonedx-json:
    deterministic-uuid: true

# Explicitly select catalogers. Relying on the default set means a syft
# upgrade can silently change the component count of "the same" image.
select-catalogers:
  - "image"          # default image set: OS package DBs + binaries
  - "+sbom-cataloger" # ingest SBOMs already embedded in the image

package:
  search-unindexed-archives: true   # look inside nested JAR/WAR/EAR
  search-indexed-archives: true
  exclude-binary-overlap-by-ownership: true

file:
  metadata:
    selection: owned-by-package
    digests: ["sha256"]
  executable:
    cataloger:
      enabled: true

exclude:
  - "./proc/**"
  - "./sys/**"
  - "**/test/fixtures/**"

source:
  name: "payments-api"
  version: "1.24.3"
```

### 4.3 Matching de vulnerabilidades con grype (entra un SBOM, sale una decisión)

```bash
$ grype db status
Location:  /home/build/.cache/grype/db/6
Built:     2026-09-03T02:11:07Z
Schema:    6
Checksum:  sha256:c2e8a1f9d0b73c46a5f28e9d1b0c7a63f5e4d2c1b0a9f8e7d6c5b4a3928170f6
Status:    valid

$ grype sbom:./sbom.cdx.json --fail-on high --by-cve -o table
 ✔ Scanned for vulnerabilities     [37 vulnerability matches]
   ├── by severity: 2 critical, 6 high, 18 medium, 9 low, 2 negligible
   └── by status:   21 fixed, 16 not-fixed
NAME        INSTALLED         FIXED-IN    TYPE           VULNERABILITY   SEVERITY
libssl3     3.0.15-1~deb12u1  (won't fix) deb            CVE-2024-13176  Medium
log4j-core  2.14.1            2.15.0      java-archive   CVE-2021-44228  Critical
log4j-core  2.14.1            2.16.0      java-archive   CVE-2021-45046  Critical
log4j-core  2.14.1            2.17.0      java-archive   CVE-2021-45105  High
zlib1g      1:1.2.13.dfsg-1   (won't fix) deb            CVE-2023-45853  High
...
1 error occurred:
	* discovered vulnerabilities at or above the severity threshold: high

$ echo $?
1
```

El gate es `--fail-on high` más un **archivo de triage**, no una exclusión general:

```yaml
# .grype.yaml
check-for-app-update: false
fail-on-severity: high
only-fixed: false          # NEVER true on a gate: hides unfixed criticals
add-cpes-if-none: true     # generate CPEs for language packages lacking them
by-cve: true               # normalise GHSA/ELSA/DSA to CVE for dedup

db:
  auto-update: true
  validate-age: true
  max-allowed-built-age: 120h   # fail if the DB is older than 5 days

# Every ignore MUST carry an expiry and a reason. Unbounded ignores are
# how a "temporary" exception becomes permanent technical debt.
ignore:
  - vulnerability: CVE-2023-45853
    package:
      name: zlib1g
      type: deb
    # zlib MiniZip only; we never call minizip. Debian marks it won't-fix.
    # Re-review: 2026-12-01
  - vulnerability: GHSA-jfh8-c2jp-5v3q
    reason: "superseded by CVE mapping, deduplicated via by-cve"

exclude:
  - "/usr/share/doc/**"

registry:
  auth:
    - authority: ghcr.io
      username: ${GHCR_USER}
      password: ${GHCR_TOKEN}
```

### 4.4 Trivy: vulnerabilidades, licencias, secretos y errores de configuración en una sola pasada

```bash
$ trivy image --scanners vuln,license,secret \
        --license-full \
        --severity HIGH,CRITICAL \
        --exit-code 1 \
        --format table \
        ghcr.io/acme/payments-api:1.24.3
2026-09-03T09:20:11Z    INFO    Vulnerability scanning is enabled
2026-09-03T09:20:11Z    INFO    Secret scanning is enabled
2026-09-03T09:20:11Z    INFO    License scanning is enabled
2026-09-03T09:20:14Z    INFO    Detected OS  family="debian" version="12.8"
2026-09-03T09:20:14Z    INFO    [debian] Detecting vulnerabilities...  os_version="12" pkg_num=118
2026-09-03T09:20:15Z    INFO    Number of language-specific files  num=2
2026-09-03T09:20:15Z    INFO    [gobinary] Detecting vulnerabilities...
2026-09-03T09:20:15Z    INFO    [jar] Detecting vulnerabilities...

ghcr.io/acme/payments-api:1.24.3 (debian 12.8)
==============================================
Total: 3 (HIGH: 2, CRITICAL: 1)

┌──────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│ Library  │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├──────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ zlib1g   │ CVE-2023-45853 │ CRITICAL │ will_  │ 1:1.2.13.dfsg-1   │               │
│          │                │          │ not_fix│                   │               │
└──────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘

Java (jar)
==========
Total: 3 (HIGH: 1, CRITICAL: 2)

┌────────────────────────────────┬────────────────┬──────────┬───────────────────┬───────────────┐
│            Library             │ Vulnerability  │ Severity │ Installed Version │ Fixed Version │
├────────────────────────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│ org.apache.logging.log4j:      │ CVE-2021-44228 │ CRITICAL │ 2.14.1            │ 2.15.0        │
│ log4j-core                     │                │          │                   │               │
├────────────────────────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│                                │ CVE-2021-45046 │ CRITICAL │                   │ 2.16.0        │
├────────────────────────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│                                │ CVE-2021-45105 │ HIGH     │                   │ 2.17.0        │
└────────────────────────────────┴────────────────┴──────────┴───────────────────┴───────────────┘

ghcr.io/acme/payments-api:1.24.3 (debian 12.8)
==============================================
Total: 4 (HIGH: 1, CRITICAL: 0)

┌──────────────┬─────────────────┬──────────┬──────────────────────────────────────────┐
│ Classification│    Severity    │ Licence  │                   Path                   │
├──────────────┼─────────────────┼──────────┼──────────────────────────────────────────┤
│ Restricted   │ HIGH            │ GPL-3.0  │ /usr/share/licenses/os/coreutils.copyright│
├──────────────┼─────────────────┼──────────┼──────────────────────────────────────────┤
│ Reciprocal   │ MEDIUM          │ MPL-2.0  │ /usr/share/licenses/go/…/mozilla-cert.txt │
└──────────────┴─────────────────┴──────────┴──────────────────────────────────────────┘

$ echo $?
1
```

Trivy clasifica las licencias usando el modelo de categorías de Google. Codificá la política en `trivy.yaml` en vez de en shell:

```yaml
# trivy.yaml
scan:
  scanners:
    - vuln
    - license
    - secret
  skip-dirs:
    - /usr/share/doc
    - /var/lib/apt

severity:
  - HIGH
  - CRITICAL

vulnerability:
  ignore-unfixed: false      # do NOT hide won't-fix; triage them via VEX

license:
  full: true
  # Categories: forbidden > restricted > reciprocal > notice > permissive
  #             > unencumbered > unknown
  forbidden:
    - AGPL-1.0
    - AGPL-3.0
    - SSPL-1.0
    - BUSL-1.1
    - Elastic-2.0
    - CC-BY-NC-4.0
  restricted:
    - GPL-2.0-only
    - GPL-3.0-only
    - LGPL-3.0-only
  reciprocal:
    - MPL-2.0
    - EPL-2.0
    - CDDL-1.0
  notice:
    - Apache-2.0
    - MIT
    - BSD-3-Clause
    - ISC
  ignored:
    # Classpath Exception removes the copyleft reach across the linking
    # boundary; a substring match on "GPL" would wrongly block every JRE.
    - GPL-2.0-only WITH Classpath-exception-2.0
    - GPL-3.0-or-later WITH GCC-exception-3.1

db:
  # Mirror the DB internally: ghcr.io anonymous pulls are rate-limited and
  # will break your pipeline at the worst possible moment.
  repository: registry.internal.acme.example/mirror/trivy-db:2
  java-repository: registry.internal.acme.example/mirror/trivy-java-db:1
  skip-update: false

cache:
  dir: /var/cache/trivy

exit-code: 1
```

### 4.5 osv-scanner: el gate barato de pre-commit / PR

```bash
$ osv-scanner scan source --recursive --licenses="MIT,Apache-2.0,BSD-3-Clause,ISC,BSD-2-Clause" .
Scanned /src/go.mod file and found 84 packages
Scanned /src/web/package-lock.json file and found 1204 packages
Scanned /src/requirements.txt file and found 31 packages

╭─────────────────────────────────────┬──────┬───────────┬─────────────────────┬─────────┬──────────────────╮
│ OSV URL                             │ CVSS │ ECOSYSTEM │ PACKAGE             │ VERSION │ SOURCE           │
├─────────────────────────────────────┼──────┼───────────┼─────────────────────┼─────────┼──────────────────┤
│ https://osv.dev/GHSA-m425-mq94-257g │ 7.5  │ Go        │ google.golang.org/  │ 1.58.2  │ go.mod           │
│                                     │      │           │ grpc                │         │                  │
│ https://osv.dev/GHSA-w596-4wvx-j9j6 │ 9.8  │ PyPI      │ pyyaml              │ 5.3.1   │ requirements.txt │
╰─────────────────────────────────────┴──────┴───────────┴─────────────────────┴─────────┴──────────────────╯

License violations found:
╭───────────┬──────────────────────────┬─────────┬──────────────────╮
│ ECOSYSTEM │ PACKAGE                  │ LICENSE │ SOURCE           │
├───────────┼──────────────────────────┼─────────┼──────────────────┤
│ npm       │ @acme/legacy-charting    │ GPL-3.0 │ package-lock.json│
╰───────────┴──────────────────────────┴─────────┴──────────────────╯

$ echo $?
1
```

### 4.6 Forense profundo de licencias con ScanCode

`syft` y `trivy` leen metadatos *declarados*. Solo un escáner por matching de texto te dice que `vendor/thirdparty/base64.c` lleva una cabecera GPL dentro de un repositorio que por lo demás es MIT.

```bash
$ scancode --license --copyright --package --info --license-text \
           --processes 8 --timeout 120 \
           --json-pp scancode.json \
           --spdx-rdf scancode.spdx.rdf \
           ./src
Setup plugins...
Collect file inventory...
Scan files for: info, licenses, copyrights, packages with 8 process(es)...
[####################] 2184
Scanning done.
Summary:        info, licenses, copyrights, packages with 8 process(es)
Errors count:   0
Scan Speed:     41.32 files/sec
Initial counts: 2184 resource(s): 1976 file(s) and 208 directorie(s)
Final counts:   2184 resource(s): 1976 file(s) and 208 directorie(s)
Timings:
  scan_start: 2026-09-03T09:31:02.114
  scan_end:   2026-09-03T09:31:50.882

$ jq -r '
    [ .files[]
      | select(.detected_license_expression != null)
      | .detected_license_expression ]
    | group_by(.) | map({licence: .[0], files: length})
    | sort_by(-.files) | .[] | "\(.files)\t\(.licence)"
  ' scancode.json
1421	apache-2.0
318	mit
92	bsd-new
14	mpl-2.0
3	gpl-2.0            <-- not declared anywhere in go.mod / package.json
1	unknown-license-reference

$ jq -r '.files[] | select(.detected_license_expression=="gpl-2.0") | .path' scancode.json
src/vendor/thirdparty/base64.c
src/vendor/thirdparty/crc32.c
src/vendor/thirdparty/README
```

Ese es el hallazgo que un SBOM basado solo en metadatos nunca va a producir.

---

## 5. VEX: por qué «1.437 vulnerabilidades» no es una respuesta

Un escaneo crudo de una imagen realista devuelve cientos de coincidencias. La mayoría son irrelevantes: la ruta de código vulnerable no está compilada, no es alcanzable o ya está mitigada. Entregarle esa lista a un equipo de entrega les enseña a ignorar los escáneres — el peor resultado posible.

**VEX (Vulnerability Exploitability eXchange)** es la afirmación legible por máquina, hecha por el proveedor, sobre si una vulnerabilidad *conocida* afecta realmente a un producto *específico*.

### 5.1 Formatos VEX

| | **OpenVEX** | **Perfil VEX de CSAF 2.0** | **CycloneDX VEX** |
|---|---|---|---|
| Custodio | comunidad OpenVEX / OpenSSF | OASIS | OWASP |
| Codificación | JSON-LD pequeño e independiente | JSON grande, modelo completo de advisory | dentro o junto a un BOM CycloneDX |
| Identidad del producto | purl / cualquier IRI en `products[].@id` | árbol de productos CSAF + `product_identification_helper` | `bom-ref` / purl |
| Estados | `not_affected`, `affected`, `fixed`, `under_investigation` | `known_not_affected`, `known_affected`, `fixed`, `first_fixed`, `under_investigation`, `recommended` | `not_affected`, `exploitable`, `in_triage`, `resolved`, `false_positive` … |
| Justificaciones | 5 valores legibles por máquina | 5 etiquetas de flag (misma semántica) | `analysis.justification` |
| Mejor encaje | adjuntarlo por artefacto en CI | publicación a escala por el PSIRT del proveedor | equipos ya volcados por completo a CycloneDX |

### 5.2 Las cinco justificaciones de `not_affected` (idénticas en OpenVEX y CSAF)

| Justificación | Significado | Evidencia típica |
|---|---|---|
| `component_not_present` | el componente nunca estuvo en el artefacto | diff de SBOM, coincidencia falso positivo |
| `vulnerable_code_not_present` | el componente está, pero la función/archivo vulnerable fue eliminado o nunca se compiló | flags de build, `nm`/`objdump` |
| `vulnerable_code_not_in_execute_path` | presente y compilado, pero inalcanzable desde cualquier entrypoint | análisis de grafo de llamadas / alcanzabilidad |
| `vulnerable_code_cannot_be_controlled_by_adversary` | alcanzable, pero el atacante no puede influir en la entrada | modelo de amenazas, validación de entrada |
| `inline_mitigations_already_exist` | alcanzable y controlable, pero un control compensatorio lo bloquea | regla de WAF, perfil seccomp, NetworkPolicy |

### 5.3 Un documento OpenVEX real

```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://acme.example/vex/payments-api/2026-09-03-001",
  "author": "Acme Product Security <psirt@acme.example>",
  "role": "Document Creator",
  "timestamp": "2026-09-03T10:02:00Z",
  "last_updated": "2026-09-03T10:02:00Z",
  "version": 1,
  "tooling": "vexctl/0.4.0",
  "statements": [
    {
      "vulnerability": {
        "@id": "https://nvd.nist.gov/vuln/detail/CVE-2023-45853",
        "name": "CVE-2023-45853",
        "description": "zlib MiniZip integer overflow in zipOpenNewFileInZip4_64"
      },
      "timestamp": "2026-09-03T10:02:00Z",
      "products": [
        {
          "@id": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api",
          "identifiers": {
            "purl": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api"
          },
          "subcomponents": [
            { "@id": "pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=amd64&distro=debian-12" }
          ]
        }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_present",
      "impact_statement": "The overflow is in MiniZip (contrib/minizip), which Debian does not build into libz.so.1. Verified with `nm -D /lib/x86_64-linux-gnu/libz.so.1 | grep -c zipOpenNewFileInZip4_64` => 0."
    },
    {
      "vulnerability": { "name": "CVE-2021-44228" },
      "timestamp": "2026-09-03T10:02:00Z",
      "products": [
        { "@id": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api",
          "subcomponents": [
            { "@id": "pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1" }
          ]
        }
      ],
      "status": "affected",
      "action_statement": "Upgrade log4j-core to >= 2.17.1. Interim mitigation: JVM flag -Dlog4j2.formatMsgNoLookups=true is set in the container ENTRYPOINT.",
      "action_statement_timestamp": "2026-09-03T10:02:00Z"
    },
    {
      "vulnerability": { "name": "CVE-2024-13176" },
      "timestamp": "2026-09-03T10:02:00Z",
      "products": [
        { "@id": "pkg:oci/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e?repository_url=ghcr.io%2Facme%2Fpayments-api" }
      ],
      "status": "under_investigation"
    }
  ]
}
```

### 5.4 Producir y consumir VEX

```bash
$ vexctl create \
    --author "Acme Product Security <psirt@acme.example>" \
    --product "pkg:oci/payments-api@sha256:9f2b3c…?repository_url=ghcr.io%2Facme%2Fpayments-api" \
    --subcomponents "pkg:deb/debian/zlib1g@1:1.2.13.dfsg-1?arch=amd64&distro=debian-12" \
    --vuln "CVE-2023-45853" \
    --status "not_affected" \
    --justification "vulnerable_code_not_present" \
    --file payments-api.openvex.json
{ … }

# Attach VEX to the image as an in-toto attestation
$ vexctl attest --attach --sign payments-api.openvex.json \
    ghcr.io/acme/payments-api@sha256:9f2b3c…

# Consume it: grype re-scans and the suppressed finding disappears
$ grype sbom:./sbom.cdx.json --vex payments-api.openvex.json --show-suppressed -o table
 ✔ Scanned for vulnerabilities     [37 vulnerability matches]
   ├── by severity: 2 critical, 5 high, 18 medium, 9 low, 2 negligible (1 suppressed)
   └── by status:   21 fixed, 16 not-fixed
NAME        INSTALLED         FIXED-IN  TYPE          VULNERABILITY   SEVERITY
log4j-core  2.14.1            2.15.0    java-archive  CVE-2021-44228  Critical
zlib1g      1:1.2.13.dfsg-1             deb           CVE-2023-45853  High (suppressed by VEX)
…

# Trivy consumes the same document
$ trivy image --vex payments-api.openvex.json --show-suppressed \
        --severity HIGH,CRITICAL ghcr.io/acme/payments-api:1.24.3
2026-09-03T10:05:44Z    INFO    VEX filtering  file="payments-api.openvex.json"
2026-09-03T10:05:47Z    INFO    Suppressed vulnerability  vuln_id="CVE-2023-45853" status="not_affected" justification="vulnerable_code_not_present"
```

> **El invariante:** VEX suprime en el momento del *reporte*, nunca en el momento del *SBOM*. El SBOM sigue completo y veraz; VEX es una capa de afirmaciones separada, firmada por separado y revisable por separado, superpuesta encima. Borrar un componente del SBOM para silenciar un escáner es falsificar el inventario.

---

## 6. Procedencia y atestación: demostrar de dónde salió el artefacto

Un SBOM afirma *qué hay adentro*. No afirma nada sobre *quién lo produjo* ni sobre *si fue manipulado*. Eso corresponde a la capa de procedencia.

### 6.1 Niveles de Build de SLSA v1.0

| Nivel | Requisito | Qué neutraliza | Costo |
|---|---|---|---|
| **L0** | nada | — | — |
| **L1** | la procedencia existe y se distribuye; proceso de build documentado y automatizado | artefactos de origen misterioso por accidente, «se compiló en la laptop de Jenkins» | bajo |
| **L2** | el build corre en una plataforma **alojada**; la procedencia está **firmada** por esa plataforma, autenticada | procedencia falsificada por un tercero; manipulación posterior al build | medio |
| **L3** | la plataforma de build está **endurecida**: los builds están aislados y el material secreto no puede ser falsificado por los pasos definidos por el usuario del propio build | un script de build malicioso que exfiltra la clave de firma y falsifica la procedencia | alto |

SLSA v1.0 reorganizó explícitamente el modelo previo de cuatro niveles de la v0.1 en **tracks**; «Build L3» no es la misma afirmación que «SLSA 3» de la documentación de 2021.

### 6.2 Estructura de una atestación in-toto

Todo — SBOM, procedencia SLSA, VEX, resultados de tests — se envuelve de forma idéntica:

```
DSSE envelope
├── payloadType: "application/vnd.in-toto+json"
├── payload: base64( in-toto Statement )
│   └── Statement
│       ├── _type: "https://in-toto.io/Statement/v1"
│       ├── subject: [ { name, digest: { sha256: "…" } } ]   ← binds to the artifact
│       ├── predicateType: "https://slsa.dev/provenance/v1"  ← what kind of claim
│       └── predicate: { … }                                  ← the claim itself
└── signatures: [ { keyid, sig } ]
```

Un predicado de procedencia SLSA v1.0:

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "ghcr.io/acme/payments-api",
      "digest": {
        "sha256": "9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://actions.github.io/buildtypes/workflow/v1",
      "externalParameters": {
        "workflow": {
          "ref": "refs/tags/v1.24.3",
          "repository": "https://github.com/acme/payments-api",
          "path": ".github/workflows/release.yml"
        },
        "inputs": { "push_image": true }
      },
      "internalParameters": {
        "github": {
          "event_name": "push",
          "repository_id": "487213904",
          "repository_owner_id": "10294851"
        }
      },
      "resolvedDependencies": [
        {
          "uri": "git+https://github.com/acme/payments-api@refs/tags/v1.24.3",
          "digest": { "gitCommit": "7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21" }
        },
        {
          "uri": "https://github.com/actions/checkout@v4",
          "digest": { "gitCommit": "11bd71901bbe5b1630ceea73d27597364c9af683" }
        }
      ]
    },
    "runDetails": {
      "builder": {
        "id": "https://github.com/actions/runner/github-hosted"
      },
      "metadata": {
        "invocationId": "https://github.com/acme/payments-api/actions/runs/9182736450/attempts/1",
        "startedOn": "2026-09-03T09:10:04Z",
        "finishedOn": "2026-09-03T09:16:52Z"
      }
    }
  }
}
```

### 6.3 Firmar y adjuntar con cosign (keyless / Sigstore)

```bash
$ export IMAGE=ghcr.io/acme/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e

$ cosign sign --yes "$IMAGE"
Generating ephemeral keys...
Retrieving signed certificate...
        Note that there may be personally identifiable information associated with this signed artifact.
        This may include the email address associated with the account with which you authenticate.
        This information will be used for signing this artifact and will be stored in public transparency logs and cannot be removed later.
Successfully verified SCT...
tlog entry created with index: 187436291
Pushing signature to: ghcr.io/acme/payments-api

$ cosign attest --yes --type spdxjson --predicate sbom.spdx.json "$IMAGE"
Using payload from: sbom.spdx.json
Generating ephemeral keys...
Retrieving signed certificate...
Successfully verified SCT...
tlog entry created with index: 187436294
Pushing attestation to: ghcr.io/acme/payments-api

$ cosign attest --yes --type cyclonedx --predicate sbom.cdx.json "$IMAGE"
tlog entry created with index: 187436297

$ cosign attest --yes --type openvex --predicate payments-api.openvex.json "$IMAGE"
tlog entry created with index: 187436301
```

Verificación — el paso que realmente importa:

```bash
$ cosign verify-attestation \
    --type spdxjson \
    --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yml@refs/tags/v.+$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    "$IMAGE" > attestation.json

Verification for ghcr.io/acme/payments-api@sha256:9f2b3c… --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
Certificate subject: https://github.com/acme/payments-api/.github/workflows/release.yml@refs/tags/v1.24.3
Certificate issuer URL: https://token.actions.githubusercontent.com
GitHub Workflow Trigger: push
GitHub Workflow SHA: 7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21
GitHub Workflow Name: release
GitHub Workflow Repository: acme/payments-api
GitHub Workflow Ref: refs/tags/v1.24.3

# Recover the SBOM from the verified attestation
$ jq -r '.payload' attestation.json | base64 -d \
  | jq -r '.predicate.packages | length'
312

# And confirm the attestation is bound to THIS digest, not another
$ jq -r '.payload' attestation.json | base64 -d | jq -r '.subject[].digest.sha256'
9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
```

> **Antipatrón de verificación.** `cosign verify --certificate-identity-regexp '.*'` verifica que *alguien* firmó la imagen — incluido un atacante con cualquier identidad OIDC válida en la instancia pública de Sigstore. La regexp de identidad y el emisor OIDC son la frontera de seguridad completa. Anclá ambos extremos de la expresión (`^…$`).

### 6.4 Verificar la procedencia SLSA de forma independiente

```bash
$ slsa-verifier verify-image "$IMAGE" \
    --source-uri github.com/acme/payments-api \
    --source-tag v1.24.3
Verified build using builder "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.0.0" at commit 7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21
PASSED: SLSA verification passed

# GitHub-native equivalent
$ gh attestation verify oci://ghcr.io/acme/payments-api:1.24.3 --owner acme
Loaded digest sha256:9f2b3c… for oci://ghcr.io/acme/payments-api:1.24.3
Loaded 1 attestation from GitHub API

The following policy criteria will be enforced:
- Predicate type must match:................ https://slsa.dev/provenance/v1
- Source Repository Owner URI must match:... https://github.com/acme
- Subject Alternative Name must match regex: (?i)^https://github.com/acme/
- OIDC Issuer must match:................... https://token.actions.githubusercontent.com

✓ Verification succeeded!
```

---

## 7. Implementación completa de producción

### 7.1 GitHub Actions: build → SBOM → gate → firmar → atestar → publicar

```yaml
# .github/workflows/release.yml
name: release

on:
  push:
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      push_image:
        description: "Push the image to the registry"
        type: boolean
        default: true

permissions:
  contents: read

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  COSIGN_VERSION: v2.4.1
  SYFT_VERSION: v1.29.0
  GRYPE_VERSION: v0.87.0

jobs:
  license-compliance:
    name: Licence compliance (REUSE + source scan)
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: REUSE compliance
        uses: fsfe/reuse-action@v5

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install osv-scanner
        run: |
          set -euo pipefail
          curl -sSfL -o /usr/local/bin/osv-scanner \
            https://github.com/google/osv-scanner/releases/download/v2.0.2/osv-scanner_linux_amd64
          chmod +x /usr/local/bin/osv-scanner
          osv-scanner --version

      - name: Licence allow-list over resolved dependencies
        run: |
          set -euo pipefail
          osv-scanner scan source --recursive \
            --licenses="MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0,Unlicense,CC0-1.0,Zlib,PostgreSQL,Python-2.0,BSL-1.0" \
            --format=json --output=osv-licences.json . || RC=$?
          echo "osv-scanner exit code: ${RC:-0}"
          jq -r '
            .results[]?.packages[]?
            | select(.licenses != null)
            | [ .package.name, .package.version, (.licenses | join(" OR ")) ]
            | @tsv
          ' osv-licences.json | sort -u | head -50
          exit "${RC:-0}"

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: licence-report
          path: osv-licences.json
          retention-days: 90

  build:
    name: Build, scan, sign and attest
    needs: license-compliance
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      packages: write        # push to GHCR
      id-token: write        # OIDC token for keyless signing
      attestations: write    # GitHub attestation store
      security-events: write # SARIF upload
    outputs:
      digest: ${{ steps.build.outputs.digest }}
      image: ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Buildx
        uses: docker/setup-buildx-action@v3
        with:
          driver-opts: image=moby/buildkit:v0.19.0

      - name: Log in to registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Derive image metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,format=long
          labels: |
            org.opencontainers.image.licenses=Apache-2.0
            org.opencontainers.image.vendor=Acme Corp
            org.opencontainers.image.source=https://github.com/${{ github.repository }}

      - name: Build and push (digest-pinned)
        id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: ${{ github.event_name == 'push' || inputs.push_image }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: mode=max      # BuildKit-native SLSA provenance
          sbom: true                # BuildKit-native SBOM attestation
          cache-from: type=gha
          cache-to: type=gha,mode=max
          build-args: |
            VERSION=${{ github.ref_name }}

      - name: Install syft
        uses: anchore/sbom-action/download-syft@v0
        with:
          syft-version: ${{ env.SYFT_VERSION }}

      - name: Generate SBOMs (SPDX + CycloneDX) from the pushed digest
        env:
          IMAGE_REF: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail
          syft scan "registry:${IMAGE_REF}" \
            -o "spdx-json=sbom.spdx.json" \
            -o "cyclonedx-json=sbom.cdx.json"
          echo "SPDX packages:       $(jq '.packages | length' sbom.spdx.json)"
          echo "CycloneDX components:$(jq '.components | length' sbom.cdx.json)"
          # Non-empty SBOM is a hard requirement: an empty one silently
          # turns every downstream scan into a green build.
          test "$(jq '.packages | length' sbom.spdx.json)" -gt 10

      - name: Install grype
        uses: anchore/scan-action/download-grype@v6
        with:
          grype-version: ${{ env.GRYPE_VERSION }}

      - name: Vulnerability gate (SBOM in, no re-pull)
        run: |
          set -euo pipefail
          grype "sbom:./sbom.cdx.json" \
            --config .grype.yaml \
            --vex ./vex/payments-api.openvex.json \
            --output "sarif=grype.sarif" \
            --output "json=grype.json" \
            --output "table" \
            --fail-on high

      - name: Upload SARIF to code scanning
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: grype.sarif
          category: grype-container

      - name: Install cosign
        uses: sigstore/cosign-installer@v3
        with:
          cosign-release: ${{ env.COSIGN_VERSION }}

      - name: Sign image and attach attestations (keyless)
        env:
          IMAGE_REF: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail
          cosign sign   --yes "${IMAGE_REF}"
          cosign attest --yes --type spdxjson  --predicate sbom.spdx.json "${IMAGE_REF}"
          cosign attest --yes --type cyclonedx --predicate sbom.cdx.json  "${IMAGE_REF}"
          cosign attest --yes --type openvex   --predicate ./vex/payments-api.openvex.json "${IMAGE_REF}"

      - name: GitHub-native build provenance
        uses: actions/attest-build-provenance@v2
        with:
          subject-name: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          subject-digest: ${{ steps.build.outputs.digest }}
          push-to-registry: true

      - name: Verify what we just published (fail closed)
        env:
          IMAGE_REF: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail
          cosign verify \
            --certificate-identity-regexp "^https://github\.com/${{ github.repository }}/\.github/workflows/release\.yml@refs/tags/v.+$" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            "${IMAGE_REF}"
          cosign verify-attestation --type spdxjson \
            --certificate-identity-regexp "^https://github\.com/${{ github.repository }}/\.github/workflows/release\.yml@refs/tags/v.+$" \
            --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
            "${IMAGE_REF}" > /dev/null
          echo "publish-time verification OK"

      - name: Publish SBOM to Dependency-Track
        env:
          DT_URL:     ${{ secrets.DEPENDENCY_TRACK_URL }}
          DT_API_KEY: ${{ secrets.DEPENDENCY_TRACK_API_KEY }}
        run: |
          set -euo pipefail
          HTTP=$(curl -sS -o dt-response.json -w '%{http_code}' \
            -X POST "${DT_URL}/api/v1/bom" \
            -H "X-Api-Key: ${DT_API_KEY}" \
            -F "autoCreate=true" \
            -F "projectName=${{ github.event.repository.name }}" \
            -F "projectVersion=${{ github.ref_name }}" \
            -F "bom=@sbom.cdx.json")
          echo "HTTP ${HTTP}"; cat dt-response.json
          test "${HTTP}" = "200"

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: sbom-and-scan
          path: |
            sbom.spdx.json
            sbom.cdx.json
            grype.json
            grype.sarif
          retention-days: 365   # SBOM retention must outlive the release
```

### 7.2 Equivalente en GitLab CI

```yaml
# .gitlab-ci.yml
stages: [compliance, build, sbom, scan, sign, publish]

variables:
  IMAGE: "$CI_REGISTRY_IMAGE"
  SYFT_VERSION: "v1.29.0"
  GRYPE_VERSION: "v0.87.0"
  COSIGN_VERSION: "v2.4.1"
  DOCKER_BUILDKIT: "1"

.oidc: &oidc
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore

reuse-lint:
  stage: compliance
  image: fsfe/reuse:latest
  script:
    - reuse lint

licence-allowlist:
  stage: compliance
  image: ghcr.io/google/osv-scanner:v2.0.2
  script:
    - |
      osv-scanner scan source --recursive \
        --licenses="MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0,Zlib,Unlicense,CC0-1.0" \
        --format=json --output=osv-licences.json .
  artifacts:
    when: always
    paths: [osv-licences.json]
    expire_in: 90 days

build-image:
  stage: build
  image: gcr.io/kaniko-project/executor:v1.23.2-debug
  script:
    - /kaniko/executor
        --context "${CI_PROJECT_DIR}"
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
        --destination "${IMAGE}:${CI_COMMIT_REF_SLUG}"
        --destination "${IMAGE}:${CI_COMMIT_SHA}"
        --digest-file /tmp/digest
        --reproducible
    - cp /tmp/digest digest.txt
  artifacts:
    paths: [digest.txt]

generate-sbom:
  stage: sbom
  image: anchore/syft:${SYFT_VERSION}
  script:
    - export DIGEST="$(cat digest.txt)"
    - syft scan "registry:${IMAGE}@${DIGEST}"
        -o spdx-json=sbom.spdx.json
        -o cyclonedx-json=sbom.cdx.json
    - test "$(grep -c '"SPDXID"' sbom.spdx.json)" -gt 10
  artifacts:
    paths: [sbom.spdx.json, sbom.cdx.json]
    reports:
      cyclonedx: sbom.cdx.json
    expire_in: 1 year

vuln-gate:
  stage: scan
  image: anchore/grype:${GRYPE_VERSION}
  script:
    - grype sbom:./sbom.cdx.json
        --config .grype.yaml
        --vex ./vex/payments-api.openvex.json
        -o table -o "json=grype.json"
        --fail-on high
  artifacts:
    when: always
    paths: [grype.json]

sign-and-attest:
  stage: sign
  <<: *oidc
  image:
    name: gcr.io/projectsigstore/cosign:${COSIGN_VERSION}
    entrypoint: [""]
  script:
    - export DIGEST="$(cat digest.txt)"
    - echo "$CI_REGISTRY_PASSWORD" | cosign login "$CI_REGISTRY" -u "$CI_REGISTRY_USER" --password-stdin
    - cosign sign   --yes "${IMAGE}@${DIGEST}"
    - cosign attest --yes --type spdxjson  --predicate sbom.spdx.json "${IMAGE}@${DIGEST}"
    - cosign attest --yes --type cyclonedx --predicate sbom.cdx.json  "${IMAGE}@${DIGEST}"
    - cosign verify
        --certificate-identity-regexp "^${CI_SERVER_URL}/${CI_PROJECT_PATH}//.gitlab-ci.yml@refs/tags/v.+$"
        --certificate-oidc-issuer "${CI_SERVER_URL}"
        "${IMAGE}@${DIGEST}"

publish-sbom:
  stage: publish
  image: curlimages/curl:8.11.0
  script:
    - |
      curl -sSf -X POST "${DT_URL}/api/v1/bom" \
        -H "X-Api-Key: ${DT_API_KEY}" \
        -F "autoCreate=true" \
        -F "projectName=${CI_PROJECT_NAME}" \
        -F "projectVersion=${CI_COMMIT_REF_NAME}" \
        -F "bom=@sbom.cdx.json"
```

### 7.3 Dependency-Track en Kubernetes (manifiestos completos)

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: supply-chain
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Secret
metadata:
  name: dtrack-db
  namespace: supply-chain
type: Opaque
stringData:
  # In production this is sourced from ExternalSecrets / Vault, never from git.
  POSTGRES_DB: dtrack
  POSTGRES_USER: dtrack
  POSTGRES_PASSWORD: "CHANGE-ME-VIA-EXTERNAL-SECRET"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dtrack-postgres-data
  namespace: supply-chain
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: dtrack-postgres
  namespace: supply-chain
spec:
  serviceName: dtrack-postgres
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: dtrack-postgres }
  template:
    metadata:
      labels: { app.kubernetes.io/name: dtrack-postgres }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        fsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: postgres
          image: postgres:16.6-alpine
          ports:
            - { name: postgres, containerPort: 5432 }
          envFrom:
            - secretRef: { name: dtrack-db }
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "dtrack", "-d", "dtrack"] }
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            exec: { command: ["pg_isready", "-U", "dtrack", "-d", "dtrack"] }
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2",  memory: 2Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities: { drop: ["ALL"] }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: dtrack-postgres-data }
---
apiVersion: v1
kind: Service
metadata:
  name: dtrack-postgres
  namespace: supply-chain
spec:
  clusterIP: None
  selector: { app.kubernetes.io/name: dtrack-postgres }
  ports:
    - { name: postgres, port: 5432, targetPort: 5432 }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dtrack-apiserver-data
  namespace: supply-chain
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi     # mirrored NVD/OSV/GitHub feeds live here
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dtrack-apiserver
  namespace: supply-chain
  labels: { app.kubernetes.io/name: dtrack-apiserver }
spec:
  replicas: 1                 # the API server is stateful (embedded index)
  strategy: { type: Recreate }
  selector:
    matchLabels: { app.kubernetes.io/name: dtrack-apiserver }
  template:
    metadata:
      labels: { app.kubernetes.io/name: dtrack-apiserver }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: apiserver
          image: dependencytrack/apiserver:4.12.7
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: ALPINE_DATABASE_MODE
              value: external
            - name: ALPINE_DATABASE_URL
              value: jdbc:postgresql://dtrack-postgres.supply-chain.svc.cluster.local:5432/dtrack
            - name: ALPINE_DATABASE_DRIVER
              value: org.postgresql.Driver
            - name: ALPINE_DATABASE_USERNAME
              valueFrom: { secretKeyRef: { name: dtrack-db, key: POSTGRES_USER } }
            - name: ALPINE_DATABASE_PASSWORD
              valueFrom: { secretKeyRef: { name: dtrack-db, key: POSTGRES_PASSWORD } }
            - name: ALPINE_DATA_DIRECTORY
              value: /data
            - name: ALPINE_METRICS_ENABLED
              value: "true"
            - name: EXTRA_JAVA_OPTIONS
              value: "-Xms2g -Xmx6g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: tmp,  mountPath: /tmp }
          startupProbe:
            httpGet: { path: /api/version, port: http }
            periodSeconds: 15
            failureThreshold: 40    # first boot mirrors NVD: this is slow
          readinessProbe:
            httpGet: { path: /api/version, port: http }
            periodSeconds: 15
            timeoutSeconds: 5
          livenessProbe:
            httpGet: { path: /api/version, port: http }
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          resources:
            requests: { cpu: "1",   memory: 4Gi }
            limits:   { cpu: "4",   memory: 8Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: dtrack-apiserver-data }
        - name: tmp
          emptyDir: { sizeLimit: 2Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: dtrack-apiserver
  namespace: supply-chain
spec:
  selector: { app.kubernetes.io/name: dtrack-apiserver }
  ports:
    - { name: http, port: 8080, targetPort: http }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dtrack-frontend
  namespace: supply-chain
spec:
  replicas: 2
  selector:
    matchLabels: { app.kubernetes.io/name: dtrack-frontend }
  template:
    metadata:
      labels: { app.kubernetes.io/name: dtrack-frontend }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: frontend
          image: dependencytrack/frontend:4.12.7
          ports:
            - { name: http, containerPort: 8080 }
          env:
            - name: API_BASE_URL
              value: https://dtrack.acme.example
          volumeMounts:
            - { name: nginx-cache, mountPath: /var/cache/nginx }
            - { name: nginx-run,   mountPath: /var/run }
          readinessProbe:
            httpGet: { path: /, port: http }
            periodSeconds: 10
          resources:
            requests: { cpu: 50m,  memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      volumes:
        - { name: nginx-cache, emptyDir: {} }
        - { name: nginx-run,   emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata:
  name: dtrack-frontend
  namespace: supply-chain
spec:
  selector: { app.kubernetes.io/name: dtrack-frontend }
  ports:
    - { name: http, port: 8080, targetPort: http }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dtrack
  namespace: supply-chain
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "64m"   # SBOMs are large
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [dtrack.acme.example]
      secretName: dtrack-tls
  rules:
    - host: dtrack.acme.example
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend: { service: { name: dtrack-apiserver, port: { number: 8080 } } }
          - path: /
            pathType: Prefix
            backend: { service: { name: dtrack-frontend, port: { number: 8080 } } }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dtrack-apiserver
  namespace: supply-chain
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: dtrack-apiserver }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
        - podSelector:
            matchLabels: { app.kubernetes.io/name: dtrack-frontend }
      ports: [{ protocol: TCP, port: 8080 }]
  egress:
    - to:
        - podSelector:
            matchLabels: { app.kubernetes.io/name: dtrack-postgres }
      ports: [{ protocol: TCP, port: 5432 }]
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    # Egress to the internet is required to mirror NVD/OSV/GitHub advisories.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.169.254/32]
      ports: [{ protocol: TCP, port: 443 }]
```

### 7.4 Admission control: rechazar imágenes sin un SBOM verificado

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-sbom-and-provenance
  annotations:
    policies.kyverno.io/title: Require signed SBOM and SLSA provenance
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Every first-party image admitted to prod or staging must carry a
      Sigstore-signed SPDX attestation produced by a release workflow on a
      protected tag, and SLSA build provenance naming an approved builder.
spec:
  validationFailureAction: Enforce   # Kyverno >=1.11; on newer releases confirm
                                     # whether your CRD expects a per-rule field
  background: false                  # image verification needs registry access
  failurePolicy: Fail                # fail closed
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-first-party-images
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [prod, staging]
      # Exempt the supply-chain tooling itself to avoid a bootstrap deadlock.
      exclude:
        any:
          - resources:
              namespaces: [kube-system, supply-chain]
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/*"
          required: true
          mutateDigest: true      # rewrite tag -> digest; TOCTOU protection
          verifyDigest: true
          imageRegistryCredentials:
            secrets: [ghcr-pull]

          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/*/.github/workflows/release.yml@refs/tags/v*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false

          attestations:
            # ---- 1. A signed SPDX SBOM must exist and be well-formed -------
            - type: https://spdx.dev/Document
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/*/.github/workflows/release.yml@refs/tags/v*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor: { url: https://rekor.sigstore.dev }
              conditions:
                - all:
                    - key: "{{ spdxVersion }}"
                      operator: AnyIn
                      value: ["SPDX-2.2", "SPDX-2.3"]
                    # An "SBOM" with three packages is an empty SBOM.
                    - key: "{{ packages | length(@) }}"
                      operator: GreaterThan
                      value: 10
                    - key: "{{ creationInfo.creators }}"
                      operator: AnyIn
                      value: ["Organization: Acme Corp"]

            # ---- 2. SLSA provenance from an approved builder ---------------
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/*/.github/workflows/release.yml@refs/tags/v*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor: { url: https://rekor.sigstore.dev }
              conditions:
                - all:
                    - key: "{{ buildDefinition.buildType }}"
                      operator: Equals
                      value: "https://actions.github.io/buildtypes/workflow/v1"
                    - key: "{{ runDetails.builder.id }}"
                      operator: AnyIn
                      value:
                        - "https://github.com/actions/runner/github-hosted"
                    - key: "{{ buildDefinition.externalParameters.workflow.repository }}"
                      operator: AnyIn
                      value:
                        - "https://github.com/acme/payments-api"
                        - "https://github.com/acme/ledger-api"
                        - "https://github.com/acme/notify-worker"
---
# Third-party images: no attestations available, so pin by digest instead.
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: third-party-images-must-be-digest-pinned
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-digest
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [prod, staging]
      validate:
        message: >-
          Third-party images must be referenced by immutable digest
          (name@sha256:...), never by a mutable tag.
        pattern:
          spec:
            =(initContainers):
              - image: "*@sha256:*"
            =(ephemeralContainers):
              - image: "*@sha256:*"
            containers:
              - image: "*@sha256:*"
```

Comportamiento en la admisión:

```bash
$ kubectl -n prod run rogue --image=ghcr.io/acme/payments-api:latest --restart=Never
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/rogue was blocked due to the following policies

require-signed-sbom-and-provenance:
  verify-first-party-images: |
    failed to verify image ghcr.io/acme/payments-api:latest:
    .attestors[0].entries[0].keyless: no matching attestations:
    none of the expected identities matched what was in the certificate

$ kubectl -n prod apply -f deploy/payments-api.yaml
deployment.apps/payments-api created

$ kubectl -n prod get deploy payments-api \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
ghcr.io/acme/payments-api@sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
# ^ mutateDigest rewrote the tag to the digest that was actually verified
```

### 7.5 Reevaluación continua: el CVE publicado *después* de que entregaste

El valor de un SBOM es que un CVE *nuevo* puede compararse contra un artefacto *viejo* sin recompilarlo.

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sbom-rescan
  namespace: supply-chain
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sbom-rescan-read-pods
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [list, get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sbom-rescan-read-pods
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sbom-rescan-read-pods
subjects:
  - kind: ServiceAccount
    name: sbom-rescan
    namespace: supply-chain
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: sbom-rescan
  namespace: supply-chain
spec:
  schedule: "17 3 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 5400
      template:
        spec:
          serviceAccountName: sbom-rescan
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: rescan
              image: ghcr.io/acme/supply-chain-toolbox:2026.09.1   # kubectl+cosign+grype+jq+curl
              command: [/bin/sh, -euo, pipefail, -c]
              args:
                - |
                  echo "== refreshing vulnerability DB =="
                  grype db update
                  grype db status

                  echo "== enumerating running first-party images =="
                  kubectl get pods -A \
                    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}' \
                    | grep -E '^ghcr\.io/acme/' \
                    | sed 's#^docker-pullable://##' \
                    | sort -u > /tmp/images.txt
                  wc -l < /tmp/images.txt

                  FAILED=0
                  while read -r IMG; do
                    [ -n "$IMG" ] || continue
                    echo "----- $IMG -----"

                    # Pull the SBOM we signed at build time; never re-derive it.
                    if ! cosign verify-attestation --type cyclonedx \
                         --certificate-identity-regexp "$IDENTITY_RE" \
                         --certificate-oidc-issuer "$OIDC_ISSUER" \
                         "$IMG" > /tmp/att.json 2>/tmp/att.err; then
                      echo "NO VERIFIED SBOM: $IMG"; cat /tmp/att.err
                      FAILED=1; continue
                    fi
                    jq -r '.payload' /tmp/att.json | base64 -d \
                      | jq '.predicate' > /tmp/sbom.cdx.json

                    grype "sbom:/tmp/sbom.cdx.json" -o json > /tmp/result.json || true
                    CRIT=$(jq '[.matches[] | select(.vulnerability.severity=="Critical")] | length' /tmp/result.json)
                    HIGH=$(jq '[.matches[] | select(.vulnerability.severity=="High")]     | length' /tmp/result.json)
                    echo "critical=$CRIT high=$HIGH"

                    if [ "$CRIT" -gt 0 ]; then
                      jq -n --arg img "$IMG" --argjson crit "$CRIT" --argjson high "$HIGH" \
                        '{text: "🔴 New CRITICAL findings in a RUNNING image\n\($img)\ncritical=\($crit) high=\($high)"}' \
                        | curl -sS -X POST -H 'Content-Type: application/json' -d @- "$ALERT_WEBHOOK" >/dev/null
                      FAILED=1
                    fi
                  done < /tmp/images.txt
                  exit "$FAILED"
              env:
                - name: IDENTITY_RE
                  value: '^https://github\.com/acme/[^/]+/\.github/workflows/release\.yml@refs/tags/v.+$'
                - name: OIDC_ISSUER
                  value: https://token.actions.githubusercontent.com
                - name: ALERT_WEBHOOK
                  valueFrom: { secretKeyRef: { name: alerting, key: webhook } }
                - name: GRYPE_DB_CACHE_DIR
                  value: /tmp/grype-db
              volumeMounts:
                - { name: tmp, mountPath: /tmp }
              resources:
                requests: { cpu: 500m, memory: 1Gi }
                limits:   { cpu: "2",  memory: 4Gi }
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: ["ALL"] }
          volumes:
            - name: tmp
              emptyDir: { sizeLimit: 8Gi }
```

### 7.6 Renovate: cerrar el círculo sobre la actualidad de las dependencias

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":dependencyDashboard",
    ":semanticCommits",
    "helpers:pinGitHubActionDigests"
  ],
  "timezone": "Etc/UTC",
  "schedule": ["after 2am and before 6am every weekday"],
  "prConcurrentLimit": 8,
  "prHourlyLimit": 4,
  "rangeStrategy": "pin",
  "postUpdateOptions": ["gomodTidy", "npmDedupe"],
  "osvVulnerabilityAlerts": true,
  "vulnerabilityAlerts": {
    "enabled": true,
    "schedule": ["at any time"],
    "labels": ["security", "priority/critical"],
    "prPriority": 10,
    "minimumReleaseAge": null
  },
  "packageRules": [
    {
      "description": "Cooling-off period defeats compromised-release attacks (event-stream, xz)",
      "matchUpdateTypes": ["minor", "patch"],
      "minimumReleaseAge": "5 days"
    },
    {
      "description": "Group all patch-level Go module bumps into one reviewable PR",
      "matchManagers": ["gomod"],
      "matchUpdateTypes": ["patch"],
      "groupName": "go modules (patch)"
    },
    {
      "description": "Major bumps require an explicit human decision",
      "matchUpdateTypes": ["major"],
      "dependencyDashboardApproval": true,
      "labels": ["needs-architecture-review"]
    },
    {
      "description": "Never auto-follow a project that relicensed away from OSI",
      "matchPackageNames": [
        "github.com/hashicorp/terraform",
        "github.com/hashicorp/vault",
        "github.com/hashicorp/consul"
      ],
      "enabled": false
    },
    {
      "description": "Base images: track digests, not tags",
      "matchDatasources": ["docker"],
      "pinDigests": true
    }
  ],
  "customManagers": [
    {
      "customType": "regex",
      "description": "Keep tool versions in workflow env blocks up to date",
      "managerFilePatterns": ["/^\\.github/workflows/.+\\.ya?ml$/"],
      "matchStrings": [
        "#\\s*renovate:\\s*datasource=(?<datasource>\\S+)\\s+depName=(?<depName>\\S+)\\s*\\n\\s*\\w+:\\s*[\"']?(?<currentValue>v?[\\d.]+)[\"']?"
      ]
    }
  ]
}
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 La tabla de triage

| Síntoma | Causa más probable | Comando de diagnóstico | Solución |
|---|---|---|---|
| El SBOM tiene 0–3 paquetes | se escaneó una imagen scratch/distroless sin DB de paquetes; objetivo de escaneo equivocado | `syft scan <img> -o table \| wc -l` | escanear también la etapa de build, o usar el SBOM del sistema de build y fusionar |
| Grype reporta 0 vulnerabilidades en una imagen que se sabe vulnerable | DB desactualizada o faltante; los componentes carecen tanto de purl como de CPE | `grype db status`; `jq '.artifacts[] \| select(.cpes==[])' sbom.syft.json` | `grype db update`; `add-cpes-if-none: true` |
| El binario Go muestra versión `(devel)` | compilado sin estampado de VCS o desde un árbol sucio | `go version -m ./bin/app` | compilar con `-buildvcs=true` e inyectar `-X main.version=` |
| `log4j-core` invisible en un fat JAR | clases shaded/relocalizadas; sin POM adentro | `unzip -l app.jar \| grep -i log4j`; `jar tf app.jar \| grep JndiLookup` | SBOM en tiempo de build vía `cyclonedx-maven-plugin`; `--search-unindexed-archives` |
| Miles de hallazgos en npm | `node_modules` todavía contiene devDependencies | `npm ls --omit=dev --all \| wc -l` | `npm ci --omit=dev` antes del escaneo; build multietapa |
| Todas las licencias en `NOASSERTION` | detección solo por metadatos; no hay texto de `LICENSE` presente | `scancode --license …` sobre el código fuente | correr ScanCode/ORT; agregar curations |
| La política bloquea el JDK por «GPL» | matching por subcadena que ignora `WITH Classpath-exception-2.0` | `jq '.components[].licenses' sbom.cdx.json` | parsear la expresión SPDX, permitir explícitamente la excepción |
| `cosign verify` → `no matching signatures` | regexp de identidad / emisor equivocados, o imagen sin firmar | ver §8.4 | corregir la regexp; revisar el tlog |
| `cosign verify-attestation` → `no matching attestations` | se atestó un digest distinto, o `--type` equivocado | `crane digest`; `cosign tree` | atestar el digest, no el tag |
| Trivy `TOOMANYREQUESTS` al bajar la DB | límite de tasa anónimo de ghcr.io | `trivy image --debug` | espejar la DB (`db.repository`) |
| Subida a Dependency-Track → HTTP 400 | versión del spec CycloneDX más nueva que la release de DT | `curl -v … ; jq '.specVersion'` | bajar la salida (`-o cyclonedx-json@1.5`) o actualizar DT |
| VEX ignorado, el hallazgo sigue apareciendo | el `@id` del producto no coincide exactamente con el purl del artefacto | ver §8.7 | hacer que los purl sean idénticos byte a byte |
| Kyverno admite una imagen sin firmar | regla con `background: true` + `failurePolicy: Ignore`; timeout del webhook | `kubectl logs -n kyverno deploy/kyverno-admission-controller` | `background: false`, `failurePolicy: Fail` |

### 8.2 Demostrar que el SBOM no está vacío *antes* de confiar en un escaneo en verde

El resultado más peligroso de este pipeline es un **SBOM estructuralmente válido y semánticamente vacío**: todos los gates posteriores pasan.

```bash
$ jq -r '
    {
      spdx_version: .spdxVersion,
      packages: (.packages | length),
      with_purl: ([ .packages[] | select(
                      (.externalRefs // []) | map(.referenceType=="purl") | any) ] | length),
      with_version: ([ .packages[]
                       | select(.versionInfo != null and .versionInfo != "NOASSERTION") ] | length),
      relationships: (.relationships | length),
      noassertion_licence: ([ .packages[]
                       | select(.licenseConcluded=="NOASSERTION"
                                and .licenseDeclared=="NOASSERTION") ] | length)
    }' sbom.spdx.json
{
  "spdx_version": "SPDX-2.3",
  "packages": 312,
  "with_purl": 312,
  "with_version": 311,
  "relationships": 313,
  "noassertion_licence": 6
}
```

Convertí eso en un gate duro:

```bash
#!/usr/bin/env bash
# scripts/assert-sbom-quality.sh
set -euo pipefail
SBOM="${1:?usage: assert-sbom-quality.sh <sbom.spdx.json>}"
MIN_PACKAGES="${MIN_PACKAGES:-25}"
MAX_UNKNOWN_LICENCE_PCT="${MAX_UNKNOWN_LICENCE_PCT:-10}"

total=$(jq '.packages | length' "$SBOM")
purl=$(jq '[ .packages[] | select((.externalRefs // []) | map(.referenceType=="purl") | any) ] | length' "$SBOM")
unknown=$(jq '[ .packages[] | select(.licenseConcluded=="NOASSERTION" and .licenseDeclared=="NOASSERTION") ] | length' "$SBOM")

echo "packages=${total} with_purl=${purl} unknown_licence=${unknown}"

(( total >= MIN_PACKAGES )) || { echo "FAIL: only ${total} packages (< ${MIN_PACKAGES})"; exit 1; }
(( purl == total ))         || { echo "FAIL: $((total - purl)) packages have no purl"; exit 1; }
pct=$(( unknown * 100 / total ))
(( pct <= MAX_UNKNOWN_LICENCE_PCT )) || { echo "FAIL: ${pct}% unknown licences (> ${MAX_UNKNOWN_LICENCE_PCT}%)"; exit 1; }
echo "SBOM quality gate: PASS"
```

```bash
$ MIN_PACKAGES=25 ./scripts/assert-sbom-quality.sh sbom.spdx.json
packages=312 with_purl=312 unknown_licence=6
SBOM quality gate: PASS

$ ./scripts/assert-sbom-quality.sh /tmp/scratch-image.spdx.json
packages=1 with_purl=1 unknown_licence=1
FAIL: only 1 packages (< 25)
$ echo $?
1
```

### 8.3 Diagnosticar componentes faltantes en una imagen distroless / scratch

```bash
# Symptom: 312 packages in the builder stage, 1 in the final image
$ syft scan registry:ghcr.io/acme/payments-api:1.24.3 -o table
NAME          VERSION   TYPE
payments-api  1.24.3    go-module

# Why: no OS package DB exists in the final layer
$ crane export ghcr.io/acme/payments-api:1.24.3 - | tar -tf - | grep -E 'var/lib/dpkg|lib/apk/db|var/lib/rpm' | head
(no output)

# But the Go module graph IS embedded in the binary
$ crane export ghcr.io/acme/payments-api:1.24.3 - \
    | tar -xO usr/local/bin/payments-api > /tmp/payments-api
$ go version -m /tmp/payments-api | head -20
/tmp/payments-api: go1.23.6
	path	github.com/acme/payments-api/cmd/payments-api
	mod	github.com/acme/payments-api	v1.24.3	h1:6C3g…=
	dep	github.com/gorilla/mux	v1.8.1	h1:TuBL49tXwgrFYWhqrNgrUNEY92u81SPhu7sTdzQEiWY=
	dep	google.golang.org/grpc	v1.68.1	h1:oI5oTa11+ng8r8XvFCLQVs1TR1S…=
	build	-buildmode=exe
	build	-compiler=gc
	build	-trimpath=true
	build	CGO_ENABLED=0
	build	vcs=git
	build	vcs.revision=7ab3c19d4e0f5a6b8c2d1e0f9a8b7c6d5e4f3a21
	build	vcs.time=2026-09-03T09:08:11Z
	build	vcs.modified=false

# If `mod` shows "(devel)" instead of v1.24.3, VCS stamping is missing:
$ go build -buildvcs=true -ldflags "-X main.version=$(git describe --tags)" ./cmd/payments-api
```

**Solución:** emitir el SBOM también desde la etapa *builder* y fusionarlos:

```bash
$ docker build --target build -t payments-api:builder .
$ syft scan docker:payments-api:builder     -o cyclonedx-json=sbom.build.json
$ syft scan registry:ghcr.io/acme/payments-api:1.24.3 -o cyclonedx-json=sbom.image.json
$ cyclonedx-cli merge --input-files sbom.build.json sbom.image.json \
                      --output-file sbom.merged.json --hierarchical \
                      --name payments-api --version 1.24.3
$ jq '.components | length' sbom.build.json sbom.image.json sbom.merged.json
298
1
299
```

### 8.4 Diagnosticar fallas de firma y de atestación

```bash
$ cosign verify \
    --certificate-identity-regexp 'github.com/acme/payments-api' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/acme/payments-api:1.24.3

Error: no matching signatures:
main.go:74: error during command execution: no matching signatures
```

Bajá por la escalera:

```bash
# 1. Does ANY signature exist for this digest?
$ cosign tree ghcr.io/acme/payments-api:1.24.3
📦 Supply Chain Security Related artifacts for an image: ghcr.io/acme/payments-api:1.24.3
└── 💾 Attestations for an image tag: ghcr.io/acme/payments-api:sha256-9f2b3c….att
   ├── 🍒 sha256:c8b1e4d7a2f905638e1c0b7a4d3f296e8c5b0a1d7f3e6c9b2a4d8f1e0c7b3a56
   └── 🍒 sha256:e1f0a9d8c7b6a5948372615f4e3d2c1b0a9f8e7d6c5b4a39281706f5e4d3c2b1
└── 🔐 Signatures for an image tag: ghcr.io/acme/payments-api:sha256-9f2b3c….sig
   └── 🍒 sha256:a4f7d2c9e0b18365d4c7a0f3e6b9d2c5a8f1e4d7c0b3a6f9e2d5c8b1a4f7e0d3

# 2. Signature exists → the identity is wrong. Read the certificate directly.
$ cosign verify --insecure-ignore-tlog=true --certificate-identity-regexp '.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/acme/payments-api:1.24.3 2>/dev/null \
  | jq -r '.[0].optional.Subject, .[0].optional.Issuer'
https://github.com/acme/payments-api/.github/workflows/build-nightly.yml@refs/heads/main
https://token.actions.githubusercontent.com
# ^ signed by the NIGHTLY workflow, not release.yml. The policy is correct;
#   the artifact is not the one the policy is meant to admit.

# 3. Confirm independently in the transparency log
$ rekor-cli search --sha sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
Found matching entries (listed by UUID):
24296fb24b8ad77a1f9c0e4b7d2a5638e0c1b4a7f3d6e9c2b5a8f1d4e7c0b3a6f92d8e1c4b7a0f3e6

$ rekor-cli get --uuid 24296fb24b8ad77a…0f3e6 --format json \
  | jq -r '.Body.HashedRekordObj.signature.publicKey.content' \
  | base64 -d | openssl x509 -noout -text \
  | grep -A3 'X509v3 Subject Alternative Name'
            X509v3 Subject Alternative Name: critical
                URI:https://github.com/acme/payments-api/.github/workflows/build-nightly.yml@refs/heads/main
```

Fallas específicas de atestaciones:

```bash
# Wrong predicate type
$ cosign verify-attestation --type slsaprovenance ghcr.io/acme/payments-api@sha256:9f2b3c… \
    --certificate-identity-regexp '…' --certificate-oidc-issuer '…'
Error: none of the attestations matched the predicate type: slsaprovenance
# SLSA v1.0 uses https://slsa.dev/provenance/v1 ; "slsaprovenance" is the v0.2 alias.
$ cosign verify-attestation --type "https://slsa.dev/provenance/v1" …

# Attested the tag, deployed the digest (or vice versa)
$ crane digest ghcr.io/acme/payments-api:1.24.3
sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
$ jq -r '.payload' attestation.json | base64 -d | jq -r '.subject[].digest.sha256'
b7e1a4c9d2f0836e5a1c4b7d0f3e6a9c2b5d8f1e4a7c0b3d6f9e2a5c8b1d4f7e0
# ^ mismatch: the tag was moved after attestation. Always attest and deploy
#   the same @sha256: reference; never a tag.
```

### 8.5 Problemas del lado del registry

```bash
# OCI 1.1 referrers API unsupported by an older registry
$ cosign attest --yes --type spdxjson --predicate sbom.spdx.json \
    registry.internal.acme.example/payments-api@sha256:9f2b3c…
Error: recursively copying attestation: PUT https://registry.internal.acme.example/v2/…/referrers/sha256:9f2b3c…:
  UNSUPPORTED: The operation is unsupported

# Fall back to the tag-based fallback scheme
$ COSIGN_EXPERIMENTAL=0 cosign attest --yes --registry-referrers-mode=legacy \
    --type spdxjson --predicate sbom.spdx.json registry.internal.acme.example/payments-api@sha256:9f2b3c…

# The fallback stores attestations at a derived tag:
$ crane ls registry.internal.acme.example/payments-api | grep sha256-
sha256-9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e.att
sha256-9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e.sig
# ⚠️ A registry garbage-collection or "delete untagged manifests" policy will
#    silently destroy these. Exclude *.att / *.sig / *.sbom from GC rules.
```

### 8.6 purl vs CPE: la máquina de falsos negativos

```bash
# A Go module with no CPE: NVD-only matchers will never see it
$ jq -r '
    .artifacts[]
    | select(.type=="go-module" and (.cpes | length)==0)
    | "\(.name)\t\(.version)\tpurl=\(.purl)\tcpes=\(.cpes|length)"
  ' sbom.syft.json | head -5
github.com/gorilla/mux	v1.8.1	purl=pkg:golang/github.com/gorilla/mux@v1.8.1	cpes=0
google.golang.org/grpc	v1.68.1	purl=pkg:golang/google.golang.org/grpc@v1.68.1	cpes=0

# Compare matcher coverage
$ grype sbom:./sbom.cdx.json -o json | jq '[.matches[].vulnerability.id] | length'
37
$ grype sbom:./sbom.cdx.json --add-cpes-if-none -o json | jq '[.matches[].vulnerability.id] | length'
44

# Cross-check the same lockfile against OSV, whose native key is the purl
$ osv-scanner scan source --lockfile=go.mod --format=json . \
  | jq -r '[.results[].packages[].vulnerabilities[]?.id] | unique | length'
9
```

> **Regla operativa:** ejecutá al menos dos matchers con fuentes de datos distintas (grype ⇒ GitHub Security Advisories + feeds de distros + NVD; osv-scanner ⇒ OSV.dev). Su unión es el conjunto de hallazgos; su intersección es el conjunto de alta confianza. Un único matcher es un punto único de falla para la *detección*, y las fallas de detección son silenciosas.

### 8.7 VEX que no se aplica

```bash
$ grype sbom:./sbom.cdx.json --vex vex.json --show-suppressed -o json \
  | jq '[.matches[] | select(.vulnerability.id=="CVE-2023-45853")] | length'
1          # still present — VEX did not match

# Compare the identifiers byte for byte
$ jq -r '.statements[].products[]."@id"' vex.json
pkg:oci/payments-api@sha256:9f2b3c…?repository_url=ghcr.io/acme/payments-api

$ jq -r '.metadata.component.purl' sbom.cdx.json
pkg:oci/payments-api@sha256:9f2b3c…?repository_url=ghcr.io%2Facme%2Fpayments-api
#                                                             ^^^ percent-encoded

# purl qualifier values must be percent-encoded per the purl spec.
$ jq '(.statements[].products[]."@id") |=
        sub("repository_url=ghcr\\.io/acme/payments-api";
            "repository_url=ghcr.io%2Facme%2Fpayments-api")' vex.json > vex.fixed.json

$ grype sbom:./sbom.cdx.json --vex vex.fixed.json --show-suppressed -o table \
  | grep CVE-2023-45853
zlib1g  1:1.2.13.dfsg-1  deb  CVE-2023-45853  High (suppressed by VEX)
```

### 8.8 Entornos air-gapped y con límite de tasa

```bash
# Symptom
$ trivy image ghcr.io/acme/payments-api:1.24.3
2026-09-03T11:02:19Z    FATAL   Fatal error   init error: DB error: failed to download vulnerability DB:
  OCI repository error: 1 error occurred:
	* GET https://ghcr.io/v2/aquasecurity/trivy-db/manifests/2: TOOMANYREQUESTS: retry-after=…

# Fix: mirror the DB into the internal registry once per day, then point at it
$ oras copy ghcr.io/aquasecurity/trivy-db:2 \
            registry.internal.acme.example/mirror/trivy-db:2
Copying  ba1c4e7d9f02 db.tar.gz
Copied  [================================================] 58.4/58.4 MB
Digest: sha256:d3c9b0a7f1e4628d5c0b3a6f9e2d5c8b1a4f7e0d3c6b9a2f5e8d1c4b7a0f3e69

$ export TRIVY_DB_REPOSITORY=registry.internal.acme.example/mirror/trivy-db:2
$ export TRIVY_JAVA_DB_REPOSITORY=registry.internal.acme.example/mirror/trivy-java-db:1
$ trivy image --skip-db-update=false ghcr.io/acme/payments-api:1.24.3
2026-09-03T11:05:02Z    INFO    Downloading DB   repository="registry.internal.acme.example/mirror/trivy-db:2"

# Grype, air-gapped
$ grype db update -o json > /dev/null            # on a connected host
$ tar -czf grype-db-$(date +%F).tar.gz -C ~/.cache/grype/db .
# transfer, then on the air-gapped host:
$ grype db import ./grype-db-2026-09-03.tar.gz
$ GRYPE_DB_AUTO_UPDATE=false grype sbom:./sbom.cdx.json

# osv-scanner, offline
$ osv-scanner --download-offline-databases scan source --offline .
```

### 8.9 El script completo de verificación de punta a punta

```bash
#!/usr/bin/env bash
# scripts/verify-release.sh — run this against a candidate before promotion.
set -euo pipefail

IMAGE_REPO="${1:?usage: verify-release.sh <repo> <tag>}"
TAG="${2:?}"
IDENTITY_RE='^https://github\.com/acme/[^/]+/\.github/workflows/release\.yml@refs/tags/v.+$'
OIDC_ISSUER='https://token.actions.githubusercontent.com'

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "1. Resolve tag -> immutable digest"
DIGEST="$(crane digest "${IMAGE_REPO}:${TAG}")"
REF="${IMAGE_REPO}@${DIGEST}"
echo "$REF"

step "2. Verify the image signature"
cosign verify --certificate-identity-regexp "$IDENTITY_RE" \
              --certificate-oidc-issuer "$OIDC_ISSUER" "$REF" > /dev/null
echo "signature OK"

step "3. Verify and extract the SPDX attestation"
cosign verify-attestation --type spdxjson \
  --certificate-identity-regexp "$IDENTITY_RE" \
  --certificate-oidc-issuer "$OIDC_ISSUER" "$REF" \
  | jq -r '.payload' | base64 -d > /tmp/spdx-statement.json
jq -r '.predicate' /tmp/spdx-statement.json > /tmp/sbom.spdx.json

step "4. Confirm the attestation is bound to THIS digest"
SUBJ="$(jq -r '.subject[0].digest.sha256' /tmp/spdx-statement.json)"
[ "sha256:${SUBJ}" = "$DIGEST" ] || { echo "FAIL: subject/digest mismatch"; exit 1; }
echo "subject binding OK"

step "5. SBOM quality gate"
MIN_PACKAGES=25 ./scripts/assert-sbom-quality.sh /tmp/sbom.spdx.json

step "6. Verify SLSA provenance"
cosign verify-attestation --type "https://slsa.dev/provenance/v1" \
  --certificate-identity-regexp "$IDENTITY_RE" \
  --certificate-oidc-issuer "$OIDC_ISSUER" "$REF" \
  | jq -r '.payload' | base64 -d \
  | jq -e '.predicate.runDetails.builder.id
           | test("^https://github.com/actions/runner/")' > /dev/null
echo "provenance builder OK"

step "7. Vulnerability gate against the fresh DB"
grype db update >/dev/null
grype "sbom:/tmp/sbom.spdx.json" --config .grype.yaml \
      --vex ./vex/payments-api.openvex.json --fail-on high -o table

step "8. Licence gate"
jq -r '
  [ .packages[].licenseDeclared ] | unique | .[]
  | select(test("AGPL|SSPL|BUSL|Elastic-2\\.0|CC-BY-NC"))
' /tmp/sbom.spdx.json > /tmp/forbidden.txt || true
if [ -s /tmp/forbidden.txt ]; then
  echo "FAIL: forbidden licences present:"; cat /tmp/forbidden.txt; exit 1
fi
echo "licence gate OK"

printf '\n\033[1;32mRELEASE VERIFICATION PASSED: %s\033[0m\n' "$REF"
```

```bash
$ ./scripts/verify-release.sh ghcr.io/acme/payments-api 1.24.3

== 1. Resolve tag -> immutable digest ==
sha256:9f2b3c7d1e4a5b6c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e
ghcr.io/acme/payments-api@sha256:9f2b3c…

== 2. Verify the image signature ==
signature OK

== 3. Verify and extract the SPDX attestation ==

== 4. Confirm the attestation is bound to THIS digest ==
subject binding OK

== 5. SBOM quality gate ==
packages=312 with_purl=312 unknown_licence=6
SBOM quality gate: PASS

== 6. Verify SLSA provenance ==
provenance builder OK

== 7. Vulnerability gate against the fresh DB ==
 ✔ Scanned for vulnerabilities     [36 vulnerability matches]
   ├── by severity: 0 critical, 0 high, 18 medium, 16 low, 2 negligible (1 suppressed)
   └── by status:   20 fixed, 16 not-fixed

== 8. Licence gate ==
licence gate OK

RELEASE VERIFICATION PASSED: ghcr.io/acme/payments-api@sha256:9f2b3c…
$ echo $?
0
```

---

## 9. Resumen de decisiones arquitectónicas

| Decisión | Elegí esto | Porque |
|---|---|---|
| Formato de SBOM | emitir **ambos**, SPDX 2.3 y CycloneDX 1.6 | los consumidores están divididos; el costo marginal es un flag `-o` extra |
| Punto de generación del SBOM | etapa de build **y** etapa de imagen, fusionados | ninguno por separado ve a la vez las deps del lenguaje y las del OS |
| Mecanismo de adjunción | atestación in-toto en un envoltorio DSSE vía cosign | vincula el SBOM a un digest y a una identidad de firma |
| Firma | Sigstore keyless con identidad de carga de trabajo OIDC | no hay clave de larga vida que filtrar o rotar; la identidad es el workflow |
| Control de ruido | **VEX**, nunca listas de exclusión del escáner | VEX está firmado, fechado, justificado y se comparte con los clientes |
| Almacenamiento | Dependency-Track (o equivalente) como inventario consultable | la respuesta a incidentes debe ser una consulta a una base de datos, no N ejecuciones de pipeline |
| Aplicación | admission control que verifica atestaciones + `mutateDigest` | cierra la ventana TOCTOU de mutación de tags |
| Detección de licencias | escaneo de metadatos en CI, ScanCode/ORT en la release | los metadatos declarados se pierden el código vendorizado |
| Política de licencias | parseo de **expresiones** SPDX, nunca matching por subcadena | de otro modo, tanto `WITH Classpath-exception-2.0` como `OR` se manejan mal |
| Modelo de contribución | DCO, salvo que relicenciar sea un requisito real | la fricción del CLA es un costo medible de adquisición de contribuyentes |
| Actualidad de dependencias | Renovate con un período de enfriamiento `minimumReleaseAge` | frustra los ataques por release comprometida y aun así te mantiene al día |
| Retención | los SBOM sobreviven al artefacto (≥ la ventana de soporte) | te van a preguntar por una release de hace dos años |

### Términos y utilidades

`SPDX` · `CycloneDX` · `SWID` · `purl` · `CPE` · `CVE` · `CVSS` · `EPSS` · `OSV` · `VEX` · `OpenVEX` · `CSAF` · `SLSA` · `in-toto` · `DSSE` · `Sigstore` · `Fulcio` · `Rekor` · `SCA` · `OSPO` · `DCO` · `CLA` · `REUSE` · copyleft (fuerte/débil/de red) · compatibilidad de licencias · fases del ciclo de vida del SBOM
`syft` · `grype` · `trivy` · `osv-scanner` · `cdxgen` · `scancode` · `ort` · `reuse` · `cosign` · `rekor-cli` · `slsa-verifier` · `vexctl` · `crane` · `oras` · `go-licenses` · `licensee` · `cyclonedx-cli` · `dependency-track` · `renovate`

---

## 10. Referencias

**Objetivos del examen**
- LPI DevOps Tools Engineer — Objetivos del examen 701: https://www.lpi.org/our-certifications/exam-701-objectives/
- Panorama general de LPI DevOps Tools Engineer: https://www.lpi.org/our-certifications/devops-overview/

**Definición de open source y licencias**
- Open Source Definition (OSI): https://opensource.org/osd
- Licencias aprobadas por la OSI: https://opensource.org/licenses
- Lista de licencias SPDX: https://spdx.org/licenses/
- Expresiones de licencia SPDX (Anexo D, SPDX 2.3): https://spdx.github.io/spdx-spec/v2.3/SPDX-license-expressions/
- Lista y comentarios de licencias de GNU: https://www.gnu.org/licenses/license-list.html
- FAQ de la GPL de GNU (enlazado, transmisión, uso en red): https://www.gnu.org/licenses/gpl-faq.html
- GNU GPL v3: https://www.gnu.org/licenses/gpl-3.0.en.html
- GNU AGPL v3: https://www.gnu.org/licenses/agpl-3.0.en.html
- GNU LGPL v3: https://www.gnu.org/licenses/lgpl-3.0.en.html
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
- Política de licenciamiento de terceros de la ASF: https://www.apache.org/legal/resolved.html
- FAQ de la Mozilla Public License 2.0: https://www.mozilla.org/en-US/MPL/2.0/FAQ/
- Business Source License 1.1: https://mariadb.com/bsl11/
- Server Side Public License: https://www.mongodb.com/legal/licensing/server-side-public-license

**Contribución y cumplimiento a nivel de archivo**
- Developer Certificate of Origin 1.1: https://developercertificate.org/
- ICLA/CCLA de Apache: https://www.apache.org/licenses/contributor-agreements.html
- Especificación REUSE: https://reuse.software/spec/
- Herramientas REUSE: https://reuse.software/dev/

**Especificaciones de SBOM**
- Proyecto SPDX: https://spdx.dev/
- Especificación SPDX 2.3: https://spdx.github.io/spdx-spec/v2.3/
- Especificación SPDX 3.0: https://spdx.github.io/spdx-spec/v3.0.1/
- Panorama general de la especificación CycloneDX: https://cyclonedx.org/specification/overview/
- Referencia JSON de CycloneDX 1.6: https://cyclonedx.org/docs/1.6/json/
- Casos de uso de CycloneDX: https://cyclonedx.org/use-cases/
- Especificación de Package URL (purl): https://github.com/package-url/purl-spec
- Recursos de SBOM de CISA: https://www.cisa.gov/sbom
- NTIA «The Minimum Elements For a Software Bill of Materials»: https://www.ntia.gov/report/2021/minimum-elements-software-bill-materials-sbom

**Datos de vulnerabilidad y explotabilidad**
- Base de datos OSV: https://osv.dev/
- Esquema OSV: https://ossf.github.io/osv-schema/
- National Vulnerability Database: https://nvd.nist.gov/
- Programa CVE: https://www.cve.org/
- Especificación CVSS v4.0: https://www.first.org/cvss/v4-0/specification-document
- EPSS: https://www.first.org/epss/
- Especificación OpenVEX: https://github.com/openvex/spec
- CSAF 2.0 (estándar OASIS, incluye el perfil VEX): https://docs.oasis-open.org/csaf/csaf/v2.0/csaf-v2.0.html
- CISA «Minimum Requirements for Vulnerability Exploitability eXchange (VEX)»: https://www.cisa.gov/resources-tools/resources/minimum-requirements-vulnerability-exploitability-exchange-vex

**Integridad de la cadena de suministro**
- Especificación SLSA v1.0: https://slsa.dev/spec/v1.0/
- Predicado de procedencia de SLSA: https://slsa.dev/spec/v1.0/provenance
- in-toto Attestation Framework: https://github.com/in-toto/attestation
- DSSE (Dead Simple Signing Envelope): https://github.com/secure-systems-lab/dsse
- Documentación de Sigstore: https://docs.sigstore.dev/
- cosign: https://github.com/sigstore/cosign
- slsa-verifier: https://github.com/slsa-framework/slsa-verifier
- OpenSSF Scorecard: https://scorecard.dev/
- NIST SP 800-218 (Secure Software Development Framework): https://csrc.nist.gov/pubs/sp/800/218/final
- Executive Order 14028: https://www.federalregister.gov/d/2021-10460
- Cyber Resilience Act de la UE (Reglamento 2024/2847): https://eur-lex.europa.eu/eli/reg/2024/2847/oj

**Herramientas**
- syft: https://github.com/anchore/syft
- grype: https://github.com/anchore/grype
- Documentación de Trivy: https://trivy.dev/latest/docs/
- osv-scanner: https://google.github.io/osv-scanner/
- cdxgen: https://github.com/CycloneDX/cdxgen
- CycloneDX CLI: https://github.com/CycloneDX/cyclonedx-cli
- ScanCode Toolkit: https://scancode-toolkit.readthedocs.io/
- OSS Review Toolkit (ORT): https://oss-review-toolkit.org/ort/
- FOSSology: https://www.fossology.org/
- Dependency-Track: https://docs.dependencytrack.org/
- Verificación de imágenes en Kyverno: https://kyverno.io/docs/writing-policies/verify-images/
- Renovate: https://docs.renovatebot.com/
- go-licenses: https://github.com/google/go-licenses
- crane / go-containerregistry: https://github.com/google/go-containerregistry
- ORAS: https://oras.land/docs/
- OCI Image Specification: https://github.com/opencontainers/image-spec
- OCI Distribution Specification (referrers API): https://github.com/opencontainers/distribution-spec