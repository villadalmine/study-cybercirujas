# CGOA 4.1 — Seguridad y Observabilidad en GitOps

**Peso del dominio: 25%** — el bloque individual más grande del examen y, no por casualidad, la parte de GitOps que la mayoría de las plataformas en producción hace mal primero. Todo lo anterior a este dominio enseña cómo hacer que un clúster converja hacia un estado declarado. Este dominio plantea una pregunta más difícil: *¿quién está autorizado a declararlo, cómo se demuestra que lo hizo, y cómo se sabe que el bucle sigue corriendo?*

---

## 1. El problema en producción

### 1.1 Qué cambia realmente cuando el clúster hace pull

En un pipeline clásico de CI/CD por push, el runner de CI tiene las llaves. Tiene un kubeconfig, normalmente con permisos amplios, normalmente para cada entorno, y se autentica desde fuera del límite de confianza del clúster. La postura de seguridad de tu clúster de producción es, por lo tanto, la postura de seguridad de tu sistema de CI — sus plugins, sus acciones de terceros, sus runners compartidos, su almacén de secretos, y cada ingeniero que pueda abrir un PR que modifique un archivo de pipeline.

GitOps invierte la dirección: un agente dentro del clúster (el application-controller de Argo CD, el source-controller + kustomize-controller de Flux) hace pull del estado deseado y reconcilia. Ningún sistema externo tiene credenciales del clúster. Esa sola inversión elimina toda una clase de ataques — pero no elimina el riesgo, lo **reubica**. Aparecen tres nuevas concentraciones de privilegio:

1. **El repositorio se convierte en un plano de control de producción.** Un merge es un despliegue. `git push --force` a una rama rastreada es ahora un evento de gestión de cambios con el mismo radio de impacto que `kubectl apply -f`.
2. **El reconciliador es la carga de trabajo más privilegiada del clúster.** Por defecto, tanto Argo CD como Flux se instalan con una identidad capaz de crear y eliminar recursos arbitrarios en todos los namespaces. Un tenant que pueda meter un manifiesto en el repo puede lograr que se aplique *con esa identidad*.
3. **El bucle es ahora infraestructura que puede detenerse en silencio.** Un pipeline de push falla ruidosamente — el build se pone en rojo. Un bucle de pull falla en silencio: el último estado aplicado sigue sirviendo tráfico, la `Kustomization` queda en `Ready=False` en un namespace que nadie mira, y once días más tarde un rollback "no hace nada" porque la reconciliación está rota desde que expiró la credencial.

El punto 3 es la razón por la que seguridad y observabilidad son un solo dominio de examen y no dos. **En GitOps, la observabilidad es un control de seguridad**: la única evidencia de que el estado declarado es el estado en ejecución es una métrica emitida por el reconciliador. La deriva que no podés ver es deriva que no podés atribuir.

### 1.2 Modelo de amenazas del bucle GitOps

Recorré el pipeline etapa por etapa y enumerá lo que un adversario — externo o un insider descuidado — puede hacer en cada salto.

| # | Etapa | Amenaza | Vector realista | Control principal | Verificable con |
|---|---|---|---|---|---|
| T1 | Desarrollador → Git | Cambio no autorizado del estado deseado | Portátil comprometido, PAT robado, sin requisito de revisión | Protección de rama + revisiones obligatorias + CODEOWNERS | API del proveedor / `gh api` |
| T2 | Desarrollador → Git | Cambio atribuido al autor equivocado | Los campos de autor de Git son texto libre; cualquiera puede fijar `user.email` | Firma de commits obligatoria (GPG / SSH / gitsign) | `git log --show-signature`, `signatureKeys` de Argo CD, `spec.verify` de Flux |
| T3 | CI → Registro | Imagen maliciosa o sin revisar publicada | Paso de build comprometido, confusión de dependencias | Imágenes firmadas + atestaciones de procedencia (SLSA) | `cosign verify`, `cosign verify-attestation` |
| T4 | Git → Clúster | Man-in-the-middle en el fetch del repo | `known_hosts` ausente, verificación TLS deshabilitada | Fijación de host-key SSH, bundle de CA, nada de `insecure: true` | Logs del source-controller, `argocd cert list` |
| T5 | Contenido del repo → Clúster | Escalada de privilegios vía manifiesto | Un tenant commitea un `ClusterRoleBinding` a `cluster-admin` | Impersonación del reconciliador + política de admisión | Auditoría de Kyverno/Gatekeeper, log de auditoría de K8s |
| T6 | Contenido del repo → Clúster | Escritura entre tenants | La `Kustomization` del tenant A apunta al namespace B | `--no-cross-namespace-refs`, destinos de AppProject | `flux get kustomizations -A`, validación de proyecto de Argo CD |
| T7 | Secretos | Credenciales en texto plano en Git | Manifiesto `Secret` "temporal" commiteado | SOPS / SealedSecrets / ESO — nunca texto plano | Escaneo del repo estilo `check_citations`, gitleaks, estado de ESO |
| T8 | Clúster → Git | Exfiltración vía egress del reconciliador | Al pod del reconciliador se le dio egress sin restricciones | Lista de permitidos de egress con NetworkPolicy | Sonda con `kubectl exec`, logs de flujo del CNI |
| T9 | El propio bucle | Detención silenciosa / suspensión | Deploy key expirada, `flux suspend` olvidado activo, OOM del controlador | Alertas sobre `Ready=False` **y** sobre suspensión **y** sobre obsolescencia | Reglas de Prometheus (§7.4) |
| T10 | El propio bucle | Pelea de deriva / thrashing | HPA contra `replicas` declaradas | `ignoreDifferences` / propiedad de campos con server-side apply | Métrica de tasa de reconciliación, avalancha de eventos |

Dos de estas merecen énfasis porque son las que rondan tanto las preguntas de examen como los incidentes reales:

- **T2 (atribución).** La identidad de autor y committer de Git son cadenas no autenticadas. `git commit --author="Alice <alice@acme.io>"` no es una mentira que la herramienta vaya a detectar. La firma criptográfica es el único mecanismo que convierte el rastro de auditoría en un rastro de auditoría en lugar de un registro de afirmaciones auto-declaradas.
- **T9 (liveness).** "Synced" es una afirmación sobre la última reconciliación exitosa, no sobre el ahora. Una `Kustomization` cuya fuente no se ha traído en tres días puede seguir reportando `Ready=True` sobre una revisión obsoleta si leés solo el campo equivocado.

### 1.3 Push vs pull: el trade-off de seguridad, dicho con honestidad

| Dimensión | Push (CI tiene el kubeconfig) | Pull (agente dentro del clúster) |
|---|---|---|
| Ubicación de la credencial del clúster | Almacén de secretos externo de CI | Nunca sale del clúster |
| Superficie de ataque | Runners de CI, plugins, acciones del marketplace | Reconciliador + credencial del repo |
| Requisito de red | CI debe alcanzar el API server (a menudo público / bastión) | Solo egress del clúster hacia Git/OCI; el API server puede ser privado |
| Rotación de credenciales | Rotar el kubeconfig en *n* sistemas de CI | Rotar una deploy key o una identidad de carga de trabajo |
| Corrección de deriva | Ninguna — solo en la siguiente ejecución del pipeline | Continua; el intervalo de detección es ajustable |
| Visibilidad de fallos | Alta (build en rojo) | **Baja por defecto** — hay que instrumentarla |
| Radio de impacto si el agente se compromete | Compromiso de CI = todos los clústeres | Compromiso del agente = ese clúster (salvo que sea un hub) |
| Fan-out multi-clúster | *n* credenciales en CI | *n* agentes, o un hub con *n* credenciales (recentraliza el riesgo) |
| Entornos efímeros / de preview | Simple | Necesita ApplicationSet / automatización de bootstrap |

La lectura honesta: pull es una mejora genuina en custodia de credenciales y en deriva, y una regresión genuina en visibilidad por defecto. El dominio 4.1 existe para que cierres la segunda brecha mientras disfrutás la primera.

### 1.4 Dónde encaja esto con los principios de OpenGitOps

Los cuatro principios (declarativo, versionado e inmutable, obtenido automáticamente, reconciliado continuamente) no son controles de seguridad por sí mismos, pero cada uno crea una *afordancia* de seguridad — y cada afordancia requiere un control explícito para materializarse:

| Principio | Afordancia de seguridad | Control que la materializa | Señal de observabilidad |
|---|---|---|---|
| Declarativo | El estado es revisable antes de existir | Revisión de PR, política como código en CI | Tasa de aprobado/fallo de políticas |
| Versionado e inmutable | Cada estado es atribuible y restaurable | Commits firmados, refs protegidas, artefactos OCI firmados por digest | Resultado de la verificación de firma |
| Obtenido automáticamente | Ningún poseedor externo de credenciales | Identidad del reconciliador + impersonación | Éxito del fetch de la fuente, revisión del artefacto |
| Reconciliado continuamente | El cambio no autorizado dentro del clúster es transitorio | Corrección de deriva (`selfHeal` / SSA) | Eventos de deriva, duración de la reconciliación |

---

## 2. Confianza y la cadena de custodia

### 2.1 Git es la raíz de confianza — que es exactamente el problema

"Git es la fuente de verdad" es una afirmación sobre *autoridad*, no sobre *autenticidad*. La autoridad dice: lo que esté en `main` es lo que el clúster debe ejecutar. La autenticidad pregunta: ¿lo que está en `main` es lo que los humanos responsables de `main` realmente aprobaron?

La brecha entre esas dos se cierra con tres capas, y necesitás las tres:

1. **Política del lado del forge** — protección de ramas, aprobaciones requeridas, CODEOWNERS, force-push prohibido, status checks requeridos. Barato, efectivo, y *no verificable desde dentro del clúster*. Un administrador del repo puede apagarlo; el reconciliador nunca se enterará.
2. **Firma criptográfica** — firmas de commit o tag verificadas por el reconciliador en el momento del fetch. Esta es la única capa dentro del propio límite de confianza del clúster.
3. **Política de admisión** — aplicación de última línea sobre qué puede existir, con independencia de cómo llegó ahí.

La capa 2 es la que más le importa a CGOA, porque es la única exclusiva de GitOps.

### 2.2 Comparativa de opciones de firma

| Mecanismo | Material de clave | Verificado por | Historia de revocación | Coste operativo | Notas |
|---|---|---|---|---|---|
| Firma de commits GPG | Clave privada de larga vida por desarrollador | `GitRepository.spec.verify` de Flux, `AppProject.spec.signatureKeys` de Argo CD | Expiración de la clave + eliminación de la lista de permitidos | Alto (distribución de claves, expiración, HSM/YubiKey) | El clásico; ambas herramientas lo soportan de forma nativa |
| Firma de commits SSH (`gpg.format=ssh`) | Reutiliza la clave SSH de autenticación existente | Del lado del forge; **no** verificado nativamente por los reconciliadores de Flux/Argo CD | Quitar de allowed-signers | Bajo | Excelente para política del forge, débil para verificación dentro del clúster |
| Sigstore `gitsign` (keyless) | Certificado efímero, identidad OIDC, log de transparencia Rekor | Forge / CI; dentro del clúster vía herramientas de política | Identidad revocada en el IdP; el log es solo-añadir | Medio | Sin custodia de claves en absoluto; requiere identidad OIDC por firmante |
| Solo **tags** firmados | Una clave de release, en manos de la automatización de release | `verify.mode: Tag` / `TagAndHEAD` de Flux | Rotar la clave de release | Bajo | Encaja muy bien en los límites de promoción |
| **Artefactos OCI** firmados (`cosign` + `OCIRepository` de Flux) | Keyless o clave KMS | `spec.verify.provider: cosign` de Flux, `verifyImages` de Kyverno | Identidad OIDC / política de clave KMS | Medio | Verifica la *configuración empaquetada*, no solo el commit |

Guía práctica para un equipo de plataforma: exigí firma SSH a cada desarrollador (aplicada por el forge, fricción casi nula), y exigí un **tag firmado o un artefacto OCI firmado** en el límite de promoción a producción, verificado dentro del clúster. GPG por desarrollador verificado por el reconciliador es defendible pero rara vez sobrevive al contacto con la expiración de claves a escala.

### 2.3 Flux: verificar firmas en el momento del fetch

Importá las claves públicas permitidas y fijalas a la fuente:

```console
$ gpg --export --armor 3CF6A1B4C0DE9A17 > release-signing.asc
$ gpg --export --armor 9B2E4D1A77C0F332 >> release-signing.asc

$ kubectl -n flux-system create secret generic git-signing-keys \
    --from-file=release-signing.asc=./release-signing.asc
secret/git-signing-keys created
```

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 1m
  timeout: 60s
  url: ssh://git@github.com/acme/platform-config
  ref:
    # Track signed release tags only, never a moving branch, for production.
    semver: ">=1.0.0 <2.0.0"
  secretRef:
    name: platform-config-auth      # identity + known_hosts, see §3
  verify:
    # HEAD  -> verify the commit at the resolved ref
    # Tag   -> verify the annotated tag object
    # TagAndHEAD -> both must verify (strongest)
    # NOTE: pre-Flux-2.1 the only accepted value was the lowercase "head".
    mode: TagAndHEAD
    secretRef:
      name: git-signing-keys
  ignore: |
    # Never let non-manifest content into the artifact.
    /*
    !/clusters/prod/
    !/apps/
    /**/*.md
    /**/*.png
```

Una verificación fallida es una parada en seco — el artefacto nunca se produce, así que nada aguas abajo puede aplicar una revisión no verificada:

```console
$ flux get sources git platform-config
NAME            	REVISION	SUSPENDED	READY	MESSAGE
platform-config 	        	False    	False	failed to verify the signature of 'v1.4.2': unable to verify Git tag: object not signed by a trusted key

$ kubectl -n flux-system get gitrepository platform-config \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq
{
  "lastTransitionTime": "2026-08-18T09:12:44Z",
  "message": "failed to verify the signature of 'v1.4.2': unable to verify Git tag: object not signed by a trusted key",
  "observedGeneration": 7,
  "reason": "VerificationError",
  "status": "False",
  "type": "Ready"
}
```

### 2.4 Argo CD: aplicación de firmas por proyecto

Argo CD aplica esto a nivel de **AppProject**, que es la granularidad correcta — los proyectos de producción requieren firmas, los de sandbox no hace falta.

```console
$ kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.admin\.enabled}'
false

# GPG verification is off unless the controller/repo-server sees this env var.
$ kubectl -n argocd set env statefulset/argocd-application-controller ARGOCD_GPG_ENABLED=true
statefulset.apps/argocd-application-controller env updated

$ argocd gpg add --from ./release-signing.asc
Created 2 GPG public keys

$ argocd gpg list
KEYID             TYPE  IDENTITY
3CF6A1B4C0DE9A17  rsa   ACME Release Bot <release@acme.io>
9B2E4D1A77C0F332  rsa   ACME Platform SRE <platform@acme.io>
```

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Production workloads. Signed revisions only.
  sourceRepos:
    - https://github.com/acme/platform-config
    - https://acme.github.io/charts
  destinations:
    - server: https://kubernetes.default.svc
      namespace: payments
    - server: https://kubernetes.default.svc
      namespace: checkout
  # Only these cluster-scoped kinds may ever be created by this project.
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
    - group: networking.k8s.io
      kind: IngressClass
  # Explicitly deny escalation primitives even inside allowed namespaces.
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  # Every revision synced by this project must carry a signature from one of these keys.
  signatureKeys:
    - keyID: 3CF6A1B4C0DE9A17
    - keyID: 9B2E4D1A77C0F332
  orphanedResources:
    warn: true
    ignore:
      - group: ""
        kind: ServiceAccount
        name: default
  syncWindows:
    - kind: deny
      schedule: "0 22 * * 5"        # Friday 22:00
      duration: 58h                 # through Monday 08:00
      applications:
        - "*"
      manualSync: true              # break-glass still possible, and audited
      timeZone: "Europe/Madrid"
  roles:
    - name: deployer
      description: CI identity, may sync but never mutate the spec
      policies:
        - p, proj:prod:deployer, applications, sync, prod/*, allow
        - p, proj:prod:deployer, applications, get, prod/*, allow
      jwtTokens:
        - iat: 1755500000
```

Verificación de la ruta de denegación:

```console
$ argocd app sync payments
FATA[0001] rpc error: code = InvalidArgument desc = application repository revision
'9f3c2ab' is not signed by a key in the project's allowed signature key list
```

### 2.5 Extender la cadena a los artefactos: OCI + cosign

La firma de commits demuestra quién escribió el YAML. No demuestra qué imagen de contenedor es segura de ejecutar. Cerrá el bucle (a) publicando la configuración renderizada como un artefacto OCI firmado, y (b) verificando las firmas de imagen en la admisión.

```console
$ flux push artifact oci://ghcr.io/acme/platform-config:v1.4.2 \
    --path="./clusters/prod" \
    --source="$(git config --get remote.origin.url)" \
    --revision="v1.4.2@sha1:$(git rev-parse HEAD)"
► pushing artifact to ghcr.io/acme/platform-config:v1.4.2
✔ artifact successfully pushed to ghcr.io/acme/platform-config@sha256:6f0a1c...e42b

$ cosign sign --yes ghcr.io/acme/platform-config@sha256:6f0a1c...e42b
tlog entry created with index: 148829301
```

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: platform-config
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/acme/platform-config
  ref:
    semver: ">=1.4.0 <2.0.0"
  secretRef:
    name: ghcr-pull
  verify:
    provider: cosign
    # Keyless: bind the artifact to the identity of the workflow that produced it.
    matchOIDCIdentity:
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/acme/platform-config/\\.github/workflows/release\\.yaml@refs/tags/v.*$"
```

```console
$ flux get sources oci platform-config
NAME           	REVISION                       	SUSPENDED	READY	MESSAGE
platform-config	v1.4.2@sha256:6f0a1c...e42b   	False    	True 	stored artifact for digest 'v1.4.2@sha256:6f0a1c...e42b'
```

Si la verificación falla, el mensaje nombra la razón con precisión:

```console
$ flux get sources oci platform-config
NAME           	REVISION	SUSPENDED	READY	MESSAGE
platform-config	        	False    	False	failed to verify the signature of 'ghcr.io/acme/platform-config:v1.4.3': no matching signatures: none of the expected identities matched what was in the certificate
```

---

## 3. Credenciales del repositorio: la identidad del reconciliador

El reconciliador necesita acceso de lectura a Git y/o a un registro OCI. Esa credencial es un secreto de producción con una propiedad interesante: es la *única* credencial externa de larga vida en un sistema pull bien construido, lo que hace que valga la pena sobre-diseñarla.

| Tipo de credencial | Alcance | Rotación | Auditabilidad | Veredicto |
|---|---|---|---|---|
| Token de acceso personal | Todo lo que el humano puede ver | Manual, se rompe cuando esa persona se va | Atribuida a un humano, erróneamente | **Nunca** |
| PAT de usuario máquina | Repos donde se agregó al bot | Manual, guiada por calendario | Identidad de bot, decente | Solución provisional aceptable |
| Deploy key (SSH, solo lectura) | **Un repositorio** | Manual, por repo | Por repo, excelente | Buen valor por defecto |
| GitHub App / token de grupo de GitLab | Repos seleccionados, granularidad fina | Tokens de instalación de vida corta | A nivel de app, excelente | Lo mejor para muchos repos |
| Identidad de carga de trabajo en la nube (OIDC → IAM) | Registro/almacén de artefactos | Automática, sin secreto estático | Rastro de auditoría de IAM | Lo mejor donde esté soportado |

**Regla: una deploy key de solo lectura por repositorio por clúster.** Una sola clave a nivel de organización significa que un clúster comprometido lee todos los repos, y la rotación se convierte en un proyecto del tamaño de un congelamiento de cambios.

### 3.1 Flux: identidad SSH con fijación de host key

```console
$ flux create secret git platform-config-auth \
    --namespace=flux-system \
    --url=ssh://git@github.com/acme/platform-config \
    --ssh-key-algorithm=ecdsa \
    --ssh-ecdsa-curve=p384
✚ generating GitRepository authentication secret
► public key: ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQ...
✔ authentication configured

$ kubectl -n flux-system get secret platform-config-auth -o jsonpath='{.data}' | jq 'keys'
[
  "identity",
  "identity.pub",
  "known_hosts"
]
```

La clave `known_hosts` es el control que derrota a T4. Verificá que esté poblada y coincida con la huella publicada por el forge — un `known_hosts` vacío o con comodines deshabilita silenciosamente la verificación del host:

```console
$ kubectl -n flux-system get secret platform-config-auth \
    -o jsonpath='{.data.known_hosts}' | base64 -d | ssh-keygen -lf -
3072 SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s github.com (RSA)
```

### 3.2 Argo CD: credencial de repositorio como Secret etiquetado (declarativo, no `argocd repo add`)

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: repo-platform-config
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ssh://git@github.com/acme/platform-config
  # sshPrivateKey is injected by External Secrets — see §5.3. Never inline it.
  project: prod
```

```console
$ argocd repo list
TYPE  NAME             REPO                                              INSECURE  OCI    LFS    CREDS  STATUS      MESSAGE  PROJECT
git   platform-config  ssh://git@github.com/acme/platform-config         false     false  false  true   Successful           prod

$ argocd cert list --cert-type ssh
HOSTNAME    TYPE  SUBTYPE              FINGERPRINT/SUBJECT
github.com  ssh   ecdsa-sha2-nistp256  SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM
```

`INSECURE=false` y un `argocd cert list` poblado son las dos cosas que hay que afirmar en una revisión de hardening. `insecure: "true"` en un secret de repositorio deshabilita la verificación TLS/de host y es un hallazgo, no una solución alternativa.

---

## 4. Mínimo privilegio para el reconciliador

Este es el control de mayor valor de todo el dominio y el que más a menudo se omite, porque la instalación por defecto funciona y la endurecida requiere pensar.

### 4.1 La escalada de la que te estás defendiendo

Un tenant con acceso de escritura a `apps/team-a/` en el repo de configuración commitea:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: team-a-helper
subjects:
  - kind: ServiceAccount
    name: default
    namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
```

Si el reconciliador corre como `cluster-admin`, esto se aplica con éxito. La propia prevención de escalada de privilegios de Kubernetes no te salva: el reconciliador genuinamente *tiene* `cluster-admin`, así que otorgarlo está permitido. El tenant nunca necesitó acceso al clúster — necesitó acceso al repo, y el reconciliador lo lavó convirtiéndolo en cluster-admin.

### 4.2 Flux: la impersonación como valor por defecto

El kustomize-controller y el helm-controller de Flux impersonan una ServiceAccount al aplicar. Configurá los flags de aplicación en el bootstrap para que *omitir* `serviceAccountName` sea un fallo en lugar de un repliegue a privilegio total.

```yaml
# clusters/prod/flux-system/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
patches:
  - target:
      kind: Deployment
      name: "(kustomize-controller|helm-controller)"
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --no-cross-namespace-refs=true
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --no-remote-bases=true
      # Any Kustomization without spec.serviceAccountName falls back to the
      # ServiceAccount named "default" IN ITS OWN NAMESPACE, which has no rights.
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --default-service-account=default
  - target:
      kind: Deployment
      name: "(source-controller|notification-controller|image-reflector-controller|image-automation-controller)"
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/args/-
        value: --watch-all-namespaces=true
```

El onboarding de un tenant es entonces un namespace, una ServiceAccount, un Role con alcance de namespace, y una `Kustomization` que la impersona:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    toolkit.fluxcd.io/tenant: team-a
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: team-a-reconciler
  namespace: team-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-a-reconciler
  namespace: team-a
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets", "services", "serviceaccounts", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Deliberately absent: rbac.authorization.k8s.io, all cluster-scoped kinds,
  # and any *.k8s.io admission/policy group.
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-a-reconciler
  namespace: team-a
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: team-a-reconciler
subjects:
  - kind: ServiceAccount
    name: team-a-reconciler
    namespace: team-a
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: team-a
  namespace: team-a
spec:
  interval: 5m
  url: https://github.com/acme/team-a-config
  ref:
    branch: main
  secretRef:
    name: team-a-git-auth
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: team-a
  namespace: team-a
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  path: ./deploy/prod
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: team-a          # cross-namespace ref would be rejected by the flag above
  # The whole point: apply AS the tenant identity, not as the controller.
  serviceAccountName: team-a-reconciler
  targetNamespace: team-a
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: api
      namespace: team-a
```

Prueba de que la escalada está ahora bloqueada:

```console
$ flux -n team-a get kustomizations
NAME  	REVISION	SUSPENDED	READY	MESSAGE
team-a	        	False    	False	Kustomization/team-a/team-a dry-run failed: clusterrolebindings.rbac.authorization.k8s.io "team-a-helper" is forbidden: User "system:serviceaccount:team-a:team-a-reconciler" cannot create resource "clusterrolebindings" in API group "rbac.authorization.k8s.io" at the cluster scope

$ kubectl auth can-i create clusterrolebindings \
    --as=system:serviceaccount:team-a:team-a-reconciler
no
```

Notá que el fallo ocurre en el **dry-run**, antes de cualquier aplicación parcial. Flux hace dry-run del lado del servidor de todo el conjunto primero, así que un recurso prohibido aborta la transacción en lugar de dejar la mitad de los manifiestos aplicados.

### 4.3 Argo CD: proyectos, RBAC e instalación con alcance de namespace

El modelo de aislamiento de Argo CD es el `AppProject` (qué puede referenciar y crear una Application) más `argocd-rbac-cm` (quién puede actuar sobre las Applications).

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  # Anything not explicitly allowed is denied outright.
  policy.default: ""
  scopes: '[groups, email]'
  policy.csv: |
    # --- roles -------------------------------------------------------------
    p, role:platform-sre, applications, *,        */*,      allow
    p, role:platform-sre, clusters,     get,      *,        allow
    p, role:platform-sre, repositories, *,        *,        allow
    p, role:platform-sre, projects,     *,        *,        allow
    p, role:platform-sre, exec,         create,   */*,      deny

    p, role:team-a-dev,   applications, get,      team-a/*, allow
    p, role:team-a-dev,   applications, sync,     team-a/*, allow
    p, role:team-a-dev,   applications, action/*, team-a/*, allow
    p, role:team-a-dev,   applications, delete,   team-a/*, deny
    p, role:team-a-dev,   applications, override, team-a/*, deny
    p, role:team-a-dev,   logs,         get,      team-a/*, allow

    p, role:auditor,      applications, get,      */*,      allow
    p, role:auditor,      projects,     get,      *,        allow

    # --- bindings (SSO groups) --------------------------------------------
    g, acme:platform-sre, role:platform-sre
    g, acme:team-a,       role:team-a-dev
    g, acme:security,     role:auditor
```

Argo CD incluye un simulador de políticas — usalo en CI para que un cambio de RBAC se revise con evidencia, no con confianza:

```console
$ argocd admin settings rbac can acme:team-a sync applications 'team-a/payments' \
    --policy-file rbac-cm.yaml --namespace argocd
Yes

$ argocd admin settings rbac can acme:team-a delete applications 'team-a/payments' \
    --policy-file rbac-cm.yaml --namespace argocd
No

$ argocd admin settings rbac can acme:team-a sync applications 'prod/checkout' \
    --policy-file rbac-cm.yaml --namespace argocd
No

$ argocd admin settings rbac validate --policy-file rbac-cm.yaml
Policy is valid.
```

Endurecé el propio servidor en `argocd-cm`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.acme.io
  admin.enabled: "false"                 # local admin off; SSO is the only path
  users.anonymous.enabled: "false"
  exec.enabled: "false"                  # no terminal into workloads from the UI
  users.session.duration: "8h"
  application.instanceLabelKey: argocd.argoproj.io/instance
  # Restrict which resources Argo CD tracks at all (reduces cache + blast radius)
  resource.exclusions: |
    - apiGroups: ["cilium.io"]
      kinds: ["CiliumIdentity"]
      clusters: ["*"]
    - apiGroups: ["*"]
      kinds: ["Event", "EndpointSlice"]
      clusters: ["*"]
  dex.config: |
    connectors:
      - type: oidc
        id: acme-idp
        name: ACME SSO
        config:
          issuer: https://idp.acme.io
          clientID: $oidc.acme.clientId
          clientSecret: $oidc.acme.clientSecret
          requestedScopes: ["openid", "profile", "email", "groups"]
```

### 4.4 Modelo de aislamiento lado a lado

| Control | Flux | Argo CD |
|---|---|---|
| Identidad en el momento de aplicar | Impersonación de SA por `Kustomization` (`spec.serviceAccountName`) | SA del controlador, o credencial del clúster de destino; **sin impersonación por app por defecto** |
| Forzar que la identidad esté fijada | `--default-service-account` | No aplica — usá una instancia de Argo por tenant, o restricciones de `AppProject` |
| Referencia entre namespaces | Bloqueada con `--no-cross-namespace-refs` | `AppProject.spec.destinations` / `sourceNamespaces` |
| Fuentes permitidas | El `GitRepository` debe existir en el NS del tenant | `AppProject.spec.sourceRepos` |
| Kinds permitidos | Lo que permita el Role impersonado | `clusterResourceWhitelist` / `namespaceResourceBlacklist` |
| RBAC humano | RBAC nativo de Kubernetes sobre los CRs | `argocd-rbac-cm` (Casbin), separado del RBAC de K8s |
| Bases remotas desde internet | `--no-remote-bases=true` | Lista de repos permitidos + endurecimiento de `kustomize.buildOptions` |
| Control por horarios | `spec.suspend` (manual) | `AppProject.spec.syncWindows` |

La diferencia estructural importa para el examen: **la tenencia de Flux es RBAC de Kubernetes**; **la tenencia de Argo CD es un sistema de autorización a nivel de aplicación por encima de un controlador privilegiado compartido**. Ninguna está mal, pero la historia de hardening de Argo CD suele terminar en "una instancia de Argo CD por zona de confianza" para una multi-tenencia genuinamente hostil.

### 4.5 Contención del egress del reconciliador (T8)

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: flux-controllers-egress
  namespace: flux-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: flux
  policyTypes: ["Egress"]
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Kubernetes API server
    - to:
        - ipBlock:
            cidr: 10.100.0.1/32
      ports:
        - protocol: TCP
          port: 443
    # Git forge + registry, via the egress proxy only
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: egress
          podSelector:
            matchLabels:
              app: egress-proxy
      ports:
        - protocol: TCP
          port: 3128
    # Intra-namespace (source-controller artifact HTTP server on :9090)
    - to:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 9090
```

---

## 5. Secretos en un flujo de trabajo cuya premisa es "todo está en Git"

El principio declarativo dice que todo el estado vive en el repo. Los secretos son estado. Esta es la colisión con la que se topa toda adopción de GitOps en la segunda semana.

### 5.1 Las cinco respuestas viables, comparadas

| Enfoque | ¿Texto cifrado en Git? | Ancla de confianza | Rotación sin commit | ¿Funciona offline / air-gapped? | Modo de fallo clave |
|---|---|---|---|---|---|
| **SealedSecrets** | Sí | Clave privada del controlador, dentro del clúster | No — hay que volver a sellar y commitear | Sí | Perder la clave del controlador pierde todos los secretos sellados; texto cifrado por clúster |
| **SOPS + age** | Sí | Clave privada age como Secret de K8s | No | Sí | La propia clave age es un secreto de bootstrap que hay que proteger fuera de banda |
| **SOPS + KMS en la nube** | Sí | KMS / IAM de la nube | No | No | Una caída del KMS o una deriva de IAM bloquea toda la reconciliación |
| **External Secrets Operator** | **No** — solo referencias | Almacén externo (Vault, secret manager de la nube) | **Sí** — `refreshInterval` lo recoge | No | Caída del almacén; ESO se convierte en una dependencia crítica |
| **Vault Agent / driver CSI** | No — montado al arrancar el pod | Vault + identidad de carga de trabajo | Sí (con templating/reinicio) | No | El secreto nunca se convierte en un objeto `Secret` de K8s — algunas cargas de trabajo no pueden consumirlo |

**Heurística de decisión:** si el secreto es material de *bootstrap del clúster* (la deploy key de Git, la credencial de ESO, la propia clave age), usá SOPS o SealedSecrets — no podés depender de un operador que todavía no ha sido instalado. Para todo lo que sea *a nivel de aplicación*, usá ESO, porque la rotación sin commit vale más que todas las demás propiedades juntas.

### 5.2 SOPS + age con Flux, de punta a punta

```console
$ age-keygen -o age.agekey
Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

$ cat age.agekey | kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin
secret/sops-age created

# Store the private key in the org password manager / HSM, then destroy the local copy.
$ shred -u age.agekey
```

`.sops.yaml` en la raíz del repo — este archivo es lo que hace que el cifrado sea *el valor por defecto* en lugar de algo que la gente tiene que recordar:

```yaml
creation_rules:
  - path_regex: clusters/prod/.*\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
  - path_regex: clusters/staging/.*\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1vy7q9wr3kdqcs8n2m6ldg0rp4uz5xh7ct2j9fw0lqe8dnvs4a3xq7hj2ke
```

```console
$ kubectl -n payments create secret generic payments-db \
    --from-literal=username=payments_rw \
    --from-literal=password='S3cr3t-not-really' \
    --dry-run=client -o yaml > clusters/prod/payments/db-secret.yaml

$ sops --encrypt --in-place clusters/prod/payments/db-secret.yaml

$ head -14 clusters/prod/payments/db-secret.yaml
apiVersion: v1
kind: Secret
metadata:
    name: payments-db
    namespace: payments
type: Opaque
data:
    username: ENC[AES256_GCM,data:2rN9xQ==,iv:8vK1...,tag:pQ==,type:str]
    password: ENC[AES256_GCM,data:mLp0dR6yTt==,iv:cW4z...,tag:9a==,type:str]
sops:
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
```

Notá que `apiVersion`, `kind`, `metadata` y `type` quedan en texto claro. Eso es deliberado y es lo que te compra `encrypted_regex`: Kustomize todavía puede parchear, mezclar y referenciar el objeto, y quien revisa todavía puede ver *qué* cambió sin ver el valor.

Conectá el descifrado a la `Kustomization`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: payments
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/prod/payments
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: platform-config
  serviceAccountName: payments-reconciler
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-vars
```

Diagnóstico del fallo clásico:

```console
$ flux get kustomizations payments
NAME    	REVISION	SUSPENDED	READY	MESSAGE
payments	        	False    	False	Decryption failed for 'payments-db': failed to decrypt sops data key with provider 'age': no identity matched any of the recipients

$ kubectl -n flux-system get secret sops-age -o jsonpath='{.data}' | jq 'keys'
["age.agekey"]      # correct key name — the controller looks for *.agekey

$ kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}' \
    | base64 -d | age-keygen -y
age1vy7q9wr3kdqcs8n2m6ldg0rp4uz5xh7ct2j9fw0lqe8dnvs4a3xq7hj2ke
#  ^ the STAGING public key is in the PROD cluster. Root cause found.
```

### 5.3 External Secrets Operator: rotación sin commit

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets
---
# NOTE: ESO ≥ 0.17 serves the stable external-secrets.io/v1 API; older
# deployments serve v1beta1. Check with: kubectl api-resources | grep external-secrets
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-prod
spec:
  provider:
    vault:
      server: https://vault.internal.acme.io:8200
      path: kv
      version: v2
      caProvider:
        type: ConfigMap
        name: vault-ca
        namespace: external-secrets
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes/prod
          role: eso-prod
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
  # Fail closed and loudly rather than serving stale material silently.
  retrySettings:
    maxRetries: 5
    retryInterval: "10s"
  conditions:
    - namespaceSelector:
        matchLabels:
          acme.io/environment: prod
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payments-db
  namespace: payments
spec:
  refreshInterval: 15m
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-prod
  target:
    name: payments-db
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      type: Opaque
      data:
        DATABASE_URL: >-
          postgres://{{ .username }}:{{ .password }}@pg.payments.svc.cluster.local:5432/payments?sslmode=verify-full&sslrootcert=/etc/pg/ca.crt
  data:
    - secretKey: username
      remoteRef:
        key: payments/db
        property: username
    - secretKey: password
      remoteRef:
        key: payments/db
        property: password
```

```console
$ kubectl -n payments get externalsecret payments-db
NAME          STORE        REFRESH INTERVAL   STATUS         READY
payments-db   vault-prod   15m                SecretSynced   True

$ kubectl -n payments get secret payments-db -o jsonpath='{.metadata.ownerReferences}' | jq -r '.[].kind'
ExternalSecret

# Rotate in Vault; no commit, no sync, no PR.
$ vault kv put kv/payments/db username=payments_rw password="$(openssl rand -base64 32)"
====== Secret Path ======
kv/data/payments/db
Version: 8

$ kubectl -n payments annotate externalsecret payments-db \
    force-sync=$(date +%s) --overwrite
externalsecret.external-secrets.io/payments-db annotated

$ kubectl -n payments get secret payments-db -o jsonpath='{.metadata.resourceVersion}'
88421037
```

El repo de Git contiene el `ExternalSecret` — una *referencia*, revisable y comparable — y nunca el valor. Esta es la reconciliación entre "todo en Git" y "ningún secreto en Git": lo que se declara es el *vínculo*, no el material.

### 5.4 Impedir que el texto plano llegue siquiera a aterrizar (defensa en profundidad)

Dos compuertas independientes, porque cualquiera de ellas por sí sola tiene un bypass:

```yaml
# .github/workflows/secret-scan.yaml — gate 1, pre-merge
name: secret-scan
on: [pull_request]
jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Detect committed secrets
        run: |
          docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
            detect --source=/repo --redact --exit-code=1 --report-format=sarif \
            --report-path=/repo/gitleaks.sarif
      - name: Assert every Secret manifest is SOPS-encrypted
        run: |
          fail=0
          while IFS= read -r f; do
            if ! grep -q '^sops:' "$f"; then
              echo "::error file=$f::Secret manifest is not SOPS-encrypted"
              fail=1
            fi
          done < <(grep -rlE '^kind:[[:space:]]*Secret$' clusters/ apps/ || true)
          exit "$fail"
```

```yaml
# gate 2 — admission, catches anything that bypassed CI
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-unmanaged-secrets
spec:
  # Kyverno ≥1.13 moves this to spec.rules[].validate.failureAction
  validationFailureAction: Enforce
  background: false
  rules:
    - name: secrets-must-be-operator-owned
      match:
        any:
          - resources:
              kinds: ["Secret"]
              namespaceSelector:
                matchLabels:
                  acme.io/environment: prod
      exclude:
        any:
          - resources:
              kinds: ["Secret"]
              selector:
                matchExpressions:
                  - key: "type"
                    operator: In
                    values: ["kubernetes.io/service-account-token"]
      validate:
        message: >-
          Secrets in prod namespaces must be created by External Secrets Operator,
          the SealedSecrets controller, or a SOPS-enabled Flux Kustomization.
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.ownerReferences[?kind=='ExternalSecret'] || `[]` | length(@) }}"
                operator: Equals
                value: 0
              - key: "{{ request.object.metadata.ownerReferences[?kind=='SealedSecret'] || `[]` | length(@) }}"
                operator: Equals
                value: 0
              - key: "{{ request.object.metadata.annotations.\"kustomize.toolkit.fluxcd.io/name\" || '' }}"
                operator: Equals
                value: ""
```

---

## 6. Política como código: dónde aplicarla, y por qué "en ambos sitios" es la respuesta

| Punto de aplicación | Detecta | Latencia del feedback | Eludible por | Coste |
|---|---|---|---|---|
| Hook de pre-commit | Erratas, violaciones evidentes de política | Segundos | `--no-verify` | Gratis |
| CI (check de PR) | Esquema, política, deriva respecto al render | Minutos | Merge de admin, push directo | Barato |
| Dry-run del reconciliador | Violaciones de RBAC, versiones de API inválidas | Un intervalo de reconciliación | Nada (está en el camino) | Gratis |
| **Controlador de admisión** | Todo, venga de donde venga (`kubectl`, operadores, GitOps) | Instantánea, en la escritura | Nada (salvo eludir el webhook) | Riesgo de disponibilidad |
| Auditoría en tiempo de ejecución / escaneo periódico | Recursos anteriores a la política | Horas | Nada | Barato |

La política solo en CI es el error más común. Valida los manifiestos a los que se le apuntó, en el estado en que el PR los dejó, bajo la suposición de que nada más escribe en el clúster. La política solo en admisión es el segundo error: los desarrolladores se enteran de la violación después del merge, cuando el reconciliador ya está reintentando en bucle. Ejecutá la política en CI **para el feedback** y en la admisión **para la aplicación**, desde la misma fuente de políticas.

### 6.1 Kyverno: verificar firmas de imagen en la admisión

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-provenance
  annotations:
    policies.kyverno.io/severity: critical
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  background: false
  rules:
    - name: require-cosign-keyless-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaceSelector:
                matchLabels:
                  acme.io/environment: prod
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/*"
          # Rewrite tag -> digest so the admitted spec is immutable.
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/acme/*/.github/workflows/release.yaml@refs/tags/v*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
    - name: require-slsa-provenance
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaceSelector:
                matchLabels:
                  acme.io/environment: prod
      verifyImages:
        - imageReferences:
            - "ghcr.io/acme/*"
          attestations:
            - type: https://slsa.dev/provenance/v1
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        subject: "https://github.com/slsa-framework/slsa-github-generator/*"
                        issuer: "https://token.actions.githubusercontent.com"
              conditions:
                - all:
                    - key: "{{ predicate.buildDefinition.buildType }}"
                      operator: Equals
                      value: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
                    - key: "{{ predicate.runDetails.builder.id }}"
                      operator: Equals
                      value: "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.0.0"
```

```console
$ kubectl -n prod-payments run rogue --image=docker.io/library/nginx:latest
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:

resource Pod/prod-payments/rogue was blocked due to the following policies

verify-image-provenance:
  require-cosign-keyless-signature: 'failed to verify image docker.io/library/nginx:latest:
    .attestors[0].entries[0].keyless: no signatures found'
```

### 6.2 Gatekeeper: restringir qué puede crear el reconciliador

```yaml
---
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
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("container <%v> has an untrusted image <%v>; allowed prefixes: %v",
                         [container.name, container.image, input.parameters.repos])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.repos[_]
                               good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("initContainer <%v> has an untrusted image <%v>",
                         [container.name, container.image])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: prod-registry-allowlist
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaceSelector:
      matchLabels:
        acme.io/environment: prod
  parameters:
    repos:
      - "ghcr.io/acme/"
      - "registry.k8s.io/"
```

```console
$ kubectl get k8sallowedrepos prod-registry-allowlist \
    -o jsonpath='{.status.totalViolations}'
0

$ kubectl get constraint -o custom-columns=\
'NAME:.metadata.name,ENFORCE:.spec.enforcementAction,VIOLATIONS:.status.totalViolations'
NAME                      ENFORCE   VIOLATIONS
prod-registry-allowlist   deny      0
```

### 6.3 Kyverno vs Gatekeeper para una plataforma GitOps

| | Kyverno | OPA Gatekeeper |
|---|---|---|
| Lenguaje de políticas | YAML (nativo de Kubernetes) | Rego |
| Curva de aprendizaje | Baja | Empinada, pero mucho más expresivo |
| Mutación | De primera clase (`mutate`, `mutateDigest`) | Assign/AssignMetadata (más nuevo, menos maduro) |
| Verificación de imágenes | Incorporada (`verifyImages`, cosign, atestaciones) | Requiere datos externos / proveedor `external_data` |
| Generación de recursos | Reglas `generate` (p. ej. NetworkPolicy por defecto por NS) | Solo expansión |
| Consultas entre objetos | `context` con consultas a la API | `data.inventory` (caché replicada) |
| CLI para CI | `kyverno apply -p policies/ -r manifests/` | `gator test` |
| Mejor encaje | Cadena de suministro + reglas con forma de Kubernetes | Política compleja, a nivel de organización, con mucha lógica |

Ejecutá las mismas políticas en CI para que el feedback llegue al PR:

```console
$ kyverno apply ./policies/ --resource ./rendered/prod.yaml --policy-report
Applying 6 policy(ies) to 41 resource(s)...

pass: 38, fail: 2, warn: 0, error: 0, skip: 1

policy: verify-image-provenance / require-cosign-keyless-signature
  FAIL  Pod/prod-payments/payments-7c9f8   image ghcr.io/acme/payments:dev-build not signed
policy: block-unmanaged-secrets / secrets-must-be-operator-owned
  FAIL  Secret/prod-payments/legacy-api-key
```

---

## 7. Observabilidad del bucle de reconciliación

### 7.1 Las cuatro preguntas

Todo stack de observabilidad de GitOps responde exactamente cuatro preguntas. Si tu panel no puede responder las cuatro en menos de treinta segundos, está incompleto.

1. **¿Es el estado declarado el estado en ejecución?** → estado de sincronización/deriva
2. **¿Está sano el estado en ejecución?** → salud de las cargas de trabajo, que *no* es lo mismo
3. **¿Cuánto hace que el bucle corrió realmente por última vez?** → liveness/obsolescencia, la que todo el mundo olvida
4. **¿Qué commit está corriendo, y quién lo firmó?** → atribución

Un punto sutil y relevante para el examen: **`Synced` + `Degraded` es un estado normal y esperado.** Significa "aplicamos con éxito exactamente lo que pediste, y lo que pediste está roto". Las herramientas de GitOps reportan estos dos ejes de forma independiente precisamente para que puedas distinguir "el pipeline falló" de "el cambio era malo".

### 7.2 Referencia de métricas de Flux

Todos los controladores de Flux exponen métricas de Prometheus en el puerto `8080` (`/metrics`) y salud en el `9440`.

| Métrica | Tipo | Etiquetas clave | Qué te dice |
|---|---|---|---|
| `gotk_reconcile_condition` | Gauge (0/1) | `kind`, `name`, `exported_namespace`, `type` (`Ready`\|`Reconciling`\|`Stalled`), `status` | La señal canónica de readiness para cada CR de Flux |
| `gotk_suspend_status` | Gauge (0/1) | `kind`, `name`, `exported_namespace` | Si la reconciliación está pausada deliberadamente |
| `gotk_resource_info` | Gauge (1) | `kind`, `name`, `revision`, `ready`, `suspended`, `url` | Flux ≥2.3: serie informativa que lleva la revisión — la mejor para "qué commit está vivo" |
| `controller_runtime_reconcile_total` | Counter | `controller`, `result` (`success`\|`error`\|`requeue`) | Rendimiento de reconciliación y tasa de errores |
| `controller_runtime_reconcile_errors_total` | Counter | `controller` | Tasa de errores duros |
| `controller_runtime_reconcile_time_seconds` | Histogram | `controller` | Distribución de la latencia de reconciliación |
| `workqueue_depth` | Gauge | `name` | Backlog — mantenerse >0 significa que el controlador está saturado |
| `workqueue_longest_running_processor_seconds` | Gauge | `name` | Una única reconciliación atascada |
| `rest_client_requests_total` | Counter | `code`, `method` | Presión sobre el API server y 429s |
| `go_memstats_alloc_bytes`, `process_cpu_seconds_total` | Gauge/Counter | — | Margen de recursos del controlador |

```console
$ kubectl -n flux-system port-forward deploy/kustomize-controller 8080:8080 >/dev/null 2>&1 &
$ curl -s localhost:8080/metrics | grep '^gotk_reconcile_condition' | sort | head -8
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="Deleted",type="Ready"} 0
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="False",type="Ready"} 0
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="True",type="Ready"} 1
gotk_reconcile_condition{kind="Kustomization",name="apps",namespace="flux-system",status="Unknown",type="Ready"} 0
gotk_reconcile_condition{kind="Kustomization",name="infra",namespace="flux-system",status="False",type="Ready"} 1
gotk_reconcile_condition{kind="Kustomization",name="infra",namespace="flux-system",status="True",type="Ready"} 0

$ curl -s localhost:8080/metrics | grep '^gotk_suspend_status'
gotk_suspend_status{kind="Kustomization",name="apps",namespace="flux-system"} 0
gotk_suspend_status{kind="Kustomization",name="infra",namespace="flux-system"} 0
gotk_suspend_status{kind="Kustomization",name="tenants",namespace="flux-system"} 1
```

> **La trampa de `exported_namespace`.** La métrica emite una etiqueta `namespace` que nombra el namespace del *objeto reconciliado*. Prometheus también adjunta una etiqueta `namespace` que identifica el namespace del pod del *target de scrapeo*. El comportamiento por defecto `honor_labels: false` renombra la original en conflicto a `exported_namespace`. Por lo tanto, cada regla de alerta que copies de upstream referenciará `exported_namespace`, y cada regla que escribas a partir de un `curl` crudo de `/metrics` referenciará `namespace` — y no coincidirá con nada, en silencio. Confirmá cuál produce tu Prometheus antes de escribir reglas:
>
> ```console
> $ curl -sG 'http://prometheus:9090/api/v1/series' \
>     --data-urlencode 'match[]=gotk_reconcile_condition' | jq -r '.data[0] | keys[]'
> __name__
> container
> endpoint
> exported_namespace
> instance
> job
> kind
> name
> namespace
> pod
> status
> type
> ```

### 7.3 Referencia de métricas de Argo CD

| Componente | Service / puerto | Métricas clave |
|---|---|---|
| application-controller | `argocd-metrics:8082` | `argocd_app_info`, `argocd_app_sync_total`, `argocd_app_reconcile` (histograma), `argocd_app_k8s_request_total`, `argocd_cluster_api_resource_objects`, `argocd_cluster_events_total`, `argocd_kubectl_exec_total` |
| api-server | `argocd-server-metrics:8083` | `argocd_redis_request_total`, `grpc_server_handled_total`, `argocd_proxy_extension_request_total` |
| repo-server | `argocd-repo-server:8084` | `argocd_git_request_total{request_type="ls-remote"\|"fetch"}`, `argocd_git_request_duration_seconds`, `argocd_repo_pending_request_total` |
| notifications-controller | `argocd-notifications-controller-metrics:9001` | `argocd_notifications_deliveries_total`, `argocd_notifications_trigger_eval_total` |
| applicationset-controller | `:8080` | `controller_runtime_*` |

```console
$ kubectl -n argocd port-forward svc/argocd-metrics 8082:8082 >/dev/null 2>&1 &
$ curl -s localhost:8082/metrics | grep '^argocd_app_info' | head -2
argocd_app_info{autosync_enabled="true",dest_namespace="payments",dest_server="https://kubernetes.default.svc",health_status="Healthy",name="payments",namespace="argocd",operation="",project="prod",repo="https://github.com/acme/platform-config",sync_status="Synced"} 1
argocd_app_info{autosync_enabled="false",dest_namespace="checkout",dest_server="https://kubernetes.default.svc",health_status="Degraded",name="checkout",namespace="argocd",operation="Sync",project="prod",repo="https://github.com/acme/platform-config",sync_status="OutOfSync"} 1

$ curl -s localhost:8082/metrics | grep '^argocd_app_sync_total'
argocd_app_sync_total{dest_server="https://kubernetes.default.svc",name="payments",namespace="argocd",phase="Succeeded",project="prod"} 341
argocd_app_sync_total{dest_server="https://kubernetes.default.svc",name="checkout",namespace="argocd",phase="Failed",project="prod"} 17
argocd_app_sync_total{dest_server="https://kubernetes.default.svc",name="checkout",namespace="argocd",phase="Error",project="prod"} 2
```

`autosync_enabled="false"` en una aplicación de producción es un hallazgo de *seguridad*, no solo operativo: significa que la deriva ya no se está corrigiendo y que el cambio manual con `kubectl` de alguien persistirá indefinidamente. Alertá sobre ello (§7.4).

### 7.4 Configuración de scrapeo y reglas de alerta

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: flux-controllers
  namespace: flux-system
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames: ["flux-system"]
  selector:
    matchExpressions:
      - key: app
        operator: In
        values:
          - source-controller
          - kustomize-controller
          - helm-controller
          - notification-controller
          - image-automation-controller
          - image-reflector-controller
  podMetricsEndpoints:
    - port: http-prom
      path: /metrics
      interval: 30s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_app]
          targetLabel: flux_controller
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: argocd
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
      interval: 30s
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-repo-server
  namespace: argocd
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
  endpoints:
    - port: metrics
      interval: 30s
```

Las reglas que importan. Notá las cuatro clases distintas de fallo: **fallando**, **suspendido**, **obsoleto** y **en thrashing** — un stack que solo alerta sobre la primera es el stack que se entera de las otras tres por un cliente.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-reconciliation
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: flux-reconciliation
      rules:
        # Failing AND not deleted. The "* 2 == 1" arithmetic is upstream's idiom:
        # a resource pending deletion also reports Ready=False, and paging on
        # a deliberate deletion is noise.
        - alert: FluxReconciliationFailure
          expr: |
            max by (exported_namespace, name, kind) (
              gotk_reconcile_condition{type="Ready",status="False"}
            )
            + on(exported_namespace, name, kind)
            (
              max by (exported_namespace, name, kind) (
                gotk_reconcile_condition{type="Deleted",status="True"}
              )
            ) * 2
            == 1
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "{{ $labels.kind }} {{ $labels.exported_namespace }}/{{ $labels.name }} has been failing for 10m"
            runbook_url: "https://runbooks.acme.io/gitops/reconciliation-failure"

        # Suspension is a legitimate operation that becomes an incident when forgotten.
        - alert: FluxResourceSuspendedTooLong
          expr: gotk_suspend_status == 1
          for: 24h
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.kind }} {{ $labels.exported_namespace }}/{{ $labels.name }} suspended for >24h — drift is not being corrected"

        # Staleness: the loop stopped without turning anything red.
        - alert: FluxReconcileStalled
          expr: |
            rate(controller_runtime_reconcile_total{controller=~"kustomization|gitrepository|helmrelease|ocirepository"}[15m]) == 0
          for: 30m
          labels:
            severity: critical
          annotations:
            summary: "Controller {{ $labels.controller }} has performed no reconciliations in 30m"

        - alert: FluxControllerAbsent
          expr: |
            absent(up{job=~".*flux.*"} == 1)
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "No Flux controller is being scraped — the observability of the loop is itself down"

        - alert: FluxReconcileLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum by (le, controller) (
                rate(controller_runtime_reconcile_time_seconds_bucket[10m])
              )
            ) > 60
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "p99 reconcile latency for {{ $labels.controller }} is {{ $value | humanizeDuration }}"

        - alert: FluxWorkqueueBacklog
          expr: workqueue_depth{name=~"kustomization|helmrelease|gitrepository"} > 20
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Workqueue {{ $labels.name }} depth {{ $value }} — controller is saturated"

    - name: argocd-reconciliation
      rules:
        - alert: ArgoCDAppOutOfSync
          expr: |
            argocd_app_info{sync_status!="Synced",project="prod"} == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Application {{ $labels.name }} is {{ $labels.sync_status }} for 15m"

        - alert: ArgoCDAppUnhealthy
          expr: |
            argocd_app_info{health_status=~"Degraded|Missing|Unknown",project="prod"} == 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "Application {{ $labels.name }} health is {{ $labels.health_status }}"

        # Drift correction silently disabled — a security control regression.
        - alert: ArgoCDAutoSyncDisabled
          expr: argocd_app_info{autosync_enabled="false",project="prod"} == 1
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Auto-sync disabled on prod application {{ $labels.name }} — drift will persist"

        - alert: ArgoCDSyncFailureRate
          expr: |
            sum by (name) (rate(argocd_app_sync_total{phase=~"Failed|Error"}[30m]))
              /
            clamp_min(sum by (name) (rate(argocd_app_sync_total[30m])), 1e-9)
              > 0.25
          for: 20m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.name }}: {{ $value | humanizePercentage }} of syncs failing"

        # Thrash detector: healthy sync rate far above the human change rate
        # means selfHeal is fighting something (HPA, mutating webhook, operator).
        - alert: ArgoCDSyncThrashing
          expr: sum by (name) (rate(argocd_app_sync_total{phase="Succeeded"}[10m])) * 600 > 20
          for: 20m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.name }} synced >20 times in 10m — probable drift fight"

        - alert: ArgoCDRepoServerGitErrors
          expr: |
            sum by (repo) (rate(argocd_git_request_total{request_type="ls-remote"}[10m])) > 5
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Excessive ls-remote against {{ $labels.repo }} — check webhook / polling interval"
```

### 7.5 SLOs para el plano de control de GitOps

Tratá al bucle como un servicio con sus propios SLIs. Estos son los cuatro que vale la pena definir:

| SLI | Definición | Boceto de consulta | Objetivo sugerido |
|---|---|---|---|
| **Ratio de éxito de reconciliación** | reconciliaciones exitosas ÷ total | `sum(rate(controller_runtime_reconcile_total{result="success"}[28d])) / sum(rate(controller_runtime_reconcile_total[28d]))` | ≥ 99.0% |
| **Latencia de sincronización (merge → aplicado)** | p95 de segundos desde el timestamp del commit hasta `Ready=True` en la nueva revisión | Requiere exportar la hora del commit; aproximá con `histogram_quantile(0.95, ...reconcile_time_seconds_bucket)` + intervalo de poll | p95 < 5 min |
| **MTTR de deriva** | tiempo que un recurso pasa en `OutOfSync` antes de la corrección | `avg_over_time(argocd_app_info{sync_status="OutOfSync"}[1h])` × ventana | p95 < 3 min |
| **Liveness del bucle** | fracción del tiempo en que ocurrió al menos una reconciliación por cada 15 min | `avg_over_time((rate(controller_runtime_reconcile_total[15m]) > bool 0)[28d:15m])` | ≥ 99.9% |

Estos se agregan hacia las métricas DORA que el negocio realmente pregunta — la frecuencia de despliegue es `rate(argocd_app_sync_total{phase="Succeeded"}[1d])`, y la tasa de fallo de cambios es el ratio de sincronizaciones seguidas de un rollback o de una transición a `Degraded` en menos de 30 minutos.

```console
$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=sum(rate(controller_runtime_reconcile_total{result="success"}[7d])) / sum(rate(controller_runtime_reconcile_total[7d]))' \
    | jq -r '.data.result[0].value[1]'
0.9973118279569892

$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=histogram_quantile(0.95, sum by (le) (rate(controller_runtime_reconcile_time_seconds_bucket{controller="kustomization"}[6h])))' \
    | jq -r '.data.result[0].value[1]'
3.8421052631578947
```

### 7.6 Notificación dirigida por eventos (la vía rápida)

Las métricas son para tendencias y SLOs; los eventos son para "este cambio concreto falló, acá está el commit". Ambos, no uno u otro.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: slack-webhook
  namespace: flux-system
type: Opaque
stringData:
  address: https://hooks.slack.com/services/T000/B000/XXXXXXXX   # via SOPS/ESO in reality
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-platform
  namespace: flux-system
spec:
  type: slack
  channel: platform-alerts
  secretRef:
    name: slack-webhook
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: on-call-errors
  namespace: flux-system
spec:
  providerRef:
    name: slack-platform
  eventSeverity: error
  eventSources:
    - kind: GitRepository
      namespace: flux-system
      name: '*'
    - kind: OCIRepository
      namespace: flux-system
      name: '*'
    - kind: Kustomization
      namespace: '*'
      name: '*'
    - kind: HelmRelease
      namespace: '*'
      name: '*'
  # Suppress transient chatter that resolves on the next interval.
  exclusionList:
    - "waiting for the .* to be ready"
    - "dependency .* is not ready"
  suspend: false
---
# Commit-status write-back: the PR that introduced a bad manifest turns red.
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: github-status
  namespace: flux-system
spec:
  type: github
  address: https://github.com/acme/platform-config
  secretRef:
    name: github-token
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: github-commit-status
  namespace: flux-system
spec:
  providerRef:
    name: github-status
  eventSeverity: info
  eventSources:
    - kind: Kustomization
      namespace: flux-system
      name: apps
---
# Push-triggered reconciliation: latency drops from the poll interval to seconds.
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-webhook
  namespace: flux-system
spec:
  type: github
  events: ["ping", "push"]
  secretRef:
    name: webhook-token       # key "token" -> the HMAC shared secret
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: platform-config
      namespace: flux-system
```

```console
$ kubectl -n flux-system create secret generic webhook-token \
    --from-literal=token="$(head -c 32 /dev/urandom | base64)"
secret/webhook-token created

$ kubectl -n flux-system get receiver github-webhook \
    -o jsonpath='{.status.webhookPath}'
/hook/7d1f9ac5b4e2f0c831a6d94e5b7c20fa3e8d6194b2c7f05a83d1e4b96c7025af
```

Registrá `https://flux-webhook.acme.io<webhookPath>` en el forge. El token HMAC es lo que impide que un host de internet no autenticado fuerce una reconciliación a demanda — el receiver rechaza payloads sin firmar, así que el endpoint puede ser público.

El equivalente de Argo CD:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: $slack-token
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
  trigger.on-health-degraded: |
    - when: app.status.health.status == 'Degraded'
      send: [app-health-degraded]
  trigger.on-sync-status-unknown: |
    - when: app.status.sync.status == 'Unknown'
      send: [app-sync-failed]
  template.app-sync-failed: |
    message: |
      :x: *{{.app.metadata.name}}* sync {{.app.status.operationState.phase}}
      Revision: {{.app.status.operationState.syncResult.revision}}
      Author:   {{.app.status.operationState.operation.initiatedBy.username}}
      Message:  {{.app.status.operationState.message}}
      <{{.context.argocdUrl}}/applications/{{.app.metadata.name}}|Open in Argo CD>
  template.app-health-degraded: |
    message: |
      :warning: *{{.app.metadata.name}}* is Degraded on revision {{.app.status.sync.revision}}
  subscriptions: |
    - recipients: [slack:platform-alerts]
      triggers: [on-sync-failed, on-health-degraded, on-sync-status-unknown]
      selector: argocd.argoproj.io/notified!=true
```

### 7.7 El rastro de auditoría: Git más el API server, no Git a solas

"Git es el log de auditoría" es cierto solo para los cambios que pasaron por Git. Los cambios hechos directamente contra el API server — por un humano, un operador o el propio reconciliador — quedan registrados en el **log de auditoría de Kubernetes**, y correlacionar ambos es lo que produce una narrativa completa.

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Full request+response for everything the GitOps agents write.
  - level: RequestResponse
    users:
      - system:serviceaccount:flux-system:kustomize-controller
      - system:serviceaccount:flux-system:helm-controller
      - system:serviceaccount:argocd:argocd-application-controller
    verbs: ["create", "update", "patch", "delete"]

  # Impersonated tenant identities — this is where escalation attempts appear.
  - level: RequestResponse
    userGroups: ["system:serviceaccounts"]
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Any human writing directly to a prod namespace is, by definition, drift.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    namespaces: ["payments", "checkout"]
    omitStages: ["RequestReceived"]

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  - level: None
    users: ["system:kube-scheduler", "system:kube-controller-manager"]

  - level: Metadata
```

Respondiendo a "¿quién cambió esto, y pasó por Git?":

```console
$ kubectl -n payments get deploy payments \
    -o jsonpath='{.metadata.annotations}' | jq
{
  "deployment.kubernetes.io/revision": "42",
  "kustomize.toolkit.fluxcd.io/name": "payments",
  "kustomize.toolkit.fluxcd.io/namespace": "flux-system",
  "fluxcd.io/reconcileAt": "2026-08-18T09:41:02Z"
}

$ kubectl -n flux-system get kustomization payments \
    -o jsonpath='{.status.lastAppliedRevision}'
v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93

$ git log -1 --show-signature 9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
commit 9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
gpg: Signature made Mon 18 Aug 2026 09:33:11 AM CEST
gpg:                using RSA key 3CF6A1B4C0DE9A17
gpg: Good signature from "ACME Release Bot <release@acme.io>" [ultimate]
Author: ACME Release Bot <release@acme.io>
Date:   Mon Aug 18 09:33:11 2026 +0200

    feat(payments): raise connection pool to 40 (#1187)
```

`flux trace` condensa toda esa cadena en un solo comando:

```console
$ flux trace --kind Deployment --api-version apps/v1 --name payments --namespace payments

Object:          Deployment/payments
Namespace:       payments
Status:          Managed by Flux
---
Kustomization:   payments
Namespace:       flux-system
Path:            ./clusters/prod/payments
Revision:        v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
Status:          Last reconciled at 2026-08-18 09:41:02 +0200 CEST
Message:         Applied revision: v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
---
GitRepository:   platform-config
Namespace:       flux-system
URL:             ssh://git@github.com/acme/platform-config
Tag:             v1.4.2
Revision:        v1.4.2@sha1:9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
Status:          Last reconciled at 2026-08-18 09:40:55 +0200 CEST
Message:         stored artifact for revision 'v1.4.2@sha1:9f3c2ab...'
```

Un objeto que devuelve "Status: Unmanaged by Flux" mientras vive en un namespace propiedad de GitOps es o bien deriva o bien un hueco de política. Ambas cosas son hallazgos.

---

## 8. Verificación y diagnóstico de fallos

### 8.1 La comprobación previa al vuelo

```console
$ flux check
► checking prerequisites
✔ Kubernetes 1.31.4 >=1.30.0-0
► checking version in cluster
✔ distribution: flux-v2.4.0
✔ bootstrapped: true
► checking controllers
✔ helm-controller: deployment ready
► ghcr.io/fluxcd/helm-controller:v1.1.0
✔ kustomize-controller: deployment ready
► ghcr.io/fluxcd/kustomize-controller:v1.4.0
✔ notification-controller: deployment ready
► ghcr.io/fluxcd/notification-controller:v1.4.0
✔ source-controller: deployment ready
► ghcr.io/fluxcd/source-controller:v1.4.1
► checking crds
✔ alerts.notification.toolkit.fluxcd.io/v1beta3
✔ buckets.source.toolkit.fluxcd.io/v1
✔ gitrepositories.source.toolkit.fluxcd.io/v1
✔ helmreleases.helm.toolkit.fluxcd.io/v2
✔ kustomizations.kustomize.toolkit.fluxcd.io/v1
✔ ocirepositories.source.toolkit.fluxcd.io/v1beta2
✔ receivers.notification.toolkit.fluxcd.io/v1
✔ all checks passed
```

```console
$ argocd admin app get-reconcile-results --l 'argocd.argoproj.io/instance' -o results.yaml
$ kubectl -n argocd get application -o custom-columns=\
'NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision'
NAME       PROJECT   SYNC       HEALTH     REV
payments   prod      Synced     Healthy    9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
checkout   prod      OutOfSync  Degraded   9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
grafana    infra     Synced     Healthy    9f3c2ab7d1e0854b3c6f21a9e7d40b8c5a2f1e93
```

### 8.2 Taxonomía de fallos

| # | Síntoma | Causa más probable | Primer comando | Solución |
|---|---|---|---|---|
| F1 | `Ready=False`, `unable to clone` | Deploy key mala/expirada; `known_hosts` ausente | `kubectl -n flux-system logs deploy/source-controller \| grep -i clone` | Recrear el secret de autenticación; volver a añadir la deploy key |
| F2 | `Ready=False`, `object not signed by a trusted key` | Clave de firma rotada / no está en la lista de permitidos | `flux get sources git -A` | Añadir la nueva clave pública al secret de verificación |
| F3 | `Decryption failed ... no identity matched` | Clave age/KMS equivocada para este clúster | `kubectl get secret sops-age -o ... \| age-keygen -y` | Instalar la clave privada correcta |
| F4 | `is forbidden: User "system:serviceaccount:..." cannot ...` | La SA impersonada carece del permiso (normalmente el comportamiento correcto) | `kubectl auth can-i <verb> <res> --as=<sa>` | Otorgar de forma acotada, o rechazar el manifiesto |
| F5 | `OutOfSync` para siempre, `Synced` nunca se alcanza | Falta `ignoreDifferences`; un webhook mutante reescribe el objeto | `argocd app diff <app>` | Añadir `ignoreDifferences` o `managedFieldsManagers` |
| F6 | Contador de sincronizaciones subiendo, recurso oscilando | Pelea de deriva: HPA contra `replicas` declaradas | `kubectl -n <ns> get events --sort-by=.lastTimestamp` | Quitar `replicas` del manifiesto |
| F7 | `Synced` + `Degraded` | El manifiesto es correcto, la carga de trabajo está rota | `kubectl -n <ns> describe pod ...` | Bug de la aplicación — revertir el commit |
| F8 | `Progressing` para siempre | `wait: true` + `healthChecks` sobre un objeto que nunca queda listo | `flux -n <ns> get kustomization <k>` | Arreglar el readiness probe o el objetivo del health check |
| F9 | No pasa nada al hacer push | El webhook no se dispara; `suspend: true` | `flux get all -A \| grep True` (columna suspended) | `flux resume`; verificar el token/path del Receiver |
| F10 | Métricas ausentes en Prometheus | Etiquetas del ServiceMonitor no coinciden; una NetworkPolicy bloquea el scrapeo | `kubectl get servicemonitor -A -o yaml \| grep release` | Hacer coincidir el `serviceMonitorSelector` de Prometheus |
| F11 | Las alertas nunca se disparan | La regla usa `namespace` donde Prometheus emite `exported_namespace` | Consultar la serie en la UI de Prometheus | Corregir el nombre de la etiqueta |
| F12 | La `Kustomization` falla, `no matches for kind` | El CRD todavía no se aplicó (orden) | `flux tree kustomization flux-system` | Poner `dependsOn` sobre la Kustomization del CRD |
| F13 | CPU del repo-server al máximo, sincronizaciones lentas | Intervalo de polling demasiado bajo con muchas apps | Tasa de `argocd_git_request_total` | Habilitar webhooks; subir `timeout.reconciliation` |
| F14 | Prune eliminó algo inesperado | El recurso perdió su etiqueta de Flux/Argo, o cambió de ruta | Log de auditoría para el delete | Restaurar desde Git; usar `prune: false` mientras se migra |

### 8.3 Escenario A — el bucle que se detuvo sin ponerse en rojo

```console
$ flux get kustomizations -A
NAMESPACE  	NAME       	REVISION                     	SUSPENDED	READY	MESSAGE
flux-system	apps       	main@sha1:4b81ff0            	False    	True 	Applied revision: main@sha1:4b81ff0
flux-system	flux-system	main@sha1:4b81ff0            	False    	True 	Applied revision: main@sha1:4b81ff0
flux-system	infra      	main@sha1:4b81ff0            	False    	True 	Applied revision: main@sha1:4b81ff0
```

Todo en verde — pero `main` en el forge está en `7c19d3a`, once commits por delante. La `Kustomization` está en `Ready=True` porque la última vez *aplicó* con éxito; el fallo está aguas arriba, en la fuente:

```console
$ flux get sources git -A
NAMESPACE  	NAME           	REVISION         	SUSPENDED	READY	MESSAGE
flux-system	platform-config	main@sha1:4b81ff0	False    	False	failed to checkout and determine revision: unable to list remote for 'ssh://git@github.com/acme/platform-config': ssh: handshake failed: knownhosts: key mismatch

$ kubectl -n flux-system get gitrepository platform-config \
    -o jsonpath='{.status.artifact.lastUpdateTime}'
2026-08-07T11:22:41Z          # eleven days stale
```

El forge rotó su host key. La `Kustomization` nunca se enteró porque solo consume el artefacto, y un artefacto obsoleto sigue siendo un artefacto válido.

```console
$ ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null > /tmp/known_hosts
$ kubectl -n flux-system create secret generic platform-config-auth \
    --from-file=identity=/dev/stdin \
    --from-file=known_hosts=/tmp/known_hosts \
    --dry-run=client -o yaml < <(kubectl -n flux-system get secret platform-config-auth -o jsonpath='{.data.identity}' | base64 -d) \
    | kubectl apply -f -
secret/platform-config-auth configured

$ flux reconcile source git platform-config
► annotating GitRepository platform-config in flux-system namespace
✔ GitRepository annotated
◎ waiting for GitRepository reconciliation
✔ fetched revision main@sha1:7c19d3a
```

**La lección, y la razón por la que `FluxReconcileStalled` existe en §7.4:** nunca construyas un panel de GitOps solo sobre `Ready`. Añadí la frescura de la fuente — `time() - gotk_resource_info` de última actualización, o simplemente alertá sobre la propia condición `Ready` del `GitRepository`, que es una serie distinta de la de la `Kustomization`.

### 8.4 Escenario B — `OutOfSync` permanente por culpa de un webhook mutante

```console
$ argocd app get checkout
Name:               argocd/checkout
Sync Status:        OutOfSync from main (9f3c2ab)
Health Status:      Healthy

GROUP  KIND        NAMESPACE  NAME      STATUS     HEALTH   MESSAGE
apps   Deployment  checkout   checkout  OutOfSync  Healthy

$ argocd app diff checkout
===== apps/Deployment checkout/checkout ======
28c28
<       - name: istio-proxy
<         image: docker.io/istio/proxyv2:1.24.1
---
>   (absent)
```

El service mesh inyecta un sidecar después de la admisión. Argo CD ve un contenedor que no declaró y reporta deriva para siempre. La solución correcta — declarar el ignore, no deshabilitar el self-heal:

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: checkout
  namespace: argocd
spec:
  project: prod
  source:
    repoURL: https://github.com/acme/platform-config
    targetRevision: main
    path: apps/checkout/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: checkout
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
      - RespectIgnoreDifferences=true      # honour ignores during SYNC too, not just diff
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
  ignoreDifferences:
    # Sidecar injected by the mesh admission webhook.
    - group: apps
      kind: Deployment
      name: checkout
      jsonPointers:
        - /spec/template/spec/containers/1
    # Replica count owned by the HPA, not by Git.
    - group: apps
      kind: Deployment
      name: checkout
      jsonPointers:
        - /spec/replicas
    # Preferred modern form: defer to whichever manager owns the field.
    - group: apps
      kind: Deployment
      managedFieldsManagers:
        - istio-sidecar-injector
        - kube-controller-manager
```

> **`RespectIgnoreDifferences=true` es la opción que la gente pasa por alto.** Sin ella, `ignoreDifferences` afecta solo a lo que el *diff* muestra; la sincronización sigue empujando el valor declarado, así que `selfHeal` arranca el sidecar en cada ciclo. La app se ve bien en el panel y los pods se reinician cada pocos minutos.

Verificalo con la propiedad de campos de server-side apply — la respuesta definitiva a "quién es dueño de este campo":

```console
$ kubectl -n checkout get deploy checkout --show-managed-fields -o json \
    | jq '.metadata.managedFields[] | {manager, operation, fields: (.fieldsV1 | keys)}'
{
  "manager": "kustomize-controller",
  "operation": "Apply",
  "fields": ["f:metadata", "f:spec"]
}
{
  "manager": "kube-controller-manager",
  "operation": "Update",
  "fields": ["f:spec"]
}
{
  "manager": "istio-sidecar-injector",
  "operation": "Update",
  "fields": ["f:spec"]
}
```

### 8.5 Escenario C — deriva inyectada fuera de banda, y su corrección

```console
$ kubectl -n payments scale deploy/payments --replicas=12
deployment.apps/payments scaled

$ kubectl -n payments get deploy payments -o jsonpath='{.spec.replicas}'
12

# ... one reconcile interval later ...
$ kubectl -n payments get deploy payments -o jsonpath='{.spec.replicas}'
4

$ kubectl -n flux-system get events --field-selector involvedObject.name=payments \
    --sort-by=.lastTimestamp | tail -3
LAST SEEN   TYPE     REASON              OBJECT                   MESSAGE
2m14s       Normal   Progressing         kustomization/payments   Deployment/payments/payments configured
2m14s       Normal   ReconciliationSucceeded  kustomization/payments   Reconciliation finished in 1.42s, next run in 10m
```

Ahora la pregunta de seguridad que el examen realmente hace: **¿quién lo hizo?** El reconciliador corrigió la deriva, lo cual está bien, pero corregir sin atribuir significa que un atacante que va tanteando obtiene intentos gratuitos ilimitados.

```console
$ kubectl get --raw '/api/v1/namespaces/payments/events' >/dev/null   # events are already gone (1h TTL)

$ jq -c 'select(.objectRef.resource=="deployments"
         and .objectRef.name=="payments"
         and .verb=="patch"
         and (.user.username | startswith("system:") | not))
         | {t:.requestReceivedTimestamp, user:.user.username, groups:.user.groups, sub:.objectRef.subresource}' \
    /var/log/kubernetes/audit.log | tail -2
{"t":"2026-08-18T10:14:02.881Z","user":"jorge@acme.io","groups":["acme:team-a","system:authenticated"],"sub":"scale"}
```

Dos seguimientos, ambos obligatorios: revocar la vía de escritura directa (`jorge@acme.io` no debería tener `patch` sobre Deployments de producción), y añadir una alerta `DirectWriteToGitOpsNamespace` alimentada por los logs de auditoría. La reconciliación continua hace que el cambio no autorizado sea *transitorio*; no lo hace *visible*. El logging de auditoría es lo que lo hace visible.

### 8.6 Escenario D — el reconciliador está bien, la observabilidad no

```console
$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=gotk_reconcile_condition' | jq '.data.result | length'
0

$ kubectl -n flux-system get svc -l app.kubernetes.io/part-of=flux
No resources found in flux-system namespace.
```

No hay ningún `Service` delante de los controladores de Flux — la instalación de upstream expone las métricas directamente en los pods. Por lo tanto, un `ServiceMonitor` nunca coincidirá con nada; necesitás un `PodMonitor` (§7.4). Confirmá que el selector realmente resuelve:

```console
$ kubectl -n flux-system get pods -l app=kustomize-controller \
    -o jsonpath='{.items[0].spec.containers[0].ports}' | jq
[
  {"containerPort": 8080, "name": "http-prom", "protocol": "TCP"},
  {"containerPort": 9440, "name": "healthz", "protocol": "TCP"}
]

$ kubectl apply -f podmonitor-flux.yaml
podmonitor.monitoring.coreos.com/flux-controllers created

$ kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
    -o jsonpath='{.spec.podMonitorSelector}' | jq
{ "matchLabels": { "release": "kube-prometheus-stack" } }
# -> the PodMonitor must carry release: kube-prometheus-stack, and it does.

$ curl -sG 'http://prometheus.monitoring:9090/api/v1/query' \
    --data-urlencode 'query=count(gotk_reconcile_condition)' | jq -r '.data.result[0].value[1]'
248
```

Confirmá también que el scrapeo no está bloqueado por la NetworkPolicy que escribiste en §4.5 — esa política cubre solo el egress, pero una denegación de ingress correspondiente en `flux-system` rompería silenciosamente el scrapeo dejando la reconciliación perfectamente sana. Este modo de fallo es el que produce el "no teníamos alertas, así que pensamos que estaba todo bien".

### 8.7 Lista de verificación de seguridad (ejecutable)

```bash
#!/usr/bin/env bash
# gitops-audit.sh — assert the controls of domain 4.1 are actually in place.
set -euo pipefail
fail=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

check "No plaintext Secret manifests in the repo" \
  '! grep -rlE "^kind:[[:space:]]*Secret$" clusters/ apps/ 2>/dev/null | xargs -r grep -L "^sops:" | grep -q .'

check "Every Kustomization impersonates a ServiceAccount" \
  '[ "$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq "[.items[] | select(.spec.serviceAccountName == null)] | length")" -eq 0 ]'

check "Cross-namespace source refs are disabled" \
  'kubectl -n flux-system get deploy kustomize-controller -o yaml | grep -q -- "--no-cross-namespace-refs=true"'

check "Reconciler cannot create ClusterRoleBindings as a tenant" \
  '! kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:team-a:team-a-reconciler -q'

check "Git source enforces signature verification" \
  '[ "$(kubectl get gitrepositories.source.toolkit.fluxcd.io -A -o json | jq "[.items[] | select(.spec.verify == null)] | length")" -eq 0 ]'

check "No repository is configured as insecure" \
  '! kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository -o json | jq -r ".items[].data.insecure // empty" | base64 -d 2>/dev/null | grep -q true'

check "Argo CD local admin account is disabled" \
  '[ "$(kubectl -n argocd get cm argocd-cm -o jsonpath="{.data.admin\.enabled}")" = "false" ]'

check "Argo CD default RBAC policy denies" \
  '[ -z "$(kubectl -n argocd get cm argocd-rbac-cm -o jsonpath="{.data.policy\.default}")" ]'

check "Nothing is left suspended" \
  '[ "$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io -A -o json | jq "[.items[] | select(.spec.suspend == true)] | length")" -eq 0 ]'

check "Flux metrics are reaching Prometheus" \
  '[ "$(curl -sG http://prometheus.monitoring:9090/api/v1/query --data-urlencode "query=count(gotk_reconcile_condition)" | jq -r ".data.result[0].value[1] // 0")" -gt 0 ]'

check "Reconciliation alert rules are loaded" \
  'curl -s http://prometheus.monitoring:9090/api/v1/rules | jq -e ".data.groups[].rules[] | select(.name==\"FluxReconciliationFailure\")" >/dev/null'

exit "$fail"
```

```console
$ ./gitops-audit.sh
PASS  No plaintext Secret manifests in the repo
PASS  Every Kustomization impersonates a ServiceAccount
PASS  Cross-namespace source refs are disabled
PASS  Reconciler cannot create ClusterRoleBindings as a tenant
FAIL  Git source enforces signature verification
PASS  No repository is configured as insecure
PASS  Argo CD local admin account is disabled
PASS  Argo CD default RBAC policy denies
FAIL  Nothing is left suspended
PASS  Flux metrics are reaching Prometheus
PASS  Reconciliation alert rules are loaded
$ echo $?
1
```

---

## 9. Puntos clave

- **El acceso de escritura al repo es acceso de escritura a producción.** La protección de ramas, la revisión obligatoria y la firma son controles de gestión de cambios, no preferencias de experiencia de desarrollo.
- **La firma es el único control de autenticidad dentro del clúster.** Todo lo demás en el forge puede ser deshabilitado por un administrador del repo sin que el clúster se entere jamás. Aplicá `verify` sobre la fuente (Flux) o `signatureKeys` sobre el proyecto (Argo CD).
- **Un reconciliador con `cluster-admin` convierte el acceso al repo en cluster-admin.** Impersoná una ServiceAccount por tenant y forzalo con `--default-service-account`; en Argo CD, usá las listas de permitidos/denegados de `AppProject` y aceptá que la multi-tenencia hostil suele significar instancias separadas.
- **Secretos: cifrá para el material de bootstrap, referenciá para todo lo demás.** SOPS/SealedSecrets para lo que debe existir antes que los operadores; External Secrets para todo lo posterior, porque la rotación sin commit es la propiedad que importa.
- **La política pertenece a CI *y* a la admisión.** CI da feedback, la admisión da aplicación; ninguna por sí sola cubre el bypass de la otra.
- **`Synced` ≠ `Healthy` ≠ `Fresh`.** Tres ejes independientes, tres alertas independientes. El tercero — la frescura — es el que produce caídas silenciosas de varias semanas.
- **Alertá sobre la suspensión y sobre el auto-sync deshabilitado.** Ambas son operaciones legítimas que se convierten en deriva no monitorizada cuando se olvidan.
- **La reconciliación hace que el cambio no autorizado sea transitorio; solo el log de auditoría lo hace visible.** Correlacioná `lastAppliedRevision` → commit → firma, y registrá las escrituras directas a los namespaces propiedad de GitOps.
- **Cuidado con `exported_namespace`.** La razón individual más común por la que una alerta de Flux que se ve correcta nunca se dispara.

---

## Referencias

**CNCF / examen**
- Currículo CGOA — https://github.com/cncf/curriculum/blob/master/cgoa/README.md
- Linux Foundation, certificación CGOA — https://training.linuxfoundation.org/certification/certified-gitops-associate-cgoa/
- Principios de OpenGitOps v1.0.0 — https://opengitops.dev/
- Glosario del CNCF GitOps WG — https://github.com/open-gitops/documents/blob/main/GLOSSARY.md

**Flux**
- Documentación de seguridad — https://fluxcd.io/flux/security/
- Multi-tenencia y aislamiento de tenants — https://fluxcd.io/flux/installation/configuration/multitenancy/
- API de `GitRepository` (incluido `spec.verify`) — https://fluxcd.io/flux/components/source/gitrepositories/
- API de `OCIRepository` y verificación con cosign — https://fluxcd.io/flux/components/source/ocirepositories/
- API de `Kustomization` (`serviceAccountName`, `decryption`) — https://fluxcd.io/flux/components/kustomize/kustomizations/
- Gestión de secretos con SOPS — https://fluxcd.io/flux/guides/mozilla-sops/
- Monitorización con Prometheus y Grafana — https://fluxcd.io/flux/monitoring/metrics/
- Reglas de alerta y `gotk_reconcile_condition` — https://fluxcd.io/flux/monitoring/alerts/
- `Alert` / `Provider` / `Receiver` del notification controller — https://fluxcd.io/flux/components/notification/
- Receptores de webhook — https://fluxcd.io/flux/guides/webhook-receivers/
- `flux trace` — https://fluxcd.io/flux/cmd/flux_trace/

**Argo CD**
- Visión general de seguridad y hardening — https://argo-cd.readthedocs.io/en/stable/operator-manual/security/
- Configuración de RBAC — https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Proyectos (`AppProject`) — https://argo-cd.readthedocs.io/en/stable/user-guide/projects/
- Verificación de firmas GnuPG — https://argo-cd.readthedocs.io/en/stable/user-guide/gpg-verification/
- Referencia de métricas — https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
- Personalización del diffing / `ignoreDifferences` — https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- Opciones de sincronización (`ServerSideApply`, `RespectIgnoreDifferences`) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- Notificaciones — https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/

**Secretos y cadena de suministro**
- External Secrets Operator — https://external-secrets.io/latest/
- Sealed Secrets — https://github.com/bitnami-labs/sealed-secrets
- SOPS — https://github.com/getsops/sops
- age — https://github.com/FiloSottile/age
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- gitsign — https://docs.sigstore.dev/cosign/signing/gitsign/
- Especificación SLSA v1.0 — https://slsa.dev/spec/v1.0/
- Buenas prácticas de cadena de suministro de software del CNCF — https://github.com/cncf/tag-security/blob/main/community/resources/software-supply-chain-security/secure-software-factory/secure-software-factory.md

**Política y plataforma**
- Verificación de imágenes con Kyverno — https://kyverno.io/docs/policy-types/cluster-policy/verify-images/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- RBAC de Kubernetes — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Auditoría en Kubernetes — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Server-Side Apply y gestión de campos — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- `PodMonitor` / `ServiceMonitor` de Prometheus Operator — https://prometheus-operator.dev/docs/api-reference/api/