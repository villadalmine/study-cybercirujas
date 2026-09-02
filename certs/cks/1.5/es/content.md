# 1.5 Verificar los binarios de la plataforma antes de desplegar

## Por qué esto importa

Todos los componentes del control plane, el kubelet, `kubectl`, `kubeadm`, los plugins CNI y las imágenes de contenedor que los respaldan son *código ejecutable corriendo con privilegios muy altos*. Un binario `kubelet` manipulado se adueña de cada nodo donde corre. Una imagen `kube-apiserver` manipulada se adueña del clúster entero.

La amenaza realista no es que alguien rompa TLS en `dl.k8s.io` — es la larga cola de la cadena de entrega:

- un mirror interno o un proxy de artefactos (Nexus, Artifactory, un bucket S3) sobre el que alguien puede escribir,
- un script de instalación "cómodo" pasado por curl a `bash` desde un post de blog,
- una imagen base o un chart de Helm traído de un registry público que sufrió typosquatting o el compromiso de una cuenta,
- un pipeline de build que inyecta código entre el código fuente y el artefacto (el patrón SolarWinds / `xz-utils`).

La verificación es el control barato que rompe todos estos casos: **nunca ejecutás un byte que no hayas podido atar a un publicador en el que confiás.**

Hay tres niveles crecientes de garantía, y deberías conocer los tres para el examen:

| Nivel | Mecanismo | Responde la pregunta |
|---|---|---|
| 1 | Checksum (`sha256sum` / `sha512sum`) | "¿Llegaron los bytes intactos / son los bytes que listó el publicador?" |
| 2 | Firma digital (cosign/sigstore, GPG) | "¿Quién produjo estos bytes, y puede negarlo?" |
| 3 | Procedencia + SBOM | "¿Cómo se construyeron estos bytes, y qué hay adentro?" |

Un checksum publicado en el *mismo* servidor que el artefacto no prueba casi nada frente a un atacante que controla ese servidor. Solo una firma (nivel 2) ata el artefacto a una identidad.

---

## Anclas de confianza para los artefactos de Kubernetes

| Artefacto | Fuente canónica |
|---|---|
| Binarios (`kubectl`, `kubelet`, `kubeadm`, `kube-apiserver`, …) | `https://dl.k8s.io/release/<version>/bin/<os>/<arch>/<binary>` |
| Checksum por binario | misma URL + `.sha256` |
| Firma / certificado por binario | misma URL + `.sig` y `.cert` |
| Tarballs + listado sha512 | `CHANGELOG/CHANGELOG-1.34.md` en `kubernetes/kubernetes` |
| Imágenes de contenedor | `registry.k8s.io/<component>:<version>` (firmadas con cosign) |
| SBOM | `https://sbom.k8s.io/<version>/release` |
| Paquetes de la distro | `https://pkgs.k8s.io/core:/stable:/v1.34/{deb,rpm}/` |

Prestá atención a los hostnames `registry.k8s.io` / `dl.k8s.io`: el viejo registry `k8s.gcr.io` está congelado. Cualquier cosa que todavía traiga imágenes de ahí es un hallazgo en sí mismo.

---

## Nivel 1 — Verificación por checksum

El flujo de trabajo cotidiano, y el que más probablemente aparezca como tarea de examen:

```bash
KUBE_VERSION=v1.34.0
ARCH=linux/amd64

curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/${ARCH}/kubectl"
curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/${ARCH}/kubectl.sha256"

echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

```
kubectl: OK
```

Si el archivo fue modificado en tránsito o en disco:

```
kubectl: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
```

`sha256sum --check` devuelve un **código de salida distinto de cero** ante una falla, que es lo que querés dentro de un script de instalación:

```bash
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check || { rm -f kubectl; exit 1; }
```

Hacerlo a ojo (útil cuando solo tenés el hash, no un archivo `.sha256`):

```bash
sha256sum kubectl
```
```
3a1b7f0c9e5d8a2f4b6c1d0e9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b  kubectl
```

La misma idea para los tarballs de release, que usan SHA-512:

```bash
curl -LO "https://dl.k8s.io/${KUBE_VERSION}/kubernetes-server-linux-amd64.tar.gz"
sha512sum kubernetes-server-linux-amd64.tar.gz
# compare against the value listed in CHANGELOG-1.34.md
```

### Verificar un binario que ya está instalado

Este es el escenario "un intruso puede haber cambiado un binario en este nodo". Calculá el hash de lo que hay en disco y compará con upstream:

```bash
sha256sum /usr/local/bin/kubelet
curl -sL "https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubelet.sha256"
```

Dos trampas frecuentes:

1. **Desfasaje de versión.** Calculá el hash de la versión que está realmente instalada, no de la más nueva: `kubelet --version`, `kubectl version --client`, `kubeadm version -o short`.
2. **Binarios reempaquetados.** Si el nodo se instaló desde los repos comunitarios `deb`/`rpm`, los binarios entregados son los builds de release de upstream y normalmente coinciden — pero una distribución de proveedor (EKS, GKE, OpenShift, Rancher) los recompila, así que los hashes de upstream *no* van a coincidir por diseño. Verificá esos contra los hashes publicados por el proveedor, o contra el gestor de paquetes (más abajo).

---

## Nivel 2 — Verificación de firmas con cosign

Desde v1.26 **todos** los artefactos de release de Kubernetes — binarios, tarballs e imágenes — se firman con cosign de [Sigstore](https://sigstore.dev/) en modo *keyless*: la identidad firmante es un certificado de vida corta emitido para la identidad OIDC de la automatización de release y registrado en el log público de transparencia Rekor. No hay clave privada de larga vida para robar.

### Un binario de release

```bash
BINARY=kubectl
VERSION=v1.34.0
URL="https://dl.k8s.io/release/${VERSION}/bin/linux/amd64"

curl -sSLO "${URL}/${BINARY}"
curl -sSLO "${URL}/${BINARY}.sig"
curl -sSLO "${URL}/${BINARY}.cert"

cosign verify-blob "${BINARY}" \
  --signature "${BINARY}.sig" \
  --certificate "${BINARY}.cert" \
  --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com
```

```
Verified OK
```

### Una imagen de release

```bash
cosign verify registry.k8s.io/kube-apiserver:v1.34.0 \
  --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com
```

```
Verification for registry.k8s.io/kube-apiserver:v1.34.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

Puntos clave para internalizar:

- `--certificate-identity` y `--certificate-oidc-issuer` son **obligatorios** en cosign v2. Omitirlos significa "aceptar una firma de cualquiera", que es peor que no verificar. El string exacto de identidad difiere entre binarios e imágenes y puede cambiar entre releases — tomalo de la página oficial *Verify Signed Kubernetes Artifacts* para el release en el que estés.
- La verificación contacta el log de transparencia Rekor por defecto. En un entorno air-gapped usá `--insecure-ignore-tlog` más una raíz TUF replicada localmente, y entendé que estás resignando la propiedad "¿esta firma fue alguna vez pública?".
- Para tus propias imágenes, el equivalente con un par de claves es:

```bash
cosign generate-key-pair                       # cosign.key + cosign.pub
cosign sign --key cosign.key myregistry.io/app@sha256:<digest>
cosign verify --key cosign.pub myregistry.io/app@sha256:<digest>
```

---

## Nivel 3 — Gestores de paquetes, SBOMs y procedencia

### Paquetes de la distro

Los repos comunitarios están firmados con GPG; `apt`/`dnf` verifican los metadatos del repositorio automáticamente, siempre que hayas instalado el keyring:

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

Verificá un RPM individual antes de instalarlo, y verificá los archivos instalados después:

```bash
rpm --checksig kubeadm-1.34.0-150500.1.1.x86_64.rpm
# kubeadm-1.34.0-...x86_64.rpm: digests signatures OK

rpm --verify kubelet        # empty output = no file has been modified
```

El equivalente en Debian para detectar desviaciones:

```bash
debsums -c kubelet          # lists only files whose checksum changed
```

`rpm --verify` / `debsums -c` son excelentes victorias rápidas durante un incidente: te dicen qué archivos en disco ya no coinciden con lo que instaló el paquete.

### SBOM

Cada release incluye un SBOM SPDX, así que podés responder "¿este componente embebe la biblioteca vulnerable?" sin desempaquetar nada:

```bash
curl -sL https://sbom.k8s.io/v1.34.0/release -o k8s-v1.34.0.spdx
grep -i 'name: golang.org/x/net' k8s-v1.34.0.spdx
```

O traer el SBOM adjunto a una imagen:

```bash
cosign download sbom registry.k8s.io/kube-apiserver:v1.34.0
```

---

## Fijá por digest, no por tag

Un checksum que verificaste al momento de instalar no vale nada si después la carga de trabajo trae un tag mutable. Los tags son punteros; **los digests son direccionables por contenido e inmutables**.

```yaml
# Bad: :latest, and even :v1.34.0 can be re-pushed
image: registry.k8s.io/kube-apiserver:v1.34.0

# Good
image: registry.k8s.io/kube-apiserver@sha256:0f6a3b0e3d7c9b1a5e2d4c8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b
```

Inspeccioná lo que realmente está corriendo en un nodo:

```bash
kubectl get pod kube-apiserver-controlplane -n kube-system \
  -o jsonpath='{.status.containerStatuses[*].imageID}{"\n"}'
```
```
registry.k8s.io/kube-apiserver@sha256:0f6a3b0e3d7c9b1a5e2d4c8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b
```

```bash
crictl images --digests
crictl inspecti registry.k8s.io/kube-apiserver:v1.34.0
```

Si el digest del `imageID` en ejecución no coincide con el digest que firmaste y aprobaste, algo cambió la imagen detrás del tag.

## Hacelo cumplir, no solo lo verifiques

La verificación manual no escala. Empujala hacia el control de admisión para que las imágenes no verificadas sean rechazadas en el API server:

```yaml
# Kyverno: only admit images signed by our key
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "myregistry.io/*"
          mutateDigest: true      # rewrites the tag to the resolved digest
          required: true
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

`mutateDigest: true` es la parte subestimada: resuelve el tag a un digest en el momento de la admisión, así que el pod queda fijado permanentemente a la imagen exacta que fue verificada. Los equivalentes son Gatekeeper/OPA con un proveedor de datos externo, el `policy-controller` de Sigstore, o el plugin de admisión `ImagePolicyWebhook` incorporado.

## Charts de Helm y herramientas de terceros

Los charts también son código. Helm soporta archivos de procedencia (`.prov`) firmados con GPG:

```bash
helm package --sign --key 'release@example.com' --keyring ~/.gnupg/secring.gpg ./mychart
helm verify mychart-1.2.3.tgz
helm install myrel mychart-1.2.3.tgz --verify
```

```
Signed by: Release Bot <release@example.com>
Using Key With Fingerprint: 8F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A
Chart Hash Verified: sha256:9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d
```

La misma disciplina aplica a los plugins de `kubectl` de Krew, a los tarballs de plugins CNI, a los releases de `etcd` (firmados también con cosign), a `crictl`, y a cualquier instalador `curl … | bash` — reemplazá el pipe por descargar → verificar → ejecutar.

## Errores comunes

- **Confiar en un checksum servido desde el mismo host comprometido que el artefacto.** Usá firmas para cualquier cosa que importe.
- **`cosign verify` sin los flags de identidad** (o con una expresión regular comodín) — acepta cualquier firma Sigstore válida de cualquiera.
- **Verificar la descarga pero instalar desde caché**, o verificar `v1.34.0` mientras el nodo corre `v1.33.4`.
- **Fijar un tag y llamarlo inmutable.** Solo los digests son inmutables.
- **Ignorar el código de salida** en la automatización — siempre `set -euo pipefail` y dejá que `sha256sum --check` haga fallar el build.
- **Verificar solo al momento de instalar.** Re-chequeá con `rpm --verify` / `debsums` y compará los digests de `imageID` en ejecución como parte de la auditoría rutinaria de nodos.

## Checklist rápida de examen

```bash
# 1. Hash a suspect binary and compare with upstream
sha256sum /usr/bin/kubectl
curl -sL https://dl.k8s.io/release/$(kubectl version --client -o json \
  | jq -r .clientVersion.gitVersion)/bin/linux/amd64/kubectl.sha256

# 2. One-shot verify of a fresh download
echo "$(curl -sL .../kubectl.sha256)  kubectl" | sha256sum --check

# 3. Signature check
cosign verify-blob kubectl --signature kubectl.sig --certificate kubectl.cert \
  --certificate-identity <identity> --certificate-oidc-issuer <issuer>

# 4. What is really running
kubectl get pods -n kube-system -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' | sort -u

# 5. Which installed files drifted from their package
rpm -Va | grep -E 'kube|etcd'      # or: debsums -c
```

---

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Verify Signed Kubernetes Artifacts — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/
- Install and Set Up kubectl on Linux (checksum validation) — https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Installing kubeadm (community package repositories) — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Kubernetes Downloads and release artifacts — https://kubernetes.io/releases/download/
- Kubernetes SBOM — https://kubernetes.io/docs/reference/issues-security/official-cve-feed/ y https://sbom.k8s.io/
- Kubernetes Images and image pull policy — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes Software Supply Chain Best Practices (CNCF TAG Security) — https://github.com/cncf/tag-security/blob/main/community/working-groups/supply-chain-security/supply-chain-security-paper/CNCF_SSCP_v1.pdf
- Sigstore cosign documentation — https://docs.sigstore.dev/cosign/signing/overview/
- cosign `verify` / `verify-blob` reference — https://github.com/sigstore/cosign/blob/main/doc/cosign_verify.md
- Kyverno — Verify Image Signatures — https://kyverno.io/docs/writing-policies/verify-images/
- Helm — Provenance and Integrity — https://helm.sh/docs/topics/provenance/
- Kubernetes Admission Controllers Reference (`ImagePolicyWebhook`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook