# Tema 3.3: Generating Audit Trails and Enforcing Policy Compliance

> **Dominio 3 — Observability, Compliance & Security del CNPE.** Peso: 3.
> Este tema responde a tres preguntas que un auditor externo te hará tarde o temprano: *¿qué está corriendo?*, *¿de dónde salió?* y *¿cómo demostrás que cumple la política?* — de forma **continua, verificable y a escala**, sin convertir al platform team en un cuello de botella manual.

---

## 1. Motivación y problema arquitectónico de producción

El Platform Engineer no escribe el código de las aplicaciones, pero es responsable del **golden path** por el que ese código llega a producción. Cuando llega la auditoría de SOC 2 Type II, el requisito de PCI-DSS 6.3.2 (inventario de componentes custom y de terceros), FedRAMP, o la **EU Cyber Resilience Act** (que a partir de 2027 exige SBOM para todo producto con elementos digitales vendido en la UE), la pregunta no es *"¿tu equipo es cuidadoso?"* sino *"¿mostrame la evidencia, generada por máquina, de que ningún artefacto sin firmar, con un CVE crítico o violando la política, alcanzó producción — para cada deploy de los últimos 12 meses"*.

Ese es el problema arquitectónico. Se descompone en dos planos que este tema une:

### 1.1 El plano de la procedencia (audit trail / SBOM)

La cadena de suministro de software moderna es un DAG opaco. Una imagen de contenedor de 200 MB arrastra cientos de paquetes transitivos (`glibc`, `openssl`, un `log4j` que nadie recuerda haber importado). Los incidentes que definieron la disciplina lo dejaron claro:

- **SolarWinds (2020)**: el build system comprometido inyectó backdoor en un artefacto legítimamente firmado. Firmar no alcanza si no atestiguás *cómo* se construyó.
- **Log4Shell (CVE-2021-44228)**: el costo real no fue parchear, fue **encontrar** dónde estaba `log4j`. Las organizaciones con SBOM lo resolvieron con una query; el resto pasó semanas escaneando.
- **xz-utils (CVE-2024-3094, 2024)**: backdoor introducido por un maintainer con acceso legítimo, activo solo en builds con ciertas condiciones. Demostró que la confianza en el origen debe ser verificable, no asumida.

El **SBOM** (Software Bill of Materials) es el inventario legible por máquina de esos componentes. Pero un SBOM suelto en un bucket S3 es un documento muerto. El objetivo de producción es que el SBOM sea una **atestación firmada, ligada criptográficamente al digest de la imagen** (no al tag mutable), verificable en el momento del admission.

### 1.2 El plano de la aplicación de política (policy enforcement)

Generar evidencia es necesario pero no suficiente. El auditor también pregunta: *"¿qué impide que un pod privilegiado, sin límites de recursos, con una imagen `:latest` sin firmar, se despliegue?"*. La respuesta de producción no es "revisión manual en el PR" (no escala, no deja rastro) sino un **admission controller** que rechaza en el momento del `kubectl apply` y **registra la decisión**.

El problema arquitectónico central de este tema es reconciliar tres fuerzas en tensión:

| Fuerza | Qué exige | Riesgo si domina sola |
|---|---|---|
| **Compliance** | Evidencia continua, deny-by-default, inmutabilidad del audit log | Fricción; developers evaden el golden path |
| **Developer velocity** | Feedback rápido, self-service, políticas comprensibles | Controles laxos; "lo arreglamos después" |
| **Operabilidad** | Bajo overhead, sin single points of failure en el data path | Webhooks que tumban el cluster cuando fallan |

El error clásico: un `ValidatingWebhookConfiguration` con `failurePolicy: Fail` cuyo pod de política se cae → **ningún pod puede crearse en todo el cluster**, incluidos los del sistema. La compliance mal implementada es un incidente de disponibilidad esperando ocurrir.

### 1.3 El modelo mental: shift-left + shift-right + el registro en el medio

