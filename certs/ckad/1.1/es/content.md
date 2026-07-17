# 1.1 Define, build and modify container images

**Examen:** CKAD (versión 1.35) · **Peso:** 5

---

## 1. Imágenes de contenedor y el estándar OCI

Una **imagen de contenedor** es un paquete inmutable, de solo lectura, que contiene todo lo necesario para ejecutar una aplicación: código, runtime, librerías y variables de configuración por defecto. Kubernetes no define su propio formato de imagen: usa el estándar de la **Open Container Initiative (OCI)**, que especifica tres partes:

- **Image spec**: cómo se estructura una imagen (manifest, capas o *layers*, configuración).
- **Runtime spec**: cómo un runtime (containerd, CRI-O) debe ejecutar esa imagen.
- **Distribution spec**: cómo se publican y descargan las imágenes desde un *registry*.

Una imagen se compone de **capas** apiladas (cada instrucción del Dockerfile que modifica el filesystem genera una capa) más un **manifest** en JSON que las referencia por hash. Esto permite compartir capas entre imágenes distintas y descargar solo lo que falta.

```bash
$ docker image inspect nginx:1.27 --format '{{.RootFS.Layers}}'
[sha256:1e3d3b7f... sha256:8a2f5c11... sha256:4c9d0b3e...]
```

Cada imagen se identifica de forma única por su **digest** (`sha256:...`), que es determinístico e inmutable — a diferencia de un **tag**, que es solo un puntero mutable a un digest.

---

## 2. El Dockerfile: instrucciones principales

Un **Dockerfile** describe, paso a paso, cómo construir una imagen.

```dockerfile
# Dockerfile
FROM python:3.12-slim AS base

WORKDIR /app

# Instalar dependencias primero: aprovecha el cache de capas
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PORT=8080
EXPOSE 8080

RUN useradd -r appuser
USER appuser

ENTRYPOINT ["python"]
CMD ["app.py"]
```

Instrucciones clave que suele evaluar el examen:

| Instrucción | Función |
|---|---|
| `FROM` | Imagen base; define el punto de partida y sus capas |
| `RUN` | Ejecuta un comando durante el *build* y persiste el resultado en una nueva capa |
| `COPY` | Copia archivos del contexto de build al filesystem de la imagen |
| `ADD` | Como `COPY`, pero además descomprime tarballs y admite URLs (usar `COPY` salvo que necesites esto) |
| `WORKDIR` | Fija el directorio de trabajo para las instrucciones siguientes |
| `ENV` | Define variables de entorno persistentes en la imagen final |
| `ARG` | Variable disponible solo durante el build (`--build-arg`), no queda en la imagen final |
| `EXPOSE` | Documenta el puerto que expone el contenedor (no lo publica; es metadata) |
| `USER` | Usuario con el que corren las instrucciones siguientes y el contenedor en runtime |
| `ENTRYPOINT` / `CMD` | Definen el proceso principal (ver detalle abajo) |

### `ENTRYPOINT` vs `CMD`

- `ENTRYPOINT` fija el ejecutable; no se sobrescribe fácilmente al correr el contenedor.
- `CMD` provee argumentos por defecto (o el comando completo si no hay `ENTRYPOINT`); **sí** se sobrescribe con argumentos al final de `docker run` o con el campo `args` de un Pod.
- Kubernetes mapea `ENTRYPOINT` → `command` y `CMD` → `args` en el spec del contenedor.

```yaml
# En un Pod, para sobrescribir el CMD de la imagen:
spec:
  containers:
  - name: app
    image: miapp:1.0
    args: ["--debug"]
```

---

## 3. Construir imágenes

### `docker build` / `podman build`

```bash
$ docker build -t miapp:1.0 .
[+] Building 8.2s (10/10) FINISHED
 => [1/5] FROM docker.io/library/python:3.12-slim
 => [2/5] WORKDIR /app
 => [3/5] COPY requirements.txt .
 => [4/5] RUN pip install --no-cache-dir -r requirements.txt
 => [5/5] COPY . .
 => exporting to image
 => => writing image sha256:9f2a1c...
 => => naming to docker.io/library/miapp:1.0
```

`podman build` acepta prácticamente la misma sintaxis y no requiere un daemon corriendo como root (arquitectura *daemonless*), lo que lo hace común en pipelines CI/CD.

### Construir sin Docker daemon: Buildah y Kaniko

Dentro de un clúster de Kubernetes normalmente **no** hay un daemon Docker disponible (y no es recomendable exponerlo). Para construir imágenes desde dentro de un Pod (por ejemplo, en un pipeline CI) se usan herramientas *daemonless* o *rootless*:

- **Buildah**: construye imágenes OCI sin necesitar un daemon; puede correr dentro de un contenedor.
- **Kaniko** (Google): construye imágenes a partir de un Dockerfile dentro de un Pod, sin acceso privilegiado al Docker socket del nodo. Muy usado en runners de CI que corren sobre Kubernetes.

```bash
$ docker run --rm -v "$PWD":/workspace gcr.io/kaniko-project/executor:latest \
    --context=/workspace --dockerfile=/workspace/Dockerfile \
    --destination=registry.example.com/miapp:1.0
```

### `.dockerignore`

Igual que `.gitignore`, evita copiar archivos innecesarios al contexto de build (reduce tamaño y evita filtrar secretos):

```
.git
__pycache__/
*.pyc
.env
```

---

## 4. Tags y digests

```bash
$ docker tag miapp:1.0 registry.example.com/team/miapp:1.0
$ docker tag miapp:1.0 registry.example.com/team/miapp:latest
$ docker push registry.example.com/team/miapp:1.0
```

- `latest` **no** significa "la versión más reciente": es solo el nombre por defecto si no se especifica un tag, y su contenido puede cambiar. En producción y en manifiestos de Kubernetes conviene **evitar `latest`** y fijar versiones explícitas o, para máxima reproducibilidad, el **digest**:

```yaml
spec:
  containers:
  - name: app
    image: registry.example.com/team/miapp@sha256:9f2a1c4b7e...
```

Fijar por digest garantiza que el Pod siempre corre exactamente el mismo binario, sin depender de que un tag mutable no haya sido re-empujado.

---

## 5. Multi-stage builds

Permiten separar el entorno de compilación (con compiladores, herramientas de build) del entorno de ejecución final, reduciendo drásticamente el tamaño de la imagen y su superficie de ataque.

```dockerfile
# Etapa 1: compilar
FROM golang:1.23 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/server .

# Etapa 2: imagen final, mínima
FROM gcr.io/distroless/static-debian12
COPY --from=build /out/server /server
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

```bash
$ docker build -t miapp-go:1.0 .
$ docker images miapp-go:1.0
REPOSITORY   TAG    IMAGE ID      SIZE
miapp-go     1.0    3f8a9d2e1c00  22.4MB
```

Frente a una imagen basada en `golang:1.23` completa (~800MB+), el resultado final es órdenes de magnitud más chico y no incluye compilador, shell ni herramientas que un atacante podría aprovechar.

---

## 6. Modificar imágenes existentes

Hay dos caminos para modificar una imagen:

1. **Editar el Dockerfile y reconstruir** (recomendado): reproducible, versionable en Git, auditable.
2. **`docker commit`**: crea una imagen a partir de los cambios hechos manualmente en un contenedor corriendo. Útil para debugging rápido, pero **no reproducible** ni recomendado para imágenes de producción, porque no queda registro declarativo de qué cambió.

```bash
$ docker run -it --name temp miapp:1.0 sh
# dentro del contenedor: apt-get install -y curl
$ docker commit temp miapp:1.0-debug
$ docker rm temp
```

Para extender una imagen de terceros (por ejemplo, agregar un certificado o una herramienta a una imagen base), la forma correcta es un Dockerfile propio con `FROM` apuntando a esa imagen:

```dockerfile
FROM nginx:1.27
COPY custom.conf /etc/nginx/conf.d/default.conf
COPY ca-cert.pem /usr/local/share/ca-certificates/
RUN update-ca-certificates
```

---

## 7. Usar la imagen en Kubernetes

Una vez publicada la imagen en un registry, se referencia en el Pod:

```bash
$ kubectl run miapp --image=registry.example.com/team/miapp:1.0 --restart=Never
pod/miapp created

$ kubectl get pod miapp -o jsonpath='{.spec.containers[0].image}'
registry.example.com/team/miapp:1.0
```

### `imagePullPolicy`

| Valor | Comportamiento |
|---|---|
| `IfNotPresent` | Usa la imagen local si ya existe; si no, la descarga. Default cuando el tag **no** es `latest`. |
| `Always` | Siempre consulta el registry (aunque exista localmente). Default cuando el tag es `latest` u omitido. |
| `Never` | Nunca descarga; falla si la imagen no está ya en el nodo. Útil en clústeres locales de desarrollo. |

```yaml
spec:
  containers:
  - name: app
    image: miapp:1.0
    imagePullPolicy: IfNotPresent
```

### Cargar imágenes locales en clústeres de desarrollo

Al practicar para el examen (kind, minikube) suele hacer falta subir una imagen construida localmente sin pasar por un registry externo:

```bash
$ kind load docker-image miapp:1.0 --name mi-cluster

$ minikube image load miapp:1.0
```

---

## 8. Buenas prácticas y seguridad de imágenes

- **Imágenes base mínimas**: `alpine`, `-slim` o `distroless` reducen tamaño y vulnerabilidades.
- **No correr como root**: usar `USER` en el Dockerfile o `securityContext.runAsNonRoot` en el Pod.
- **Un proceso por contenedor**, capas ordenadas de menos a más cambiantes para maximizar el cache de build.
- **No incluir secretos** en capas de la imagen (ni siquiera si se borran después: quedan en capas anteriores del historial). Usar `--secret` de BuildKit o Secrets de Kubernetes en runtime.
- **Escanear imágenes** antes de publicarlas (`trivy image miapp:1.0`, `grype`) para detectar CVEs conocidas.
- **Fijar versiones** de la imagen base y de dependencias para builds reproducibles.

```bash
$ trivy image miapp:1.0
miapp:1.0 (debian 12.5)
Total: 3 (HIGH: 2, CRITICAL: 1)
```

---

## Resumen para el examen

- Las imágenes siguen el estándar **OCI**: capas + manifest, identificadas de forma inmutable por **digest**; los **tags** son punteros mutables.
- El **Dockerfile** define la construcción; distinguir bien `ENTRYPOINT` (→ `command` en el Pod) de `CMD` (→ `args`).
- Construir con `docker build` / `podman build`; dentro de clústeres, sin daemon Docker, se usa **Buildah** o **Kaniko**.
- **Multi-stage builds** separan compilación de runtime y reducen tamaño y superficie de ataque.
- Modificar imágenes: siempre vía Dockerfile + rebuild, nunca `docker commit` en producción.
- En el Pod: `spec.containers[].image` y `imagePullPolicy` (`Always`, `IfNotPresent`, `Never`); para desarrollo local, `kind load docker-image` / `minikube image load`.
- Buenas prácticas: imágenes mínimas, usuario no root, sin secretos embebidos, escaneo de vulnerabilidades.

---

## Referencias

- Kubernetes — Images: https://kubernetes.io/docs/concepts/containers/images/
- Kubernetes — Containers: https://kubernetes.io/docs/concepts/containers/
- Docker — Dockerfile reference: https://docs.docker.com/reference/dockerfile/
- Docker — Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Docker — Best practices for building images: https://docs.docker.com/build/building/best-practices/
- OCI Image Format Specification: https://github.com/opencontainers/image-spec
- Buildah: https://buildah.io/
- Kaniko: https://github.com/GoogleContainerTools/kaniko
- kind — Loading an image into your cluster: https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster
- minikube — Pushing images: https://minikube.sigs.k8s.io/docs/handbook/pushing/
- Trivy — Vulnerability scanner: https://trivy.dev/
- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf