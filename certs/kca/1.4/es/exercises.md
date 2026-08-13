# Ejercicios guiados — Tema 1.4: OCI Images (examen KCA)

> **Requisitos previos.** Un host Linux con acceso a Internet y las siguientes herramientas instaladas: `skopeo`, `crane` (de `go-containerregistry`), `buildah`, `jq`, `umoci` y opcionalmente `docker`/`nerdctl` y `cosign`. Ninguno de estos ejercicios necesita privilegios de root si usás `buildah`/`skopeo` en modo *rootless*. Se recomienda trabajar en un directorio limpio: `mkdir -p ~/oci-lab && cd ~/oci-lab`.
>
> **Objetivo del tema.** Entender la OCI Image Specification como formato *content-addressable*: cómo un *image reference* (`repo:tag`) se resuelve a un **manifest**, cómo el manifest apunta por *digest* a un **config** y a una lista de **layers**, y cómo todo ese grafo se guarda, se transporta y se verifica sin un daemon de por medio.

---

## Ejercicio 1 — Anatomía de una OCI image: del *reference* al grafo de blobs

En este ejercicio vas a descomponer una imagen real en sus tres piezas fundamentales (**manifest → config → layers**) sin arrancar ningún contenedor y sin un daemon de Docker.

### Pasos

1. Traé el **manifest** de una imagen conocida directamente del registry, en crudo, sin descargarla entera:

   ```bash
   skopeo inspect --raw docker://docker.io/library/alpine:3.20 | jq .
   ```

   Salida esperada (recortada):

   ```json
   {
     "schemaVersion": 2,
     "mediaType": "application/vnd.oci.image.index.v1+json",
     "manifests": [
       {
         "mediaType": "application/vnd.oci.image.manifest.v1+json",
         "digest": "sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d",
         "size": 528,
         "platform": { "architecture": "amd64", "os": "linux" }
       },
       {
         "mediaType": "application/vnd.oci.image.manifest.v1+json",
         "digest": "sha256:2f3d1f...",
         "size": 528,
         "platform": { "architecture": "arm64", "os": "linux" }
       }
     ]
   }
   ```

2. Lo que trajiste **no es un image manifest, es un image index** (`...image.index.v1+json`, antes conocido como "manifest list"). Fijá el *reference* a una plataforma concreta para obtener el manifest de plataforma. Podés dejar que la herramienta elija, o pedir la arquitectura explícitamente:

   ```bash
   skopeo inspect --raw --override-arch amd64 --override-os linux \
     docker://docker.io/library/alpine:3.20 | jq .
   ```

   Salida esperada (el manifest de plataforma):

   ```json
   {
     "schemaVersion": 2,
     "mediaType": "application/vnd.oci.image.manifest.v1+json",
     "config": {
       "mediaType": "application/vnd.oci.image.config.v1+json",
       "digest": "sha256:1d34ffeaf190be23d3de5a8de0a436676b758f48f835c3a2d4768b798c15a7f1",
       "size": 581
     },
     "layers": [
       {
         "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
         "digest": "sha256:9fda8d8052c6f...",
         "size": 3623807
       }
     ]
   }
   ```

3. Observá que el manifest **no contiene bytes de contenido**: solo *descriptors*. Un *descriptor* es la terna `{mediaType, digest, size}`. Extraé los tres digests que forman el grafo:

   ```bash
   MAN=$(skopeo inspect --raw --override-arch amd64 \
     docker://docker.io/library/alpine:3.20)
   echo "$MAN" | jq -r '.config.digest'
   echo "$MAN" | jq -r '.layers[].digest'
   ```

4. Ahora traé el **config object**, que es el blob al que apunta `.config.digest`. Copiá la imagen a un directorio en formato OCI y leé el config desde ahí:

   ```bash
   skopeo copy --override-arch amd64 \
     docker://docker.io/library/alpine:3.20 \
     oci:alpine-oci:3.20
   ls -R alpine-oci
   ```

   Salida esperada:

   ```
   alpine-oci:
   blobs  index.json  oci-layout

   alpine-oci/blobs:
   sha256

   alpine-oci/blobs/sha256:
   1d34ffeaf190be23d3de5a8de0a436676b758f48f835c3a2d4768b798c15a7f1
   9fda8d8052c6f...
   beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d
   ```

5. Leé el config directamente del *content store* (el nombre del archivo **es** el digest, sin el prefijo `sha256:`):

   ```bash
   CONF=$(echo "$MAN" | jq -r '.config.digest' | cut -d: -f2)
   jq '{architecture, os, rootfs, history: (.history | length), config: .config.Env}' \
     alpine-oci/blobs/sha256/$CONF
   ```

   Salida esperada (recortada):

   ```json
   {
     "architecture": "amd64",
     "os": "linux",
     "rootfs": {
       "type": "layers",
       "diff_ids": [
         "sha256:63ca1fbb43ae5034640e5e6cb3e083e05c290072c5366fcaa9d62435a4cced85"
       ]
     },
     "history": 1,
     "config": [ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ]
   }
   ```

> **Preguntas de comprensión (bloque 1)**
>
> 1.1 ¿Por qué el primer `skopeo inspect --raw` devolvió un objeto con `mediaType: application/vnd.oci.image.index.v1+json` en lugar de uno con `config` y `layers`? ¿Qué representa ese objeto?
>
> 1.2 En el manifest de plataforma aparecen dos digests distintos para el mismo `layer`: uno en `.layers[].digest` (dentro del manifest) y otro en `.rootfs.diff_ids[]` (dentro del config). ¿Sobre qué bytes se calcula cada uno y por qué **no** coinciden?
>
> 1.3 El manifest declara `size` para cada descriptor. ¿Qué gana un cliente (por ejemplo `containerd` al hacer *pull*) por tener el `size` esperado *antes* de descargar el blob?

---

## Ejercicio 2 — *Content addressing*: por qué un digest es una garantía, no un nombre

Acá vas a comprobar en la práctica la propiedad central de OCI: **el digest es el hash del contenido**, de modo que verificar integridad y deduplicar son la misma operación.

### Pasos

1. Calculá a mano el digest del config object y comparalo con el nombre del archivo:

   ```bash
   sha256sum alpine-oci/blobs/sha256/$CONF
   echo "esperado: $CONF"
   ```

   Salida esperada (los dos hashes coinciden):

   ```
   1d34ffeaf190be23d3de5a8de0a436676b758f48f835c3a2d4768b798c15a7f1  alpine-oci/blobs/sha256/1d34ff...
   esperado: 1d34ffeaf190be23d3de5a8de0a436676b758f48f835c3a2d4768b798c15a7f1
   ```

2. Ahora demostrá que el digest del **manifest** (el que usás en `image@sha256:...`) es el hash de los bytes **exactos** del manifest, no de su contenido "lógico". Traé el manifest en crudo y hasheá esos bytes:

   ```bash
   skopeo inspect --raw --override-arch amd64 \
     docker://docker.io/library/alpine:3.20 \
     | sha256sum
   ```

   Compará el resultado con el digest que reporta `crane`:

   ```bash
   crane digest docker.io/library/alpine:3.20 --platform linux/amd64
   ```

   Salida esperada (ambos coinciden, p. ej.):

   ```
   sha256:beefdbd8a1da6d2915566fde36db9db0b524eb737fc57cd1367effd16dc0d06d
   ```

3. Provocá una corrupción y observá que el digest deja de validar. Modificá **un solo byte** de un blob local y pedile a la herramienta que lo re-hashee:

   ```bash
   cp alpine-oci/blobs/sha256/$CONF /tmp/config.json
   printf ' ' >> /tmp/config.json      # un byte extra
   sha256sum /tmp/config.json
   echo "original: $CONF"
   ```

   Salida esperada (hashes distintos): un espacio de más ⇒ digest completamente distinto.

4. Verificá que *pull* por digest es inmutable, mientras que *pull* por tag no lo es. Pineá la imagen por digest:

   ```bash
   crane digest docker.io/library/alpine:3.20 > alpine.digest
   cat alpine.digest
   skopeo copy \
     docker://docker.io/library/alpine@$(cat alpine.digest) \
     oci:alpine-pinned:latest
   ```

   Salida esperada: la copia se resuelve sin ambigüedad al *index* exacto identificado por ese digest, independiente de a dónde apunte el tag `3.20` mañana.

> **Preguntas de comprensión (bloque 2)**
>
> 2.1 Un compañero propone "arreglar" un manifest agregando un espacio para que quede *pretty-printed* antes de subirlo, "porque el JSON es equivalente". ¿Por qué eso rompe la imagen aunque el JSON sea semánticamente idéntico?
>
> 2.2 ¿Qué diferencia operativa y de seguridad hay entre desplegar `alpine:3.20` y desplegar `alpine@sha256:beef...`? Nombrá un escenario en el que el tag te juegue en contra en producción.
>
> 2.3 Dos imágenes distintas (`alpine` y `busybox`) comparten un layer base idéntico. ¿Cuántas veces se almacena ese layer en un registry OCI y por qué? ¿Qué propiedad del *content addressing* lo permite?

---

## Ejercicio 3 — Construir una OCI image sin daemon (`buildah`) y auditar sus layers

Acá construís una imagen desde cero con `buildah` en modo *rootless* y observás cómo **cada instrucción del build se materializa como un layer** y una entrada de `history`.

### Pasos

1. Escribí un `Containerfile` (sinónimo de `Dockerfile`, es el nombre que prefiere la toolchain OCI):

   ```bash
   cat > Containerfile <<'EOF'
   FROM docker.io/library/alpine:3.20
   RUN apk add --no-cache curl
   COPY app.sh /usr/local/bin/app.sh
   RUN chmod +x /usr/local/bin/app.sh
   ENV APP_ENV=prod
   ENTRYPOINT ["/usr/local/bin/app.sh"]
   EOF

   cat > app.sh <<'EOF'
   #!/bin/sh
   echo "running in $APP_ENV"
   EOF
   ```

2. Construí la imagen y forzá el formato de salida **OCI** (buildah puede emitir formato Docker v2s2 o OCI; para este tema queremos OCI):

   ```bash
   buildah build --format oci -t myapp:1.0 -f Containerfile .
   ```

   Salida esperada (recortada):

   ```
   STEP 1/6: FROM docker.io/library/alpine:3.20
   STEP 2/6: RUN apk add --no-cache curl
   ...
   STEP 6/6: ENTRYPOINT ["/usr/local/bin/app.sh"]
   COMMIT myapp:1.0
   Successfully tagged localhost/myapp:1.0
   <image-id>
   ```

3. Exportá la imagen a un layout OCI en disco e inspeccioná el manifest generado:

   ```bash
   buildah push myapp:1.0 oci:myapp-oci:1.0
   jq '.manifests[0].mediaType' myapp-oci/index.json
   MANDIG=$(jq -r '.manifests[0].digest' myapp-oci/index.json | cut -d: -f2)
   jq '{config: .config.mediaType, layers: [.layers[].mediaType]}' \
     myapp-oci/blobs/sha256/$MANDIG
   ```

   Salida esperada:

   ```json
   { "mediaType": "application/vnd.oci.image.manifest.v1+json" }
   ```
   ```json
   {
     "config": "application/vnd.oci.image.config.v1+json",
     "layers": [
       "application/vnd.oci.image.layer.v1.tar+gzip",
       "application/vnd.oci.image.layer.v1.tar+gzip",
       "application/vnd.oci.image.layer.v1.tar+gzip",
       "application/vnd.oci.image.layer.v1.tar+gzip"
     ]
   }
   ```

4. Leé la `history` del config y correlacioná cada entrada con una instrucción del `Containerfile`:

   ```bash
   CDIG=$(jq -r '.config.digest' myapp-oci/blobs/sha256/$MANDIG | cut -d: -f2)
   jq -r '.history[] | "\(.created_by)  empty_layer=\(.empty_layer // false)"' \
     myapp-oci/blobs/sha256/$CDIG
   ```

   Salida esperada (recortada):

   ```
   /bin/sh -c apk add --no-cache curl        empty_layer=false
   /bin/sh -c #(nop) COPY file:...           empty_layer=false
   /bin/sh -c chmod +x /usr/local/bin/app.sh empty_layer=false
   /bin/sh -c #(nop) ENV APP_ENV=prod        empty_layer=true
   /bin/sh -c #(nop) ENTRYPOINT [...]        empty_layer=true
   ```

5. Contá layers vs. entradas de history para ver la asimetría:

   ```bash
   echo "layers:  $(jq '.layers | length' myapp-oci/blobs/sha256/$MANDIG)"
   echo "history: $(jq '.history | length' myapp-oci/blobs/sha256/$CDIG)"
   echo "diff_ids: $(jq '.rootfs.diff_ids | length' myapp-oci/blobs/sha256/$CDIG)"
   ```

   Salida esperada:

   ```
   layers:  4
   history: 5
   diff_ids: 4
   ```

> **Preguntas de comprensión (bloque 3)**
>
> 3.1 El build tiene 5 instrucciones que "hacen algo" (`FROM` no cuenta como layer nuevo, aporta el suyo) pero el resultado tiene 4 layers y 5 entradas de `history`. Explicá el desajuste usando el campo `empty_layer`. ¿Qué instrucciones **no** producen un filesystem layer?
>
> 3.2 `ENV` y `ENTRYPOINT` aparecen en `history` con `empty_layer=true`. ¿Dónde queda entonces guardada esa configuración, si no hay un layer para ella?
>
> 3.3 ¿Por qué el número de `diff_ids` en el config **siempre** es igual al número de `layers` en el manifest, mientras que `history` puede ser mayor?

---

## Ejercicio 4 — *Image index* multi-arquitectura: cómo un tag sirve a `amd64` y `arm64`

En este ejercicio armás a mano un **image index** que agrupa dos manifests de plataforma bajo un único tag, que es exactamente lo que hace que `docker pull alpine` funcione igual en tu laptop ARM y en un nodo x86.

### Pasos

1. Construí la misma app para dos plataformas (usando emulación si tu host es de una sola arquitectura):

   ```bash
   buildah build --format oci --platform linux/amd64 -t myapp:1.0-amd64 .
   buildah build --format oci --platform linux/arm64 -t myapp:1.0-arm64 .
   ```

2. Creá un **manifest list / image index** vacío y agregale ambas variantes:

   ```bash
   buildah manifest create myapp:1.0
   buildah manifest add myapp:1.0 myapp:1.0-amd64
   buildah manifest add myapp:1.0 myapp:1.0-arm64
   buildah manifest inspect myapp:1.0
   ```

   Salida esperada (recortada):

   ```json
   {
     "schemaVersion": 2,
     "mediaType": "application/vnd.oci.image.index.v1+json",
     "manifests": [
       { "digest": "sha256:aaa...", "platform": { "architecture": "amd64", "os": "linux" } },
       { "digest": "sha256:bbb...", "platform": { "architecture": "arm64", "os": "linux" } }
     ]
   }
   ```

