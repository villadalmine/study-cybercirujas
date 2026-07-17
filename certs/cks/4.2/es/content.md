# 4.2 Understand your supply chain (SBOM, CI/CD, artifact repositories)

## Qué es la software supply chain

La *software supply chain* es la cadena completa de personas, sistemas y procesos que transforman código fuente en una aplicación corriendo en producción: repositorios de código, dependencias de terceros, sistemas de build (CI), registries de artefactos, sistemas de despliegue (CD) y, finalmente, el runtime en el cluster. Cada eslabón es una superficie de ataque: comprometer cualquiera de ellos permite inyectar código malicioso sin tocar directamente el cluster de Kubernetes.

Casos reales que motivan este dominio del examen: SolarWinds (compromiso del build system), el ataque a `event-stream` en npm (dependencia maliciosa), y Codecov (exfiltración de secretos vía script de CI). Ninguno de estos explotó una vulnerabilidad de Kubernetes — explotaron la cadena que produce lo que corre *sobre* Kubernetes.

## Las fases de la supply chain y sus riesgos

| Fase | Qué incluye | Riesgo típico |
|---|---|---|
| **Source** | Repo Git, dependencias (`package.json`, `go.mod`, `requirements.txt`) | Dependency confusion/typosquatting, secrets commiteados, PRs maliciosos |
| **Build (CI)** | Runners, pipeline definitions, build tools | Poisoned Pipeline Execution (PPE), agentes con permisos excesivos, dependencias no fijadas (`latest`) |
| **Artifact** | Container image, Helm chart, binario | Imagen basada en base image sin mantener, capas con malware, falta de SBOM |
| **Registry** | Docker Hub, ECR, GCR, Harbor, Quay | Push no autorizado, tags mutables, imágenes públicas sin control |
| **Deploy (CD)** | Credenciales de CD, GitOps controller | Credenciales de despliegue sobre-privilegiadas, manifests no revisados |

El examen agrupa **CI/CD**, **artifact repositories** y **SBOM** porque son los tres controles que dan *visibilidad* y *trazabilidad* sobre qué corre en el cluster y de dónde salió.

## CI/CD: entender la superficie de ataque

Un pipeline de CI/CD típicamente tiene acceso a: secrets (credenciales de registry, tokens de cloud), el propio código fuente, y a veces credenciales para desplegar directamente en el cluster. Comprometer el pipeline es equivalente a comprometer todo lo que produce.

Puntos clave para el examen:

- **Poisoned Pipeline Execution (PPE)**: un pipeline que ejecuta código de un PR externo (fork) con acceso a secrets del repo original. Ejemplo de configuración riesgosa en GitHub Actions:

```yaml
# INSEGURO: pull_request_target da acceso a secrets
# incluso a workflows disparados desde un fork
on: pull_request_target
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - run: npm ci && npm run build   # ejecuta código del fork con secrets disponibles
```

  Mitigación: usar `pull_request` (sin acceso a secrets) para código no confiable, o exigir aprobación manual (`environment` con *required reviewers*) antes de exponer secrets.

- **Least privilege en el runner/service account**: el token que usa CI para hacer `kubectl apply` o `docker push` debe tener el mínimo scope posible (namespace específico, registry específico), nunca credenciales de cluster-admin.
- **Pipelines inmutables y auditables**: definir el pipeline como código versionado (`Jenkinsfile`, `.github/workflows/*.yml`, `Tekton Pipeline`), no como configuración manual en la UI del CI server — así cualquier cambio queda en el historial de Git.
- **Fijar versiones de dependencias y de imágenes base** (`FROM golang:1.22.3` en vez de `FROM golang:latest`) para evitar que un build reproduzca contenido distinto cada vez.
- **Segregar el paso que firma/publica artefactos** en un job separado con credenciales propias, para que un fallo en el paso de test/build no exponga las llaves de firma.

## Artifact repositories

Un *artifact repository* (o container registry) es el almacén de las imágenes/charts producidas por el pipeline: Docker Hub, Amazon ECR, Google Artifact Registry, Harbor, Quay, etc. Es el punto donde el cluster confía ciegamente en que la imagen que va a correr es la que el pipeline realmente construyó.

Prácticas que el examen espera que entiendas:

- **Registries privados** en vez de públicos para imágenes propias; acceso vía `imagePullSecrets`.

```bash
kubectl create secret docker-registry regcred \
  --docker-server=myregistry.example.com \
  --docker-username=ci-bot \
  --docker-password="$REGISTRY_TOKEN" \
  --docker-email=ci@example.com
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
    - name: app
      image: myregistry.example.com/team/app:1.4.2
  imagePullSecrets:
    - name: regcred
```

- **Tags inmutables**: usar el *digest* (`@sha256:...`) o habilitar *immutable tags* en el registry, porque un tag como `:latest` o `:v1.4` puede repuntar a contenido distinto sin previo aviso.

```bash
docker pull myregistry.example.com/team/app@sha256:3f8a1c9e2b...
```

- **Restringir de qué registries el cluster puede tirar imágenes** (allowlisting) — el mecanismo de enforcement (admission controllers como Kyverno/Gatekeeper) se profundiza en el tema 4.3, pero conceptualmente es parte de entender la supply chain: sin esto, cualquier Pod puede pullear de cualquier registry público.
- **Retention y limpieza** de imágenes viejas/vulnerables para reducir superficie expuesta.

## SBOM (Software Bill of Materials)

