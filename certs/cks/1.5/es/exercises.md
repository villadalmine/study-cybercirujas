# Tema 1.5 — Verificar los binarios de plataforma antes de desplegar

## Ejercicios guiados

> **Alcance.** Estos ejercicios cubren los controles de cadena de suministro que se espera que realices *antes* de que un binario, paquete, imagen o chart llegue siquiera a un nodo: verificación de checksums, verificación de firmas Sigstore/cosign, confianza en la clave del repositorio de paquetes, auditoría de drift en el nodo, fijado por digest y provenance de Helm.

### Prerrequisitos del laboratorio

- Una máquina Linux (se asume amd64; sustituí por `arm64` donde corresponda) con `curl`, `sha256sum`, `gpg`, `openssl` y `jq`.
- Acceso HTTPS saliente a `dl.k8s.io`, `registry.k8s.io`, `pkgs.k8s.io`, `rekor.sigstore.dev` y `fulcio.sigstore.dev`.
- Un clúster funcional basado en `kubeadm` con `crictl` en al menos un nodo (se usa a partir del Ejercicio 7).
- `sudo` en la máquina del laboratorio. **No ejecutes los pasos de manipulación contra un nodo de producción.**

---

## Ejercicio 1 — Fijar la release que vas a verificar

La verificación no tiene sentido si antes no decidís *exactamente* qué artefacto confiás.

1. Creá un directorio de trabajo limpio:

   ```bash
   mkdir -p ~/verify-lab && cd ~/verify-lab
   ```

2. Preguntale al canal de releases cuál es la versión estable actual, y cuál es la versión estable de la línea menor 1.34:

   ```bash
   curl -sL https://dl.k8s.io/release/stable.txt
   curl -sL https://dl.k8s.io/release/stable-1.34.txt
   ```

3. Fijá la versión explícitamente en tu shell — cada paso posterior la reutiliza:

   ```bash
   export K8S_VERSION=v1.34.0
   export ARCH=amd64
   echo "${K8S_VERSION}/${ARCH}"
   ```

4. Mirá qué publica el directorio de la release para un único binario:

   ```bash
   for ext in "" .sha256 .sig .cert; do
     echo -n "kubectl${ext}: "
     curl -sIL -o /dev/null -w '%{http_code}\n' \
       "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl${ext}"
   done
   ```

**Preguntas**

1. ¿Por qué `curl -sL https://dl.k8s.io/release/stable.txt` es una *comodidad* y no un control de seguridad?
2. `dl.k8s.io` se sirve sobre HTTPS. ¿Por qué TLS por sí solo es insuficiente para confiar en el `kubectl` que acabás de localizar?
3. ¿Cuál es la diferencia práctica, para un auditor, entre "instalamos Kubernetes 1.34" e "instalamos `v1.34.0` con digest `sha256:…`"?

---

## Ejercicio 2 — Verificar un binario publicado con su checksum publicado

1. Descargá el binario y su archivo de checksum:

   ```bash
   cd ~/verify-lab
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl"
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
   cat kubectl.sha256; echo
   ```

2. Notá que el archivo `.sha256` contiene **solo el hash**, sin nombre de archivo. Construí una línea de checksum válida y verificá:

   ```bash
   echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
   ```

   Salida esperada:

   ```
   kubectl: OK
   ```

3. Confirmá el código de salida, porque es sobre eso que un script o un pipeline debe decidir:

   ```bash
   echo "exit code: $?"
   ```

4. Hacé lo mismo con el tarball del servidor, que es lo que consumen normalmente las instalaciones estilo `kubeadm` y los mirrors air-gapped:

   ```bash
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/kubernetes-server-linux-${ARCH}.tar.gz"
   curl -sL "https://dl.k8s.io/release/${K8S_VERSION}/kubernetes-server-linux-${ARCH}.tar.gz.sha512" \
     | tr -d '\n' > server.sha512
   echo "$(cat server.sha512)  kubernetes-server-linux-${ARCH}.tar.gz" | sha512sum --check
   ```

   > Si el archivo `.sha512` no está publicado para tu release, los mismos digests están listados en el changelog de la release: `https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.34.md`.

5. Recién ahora instalá el binario:

   ```bash
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   kubectl version --client
   ```

**Preguntas**

1. ¿Por qué `sha256sum --check` falla con "no properly formatted checksum lines found" si le pasás `kubectl.sha256` directamente?
2. El archivo de checksum está en el mismo servidor que el binario. ¿Contra qué ataque te protege realmente el checksum, y contra cuál *no*?
3. ¿Por qué el paso 5 va después del paso 2, y no antes?
4. ¿Cuál es la razón relevante para la seguridad de usar `install -o root -g root -m 0755` en lugar de `cp` + `chmod +x`?

---

## Ejercicio 3 — Prueba negativa: detectar un binario manipulado

Un control que nunca viste fallar es un control que no probaste.

1. Hacé una copia y modificá un byte al final:

   ```bash
   cd ~/verify-lab
   cp kubectl kubectl-tampered
   printf '\x00' >> kubectl-tampered
   ```

