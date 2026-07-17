#!/usr/bin/env bash
#
# CKS v1.34 - Supply Chain Security
# Tema 4.1: Minimize base image footprint (peso en el examen: 5)
# Fuente: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
#
# Script "break & fix" para una VM de laboratorio DESCARTABLE.
# Instala Docker si falta, construye una imagen deliberadamente "bloated"
# (con toolchain de build, shell y herramientas de red dentro del runtime)
# y la deja corriendo como contenedor. El estudiante debe reconstruirla
# minimizando el footprint (multi-stage build + base minimal + non-root).
#
# NO ejecutar en un host que no sea descartable.

set -euo pipefail

LAB_DIR="${HOME}/cks-lab-4.1"
DOCKERFILE_BLOATED="Dockerfile.bloated"
IMAGE_BLOATED="webapp:bloated"
CONTAINER_NAME="cks-webapp"

echo "=================================================================="
echo " CKS 4.1 - Minimize base image footprint - LAB DESTRUCTIVO/DESCARTABLE"
echo "=================================================================="
echo "Este script instala Docker (si falta), construye una imagen y corre"
echo "un contenedor en este host. Pensado solo para una VM de lab descartable."
read -r -p "Continuar? [y/N] " ans
[[ "${ans:-}" =~ ^[Yy]$ ]] || { echo "Abortado."; exit 1; }

# ---------------------------------------------------------------------------
# 1. Asegurar Docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "[*] Docker no encontrado, instalando..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y docker.io
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y moby-engine || sudo dnf install -y docker
  else
    echo "No se detectó apt-get ni dnf. Instalá Docker manualmente y reintentá." >&2
    exit 1
  fi
  sudo systemctl enable --now docker
fi

if docker info >/dev/null 2>&1; then
  SUDO=""
else
  SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# 2. Limpieza de corridas previas (idempotencia)
# ---------------------------------------------------------------------------
$SUDO docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Preparar el "break": una app trivial en Go, construida y corrida
#    dentro de una imagen base completa (ubuntu:22.04) con toda la
#    toolchain de build + shell + gestor de paquetes + herramientas de
#    red dejadas en el runtime final. Esto es el anti-patrón que hay
#    que corregir.
# ---------------------------------------------------------------------------
mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

cat > app.go <<'EOF'
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "OK - cks-lab webapp")
	})
	http.ListenAndServe(":8080", nil)
}
EOF

cat > "$DOCKERFILE_BLOATED" <<'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    golang-go gcc curl wget netcat-openbsd vim openssh-server ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY app.go .
RUN go build -o webapp app.go
EXPOSE 8080
CMD ["./webapp"]
EOF

echo "[*] Construyendo imagen bloated (puede tardar, descarga ubuntu + toolchain de Go)..."
$SUDO docker build -t "$IMAGE_BLOATED" -f "$DOCKERFILE_BLOATED" .

echo "[*] Levantando contenedor $CONTAINER_NAME..."
$SUDO docker run -d --name "$CONTAINER_NAME" -p 8080:8080 "$IMAGE_BLOATED" >/dev/null

# ---------------------------------------------------------------------------
# 4. Mostrar el síntoma y el objetivo al estudiante
# ---------------------------------------------------------------------------
SIZE=$($SUDO docker images "$IMAGE_BLOATED" --format '{{.Size}}')

cat <<EOF

------------------------------------------------------------------
SÍNTOMA
------------------------------------------------------------------
La app "$CONTAINER_NAME" está corriendo en http://localhost:8080
y responde OK, así que "funciona". El problema NO es funcional:
es de superficie de ataque (attack surface) en la imagen misma.

Corré esto para ver el problema:

  docker images $IMAGE_BLOATED
  docker exec $CONTAINER_NAME id
  docker exec $CONTAINER_NAME sh -c 'which bash curl wget nc gcc apt-get sshd'
  docker exec $CONTAINER_NAME find / -xdev -perm -4000 -type f 2>/dev/null

Vas a ver:
  - Tamaño de imagen: $SIZE (una app "hello world" no debería pesar esto).
  - El proceso corre como root (uid 0) dentro del contenedor.
  - bash, curl, wget, nc, gcc, apt-get y sshd están todos disponibles:
    cualquier RCE mínimo en la app le da a un atacante shell completa,
    gestor de paquetes para bajar más herramientas, compilador, y
    utilidades de red para pivoting/exfiltración.
  - Hay binarios setuid heredados de la base ubuntu completa.

Esta imagen jamás debería llegar a producción así.

------------------------------------------------------------------
OBJETIVO
------------------------------------------------------------------
Reconstruí "$IMAGE_BLOATED" como una imagen "webapp:fixed" que:
  1. Use multi-stage build: el compilador de Go y sus dependencias
     quedan SOLO en el stage de build, nunca en el runtime final.
  2. Use una base minimal para el runtime (distroless/static o
     scratch), sin shell, sin gestor de paquetes, sin compilador.
  3. Corra como usuario non-root.
  4. Reduzca drásticamente el tamaño (de cientos de MB a menos de
     ~20MB).

Vas a saber que lo lograste cuando:

  docker images webapp:fixed
      -> tamaño << $SIZE

  docker exec -it webapp-fixed sh
      -> falla porque no hay shell en la imagen

  docker inspect --format='{{.Config.User}}' webapp:fixed
      -> devuelve un usuario non-root (no vacío, no "root")

  curl http://localhost:8081/
      -> sigue respondiendo "OK - cks-lab webapp"

Archivos de trabajo en: $LAB_DIR
(el Dockerfile "bloated" ya está ahí como referencia de lo que NO hacer)
------------------------------------------------------------------
EOF

# ---------------------------------------------------------------------------
# SOLUCIÓN (spoiler - no ejecutar hasta intentarlo)
# ---------------------------------------------------------------------------
#
# 1) Crear Dockerfile.fixed con multi-stage build:
#
#    cat > Dockerfile.fixed <<'EOF'
#    FROM golang:1.22-alpine AS builder
#    WORKDIR /src
#    COPY app.go .
#    RUN CGO_ENABLED=0 GOOS=linux go build -o /out/webapp app.go
#
#    FROM gcr.io/distroless/static-debian12:nonroot
#    COPY --from=builder /out/webapp /webapp
#    USER nonroot:nonroot
#    EXPOSE 8080
#    ENTRYPOINT ["/webapp"]
#    EOF
#
#    (alternativa aún más chica: "FROM scratch" en vez de distroless,
#    pero perdés CA certs/tzdata/passwd nonroot ya resueltos por distroless)
#
# 2) Construir y correr la versión fija en otro puerto para comparar:
#
#    docker build -t webapp:fixed -f Dockerfile.fixed .
#    docker run -d --name cks-webapp-fixed -p 8081:8080 webapp:fixed
#
# 3) Verificar la reducción de footprint:
#
#    docker images | grep webapp
#      -> webapp:bloated  ~700MB-900MB
#      -> webapp:fixed    ~8MB-15MB
#
#    docker exec -it cks-webapp-fixed sh
#      -> "OCI runtime exec failed... exec: sh: executable file not found"
#         (no hay shell: no hay superficie para un atacante que logre RCE)
#
#    docker inspect --format='{{.Config.User}}' webapp:fixed
#      -> nonroot:nonroot
#
#    curl http://localhost:8081/
#      -> OK - cks-lab webapp
#
#    docker history webapp:fixed
#      -> una sola capa relevante: el binario estático copiado, sin capas
#         de apt-get/build tools
#
# 4) Limpieza del lab:
#
#    docker rm -f cks-webapp cks-webapp-fixed
#    docker rmi webapp:bloated webapp:fixed
#    rm -rf "$LAB_DIR"