Un **SBOM** es un inventario formal y legible por máquina de todos los componentes (paquetes de SO, librerías de lenguaje, licencias, versiones) que forman una imagen o artefacto. Es la pieza que da *visibilidad*: sin SBOM no sabés qué hay realmente dentro de una imagen más allá de lo que dice el `Dockerfile`.

Formatos estándar (ambos relevantes para el examen):

- **SPDX** (Software Package Data Exchange) — estándar ISO/IEC 5962:2021, mantenido por la Linux Foundation.
- **CycloneDX** — estándar orientado a seguridad, mantenido por OWASP.

### Generar un SBOM con `syft`

```bash
$ syft nginx:1.25 -o cyclonedx-json=sbom.json
 ✔ Loaded image                nginx:1.25
 ✔ Parsed image                sha256:8a1e2c...
 ✔ Cataloged packages          [128 packages]
```

Fragmento del SBOM resultante:

```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "components": [
    {
      "type": "library",
      "name": "openssl",
      "version": "3.0.13",
      "purl": "pkg:deb/debian/openssl@3.0.13"
    }
  ]
}
```

### Usar el SBOM para escanear vulnerabilidades

Un SBOM se convierte en accionable cuando se lo cruza contra bases de datos de CVEs — no hace falta re-escanear la imagen entera si ya tenés el inventario:

```bash
$ trivy sbom sbom.json
nginx:1.25 (debian 12.5)
=========================
Total: 3 (HIGH: 2, CRITICAL: 1)

┌──────────┬────────────────┬──────────┬───────────────┐
│ Library  │ Vulnerability  │ Severity │ Fixed Version │
├──────────┼────────────────┼──────────┼───────────────┤
│ openssl  │ CVE-2024-XXXXX │ CRITICAL │ 3.0.14         │
└──────────┴────────────────┴──────────┴───────────────┘
```

Este flujo (generar SBOM en el pipeline → adjuntarlo al artefacto en el registry → escanear en cada release y en runtime) es el patrón que se espera que reconozcas: el SBOM se genera **una vez, en CI**, y se reutiliza en distintos puntos del ciclo de vida en lugar de volver a analizar el binario cada vez.

## Provenance y attestations (SLSA / in-toto)

Más allá de *qué* contiene una imagen (SBOM), la supply chain también necesita responder *cómo* y *dónde* se construyó (provenance). El framework **SLSA** (Supply-chain Levels for Software Artifacts) define niveles crecientes de garantías: desde build scripted (SLSA 1) hasta builds en infraestructura aislada con provenance firmada y no falsificable (SLSA 3/4).

Una **attestation** es una declaración firmada (formato **in-toto**) que acompaña al artefacto: "esta imagen fue construida por el pipeline X, a partir del commit Y, con estas dependencias". Herramientas como `cosign` permiten adjuntar y verificar estas attestations junto con la firma de la imagen:

```bash
# adjuntar una attestation de provenance a la imagen
cosign attest --predicate provenance.json \
  --type slsaprovenance \
  myregistry.example.com/team/app@sha256:3f8a1c9e2b...

# verificar la attestation antes de desplegar
cosign verify-attestation --type slsaprovenance \
  myregistry.example.com/team/app@sha256:3f8a1c9e2b...
```

La firma y verificación *enforced* en el cluster (política que rechaza imágenes no firmadas) es tema de 4.3 — acá lo importante es entender que **SBOM responde "qué hay adentro"** y **provenance/attestation responde "de dónde vino y cómo se construyó"**, y que ambas son metadata que viaja junto al artefacto desde CI hasta el registry.

## Resumen para el examen

- La supply chain tiene 5 eslabones: source → build (CI) → artifact → registry → deploy (CD). Cualquiera puede ser el vector de ataque, no solo el runtime.
- **PPE (Poisoned Pipeline Execution)**: pipelines que ejecutan código no confiable (forks) con acceso a secrets — riesgo típico de `pull_request_target`.
- Los runners/service accounts de CI/CD deben tener el mínimo privilegio posible, nunca cluster-admin.
- Usar **digests** (`@sha256:...`) en vez de tags mutables para referenciar imágenes de forma inmutable.
- **SBOM** = inventario de componentes de un artefacto. Formatos: **SPDX** y **CycloneDX**. Se genera con herramientas como `syft` y se puede escanear con `trivy sbom`.
- **Provenance/attestation** (SLSA, in-toto) = evidencia firmada de cómo y dónde se construyó el artefacto, distinto del SBOM (que describe el contenido).
- El *enforcement* (whitelisting de registries, rechazo de imágenes no firmadas vía admission control) pertenece al tema 4.3 — acá el foco es comprender los componentes y riesgos de la cadena.

## Referencias

- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF TAG Security — Software Supply Chain Security: https://github.com/cncf/tag-security/tree/main/supply-chain-security
- SLSA (Supply-chain Levels for Software Artifacts): https://slsa.dev/
- in-toto: https://in-toto.io/
- Sigstore / cosign: https://docs.sigstore.dev/ y https://github.com/sigstore/cosign
- syft (generación de SBOM): https://github.com/anchore/syft
- trivy (escaneo de vulnerabilidades y SBOM): https://trivy.dev/
- SPDX: https://spdx.dev/
- CycloneDX: https://cyclonedx.org/
- Kubernetes — Images: https://kubernetes.io/docs/concepts/containers/images/
- Kyverno — Verify Images: https://kyverno.io/docs/writing-policies/verify-images/
- OPA Gatekeeper: https://open-policy-agent.github.io/gatekeeper/website/docs/