```
                          [ Firma + Atestación SBOM/provenance ]
   ┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────┐
   │  Source  │──▶│  Build   │──▶│   Registry   │──▶│   Admission   │──▶│ Runtime  │
   │ (git)    │   │  (CI)    │   │  (OCI + sig) │   │ (Kyverno/GK)  │   │ (Falco)  │
   └──────────┘   └──────────┘   └──────────────┘   └───────────────┘   └──────────┘
       │              │               │                    │                  │
   commit sign    SBOM (syft)     cosign attest       verify sig +       audit events
   (gitsign)      SLSA prov.      cosign sign         verify SBOM        (runtime drift)
                  (grype gate)    (immutable digest)  + policy report
       └───────────────────────────── K8s API server audit log ──────────────────────┘
                          (quién hizo qué, cuándo, contra qué recurso)
```

El **audit trail** no es un solo artefacto: es la unión del *audit log del API server* (mutaciones al estado deseado), las *atestaciones firmadas* (procedencia del artefacto) y los *policy reports* (qué se cumplió/violó). El tema 3.3 exige entender cómo se generan y correlacionan los tres.

---

## 2. Comparativas técnicas y trade-offs

### 2.1 Formatos de SBOM: SPDX vs CycloneDX

Los dos estándares que el examen espera que conozcas. Ambos son first-class en el ecosistema CNCF.

| Dimensión | **SPDX** | **CycloneDX** |
|---|---|---|
| Gobernanza | Linux Foundation; ISO/IEC 5962:2021 | OWASP |
| Foco de diseño | Licencias y compliance legal (origen histórico) | Seguridad de la supply chain, VEX |
| Formatos serialización | Tag-value, JSON, YAML, RDF | JSON, XML, Protobuf |
| VEX (Vulnerability Exploitability eXchange) | Vía SPDX 3.0 / perfil de seguridad | Nativo y maduro |
| Relaciones entre componentes | Muy expresivo (`RELATIONSHIP` types) | `dependencies` graph |
| Mandato regulatorio | Referenciado por NTIA "minimum elements" | Referenciado por NTIA; fuerte en tooling de seguridad |
| Cuándo elegirlo | Auditoría legal/licencias, requisitos gubernamentales US | Pipelines de seguridad, correlación con vuln scanners |

**Trade-off práctico:** en la práctica de plataforma, generás **ambos** con la misma herramienta (`syft` los emite los dos) y los adjuntás como atestaciones separadas. No es una decisión excluyente; es un costo marginal casi nulo. Elegí uno como *canónico* para tus queries internas.

### 2.2 Generadores de SBOM

| Herramienta | Fortaleza | Debilidad | Formatos de salida |
|---|---|---|---|
| **syft** (Anchore) | Amplia cobertura de ecosistemas; integra con grype; scan de filesystem, imagen y dir | No escanea vulnerabilidades por sí solo | SPDX, CycloneDX, syft-json |
| **trivy** (Aqua) | SBOM + scan de vulns + IaC + secrets en una sola herramienta | SBOM menos detallado que syft en algunos casos | SPDX, CycloneDX |
| **cdxgen** (CycloneDX) | Muy profundo en árboles de dependencias por lenguaje | Solo CycloneDX; más pesado | CycloneDX |
| **docker sbom / buildx** | Integrado en el build (BuildKit genera provenance + SBOM) | Atado a Docker/BuildKit | SPDX |

**Recomendación de arquitectura:** generá el SBOM **en el momento del build** (BuildKit `--sbom=true` o `syft` sobre la imagen recién construida), no post-hoc sobre el registry. El SBOM de build captura el contexto exacto; el post-hoc reconstruye por heurística.

### 2.3 Policy engines para admission control

El corazón del enforcement. Las tres opciones que el CNPE espera que sepas comparar:

| Dimensión | **OPA / Gatekeeper** | **Kyverno** | **sigstore policy-controller** |
|---|---|---|---|
| Lenguaje de política | Rego (declarativo, curva de aprendizaje alta) | YAML (nativo K8s, sin lenguaje nuevo) | YAML (`ClusterImagePolicy`) |
| Alcance | Genérico (cualquier JSON), reutilizable fuera de K8s | Específico K8s, muy ergonómico | Especializado: verificación de firmas/atestaciones |
| Mutación de recursos | No (Gatekeeper mutation es aparte y limitado) | Sí, nativo y potente (`mutate`) | No |
| Generación de recursos | No | Sí (`generate`: NetworkPolicies, quotas por namespace) | No |
| Verificación de firmas | Vía external data / bibliotecas | Nativo (`verifyImages`) | Su razón de ser |
| Policy reports | Vía audit / constraint status | `PolicyReport` CRD (open standard) | Admite reporte vía eventos |
| Testing offline | `opa test`, `conftest` | `kyverno test`, `kyverno apply` | limitado |
| Cuándo elegirlo | Política transversal multi-plataforma, equipos con Rego | Estándar de facto K8s-only, mutate+generate+verify | Solo verificación de supply chain (o combinado con Kyverno) |

