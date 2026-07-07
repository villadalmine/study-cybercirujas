#!/usr/bin/env bash
#
# ==============================================================================
#  LAB "BREAK & FIX" — LPI Linux Essentials (010-160 v1.6)
#  Tema 4.2: Understanding Computer Hardware (peso: 2)
#
#  Escenario: "La memoria virtual desapareció"
#
#  Conceptos que practica este lab:
#    - RAM y swap como parte de la jerarquía de memoria del sistema
#    - Dispositivos de almacenamiento y particiones (lsblk, blkid, /dev)
#    - Inspección de hardware y memoria (free, /proc/meminfo, swapon)
#    - El archivo /etc/fstab y la activación de dispositivos al arranque
#
#  Referencia consultada (no se copia texto literal):
#    https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
#
#  ADVERTENCIA: ejecutá este script SOLO en una VM de laboratorio descartable,
#  con snapshot previo. Requiere root. NO lo corras en una máquina real.
#
#  Uso:
#    sudo ./lab42_break_fix.sh          -> rompe el escenario y explica
#    sudo ./lab42_break_fix.sh check    -> verifica si ya lo arreglaste
# ==============================================================================

set -u

LAB_DIR="/root/.lab42-hardware"
FSTAB="/etc/fstab"
SWAPFILE_LAB="/lab42-swapfile"

# ------------------------------------------------------------------------------
# Verificaciones de seguridad básicas
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este lab necesita root. Ejecutalo con: sudo $0" >&2
    exit 1
fi

if [[ ! -e /dev/vda && ! -e /dev/sda && ! -d /proc/vz && ! -e /sys/hypervisor ]]; then
    echo "AVISO: no puedo confirmar que esto sea una VM."
    echo "Este lab modifica swap y /etc/fstab. Continuá solo si es una VM descartable."
    read -r -p "¿Es una VM de laboratorio descartable? (escribí SI): " RESP
    [[ "$RESP" == "SI" ]] || { echo "Abortado. Buena decisión."; exit 1; }
fi

# ------------------------------------------------------------------------------
# Modo "check": verificar si el estudiante ya resolvió el escenario
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "check" ]]; then
    echo "=== Verificando el estado del swap ==="
    if swapon --show | grep -q .; then
        echo "[OK] Hay swap activo:"
        swapon --show
        echo
        free -h
        echo
        if swapoff -a 2>/dev/null && swapon -a 2>/dev/null && swapon --show | grep -q .; then
            echo "[OK] El swap también se activa correctamente desde /etc/fstab."
            echo
            echo "*** ¡ESCENARIO RESUELTO! Felicitaciones. ***"
        else
            echo "[FALTA] El swap estaba activo, pero 'swapon -a' falla."
            echo "        Revisá que la entrada en /etc/fstab apunte al dispositivo"
            echo "        o UUID correcto (compará con la salida de 'blkid')."
        fi
    else
        echo "[FALTA] No hay swap activo. Seguí trabajando:"
        echo "        pistas: free -h, swapon --show, lsblk, blkid, mkswap, /etc/fstab"
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# Evitar romper dos veces
# ------------------------------------------------------------------------------
if [[ -f "$LAB_DIR/fstab.bak" ]]; then
    echo "El escenario ya fue preparado antes (existe $LAB_DIR/fstab.bak)."
    echo "Si querés reiniciarlo, restaurá primero el snapshot de la VM."
    exit 1
fi

mkdir -p "$LAB_DIR"
chmod 700 "$LAB_DIR"

# ------------------------------------------------------------------------------
# Preparación: si la VM no tiene swap, creamos uno de laboratorio para
# poder romperlo (así el escenario funciona en cualquier VM).
# ------------------------------------------------------------------------------
cp -a "$FSTAB" "$LAB_DIR/fstab.bak"

SWAP_DEVICES=$(swapon --show=NAME --noheadings 2>/dev/null)

if [[ -z "$SWAP_DEVICES" ]]; then
    echo "[lab] Esta VM no tiene swap: creando un swap file de laboratorio..."
    dd if=/dev/zero of="$SWAPFILE_LAB" bs=1M count=256 status=none
    chmod 600 "$SWAPFILE_LAB"
    mkswap "$SWAPFILE_LAB" >/dev/null
    echo "$SWAPFILE_LAB none swap sw 0 0" >> "$FSTAB"
    swapon "$SWAPFILE_LAB"
    SWAP_DEVICES="$SWAPFILE_LAB"
    # actualizamos el backup para que refleje el estado "sano" con swap
    cp -a "$FSTAB" "$LAB_DIR/fstab.bak"
fi

echo "$SWAP_DEVICES" > "$LAB_DIR/swap_targets.txt"

# ------------------------------------------------------------------------------
# LA ROTURA (controlada y reversible):
#   1. Desactivamos todo el swap (swapoff -a).
#   2. Destruimos la firma (signature) de swap del dispositivo/archivo,
#      sobrescribiendo solo su cabecera. Los datos del resto del disco
#      NO se tocan.
#   3. Corrompemos la entrada de swap en /etc/fstab apuntándola a un
#      UUID inexistente.
# ------------------------------------------------------------------------------
echo "[lab] Desactivando y rompiendo el swap de forma controlada..."
swapoff -a

while read -r DEV; do
    [[ -n "$DEV" ]] || continue
    # Borra únicamente la cabecera/firma de swap (primeros 4 KiB).
    dd if=/dev/zero of="$DEV" bs=4096 count=1 conv=notrunc status=none