2. Compará los dos hashes visualmente:

   ```bash
   sha256sum kubectl kubectl-tampered
   ```

3. Ejecutá la misma verificación contra el archivo manipulado y capturá el código de salida:

   ```bash
   echo "$(cat kubectl.sha256)  kubectl-tampered" | sha256sum --check
   echo "exit code: $?"
   ```

   Salida esperada:

   ```
   kubectl-tampered: FAILED
   sha256sum: WARNING: 1 computed checksum did NOT match
   exit code: 1
   ```

4. Ahora demostrá que el binario manipulado igual *funciona*:

   ```bash
   chmod +x kubectl-tampered
   ./kubectl-tampered version --client
   ```

5. Compará los tamaños de archivo y limpiá:

   ```bash
   ls -l kubectl kubectl-tampered
   rm -f kubectl-tampered
   ```

**Preguntas**

1. El paso 4 muestra el binario manipulado ejecutándose normalmente. ¿Qué lección enseña eso sobre "funciona, así que debe estar bien"?
2. Un único byte NUL agregado cambió toda la salida SHA-256. ¿Qué propiedad de una función hash criptográfica es esa, y por qué importa acá?
3. ¿Comparar el *tamaño* del archivo habría detectado un `kubectl` troyanizado real? ¿Por qué sí o por qué no?
4. En un pipeline de CI, ¿qué tiene de malo `sha256sum --check checksums.txt || true`?

---

## Ejercicio 4 — Verificar la firma Sigstore de un binario de release

Desde la v1.24, los artefactos de release de Kubernetes se firman con cosign usando firma keyless (Fulcio/Rekor). Los checksums prueban *integridad*; las firmas prueban *provenance*.

1. Instalá cosign:

   ```bash
   cd ~/verify-lab
   curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   sudo install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
   cosign version
   ```

2. Descargá la firma y el certificado de firma para `kubectl`:

   ```bash
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.sig"
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl.cert"
   ```

3. Inspeccioná el certificado antes de confiar en él — mirá el Subject Alternative Name:

   ```bash
   openssl x509 -in kubectl.cert -noout -text | grep -A1 "Subject Alternative Name"
   # If that errors, the file is base64-wrapped:
   # base64 -d kubectl.cert | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
   ```

4. Verificá el blob, atándolo a la identidad esperada **y** al emisor OIDC esperado:

   ```bash
   cosign verify-blob kubectl \
     --signature kubectl.sig \
     --certificate kubectl.cert \
     --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   ```

   Salida esperada:

   ```
   Verified OK
   ```

5. Ejecutá la prueba negativa — misma firma, artefacto equivocado:

   ```bash
   cp kubectl kubectl-evil && printf '\x00' >> kubectl-evil
   cosign verify-blob kubectl-evil \
     --signature kubectl.sig \
     --certificate kubectl.cert \
     --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   echo "exit code: $?"
   rm -f kubectl-evil
   ```

6. Ejecutá una segunda prueba negativa — artefacto correcto, identidad esperada equivocada:

   ```bash
   cosign verify-blob kubectl \
     --signature kubectl.sig --certificate kubectl.cert \
     --certificate-identity attacker@example.com \
     --certificate-oidc-issuer https://accounts.google.com
   echo "exit code: $?"
   ```

**Preguntas**

1. ¿Qué garantía extra te da la firma de cosign que el archivo `.sha256` no da?
2. ¿Por qué `--certificate-identity` y `--certificate-oidc-issuer` son **obligatorios** en cosign v2? ¿Qué le pasa a tu postura de seguridad si pudieras omitirlos?
3. El certificado de Fulcio es válido durante aproximadamente diez minutos. ¿Cómo puede una firma hecha hace meses seguir verificando hoy?
4. Tu servidor de build está air-gapped y no puede alcanzar `rekor.sigstore.dev`. Nombrá un flag que haga que la verificación proceda y explicá el trade-off que aceptás al usarlo.

---

## Ejercicio 5 — Verificar las firmas de las imágenes de contenedor del plano de control

1. Localizá dónde se almacena la firma de una imagen en el registry:

   ```bash
   cosign triangulate registry.k8s.io/kube-apiserver:${K8S_VERSION}
   ```

2. Verificá la firma de la imagen contra la identidad de firma de imágenes (nota: **no** es la misma identidad usada para los binarios):

   ```bash
   cosign verify registry.k8s.io/kube-apiserver:${K8S_VERSION} \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com | jq '.[0].optional'
   ```

3. Resolvé el tag a un digest inmutable y verificá *el digest*:

   ```bash
   DIGEST=$(crictl images --digests 2>/dev/null | awk '/kube-apiserver/ {print $3; exit}')
   echo "$DIGEST"
   cosign verify "registry.k8s.io/kube-apiserver@${DIGEST}" \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com >/dev/null && echo "signature OK"
   ```

4. Verificá el conjunto completo de imágenes que necesita la versión de tu clúster:

   ```bash
   for img in $(kubeadm config images list --kubernetes-version ${K8S_VERSION}); do
     echo "== $img"
     cosign verify "$img" \
       --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
       --certificate-oidc-issuer https://accounts.google.com >/dev/null 2>&1 \
       && echo "  OK" || echo "  FAILED / unsigned"
   done
   ```

5. Prueba negativa — verificá una imagen que el proceso de release de Kubernetes nunca firmó:

   ```bash
   cosign verify docker.io/library/nginx:latest \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   echo "exit code: $?"
   ```

**Preguntas**

1. ¿Por qué verificar `image:tag` es más débil que verificar `image@sha256:…`, incluso cuando ambas tienen éxito ahora mismo?
2. El paso 4 puede reportar `FAILED / unsigned` para algunas imágenes (por ejemplo, un CNI de terceros o un `etcd` mirroreado). ¿Es eso necesariamente un compromiso? ¿Qué deberías hacer al respecto?
3. `cosign verify` tuvo éxito en tu estación de trabajo. ¿Eso impide que una imagen comprometida se ejecute en el clúster? ¿Qué componente necesitarías para eso?
4. ¿Qué devuelve `cosign triangulate`, y por qué el almacenamiento de la firma como un tag separado es relevante cuando mirroreás imágenes hacia un registry air-gapped?

---

## Ejercicio 6 — Confiar en el repositorio de paquetes, no solo en los paquetes

La mayoría de los clústeres instalan `kubelet`/`kubeadm`/`kubectl` desde `pkgs.k8s.io`. El ancla de confianza ahí es una clave GPG.

1. Obtené la clave de firma del repositorio e inspeccionala *antes* de instalarla:

   ```bash
   cd ~/verify-lab
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key -o k8s-1.34-release.key
   gpg --show-keys --with-fingerprint --with-colons k8s-1.34-release.key | grep -E '^(pub|fpr|uid)'
   ```

2. Instalala en un keyring dedicado (nunca en el conjunto global de confianza):

   ```bash
   sudo mkdir -p /etc/apt/keyrings
   sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg < k8s-1.34-release.key
   sudo chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   ```

3. Acotá esa clave a exactamente un repositorio con `signed-by=`:

   ```bash
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
     | sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update
   ```

4. Demostrá que la verificación de firma está activa rompiéndola:

   ```bash
   sudo cp /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/k8s-key.bak
   sudo dd if=/dev/urandom of=/etc/apt/keyrings/kubernetes-apt-keyring.gpg bs=64 count=1 status=none
   sudo apt-get update 2>&1 | grep -iE 'NO_PUBKEY|not signed|GPG error' || echo "no error - investigate!"
   sudo cp /tmp/k8s-key.bak /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   sudo apt-get update >/dev/null && echo "restored"
   ```

5. En un nodo basado en RPM, los controles equivalentes viven en la definición del repo — confirmá que ambos flags estén habilitados:

   ```bash
   grep -E 'gpgcheck|repo_gpgcheck|gpgkey' /etc/yum.repos.d/kubernetes.repo
   ```

6. Verificá que los archivos de los paquetes instalados no hayan derivado respecto de lo que el paquete declaró:

   ```bash
   sudo dpkg --verify kubelet kubeadm kubectl ; echo "dpkg exit: $?"
   # RPM-based:
   # sudo rpm -V kubelet kubeadm kubectl ; echo "rpm exit: $?"
   ```

**Preguntas**

1. ¿Qué sale mal concretamente si dejás caer la clave en `/etc/apt/trusted.gpg.d/` en lugar de usar `signed-by=`?
2. En el paso 4, `apt-get update` falló. ¿La firma de qué archivo se estaba verificando realmente?
3. `gpgcheck=1` versus `repo_gpgcheck=1` — ¿qué cubre cada uno?
4. `dpkg --verify` no reportó nada para un archivo que un atacante reemplazó. Dá una razón por la que eso puede pasar, y nombrá la clase de herramienta que cierra la brecha.

---

## Ejercicio 7 — Auditar los binarios que ya están corriendo en un nodo

La verificación antes del despliegue es la mitad del trabajo; también necesitás detectar manipulación posterior a la instalación.

1. Averiguá exactamente qué versión declara ser cada binario del nodo:

   ```bash
   for b in kubelet kubeadm kubectl; do
     printf '%-8s %s\n' "$b" "$(command -v $b) -> $($b --version 2>/dev/null | head -1)"
   done
   ```

2. Hasheá el `kubelet` instalado y obtené el checksum oficial para esa versión exacta:

   ```bash
   KUBELET_VER=$(kubelet --version | awk '{print $2}')
   LOCAL=$(sha256sum "$(command -v kubelet)" | awk '{print $1}')
   OFFICIAL=$(curl -sL "https://dl.k8s.io/release/${KUBELET_VER}/bin/linux/${ARCH}/kubelet.sha256")
   echo "local:    $LOCAL"
   echo "official: $OFFICIAL"
   [ "$LOCAL" = "$OFFICIAL" ] && echo "MATCH" || echo "MISMATCH - investigate"
   ```

