# CKS 1.5 — Verify platform binaries before deploying

**Certificación:** CKS v1.34 | **Dominio:** Cluster Setup | **Peso:** 3
**Fuente de referencia:** [CNCF CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

Antes de instalar cualquier binario del control plane o del node (`kubectl`, `kubeadm`, `kubelet`), hay que confirmar que el archivo descargado es exactamente el que publicó el proyecto Kubernetes, y no una versión alterada por un mirror comprometido, un MITM o un typosquat. Esto se logra comparando el **checksum** (hash criptográfico) del archivo descargado contra el hash publicado oficialmente, y opcionalmente verificando la **firma criptográfica** del artefacto.

---

## Ejercicio 1 — Descargar `kubectl` y su checksum publicado

1. Determiná la versión estable actual:
   ```bash
   curl -L -s https://dl.k8s.io/release/stable.txt
   ```
2. Guardá esa versión en una variable de entorno:
   ```bash
   export K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
   echo "$K8S_VERSION"
   ```
3. Descargá el binario `kubectl` para esa versión:
   ```bash
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
   ```
4. Descargá el archivo de checksum publicado junto al binario:
   ```bash
   curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256"
   ```
5. Inspeccioná el contenido del archivo de checksum:
   ```bash
   cat kubectl.sha256
   ```

**Preguntas de comprensión:**
1. ¿Por qué el checksum se descarga de un archivo separado (`kubectl.sha256`) en vez de venir embebido en el binario?
2. Si un atacante controla el mirror desde donde bajás el binario, ¿alcanza con este paso para estar seguro? ¿Qué supuesto de confianza estás haciendo sobre `dl.k8s.io`?

---

## Ejercicio 2 — Verificar la integridad con `sha256sum`

1. Calculá el hash real del binario descargado:
   ```bash
   sha256sum kubectl
   ```
2. Compará automáticamente contra el valor publicado, con el formato que espera `sha256sum --check`:
   ```bash
   echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
   ```
3. Observá la salida. Debería decir `kubectl: OK`.
4. Solo si el resultado es `OK`, otorgá permisos de ejecución e instalá:
   ```bash
   chmod +x kubectl
   sudo mv kubectl /usr/local/bin/kubectl
   ```

**Preguntas de comprensión:**
3. ¿Qué significa exactamente que `sha256sum --check` devuelva `OK`? ¿Garantiza que el binario es "seguro", o solo que coincide con el hash que vos mismo le diste?
4. ¿Por qué el paso 4 (dar permisos e instalar) debe ejecutarse *solo* si la verificación fue exitosa?

---

## Ejercicio 3 — Detectar un binario alterado (simulación de supply-chain attack)

1. Hacé una copia del binario ya verificado:
   ```bash
   cp /usr/local/bin/kubectl ./kubectl-tampered
   ```
2. Alterá un solo byte del archivo para simular una modificación maliciosa:
   ```bash
   printf '\x00' | dd of=./kubectl-tampered bs=1 seek=100 count=1 conv=notrunc
   ```
3. Repetí la verificación contra el checksum original, apuntando al archivo alterado:
   ```bash
   echo "$(cat kubectl.sha256)  kubectl-tampered" | sha256sum --check
   ```
4. Observá el mensaje de error (`FAILED`).

**Preguntas de comprensión:**
5. ¿Por qué cambiar un solo byte es suficiente para que el hash completo no coincida?
6. En un pipeline de CI/CD que descarga binarios automáticamente, ¿qué acción debería disparar un `FAILED` en este chequeo?

---

## Ejercicio 4 — Aplicar el mismo mecanismo a `kubeadm` y `kubelet`

1. Descargá ambos binarios y sus checksums para la misma versión:
   ```bash
   for BIN in kubeadm kubelet; do
     curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/${BIN}"
     curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/${BIN}.sha256"
   done
   ```
2. Verificá los dos binarios en un solo paso:
   ```bash
   for BIN in kubeadm kubelet; do
     echo "$(cat ${BIN}.sha256)  ${BIN}" | sha256sum --check
   done
   ```
3. Instalá solo los que hayan pasado la verificación:
   ```bash
   chmod +x kubeadm kubelet
   sudo mv kubeadm kubelet /usr/local/bin/
   ```

**Preguntas de comprensión:**
7. ¿Por qué es importante verificar *cada* binario del node (`kubelet`, `kubeadm`, `kubectl`) por separado, y no asumir que si uno es confiable los demás también lo son?

---

## Ejercicio 5 — Verificar la firma criptográfica con `cosign` (más allá del checksum)

Desde que Kubernetes firma sus artefactos de release con `cosign` (keyless signing vía Sigstore), es posible verificar no solo la integridad sino también la **autoría** del artefacto.

1. Instalá `cosign` si no lo tenés (ver [documentación de Sigstore](https://docs.sigstore.dev/cosign/system_config/installation/)).
2. Descargá el archivo `checksums.txt` firmado y su certificado/firma para la versión de release correspondiente (publicados junto a los tarballs de la release).
3. Verificá la firma del archivo de checksums usando la identidad publicada por el proyecto:
   ```bash
   cosign verify-blob checksums.txt \
     --certificate checksums.txt.cert \
     --signature checksums.txt.sig \
     --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   ```
4. Solo si `cosign` confirma `Verified OK`, usá ese `checksums.txt` como fuente de confianza para validar los binarios individuales (como en los ejercicios 2 y 4).

**Preguntas de comprensión:**
8. ¿Qué problema de confianza resuelve `cosign verify-blob` que `sha256sum --check` por sí solo no resuelve?
9. ¿Qué son `--certificate-identity` y `--certificate-oidc-issuer`, y por qué reemplazan a una clave GPG estática en el modelo de *keyless signing*?

*(Referencia: [Kubernetes blog — Signing Release Artifacts](https://kubernetes.io/blog/2022/12/12/kubernetes-release-artifact-signing/))*

---

## Ejercicio 6 — Verificar imágenes de contenedor del control plane

Las imágenes oficiales del control plane (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-proxy`) publicadas en `registry.k8s.io` también están firmadas.

1. Elegí una imagen y su tag:
   ```bash
   export IMAGE="registry.k8s.io/kube-apiserver:${K8S_VERSION}"
   ```
2. Verificá su firma con `cosign`:
   ```bash
   cosign verify "$IMAGE" \
     --certificate-identity krel-staging@k8s-releng-prod.iam.gserviceaccount.com \
     --certificate-oidc-issuer https://accounts.google.com
   ```
3. Compará la salida contra el intento de verificar una imagen de un registry no oficial (por ejemplo, un mirror de terceros) y observá que la verificación falla o no encuentra firma.

**Preguntas de comprensión:**
10. ¿Por qué verificar la imagen de contenedor del `kube-apiserver` es tan importante como verificar el binario `kubeadm` que la despliega?
11. Si `cosign verify` no encuentra ninguna firma asociada a una imagen, ¿qué conclusión NO deberías sacar automáticamente (pensá en imágenes legítimas pero no firmadas por este mecanismo)?

---

## Ejercicio 7 — Automatizar la verificación en un script reutilizable

1. Creá un script `verify-k8s-binaries.sh` que reciba la versión y arquitectura como parámetros y falle (`exit 1`) si algún binario no pasa la verificación:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   VERSION="$1"
   ARCH="${2:-amd64}"
   BINARIES=(kubectl kubeadm kubelet)

   for BIN in "${BINARIES[@]}"; do
     curl -sLO "https://dl.k8s.io/release/${VERSION}/bin/linux/${ARCH}/${BIN}"
     curl -sLO "https://dl.k8s.io/release/${VERSION}/bin/linux/${ARCH}/${BIN}.sha256"
     if ! echo "$(cat ${BIN}.sha256)  ${BIN}" | sha256sum --check --status; then
       echo "VERIFICATION FAILED: ${BIN}" >&2
       exit 1
     fi
     echo "OK: ${BIN}"
   done
   ```
2. Dale permisos de ejecución y corrélo:
   ```bash
   chmod +x verify-k8s-binaries.sh
   ./verify-k8s-binaries.sh "$K8S_VERSION"
   ```
3. Probá el caso de falla: modificá manualmente uno de los archivos `.sha256` descargados para que no coincida, y volvé a correr el script.

**Preguntas de comprensión:**
12. ¿Por qué usar `sha256sum --check --status` en vez de `sha256sum --check` dentro de un script pensado para un pipeline automatizado?
13. ¿En qué etapa del ciclo de vida de un cluster (aprovisionamiento, actualización, ambos) tiene sentido ejecutar este script como control obligatorio?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

1. Porque el checksum debe generarse y publicarse de forma independiente del binario: si viniera embebido en el mismo archivo, cualquier alteración del binario podría regenerar también un checksum embebido falso. Al ser un archivo separado publicado en el sitio oficial, actúa como una referencia externa de confianza.
2. No alcanza. Este chequeo solo garantiza que el binario descargado coincide con el checksum que también descargaste del mismo origen. El supuesto de confianza es que `dl.k8s.io` (el dominio oficial de releases de Kubernetes) no está comprometido y que la conexión TLS hacia él es íntegra. Por eso se complementa con verificación de firma (Ejercicio 5), que depende de una cadena de confianza distinta (Sigstore/OIDC).
3. Significa únicamente que el hash SHA-256 calculado sobre el archivo descargado coincide con el valor que vos le diste como referencia. No implica que el binario esté libre de vulnerabilidades o sea "seguro" en un sentido amplio, solo que no fue alterado respecto a esa referencia puntual.
4. Porque instalar (dar permisos de ejecución y mover a un `PATH` del sistema) un binario no verificado significa exponer al sistema a ejecutar código potencialmente malicioso o corrupto. El chequeo debe actuar como gate antes de cualquier paso irreversible.
5. Porque las funciones hash criptográficas (como SHA-256) están diseñadas con el efecto avalancha: un cambio mínimo en la entrada (aunque sea un solo bit) produce un hash de salida completamente distinto e impredecible. Esto hace que sea prácticamente imposible alterar un archivo y conservar el mismo hash.
6. Debería abortar el pipeline (fallar el build/deploy), alertar al equipo, y no promover ese artefacto a ningún ambiente. Un `FAILED` en este chequeo es indicador de un posible ataque a la cadena de suministro (supply chain) y nunca debe tratarse como advertencia ignorable.
7. Porque cada binario es un artefacto independiente con su propio archivo de checksum, y la confianza no es transitiva entre binarios: un `kubelet` verificado no dice nada sobre la integridad de un `kubeadm` descargado en la misma sesión. Cada uno pudo haberse corrompido de forma independiente (por ejemplo, por una descarga incompleta o un mirror comprometido en un artefacto puntual).
8. `sha256sum --check` solo confirma integridad (el archivo no cambió respecto a un hash de referencia), pero ese hash de referencia lo bajaste vos mismo y podría también haber sido reemplazado por un atacante. `cosign verify-blob` valida además la **autenticidad**: que la firma fue generada por una identidad específica (en este caso, la cuenta de servicio del proceso de release de Kubernetes) confirmada por una autoridad externa (Sigstore/Fulcio + Rekor), no por un hash que vos mismo descargaste del mismo lugar.
9. `--certificate-identity` es la identidad (por ejemplo, una cuenta de servicio o workflow de CI) que debió haber firmado el artefacto, y `--certificate-oidc-issuer` es el proveedor de identidad (OIDC) que emitió el certificado efímero usado para firmar. En el modelo *keyless* de Sigstore no existe una clave privada de largo plazo que gestionar ni rotar: se emite un certificado de corta duración vinculado a una identidad verificada por OIDC, y la firma queda registrada en un log de transparencia (Rekor), eliminando el riesgo de robo o filtración de una clave GPG estática.
10. Porque `kubeadm` solo orquesta el despliegue: si la imagen del `kube-apiserver` que termina ejecutándose fue alterada, tener un `kubeadm` íntegro no evita que el control plane corra un componente comprometido. Ambos artefactos —el orquestador y lo que orquesta— forman parte de la misma cadena de confianza y deben verificarse por separado.
11. No deberías concluir automáticamente que la imagen es maliciosa o inválida. Puede tratarse de una imagen legítima construida antes de que el proyecto adoptara firma con `cosign`, o de una imagen de un componente de terceros que usa otro mecanismo de verificación (por ejemplo, verificación por checksum de su propio proceso de release). La ausencia de firma en este esquema puntual es una señal para investigar el origen del artefacto, no una prueba definitiva de compromiso.
12. Porque `--status` suprime la salida por texto y comunica el resultado únicamente a través del código de salida (`exit code`), que es lo que un script necesita para tomar decisiones (`if`) de forma confiable, sin tener que parsear mensajes de texto que podrían cambiar entre versiones de `sha256sum`.
13. En ambas etapas. Durante el aprovisionamiento inicial (bootstrap del cluster con `kubeadm init`/`join`) es crítico porque ahí se instalan los binarios base del control plane y los nodes. Durante las actualizaciones (upgrades de versión) es igual de crítico, porque cada nueva versión implica descargar y reemplazar binarios existentes, y un binario de upgrade comprometido tiene el mismo impacto que uno comprometido en la instalación inicial.

</details>