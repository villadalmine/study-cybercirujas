#!/usr/bin/env bash
# study-lab template (linux). Contract: break | verify | cleanup.
#   break   leaves the system broken on purpose and explains the symptom
#   verify  exit 0 ONLY when the student fixed it, non-zero otherwise
#   cleanup removes everything break created (idempotent)
# Example scenario: a config file nobody can read. Replace it.
set -euo pipefail
FILE="/srv/__NS__/app.conf"

case "${1:-break}" in
  break)
    mkdir -p "$(dirname "$FILE")"
    echo "port=8080" > "$FILE"
    chmod 000 "$FILE"
    echo "ROTO: la app no puede leer $FILE. Dejalo legible para todos (644) sin perder su contenido."
    ;;
  verify)
    if [[ "$(stat -c %a "$FILE" 2>/dev/null)" == "644" ]] && grep -q '^port=8080$' "$FILE"; then
      echo "OK: $FILE legible y con su contenido"; exit 0
    fi
    echo "Todavía no: $FILE no es 644 o perdió su contenido"; exit 1
    ;;
  cleanup)
    rm -rf "$(dirname "$FILE")"
    echo "limpio"
    ;;
  *) echo "uso: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac
# SOLUCIÓN (no se ejecuta): chmod 644 /srv/__NS__/app.conf