3. Registrá una línea base firmada de las rutas relevantes para la seguridad, para que el drift sea detectable:

   ```bash
   sudo sha256sum /usr/bin/kubelet /usr/bin/kubeadm /usr/bin/kubectl \
        /etc/kubernetes/manifests/*.yaml \
        > ~/verify-lab/node-baseline.sha256
   cat ~/verify-lab/node-baseline.sha256
   ```

4. Re-verificá la línea base en cualquier momento posterior:

   ```bash
   sudo sha256sum --check ~/verify-lab/node-baseline.sha256
   echo "exit: $?"
   ```

5. Simulá drift en un manifiesto de Pod estático y volvé a ejecutar la verificación:

   ```bash
   sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.bak
   sudo sed -i 's/--anonymous-auth=false/--anonymous-auth=true/' /etc/kubernetes/manifests/kube-apiserver.yaml
   sudo sha256sum --check ~/verify-lab/node-baseline.sha256 | grep -i failed
   sudo cp /tmp/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
   sudo sha256sum --check ~/verify-lab/node-baseline.sha256
   ```

6. Verificá la propiedad y los permisos de los binarios y del directorio de manifiestos:

   ```bash
   stat -c '%n owner=%U:%G mode=%a' /usr/bin/kubelet /etc/kubernetes/manifests
   ```

**Preguntas**

1. En el paso 2 el hash coincidió. ¿Por qué un nodo legítimo y no comprometido podría igualmente mostrar `MISMATCH`?
2. ¿Dónde debería almacenarse `node-baseline.sha256`, y por qué mantenerlo solo en el nodo que describe es un diseño débil?
3. ¿Por qué los manifiestos de Pods estáticos en `/etc/kubernetes/manifests` son un objetivo de manipulación de valor especialmente alto?
4. `/usr/bin/kubelet` tiene modo `755` y pertenece a `root:root`. Si fuera `root:root 775` y una cuenta de operador estuviera en el grupo `root`, ¿qué ganaría el atacante?

---

## Ejercicio 8 — Fijar imágenes por digest y confirmar qué se ejecutó realmente

1. Resolvé un tag a un digest sin descargar la imagen entera:

   ```bash
   cosign triangulate registry.k8s.io/pause:3.10 2>/dev/null
   crictl pull registry.k8s.io/pause:3.10
   crictl images --digests | grep pause
   ```

2. Desplegá un Pod fijado por digest (reemplazá el digest por el que acabás de resolver):

   ```bash
   PAUSE_DIGEST=$(crictl images --digests | awk '/pause/ {print $3; exit}')
   cat <<EOF | kubectl apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pinned-demo
   spec:
     containers:
     - name: app
       image: registry.k8s.io/pause@${PAUSE_DIGEST}
   EOF
   ```

3. Preguntale al clúster qué ejecutó *realmente*, no qué pediste:

   ```bash
   kubectl get pod pinned-demo -o jsonpath='{.spec.containers[*].image}{"\n"}'
   kubectl get pod pinned-demo -o jsonpath='{.status.containerStatuses[*].imageID}{"\n"}'
   ```

4. Auditá cada contenedor en ejecución del clúster en busca de referencias basadas en tags (mutables):

   ```bash
   kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.containers[*].image}{"\n"}{end}' \
     | grep -v '@sha256:' | sort -u
   ```

5. Limpiá:

   ```bash
   kubectl delete pod pinned-demo
   ```

**Preguntas**

1. `.spec.containers[].image` y `.status.containerStatuses[].imageID` pueden discrepar. ¿Cuál es la evidencia, y por qué?
2. Con una imagen fijada por digest, ¿`imagePullPolicy: Always` versus `IfNotPresent` cambia la garantía de integridad? Explicá.
3. Un atacante con acceso de push re-taggea `v1.2.3` para que apunte a un conjunto de capas malicioso. ¿Cuáles de tus Pods se ven afectados, y cuáles no?
4. ¿Qué costo operativo aceptás al fijar digests en todos lados, y cómo se absorbe normalmente?

---

## Ejercicio 9 — Verificar la provenance de un chart de Helm

Los charts también son artefactos de plataforma: llevan los manifiestos que definen tu postura de seguridad.

1. Creá una clave de firma y exportá los keyrings en el formato legacy que Helm necesita:

   ```bash
   cd ~/verify-lab
   gpg --batch --quick-generate-key "Lab Signer <lab@example.com>" default default never
   gpg --export-secret-keys > ~/.gnupg/secring.gpg
   gpg --export > ~/.gnupg/pubring-legacy.gpg
   ```

2. Creá y firmá un chart:

   ```bash
   helm create demo
   helm package --sign --key 'Lab Signer' --keyring ~/.gnupg/secring.gpg demo
   ls -l demo-0.1.0.tgz demo-0.1.0.tgz.prov
   ```

3. Leé el archivo de provenance — contiene los metadatos del chart más el hash del paquete, todo dentro de un bloque firmado:

   ```bash
   head -30 demo-0.1.0.tgz.prov
   grep -A2 'files:' demo-0.1.0.tgz.prov
   ```

4. Verificá el chart:

   ```bash
   helm verify demo-0.1.0.tgz --keyring ~/.gnupg/pubring-legacy.gpg
   echo "exit: $?"
   ```

5. Manipulá el chart empaquetado y volvé a verificar:

   ```bash
   cp demo-0.1.0.tgz demo-tampered.tgz
   cp demo-0.1.0.tgz.prov demo-tampered.tgz.prov
   printf '\x00' >> demo-tampered.tgz
   helm verify demo-tampered.tgz --keyring ~/.gnupg/pubring-legacy.gpg
   echo "exit: $?"
   ```

6. Forzá la verificación en el momento de instalar y de descargar:

   ```bash
   helm install --dry-run --verify --keyring ~/.gnupg/pubring-legacy.gpg demo ./demo-0.1.0.tgz
   # For remote charts:
   # helm pull --verify --keyring ~/.gnupg/pubring-legacy.gpg <repo>/<chart> --version <ver>
   ```

**Preguntas**

1. ¿Qué firma realmente un archivo `.prov` — el `.tgz`, los manifiestos renderizados, o los metadatos del chart?
2. `helm verify` pasó. ¿Qué dos afirmaciones distintas estableciste?
3. ¿Qué pasa si ejecutás `helm install` **sin** `--verify` sobre un chart que trae un `.prov` válido?
4. ¿Por qué la provenance del chart no sustituye la verificación de las imágenes de contenedor que el chart referencia?

---

## Ejercicio 10 — SBOMs y attestations (opcional, para profundizar)

1. Descargá el SBOM SPDX publicado para la release:

   ```bash
   cd ~/verify-lab
   curl -Ls "https://sbom.k8s.io/${K8S_VERSION}/release" -o kubernetes-${K8S_VERSION}.spdx
   head -20 kubernetes-${K8S_VERSION}.spdx
   grep -c '^SPDXID:' kubernetes-${K8S_VERSION}.spdx
   ```

2. Buscá en el SBOM un artefacto específico y su checksum declarado:

   ```bash
   grep -B2 -A6 'FileName:.*kubectl' kubernetes-${K8S_VERSION}.spdx | head -40
   ```

3. Contrastá el checksum declarado en el SBOM contra el archivo que verificaste en el Ejercicio 2:

   ```bash
   sha256sum kubectl
   ```

4. Intentá recuperar una attestation in-toto para una imagen de la release (si la release publica una, cosign imprime el payload; si no, informa que no se encontraron attestations coincidentes):

   ```bash
   cosign verify-attestation --type slsaprovenance \
     registry.k8s.io/kube-apiserver:${K8S_VERSION} \
     --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com \
     2>&1 | head -20
   ```

**Preguntas**

1. Un SBOM lista componentes. ¿Descargar un SBOM te dice algo sobre integridad por sí mismo?
2. ¿Cuál es la diferencia entre una *firma* y una *attestation* en el modelo de Sigstore?
3. ¿Cómo cambia un SBOM tu tiempo de respuesta cuando aparece un CVE en una librería que Kubernetes vendoriza?

---

## Cierre: la checklist previa al despliegue

Antes de que cualquier binario, paquete, imagen o chart de plataforma llegue a un nodo:

| Artefacto | Verificación mínima | Comando |
|---|---|---|
| Binario de release | SHA-256 + firma cosign | `sha256sum --check` + `cosign verify-blob` |
| Tarball de release | SHA-512 de la página de release/changelog | `sha512sum --check` |
| Imagen de contenedor | Firma atada a una identidad, referenciada por digest | `cosign verify <img>@sha256:…` |
| Paquete de la distro | Clave del repo acotada con `signed-by=`, `gpgcheck=1` | `apt-get update` / `rpm -V` |
| Chart de Helm | Archivo de provenance verificado | `helm verify` / `helm install --verify` |
| Archivos instalados en el nodo | Comparación con hash de línea base | `sha256sum --check baseline` |

Dos reglas que vale la pena memorizar: **verificá antes de instalar, nunca después**, y **atá siempre una firma a una identidad y un emisor esperados** — un "está firmado" sin atar prueba únicamente que *alguien* lo firmó.

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas</summary>

### Ejercicio 1

1. `stable.txt` te dice qué considera estable upstream en este momento; se obtiene en tiempo de ejecución y puede cambiar entre tu corrida de prueba y tu corrida de producción. Es un insumo para una decisión, no un paso de verificación. La seguridad requiere una versión que fijaste deliberadamente y que podés reproducir.
2. TLS protege el *canal*: prueba que estás hablando con `dl.k8s.io` y que nadie modificó los bytes en tránsito. No dice nada sobre si el objeto almacenado en ese servidor es el objeto que produjo el equipo de release de Kubernetes — un bucket comprometido, un mirror envenenado o un edge de CDN malicioso servirían todos su contenido sobre TLS perfectamente válido. La integridad y la provenance necesitan checksums y firmas.
3. "Kubernetes 1.34" es un rango de decenas de binarios distintos con distintos fixes y distintos hashes; no es verificable. `v1.34.0` más un digest es un objeto único, inmutable y reproducible — un auditor puede volver a descargarlo, volver a hashearlo y obtener la misma respuesta el año que viene.

### Ejercicio 2

1. `sha256sum --check` espera líneas de la forma `<hash>  <filename>`. El archivo `.sha256` publicado contiene solo el hash pelado, sin separador de dos espacios y sin nombre de archivo, así que el parser no encuentra líneas válidas. Tenés que construir la línea vos mismo, que es la razón de que exista el idiom `echo "$(cat kubectl.sha256)  kubectl"`.
2. Protege contra **corrupción accidental o en tránsito** y contra manipulación que afecte al binario pero no al archivo de checksum (un compromiso parcial de un mirror, una descarga rota, una caché de proxy). **No** protege contra un atacante que controla el servidor o la conexión de extremo a extremo, porque simplemente publicaría un checksum que coincida con su binario malicioso. Cerrar esa brecha es exactamente lo que hace la firma de cosign en el Ejercicio 4.
3. Porque instalar primero significa que el binario no confiable ya está en el `PATH`, ya pertenece a root y es ejecutable, y posiblemente ya fue ejecutado por otro proceso o por un hook de autocompletado de la shell. La verificación debe condicionar la instalación, no seguirla.
4. Establece la propiedad y los permisos finales de forma atómica como parte de colocar el archivo. Un `cp` seguido de `chmod` deja una ventana en la que el archivo existe en su destino con la propiedad del usuario que copió o con un modo permisivo derivado del umask — un atacante local puede sobrescribirlo o reemplazarlo en esa ventana. `install` también evita heredar un grupo o un modo del directorio de descarga.

### Ejercicio 3

1. Funcionalidad e integridad son independientes. Un `kubectl` troyanizado real se comportaría exactamente igual que el genuino para cada comando que pruebes, mientras adicionalmente exfiltra tu kubeconfig. "Funciona" no es evidencia de autenticidad; solo lo es una verificación criptográfica.
2. El **efecto avalancha** — un cambio de un bit en la entrada cambia aproximadamente la mitad de los bits de salida, de forma impredecible. Combinado con la resistencia a colisiones y a segunda preimagen, esto significa que un atacante no puede fabricar un binario malicioso que hashee al valor publicado.
3. No. El tamaño es trivialmente controlable: un atacante que quita tantos bytes como agrega produce un tamaño de archivo idéntico byte a byte. Rellenar hasta un tamaño objetivo es una técnica estándar. La comparación de tamaños es una verificación de sensatez, nunca un control de seguridad.
4. `|| true` se traga el código de salida distinto de cero, así que el pipeline reporta éxito incluso cuando la verificación falló. La verificación se vuelve decorativa — produce ruido de log que parece garantía mientras no impone nada. A los pasos de verificación hay que permitirles hacer fallar el build.

### Ejercicio 4

1. El checksum prueba que el archivo coincide con *un hash publicado*. La firma de cosign prueba que el archivo fue producido y firmado por **la identidad de automatización de release de Kubernetes**, con el evento registrado en el log público de transparencia Rekor. Un atacante que controle completamente `dl.k8s.io` puede falsificar un checksum; no puede falsificar un certificado de Fulcio para `krel-staging@k8s-releng-prod.iam.gserviceaccount.com` sin comprometer también el emisor OIDC de Google y la CA de Sigstore — y cualquier firma así sería públicamente visible en el log de transparencia.
2. Le dicen a cosign *de quién* aceptar la firma. Sin ellos, la verificación se degrada a "este artefacto lleva una firma sintácticamente válida de alguien" — un atacante firma su binario malicioso con su propia identidad de Sigstore y verifica. cosign v2 los hizo obligatorios precisamente porque omitirlos era el mal uso más común en la práctica de la v1.
3. Porque la verificación comprueba que el certificado era **válido en el momento de la firma**, y la entrada en el log de transparencia Rekor provee el timestamp confiable que prueba *cuándo* se hizo la firma. La corta vida del certificado limita el radio de daño de una clave robada sin invalidar firmas pasadas.
4. `--insecure-ignore-tlog=true` (a menudo junto con `--insecure-ignore-sct`). El trade-off: perdés la prueba del log de transparencia sobre el momento de la firma y la auditabilidad pública, así que la verificación ahora descansa solo en la cadena de certificados — un certificado revocado o emitido maliciosamente es mucho más difícil de detectar. El patrón correcto para entornos air-gapped es verificar en el límite donde *sí* tenés conectividad, y luego mirrorear hacia adentro solo artefactos verificados.

### Ejercicio 5

1. Un tag es un puntero mutable. Verificar `image:tag` establece que *lo que sea que el tag apuntara en el momento de la verificación* estaba firmado; el tag puede moverse a un manifiesto distinto (sin firmar o malicioso) un segundo después, y el siguiente pull obtiene el nuevo contenido. Un digest es la dirección de contenido en sí — verificar `image@sha256:…` y luego desplegar ese mismo digest cierra la brecha de tiempo-de-verificación/tiempo-de-uso.
2. No necesariamente. Las imágenes fuera del proceso de release de Kubernetes (CNIs de terceros, builds mirroreados de `etcd`, imágenes de proveedores) están firmadas por identidades distintas o directamente no están firmadas. La respuesta correcta es determinar la identidad de firma correcta para cada fuente y verificar contra *esa*, y registrar una excepción explícita y revisada para cualquier cosa genuinamente sin firmar — no silenciar la verificación.
3. No. La verificación en tu estación de trabajo es orientativa; nada impide que alguien aplique un manifiesto que referencia una imagen no verificada. Hacerlo cumplir requiere un **admission controller de validación** que verifique firmas en el momento de la admisión (por ejemplo, la regla `verifyImages` de Kyverno, Sigstore Policy Controller, o Connaisseur), respaldado por una política que rechace imágenes sin firmar o de identidad desconocida.
4. Devuelve la referencia del registry donde se almacena la firma — el mismo repositorio con un tag derivado del digest de la imagen, terminado en `.sig`. Esto importa para el mirroreo air-gapped porque un `crane copy image:tag` o `skopeo copy` ingenuo de solo el manifiesto etiquetado deja atrás los tags `.sig` (y `.att`), y la verificación entonces falla dentro del entorno aislado. Tenés que copiar también los tags de firma (`cosign copy` se encarga de esto).

### Ejercicio 6

1. Una clave en `/etc/apt/trusted.gpg.d/` es de confianza para **todos** los repositorios configurados en el sistema. Si cualquier repo de tu lista de fuentes es secuestrado o se agrega un repo malicioso, esa clave puede presentarse para autenticar sus paquetes. `signed-by=` ata la clave a una única entrada de repositorio, de modo que el compromiso de un proveedor no puede usarse para autenticar paquetes de otro.
2. El archivo `InRelease` del repositorio (o el par `Release`/`Release.gpg`). Ese archivo está firmado por la clave del repo y contiene los hashes de los índices `Packages`, que a su vez contienen los hashes de cada `.deb`. Romper la clave rompe la cadena en su raíz, así que apt rechaza el repositorio entero — este es el modelo `apt-secure`.
3. `gpgcheck=1` verifica la firma GPG de cada **paquete RPM individual** antes de la instalación. `repo_gpgcheck=1` verifica la firma de los **metadatos del repositorio** (`repomd.xml`). Querés ambos: la firma de metadatos previene la manipulación de índices/downgrades, la firma de paquetes previene instalar un paquete sin firmar o alterado.
4. `dpkg --verify` compara contra checksums registrados en el momento del empaquetado y no cubre todo tipo de archivo ni todo paquete (manejo de `conffiles`, paquetes que no traen md5sums); un atacante con root también puede reescribir `/var/lib/dpkg/info/*.md5sums` para que coincida con su archivo modificado. La clase de herramienta que cierra la brecha es un sistema de **monitoreo de integridad de archivos / HIDS** con una línea base fuera del host o inmutable — AIDE, Tripwire, o detección en runtime como Falco.

### Ejercicio 7

1. Puede que el binario no haya venido de `dl.k8s.io` en absoluto: los paquetes de la distro o del proveedor a veces se recompilan desde el código fuente con distintos flags de compilador, se strippean, o se parchean, produciendo un hash legítimamente distinto. Las distribuciones gestionadas (y algunos proveedores de nube) despachan sus propios builds. `MISMATCH` significa "esto no vino de la release upstream" — lo que te obliga a identificar y verificar la cadena de suministro *real*, no a asumir compromiso ni a ignorarlo.
2. Fuera del nodo — un repositorio de artefactos firmado, un servidor de gestión de configuración, o un almacenamiento WORM/inmutable. Mantenerlo solo en el nodo que describe significa que un atacante con root simplemente regenera la línea base después de manipular, y toda verificación posterior pasa. La línea base debe vivir en algún lugar que el propio nodo no pueda reescribir.
3. Porque el kubelet aplica lo que sea que encuentre ahí **sin intervención del API server, sin RBAC y sin control de admisión**. Editar `kube-apiserver.yaml` le permite a un atacante habilitar autenticación anónima, quitar plugins de admisión, agregar un webhook de autenticación, o montar el sistema de archivos del host — una toma de control completa del plano de control que evade todas las políticas dentro del clúster que hayas configurado.
4. Permiso de escritura para el grupo en un binario que pertenece a root significa que cualquier miembro del grupo `root` puede reemplazar `/usr/bin/kubelet` con un troyano **sin ser root**, y el kubelet entonces lo ejecuta como root en el siguiente reinicio. Es una vía directa de escalada de no privilegiado a root. Los binarios de plataforma no deben ser escribibles por grupo ni por el mundo, y sus directorios padres tampoco.

### Ejercicio 8

1. `.status.containerStatuses[].imageID` es la evidencia: es el digest que el runtime de contenedores realmente resolvió y ejecutó. `.spec.containers[].image` es solo el pedido. Divergen cada vez que la spec usó un tag mutable, así que las auditorías y la respuesta a incidentes deben leer el campo de status.
2. Con una referencia por digest, la política de pull no cambia la garantía de integridad — el runtime solo puede obtener contenido cuyo hash coincida con el digest, así que `IfNotPresent` reutiliza una copia local idéntica byte a byte y `Always` vuelve a traer los mismos bytes. (La política igual importa para la disponibilidad y para escenarios de envenenamiento de la caché del almacén local, pero no para la garantía de contenido.) Con un tag, `Always` *aumenta* activamente el riesgo, porque cada reinicio vuelve a resolver un puntero que un atacante puede haber movido.
3. Los Pods que referencian `image:v1.2.3` se ven afectados en su próximo pull — que con `imagePullPolicy: Always` es el próximo reinicio, reprogramación o falla de nodo. Los Pods que referencian `image@sha256:…` no: el digest ya no resuelve al contenido del atacante, así que el pull o bien tiene éxito con los bytes originales o bien falla ruidosamente. Ese "falla ruidosamente" es una característica.
4. Los digests son ilegibles y hay que actualizarlos en cada actualización legítima, así que los humanos dejan de poder revisar manifiestos a ojo y el parcheo rutinario se convierte en un cambio de código. Se absorbe con automatización: un bot estilo renovate/dependabot que resuelve tags a digests y abre un PR revisable, o un paso de renderizado GitOps que fija en tiempo de build mientras los desarrolladores siguen escribiendo tags.

### Ejercicio 9

1. El archivo `.prov` es un documento clear-signed que contiene los metadatos del `Chart.yaml` del chart **más un bloque `files:` con el digest SHA-256 del paquete `.tgz`**. Así que firma los metadatos directamente y el contenido del paquete indirectamente, a través de ese hash. No firma los manifiestos renderizados, que dependen de los values suministrados en el momento de la instalación.
2. (a) **Integridad** — el `.tgz` que tenés hashea al valor registrado en el archivo de provenance, así que no fue alterado. (b) **Provenance** — ese archivo de provenance fue firmado por una clave privada cuya mitad pública está en tu keyring, así que vino de un firmante en el que decidiste confiar. Ambas afirmaciones son necesarias; cualquiera por sí sola es insuficiente.
3. No se verifica nada. Helm no comprueba la provenance implícitamente — el archivo `.prov` simplemente se ignora, y un chart manipulado se instala sin problemas. La verificación es opt-in por comando (`--verify`), razón por la cual pertenece a tu tooling/wrapper de CI y no a la memoria muscular humana.
4. Un chart es un conjunto de plantillas que *referencian* imágenes por nombre. Firmar el chart prueba que las plantillas son auténticas; no dice nada sobre los bytes detrás de `image: vendor/app:1.2.3`, que se obtienen de un registry en el momento de creación del Pod y son una cadena de suministro completamente separada. Necesitás provenance del chart **y** verificación de firma de imágenes (idealmente forzada en la admisión) para cubrir ambas.

### Ejercicio 10

1. No. Un SBOM es una *afirmación* sobre composición — un archivo de texto que cualquiera puede escribir. Por sí solo provee inventario, no integridad. Se vuelve confiable únicamente cuando está a su vez firmado o entregado como una attestation firmada atada al digest del artefacto, y cuando los checksums que declara se verifican efectivamente contra el artefacto (paso 3).
2. Una **firma** afirma solamente "esta identidad respalda estos bytes exactos". Una **attestation** es una *declaración firmada sobre* un artefacto — un payload in-toto con un tipo de predicado (provenance SLSA, SBOM SPDX, resultado de escaneo de vulnerabilidades) atado al digest del artefacto. Las firmas responden "¿esto es auténtico?"; las attestations responden "¿cómo se construyó, qué contiene, y qué se verificó?"
3. Drásticamente. Sin SBOMs, responder a un CVE en una librería vendorizada significa bucear en el código fuente de cada release para determinar si está afectada. Con SBOMs consultás tu inventario por el paquete afectado y el rango de versiones y obtenés una lista inmediata y respaldada por evidencia de releases e imágenes impactadas — convirtiendo una investigación de varios días en una búsqueda.

</details>

---

## Fuentes

- CNCF, *CKS Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Documentación de Kubernetes, *Verify Signed Kubernetes Artifacts* — https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/
- Documentación de Kubernetes, *Install and Set Up kubectl on Linux* — https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Kubernetes, *Download Kubernetes / release artifacts* — https://kubernetes.io/releases/download/
- Documentación de Kubernetes, *Installing kubeadm (pkgs.k8s.io repositories)* — https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Blog de Kubernetes, *Signing Kubernetes Release Artifacts* — https://kubernetes.io/blog/2022/05/03/kubernetes-1-24-release-signing/
- Documentación de Sigstore, *Verifying with cosign* — https://docs.sigstore.dev/cosign/verifying/verify/
- Documentación de Helm, *Helm Provenance and Integrity* — https://helm.sh/docs/topics/provenance/
- Debian, *SecureApt* — https://wiki.debian.org/SecureApt
- SLSA, *Supply-chain Levels for Software Artifacts* — https://slsa.dev/spec/v1.0/levels