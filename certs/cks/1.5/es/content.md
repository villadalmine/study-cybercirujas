# 1.5 Verify Platform Binaries Before Deploying

## Por qué importa

Los binarios que forman el control plane y los nodos (`kubelet`, `kubeadm`, `kubectl`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-proxy`, y también componentes de soporte como `containerd`, `runc` y plugins CNI) son la base de confianza de todo el clúster. Si un atacante logra sustituir uno de estos binarios antes de que se instale —mediante un mirror comprometido, un ataque MITM en la descarga, o un build server envenenado— obtiene ejecución de código con privilegios de root en cada nodo o control sobre el control plane completo. Este es un ataque de **supply chain** clásico (comparable a incidentes como SolarWinds), y por eso el CIS Kubernetes Benchmark y el propio proceso de release de Kubernetes ponen énfasis en verificar la integridad de un binario **antes** de desplegarlo, no después.

La verificación se apoya en dos mecanismos complementarios:

- **Checksum (SHA-256/SHA-512)**: garantiza integridad (el archivo no fue alterado ni corrompido en tránsito).
- **Firma criptográfica (cosign / Sigstore, GPG en repos de paquetes)**: garantiza autenticidad (el archivo realmente proviene del proyecto Kubernetes).

## Fuentes oficiales de binarios

| Binario | Rol | Fuente oficial |
|---|---|---|
| `kubectl` | cliente | `dl.k8s.io`, repos `pkgs.k8s.io` |
| `kubeadm`, `kubelet`, `kube-proxy` | nodo | `dl.k8s.io`, repos `pkgs.k8s.io` |
| `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` | control plane | imágenes en `registry.k8s.io` (kubeadm las descarga como contenedores) |
| `containerd`, `runc`, plugins CNI | runtime/red | releases de sus repos GitHub respectivos |

`dl.k8s.io` es un bucket de Google Cloud Storage detrás de un dominio controlado por el proyecto Kubernetes (CDN + HTTPS), pero eso **no reemplaza** la verificación: la descarga puede ocurrir sobre una red insegura, un proxy corporativo que hace TLS-termination, o un host comprometido con `/etc/hosts` alterado. Nunca se deben usar mirrors no oficiales ni instaladores tipo `curl | bash` sin verificar el artefacto descargado.

## Verificación por checksum (SHA-256)

Cada binario publicado en `dl.k8s.io` tiene un archivo `.sha256` (y `.sha512`) hermano. El patrón es el mismo para `kubectl`, `kubeadm` y `kubelet`:

```bash
VERSION="v1.32.0"

for BIN in kubectl kubeadm kubelet; do
  curl -LO "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/${BIN}"
  curl -LO "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/${BIN}.sha256"
  echo "$(cat ${BIN}.sha256)  ${BIN}" | sha256sum --check
done
```

Salida esperada (integridad OK):

```
kubectl: OK
kubeadm: OK
kubelet: OK
```

Si el binario fue alterado o la descarga se corrompió:

```
kubelet: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
```

Ante un `FAILED` **nunca se debe continuar la instalación**: hay que descartar el archivo, repetir la descarga desde una red confiable y, si persiste, tratarlo como un posible indicador de compromiso (IOC) e investigar la fuente.

### Verificación manual contra el CHANGELOG

Como alternativa (útil en entornos air-gapped donde solo se dispone del tarball), los hashes SHA-512 de cada release también están publicados en texto plano en el CHANGELOG oficial del repo `kubernetes/kubernetes`, bajo la sección "Downloads for vX.Y.Z":

```bash
sha512sum kubernetes-node-linux-amd64.tar.gz
# comparar manualmente el valor contra la tabla del CHANGELOG-1.32.md
```

Esto permite verificar sin depender de que el archivo `.sha512` viaje junto al binario, protegiendo contra el caso en que ambos archivos (binario + checksum) fueron reemplazados juntos en el mismo mirror comprometido — conviene obtener el hash desde una fuente independiente (el repo de GitHub) del canal usado para bajar el binario.

## Verificación al instalar vía paquetes (apt/yum)

En producción es más común instalar `kubelet`/`kubeadm`/`kubectl` desde los repositorios oficiales `pkgs.k8s.io` (que reemplazaron a `apt.kubernetes.io`/`yum.kubernetes.io` en 2023), en cuyo caso `apt`/`dnf` verifican automáticamente la firma GPG del paquete usando la clave pública del repo:

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update && apt-get install -y kubelet kubeadm kubectl
```

Si la firma del repo no coincide, `apt` rechaza la instalación (`NO_PUBKEY` / `BADSIG`) antes de escribir un solo byte en disco. Esta es la vía preferida en la mayoría de los clústeres porque automatiza lo que en la descarga manual hay que hacer a mano.

## Verificación de imágenes firmadas del control plane (cosign)

Desde Kubernetes v1.24, todas las imágenes de contenedor publicadas en `registry.k8s.io` (kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy, etc.) están firmadas con **cosign** usando firma *keyless* de Sigstore (el certificado se emite vía OIDC y queda registrado en el transparency log Rekor, sin necesidad de gestionar una clave privada):

```bash
cosign verify registry.k8s.io/kube-apiserver-amd64:v1.32.0 \
  --certificate-oidc-issuer=https://accounts.google.com \
  --certificate-identity-regexp="^https://github.com/kubernetes/k8s.io.*$" \
  | jq
```

Salida (resumida):

```json
[
  {
    "critical": {
      "identity": { "docker-reference": "registry.k8s.io/kube-apiserver-amd64" },
      "type": "cosign container image signature"
    },
    "optional": { "Issuer": "https://accounts.google.com" }
  }
]
```

El OIDC issuer y el identity pattern exactos pueden cambiar entre releases (ya hubo migraciones de la infraestructura de firma del proyecto); antes de automatizar esta verificación en un pipeline conviene confirmar los valores vigentes en la documentación oficial ("Verify Signed Kubernetes Artifacts").

Kubernetes también publica metadata de proveniencia (SBOM y atestaciones tipo SLSA) para sus artefactos de release, pensada para entornos que requieren trazabilidad de build de extremo a extremo; se verifica con herramientas como `slsa-verifier` sobre el bundle publicado por el proceso de release (`kubernetes-sigs/release`).

## Buenas prácticas para el examen y para producción

- **Fijar versión exacta** (`VERSION=v1.32.0`, nunca `latest`) para que la comparación de checksum sea determinística y reproducible.
- Verificar **siempre antes de `kubeadm init` / `kubeadm join`**, no después: `kubeadm` no re-verifica binarios ya presentes en el `PATH`.
- Automatizar la verificación como parte del pipeline de construcción de imágenes de nodo (Packer/Ansible), no como paso manual "cuando me acuerdo".
- No mezclar la fuente del binario con la fuente del checksum (bajar el `.sha256` desde el repo de GitHub aunque el binario venga de `dl.k8s.io`, para reducir el riesgo de que un solo mirror comprometido entregue ambos alterados).
- Aplicar el mismo criterio a binarios de soporte: `containerd`, `runc`, `crictl`, plugins CNI — todos publican `.sha256`/checksums en sus releases de GitHub.
- Auditar binarios ya instalados (no solo en el momento de la descarga) comparando su hash contra el esperado, o verificando la integridad del paquete instalado:

```bash
sha256sum /usr/bin/kubelet
dpkg -V kubelet     # Debian/Ubuntu: compara contra la base de datos de paquetes
rpm -V kubelet       # RHEL/CentOS: idem
```

Esto sirve tanto para detección post-incidente como para controles de compliance recurrentes (kube-bench, en su chequeo de la CIS Benchmark, valida permisos y presencia de los binarios del control plane, aunque no su checksum).

## Referencias

- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Verify Signed Kubernetes Artifacts: https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/
- Install and Set Up kubectl (verificación de binario): https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Installing kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Kubernetes Releases / Downloads: https://kubernetes.io/releases/download/
- Introducción a pkgs.k8s.io: https://kubernetes.io/blog/2023/08/15/pkgs-k8s-io-introduction/
- Proceso de release y proveniencia (kubernetes-sigs/release): https://github.com/kubernetes-sigs/release
- Sigstore / cosign: https://docs.sigstore.dev/cosign/overview/
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes