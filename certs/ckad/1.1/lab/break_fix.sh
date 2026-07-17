#!/usr/bin/env bash
#
# CKAD v1.35 - Tema 1.1: Define, build and modify container images (peso: 5)
# Fuente de referencia: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
#
# Laboratorio "break & fix" pensado para correr en una VM de laboratorio DESCARTABLE.
# Todo lo que este script toca vive dentro de $LAB_DIR (por defecto bajo $HOME) y en
# una imagen de contenedor con tag propio: no borra ni modifica nada fuera de eso.
#
# Uso:
#   ./ckad-1.1-break-fix.sh break    -> rompe el laboratorio (deja el síntoma listo)
#   ./ckad-1.1-break-fix.sh check    -> valida si ya arreglaste el problema
#   ./ckad-1.1-break-fix.sh reset    -> reconstruye el laboratorio en estado sano (para repetir el ejercicio)
#   ./ckad-1.1-break-fix.sh cleanup  -> borra la imagen y el directorio de laboratorio
#
# Requisitos: docker o podman instalados en la VM.

set -uo pipefail

LAB_DIR="${LAB_DIR:-$HOME/ckad-lab/1.1-images}"
IMAGE_NAME="ckad-1-1-lab"
IMAGE_TAG="lab"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

if command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
elif command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
else
  echo "ERROR: necesitás 'docker' o 'podman' instalado en esta VM de laboratorio." >&2
  exit 1
fi

write_healthy_files() {
  mkdir -p "$LAB_DIR"

  cat > "$LAB_DIR/greet.sh" <<'EOF'
#!/bin/sh
echo "Hello from the CKAD image lab, build number: ${BUILD_ID:-unknown}"
EOF
  chmod +x "$LAB_DIR/greet.sh"

  cat > "$LAB_DIR/Dockerfile" <<'EOF'
FROM alpine:3.19 AS builder
WORKDIR /src
COPY greet.sh .
RUN chmod +x greet.sh

FROM alpine:3.19
COPY --from=builder /src/greet.sh /usr/local/bin/greet.sh
ENV BUILD_ID=42
ENTRYPOINT ["/usr/local/bin/greet.sh"]
EOF
}

scaffold_lab() {
  if [ ! -f "$LAB_DIR/Dockerfile" ]; then
    echo ">> Creando laboratorio en $LAB_DIR ..."
  fi
  write_healthy_files
}

break_lab() {
  scaffold_lab

  # Rompe el laboratorio introduciendo un desajuste de path entre el destino
  # del COPY --from=builder y el path que espera el ENTRYPOINT. Es un error
  # muy real: pasa seguido al modificar un Dockerfile multi-stage y renombrar
  # o mover un archivo en una sola de las dos líneas.
  sed -i '/^COPY --from=builder/ s#/usr/local/bin/greet\.sh#/usr/local/bin/greeting.sh#' "$LAB_DIR/Dockerfile"

  cat <<'MSG'

=== LABORATORIO ROTO: CKAD 1.1 - Define, build and modify container images ===

Directorio de trabajo: LAB_DIR (ver variable al inicio del script)
Archivo modificado: Dockerfile

Contexto:
Tenés un Dockerfile multi-stage que compila/prepara un script en un stage
"builder" y después lo copia al stage final para armar la imagen runtime.
Alguien "modificó" el Dockerfile y ahora algo no cierra.

Síntoma que vas a observar:
  1. La imagen construye SIN errores.
  2. Al correr el contenedor, falla al arrancar (no llega a imprimir nada
     de la aplicación).

Tu objetivo:
  - Buildear la imagen:
      docker build -t ckad-1-1-lab:lab .      (o podman build ...)
  - Correr el contenedor y observar el error exacto:
      docker run --rm ckad-1-1-lab:lab
  - Inspeccionar el Dockerfile y el filesystem de la imagen para entender
    por qué el binario que el ENTRYPOINT quiere ejecutar no está donde
    él espera.
  - Corregir el Dockerfile para que el path que usa COPY y el path que usa
    ENTRYPOINT coincidan.
  - Reconstruir la imagen y confirmar que el contenedor corre y muestra:
      "Hello from the CKAD image lab, build number: 42"

Cuando creas que lo arreglaste, corré:
  ./ckad-1.1-break-fix.sh check

MSG
}

check_lab() {
  if [ ! -f "$LAB_DIR/Dockerfile" ]; then
    echo "No hay laboratorio en $LAB_DIR. Corré primero: $0 break"
    exit 1
  fi

  echo ">> Buildeando imagen desde $LAB_DIR ..."
  build_output=$("$ENGINE" build -t "$FULL_IMAGE" "$LAB_DIR" 2>&1)
  build_rc=$?
  if [ $build_rc -ne 0 ]; then
    echo "TODAVIA NO: el build de la imagen falló."
    echo "--- output del build ---"
    echo "$build_output"
    exit 1
  fi

  echo ">> Corriendo el contenedor ..."
  run_output=$("$ENGINE" run --rm "$FULL_IMAGE" 2>&1)
  run_rc=$?

  if [ $run_rc -ne 0 ]; then
    echo "TODAVIA NO: el contenedor no arrancó correctamente."
    echo "--- output del run (exit code $run_rc) ---"
    echo "$run_output"
    exit 1
  fi

  if echo "$run_output" | grep -q "Hello from the CKAD image lab, build number: 42"; then
    echo "RESUELTO: la imagen buildea y el contenedor corre mostrando el mensaje esperado."
  else
    echo "TODAVIA NO: el contenedor corrió pero el output no es el esperado."
    echo "--- output obtenido ---"
    echo "$run_output"
    exit 1
  fi
}

reset_lab() {
  echo ">> Reconstruyendo el laboratorio en estado sano en $LAB_DIR ..."
  write_healthy_files
  "$ENGINE" rmi "$FULL_IMAGE" >/dev/null 2>&1 || true
  echo ">> Listo. Corré '$0 break' para volver a romperlo."
}

cleanup_lab() {
  echo ">> Borrando imagen $FULL_IMAGE y directorio $LAB_DIR ..."
  "$ENGINE" rmi "$FULL_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  echo ">> Limpieza completa."
}

usage() {
  cat <<EOF
Uso: $0 {break|check|reset|cleanup}
EOF
}

case "${1:-}" in
  break)   break_lab ;;
  check)   check_lab ;;
  reset)   reset_lab ;;
  cleanup) cleanup_lab ;;
  *)       usage; exit 1 ;;
esac

# =============================================================================
# SOLUCION PASO A PASO (comentada - no se ejecuta)
# =============================================================================
#
# 1. Mirar el Dockerfile roto:
#      cat $LAB_DIR/Dockerfile
#
#    Vas a ver algo como:
#      FROM alpine:3.19 AS builder
#      WORKDIR /src
#      COPY greet.sh .
#      RUN chmod +x greet.sh
#
#      FROM alpine:3.19
#      COPY --from=builder /src/greet.sh /usr/local/bin/greeting.sh
#      ENV BUILD_ID=42
#      ENTRYPOINT ["/usr/local/bin/greet.sh"]
#
# 2. Diagnóstico: el build de una imagen multi-stage NO valida que los paths
#    entre stages/instrucciones sean consistentes entre sí. El COPY --from=builder
#    deja el archivo en /usr/local/bin/greeting.sh (con "ing"), pero el
#    ENTRYPOINT intenta ejecutar /usr/local/bin/greet.sh, que no existe en la
#    imagen final. Por eso el build es exitoso pero el runtime falla.
#
# 3. Confirmarlo corriendo el contenedor con el ENTRYPOINT reemplazado por un
#    shell, para inspeccionar el filesystem de la imagen final:
#      docker run --rm --entrypoint sh ckad-1-1-lab:lab -c "ls -la /usr/local/bin"
#    Esto muestra "greeting.sh" en vez de "greet.sh", confirmando el desajuste.
#
# 4. Arreglar el Dockerfile haciendo que ambos paths coincidan. Cualquiera de
#    las dos opciones es una solución válida:
#      a) Corregir el destino del COPY para que coincida con el ENTRYPOINT:
#           COPY --from=builder /src/greet.sh /usr/local/bin/greet.sh
#      b) O corregir el ENTRYPOINT para que apunte al nombre real copiado:
#           ENTRYPOINT ["/usr/local/bin/greeting.sh"]
#
# 5. Reconstruir la imagen:
#      docker build -t ckad-1-1-lab:lab $LAB_DIR
#
# 6. Correr el contenedor y confirmar el mensaje esperado:
#      docker run --rm ckad-1-1-lab:lab
#      -> "Hello from the CKAD image lab, build number: 42"
#
# 7. Validar automáticamente:
#      ./ckad-1.1-break-fix.sh check
#
# =============================================================================