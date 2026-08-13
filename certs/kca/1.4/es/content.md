# Tema 1.4 — OCI Images

> Dominio 1 · Peso en el examen: **4.5** · Perfil: SRE / Platform Architect
> Términos técnicos en inglés; explicación en español.

---

## 1. Motivación y problema arquitectónico de producción

Antes de la Open Container Initiative (OCI, fundada en 2015 bajo la Linux Foundation con la donación del formato y el runtime de Docker), "una imagen de contenedor" era un artefacto **propietario y acoplado a un solo builder y un solo runtime**. Docker definía tanto el formato en disco como el protocolo de registry como el runtime. Esto generaba tres problemas que en producción se pagan caro:

1. **Lock-in de toolchain.** Si tu pipeline construía con `docker build`, no podías construir sin un daemon `dockerd` privilegiado corriendo en el nodo de CI. En un cluster Kubernetes, esto significaba montar `/var/run/docker.sock` dentro de un Pod — un escape de privilegios de manual (quien controla el socket controla el host).
2. **Falta de contrato de interoperabilidad.** No había garantía de que una imagen construida con la herramienta A se ejecutara idénticamente en el runtime B. `containerd`, CRI-O, Podman, Kata — cada uno reimplementaba supuestos.
3. **Verificabilidad e inmutabilidad débiles.** El modelo de `tag` (`myapp:latest`) es mutable: el mismo nombre puede apuntar a bytes distintos mañana. Sin un identificador criptográfico del contenido no hay reproducibilidad, no hay rollback determinista, no hay supply-chain security.

La OCI responde con **tres especificaciones desacopladas** que forman el contrato de la industria:

| Spec | Qué estandariza | Artefacto de referencia |
|---|---|---|
| **image-spec** | Formato en disco de la imagen: manifest, index, config, layers, media types, digests | `application/vnd.oci.image.*` |
| **runtime-spec** | Cómo se ejecuta un *filesystem bundle* desempaquetado (`config.json` + `rootfs/`) | runc, crun, youki |
| **distribution-spec** | Protocolo HTTP del registry: push/pull de blobs y manifests, referrers API | `GET /v2/...` |

La idea arquitectónica central que hay que interiorizar: **una imagen OCI es un grafo Merkle de contenido content-addressable**. Cada nodo (manifest, config, layer) se identifica por el `sha256` de sus propios bytes (su *digest*). Cambiar un byte de una layer cambia su digest, que cambia el manifest que la referencia, que cambia el digest del manifest. Esto da tres propiedades gratis:

- **Inmutabilidad por digest.** `registry.io/app@sha256:abc...` es criptográficamente imposible de falsificar sin cambiar el digest.
- **Deduplicación.** Dos imágenes que comparten la misma base layer comparten el mismo blob en el registry y en el disco del nodo — se descarga y almacena una sola vez.
- **Cacheabilidad y transferencia incremental.** Al hacer `pull`, el runtime solo baja las layers cuyo digest no tiene ya.

En producción esto habilita el patrón que todo SRE debe defender: **desplegar siempre por digest, nunca por tag mutable.** Un `Deployment` que referencia `app@sha256:...` es determinista ante `imagePullPolicy` y ante repushes maliciosos del tag.

---

## 2. Anatomía del formato OCI Image (deep dive)

Una imagen OCI **no es un archivo**: es un conjunto de blobs relacionados. El punto de entrada al grafo es un **descriptor**, la estructura que aparece en todas las specs:

```json
{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "digest": "sha256:e7d92cdc71feacf90708cb59065d969b83 b41c6cfd92ea6a9a4453d3f7b21a8",
  "size": 7143,
  "platform": { "architecture": "amd64", "os": "linux" }
}
```

`mediaType` + `digest` + `size` es el triplete que aparece en cada arista del grafo.

### 2.1 Los cuatro objetos

**a) OCI Image Index** (multi-arch / *manifest list*). Es opcional; apunta a varios manifests, uno por plataforma:

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:9f6ad537c5132220...amd64",
      "size": 1472,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:3a1e2b8c4d5e6f70...arm64",
      "size": 1472,
      "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" }
    }
  ],
  "annotations": {
    "org.opencontainers.image.source": "https://github.com/org/app"
  }
}
```

Cuando un nodo `arm64` hace `pull registry.io/app:1.0.0`, el runtime lee el index, resuelve la entrada `linux/arm64/v8` y baja **solo ese** manifest y sus layers. El resto ni se transfiere.

**b) OCI Image Manifest.** Describe una imagen concreta para una plataforma: un `config` y una lista ordenada de `layers`.

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:c1aab3fc31f4...",
    "size": 1024
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:2408cc74d12b...",
      "size": 3236992
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:a0c476849e7d...",
      "size": 14567
    }
  ],
  "annotations": {
    "org.opencontainers.image.created": "2026-08-13T09:00:00Z",
    "org.opencontainers.image.revision": "9c1f0a2"
  }
}
```

**c) OCI Image Config.** El JSON que containerd/CRI-O convierte en el `config.json` del runtime-spec. Contiene los parámetros de arranque *y* el `rootfs` (la lista ordenada de `diff_ids`) *y* el `history`.

```json
{
  "created": "2026-08-13T09:00:00Z",
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "User": "65532:65532",
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "APP_ENV=production"
    ],
    "Entrypoint": ["/app/server"],
    "Cmd": ["--config=/etc/app/config.yaml"],
    "WorkingDir": "/app",
    "ExposedPorts": { "8080/tcp": {} },
    "Volumes": { "/data": {} },
    "Labels": {
      "org.opencontainers.image.source": "https://github.com/org/app"
    },
    "StopSignal": "SIGTERM"
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:1f0f36e4a1f2...",
      "sha256:b3d4c9e01a77..."
    ]
  },
  "history": [
    { "created": "2026-08-13T09:00:00Z", "created_by": "COPY server /app/server" },
    { "created": "2026-08-13T09:00:00Z", "created_by": "USER 65532", "empty_layer": true }
  ]
}
```

**d) Layers.** Cada layer es un **tar filesystem changeset** (un diff respecto de la layer anterior), normalmente comprimido con gzip o zstd. Los borrados se representan con **whiteout files**:

- `.wh.<archivo>` → el archivo fue borrado en esta layer.
- `.wh..wh..opq` dentro de un directorio → *opaque directory*: ignorá todo lo heredado de layers previas para este directorio.

### 2.2 `digest` vs `diff_id` vs `chainID` — la trampa clásica del examen

Hay **tres** hashes distintos y confundirlos es un error frecuente:

| Concepto | Se calcula sobre | Dónde aparece | Para qué sirve |
|---|---|---|---|
| **`digest`** | La layer **comprimida** (el blob gzip/zstd tal cual se transfiere) | En el manifest (`layers[].digest`) | Content-addressing en el registry: cómo se sube/baja el blob |
| **`diff_id`** | El tar **descomprimido** (contenido lógico) | En el config (`rootfs.diff_ids`) | Identifica el contenido del filesystem, independiente de la compresión |
| **`chainID`** | Recursivo sobre `diff_ids` | Interno del runtime (containerd snapshotter) | Identifica un rootfs *acumulado* (layer N aplicada sobre 0..N-1) para deduplicar snapshots |

Cálculo del chainID:

```
chainID(L0)      = diffID(L0)
chainID(L0..Ln)  = sha256( chainID(L0..Ln-1) + " " + diffID(Ln) )
```

**Consecuencia práctica:** recomprimir una layer (gzip→zstd) **cambia el `digest` pero no el `diff_id`**. Por eso el mismo contenido puede tener dos representaciones en el registry pero un solo snapshot en el nodo. Y por eso "el digest de la layer" nunca es el hash de lo que ves con `tar tf`.

---

## 3. Comparativas técnicas (tablas de trade-offs)

### 3.1 OCI Image Spec vs Docker Schema 2

Ambos coexisten en registries reales; un SRE debe saber leer los dos.

| Aspecto | Docker Image Manifest v2 s2 | OCI Image Spec v1.1 |
|---|---|---|
| Manifest | `application/vnd.docker.distribution.manifest.v2+json` | `application/vnd.oci.image.manifest.v1+json` |
| Lista multi-arch | `...manifest.list.v2+json` | `...image.index.v1+json` |
| Config | `...container.image.v1+json` | `...image.config.v1+json` |
| Layer | `...image.rootfs.diff.tar.gzip` | `...image.layer.v1.tar+gzip` |
| Compresión zstd | No estándar | Sí (`...tar+zstd`) |
| `artifactType` / `subject` (referrers) | No | Sí (OCI 1.1) |
| Annotations arbitrarias | Limitado | Sí, first-class |
| Compatibilidad | Universal (registries viejos) | Universal en registries modernos |

En la práctica los campos son estructuralmente equivalentes y las herramientas convierten transparentemente. El punto de fricción son registries antiguos que rechazan media types OCI (`400 Bad Request` / `manifest invalid`).

### 3.2 Compresión de layers

| Formato | Media type | Ratio | CPU compresión | CPU descompresión (pull) | Uso recomendado |
|---|---|---|---|---|---|
| Sin comprimir | `...tar` | 1.0× | nulo | nulo | OCI layout local, debugging |
| gzip | `...tar+gzip` | ~2.5–3× | medio | bajo | Default universal, máxima compatibilidad |
| zstd | `...tar+zstd` | ~3–3.5× | bajo-medio | **muy bajo** | Cold-start crítico, imágenes grandes, registries modernos |

Trade-off SRE: zstd reduce el *tiempo de pull* (menos bytes + descompresión más rápida), lo que baja el cold-start de Pods en autoscaling. El costo es compatibilidad: un runtime viejo no sabe descomprimir zstd y falla el pull. Verificá que containerd ≥ 1.5 en todos los nodos antes de emitir zstd.

### 3.3 Builders (foco Kubernetes / CI sin daemon)

| Builder | Daemon requerido | Rootless | Build in-cluster | Cache remoto | Reproducible | Notas |
|---|---|---|---|---|---|---|
| `docker buildx` (BuildKit) | Sí (buildkitd) | Parcial | Sí (buildkit pod) | Sí | Sí (`--build-arg SOURCE_DATE_EPOCH`) | El más completo; multi-arch nativo |
| **buildah** | **No** | **Sí** | Sí | Sí | Sí | Daemonless; ideal para pipelines |
| **kaniko** | **No** | Sí (userspace) | **Diseñado para ello** | Sí (`--cache-repo`) | Sí (`--reproducible`) | Ejecuta el Dockerfile dentro de un Pod, sin privilegios de host |
| `img` | No | Sí | Sí | Sí | Sí | Frontend BuildKit standalone |
| **ko** | No | Sí | Sí | — | Sí | Solo Go; sin Dockerfile, construye desde el binario |
| **jib** | No | Sí | Sí (Maven/Gradle) | Sí | Sí | Solo JVM; sin daemon ni Dockerfile |
| bazel `rules_oci` | No | Sí | Sí | Sí | **Sí (bit-exact)** | Hermetic builds; curva de aprendizaje alta |

Regla de decisión: **si construís dentro de Kubernetes, elegí kaniko o buildah**, nunca `docker build` con el socket montado.

### 3.4 Base images

| Base | Tamaño típico | libc | Shell / package mgr | Superficie CVE | Debuggabilidad | Uso |
|---|---|---|---|---|---|---|
| `scratch` | 0 B | — | ninguno | mínima | nula (sin shell) | Binarios estáticos (Go/Rust) |
| `distroless/static` | ~2 MB | — | ninguno | mínima | baja (`:debug` con busybox) | Binarios estáticos, producción |
| `distroless/base` | ~20 MB | glibc | ninguno | baja | baja | Binarios dinámicos glibc |
| `alpine` | ~7 MB | **musl** | sh + apk | baja | media | General; ojo con musl vs glibc |
| `debian:*-slim` | ~30 MB | glibc | bash + apt | media | alta | Compatibilidad máxima |
| `ubuntu` | ~78 MB | glibc | bash + apt | alta | alta | Evitar en producción |

Trade-off clave: **`alpine` usa musl libc**, no glibc. Binarios compilados/enlazados contra glibc pueden fallar con `Error loading shared library` o comportarse distinto en DNS/threads. Para binarios estáticos, `distroless/static` o `scratch` dan menor superficie de ataque y arranque instantáneo, a costa de no tener shell para `kubectl exec` (mitigable con `distroless:debug` o `kubectl debug` ephemeral containers).

---

## 4. Manifiestos e infraestructura completos

### 4.1 Dockerfile / Containerfile de producción (multi-stage, non-root, reproducible)

```dockerfile
# syntax=docker/dockerfile:1.7
# ---- Stage 1: build ----
FROM golang:1.22-bookworm AS build
WORKDIR /src

# Cache de módulos separada del código: solo invalida al cambiar go.mod/go.sum
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
# Build estático y reproducible: sin CGO, con timestamps deterministas
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -ldflags="-s -w -buildid=" -o /out/server ./cmd/server

# ---- Stage 2: runtime mínimo ----
FROM gcr.io/distroless/static-debian12:nonroot
# UID 65532 = 'nonroot' en distroless; no hay root en runtime
USER 65532:65532
WORKDIR /app
COPY --from=build --chown=65532:65532 /out/server /app/server

EXPOSE 8080
ENTRYPOINT ["/app/server"]
CMD ["--config=/etc/app/config.yaml"]

# OCI labels: trazabilidad supply-chain
LABEL org.opencontainers.image.source="https://github.com/org/app" \
      org.opencontainers.image.licenses="Apache-2.0"
```

Notas de arquitectura: la separación de stages hace que **la imagen final no contenga el compilador ni el código fuente**, solo el binario. Los `--mount=type=cache` de BuildKit persisten el cache de módulos entre builds sin meterlo en una layer. `-trimpath -buildid=` y `SOURCE_DATE_EPOCH` (ver §5) dan builds bit-a-bit reproducibles.

### 4.2 Build in-cluster con **kaniko** (Job, sin daemon, sin privilegios de host)

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-app-1-0-0
  namespace: ci
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      # NO se monta docker.sock ni se pide privileged
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:v1.23.2
          args:
            - "--context=git://github.com/org/app.git#refs/heads/main"
            - "--dockerfile=Dockerfile"
            - "--destination=registry.example.com/org/app:1.0.0"
            - "--destination=registry.example.com/org/app:$(GIT_SHA)"
            - "--cache=true"
            - "--cache-repo=registry.example.com/org/app/cache"
            - "--reproducible"                # limpia timestamps → digest estable
            - "--snapshot-mode=redo"
            - "--use-new-run"
          env:
            - name: GIT_SHA
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['git-sha']
          resources:
            requests: { cpu: "1", memory: "2Gi" }
            limits:   { cpu: "2", memory: "4Gi" }
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
      volumes:
        - name: docker-config
          secret:
            secretName: regcred                # tipo kubernetes.io/dockerconfigjson
            items:
              - key: .dockerconfigjson
                path: config.json
```

### 4.3 Secret de autenticación al registry (`imagePullSecrets` y push)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: regcred
  namespace: ci
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "registry.example.com": {
          "username": "ci-bot",
          "password": "REDACTED",
          "auth": "Y2ktYm90OlJFREFDVEVE"
        }
      }
    }
```

Este mismo Secret sirve como `imagePullSecrets` en un Pod que **consume** la imagen privada:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: app
      # SIEMPRE por digest en producción, no por tag mutable
      image: registry.example.com/org/app@sha256:e7d92cdc71feacf90708cb59065d969b83b41c6cfd92ea6a9a4453d3f7b21a8
      imagePullPolicy: IfNotPresent
```

### 4.4 Verificación de firmas en admisión con **Kyverno** (cosign / sigstore)

Cierra el supply chain: rechaza en el API server cualquier imagen no firmada por tu clave.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: require-cosign-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences:
            - "registry.example.com/org/*"
          mutateDigest: true          # reescribe tag → digest en el Pod admitido
          verifyDigest: true
          required: true
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
                    ctlog:
                      ignoreSCT: true
```

`mutateDigest: true` es la pieza SRE clave: aunque el desarrollador escriba `:1.0.0`, Kyverno resuelve y **congela el digest** en el objeto admitido, garantizando inmutabilidad de lo que efectivamente corre.

### 4.5 OCI Image Layout en disco (formato de intercambio local)

Cuando exportás con `skopeo copy ... oci:./dir:tag`, obtenés esta estructura estándar:

