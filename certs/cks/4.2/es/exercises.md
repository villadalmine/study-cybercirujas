# CKS 4.2 — Entendé tu cadena de suministro (SBOM, CI/CD, repositorios de artefactos)

**Examen:** CKS v1.34 · **Dominio:** Supply Chain Security (20%) · **Peso del tema:** 5

---

## Alcance y modelo mental

Una cadena de suministro de Kubernetes es la cadena de custodia entre *una línea de código fuente* y *un proceso corriendo en un contenedor con el token de la ServiceAccount de tu clúster montado*. Cada salto de esa cadena es un lugar donde un atacante puede inyectar código sin tocar tu clúster:

```text
  source          build            artifact             admission          runtime
  ------          -----            --------             ---------          -------
  git repo  -->   CI runner  -->   registry (OCI)  -->  kube-apiserver --> kubelet
     |               |                  |                     |               |
  commit          builder            tag is             does this image   was the layer
  signing?        identity?          MUTABLE            match policy?     pulled or reused
  branch          secrets            digest is          signature?        from node cache?
  protection      exfil?             immutable          registry allow?
```

Los cuatro artefactos que vas a manipular en estos ejercicios:

| Artefacto | Formato | Responde a la pregunta |
|---|---|---|
| **SBOM** | SPDX / CycloneDX | *¿Qué hay adentro de esta imagen?* |
| **Reporte de vulnerabilidades** | JSON de Grype/Trivy, SARIF | *¿Cuál de esas cosas es hoy conocida-como-mala?* |
| **Procedencia / attestation** | in-toto, SLSA, sobre DSSE | *¿Quién la construyó, desde qué fuente, en qué máquina?* |
| **Firma** | `.sig` de cosign en el registry | *¿Es este el artefacto que esa entidad realmente aprobó?* |

Un SBOM por sí solo no prueba nada — es un archivo de texto sin firmar. La propiedad de seguridad recién aparece cuando el SBOM está **ligado a un digest de imagen** y **firmado**, y cuando el clúster **rechaza** imágenes que carecen de esa ligadura.

---

## Requisitos previos

Un clúster de un solo nodo o kubeadm donde tengas **root en el nodo del plano de control** (vas a editar manifiestos de static pods), más estas herramientas de CLI.

```bash
# 1. Verify you can reach the cluster and are cluster-admin.
kubectl version -o yaml | grep -E 'gitVersion'
kubectl auth can-i '*' '*' --all-namespaces

# 2. Install the supply-chain toolbelt (Linux amd64).
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh  | sh -s -- -b /usr/local/bin
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin
curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
curl -sSfLO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
go install github.com/google/go-containerregistry/cmd/crane@latest 2>/dev/null || \
  curl -sSfL https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin crane

# 3. Confirm.
syft version; grype version; trivy --version; cosign version; crane version
```

```bash
# 4. A local registry to push to, so the exercises do not depend on Docker Hub rate limits.
docker run -d --restart=always -p 5000:5000 --name registry registry:2
export REG=localhost:5000
crane catalog $REG    # empty on a fresh registry, exits 0
```

> **Nota de examen.** En el examen *no* vas a instalar herramientas. `syft`, `grype`, `trivy`, `cosign` y `crane` pueden estar o no estar; lo que siempre está es `kubectl`, `crictl`, `docker`/`podman`, y el manifiesto del API server en `/etc/kubernetes/manifests/kube-apiserver.yaml`. Los ejercicios 6, 7 y 10 son los que mapean directamente sobre tareas de examen.

---

## Ejercicio 1 — Medí y reducí la superficie de ataque de una imagen

**Objetivo:** entender *por qué* la minimización de imágenes es un control de cadena de suministro, no una optimización de rendimiento, y cuantificarla.

1. Escribí una aplicación y un Dockerfile deliberadamente ingenuos.

```bash
mkdir -p ~/sc-lab/app && cd ~/sc-lab/app
cat > main.go <<'EOF'
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	http.ListenAndServe(":8080", nil)
}
EOF
cat > go.mod <<'EOF'
module example.com/healthz

go 1.22
EOF
```

2. Construí la variante "gorda" — la forma con la que arrancan la mayoría de los pipelines reales.

```bash
cat > Dockerfile.fat <<'EOF'
FROM golang:1.22
WORKDIR /src
COPY . .
RUN go build -o /healthz ./main.go
EXPOSE 8080
CMD ["/healthz"]
EOF

docker build -f Dockerfile.fat -t $REG/healthz:fat .
```

3. Construí la variante minimizada: multi-stage, binario estático, base distroless, non-root, sin shell.

```bash
cat > Dockerfile.slim <<'EOF'
# ---- build stage: never shipped ----
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# CGO_ENABLED=0 removes the dynamic link against glibc, so the runtime
# layer needs no libc at all.
RUN CGO_ENABLED=0 GOFLAGS=-trimpath go build -ldflags="-s -w" -o /healthz ./main.go

# ---- runtime stage: pinned by digest, not by tag ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /healthz /healthz
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/healthz"]
EOF

docker build -f Dockerfile.slim -t $REG/healthz:slim .
```

4. Compará tamaño y cantidad de capas.

```bash
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep healthz
```

```text
REPOSITORY:TAG                 SIZE
localhost:5000/healthz:fat     1.24GB
localhost:5000/healthz:slim    6.61MB
```

5. Compará la cantidad de *paquetes* — el número de cosas que pueden recibir un CVE.

```bash
syft scan docker:$REG/healthz:fat  -o table | tail -n 3
syft scan docker:$REG/healthz:slim -o table
```

```text
# fat  (abridged) …
[1194 packages]

# slim
NAME                 VERSION   TYPE
healthz              (devel)   go-module
stdlib               go1.22.5  go-module
base-files           12.4      deb
netbase              6.4       deb
tzdata               2024a-3   deb
```

6. Comprobá que la imagen minimizada no tiene punto de apoyo interactivo.

```bash
docker run --rm -it --entrypoint sh  $REG/healthz:slim || echo "no shell -> exit $?"
docker run --rm -it --entrypoint /bin/ls $REG/healthz:slim || echo "no coreutils"
```

7. Hacé push de ambas, así los ejercicios posteriores tienen sobre qué trabajar.

```bash
docker push $REG/healthz:fat
docker push $REG/healthz:slim
```

### Preguntas de verificación — bloque 1

- **Q1.1** La imagen `fat` contiene el toolchain de Go, `git`, `apt` y un shell completo. Nombrá tres capacidades *distintas* de post-explotación que eso le da a un atacante que logra RCE dentro del contenedor, y que la imagen `slim` le niega.
- **Q1.2** ¿Por qué importa `CGO_ENABLED=0` para la elección entre `distroless/static` y `distroless/base`?
- **Q1.3** Un colega argumenta que distroless es "teatro de seguridad" porque un atacante puede subir su propio busybox por la red. Dale el contraargumento más fuerte, y después decí el único control a nivel Kubernetes que hace que esa objeción sea genuinamente débil.
- **Q1.4** La imagen de la etapa de build `golang:1.22` tenía 1194 paquetes, varios con CVEs críticos. ¿Aparecen esos CVEs en el SBOM de la imagen `slim`? ¿Importan en absoluto?

---

## Ejercicio 2 — Generá un SBOM en ambos formatos estándar

**Objetivo:** producir documentos SPDX y CycloneDX, y leer los campos que realmente cargan significado de seguridad.

1. Resolvé el tag a un digest inmutable **primero**. Cada artefacto que produzcas de acá en adelante se refiere al digest, nunca al tag.

```bash
export IMG_TAG=$REG/healthz:slim
export IMG_DIGEST=$(crane digest $IMG_TAG)
export IMG=$REG/healthz@$IMG_DIGEST
echo "$IMG"
```

```text
localhost:5000/healthz@sha256:4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281
```

2. Generá un SBOM SPDX 2.3 en JSON con syft.

```bash
syft scan registry:$IMG -o spdx-json=sbom.spdx.json
jq '{spdxVersion, name, creationInfo: .creationInfo.creators, packages: (.packages|length)}' sbom.spdx.json
```

```text
{
  "spdxVersion": "SPDX-2.3",
  "name": "localhost:5000/healthz@sha256:4d1e2b7c...",
  "creationInfo": [ "Organization: Anchore, Inc", "Tool: syft-1.x.x" ],
  "packages": 5
}
```

3. Generá un SBOM CycloneDX 1.6, e inspeccioná la **ligadura al sujeto** — el campo que ata el documento a una imagen específica.

```bash
syft scan registry:$IMG -o cyclonedx-json=sbom.cdx.json
jq '.metadata.component | {type, name, version}' sbom.cdx.json
jq '.metadata.component.hashes' sbom.cdx.json
```

4. Generá lo mismo con Trivy, y diffeá los inventarios. Que dos escáneres no coincidan es normal y es en sí mismo una lección.

```bash
trivy image --format cyclonedx --output trivy.cdx.json $IMG
jq -r '.components[]? | "\(.name)@\(.version)"' sbom.cdx.json  | sort > /tmp/syft.txt
jq -r '.components[]? | "\(.name)@\(.version)"' trivy.cdx.json | sort > /tmp/trivy.txt
diff /tmp/syft.txt /tmp/trivy.txt || true
```

5. Mirá qué registra un SBOM para un *archivo* que ningún gestor de paquetes instaló.

```bash
# Inject a vendored binary with no package metadata.
cat > Dockerfile.blind <<'EOF'
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=busybox:1.36 /bin/busybox /opt/vendor/busybox
COPY --from=build /healthz /healthz
ENTRYPOINT ["/healthz"]
EOF
docker build -f Dockerfile.slim -t healthz-build --target build .
docker build -f Dockerfile.blind -t $REG/healthz:blind --build-context build=docker-image://healthz-build . 2>/dev/null \
  || echo "if buildx contexts are unavailable, copy busybox in manually and rebuild"

syft scan docker:$REG/healthz:blind -o table | grep -i busybox || echo "busybox NOT catalogued"
```

6. Habilitá los catalogadores a nivel de archivo y re-escaneá.

```bash
syft scan docker:$REG/healthz:blind \
  --select-catalogers '+binary-classifier-cataloger' -o table | grep -i busybox
```

```text
busybox   1.36.1   binary
```

### Preguntas de verificación — bloque 2

- **Q2.1** ¿Cuál es el campo más importante de un SBOM desde el punto de vista de la *verificación*, y qué le pasa al valor del documento si falta?
- **Q2.2** Syft y Trivy produjeron listas de componentes distintas para el mismo digest. ¿Cuál está "bien", y qué te dice el desacuerdo sobre consumir SBOMs como entrada de política?
- **Q2.3** El escaneo por defecto se perdió el `busybox` vendorizado. Describí la clase de ataque de cadena de suministro que habilita ese punto ciego, y dos maneras en que un pipeline puede cerrarlo.
- **Q2.4** Generaste el SBOM desde `registry:$IMG` en vez de `docker:$REG/healthz:slim`. Dame una razón de seguridad para preferir la fuente registry sobre la fuente del daemon local en CI.
- **Q2.5** SPDX o CycloneDX — ¿cuál elegirías para un pipeline cuyo objetivo principal es el cumplimiento de licencias, y cuál para uno cuyo objetivo principal es el triaje de vulnerabilidades guiado por VEX? Justificá brevemente.

---

## Ejercicio 3 — Consumí el SBOM: escaneo, gating y VEX

**Objetivo:** convertir el inventario en una decisión que rompe el build, y aprender por qué un conteo crudo de CVEs es un mal gate.

1. Escaneá el *archivo SBOM*, no la imagen. Esto es lo que hace un servicio de política — nunca necesita acceso al registry.

```bash
grype sbom:./sbom.spdx.json -o table
```

```text
NAME     INSTALLED  FIXED-IN  TYPE       VULNERABILITY   SEVERITY
stdlib   go1.22.5   1.22.7    go-module  GHSA-xxxx-xxxx  High
```

2. Ahora escaneá la imagen gorda para contrastar, y hacé que la corrida *falle* por severidad.

```bash
syft scan docker:$REG/healthz:fat -o spdx-json=fat.spdx.json
grype sbom:./fat.spdx.json --fail-on critical -q -o table | head -n 15; echo "exit=$?"
```

3. Restringí el gate a lo que es accionable — vulnerabilidades con fix disponible.

```bash
grype sbom:./fat.spdx.json --only-fixed --fail-on high -o table | wc -l
```

4. Hacé lo mismo con Trivy, tanto desde el SBOM como directo, y emití SARIF para la UI de CI.

```bash
trivy sbom sbom.cdx.json --severity HIGH,CRITICAL --exit-code 1
trivy image --scanners vuln,secret,misconfig --severity HIGH,CRITICAL \
             --format sarif --output trivy.sarif $IMG
jq -r '.runs[0].results | length' trivy.sarif
```

5. Suprimí una vulnerabilidad que analizaste como no explotable, usando OpenVEX en vez de un ignore general.

```bash
cat > vex.json <<'EOF'
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "https://example.com/vex/healthz-2026-08-03",
  "author": "platform-security@example.com",
  "timestamp": "2026-08-03T10:00:00Z",
  "version": 1,
  "statements": [
    {
      "vulnerability": { "name": "CVE-2024-24790" },
      "products": [
        { "@id": "pkg:oci/healthz@sha256%3A4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281" }
      ],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path"
    }
  ]
}
EOF

trivy image --vex vex.json --severity HIGH,CRITICAL $IMG
```

6. Compará contra la alternativa a la que recurren los equipos bajo presión de fecha límite.

```bash
cat > .trivyignore <<'EOF'
CVE-2024-24790
EOF
trivy image --severity HIGH,CRITICAL $IMG
```

### Preguntas de verificación — bloque 3

- **Q3.1** `grype sbom:./sbom.spdx.json` y `grype registry:$IMG` pueden devolver resultados distintos para la misma imagen el mismo día. Dame dos razones independientes.
- **Q3.2** Un gate de pipeline se define como "fallar si existe cualquier CRITICAL". Explicá por qué ese gate degenera de forma confiable en un sello de goma, y propone una definición de gate que no lo haga.
- **Q3.3** ¿Qué afirma `.trivyignore`, y qué afirma la declaración OpenVEX `not_affected` / `vulnerable_code_not_in_execute_path`? ¿Por qué le importa la diferencia a un auditor?
- **Q3.4** Tu SBOM se generó en tiempo de build en enero. En agosto se publica un CVE nuevo contra un paquete listado en él. ¿Hace falta regenerar el SBOM? ¿Qué *sí* hay que volver a correr, y dónde debería correr?

---

## Ejercicio 4 — Los tags son mutables; los digests no

**Objetivo:** reproducir un ataque de mutación de tag contra una carga de trabajo viva y detectarlo desde adentro del clúster.

1. Desplegá una carga de trabajo que referencia un **tag**.

```bash
kubectl create ns supply
cat > tagged.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: healthz
  namespace: supply
spec:
  replicas: 1
  selector:
    matchLabels: { app: healthz }
  template:
    metadata:
      labels: { app: healthz }
    spec:
      containers:
      - name: app
        image: localhost:5000/healthz:slim
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
EOF
kubectl apply -f tagged.yaml
kubectl -n supply rollout status deploy/healthz
```

2. Registrá qué está corriendo realmente. Notá la distinción entre `spec…image` (lo que pediste) y `status…imageID` (lo que el kubelet resolvió).

```bash
kubectl -n supply get pods -o custom-columns=\
'POD:.metadata.name,SPEC:.spec.containers[*].image,RESOLVED:.status.containerStatuses[*].imageID'
```

```text
POD                       SPEC                            RESOLVED
healthz-7c9d5f8b6-2xk4q   localhost:5000/healthz:slim     localhost:5000/healthz@sha256:4d1e2b7c...
```

3. Mutá el tag. Esto es exactamente lo que hace un atacante con acceso de escritura al registry — o un job de CI comprometido.

```bash
crane copy $REG/healthz:fat $REG/healthz:slim     # the tag now points somewhere else
crane digest $REG/healthz:slim                   # different from $IMG_DIGEST
```

4. Dispará un evento de aspecto benigno: un reinicio de nodo, un desalojo, un scale-up de HPA. Simulalo con un rollout restart.

```bash
kubectl -n supply rollout restart deploy/healthz
kubectl -n supply rollout status deploy/healthz
kubectl -n supply get pods -o custom-columns=\
'POD:.metadata.name,SPEC:.spec.containers[*].image,RESOLVED:.status.containerStatuses[*].imageID'
```

```text
POD                       SPEC                            RESOLVED
healthz-6b4f9c7d5-p8m2r   localhost:5000/healthz:slim     localhost:5000/healthz@sha256:9f3c1a...
```

Nada cambió en el Deployment. El código en ejecución sí.

5. Escribí el detector de deriva a nivel de clúster — la consulta que encuentra cada carga de trabajo cuya imagen declarada no está fijada por digest.

```bash
kubectl get pods -A -o json | jq -r '
  .items[] |
  . as $p |
  ($p.spec.containers + ($p.spec.initContainers // []))[] |
  select(.image | contains("@sha256:") | not) |
  "\($p.metadata.namespace)/\($p.metadata.name)\t\(.image)"
' | sort -u | head
```

6. Repará el Deployment fijándolo a un digest.

```bash
kubectl -n supply set image deploy/healthz app=$REG/healthz@$IMG_DIGEST
kubectl -n supply get deploy healthz -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Preguntas de verificación — bloque 4

- **Q4.1** En el paso 4, el `spec` del Deployment era idéntico byte a byte antes y después, y sin embargo corrió código distinto. ¿Qué campo de Kubernetes habría revelado el cambio, y por qué `spec.containers[].image` es insuficiente para auditoría?
- **Q4.2** Con `imagePullPolicy: IfNotPresent` y un tag mutado, ¿qué determina si un nodo dado corre el código viejo o el nuevo? ¿Cuál es la consecuencia de seguridad de ese no-determinismo?
- **Q4.3** Un pod se agenda en un nodo que ya tiene una imagen privada en su caché local. El namespace del pod no tiene ningún `imagePullSecret` para ese registry. ¿Arranca el contenedor? ¿Qué plugin de admisión cambia la respuesta, y cómo?
- **Q4.4** Fijar por digest hace que los rollouts sean inmunes a la mutación de tags pero introduce un costo operativo. ¿Cuál es, y qué componente del pipeline normalmente lo absorbe?

---

## Ejercicio 5 — Firmá la imagen y adjuntá el SBOM como attestation

**Objetivo:** ligar el SBOM al digest criptográficamente, para que el clúster pueda verificar una afirmación en vez de confiar en un archivo.

1. Generá un par de claves. En CI usarías keyless/OIDC en su lugar — paso 6.

```bash
cd ~/sc-lab/app
COSIGN_PASSWORD="" cosign generate-key-pair
ls cosign.key cosign.pub
```

2. Firmá el **digest**, nunca el tag.

```bash
COSIGN_PASSWORD="" cosign sign --key cosign.key --tlog-upload=false --yes $IMG
```

3. Observá dónde vive físicamente la firma: es un artefacto OCI común y corriente en el mismo repositorio.

```bash
cosign triangulate $IMG
crane ls $REG/healthz
```

```text
localhost:5000/healthz:sha256-4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281.sig
fat
slim
sha256-4d1e2b7c....sig
```

4. Verificá, y leé el payload.

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true $IMG | jq '.[0].critical'
```

```text
{
  "identity": { "docker-reference": "localhost:5000/healthz" },
  "image": { "docker-manifest-digest": "sha256:4d1e2b7c..." },
  "type": "cosign container image signature"
}
```

5. Adjuntá el SBOM como una attestation in-toto firmada, después verificala y extraé de vuelta el predicado.

```bash
COSIGN_PASSWORD="" cosign attest --key cosign.key --tlog-upload=false --yes \
  --predicate sbom.spdx.json --type spdxjson $IMG

cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson $IMG \
  | jq -r '.payload' | base64 -d | jq '{_type, predicateType, subject: .subject[0].digest}'
```

```text
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://spdx.dev/Document",
  "subject": { "sha256": "4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281" }
}
```

6. Demostrá que la ligadura es a prueba de manipulación: atestiguá una imagen *distinta* con el *mismo* SBOM y mirá el desajuste de sujeto.

```bash
FAT=$REG/healthz@$(crane digest $REG/healthz:fat)
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type spdxjson $FAT
```

```text
Error: no matching attestations: ...
```

7. Inspeccioná qué produce la firma keyless, conceptualmente — la identidad reemplaza a la clave.

```bash
# In a GitHub Actions job with `id-token: write`, this needs no secret at all:
#   cosign sign --yes $IMG
# and verification pins the *workflow identity*, not a public key:
cat <<'EOF'
cosign verify \
  --certificate-identity-regexp '^https://github.com/acme/healthz/\.github/workflows/release\.yaml@refs/tags/v.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/acme/healthz@sha256:...
EOF
```

8. Agregá procedencia de build con buildx, para que la imagen cargue "quién me construyó, desde qué commit".

```bash
docker buildx build -f Dockerfile.slim \
  --provenance=mode=max --sbom=true \
  -t $REG/healthz:attested --push .
crane manifest $REG/healthz:attested | jq '.manifests[] | {mediaType, "predicate": .annotations["vnd.docker.reference.type"]}'
```

### Preguntas de verificación — bloque 5

- **Q5.1** `cosign sign` no modificó la imagen. ¿Dónde se guarda la firma, y qué implica eso si hacés `crane copy` de la imagen a otro registry con una copia simple?
- **Q5.2** Explicá la diferencia de confianza entre la firma basada en claves y la firma keyless. ¿Cuál es más difícil para un atacante que roba el disco de un runner de CI, y por qué?
- **Q5.3** En el paso 6, la verificación falló. ¿Qué campo del statement in-toto hizo posible esa falla, y qué ataque previene?
- **Q5.4** Se usó `--insecure-ignore-tlog=true` en todo el ejercicio. ¿Contra qué protege realmente el log de transparencia (Rekor), y qué capacidad perdés al deshabilitarlo?
- **Q5.5** Una firma verificada dice "el poseedor de esta clave aprobó este digest". Listá dos preguntas importantes de cadena de suministro que una firma válida **no** responde.

---

## Ejercicio 6 — Aplicá política en el clúster con `ImagePolicyWebhook`

**Objetivo:** configurar el plugin de admisión del API server que el examen CKS tiene más probabilidad de pedir. Tomá un **snapshot/backup del manifiesto antes de empezar** — un error acá detiene el API server.

1. Respaldá el manifiesto del API server y preparé el directorio de configuración.

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
sudo mkdir -p /etc/kubernetes/admission
```

2. Escribí el `AdmissionConfiguration` que apunta el plugin a un backend.

```bash
sudo tee /etc/kubernetes/admission/admission-config.yaml >/dev/null <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: ImagePolicyWebhook
  configuration:
    imagePolicy:
      kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
      # Cache TTLs, in seconds.
      allowTTL: 50
      denyTTL: 50
      retryBackoff: 500
      # false == fail CLOSED. If the backend is unreachable, DENY.
      defaultAllow: false
EOF
```

3. Escribí el kubeconfig que el API server usa para *llamar* al webhook. Notá que acá el API server actúa como cliente, con su propio certificado de cliente.

```bash
sudo tee /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: image-checker
  cluster:
    certificate-authority: /etc/kubernetes/admission/webhook-ca.crt
    server: https://image-checker.supply-chain.svc:443/check
contexts:
- name: image-checker
  context:
    cluster: image-checker
    user: api-server
current-context: image-checker
preferences: {}
users:
- name: api-server
  user:
    client-certificate: /etc/kubernetes/admission/apiserver-client.crt
    client-key: /etc/kubernetes/admission/apiserver-client.key
EOF
```

4. Editá el manifiesto del static pod. Se requieren tres cambios separados — omitir cualquiera de ellos es la falla clásica.

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    # (a) enable the plugin — keep the plugins that were already there
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
    # (b) point it at the config
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
    volumeMounts:
    # (c) the config must be visible INSIDE the static pod
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
  volumes:
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

5. Esperá a que el kubelet reinicie el static pod y confirmá que los flags surtieron efecto.

```bash
until kubectl get --raw /healthz >/dev/null 2>&1; do echo waiting; sleep 3; done
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -E 'admission'
```

6. Observá el comportamiento fail-closed sin ningún backend desplegado.

```bash
kubectl -n supply run probe --image=$REG/healthz:slim --restart=Never
```

```text
Error from server (Forbidden): pods "probe" is forbidden: Post "https://image-checker.supply-chain.svc:443/check": dial tcp: lookup image-checker.supply-chain.svc: no such host
```

7. Entendé el contrato de red. Esto es lo que el API server hace POST y lo que tu backend debe responder.

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "spec": {
    "containers": [ { "image": "localhost:5000/healthz:slim" } ],
    "annotations": { "policy.image-policy.k8s.io/break-glass": "INC-4417" },
    "namespace": "supply"
  }
}
```

```json
{
  "apiVersion": "imagepolicy.k8s.io/v1alpha1",
  "kind": "ImageReview",
  "status": { "allowed": false, "reason": "image is not digest-pinned" }
}
```

8. Restaurá el clúster a un estado funcional antes de continuar.

```bash
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw /healthz >/dev/null 2>&1; do sleep 3; done
kubectl get --raw /healthz
```

### Preguntas de verificación — bloque 6

- **Q6.1** Configuraste `--enable-admission-plugins` y `--admission-control-config-file` correctamente, reiniciaste, y el API server levanta pero nunca se llama al webhook. ¿Cuál es la causa más probable, y cómo la confirmás en diez segundos?
- **Q6.2** `defaultAllow: false` bloqueó un pod. En un clúster de producción, describí la secuencia concreta de fallas que convierte esta configuración en una caída de todo el clúster, y la mitigación que mantiene la semántica fail-closed sin ese riesgo.
- **Q6.3** El contenedor del API server no volvió en absoluto después de tu edición. ¿Dónde buscás el error, dado que `kubectl` ya no funciona?
- **Q6.4** Las anotaciones de pod con prefijo `*.image-policy.k8s.io/*` se reenvían al backend. ¿Por qué una anotación "break-glass" es un riesgo de escalada de privilegios, y cómo la contenés?
- **Q6.5** `ImageReview` sigue siendo `v1alpha1`. Dame dos razones por las que una plataforma de producción elegiría en su lugar un controlador basado en `ValidatingWebhookConfiguration`, y una razón por la que `ImagePolicyWebhook` sigue valiendo la pena conocer.

---

## Ejercicio 7 — Restringí repositorios de artefactos con `ValidatingAdmissionPolicy`

**Objetivo:** aplicar "solo imágenes de registries aprobados, fijadas por digest" con **ningún componente externo** — el mecanismo in-tree basado en CEL, GA desde 1.30.

1. Escribí la política. Cubrí `initContainers` y `ephemeralContainers`, no solo `containers` — es acá donde se filtran la mayoría de las políticas escritas a mano.

```bash
cat > vap-registry.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: approved-registries
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  variables:
  - name: allowedPrefixes
    expression: "['registry.internal.example.com/', 'localhost:5000/']"
  - name: allImages
    expression: >-
      object.spec.containers.map(c, c.image) +
      (has(object.spec.initContainers) ? object.spec.initContainers.map(c, c.image) : []) +
      (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers.map(c, c.image) : [])
  validations:
  - expression: >-
      variables.allImages.all(i,
        variables.allowedPrefixes.exists(p, i.startsWith(p)))
    messageExpression: >-
      'image from an unapproved registry; allowed prefixes: ' +
      variables.allowedPrefixes.join(', ')
    reason: Forbidden
  - expression: "variables.allImages.all(i, i.contains('@sha256:'))"
    message: "every image must be pinned by digest (image@sha256:...)"
    reason: Forbidden
EOF
kubectl apply -f vap-registry.yaml
```

2. Vinculala. Una política sin binding es inerte — este es el error más común de todos.

```bash
cat > vap-binding.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: approved-registries-binding
spec:
  policyName: approved-registries
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: ["kube-system", "kube-node-lease"]
EOF
kubectl apply -f vap-binding.yaml
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding
```

3. Probá el camino de denegación — registry incorrecto.

```bash
kubectl -n supply run bad-reg --image=docker.io/library/nginx:1.27 --restart=Never
```

```text
The pods "bad-reg" is invalid: ValidatingAdmissionPolicy 'approved-registries'
with binding 'approved-registries-binding' denied request:
image from an unapproved registry; allowed prefixes: registry.internal.example.com/, localhost:5000/
```

4. Probá la segunda regla — registry correcto, tag sin fijar.

```bash
kubectl -n supply run bad-tag --image=$REG/healthz:slim --restart=Never
```

```text
... denied request: every image must be pinned by digest (image@sha256:...)
```

5. Probá el camino de permitido.

```bash
kubectl -n supply run good --image=$IMG --restart=Never
kubectl -n supply get pod good
```

6. Ahora observá la trampa de la *falla diferida*: creá un Deployment con una imagen mala y mirá dónde aparece el error.

```bash
kubectl -n supply create deployment bad-deploy --image=docker.io/library/nginx:1.27
echo "apply exit=$?"
kubectl -n supply get deploy bad-deploy
kubectl -n supply describe rs -l app=bad-deploy | grep -A3 -i events
```

```text
apply exit=0
NAME         READY   UP-TO-DATE   AVAILABLE
bad-deploy   0/1     0            0
Events:
  Warning  FailedCreate  ... Error creating: ... denied request: image from an unapproved registry ...
```

7. Agregá un binding sombra de solo auditoría, tal como harías el despliegue en un clúster existente.

```bash
cat > vap-binding-audit.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: approved-registries-audit
spec:
  policyName: approved-registries
  validationActions: ["Audit", "Warn"]
EOF
kubectl apply -f vap-binding-audit.yaml
```

Las anotaciones de auditoría aparecen entonces en el log de auditoría del API server bajo `validation.policy.admission.k8s.io/validation_failure`, permitiéndote dimensionar el radio de impacto antes de pasar a `Deny`.

### Preguntas de verificación — bloque 7

- **Q7.1** `kubectl create deployment` devolvió exit 0 con una imagen prohibida. Explicá el mecanismo, y decí qué le agregarías a la política para hacer visible la falla en el momento del `kubectl apply`.
- **Q7.2** Tu primer borrador de la política solo inspeccionaba `object.spec.containers`. Dame la línea exacta de spec de pod que usa un atacante para saltearla, y un segundo bypass usando un subrecurso.
- **Q7.3** `failurePolicy: Fail` en una `ValidatingAdmissionPolicy` se comporta distinto de `failurePolicy: Fail` en una `ValidatingWebhookConfiguration` en términos de riesgo de disponibilidad. ¿Por qué?
- **Q7.4** El binding excluye `kube-system`. Argumentá ambos lados: ¿por qué esa exclusión es pragmática, y qué te cuesta desde el punto de vista de la cadena de suministro?
- **Q7.5** `validationActions: ["Deny", "Audit"]` — ¿por qué querrías alguna vez ambos, si Deny ya bloquea la solicitud?

---

## Ejercicio 8 — Aplicá verificación de firmas en admisión

**Objetivo:** cerrar el círculo — hacer que el clúster rechace cualquier imagen cuya firma y attestation de SBOM del Ejercicio 5 no puedan verificarse. CEL no puede hacer criptografía, así que esto necesita un controlador.

1. Instalá Kyverno.

```bash
kubectl create ns kyverno
kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s
```

2. Escribí una política que verifique la firma de cosign **y** reescriba el tag al digest resuelto en tiempo de admisión.

```bash
cat > kyverno-verify.yaml <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
  - name: check-signature
    match:
      any:
      - resources:
          kinds: ["Pod"]
          namespaces: ["supply"]
    verifyImages:
    - imageReferences:
      - "localhost:5000/healthz*"
      # Resolve the tag to a digest and REWRITE the pod spec.
      mutateDigest: true
      # Refuse to admit anything that is not verifiable.
      required: true
      verifyDigest: true
      attestors:
      - count: 1
        entries:
        - keys:
            publicKeys: |-
$(sed 's/^/              /' cosign.pub)
            rekor:
              ignoreTlog: true
EOF
kubectl apply -f kyverno-verify.yaml
```

3. Probá con la imagen firmada.

```bash
kubectl -n supply run signed --image=$REG/healthz:slim --restart=Never
kubectl -n supply get pod signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

```text
localhost:5000/healthz@sha256:4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281
```

El tag que tipeaste fue reemplazado por el digest que Kyverno verificó. Esa mutación es el punto.

4. Probá con la imagen sin firmar.

```bash
kubectl -n supply run unsigned --image=$REG/healthz:fat --restart=Never
```

```text
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
resource Pod/supply/unsigned was blocked due to the following policies

verify-image-signature:
  check-signature: 'failed to verify image localhost:5000/healthz:fat: .attestors[0].entries[0].keys: no matching signatures'
```

5. Extendé la política para exigir la attestation del SBOM y afirmar una condición *dentro* del predicado.

```yaml
    verifyImages:
    - imageReferences: ["localhost:5000/healthz*"]
      mutateDigest: true
      required: true
      attestations:
      - type: https://spdx.dev/Document
        attestors:
        - entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                ...
                -----END PUBLIC KEY-----
              rekor:
                ignoreTlog: true
        conditions:
        - all:
          - key: "{{ spdxVersion }}"
            operator: Equals
            value: "SPDX-2.3"
```

6. Confirmá que la mutación es duradera a través de reinicios y que las propias imágenes de Kyverno están excluidas de la política (si no, construís un deadlock).

```bash
kubectl -n supply delete pod signed
kubectl -n supply run signed --image=$REG/healthz:slim --restart=Never
kubectl -n supply get pod signed -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
```

### Preguntas de verificación — bloque 8

- **Q8.1** `mutateDigest: true` es un comportamiento mutante dentro de una política de verificación. ¿Qué brecha TOCTOU (time-of-check/time-of-use) cierra, y qué saldría mal sin ella?
- **Q8.2** ¿Por qué una `ValidatingAdmissionPolicy` (Ejercicio 7) no puede reemplazar esta política, aunque CEL sea expresivo?
- **Q8.3** El webhook de Kyverno tiene `failurePolicy: Fail`. Describí el deadlock de bootstrap que esto crea en un arranque en frío del clúster, y las dos mitigaciones estándar.
- **Q8.4** Tu política matchea `localhost:5000/healthz*`. Un atacante despliega `localhost:5000/healthzevil:v1`. ¿Se verifica? ¿Qué enseña esto sobre escribir globs de referencias de imagen?
- **Q8.5** La verificación de firmas está activada. Explicá por qué una imagen firmada igual puede ser maliciosa, y nombrá el control que aborda ese riesgo residual.

---

## Ejercicio 9 — Endurecé la etapa de CI/CD misma

**Objetivo:** tratar al pipeline como un sistema de producción con una identidad, un radio de impacto y secretos — porque es el objetivo de mayor valor de toda la cadena.

1. Analizá estáticamente los manifiestos antes de que se apliquen.

```bash
cd ~/sc-lab/app
trivy config --severity HIGH,CRITICAL --exit-code 1 ./tagged.yaml
```

```text
tagged.yaml (kubernetes)
HIGH: Container 'app' of Deployment 'healthz' should set 'securityContext.runAsNonRoot' to true
HIGH: Container 'app' of Deployment 'healthz' should set 'securityContext.readOnlyRootFilesystem' to true
CRITICAL: Container 'app' of Deployment 'healthz' should not set 'allowPrivilegeEscalation' implicitly
```

2. Puntuá con `kubesec` para una opinión complementaria.

```bash
kubesec scan tagged.yaml | jq '.[0] | {score, advise: (.scoring.advise | map(.selector))}'
```

3. Analizá el propio Dockerfile en busca de mala configuración en tiempo de build.

```bash
trivy config Dockerfile.fat
```

4. Escaneá el repositorio en busca de credenciales filtradas — los pipelines las commitean constantemente.

```bash
trivy fs --scanners secret,vuln,misconfig --severity HIGH,CRITICAL .
```

5. Auditá la identidad que tu job de CI tiene dentro del clúster. Este es el paso que la mayoría de los equipos nunca hace.

```bash
kubectl create ns ci
kubectl -n ci create serviceaccount deployer
kubectl create clusterrolebinding ci-deployer-toowide \
  --clusterrole=cluster-admin --serviceaccount=ci:deployer

# What can this token actually do?
kubectl auth can-i --list --as=system:serviceaccount:ci:deployer | head
kubectl auth can-i create pods --as=system:serviceaccount:ci:deployer -n kube-system
kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:ci:deployer
```

6. Reemplazala con un binding de mínimo privilegio acotado a un namespace y un conjunto de verbos.

```bash
kubectl delete clusterrolebinding ci-deployer-toowide

cat > ci-rbac.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: supply
  name: deployer
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: supply
  name: deployer
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: ci
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f ci-rbac.yaml

kubectl auth can-i create pods --as=system:serviceaccount:ci:deployer -n supply
kubectl auth can-i patch deployments --as=system:serviceaccount:ci:deployer -n supply
```

7. Emití un token de vida corta en vez de un Secret de larga duración.

```bash
TOKEN=$(kubectl -n ci create token deployer --duration=10m)
kubectl -n ci get secrets | grep deployer || echo "no long-lived Secret exists — correct"
```

8. Revisá la definición del pipeline contra los sumideros de inyección clásicos.

```yaml
# .github/workflows/release.yaml — annotated with the controls that matter
name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: read          # default-deny; widen per job, never at workflow level
  id-token: write         # OIDC for keyless signing — no static key material
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # Pin actions by COMMIT SHA, not by tag. A tag on a third-party action
      # is mutable by its owner — the same attack as Exercise 4, one layer up.
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false   # do not leave a push-capable token in .git/config

      - uses: docker/build-push-action@4f58ea79222b3b9dc2c8bbdd6debcef730109a75 # v6.9.0
        id: build
        with:
          push: true
          provenance: mode=max
          sbom: true

      # Sign the DIGEST that build-push-action reported, not the tag we asked for.
      - run: cosign sign --yes ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}

      - run: |
          syft scan ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }} \
            -o spdx-json=sbom.spdx.json
          grype sbom:./sbom.spdx.json --only-fixed --fail-on high
          cosign attest --yes --predicate sbom.spdx.json --type spdxjson \
            ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
```

### Preguntas de verificación — bloque 9

- **Q9.1** El workflow fija las actions de terceros por SHA de commit. ¿Qué ejercicio de este documento es el análogo directo de ese control, y cuál es el principio subyacente compartido?
- **Q9.2** Se configuró `persist-credentials: false` en el checkout. ¿Qué escalada específica previene eso, dado que el job además corre `docker build` sobre archivos influenciados por el atacante?
- **Q9.3** El pipeline firma `steps.build.outputs.digest` en vez del tag que hizo push. Construí la condición de carrera a la que te expondría firmar el tag.
- **Q9.4** En el paso 5 la ServiceAccount de CI era `cluster-admin` en un pipeline acotado a un namespace. Enumerá el camino desde "el atacante envía un pull request" hasta "el atacante es dueño del clúster", asumiendo que los builds de PR comparten esa ServiceAccount.
- **Q9.5** Tokens de vida corta (`kubectl create token --duration=10m`) versus un Secret `kubernetes.io/service-account-token`: decí las dos propiedades que gana el token de vida corta, y la única cosa operativa que rompe.

---

## Ejercicio 10 — Endurecimiento del repositorio de artefactos y control del camino de pull

**Objetivo:** controlar cómo el clúster se autentica contra los registries y qué le está permitido descargar.

1. Creá un pull secret con alcance de namespace y adjuntalo a una ServiceAccount, para que los pods no lleven cada uno las credenciales.

```bash
kubectl -n supply create secret docker-registry regcred \
  --docker-server=registry.internal.example.com \
  --docker-username=ci-pull \
  --docker-password='S3cr3t!' \
  --docker-email=platform@example.com

kubectl -n supply patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'

kubectl -n supply get sa default -o jsonpath='{.imagePullSecrets}{"\n"}'
```

2. Confirmá que la credencial es recuperable por cualquiera con `get secrets` en ese namespace — por esto las credenciales de registry deben ser de solo lectura (pull-only).

```bash
kubectl -n supply get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
```

```text
{ "auths": { "registry.internal.example.com": { "username": "ci-pull", "password": "S3cr3t!", "auth": "..." } } }
```

3. Habilitá `AlwaysPullImages` para que un pod no pueda reutilizar una imagen privada ya cacheada en el nodo sin demostrar que puede autenticarse.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
- --enable-admission-plugins=NodeRestriction,AlwaysPullImages
```

4. Verificá el efecto: el plugin reescribe el campo sin importar lo que el autor haya pedido.

```bash
kubectl -n supply run cachetest --image=$REG/healthz:slim --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"cachetest","image":"localhost:5000/healthz:slim","imagePullPolicy":"IfNotPresent"}]}}'
kubectl -n supply get pod cachetest -o jsonpath='{.spec.containers[0].imagePullPolicy}{"\n"}'
```

```text
Always
```

5. Enumerá cada imagen distinta corriendo en el clúster, y cada registry del que proviene — el inventario con el que arranca un incidente.

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}' \
  | grep -v '^$' | sort -u

kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' \
  | awk -F/ '{ if ($0 ~ /\//) print $1; else print "docker.io (implicit)" }' | sort | uniq -c | sort -rn
```

```text
     41 registry.k8s.io
      7 localhost:5000
      3 docker.io (implicit)
      1 quay.io
```

6. Controles del lado del registry a configurar en Harbor / Artifactory / ECR (verificalos en la UI o API de tu propio registry):

```text
  IMMUTABLE TAG RULES     tag `v*` in project `prod` cannot be overwritten  -> kills Exercise 4's attack
  VULNERABILITY GATE      block pull if severity >= High and scan is stale  -> policy at the pull, not the push
  CONTENT TRUST           reject unsigned artifacts on push
  PROXY CACHE             one egress path to docker.io; nodes never reach the internet directly
  RETENTION + QUOTA       old digests garbage-collected on a schedule
  ROBOT ACCOUNTS          push identity != pull identity; pull is read-only, scoped to one project
```

7. Confirmá que los nodos no pueden saltear el registry interno.

```bash
kubectl -n supply run egress --image=$IMG --restart=Never --rm -it --command -- /healthz &
# From the node:
sudo crictl pull docker.io/library/nginx:1.27 || echo "direct egress blocked -> correct"
```

### Preguntas de verificación — bloque 10

- **Q10.1** El Secret `regcred` es legible por todo sujeto con `get secrets` en `supply`. Describí el daño exacto que hace una credencial filtrada con capacidad de *push*, versus una filtrada de solo pull.
- **Q10.2** Se habilitó `AlwaysPullImages`. ¿Qué ataque detiene, y qué dos costos operativos impone?
- **Q10.3** El paso 5 contó 3 imágenes de "docker.io (implicit)". ¿Por qué un nombre de imagen sin calificar como `nginx:1.27` es un riesgo de cadena de suministro más allá de la mera elección de registry?
- **Q10.4** Las reglas de tags inmutables y el fijado por digest ambos derrotan la mutación de tags. ¿Por qué implementar ambos, y cuál te protege cuando un desarrollador saltea el pipeline?
- **Q10.5** Un registry de caché proxy significa que cada nodo solo hace pull desde `registry.internal.example.com`. ¿Qué nuevo punto único de compromiso acabás de crear, y qué control compensatorio lo mantiene honesto?

---

## Ejercicio 11 — Trazá un contenedor en ejecución de vuelta hasta su fuente

**Objetivo:** realizar el recorrido punta a punta que hace un respondedor de incidentes. Este es el examen de todo el tema.

1. Empezá desde un pod en ejecución. Obtené el digest resuelto, no el tag.

```bash
kubectl -n supply get pod signed \
  -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'
```

```text
localhost:5000/healthz@sha256:4d1e2b7c9a0f5e3b8c6d4a2f1e0b9c8d7a6f5e4d3c2b1a09f8e7d6c5b4a39281
```

2. Preguntale al registry qué es ese digest.

```bash
crane manifest $IMG | jq '{schemaVersion, layers: (.layers|length), config: .config.digest}'
crane config $IMG | jq '{created, architecture, config: .config.Entrypoint, history: (.history|length)}'
```

3. Recuperá la procedencia del build desde las labels de config o desde la attestation.

```bash
crane config $IMG | jq '.config.Labels'
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type slsaprovenance $IMG 2>/dev/null \
  | jq -r '.payload' | base64 -d \
  | jq '.predicate | {builder: .builder.id, source: .invocation.configSource}'
```

4. Recuperá el inventario tal como estaba en tiempo de build.

```bash
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson $IMG | jq -r '.payload' | base64 -d \
  | jq -r '.predicate.packages[] | "\(.name)\t\(.versionInfo)"'
```

5. Hacé la pregunta de hoy contra el inventario de ayer.

```bash
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
  --type spdxjson $IMG | jq -r '.payload' | base64 -d | jq '.predicate' > shipped-sbom.json
grype db update
grype sbom:./shipped-sbom.json --only-fixed -o table
```

6. Encontrá cada carga de trabajo del clúster afectada por el mismo digest.

```bash
kubectl get pods -A -o json | jq -r --arg D "$IMG_DIGEST" '
  .items[] | select(
    (.status.containerStatuses // [])[]? | .imageID | contains($D)
  ) | "\(.metadata.namespace)/\(.metadata.name)"'
```

7. Escribí la línea de tiempo del incidente que ahora podés defender.

```text
  DIGEST      sha256:4d1e2b7c...        <- what is running, verified against the kubelet
  SIGNATURE   valid, key platform-2026  <- who approved it
  PROVENANCE  builder github/acme, ref refs/tags/v1.4.2, commit 9a1c7f0
  SBOM        5 packages, signed, subject == digest
  EXPOSURE    stdlib go1.22.5 -> CVE-2024-xxxxx (fixed in 1.22.7)
  BLAST       supply/signed, supply/healthz-6b4f9c7d5-p8m2r  (2 pods, 1 namespace)
  ACTION      rebuild from 9a1c7f0 on go1.22.7, re-sign, re-attest, patch digest
```

### Preguntas de verificación — bloque 11

- **Q11.1** En el paso 1 leíste `.status.containerStatuses[].imageID` en vez de `.spec.containers[].image`. Si los dos no coinciden, ¿en cuál confiás para respuesta a incidentes y por qué?
- **Q11.2** El paso 5 escaneó el SBOM *entregado* en vez de re-escanear la imagen viva. Nombrá una ventaja y una limitación seria de ese enfoque.
- **Q11.3** La procedencia dice `commit 9a1c7f0`. ¿Qué control adicional debe existir para que esa afirmación valga algo?
- **Q11.4** Supongamos que el paso 3 no devuelve ninguna attestation, y el digest del paso 1 no está en ningún registry que controles. ¿Qué pasó casi con seguridad, y cuáles de los controles de los ejercicios anteriores lo habrían prevenido?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1 — minimización de imágenes

**A1.1** Tres capacidades distintas que la imagen `fat` otorga y `slim` niega:
1. **Reconocimiento interactivo y movimiento lateral** — un shell más `curl`/`wget` le permite al atacante enumerar la red de pods, golpear el API server en `https://kubernetes.default.svc`, leer `/var/run/secrets/kubernetes.io/serviceaccount/token`, y pivotear. Con distroless no hay `sh`, no hay `curl`, no hay `cat`; el atacante debe traer su propio herramental y ya debe tener un camino con capacidad de escritura+ejecución.
2. **Compilación in situ y abuso del toolchain** — el toolchain de Go, `gcc` y `git` significan que un atacante puede construir una carga útil de segunda etapa en el host, evitando cualquier descarga por red que una política de egreso o un IDS detectaría.
3. **Instalación de paquetes** — `apt-get install` le da al atacante un gestor de paquetes con capacidades equivalentes a root dentro del contenedor, un arsenal enorme ya armado, y un mecanismo de aspecto plausible que se mimetiza con el ruido operativo normal.

**A1.2** `CGO_ENABLED=0` produce un binario **enlazado estáticamente** sin dependencia dinámica de `glibc`, `libpthread` o las bibliotecas del resolvedor NSS. `distroless/static` contiene solo certificados de CA, `/etc/passwd`, `tzdata` y un usuario `nonroot` — nada de libc — así que un binario con CGO habilitado fallaría en el exec con un error de intérprete faltante. `distroless/base` incluye glibc precisamente para builds con CGO, a costa de una superficie mayor (glibc es una fuente recurrente de CVEs). Elegí `static` siempre que puedas; elegí `base` solo cuando CGO sea genuinamente necesario (p. ej. ciertas configuraciones de SQLite o del resolvedor DNS).

**A1.3** El contraargumento: la minimización no es un límite, es **imposición de costo y detectabilidad**. Subir busybox requiere que el atacante ya tenga (a) una ubicación del sistema de archivos escribible, (b) que esa ubicación esté montada sin `noexec`, y (c) o bien egreso para descargarlo o bien una forma de escribirlo a través de la primitiva de explotación existente. Cada uno de esos pasos es una acción nueva, ruidosa y detectable, y cada uno es bloqueable de forma independiente.

El control a nivel Kubernetes que hace que la objeción sea genuinamente débil es `securityContext.readOnlyRootFilesystem: true` combinado con `allowPrivilegeEscalation: false` y descartar todas las capabilities — con un root de solo lectura y volúmenes `emptyDir` montados `noexec`, no hay lugar donde aterrizar el binario. Minimización más un root de solo lectura es mucho más fuerte que cualquiera de las dos por separado.

**A1.4** **No** aparecen en el SBOM de `slim`, y **no** importan para la exposición en runtime — la etapa de build se descarta y ningún byte del toolchain de Go está en la imagen entregada. Ese es todo el punto de los builds multi-stage. Dos salvedades que vale la pena decir: (i) los CVEs de la etapa de build sí importan para la **integridad del build** — un toolchain comprometido puede inyectar una puerta trasera en el binario de salida (la clásica preocupación de Ken Thompson / "trusting trust", y la razón práctica por la que a SLSA le importan los builders herméticos y con procedencia atestiguada); (ii) si una *biblioteca* vulnerable fue enlazada estáticamente en el binario, el CVE viaja a la imagen de runtime aunque el *paquete* no aparezca como un deb — que es exactamente el punto ciego de catalogación del Ejercicio 2.

---

### Bloque 2 — generación de SBOM

**A2.1** El **digest del sujeto** — el identificador criptográfico del artefacto que el documento describe (`.metadata.component.hashes` en CycloneDX, el `name` del documento / la relación `DESCRIBES` y los checksums de paquetes en SPDX; y en una attestation in-toto, `subject[].digest.sha256`). Sin él, el SBOM es una lista de nombres de paquetes atada a nada: no puede verificarse contra ninguna imagen, puede intercambiarse por el SBOM de otra imagen, y degenera en documentación. Todo lo que viene después — firma, política de admisión, respuesta a incidentes — se apoya en esa ligadura.

**A2.2** Ninguno está "bien"; usan **catalogadores** distintos y supuestos distintos. Syft enumera bases de datos de paquetes y manifiestos de lenguaje agresivamente a lo largo de muchos ecosistemas; Trivy aplica sus propios analizadores y está sintonizado hacia lo que su base de datos de vulnerabilidades puede matchear. Las diferencias surgen de: qué tipos de paquete cataloga cada herramienta por defecto, cómo maneja cada una la información de build de Go embebida en binarios, si se reportan archivos sin metadatos de paquete, y las decisiones de normalización de versiones.

La lección para política: **no trates un SBOM como verdad absoluta sobre lo que hay en una imagen** — tratalo como la mejor evidencia de una herramienta. Concretamente: fijá el generador y su versión en el pipeline (un SBOM solo es comparable con otro SBOM de la misma herramienta+versión), registrá el generador en `creationInfo`/`metadata.tools`, y si una decisión de política debe ser defendible, generá con dos herramientas y alertá ante la divergencia en vez de confiar silenciosamente en una.

**A2.3** La clase de ataque es la **inyección de dependencias fuera del plano del gestor de paquetes** — un binario vendorizado, una biblioteca enlazada estáticamente, una instalación `curl | sh` en el Dockerfile, un JAR shaded dentro de un uber-JAR, o un archivo malicioso copiado vía `COPY`. Como ninguna base de datos de paquetes lo registra, el SBOM no lista nada, el escáner no tiene con qué matchear, y el pipeline reporta "0 vulnerabilidades" sobre una imagen que contiene un binario conocido como vulnerable o directamente malicioso. Así fue como Log4Shell se escondió dentro de JARs shaded en muchas organizaciones.

Dos maneras de cerrarlo:
1. **Habilitar catalogadores a nivel de archivo/binario** (`syft --select-catalogers '+binary-classifier-cataloger'`, o el `--scanners vuln` de Trivy con sus analizadores de binarios), para que se detecten las cadenas de versión embebidas en ejecutables.
2. **Restringir el build mismo**: prohibir `curl|sh` y `COPY` sin fijar desde fuentes arbitrarias en el linting de Dockerfiles, exigir que todo el contenido de runtime venga de un gestor de paquetes o de un `COPY --from` de una etapa de build atestiguada, y usar builds herméticos donde el builder no tiene acceso a red después de la resolución de dependencias. Complementá con **diffing del sistema de archivos** — comparar el inventario de archivos de la imagen contra la unión de archivos reclamados por los paquetes catalogados, y alertar sobre el remanente.

**A2.4** Escanear `registry:$IMG` escanea **exactamente los bytes que el clúster va a descargar**, resueltos por digest, sin dependencia del estado del daemon local. La fuente `docker:` escanea lo que sea que el daemon local tenga bajo ese tag, que puede estar rancio, puede haberse construido con un `--build-arg` distinto, puede haber recibido un `docker tag` local de otro job en un runner compartido, y no está direccionado por digest. En CI sobre runners compartidos o de larga vida, la caché de imágenes del daemon es estado influenciable por el atacante; el digest del registry no. También significa que el mismo job de SBOM puede correr en una máquina que nunca tuvo acceso al build — una separación de privilegios más limpia.

**A2.5** **SPDX** para cumplimiento de licencias: fue diseñado por la Linux Foundation exactamente para eso, tiene el modelo de expresión de licencias más rico (`licenseConcluded` vs `licenseDeclared`, los identificadores de licencia SPDX como vocabulario de la industria), y es el formato que esperan los equipos legales y de compras y el estándar ISO 5962.

**CycloneDX** para triaje de vulnerabilidades guiado por VEX: fue diseñado por OWASP con la seguridad como caso de uso principal, modela bien las relaciones entre componentes y el `pedigree`, tiene identificadores **PURL** de primera clase que mapean limpiamente sobre las bases de datos de vulnerabilidades y — de forma decisiva — tiene una representación VEX nativa e integrada, así que las declaraciones de explotabilidad viven en la misma familia de esquemas que el inventario.

En la práctica, los pipelines maduros emiten ambos; son baratos de generar y distintos consumidores quieren distintos formatos.

---

### Bloque 3 — consumir el SBOM

**A3.1** Dos razones independientes:
1. **Inventario distinto.** El SBOM se generó una vez, con una herramienta, con una configuración de catalogadores. `grype registry:` re-cataloga la imagen en el momento del escaneo — posiblemente con un Grype más nuevo que contiene catalogadores nuevos o mejorados, así que puede ver paquetes que el SBOM almacenado nunca registró (y viceversa si se quitaron catalogadores).
2. **Instantánea distinta de la base de datos de vulnerabilidades.** Grype matchea contra una base de datos que se actualiza continuamente. Incluso con inventarios idénticos, un escaneo hoy y uno de hace una hora pueden diferir porque se publicó un CVE, se recalificó una severidad o se agregó una versión con fix. (Una tercera razón, más sutil: `registry:` puede resolver un *tag* a un digest distinto del sujeto del SBOM — el problema del Ejercicio 4.)

**A3.2** Degenera en un sello de goma porque el conteo es **ilimitado, no accionable y no está bajo el control del desarrollador**. Una imagen base con 1200 paquetes acumulará críticos continuamente; la mayoría no tendrá fix disponible; la mayoría de los que sí lo tengan estarán en rutas de código que la aplicación nunca ejecuta. Las únicas opciones del equipo pasan a ser "bloquear todas las releases indefinidamente" o "agregar un ignore general" — y bajo presión de fecha límite, siempre es la segunda. El gate entonces permite todo, mientras el dashboard implica que no permite nada.

Un gate que sobrevive al contacto con la realidad tiene cuatro propiedades:
- **Solo lo corregible** — `--only-fixed`: fallar solo donde el desarrollador realmente puede actuar (`grype sbom:... --only-fixed --fail-on high`).
- **Acotado por alcanzabilidad** — suprimir con declaraciones VEX respaldadas por análisis, no con ignores generales.
- **Sin regresión, más un presupuesto decreciente** — fallar ante cualquier hallazgo *nuevo* respecto de la release anterior, y por separado seguir un conteo absoluto con un trinquete programado, de modo que la deuda heredada no bloquee la release de hoy pero tampoco se vuelva permanente.
- **Excepciones con plazo** — cada supresión lleva un responsable y una fecha de vencimiento, y el vencimiento vuelve a romper el build.

Crucialmente, el gate también debería fallar ante cosas que son *siempre* accionables y *siempre* culpa del desarrollador: secretos filtrados, tags `latest`, imágenes base sin fijar.

**A3.3** `.trivyignore` no afirma nada. Es `"no me hables de este ID"` — una línea sin atribución, sin fecha, sin justificación y sin firma en un archivo de texto. Suprime el hallazgo para todos, para siempre, en cada imagen, sin registro de quién lo decidió ni por qué.

La declaración OpenVEX `not_affected` / `vulnerable_code_not_in_execute_path` afirma una **reivindicación específica, atribuida, con marca temporal y acotada al producto**: *este autor, en esta fecha, analizó este CVE contra este producto exacto (identificado por PURL/digest) y determinó que el código vulnerable está presente pero no es alcanzable.*

Por qué le importa a un auditor: la declaración VEX es **evidencia de un proceso de seguridad**. Está acotada a un digest (no se arrastra silenciosamente a un rebuild donde la ruta de código *sí* pasó a ser alcanzable), nombra a un responsable, declara una justificación legible por máquina de un vocabulario fijo, puede firmarse y distribuirse a consumidores aguas abajo, y puede revisarse y revocarse. `.trivyignore` es indistinguible de "alguien quería que el build saliera en verde".

**A3.4** El SBOM **no** necesita regenerarse — la imagen no cambió, así que el inventario no cambió. Regenerarlo produciría el mismo contenido con una marca temporal nueva y no te diría nada.

Lo que hay que volver a correr es el **paso de matcheo**: el escaneo de vulnerabilidades del SBOM almacenado contra una base de datos actual. Este es el argumento operativo central para almacenar SBOMs como attestations: podés volver a responder "¿estoy expuesto?" para cada imagen que hayas entregado alguna vez, en segundos, sin reconstruir nada y sin descargar imágenes.

Dónde debería correr: **continuamente, fuera del pipeline de build**, en un servicio que mantiene un inventario de cada artefacto desplegado actualmente (correlacionado con los digests realmente en ejecución del clúster, según el paso 6 del Ejercicio 11) y re-escanea todos sus SBOMs en cada actualización de la base de datos. Un gate que solo corre en tiempo de build responde "¿era esto seguro cuando lo entregamos?", que no es la pregunta que nadie hace durante un incidente.

---

### Bloque 4 — tags vs digests

**A4.1** `.status.containerStatuses[].imageID` — el digest que el kubelet realmente resolvió y corrió. `spec.containers[].image` es una **solicitud**, no un hecho: registra lo que el autor pidió, y cuando contiene un tag mutable es un puntero cuyo destino puede cambiar en cualquier momento sin que se modifique ningún objeto de Kubernetes. Para auditoría necesitás el valor que identifica bytes, y solo el digest lo hace. Esta es también la razón por la que `kubectl diff`, la detección de deriva de GitOps y los webhooks de admisión que solo leen el spec pueden reportar todos "sin cambios" ante una sustitución completa de código.

**A4.2** Con `IfNotPresent`, el kubelet corre lo que haya en la **caché local de imágenes del nodo** bajo ese tag; solo contacta al registry si no hay nada cacheado. Así que el factor decisivo es simplemente *si ese nodo alguna vez descargó el tag antes* — lo que depende del historial de scheduling, la antigüedad del nodo, si el nodo se agregó o reimaginó recientemente, y la presión de recolección de basura de `--image-gc-high-threshold`.

La consecuencia de seguridad: **el mismo Deployment corre código distinto en nodos distintos, indefinidamente e invisiblemente.** Un rollback que "arregla" el problema en los nodos nuevos deja a los nodos comprometidos sirviendo la imagen maliciosa; escalar hacia arriba puede propagarla o no; y ningún objeto de Kubernetes refleja la división. Delimitar el incidente pasa a ser una investigación por nodo en vez de una consulta. (`AlwaysPullImages`, Ejercicio 10, fuerza determinismo acá.)

**A4.3** **Sí, el contenedor arranca.** Sin `AlwaysPullImages`, `imagePullPolicy: IfNotPresent` significa que el kubelet encuentra la imagen localmente y nunca contacta al registry, así que nunca se requiere ninguna credencial. Esta es una falla de aislamiento real y frecuentemente pasada por alto: un inquilino del namespace B puede correr una imagen privada del inquilino A simplemente nombrándola, siempre que el pod de A haya sido agendado en el mismo nodo — las cachés de imágenes tienen alcance de nodo, no de namespace.

El plugin que cambia la respuesta es **`AlwaysPullImages`**. Habilitado en el API server, muta el `imagePullPolicy` de cada pod a `Always` en admisión, forzando al kubelet a contactar al registry en cada arranque de contenedor. La descarga entonces falla con un error de autenticación a menos que el namespace del pod tenga un `imagePullSecret` funcional, restaurando las credenciales del registry como una frontera de autorización real.

**A4.4** El costo operativo es que **el manifiesto ya no expresa intención** — `image: healthz@sha256:4d1e...` es ilegible, y cada actualización (incluido el parcheo automatizado de la imagen base) requiere reescribir el manifiesto, así que el fijado por digest es incompatible con YAML mantenido a mano a escala.

El componente del pipeline que lo absorbe es el **actualizador de imágenes / automatización de releases**: un controlador GitOps como los image-automation controllers de Flux, Argo CD Image Updater, o Renovate/Dependabot, que vigila el registry en busca de un digest nuevo que matchee una política de tags, abre un commit o PR que reescribe el digest en Git, y deja que el camino normal de revisión y despliegue lo aplique. El digest sigue siendo autoritativo; el tag pasa a ser una entrada para la automatización en vez de una indirección de runtime. Una alternativa en tiempo de admisión es el `mutateDigest: true` de Kyverno (Ejercicio 8), que resuelve y reescribe el digest en admisión después de verificar la firma.

---

### Bloque 5 — firma y attestation

**A5.1** La firma se almacena como un **artefacto OCI separado en el mismo repositorio**, bajo un tag derivado `sha256-<digest>.sig` (como mostró `cosign triangulate`), conteniendo un manifiesto pequeño cuya capa contiene el payload de la firma y cuyas anotaciones contienen la firma misma. Cosign moderno también puede usar referrers de OCI 1.1.

La implicación para `crane copy`: una copia simple de `repo:tag` mueve el manifiesto de la imagen y las capas pero **no** los artefactos `.sig`/`.att` asociados, porque son objetos separados bajo tags distintos. La imagen llega al registry destino sin poder verificarse, y cualquier política de admisión que exija una firma la rechazará. Tenés que copiar también las firmas — `cosign copy $SRC $DST`, un `crane copy` explícito de los tags `.sig`, o una regla de replicación del registry que entienda los artefactos de cosign/referrers. La pérdida silenciosa de firmas durante una migración de registry o una promoción entre entornos es una de las causas más comunes de "la política de repente rechaza nuestras imágenes de producción".

**A5.2** Con firma **basada en claves**, la confianza está anclada en la posesión de una clave privada. La clave debe existir en algún lado — un KMS, un secreto de CI, un archivo — durante toda la vida de la identidad firmante, y cualquiera que la obtenga puede falsificar firmas indefinidamente e indetectablemente, incluso retroactivamente.

Con firma **keyless**, no hay clave de larga vida. El firmante prueba una **identidad** ante un proveedor OIDC (p. ej. la workload identity de GitHub Actions), Fulcio emite un certificado válido por ~10 minutos que liga una clave efímera recién generada a esa identidad, el artefacto se firma, la clave privada efímera se descarta, y el certificado más la firma se registran en el log de transparencia Rekor. La verificación fija la *identidad y el emisor* (`--certificate-identity-regexp`, `--certificate-oidc-issuer`), no una clave.

Keyless es dramáticamente más difícil para un atacante que roba el disco de un runner: no hay clave en reposo para robar. La credencial es un token OIDC ligado a un workflow, repositorio y ref específicos, expira en minutos, y no puede exfiltrarse para reutilizarla después. Comprometerla requiere **ejecución de código en vivo dentro del workflow legítimo en el momento de la firma** — e incluso entonces, cada firma producida queda permanentemente registrada en Rekor con la identidad que la hizo, así que el abuso es descubrible a posteriori. El robo de claves es silencioso; el abuso keyless deja un registro público.

**A5.3** El campo `subject[].digest.sha256` del statement in-toto. `cosign attest` envuelve el predicado (tu SBOM) en un Statement in-toto cuyo `subject` es el digest de la imagen que se atestigua, y luego firma el sobre entero. La verificación contra `$FAT` falla porque no existe ninguna attestation cuyo sujeto coincida con ese digest y cuya firma valide con la clave dada.

El ataque que previene es el **trasplante de SBOM/attestation**: tomar el SBOM limpio y de bajos CVEs de una imagen auditada y presentarlo como el SBOM de una imagen distinta y maliciosa. Sin la ligadura al sujeto, un SBOM es un archivo de texto suelto que puede adjuntarse a cualquier cosa; con ella, la afirmación "este inventario describe este artefacto" es criptográficamente inseparable de la identidad del artefacto.

**A5.4** **Rekor** es un log de transparencia de eventos de firma, solo-agregable y auditable públicamente. Protege principalmente contra el **compromiso indetectable de claves y el antedatado**. Como cada firma legítima queda registrada, una firma producida con una clave robada o bien está ausente del log (y es rechazada por verificadores que exigen inclusión en el log) o bien está presente en él — donde el dueño del artefacto puede ver un evento de firma que no realizó. También provee **verificabilidad a largo plazo de certificados de vida corta**: los certificados de Fulcio viven ~10 minutos, así que sin una entrada de log con marca temporal que pruebe que la firma se hizo mientras el certificado era válido, las firmas keyless se volverían inverificables minutos después de creadas.

Deshabilitarlo con `--insecure-ignore-tlog=true` pierde: la detección de firmas no autorizadas, la marca temporal confiable, la capacidad de razonar sobre ventanas de revocación, y (para keyless) la verificabilidad más allá del vencimiento del certificado. Es aceptable en un laboratorio aislado contra un registry local — como acá — y en entornos que corren una instancia privada de Rekor, pero nunca debería ser la postura de producción. Notá que un Rekor privado es la respuesta estándar para entornos regulados o air-gapped; "sin log" no lo es.

**A5.5** Una firma válida no responde:
- **Qué hay en el artefacto.** El firmante puede haber firmado una imagen con puerta trasera, ya sea maliciosamente o porque su build estaba comprometido. Una firma es una afirmación de aprobación, no de contenido ni de calidad — que es exactamente por qué adjuntás un SBOM *y* una attestation de procedencia junto a ella, y por qué la política de admisión debería verificar también esos predicados, no solo la firma.
- **Si el artefacto debería seguir siendo confiable hoy.** Las firmas no expiran en ningún sentido operativo útil y no hay un mecanismo de revocación ampliamente desplegado para ellas. Una imagen firmada legítimamente hace seis meses, que ahora se sabe que contiene un RCE crítico o que se sabe producida por un builder comprometido, sigue verificando perfectamente. La frescura y la revocación deben venir de otro lado — re-escaneo continuo de los SBOMs almacenados (A3.4), una lista blanca de digests aprobados actualmente, o una política que exija una attestation reciente y firmada de "sigue aprobada".

(Otras respuestas válidas: no te dice la *fuente* desde la que se construyó el artefacto — eso es el predicado de procedencia — ni si la identidad firmante estaba autorizada a firmar *este artefacto en particular*, que es una cuestión de política sobre el mapeo identidad-a-repositorio.)

---

### Bloque 6 — ImagePolicyWebhook

**A6.1** La causa más probable es que el **archivo de configuración no es visible dentro del contenedor del API server**: no se agregaron el volumen `hostPath` y el `volumeMount` para `/etc/kubernetes/admission`, o se agregaron bajo una ruta que no coincide con el valor de `--admission-control-config-file`. `kube-apiserver` corre como un static pod; un archivo del sistema de archivos del nodo no existe en su mount namespace a menos que se monte. (Un segundo muy cercano: el `kubeConfigFile` dentro de `admission-config.yaml` apunta a una ruta que tampoco está montada, o el bloque completo del plugin referencia el nombre de plugin equivocado.)

Confirmalo en diez segundos:
```bash
kubectl -n kube-system exec -it kube-apiserver-$(hostname) -- ls -l /etc/kubernetes/admission/
# or, if the API server is unhealthy:
sudo crictl ps -a --name kube-apiserver
sudo crictl logs <container-id> 2>&1 | tail -20
```
Si el API server arrancó *exitosamente* con el flag pero nunca se llama al webhook, la causa restante más común es que el archivo se montó de solo lectura desde una ruta que no existía al arrancar el kubelet, así que `DirectoryOrCreate` produjo un directorio vacío — `ls` lo muestra de inmediato. Notá también que una configuración genuinamente malformada normalmente hace que el API server se niegue a arrancar, que es un síntoma distinto (A6.3).

**A6.2** La secuencia de fallas: el backend del webhook es en sí mismo una carga de trabajo. Supongamos que corre dentro del clúster y el clúster se reinicia, o su nodo falla, o su Deployment se escala a cero durante un mantenimiento, o un cambio de network policy corta el camino del API server hacia él. Ahora **no se puede crear ningún pod en ningún lado** — incluidos los propios pods del webhook, así que nunca puede volver. El clúster queda en deadlock y la recuperación requiere editar a mano el manifiesto del static pod en el nodo del plano de control, exactamente como en el paso 8. Lo mismo pasa en un arranque en frío: nada puede agendarse hasta que el webhook esté arriba, y el webhook no puede levantar hasta que algo pueda agendarse.

Mitigaciones que mantienen la semántica fail-closed sin el riesgo:
- **Nunca corras el backend en el clúster que protege**, o corrélo como static pod / DaemonSet con host-network en los nodos del plano de control, sin dependencia del scheduling del clúster.
- **Eximí los namespaces de sistema**, para que `kube-system` y las cargas de CNI/CSI/webhook salteen el chequeo. (`ImagePolicyWebhook` en sí no tiene campo de exención por namespace — una de sus limitaciones reales — lo cual es un argumento fuerte a favor de la ruta `ValidatingWebhookConfiguration`/`ValidatingAdmissionPolicy`, donde las exenciones por `namespaceSelector`/`objectSelector` son de primera clase.)
- **Corré el backend en alta disponibilidad** con múltiples réplicas, anti-afinidad de pods, un PDB y un `allowTTL` de caché generoso para que las interrupciones breves sean absorbidas por decisiones cacheadas.
- **Ensayá el procedimiento de break-glass**: un camino documentado y probado para quitar el flag del manifiesto del static pod, con el backup tomado *antes* del cambio (paso 1).

**A6.3** `kubectl` no está disponible porque el API server es justamente lo que está caído, así que tenés que ir por debajo, en el nodo del plano de control:

```bash
# 1. Is the container even being created? The kubelet retries static pods continuously.
sudo crictl ps -a --name kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -40

# 2. The kubelet's own view — YAML parse errors in the manifest show up here.
sudo journalctl -u kubelet -n 100 --no-pager | grep -iE 'apiserver|static|manifest|error'

# 3. Container-runtime-level logs if crictl shows nothing.
sudo ls -lt /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/
sudo tail -40 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log

# 4. Recovery.
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

Dos síntomas distintos a diferenciar: si `crictl ps -a` muestra un contenedor en `Exited` con un error de configuración en sus logs, los flags o el archivo de configuración están mal. Si `crictl ps -a` no muestra **ningún contenedor**, el kubelet no pudo parsear el manifiesto del static pod en sí (mala indentación de YAML en tu edición) — y ese error aparece solo en `journalctl -u kubelet`.

**A6.4** El API server reenvía cualquier anotación de pod con el prefijo `*.image-policy.k8s.io/*` al backend en `ImageReview.spec.annotations`, y el backend es libre de actuar sobre ella. La implementación de backend abrumadoramente común trata una anotación de break-glass como "permitir esta imagen a pesar de la política", para que los operadores puedan entregar durante un incidente.

El riesgo de escalada: **el API server no controla quién puede poner esa anotación.** Cualquier sujeto que pueda crear un pod en cualquier namespace puede agregar la anotación y así saltear toda la política de imágenes — convirtiendo un control de seguridad de todo el clúster en un opt-out que cada desarrollador tiene en la mano. Peor, es invisible en RBAC: `can-i create pods` no se lee como "puede saltear la política de imágenes".

Contención:
- **No implementes break-glass en el backend en absoluto** si podés evitarlo; hacé que el camino de excepción sea un cambio en la propia lista blanca del backend, que se audita por separado.
- Si tenés que tenerlo, **controlá la anotación con un segundo control de admisión** — una `ValidatingAdmissionPolicy` o webhook que deniegue cualquier pod que lleve una anotación `*.image-policy.k8s.io/*` a menos que el usuario solicitante (`request.userInfo`) esté en un grupo explícito de break-glass, evaluado *antes* de que la política se saltee.
- **Exigí un valor correlacionado** (un ID de ticket de incidente) que el backend valide contra el sistema de tickets, y **alertá fuerte e inmediatamente** ante cada uso — un break-glass que se dispara en silencio es simplemente un bypass.
- **Hacelo expirar**: que el backend acepte la anotación solo durante una ventana de mantenimiento declarada.

**A6.5** Dos razones para preferir un controlador basado en `ValidatingWebhookConfiguration` (Kyverno, Gatekeeper, sigstore policy-controller):
1. **Expresividad y alcance del objeto.** `ImageReview` le da al backend solo una lista de cadenas de imagen, el namespace y las anotaciones. No puede ver el `securityContext` del pod, sus labels, el usuario solicitante, el controlador dueño, ni nada más — así que no puede expresar "imágenes del registry X solo en el namespace Y", "el equipo A solo puede desplegar su propio repositorio", ni ninguna regla que combine imagen con configuración de pod. Un validating webhook recibe el `AdmissionReview` completo con el objeto entero y `userInfo`.
2. **Seguridad operativa y ciclo de vida.** `ValidatingWebhookConfiguration` es un objeto de la API: soporta exenciones por `namespaceSelector` y `objectSelector`, `failurePolicy` por webhook, `timeoutSeconds` y `matchPolicy`, y puede crearse, modificarse y eliminarse con `kubectl` en tiempo de ejecución por cualquier administrador del clúster. `ImagePolicyWebhook` se configura mediante un archivo en el disco del nodo del plano de control más flags del API server — cada cambio requiere acceso al nodo y un reinicio del API server, no puede ajustarse durante un incidente desde fuera del nodo, y no tiene ningún mecanismo de exención. También sigue siendo `v1alpha1` después de muchas releases, sin capacidad de mutación (así que no puede resolver tags a digests, cf. A8.1).

Una razón por la que sigue valiendo la pena conocerlo: **está en el examen CKS**, y el examen evalúa exactamente esto — editar `/etc/kubernetes/manifests/kube-apiserver.yaml` para agregar `--enable-admission-plugins`, `--admission-control-config-file`, y el `volume`/`volumeMount` correspondiente, y luego recuperar el API server. Más allá del examen, es el único mecanismo de política de imágenes que no requiere ningún componente dentro del clúster, lo que ocasionalmente importa para planos de control estrictamente controlados o air-gapped.

---

### Bloque 7 — ValidatingAdmissionPolicy

**A7.1** La política matchea `Pods`, y `kubectl create deployment` crea un **Deployment**, no un Pod. El Deployment se admite exitosamente; el controlador de deployments crea entonces un ReplicaSet (también admitido); el controlador de ReplicaSet intenta luego crear un Pod, y *esa* solicitud es denegada. Como la denegación ocurre asincrónicamente en un bucle de controlador, `kubectl` hace rato devolvió 0 — el usuario ve un Deployment trabado en `0/1` y debe hurgar en `kubectl describe rs` para encontrar el evento `FailedCreate`. En un pipeline de CI es mucho peor: `kubectl apply` tiene éxito, el pipeline reporta verde, y la falla aparece solo en el monitoreo.

Para que falle en tiempo de apply, **extendé `matchConstraints` para cubrir los recursos de carga de trabajo que llevan pod template** y leé la lista de imágenes desde `object.spec.template.spec` para esos kinds:

```yaml
  matchConstraints:
    resourceRules:
    - apiGroups: ["apps"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    - apiGroups: ["batch"]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["jobs", "cronjobs"]
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods"]
```

con una variable que localice el pod spec sin importar el kind:

```yaml
  - name: podSpec
    expression: >-
      has(object.spec.template) ? object.spec.template.spec :
      (has(object.spec.jobTemplate) ? object.spec.jobTemplate.spec.template.spec : object.spec)
```

Mantené también la regla de Pod — es la red de contención que atrapa pods sueltos y cualquier cosa creada por un controlador que no enumeraste. Fallar temprano sobre el recurso de carga de trabajo es un control de **usabilidad**; la regla de Pod es el control de **seguridad**.

**A7.2** El bypass de una línea: poner la imagen en un **init container**.

```yaml
spec:
  initContainers:
  - {name: pull, image: docker.io/attacker/evil:v1, command: ["/bin/sh","-c","..."]}
  containers:
  - {name: app, image: localhost:5000/healthz@sha256:4d1e...}
```

Los init containers corren hasta completarse *antes* que los contenedores de aplicación, con los mismos volúmenes, el mismo token de ServiceAccount y el mismo namespace de red — una ranura de ejecución con privilegios completos que la política nunca miró. (Un sidecar — un init container con `restartPolicy: Always` — es el mismo bypass pero sigue corriendo junto a la aplicación.)

El bypass por subrecurso: **ephemeral containers**, inyectados vía `kubectl debug`:

```bash
kubectl -n supply debug -it good --image=docker.io/attacker/evil:v1 --target=app
```

Esto es doblemente peligroso porque los ephemeral containers se agregan a través del **subrecurso** `pods/ephemeralcontainers` — un `UPDATE` sobre un subrecurso, no un `CREATE` sobre `pods`. Una entrada de `resourceRules` que lista solo `resources: ["pods"]` no lo matchea; necesitás `resources: ["pods/ephemeralcontainers"]` explícitamente (y la forma del objeto difiere, así que el CEL debe manejarlo). Muchas políticas de producción que manejan correctamente los init containers igual se pierden esta. La misma clase de descuido aplica a `pods/exec` para otros tipos de política.

**A7.3** Para una `ValidatingWebhookConfiguration`, `failurePolicy: Fail` significa "si la **llamada HTTP externa** al webhook falla — el pod está caído, la red está particionada, el certificado TLS expiró, se agotó el timeout — denegá la solicitud". La disponibilidad de toda una clase de operaciones de la API queda acoplada a la disponibilidad de un servicio separado (dentro o fuera del clúster), que es precisamente el deadlock discutido en A6.2 y A8.3.

Para una `ValidatingAdmissionPolicy`, la evaluación es **en proceso dentro del API server**: CEL se compila y evalúa dentro del propio API server. No hay llamada de red, no hay servicio que pueda estar caído, no hay TLS que expire, no hay timeout que se dispare. `failurePolicy: Fail` acá cubre un conjunto de condiciones mucho más estrecho — principalmente errores de evaluación de CEL en tiempo de ejecución (errores de tipo ante formas de objeto inesperadas, agotamiento del límite de costo, división por cero).

Así que el riesgo de disponibilidad es categóricamente menor: una VAP no puede quedar indisponible por una falla de carga de trabajo o de red, y sobrevive un arranque en frío del clúster sin problema de orden de bootstrap. Eso, más la ausencia de un componente que operar y certificados que rotar, es la razón práctica principal para expresar como VAP toda política expresable en CEL y reservar los webhooks para lo que genuinamente los necesita (A8.2). El riesgo restante es distinto en especie: una expresión CEL que lanza error ante una forma de objeto que no anticipaste, con `failurePolicy: Fail`, denegará esa solicitud — que es por qué importan las guardas `has()` sobre `initContainers`/`ephemeralContainers` en el paso 1, y por qué desplegás primero con un binding en `Audit`.

**A7.4** **A favor de la exclusión:** `kube-system` alberga los static pods y mirror pods del propio plano de control, el CNI, los drivers CSI, CoreDNS y kube-proxy — componentes que deben arrancar antes que todo lo demás y cuyas imágenes vienen de `registry.k8s.io` o del registry de un proveedor, no de tu registry de aplicaciones. Incluirlos significa o bien que el clúster no puede hacer bootstrap en absoluto, o bien que tenés que mantener la unión de cada prefijo de imagen de sistema en la política y actualizarla en cada upgrade de Kubernetes y en cada cambio de CNI/CSI. Durante un incidente, un operador a menudo necesita correr un pod de debug con una imagen arbitraria en un nodo del plano de control; una denegación dura en `kube-system` le quita esa opción en el peor momento.

**En contra:** `kube-system` es el **namespace de mayor valor del clúster**. Los pods de ahí frecuentemente corren con host network, host PID, security contexts privilegiados, montajes hostPath del sistema de archivos del nodo, y ServiceAccounts con permisos amplísimos. Un atacante que puede crear un pod en `kube-system` — vía un operador comprometido, una concesión RBAC demasiado amplia, o un controlador con `create pods` a nivel de clúster — ahora no enfrenta ninguna restricción de imagen, y puede descargar una imagen arbitraria directo a un nodo del plano de control. Eximiste exactamente el lugar donde el control más importa.

La reconciliación: eximí a `kube-system` de la **lista blanca de registries** solo si tenés que hacerlo, pero (a) reemplazá la exención por una lista blanca *más amplia* en vez de ninguna política — listá `registry.k8s.io/`, los registries de tus proveedores y tu mirror interno explícitamente; (b) mantené la regla de fijado por digest aplicada ahí; (c) restringí estrictamente quién puede crear pods en `kube-system` vía RBAC, que es el control real; y (d) mantené un binding `Audit`+`Warn` sin exclusión de namespace, para que incluso donde no denegás tengas un registro de cada imagen de sistema que habría fallado la política.

**A7.5** `Deny` y `Audit` no son redundantes porque producen **artefactos distintos**. `Deny` rechaza la solicitud y devuelve un error al cliente — quien llama lo ve, pero no queda registrado nada duradero que un equipo de seguridad pueda consultar después. `Audit` agrega una anotación (`validation.policy.admission.k8s.io/validation_failure`) a la entrada del **log de auditoría del API server** para esa solicitud, capturando el nombre de la política, el binding, el mensaje de la expresión fallida, el usuario solicitante y el contexto completo de la solicitud.

Usar ambos te da: aplicación *y* un registro duradero, enviado centralmente y consultable de cada evento de aplicación. Ese registro es lo que te permite responder "¿quién viene intentando desplegar imágenes de registries no aprobados, y con qué frecuencia?" — lo que distingue a un desarrollador que no actualizó sus manifiestos de un atacante sondeando tus controles. Sin `Audit`, las denegaciones existen solo como cadenas de error transitorias en la terminal de alguien o en un log de CI que rota y desaparece.

El emparejamiento relacionado es `Warn`, que devuelve el mensaje como un encabezado `Warning:` que `kubectl` muestra sin bloquear. `["Audit", "Warn"]` es el despliegue estándar en **modo sombra** (paso 7): a los usuarios se les avisa, seguridad ve el volumen, nada se rompe. Una vez que el log de auditoría muestra una tasa de violación cercana a cero, pasás a `["Deny", "Audit"]`.

---

### Bloque 8 — verificación de firmas en admisión

**A8.1** `mutateDigest: true` cierra la brecha entre **el momento en que la política verificó una imagen** y **el momento en que el kubelet la descarga**.

Sin ello, el flujo es: el pod dice `healthz:slim` → Kyverno resuelve ese tag al digest D, verifica la firma de D, permite el pod → el pod spec sigue diciendo `healthz:slim` → algunos segundos, minutos o (en un reinicio posterior) meses después, el kubelet resuelve `healthz:slim` otra vez. Si el tag se movió en el medio — Ejercicio 4, exactamente — el kubelet descarga el digest D′, que nunca fue verificado y puede no tener ninguna firma. La verificación se realizó sobre un artefacto y la garantía se transfirió silenciosamente a otro. Peor, esto se repite en cada reinicio, reagendamiento y scale-up, para siempre, con la política reportando éxito cada vez.

Con `mutateDigest: true`, Kyverno **reescribe el pod spec** al digest que verificó antes de admitirlo. El objeto persistido nombra un artefacto inmutable, así que el kubelet solo puede descargar exactamente los bytes que fueron verificados, ahora y en cada reinicio futuro. Como bonus, la carga de trabajo en ejecución se vuelve auto-documentada para auditoría (A4.1 / A11.1).

El principio general: cualquier política que verifique una referencia mutable debe o bien fijarla o bien re-verificar en el momento de uso. Kubernetes no te da ningún hook en el momento del pull, así que fijar en admisión es la única opción.

**A8.2** Porque la verificación de firmas no es una **decisión sobre el objeto que se está admitiendo** — es una decisión que requiere **E/S externa y criptografía**:
- Debe **descargar** artefactos adicionales del registry (los objetos `.sig` y `.att`, la cadena de certificados), lo que implica llamadas de red salientes autenticadas con credenciales del registry.
- Debe realizar **verificación criptográfica**: validación de firma ECDSA/RSA, validación de la cadena de certificados contra las raíces de Fulcio, y verificación de la prueba de inclusión en Rekor.
- Puede necesitar **consultar un log de transparencia** por red.

CEL en una `ValidatingAdmissionPolicy` corre en proceso dentro del API server bajo un presupuesto de costo estricto, es deliberadamente **libre de efectos secundarios y no Turing-completo**, y no tiene acceso a red, ni primitivas criptográficas, ni cliente de registry. Esto es por diseño — es lo que hace seguro correr VAP en el camino crítico del API server (A7.3). En el momento en que una política necesita hablar con algo fuera de la solicitud, necesita un webhook.

La división práctica: usá `ValidatingAdmissionPolicy` para todo lo decidible a partir del objeto mismo (prefijos de registry, fijado por digest, campos de `securityContext`, requisitos de labels, límites de recursos) y un controlador webhook para la verificación de firmas y attestations. Correr ambos es la configuración de producción normal — VAP como línea base barata y siempre disponible que no puede ser tumbada por una falla de carga de trabajo, más el webhook para las aserciones criptográficas.

**A8.3** El deadlock: en un arranque en frío del clúster, el kubelet inicia los static pods del plano de control, y el API server levanta y carga los objetos `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` desde etcd. Con `failurePolicy: Fail`, cada creación de pod debe ahora ser aprobada por el servicio de Kyverno — pero los propios pods de Kyverno todavía no arrancaron, así que la llamada del API server a `kyverno-svc` falla, así que las creaciones de pods son denegadas, **incluidos los propios pods de Kyverno**. Nada puede arrancar nunca. Lo mismo pasa si todas las réplicas de Kyverno son desalojadas simultáneamente, si el nodo que las corre falla y los pods de reemplazo no pueden ser admitidos, o si un cambio de NetworkPolicy corta el camino API server → webhook.

Las dos mitigaciones estándar:
1. **Exclusiones de namespace y de objeto.** La configuración del webhook debe eximir el namespace donde corre Kyverno mismo, más `kube-system` y los namespaces de infraestructura crítica (CNI, CSI, DNS), vía `namespaceSelector`/`objectSelector`. Kyverno trae esto por defecto — su chart de Helm inyecta una exclusión para su propio namespace y para `kube-system` — y la caída autoinfligida clásica es un operador "endureciendo" la configuración al quitarlas.
2. **Alta disponibilidad más garantías de scheduling**, para que el webhook nunca esté completamente ausente: ≥3 réplicas, anti-afinidad dura de pods entre nodos, un `PodDisruptionBudget`, `priorityClassName: system-cluster-critical` para que sea agendado y nunca desalojado por preempción, y tolerations que le permitan correr en nodos del plano de control.

Una tercera práctica complementaria: fijar un `webhookTimeoutSeconds` corto con `failurePolicy: Ignore` en las reglas *no críticas* manteniendo `Fail` solo en las reglas que no deben ser salteadas — aceptando un radio de impacto menor en vez de una elección de todo-o-nada. Y mantené siempre documentado el procedimiento de break-glass: `kubectl delete validatingwebhookconfiguration ...` desde un nodo del plano de control, lo cual requiere que el API server sea alcanzable — una razón más para eximir `kube-system`.

**A8.4** **No, no se verifica.** `localhost:5000/healthz*` es un glob, y `healthzevil` matchea el prefijo `healthz` seguido de `evil` — esperá, más precisamente: el glob *sí* matchea `localhost:5000/healthzevil:v1`, así que la política *sí* aplicaría, y como la imagen del atacante no está firmada sería **rechazada**. El caso peligroso es la imagen especular de este, y es el que importa: un glob demasiado *estrecho*, o una referencia de imagen que no matchea el patrón en absoluto, **silenciosamente no es evaluada** — las reglas `verifyImages` solo aplican a las referencias que matchean, y una imagen no matcheada se admite sin ninguna verificación.

Así que la trampa real es `imageReferences: ["localhost:5000/healthz*"]` combinado con un atacante desplegando `docker.io/attacker/evil:v1` — que no matchea nada, no dispara ninguna regla, y se admite sin verificar. La política que parece decir "verificamos firmas" en realidad significa "verificamos firmas en imágenes cuyos nombres nos tocó listar".

La lección sobre los globs: **escribí la política de referencias de imagen como default-deny, no como default-allow.** Matcheá ampliamente (`"*"`) y recortá excepciones explícitamente, en vez de matchear estrechamente y esperar que la lista esté completa. Combinalo con la lista blanca de registries del Ejercicio 7 para que cualquier cosa que no venga de un registry aprobado sea rechazada antes de que la verificación de firma sea siquiera relevante — las dos políticas se componen en "solo registries aprobados, y todo lo que venga de ellos debe estar firmado". También preferí patrones anclados y conscientes de delimitadores (`localhost:5000/healthz:*` o `localhost:5000/healthz@*`) por sobre globs de prefijo pelados, ya que `*` cruza alegremente los límites `:`/`/` que un lector humano asume que respeta.

**A8.5** Una imagen firmada igual puede ser maliciosa porque una firma atestigua la **procedencia de la aprobación, no la seguridad del contenido** (cf. A5.5). Concretamente: la clave de firma o la identidad de workflow pueden ser comprometidas; un builder legítimo puede ser comprometido y firmar un artefacto con puerta trasera; un insider malicioso o coaccionado con derechos de firma puede firmar deliberadamente; una dependencia traída durante un build legítimo puede ser maliciosa, produciendo una imagen honestamente firmada que contiene la puerta trasera de otro; y una imagen firmada legítimamente el año pasado puede contener una vulnerabilidad descubierta desde entonces.

El control que aborda el riesgo residual es la **seguridad en runtime** — el supuesto de que los controles en tiempo de admisión eventualmente serán salteados, así que el comportamiento debe monitorearse donde el código realmente se ejecuta. En la práctica: una herramienta de detección de amenazas en runtime consumiendo eventos de syscalls (Falco, Tetragon, o un EDR basado en eBPF) que alerte sobre ejecución de procesos, conexiones salientes y escrituras de archivos que no coincidan con el perfil de la carga de trabajo; combinado con el endurecimiento de runtime que limita lo que un proceso comprometido puede hacer siquiera — `readOnlyRootFilesystem`, capabilities descartadas, `runAsNonRoot`, seccomp `RuntimeDefault`, perfiles AppArmor/SELinux, NetworkPolicies restrictivas (default-deny de egreso en particular), y ServiceAccounts de mínimo privilegio.

El control complementario del lado de la cadena de suministro es la **reevaluación continua**: re-escanear los SBOMs firmados y entregados contra una base de datos de vulnerabilidades actual (A3.4) para que "firmado y verificado" no se calcifique en "confiable para siempre".

---

### Bloque 9 — endurecimiento de CI/CD

**A9.1** El análogo directo es el **Ejercicio 4** — fijado por digest de imágenes de contenedor. Un tag de Git en una GitHub Action de terceros es mutable exactamente como un tag OCI: el dueño de la action (o cualquiera que comprometa su cuenta) puede mover `v4` para que apunte a un commit nuevo, y cada workflow que referencie `@v4` ejecuta el código nuevo en su próxima corrida, con acceso completo a los secretos del job, al `id-token` y a las credenciales de push del registry — sin que cambie una sola línea en tu repositorio.

El principio compartido: **referenciá contenido inmutable por su identidad criptográfica, nunca por una etiqueta mutable controlada por un tercero.** Un digest y un SHA de commit están direccionados por contenido y no pueden reapuntarse; un tag y una rama son punteros cuyo destino controla otra persona. Este es el mismo modo de falla en cada capa de la cadena — imágenes base, versiones de actions, versiones de charts de Helm, rangos `^1.2.0` de paquetes — y es por eso que el compromiso al estilo `tj-actions/changed-files`, donde los tags de una action ampliamente usada fueron reapuntados a código malicioso, se propagó a decenas de miles de repositorios en horas.

**A9.2** Por defecto, `actions/checkout` escribe el `GITHUB_TOKEN` del job en `.git/config` como credencial `http.extraheader` para que los comandos `git` posteriores del job puedan autenticarse. Esa credencial queda entonces **en un archivo en disco, dentro del contexto de build**.

La escalada específica que previene: el job corre `docker build` sobre archivos influenciables por el atacante. Un `Dockerfile` (o un cambio de `.dockerignore`, o un script de build que el Dockerfile invoca) aportado vía un pull request puede simplemente hacer `COPY .git/config /tmp/` — o correr `RUN cat /.git/config` — y exfiltrar el token a un endpoint controlado por el atacante, o escribirlo dentro de una capa de la imagen publicada. Lo mismo aplica a cualquier paso `RUN`, cualquier target de `make`, cualquier script de ciclo de vida de `npm`, cualquier test que el job ejecute: todos pueden leer el directorio de trabajo del repositorio, y por lo tanto la credencial.

Con `persist-credentials: false`, el checkout usa el token para el fetch y después lo elimina; no queda nada duradero en disco para que el resto del job lo robe. Combinado con el `permissions: contents: read` por defecto a nivel de workflow, incluso un token robado sería de solo lectura en vez de tener capacidad de push — defensa en profundidad, ya que un token con capacidad de push en un job de build significa que un atacante puede commitear directo al repositorio y así ser dueño de cada build futuro.

**A9.3** Firmar el tag crea una **carrera de tiempo-de-verificación / tiempo-de-uso entre el push y la firma** — la versión del lado de CI de A8.1.

La secuencia: el paso de build hace push de la imagen y la etiqueta `ghcr.io/acme/healthz:v1.4.2`, produciendo el digest D. El workflow después corre `cosign sign ghcr.io/acme/healthz:v1.4.2` como un paso separado. Entre esos dos pasos, un atacante con acceso de escritura al registry — una credencial de robot filtrada, un job paralelo comprometido, un segundo workflow disparado por el mismo tag, o un build de un fork malicioso que comparte acceso al registry — hace push de su propia imagen y mueve `v1.4.2` al digest D′. `cosign sign` entonces resuelve el tag, encuentra D′, y **firma la imagen del atacante con tu clave legítima**. La firma es válida, la verificación pasa, y el control de admisión la admite. Tu propio pipeline lavó el artefacto del atacante.

Firmar `steps.build.outputs.digest` elimina la carrera por completo: el valor lo captura el propio paso de build en el momento del push, y un digest no puede reapuntarse. El mismo razonamiento aplica a cada paso posterior — la generación del SBOM y la attestation de ese workflow también se apoyan en `steps.build.outputs.digest`, no en el tag, así que el inventario, la firma y el artefacto son todos demostrablemente sobre los mismos bytes.

**A9.4** Asumiendo que los builds de PR corren con la ServiceAccount `ci:deployer` que tiene `cluster-admin`:

1. **El atacante abre un pull request** contra el repositorio desde un fork. En muchas configuraciones por defecto no se requiere revisión para que corra CI (`pull_request_target`, o un runner autohospedado configurado para construir PRs).
2. **El PR modifica un archivo que el build ejecuta** — el `Dockerfile`, un target del `Makefile`, un archivo de test, un script `postinstall` de `npm`, o el bloque `run:` en línea de un paso del workflow. Ahora se ejecuta código arbitrario en el runner con el entorno completo del job.
3. **El código del atacante lee la credencial de la ServiceAccount** — el token montado en `/var/run/secrets/kubernetes.io/serviceaccount/token` si el runner es él mismo un pod, o el kubeconfig/secreto `KUBE_TOKEN` inyectado en el job.
4. **El token es `cluster-admin`.** El atacante ahora tiene control total del clúster desde el runner, o puede exfiltrar el token y usarlo desde cualquier lugar donde el API server sea alcanzable.
5. **Persistencia y expansión**: crear un DaemonSet privilegiado con `hostPID: true` y un montaje `hostPath` de `/`, obteniendo root en cada nodo; leer cada Secret de cada namespace, incluidas credenciales de nube, contraseñas de bases de datos y las credenciales de push del registry; crear un ClusterRoleBinding nuevo para una ServiceAccount que controle para que el acceso sobreviva a la rotación del token; y — cerrando el círculo — usar las credenciales de registry robadas para envenenar imágenes consumidas por otros clústeres (A9.3, A10.1).

Las fallas que se acumulan: los builds de PR no deberían tener credenciales de despliegue en absoluto (build y deploy deben ser jobs separados con identidades separadas, y deploy debería correr solo desde una rama o tag protegido con reglas de protección de entorno); la identidad de despliegue debería estar acotada a un namespace y limitada en verbos (paso 6); los runners que ejecutan código no confiable deben ser efímeros y aislados; y la credencial del clúster debería ser un token de vida corta federado por OIDC en vez de un secreto estático (paso 7).

**A9.5** Dos propiedades ganadas por `kubectl create token --duration=10m`:
1. **Vida útil acotada.** El token expira. Una credencial filtrada en un log de build, un core dump, un reporte de error o un volcado de entorno exfiltrado no vale nada minutos después, lo que colapsa la ventana entre el compromiso y la contención y hace imposible el cracking offline o la reutilización posterior. Un Secret `kubernetes.io/service-account-token` heredado **no tiene ninguna expiración** — es válido hasta que se borre el Secret o la ServiceAccount, lo que en la práctica significa para siempre.
2. **Ninguna credencial en reposo, y ligadura de audiencia/objeto.** El token nunca se persiste en etcd como Secret, así que no es legible por nadie con `get secrets` en ese namespace, no queda capturado en un backup de etcd, ni queda expuesto por una vulnerabilidad de listado de Secrets. Lo emite la API TokenRequest con un claim `aud` (y opcionalmente ligado a un objeto específico vía `--bound-object-kind`/`--bound-object-name`), así que no puede reproducirse contra una audiencia distinta, y un token ligado a un pod se invalida automáticamente cuando ese pod se elimina. Los tokens ligados también llevan la identidad al log de auditoría con más precisión.

La cosa operativa que rompe: **ya no hay una credencial estable y de larga vida para entregarle a un sistema externo.** Cualquier cosa que espere ser configurada una vez con un token estático — la integración de Kubernetes de una plataforma de CI, un dashboard de terceros, un agente de monitoreo fuera del clúster, un archivo `kubeconfig` en la laptop de alguien — ahora necesita un **mecanismo de refresco**: debe llamar a la API TokenRequest antes del vencimiento y rotar la credencial en el lugar. Las cargas de trabajo dentro del clúster obtienen esto gratis (el kubelet proyecta y rota el token vía un volumen proyectado `serviceAccountToken`), pero los consumidores externos necesitan o bien un plugin de exec-credential, o federación OIDC/workload-identity, o un pequeño job de rotación. Los equipos que saltean ese trabajo invariablemente vuelven a un Secret de larga vida, así que planificá el camino de refresco antes de quitar el token estático.

---

### Bloque 10 — repositorios de artefactos

**A10.1** Una credencial filtrada de **solo pull** es una brecha de **confidencialidad**: el atacante puede descargar e inspeccionar tus imágenes privadas — leyendo código propietario, configuración embebida y cualquier secreto que builds descuidados hayan horneado en las capas (un hallazgo genuinamente común; `trivy image --scanners secret` existe por algo). Pueden enumerar tus repositorios y tags, aprendiendo tu arquitectura interna y tu historial de versiones, lo que es excelente reconocimiento. Pero no pueden cambiar lo que nadie corre.

Una credencial filtrada **con capacidad de push** es una brecha de **integridad** y es categóricamente peor: el atacante puede sobrescribir tags mutables (Ejercicio 4), así que cada nodo que descargue después corre su código — silenciosamente, sin que cambie ningún objeto de Kubernetes y sin que se dispare ninguna alerta. Puede hacer push de una imagen maliciosa bajo un tag nuevo plausible; puede borrar artefactos para causar caídas; y si las firmas se almacenan en el mismo repositorio como artefactos OCI, puede llegar a borrar o sobrescribir los objetos `.sig`/`.att`. En efecto, una credencial de push filtrada otorga **ejecución de código arbitrario en cada carga de trabajo que consume ese repositorio**, a través de cada clúster y cada entorno, con el compromiso aparentando originarse en tu propio registry confiable.

De ahí las reglas: cuentas de robot acotadas a un solo proyecto con un solo verbo; el `imagePullSecret` del clúster es siempre de solo pull y nunca la cuenta de CI; las credenciales de push existen solo en el job de release, nunca en builds de PR (A9.4); y el registry aplica tags inmutables para que ni siquiera una credencial de push robada pueda reescribir la historia.

**A10.2** `AlwaysPullImages` muta el `imagePullPolicy` de cada pod a `Always` en admisión, forzando al kubelet a contactar al registry — y por lo tanto a **autenticarse** — en cada arranque de contenedor.

El ataque que detiene es la **reutilización entre inquilinos de imágenes privadas cacheadas en el nodo** (A4.3): sin ello, cualquier usuario que pueda crear un pod en un nodo puede correr cualquier imagen previamente descargada a ese nodo, sin importar si su namespace tiene credenciales para ese registry. También, como efecto secundario, elimina el no-determinismo de caché rancia de A4.2, asegurando que todas las réplicas de una carga de trabajo etiquetada converjan al mismo digest.

Los dos costos operativos:
1. **Latencia y carga sobre el registry.** Cada arranque de contenedor se vuelve un viaje de ida y vuelta al registry. Incluso cuando todas las capas están cacheadas y solo se descarga el manifiesto, esto agrega latencia de arranque y multiplica las solicitudes al registry por la tasa de rotación de pods — significativo para clústeres grandes, para CronJobs, y para pods en CrashLoopBackOff martillando el registry en cada reinicio.
2. **Una dependencia dura de la disponibilidad del registry.** Si el registry está caído, inalcanzable, limitando por tasa (los límites de pull anónimo de Docker Hub son un incidente de producción clásico), o la credencial expiró, **los pods no pueden arrancar** — incluso durante una falla de nodo o una recuperación del clúster, exactamente cuando más los necesitás. Convertiste una dependencia blanda en una dura, e hiciste del registry un componente crítico para el plano de control que requiere su propia HA y monitoreo. Mitigalo con un mirror de caché pull-through (paso 6) que sea a su vez de alta disponibilidad.

**A10.3** Más allá de la elección de registry, un nombre sin calificar como `nginx:1.27` es riesgoso porque el nombre es **resuelto por la configuración del container runtime, no por el manifiesto**. El manifiesto no dice de dónde viene la imagen; el runtime le agrega un valor por defecto. Consecuencias:

- **La resolución difiere por runtime y por nodo.** Docker y containerd usan por defecto `docker.io/library/`, pero los `registry.mirrors` de `containerd`, los `unqualified-search-registries` de CRI-O en `/etc/containers/registries.conf`, y la lista de búsqueda de Podman pueden configurarse para resolver nombres sin calificar contra un registry completamente distinto — y esa configuración vive en el nodo, editable por cualquiera con acceso al nodo. **El mismo manifiesto puede descargar imágenes distintas en nodos distintos**, y un atacante con acceso a nivel de nodo puede redirigir silenciosamente cada pull de imagen sin calificar a un registry que controla.
- **Derrota la lista blanca de registries.** Una política que matchea por prefijos (Ejercicio 7) ve la cadena literal `nginx:1.27`, que no matchea ningún prefijo aprobado y sería denegada — bien — pero una política escrita para permitir `docker.io/` *tampoco* la matcheará, así que las listas blancas ingenuas matchean de más y de menos a la vez. Exigir nombres completamente calificados es un prerrequisito para que cualquier política de registry sea significativa.
- **Typosquatting y confusión de namespaces.** `nginx` resuelve a la imagen *oficial* `library/nginx`, pero `ngnix`, o un nombre que hoy resuelve a una imagen oficial y mañana a una en el namespace de un usuario, no. Los nombres sin calificar ocultan qué namespace de qué registry se está confiando realmente.
- **Egreso a internet sin control.** Implica que los nodos alcanzan Docker Hub directamente, exponiéndote a límites de tasa, a disponibilidad fuera de tu control, y a un camino de egreso que saltea tu mirror y sus políticas de escaneo.

El control es exigir en la política referencias completamente calificadas y fijadas por digest — que es lo que las reglas del Ejercicio 7 ya hacen, ya que `nginx:1.27` no matchea ningún prefijo permitido y no contiene ningún `@sha256:`.

**A10.4** Protegen contra el mismo ataque en **puntos distintos de la cadena, bajo modelos de amenaza distintos**.

- **El fijado por digest** es un control del *lado del consumidor* que vive en tus manifiestos. Te protege incluso si el registry está totalmente comprometido o mal configurado, porque ya no le estás pidiendo al registry que resuelva un nombre — estás exigiendo bytes específicos, y el runtime verifica el hash del contenido al descargar. Pero solo protege a las cargas de trabajo cuyos manifiestos están realmente fijados.
- **Las reglas de tags inmutables** son un control del *lado del productor* que vive en el registry. Impiden que la mutación ocurra siquiera, protegiendo a cada consumidor — incluidos los que no controlás, los que tienen manifiestos sin fijar, y los desarrolladores que corren `docker pull` en sus laptops.

Implementá ambos porque cada uno cubre el hueco del otro. El fijado por digest no hace nada por las muchas referencias que no están fijadas (charts de Helm de terceros, el `kubectl run` de un colega, la imagen base en una línea `FROM` de un job de CI). Los tags inmutables no hacen nada si el atacante hace push de un tag *nuevo* y usa ingeniería social o automatización para su adopción, ni nada contra un registry comprometido o un MITM.

El que te protege cuando un desarrollador saltea el pipeline es la **regla de tags inmutables** — se aplica del lado del servidor en el registry, así que rige sin importar quién hace push, desde dónde, con qué herramental y con cuánta disciplina. El fijado por digest es una convención que requiere que todos la sigan; la inmutabilidad es una propiedad que no.

**A10.5** Creaste **un único cuello de botella aguas arriba cuyo compromiso envenena cada imagen del clúster**. Si el registry de caché proxy se compromete — o simplemente se configura mal, o su caché se envenena — un atacante puede servir capas modificadas para `registry.k8s.io/kube-proxy`, para tus imágenes base, para todo, y cada nodo las acepta porque el registry es la fuente confiable y ningún nodo tiene un camino independiente contra el cual comparar. También lo convertiste en una dependencia dura de disponibilidad (A10.2) y en un objetivo de alto valor que concentra credenciales para cada registry aguas arriba.

Los controles compensatorios que lo mantienen honesto:
- **Fijado por digest de punta a punta** (A10.4). Si los manifiestos exigen un digest específico, un proxy comprometido no puede sustituir contenido distinto: el runtime verifica el hash del contenido contra el digest solicitado y la descarga falla. Esta es la respuesta individual más fuerte — hace que el proxy sea no-confiable-por-construcción para la integridad del contenido.
- **Verificación de firmas en admisión** (Ejercicio 8) usando claves o identidades ancladas *fuera* del proxy, para que el contenido servido por el mirror igual deba verificar contra la firma del publicador original. Las imágenes upstream firmadas con Sigstore (las imágenes de `registry.k8s.io` están firmadas) pueden verificarse contra las raíces públicas de Fulcio/Rekor sin importar qué mirror entregó los bytes.
- **Endurecé y monitoreá el proxy mismo**: tratalo como infraestructura crítica del plano de control — RBAC estricto sobre quién puede hacer push o configurarlo, tags inmutables y content trust habilitados, logging de auditoría en cada push y cambio de configuración, y alertas ante cualquier escritura a un repositorio cacheado por proxy (una caché pull-through nunca debería recibir pushes directos; una que los recibe está siendo envenenada).
- **Verificación independiente**: comparar periódicamente los digests servidos por el mirror contra los digests del registry upstream para los mismos tags, desde un host con su propio camino de egreso, y alertar ante divergencias.

---

### Bloque 11 — trazado punta a punta

**A11.1** Confiá en `.status.containerStatuses[].imageID`. Es el digest que el kubelet **realmente resolvió y corrió**, reportado por el container runtime después de la descarga — una afirmación de hecho sobre bytes en disco. `.spec.containers[].image` es una afirmación de *intención* registrada cuando se creó el objeto, y cuando contiene un tag es un puntero mutable (A4.1).

Si los dos no coinciden, el desacuerdo es en sí mismo el hallazgo: significa que el tag se movió desde que arrancó este pod, así que otros pods de la misma carga de trabajo — creados antes o después de la mutación, o en nodos con distinto estado de caché (A4.2) — pueden estar corriendo **código distinto bajo un spec idéntico**. Durante un incidente esa es exactamente la señal que necesitás: el spec te dice qué quiso desplegar alguien, el status te dice qué se está ejecutando, y la diferencia te dice que hubo una sustitución y aproximadamente cuándo.

Salvedad práctica: los formatos de `imageID` varían según el runtime (containerd típicamente reporta `registry/repo@sha256:<manifest-digest>`; algunos runtimes reportan en cambio el digest de *config*, y Docker históricamente reportaba `docker-pullable://…`). Normalizá antes de comparar, y cuando lo que tenés es el digest de config, resolvelo contra el registry (`crane config`) en vez de asumir que es igual al digest del manifiesto.

**A11.2** **Ventaja:** es rápido, offline y funciona para artefactos que ya no podés alcanzar. No necesitás acceso al registry, ni descargar la imagen, ni un pod en ejecución, ni un rebuild — así que podés volver a responder la pregunta de exposición para miles de imágenes en segundos, incluidas imágenes que fueron borradas del registry, que están en un entorno air-gapped, o que pertenecen a un clúster al que perdiste acceso. También es **verificable**: el SBOM salió de una attestation firmada cuyo sujeto matchea el digest, así que el inventario es atribuible y a prueba de manipulación en vez de ser lo que un escáner reporte hoy. Esto es lo que convierte el "¿estoy afectado por el CVE-X?" a escala de flota en una consulta en vez de un proyecto (A3.4).

**Limitación:** estás confiando en el inventario tal como fue registrado en tiempo de build por una herramienta con una configuración de catalogadores — así que **todo lo que esa herramienta se perdió es permanentemente invisible**. El `busybox` vendorizado del Ejercicio 2, las bibliotecas enlazadas estáticamente, los archivos copiados sin metadatos de paquete, y cualquier cosa agregada por un paso posterior de `docker build` que el catalogador no entendió simplemente no existen para este escaneo, y ninguna cantidad de actualizaciones de base de datos los hará aparecer. El SBOM almacenado tampoco puede reflejar la **deriva en runtime**: paquetes instalados dentro de un contenedor en ejecución, archivos escritos en un sistema de archivos raíz escribible, o código cargado dinámicamente después del arranque. Y si la imagen fue reconstruida y el tag reapuntado sin una nueva attestation, puede que estés escaneando el inventario de un artefacto que ya no está corriendo.

La postura correcta es ambas: escaneo basado en SBOM por amplitud y velocidad a lo largo de la flota, más re-escaneo directo periódico de las imágenes vivas (y detección en runtime, A8.5) para atrapar lo que el inventario registrado no puede ver.

**A11.3** La procedencia es solo una **afirmación firmada por el builder**, así que vale exactamente tanto como la integridad del builder y la solidez del vínculo entre commit y build. Para que `commit 9a1c7f0` signifique algo, además necesitás:

- **Un builder confiable, aislado y con identidad verificable.** La procedencia debe estar firmada por una identidad de builder que puedas fijar (`--certificate-identity-regexp` contra un archivo de workflow y ref específicos, A5.2), corriendo sobre infraestructura que el solicitante no pueda influenciar — si no, cualquiera puede producir un documento afirmando cualquier commit. Esta es la sustancia de los niveles de build de SLSA: en L3 la plataforma de build genera la procedencia ella misma, y las entradas y el entorno del build están aislados del usuario que solicita el build.
- **Integridad del commit y de la rama de la que vino.** Protección de rama y revisión obligatoria, para que `9a1c7f0` haya llegado a la ref de release por un camino controlado; idealmente **commits/tags firmados** para que el commit en sí sea atribuible, y un tag protegido para que `v1.4.2` no pueda reapuntarse a un commit distinto (la versión a nivel Git de A4.1).
- **Un registro duradero y a prueba de manipulación.** El historial de Git no debe admitir force-push en esa ref, y el repositorio debe seguir existiendo — una procedencia que apunta a un commit que fue reescrito o borrado es inverificable. Una entrada en Rekor (A5.4) provee la marca temporal confiable que prueba cuándo se hizo la afirmación.
- **Reproducibilidad, idealmente.** La forma más fuerte de la afirmación es una que puedas verificar independientemente: reconstruir desde `9a1c7f0` bajo las mismas condiciones herméticas y obtener el mismo digest.

Sin esto, "construido desde el commit 9a1c7f0" es una auto-afirmación de quien tenía la clave de firma — informativa para depurar, inútil como evidencia.

**A11.4** Casi con seguridad: **se desplegó una imagen desde afuera de tu cadena de suministro por completo** — descargada de un registry público o controlado por el atacante, o cargada directamente en el container runtime del nodo (`crictl pull` / `ctr images import` / un `docker load` por alguien con acceso al nodo), lo que produce un digest que no existe en ningún registry que operes y que no tiene firma, ni SBOM, ni procedencia porque nunca pasó por tu sistema de build. Esta es la firma de o bien una carga de trabajo/operador comprometido con derechos de creación de pods, o bien un operador salteando el pipeline "solo esta vez" durante un incidente.

Controles de los ejercicios anteriores que lo habrían prevenido:
- **Ejercicio 7 — lista blanca de registries con `ValidatingAdmissionPolicy` más fijado por digest obligatorio.** Una imagen de un registry no aprobado se rechaza en admisión de plano; este es el control más barato y robusto, no necesita ningún componente externo, y no puede ser tumbado por una falla de carga de trabajo.
- **Ejercicio 8 — `verifyImages` de Kyverno con `required: true` y `mutateDigest: true`.** Incluso una imagen de un registry aprobado se rechaza a menos que exista una firma y attestation válidas, y el spec admitido se reescribe al digest verificado para que la garantía sobreviva a los reinicios.
- **Ejercicio 10 — `AlwaysPullImages`, más restricción de egreso al registry/proxy interno.** Fuerza a que cada arranque de contenedor pase por una descarga autenticada del registry, lo que derrota la variante de carga lateral en el nodo: una imagen presente solo en la caché local del nodo ya no puede correrse, y la descarga misma falla si la fuente es inalcanzable.
- **De apoyo: RBAC.** Restringí quién y qué puede crear pods, especialmente en namespaces privilegiados (A7.4) y especialmente para operadores e identidades de CI (A9.4) — la capacidad de crear un pod en cualquier lado es la precondición de todo esto.

El orden importa operativamente: la regla de registry/digest de la VAP es la línea base siempre activa, la verificación de firmas es la aserción criptográfica encima, `AlwaysPullImages` más el control de egreso cierra el bypass local del nodo, y RBAC limita quién llega a intentarlo.

</details>

---

## Referencias

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Using Admission Controllers* (`ImagePolicyWebhook`, `AlwaysPullImages`, `NodeRestriction`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Kubernetes, *Common Expression Language in Kubernetes* — https://kubernetes.io/docs/reference/using-api/cel/
- Kubernetes, *Images* (políticas de pull, image pull secrets) — https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes, *Pull an Image from a Private Registry* — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- Kubernetes, *Service Account Token Volume Projection / TokenRequest* — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes, *Auditing* — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Sigstore, *cosign documentation* — https://docs.sigstore.dev/cosign/signing/overview/
- Sigstore, *Rekor transparency log* — https://docs.sigstore.dev/logging/overview/
- in-toto, *Attestation specification* — https://github.com/in-toto/attestation/blob/main/spec/README.md
- SLSA, *Supply-chain Levels for Software Artifacts v1.0* — https://slsa.dev/spec/v1.0/levels
- Anchore, *Syft* — https://github.com/anchore/syft · *Grype* — https://github.com/anchore/grype
- Aqua Security, *Trivy documentation* — https://trivy.dev/latest/docs/
- SPDX, *Specification v2.3* — https://spdx.github.io/spdx-spec/v2.3/
- OWASP, *CycloneDX Specification* — https://cyclonedx.org/specification/overview/
- OpenVEX, *Specification* — https://github.com/openvex/spec
- Kyverno, *Verify Images* — https://kyverno.io/docs/writing-policies/verify-images/
- Sigstore, *Policy Controller* — https://docs.sigstore.dev/policy-controller/overview/
- Google, *Distroless container images* — https://github.com/GoogleContainerTools/distroless
- Docker, *Build attestations (provenance and SBOM)* — https://docs.docker.com/build/metadata/attestations/
- OpenSSF, *Security Scorecard* — https://github.com/ossf/scorecard
- GitHub, *Security hardening for GitHub Actions* — https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions