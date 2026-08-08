# Guía de estudio KCSA: Tema 1.6 – Seguridad de Workloads y Código de Aplicaciones

**Examen:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 1:** Cloud Native Security Basics  
**Subtema 1.6:** Workload and Application Code Security  
**Peso:** ~2.33%  

---

## 1. Enlaces de referencia oficiales

- **Plan de estudios KCSA de la CNCF:** [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Pod Security Standards de Kubernetes:** [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- **Security Context de Kubernetes:** [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- **RuntimeClass de Kubernetes:** [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- **Documentación de Sigstore Cosign:** [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
- **Framework de seguridad SLSA:** [https://slsa.dev/spec/v1.0/about](https://slsa.dev/spec/v1.0/about)
- **Mejores prácticas para la cadena de suministro de software de la CNCF:** [https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsp.md](https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsp.md)

---

## 2. Arquitectura técnica y mecánica interna

### 2.1 La arquitectura del ciclo de vida de seguridad de workloads
Asegurar los workloads en una arquitectura cloud-native requiere defensa en profundidad a través de tres fases principales del ciclo de vida: **Build**, **Deploy** y **Runtime**.

```
[ BUILD PHASE ]                 [ DEPLOY PHASE ]               [ RUNTIME PHASE ]
+-------------------+           +---------------------+        +--------------------+
|  Source Code      |           | Kubernetes API      |        | Kernel / Container |
|  & Dependencies   |           | Server (Admission)  |        | Runtime Engine     |
+---------+---------+           +----------+----------+        +---------+----------+
          |                                |                             |
  (Static Scanning)               (Policy Enforcement)           (System Call Intercept)
          |                                |                             |
          v                                v                             v
+-------------------+           +---------------------+        +--------------------+
| SAST / Secret     |           | Pod Security        |        | Seccomp, AppArmor, |
| Detection         |           | Admission (PSA)     |        | Linux Capabilities |
+---------+---------+           +----------+----------+        +---------+----------+
          |                                |                             |
  (Container Build)                       |                             |
          |                                |                             |
          v                                |                             v
+-------------------+                      |                   +--------------------+
| Distroless Image  |                      |                   | MicroVM Isolation  |
| + Syft SBOM       |                      |                   | (gVisor / Kata)    |
+---------+---------+                      |                   +--------------------+
          |                                |
  (Signing & Provenance)                   |
          |                                |
          v                                |
+-------------------+                      |
| Cosign Signatures |                      |
| + SLSA Attestation|----------------------+
+-------------------+
```

### 2.2 Mecánica de los componentes de seguridad principales

#### Reducción de la huella de la imagen base
Las imágenes base estándar (por ejemplo, `ubuntu`, `debian`) contienen intérpretes de shell (`/bin/sh`, `/bin/bash`), gestores de paquetes (`apt`) y utilidades estándar de C (`curl`, `wget`, `nc`). Un atacante que obtenga ejecución remota de código (RCE) dentro de dicho contenedor puede realizar fácilmente un movimiento lateral en la etapa de post-explotación. 

Usar **Distroless** (por ejemplo, `gcr.io/distroless/static-debian12`) o `scratch` elimina las shells, los gestores de paquetes y las utilidades estándar de Linux. Sin `/bin/sh`, las primitivas de inyección de comandos maliciosos fallan inmediatamente debido a fallos de `execve` (`ENOENT`).

#### Verificación de la cadena de suministro (Sigstore Cosign y SLSA)
Las imágenes de contenedor almacenadas en registros OCI pueden ser manipuladas o sufrir intercambios de vectores man-in-the-middle. **Cosign** implementa el firmado criptográfico de artefactos OCI. En modo keyless, aprovecha tokens OIDC (por ejemplo, GitHub Actions, GCP Workload Identity) emitidos a **Fulcio** (una Autoridad de Certificación), la cual emite un certificado x509 de corta duración. La firma se registra en **Rekor**, un registro de transparencia inmutable y de solo escritura al final (append-only). El admission controller verifica las firmas contra las claves públicas de Rekor antes de permitir el scheduling del Pod.

#### Software Bill of Materials (SBOM)
Un SBOM es un inventario estructurado de todos los componentes de software, dependencias directas y transitivas, versiones y licencias embebidas en un artefacto. Estándares como **SPDX** (System Package Data Exchange) y **CycloneDX** permiten la comparación automatizada de vulnerabilidades contra bases de datos de CVE incluso después de que las imágenes se hayan desplegado en producción.

#### Primitivas de seguridad del kernel de Linux en contenedores
- **Linux Capabilities (`capget`/`capset`):** Desagrega el todopoderoso `root` UID 0 en 41 privilegios distintos (por ejemplo, `CAP_NET_RAW`, `CAP_SYS_ADMIN`, `CAP_CHOWN`). Eliminar todas las capabilities (`drop: ["ALL"]`) evita que root dentro del contenedor modifique la red del kernel, monte sistemas de archivos o ejecute ataques con sockets crudos (raw sockets).
- **Seccomp (Secure Computing Mode):** Filtra las llamadas al sistema (syscalls) realizadas por un proceso al kernel de Linux utilizando Berkeley Packet Filters (BPF). Las aplicaciones estándar de glibc requieren menos de 70 llamadas al sistema de más de ~350. Aplicar `RuntimeDefault` o un perfil personalizado de seccomp bloquea syscalls peligrosas como `ptrace`, `kexec_load` o `reboot`.
- **Read-Only Root Filesystem:** Montar `/` como solo lectura (`readOnlyRootFilesystem: true`) fuerza a que todo el estado persistente o dinámico vaya a `tmpfs` o `volumeMounts` declarados explícitamente. Esto neutraliza la persistencia de payloads, las instalaciones de rootkits y los ataques de modificación de binarios.

#### Aislamiento de workloads mediante MicroVM (RuntimeClass)
Los contenedores estándar comparten el kernel de Linux del host a través de cgroups y namespaces. Una vulnerabilidad de día cero en el kernel permite un container escape directamente al espacio del kernel del host. **RuntimeClass** enruta Pods a runtimes de OCI alternativos:
- **gVisor (`runsc`):** Intercepta syscalls en un kernel en espacio de usuario escrito en Go, exponiendo una superficie restringida al kernel del host.
- **Kata Containers:** Inicia cada Pod de Kubernetes dentro de su propia microVM ligera dedicada de QEMU/Firecracker con un kernel de Linux dedicado.

---

## 3. Ejercicios guiados

### Ejercicio 1: Construcción de imagen de contenedor endurecida, análisis estático y generación de SBOM

En este ejercicio, crearás un Dockerfile multi-stage utilizando Google Distroless, ejecutarás análisis estático de seguridad, realizarás escaneo de secretos y generarás un SBOM estandarizado.

#### Paso 1.1: Build multi-stage con huella mínima
Crea un directorio de aplicación y escribe un `Dockerfile` multi-stage seguro para un servicio en Go.

Ejecuta en tu terminal:
```bash
mkdir -p ~/kcsa-workload-lab && cd ~/kcsa-workload-lab

cat << 'EOF' > main.go
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "OK")
	})
	fmt.Println("Server running on port 8080...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		panic(err)
	}
}
EOF

cat << 'EOF' > Dockerfile
# Stage 1: Build stage with full toolchain
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o server main.go

# Stage 2: Minimal Distroless runtime
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=builder /app/server /server
USER 65532:65532
ENTRYPOINT ["/server"]
EOF

docker build -t localapp:v1.0.0 .
```

Fragmento de salida esperada:
```text
[+] Building 4.2s (10/10) FINISHED
 => [stage-1 1/3] FROM gcr.io/distroless/static-debian12:nonroot
 => [stage-0 4/4] RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o server main.go
 => EXPORTING image docker.io/library/localapp:v1.0.0
```

#### Paso 1.2: Escaneo de vulnerabilidades y secretos utilizando Trivy
Escanea la imagen compilada en busca de vulnerabilidades, malas configuraciones y credenciales hardcodeadas.

Ejecuta:
```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 localapp:v1.0.0
```

Fragmento de salida esperada:
```text
localapp:v1.0.0 (debian 12.5)

Total: 0 (HIGH: 0, CRITICAL: 0)
```

Ahora realiza un escaneo de secretos en el directorio local para verificar los controles de análisis estático de código:

Ejecuta:
```bash
cat << 'EOF' > test_secret.py
# Hardcoded AWS secret key for demonstration
AWS_SECRET_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLEkey"
EOF

trivy fs --security-checks secret .
```

Fragmento de salida esperada:
```text
Target: test_secret.py
Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 1, CRITICAL: 0)

CRITICAL: AWS Secret Access Key identified
Line 2: AWS_SECRET_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLEkey"
```

Limpia el archivo de secreto de prueba:
```bash
rm test_secret.py
```

#### Paso 1.3: Generación de Software Bill of Materials (SBOM) con Syft
Genera un SBOM en formato SPDX JSON para el seguimiento de la cadena de suministro.

Ejecuta:
```bash
syft localapp:v1.0.0 -o spdx-json=sbom.spdx.json
head -n 25 sbom.spdx.json
```

Fragmento de salida esperada:
```json
{
 "SPDXID": "SPDXRef-DOCUMENT",
 "spdxVersion": "SPDX-2.3",
 "creationInfo": {
  "created": "2026-08-07T19:30:00Z",
  "creators": [
   "Organization: Anchore, Inc.",
   "Tool: syft-1.0.0"
  ]
 },
 "name": "localapp:v1.0.0",
 "dataLicense": "CC0-1.0",
 "documentNamespace": "https://anchore.com/syft/image/localapp-v1.0.0"
}
```

---

#### Comprobación de comprensión 1

**Pregunta 1.1:** ¿Por qué el uso de `gcr.io/distroless/static-debian12:nonroot` como imagen base reduce significativamente la superficie de ataque de la aplicación en comparación con `alpine` o `ubuntu`?  
A) Cifra automáticamente la memoria del contenedor en reposo.  
B) Elimina shells (`sh`, `bash`), binarios de utilidad (`curl`, `apt`), y se ejecuta por defecto como UID 65532 non-root, evitando la ejecución de shells en la etapa de post-explotación.  
C) Embebe un agente de kernel eBPF automático para bloquear llamadas al sistema no autorizadas.  
D) Convierte el bytecode de Go directamente en controladores de módulos del kernel.  

**Pregunta 1.2:** En una política de seguridad de pipeline CI/CD, ¿cuál es el efecto de ejecutar `trivy image --exit-code 1 --severity CRITICAL <image>`?  
A) Trivy parchea automáticamente las vulnerabilidades en el registro OCI.  
B) Trivy registra las vulnerabilidades críticas y permite que el pipeline de build continúe con éxito.  
C) Trivy devuelve un código de salida distinto de cero (`1`), lo que instruye al runner de CI a fallar el paso del pipeline y bloquear el despliegue si se detecta alguna vulnerabilidad CRITICAL.  
D) Trivy termina el proceso del demonio de Docker en el host.  

---

### Ejercicio 2: Seguridad de la cadena de suministro con firmado y atestaciones de Cosign

En este ejercicio, crearás un par de claves criptográficas utilizando Sigstore Cosign, firmarás un artefacto de imagen de contenedor OCI, adjuntarás una atestación in-toto y verificarás la integridad de la firma.

#### Paso 2.1: Generación de claves y firmado de imagen
Genera un par de claves usando Cosign. (Para pipelines CI automatizados, se prefiere el modo keyless de Cosign con OIDC a través de Fulcio/Rekor; aquí generamos claves explícitas para una ejecución local determinista).

Ejecuta:
```bash
# Set password variable for non-interactive key generation
export COSIGN_PASSWORD="KcsaExamPassWord123!"

cosign generate-key-pair
```

Fragmento de salida esperada:
```text
Private key written to cosign.key
Public key written to cosign.pub
```

Ahora firma tu imagen de contenedor (Nota: asegúrate de que la imagen se suba a un registro accesible o a una instancia de registro local; para la demostración la etiquetamos para un registro local):

Ejecuta:
```bash
# Start a local OCI registry container
docker run -d -p 5000:5000 --name registry registry:2

# Tag and push container image to local registry
docker tag localapp:v1.0.0 localhost:5000/localapp:v1.0.0
docker push localhost:5000/localapp:v1.0.0

# Sign the OCI artifact with Cosign
cosign sign --key cosign.key --tlog-upload=false localhost:5000/localapp:v1.0.0
```

Fragmento de salida esperada:
```text
Enter password for private key: 
Pushing signature to: localhost:5000/localapp
```

#### Paso 2.2: Verificación de firma
Verifica que la imagen publicada en el registro coincida con la clave pública criptográfica.

Ejecuta:
```bash
cosign verify --key cosign.pub localhost:5000/localapp:v1.0.0
```

Fragmento de salida esperada:
```json
Verification for localhost:5000/localapp:v1.0.0 --
The following checks were performed on each of these signatures:
  - The checks were verified against the specified public key
  - The signatures were verified against the specified code signing claims

[{"critical":{"identity":{"docker-reference":"localhost:5000/localapp"},"image":{"docker-manifest-digest":"sha256:a1b2c3..."},"type":"cosign container image signature"}}]
```

---

#### Comprobación de comprensión 2

**Pregunta 2.1:** ¿Qué rol desempeña Rekor en la arquitectura keyless de Sigstore / Cosign?  
A) Actúa como el registro principal de imágenes OCI almacenando capas brutas del contenedor.  
B) Es un registro de transparencia inmutable y de solo escritura al final (append-only) que registra los metadatos de las firmas, proporcionando una prueba pública de cuándo y por quién fue firmada una imagen.  
C) Genera certificados x509 de corta duración basados en tokens OIDC del proveedor de identidad.  
D) Inyecta dinámicamente capacidades del kernel de Linux en los Pods en ejecución tras la verificación.  

**Pregunta 2.2:** Si un atacante manipula una sola capa de una imagen de contenedor firmada dentro del registro de contenedores, ¿qué sucede durante `cosign verify`?  
A) Cosign recompila la capa del contenedor para que coincida con la firma.  
B) La verificación de Cosign se realiza con éxito pero imprime un mensaje de advertencia en los logs.  
C) La verificación de Cosign falla porque el digest del manifiesto de la imagen del contenedor (`sha256`) ya no coincide con el payload del digest firmado.  
D) Cosign solicita un nuevo certificado x509 a Fulcio para sobrescribir la imagen manipulada.  

---

### Ejercicio 3: Pod Security Standards (PSS) de Kubernetes y control de admisión

Kubernetes implementa tres niveles de Pod Security Standards: **Privileged**, **Baseline** y **Restricted**. Pod Security Admission (PSA) hace cumplir estos estándares en el límite del namespace mediante etiquetas.

#### Paso 3.1: Aplicación de la política de namespace Restricted
Crea un namespace seguro y configura etiquetas de Pod Security Admission para aplicar estrictamente el perfil `restricted`.

Ejecuta:
```bash
cat << 'EOF' > namespace-restricted.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: secure-workloads
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
EOF

kubectl apply -f namespace-restricted.yaml
```

Salida esperada:
```text
namespace/secure-workloads created
```

#### Paso 3.2: Prueba de denegación de admisión con un Pod no conforme
Intenta desplegar una definición de Pod insegura en el namespace `secure-workloads`.

Ejecuta:
```bash
cat << 'EOF' > insecure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-workload
  namespace: secure-workloads
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF

kubectl apply -f insecure-pod.yaml
```

Fragmento de salida esperada:
```text
Error from server (Forbidden): error when creating "insecure-pod.yaml": pods "insecure-workload" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Paso 3.3: Creación de un manifiesto de Pod endurecido de grado de producción
Crea un manifiesto de Pod sintácticamente válido y listo para producción que cumpla estrictamente con el Pod Security Standard `restricted`.

Ejecuta:
```bash
cat << 'EOF' > secure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  namespace: secure-workloads
  labels:
    app.kubernetes.io/name: secure-app
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: localhost:5000/localapp:v1.0.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    resources:
      limits:
        cpu: "250m"
        memory: "128Mi"
      requests:
        cpu: "100m"
        memory: "64Mi"
EOF

kubectl apply -f secure-pod.yaml
```

Salida esperada:
```text
pod/secure-workload created
```

Verifica la ejecución del Pod y los parámetros del Security Context:
```bash
kubectl get pod secure-workload -n secure-workloads -o jsonpath='{.spec.securityContext}'
```

Fragmento de salida esperada:
```json
{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}
```

---

#### Comprobación de comprensión 3

**Pregunta 3.1:** ¿Cuál es el propósito principal de configurar `allowPrivilegeEscalation: false` en el `securityContext` de un contenedor?  
A) Evita que el proceso del contenedor se vincule a puertos de red inferiores a 1024.  
B) Establece el bit `no_new_privs` en el proceso a través de `prctl(PR_SET_NO_NEW_PRIVS)`, evitando que binarios con flags SUID/SGID (por ejemplo, `sudo`, `passwd`) obtengan privilegios elevados durante la ejecución.  
C) Bloquea el contenedor para que no realice solicitudes HTTP GET al servicio de metadatos del proveedor de la nube (169.254.169.254).  
D) Desmonta el directorio `/proc` dentro del entorno del runtime del contenedor.  

**Pregunta 3.2:** Bajo el Pod Security Standard `restricted`, ¿qué configuración es obligatoria respecto a las Linux Capabilities?  
A) Los contenedores deben agregar explícitamente `CAP_SYS_ADMIN`.  
B) Los contenedores deben eliminar explícitamente todas las capabilities (`capabilities.drop: ["ALL"]`) y solo pueden agregar selectivamente capabilities mínimas requeridas como `NET_BIND_SERVICE` si está justificado.  
C) Los contenedores heredan por defecto todas las capabilities del kernel del nodo worker host.  
D) La eliminación de capabilities la maneja por completo el complemento CNI y no se puede configurar en el YAML del Pod.  

---

### Ejercicio 4: Aislamiento avanzado de workloads con perfiles personalizados de Seccomp y RuntimeClasses

En este ejercicio, crearás un perfil personalizado de seccomp para restringir las syscalls de Linux y configurarás una `RuntimeClass` para el aislamiento de workloads a nivel de hipervisor.

#### Paso 4.1: Despliegue de un perfil personalizado de Seccomp
Los nodos worker evalúan los perfiles de seccomp ubicados en el directorio raíz del kubelet (típicamente `/var/lib/kubelet/seccomp/`). Crea un perfil personalizado restrictivo que bloquee la llamada al sistema `mkdir`.

Ejecuta (definición de perfil simulada):
```bash
cat << 'EOF' > fine-grained-seccomp.json
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "clone",
        "execve",
        "exit",
        "exit_group",
        "futex",
        "write",
        "read",
        "epoll_wait"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": [
        "mkdir",
        "rmdir"
      ],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
EOF
```

Para hacer referencia a este perfil personalizado en un Pod de Kubernetes, especifica `type: Localhost` en la configuración de `seccompProfile`:

```yaml
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/fine-grained-seccomp.json
```

#### Paso 4.2: Configuración de una RuntimeClass de MicroVM (gVisor / Kata)
Define un objeto `RuntimeClass` de Kubernetes que mapee workloads a un gestor de runtime de OCI en sandbox (`gvisor` o `kata`).

Ejecuta:
```bash
cat << 'EOF' > runtime-class.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor-sandbox
handler: runsc
scheduling:
  nodeSelector:
    sandbox.k8s.io/enabled: "true"
  tolerations:
  - key: "sandbox.k8s.io/untrusted"
    operator: "Exists"
    effect: "NoSchedule"
EOF

kubectl apply -f runtime-class.yaml
```

Salida esperada:
```text
runtimeclass.node.k8s.io/gvisor-sandbox created
```

Despliega un Pod utilizando la `RuntimeClass`:

Ejecuta:
```bash
cat << 'EOF' > sandboxed-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed-workload
  namespace: default
spec:
  runtimeClassName: gvisor-sandbox
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: worker
    image: localhost:5000/localapp:v1.0.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
EOF

kubectl apply -f sandboxed-pod.yaml
```

Salida esperada:
```text
pod/sandboxed-workload created
```

---

#### Comprobación de comprensión 4

**Pregunta 4.1:** ¿Cuál es el mecanismo técnico mediante el cual `gVisor` (`runsc`) aísla un workload de contenedor del sistema operativo host?  
A) Aísla los workloads inyectando reglas de iptables que descartan todas las conexiones TCP entrantes.  
B) Ejecuta un kernel en espacio de usuario (escrito en Go) que intercepta las llamadas al sistema de la aplicación, reimplementando la mecánica del kernel y evitando el contacto directo de la aplicación con el kernel de Linux del host.  
C) Ejecuta el contenedor completamente dentro de un bucket remoto de AWS S3.  
D) Recompila el código fuente de la aplicación en binarios de WebAssembly (Wasm) al iniciar.  

**Pregunta 4.2:** ¿Cuál es la diferencia entre configurar la acción de seccomp en `SCMP_ACT_ERRNO` versus `SCMP_ACT_KILL` en un perfil personalizado de seccomp?  
A) `SCMP_ACT_ERRNO` hace que el kernel devuelva un código de error (`EPERM`) al proceso invocador sin terminarlo, mientras que `SCMP_ACT_KILL` termina inmediatamente el hilo/proceso que realiza la llamada al sistema prohibida.  
B) `SCMP_ACT_ERRNO` elimina el manifiesto del Pod de `etcd`.  
C) `SCMP_ACT_KILL` reinicia el SO host del nodo worker.  
D) No hay diferencia funcional; ambas acciones escriben un mensaje en `/var/log/syslog` y permiten que la llamada al sistema continúe.  

---

## 4. Técnicas de diagnóstico y resolución de problemas

### 4.1 Diagnóstico de denegaciones de Pod Security Admission (PSA)
Cuando un Pod o Deployment no logra desplegarse debido a la aplicación de PSA, inspecciona la respuesta del API server o describe el recurso padre (por ejemplo, ReplicaSet/Deployment):

```bash
kubectl get events -n secure-workloads --field-selector reason=FailedCreate
```

Patrón de error común:
```text
packs/ReplicaSet failed to create pods: pods "app-674b889796-" is forbidden: violates PodSecurity "restricted:latest": ...
```

**Lista de verificación de resolución:**
1. Verificar estado root: Asegurarse de que esté configurado `spec.securityContext.runAsNonRoot: true`.
2. Verificar capabilities: Asegurarse de que `spec.containers[*].securityContext.capabilities.drop` incluya `"ALL"`.
3. Verificar escalación: Asegurarse de que `spec.containers[*].securityContext.allowPrivilegeEscalation: false`.
4. Verificar seccomp: Asegurarse de que `spec.securityContext.seccompProfile.type` esté configurado en `RuntimeDefault` o `Localhost`.

### 4.2 Verificación del gestor del motor de runtime de contenedores
Para verificar si un Pod en ejecución se está ejecutando correctamente dentro de un runtime de sandbox (por ejemplo, `gVisor`), comprueba el nombre del kernel o el árbol de procesos dentro del contenedor:

```bash
kubectl exec -it sandboxed-workload -- uname -a
```

- **Salida en contenedor estándar:** `Linux node-01 6.5.0-28-generic #29-Ubuntu SMP ... x86_64 GNU/Linux`
- **Salida en sandbox de gVisor:** `Linux gVisor 2.6.35-gVisor #1 SMP Sun Jan 1 00:00:00 2017 x86_64 GNU/Linux`

---

<details>
<summary><b>5. Clave de respuestas y explicaciones técnicas detalladas</b></summary>

### Respuestas del Ejercicio 1

- **Pregunta 1.1: Respuesta correcta = B**  
  *Explicación:* Las imágenes Distroless contienen únicamente el binario de la aplicación y las dependencias mínimas en tiempo de ejecución (como certificados SSL y glibc/musl). Los intérpretes de shell como `/bin/sh` o `/bin/bash` y los gestores de paquetes como `apt` están completamente ausentes. Si un atacante descubre una vulnerabilidad en la aplicación (por ejemplo, ejecución remota de comandos), los intentos de generar un proceso shell fallan con `ENOENT` (archivo no encontrado). Además, la etiqueta `nonroot` predeterminada establece el usuario en el UID `65532`, adhiriéndose al menor privilegio.

- **Pregunta 1.2: Respuesta correcta = C**  
  *Explicación:* Configurar `--exit-code 1` fuerza a Trivy a devolver el código de salida `1` cada vez que se encuentran vulnerabilidades que coinciden con el filtro especificado (`--severity HIGH,CRITICAL`). Los motores de integración continua (CI) evalúan los códigos de salida; un código distinto de cero detiene el pipeline, evitando que artefactos vulnerables se envíen a registros o se desplieguen en clusters de producción.

---

### Respuestas del Ejercicio 2

- **Pregunta 2.1: Respuesta correcta = B**  
  *Explicación:* Rekor es el registro de transparencia inmutable de Sigstore basado en una arquitectura de árbol de Merkle. En el firmado keyless, Rekor almacena atestaciones de metadatos firmadas junto con marcas de tiempo criptográficas. Cualquiera que verifique la imagen puede auditar Rekor para confirmar que la firma de la imagen fue generada dentro de la ventana de validez precisa del certificado x509 de corta duración emitido por OIDC.

- **Pregunta 2.2: Respuesta correcta = C**  
  *Explicación:* Cosign firma el digest del manifiesto de la imagen OCI (`sha256:hash`). El digest del manifiesto representa un hash criptográfico de todos los diff IDs de las capas de componentes. Si una capa se modifica o manipula, el digest SHA256 del manifiesto OCI resultante cambia. Durante `cosign verify`, el hash calculado de la imagen del registro no coincide con el digest del payload firmado, lo que resulta en un fallo de verificación.

---

### Respuestas del Ejercicio 3

- **Pregunta 3.1: Respuesta correcta = B**  
  *Explicación:* En Linux, los binarios setuid (como `passwd` o `su`) permiten que los procesos asuman temporalmente los privilegios del propietario del archivo (a menudo root). Configurar `allowPrivilegeEscalation: false` se traduce en la llamada al sistema del kernel `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`. Una vez configurado, los procesos hijo creados a través de `execve` no pueden obtener privilegios superiores a los de su proceso padre, neutralizando los ataques de escalación de privilegios a través de binarios setuid.

- **Pregunta 3.2: Respuesta correcta = B**  
  *Explicación:* El Pod Security Standard `restricted` de Kubernetes requiere que los Pods eliminen todas las Linux capabilities por defecto a través de `capabilities.drop: ["ALL"]`. Si el workload requiere una funcionalidad específica (como vincularse a puertos de red bajos), solo se pueden volver a agregar explícitamente las capabilities mínimas necesarias (por ejemplo, `NET_BIND_SERVICE`) bajo `capabilities.add`.

---

### Respuestas del Ejercicio 4

- **Pregunta 4.1: Respuesta correcta = B**  
  *Explicación:* Los contenedores estándar ejecutan llamadas al sistema directamente en el kernel de Linux compartido del host. `gVisor` introduce `runsc`, un runtime de OCI que ejecuta un kernel dedicado en espacio de usuario (llamado Sentry) escrito en Go con seguridad de memoria. Las llamadas al sistema emitidas por la aplicación del contenedor son interceptadas y manejadas por el Sentry, reduciendo significativamente la exposición directa al kernel del SO host.

- **Pregunta 4.2: Respuesta correcta = A**  
  *Explicación:* Los filtros BPF de Seccomp ejecutan acciones cuando una llamada al sistema coincide con un filtro de regla. `SCMP_ACT_ERRNO` hace que el kernel de Linux rechace la llamada al sistema y devuelva inmediatamente un código de error (como `EPERM` / Operación no permitida) al proceso invocador, lo que permite un manejo controlado del error por la aplicación. `SCMP_ACT_KILL` (o `SCMP_ACT_KILL_PROCESS`) envía una señal `SIGSYS`, terminando el hilo/proceso invocador inmediatamente.

</details>