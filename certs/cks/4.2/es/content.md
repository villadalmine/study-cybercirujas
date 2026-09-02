# CKS 4.2 — Entendé tu cadena de suministro (SBOM, CI/CD, repositorios de artefactos)

> **Dominio:** Supply Chain Security · **Peso de este objetivo en el examen:** 5 · **Temario:** CKS v1.34

---

## 1. El problema en producción

### 1.1 Por qué existe este objetivo

Un clúster de Kubernetes es, desde la perspectiva de un atacante, un **motor automatizado de ejecución de binarios de terceros arbitrarios**. El trabajo del kubelet es traer un blob desde un endpoint de red, desempaquetarlo en un nodo y ejecutarlo como PID 1 de un namespace con los privilegios que el PodSpec haya pedido. Todos los controles que aprendés en los demás dominios de CKS — RBAC, NetworkPolicy, seccomp, AppArmor, Pod Security Standards — asumen que *aquello que estás confinando es aquello que pretendías ejecutar*. La seguridad de la cadena de suministro es la disciplina que hace verdadera esa suposición.

El modo de fallo no es teórico:

| Incidente | Año | Punto de compromiso (amenaza SLSA) | Lección relevante para Kubernetes |
|---|---|---|---|
| SolarWinds / SUNBURST | 2020 | (D) Proceso de build comprometido | Artefactos firmados por un proveedor de confianza eran maliciosos. Firma ≠ seguridad; hace falta *procedencia* sobre **cómo** fue construido. |
| Codecov Bash Uploader | 2021 | (F) Subida de un paquete modificado | Una única URL de script mutable, sin pinning, exfiltró variables de entorno de CI. Cada `curl \| bash` en un pipeline es una primitiva de ejecución remota de código sin autenticar. |
| `event-stream` / `ua-parser-js` | 2018/2021 | (E) Dependencia comprometida | Dependencia transitiva que nunca elegiste. Solo un SBOM te permite responder "¿estoy afectado?" en minutos en vez de semanas. |
| Dependency confusion | 2021 | (E)/(G) Orden de resolución del registro | Nombres de paquetes internos resolubles desde un índice público. Aplica literalmente a los registros de contenedores y a los repos de Helm. |
| Backdoor en `xz-utils` (CVE-2024-3094) | 2024 | (B)/(C) Repo de fuentes + script de build | El payload malicioso estaba presente únicamente en el **tarball de release**, no en git. Construir desde la fuente de verdad (SLSA L3) es lo que detecta esta clase de ataque. |
| Log4Shell (CVE-2021-44228) | 2021 | (H) Consumo | No fue un compromiso en absoluto — un CVE ordinario. Pero las organizaciones sin SBOM tardaron **semanas** en enumerar su exposición; las que tenían SBOM tardaron **minutos**. |

### 1.2 Las cuatro preguntas

"Entender tu cadena de suministro" se reduce operativamente a cuatro preguntas que un equipo de plataforma debe poder responder **sobre cualquier contenedor que esté corriendo ahora mismo en producción, en minutos, sin preguntarle a un desarrollador**:

1. **¿Qué hay adentro?** → SBOM (Software Bill of Materials)
2. **¿De dónde vino?** → Repositorio de artefactos + referencia inmutable por digest
3. **¿Cómo fue construido?** → Atestación de procedencia (in-toto / SLSA)
4. **¿Quién responde por él, y ese respaldo sigue siendo válido?** → Firma + log de transparencia + verificación en tiempo de admisión

Si falta cualquiera de las cuatro, la cadena tiene un agujero. Las secciones siguientes construyen la respuesta a cada una, y después cierran el círculo con la aplicación del lado del clúster.

### 1.3 El mapa arquitectónico

```
   ┌─────────────┐   (A)(B)      ┌──────────────┐   (C)(D)      ┌───────────────┐
   │  Developer  │──────────────▶│  Source repo │──────────────▶│  Build system │
   │  workstation│  push/PR      │  (git)       │  checkout     │  (CI/CD)      │
   └─────────────┘               └──────────────┘               └───────┬───────┘
                                        ▲                               │
                                        │ (E) deps                      │ produces:
                                 ┌──────┴───────┐                       │  • image
                                 │ Package idx  │                       │  • SBOM
                                 │ npm/PyPI/Go  │                       │  • provenance
                                 └──────────────┘                       │  • signature
                                                                        ▼
   ┌─────────────┐   (H) pull    ┌──────────────┐   (F)(G)      ┌───────────────┐
   │   kubelet   │◀──────────────│   Admission  │◀──────────────│   Artifact    │
   │ + containerd│   scheduled   │  controller  │   verify      │  repository   │
   └─────────────┘               └──────────────┘               └───────────────┘
         │                               ▲
         │ runs                          │ ENFORCEMENT BOUNDARY
         ▼                               │ (the only place the cluster
   ┌─────────────┐                       │  can still say "no")
   │  Container  │───────────────────────┘
   └─────────────┘
```

Las letras de amenaza siguen el modelo de amenazas de SLSA. Notá que el **único** punto donde un clúster de Kubernetes puede intervenir unilateralmente es la admisión. Todo lo que está a la izquierda de esa frontera es una cuestión de confianza que debe ser *establecida mediante evidencia que puedas verificar en tiempo de admisión*.

### 1.4 Amplificadores específicos de Kubernetes

Cuatro propiedades de Kubernetes hacen que las debilidades de la cadena de suministro sean peores que en las flotas clásicas de VMs:

| Amplificador | Mecanismo | Mitigación cubierta acá |
|---|---|---|
| **Tags mutables** | `image: app:latest` resuelve distinto en cada nodo y en cada reinicio. Dos réplicas del mismo Deployment pueden ejecutar código diferente. | Pinning por digest aplicado en admisión (§5.2) |
| **Caché de imágenes local al nodo** | Un pod en el namespace `A` puede ejecutar una imagen que previamente descargó un pod del namespace `B` **sin poseer las credenciales de pull**. | Plugin de admisión `AlwaysPullImages` (§5.6) |
| **Re-pull dirigido por controladores** | Un fallo de nodo o un scale-out vuelve a resolver el tag en un momento futuro arbitrario, fuera de cualquier compuerta de CI/CD. | Pinning por digest + verificación en admisión en cada CREATE |
| **Agentes ubicuos a nivel de clúster** | CNI, CSI, ingress, monitoreo y service mesh corren todos como DaemonSets privilegiados desde registros de terceros. | Allowlist de registros aplicada también a `kube-system` (§5.2), no solo a los namespaces de aplicaciones |

---

## 2. SBOM: formato, generación, distribución

### 2.1 Qué es realmente un SBOM

Un SBOM es un inventario legible por máquina de componentes y sus relaciones. El conjunto mínimo viable de campos (elementos mínimos de la NTIA) es: proveedor, nombre del componente, versión, identificadores únicos (PURL / CPE), relación de dependencia, autor del SBOM y timestamp.

Para contenedores hay efectivamente **tres capas** de contenido, y la mayoría de las herramientas solo cubre las dos primeras por defecto:

| Capa | Contenido de ejemplo | Detectado por |
|---|---|---|
| **Paquetes del SO** | bases de datos `apk`/`dpkg`/`rpm` | Syft, Trivy, Grype — de forma confiable |
| **Paquetes de lenguaje** | `go.mod` embebido en el binario, `package-lock.json`, `*.dist-info`, `Cargo.lock`, `pom.xml` | Syft, Trivy — de forma confiable para lockfiles y buildinfo de Go |
| **Binarios vendorizados / enlazados estáticamente / copiados** | Un binario `curl` copiado en un paso `COPY`, una biblioteca C enlazada estáticamente, un JAR fusionado dentro de un uber-JAR | **Mal.** Requiere catalogación de digests de archivos + clasificadores binarios (`syft --select-catalogers`) o comparación contra hashes de referencia |

> **Nota del arquitecto:** la tercera capa es donde vive el ataque de la clase `xz`. Tratá "el SBOM está limpio" como evidencia de *ausencia de componentes declarados con vulnerabilidades conocidas*, nunca como evidencia de *ausencia de código malicioso*. Esta es la sobreafirmación más común que se hace sobre los SBOM en los programas de producción.

### 2.2 Comparación de formatos

| | **SPDX 2.3 / 3.0** | **CycloneDX 1.6** | **Syft JSON** | **SWID** |
|---|---|---|---|---|
| Gobernanza | Linux Foundation / ISO/IEC 5962:2021 | OWASP / ECMA-424 | Anchore (proveedor) | ISO/IEC 19770-2 |
| Objetivo de diseño principal | Cumplimiento de licencias y procedencia | Seguridad y análisis de riesgo | Nativo de la herramienta, sin pérdida | Gestión de activos de software |
| Serializaciones | JSON, YAML, RDF, tag-value, planilla | JSON, XML, Protobuf | JSON | XML |
| Datos de vulnerabilidades en banda | No (externo, o perfil de seguridad de SPDX 3.0) | **Sí** (`vulnerabilities[]`) | No | No |
| Soporte de VEX | Documento separado | **Nativo** (CycloneDX VEX) | No | No |
| Service / ML-BOM / HW-BOM | Perfiles de SPDX 3.0 | **Sí** (SaaSBOM, ML-BOM, CBOM) | No | No |
| Fidelidad del grafo de dependencias | Basada en relaciones, muy expresiva, verbosa | Árbol `dependencies[]`, compacto | Completa | Débil |
| Sobre de firma | Externo (in-toto/DSSE) | **Nativo** JSON Signature Format + externo | Externo | XML DSig |
| Tamaño típico (Alpine + app en Go, ~150 pkgs) | ~420 KB JSON | ~180 KB JSON | ~600 KB | n/d |
| Predeterminado en el ecosistema Kubernetes | **Sí** — los releases de k8s publican SPDX en `sbom.k8s.io` | Ampliamente usado por Trivy/Dependency-Track | Interno | Raro |

**Recomendación práctica:** emitir **ambos**. Cuesta un flag `-o` extra y elimina toda una clase de trabajo improductivo del tipo "nuestro scanner/nuestro cliente/nuestro regulador necesita el otro".

```
-o spdx-json=sbom.spdx.json -o cyclonedx-json=sbom.cdx.json
```

### 2.3 SBOM en tiempo de build vs. en tiempo de análisis

Esta es la decisión de diseño más consecuente de todo el objetivo, y habitualmente se toma mal.

| | **Tiempo de análisis (escaneo a posteriori)** | **Tiempo de build (generado por el builder)** |
|---|---|---|
| Cómo | `syft scan registry:img:tag` después del hecho | `docker buildx build --sbom=true`, Bazel, Tekton Chains, `ko` |
| Ve contenido vendorizado/estático | No | Parcialmente — conoce el grafo de build |
| Ve dependencias solo de build (compiladores, deps de test) | No | Sí (`mode=max`) |
| Ve el *origen* de cada componente | Inferido | **Autoritativo** — conoce la salida exacta del resolvedor |
| Ancla de confianza | El scanner, ejecutado por quien sea que lo ejecute | La plataforma de build (puede ser SLSA L3) |
| Reproducible | Depende de la versión de la base de datos del scanner | Sí, atado al build |
| Costo de retrofit sobre imágenes existentes | Cero | Alto — requiere cambios en el builder |
| Respuesta correcta para | Imágenes de terceros / base que no construiste vos | **Todo lo que construís vos mismo** |

Usá SBOM en tiempo de build para las imágenes propias y SBOM en tiempo de análisis para todo lo demás. Nunca dependas exclusivamente de SBOM en tiempo de análisis para código que tu organización escribió.

### 2.4 Generando SBOMs — comandos reales

**Syft (tiempo de análisis, multiformato):**

```
$ syft scan registry:registry.acme.io/payments-api:1.8.3 \
    -o spdx-json=sbom.spdx.json \
    -o cyclonedx-json=sbom.cdx.json \
    -o table
 ✔ Pulled image
 ✔ Loaded image                        registry.acme.io/payments-api:1.8.3
 ✔ Parsed image             sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
 ✔ Cataloged contents                  6c1e0b0a4f2d8e7b9c3a5f1d0e8b2c4a6f9d3e7b1c5a8f0d2e4b6c9a3f7d1e5b
   ├── ✔ Packages                        [148 packages]
   ├── ✔ File digests                    [2417 files]
   ├── ✔ File metadata                   [2417 locations]
   └── ✔ Executables                     [41 executables]

NAME                     VERSION                TYPE
busybox                  1.36.1-r29             apk
ca-certificates-bundle   20241121-r1            apk
github.com/gin-gonic/gin v1.10.0                go-module
github.com/jackc/pgx/v5  v5.7.1                 go-module
golang.org/x/crypto      v0.28.0                go-module
libcrypto3               3.3.2-r0               apk
libssl3                  3.3.2-r0               apk
musl                     1.2.5-r8               apk
payments-api             (devel)                go-module
...
```

Verificá que los dos artefactos describan el mismo digest — un bug de CI sorprendentemente común es escanear `:latest` mientras se despacha un digest diferente:

```
$ jq -r '.packages[0].externalRefs[]? | select(.referenceType=="purl") | .referenceLocator' sbom.spdx.json | head -1
pkg:oci/payments-api@sha256%3A9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c?arch=amd64&repository_url=registry.acme.io

$ crane digest registry.acme.io/payments-api:1.8.3
sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
```

**Trivy (tiempo de análisis, integrado con su propia base de datos de vulnerabilidades):**

```
$ trivy image --format cyclonedx --output trivy-sbom.cdx.json \
    registry.acme.io/payments-api:1.8.3
2026-08-03T14:22:07Z INFO  [vulndb] Need to update DB
2026-08-03T14:22:11Z INFO  [vulndb] Downloading vulnerability DB...
2026-08-03T14:22:19Z INFO  "--format cyclonedx" disables security scanning. Specify "--scanners vuln" explicitly if you want to include vulnerabilities.
2026-08-03T14:22:21Z INFO  Detected OS  family="alpine" version="3.20.3"
2026-08-03T14:22:21Z INFO  Number of language-specific files  num=1
```

Fijate en la advertencia: por defecto `--format cyclonedx` te da un inventario **sin** vulnerabilidades. Para obtener un documento combinado SBOM+VDR:

```
$ trivy image --scanners vuln --format cyclonedx --output vdr.cdx.json \
    registry.acme.io/payments-api:1.8.3
```

**En tiempo de build con BuildKit (el camino preferido para imágenes propias):**

```
$ docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --sbom=true \
    --provenance=mode=max \
    --tag registry.acme.io/payments-api:1.8.3 \
    --push .
[+] Building 42.7s (23/23) FINISHED
 => [internal] load build definition from Dockerfile                       0.0s
 ...
 => exporting to image                                                     6.1s
 => => exporting layers                                                    2.3s
 => => exporting manifest sha256:9f2b3c7d...                               0.0s
 => => exporting config sha256:1b7e4a2d...                                 0.0s
 => => exporting attestation manifest sha256:c4a91e0f...                   0.1s
 => => exporting manifest list sha256:3d8f0b6c...                          0.0s
 => => pushing layers                                                      3.2s
 => => pushing manifest for registry.acme.io/payments-api:1.8.3@sha256:3d8f0b6c...
```

Las atestaciones se convierten en entradas del índice de imagen OCI, descubribles sin herramientas adicionales:

```
$ docker buildx imagetools inspect registry.acme.io/payments-api:1.8.3 --raw | jq -r \
    '.manifests[] | "\(.platform.os)/\(.platform.architecture)\t\(.annotations["vnd.docker.reference.type"] // "image")\t\(.digest)"'
linux/amd64	image	sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
linux/arm64	image	sha256:5e1a8c3f7b2d9e0a4c6f8b1d3e5a7c9f0b2d4e6a8c1f3b5d7e9a0c2f4b6d8e1a
unknown/unknown	attestation-manifest	sha256:c4a91e0f2b6d8a3c5e7f9b1d0a2c4e6f8b0d2a4c6e8f0b2d4a6c8e0f2b4d6a8c
unknown/unknown	attestation-manifest	sha256:7b3e5a9c1f0d2b4e6a8c0f2d4b6e8a0c2f4d6b8e0a2c4f6d8b0e2a4c6f8d0b2e

$ docker buildx imagetools inspect registry.acme.io/payments-api:1.8.3 \
    --format '{{ json .Provenance.SLSA.buildDefinition.externalParameters }}' | jq .
{
  "configSource": {
    "digest": { "sha1": "4c8e2b1f7a9d0c3e5b6f8a1d2c4e6b8f0a3d5c7e" },
    "entryPoint": "Dockerfile",
    "uri": "https://github.com/acme/payments-api.git#refs/tags/v1.8.3"
  },
  "request": {
    "frontend": "dockerfile.v0",
    "args": { "build-arg:GOFLAGS": "-trimpath -buildvcs=true" }
  }
}
```

### 2.5 Distribuir SBOMs: atestaciones, no archivos sidecar

Un SBOM almacenado en un bucket de artefactos de CI está operativamente muerto — nadie lo va a encontrar seis meses después cuando el CVE caiga a las 02:00. El SBOM debe viajar **con la imagen, direccionado por digest**.

Tres mecanismos, en orden creciente de corrección:

| Mecanismo | Cómo se almacena | Descubrible mediante | Veredicto |
|---|---|---|---|
| `cosign attach sbom` (**obsoleto**) | Tag `sha256-<digest>.sbom` | `cosign download sbom` | **No usar.** Sin firmar, obsoleto desde cosign v2. |
| `cosign attest` (basado en tags) | Tag `sha256-<digest>.att`, in-toto envuelto en DSSE | `cosign verify-attestation` | Bueno. Funciona en todos los registros. |
| Referrers de OCI 1.1 (campo `subject`) | Manifest con `subject`, consultado vía `/v2/<n>/referrers/<digest>` | `oras discover`, `cosign --registry-referrers-mode oci-1-1` | **El mejor.** Semántica nativa de GC, sin contaminación de tags. Requiere un registro que implemente la Referrers API (Harbor ≥ 2.9, GHCR, ECR, GAR, Zot, distribution ≥ 2.8.2 con fallback). |

**Firmar el SBOM como atestación:**

```
$ cosign attest --yes \
    --type cyclonedx \
    --predicate sbom.cdx.json \
    registry.acme.io/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
Generating ephemeral keys...
Retrieving signed certificate...
        Note that there may be personally identifiable information associated with this signed artifact.
        This may include the email address associated with the account with which you authenticate.
        This information will be used for signing this artifact and will be stored in public transparency logs and cannot be removed later.
Successfully verified SCT...
tlog entry created with index: 187443902
Using payload from: sbom.cdx.json
```

**Descubrir todo lo que está adjunto a una imagen:**

```
$ cosign tree registry.acme.io/payments-api:1.8.3
📦 Supply Chain Security Related artifacts for an image: registry.acme.io/payments-api:1.8.3
└── 💾 Attestations for an image tag: registry.acme.io/payments-api:sha256-9f2b3c7d....att
   ├── 🍒 sha256:a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90
   └── 🍒 sha256:b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1
└── 🔐 Signatures for an image tag: registry.acme.io/payments-api:sha256-9f2b3c7d....sig
   └── 🍒 sha256:c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2

$ oras discover -o tree registry.acme.io/payments-api:1.8.3
registry.acme.io/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
├── application/vnd.in-toto+json
│   ├── sha256:a1b2c3d4... [https://cyclonedx.org/bom]
│   └── sha256:b2c3d4e5... [https://slsa.dev/provenance/v1]
└── application/vnd.dev.cosign.artifact.sig.v1+json
    └── sha256:c3d4e5f6...
```

### 2.6 VEX: el control que hace que los SBOM sean soportables a escala

Una imagen de 148 paquetes va a coincidir típicamente con 30–80 CVEs. Bloquear por todos ellos es imposible; ignorarlos es negligente. **VEX (Vulnerability Exploitability eXchange)** es la capa de aserción: para un producto y una vulnerabilidad dados, uno de cuatro estados — `not_affected`, `affected`, `fixed`, `under_investigation` — más una justificación legible por máquina.

```
$ cat vex/payments-api.openvex.json
```
```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://acme.io/vex/payments-api/2026-08-03-001",
  "author": "ACME Product Security <psirt@acme.io>",
  "timestamp": "2026-08-03T09:00:00Z",
  "version": 1,
  "statements": [
    {
      "vulnerability": { "name": "CVE-2024-45337" },
      "products": [
        {
          "@id": "pkg:oci/payments-api@sha256%3A9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c?repository_url=registry.acme.io",
          "subcomponents": [
            { "@id": "pkg:golang/golang.org/x/crypto@v0.28.0" }
          ]
        }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path",
      "impact_statement": "payments-api imports golang.org/x/crypto only for bcrypt password hashing. The vulnerable ssh.ServerConfig callback path is not reachable; verified with `go tool callgraph` on build 1.8.3."
    }
  ]
}
```

Consumido en tiempo de escaneo para que la compuerta siga siendo significativa:

```
$ trivy image --scanners vuln --severity HIGH,CRITICAL --exit-code 1 \
    --vex vex/payments-api.openvex.json \
    registry.acme.io/payments-api:1.8.3
2026-08-03T14:31:02Z INFO  [vex] VEX filtering  vex_id="https://acme.io/vex/payments-api/2026-08-03-001"
2026-08-03T14:31:02Z INFO  [vex] Filtered out the detected vulnerability  vulnerability-id="CVE-2024-45337" status="not_affected" justification="vulnerable_code_not_in_execute_path"

registry.acme.io/payments-api:1.8.3 (alpine 3.20.3)
Total: 0 (HIGH: 0, CRITICAL: 0)
```

Los documentos VEX deberían estar ellos mismos firmados y adjuntos como atestaciones (`cosign attest --type openvex`), de modo que la excepción sea auditable y expire junto con el digest de la imagen en vez de vivir en la lista de exclusión mutable de un scanner.

---

## 3. Repositorios de artefactos

### 3.1 Comparación

| | **Harbor** | **Artifactory** | **GHCR** | **ECR / GAR** | **Quay** | **Zot** | **distribution** |
|---|---|---|---|---|---|---|---|
| Licencia | Apache 2.0 (CNCF graduado) | Comercial | SaaS | SaaS | Apache 2.0 / SaaS | Apache 2.0 (CNCF sandbox) | Apache 2.0 |
| Referrers de OCI 1.1 | ✅ ≥ 2.9 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ ≥ 2.8.2 (fallback por tags) |
| Escaneo de vulnerabilidades incorporado | ✅ Trivy | ✅ Xray (pago) | ❌ | ✅ (básico/mejorado) | ✅ Clair | ✅ Trivy | ❌ |
| Aplicación de firmas en la política de pull | ✅ Cosign + Notation | ✅ | ❌ | ⚠️ vía motores de políticas | ✅ | ⚠️ | ❌ |
| Reglas de tags inmutables | ✅ | ✅ | ⚠️ manual | ✅ | ✅ | ⚠️ | ❌ |
| Replicación / proxy pull-through | ✅ | ✅ | ❌ | ✅ (pull-through) | ✅ | ✅ | ✅ (modo proxy) |
| Cuotas y retención (GC) | ✅ | ✅ | ⚠️ | ✅ políticas de ciclo de vida | ✅ | ⚠️ | GC manual |
| Identidad robot / de workload | ✅ cuentas robot | ✅ | ✅ OIDC | ✅ IRSA / WI | ✅ | ✅ | ❌ |
| Amigable para air-gap | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ **(el mejor — diminuto, binario único)** | ✅ |
| Corre dentro del clúster | ✅ Helm/operator | ✅ | n/d | n/d | ✅ | ✅ | ✅ |

**Heurística de selección:** Harbor para empresas self-hosted (las capacidades de política son el diferenciador); Zot para edge/air-gap/embebido (un binario estático de ~30 MB con conformidad OCI 1.1 completa); registro nativo de la nube para clústeres nativos de la nube, porque la identidad de workload le gana a cualquier secreto que de otro modo tendrías que rotar.

### 3.2 Referencia de endurecimiento de proyectos en Harbor

El registro es un punto de aplicación de políticas por derecho propio — una segunda línea de defensa detrás de la admisión. Configurá por proyecto:

```
$ curl -sS -u "admin:${HARBOR_PW}" -X PUT \
    -H 'Content-Type: application/json' \
    https://registry.acme.io/api/v2.0/projects/payments \
    -d '{
      "metadata": {
        "public": "false",
        "enable_content_trust_cosign": "true",
        "prevent_vul": "true",
        "severity": "high",
        "auto_scan": "true",
        "reuse_sys_cve_allowlist": "false"
      }
    }'
```

| Ajuste | Efecto | Modo de fallo si no se configura |
|---|---|---|
| `public: false` | Exige autenticación para el pull | Enumeración anónima de los nombres y versiones de tus servicios internos |
| `enable_content_trust_cosign: true` | Harbor se niega a servir imágenes sin firmar | Una imagen sin firmar llega a un clúster cuyo controlador de admisión justo está degradado |
| `prevent_vul: true` + `severity: high` | Bloquea el pull de imágenes con hallazgos ≥ High | Imagen con vulnerabilidades conocidas redesplegada meses después durante un drenaje de nodo no relacionado |
| `auto_scan: true` | Escaneo al hacer push | Los hallazgos se descubren solo cuando alguien se acuerda de mirar |
| Regla de tag inmutable | Vínculo tag→digest congelado | `1.8.3` se convierte silenciosamente en otra imagen; tu rastro de auditoría es ficción |

Regla de tag inmutable (`v*` y `[0-9]*` en cada repositorio del proyecto):

```
$ curl -sS -u "admin:${HARBOR_PW}" -X POST \
    -H 'Content-Type: application/json' \
    https://registry.acme.io/api/v2.0/projects/payments/immutabletagrules \
    -d '{
      "disabled": false,
      "scope_selectors": {
        "repository": [ { "kind": "doublestar", "decoration": "repoMatches", "pattern": "**" } ]
      },
      "tag_selectors": [
        { "kind": "doublestar", "decoration": "matches", "pattern": "{v*,[0-9]*}" }
      ]
    }'
```

Verificación de que la inmutabilidad efectivamente tomó efecto:

```
$ docker tag alpine:3.20 registry.acme.io/payments/payments-api:1.8.3
$ docker push registry.acme.io/payments/payments-api:1.8.3
The push refers to repository [registry.acme.io/payments/payments-api]
denied: The tag 1.8.3 in repository payments/payments-api is immutable, please delete it or make it mutable first
```

### 3.3 Espejado de registros y pull-through — la capa de containerd

Incluso con una política de registro perfecta, los nodos deben estar configurados para usarlo de verdad. Los clústeres con egreso restringido deberían resolver *todas* las referencias de imágenes a través del registro interno.

`containerd` 2.x (`/etc/containerd/config.toml`):

```toml
version = 3

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
```

`containerd` 1.7.x:

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

Definiciones de mirror por host:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://registry.acme.io/v2/dockerhub-proxy"]
  capabilities = ["pull", "resolve"]
  override_path = true
  skip_verify = false
  ca = "/etc/containerd/certs.d/acme-root-ca.pem"
```

```toml
# /etc/containerd/certs.d/registry.acme.io/hosts.toml
server = "https://registry.acme.io"

[host."https://registry.acme.io"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/acme-root-ca.pem"
```

Verificá desde el nodo — el mirror se está usando solo si la resolución ocurre contra el host del mirror:

```
$ sudo ctr --namespace k8s.io images pull --hosts-dir /etc/containerd/certs.d docker.io/library/alpine:3.20
docker.io/library/alpine:3.20:                                     resolved
index-sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a: exists
...
elapsed: 1.4 s    total:   0.0 B (0.0 B/s)
unpacking linux/amd64 sha256:1e42bbe2...
done: 61.2ms

$ sudo journalctl -u containerd --since '1 min ago' | grep -i 'registry.acme.io'
Aug 03 14:40:11 node-01 containerd[1183]: time="..." level=debug msg="resolving" host=registry.acme.io
```

### 3.4 CRI-O: verificación de firmas a nivel de runtime

CRI-O (mediante `containers/image`) puede verificar firmas **en el momento del pull, en el nodo**, lo que es un punto de control genuinamente distinto de la admisión — sobrevive a una cadena de admisión del API server comprometida o eludida.

```
# /etc/crio/crio.conf.d/10-signature-policy.conf
[crio.image]
signature_policy = "/etc/containers/policy.json"
signature_policy_dir = "/etc/crio/policies"
```

```json
{
  "default": [ { "type": "reject" } ],
  "transports": {
    "docker": {
      "registry.acme.io": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/containers/keys/acme-release.pub",
          "signedIdentity": { "type": "matchRepoDigestOrExact" }
        }
      ],
      "registry.k8s.io": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/containers/keys/k8s-release.pub",
          "signedIdentity": { "type": "matchRepoDigestOrExact" }
        }
      ]
    },
    "": [ { "type": "reject" } ]
  }
}
```

```
$ sudo crictl pull registry.acme.io/payments-api:1.8.3
FATA[0002] pulling image: rpc error: code = Unknown desc = SignatureValidationFailed:
  Source image rejected: A signature was required, but no signature exists
```

> `containerd` **no tiene un mecanismo nativo equivalente**. En clústeres basados en containerd, la admisión es tu único punto de aplicación — que es la razón por la que §5 importa tanto.

### 3.5 Credenciales de pull en el nodo sin secretos de larga vida

Los `imagePullSecrets` son credenciales de registro estáticas y de larga vida, almacenadas en etcd y legibles por cualquiera que tenga `get secrets` en el namespace. Preferí el **credential provider del kubelet** (GA desde v1.26), que obtiene tokens de corta duración desde el plano IAM de la nube en el momento del pull.

```yaml
# /etc/kubernetes/kubelet/credential-provider-config.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr-fips.*.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - get-credentials
    env:
      - name: AWS_REGION
        value: sa-east-1
  - name: acme-oidc-credential-provider
    matchImages:
      - "registry.acme.io"
      - "registry.acme.io/*"
    defaultCacheDuration: "10m"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - --oidc-issuer=https://oidc.acme.io
      - --audience=registry.acme.io
```

Flags del kubelet:

```
--image-credential-provider-config=/etc/kubernetes/kubelet/credential-provider-config.yaml
--image-credential-provider-bin-dir=/usr/local/bin/credential-providers
```

Verificación:

```
$ sudo journalctl -u kubelet --since '5 min ago' | grep -i 'credential provider'
Aug 03 14:44:02 node-01 kubelet[2214]: I0803 14:44:02.118442  2214 plugin.go:158] "Successfully registered credential provider plugin" name="acme-oidc-credential-provider"
Aug 03 14:44:09 node-01 kubelet[2214]: I0803 14:44:09.774310  2214 plugin.go:245] "Got credentials from external credential provider" image="registry.acme.io/payments-api:1.8.3" cacheDuration="10m0s"
```

---

## 4. CI/CD: la plataforma de build es parte de tu Trusted Computing Base

### 4.1 Niveles de Build de SLSA v1.0

| Nivel | Requisito | Qué derrota | Implementación típica |
|---|---|---|---|
| **L0** | Nada | — | `docker build && docker push` local |
| **L1** | La procedencia existe y se distribuye | Etiquetado erróneo accidental; "¿qué commit está corriendo en prod?" | `buildx --provenance=mode=max` |
| **L2** | El build corre en una plataforma alojada; la procedencia está **firmada** por esa plataforma | Un desarrollador falsificando procedencia desde su laptop | GitHub Actions + `actions/attest-build-provenance`; Tekton Chains |
| **L3** | La plataforma de build está endurecida; la procedencia es **no falsificable** (la clave de firma es inalcanzable desde pasos de build controlados por el usuario); runners efímeros y aislados | Un paso de build malicioso robando la clave de firma y auto-atestándose | Runners alojados por GitHub + certificados efímeros de Fulcio; Tekton Chains con una clave en poder del controlador; SLSA GitHub Generator |

> **La distinción L2→L3 es la que los arquitectos entienden mal.** Si tu pipeline hace `cosign sign --key $COSIGN_KEY` donde `COSIGN_KEY` es una variable de entorno disponible para el mismo job que ejecuta `make build`, entonces código arbitrario de tu repositorio (incluyendo el de cualquier dependencia ejecutada durante el build) puede leer esa clave. Eso es L2 en el mejor de los casos. La firma sin clave (keyless) con un certificado efímero federado por OIDC, o un job de firma separado que solo recibe el digest, es el arreglo estructural.

### 4.2 Pipeline de referencia (GitHub Actions, con forma de SLSA L3)

```yaml
# .github/workflows/release.yaml
name: release

on:
  push:
    tags: ['v*.*.*']

# Default to nothing; each job opts in explicitly.
permissions: {}

env:
  REGISTRY: registry.acme.io
  IMAGE_NAME: payments/payments-api

jobs:
  # ── Stage 1: static analysis of source + IaC ──────────────────────────────
  static-analysis:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      security-events: write
    steps:
      - name: Checkout
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

      - name: Scan source, secrets and misconfigurations
        uses: aquasecurity/trivy-action@6c175e9c4083a92bbca2f9724c8a5e33bc2d97a5 # 0.30.0
        with:
          scan-type: fs
          scanners: vuln,secret,misconfig
          severity: HIGH,CRITICAL
          exit-code: '1'
          ignore-unfixed: true

      - name: Lint Kubernetes manifests
        run: |
          curl -sSfL -o kube-linter.tar.gz \
            https://github.com/stackrox/kube-linter/releases/download/v0.7.2/kube-linter-linux.tar.gz
          echo "b3a5b6bbf4c0cbb0eb8bbf9d4a2d5ee7c2f4a5b0f1e3d7c9a1b5e0f2d4c6a8b0  kube-linter.tar.gz" | sha256sum -c -
          tar -xzf kube-linter.tar.gz && sudo install kube-linter /usr/local/bin/
          kube-linter lint deploy/ --config .kube-linter.yaml

      - name: Kubesec scan
        run: |
          docker run --rm -i kubesec/kubesec:v2.14.2 scan /dev/stdin \
            < deploy/deployment.yaml | tee kubesec.json
          score=$(jq -r '.[0].score' kubesec.json)
          echo "kubesec score: ${score}"
          [ "${score}" -ge 5 ] || { echo "::error::kubesec score ${score} below threshold 5"; exit 1; }

  # ── Stage 2: build, SBOM, push. NO signing key is present in this job. ────
  build:
    needs: [static-analysis]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write        # OIDC token for registry auth — no static password
    outputs:
      digest: ${{ steps.build.outputs.digest }}
      image:  ${{ steps.meta.outputs.image }}
    steps:
      - name: Checkout
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

      - name: Set up QEMU
        uses: docker/setup-qemu-action@49b3bc8e6bdd4a60e6116a5414239cba5943d3cf # v3.2.0

      - name: Set up Buildx
        uses: docker/setup-buildx-action@c47758b77c9736f4b2ef4073d4d51994fabfe349 # v3.7.1

      - name: Registry login (OIDC-federated, short-lived)
        uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567 # v3.3.0
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ vars.HARBOR_ROBOT_NAME }}
          password: ${{ secrets.HARBOR_ROBOT_TOKEN }}

      - name: Compute metadata
        id: meta
        run: |
          echo "image=${REGISTRY}/${IMAGE_NAME}" >> "$GITHUB_OUTPUT"
          echo "version=${GITHUB_REF_NAME#v}"    >> "$GITHUB_OUTPUT"

      - name: Build and push (multi-arch, with SBOM + max provenance)
        id: build
        uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75 # v6.9.0
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          sbom: true
          provenance: mode=max
          tags: |
            ${{ steps.meta.outputs.image }}:${{ steps.meta.outputs.version }}
          build-args: |
            GOFLAGS=-trimpath -buildvcs=true
          # Reproducibility: freeze timestamps to the commit time.
          outputs: type=image,rewrite-timestamp=true
        env:
          SOURCE_DATE_EPOCH: ${{ github.event.repository.pushed_at }}

      - name: Generate and upload standalone SBOMs
        run: |
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
            | sh -s -- -b /usr/local/bin v1.18.1
          syft scan "${{ steps.meta.outputs.image }}@${{ steps.build.outputs.digest }}" \
            -o spdx-json=sbom.spdx.json \
            -o cyclonedx-json=sbom.cdx.json

      - name: Gate on vulnerabilities (VEX-filtered)
        run: |
          curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b /usr/local/bin v0.58.0
          trivy sbom sbom.cdx.json \
            --severity HIGH,CRITICAL \
            --ignore-unfixed \
            --vex vex/ \
            --exit-code 1

      - uses: actions/upload-artifact@b4b15b8c7c6ac21ea08fcf65892d2ee8f75cf882 # v4.4.3
        with:
          name: sboms
          path: sbom.*.json
          retention-days: 90

  # ── Stage 3: sign + attest. Isolated job; sees only the digest. ───────────
  sign:
    needs: [build]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
      id-token: write        # required for keyless (Fulcio) signing
    steps:
      - name: Install cosign
        uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da # v3.7.0
        with:
          cosign-release: v2.4.1

      - uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v4.1.8
        with:
          name: sboms

      - name: Registry login
        uses: docker/login-action@9780b0c442fbb1117ed29e0efdff1e18412f7567 # v3.3.0
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ vars.HARBOR_ROBOT_NAME }}
          password: ${{ secrets.HARBOR_ROBOT_TOKEN }}

      - name: Sign the image (keyless — ephemeral Fulcio cert, Rekor logged)
        run: |
          cosign sign --yes \
            --registry-referrers-mode oci-1-1 \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}"

      - name: Attest the SBOM
        run: |
          cosign attest --yes \
            --type cyclonedx \
            --predicate sbom.cdx.json \
            --registry-referrers-mode oci-1-1 \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}"

      - name: Attest the SPDX SBOM as well
        run: |
          cosign attest --yes \
            --type spdxjson \
            --predicate sbom.spdx.json \
            --registry-referrers-mode oci-1-1 \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}"

  # ── Stage 4: prove the artifact passes the same gate the cluster applies ──
  verify:
    needs: [build, sign]
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - name: Install cosign
        uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da # v3.7.0

      - name: Verify signature exactly as the admission controller will
        run: |
          cosign verify \
            --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
            --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}" | jq -e '.[0].optional.Bundle' > /dev/null

      - name: Verify the SBOM attestation
        run: |
          cosign verify-attestation \
            --type cyclonedx \
            --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
            --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
            "${{ needs.build.outputs.image }}@${{ needs.build.outputs.digest }}" > /dev/null
```

**Propiedades no obvias de ese pipeline, y por qué cada una importa:**

| Propiedad | Fundamento |
|---|---|
| `permissions: {}` a nivel de workflow, con opt-in por job | El alcance por defecto de `GITHUB_TOKEN` es una primitiva de movimiento lateral. Mínimo privilegio por job. |
| Cada `uses:` fijado a un **SHA de commit** | Los tags en acciones de terceros son mutables. `actions/checkout@v4` es una dependencia remota sin autenticar que volvés a resolver en cada ejecución. |
| `persist-credentials: false` | De lo contrario la credencial de git queda en `.git/config` en disco para todos los pasos posteriores, incluidos los de terceros. |
| El job de build no contiene **material de firma** | Propiedad estructural de SLSA L3. Un `go generate` malicioso en una dependencia no puede firmar. |
| El job de firma recibe solo el `digest`, nunca reconstruye | Elimina el TOCTOU entre lo que se escaneó y lo que se firma. |
| `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true` | Hace que los builds sean reproducibles byte a byte, así un segundo builder independiente puede corroborar el digest. |
| El job `verify` vuelve a ejecutar el predicado de verificación de *producción* | El pipeline falla en CI en vez de a las 03:00 durante un rollout, que es el único momento en el que alguien notaría una regexp de identidad rota. |
| La compuerta de vulnerabilidades corre sobre el **SBOM**, no sobre la imagen | Determinista, capaz de funcionar offline, e idéntica a lo que van a correr los consumidores aguas abajo. |

### 4.3 Builds dentro del clúster: Tekton Chains

Para organizaciones que construyen dentro de Kubernetes, Tekton Chains observa los objetos `TaskRun`/`PipelineRun` completados y emite procedencia in-toto firmada — la clave de firma vive en el namespace del controlador de Chains, inalcanzable desde el pod de build. Ese es el equivalente in-cluster de SLSA L3.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chains-config
  namespace: tekton-chains
data:
  # Provenance format and where it goes
  artifacts.taskrun.format: "in-toto"
  artifacts.taskrun.storage: "oci"
  artifacts.taskrun.signer: "x509"

  artifacts.pipelinerun.format: "in-toto"
  artifacts.pipelinerun.storage: "oci"
  artifacts.pipelinerun.signer: "x509"

  # Image signatures alongside provenance
  artifacts.oci.format: "simplesigning"
  artifacts.oci.storage: "oci"
  artifacts.oci.signer: "x509"

  # SLSA v1.0 predicate
  builder.id: "https://tekton.dev/chains/v2"
  slsa.builder.id: "https://tekton.dev/chains/v2"

  # Keyless signing via Fulcio, transparency via Rekor
  signers.x509.fulcio.enabled: "true"
  signers.x509.fulcio.address: "https://fulcio.sigstore.dev"
  signers.x509.fulcio.issuer: "https://oauth2.sigstore.dev/auth"
  signers.x509.fulcio.provider: "spiffe"
  signers.x509.identity.token.file: "/var/run/sigstore/cosign/oidc-token"

  transparency.enabled: "true"
  transparency.url: "https://rekor.sigstore.dev"
```

```
$ kubectl -n tekton-chains logs deploy/tekton-chains-controller --tail=8
{"level":"info","ts":"2026-08-03T14:52:10.331Z","logger":"watcher","caller":"taskrun/taskrun.go:60",
 "msg":"Received TaskRun payments-api-build-7fk2x in namespace builds"}
{"level":"info","ts":"2026-08-03T14:52:10.902Z","logger":"watcher","caller":"chains/signing.go:181",
 "msg":"Signing object with identity spiffe://acme.io/ns/builds/sa/build-runner"}
{"level":"info","ts":"2026-08-03T14:52:11.744Z","logger":"watcher","caller":"chains/rekor.go:74",
 "msg":"Uploaded entry to rekor with UUID 24296fb24b8ad77a9c4f1e0b3d5a7c9e1f0b2d4a6c8e0f2b4d6a8c0e2f4b6d8a0c2e4f6b8"}
{"level":"info","ts":"2026-08-03T14:52:11.981Z","logger":"watcher","caller":"chains/signing.go:271",
 "msg":"Successfully signed and stored 1 artifact(s) for TaskRun builds/payments-api-build-7fk2x"}

$ tkn tr describe payments-api-build-7fk2x -n builds -o jsonpath='{.metadata.annotations}' | jq .
{
  "chains.tekton.dev/signed": "true",
  "chains.tekton.dev/payload-taskrun-abc123": "eyJfdHlwZSI6Imh0dHBzOi8vaW4tdG90by5pby9TdGF0ZW1lbnQvdjEi...",
  "chains.tekton.dev/transparency": "https://rekor.sigstore.dev/api/v1/log/entries?logIndex=187449118"
}
```

### 4.4 Checklist de endurecimiento del pipeline

| Control | Antipatrón que elimina |
|---|---|
| Runners efímeros de un solo uso | Envenenamiento de credenciales y de caché entre jobs |
| Sin contraseña de registro de larga vida; federación OIDC o tokens robot de TTL corto | Un token filtrado en los logs sigue siendo válido durante meses |
| Todas las acciones/plugins de terceros fijados por digest o SHA | Compromiso silencioso de la cadena de suministro mediante tag mutable |
| Resolución de dependencias desde un proxy interno con allowlist explícita | Dependency confusion / typosquatting |
| Lockfiles commiteados y aplicados (`npm ci`, `go mod verify`, `pip install --require-hashes`) | Resolución no reproducible en tiempo de build |
| Firma aislada de la construcción | Robo de clave por un paso de build malicioso |
| Protección de ramas + revisiones obligatorias + commits firmados en la rama de release | (A)(B) cambio de fuente no autorizado |
| Logs de build retenidos y procedencia archivada de forma independiente del registro | Forense post-incidente con un registro borrado |
| Red de build con egreso restringido | Exfiltración y `curl \| bash` sin pinning |

Verificá la capa de dependencias explícitamente — esto es barato y atrapa problemas reales:

```
$ go mod verify
all modules verified

$ GOFLAGS=-mod=readonly go build ./... && go version -m ./payments-api | head -20
./payments-api: go1.23.4
	path	github.com/acme/payments-api/cmd/api
	mod	github.com/acme/payments-api	(devel)
	dep	github.com/gin-gonic/gin	v1.10.0	h1:nTuyha1TYqgedzytsKYqna+DfLos46nTv2ygFy86HFU=
	dep	github.com/jackc/pgx/v5	v5.7.1	h1:x7SYsPBYDkHDksogeSmZZ5xzThcTgRz++hOSZ6NAJ68=
	dep	golang.org/x/crypto	v0.28.0	h1:GBDwsMXVQi34v5CCYUm2jkJvu4cbtru2U4TN2PSyQnw=
	build	-buildmode=exe
	build	-trimpath=true
	build	vcs=git
	build	vcs.revision=4c8e2b1f7a9d0c3e5b6f8a1d2c4e6b8f0a3d5c7e
	build	vcs.time=2026-08-03T13:58:41Z
	build	vcs.modified=false
```

`vcs.modified=false` es la aserción de que el árbol de trabajo estaba limpio. Un `true` ahí significa que el binario no se corresponde con ningún commit — la procedencia no vale nada.

---

## 5. Aplicación en el borde del clúster

### 5.1 Comparación de opciones

| | **ValidatingAdmissionPolicy** | **Kyverno** | **Gatekeeper (+Ratify)** | **ImagePolicyWebhook** | **Connaisseur** |
|---|---|---|---|---|---|
| Lenguaje | CEL (en proceso) | DSL en YAML | Rego | Tu propio servicio HTTP | Configuración YAML |
| Corre dentro del proceso de kube-apiserver | ✅ | ❌ webhook | ❌ webhook | ❌ webhook | ❌ webhook |
| Riesgo de disponibilidad si el componente está caído | **Ninguno** | Lo decide `failurePolicy` | Lo decide `failurePolicy` | Lo decide `defaultAllow` | Lo decide `failurePolicy` |
| Allowlist de registros | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| Aplicación de pinning por digest | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Verificación de firmas** | ❌ (sin egreso de red desde CEL) | ✅ `verifyImages` nativo | ✅ vía datos externos de Ratify | ✅ si lo implementás | ✅ |
| Política de atestaciones (contenido SLSA/SBOM) | ❌ | ✅ `attestations` + condiciones | ✅ verificadores de Ratify | a medida | ⚠️ limitado |
| Mutar tag → digest | ❌ | ✅ `mutateDigest: true` | ❌ | ❌ | ✅ |
| Versión de la API de Kubernetes | `admissionregistration.k8s.io/v1` (GA 1.30) | CRD | CRD | `v1alpha1` (sin cambios desde 1.9) | CRD |
| Costo operativo | El más bajo | Medio | Medio-alto (Rego) | Alto (el servicio es tuyo) | Bajo |
| Presencia en el examen CKS | Cada vez más | ✅ frecuentemente | ✅ frecuentemente | ✅ **ítem clásico del examen** | Raro |

**Topología de producción recomendada — defensa en profundidad, tres capas:**
1. **VAP** para los invariantes baratos y absolutos (allowlist de registros, solo digest). En proceso, no puede ser derribado, se evalúa incluso si todos los webhooks están inaccesibles.
2. **`verifyImages` de Kyverno** para la verificación criptográfica y la política de atestaciones. `failurePolicy: Fail` para que una caída de Kyverno bloquee nuevos workloads en vez de admitir silenciosamente los no firmados.
3. **Del lado del registro**, `prevent_vul` / `enable_content_trust_cosign` como respaldo para todo lo que eluda la admisión (pods estáticos, una configuración de webhook comprometida).

### 5.2 ValidatingAdmissionPolicy — allowlist de registros + pinning por digest

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: supply-chain-image-provenance.acme.io
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - apiGroups:   ["batch"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["jobs", "cronjobs"]
  variables:
    # Normalise: pods carry .spec, workload controllers carry .spec.template.spec,
    # cronjobs carry .spec.jobTemplate.spec.template.spec.
    - name: podSpec
      expression: >-
        has(object.spec.template)
          ? object.spec.template.spec
          : (has(object.spec.jobTemplate)
              ? object.spec.jobTemplate.spec.template.spec
              : object.spec)
    - name: allImages
      expression: >-
        (variables.podSpec.containers.map(c, c.image)) +
        (has(variables.podSpec.initContainers)
           ? variables.podSpec.initContainers.map(c, c.image) : []) +
        (has(variables.podSpec.ephemeralContainers)
           ? variables.podSpec.ephemeralContainers.map(c, c.image) : [])
    - name: allowedPrefixes
      expression: >-
        ['registry.acme.io/', 'registry.k8s.io/']
  validations:
    - expression: >-
        variables.allImages.all(img,
          variables.allowedPrefixes.exists(p, img.startsWith(p)))
      messageExpression: >-
        'image(s) ' +
        variables.allImages.filter(img,
          !variables.allowedPrefixes.exists(p, img.startsWith(p))).join(', ') +
        ' are not from an approved registry. Approved: ' +
        variables.allowedPrefixes.join(', ')
      reason: Forbidden
    - expression: >-
        variables.allImages.all(img, img.contains('@sha256:'))
      messageExpression: >-
        'image(s) ' +
        variables.allImages.filter(img, !img.contains('@sha256:')).join(', ') +
        ' must be referenced by immutable digest (repo@sha256:...), not by tag'
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: supply-chain-image-provenance-binding.acme.io
spec:
  policyName: supply-chain-image-provenance.acme.io
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        # Exempt only the namespaces that bootstrap the cluster itself.
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

**Cómo desplegar esto de forma segura** — siempre empezá en modo solo auditoría y leé el log de auditoría antes de pasar a `Deny`:

```yaml
  validationActions: ["Audit", "Warn"]
```

```
$ sudo grep -o '"validation.policy.admission.k8s.io/validation_failure":"[^"]*"' \
    /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn | head
     41 "validation.policy.admission.k8s.io/validation_failure":"[{\"message\":\"image(s) docker.io/bitnami/redis:7.4.1 are not from an approved registry...
     12 "validation.policy.admission.k8s.io/validation_failure":"[{\"message\":\"image(s) registry.acme.io/payments-api:1.8.3 must be referenced by immutable digest...
```

Después, aplicá:

```
$ kubectl run rogue --image=docker.io/library/nginx:latest
error: failed to create pod: admission webhook denied the request:
ValidatingAdmissionPolicy 'supply-chain-image-provenance.acme.io' with binding
'supply-chain-image-provenance-binding.acme.io' denied request:
image(s) docker.io/library/nginx:latest are not from an approved registry.
Approved: registry.acme.io/, registry.k8s.io/

$ kubectl run good --image=registry.acme.io/payments-api:1.8.3
error: failed to create pod: ... denied request: image(s) registry.acme.io/payments-api:1.8.3
must be referenced by immutable digest (repo@sha256:...), not by tag

$ kubectl run good --image=registry.acme.io/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
pod/good created
```

### 5.3 Kyverno — verificación de firmas y atestaciones

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-acme-supply-chain
  annotations:
    policies.kyverno.io/title: Verify signatures, SLSA provenance and SBOM
    policies.kyverno.io/severity: critical
spec:
  # NOTE: on Kyverno >= 1.12 `spec.validationFailureAction` is deprecated for
  # validate rules in favour of `spec.rules[].validate.failureAction`, but it
  # remains the correct field for verifyImages rules.
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    # ── Rule 1: the image must carry a valid keyless signature ────────────
    - name: verify-image-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kyverno]
      verifyImages:
        - imageReferences:
            - "registry.acme.io/payments/*"
          # Rewrite tag -> digest in the admitted object so that the thing
          # verified is provably the thing that runs (closes the TOCTOU gap).
          mutateDigest: true
          verifyDigest: true
          required: true
          imageRegistryCredentials:
            allowInsecureRegistry: false
            secrets:
              - regcred-kyverno
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false

    # ── Rule 2: SLSA provenance must exist and name the right repo/builder ─
    - name: verify-slsa-provenance
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kyverno]
      verifyImages:
        - imageReferences:
            - "registry.acme.io/payments/*"
          required: true
          attestations:
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor:
                          url: https://rekor.sigstore.dev
              conditions:
                - all:
                    - key: "{{ buildDefinition.externalParameters.workflow.repository }}"
                      operator: Equals
                      value: "https://github.com/acme/payments-api"
                    - key: "{{ buildDefinition.externalParameters.workflow.ref }}"
                      operator: AnyIn
                      value: ["refs/heads/main", "refs/tags/*"]
                    - key: "{{ runDetails.builder.id }}"
                      operator: Equals
                      value: "https://github.com/actions/runner/github-hosted"

    # ── Rule 3: a CycloneDX SBOM attestation must exist and be recent ──────
    - name: verify-sbom-attestation
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kyverno]
      verifyImages:
        - imageReferences:
            - "registry.acme.io/payments/*"
          required: true
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ time_since('', '{{ metadata.timestamp }}', '') }}"
                      operator: LessThanOrEquals
                      value: "2160h"   # SBOM older than 90 days -> rebuild required
```

Comportamiento observado:

```
$ kubectl -n payments run unsigned --image=registry.acme.io/payments/scratch-build:dev
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/payments/unsigned was blocked due to the following policies

verify-acme-supply-chain:
  verify-image-signature: 'failed to verify image registry.acme.io/payments/scratch-build:dev:
    .attestors[0].entries[0].keyless: no signatures found'

$ kubectl -n payments apply -f deploy/payments-api.yaml
deployment.apps/payments-api created

$ kubectl -n payments get pod -l app=payments-api \
    -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
```

Fijate en la última salida: el manifiesto declaraba `:1.8.3`, y `mutateDigest: true` lo reescribió al digest que efectivamente se verificó. Esa reescritura es lo que hace que la garantía se sostenga a través de un reinicio de nodo posterior.

### 5.4 ImagePolicyWebhook — la configuración clásica del examen

Todavía se distribuye en v1.34 como `imagepolicy.k8s.io/v1alpha1`. Arquitectónicamente superado, pero aparece en el examen y es el único mecanismo de admisión cuya *configuración entera* vive en el sistema de archivos del plano de control — vale la pena entenderlo aunque sea solo por eso.

**Paso 1 — el archivo de configuración de admisión:**

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
        allowTTL: 50          # seconds to cache an "allow" decision
        denyTTL: 50           # seconds to cache a "deny" decision
        retryBackoff: 500     # milliseconds between retries
        defaultAllow: false   # FAIL CLOSED. The single most important field.
```

> `defaultAllow: true` significa "si mi webhook es inalcanzable, admitir todo". Eso convierte tu política de imágenes en una sugerencia. En el examen, la respuesta esperada es casi siempre `false`; en producción es *siempre* `false`, acompañado de un despliegue del webhook en alta disponibilidad.

**Paso 2 — el kubeconfig que usa el API server para llegar al webhook (mTLS):**

```yaml
# /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
apiVersion: v1
kind: Config
clusters:
  - name: image-policy-webhook
    cluster:
      certificate-authority: /etc/kubernetes/admission/pki/ca.crt
      server: https://image-policy.image-policy.svc:443/policy
users:
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/admission/pki/apiserver-client.crt
      client-key: /etc/kubernetes/admission/pki/apiserver-client.key
current-context: webhook
contexts:
  - name: webhook
    context:
      cluster: image-policy-webhook
      user: kube-apiserver
```

**Paso 3 — conectalo al manifiesto del pod estático.** Tanto los flags como los volume mounts son obligatorios; olvidarse del mount es el fallo clásico.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml   (excerpt)
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.34.0
      command:
        - kube-apiserver
        - --advertise-address=10.0.1.10
        - --allow-privileged=true
        - --authorization-mode=Node,RBAC
        - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook,AlwaysPullImages
        - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        # ... remaining flags unchanged ...
      volumeMounts:
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
  volumes:
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
  hostNetwork: true
  priorityClassName: system-node-critical
```

**Paso 4 — qué envía el API server y qué espera de vuelta.**

Solicitud:

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "spec": {
    "containers": [
      { "image": "registry.acme.io/payments/payments-api@sha256:9f2b3c7d..." }
    ],
    "annotations": {
      "policy.image-policy.k8s.io/break-glass": "INC-4471"
    },
    "namespace": "payments"
  }
}
```

Respuesta que el webhook debe devolver (HTTP 200 en ambos casos):

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "status": {
    "allowed": false,
    "reason": "image registry.acme.io/payments/payments-api@sha256:9f2b... has no valid cosign signature from the release workflow"
  }
}
```

Solo se reenvían las anotaciones de pod bajo `*.image-policy.k8s.io/*`, y solo si el plugin está configurado para aceptarlas — son el canal de emergencia (break-glass) previsto, y cada uso debería generar una alerta.

**Verificar que el plugin esté efectivamente cargado:**

```
$ sudo crictl ps --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT  POD ID
7a3f1c0e9b2d   9e1d0f3a7b5c   2 minutes ago   Running   kube-apiserver   3        4b8e2f1a0c7d

$ sudo crictl logs 7a3f1c0e9b2d 2>&1 | grep -i 'admission\|imagepolicy' | head
I0803 15:02:11.442901       1 plugins.go:157] Loaded 14 mutating admission controller(s) successfully in the following order: NamespaceLifecycle,LimitRanger,ServiceAccount,...,DefaultIngressClass,MutatingAdmissionWebhook
I0803 15:02:11.443118       1 plugins.go:160] Loaded 15 validating admission controller(s) successfully in the following order: LimitRanger,ServiceAccount,PodSecurity,...,ImagePolicyWebhook,ValidatingAdmissionPolicy,ValidatingAdmissionWebhook

$ kubectl run test --image=docker.io/library/nginx:1.27
Error from server (Forbidden): pods "test" is forbidden: image policy webhook backend denied one or more images: image docker.io/library/nginx:1.27 is not from an approved registry
```

### 5.5 Equivalente en Gatekeeper (para quienes usan Rego)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedrepos
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRepos
      validation:
        openAPIV3Schema:
          type: object
          properties:
            repos:
              type: array
              items:
                type: string
            requireDigest:
              type: boolean
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input_containers[_]
          not any_prefix_matches(container.image)
          msg := sprintf(
            "container <%v> uses disallowed image <%v>; allowed repositories: %v",
            [container.name, container.image, input.parameters.repos])
        }

        violation[{"msg": msg}] {
          input.parameters.requireDigest
          container := input_containers[_]
          not contains(container.image, "@sha256:")
          msg := sprintf(
            "container <%v> image <%v> must be pinned by digest",
            [container.name, container.image])
        }

        any_prefix_matches(image) {
          startswith(image, input.parameters.repos[_])
        }

        input_containers[c] { c := input.review.object.spec.containers[_] }
        input_containers[c] { c := input.review.object.spec.initContainers[_] }
        input_containers[c] { c := input.review.object.spec.ephemeralContainers[_] }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: acme-approved-registries
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  parameters:
    repos:
      - "registry.acme.io/"
      - "registry.k8s.io/"
    requireDigest: true
```

```
$ kubectl get k8sallowedrepos acme-approved-registries -o jsonpath='{.status.totalViolations}{"\n"}'
0

$ kubectl -n staging run bad --image=quay.io/prometheus/node-exporter:v1.8.2
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request:
[acme-approved-registries] container <bad> uses disallowed image <quay.io/prometheus/node-exporter:v1.8.2>;
allowed repositories: ["registry.acme.io/", "registry.k8s.io/"]
```

### 5.6 `AlwaysPullImages` — el control que todos olvidan

Sin él, el cacheo local de imágenes en el nodo es una elusión del aislamiento por namespace: si algún pod en el nodo N alguna vez descargó `registry.acme.io/private/secrets-manager:1.0`, cualquier otro pod planificado en N puede ejecutar esa imagen con `imagePullPolicy: IfNotPresent` **sin presentar jamás una credencial de pull**.

```
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages,ImagePolicyWebhook
```

Verificación:

```
$ kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cache-probe
  namespace: default
spec:
  containers:
    - name: c
      image: registry.acme.io/payments/payments-api:1.8.3
      imagePullPolicy: IfNotPresent
EOF
pod/cache-probe created

$ kubectl get pod cache-probe -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
Always

$ kubectl describe pod cache-probe | sed -n '/Events/,$p'
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  8s    default-scheduler  Successfully assigned default/cache-probe to node-02
  Normal   Pulling    7s    kubelet            Pulling image "registry.acme.io/payments/payments-api:1.8.3"
  Warning  Failed     6s    kubelet            Failed to pull image "registry.acme.io/payments/payments-api:1.8.3": failed to pull and unpack image: failed to resolve reference: unexpected status from HEAD request to https://registry.acme.io/v2/payments/payments-api/manifests/1.8.3: 401 Unauthorized
  Warning  Failed     6s    kubelet            Error: ErrImagePull
```

La política de pull fue reescrita a `Always`, y el pull sin credenciales falló correctamente. **Compromiso:** ahora cada arranque de pod hace un viaje de ida y vuelta al registro. Presupuestá disponibilidad y latencia del registro (una caché pull-through en el nodo o un mirror dentro del clúster es la mitigación habitual), y entendé que un registro inalcanzable ahora bloquea los reinicios de pods en todo el clúster.

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Recorrido de verificación de punta a punta

La secuencia exacta a ejecutar cuando alguien pregunta "¿podemos demostrar qué está corriendo en producción?":

```
# 1. What digest is actually running, per container, cluster-wide?
$ kubectl get pods -A -o json | jq -r '
    .items[] as $p |
    (($p.status.containerStatuses // []) + ($p.status.initContainerStatuses // []))[] |
    [$p.metadata.namespace, $p.metadata.name, .name, .imageID] | @tsv' \
  | sort -u | column -t | head
kube-system  coredns-7c8f9b4d5-2xk7p   coredns  registry.k8s.io/coredns/coredns@sha256:1eeb4c7316bacb1d4c8ead65571cd92dd21e27359f0d4750fbe85edc1f1e5f6f
payments     payments-api-6f4c8d9b7-h2m9q  api  registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
payments     payments-api-6f4c8d9b7-tk3rl  api  registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c

# 2. Detect digest drift — replicas of the same workload running different code.
$ kubectl get pods -A -o json | jq -r '
    .items[] | select(.metadata.ownerReferences != null) |
    "\(.metadata.namespace)/\(.metadata.labels["app.kubernetes.io/name"] // .metadata.labels.app)\t\(.status.containerStatuses[0].imageID)"' \
  | sort -u | awk -F'\t' '{c[$1]++} END {for (k in c) if (c[k]>1) print "DRIFT:", k, c[k]" distinct digests"}'
DRIFT: default/legacy-worker 2 distinct digests

# 3. Verify the signature of a running digest.
$ cosign verify \
    --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    registry.acme.io/payments/payments-api@sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c

Verification for registry.acme.io/payments/payments-api@sha256:9f2b3c7d... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

[{"critical":{"identity":{"docker-reference":"registry.acme.io/payments/payments-api"},
"image":{"docker-manifest-digest":"sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c"},
"type":"cosign container image signature"},"optional":{
"1.3.6.1.4.1.57264.1.1":"https://token.actions.githubusercontent.com",
"Bundle":{"SignedEntryTimestamp":"MEUCIQ...","Payload":{"logIndex":187443901,
"logID":"c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d",
"integratedTime":1785...,"index":187443901}},
"Issuer":"https://token.actions.githubusercontent.com",
"Subject":"https://github.com/acme/payments-api/.github/workflows/release.yaml@refs/tags/v1.8.3"}}]

# 4. Pull the SBOM attestation back out and interrogate it.
$ cosign verify-attestation --type cyclonedx \
    --certificate-identity-regexp '^https://github\.com/acme/payments-api/\.github/workflows/release\.yaml@refs/tags/v.*$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    registry.acme.io/payments/payments-api@sha256:9f2b3c7d... 2>/dev/null \
  | jq -r '.payload' | base64 -d | jq -r '.predicate.components[] | "\(.name)\t\(.version)"' \
  | grep -i 'crypto\|ssl\|xz\|log4j'
golang.org/x/crypto	v0.28.0
libcrypto3	3.3.2-r0
libssl3	3.3.2-r0

# 5. Verify provenance points at the source you think it does.
$ cosign verify-attestation --type slsaprovenance1 \
    --certificate-identity-regexp '^https://github\.com/acme/.*$' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    registry.acme.io/payments/payments-api@sha256:9f2b3c7d... 2>/dev/null \
  | jq -r '.payload' | base64 -d \
  | jq '.predicate.buildDefinition.externalParameters, .predicate.runDetails.builder'
{
  "workflow": {
    "path": ".github/workflows/release.yaml",
    "ref": "refs/tags/v1.8.3",
    "repository": "https://github.com/acme/payments-api"
  }
}
{
  "id": "https://github.com/actions/runner/github-hosted"
}

# 6. Corroborate independently against the transparency log.
$ rekor-cli search --sha sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c
Found matching entries (listed by UUID):
24296fb24b8ad77a3f8e2c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d
24296fb24b8ad77abc9e0f1d2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80912

$ rekor-cli get --uuid 24296fb24b8ad77a3f8e2c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d9a7e5f3c1b0d \
    --format json | jq -r '.IntegratedTime, .LogIndex'
1785294731
187443901
```

**La pregunta del auditor que esto responde:** "demostrame que el binario que corre en `payments/payments-api` fue construido a partir del commit X del repositorio Y por el workflow Z en la fecha D, y que nada lo alteró desde entonces". Los pasos 1, 3 y 5 juntos son esa prueba, y el paso 6 la hace verificable de forma independiente por un tercero que no confía en tu registro.

### 6.2 Catálogo de fallos

| Síntoma | Causa raíz más probable | Comando de diagnóstico | Arreglo |
|---|---|---|---|
| `ErrImagePull` / `401 Unauthorized` | `imagePullSecret` faltante/expirado, SA equivocada, token robot rotado | `kubectl describe pod`, después `kubectl get sa <sa> -o yaml \| grep -A3 imagePullSecrets` | Adjuntar el secreto a la SA o migrar al credential provider del kubelet |
| `ErrImagePull` / `manifest unknown` | Tag borrado, arquitectura equivocada, digest recolectado por la retención del registro | `crane manifest <ref>`, `crane ls <repo>` | Restaurar el artefacto; deshabilitar el GC de digests referenciados |
| `ImagePullBackOff` solo en **algunos** nodos | Deriva del `hosts.toml` por nodo / confianza en la CA | `sudo ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d <ref>` en el nodo que falla | Reconciliar la configuración del nodo con el DaemonSet/Ignition |
| Kyverno: `no signatures found` | Imagen firmada bajo otro digest (índice multi-arch vs. manifest de plataforma), o desajuste del modo referrers | `cosign tree <ref>`; `oras discover -o tree <ref>` | Firmar el digest del **índice**; alinear `--registry-referrers-mode` |
| Kyverno: `no matching signatures: certificate identity ... does not match` | Archivo de workflow renombrado, patrón de tags cambiado, o lo construyó un fork | `cosign verify ... 2>&1 \| grep Subject`; inspeccionar el certificado | Actualizar el glob de `subject`, o rechazar — este es el control funcionando |
| Kyverno: `failed to fetch attestations: ... 403` | Kyverno no tiene credenciales de registro para el repo privado | `kubectl -n kyverno logs deploy/kyverno-admission-controller \| grep -i registry` | Configurar `imageRegistryCredentials.secrets` o `--imagePullSecrets` |
| **El API server no arranca** después de habilitar `ImagePolicyWebhook` | Falta el mount de hostPath, configuración no parseable, ruta incorrecta | `sudo crictl ps -a --name kube-apiserver`; `sudo crictl logs <id>`; `sudo journalctl -u kubelet \| grep apiserver` | Agregar el par `volumes`+`volumeMounts`; validar el YAML |
| Todo se admite pese a la política | `defaultAllow: true`, o `failurePolicy: Ignore`, o binding con `validationActions: ["Audit"]` | `grep defaultAllow /etc/kubernetes/admission/admission-config.yaml`; `kubectl get vapb -o yaml` | Fallar cerrado |
| `cosign verify` → `error validating certificate: no matching CT log found` | Entorno air-gapped o raíz TUF desactualizada | salida de `cosign initialize` | `cosign initialize --mirror <internal> --root <root.json>` |
| `cosign verify` → `no matching signatures` pero la firma existe visiblemente | Se verifica el tag mientras la firma está sobre el digest específico de plataforma | `crane digest --platform linux/amd64 <ref>` vs `crane digest <ref>` | Verificar siempre por el digest del índice |
| El scanner reporta 0 hallazgos en una app real | Binario distroless/estático sin base de datos de paquetes; el scanner no encontró nada que parsear | `syft scan <ref> -o table \| wc -l` | Usar SBOM en tiempo de build; agregar clasificadores binarios |
| Trivy: `DB error: failed to download` en CI | Límite de tasa en el registro de la base de datos de vulnerabilidades | — | Espejar la DB: `trivy image --db-repository registry.acme.io/trivy-db` |

### 6.3 Dos fallos que vale la pena recorrer en detalle

**Fallo A — `cosign verify` falla en una imagen multi-arch.**

```
$ cosign verify --certificate-identity-regexp '...' --certificate-oidc-issuer '...' \
    registry.acme.io/payments/payments-api:1.8.3
Error: no matching signatures:
main.go:74: error during command execution: no matching signatures:

$ crane digest registry.acme.io/payments/payments-api:1.8.3
sha256:3d8f0b6c2e4a1f7d9b0c3e5a7f1d4b6e8a0c2f4d6b8e0a2c4f6d8b0e2a4c6f8d

$ crane digest --platform linux/amd64 registry.acme.io/payments/payments-api:1.8.3
sha256:9f2b3c7d1a4e8b0c5d6f2a9e3b7c1d8f0a4e6b2c9d3f7a1e5b8c0d4f6a2e9b3c

$ cosign verify ... registry.acme.io/payments/payments-api@sha256:9f2b3c7d...
Verification for registry.acme.io/payments/payments-api@sha256:9f2b3c7d... --
  ...checks passed
```

**Diagnóstico:** el pipeline firmó el digest del **manifest de plataforma** (lo que `build-push-action` devuelve como `digest` para un build de una sola plataforma) en vez del digest del **índice** al que apunta el tag. Kubernetes resuelve el tag al índice, así que la admisión verifica el índice y no encuentra nada.
**Arreglo:** firmar el digest del índice. En `docker/build-push-action` con múltiples `platforms`, `steps.build.outputs.digest` *es* el digest del índice — el bug aparece cuando alguien más tarde agrega una segunda plataforma sin volver a revisar el paso de firma. Agregá el job `verify` de §4.2 para que CI lo detecte.

**Fallo B — el API server entra en crash-loop después de habilitar ImagePolicyWebhook.**

```
$ kubectl get nodes
The connection to the server 10.0.1.10:6443 was refused - did you specify the right host or port?

$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE    NAME             ATTEMPT  POD ID
2f1a9c0e3b7d   9e1d0f3a7b5c   9 seconds ago   Exited   kube-apiserver   7        8c3e1b0a5f2d

$ sudo crictl logs 2f1a9c0e3b7d 2>&1 | tail -4
W0803 15:14:02.117338       1 admission.go:78] Admission plugin "ImagePolicyWebhook" configuration error
E0803 15:14:02.117512       1 run.go:74] "command failed" err="failed to initialize admission: couldn't init admission plugin \"ImagePolicyWebhook\": open /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml: no such file or directory"

$ sudo ls -l /etc/kubernetes/admission/
total 8
-rw------- 1 root root  312 Aug  3 15:12 admission-config.yaml
-rw------- 1 root root  641 Aug  3 15:12 imagepolicy-kubeconfig.yaml

$ sudo grep -A6 'volumeMounts' /etc/kubernetes/manifests/kube-apiserver.yaml | head -8
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
```

**Diagnóstico:** los archivos existen en el host, pero el API server corre como contenedor y `/etc/kubernetes/admission` nunca fue montado dentro de él. El fallo de resolución de ruta ocurre dentro del namespace de montaje del contenedor.
**Arreglo:** agregar el par `volumes`/`volumeMounts` de §5.4. El kubelet vuelve a leer el manifiesto del pod estático en segundos; no hace falta reiniciar.

```
$ sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml    # add the mount + volume
$ sleep 25 && kubectl get --raw='/readyz?verbose' | tail -3
[+]shutdown ok
[+]poststarthook/start-legacy-token-tracking-controller ok
readyz check passed
```

> **Regla operativa:** antes de editar `kube-apiserver.yaml`, siempre hacé `sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak`. Mover el manifiesto *fuera* de `/etc/kubernetes/manifests/` detiene el API server; volverlo a poner lo arranca. Ese es tu único camino de recuperación cuando el archivo está mal formado, y es un escenario rutinario del examen.

### 6.4 Verificación en entornos air-gapped

La instancia de bien público de Sigstore es inalcanzable en un clúster air-gapped. Dos enfoques soportados:

**(a) Espejar la raíz TUF y correr Fulcio/Rekor internos:**

```
$ cosign initialize \
    --mirror https://tuf.acme.internal \
    --root /etc/sigstore/acme-tuf-root.json
Root status:
 {
  "local": "/home/sre/.sigstore/root",
  "remote": "https://tuf.acme.internal",
  "metadata": {
    "root.json": { "version": 3, "len": 4271, "expiration": "27 Jan 27 12:00 UTC", "error": "" },
    "targets.json": { "version": 9, "len": 1782, "expiration": "12 Nov 26 09:00 UTC", "error": "" }
  },
  "targets": [ "fulcio_v1.crt.pem", "ctfe.pub", "rekor.pub" ]
 }
```

**(b) Claves de larga vida más bundles offline** — más simple, y correcto cuando controlás ambos extremos:

```
$ cosign generate-key-pair k8s://cosign-system/cosign-signing-key
Private key written to kubernetes://cosign-system/cosign-signing-key
Public key written to cosign.pub

$ cosign sign --key k8s://cosign-system/cosign-signing-key --tlog-upload=false --yes \
    registry.acme.internal/payments/payments-api@sha256:9f2b3c7d...

$ cosign verify --key cosign.pub --insecure-ignore-tlog=true \
    registry.acme.internal/payments/payments-api@sha256:9f2b3c7d...
WARNING: Skipping tlog verification is an insecure practice that lacks transparency/timestamping.
Verification for registry.acme.internal/payments/payments-api@sha256:9f2b3c7d... --
  ...checks passed
```

Attestor de Kyverno correspondiente:

```yaml
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqR8b3F1a5c7d9e0f2a4b6c8d0e2f4a
                      6b8c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c==
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true
                    ctlog:
                      ignoreSCT: true
```

El compromiso es explícito: sin un log de transparencia perdés la capacidad de detectar que una clave fue mal usada antes de saber que estaba comprometida, y asumís la rotación de claves como carga operativa. Espejá Rekor si el entorno lo permite.

---

## 7. Checklist consolidada

| # | Control | Verificar con |
|---|---|---|
| 1 | Cada imagen propia tiene un SBOM de tiempo de build (SPDX + CycloneDX) adjunto como atestación firmada | `cosign verify-attestation --type cyclonedx` |
| 2 | Cada imagen tiene procedencia SLSA v1 que nombra el repo, la ref y el builder correctos | `cosign verify-attestation --type slsaprovenance1` |
| 3 | El material de la clave de firma es inalcanzable desde los pasos de build (keyless, o un job/controlador separado) | Leé el pipeline: ¿el job de build ve `COSIGN_*`? |
| 4 | El registro impone tags inmutables, auto-scan, y bloquea pulls vulnerables/sin firmar | Intentá sobrescribir un tag ya publicado; esperá `denied` |
| 5 | La admisión impone allowlist de registros **y** pinning por digest, en proceso (VAP), fallando cerrado | `kubectl run` con un tag de `docker.io`; esperá denegación |
| 6 | La admisión verifica firmas + atestaciones (Kyverno/Ratify), `failurePolicy: Fail`, `mutateDigest: true` | Desplegá una imagen sin firmar; esperá denegación. Verificá que la imagen del pod admitido sea un digest. |
| 7 | `AlwaysPullImages` habilitado | `kubectl get pod X -o jsonpath='{.spec.containers[0].imagePullPolicy}'` → `Always` |
| 8 | Sin `imagePullSecrets` de larga vida donde haya un credential provider disponible | `kubectl get secrets -A --field-selector type=kubernetes.io/dockerconfigjson` |
| 9 | Los nodos resuelven todas las imágenes a través del registro/mirror interno | `sudo ctr -n k8s.io images pull --hosts-dir ...` en un nodo |
| 10 | Se produce un inventario de digests a nivel de clúster de forma programada y se compara contra el almacén de SBOM | El pipeline de `jq` de §6.1, corrido como CronJob |
| 11 | Los documentos VEX están firmados, adjuntos y son consumidos por la compuerta del scanner | `trivy sbom --vex ...` muestra líneas `Filtered out` |
| 12 | Los caminos de emergencia (exclusiones de política, anotaciones `image-policy.k8s.io`) generan alertas | Consulta al log de auditoría por el prefijo de la anotación |

Los ítems 5–7 son trabajo puro de `kubectl`/plano de control y son la superficie de examen más probable. Los ítems 1–3 son lo que separa a un programa que puede responder "¿estamos afectados por CVE-AAAA-NNNNN?" en diez minutos de uno que no puede responderlo en absoluto.

---

## Referencias

**Temario y examen**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF Curriculum repository — https://github.com/cncf/curriculum
- Linux Foundation CKS program page — https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/

**Documentación oficial de Kubernetes**
- Admission Controllers Reference (ImagePolicyWebhook, AlwaysPullImages) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- Images (pull policy, private registries, digests) — https://kubernetes.io/docs/concepts/containers/images/
- Pull an Image from a Private Registry — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Kubelet Credential Provider — https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/
- Image Volumes — https://kubernetes.io/docs/tasks/configure-pod-container/image-volumes/
- Kubernetes Release SBOMs — https://sbom.k8s.io/
- Kubernetes Supply Chain Security (SIG Release) — https://github.com/kubernetes/sig-release/blob/master/security/README.md
- Verify Kubernetes release artifact signatures — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/

**Estándares de SBOM**
- SPDX specification — https://spdx.dev/use/specifications/
- SPDX 3.0 — https://spdx.github.io/spdx-spec/v3.0.1/
- CycloneDX specification — https://cyclonedx.org/specification/overview/
- CycloneDX / ECMA-424 — https://ecma-international.org/publications-and-standards/standards/ecma-424/
- NTIA Minimum Elements for an SBOM — https://www.ntia.gov/report/2021/minimum-elements-software-bill-materials-sbom
- CISA SBOM resources — https://www.cisa.gov/sbom
- Package URL (PURL) specification — https://github.com/package-url/purl-spec

**VEX**
- OpenVEX specification — https://github.com/openvex/spec
- CISA VEX documentation — https://www.cisa.gov/resources-tools/resources/minimum-requirements-vulnerability-exploitability-exchange-vex

**Procedencia, atestación y firma**
- SLSA v1.0 specification — https://slsa.dev/spec/v1.0/
- SLSA threat model — https://slsa.dev/spec/v1.0/threats
- SLSA provenance predicate — https://slsa.dev/provenance/v1
- in-toto Attestation Framework — https://github.com/in-toto/attestation
- Sigstore documentation — https://docs.sigstore.dev/
- cosign — https://github.com/sigstore/cosign
- Rekor transparency log — https://docs.sigstore.dev/logging/overview/
- Fulcio certificate authority — https://docs.sigstore.dev/certificate_authority/overview/
- Notary Project (Notation) — https://notaryproject.dev/docs/
- Notation trust policy reference — https://github.com/notaryproject/specifications/blob/main/specs/trust-store-trust-policy.md

**Registros y OCI**
- OCI Image Specification v1.1 (referrers, subject) — https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Distribution Specification (Referrers API) — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- Harbor documentation — https://goharbor.io/docs/
- Harbor content trust & vulnerability policy — https://goharbor.io/docs/latest/administration/vulnerability-scanning/
- Zot registry — https://zotregistry.dev/
- ORAS — https://oras.land/docs/
- containerd registry host configuration — https://github.com/containerd/containerd/blob/main/docs/hosts.md
- CRI-O signature verification (containers-policy.json) — https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md

**Herramientas**
- Syft — https://github.com/anchore/syft
- Grype — https://github.com/anchore/grype
- Trivy — https://trivy.dev/latest/docs/
- Trivy VEX support — https://trivy.dev/latest/docs/supply-chain/vex/
- BuildKit attestations — https://docs.docker.com/build/metadata/attestations/
- Docker build provenance — https://docs.docker.com/build/metadata/attestations/slsa-provenance/
- Kubesec — https://kubesec.io/
- KubeLinter — https://docs.kubelinter.io/

**Motores de políticas**
- Kyverno image verification — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- Kyverno verifying attestations — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/#verifying-image-attestations
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Gatekeeper policy library (allowed repos) — https://open-policy-agent.github.io/gatekeeper-library/website/validation/allowedrepos
- Ratify — https://ratify.dev/docs/what-is-ratify
- Connaisseur — https://sse-secure-systems.github.io/connaisseur/

**CI/CD**
- Tekton Chains — https://tekton.dev/docs/chains/
- GitHub Actions OIDC hardening — https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
- GitHub artifact attestations — https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds
- SLSA GitHub Generator — https://github.com/slsa-framework/slsa-github-generator
- CNCF Software Supply Chain Best Practices White Paper — https://github.com/cncf/tag-security/blob/main/community/resources/software-supply-chain-security/secure-software-factory/secure-software-factory.md