# 704.1 Cloud Native Security — Ejercicios guiados

> **Examen:** LPI DevOps Tools Engineer 701-100, v2.0.0 — Objetivo 704.1 (peso 6.67)
> **Lista oficial de objetivos:** <https://www.lpi.org/our-certifications/exam-701-objectives/>
>
> Estos ejercicios son prácticos. Cada paso está pensado para ser tipeado y su salida leída. Las preguntas que siguen a cada bloque no son retóricas: si no podés responderlas con lo que acabás de ver en pantalla, volvé a ejecutar el paso antes de seguir.

---

## Entorno de laboratorio

Necesitás un host Linux (kernel ≥ 5.8 para el ejercicio de eBPF), con:

| Herramienta | Mínimo | Propósito |
|---|---|---|
| `podman` o `docker` | 4.x / 24.x | ejercicios de runtime de contenedores |
| `kind` | 0.23+ | cluster de Kubernetes descartable |
| `kubectl` | coincidente con la minor del cluster | ejercicios de cluster |
| `trivy` | 0.50+ | escaneo de vulnerabilidades y de configuraciones erróneas |
| `syft` / `grype` | 1.x / 0.7x | generación y consumo de SBOM |
| `cosign` | 2.x | firma y verificación |
| `helm` | 3.x | instalación de Kyverno / Falco |
| `jq`, `capsh` (`libcap`), `openssl` | — | inspección |

### Paso 0 — construir el cluster

El CNI por defecto de `kind` (`kindnetd`) **no** aplica `NetworkPolicy`. El ejercicio 7 depende de que se aplique, así que el cluster se construye sin CNI y en su lugar se instala Calico.

```bash
cat > kind-704.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
  - role: worker
EOF

kind create cluster --name sec704 --config kind-704.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
kubectl get nodes
```

Salida esperada:

```
NAME                  STATUS   ROLES           AGE   VERSION
sec704-control-plane  Ready    control-plane   96s   v1.31.0
sec704-worker         Ready    <none>          72s   v1.31.0
```

> Referencia: <https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart>

---

## Ejercicio 1 — Mapear la superficie de ataque con las 4C

La seguridad Cloud Native está por capas: **Cloud → Cluster → Container → Code**. Cada capa solo puede ser tan segura como la que está debajo. Este ejercicio establece la línea base que vas a endurecer en el resto del documento.

**Pasos**

1. Arrancá un contenedor sin endurecer y mirá quién sos adentro:

   ```bash
   podman run --rm -it docker.io/library/nginx:1.27 id
   ```

   ```
   uid=0(root) gid=0(root) groups=0(root)
   ```

2. Inspeccioná el conjunto efectivo de capabilities del PID 1 dentro de un contenedor Docker *rootful*:

   ```bash
   docker run --rm docker.io/library/nginx:1.27 grep Cap /proc/1/status
   ```

   ```
   CapInh: 0000000000000000
   CapPrm: 00000000a80425fb
   CapEff: 00000000a80425fb
   CapBnd: 00000000a80425fb
   CapAmb: 0000000000000000
   ```

3. Decodificá esa máscara de bits a nombres:

   ```bash
   capsh --decode=00000000a80425fb
   ```

   ```
   0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,
   cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,
   cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
   ```

4. Repetí con Podman y compará:

   ```bash
   podman run --rm docker.io/library/nginx:1.27 grep CapEff /proc/1/status
   ```

   ```
   CapEff: 00000000800405fb
   ```

5. Ahora rompé el límite del contenedor a propósito, para ver qué significa realmente "privileged":

   ```bash
   docker run --rm --privileged docker.io/library/alpine:3.20 \
     sh -c 'ls /dev/ | head -5; grep CapEff /proc/1/status'
   ```

   ```
   autofs
   bsg
   btrfs-control
   bus
   console
   CapEff: 000001ffffffffff
   ```

6. Demostrá que el filesystem del host está a una flag de distancia:

   ```bash
   docker run --rm -v /:/host:ro docker.io/library/alpine:3.20 \
     cat /host/etc/shadow | head -2
   ```

**Comprobá lo que entendiste**

- **Q1.1** — El paso 2 muestra 14 capabilities, no las 40+ completas. ¿Qué principio de seguridad representa ese valor por defecto, y por qué sigue *sin* ser suficiente para una carga de trabajo de producción?
- **Q1.2** — El conjunto efectivo de Podman en el paso 4 difiere del de Docker. ¿Qué capabilities faltan, y qué consecuencia práctica tiene quitar `CAP_NET_RAW`?
- **Q1.3** — En el paso 5, `CapEff` tiene todos los bits en 1 *y además* los nodos de dispositivo del host son visibles. Nombrá dos mecanismos de aislamiento adicionales que `--privileged` desactiva más allá de las capabilities.
- **Q1.4** — El paso 6 monta la raíz del host en solo lectura y aun así es un hallazgo crítico. Mapealo a una de las 4C y explicá qué control (no qué herramienta) debería haberlo impedido.

---

## Ejercicio 2 — Reducir la superficie de ataque de la imagen

No podés parchear una vulnerabilidad en un paquete que no está instalado. Este ejercicio mide esa afirmación.

**Pasos**

1. Creá una imagen trivialmente insegura:

   ```bash
   mkdir -p ~/lab/app && cd ~/lab/app
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

   cat > Containerfile.bad <<'EOF'
   FROM golang:1.22
   WORKDIR /src
   COPY main.go .
   RUN go mod init app && go build -o /app .
   EXPOSE 8080
   CMD ["/app"]
   EOF

   podman build -f Containerfile.bad -t localhost/app:bad .
   ```

2. Reescribila como un build multi-stage sobre una base distroless con un usuario no-root numérico:

   ```bash
   cat > Containerfile.good <<'EOF'
   FROM golang:1.22 AS build
   WORKDIR /src
   COPY main.go .
   RUN go mod init app && \
       CGO_ENABLED=0 GOFLAGS=-trimpath go build -ldflags="-s -w" -o /app .

   FROM gcr.io/distroless/static-debian12:nonroot
   COPY --from=build /app /app
   USER 65532:65532
   EXPOSE 8080
   ENTRYPOINT ["/app"]
   EOF

   podman build -f Containerfile.good -t localhost/app:good .
   ```

3. Compará tamaño y contenido:

   ```bash
   podman images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep localhost/app
   ```

   ```
   localhost/app:bad     897 MB
   localhost/app:good    6.42 MB
   ```

4. Intentá obtener una shell interactiva en cada una:

   ```bash
   podman run --rm -it localhost/app:bad  /bin/sh -c 'id; which curl wget apt'
   podman run --rm -it localhost/app:good /bin/sh
   ```

   La segunda falla:

   ```
   Error: crun: executable file `/bin/sh` not found in $PATH: No such file or directory: OCI runtime attempted to invoke a command that was not found
   ```

5. Confirmá la identidad en runtime de la imagen endurecida:

   ```bash
   podman inspect localhost/app:good --format '{{.Config.User}}'
   ```

   ```
   65532:65532
   ```

6. Fijá por digest en lugar de por tag: registrá la referencia inmutable:

   ```bash
   podman image inspect localhost/app:good --format '{{index .RepoDigests 0}}' 2>/dev/null || \
     podman inspect localhost/app:good --format '{{.Digest}}'
   ```

   ```
   sha256:0a5b1f6e0b9c4c4d5c4b8a2d4b8f8c1a9d3e6f2b7c8d9e0f1a2b3c4d5e6f7a8b
   ```

**Comprobá lo que entendiste**

- **Q2.1** — La falla del paso 4 suele ser reportada como un bug por los desarrolladores. Explicá, en términos de respuesta a incidentes, por qué la ausencia de `/bin/sh` es una *feature*, y nombrá una técnica de depuración que sigue funcionando.
- **Q2.2** — ¿Por qué el build de `Containerfile.good` define `CGO_ENABLED=0`, y qué se rompería en la base distroless `static` si se lo dejara en su valor por defecto?
- **Q2.3** — `USER 65532:65532` usa un UID numérico en lugar de `USER nonroot`. ¿Qué comprobación de admisión de Kubernetes depende de esa distinción? (Lo vas a confirmar empíricamente en el ejercicio 10.)
- **Q2.4** — Ambas imágenes contienen el mismo binario de aplicación. Si mañana se publica un CVE para `libssl`, ¿cuál de las dos imágenes se ve afectada, y qué te dice eso sobre el "conteo de vulnerabilidades" como KPI?

---

## Ejercicio 3 — SBOM, escaneo y un quality gate de CI

**Pasos**

1. Escaneá la imagen sin endurecer y leé el resumen:

   ```bash
   trivy image --severity HIGH,CRITICAL localhost/app:bad
   ```

   ```
   localhost/app:bad (debian 12.6)
   Total: 71 (HIGH: 68, CRITICAL: 3)

   ┌──────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
   │   Library    │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
   ├──────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
   │ libc-bin     │ CVE-2024-2961  │ HIGH     │ fixed  │ 2.36-9+deb12u4    │ 2.36-9+deb12u7│
   ...
   ```

2. Escaneá la imagen endurecida:

   ```bash
   trivy image --severity HIGH,CRITICAL localhost/app:good
   ```

   ```
   localhost/app:good (debian 12.6)
   Total: 0 (HIGH: 0, CRITICAL: 0)
   ```

3. Generá un SBOM en dos formatos estándar:

   ```bash
   syft localhost/app:good -o spdx-json=sbom.spdx.json
   trivy image --format cyclonedx --output sbom.cdx.json localhost/app:good

   jq -r '.packages | length' sbom.spdx.json
   jq -r '.components[].name' sbom.cdx.json | head
   ```

4. Consumí el SBOM en lugar de la imagen: el patrón que usa un equipo de seguridad offline:

   ```bash
   grype sbom:./sbom.spdx.json --fail-on high
   echo "exit=$?"
   ```

   ```
   No vulnerabilities found
   exit=0
   ```

5. Construí un gate que haga fallar un pipeline. Fijate en `--ignore-unfixed`, que es la diferencia entre un gate accionable y uno ignorado:

   ```bash
   trivy image --severity HIGH,CRITICAL \
                --ignore-unfixed \
                --exit-code 1 \
                --format table \
                localhost/app:bad
   echo "exit=$?"
   ```

   ```
   exit=1
   ```

6. Escaneá el *árbol de fuentes*, no la imagen: configuraciones erróneas y secretos hardcodeados:

   ```bash
   printf 'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' > .env
   trivy fs --scanners misconfig,secret --severity MEDIUM,HIGH,CRITICAL .
   ```

   ```
   .env (secrets)
   Total: 1 (MEDIUM: 0, HIGH: 0, CRITICAL: 1)

   CRITICAL: AWS (aws-secret-access-key)
   Reason: AWS Secret Access Key
   ```

7. Registrá una excepción justificada y acotada en el tiempo:

   ```bash
   cat > .trivyignore <<'EOF'
   # Vulnerable code path is unreachable: the CLI parser is never invoked.
   # Owner: platform-sec  Review: 2026-10-15
   CVE-2024-2961 exp:2026-10-15
   EOF
   trivy image --severity HIGH,CRITICAL --ignorefile .trivyignore localhost/app:bad | head -3
   ```

> Referencias: <https://trivy.dev/latest/docs/>, <https://github.com/anchore/syft>, <https://spdx.dev/>, <https://cyclonedx.org/>

**Comprobá lo que entendiste**

- **Q3.1** — ¿Por qué el paso 5 usa `--ignore-unfixed`? Describí el modo de falla de un gate que lo omite.
- **Q3.2** — El paso 4 escanea un SBOM, no una imagen. Dá dos ventajas operativas de almacenar el SBOM como artefacto de build en lugar de reescanear la imagen más tarde.
- **Q3.3** — Un escaneo que la semana pasada devolvió `Total: 0` hoy devuelve `Total: 12`, sin ningún rebuild. ¿Qué cambió, y qué implica esto sobre *cuándo* debe correr un gate?
- **Q3.4** — El paso 7 fija una fecha de expiración en `.trivyignore`. ¿Cuál es el riesgo concreto de una entrada de ignore sin expiración, y quién debería ser dueño de la revisión?

---

## Ejercicio 4 — Firmar imágenes y verificar la procedencia

El escaneo te dice *qué hay adentro* de una imagen. La firma te dice *de dónde vino*. Son garantías distintas.

**Pasos**

1. Levantá un registry local para que el laboratorio siga siendo offline:

   ```bash
   podman run -d --name reg -p 5000:5000 docker.io/library/registry:2
   podman tag localhost/app:good localhost:5000/app:1.0.0
   podman push --tls-verify=false localhost:5000/app:1.0.0
   ```

2. Generá un par de claves y firmá **por digest**:

   ```bash
   export COSIGN_PASSWORD=lab
   cosign generate-key-pair

   DIGEST=$(podman image inspect localhost:5000/app:1.0.0 --format '{{.Digest}}')
   echo "$DIGEST"
   cosign sign --key cosign.key --tlog-upload=false --yes \
     "localhost:5000/app@${DIGEST}"
   ```

   ```
   Pushing signature to: localhost:5000/app
   ```

3. Verificá, y después verificá un tag que no firmaste:

   ```bash
   cosign verify --key cosign.pub --insecure-ignore-tlog=true \
     "localhost:5000/app@${DIGEST}" | jq -r '.[0].critical.image'
   ```

   ```json
   { "docker-manifest-digest": "sha256:0a5b1f6e..." }
   ```

   ```bash
   podman tag docker.io/library/alpine:3.20 localhost:5000/evil:1.0.0
   podman push --tls-verify=false localhost:5000/evil:1.0.0
   cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5000/evil:1.0.0
   ```

   ```
   Error: no matching signatures:
   main.go:74: error during command execution: no matching signatures:
   ```

4. Adjuntá el SBOM como una attestation firmada, no como un archivo suelto:

   ```bash
   cosign attest --key cosign.key --tlog-upload=false --yes \
     --type cyclonedx --predicate sbom.cdx.json \
     "localhost:5000/app@${DIGEST}"

   cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true \
     --type cyclonedx "localhost:5000/app@${DIGEST}" \
     | jq -r '.payload' | base64 -d | jq -r '.predicateType'
   ```

   ```
   https://cyclonedx.org/bom
   ```

5. Mirá cómo se vería la firma keyless en CI (no lo ejecutes acá: necesita un token OIDC):

   ```bash
   # In GitHub Actions with id-token: write
   # cosign sign --yes ghcr.io/org/app@sha256:...
   # Verification then asserts *identity*, not a key:
   # cosign verify \
   #   --certificate-identity-regexp '^https://github.com/org/app/.github/workflows/.*' \
   #   --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
   #   ghcr.io/org/app@sha256:...
   ```

> Referencias: <https://docs.sigstore.dev/>, <https://github.com/sigstore/cosign>, <https://slsa.dev/spec/v1.0/levels>

**Comprobá lo que entendiste**

- **Q4.1** — El paso 2 firma un digest, no el tag `1.0.0`. ¿Qué ataque se vuelve posible si firmás y verificás por tag?
- **Q4.2** — El paso 4 produce una *attestation* en lugar de un archivo SBOM plano en el almacén de artefactos. ¿Qué propiedad agrega la attestation?
- **Q4.3** — En el flujo keyless del paso 5 no se almacena ninguna clave privada en ningún lado. ¿Qué reemplaza a la clave como raíz de confianza, y cuál es el nuevo modo de falla correspondiente?
- **Q4.4** — Una firma se verifica con éxito sobre una imagen con 40 CVE CRITICAL. ¿La verificación sirve de algo? Justificá en referencia a lo que cada control afirma realmente.

---

## Ejercicio 5 — Endurecimiento de contenedores a nivel de kernel

**Pasos**

1. Mostrá que el valor por defecto es permisivo: escalá privilegios dentro de un contenedor mediante un binario setuid.

   ```bash
   cat > Containerfile.suid <<'EOF'
   FROM docker.io/library/debian:12-slim
   RUN useradd -u 1001 -m appuser && \
       cp /bin/bash /usr/local/bin/rootbash && \
       chmod u+s /usr/local/bin/rootbash
   USER 1001
   CMD ["sleep", "infinity"]
   EOF
   podman build -f Containerfile.suid -t localhost/suid:demo .

   podman run --rm localhost/suid:demo /usr/local/bin/rootbash -p -c id
   ```

   ```
   uid=1001(appuser) gid=1001 euid=0(root) groups=1001
   ```

2. Bloqueá la escalada:

   ```bash
   podman run --rm --security-opt no-new-privileges \
     localhost/suid:demo /usr/local/bin/rootbash -p -c id
   ```

   ```
   uid=1001(appuser) gid=1001 groups=1001
   ```

3. Quitá todas las capabilities y volvé a agregar solo las que el workload demuestre que necesita:

   ```bash
   podman run --rm --cap-drop=ALL docker.io/library/nginx:1.27 \
     grep CapEff /proc/1/status
   ```

   ```
   CapEff: 0000000000000000
   ```

   ```bash
   podman run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
     docker.io/library/nginx:1.27 grep CapEff /proc/1/status
   ```

   ```
   CapEff: 0000000000000400
   ```

4. Escribí un perfil seccomp que deniegue las syscalls de la familia `chmod`, y comprobá que se aplica:

   ```bash
   cat > seccomp-nochmod.json <<'EOF'
   {
     "defaultAction": "SCMP_ACT_ALLOW",
     "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
     "syscalls": [
       {
         "names": ["chmod", "fchmod", "fchmodat", "fchmodat2"],
         "action": "SCMP_ACT_ERRNO",
         "errnoRet": 1
       }
     ]
   }
   EOF

   podman run --rm --security-opt seccomp=seccomp-nochmod.json \
     docker.io/library/alpine:3.20 sh -c 'touch /tmp/f && chmod 777 /tmp/f'
   ```

   ```
   chmod: /tmp/f: Operation not permitted
   ```

5. Hacé que el filesystem raíz sea de solo lectura y dale al proceso un área escribible explícita:

   ```bash
   podman run --rm --read-only docker.io/library/alpine:3.20 \
     sh -c 'touch /oops' ; echo "exit=$?"
   ```

   ```
   touch: /oops: Read-only file system
   exit=1
   ```

   ```bash
   podman run --rm --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
     docker.io/library/alpine:3.20 sh -c 'touch /tmp/ok && ls -l /tmp/ok'
   ```

   ```
   -rw-r--r--    1 root     root             0 Sep  3 10:14 /tmp/ok
   ```

6. Verificá el remapeo de user namespace en Podman rootless: el más fuerte de los límites de este ejercicio:

   ```bash
   id -u
   podman unshare cat /proc/self/uid_map
   podman run --rm docker.io/library/alpine:3.20 sh -c 'id -u; readlink /proc/self/ns/user'
   ```

   ```
   1000
            0       1000          1
            1     100000      65536
   0
   user:[4026532567]
   ```

> Referencias: <https://man7.org/linux/man-pages/man7/capabilities.7.html>, <https://docs.docker.com/engine/security/>, <https://kubernetes.io/docs/tutorials/security/seccomp/>

**Comprobá lo que entendiste**

- **Q5.1** — En el paso 6, `id -u` dentro del contenedor devuelve `0` mientras que el UID del host es `1000`. Explicá qué está realmente autorizado a hacer el proceso sobre el filesystem del host, y por qué acá "root en el contenedor" no es "root en el host".
- **Q5.2** — El paso 2 detiene la escalada por setuid pero *no* elimina el bit setuid. ¿Qué capa de defensa es `no_new_privs`, y contra qué *no* protege?
- **Q5.3** — El perfil del paso 4 usa `SCMP_ACT_ERRNO`. Compará con `SCMP_ACT_KILL` y `SCMP_ACT_LOG` e indicá cuál desplegarías primero al perfilar una aplicación desconocida.
- **Q5.4** — ¿Por qué se combina `--read-only` con un `tmpfs` montado `noexec,nosuid` en lugar de un volumen escribible común?
- **Q5.5** — Después del paso 3, `nginx:1.27` arranca correctamente con solo `NET_BIND_SERVICE`. ¿Qué cambio en la imagen te permitiría quitar incluso esa capability?

---

## Ejercicio 6 — Pod Security Admission

**Pasos**

1. Creá dos namespaces con posturas distintas e inspeccioná las labels:

   ```bash
   kubectl create namespace legacy
   kubectl label namespace legacy \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/enforce-version=latest \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted

   kubectl create namespace prod
   kubectl label namespace prod \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=latest

   kubectl get ns legacy prod -o custom-columns=\
   'NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'
   ```

   ```
   NS       ENFORCE
   legacy   baseline
   prod     restricted
   ```

2. Probá un Pod sin endurecer en `prod`:

   ```bash
   cat > pod-bad.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
   spec:
     containers:
       - name: app
         image: nginx:1.27
   EOF

   kubectl -n prod apply -f pod-bad.yaml
   ```

   ```
   Error from server (Forbidden): error when creating "pod-bad.yaml": pods "web" is forbidden:
   violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false
   (container "app" must set securityContext.allowPrivilegeEscalation=false),
   unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
   seccompProfile (pod or container "app" must set securityContext.seccompProfile.type
   to "RuntimeDefault" or "Localhost")
   ```

3. Aplicá el mismo manifiesto en `legacy` y leé el *warning*:

   ```bash
   kubectl -n legacy apply -f pod-bad.yaml
   ```

   ```
   Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
   pod/web created
   ```

4. Escribí un Pod que cumpla con `restricted`:

   ```bash
   cat > pod-good.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: web
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 101
       runAsGroup: 101
       fsGroup: 101
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:1.27-alpine
         ports:
           - containerPort: 8080
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
         volumeMounts:
           - { name: cache,   mountPath: /var/cache/nginx }
           - { name: run,     mountPath: /var/run }
           - { name: tmp,     mountPath: /tmp }
     volumes:
       - { name: cache, emptyDir: {} }
       - { name: run,   emptyDir: {} }
       - { name: tmp,   emptyDir: {} }
   EOF

   kubectl -n prod apply -f pod-good.yaml
   kubectl -n prod get pod web -o wide
   ```

   ```
   pod/web created
   NAME   READY   STATUS    RESTARTS   AGE   IP              NODE
   web    1/1     Running   0          8s    192.168.44.12   sec704-worker
   ```

5. Confirmá que el estado en runtime coincide con lo declarado:

   ```bash
   kubectl -n prod exec web -- id
   kubectl -n prod exec web -- grep CapEff /proc/1/status
   kubectl -n prod exec web -- sh -c 'touch /oops' ; echo "exit=$?"
   ```

   ```
   uid=101(nginx) gid=101(nginx) groups=101(nginx)
   CapEff: 0000000000000000
   touch: /oops: Read-only file system
   exit=1
   ```

6. Hacé un dry-run de todo el cluster contra `restricted` antes de desplegarlo: el camino de migración seguro:

   ```bash
   kubectl label --dry-run=server --overwrite ns --all \
     pod-security.kubernetes.io/enforce=restricted 2>&1 | grep -i warn | head
   ```

> Referencias: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>, <https://kubernetes.io/docs/concepts/security/pod-security-admission/>

**Comprobá lo que entendiste**

- **Q6.1** — PSA tiene tres modos: `enforce`, `audit`, `warn`. Describí el orden de despliegue que usarías para llevar un namespace en producción de `privileged` a `restricted` sin romper las cargas de trabajo en ejecución.
- **Q6.2** — Arriba se usó `enforce-version=latest`. ¿Por qué fijarlo a una versión explícita como `v1.31` es la opción más defendible para un cluster de producción?
- **Q6.3** — En el paso 3 el Pod fue **creado** a pesar del warning. ¿Qué modo produjo el mensaje, y dónde termina el registro de `audit` correspondiente?
- **Q6.4** — PSA es un control a nivel de namespace. Nombrá una clase de escalada de privilegios que no puede detener, y el control que sí lo hace.
- **Q6.5** — El paso 4 reemplazó `nginx:1.27` por `nginx-unprivileged`. Explicá por qué `readOnlyRootFilesystem: true` obligó a los tres volúmenes `emptyDir`.

---

## Ejercicio 7 — NetworkPolicy default-deny

**Pasos**

1. Construí un namespace de dos capas:

   ```bash
   kubectl create namespace shop
   kubectl -n shop run api  --image=nginxinc/nginx-unprivileged:1.27-alpine \
     --port=8080 --labels=app=api
   kubectl -n shop expose pod api --port=8080
   kubectl -n shop run client --image=curlimages/curl:8.8.0 --labels=app=client \
     --command -- sleep infinity
   kubectl -n shop wait --for=condition=Ready pod --all --timeout=90s
   ```

2. Comprobá que la conectividad plana es el comportamiento por defecto:

   ```bash
   kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://api:8080/
   kubectl -n shop exec client -- curl -s -o /dev/null -w '%{http_code}\n' https://example.com/
   ```

   ```
   200
   200
   ```

3. Aplicá una política default-deny para ambas direcciones:

   ```bash
   cat > netpol-deny.yaml <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
     namespace: shop
   spec:
     podSelector: {}
     policyTypes: ["Ingress", "Egress"]
   EOF
   kubectl apply -f netpol-deny.yaml

   kubectl -n shop exec client -- curl -s --max-time 5 http://api:8080/ ; echo "exit=$?"
   ```

   ```
   exit=28
   ```

4. Restaurá *solo* DNS, y después solo el camino este-oeste requerido:

   ```bash
   cat > netpol-allow.yaml <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-dns, namespace: shop }
   spec:
     podSelector: {}
     policyTypes: ["Egress"]
     egress:
       - to:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: kube-system
             podSelector:
               matchLabels:
                 k8s-app: kube-dns
         ports:
           - { protocol: UDP, port: 53 }
           - { protocol: TCP, port: 53 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: client-to-api, namespace: shop }
   spec:
     podSelector:
       matchLabels: { app: client }
     policyTypes: ["Egress"]
     egress:
       - to:
           - podSelector:
               matchLabels: { app: api }
         ports:
           - { protocol: TCP, port: 8080 }
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: api-from-client, namespace: shop }
   spec:
     podSelector:
       matchLabels: { app: api }
     policyTypes: ["Ingress"]
     ingress:
       - from:
           - podSelector:
               matchLabels: { app: client }
         ports:
           - { protocol: TCP, port: 8080 }
   EOF
   kubectl apply -f netpol-allow.yaml
   ```

5. Verificá que la allow-list sea exactamente tan estrecha como se pretendía:

   ```bash
   kubectl -n shop exec client -- curl -s -o /dev/null -w 'api=%{http_code}\n' --max-time 5 http://api:8080/
   kubectl -n shop exec client -- curl -s -o /dev/null -w 'ext=%{http_code}\n' --max-time 5 https://example.com/ ; echo "exit=$?"
   ```

   ```
   api=200
   exit=28
   ```

6. Volvé a leer las políticas como lo haría un auditor:

   ```bash
   kubectl -n shop get networkpolicy
   kubectl -n shop describe networkpolicy default-deny-all | sed -n '1,20p'
   ```

> Referencia: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>

**Comprobá lo que entendiste**

- **Q7.1** — El paso 3 rompió DNS además de HTTP. ¿Por qué un default-deny de egress casi siempre requiere una regla explícita de DNS, y qué síntoma produce su ausencia en los logs de la aplicación?
- **Q7.2** — `NetworkPolicy` es aditiva: las reglas se unen, nunca restan. Dado eso, explicá con precisión cómo sigue haciendo efecto `default-deny-all` en el paso 5.
- **Q7.3** — El código de salida en los pasos 3 y 5 es `28` (timeout), no "connection refused". ¿Qué le dice esa diferencia a quien está diagnosticando sobre *dónde* murió el paquete?
- **Q7.4** — Si este cluster hubiera conservado `kindnetd`, todas las políticas de arriba se habrían aplicado limpiamente y no habrían aplicado nada. ¿Qué único comando correrías para detectar esa clase de falla silenciosa en un cluster nuevo?
- **Q7.5** — La regla `allow-dns` matchea `kubernetes.io/metadata.name: kube-system`. ¿De dónde viene esa label, y por qué es preferible a etiquetar el namespace vos mismo?

---

## Ejercicio 8 — RBAC de mínimo privilegio y tokens de ServiceAccount

**Pasos**

1. Creá una identidad acotada:

   ```bash
   kubectl create namespace app
   kubectl -n app create serviceaccount reader

   cat > rbac.yaml <<'EOF'
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata: { name: pod-reader, namespace: app }
   rules:
     - apiGroups: [""]
       resources: ["pods", "pods/log"]
       verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata: { name: reader-binds-pod-reader, namespace: app }
   subjects:
     - kind: ServiceAccount
       name: reader
       namespace: app
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: pod-reader
   EOF
   kubectl apply -f rbac.yaml
   ```

2. Probá el límite sin llegar a tener nunca la credencial:

   ```bash
   for verb_res in "get pods" "list secrets" "create pods" "get pods -n prod"; do
     printf '%-22s ' "$verb_res"
     kubectl auth can-i $verb_res --as=system:serviceaccount:app:reader -n app
   done
   ```

   ```
   get pods               yes
   list secrets           no
   create pods            no
   get pods -n prod       no
   ```

3. Enumerá todo lo que la identidad puede hacer: el comando de revisión:

   ```bash
   kubectl auth can-i --list --as=system:serviceaccount:app:reader -n app
   ```

   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   pods                                            []                  []               [get list watch]
   pods/log                                        []                  []               [get list watch]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   ...
   ```

4. Emití un token de vida corta y ligado a una audiencia, y diseccionalo:

   ```bash
   TOKEN=$(kubectl -n app create token reader --duration=10m)
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```

   ```json
   {
     "aud": ["https://kubernetes.default.svc.cluster.local"],
     "exp": 1788000000,
     "iss": "https://kubernetes.default.svc.cluster.local",
     "kubernetes.io": {
       "namespace": "app",
       "serviceaccount": { "name": "reader", "uid": "4f0c..." }
     },
     "sub": "system:serviceaccount:app:reader"
   }
   ```

5. Apagá la proyección del token donde el workload directamente no llama a la API:

   ```bash
   cat > pod-noapi.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: { name: noapi, namespace: app }
   spec:
     serviceAccountName: reader
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 65532
       seccompProfile: { type: RuntimeDefault }
     containers:
       - name: c
         image: curlimages/curl:8.8.0
         command: ["sleep", "infinity"]
         securityContext:
           allowPrivilegeEscalation: false
           capabilities: { drop: ["ALL"] }
   EOF
   kubectl apply -f pod-noapi.yaml
   kubectl -n app wait --for=condition=Ready pod/noapi --timeout=60s
   kubectl -n app exec noapi -- ls /var/run/secrets/kubernetes.io/serviceaccount/ ; echo "exit=$?"
   ```

   ```
   ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
   exit=1
   ```

6. Buscá el antipatrón que deshace todo lo anterior:

   ```bash
   kubectl get clusterrolebindings -o json | jq -r '
     .items[] | select(.roleRef.name=="cluster-admin")
     | .metadata.name + " -> " + ([.subjects[]? | .kind + "/" + .name] | join(","))'
   ```

> Referencias: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>, <https://kubernetes.io/docs/concepts/security/service-accounts/>

**Comprobá lo que entendiste**

- **Q8.1** — El token del paso 4 lleva `aud` y `exp`. Contrastalo con el token de ServiceAccount legacy respaldado por un `Secret` y establecé la diferencia concreta de radio de impacto si el token se filtra.
- **Q8.2** — `kubectl auth can-i --list` reportó `selfsubjectaccessreviews … create`, que nadie otorgó. ¿De dónde viene ese permiso?
- **Q8.3** — ¿Por qué `--as=` es más confiable para verificar RBAC que construir un kubeconfig a partir del token y reintentar a mano?
- **Q8.4** — Un `Role` otorga `get` sobre `pods` pero la aplicación además lee `pods/log`. Explicá por qué esa es una regla aparte y qué revela eso sobre los subrecursos en RBAC.
- **Q8.5** — El paso 6 lista los bindings de `cluster-admin`. Más allá de `cluster-admin` en sí, nombrá dos permisos que son efectivamente cluster-admin disfrazados.

---

## Ejercicio 9 — Secrets: qué protege Kubernetes y qué no

**Pasos**

1. Creá un Secret y observá la codificación:

   ```bash
   kubectl -n app create secret generic db \
     --from-literal=username=svc_orders \
     --from-literal=password='S3cr3t-Rotate-Me'

   kubectl -n app get secret db -o jsonpath='{.data.password}' ; echo
   kubectl -n app get secret db -o jsonpath='{.data.password}' | base64 -d ; echo
   ```

   ```
   UzNjcjN0LVJvdGF0ZS1NZQ==
   S3cr3t-Rotate-Me
   ```

2. Leelo directo de etcd, sin cifrar, desde el nodo del control plane:

   ```bash
   docker exec sec704-control-plane sh -c '
     ETCDCTL_API=3 etcdctl \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       get /registry/secrets/app/db' | strings | grep -i rotate
   ```

   ```
   S3cr3t-Rotate-Me
   ```

3. Habilitá el cifrado en reposo. Escribí la configuración del provider en el nodo:

   ```bash
   KEY=$(head -c 32 /dev/urandom | base64)
   docker exec -i sec704-control-plane sh -c "cat > /etc/kubernetes/enc.yaml" <<EOF
   apiVersion: apiserver.config.k8s.io/v1
   kind: EncryptionConfiguration
   resources:
     - resources: ["secrets"]
       providers:
         - aescbc:
             keys:
               - name: key1
                 secret: ${KEY}
         - identity: {}
   EOF
   ```

4. Agregá la flag y el mount al manifiesto del static Pod:

   ```bash
   docker exec sec704-control-plane sh -c '
     sed -i "s|    - kube-apiserver|    - kube-apiserver\n    - --encryption-provider-config=/etc/kubernetes/enc.yaml|" \
       /etc/kubernetes/manifests/kube-apiserver.yaml'
   # /etc/kubernetes is already host-mounted into the apiserver static pod on kubeadm clusters.
   sleep 60
   kubectl -n kube-system get pod -l component=kube-apiserver
   ```

5. Comprobá que los Secrets existentes **no** se cifran retroactivamente, y después reescribilos:

   ```bash
   docker exec sec704-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/app/db' | strings | grep -i rotate   # still plaintext

   kubectl get secrets --all-namespaces -o json | kubectl replace -f -

   docker exec sec704-control-plane sh -c 'ETCDCTL_API=3 etcdctl \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     get /registry/secrets/app/db' | head -c 120
   ```

   ```
   /registry/secrets/app/dbk8s:enc:aescbc:v1:key1:^Z...
   ```

6. Compará las dos vías de consumo: variable de entorno versus archivo proyectado:

   ```bash
   cat > pod-secret.yaml <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata: { name: consumer, namespace: app }
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 65532
       fsGroup: 65532
       seccompProfile: { type: RuntimeDefault }
     containers:
       - name: c
         image: curlimages/curl:8.8.0
         command: ["sleep", "infinity"]
         env:
           - name: DB_USER
             valueFrom: { secretKeyRef: { name: db, key: username } }
         volumeMounts:
           - { name: db, mountPath: /etc/db, readOnly: true }
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities: { drop: ["ALL"] }
     volumes:
       - name: db
         secret:
           secretName: db
           defaultMode: 0400
   EOF
   kubectl apply -f pod-secret.yaml
   kubectl -n app wait --for=condition=Ready pod/consumer --timeout=60s

   kubectl -n app exec consumer -- cat /proc/1/environ | tr '\0' '\n' | grep DB_USER
   kubectl -n app exec consumer -- ls -l /etc/db/
   ```

   ```
   DB_USER=svc_orders
   -r--------    1 65532    65532           16 Sep  3 10:41 password
   -r--------    1 65532    65532           10 Sep  3 10:41 username
   ```

7. Mirá quién puede leer Secrets en todo el cluster:

   ```bash
   kubectl auth can-i list secrets --all-namespaces --as=system:serviceaccount:app:reader
   kubectl get rolebindings,clusterrolebindings -A -o json \
     | jq -r '.items[] | select(.roleRef.name | test("secret|admin|edit"; "i")) | .metadata.name'
   ```

> Referencias: <https://kubernetes.io/docs/concepts/configuration/secret/>, <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>

**Comprobá lo que entendiste**

- **Q9.1** — El paso 1 muestra base64. En una oración, establecé exactamente qué propiedad de seguridad le aporta base64 a un Secret de Kubernetes.
- **Q9.2** — El paso 5 muestra que activar el cifrado no hace nada con los objetos existentes. Explicá el mecanismo detrás de `kubectl get secrets -o json | kubectl replace -f -`.
- **Q9.3** — Contrastá la vía `env` y la vía de volumen del paso 6 en términos de (a) rotación sin reinicio, y (b) exposición accidental en crash dumps o en `/proc`.
- **Q9.4** — El provider `aescbc` guarda la clave en un archivo del nodo del control plane. ¿Bajo qué modelo de amenaza eso todavía sirve, y qué provider elimina esa limitación?
- **Q9.5** — ¿Por qué importa `defaultMode: 0400`, y qué tiene que ser cierto sobre el UID del contenedor para que sea legible siquiera?

---

## Ejercicio 10 — Policy as code: Kyverno y ValidatingAdmissionPolicy

**Pasos**

1. Instalá Kyverno:

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
   kubectl -n kyverno get pods
   ```

2. Exigí el pinning por digest y prohibí `:latest`, primero en `Audit`:

   ```bash
   cat > pol-images.yaml <<'EOF'
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: image-hygiene
   spec:
     validationFailureAction: Audit
     background: true
     rules:
       - name: no-latest-tag
         match:
           any:
             - resources:
                 kinds: ["Pod"]
                 namespaces: ["prod", "app"]
         validate:
           message: "Images must not use the ':latest' tag: {{ request.object.metadata.name }}"
           pattern:
             spec:
               containers:
                 - image: "!*:latest"
       - name: registry-allowlist
         match:
           any:
             - resources:
                 kinds: ["Pod"]
                 namespaces: ["prod"]
         validate:
           message: "Images must come from an approved registry."
           pattern:
             spec:
               containers:
                 - image: "registry.internal/* | ghcr.io/myorg/*"
   EOF
   kubectl apply -f pol-images.yaml
   ```

3. Disparala y leé el report en lugar de un error:

   ```bash
   kubectl -n prod run bad --image=nginx:latest --dry-run=server -o name
   kubectl -n prod get policyreport -o wide 2>/dev/null | head
   ```

4. Pasá a enforcement y observá el rechazo:

   ```bash
   kubectl patch clusterpolicy image-hygiene --type=merge \
     -p '{"spec":{"validationFailureAction":"Enforce"}}'

   kubectl -n prod run bad --image=nginx:latest
   ```

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/prod/bad was blocked due to the following policies

   image-hygiene:
     no-latest-tag: 'validation error: Images must not use the '':latest'' tag: bad.'
     registry-allowlist: 'validation error: Images must come from an approved registry.'
   ```

5. Ahora hacé lo mismo **sin webhook externo**, usando CEL in-tree:

   ```bash
   cat > vap.yaml <<'EOF'
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: require-digest-pinning
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
         - apiGroups: [""]
           apiVersions: ["v1"]
           operations: ["CREATE", "UPDATE"]
           resources: ["pods"]
     validations:
       - expression: >-
           object.spec.containers.all(c, c.image.contains('@sha256:'))
         message: "every container image must be pinned by digest (@sha256:...)"
         reason: Invalid
   ---
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: require-digest-pinning-prod
   spec:
     policyName: require-digest-pinning
     validationActions: ["Deny"]
     matchResources:
       namespaceSelector:
         matchLabels:
           kubernetes.io/metadata.name: prod
   EOF
   kubectl apply -f vap.yaml

   kubectl -n prod run tagged --image=ghcr.io/myorg/app:1.0.0
   ```

   ```
   The pods "tagged" is invalid: : ValidatingAdmissionPolicy 'require-digest-pinning'
   with binding 'require-digest-pinning-prod' denied request:
   every container image must be pinned by digest (@sha256:...)
   ```

6. Reproducí la falla clásica de usuario no numérico predicha en el ejercicio 2:

   ```bash
   cat > Containerfile.namedu <<'EOF'
   FROM docker.io/library/alpine:3.20
   RUN adduser -D -u 10001 appuser
   USER appuser
   CMD ["sleep", "infinity"]
   EOF
   podman build -f Containerfile.namedu -t localhost:5000/namedu:1 . && \
     podman push --tls-verify=false localhost:5000/namedu:1

   # In the cluster, referencing an equivalent image with a NAMED user:
   kubectl -n app run namedu --image=<your-registry>/namedu:1 \
     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true}}}'
   kubectl -n app describe pod namedu | grep -A3 'Warning\|Error'
   ```

   ```
   Warning  Failed  3s (x2 over 5s)  kubelet
     Error: container has runAsNonRoot and image has non-numeric user (appuser),
     cannot verify user is non-root
   ```

> Referencias: <https://kyverno.io/docs/>, <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/>, <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>

**Comprobá lo que entendiste**

- **Q10.1** — El `failurePolicy` de Kyverno (implícito en el nombre del webhook `validate.kyverno.svc-fail`) es `Fail`. Describí el incidente de disponibilidad que se produce si todos los Pods de Kyverno están caídos, y el trade-off frente a `Ignore`.
- **Q10.2** — El `ValidatingAdmissionPolicy` del paso 5 no necesita webhook, ni Pods, ni certificados. Dado eso, ¿por qué seguirías corriendo Kyverno o Gatekeeper?
- **Q10.3** — El paso 2 arrancó en `Audit`. ¿Qué te da el `PolicyReport` que un rechazo no te da, y por qué importa eso en un cluster ya existente?
- **Q10.4** — El error del paso 6 viene del **kubelet**, no de admission. Explicá por qué la comprobación ocurre ahí, y dá el cambio de una línea en el Containerfile que lo arregla de forma permanente.
- **Q10.5** — Fijar por digest mejora la integridad de la cadena de suministro pero complica el parcheo. Describí el patrón de herramientas que reconcilia ambas cosas.

---

## Ejercicio 11 — Detección en runtime con Falco

El control de admisión decide qué *tiene permitido arrancar*. La detección en runtime te dice qué está *haciendo realmente* un contenedor en ejecución.

**Pasos**

1. Instalá Falco con el driver eBPF moderno (sin compilar módulo de kernel):

   ```bash
   helm repo add falcosecurity https://falcosecurity.github.io/charts && helm repo update
   helm install falco falcosecurity/falco -n falco --create-namespace \
     --set driver.kind=modern_ebpf \
     --set tty=true \
     --wait
   kubectl -n falco get pods
   ```

2. Seguí el stream de eventos en una terminal:

   ```bash
   kubectl -n falco logs -f -l app.kubernetes.io/name=falco | grep -i --line-buffered 'Warning\|Notice\|Critical'
   ```

3. En una segunda terminal, realizá la acción de post-explotación más común de todas:

   ```bash
   kubectl -n legacy exec -it web -- /bin/bash -c 'cat /etc/shadow; id'
   ```

   Falco emite:

   ```
   Notice A shell was spawned in a container with an attached terminal
   (evt_type=execve user=root user_uid=0 proc_exepath=/usr/bin/bash
   container_id=8f2b9c1a4e77 container_image=docker.io/library/nginx:1.27
   k8s_ns=legacy k8s_pod_name=web)
   Warning Sensitive file opened for reading by non-trusted program
   (file=/etc/shadow proc_exepath=/usr/bin/cat container_id=8f2b9c1a4e77 ...)
   ```

4. Dispará una escritura debajo de un directorio de binarios:

   ```bash
   kubectl -n legacy exec web -- sh -c 'cp /bin/ls /usr/local/bin/ls-copy'
   ```

   ```
   Error Write below binary dir (file=/usr/local/bin/ls-copy ... k8s_pod_name=web)
   ```

5. Agregá una regla para algo que Falco no trae por defecto: la lectura del token proyectado del ServiceAccount:

   ```bash
   cat > custom-rules.yaml <<'EOF'
   customRules:
     sa-token.yaml: |-
       - rule: Read Kubernetes ServiceAccount Token
         desc: A process read the projected ServiceAccount token file.
         condition: >
           open_read and container
           and fd.name startswith /var/run/secrets/kubernetes.io/serviceaccount
           and not proc.name in (kubelet, kube-proxy)
         output: >
           SA token read (proc=%proc.name cmd=%proc.cmdline file=%fd.name
           pod=%k8s.pod.name ns=%k8s.ns.name image=%container.image.repository)
         priority: WARNING
         tags: [k8s, credentials, mitre_credential_access]
   EOF
   helm upgrade falco falcosecurity/falco -n falco -f custom-rules.yaml --wait

   kubectl -n legacy exec web -- cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
   ```

   ```
   Warning SA token read (proc=cat cmd=cat /var/run/secrets/... pod=web ns=legacy
   image=docker.io/library/nginx)
   ```

> Referencia: <https://falco.org/docs/>

**Comprobá lo que entendiste**

- **Q11.1** — Falco ve el `exec` del paso 3 aunque el Pod pasó el control de admisión. ¿Qué capa de defensa en profundidad es esta, y qué te aporta que PSA no puede?
- **Q11.2** — La regla del paso 5 excluye `kubelet` y `kube-proxy`. ¿Qué pasaría operativamente si se omitiera esa exclusión?
- **Q11.3** — Falco lee syscalls vía eBPF a nivel de nodo. ¿Qué implica eso sobre la cobertura en un control plane gestionado que no es tuyo, y sobre los privilegios que requiere un DaemonSet?
- **Q11.4** — Falco es un control de *detección*, no de *prevención*. Nombrá el equivalente en seccomp/AppArmor para cada uno de los tres eventos disparados arriba, y explicá cuándo la detección es preferible a la prevención.

---

## Ejercicio 12 — Ejercicio de diagnóstico: un Pod que no arranca

Estás de guardia. Un deployment que viene corriendo hace meses falla después de que el namespace fue migrado a `restricted`.

**Pasos**

1. Reproducí el incidente:

   ```bash
   kubectl create namespace payments
   kubectl label ns payments \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.31

   cat > legacy-deploy.yaml <<'EOF'
   apiVersion: apps/v1
   kind: Deployment
   metadata: { name: ledger, namespace: payments }
   spec:
     replicas: 2
     selector: { matchLabels: { app: ledger } }
     template:
       metadata: { labels: { app: ledger } }
       spec:
         containers:
           - name: ledger
             image: nginx:1.27
             securityContext:
               privileged: true
   EOF
   kubectl apply -f legacy-deploy.yaml
   ```

2. Observá que el Deployment reporta éxito mientras no corre nada:

   ```bash
   kubectl -n payments get deploy,rs,pods
   ```

   ```
   NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/ledger   0/2     0            0           12s

   NAME                                DESIRED   CURRENT   READY   AGE
   replicaset.apps/ledger-6c8f9d7b54   2         0         0       12s

   No resources found in payments namespace.
   ```

3. Encontrá el error real: no está en el Deployment:

   ```bash
   kubectl -n payments describe replicaset -l app=ledger | sed -n '/Events/,$p'
   ```

   ```
   Events:
     Type     Reason        Age   From                   Message
     ----     ------        ----  ----                   -------
     Warning  FailedCreate  14s   replicaset-controller  Error creating: pods "ledger-6c8f9d7b54-" is
       forbidden: violates PodSecurity "restricted:v1.31": privileged (container "ledger" must not set
       securityContext.privileged=true), allowPrivilegeEscalation != false, unrestricted capabilities,
       runAsNonRoot != true, seccompProfile
   ```

4. Confirmalo con el equivalente al rastro de auditoría del API server:

   ```bash
   kubectl -n payments get events --sort-by=.lastTimestamp | tail -5
   ```

5. Determiná si el workload realmente necesita privilegios antes de otorgar una exención:

   ```bash
   kubectl -n payments get deploy ledger -o jsonpath='{.spec.template.spec.containers[0].securityContext}' ; echo
   # Ask: which syscalls / devices / host paths does it use? Test in a lower namespace:
   kubectl -n legacy run probe --image=nginx:1.27 --restart=Never -- \
     sh -c 'nginx -t 2>&1'
   ```

6. Aplicá el arreglo, con el mínimo privilegio que lo mantenga funcionando:

   ```bash
   kubectl -n payments patch deploy ledger --type=merge -p '{
     "spec": { "template": { "spec": {
       "securityContext": { "runAsNonRoot": true, "runAsUser": 101,
                            "fsGroup": 101, "seccompProfile": { "type": "RuntimeDefault" } },
       "containers": [ { "name": "ledger",
         "image": "nginxinc/nginx-unprivileged:1.27-alpine",
         "securityContext": { "privileged": false, "allowPrivilegeEscalation": false,
                              "readOnlyRootFilesystem": true,
                              "capabilities": { "drop": ["ALL"] } },
         "volumeMounts": [ {"name":"cache","mountPath":"/var/cache/nginx"},
                           {"name":"run","mountPath":"/var/run"},
                           {"name":"tmp","mountPath":"/tmp"} ] } ],
       "volumes": [ {"name":"cache","emptyDir":{}},
                    {"name":"run","emptyDir":{}},
                    {"name":"tmp","emptyDir":{}} ]
     } } } }'

   kubectl -n payments rollout status deploy/ledger --timeout=120s
   ```

   ```
   deployment "ledger" successfully rolled out
   ```

7. Comprobá el arreglo en runtime, no en papel:

   ```bash
   POD=$(kubectl -n payments get pod -l app=ledger -o name | head -1)
   kubectl -n payments exec "$POD" -- id
   kubectl -n payments exec "$POD" -- grep CapEff /proc/1/status
   kubectl -n payments exec "$POD" -- sh -c 'grep Seccomp: /proc/1/status'
   ```

   ```
   uid=101(nginx) gid=101(nginx)
   CapEff: 0000000000000000
   Seccomp:	2
   ```

**Comprobá lo que entendiste**

- **Q12.1** — En el paso 2 el Deployment existe y no reporta error, y sin embargo no se creó ningún Pod. Explicá la cadena de controladores y por qué el diagnóstico vive en el ReplicaSet.
- **Q12.2** — PSA rechazó el Pod en el momento de la *creación*. ¿Qué otros objetos de Kubernetes que crean Pods indirectamente muestran esta misma falla "silenciosa", y cuál es la regla general de diagnóstico?
- **Q12.3** — `Seccomp: 2` en `/proc/1/status`. ¿Qué significan los valores `0`, `1` y `2`, y cuál corresponde a `seccompProfile: RuntimeDefault`?
- **Q12.4** — Supongamos que la investigación del paso 5 hubiera mostrado que el workload realmente necesita `CAP_NET_ADMIN`. Describí la resolución correcta bajo PSA, y por qué etiquetar el namespace entero como `privileged` es la respuesta equivocada.

---

## Limpieza

```bash
kind delete cluster --name sec704
podman rm -f reg
rm -f cosign.key cosign.pub sbom.*.json .trivyignore .env
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** — El valor por defecto de 14 capabilities es *mínimo privilegio por defecto*: el runtime quita del bounding set las ~26 capabilities más peligrosas (`CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_SYS_MODULE`, `CAP_NET_ADMIN`, …), de modo que ni siquiera un compromiso total del PID 1 puede cargar un módulo de kernel o montar un filesystem. No alcanza porque el resto sigue siendo explotable: `CAP_DAC_OVERRIDE` saltea todas las comprobaciones de permisos de archivo sobre cualquier ruta del host montada, `CAP_SETUID`/`CAP_SETGID` permiten cambiar a cualquier UID, `CAP_NET_RAW` habilita spoofing de ARP/DNS en la red de pods y escaneo con raw sockets, y `CAP_CHOWN`/`CAP_FOWNER` permiten manipular la propiedad sobre montajes escribibles. La línea base de producción es `drop: ["ALL"]` más una lista de adds explícita y justificada.

**A1.2** — El `00000000800405fb` de Podman quita `CAP_NET_RAW`, `CAP_MKNOD` y `CAP_AUDIT_WRITE` respecto del valor por defecto de Docker. Quitar `CAP_NET_RAW` significa que el contenedor no puede abrir raw sockets ni packet sockets: `ping` (que usa ICMP raw) falla y —más importante— el contenedor no puede falsificar respuestas ARP, envenenar la caché de vecinos de la red de pods, ni hacer sniffing estilo `tcpdump`. El `iputils` moderno de muchas distros usa ICMP `SOCK_DGRAM`, así que `ping` puede seguir funcionando según la imagen; eso es un detalle de la imagen, no una capability otorgada.

**A1.3** — `--privileged` además: (a) desactiva el filtro seccomp (no se aplica el perfil por defecto que bloquea ~44 syscalls, así que `mount`, `unshare`, `keyctl`, `bpf` y `ptrace` sobre otros namespaces quedan alcanzables); (b) desactiva el confinamiento de AppArmor/SELinux para el contenedor; (c) monta `/sys` y todo `/dev` en lectura-escritura con todos los nodos de dispositivo del host, de modo que dispositivos de bloque crudos como `/dev/sda` quedan directamente accesibles; y (d) elimina la restricción del controlador de dispositivos de cgroups. *Cualquiera* de estas alcanza para un takeover completo del host: las capabilities son lo de menos.

**A1.4** — Esta es la C de **Container** fallando por una brecha de control de **Cluster**/**Cloud**. El montaje de solo lectura igual expone `/etc/shadow`, claves privadas TLS bajo `/etc/kubernetes/pki`, credenciales de instancia de la nube, y el rootfs de todos los demás contenedores bajo `/var/lib/containers`. La solo-lectura previene la *modificación*, no la *divulgación*, y la confidencialidad es la propiedad que importa para las credenciales. El control que debería haberlo detenido es la política en tiempo de admisión —los Pod Security Standards `baseline`/`restricted` prohíben por completo los volúmenes `hostPath` (ejercicio 6)—, no un escáner ni la disciplina del desarrollador.

### Ejercicio 2

**A2.1** — Durante un incidente, un atacante que logra ejecución remota de código en un contenedor distroless no tiene intérprete con el que pivotear: no hay `sh`, no hay `curl`/`wget` para preparar un payload de segunda etapa, no hay `apt` para instalar herramientas, no hay `nc` para abrir una reverse shell. Convierte muchas primitivas de RCE en un callejón sin salida. La depuración sigue siendo posible con **contenedores efímeros**: `kubectl debug -it <pod> --image=busybox:1.36 --target=<container> -- sh` adjunta un contenedor completamente equipado que comparte los namespaces de proceso y de red del target sin cambiar la imagen en ejecución. En un runtime pelado, `nsenter`/`podman exec` desde un contenedor de debug logra lo mismo.

**A2.2** — `CGO_ENABLED=0` produce un binario enlazado estáticamente con las implementaciones puramente Go de `net` y `os/user`. La base `distroless/static` contiene solo certificados CA, `/etc/passwd`, datos de zona horaria y `tmp`: **no** tiene `libc` ni cargador dinámico (`ld-linux-x86-64.so.2`). Un binario con cgo habilitado fallaría en tiempo de exec con `no such file or directory` (el error engañoso que produce un intérprete faltante). La alternativa es `distroless/base`, que sí incluye glibc.

**A2.3** — La comprobación `runAsNonRoot: true` del kubelet. El kubelet tiene que decidir, *antes* de arrancar el contenedor, si el UID efectivo es distinto de cero. Solo puede hacerlo si el campo `User` de la config de la imagen es numérico; un nombre como `nonroot` requeriría resolver `/etc/passwd` dentro de la imagen, cosa que el kubelet no hace. Con un usuario nombrado se niega a arrancar el contenedor con `container has runAsNonRoot and image has non-numeric user (...), cannot verify user is non-root` — reproducido en el ejercicio 10, paso 6.

**A2.4** — Solo `localhost/app:bad` se ve afectada: la base distroless `static` no tiene OpenSSL en absoluto (el binario Go usa `crypto/tls`). Este es el punto central sobre los conteos de vulnerabilidades: un conteo es una propiedad del *bill of materials*, no del riesgo. Reducir el BOM reduce el conteo sin parchear nada, y una imagen de "0 CVE" con una falla de aplicación alcanzable y sin autenticar es muchísimo más peligrosa que una de "40 CVE" cuyos hallazgos están todos en código inalcanzable. Usá los conteos para comparar una imagen contra *su propia historia*, nunca como una barra de calidad absoluta.

### Ejercicio 3

**A3.1** — `--ignore-unfixed` suprime las vulnerabilidades para las cuales la distribución no publicó ninguna versión corregida. Sin eso, el gate falla por hallazgos que el equipo estructuralmente no puede remediar: no hay paquete al cual actualizar. El resultado predecible es que el gate termine siendo evadido: alguien agrega `|| true`, o `--exit-code 0`, o un archivo de ignores que crece sin parar, y a partir de ese día el gate no detecta nada, incluidos los críticos que sí tenían fix. Un gate solo debe fallar por hallazgos *accionables*; los que no tienen fix van a un reporte con un responsable y un SLA.

**A3.2** — (a) El SBOM registra lo que *realmente se construyó*, en tiempo de build, incluidas dependencias solo-de-build y vendorizadas que pueden no verse desde las capas de la imagen final. (b) Reescanear un SBOM es gratis, offline e instantáneo, así que podés reevaluar toda tu flota histórica contra un CVE nuevo en segundos sin bajar cientos de imágenes ni contactar al registry: exactamente la carga de trabajo posterior a un zero-day como Log4Shell. También le permite a un equipo de seguridad escanear artefactos que no está autorizado a bajar, y te deja responder "¿cuáles de nuestros 400 servicios incluyen esta biblioteca?" con una consulta en lugar de un rebuild.

**A3.3** — La imagen es idéntica byte a byte; lo que cambió es la **base de datos de vulnerabilidades**. Se publicaron CVE nuevos, o se asignaron CVE existentes a paquetes presentes en esa imagen. Por eso un gate en tiempo de build es necesario pero no suficiente: también necesitás **reescaneo continuo de lo que está desplegado** (`trivy k8s --report summary cluster`, o un escáner del lado del registry), porque el riesgo de un artefacto cambia mucho después de su último build.

**A3.4** — Una entrada de ignore sin expiración es permanente por accidente. La justificación ("ruta de código inalcanzable") es cierta para una versión de la aplicación; la próxima refactorización puede volver alcanzable esa ruta, y nada reevalúa la decisión. La entrada suprime el hallazgo para siempre y en todos los escaneos, incluido el posterior al cambio de código. La propiedad debe ser un equipo con nombre, y la expiración lo bastante corta como para que la revisión efectivamente ocurra: la sintaxis `exp:` de Trivy hace que la entrada deje de suprimir automáticamente, que es justamente el punto.

### Ejercicio 4

**A4.1** — Los tags son **mutables**. Si firmás `app:1.0.0` y verificás `app:1.0.0`, un atacante (o un job de CI descuidado) con permiso de push al registry puede reapuntar ese tag a un manifiesto distinto después de la firma. El verificador entonces o falla (el mejor caso) o, si el atacante además tiene una firma válida para su propio build, tiene éxito sobre el artefacto equivocado. Firmar un digest liga la firma a contenido inmutable: `sha256:…` *es* el hash del contenido, así que una imagen sustituida produce un digest distinto y no puede presentarse bajo la misma referencia. El patrón completo de producción es: resolver tag → digest una sola vez, firmar el digest, y desplegar el digest.

**A4.2** — Integridad y origen autenticado. Un `sbom.json` plano en un almacén de artefactos es una afirmación sin firmar: cualquiera con acceso de escritura puede editarlo para eliminar un componente, y no hay vínculo criptográfico entre él y la imagen. `cosign attest` envuelve el SBOM en un statement in-toto cuyo `subject` es el digest de la imagen, lo firma, y lo almacena en el registry junto a la imagen. La verificación entonces prueba que *este SBOM describe exactamente esta imagen, y fue producido por el poseedor de esta clave / esta identidad OIDC*. Esa es la diferencia entre un documento y una evidencia.

**A4.3** — La raíz de confianza pasa a ser la **identidad OIDC** más el log de transparencia: Fulcio emite un certificado X.509 de vida corta (10 minutos) que liga la clave efímera a la identidad del workload (por ejemplo, un workflow de GitHub Actions), y Rekor registra la firma de forma inmutable para que el certificado expirado siga siendo verificable. Los nuevos modos de falla son (a) el compromiso del proveedor de identidad o de la propia cuenta de CI —si un atacante puede correr un workflow en tu repo, puede producir una imagen maliciosa legítimamente firmada, y por eso la verificación debe fijar `--certificate-identity-regexp` a rutas de workflow específicas y no simplemente a la organización—; y (b) la dependencia de la disponibilidad e integridad de las instancias públicas de Fulcio/Rekor.

**A4.4** — Sí, sirve, pero responde a una pregunta distinta. La firma afirma la *procedencia*: este artefacto fue producido por un builder autorizado y no fue alterado desde entonces. No dice nada sobre la *calidad del contenido*. El escaneo afirma lo inverso: acá está lo que hay adentro, sin ninguna afirmación sobre quién lo construyó. Necesitás ambos, más el enforcement de ambos en tiempo de admisión: una imagen firmada con 40 críticos debería fallar el gate de escaneo, y una imagen sin firmar con 0 críticos debería fallar el gate de firma.

### Ejercicio 5

**A5.1** — En Podman rootless el contenedor corre dentro de un **user namespace** donde el UID 0 del contenedor está mapeado al UID 1000 del host (el usuario que invoca) y los UID 1–65536 del contenedor mapean al rango subordinado 100000–165535 de `/etc/subuid`. Toda capability que el proceso tenga está acotada a ese namespace. Sobre el filesystem del host, por lo tanto, solo puede tocar lo que el UID 1000 del host (o el rango subuid) puede tocar: escribir en `/etc` o leer `/etc/shadow` falla con `EACCES`, y el kernel lo aplica en la capa VFS, no mediante una política que pueda estar mal configurada. "Root en el contenedor" significa que puede hacer `chown` de archivos que le pertenecen *dentro de su propio mapeo* y bindear puertos bajos dentro de su network namespace. Este es el límite más fuerte del ejercicio porque se aplica mediante traducción de UID y no mediante contabilidad de capabilities.

**A5.2** — `no_new_privs` es una flag de kernel por proceso (`PR_SET_NO_NEW_PRIVS`) que se hereda a través de `execve` y no puede limpiarse. Hace que el kernel ignore los bits setuid/setgid y las file capabilities de los binarios ejecutados posteriormente. Es una capa de *contención*: no elimina el bit setuid, no arregla la imagen, y no detiene una escalada que provenga de cualquier otro lado —un `hostPath` demasiado permisivo, una capability otorgada como `CAP_SYS_ADMIN`, una vulnerabilidad de kernel, o una credencial comprometida montada en el Pod—. Cierra exactamente un camino. En Kubernetes es `allowPrivilegeEscalation: false`, que `restricted` exige.

**A5.3** — `SCMP_ACT_ERRNO` devuelve un código de error (acá `EPERM`) al llamador: la syscall falla pero el proceso vive, lo que hace aparecer la denegación como un error normal y manejable. `SCMP_ACT_KILL` (y `SCMP_ACT_KILL_PROCESS`) termina el proceso inmediatamente con `SIGSYS`, dándote un corte duro pero un crash muy poco útil y ninguna funcionalidad parcial. `SCMP_ACT_LOG` permite la syscall y la registra en el audit log. Al perfilar una aplicación desconocida desplegás **`SCMP_ACT_LOG` primero** como acción por defecto, recolectás el uso real de syscalls bajo carga de producción durante un ciclo de negocio completo (incluyendo arranque, rotación y rutas de error), después generás un perfil y pasás a `ERRNO`, y solo considerás `KILL` cuando estés seguro de que la allow-list está completa.

**A5.4** — Un volumen escribible le permitiría a un atacante que consigue escritura de archivos dejar y ejecutar un payload, o plantar un binario setuid. `noexec` hace que el kernel se niegue a hacer `execve` de cualquier cosa en ese montaje; `nosuid` hace que ignore ahí los bits setuid/setgid. `tmpfs` además significa que los datos están respaldados en memoria y desaparecen con el contenedor, de modo que nada persiste a través de un reinicio y no hay huella en disco del host que recuperar forensemente ni que un atacante pueda reutilizar. Combinado con `--read-only`, la superficie escribible se reduce exactamente a las rutas que la aplicación declaró necesitar, y ni siquiera esas pueden alojar código ejecutable. `size=64m` previene una DoS por agotamiento de memoria vía el tmpfs.

**A5.5** — Cambiar la imagen para que escuche en un puerto no privilegiado (≥ 1024) y corra como usuario no root: exactamente lo que hace `nginxinc/nginx-unprivileged` al escuchar en 8080. `CAP_NET_BIND_SERVICE` existe únicamente para permitir bindear por debajo de 1024; una vez que el puerto es 8080 no hay nada que otorgar. El Service puede seguir exponiendo el puerto 80 hacia afuera y apuntar a 8080, así que para los clientes no cambia nada. La alternativa —fijar `net.ipv4.ip_unprivileged_port_start` vía sysctl— mueve el problema a una configuración a nivel de nodo y es peor.

### Ejercicio 6

**A6.1** — Tres fases, sin saltos: (1) etiquetar el namespace con `warn=restricted` y `audit=restricted` dejando `enforce` en su nivel actual —los clientes ahora ven advertencias y el API server escribe anotaciones de auditoría, pero no se bloquea nada—; (2) recolectar durante un ciclo de despliegue completo (incluidos los CronJobs, que pueden correr semanalmente, y los DaemonSets, que solo se reconcilian ante cambios de nodo), corregir cada workload que viole, y confirmar que el stream de advertencias está limpio; (3) recién entonces poner `enforce=restricted`. Crucialmente, **PSA se evalúa en la creación del Pod, no sobre los Pods existentes**, así que cambiar `enforce` no desaloja nada: la rotura aparece más tarde, en el próximo rollout, drenaje de nodo o evento de autoescalado, que es el peor momento posible para descubrirla. Esa propiedad de mecha retardada es exactamente por qué la fase de auditoría es obligatoria.

**A6.2** — `latest` significa "lo que sea que defina la versión actual del API server", así que el estándar puede volverse más estricto por debajo tuyo durante una actualización del cluster: una comprobación nueva agregada en la siguiente versión minor empieza a rechazar Pods que ayer cumplían, sin ningún cambio de tu lado y sin ningún deploy con el cual correlacionar. Fijar `enforce-version: v1.31` congela el conjunto de reglas: después de actualizar el cluster reevaluás deliberadamente contra la versión nueva (usando primero `warn`/`audit` en la versión nueva) y después subís el pin. Convierte un incidente no planificado en una tarea programada.

**A6.3** — El mensaje vino de la label `warn=restricted`; `enforce` era `baseline`, y el Pod satisface `baseline` (no es privileged y no pide namespaces del host), así que fue admitido. Las advertencias se devuelven al cliente en el header HTTP `Warning`: son visibles para quien corrió `kubectl`, y para nadie más. La label `audit=restricted` es la que hace durable la violación: el API server agrega una anotación `pod-security.kubernetes.io/audit-violations` al evento de auditoría, que termina en el **audit log del API server** (solo si hay una política de auditoría configurada para registrarlo a nivel `Metadata` o superior). Ese es el mecanismo que consultás para armar el inventario de workloads que violan en todo un cluster, porque las advertencias son efímeras.

**A6.4** — PSA no puede detener la escalada a través de la capa de **RBAC** y de la **API**, porque solo valida especificaciones de Pod. Un usuario con `create` sobre `deployments` en un namespace que aplica `restricted` sigue sin poder correr un Pod privilegiado; pero un usuario con `escalate`/`bind` sobre objetos RBAC, o con `create` sobre `clusterrolebindings`, o con `update` sobre un `MutatingWebhookConfiguration`, o con `create` sobre `nodes/proxy`, o con la capacidad de modificar las propias labels PSA de un namespace, puede escalar a cluster-admin sin violar jamás un Pod Security Standard. El control es el mínimo privilegio en RBAC (ejercicio 8) y, específicamente: nadie que despliegue workloads debería poder editar las labels del namespace que lo restringen.

**A6.5** — `readOnlyRootFilesystem: true` vuelve inmutable todo el filesystem raíz del contenedor, pero nginx necesita escribir en runtime: buffers de proxy/caché bajo `/var/cache/nginx`, el archivo PID bajo `/var/run` (o `/tmp` en la imagen unprivileged), y archivos temporales del cuerpo del cliente bajo `/tmp`. Cada una de esas rutas necesita entonces un montaje escribible: `emptyDir` da un volumen efímero por Pod que muere con el Pod. La imagen estándar `nginx:1.27` además no puede satisfacer `runAsNonRoot` porque su entrypoint arranca como root para bindear el puerto 80 y luego baja privilegios; `nginx-unprivileged` está construida para arrancar como UID 101 en el puerto 8080 y no necesita ni root ni `CAP_NET_BIND_SERVICE`.

### Ejercicio 7

**A7.1** — `policyTypes: ["Egress"]` sin reglas `egress` deniega **todo** el tráfico saliente, incluido UDP/TCP 53 hacia CoreDNS en `kube-system`. Como prácticamente toda aplicación resuelve un nombre antes de conectar, el primer síntoma no es "connection refused" sino una falla del resolver: `Temporary failure in name resolution`, `getaddrinfo EAI_AGAIN`, `no such host`, o —lo más confuso— una demora de 5 segundos por búsqueda seguida de un timeout, porque el stub resolver reintenta contra cada `nameserver` de `/etc/resolv.conf` y el `ndots:5` de la config DNS por defecto del Pod multiplica la cantidad de consultas. Los equipos suelen diagnosticar mal esto como una caída de DNS. Toda política de egress default-deny necesita una regla compañera que permita DNS.

**A7.2** — En la API de `NetworkPolicy` no existe el "deny". La semántica es: *si alguna política selecciona un Pod para una dirección dada, todo el tráfico en esa dirección queda denegado salvo lo que alguna política que lo seleccione permita explícitamente.* `default-deny-all` tiene `podSelector: {}`, así que selecciona todos los Pods de `shop` en ambas direcciones, pasándolos de "permitir todo" (el comportamiento cuando ninguna política selecciona un Pod) a "denegar salvo lo permitido". Las tres reglas del paso 4 luego unen los flujos permitidos específicos. Si eliminaras `default-deny-all`, las otras tres políticas seguirían seleccionando sus Pods, así que el efecto sobre `client` y `api` no cambiaría; pero cualquier *otro* Pod del namespace, no seleccionado por nada, volvería a estar sin restricciones. Ese es el valor de la política con selector vacío: hace que el namespace sea cerrado por construcción, de modo que un Pod recién desplegado queda denegado por defecto en lugar de abierto por defecto.

**A7.3** — El código 28 es el `CURLE_OPERATION_TIMEDOUT` de curl: el SYN salió y **no volvió nada**. Una `NetworkPolicy` implementada como filtro de paquetes descarta el paquete en silencio; no hay RST ni ICMP unreachable, así que el cliente espera el timeout de conexión. `Connection refused` (código 7, `ECONNREFUSED`) significaría que el paquete *sí* llegó a un host que devolvió un RST de TCP, es decir que el camino de red está bien y el problema está en el destino: ningún proceso escuchando, puerto equivocado, o un Service sin endpoints listos. Entonces: **timeout ⇒ sospechá de la política de red, del security group o del ruteo; refused ⇒ sospechá de la aplicación, del puerto o de la selección de endpoints.** Esta única distinción elimina de entrada la mitad del espacio de búsqueda.

**A7.4** — Desplegar la política y probarla: aplicar un default-deny en un namespace descartable y confirmar que el tráfico efectivamente se bloquea, por ejemplo:

```bash
kubectl create ns npcheck && kubectl -n npcheck apply -f netpol-deny.yaml
kubectl -n npcheck run t --image=curlimages/curl:8.8.0 --restart=Never --command -- \
  curl -s --max-time 5 https://example.com/
kubectl -n npcheck logs t   # empty + non-zero exit ⇒ enforced; content ⇒ NOT enforced
```

El API server acepta objetos `NetworkPolicy` incondicionalmente —es un recurso común, tipo CRD, sin ninguna comprobación en tiempo de admisión de que exista un CNI que lo implemente—, así que un `kubectl get netpol` que muestra tus políticas prueba únicamente que están *almacenadas*. Nunca infieras enforcement a partir de un `apply` exitoso.

**A7.5** — `kubernetes.io/metadata.name` la establece y mantiene automáticamente el API server en todo objeto Namespace (mediante el comportamiento `NamespaceDefaultLabelName`, GA desde 1.21); su valor es siempre el nombre del namespace y no puede desviarse. Etiquetar los namespaces vos mismo es peor porque la label es mutable por cualquiera con `update` sobre namespaces —incluidas, en muchos clusters, las mismas personas que despliegan workloads—, así que una política basada en una label gestionada a mano puede saltearse reetiquetando un namespace. Basarse en la label automática ata la regla a la identidad y no a una convención.

### Ejercicio 8

**A8.1** — El token del paso 4 es un token **bound**: lleva `aud` (solo aceptado por la audiencia del API server), `exp` (acá 10 minutos; la vida por defecto de un token proyectado es 1 hora con refresco automático del kubelet), y claims `kubernetes.io` que lo ligan al Pod específico y al UID del ServiceAccount, de modo que el API server lo rechaza una vez que el Pod se elimina. El token legacy respaldado por `Secret` era un JWT **sin expiración**, sin audiencia y sin ligadura al Pod: válido para siempre, desde cualquier lado, hasta que el Secret se borrara manualmente y se rotara cada consumidor. Radio de impacto: un token bound filtrado le da al atacante minutos y solo contra el API server; un token legacy filtrado da acceso permanente, es aceptado por cualquier servicio que confíe en el JWKS del cluster, y típicamente se descubre años después en un historial de git o en un agregador de logs.

**A8.2** — Del ClusterRole `system:basic-user`, ligado al grupo `system:authenticated` por el ClusterRoleBinding `system:basic-user`, que el API server crea y reconcilia en cada arranque. Toda identidad autenticada del cluster lo recibe. Otorga `create` sobre `selfsubjectaccessreviews` y `selfsubjectrulesreviews` —la capacidad de preguntar "¿qué puedo hacer *yo*?"—, que es precisamente lo que llama `kubectl auth can-i`. Por eso los permisos agregados siempre incluyen entradas que no escribiste: los roles `system:*` por defecto se aplican a todos, y toda revisión de los permisos efectivos de una identidad debe tenerlos en cuenta.

**A8.3** — `--as=` usa la funcionalidad de **impersonation** del API server: la solicitud se autoriza exactamente como si viniera de ese sujeto, a través de la misma cadena de autorización (RBAC, más los autorizadores Node/ABAC/webhook si están configurados), y devuelve el veredicto definitivo. Construir un kubeconfig a mano introduce modos de falla que no tienen nada que ver con el RBAC que estás probando —un token truncado, el bundle de CA equivocado, un `--server` faltante, un token expirado, un shell que destrozó el JWT—, así que un `Forbidden` puede reflejar tu tipeo y no tu política; y peor, un `yes` obtenido con un contexto admin viejo puede parecer una prueba exitosa. `--as=` además no necesita que exista ninguna credencial, así que podés validar un Role antes de crear el ServiceAccount, y funciona para usuarios y grupos (`--as-group=`) que por definición no tienen token.

**A8.4** — En RBAC, los subrecursos se nombran `padre/subrecurso` en la lista `resources` y se autorizan de forma independiente del padre. Otorgar `get` sobre `pods` **no** otorga `get` sobre `pods/log`, `pods/exec`, `pods/portforward`, `pods/attach` ni `pods/ephemeralcontainers`. Esa separación es todo el punto: te permite otorgar visibilidad de solo lectura sobre los metadatos de los Pods reteniendo la capacidad de leer logs de aplicación (que rutinariamente contienen credenciales y PII) y, mucho más importante, de hacer `exec` dentro de un contenedor — `pods/exec` es una shell completa en todos los Pods del alcance y equivale efectivamente a ser dueño de todo lo que esos Pods puedan alcanzar, incluidos sus tokens de ServiceAccount. Auditá los permisos `pods/exec` y `pods/portforward` como si fueran admin.

**A8.5** — Varios, cualquiera de los cuales es un takeover completo del cluster:
- `escalate` o `bind` sobre `roles`/`clusterroles`, que levanta la prevención normal de escalada de privilegios y permite que un sujeto se otorgue lo que quiera.
- `create` sobre `clusterrolebindings` (o `rolebindings` que referencien un ClusterRole poderoso): ligate a `cluster-admin`.
- `create` sobre `pods` en `kube-system`, o en cualquier lugar donde viva un ServiceAccount privilegiado: programá un Pod con ese SA, o con `hostPath: /`, o en un nodo del control plane, y leé el kubeconfig de admin.
- `create` sobre `pods/exec` contra un Pod que corre con un SA privilegiado.
- `update` sobre `mutatingwebhookconfigurations` / `validatingwebhookconfigurations`: interceptar y reescribir todos los objetos del cluster.
- `get`/`list` sobre `secrets` a nivel de cluster: todas las credenciales del cluster, incluidos los tokens de SA.
- `create` sobre `nodes/proxy`: acceso directo a la API del kubelet, es decir, exec en cualquier Pod del nodo.
- `impersonate` sobre users/groups/serviceaccounts.
- `approve` sobre `certificatesigningrequests` más `create` sobre CSR: emitir un certificado de cliente para `system:masters`.

### Ejercicio 9

**A9.1** — Ninguna en absoluto. Base64 es una codificación de transporte que permite almacenar valores binarios arbitrarios en un campo de tipo string de JSON/YAML; es trivialmente reversible por cualquiera y no aporta ninguna confidencialidad. Un Secret se distingue de un ConfigMap por *cómo lo trata el resto del sistema* —puede cifrarse en reposo, se excluye de algunos logs, es un recurso RBAC separado, y el kubelet lo guarda en `tmpfs`—, no por ninguna transformación de su contenido.

**A9.2** — El cifrado lo aplica el API server únicamente en el camino de **escritura**. Los objetos que ya están en etcd se quedan en la forma en que fueron escritos; el provider `identity: {}` listado después de `aescbc` es lo que hace que sigan siendo legibles (los providers se prueban en orden para descifrar, e `identity` significa "almacenado en texto plano"). `kubectl get secrets -o json | kubectl replace -f -` lee cada Secret y lo vuelve a escribir sin cambios, lo que obliga al API server a reserializarlo a través del provider de cifrado ahora activo. El mismo procedimiento es el que corrés después de una **rotación de clave**, y la regla de orden es el meollo: para rotar, agregá la clave nueva como *segunda* entrada (así puede descifrar pero todavía no cifrar), reiniciá todos los API servers, después promovela a *primera*, reiniciá de nuevo, después reescribí todos los Secrets, y recién entonces eliminá la clave vieja. Eliminar la clave vieja antes de la reescritura vuelve permanentemente ilegible todo Secret no reescrito.

**A9.3** — (a) **Rotación:** un volumen de Secret montado lo actualiza el kubelet en el lugar cuando el Secret cambia (dentro de aproximadamente un período de sincronización más el TTL de caché, por defecto hasta ~1 minuto; y nada si se usa `subPath`), así que una aplicación que relee el archivo toma el valor nuevo sin reiniciar. Un valor `env` se materializa en el entorno del proceso en el momento del exec y es inmutable durante toda la vida del proceso: rotarlo requiere reiniciar el Pod, razón por la cual las credenciales inyectadas por env tienden a no rotarse nunca. (b) **Exposición:** las variables de entorno se filtran mucho más fácilmente: aparecen en `/proc/<pid>/environ` (legible por cualquier proceso con el mismo UID en el contenedor, y por cualquier cosa que pueda entrar al namespace), las hereda todo proceso hijo, se vuelcan comúnmente tal cual en manejadores de crash, stack traces, payloads de APM y endpoints de debug, y las imprime `kubectl describe pod` si se definieron inline en lugar de vía `secretKeyRef`. Un archivo montado `0400` lo lee un proceso en un momento y no se hereda. Preferí archivos; preferí credenciales dinámicas de vida corta por sobre ambos.

**A9.4** — `aescbc` (y `secretbox`) protegen contra el compromiso **offline** de los datos de etcd: un backup de etcd robado, un snapshot copiado a almacenamiento de objetos, un disco dado de baja, o un atacante con acceso de lectura al directorio de datos de etcd o a la API cliente de etcd sin el archivo de configuración del API server. **No** protegen contra un atacante con root en el nodo del control plane, porque la clave está en `/etc/kubernetes/enc.yaml` justo al lado del texto cifrado: ambos se comprometen juntos. El provider `kms` v2 elimina esa limitación: las claves de cifrado de datos quedan envueltas por una clave de cifrado de claves guardada en un KMS/HSM externo (un KMS de nube, Vault Transit), así el nodo nunca almacena nada que descifre por sí solo, la rotación y revocación de claves se centralizan, y el uso de la KEK se audita de forma independiente. Notá que de cualquier manera el API server tiene texto plano en memoria, así que esto es protección solo en reposo.

**A9.5** — `defaultMode: 0400` hace que cada archivo proyectado sea legible solo por su dueño y no escribible por nadie, así que un sidecar comprometido o un segundo proceso corriendo bajo otro UID en el Pod no puede leer la credencial, y nada puede manipularla. Para que el proceso dueño la lea, la propiedad del archivo tiene que coincidir: en un volumen de Secret los archivos pertenecen a root con el grupo tomado de `fsGroup`, así que un contenedor que corre como UID 65532 necesita que `fsGroup` aplique la propiedad de grupo y que el modo permita lectura de grupo (`0440`), **o bien** que el `runAsUser` del Pod coincida con el dueño del archivo. Con `0400` y un `runAsUser` no root sin propiedad coincidente, el contenedor obtiene `Permission denied`: una falla muy común y muy confusa. En la práctica: poné `fsGroup` al grupo del contenedor y usá `0440`, y acordate de que `fsGroup` no se aplica a montajes con `subPath`.

### Ejercicio 10

**A10.1** — Con `failurePolicy: Fail`, el API server trata un webhook inalcanzable como un rechazo. Si todos los Pods de Kyverno están caídos, **toda** creación/actualización que matchee las reglas del webhook se deniega en todo el cluster: los deployments no pueden rotar, el HPA no puede escalar, los Pods fallados no pueden recrearse y —lo más perverso— el propio Kyverno puede quedar imposibilitado de reiniciar si su propio namespace está en alcance. Esta es una forma bien conocida de tirar abajo un cluster sano con una herramienta de seguridad. `Ignore` invierte el riesgo: durante una caída, se admiten objetos sin validar, así que la ventana es una brecha de *seguridad* en lugar de una de *disponibilidad*. Las mitigaciones estándar son correr el controlador de admisión en alta disponibilidad repartido entre nodos con un PodDisruptionBudget, excluir `kube-system` y el propio namespace del motor de políticas vía `namespaceSelector`, poner un `timeoutSeconds` corto (5s o menos), y reservar `Fail` para aquellas políticas cuyo bypass sería genuinamente inaceptable dejando el resto en `Ignore`.

**A10.2** — `ValidatingAdmissionPolicy` solo *valida*. No puede **mutar** (inyectar sidecars, agregar campos `securityContext` por defecto, fijar `imagePullPolicy`), no puede **generar** (crear una NetworkPolicy o una ResourceQuota por defecto en cada namespace nuevo), no puede **limpiar**, y no puede realizar acciones que requieran estado externo — notablemente `verifyImages`, que tiene que traer una firma de un registry y verificarla contra una clave o una identidad de Fulcio. Tampoco tiene escaneo en background de recursos preexistentes ni salida `PolicyReport`. Las expresiones CEL se evalúan solo contra el objeto de la solicitud. Así que el patrón es complementario: empujá las reglas estructurales simples y de alto volumen a `ValidatingAdmissionPolicy` —sin Pods, sin certificados, sin riesgo de disponibilidad, evaluación in-process— y quedate con Kyverno/Gatekeeper para mutación, generación, verificación de imágenes y reporting.

**A10.3** — Un rechazo te informa sobre un objeto en el momento en que alguien intentó crearlo. Un `PolicyReport` te informa sobre **todo lo que ya existe**, porque `background: true` hace que Kyverno evalúe la política contra el estado actual del cluster de forma programada. En un cluster ya existente esta es la diferencia entre conocer tu exposición y descubrirla de a un deploy roto por vez: obtenés un inventario completo de los workloads que violan, por namespace y por responsable, que podés triar, asignar y reducir *antes* de pasar a `Enforce`. Ir directo a `Enforce` en un cluster en marcha no bloquea los Pods existentes —siguen corriendo—: bloquea el próximo rollout, lo que significa que el radio de impacto de la política llega en un momento impredecible, muy probablemente durante un incidente sin relación. Primero auditar, siempre.

**A10.4** — La comprobación ocurre en el kubelet porque es el primer componente que tiene la **configuración de la imagen**. El control de admisión corre contra el PodSpec mucho antes de que se elija un nodo o se baje una imagen; el API server no sabe —y no debe tener que contactar un registry para averiguar— qué `USER` declara la imagen. Recién después del pull el runtime puede leer el campo `User` de la config de imagen OCI y compararlo con `runAsNonRoot`. Si ese campo es un *nombre*, resolverlo requeriría leer `/etc/passwd` desde adentro de la imagen, cosa que el kubelet deliberadamente no hace, así que falla en modo cerrado. El arreglo es una línea en el Containerfile: declarar el usuario numéricamente.

```dockerfile
USER 10001:10001        # instead of: USER appuser
```

Alternativamente, fijar `runAsUser: 10001` explícitamente en el PodSpec también satisface la comprobación; pero arreglar la imagen es mejor, porque hace que todo consumidor de esa imagen sea correcto por defecto.

**A10.5** — Un bot automatizado de actualización de dependencias que trate el digest como fuente: Renovate o Dependabot vigilan el tag upstream, y cuando se publica una imagen nueva abren un pull request que reescribe la línea fijada `image: ghcr.io/org/app@sha256:…` al digest nuevo (los managers `helm-values`/`kubernetes` de Renovate hacen esto de forma nativa, manteniendo un comentario `# tag` por legibilidad). El digest sigue siendo inmutable en el manifiesto desplegado, mientras que la *actualización* se vuelve un commit revisable, testeable y revertible que pasa por los mismos gates de CI —escaneo, verificación de firma, rollout escalonado— que cualquier cambio de código. El antipatrón es un tag flotante más `imagePullPolicy: Always`, que "parchea" cambiando en silencio lo que corre, sin registro de qué cambió, sin revisión, y sin posibilidad de volver a un artefacto conocido.

### Ejercicio 11

**A11.1** — Esta es la **detección en runtime**, la capa que asume que la prevención ya falló. PSA, RBAC y las políticas de admisión toman decisiones *antes* de que un workload arranque, en base a la intención declarada; una vez que el Pod está corriendo y cumple, quedan mudos. Falco observa comportamiento real —syscalls—, así que atrapa lo que ninguna comprobación de admisión puede: un RCE a nivel de aplicación en un Pod totalmente conforme con `restricted`, un operador legítimo haciendo algo ilegítimo, robo de credenciales, ejecución de un criptominero, o la explotación de un zero-day en una imagen firmada, escaneada y sin privilegios. También produce el rastro de evidencia (proceso, línea de comandos, imagen, Pod, namespace, usuario) que necesita la respuesta a incidentes y que los logs de admisión no pueden dar.

**A11.2** — `kubelet` y `kube-proxy` leen legítimamente esas rutas todo el tiempo: el kubelet proyecta y refresca el token en el montaje `tmpfs` de cada Pod, y ambos componentes leen sus propias credenciales. Sin la exclusión, la regla dispararía continuamente en cada nodo, produciendo miles de eventos por hora de puro ruido. La consecuencia operativa es fatiga de alertas seguida de que la regla se silencie o se elimine, momento en el cual la detección real desaparece. Esta es la disciplina central de la detección en runtime: el valor de una regla lo determina su tasa de falsos positivos, no su cobertura, y toda regla necesita una pasada de tuning contra tráfico real antes de que se le permita despertar a nadie.

**A11.3** — Los programas eBPF se enganchan a tracepoints del kernel en el nodo, así que Falco solo ve lo que ocurre en los nodos donde corre su DaemonSet. En un control plane gestionado (EKS, GKE, AKS) no podés programar Pods en los nodos maestros, así que **la actividad del API server, el scheduler y el controller-manager es invisible para Falco**: esa visibilidad tiene que venir del audit log del API server del proveedor de nube, que es un pipeline aparte que hay que habilitar. Del lado del nodo, el DaemonSet necesita privilegios sustanciales para hacer su trabajo: `hostPID`, montajes de host de `/proc` y `/sys`, y `CAP_BPF` + `CAP_PERFMON` (o `CAP_SYS_ADMIN` en kernels viejos) para cargar los programas. Eso convierte al propio Falco en un objetivo de alto valor y en una excepción genuina al estándar `restricted`: debe desplegarse en un namespace dedicado con una exención de PSA documentada, RBAC estrictamente acotado, e imágenes verificadas por firma, porque comprometer la herramienta de seguridad compromete el nodo.

**A11.4** — Equivalentes preventivos:
- *Shell lanzada en un contenedor* → un perfil seccomp que deniegue el `execve` de binarios nuevos es impracticable, pero la prevención efectiva es una imagen sin shell (ejercicio 2) más RBAC que deniegue `pods/exec` (ejercicio 8); AppArmor también puede denegar la ejecución de `/bin/*`.
- *Lectura de `/etc/shadow`* → reglas de archivo de AppArmor o SELinux que denieguen la lectura de rutas sensibles, `readOnlyRootFilesystem`, y correr como un UID no root que simplemente no pueda leer el archivo.
- *Escritura debajo de un directorio de binarios* → `readOnlyRootFilesystem: true`, que hace la escritura imposible en lugar de meramente notada.

La detección es preferible cuando la prevención rompería el workload o no puede especificarse de antemano: cuando todavía no conocés el comportamiento legítimo de la aplicación, cuando la política tendría un costo inaceptable de falsos positivos (matar un proceso de producción ante una syscall inesperada), durante la fase de perfilado previa a escribir una política preventiva, y para comportamientos que son legítimos en sí mismos pero sospechosos en contexto: un `exec` de un ingeniero de guardia a las 03:00 no es algo que quieras bloquear, pero sí es absolutamente algo que querés que quede registrado. En la práctica, la detección también cubre el hueco de los workloads legacy y de terceros que no podés modificar.

### Ejercicio 12

**A12.1** — La cadena es Deployment → ReplicaSet → Pod, y cada controlador solo reporta sobre el objeto que gestiona directamente. El trabajo del deployment-controller es crear y escalar un ReplicaSet; eso lo hizo con éxito, así que el Deployment no tiene ningún error que reportar: apenas muestra `0/2` listos, lo que se lee como un rollout lento. El trabajo del replicaset-controller es crear Pods, y *su* `POST /api/v1/pods` es lo que PSA rechazó, así que el evento `FailedCreate` queda registrado en el ReplicaSet. Y como el Pod nunca fue admitido, no existe ningún objeto Pod: `kubectl get pods` no devuelve nada y `kubectl describe pod` no tiene nada que describir. La regla: **cuando un workload tiene cero Pods, el error está en el objeto un nivel más abajo, no en el Pod ni en el controlador de más arriba.**

**A12.2** — Todo lo que crea Pods a través de un controlador en lugar de directamente: `Deployment` (vía ReplicaSet), `StatefulSet`, `DaemonSet`, `Job` y `CronJob` (vía Job — dos niveles más abajo, así que puede que necesites `describe job` después de `describe cronjob`), más `ReplicationController` y cualquier cosa manejada por el custom resource de un operator. La regla general es recorrer la cadena de propiedad hacia abajo hasta encontrar el objeto cuyo controlador está haciendo la llamada a la API que falla, y leer ahí `.status.conditions` y los eventos:

```bash
kubectl -n <ns> describe replicaset -l <selector>     # or: describe job / describe statefulset
kubectl -n <ns> get events --sort-by=.lastTimestamp
kubectl -n <ns> get deploy <name> -o jsonpath='{.status.conditions}' | jq .
```

`ReplicaFailure` en las conditions del Deployment es la señal específica de que está fallando la *creación* de Pods, no su scheduling ni su arranque. Notá que el mismo patrón aplica a rechazos por cuota, ServiceAccounts faltantes y denegaciones de admission webhooks, no solo a PSA.

**A12.3** — El campo `Seccomp` en `/proc/<pid>/status` reporta el modo seccomp del proceso: `0` = deshabilitado (sin filtro), `1` = modo estricto (`SECCOMP_MODE_STRICT`, solo `read`, `write`, `_exit`, `sigreturn` — esencialmente nunca usado por los runtimes de contenedores), `2` = modo filtro (`SECCOMP_MODE_FILTER`, hay un programa BPF adjunto). `seccompProfile: { type: RuntimeDefault }` produce **`2`**, igual que `type: Localhost` con un perfil propio: el campo te dice que hay un filtro *activo*, no *cuál* filtro. `type: Unconfined`, u omitir `seccompProfile` en un cluster sin el valor por defecto, da `0`. Así que `Seccomp: 2` confirma que el enforcement está activo; para saber qué perfil, mirá `Seccomp_filters` (la cantidad de filtros adjuntos) y el PodSpec. Esta es la única forma de verificar desde adentro del contenedor que el perfil declarado efectivamente tomó efecto.

**A12.4** — La resolución correcta es una **exención estrictamente acotada**, no un namespace debilitado. Mové ese único workload a su propio namespace dedicado etiquetado con `enforce=baseline` (que permite capabilities agregadas que `restricted` prohíbe) mientras todo lo demás sigue en `restricted`; otorgá solo `CAP_NET_ADMIN` vía `capabilities: { drop: ["ALL"], add: ["NET_ADMIN"] }`, conservando `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` y `seccompProfile: RuntimeDefault`; restringí con RBAC quién puede desplegar en ese namespace; y agregá una regla de Kyverno/VAP que afirme que la exención aplica al ServiceAccount y la imagen de ese único workload, para que nada más se cuele en el agujero. Documentá la justificación y una fecha de expiración para revisión.

Etiquetar el namespace como `privileged` está mal por tres razones: es una decisión de alcance *namespace* aplicada para arreglar un problema de alcance *workload*, así que todos los Pods actuales y futuros de ese namespace heredan la exención; `privileged` permite muchísimo más que `NET_ADMIN` —namespaces del host, `hostPath`, `privileged: true`, sysctls arbitrarios—, así que el privilegio otorgado no guarda ninguna relación con la necesidad demostrada; y es invisible en la revisión, porque nada en el manifiesto del workload deja registro de que está corriendo sin confinamiento. Las exenciones deben ser tan pequeñas como el requisito y tan legibles como sea posible.

</details>