```
myapp-oci/
├── oci-layout                       # {"imageLayoutVersion": "1.0.0"}
├── index.json                       # punto de entrada (un image index)
└── blobs/
    └── sha256/
        ├── 9f6ad537c5132220...      # el manifest
        ├── c1aab3fc31f4...          # el config
        ├── 2408cc74d12b...          # layer 1
        └── a0c476849e7d...          # layer 2
```

Todo es content-addressable: el nombre del archivo **es** su digest. `index.json` es la raíz del grafo Merkle; desde ahí se navega a manifests, configs y layers.

---

## 5. Comandos CLI y salidas reales

### 5.1 Inspección sin daemon con `crane` / `skopeo`

```console
$ crane manifest alpine:3.20 | jq '{mediaType, config: .config.mediaType, layers: [.layers[].mediaType]}'
{
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "config": null,
  "layers": null
}
```

Es un **index** (multi-arch): no tiene `config`/`layers` directos. Bajamos un escalón:

```console
$ crane manifest --platform linux/arm64 alpine:3.20 | jq '{mt: .mediaType, layers: [.layers[] | {mediaType, size, digest}]}'
{
  "mt": "application/vnd.oci.image.manifest.v1+json",
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "size": 3623807,
      "digest": "sha256:2408cc74d12b6cd092bb8b516ba7d5e290f485d3eb9672efc00f0583730179e8"
    }
  ]
}
```

Resolver el digest inmutable de un tag (esto es lo que ponés en el `Deployment`):

```console
$ crane digest registry.example.com/org/app:1.0.0
sha256:e7d92cdc71feacf90708cb59065d969b83b41c6cfd92ea6a9a4453d3f7b21a8
```

Inspeccionar el config (entrypoint, user, env efectivos):

```console
$ crane config alpine:3.20 | jq '{os, architecture, cfg: .config, diff_ids: .rootfs.diff_ids}'
{
  "os": "linux",
  "architecture": "amd64",
  "cfg": {
    "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "Cmd": ["/bin/sh"]
  },
  "diff_ids": ["sha256:1f0f36e4a1f2c1c0d0d3b8..."]
}
```

`skopeo` es el equivalente para copiar entre transportes sin nodo local:

```console
$ skopeo inspect docker://registry.example.com/org/app:1.0.0
{
    "Name": "registry.example.com/org/app",
    "Digest": "sha256:e7d92cdc71feacf...",
    "RepoTags": ["1.0.0", "latest"],
    "Created": "2026-08-13T09:00:00Z",
    "Architecture": "amd64",
    "Os": "linux",
    "Layers": [
        "sha256:2408cc74d12b...",
        "sha256:a0c476849e7d..."
    ],
    "Env": ["PATH=/usr/local/sbin:...", "APP_ENV=production"]
}

$ skopeo copy --all docker://registry.example.com/org/app:1.0.0 oci:./app-oci:1.0.0
Getting image list signatures
Copying 2 images generated from 2 images in list
Copying image sha256:9f6ad537 (1/2)
 ... 3.5MiB / 3.5MiB [====================================] 0s
Writing manifest to image destination
```

### 5.2 Build multi-arch reproducible con `docker buildx`

```console
$ export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
$ docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    --provenance=true --sbom=true \
    -t registry.example.com/org/app:1.0.0 \
    --push .
[+] Building 41.7s (16/16) FINISHED
 => [linux/amd64 build 5/5] RUN go build -trimpath ...          18.2s
 => [linux/arm64 build 5/5] RUN go build -trimpath ...          21.9s
 => exporting to image                                           3.1s
 => => exporting manifest list sha256:e7d92cdc71fe...            0.0s
 => => pushing layers                                            2.4s
```

Verificar que quedó como image index con dos plataformas:

```console
$ docker buildx imagetools inspect registry.example.com/org/app:1.0.0
Name:      registry.example.com/org/app:1.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:e7d92cdc71feacf...

Manifests:
  Name:        registry.example.com/org/app:1.0.0@sha256:9f6ad537...
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64
  Name:        registry.example.com/org/app:1.0.0@sha256:3a1e2b8c...
  Platform:    linux/arm64/v8
```

### 5.3 Análisis de layers y eficiencia con `dive`

```console
$ dive registry.example.com/org/app:1.0.0 --ci
  Efficiency: 98.8231 %
  Wasted Bytes: 145200 bytes (145 kB)
  User-wasted-percent: 3.9 %
Inefficient Files:
  Count  Wasted Space  File Path
      2         98 kB   /app/server
      3         47 kB   /tmp/build-cache
Result:PASS [Total:3] [Passed:3] [Failed:0]
```

(`Wasted Bytes` = bytes escritos en una layer y sobreescritos/borrados en otra: la señal de un Dockerfile mal ordenado.)

### 5.4 Firma y verificación con `cosign`

```console
$ cosign sign --key cosign.key registry.example.com/org/app@sha256:e7d92cdc71fe...
Pushing signature to: registry.example.com/org/app

$ cosign verify --key cosign.pub registry.example.com/org/app:1.0.0 | jq '.[0].critical.image'
Verification for registry.example.com/org/app:1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
{
  "docker-manifest-digest": "sha256:e7d92cdc71feacf..."
}
```

### 5.5 En el nodo: cómo containerd ve la imagen

```console
$ sudo ctr -n k8s.io images ls | grep app
registry.example.com/org/app:1.0.0    application/vnd.oci.image.index.v1+json    sha256:e7d9...    3.6 MiB    linux/amd64,linux/arm64

$ sudo crictl images
IMAGE                              TAG      IMAGE ID        SIZE
registry.example.com/org/app       1.0.0    e7d92cdc71fe    3.62MB

$ sudo ctr -n k8s.io content ls | head -3
DIGEST                                                                    SIZE      LABELS
sha256:e7d92cdc71feacf...                                                 1.2 KiB   containerd.io/gc.ref.content...
sha256:2408cc74d12b...                                                    3.5 MiB   containerd.io/uncompressed=sha256:1f0f...
```

Fijate en la label `containerd.io/uncompressed=sha256:1f0f...`: containerd guarda el mapeo **digest (comprimido) → diff_id (descomprimido)** para deduplicar snapshots (§2.2).

---

## 6. Guía de verificación y diagnóstico de fallas

### 6.1 Ladder de verificación (de barato a caro)

| Pregunta | Comando | Costo |
|---|---|---|
| ¿Existe el tag y cuál es su digest inmutable? | `crane digest <ref>` | free |
| ¿Es un index multi-arch o un manifest simple? | `crane manifest <ref> \| jq .mediaType` | free |
| ¿Está la plataforma que necesito? | `crane manifest <ref> \| jq '.manifests[].platform'` | free |
| ¿El config declara non-root user? | `crane config <ref> \| jq .config.User` | free |
| ¿Coinciden los `diff_ids` con lo desplegado? | `crane config <ref> \| jq .rootfs.diff_ids` | free |
| ¿Está firmada por mi clave? | `cosign verify --key cosign.pub <ref>` | 1 verificación |
| ¿La imagen tiene los CVEs conocidos? | `grype <ref>` / `trivy image <ref>` | scan |

### 6.2 Fallas frecuentes y diagnóstico

**a) `exec format error` al arrancar el Pod.**
Causa: mismatch de arquitectura — se corrió una imagen `amd64` en un nodo `arm64` (o al revés). El manifest bajado no coincide con el `uname -m` del nodo.

```console
$ kubectl logs app-xxxxx
exec /app/server: exec format error

$ crane manifest registry.example.com/org/app:1.0.0 | jq '.manifests[].platform'
{ "architecture": "amd64", "os": "linux" }
# ← falta arm64: la imagen NO es multi-arch. Rebuild con buildx --platform.
```

**b) `no matching manifest for linux/arm64/v8 in the manifest list entries`.**
Es un index, pero sin entrada para la plataforma del nodo. Solución: build multi-arch (§5.2) o `nodeSelector`/`nodeAffinity` sobre `kubernetes.io/arch` para clavar el Pod a la arch disponible.

**c) `ErrImagePull` / `ImagePullBackOff`.**
Desagregá con `kubectl describe pod`:

```console
$ kubectl describe pod app-xxxxx | grep -A3 Events
  Warning  Failed  kubelet  Failed to pull image "...app:1.0.0":
    failed to resolve reference "...": pull access denied,
    repository does not exist or may require authorization
```

Árbol de decisión:
- `pull access denied` / `401` → falta o está mal el `imagePullSecrets` / `regcred`.
- `manifest unknown` / `404` → el tag no existe (typo o nunca se pusheó). Verificá con `crane ls registry.example.com/org/app`.
- `manifest invalid` → registry viejo rechaza media types OCI/zstd; reconstruí con `--oci=false` o gzip.
- Timeout → el nodo no tiene ruta al registry (NetworkPolicy, DNS, mirror caído).

**d) `failed to verify layer sha256:... : unexpected commit digest`.**
La layer bajada no hashea al digest esperado → **corrupción o MITM**. containerd aborta el pull (esto es la garantía content-addressable funcionando). Revisá el proxy/mirror; nunca lo "arregles" desactivando la verificación.

**e) La firma no valida (`no matching signatures`).**
El digest efectivo cambió (se repusheó el tag) o la clave es incorrecta. Verificá siempre **por digest**, no por tag:

```console
$ cosign verify --key cosign.pub registry.example.com/org/app@sha256:e7d9...
Error: no matching signatures:
# ← el digest actual del tag no es el que se firmó. Alguien repusheó :1.0.0.
```

Este es exactamente el ataque que Kyverno + digest inmutable (§4.4) previene.

**f) Digests distintos en dos builds del "mismo" código (no reproducible).**
Casi siempre son **timestamps**. Fijá `SOURCE_DATE_EPOCH`, usá `-trimpath -buildid=` en Go, y `--reproducible` en kaniko. Comparación:

```console
$ crane config app:build-a | jq .rootfs.diff_ids > a.txt
$ crane config app:build-b | jq .rootfs.diff_ids > b.txt
$ diff a.txt b.txt
# vacío ⇒ el rootfs es idéntico; si difiere solo el digest del manifest,
#          es metadata (created/history), no contenido.
```

### 6.3 Checklist de imagen production-ready

- [ ] Se despliega **por digest**, no por tag mutable.
- [ ] `config.User` ≠ root (`runAsNonRoot` refuerza en el Pod).
- [ ] Multi-stage: sin compilador ni fuentes en la imagen final.
- [ ] Base mínima (`distroless`/`scratch`) salvo necesidad de shell justificada.
- [ ] Firmada con cosign; verificación forzada en admisión.
- [ ] SBOM + provenance adjuntos (referrers API / `--sbom --provenance`).
- [ ] Build reproducible (`SOURCE_DATE_EPOCH`, `--reproducible`).
- [ ] Escaneada (`trivy`/`grype`) sin CVEs críticos sin waiver.
- [ ] Construida **sin** `docker.sock` montado (kaniko/buildah).

---

## 7. Referencias

- OCI Image Format Specification — https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Image Manifest — https://github.com/opencontainers/image-spec/blob/main/manifest.md
- OCI Image Index — https://github.com/opencontainers/image-spec/blob/main/image-index.md
- OCI Image Configuration — https://github.com/opencontainers/image-spec/blob/main/config.md
- OCI Layer / Filesystem changeset (whiteouts) — https://github.com/opencontainers/image-spec/blob/main/layer.md
- OCI Image Layout — https://github.com/opencontainers/image-spec/blob/main/image-layout.md
- OCI Descriptor & Media Types — https://github.com/opencontainers/image-spec/blob/main/descriptor.md · https://github.com/opencontainers/image-spec/blob/main/media-types.md
- OCI Distribution Specification (registry API, referrers) — https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- OCI Runtime Specification — https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- Docker Image Manifest V2 Schema 2 — https://distribution.github.io/distribution/spec/manifest-v2-2/
- containerd — https://containerd.io/docs/ · CRI — https://github.com/containerd/containerd/blob/main/docs/cri/
- kaniko — https://github.com/GoogleContainerTools/kaniko
- Buildah — https://buildah.io/ · BuildKit — https://github.com/moby/buildkit
- google/go-containerregistry (`crane`) — https://github.com/google/go-containerregistry/tree/main/cmd/crane
- Skopeo — https://github.com/containers/skopeo
- dive — https://github.com/wagoodman/dive
- Distroless base images — https://github.com/GoogleContainerTools/distroless
- Sigstore cosign — https://docs.sigstore.dev/cosign/signing/overview/
- Kyverno image verification — https://kyverno.io/docs/writing-policies/verify-images/
- CNCF Curriculum (KCA) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf