# 5.6 Reglas VerifyImage

> **Dominio 5 — Autoría de políticas Kyverno · Peso en el examen: 2.91**
> Tipo de regla: `spec.rules[].verifyImages[]` (`kyverno.io/v1`, `ClusterPolicy` / `Policy`)
> Equivalente de próxima generación: `ImageValidatingPolicy` (`policies.kyverno.io/v1alpha1`, Kyverno ≥ 1.14)

---

## 1. El problema en producción: un tag no es una identidad

Todos los demás tipos de regla de Kyverno razonan sobre **texto dentro del AdmissionReview**. `validate` lee `securityContext.runAsNonRoot`. `mutate` escribe una etiqueta. `generate` crea un objeto derivado. Todas son funciones puras del cuerpo del request — deterministas, offline, de sub-milisegundo.

`verifyImages` es el único tipo de regla que sale del clúster para responder su pregunta.

La razón es que una referencia a imagen OCI no es una afirmación de identidad. Considerá lo que realmente afirma una especificación de pod:

```yaml
containers:
  - name: api
    image: ghcr.io/acme/api:1.4.2
```

Esto dice "traé lo que sea que el registry devuelva actualmente para el puntero mutable `1.4.2` en el repositorio `ghcr.io/acme/api`." No dice quién la construyó, a partir de qué código fuente, en qué runner, ni si los bytes cambiaron desde la última vez que tu pipeline de CI los subió. Cuatro fallas concretas de producción se derivan directamente de esa brecha:

| Falla | Mecanismo | Qué puede detectar una regla `validate` |
|---|---|---|
| **Re-push del tag** | Un atacante (o un ingeniero descuidado) con `push` sobre el repo re-apunta `1.4.2` a bytes distintos. Cada nodo que haga pull después de eso ejecuta código nuevo con un manifiesto sin cambios, un commit de GitOps sin cambios, un rastro de auditoría sin cambios. | Nada. El YAML es idéntico byte a byte. |
| **Compromiso del registry / MITM** | El registry mismo, o un mirror de caché pull-through, sirve capas sustituidas. | Nada. |
| **Typosquat / confusión de dependencias** | `ghcr.io/acme/api` vs `ghcr.io/acme-inc/api`. Al ojo de un revisor se le escapa; el manifiesto es sintácticamente perfecto. | Solo mediante una allowlist de registries — que es una verificación de *string*, no de *procedencia*. No puede distinguir "nuestra imagen" de "una imagen que alguien subió a nuestro registry." |
| **Build no atribuible** | La imagen está genuinamente en tu registry, pero nadie puede decir qué commit, qué workflow, qué builder la produjo. | Nada. |

El framework SLSA nombra las primeras tres como amenazas **(D) Compromise package repo**, **(E) Use compromised package** y **(F) Upload modified package** en el modelo de amenazas de la cadena de suministro. La mitigación que SLSA prescribe es la misma en todos los casos: vincular el *digest* del artefacto a una afirmación criptográfica producida por una identidad confiable, y verificar ese vínculo en el momento del consumo.

Para Kubernetes, "el momento del consumo" es el control de admisión. Eso es lo que implementa `verifyImages`.

### 1.1 Por qué el control de admisión es el punto de aplicación correcto (y dónde es débil)

| Punto de aplicación | Cubre | No cubre | Costo operativo |
|---|---|---|---|
| Gate de CI (verificar antes de `kubectl apply`) | Imágenes que fluyen por tu pipeline | Cualquier cosa aplicada por fuera del canal, pods generados por operators, `kubectl run`, inyección de sidecars por otros webhooks | Gratis — pero se evade trivialmente |
| **Kyverno `verifyImages` (admisión)** | Cada `CREATE`/`UPDATE` de un recurso que contiene pods en el clúster, incluidos containers creados por operators e inyectados por webhooks | Pods que ya estaban corriendo antes de que existiera la política; imágenes traídas por los nodos fuera del API server (static pods, `crictl pull`) | Uno o más viajes de ida y vuelta al registry por admisión; una dependencia dura de la disponibilidad del registry |
| Runtime de containers / nivel de nodo (ej. plugins de verificación de imágenes de containerd) | El pull real, incluidos static pods | Sin contexto de política, sin alcance por namespace, deriva de configuración por nodo | Gestión del ciclo de vida del nodo |
| Detección en runtime (Falco, Tetragon) | Detecta, no previene | — | Fatiga de alertas |

`verifyImages` se ubica en el punto de mayor apalancamiento que sigue siendo gestionado centralmente y guiado por políticas. Sus dos debilidades estructurales — **pods preexistentes** y **el registry como dependencia dura** — impulsan la mayoría de las decisiones de diseño en el resto de este tema.

---

## 2. Arquitectura: dónde se ejecuta realmente una regla verifyImages

Este es el mecanismo peor entendido de este dominio, y es examinable.

**Una regla `verifyImages` no es una regla de validación. Se ejecuta en la fase de admisión de mutación.**

La razón es estructural: la acción principal de endurecimiento de la verificación de imágenes es *reescribir el tag mutable al digest inmutable que efectivamente fue verificado*. Eso es un JSONPatch, y los JSONPatch solo son legales desde un `MutatingWebhookConfiguration`. Kyverno por lo tanto registra las rutas de verificación de imágenes en el webhook **de mutación** de recursos, no en el de validación.

```
$ kubectl get mutatingwebhookconfigurations
NAME                                   WEBHOOKS   AGE
kyverno-policy-mutating-webhook-cfg    1          31d
kyverno-resource-mutating-webhook-cfg  2          31d
kyverno-verify-mutating-webhook-cfg    1          31d

$ kubectl get mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg \
    -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.clientConfig.service.path}{"\t"}{.failurePolicy}{"\t"}{.timeoutSeconds}{"\n"}{end}'
mutate.kyverno.svc-fail      /mutate/fail          Fail     10
mutate.kyverno.svc-ignore    /mutate/ignore        Ignore   10
```

> `kyverno-verify-mutating-webhook-cfg` no tiene relación con la verificación de imágenes — es la sonda de auto-liveness de Kyverno, apuntando a su propio Deployment para confirmar que el API server puede alcanzar el servicio del webhook. No confundas los dos nombres; este es un distractor clásico.

El flujo de request de punta a punta para un request `CREATE pods` contra un clúster con una política `verifyImages`:

```
kubectl apply
      │
      ▼
API server ── AdmissionReview(CREATE, v1/Pod) ──► kyverno-resource-mutating-webhook-cfg
                                                        │
                                                        ▼
                                            Kyverno admission controller
                                                        │
                                          ┌─────────────┴──────────────┐
                                          │ 1. match/exclude evaluation │
                                          │ 2. extract image list       │
                                          │    (initContainers,         │
                                          │     containers,             │
                                          │     ephemeralContainers)    │
                                          │ 3. normalize references     │
                                          │    nginx:1.27 →             │
                                          │    docker.io/library/...    │
                                          │ 4. imageReferences glob     │
                                          │ 5. cache lookup             │
                                          └─────────────┬──────────────┘
                                                        │ MISS
                                                        ▼
                                        ┌───────────────────────────────┐
                                        │  OUTBOUND NETWORK             │
                                        │  • registry: HEAD manifest    │
                                        │    → resolve tag to digest    │
                                        │  • registry: GET signature    │
                                        │    tag  sha256-<hex>.sig      │
                                        │    (or OCI referrers API)     │
                                        │  • Fulcio/Rekor (keyless)     │
                                        └───────────────┬───────────────┘
                                                        │
                          ┌─────────────────────────────┴──────────────┐
                          │ verified                       not verified │
                          ▼                                             ▼
        JSONPatch response:                            AdmissionResponse
        • image → @sha256:<digest>  (mutateDigest)     allowed=false  (Enforce)
        • + annotation                                 allowed=true + warning (Audit)
          kyverno.io/verify-images                     + PolicyViolation event
                          │                            + PolicyReport entry
                          ▼
          API server persists mutated object
                          │
                          ▼
        kyverno-resource-validating-webhook-cfg  (validate rules run here, on the
                                                  already-digest-pinned spec)
```

Tres consecuencias que vale la pena internalizar:

1. **Orden.** Como la verificación corre en la fase de mutación, las reglas `validate` ven la especificación *post-mutación*. Una regla como "las imágenes deben referenciarse por digest" va a pasar sobre un pod referenciado por tag si una regla `verifyImages` con `mutateDigest: true` se disparó primero. Eso normalmente es lo que querés, pero significa que las dos reglas no son independientes.
2. **La latencia del registry está dentro de la ruta crítica del API server.** Un registry lento o inalcanzable se convierte en latencia de admisión, y — con `failurePolicy: Fail` — en una incapacidad de crear pods a nivel de todo el clúster.
3. **Los escaneos en segundo plano no re-verifican firmas.** El controlador de reportes de Kyverno no tiene AdmissionReview y, por diseño, no realiza I/O contra el registry para verificación de imágenes durante los escaneos periódicos. Un `PolicyReport` limpio prueba entonces "ninguna admisión fue rechazada", no "toda imagen en ejecución sigue firmada". Verificá esto en tu propio clúster en lugar de confiar en la afirmación:

```
$ kubectl get clusterpolicyreport -o json \
  | jq -r '.items[].results[] | select(.rule|test("verify")) | "\(.policy)/\(.rule)\t\(.result)"' \
  | sort -u
```

Si necesitás aseguramiento continuo para cargas de trabajo que ya están corriendo, eso es un control aparte (un `CronJob` que vuelva a correr `cosign verify` sobre `kubectl get pods -o jsonpath='{..image}'`, o un agente de atestación en runtime), no algo que `verifyImages` te dé.

---

## 3. La API de la regla, campo por campo

Acá hay una política completa y sintácticamente válida que ejercita la mayoría de la superficie. Cada campo se explica después.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-acme-images
  annotations:
    policies.kyverno.io/title: Verify ACME container image signatures
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    # Restrict autogen so we do not silently create rules for controllers we
    # have not tested. Remove the annotation to get the full default set.
    pod-policies.kyverno.io/autogen-controllers: Deployment,StatefulSet,DaemonSet,Job,CronJob
spec:
  # Enforce is what makes this a control rather than a dashboard.
  validationFailureAction: Enforce
  validationFailureActionOverrides:
    - action: Audit
      namespaces:
        - kube-system
        - sandbox-*
  # Image verification requires registry I/O and cannot run in background scans.
  background: false
  webhookConfiguration:
    timeoutSeconds: 30
  # Fail closed. See §7 for the availability trade-off this creates.
  failurePolicy: Fail
  rules:
    - name: verify-cosign-keyless
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kyverno
      verifyImages:
        - type: Cosign
          imageReferences:
            - "ghcr.io/acme/*"
          skipImageReferences:
            - "ghcr.io/acme/legacy-*"
          # Rewrite the verified tag to its digest in the admitted object.
          mutateDigest: true
          # Do NOT require the submitter to already use a digest; mutateDigest
          # will supply it. Set true only once every producer emits digests.
          verifyDigest: false
          # If no attestor set matches, fail. false would allow unmatched images.
          required: true
          useCache: true
          attestors:
            # Attestor SETS are ANDed. Both of the sets below must pass.
            - count: 1                      # within this set: 1-of-2 (OR)
              entries:
                - keyless:
                    subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false
                - keyless:
                    subject: "https://github.com/acme/worker/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
                      ignoreTlog: false
                    ctlog:
                      ignoreSCT: false
            - entries:                       # no count → ALL entries required
                - keys:
                    secret:
                      name: acme-release-pubkey
                      namespace: kyverno
                    signatureAlgorithm: sha256
          attestations:
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ buildDefinition.buildType }}"
                      operator: Equals
                      value: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
                    - key: "{{ regex_match('^https://github.com/acme/', buildDefinition.externalParameters.workflow.repository) }}"
                      operator: Equals
                      value: true
          imageRegistryCredentials:
            allowInsecureRegistry: false
            providers:
              - github
            secrets:
              - acme-ghcr-pull
```

### 3.1 Referencia de campos

| Campo | Tipo | Valor por defecto | Comportamiento y modo de falla si está mal |
|---|---|---|---|
| `type` | `Cosign` \| `Notary` | `Cosign` | Selecciona la implementación de verificación. `Notary` usa la **API de referrers** de OCI y cadenas de confianza X.509 en lugar de Sigstore. Mezclar una imagen firmada con Notary con una regla Cosign produce `no signatures found`. |
| `imageReferences` | `[]string` (glob) | — (requerido) | Se compara contra la referencia **normalizada**. `*` matchea cualquier secuencia de caracteres *incluyendo* `/`. Anclá deliberadamente: `"ghcr.io/acme/*"` matchea `ghcr.io/acme/team/api`. |
| `skipImageReferences` | `[]string` (glob) | `[]` | Se evalúa después de `imageReferences`; un match cortocircuita la regla para esa imagen. La forma limpia de tallar una excepción de migración sin una segunda política. |
| `mutateDigest` | bool | `true` | Reescribe `repo:tag` → `repo:tag@sha256:…` en el objeto admitido. **Este es el campo que hace que la verificación tenga sentido** — sin él verificás un conjunto de bytes y el kubelet puede traer otro. |
| `verifyDigest` | bool | `true` | Rechaza referencias que no estén ya fijadas por digest. Combinado con `mutateDigest: true` es en gran medida redundante; usalo solo para *forzar a los productores* a emitir digests. |
| `required` | bool | `true` | Si es `true`, una imagen que matchea `imageReferences` y que ningún conjunto de attestors satisface es una violación. Si es `false`, las imágenes sin match pasan — un modo "verificar si está firmada" que no ofrece casi ninguna garantía. |
| `useCache` | bool | `true` | Permite excluir esta regla del caché de verificación de imágenes. Poné `false` para reglas cuyo resultado deba reflejar la revocación de inmediato. |
| `attestors` | `[]AttestorSet` | — | Los conjuntos se combinan con **AND**. Ver §4. |
| `attestations` | `[]Attestation` | `[]` | Verificación de atestaciones in-toto más condiciones JMESPath sobre el predicado. Ver §5. |
| `imageRegistryCredentials` | object | hereda los flags del controlador | Autenticación de registry por regla. Sobrescribe los `--imagePullSecrets` / credential helpers de alcance global del controlador. |
| `repository` | string (dentro de la entrada de attestor) | — | Equivalente de `COSIGN_REPOSITORY`: las firmas viven en un repositorio distinto al de la imagen. Común en topologías de mirror de solo lectura. |

### 3.2 El álgebra de attestors — el detalle de examen de mayor rendimiento

```
attestors:                       ── list of AttestorSet ── ALL must pass  (AND)
  - count: <n>                   ── within one set: n of len(entries) must pass
    entries:                     ── if count omitted → ALL entries          (AND)
      - keys:    {...}
      - keyless: {...}
      - certificates: {...}
      - attestor: {...}          ── nested set, enables arbitrary boolean trees
```

| Intención | Codificación |
|---|---|
| Firmada por la clave A **o** la clave B | un conjunto, `count: 1`, dos entradas |
| Firmada por la clave A **y** la clave B (control dual) | un conjunto, sin `count`, dos entradas |
| Firmada por el sistema de build **y** por (QA **o** Seguridad) | dos conjuntos: conjunto 1 = clave del builder; conjunto 2 = `count: 1` con entradas de QA y Seguridad |
| Cualquiera 2 de 3 ingenieros de release | un conjunto, `count: 2`, tres entradas |

La forma de control dual es cómo se ve la "integridad de dos personas" en Kyverno, y es la razón por la que los *conjuntos* de attestors existen como un nivel de anidamiento separado de las *entradas*.

---

## 4. Tipos de attestor comparados

| | Cosign — keys | Cosign — keyless | Cosign — certificates | Notary (`type: Notary`) |
|---|---|---|---|---|
| Ancla de confianza | Clave pública de larga vida que vos distribuís | CA raíz de Fulcio + identidad OIDC (`subject` + `issuer`) | Tu propio certificado / cadena X.509 | Tu propio trust store X.509 |
| Dónde vive la firma | Tag OCI `sha256-<hex>.sig` | igual | igual | **referrers** OCI (manifiesto de artefacto) |
| Carga de gestión de claves | Alta — la rotación, la custodia y la revocación son tuyas | Ninguna — los certificados son efímeros de 10 minutos | Alta | Alta |
| Log de transparencia | Opcional (`rekor`) | Efectivamente obligatorio (Rekor + CT log) | Opcional | No |
| Requiere salida a internet en la admisión | Solo registry | Registry **+ Rekor + refresco de la raíz de Fulcio (TUF)** | Solo registry | Solo registry |
| Compatibilidad con air-gap | Buena | Pobre a menos que corras Fulcio/Rekor privados | Buena | **La mejor** |
| Historia de revocación | Rotar la clave, re-firmar todo | Certificados de vida corta; la identidad puede des-autorizarse en la política al instante | CRL/OCSP (no consultados por Kyverno) | CRL/OCSP (no consultados por Kyverno) |
| Vincula al firmante con un *repo de código fuente* | No — una clave no dice nada sobre procedencia | **Sí** — `subject` es la ref del workflow | No | No |
| Campo de Kyverno | `keys.publicKeys` / `keys.secret` / `keys.kms` | `keyless.{subject,issuer,roots,rekor,ctlog}` | `certificates.{cert,certChain}` | `certificates.{cert,certChain}` |

**Recomendación arquitectónica.** Para imágenes construidas por CI en un clúster conectado, keyless es estrictamente mejor: elimina por completo el problema de custodia de claves y, de manera única, la afirmación de verificación pasa a ser *"construida por el workflow X en el repositorio Y en el tag Z"* en lugar de *"alguien que posee una clave aprobó esto."* Para entornos air-gapped o regulados donde la salida hacia `rekor.sigstore.dev` no está permitida, o bien corré un stack Sigstore privado (§8) o usá Notary, cuyo modelo de confianza completo es X.509 offline.

### 4.1 Keyless: el campo `subject` es todo el control

```yaml
- keyless:
    subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
    issuer: "https://token.actions.githubusercontent.com"
```

Las dos configuraciones erróneas más comunes, y ambas producen una política que *pasa sus pruebas* y *no provee seguridad*:

| Antipatrón | Por qué es fatal |
|---|---|
| `subject: "*"` | Cualquier identidad en el mundo que pueda obtener un certificado de Fulcio — es decir, cualquiera con una cuenta de GitHub — satisface la política. |
| `subject: "https://github.com/acme/*"` con `issuer: token.actions.githubusercontent.com` | Cualquier workflow en *cualquier* rama de *cualquier* repo de ACME puede firmar. Un colaborador que pueda pushear un workflow a una rama feature de un repo no relacionado ahora puede firmar imágenes de producción. Siempre fijá la **ruta** del workflow y restringí la ref (`@refs/tags/*` o `@refs/heads/main`). |

### 4.2 Claves desde un Secret (doble uso con `cosign generate-key-pair k8s://`)

```yaml
- keys:
    secret:
      name: acme-release-pubkey
      namespace: kyverno
    signatureAlgorithm: sha256
```

El Secret debe contener una clave `cosign.pub`. `cosign generate-key-pair k8s://<ns>/<name>` crea exactamente esta forma (`cosign.key`, `cosign.password`, `cosign.pub`) — pero notá que esto pone la clave **privada** en el clúster desde el que Kyverno lee. En producción, generá el par en tu KMS o en tu almacén de secretos de CI y creá un Secret en el namespace de Kyverno que contenga únicamente `cosign.pub`.

O referenciá el KMS directamente y evitá el Secret por completo:

```yaml
- keys:
    kms: "awskms:///arn:aws:kms:eu-west-1:111122223333:key/1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
```

---

## 5. Atestaciones: verificar *lo que dijo el build*, no solo *quién firmó*

Una firma prueba que una identidad aprobó un digest. Una **atestación** es un Statement in-toto firmado que lleva un *predicado* estructurado — procedencia SLSA, un SBOM, un resultado de escaneo, una aprobación manual. `verifyImages.attestations` te permite verificar la firma de la atestación **y** afirmar condiciones JMESPath sobre el contenido del predicado.

```yaml
attestations:
  - type: https://slsa.dev/provenance/v1        # the in-toto predicateType
    attestors:
      - count: 1
        entries:
          - keyless:
              subject: "https://github.com/acme/*/.github/workflows/release.yaml@refs/tags/*"
              issuer: "https://token.actions.githubusercontent.com"
    conditions:
      - all:
          - key: "{{ buildDefinition.buildType }}"
            operator: Equals
            value: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
          - key: "{{ runDetails.builder.id }}"
            operator: Equals
            value: "https://github.com/actions/runner/github-hosted"

  - type: https://cyclonedx.org/bom
    attestors:
      - entries:
          - keys:
              secret:
                name: acme-sbom-pubkey
                namespace: kyverno
    conditions:
      - all:
          # No component may carry a known-banned licence.
          - key: "{{ components[?licenses[?license.id=='AGPL-3.0'] ] | length(@) }}"
            operator: Equals
            value: 0

  - type: https://acme.io/attestations/vulnscan/v1
    attestors:
      - entries:
          - keys:
              secret:
                name: acme-scanner-pubkey
                namespace: kyverno
    conditions:
      - all:
          - key: "{{ scanner.result.critical }}"
            operator: LessThanOrEquals
            value: 0
          - key: "{{ time_since('', '{{ scanner.timestamp }}', '') }}"
            operator: LessThanOrEquals
            value: "168h"                       # scan must be < 7 days old
```

**La raíz de JMESPath es el predicado, no el Statement.** Dentro de `conditions[].key`, `{{ buildDefinition.buildType }}` resuelve contra `.predicate.buildDefinition.buildType` del Statement in-toto. Escribir `{{ predicate.buildDefinition.buildType }}` es el error de autoría más común acá y produce un `null` silencioso, que luego falla una comparación `Equals` con un mensaje confuso.

El ejemplo de escaneo de vulnerabilidades de arriba es el patrón que vale la pena recordar arquitectónicamente: convierte una *verificación puntual de CI* en un *invariante de admisión aplicado continuamente con un límite de frescura*. Una atestación de escaneo vieja deja de admitir la imagen después de siete días, lo que obliga al pipeline a seguir re-atestando — exactamente la propiedad que querés y exactamente la propiedad que un gate solo-CI no puede darte.

`type` vs `predicateType`: Kyverno ≥ 1.10 usa `attestations[].type`. Material más viejo y políticas más viejas usan `predicateType`. Confirmalo contra tu clúster:

```
$ kubectl explain clusterpolicy.spec.rules.verifyImages.attestations --recursive | head -40
```

---

## 6. Ejemplo completo de punta a punta

### 6.1 Construir y firmar en GitHub Actions (keyless)

```yaml
# .github/workflows/release.yaml
name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: read
  packages: write
  id-token: write          # REQUIRED: mints the OIDC token Fulcio exchanges for a cert

jobs:
  build:
    runs-on: ubuntu-24.04
    outputs:
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@v4

      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: 'v2.4.1'

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/acme/api:${{ github.ref_name }}
          provenance: false          # we attach SLSA ourselves, below

      # Sign the DIGEST, never the tag. Signing a tag signs whatever the tag
      # points at right now and creates a race with any concurrent push.
      - name: Sign image
        run: |
          cosign sign --yes \
            ghcr.io/acme/api@${{ steps.push.outputs.digest }}

      - name: Attach SBOM attestation
        run: |
          syft ghcr.io/acme/api@${{ steps.push.outputs.digest }} \
            -o cyclonedx-json > sbom.cdx.json
          cosign attest --yes \
            --predicate sbom.cdx.json \
            --type https://cyclonedx.org/bom \
            ghcr.io/acme/api@${{ steps.push.outputs.digest }}

  provenance:
    needs: [build]
    permissions:
      actions: read
      id-token: write
      packages: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.0.0
    with:
      image: ghcr.io/acme/api
      digest: ${{ needs.build.outputs.digest }}
```

Verificación local antes de que siquiera escribas la política — siempre probá primero con `cosign` que la firma existe, porque una falla de Kyverno no puede distinguir "la política está mal" de "la imagen no está firmada":

```
$ export IMG=ghcr.io/acme/api@sha256:9f2b1e0a7c4d5e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f

$ cosign verify \
    --certificate-identity-regexp 'https://github.com/acme/api/\.github/workflows/release\.yaml@refs/tags/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    $IMG | jq -r '.[0].optional.Subject'

Verification for ghcr.io/acme/api@sha256:9f2b1e0a... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates

https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/v1.4.2
```

```
$ cosign tree $IMG
📦 Supply Chain Security Related artifacts for an image: ghcr.io/acme/api@sha256:9f2b1e0a...
└── 💾 Attestations for an image tag: ghcr.io/acme/api:sha256-9f2b1e0a....att
   ├── 🍒 sha256:1c4a...
   └── 🍒 sha256:8e11...
└── 🔐 Signatures for an image tag: ghcr.io/acme/api:sha256-9f2b1e0a....sig
   └── 🍒 sha256:44db...
```

### 6.2 La política

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-acme-api
spec:
  validationFailureAction: Enforce
  background: false
  failurePolicy: Fail
  webhookConfiguration:
    timeoutSeconds: 30
  rules:
    - name: verify-signature-and-sbom
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: ["prod", "staging"]
      verifyImages:
        - type: Cosign
          imageReferences:
            - "ghcr.io/acme/api*"
          mutateDigest: true
          verifyDigest: false
          required: true
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
          attestations:
            - type: https://cyclonedx.org/bom
              attestors:
                - entries:
                    - keyless:
                        subject: "https://github.com/acme/api/.github/workflows/release.yaml@refs/tags/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ components[?licenses[?license.id=='AGPL-3.0'] ] | length(@) }}"
                      operator: Equals
                      value: 0
```

### 6.3 La admisión, observada

**Imagen firmada — admitida y mutada:**

```
$ kubectl -n prod run api --image=ghcr.io/acme/api:v1.4.2 --restart=Never
pod/api created

$ kubectl -n prod get pod api -o jsonpath='{.spec.containers[0].image}{"\n"}'
ghcr.io/acme/api:v1.4.2@sha256:9f2b1e0a7c4d5e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f

$ kubectl -n prod get pod api -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}{"\n"}'
{"ghcr.io/acme/api:v1.4.2":true}
```

Fijate en ambos efectos. La imagen ahora está fijada por digest — el kubelet va a traer exactamente los bytes que Kyverno verificó, y un re-push posterior de `v1.4.2` no puede cambiar lo que este pod ejecuta. La anotación `kyverno.io/verify-images` registra la decisión de verificación en el objeto mismo.

**Imagen sin firmar — rechazada:**

```
$ kubectl -n prod run rogue --image=ghcr.io/acme/api:dev-local --restart=Never
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/rogue was blocked due to the following policies

verify-acme-api:
  verify-signature-and-sbom: 'failed to verify image ghcr.io/acme/api:dev-local:
    .attestors[0].entries[0].keyless: no signatures found'
```

**Firmada pero por el firmante equivocado — rechazada con un mensaje distinto:**

```
$ kubectl -n prod run wrong --image=ghcr.io/acme/api:v1.4.2-hotfix --restart=Never
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/wrong was blocked due to the following policies

verify-acme-api:
  verify-signature-and-sbom: 'failed to verify image ghcr.io/acme/api:v1.4.2-hotfix:
    .attestors[0].entries[0].keyless: no matching signatures: none of the expected
    identities matched what was in the certificate, got subjects
    [https://github.com/acme/api/.github/workflows/nightly.yaml@refs/heads/main]'
```

`no signatures found` (no hay nada ahí) versus `no matching signatures` (hay algo ahí, identidad equivocada) es la división de triaje más rápida que tenés. Memorizala.

**Condición de predicado que falla:**

```
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod/api was blocked due to the following policies

verify-acme-api:
  verify-signature-and-sbom: 'attestation checks failed for
    ghcr.io/acme/api:v1.4.2 and predicate https://cyclonedx.org/bom'
```

### 6.4 Probar offline con la CLI de Kyverno

La CLI hace llamadas *reales* al registry, pero solo cuando se lo permite explícitamente con `--registry`. Sin ese flag la verificación de imágenes se omite y tu prueba pasa de forma vacua.

```
$ kyverno apply verify-acme-api.yaml --resource pod-signed.yaml --registry --policy-report

Applying 1 policy rule(s) to 1 resource(s)...

apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: merged
results:
- message: image verified
  policy: verify-acme-api
  resources:
  - apiVersion: v1
    kind: Pod
    name: api
    namespace: prod
  result: pass
  rule: verify-signature-and-sbom
  scored: true
summary:
  error: 0
  fail: 0
  pass: 1
  skip: 0
  warn: 0
```

```
$ kyverno apply verify-acme-api.yaml --resource pod-unsigned.yaml --registry
pass: 0, fail: 1, warn: 0, error: 0, skip: 0
```

---

## 7. Operarlo: latencia, caché y el compromiso de disponibilidad

Cada fallo de caché cuesta como mínimo un `HEAD` de manifiesto al registry, un `GET` de la capa de firma y — para keyless — tráfico hacia Rekor y Fulcio. Medido contra un registry público a través de una WAN esto es rutinariamente de 300–900 ms, y cae de lleno dentro del timeout de admisión del API server.

### 7.1 El caché de verificación de imágenes

```yaml
# Helm values.yaml
features:
  imageVerifyCache:
    enabled: true
    maxSize: 1000          # entries
    ttl: 60m
  registryClient:
    allowInsecure: false
    credentialHelpers:
      - default
      - google
      - amazon
      - azure
      - github
```

Flags equivalentes del controlador, si no estás usando el chart:

```
--imageVerifyCacheEnabled=true
--imageVerifyCacheMaxSize=1000
--imageVerifyCacheTTLDuration=60m
--registryCredentialHelpers=default,google,amazon,azure,github
--allowInsecureRegistry=false
--imagePullSecrets=acme-ghcr-pull
```

La clave del caché incluye el digest resuelto y la identidad de la política/regla, así que una edición de la política invalida sus propias entradas. El compromiso:

| `ttl` | Latencia de admisión (estado estable) | Retraso de revocación | Carga sobre el registry |
|---|---|---|---|
| `0` (deshabilitado) | Viaje completo de ida y vuelta en cada creación de pod — catastrófico durante un rollout grande o un drenaje de nodo | Ninguno | 1 viaje de ida y vuelta × cada container × cada pod | 
| `15m` | Casi cero para imágenes repetidas | Hasta 15 min | Baja |
| `60m` (recomendado) | Casi cero | Hasta 60 min | Muy baja |
| `24h` | Casi cero | Un día entero admitiendo una imagen revocada | Insignificante |

Como cosign/keyless de todos modos no tiene verificación de revocación en línea, la columna de "retraso de revocación" mide sobre todo *cuánto tarda en morder una edición de política*, y por eso 60 minutos es un valor por defecto defendible. Poné `useCache: false` en las reglas individuales donde eso sea inaceptable.

### 7.2 `failurePolicy` — la decisión que te va a despertar

| | `failurePolicy: Fail` | `failurePolicy: Ignore` |
|---|---|---|
| Registry inalcanzable | **Todas las creaciones de pods que matcheen son rechazadas en todo el clúster.** Los rollouts se atascan; una falla de nodo concurrente no puede reprogramar pods. | Los pods se admiten sin verificar. Pérdida silenciosa del control. |
| Pods de Kyverno caídos | Igual — corte total de creación de pods en los namespaces matcheados | Igual — bypass silencioso |
| Postura de seguridad | Sólida: lo no verificado nunca corre | No sólida: un atacante que pueda hacer DoS a tu registry o a Kyverno derrota el control |
| Adecuado para | Producción, con las mitigaciones de abajo | Rollout inicial, fase `Audit` |

Si corrés `Fail` — y para un control de cadena de suministro deberías — las mitigaciones no son negociables:

1. **Excluí el namespace propio de Kyverno y `kube-system`** del `match`, o Kyverno no puede reiniciarse a sí mismo y construiste un deadlock.
2. **Acotá el `match` estrechamente.** Matcheá `namespaces: [prod, staging]`, no todo el clúster.
3. **Corré ≥ 3 réplicas del admission controller** con un `PodDisruptionBudget` y anti-afinidad.
4. **Usá un registry que esté en tu dominio de fallas** — un caché pull-through o un mirror dentro de la región del clúster — para que la disponibilidad del registry no sea una dependencia de terceros de tu plano de control.
5. **Poné `webhookConfiguration.timeoutSeconds` por encima de tu latencia de verificación p99**, no en el default de 10 s. Un timeout con `Fail` es indistinguible de una violación de política para la persona que está haciendo el deploy.

### 7.3 Métricas sobre las que alertar

```
$ kubectl -n kyverno port-forward svc/kyverno-svc-metrics 8000:8000 &
$ curl -s localhost:8000/metrics | grep -E 'rule_type="ImageVerify"' | head

kyverno_policy_results_total{policy_name="verify-acme-api",policy_type="cluster",rule_execution_cause="admission_request",rule_name="verify-signature-and-sbom",rule_result="pass",rule_type="ImageVerify"} 1842
kyverno_policy_results_total{policy_name="verify-acme-api",policy_type="cluster",rule_execution_cause="admission_request",rule_name="verify-signature-and-sbom",rule_result="fail",rule_type="ImageVerify"} 6
kyverno_policy_execution_duration_seconds_sum{policy_name="verify-acme-api",rule_type="ImageVerify"} 741.22
kyverno_policy_execution_duration_seconds_count{policy_name="verify-acme-api",rule_type="ImageVerify"} 1848
```

Tres alertas que vale la pena tener:

```yaml
groups:
  - name: kyverno-image-verification
    rules:
      - alert: KyvernoImageVerifyFailures
        expr: increase(kyverno_policy_results_total{rule_type="ImageVerify",rule_result="fail"}[15m]) > 0
        labels: {severity: warning}
        annotations:
          summary: "Unsigned or mis-signed image rejected by {{ $labels.policy_name }}"

      - alert: KyvernoImageVerifyErrors
        # 'error' means Kyverno could not reach the registry/Rekor — an
        # availability problem, not a policy violation. Page on this.
        expr: increase(kyverno_policy_results_total{rule_type="ImageVerify",rule_result="error"}[10m]) > 3
        labels: {severity: critical}

      - alert: KyvernoImageVerifySlow
        expr: |
          rate(kyverno_policy_execution_duration_seconds_sum{rule_type="ImageVerify"}[10m])
          / rate(kyverno_policy_execution_duration_seconds_count{rule_type="ImageVerify"}[10m]) > 2
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Image verification averaging >2s; approaching webhook timeout"
```

Distinguir `rule_result="fail"` (la política funcionando como fue diseñada) de `rule_result="error"` (Kyverno no pudo hacer su trabajo) es la diferencia entre un ticket y una llamada de guardia.

---

## 8. Registries privados, air-gap y Sigstore privado

### 8.1 Credenciales de registry

El admission controller de Kyverno trae las capas de firma **él mismo**; no usa las credenciales del nodo ni los `imagePullSecrets` del pod. Esta es la causa número uno de "funciona con `docker pull`, falla en Kyverno."

Tres capas, gana la más específica:

```yaml
# 1. Cluster-wide, via controller flag / Helm
#    Secrets must exist in the Kyverno namespace.
admissionController:
  container:
    extraArgs:
      imagePullSecrets: "acme-ghcr-pull,acme-ecr-pull"

# 2. Cloud credential helpers — uses the controller's workload identity /
#    IRSA / managed identity. No secrets to rotate.
features:
  registryClient:
    credentialHelpers: [default, amazon, azure, google, github]
```

```yaml
# 3. Per-rule, inside verifyImages
        imageRegistryCredentials:
          allowInsecureRegistry: false
          providers: [amazon]
          secrets:
            - acme-ecr-pull            # must live in the Kyverno namespace
```

Crear el secret, y la verificación que prueba que Kyverno realmente puede usarlo:

```
$ kubectl -n kyverno create secret docker-registry acme-ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username=acme-bot \
    --docker-password="$GH_PAT"
secret/acme-ghcr-pull created

$ kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
deployment.apps/kyverno-admission-controller restarted

# Prove reachability from inside the controller's network namespace
$ kubectl -n kyverno debug -it deploy/kyverno-admission-controller \
    --image=cgr.dev/chainguard/crane:latest --target=kyverno -- \
    crane manifest ghcr.io/acme/api:v1.4.2 | jq -r '.config.digest'
sha256:3d4b8c9e...
```

### 8.2 Sigstore privado (keyless air-gapped)

Keyless en un clúster air-gapped requiere tu propio Fulcio, Rekor y raíz TUF. Kyverno los consume mediante configuración TUF a nivel del chart más overrides por attestor:

```yaml
features:
  tuf:
    enabled: true
    mirror: https://tuf.acme.internal
    root: /etc/kyverno/tuf/root.json     # mounted via extraVolumes
```

```yaml
          attestors:
            - entries:
                - keyless:
                    subject: "https://gitlab.acme.internal/platform/api//.gitlab-ci.yml@refs/tags/*"
                    issuer: "https://gitlab.acme.internal"
                    roots: |-
                      -----BEGIN CERTIFICATE-----
                      MIIB9zCCAX2gAwIBAgIUALxxxxxxxxxxxxxxxxxxxxxxxxxxwCgYIKoZIzj0EAwMw
                      ... your private Fulcio root ...
                      -----END CERTIFICATE-----
                    rekor:
                      url: https://rekor.acme.internal
                      pubkey: |-
                        -----BEGIN PUBLIC KEY-----
                        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                        -----END PUBLIC KEY-----
                    ctlog:
                      ignoreSCT: true      # no CT log in this deployment
```

Si correr Sigstore privado está fuera de alcance, las alternativas honestas son **Cosign con claves** (`keys.kms`, respaldado por tu HSM) o **Notary**, ambas completamente offline.

### 8.3 Notary

```yaml
      verifyImages:
        - type: Notary
          imageReferences:
            - "registry.acme.internal/*"
          mutateDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - certificates:
                    cert: |-
                      -----BEGIN CERTIFICATE-----
                      MIIDTTCCAjWgAwIBAgIJALXXXXXXXXXXXXXXMA0GCSqGSIb3DQEBCwUAMEwxCzAJ
                      ... ACME internal signing CA ...
                      -----END CERTIFICATE-----
                    certChain: |-
                      -----BEGIN CERTIFICATE-----
                      ... intermediate ...
                      -----END CERTIFICATE-----
                      -----BEGIN CERTIFICATE-----
                      ... root ...
                      -----END CERTIFICATE-----
```

```
$ notation cert generate-test --default "acme.internal"
$ notation sign registry.acme.internal/api@sha256:9f2b1e0a...
Successfully signed registry.acme.internal/api@sha256:9f2b1e0a...

$ notation verify registry.acme.internal/api@sha256:9f2b1e0a...
Successfully verified signature for registry.acme.internal/api@sha256:9f2b1e0a...
```

Notary requiere un registry que implemente la **API de referrers de OCI** (`/v2/<name>/referrers/<digest>`) o el esquema de tags de fallback para referrers. Verificá antes de comprometerte con él:

```
$ curl -sI -H "Authorization: Bearer $TOKEN" \
    https://registry.acme.internal/v2/api/referrers/sha256:9f2b1e0a... | head -3
HTTP/2 200
content-type: application/vnd.oci.image.index.v1+json
oci-subject: sha256:9f2b1e0a...
```

Un `404` acá significa que el registry no tiene soporte de referrers y la verificación con Notary va a fallar con `failed to resolve referrers`.

---

## 9. Diagnóstico: un runbook guiado por fallas

### 9.1 La escalera de triaje

Trabajá siempre de afuera hacia adentro. El error de Kyverno es el *último* lugar donde mirar, porque agrega cuatro subsistemas distintos.

```
$ # 1. Does the signature exist at all, from your laptop?
$ cosign verify --certificate-identity-regexp '...' --certificate-oidc-issuer '...' $IMG

$ # 2. Can KYVERNO's pod reach the registry? (its creds, its DNS, its egress)
$ kubectl -n kyverno debug -it deploy/kyverno-admission-controller \
    --image=cgr.dev/chainguard/crane --target=kyverno -- crane manifest $IMG

$ # 3. Is the policy even matching the image?
$ kubectl get clusterpolicy verify-acme-api -o jsonpath='{.spec.rules[*].verifyImages[*].imageReferences}'

$ # 4. What did the engine actually say?
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --since=10m \
    | grep -iE 'verifyimage|imageverif|cosign|notary'
```

Salida representativa del controlador durante una falla:

```
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --since=5m | grep -i verify
I0813 14:22:07.881204  1 imageVerifyValidate.go:118] EngineVerifyImages "msg"="verifying image" "image"="ghcr.io/acme/api:v1.4.2" "policy"="verify-acme-api" "rule"="verify-signature-and-sbom"
E0813 14:22:09.114881  1 imageVerifyValidate.go:246] EngineVerifyImages "msg"="failed to verify image" "error"="no matching signatures:\nnone of the expected identities matched what was in the certificate" "image"="ghcr.io/acme/api:v1.4.2"
I0813 14:22:09.115402  1 event.go:377] Event(v1.ObjectReference{Kind:"ClusterPolicy", Name:"verify-acme-api"}): type: 'Warning' reason: 'PolicyViolation' Pod prod/api: [verify-signature-and-sbom] fail
```

Events, que sobreviven después de que la salida de `kubectl` se fue en el scroll:

```
$ kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail -5
prod   3m   Warning  PolicyViolation  clusterpolicy/verify-acme-api   Pod prod/api: [verify-signature-and-sbom] fail (no matching signatures)
```

### 9.2 Tabla de error a causa

| Fragmento del mensaje | Causa raíz | Solución |
|---|---|---|
| `no signatures found` | El tag `.sig` / referrer no existe. La imagen nunca fue firmada, o fue firmada por digest mientras vos pusheaste un digest *distinto* (índice multi-arquitectura vs manifiesto). | `cosign tree $IMG`. Para multi-arquitectura, firmá el digest del **índice** que el pod referencia. |
| `no matching signatures: none of the expected identities matched` | La firma existe; `subject`/`issuer` o la clave pública no coinciden. | Compará `cosign verify … \| jq '.[0].optional.Subject'` contra el glob de `subject` de la política. Prestá atención a `refs/heads/main` vs `refs/tags/*`. |
| `signature not found in transparency log` / timeout de `rekor` | No hay salida desde el pod de Kyverno hacia `rekor.sigstore.dev:443`. | Abrí la salida, o `rekor.ignoreTlog: true` (debilita la garantía), o corré un Rekor privado. |
| `GET https://ghcr.io/token?scope=…: UNAUTHORIZED` | Kyverno no tiene credenciales para el registry. **No** hereda los pull secrets del nodo ni del pod. | Creá el secret en el namespace de Kyverno y referencialo con `imageRegistryCredentials.secrets` o `--imagePullSecrets`; reiniciá el controlador. |
| `x509: certificate signed by unknown authority` | Registry privado / Fulcio privado con una CA que falta en el trust store de Kyverno. | Montá el bundle de la CA en el controlador y seteá `SSL_CERT_FILE`, o agregala a `keyless.roots`. |
| `failed to fetch attestations` / `attestation checks failed … and predicate <type>` | No hay atestación de ese `type`, o la condición JMESPath evaluó como falsa. | `cosign verify-attestation --type <type> $IMG \| jq -r '.payload\|@base64d' \| jq '.predicate'` — y después probá tu JMESPath contra ese objeto exacto. |
| `context deadline exceeded` | `webhookConfiguration.timeoutSeconds` más corto que la latencia real de verificación. | Subilo a 30 s; habilitá `imageVerifyCache`; pasate a un mirror regional del registry. |
| La regla no hace nada en silencio; el reporte muestra `skip` | El glob de `imageReferences` no matchea la referencia **normalizada**. `nginx:1.27` se normaliza a `docker.io/library/nginx:1.27`. | Usá globs totalmente calificados, o revisá el ConfigMap `kyverno`: `defaultRegistry` y `enableDefaultRegistryMutation`. |
| Los Deployments pasan pero los Pods sueltos son bloqueados (o al revés) | Autogen produjo (o se le impidió producir) reglas para controllers. | `kubectl get clusterpolicy X -o yaml \| grep autogen` y revisá `pod-policies.kyverno.io/autogen-controllers`. |
| `error unmarshalling PEM` / `unable to load certificate` | La indentación del escalar de bloque de YAML arruinó el PEM. | Usá `\|-`, mantené las líneas `-----BEGIN`/`-----END` intactas, sin espacios al final. `yq '.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys' policy.yaml` para ver qué se parseó realmente. |
| Funciona en el primer apply, falla después de un re-push | El caché sostiene un veredicto viejo para un digest re-tagueado, o lo contrario — el tag ahora apunta a bytes sin firmar. | Este es el control funcionando. Revisá `useCache` y el TTL solo después de confirmar con `cosign`. |
| Todo falla después de semanas de estabilidad, air-gapped | Los metadatos de la raíz TUF expiraron. | Refrescá el mirror TUF privado; `features.tuf.root` debe estar al día. |

### 9.3 Inspeccionar el estado de la política

```
$ kubectl get clusterpolicy verify-acme-api
NAME              ADMISSION   BACKGROUND   VALIDATE ACTION   READY   AGE   MESSAGE
verify-acme-api   true        false        Enforce           True    12d   Ready

$ kubectl describe clusterpolicy verify-acme-api | sed -n '/Conditions/,$p'
Conditions:
  Last Transition Time:  2026-08-01T09:14:22Z
  Message:               Ready
  Reason:                Succeeded
  Status:                True
  Type:                  Ready
```

Un `READY: False` en una política de verificación de imágenes casi siempre significa que Kyverno falló al construir el cliente del registry — revisá los logs del controlador buscando `failed to create registry client`.

---

## 10. Estrategia de rollout y excepciones

Nunca introduzcas `verifyImages` con `Enforce` el primer día. La secuencia medida:

```
Phase 1  Audit, cluster-wide, required: false
         → Build the inventory. Which images have signatures at all?

Phase 2  Audit, cluster-wide, required: true
         → PolicyReport now shows every image that WOULD be blocked.
         → Drive that count to zero by fixing pipelines, not by weakening policy.

Phase 3  Enforce in one non-critical namespace via validationFailureActionOverrides

Phase 4  Enforce everywhere; overrides carve out kube-system and vendor namespaces

Phase 5  Add verifyDigest: true once every producer emits digests
```

Fase 1→2 en una sola política:

```yaml
spec:
  validationFailureAction: Audit
  validationFailureActionOverrides:
    - action: Enforce
      namespaces: ["sandbox-supplychain"]     # phase 3 beachhead
    - action: Audit
      namespaces: ["*"]
```

### 10.1 Excepciones con límite temporal

Las imágenes de proveedores que nunca van a estar firmadas necesitan una excepción explícita, auditable y con vencimiento — no un agujero permanente en `imageReferences`:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: vendor-monitoring-unsigned
  namespace: observability
  annotations:
    acme.io/ticket: SEC-4412
    acme.io/expires: "2026-11-30"
    acme.io/approver: platform-security
spec:
  exceptions:
    - policyName: verify-acme-api
      ruleNames:
        - verify-signature-and-sbom
        - autogen-verify-signature-and-sbom
  match:
    any:
      - resources:
          kinds: [Pod, Deployment, DaemonSet]
          namespaces: [observability]
          names: ["vendor-agent-*"]
```

Notá que también tenés que listar el nombre de la regla de **autogen**; olvidarlo es la razón por la que las excepciones "no funcionan" para Deployments.

Combiná esto con una política de limpieza para que la excepción no pueda sobrevivir a su ticket:

```yaml
apiVersion: kyverno.io/v2
kind: ClusterCleanupPolicy
metadata:
  name: expire-policy-exceptions
spec:
  match:
    any:
      - resources:
          kinds: [PolicyException]
  conditions:
    any:
      - key: "{{ time_before('{{ target.metadata.annotations.\"acme.io/expires\" }}T00:00:00Z', '{{ time_now_utc() }}') }}"
        operator: Equals
        value: true
  schedule: "0 3 * * *"
```

### 10.2 Endurecimiento: proteger la anotación de verificación

La anotación `kyverno.io/verify-images` es el registro propio de Kyverno. Negá las escrituras provistas por usuarios sobre ella para que nadie pueda falsificar una marca de "verificado" en un recurso que evita la ruta del webhook de mutación:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: protect-verify-images-annotation
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: block-annotation-writes
      match:
        any:
          - resources:
              kinds: [Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob]
      exclude:
        any:
          - subjects:
              - kind: ServiceAccount
                name: kyverno-admission-controller
                namespace: kyverno
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: AnyIn
            value: [CREATE, UPDATE]
      validate:
        message: "The kyverno.io/verify-images annotation is managed by Kyverno and may not be set directly."
        deny:
          conditions:
            any:
              - key: "kyverno.io/verify-images"
                operator: AnyIn
                value: "{{ request.object.metadata.annotations.keys(@) || `[]` }}"
```

---

## 11. `ImageValidatingPolicy` — el sucesor basado en CEL (Kyverno ≥ 1.14, `v1alpha1`)

Kyverno 1.14 introdujo una nueva familia de CRDs de política bajo `policies.kyverno.io/v1alpha1` que se alinean con las convenciones de `ValidatingAdmissionPolicy` de Kubernetes upstream: `matchConstraints` en lugar de `match`, CEL en lugar de JMESPath, `validationActions` en lugar de `validationFailureAction`. `ImageValidatingPolicy` (nombre corto `ivpol`) es el miembro dedicado a la verificación de imágenes.

```yaml
apiVersion: policies.kyverno.io/v1alpha1
kind: ImageValidatingPolicy
metadata:
  name: verify-acme-ivpol
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  evaluation:
    background:
      enabled: false
    mutateDigest:
      enabled: true
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  matchImageReferences:
    - glob: "ghcr.io/acme/*"
  attestors:
    - name: acme-ci
      cosign:
        keyless:
          identities:
            - issuer: "https://token.actions.githubusercontent.com"
              subjectRegExp: "^https://github\\.com/acme/api/\\.github/workflows/release\\.yaml@refs/tags/.*$"
  attestations:
    - name: sbom
      intoto:
        type: https://cyclonedx.org/bom
  validations:
    - expression: >-
        images.containers.map(image,
          verifyImageSignatures(image, [attestors.acme_ci]) > 0
        ).all(e, e)
      message: "every ACME container image must carry a valid CI signature"
```

| | `ClusterPolicy.verifyImages` (v1) | `ImageValidatingPolicy` (v1alpha1) |
|---|---|---|
| Estabilidad | GA, el objetivo principal del examen | Alpha — los nombres de campo se mueven entre releases menores |
| Lenguaje de expresiones | JMESPath | CEL |
| Matching | `match`/`exclude` de Kyverno | `matchConstraints` de Kubernetes (compatible con VAP) |
| Lógica booleana sobre attestors | Conjuntos con `attestors[].count` | CEL arbitrario sobre resultados de `verifyImageSignatures()` |
| Autogen para controllers | Sí | Vía configuración de `autogen` |
| Excepciones | `PolicyException` | `PolicyException` |

**Guía práctica.** Escribí los controles de producción sobre `ClusterPolicy.verifyImages` hoy. Tratá a `ImageValidatingPolicy` como la dirección hacia la que se avanza, y antes de escribir una, confirmá la forma contra el CRD efectivamente instalado en tu clúster en lugar de contra cualquier documento — incluido este:

```
$ kubectl get crd imagevalidatingpolicies.policies.kyverno.io \
    -o jsonpath='{.spec.versions[*].name}{"\n"}'
v1alpha1

$ kubectl explain ivpol.spec --recursive | head -60
```

---

## 12. Resumen enfocado en el examen

- `verifyImages` corre en la fase de admisión de **mutación**, porque `mutateDigest` emite un JSONPatch. Las reglas de validación ven la especificación ya fijada por digest.
- `mutateDigest: true` es lo que cierra la brecha TOCTOU entre la verificación y el pull. Una verificación sin fijado por digest es puro teatro.
- `required: true` significa "una imagen que matchea `imageReferences` y que no satisface ningún conjunto de attestors es una violación." `required: false` es verificar-si-está-presente y casi nunca es lo que querés.
- **Los conjuntos de attestors se combinan con AND; las entradas dentro de un conjunto se combinan con AND salvo que se setee `count`, en cuyo caso es `count`-de-N.** Esta es el álgebra booleana que el examen evalúa.
- Keyless vincula la imagen a una *identidad de workflow de código fuente*; las claves la vinculan solo a la *posesión de una clave*. `subject: "*"` destruye el control por completo.
- El JMESPath de `attestations[].conditions[].key` está enraizado en el **predicado**, no en el Statement in-toto.
- El admission controller de Kyverno hace I/O contra el registry con **sus propias** credenciales — nunca con los `imagePullSecrets` del pod y nunca con las del nodo.
- Las referencias a imágenes se **normalizan** antes del matcheo por glob (`nginx:1.27` → `docker.io/library/nginx:1.27`).
- Los escaneos en segundo plano no re-verifican firmas; un reporte limpio no es evidencia de que las imágenes en ejecución sigan firmadas.
- `failurePolicy: Fail` es lo correcto para un control de seguridad y crea un acoplamiento duro de disponibilidad con el registry — mitigalo con un `match` estrecho, réplicas, un PDB, un mirror regional y un `timeoutSeconds` generoso.
- División de triaje: `no signatures found` = no hay nada ahí; `no matching signatures` = identidad equivocada.

---

## Referencias

**Kyverno — documentación oficial**
- Referencia de la regla Verify Images — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- Verify Images: Sigstore/Cosign — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/
- Verify Images: Notary — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/notary/
- Policy Exceptions — https://kyverno.io/docs/exceptions/
- Instalación de Kyverno y flags de configuración — https://kyverno.io/docs/installation/customization/
- CLI de Kyverno (`apply`, `test`, `--registry`) — https://kyverno.io/docs/kyverno-cli/
- Referencia de métricas de Kyverno — https://kyverno.io/docs/monitoring/
- Filtros personalizados de JMESPath (`time_since`, `regex_match`, `time_before`) — https://kyverno.io/docs/policy-types/cluster-policy/jmespath/
- Biblioteca de políticas de Kyverno — verificación de imágenes — https://kyverno.io/policies/?policytypes=Sigstore
- Código fuente de Kyverno (tipos de la API `ImageVerification`) — https://github.com/kyverno/kyverno/blob/main/api/kyverno/v1/image_verification_types.go
- Releases de Kyverno y notas de actualización — https://github.com/kyverno/kyverno/releases

**Sigstore**
- Documentación de Cosign — https://docs.sigstore.dev/cosign/signing/overview/
- Firma keyless / Fulcio — https://docs.sigstore.dev/certificate_authority/overview/
- Log de transparencia Rekor — https://docs.sigstore.dev/logging/overview/
- Verificación con `cosign verify` / `verify-attestation` — https://docs.sigstore.dev/cosign/verifying/verify/
- GitHub Action `cosign-installer` — https://github.com/sigstore/cosign-installer
- Stack Sigstore privado/self-hosted — https://github.com/sigstore/scaffolding

**Notary Project**
- Documentación de la CLI Notation — https://notaryproject.dev/docs/
- Especificaciones del Notary Project — https://github.com/notaryproject/specifications

**Estándares de cadena de suministro**
- Especificación SLSA v1.0 y modelo de amenazas — https://slsa.dev/spec/v1.0/threats
- Predicado de procedencia SLSA — https://slsa.dev/spec/v1.0/provenance
- Framework de atestaciones in-toto — https://github.com/in-toto/attestation
- Generador SLSA para GitHub (container) — https://github.com/slsa-framework/slsa-github-generator
- Especificación CycloneDX — https://cyclonedx.org/specification/overview/

**OCI y Kubernetes**
- OCI Distribution Specification — API de referrers — https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers
- Webhooks de admisión de Kubernetes (`failurePolicy`, `timeoutSeconds`, orden) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Imágenes de Kubernetes y política de pull de imágenes — https://kubernetes.io/docs/concepts/containers/images/

**Examen**
- Currícula KCA (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf