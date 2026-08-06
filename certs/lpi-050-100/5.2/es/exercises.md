# Guía de Estudio: LPI 050-100 — Tema 5.2: Product Management & Release Management

**Examen:** LPI Open Source Essentials (050-100)  
**Tema 5.2:** Product Management / Release Management  
**Peso:** 5  
**Referencia Oficial:** [LPI Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## 1. Technical & Architectural Foundations

En la ingeniería de plataformas de código abierto y cloud-native, **Product Management** y **Release Management** rigen cómo el software transiciona desde modificaciones de código hacia artefactos de producción predecibles y resilientes.

```
                   +-------------------------------------------------------------+
                   |                 DEVELOPMENT & COMMIT STAGE                  |
                   |  Conventional Commits (feat, fix, refactor, BREAKING)       |
                   +------------------------------+------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |                 AUTOMATED RELEASE PIPELINE                  |
                   |  1. SemVer Engine determines Next Version (e.g. v1.4.0)     |
                   |  2. Build Binary / OCI Container Image                      |
                   |  3. Generate SBOM (CycloneDX / SPDX via Syft)               |
                   |  4. Cryptographic Artifact Signing (Cosign / Keyless OIDC)   |
                   +------------------------------+------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |                 PROGRESSIVE DELIVERY STAGE                  |
                   |  Canary / Blue-Green Deployment (Argo Rollouts / Flagger)   |
                   |  Real-time Prometheus Metrics Verification & Auto-Rollback     |
                   +-------------------------------------------------------------+
```

### Key Architectural Concepts & Mechanics

1. **Open Source Product Management vs. Traditional Commercial Product Management**
   - **Upstream / Downstream Dynamics:** Los productos de código abierto mantienen un repositorio comunitario upstream (por ejemplo, el núcleo de Kubernetes) mientras que las distribuciones comerciales downstream (por ejemplo, Red Hat OpenShift, Google GKE) empaquetan, fortalecen (harden), dan soporte y extienden el software base.
   - **Community-Driven Governance:** La priorización ocurre a través de propuestas de mejora abiertas (Enhancement Proposals, por ejemplo, KEPs en Kubernetes, PEPs en Python) en lugar de roadmaps ejecutivos cerrados.

2. **Release Cadence & Lifecycle Models**
   - **Semantic Versioning ([SemVer 2.0.0](https://semver.org/)):** Formato `MAJOR.MINOR.PATCH`.
     - `MAJOR`: Cambios incompatibles en la API.
     - `MINOR`: Funcionalidad añadida compatible hacia atrás (backward-compatible).
     - `PATCH`: Correcciones de errores compatibles hacia atrás (backward-compatible bug fixes).
   - **Release Stages:** Alpha (incompleto en funcionalidades, altamente volátil) $\rightarrow$ Beta (funcionalidades completas, errores operativos) $\rightarrow$ Release Candidate / RC (pruebas de producción, fase de estabilidad) $\rightarrow$ General Availability / GA (release de producción estable) $\rightarrow$ End-of-Life / EOL (depreciación y terminación del soporte).
   - **Long-Term Support (LTS) vs. Rolling Releases:**
     - *LTS:* Cadencia fija de releases con correcciones de seguridad backported garantizadas durante períodos extendidos (por ejemplo, 2–5 años). Objetivo: Cargas de trabajo empresariales conservadoras.
     - *Rolling Release:* Modelo de integración y despliegue continuos sin versiones major distintas (por ejemplo, Arch Linux, continuous edge delivery). Objetivo: Entornos de rápida iteración.

3. **Supply Chain Security & Software Bill of Materials (SBOM)**
   - Las pipelines de release modernas deben producir evidencia criptográfica de la procedencia de los artefactos. Un **SBOM** enumera todas las dependencias transitivas, licencias y digests de módulos para permitir el rastreo de vulnerabilidades (coincidencia de CVE).
   - Las herramientas de firma criptográfica como **Cosign** (parte del [proyecto Sigstore](https://sigstore.dev/)) firman imágenes de contenedor OCI en registries utilizando firmas de identidad keyless de OIDC o pares de claves pública/privada.

4. **Progressive Delivery & Feature Management**
   - **Canary Deployments:** Enrutar una pequeña fracción del tráfico de usuarios en vivo (por ejemplo, 5%) a un nuevo release mientras se monitorean las tasas de error, la latencia (p99) y las métricas del sistema a través de Prometheus antes de escalar al 100%.
   - **Blue-Green Deployments:** Mantener dos entornos físicos/virtuales idénticos (Blue = tráfico activo, Green = nuevo release inactivo). El tráfico se conmuta instantáneamente a nivel de load balancer tras la verificación de salud.
   - **Feature Flags:** Desacoplar el despliegue de código de la exposición de funcionalidades mediante la evaluación de flags condicionales en tiempo de ejecución (por ejemplo, a través de OpenFeature / LaunchDarkly) sin requerir reinicios o nuevos despliegues de la aplicación.

---

## 2. Guided Production Exercises

### Exercise 1: Semantic Versioning, Conventional Commits, and Automated Versioning

En este ejercicio, inicializarás un repositorio git, aplicarás [Conventional Commits](https://www.conventionalcommits.org/) y ejecutarás el cálculo automatizado de SemVer utilizando herramientas CLI.

#### Step 1.1: Initialize the repository and set up initial state
Ejecutá los siguientes comandos en tu shell para simular el ciclo de vida de un proyecto:

```bash
mkdir -p /tmp/release-management-demo && cd /tmp/release-management-demo
git init -b main
git config user.name "SRE Engineer"
git config user.email "sre@example.com"

# Create base application structure
echo 'console.log("App v1.0.0 initialized");' > app.js
git add app.js
git commit -m "feat: initial core application setup"

# Tag initial release
git tag -a v1.0.0 -m "Release v1.0.0"
```

**Expected Shell Output:**
```text
Initialized empty Git repository in /tmp/release-management-demo/.git/
[main (root-commit) 8a1b2c3] feat: initial core application setup
 1 file changed, 1 insertion(+)
 create mode 100644 app.js
```

#### Step 1.2: Commit features, bug fixes, and breaking changes
Simulá las iteraciones de desarrollo subsecuentes adhiriéndote estrictamente a las especificaciones de Conventional Commits:

```bash
# Iteration 1: Bug fix (Triggers PATCH update)
echo 'console.log("Fixed null pointer issue");' >> app.js
git add app.js
git commit -m "fix(auth): resolve null pointer exception during OAuth handshake"

# Iteration 2: Backward-compatible feature (Triggers MINOR update)
echo 'function metricsExporter() { return true; }' >> app.js
git add app.js
git commit -m "feat(telemetry): add Prometheus metrics exporter endpoint"

# Iteration 3: Breaking API change (Triggers MAJOR update)
echo 'function v2AuthHandler() { throw new Error("v1 API deprecated"); }' >> app.js
git add app.js
git commit -m "feat(api)!: remove v1 authentication endpoints

BREAKING CHANGE: The /v1/auth endpoint has been permanently removed. Migrate to /v2/auth."
```

**Expected Shell Output:**
```text
[main d4e5f6a] fix(auth): resolve null pointer exception during OAuth handshake
 1 file changed, 1 insertion(+)
[main 7b8c9d0] feat(telemetry): add Prometheus metrics exporter endpoint
 1 file changed, 1 insertion(+)
[main 1a2b3c4] feat(api)!: remove v1 authentication endpoints
 1 file changed, 1 insertion(+)
```

#### Step 1.3: Inspect commit history and evaluate next version
Examiná la estructura del log utilizando `git log`:

```bash
git log --oneline --decorate v1.0.0..HEAD
```

**Expected Shell Output:**
```text
1a2b3c4 (HEAD -> main) feat(api)!: remove v1 authentication endpoints
7b8c9d0 feat(telemetry): add Prometheus metrics exporter endpoint
d4e5f6a fix(auth): resolve null pointer exception during OAuth handshake
```

---

#### Comprehension Questions — Exercise 1

**Question 1.1:** Dado el tag inicial de git `v1.0.0` y los tres commits subsecuentes (`fix(auth)...`, `feat(telemetry)...`, `feat(api)!...`), ¿cuál es el número exacto de la nueva versión que una herramienta automatizada de SemVer debe calcular y por qué?

**Question 1.2:** Si el historial de commits contuviera *únicamente* `fix(auth)...` y `feat(telemetry)...` después de `v1.0.0`, ¿cuál sería el número de versión resultante?

---

### Exercise 2: Software Bill of Materials (SBOM) Generation and Cryptographic Artifact Signing

En este ejercicio, empaquetarás un artefacto contenedorizado, construirás un SBOM usando [Syft](https://github.com/anchore/syft) y generarás/verificarás una firma criptográfica utilizando [Cosign](https://github.com/sigstore/cosign).

#### Step 2.1: Create a minimal Dockerfile and build an OCI image
Escribí un Dockerfile sintácticamente válido y construí la imagen localmente usando Docker/Podman:

```bash
cat << 'EOF' > Dockerfile
FROM alpine:3.19.1
RUN apk add --no-舆-cache curl bash jq
COPY app.js /app/app.js
ENTRYPOINT ["/bin/bash", "-c", "echo Application Running && sleep 3600"]
EOF

# Build local OCI image artifact
docker build -t local/release-app:1.0.0 .
```

**Expected Shell Output:**
```text
[+] Building 1.2s (7/7) FINISHED
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 168B
 => [internal] load .dockerignore
 => => transferring context: 2B
 => [internal] load metadata for docker.io/library/alpine:3.19.1
 => [1/3] FROM docker.io/library/alpine:3.19.1
 => [2/3] RUN apk add --no-cache curl bash jq
 => [3/3] COPY app.js /app/app.js
 => exporting to image
 => => naming to docker.io/local/release-app:1.0.0
```

#### Step 2.2: Generate a CycloneDX JSON Software Bill of Materials (SBOM)
Utilizá `syft` para escanear la jerarquía de capas de la imagen OCI y extraer los metadatos de los paquetes en un formato estándar:

```bash
syft local/release-app:1.0.0 -o cyclonedx-json=sbom.cyclonedx.json
```

Inspeccioná el archivo SBOM generado para verificar la estructura del esquema:

```bash
head -n 25 sbom.cyclonedx.json
```

**Expected Shell Output:**
```json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "version": 1,
  "metadata": {
    "timestamp": "2026-08-06T19:21:08Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.0.0"
      }
    ],
    "component": {
      "bom-ref": "pkg:oci/release-app@sha256:d3b4c5...",
      "type": "container",
      "name": "local/release-app",
      "version": "1.0.0"
    }
  }
}
```

#### Step 2.3: Generate Cosign Keypair and Sign Artifact Metadata
Generá un par de claves de Cosign para atestar criptográficamente el artefacto de release:

```bash
# Generate Cosign keypair without passphrase for non-interactive test
COSIGN_PASSWORD="" cosign generate-key-pair

# Inspect generated key files
ls -l cosign.key cosign.pub
```

**Expected Shell Output:**
```text
Private key written to cosign.key
Public key written to cosign.pub
-rw------- 1 root root  649 Aug  6 19:21 cosign.key
-rw-r--r-- 1 root root  178 Aug  6 19:21 cosign.pub
```

---

#### Comprehension Questions — Exercise 2

**Question 2.1:** ¿Qué problema específico en la cadena de suministro de software resuelve la generación de un SBOM estandarizado (por ejemplo, CycloneDX o SPDX) durante la respuesta a incidentes de seguridad (como Log4Shell)?

**Question 2.2:** ¿Por qué firmar el digest (`sha256:hash`) de una imagen de contenedor con Cosign es preferible a firmar un tag mutable como `:latest` o `:1.0.0`?

---

### Exercise 3: Progressive Delivery Mechanics — Automated Canary Rollout Manifest

En este ejercicio, analizarás un manifiesto personalizado de Kubernetes completo y de nivel de producción para **Argo Rollouts** (o Flagger) para gestionar releases progresivos a través del análisis de métricas en tiempo real.

#### Step 3.1: Analyze the complete Argo Rollout custom resource manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service-rollout
  namespace: production
  labels:
    app: payment-service
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
      - name: payment-service
        image: registry.enterprise.io/finance/payment-service:v2.1.0
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            cpu: "250m"
            memory: "512Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
  strategy:
    canary:
      canaryService: payment-service-canary
      stableService: payment-service-stable
      trafficRouting:
        nginx:
          stableIngress: payment-service-ingress
      steps:
      - setWeight: 10
      - pause: { duration: 10m }
      - setWeight: 30
      - pause: { duration: 30m }
      - setWeight: 50
      - pause: { duration: 1h }
      analysis:
        templates:
        - templateName: success-rate-prometheus-check
        args:
        - name: service-name
          value: payment-service-canary
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-prometheus-check
  namespace: production
spec:
  metrics:
  - name: success-rate
    interval: 1m
    successCondition: result[0] >= 0.995
    failureLimit: 3
    provider:
      prometheus:
        address: http://prometheus-k8s.monitoring.svc.cluster.local:9090
        query: |
          sum(rate(http_requests_total{app="payment-service-canary", status=~"2.*|3.*"}[2m]))
          /
          sum(rate(http_requests_total{app="payment-service-canary"}[2m]))
```

#### Step 3.2: Simulate monitoring and promotion CLI execution
Ejecutá el siguiente comando CLI para monitorear una progresión activa de rollout:

```bash
kubectl argo rollouts get rollout payment-service-rollout -n production --watch
```

**Expected Output:**
```text
Name:            payment-service-rollout
Namespace:       production
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/6 (setWeight: 10)
  SetWeight:     10
  ActualWeight:  10
Images:          registry.enterprise.io/finance/payment-service:v1.9.0 (stable)
                 registry.enterprise.io/finance/payment-service:v2.1.0 (canary)
Replicas:
  Desired:       10
  Current:       10
  Updated:       1
  Ready:         10
  Available:     10

NAME                                                                 STATUS        GI  AGE  HOLD
├── revision:1                                                       stable        d8  14d
│   └── payment-service-rollout-687496d8b-4x2lz                      Running       d8  14d
└── revision:2                                                       canary        e9  3m
    ├── payment-service-rollout-79bf877ec-9q1zw                      Running       e9  3m
    └── inline-analysis:success-rate-prometheus-check-revision-2-1  Successful    e9  2m
```

---

#### Comprehension Questions — Exercise 3

**Question 3.1:** De acuerdo con el manifiesto del Paso 3.1, ¿qué umbral debe satisfacer la métrica de la consulta de Prometheus para que el despliegue proceda sin activar un rollback?

**Question 3.2:** ¿Cuál es la diferencia operacional fundamental entre una estrategia de despliegue **Blue/Green** y una estrategia **Canary** en cuanto al consumo de recursos y la mitigación de riesgos?

---

<details>
<summary><strong>Click to expand Solutions and Detailed Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1:**  
  El nuevo número de versión es **`v2.0.0`**.  
  *Razón Técnica:* Aunque `fix(auth)` solicita un incremento de `PATCH` (1.0.0 $\rightarrow$ 1.0.1) y `feat(telemetry)` solicita un incremento de `MINOR` (1.0.0 $\rightarrow$ 1.1.0), el tercer commit (`feat(api)!: ...`) contiene un signo de exclamación (`!`) después del alcance (scope) y un pie de página (footer) `BREAKING CHANGE:` designado explícitamente. Bajo las reglas de SemVer 2.0.0, cualquier breaking change en la API fuerza un incremento inmediato del dígito de versión `MAJOR`, reiniciando `MINOR` y `PATCH` a cero.

* **Answer 1.2:**  
  El número de versión sería **`v1.1.0`**.  
  *Razón Técnica:* `fix` incrementa `PATCH`, pero `feat` incrementa `MINOR`. Cuando múltiples commits se acumulan dentro de una sola ventana de release, se aplica el incremento de mayor precedencia. `MINOR` tiene mayor rango que `PATCH`.

---

### Exercise 2 Solutions

* **Answer 2.1:**  
  Cuando se divulga una vulnerabilidad de día cero (por ejemplo, Log4Shell en Java o una librería C vulnerable dentro de las imágenes base de Alpine), los equipos de seguridad deben identificar rápidamente qué artefactos en ejecución contienen la versión del paquete vulnerable. Buscar en repositorios de código fuente primario es insuficiente porque las dependencias de terceros se obtienen durante las construcciones de los contenedores. Los formatos SBOM estandarizados (CycloneDX/SPDX) proporcionan un índice legible por máquina de componentes de software exactos, dependencias transitivas y hashes. Los motores de seguridad (por ejemplo, Dependency-Track, Grype) consultan este SBOM al instante sin volver a escanear las capas de la imagen.

* **Answer 2.2:**  
  Los tags de imágenes Docker como `:latest` o `:1.0.0` son **punteros mutables**. Un actor malicioso o una pipeline defectuosa pueden sobrescribir el tag `:1.0.0` en un registry para apuntar a un binario completamente diferente sin actualizar la firma. El **digest sha256** (por ejemplo, `sha256:d3b4c5...`) es un hash inmutable y derivado criptográficamente del manifiesto y las capas de la imagen. Firmar el digest garantiza que el flujo exacto de bytes verificado por Cosign sea idéntico al que ejecuta el runtime de contenedores de Kubernetes (`containerd` o `CRIO`) en los nodos host.

---

### Exercise 3 Solutions

* **Answer 3.1:**  
  La condición de la métrica de Prometheus `successCondition: result[0] >= 0.995` requiere que **al menos el 99.5%** de todo el tráfico HTTP enrutado al pod canary (`payment-service-canary`) produzca códigos de estado HTTP 2xx o 3xx a lo largo de una ventana deslizante de 2 minutos. Si la tasa de error supera el 0.5% durante 3 verificaciones consecutivas (`failureLimit: 3`), Argo Rollouts aborta automáticamente el despliegue, escala el despliegue canary a 0 réplicas y vuelve a enrutar el 100% del tráfico a `payment-service-stable`.

* **Answer 3.2:**  
  * **Consumo de Recursos:** Blue/Green requiere reservar un 200% de capacidad (aprovisionar una copia completa y duplicada de la infraestructura de producción junto a las cargas de trabajo activas) durante el rollout. Canary requiere una capacidad adicional mínima (por ejemplo, un 10% adicional de pods para el paso 1).
  * **Mitigación de Riesgos:** Blue/Green conmuta al 100% de los usuarios en vivo instantáneamente de Blue a Green. Si ocurre un error no detectado en un caso límite (edge-case), todos los usuarios experimentan la falla de manera simultánea hasta que el tráfico se vuelva a conmutar. Canary limita la exposición a un subconjunto controlado de usuarios (por ejemplo, 10%), aislando el radio de falla durante las ventanas de evaluación.

</details>