# 3.3 Containerization

## ¿Qué es un container?

Un **container** es una unidad de software que empaqueta código y todas sus dependencias (librerías, binarios, archivos de configuración) para que una aplicación corra de forma rápida y confiable en distintos entornos de cómputo. A diferencia de una máquina virtual (VM), un container no incluye un sistema operativo completo: comparte el kernel del host y aísla el proceso mediante primitivas del propio kernel de Linux.

Esta diferencia es clave para el examen: las VMs virtualizan hardware (vía un hypervisor) y cada una corre su propio kernel; los containers virtualizan el sistema operativo (vía el kernel del host) y por eso son mucho más livianos, arrancan en milisegundos/segundos y consumen menos recursos.

```
VM                              Container
┌─────────────┐                 ┌─────────────┐
│   App A     │                 │   App A     │
├─────────────┤                 ├─────────────┤
│  Bins/Libs  │                 │  Bins/Libs  │
├─────────────┤                 ├─────────────┤
│ Guest OS    │                 │  (runtime)  │
├─────────────┤                 ├─────────────┤
│ Hypervisor  │                 │  Host OS    │
├─────────────┤                 ├─────────────┤
│ Infra       │                 │  Infra      │
└─────────────┘                 └─────────────┘
```

## Las primitivas del kernel de Linux

Los containers no son "magia": son procesos normales de Linux a los que el runtime les aplica dos mecanismos del kernel.

- **Namespaces**: aíslan lo que un proceso *puede ver*. Cada namespace le da al proceso su propia vista de un recurso del sistema.
  - `pid` — árbol de procesos propio (el proceso 1 dentro del container no es el proceso 1 del host).
  - `net` — interfaces de red, tablas de rutas y puertos propios.
  - `mnt` — punto de montaje de filesystem propio.
  - `uts` — hostname y domainname propios.
  - `ipc` — mecanismos de comunicación entre procesos (colas de mensajes, semáforos) aislados.
  - `user` — mapeo de UIDs/GIDs, base de los *rootless containers*.
- **Control groups (cgroups)**: limitan y contabilizan lo que un proceso *puede usar* (CPU, memoria, I/O de disco, ancho de banda de red). Son la razón por la que un container puede tener un `--memory=512m` o `--cpus=0.5`.

En resumen: **namespaces = aislamiento (visibilidad), cgroups = límites (consumo)**.

## Imágenes de container y el estándar OCI

Una **container image** es un artefacto inmutable, de solo lectura, compuesto por capas (*layers*) apiladas mediante un filesystem de unión (union filesystem, típicamente `overlay2`). Cada instrucción de un Dockerfile que modifica el filesystem genera una capa nueva, y las capas se cachean y reutilizan entre builds.

La **Open Container Initiative (OCI)**, parte de CNCF/Linux Foundation, define especificaciones abiertas para que cualquier herramienta sea interoperable:

- **OCI Image Spec**: formato de las imágenes (capas, manifest, configuración).
- **OCI Runtime Spec**: cómo se ejecuta un container a partir de un *bundle* (filesystem + config JSON).
- **OCI Distribution Spec**: cómo se hace push/pull de imágenes contra un registry.

Ejemplo de Dockerfile con **multi-stage build** (patrón muy preguntado, reduce el tamaño final de la imagen):

```dockerfile
# Etapa 1: build
FROM golang:1.22 AS builder
WORKDIR /src
COPY . .
RUN go build -o app .

# Etapa 2: runtime, solo el binario final
FROM alpine:3.19
COPY --from=builder /src/app /usr/local/bin/app
ENTRYPOINT ["/usr/local/bin/app"]
```

```
$ docker build -t myapp:1.0 .
$ docker images
REPOSITORY   TAG    IMAGE ID       SIZE
myapp        1.0    a1b2c3d4e5f6   12.4MB
golang       1.22   f6e5d4c3b2a1   814MB
```

## Container runtimes y CRI

Kubernetes no ejecuta containers directamente: delega esa tarea a un **runtime**, a través de la **Container Runtime Interface (CRI)**, una API gRPC que desacopla el kubelet de una implementación específica.

Se distinguen dos niveles:

- **High-level runtime**: gestiona el ciclo de vida completo (pull de imágenes, gestión de storage, API para el kubelet). Ejemplos: **containerd** y **CRI-O**. Docker Engine también actuaba como high-level runtime, pero **dockershim** fue removido de Kubernetes en la v1.24; hoy Docker Desktop usa containerd por debajo.
- **Low-level runtime**: crea y ejecuta el container en sí, aplicando namespaces/cgroups según el OCI Runtime Spec. El estándar de facto es **runc**. Existen alternativas orientadas a mayor aislamiento/seguridad como **gVisor** (sandboxing vía syscall interception) y **Kata Containers** (cada container corre dentro de una micro-VM liviana).

```
kubelet ──(CRI/gRPC)──> containerd/CRI-O ──(OCI)──> runc ──> proceso container
```

```
$ crictl ps
CONTAINER    IMAGE               STATE      NAME
9f8e7d6c5b   nginx:1.27          Running    web
$ ctr images ls
REF                      TYPE       DIGEST
docker.io/library/nginx  manifest   sha256:1a2b3c...
```

## Registries

Un **container registry** almacena y distribuye imágenes siguiendo el OCI Distribution Spec. Ejemplos: Docker Hub, Harbor (registry open source de CNCF, graduado), GitHub Container Registry, ECR/GCR/ACR de los cloud providers.

```
$ docker tag myapp:1.0 registry.example.com/team/myapp:1.0
$ docker push registry.example.com/team/myapp:1.0
$ docker pull registry.example.com/team/myapp:1.0
```

Buenas prácticas asociadas (relevantes para el examen): usar tags inmutables (evitar depender solo de `latest`), firmar imágenes (Sigstore/Cosign), y escanear vulnerabilidades (Trivy, Grype) antes de publicar.

## Seguridad de containers

Puntos que suele tocar el KCNA a nivel introductorio:

- **Rootless containers**: correr el runtime y los procesos sin privilegios de root en el host, usando `user` namespaces.
- **Capabilities**: en vez de root/no-root binario, Linux expone capabilities granulares (`NET_BIND_SERVICE`, `SYS_ADMIN`, etc.) que se pueden otorgar o quitar (`--cap-drop`, `--cap-add`).
- **Seccomp**: filtra qué syscalls puede invocar un proceso dentro del container, reduciendo la superficie de ataque.
- **Imagen mínima**: usar bases como `alpine` o `distroless` reduce el tamaño y la cantidad de CVEs expuestos.

## Referencias

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Open Container Initiative — especificaciones: https://opencontainers.org/
- containerd: https://containerd.io/docs/
- CRI-O: https://cri-o.io/
- Kubernetes, *Container Runtimes*: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes, *Container Runtime Interface (CRI)*: https://kubernetes.io/docs/concepts/architecture/cri/
- runc: https://github.com/opencontainers/runc
- gVisor: https://gvisor.dev/docs/
- Kata Containers: https://katacontainers.io/
- Docker, *Overview of Docker*: https://docs.docker.com/get-started/overview/
- Harbor: https://goharbor.io/docs/