**Trade-off clave:** Rego es más poderoso y portable pero introduce un lenguaje que tu equipo debe dominar y mantener. Kyverno mantiene la política en YAML —el lenguaje que el equipo ya lee— a costa de estar acoplado a Kubernetes. Para una plataforma K8s-centric, Kyverno reduce el time-to-policy drásticamente. Para gobernanza que abarca Terraform + K8s + APIs, OPA gana por portabilidad (`conftest` corre la misma política Rego en CI sobre HCL).

### 2.4 Backends de auditoría del API server

| Backend | Mecanismo | Uso | Riesgo |
|---|---|---|---|
| **Log** | Escribe a archivo en el nodo del control plane | Simple, sin dependencias; recolectás con fluentbit/vector | Depende del acceso al FS del control plane (imposible en muchos managed K8s) |
| **Webhook** | POST a un endpoint HTTP externo | SIEM/central; funciona en managed clusters | Latencia y disponibilidad del receptor afectan el API server (mode `batch` mitiga) |

**Managed clusters (EKS/GKE/AKS):** no tenés acceso al flag `--audit-policy-file`; el provider expone los audit logs vía su servicio (CloudWatch, Cloud Logging, Azure Monitor). El examen espera que sepas que **la política de auditoría es configurable en self-managed pero delegada al provider en managed**.

---

## 3. Manifiestos e infraestructura completos

### 3.1 Política de auditoría del API server (self-managed)

La `Policy` de auditoría define *qué* eventos se registran y a *qué nivel* (`None`, `Metadata`, `Request`, `RequestResponse`). El principio: registrar mucho de lo sensible, poco del ruido de alto volumen.

```yaml
# /etc/kubernetes/audit/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# No registrar el cuerpo de request/response por defecto: PII y volumen.
omitStages:
  - "RequestReceived"
rules:
  # 1. Nunca auditar lecturas de bajo valor y alto volumen (health, endpoints del kubelet).
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"

  # 2. Secrets y ConfigMaps: registrar metadata SIEMPRE, nunca el cuerpo (fuga de credenciales).
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # 3. Cambios de RBAC: máximo detalle. Escalada de privilegios se ve acá.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # 4. Operaciones exec/attach/portforward: acceso interactivo, alto interés forense.
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 5. Mutaciones (create/update/patch/delete) de workloads: nivel Request.
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
      - group: "apps"
      - group: "batch"
      - group: "networking.k8s.io"

  # 6. Todo lo demás: solo metadata.
  - level: Metadata
```

Flags del `kube-apiserver` (en `/etc/kubernetes/manifests/kube-apiserver.yaml` de un cluster kubeadm):

```yaml
    - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30        # días de retención por rotación
    - --audit-log-maxbackup=10     # archivos rotados a conservar
    - --audit-log-maxsize=100      # MB por archivo antes de rotar
    - --audit-log-format=json
```

Y los `volumeMounts`/`volumes` correspondientes (omitirlos es el error #1 al configurar auditoría con kubeadm):

```yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/audit
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
      readOnly: false
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

### 3.2 Kyverno: verificación de firma + atestación de SBOM en admission

Esta es la pieza que une los dos planos: rechaza la imagen si no está firmada por la identidad esperada **y** si no adjunta una atestación SBOM CycloneDX firmada. Usa verificación keyless (sigstore/Fulcio+Rekor).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature-and-sbom
  annotations:
    policies.kyverno.io/title: Verify Image Signature and SBOM Attestation
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce      # Enforce = rechaza; Audit = solo reporta
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  background: false                      # verifyImages no corre en background scans
  rules:
    - name: verify-signature-keyless
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "registry.internal.example.com/prod/*"
          mutateDigest: true            # reemplaza el tag por el digest resuelto (inmutabilidad)
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    # La identidad OIDC que firmó en CI (GitHub Actions OIDC subject).
                    subject: "https://github.com/example-org/*/.github/workflows/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev

    - name: require-sbom-attestation
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "registry.internal.example.com/prod/*"
          attestations:
            - type: https://cyclonedx.org/bom       # predicateType de la atestación
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/example-org/*/.github/workflows/*"
                        issuer: "https://token.actions.githubusercontent.com"
                        rekor:
                          url: https://rekor.sigstore.dev
              conditions:
                - all:
                    # Ejemplo de gate sobre el contenido del SBOM: exigir versión de spec.
                    - key: "{{ specVersion }}"
                      operator: GreaterThanOrEquals
                      value: "1.4"
```

### 3.3 Kyverno: generar audit trail de compliance como PolicyReport

Kyverno emite `PolicyReport`/`ClusterPolicyReport` (estándar abierto del Kubernetes Policy WG). Este es el artefacto que exportás al auditor. Ejemplo de política en modo `Audit` que puebla el reporte sin bloquear:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Audit        # puebla PolicyReport, no rechaza
  background: true                      # evalúa recursos preexistentes en scans periódicos
  rules:
    - name: check-container-limits
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "Todo container debe declarar requests y limits de CPU y memoria."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
```

### 3.4 OPA/Gatekeeper: ConstraintTemplate + Constraint equivalente

Para el que necesita Rego. El `ConstraintTemplate` define la lógica; el `Constraint` la instancia y la asocia a recursos.

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
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedrepos

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.repos[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("container <%v> image <%v> viola la política: repos permitidos %v", [container.name, container.image, input.parameters.repos])
        }
```

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: prod-repos-only
spec:
  enforcementAction: deny        # deny | dryrun | warn
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces: ["prod"]
  parameters:
    repos:
      - "registry.internal.example.com/prod/"
```

### 3.5 sigstore policy-controller: ClusterImagePolicy

La alternativa especializada, solo para supply chain:

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-keyless-signature
spec:
  images:
    - glob: "registry.internal.example.com/prod/**"
  authorities:
    - keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subjectRegExp: "https://github.com/example-org/.*/.github/workflows/.*"
      ctlog:
        url: https://rekor.sigstore.dev
  policy:
    type: cue
    data: |
      // Exigir que exista una atestación SLSA provenance.
      predicateType: "https://slsa.dev/provenance/v1"
```

### 3.6 Trivy Operator: escaneo continuo como CRD auditable

El Trivy Operator escanea workloads en el cluster y emite `VulnerabilityReport` y `ConfigAuditReport` — el audit trail de vulnerabilidades vive como recurso de Kubernetes, consultable por RBAC.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trivy-operator
  namespace: trivy-system
spec:
  replicas: 1
  selector:
    matchLabels: { app: trivy-operator }
  template:
    metadata:
      labels: { app: trivy-operator }
    spec:
      serviceAccountName: trivy-operator
      containers:
        - name: trivy-operator
          image: aquasec/trivy-operator:0.22.0
          env:
            - name: OPERATOR_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
            - name: OPERATOR_TARGET_NAMESPACES
              value: ""                         # "" = todos los namespaces
            - name: OPERATOR_SCANNER_REPORT_TTL
              value: "24h"                      # regenera reportes cada 24h
            - name: OPERATOR_VULNERABILITY_SCANNER_ENABLED
              value: "true"
            - name: OPERATOR_SBOM_GENERATION_ENABLED
              value: "true"                     # emite SbomReport CRD
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { memory: 500Mi }
```

### 3.7 Falco: audit trail de runtime (shift-right)

El admission controller valida el estado deseado; Falco audita lo que *realmente* pasa en runtime. Regla que detecta un `exec` interactivo en un pod de producción — el evento que un atacante genera post-breach:

```yaml
# /etc/falco/rules.d/prod-audit.yaml
- rule: Shell en contenedor de producción
  desc: Detecta shell interactiva lanzada dentro de un pod del namespace prod
  condition: >
    spawned_process
    and container
    and shell_procs
    and k8s.ns.name = "prod"
    and proc.tty != 0
  output: >
    Shell interactiva en pod de prod
    (user=%user.name pod=%k8s.pod.name ns=%k8s.ns.name
     image=%container.image.repository proc=%proc.cmdline)
  priority: WARNING
  tags: [container, shell, compliance, mitre_execution]
  source: syscall
```

---

## 4. Comandos CLI y salidas de terminal reales

### 4.1 Generar SBOM con syft y firmarlo con cosign

```console
$ syft registry.internal.example.com/prod/checkout:1.8.3 -o cyclonedx-json > sbom.cdx.json
 ✔ Parsed image sha256:9f2c...aa71
 ✔ Cataloged contents
   ├── ✔ Packages                        [312 packages]
   ├── ✔ File digests                    [1,204 files]
   └── ✔ Executables                     [88 executables]

$ jq '.metadata.component.name, (.components | length)' sbom.cdx.json
"checkout"
312
```

Atestar el SBOM contra el **digest** (no el tag) y firmar keyless:

```console
$ export COSIGN_EXPERIMENTAL=1
$ IMG=registry.internal.example.com/prod/checkout@sha256:9f2c...aa71

$ cosign attest --yes --type cyclonedx --predicate sbom.cdx.json "$IMG"
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
Successfully verified SCT...
tlog entry created with index: 74839201
Attestation written to registry.

$ cosign sign --yes "$IMG"
tlog entry created with index: 74839202
```

### 4.2 Escanear vulnerabilidades y aplicar un gate en CI

```console
$ grype "$IMG" --fail-on high -o table
 ✔ Vulnerability DB        [updated]
 ✔ Scanned for vulnerabilities     [47 vulnerability matches]
   ├── by severity: 2 critical, 6 high, 21 medium, 18 low
   └── by status:   19 fixed, 28 not-fixed

NAME        INSTALLED   FIXED-IN   TYPE  VULNERABILITY   SEVERITY
libssl3     3.0.11-1    3.0.13-1   deb   CVE-2024-0727   High
zlib1g      1:1.2.13    (won't fix) deb  CVE-2023-45853  Critical
...
1 error occurred:
  * discovered vulnerabilities at or above the severity threshold (high)

$ echo $?
1
```

El `exit 1` es lo que rompe el pipeline — el gate de compliance en CI. `won't fix` es el caso donde entra **VEX**: si el upstream no va a parchear y vos determinás que no es explotable en tu contexto, emitís un statement VEX en vez de un waiver manual sin rastro.

Escaneo del cluster completo (audit trail de postura):

```console
$ trivy k8s --report summary cluster
Summary Report for cluster
Workload Assessment
┌───────────┬─────────────────────┬───────────────────────┬───────────────────┐
│ Namespace │      Resource       │   Vulnerabilities     │  Misconfigs       │
│           │                     │ C   H   M   L         │ C  H  M  L        │
├───────────┼─────────────────────┼───────────────────────┼───────────────────┤
│ prod      │ Deployment/checkout │ 1   6   21  18        │ 0  2  5  3        │
│ prod      │ Deployment/payments │ 0   0   4   9         │ 0  0  3  2        │
│ kube-system│ DaemonSet/kube-proxy│ 0  1   2   0         │ 0  1  2  1        │
└───────────┴─────────────────────┴───────────────────────┴───────────────────┘
```

### 4.3 Verificar firma y atestación antes de confiar

```console
$ cosign verify \
    --certificate-identity-regexp "https://github.com/example-org/.*" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$IMG" | jq '.[0].optional.Subject'
Verification for registry.internal.example.com/prod/checkout@sha256:9f2c...aa71 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority
"https://github.com/example-org/checkout/.github/workflows/release.yml@refs/tags/v1.8.3"

$ cosign verify-attestation --type cyclonedx \
    --certificate-identity-regexp "https://github.com/example-org/.*" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    "$IMG" > /dev/null && echo "SBOM attestation OK"
SBOM attestation OK
```

### 4.4 Testear políticas offline (shift-left, sin cluster)

```console
$ kyverno apply verify-image-signature-and-sbom.yaml --resource bad-pod.yaml
Applying 2 policy rule(s) to 1 resource(s)...

policy verify-image-signature-and-sbom -> resource default/Pod/legacy-app failed:
1. verify-signature-keyless: failed to verify image
   registry.internal.example.com/prod/legacy:latest: no signature found

pass: 0, fail: 1, warn: 0, error: 0, skip: 0
$ echo $?
1
```

Con Gatekeeper, `conftest` corre la misma Rego sobre manifiestos en CI:

```console
$ conftest test deploy.yaml --policy policy/
FAIL - deploy.yaml - main - container <checkout> image <docker.io/library/checkout:latest> viola la política: repos permitidos ["registry.internal.example.com/prod/"]

1 test, 0 passed, 0 warnings, 1 failure
```

### 4.5 Consultar el audit trail del API server

```console
$ tail -n1 /var/log/kubernetes/audit/audit.log | jq '{user: .user.username, verb, resource: .objectRef.resource, name: .objectRef.name, ns: .objectRef.namespace, decision: .annotations["authorization.k8s.io/decision"], time: .requestReceivedTimestamp}'
{
  "user": "alice@example.com",
  "verb": "create",
  "resource": "rolebindings",
  "name": "temp-admin",
  "ns": "prod",
  "decision": "allow",
  "time": "2026-08-07T14:22:09.481723Z"
}
```

Query forense típica — *"¿quién hizo `exec` en pods de prod en las últimas 24h?"*:

```console
$ jq 'select(.objectRef.resource=="pods" and .objectRef.subresource=="exec" and .objectRef.namespace=="prod") | {user: .user.username, pod: .objectRef.name, time: .requestReceivedTimestamp}' /var/log/kubernetes/audit/audit.log
{"user":"bob@example.com","pod":"checkout-7d9f-abc12","time":"2026-08-07T09:14:02Z"}
```

### 4.6 Extraer el policy report de compliance

```console
$ kubectl get policyreport -n prod
NAME                             KIND         NAME       PASS   FAIL   WARN   ERROR   AGE
cpol-require-resource-limits     Deployment   checkout   2      1      0      0       6d
cpol-require-resource-limits     Deployment   payments   3      0      0      0       6d

$ kubectl get clusterpolicyreport -o json | jq '.items[].summary'
{ "pass": 148, "fail": 12, "warn": 0, "error": 0, "skip": 3 }
```

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 El audit log del API server no aparece

**Síntoma:** `/var/log/kubernetes/audit/audit.log` vacío o inexistente tras configurar los flags.

Ladder de diagnóstico:

```console
# 1. ¿El apiserver arrancó con los flags? (un typo en el path del policy file = crash loop)
$ kubectl -n kube-system get pod -l component=kube-apiserver
$ crictl logs $(crictl ps --name kube-apiserver -q) 2>&1 | grep -i audit
E0807 ... failed to read audit policy file: open /etc/kubernetes/audit/audit-policy.yaml: no such file or directory

# 2. Causa raíz #1: falta el volumeMount/hostPath. El pod monta el archivo pero no el dir de salida.
# 3. Causa raíz #2: la Policy no matchea (todo cae en 'level: None').
$ kubectl get --raw /api/v1/namespaces/default/pods >/dev/null   # genera un evento auditable
$ ls -la /var/log/kubernetes/audit/
```

**Regla:** el `kube-apiserver` es un static pod; editar su manifiesto lo reinicia automáticamente. Si queda en CrashLoop, el error casi siempre es YAML de la Policy inválido o path mal montado.

### 5.2 La política de admission no rechaza (o rechaza todo)

```console
# ¿El webhook está registrado y apuntando a un service vivo?
$ kubectl get validatingwebhookconfigurations
$ kubectl get pods -n kyverno

# Modo del policy: si dice Audit, NO rechaza — solo reporta. Cambiar a Enforce.
$ kubectl get clusterpolicy verify-image-signature-and-sbom -o jsonpath='{.spec.validationFailureAction}'
Audit

# Test controlado: aplicar un recurso que DEBE fallar.
$ kubectl run bad --image=docker.io/library/nginx:latest --dry-run=server
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request: ...
```

**Falla catastrófica a evitar — el webhook tumba el cluster:** con `failurePolicy: Fail`, si el pod de Kyverno/Gatekeeper muere, *ningún* recurso puede crearse. Mitigaciones obligatorias en producción:

1. `namespaceSelector` que **excluye** `kube-system` y el propio namespace del policy engine (evita el deadlock donde el engine no puede reiniciarse).
2. `timeoutSeconds` bajo (≤10s) para que un webhook lento no cuelgue el API server.
3. HA del policy engine (≥2 réplicas, PodDisruptionBudget).
4. Decidir conscientemente `Fail` vs `Ignore` por política: firma de imágenes → `Fail` (fail-closed); reglas cosméticas → `Ignore`.

### 5.3 `cosign verify` falla

| Error | Causa | Remedio |
|---|---|---|
| `no signatures found` | Se firmó el tag, se verifica otro digest, o no se firmó | Verificar contra el `@sha256:` exacto; confirmar que CI corrió `cosign sign` |
| `certificate identity ... did not match` | El `subject`/`issuer` esperados no coinciden con quien firmó | Alinear regex de identidad con el OIDC subject real del workflow |
| `error verifying transparency log entry` | Sin conectividad a Rekor, o firma no registrada | Verificar red a `rekor.sigstore.dev`; usar Rekor privado si es airgapped |
| `SCT verification failed` | Reloj del nodo desincronizado | Corregir NTP; los certs de Fulcio son de vida corta (~10 min) |

### 5.4 Drift entre SBOM y la imagen en ejecución

**Síntoma:** el SBOM dice 312 paquetes; el escaneo runtime encuentra uno que no está en el SBOM.

**Causa raíz típica:** el SBOM se generó sobre un tag mutable y la imagen se re-pusheó, o se instaló software en runtime (`apt install` en un `initContainer`, o `pip install` en el entrypoint). **Diagnóstico:** re-generar el SBOM sobre el digest en ejecución y hacer diff:

```console
$ RUNNING=$(kubectl get pod checkout-xyz -o jsonpath='{.status.containerStatuses[0].imageID}')
$ syft "$RUNNING" -o cyclonedx-json | jq -r '.components[].purl' | sort > running.txt
$ jq -r '.components[].purl' sbom.cdx.json | sort > attested.txt
$ diff attested.txt running.txt
```

Un diff no vacío = tu audit trail miente. La regla que lo previene: **atestar contra el digest y hacer `mutateDigest: true` en admission** para que lo que corre sea inmutablemente lo que se atestó.

### 5.5 Checklist de verificación de compliance end-to-end

```console
# 1. Provenance: ¿la imagen tiene firma y atestación SLSA?
$ cosign verify-attestation --type slsaprovenance ... "$IMG" && echo OK
# 2. SBOM: ¿existe y es del digest correcto?
$ cosign verify-attestation --type cyclonedx ... "$IMG" && echo OK
# 3. Vulns: ¿bajo el umbral?
$ grype "$IMG" --fail-on critical && echo OK
# 4. Admission: ¿la política está en Enforce y HA?
$ kubectl get clusterpolicy -o wide
# 5. Runtime: ¿Falco activo y enviando a SIEM?
$ kubectl -n falco get ds falco
# 6. Audit log: ¿el API server audita y se recolecta off-cluster?
$ ls -la /var/log/kubernetes/audit/audit.log
# 7. Policy report: ¿exportable para el auditor?
$ kubectl get clusterpolicyreport -o yaml > compliance-$(date +%F).yaml
```

Cada línea que devuelve `OK` es una casilla de evidencia. La compliance de producción es exactamente esto: cada afirmación respaldada por un comando reproducible, no por memoria.

---

## 6. Referencias

- **CNPE Curriculum (CNCF)** — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **Kubernetes Auditing** — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- **Kubernetes Dynamic Admission Control** — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- **SPDX (ISO/IEC 5962:2021)** — https://spdx.dev/
- **CycloneDX (OWASP)** — https://cyclonedx.org/
- **NTIA Minimum Elements for an SBOM** — https://www.ntia.gov/report/2021/minimum-elements-software-bill-materials-sbom
- **Syft** — https://github.com/anchore/syft
- **Grype** — https://github.com/anchore/grype
- **Trivy** — https://trivy.dev/ · **Trivy Operator** — https://aquasecurity.github.io/trivy-operator/
- **Kyverno** — https://kyverno.io/docs/ · **verifyImages** — https://kyverno.io/docs/writing-policies/verify-images/
- **Kubernetes Policy Reports (Policy WG)** — https://kyverno.io/docs/policy-reports/
- **OPA / Gatekeeper** — https://open-policy-agent.github.io/gatekeeper/website/docs/ · **OPA** — https://www.openpolicyagent.org/
- **Conftest** — https://www.conftest.dev/
- **Sigstore / cosign** — https://docs.sigstore.dev/ · **policy-controller** — https://docs.sigstore.dev/policy-controller/overview/
- **SLSA (Supply-chain Levels for Software Artifacts)** — https://slsa.dev/
- **in-toto** — https://in-toto.io/
- **OpenVEX** — https://github.com/openvex/spec
- **Falco** — https://falco.org/docs/