done < "$LAB_DIR/swap_targets.txt"

# Reemplaza la línea de swap en fstab por una entrada con UUID falso
sed -i.lab42tmp -E \
    's|^[^#].*\bswap\b.*|UUID=00000000-dead-beef-0000-000000000000 none swap sw 0 0|' \
    "$FSTAB"
rm -f "${FSTAB}.lab42tmp"

# ------------------------------------------------------------------------------
# Briefing para el estudiante
# ------------------------------------------------------------------------------
cat <<'EOF'

================================================================================
 ESCENARIO ROTO — "La memoria virtual desapareció"
================================================================================

 CONTEXTO
   Un compañero de soporte "optimizó" el servidor anoche. Esta mañana, las
   aplicaciones se quedan sin memoria bajo carga y el monitoreo alerta que
   el sistema no tiene swap disponible.

 SÍNTOMAS QUE VAS A VER
   - 'free -h' muestra la fila Swap en 0B (total, used y free).
   - 'swapon --show' no devuelve nada.
   - 'swapon -a' falla: no encuentra el UUID declarado en /etc/fstab,
     y aunque corrijas el dispositivo, se queja de que no hay una
     firma (signature) de swap válida.
   - En /proc/meminfo, SwapTotal es 0 kB.

 TU MISIÓN
   1. Diagnosticar por qué no hay swap, usando las herramientas de
      inspección de hardware y memoria del tema 4.2:
         free -h, /proc/meminfo, swapon --show, lsblk, blkid
   2. Identificar el dispositivo (o archivo) que debería ser el swap.
   3. Recrear la firma de swap y corregir /etc/fstab para que el swap
      se active solo con 'swapon -a' (y en cada arranque).

 CRITERIO DE ÉXITO
   sudo ./lab42_break_fix.sh check   ->  "ESCENARIO RESUELTO"

 PISTAS
   - 'lsblk' te muestra los discos y particiones; 'blkid' muestra qué
     filesystem o firma tiene cada uno... y cuál NO tiene ninguna.
   - El comando que escribe una firma de swap nueva empieza con 'mk'.
   - El dispositivo roto quedó anotado en /root/.lab42-hardware/swap_targets.txt
     (miralo solo si estás trabado).

================================================================================
EOF

exit 0

# ==============================================================================
#  SOLUCIÓN PASO A PASO (no leer hasta intentarlo)
# ==============================================================================
#
# 1. Confirmar el síntoma: no hay swap activo.
#       free -h                      # fila Swap: 0B
#       swapon --show                # sin salida
#       grep SwapTotal /proc/meminfo # SwapTotal: 0 kB
#
# 2. Ver qué dice /etc/fstab sobre el swap:
#       grep swap /etc/fstab
#    Vas a encontrar una entrada con un UUID sospechoso:
#       UUID=00000000-dead-beef-0000-000000000000 none swap sw 0 0
#    Ese UUID no existe en el sistema (verificalo con 'blkid': ningún
#    dispositivo lo tiene).
#
# 3. Identificar cuál era el dispositivo/archivo de swap real:
#       lsblk -f        # buscá una partición sin FSTYPE (firma borrada)
#       blkid           # el dispositivo roto no aparece o aparece sin TYPE
#    Si el lab creó un swap file, el candidato es /lab42-swapfile
#    (un archivo de 256M en la raíz; 'ls -lh /lab42-swapfile').
#    Confirmación (si hace falta): cat /root/.lab42-hardware/swap_targets.txt
#
# 4. Recrear la firma de swap en el dispositivo o archivo:
#       sudo mkswap /dev/vdaN            # si era una partición, o bien:
#       sudo chmod 600 /lab42-swapfile
#       sudo mkswap /lab42-swapfile      # si era un swap file
#    mkswap imprime el UUID nuevo de la firma creada.
#
# 5. Corregir /etc/fstab. Dos opciones válidas:
#    a) Usar el UUID nuevo que imprimió mkswap (solo para particiones):
#       UUID=<uuid-nuevo> none swap sw 0 0
#    b) Usar la ruta directa (obligatorio si es un swap file):
#       /lab42-swapfile none swap sw 0 0
#    Editá con: sudoedit /etc/fstab  (o sudo nano /etc/fstab)
#
# 6. Activar el swap desde fstab y verificar:
#       sudo swapon -a
#       swapon --show     # debe listar el dispositivo/archivo
#       free -h           # la fila Swap ya no está en 0B
#
# 7. Validar el escenario:
#       sudo ./lab42_break_fix.sh check
#
# 8. (Opcional) Si te trabaste con fstab, hay un backup íntegro en:
#       /root/.lab42-hardware/fstab.bak
#    Restaurarlo también cuenta como solución para el paso 5, pero
#    igual tenés que ejecutar mkswap (paso 4): el backup arregla la
#    configuración, no la firma borrada del dispositivo.
#
# QUÉ TE LLEVÁS DE ESTE LAB (tema 4.2)
#   - El swap extiende la RAM usando almacenamiento en disco: es el punto
#     donde se cruzan memoria y storage en la jerarquía de hardware.
#   - free y /proc/meminfo son las vistas estándar del estado de la memoria.
#   - lsblk y blkid permiten inspeccionar discos, particiones y sus firmas.
#   - /etc/fstab define qué se monta/activa al arranque; un UUID incorrecto
#     ahí produce fallas silenciosas de hardware "que no aparece".
#   - Referencia: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
# ==============================================================================