3. Exportá el index a un layout OCI y verificá su estructura de dos niveles (index → manifests → configs/layers):

   ```bash
   buildah manifest push --all myapp:1.0 oci:myapp-multi:1.0
   jq '.manifests[] | {mediaType, digest, platform}' myapp-multi/index.json
   ```

4. Simulá lo que hace un runtime al resolver el tag para *su* plataforma: recorré el index, filtrá por arquitectura y quedate con el digest correcto:

   ```bash
   ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
   crane index --platform linux/$ARCH digest \
     oci:myapp-multi:1.0 2>/dev/null \
   || jq -r --arg a "$ARCH" \
      '.manifests[] | select(.platform.architecture==$a) | .digest' \
      myapp-multi/index.json
   ```

   Salida esperada: un único digest, el del manifest que le corresponde a tu CPU.

> **Preguntas de comprensión (bloque 4)**
>
> 4.1 Un cliente hace `pull registry.example.com/myapp:1.0` desde un nodo `arm64`. Describí la secuencia exacta de resoluciones (index → manifest → config/layers) y en qué punto entra la arquitectura del nodo en la decisión.
>
> 4.2 El campo `platform` dentro del index incluye a veces `variant` (p. ej. `arm64/v8`) y `os.version` (relevante en Windows). ¿Por qué el index necesita esta metadata *antes* de bajar ningún manifest de plataforma?
>
> 4.3 ¿Qué pasaría en un nodo `s390x` si el index solo tiene entradas `amd64` y `arm64`? ¿El error lo produce el registry o el cliente, y por qué?

---

## Ejercicio 5 — Transporte, deduplicación y verificación entre registries (`skopeo copy`, `oci-layout`)

Acá vas a mover imágenes entre distintos *transports* (registry ↔ directorio OCI ↔ tarball) sin ejecutar contenedores, y a comprobar que la copia es *lossless* y verificable por digest.

### Pasos

1. Copiá una imagen de un registry a un layout OCI, y de ahí a un tar OCI, y de vuelta a otro registry local, encadenando *transports*:

   ```bash
   # registry -> directorio OCI
   skopeo copy --override-arch amd64 \
     docker://docker.io/library/alpine:3.20 oci:alp-dir:3.20
   # directorio OCI -> archive OCI (un solo .tar)
   skopeo copy oci:alp-dir:3.20 oci-archive:alp.tar:3.20
   ```

2. Verificá que el digest del manifest **sobrevive** intacto a los tres transports (registry → dir → archive). Un mismo contenido ⇒ un mismo digest, sin importar el envase:

   ```bash
   crane digest docker.io/library/alpine:3.20 --platform linux/amd64
   skopeo inspect --raw oci:alp-dir:3.20 | sha256sum
   ```

   Salida esperada: el `sha256:...` del registry coincide con el hash del manifest en el layout OCI local.

3. Observá la **deduplicación** por content addressing. Copiá una segunda imagen que comparte el layer base al *mismo* layout OCI y contá los blobs:

   ```bash
   skopeo copy --override-arch amd64 \
     docker://docker.io/library/alpine:3.20 oci:shared:base
   # una imagen "derivada" cualquiera basada en alpine reutiliza su layer
   buildah push myapp:1.0-amd64 oci:shared:app
   ls oci-layout 2>/dev/null; ls shared/blobs/sha256 | wc -l
   ```

   Salida esperada: el número de blobs es **menor** que la suma de blobs de las dos imágenes por separado, porque el layer base de Alpine se guarda una sola vez.

4. Probá una copia con verificación de firma/digest estricta y mirá cómo `skopeo` re-verifica cada blob al vuelo:

   ```bash
   skopeo copy --all \
     docker://docker.io/library/alpine:3.20 \
     oci:alpine-all:3.20
   ```

   Salida esperada (recortada): una línea `Copying config ...`, luego `Copying blob ...` por cada layer, y para cada blob skopeo valida que el digest recibido coincide con el descriptor; si no coincidiera, abortaría con `error: ... digest mismatch`.

> **Preguntas de comprensión (bloque 5)**
>
> 5.1 `skopeo copy` movió la imagen entre `docker://`, `oci:` y `oci-archive:` sin que cambiara el digest del manifest. ¿Qué te dice eso sobre *dónde* vive la identidad de una imagen OCI y sobre qué NO forma parte de esa identidad (por ejemplo, el tag o el registry)?
>
> 5.2 Explicá por qué el `oci-layout` con dos imágenes que comparten base tiene menos blobs que la suma. ¿Qué archivo del layout permite que dos manifests distintos apunten al mismo blob sin duplicarlo?
>
> 5.3 Durante `skopeo copy`, ¿en qué momento y con qué información puede el cliente detectar un blob corrupto o adulterado por un *man-in-the-middle*, incluso sobre un transporte sin TLS?

---

## Ejercicio 6 — Layers, `diff_id`, whiteouts y el mito de "borrar reduce la imagen"

Este ejercicio demuestra la mecánica de *overlay*: los layers son **aditivos**, y "borrar" un archivo en un layer superior no libera espacio, sino que agrega un marcador *whiteout*.

### Pasos

1. Construí una imagen que crea un archivo grande y en un layer posterior lo borra:

   ```bash
   cat > Containerfile.fat <<'EOF'
   FROM docker.io/library/alpine:3.20
   RUN dd if=/dev/zero of=/blob.bin bs=1M count=50
   RUN rm -f /blob.bin
   EOF
   buildah build --format oci --layers -t fat:1.0 -f Containerfile.fat .
   buildah push fat:1.0 oci:fat-oci:1.0
   ```

2. Sumá el tamaño de todos los layers del manifest. Vas a ver que el archivo borrado **sigue pesando**, porque quedó capturado en un layer anterior:

   ```bash
   MDG=$(jq -r '.manifests[0].digest' fat-oci/index.json | cut -d: -f2)
   jq '[.layers[].size] | add' fat-oci/blobs/sha256/$MDG
   ```

   Salida esperada: un total que incluye ~50 MB (comprimidos, algo menos si es `/dev/zero`), pese a que el `rm` "eliminó" el archivo.

3. Extraé el layer que hace el `rm` y encontrá el marcador **whiteout**. Un whiteout es un archivo `.wh.<nombre>` que le dice al driver de overlay "ocultá este path de los layers de abajo":

   ```bash
   # tomamos el último layer (el del rm) y listamos su tar
   LAST=$(jq -r '.layers[-1].digest' fat-oci/blobs/sha256/$MDG | cut -d: -f2)
   tar -tzf fat-oci/blobs/sha256/$LAST | grep -E '\.wh\.'
   ```

   Salida esperada:

   ```
   .wh.blob.bin
   ```

4. Reescribí el `Containerfile` para crear y borrar en la **misma** instrucción `RUN` y compará el tamaño total:

   ```bash
   cat > Containerfile.slim <<'EOF'
   FROM docker.io/library/alpine:3.20
   RUN dd if=/dev/zero of=/blob.bin bs=1M count=50 && rm -f /blob.bin
   EOF
   buildah build --format oci --layers -t slim:1.0 -f Containerfile.slim .
   buildah push slim:1.0 oci:slim-oci:1.0
   SDG=$(jq -r '.manifests[0].digest' slim-oci/index.json | cut -d: -f2)
   jq '[.layers[].size] | add' slim-oci/blobs/sha256/$SDG
   ```

   Salida esperada: total mucho menor — el archivo nunca llega a persistir en un layer, porque se crea y se borra dentro del mismo *diff*.

> **Preguntas de comprensión (bloque 6)**
>
> 6.1 En la versión "fat", el archivo `/blob.bin` no aparece en el filesystem final del contenedor, pero la imagen igual pesa 50 MB más. ¿Dónde están esos bytes y por qué el `rm` no los recuperó?
>
> 6.2 ¿Qué es exactamente un archivo `.wh.blob.bin` y quién lo interpreta: se ejecuta dentro del contenedor, o lo procesa el storage driver al armar el rootfs? ¿Qué pasaría si un layer contuviera un archivo llamado literalmente `.wh.foo` como dato real?
>
> 6.3 Relacioná esto con el `diff_id` del config: ¿el `diff_id` se calcula sobre el tar **comprimido** (gzip) o **descomprimido** del layer? ¿Por qué esa elección hace que `diff_id` sea estable aunque cambies el algoritmo de compresión de `gzip` a `zstd`?

---

## Ejercicio 7 — Metadata de procedencia: `annotations`, `org.opencontainers.image.*` y firma con `cosign`

El último ejercicio cubre la parte de *supply chain* de la spec: las **annotations** estandarizadas que documentan el origen de la imagen, y cómo una firma se adjunta como un artefacto OCI referenciado por digest.

### Pasos

1. Agregá annotations estándar de la spec en el build. Estas claves (`org.opencontainers.image.*`) son parte de la OCI Image Spec y las consumen herramientas de escaneo y catálogos:

   ```bash
   buildah build --format oci -t myapp:2.0 \
     --annotation "org.opencontainers.image.source=https://github.com/acme/myapp" \
     --annotation "org.opencontainers.image.revision=$(git rev-parse HEAD 2>/dev/null || echo none)" \
     --annotation "org.opencontainers.image.licenses=Apache-2.0" \
     -f Containerfile .
   buildah push myapp:2.0 oci:myapp2:2.0
   ```

2. Leé las annotations desde el manifest (viven en el manifest, no en el config):

   ```bash
   MDG2=$(jq -r '.manifests[0].digest' myapp2/index.json | cut -d: -f2)
   jq '.annotations' myapp2/blobs/sha256/$MDG2
   ```

   Salida esperada:

   ```json
   {
     "org.opencontainers.image.source": "https://github.com/acme/myapp",
     "org.opencontainers.image.revision": "9f1c2e...",
     "org.opencontainers.image.licenses": "Apache-2.0"
   }
   ```

3. (Opcional, requiere un registry accesible.) Firmá la imagen por digest con `cosign` y observá que la firma se sube como un **artefacto OCI aparte**, etiquetado en función del digest firmado:

   ```bash
   IMG=localhost:5000/myapp@$(crane digest localhost:5000/myapp:2.0)
   COSIGN_EXPERIMENTAL=1 cosign sign --key cosign.key "$IMG"
   crane ls localhost:5000/myapp
   ```

   Salida esperada (recortada):

   ```
   2.0
   sha256-<digest-de-myapp>.sig     <-- la firma, referenciada por el digest de la imagen
   ```

4. Verificá la firma contra el digest, no contra el tag (un atacante puede mover el tag; no puede mover el digest):

   ```bash
   cosign verify --key cosign.pub "$IMG"
   ```

   Salida esperada: un JSON con el *payload* verificado, cuyo campo `critical.image.docker-manifest-digest` es exactamente el digest que firmaste.

> **Preguntas de comprensión (bloque 7)**
>
> 7.1 Las annotations `org.opencontainers.image.*` viven en el **manifest**, no en el **config**. ¿Qué consecuencia práctica tiene eso sobre el digest de la imagen cuando agregás o cambiás una annotation? ¿Cambia el `rootfs`?
>
> 7.2 `cosign` firma el **digest** del manifest, y la firma se almacena bajo un tag derivado (`sha256-<digest>.sig`). Explicá por qué firmar el tag `:2.0` en lugar del digest sería inseguro.
>
> 7.3 Un pipeline setea `org.opencontainers.image.revision` con el commit de Git. ¿Por qué esta annotation es más confiable como prueba de procedencia que un `LABEL` cualquiera puesto por el autor de la imagen, y qué le falta todavía para ser una prueba criptográfica (pista: relacionalo con el ejercicio de firma)?

---

## Fuentes

- **KCA Curriculum** — CNCF: `https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf`
- **OCI Image Specification** (manifest, config, descriptor, image-index, media-types, annotations, layer/whiteouts): `https://github.com/opencontainers/image-spec/blob/main/spec.md`
  - Image Manifest: `https://github.com/opencontainers/image-spec/blob/main/manifest.md`
  - Image Index: `https://github.com/opencontainers/image-spec/blob/main/image-index.md`
  - Image Configuration: `https://github.com/opencontainers/image-spec/blob/main/config.md`
  - Descriptor / digests: `https://github.com/opencontainers/image-spec/blob/main/descriptor.md`
  - Layer / whiteouts: `https://github.com/opencontainers/image-spec/blob/main/layer.md`
  - Annotations: `https://github.com/opencontainers/image-spec/blob/main/annotations.md`
  - OCI Image Layout: `https://github.com/opencontainers/image-spec/blob/main/image-layout.md`
- **OCI Distribution Specification** (pull/push, digests en el registry): `https://github.com/opencontainers/distribution-spec/blob/main/spec.md`
- **skopeo** (transports `docker:`, `oci:`, `oci-archive:`): `https://github.com/containers/skopeo/blob/main/docs/skopeo.1.md`
- **buildah** (`build`, `manifest`, `--format oci`): `https://github.com/containers/buildah/blob/main/docs/buildah.1.md`
- **crane / go-containerregistry**: `https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md`
- **sigstore / cosign** (firma de artefactos OCI): `https://docs.sigstore.dev/cosign/signing/signing_with_containers/`

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**1.1** Porque el tag `alpine:3.20` no apunta a un único manifest de plataforma, sino a un **image index** (`application/vnd.oci.image.index.v1+json`). El index es una lista de descriptors, cada uno con su `platform` (`{architecture, os, variant, os.version}`), que permite que un mismo tag sirva a múltiples arquitecturas/SO. No contiene `config` ni `layers` propios: es un nivel de indirección por encima de los manifests de plataforma. Un cliente elige el manifest cuyo `platform` matchea su nodo y recién ahí obtiene `config`+`layers`.

**1.2** Son hashes de bytes distintos:
- `.layers[].digest` (en el manifest) es el `sha256` del blob **tal como viaja**, es decir el tar **comprimido** (`...tar+gzip`). Es lo que el cliente descarga y verifica al hacer *pull*.
- `.rootfs.diff_ids[]` (en el config) es el `sha256` del tar **descomprimido** (el "diff" del filesystem). Es lo que identifica el *contenido lógico* del layer una vez aplicado sobre el rootfs.
No coinciden porque comprimir cambia los bytes. Esta doble identidad es deliberada: `digest` optimiza transporte y `diff_id` identifica contenido independientemente del algoritmo de compresión (ver 6.3).

**1.3** Tener el `size` esperado antes de descargar permite (a) pre-asignar buffers y validar `Content-Length`, (b) rechazar temprano un blob cuyo tamaño no coincide sin bajarlo entero, (c) calcular exactamente cuánto falta descargar para barras de progreso y presupuesto de red, y (d) como defensa: junto con el `digest`, acota el espacio de un ataque de relleno (un blob que no tiene ni el tamaño ni el hash esperados se descarta). El descriptor `{mediaType, digest, size}` es la unidad de confianza mínima.

### Bloque 2

**2.1** El digest del manifest es `sha256` de los **bytes exactos** serializados, no de su estructura JSON abstracta. Agregar un espacio, reordenar claves o re-*pretty-print* cambia los bytes ⇒ cambia el digest. Como toda referencia por digest (`@sha256:...`), toda firma cosign y todo record en el registry apuntan a esos bytes precisos, cualquier reserialización "equivalente" produce un objeto **distinto** que ya no coincide con las referencias existentes: el pull por digest fallaría con *manifest unknown* y las firmas dejarían de validar. Por eso los manifests se tratan como *bytes inmutables*, no como "un JSON".

**2.2** Un **tag es mutable**: `alpine:3.20` puede reapuntar a bytes distintos mañana (rebuild de seguridad, o *tag hijacking* malicioso), y dos nodos que hacen pull en momentos distintos pueden correr imágenes diferentes. Un **digest es inmutable**: `alpine@sha256:beef...` siempre es el mismo contenido o falla. Escenario problemático: un Deployment con `image: app:latest` y `imagePullPolicy: IfNotPresent` deja nodos con versiones divergentes de la "misma" imagen según cuándo cada nodo hizo el último pull; un rollback "al mismo tag" puede no volver al mismo contenido. Pineando por digest, el despliegue es reproducible y auditable.

**2.3** Se almacena **una sola vez**. En content addressing el identificador de un blob es el hash de su contenido, así que dos imágenes que referencian un layer idéntico apuntan al **mismo digest**, y el registry (y el `oci-layout` local, y el storage del runtime) guardan ese blob una única vez. La deduplicación es una consecuencia gratuita de nombrar por contenido: mismos bytes ⇒ mismo nombre ⇒ una copia.

### Bloque 3

**3.1** Solo las instrucciones que **modifican el filesystem** producen un layer: `RUN apk add`, `COPY`, `RUN chmod` (3) más el layer heredado de la base `alpine` (1) = 4 layers. Las instrucciones de **solo metadata** —`ENV`, `ENTRYPOINT`, `CMD`, `LABEL`, `WORKDIR` (cuando no crea directorio), `EXPOSE`— no cambian el rootfs; se registran en `history` con `empty_layer: true` y no aportan un `diff_id`. De ahí que haya 5 entradas de history pero 4 layers.

**3.2** En el **config object** (`application/vnd.oci.image.config.v1+json`), dentro del campo `.config` (`Env`, `Entrypoint`, `Cmd`, `WorkingDir`, `ExposedPorts`, `Labels`, etc.). Esa configuración es *runtime metadata*: no necesita bytes en el filesystem, se aplica cuando el runtime arranca el contenedor. Por eso `ENV`/`ENTRYPOINT` no generan layer pero sí quedan persistidos y versionados en el config.

**3.3** Porque `rootfs.diff_ids` es, por definición, la lista ordenada de los diffs de filesystem que forman el rootfs, y hay exactamente uno por cada `layer` del manifest (relación 1:1, en el mismo orden). `history`, en cambio, documenta **todos** los pasos del build, incluidos los que no tocan el filesystem (`empty_layer: true`); esos no tienen `diff_id` ni layer. Por eso `len(history) ≥ len(diff_ids) == len(layers)`.

### Bloque 4

**4.1** (1) El cliente hace *pull* del tag ⇒ el registry devuelve el **image index**. (2) El cliente recorre `manifests[]` y selecciona el descriptor cuyo `platform.architecture == arm64` (y `os == linux`, y `variant` si aplica). (3) Con el `digest` de ese descriptor pide el **manifest de plataforma**. (4) Del manifest baja el **config** (por `.config.digest`) y cada **layer** (por `.layers[].digest`), verificando digest y size de cada blob. La arquitectura del nodo entra **solo en el paso 2**, la selección dentro del index; todo lo demás ya es resolución por digest, idéntica en cualquier plataforma.

**4.2** Porque la selección de plataforma ocurre **antes** de bajar cualquier manifest de plataforma: el cliente necesita, mirando únicamente el index, saber cuál de las variantes le corresponde. Si `variant` u `os.version` faltaran, no podría distinguir, por ejemplo, `arm64/v8` de `arm/v7`, o una imagen de Windows Server 2019 de una 2022 (que requieren match de kernel). Poner esa metadata en el index evita descargar manifests que después habría que descartar.

**4.3** El **cliente** produce el error, típicamente `no matching manifest for linux/s390x in the manifest list entries`. El registry solo entrega los bytes del index tal cual; no sabe qué plataforma corre el cliente. Es el cliente quien recorre el index, no encuentra un descriptor que matchee su `platform` y falla. Es un error de *resolución*, no de red ni de servidor.

### Bloque 5

**5.1** La identidad de una imagen OCI vive **en el digest del manifest** (y, transitivamente, en los digests de config y layers): es puramente el contenido. **No** forman parte de la identidad ni el `tag`, ni el `registry/repository`, ni el *transport* (`docker:`/`oci:`/`oci-archive:`). Son solo *punteros* o *envases*. Por eso la misma imagen movida por tres transports conserva el mismo `sha256:...`: cambiaste el sobre, no la carta.

**5.2** Porque los blobs se guardan indexados por su digest de contenido; dos manifests que necesitan el mismo layer base referencian el mismo archivo `blobs/sha256/<digest>` y no se duplica. La estructura que lo permite es el `oci-layout` con su **content-addressable blob store** (`blobs/sha256/`) más el `index.json`, que lista los manifests de nivel superior; cada manifest apunta por digest a blobs compartidos del mismo store. La deduplicación es intrínseca al direccionamiento por contenido.

**5.3** En el **momento en que termina de recibir cada blob** (y de forma incremental mientras lo recibe): el cliente conoce de antemano el `digest` y el `size` esperados por el descriptor del manifest, hashea el stream recibido y lo compara. Si un MITM alteró aunque sea un byte, el hash no coincide y `skopeo` aborta con *digest mismatch*. Esto funciona **incluso sin TLS**, porque la integridad no depende del canal sino del content addressing —siempre que el **manifest raíz** (o su digest/firma) se haya obtenido por un canal confiable; esa es la raíz de confianza que el resto del grafo hereda.

### Bloque 6

**6.1** Los bytes están en el **layer anterior** (el del `dd`), que capturó `/blob.bin` como parte de su diff. El `rm` corre en un layer **posterior** y, por el modelo aditivo de overlay, no puede modificar ni achicar layers de abajo (son inmutables): solo puede **agregar** un marcador que oculte el archivo. El filesystem final del contenedor no muestra `/blob.bin`, pero la imagen —que es la suma de todos los layers— sigue transportando esos 50 MB.

**6.2** Un `.wh.blob.bin` es un **whiteout**: un archivo especial, definido por la OCI Image Spec, que indica "en la vista fusionada, ocultá el path `blob.bin` presente en layers inferiores". **No** se ejecuta dentro del contenedor: lo interpreta el **storage/overlay driver** al ensamblar el rootfs a partir de los layers (es una convención del formato de layer, no un proceso). Si un layer contuviera un archivo de datos llamado literalmente `.wh.foo`, colisionaría con la convención y el driver lo trataría como whiteout, ocultando `foo`; por eso la spec también define un mecanismo de *escape* (`.wh..wh..opq` para opaque dirs y reglas de nombrado) para estos casos.

**6.3** El `diff_id` se calcula sobre el tar **descomprimido** del layer, mientras que el `digest` del manifest se calcula sobre el tar **comprimido**. Al fijar `diff_id` sobre el contenido lógico (sin comprimir), el identificador del contenido del filesystem **no cambia** aunque recomprimas de `gzip` a `zstd`: el `digest`/`mediaType` del blob transportado cambiará, pero el `diff_id` (y por lo tanto la identidad del *rootfs* y el cache de layers descomprimidos del runtime) se mantiene estable.

### Bloque 7

**7.1** Las annotations viven en el manifest, así que **agregarlas o cambiarlas cambia los bytes del manifest y, por lo tanto, su digest**: obtenés una imagen con distinto `sha256:...` de manifest. Sin embargo, **no** tocan el `config` ni los `layers`, de modo que `rootfs`/`diff_ids` y los digests de los blobs de contenido **no cambian**: el filesystem es idéntico, solo cambió la metadata del manifest que lo referencia (y su digest).

**7.2** Un tag es mutable: si firmaras "el tag `:2.0`", un atacante que reapunte `:2.0` a otro manifest tendría, de hecho, una firma que "cubre" contenido que vos nunca firmaste. Firmando el **digest** del manifest, la firma queda atada a bytes inmutables: mover el tag no afecta lo firmado, y la verificación compara `critical.image.docker-manifest-digest` con el digest efectivamente desplegado. Por eso `cosign` firma y verifica por digest, y guarda la firma bajo `sha256-<digest>.sig`.

**7.3** `org.opencontainers.image.revision` es una annotation estandarizada que las herramientas de supply chain saben leer, pero por sí sola es solo **metadata declarada por quien construyó la imagen**: cualquiera puede poner el commit hash que quiera, igual que un `LABEL`. Es más útil que un `LABEL` arbitrario únicamente por ser una **clave convencional** que el ecosistema interpreta de forma uniforme, no por ser más confiable. Para convertirse en una prueba criptográfica de procedencia le falta lo del ejercicio 6/7: una **firma** (cosign) sobre el digest y, mejor aún, una **atestación de build/SLSA provenance** que ligue verificablemente ese digin al pipeline y al commit. Sin firma, la annotation es una afirmación; con firma sobre el digest, es evidencia verificable.

</details>