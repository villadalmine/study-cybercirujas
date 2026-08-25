# LPIC-3 303 (303-300 v3.0.0) — Tema 332.1: Endurecimiento del Host
## Ejercicios Guiados

> **Peso del examen:** 8.33 — uno de los objetivos individuales más pesados de la especialidad de Seguridad.
> **Fuente del objetivo:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

---

### Prerrequisitos del laboratorio y aviso de seguridad

Cada ejercicio de abajo modifica la configuración de arranque, el estado del kernel en tiempo de ejecución, el aislamiento de servicios o la política de autorización. Varios de ellos **pueden dejarte fuera de la máquina**.

| Requisito | Por qué |
|---|---|
| Una VM descartable (Debian 12/13 o RHEL 9/Rocky 9), **no** una estación de trabajo | Las contraseñas de GRUB, USBGuard y los límites de `nproc` son todos vectores de bloqueo |
| Un snapshot tomado *antes* del Ejercicio 3 | Los errores del cargador de arranque solo se recuperan desde un medio de rescate |
| Acceso a consola (virt-manager, `virsh console`, IPMI, serie) — no solo SSH | Vas a romper deliberadamente rutas de inicio de sesión interactivo |
| `sudo`/root, y una segunda sesión de root abierta | Práctica estándar al editar PAM, polkit o limits |
| ~4 GB de RAM, 2 vCPU, una cadena de herramientas `gcc`, y un dispositivo USB de repuesto si tenés passthrough | El Ejercicio 5 compila binarios; el Ejercicio 8 necesita un evento de conexión en caliente |

Instalá el conjunto de herramientas una sola vez:

```bash
# Debian / Ubuntu
sudo apt update
sudo apt install -y build-essential binutils checksec policykit-1 usbguard \
                    libcap2-bin lsof procps util-linux devscripts

# RHEL / Rocky / AlmaLinux 9
sudo dnf install -y gcc binutils checksec polkit usbguard libcap procps-ng \
                    lsof util-linux
```

Las diferencias entre distribuciones se señalan sobre la marcha; el examen es neutral respecto de la distribución, así que se espera que reconozcas ambas familias.

---

## Ejercicio 1 — Establecer una línea base: medir la superficie de ataque antes de tocar nada

Endurecer sin una línea base es adivinar. No podés probar que un servicio fue eliminado si nunca probaste que estaba corriendo.

### Pasos

1. Creá un directorio de trabajo para la evidencia que vas a recolectar a lo largo de este laboratorio:

   ```bash
   sudo install -d -m 0700 /root/hardening-lab
   cd /root/hardening-lab
   ```

2. Capturá cada archivo de unidad que esté *habilitado* (arrancará en el próximo booteo), no simplemente el que corre ahora:

   ```bash
   systemctl list-unit-files --state=enabled --no-pager > 01-enabled-units.txt
   wc -l 01-enabled-units.txt
   ```

   Salida ilustrativa:

   ```
   UNIT FILE                              STATE   PRESET
   auditd.service                         enabled enabled
   chronyd.service                        enabled enabled
   cups.path                              enabled enabled
   cups.service                           enabled enabled
   cups.socket                            enabled enabled
   sshd.service                           enabled enabled
   ...
   ```

3. Capturá lo que está corriendo realmente en este momento:

   ```bash
   systemctl list-units --type=service --state=running --no-pager > 02-running-services.txt
   ```

4. Capturá cada socket a la escucha junto con el proceso que lo posee:

   ```bash
   sudo ss -tulpnH | sort -k1,1 -k5,5 > 03-listeners.txt
   cat 03-listeners.txt
   ```

   Salida ilustrativa:

   ```
   tcp   LISTEN 0 128    0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=812,fd=3))
   tcp   LISTEN 0 4096   127.0.0.1:631 0.0.0.0:*  users:(("cupsd",pid=744,fd=7))
   udp   UNCONN 0 0      0.0.0.0:5353  0.0.0.0:*  users:(("avahi-daemon",pid=701,fd=12))
   ```

5. Mapeá cada socket a la escucha de vuelta al paquete que posee el binario — este es el paso que convierte "deshabilitar" en "eliminar":

   ```bash
   # Debian
   for p in $(sudo ss -tulpnH | grep -oP '(?<=users:\(\(")[^"]+' | sort -u); do
       printf '%-16s %s\n' "$p" "$(dpkg -S "$(command -v "$p" 2>/dev/null)" 2>/dev/null || echo '?')"
   done

   # RHEL
   for p in $(sudo ss -tulpnH | grep -oP '(?<=users:\(\(")[^"]+' | sort -u); do
       printf '%-16s %s\n' "$p" "$(rpm -qf "$(command -v "$p" 2>/dev/null)" 2>/dev/null || echo '?')"
   done
   ```

6. Registrá el costo de arranque de cada unidad — una aproximación burda a "cuánto está haciendo esta máquina que nadie pidió":

   ```bash
   systemd-analyze blame --no-pager | head -20 > 04-blame.txt
   systemd-analyze critical-chain --no-pager > 05-critical-chain.txt
   ```

7. Tomá la línea base de seguridad contra la que se medirá el Ejercicio 6:

   ```bash
   systemd-analyze security --no-pager > 06-security-baseline.txt
   head -12 06-security-baseline.txt
   ```

   Salida ilustrativa:

   ```
   UNIT                          EXPOSURE PREDICATE HAPPY
   dbus.service                       9.5 UNSAFE    😨
   NetworkManager.service             7.6 EXPOSED   🙁
   sshd.service                       9.6 UNSAFE    😨
   systemd-udevd.service              6.6 MEDIUM    😐
   systemd-logind.service             2.8 OK        🙂
   ```

**Comprobá tu comprensión**

- **Q1.1** — `systemctl list-units --state=running` no muestra `cups.service`, y sin embargo `systemctl list-unit-files --state=enabled` muestra `cups.socket` como habilitado. ¿La superficie de ataque de CUPS está presente o ausente? Justificá.
- **Q1.2** — ¿Por qué `ss -tulpn` es una medición más débil de la superficie de ataque que la lista de unidades habilitadas, y por qué la lista de unidades habilitadas es más débil que la lista de paquetes instalados?
- **Q1.3** — En la salida de `systemd-analyze security`, ¿un número de exposición *más alto* es mejor o peor, y cuál es el rango numérico?
- **Q1.4** — Nombrá dos categorías de superficie de ataque alcanzable localmente que `ss -tulpn` nunca te va a mostrar.

---

## Ejercicio 2 — Deshabilitar, enmascarar y eliminar software y servicios sin uso

### Pasos

1. Elegí un servicio genuinamente innecesario para un servidor. En una instalación fresca con sabor de escritorio, `cups` y `avahi-daemon` son el par clásico. Inspeccioná en qué consiste realmente CUPS:

   ```bash
   systemctl list-unit-files --no-pager | grep -E '^cups'
   ```

   ```
   cups.path       enabled  enabled
   cups.service    enabled  enabled
   cups.socket     enabled  enabled
   cups-browsed.service enabled enabled
   ```

2. Detené y deshabilitá **todas** las unidades de activación, no solo el servicio:

   ```bash
   sudo systemctl disable --now cups.service cups.socket cups.path cups-browsed.service
   ```

   ```
   Removed "/etc/systemd/system/multi-user.target.wants/cups.service".
   Removed "/etc/systemd/system/sockets.target.wants/cups.socket".
   Removed "/etc/systemd/system/multi-user.target.wants/cups.path".
   ```

3. Demostrá que `disable` no es un candado. Cualquier dependencia — o cualquier usuario con los permisos de polkit adecuados — todavía puede arrancarlo:

   ```bash
   sudo systemctl start cups.service
   systemctl is-active cups.service
   ```

   ```
   active
   ```

4. Ahora aplicá el candado real, `mask`, y observá la diferencia:

   ```bash
   sudo systemctl mask --now cups.service cups.socket cups.path
   ls -l /etc/systemd/system/cups.service
   sudo systemctl start cups.service
   ```

   ```
   lrwxrwxrwx 1 root root 9 Aug 24 10:12 /etc/systemd/system/cups.service -> /dev/null
   Failed to start cups.service: Unit cups.service is masked.
   ```

5. Verificá si algo dependía de la unidad que acabás de sacar de servicio:

   ```bash
   systemctl list-dependencies --reverse cups.socket --no-pager
   sudo systemctl --failed --no-pager
   ```

6. Escalá de "enmascarado" a "no instalado" — el único estado sin código residual, sin binarios SUID y sin exposición a CVE:

   ```bash
   # Debian: purge also removes configuration
   sudo apt-get purge --autoremove -y cups cups-daemon cups-browsed avahi-daemon

   # RHEL
   sudo dnf remove -y cups cups-filters avahi
   ```

7. Verificá la eliminación de tres maneras independientes:

   ```bash
   systemctl list-unit-files --no-pager | grep -c cups || echo "no cups units"
   command -v cupsd || echo "no cupsd binary"
   sudo ss -tulpnH | grep -E ':631|:5353' || echo "no listeners"
   ```

8. Volvé a ejecutar el diff de la línea base para cuantificar lo que lograste:

   ```bash
   systemctl list-unit-files --state=enabled --no-pager > /root/hardening-lab/01-enabled-units-after.txt
   diff /root/hardening-lab/01-enabled-units.txt /root/hardening-lab/01-enabled-units-after.txt
   ```

9. Una unidad enmascarada es *inerte*, no *inexistente*. Confirmá que el archivo de unidad del proveedor sigue existiendo en disco y podría restaurarse con un solo comando:

   ```bash
   systemctl cat cups.service 2>&1 | head -3
   # After purge this fails; before purge it shows the /usr/lib unit behind the mask.
   ```

**Comprobá tu comprensión**

- **Q2.1** — Enunciá la diferencia mecánica entre `systemctl disable` y `systemctl mask` en términos de qué escribe cada uno en el sistema de archivos.
- **Q2.2** — Enmascaraste `cups.service` pero dejaste `cups.socket` habilitado. ¿Qué pasa cuando un proceso se conecta al socket de CUPS?
- **Q2.3** — ¿Cuál de estos tres es reversible por un usuario no root con una concesión de polkit `manage-units`: deshabilitado, enmascarado, purgado?
- **Q2.4** — ¿Por qué `systemctl mask` se niega a operar sobre una unidad *estática*, y qué deberías usar en cambio para una unidad sin sección `[Install]`?

---

## Ejercicio 3 — Endurecimiento del cargador de arranque (GRUB 2) y del firmware

> **Tomá un snapshot de la VM ahora.** Un `grub.cfg` malformado produce una máquina que no arranca.

### Parte A — Demostrar la vulnerabilidad que estás por cerrar

1. Reiniciá y mantené `Shift` (BIOS) o presioná `Esc` (UEFI) para llegar al menú de GRUB.
2. Resaltá la entrada por defecto y presioná `e` para editarla.
3. Encontrá la línea que empieza con `linux /boot/vmlinuz…` y agregá al final:

   ```
   init=/bin/bash
   ```

4. Presioná `Ctrl-X` (o `F10`) para arrancar. Caés en una shell de root sin pedido de contraseña:

   ```
   bash-5.2# id
   uid=0(root) gid=0(root) groups=0(root)
   bash-5.2# mount -o remount,rw /
   bash-5.2# passwd root
   New password:
   ```

5. Reiniciá de vuelta a la normalidad (`exec /sbin/init`, o forzá el reinicio de la VM).

### Parte B — Establecer una contraseña de superusuario de GRUB 2

6. Generá un hash PBKDF2. Notá que el nombre del binario difiere según la familia:

   ```bash
   # Debian / Ubuntu
   grub-mkpasswd-pbkdf2
   # RHEL / Rocky (equivalent)
   grub2-mkpasswd-pbkdf2
   ```

   ```
   Enter password:
   Reenter password:
   PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.7A1C…F3.9B44…2E
   ```

7. En **Debian/Ubuntu**, agregá a `/etc/grub.d/40_custom` (debajo de la línea `exec tail`, nunca por encima):

   ```bash
   sudo tee -a /etc/grub.d/40_custom >/dev/null <<'EOF'
   set superusers="grubadm"
   password_pbkdf2 grubadm grub.pbkdf2.sha512.10000.7A1C…F3.9B44…2E
   EOF
   ```

8. Mantené los reinicios desatendidos funcionando marcando las entradas de menú generadas como `--unrestricted`. Editá `/etc/grub.d/10_linux` y agregá la bandera a la variable `CLASS`:

   ```bash
   sudo sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
   grep '^CLASS=' /etc/grub.d/10_linux
   ```

   ```
   CLASS="--class gnu-linux --class gnu --class os --unrestricted"
   ```

9. Regenerá la configuración y verificá antes de reiniciar:

   ```bash
   sudo update-grub                       # Debian wrapper
   # sudo grub2-mkconfig -o /boot/grub2/grub.cfg    # RHEL

   sudo grep -E 'superusers|password_pbkdf2|--unrestricted' /boot/grub/grub.cfg | head
   ```

   En **RHEL 9** el camino soportado es un único comando que escribe `/boot/grub2/user.cfg`:

   ```bash
   sudo grub2-setpassword
   sudo cat /boot/grub2/user.cfg
   ```

   ```
   GRUB2_PASSWORD=grub.pbkdf2.sha512.10000.4E9B…A1.77CD…04
   ```

10. Ajustá los permisos del archivo — el hash es crackeable offline, y por defecto `grub.cfg` es legible por todo el mundo:

    ```bash
    sudo chmod 0600 /boot/grub/grub.cfg   # /boot/grub2/grub.cfg and user.cfg on RHEL
    sudo ls -l /boot/grub/grub.cfg
    ```

11. Reiniciá. Confirmá que la entrada por defecto todavía arranca desatendida, pero que presionar `e` o `c` ahora exige credenciales:

    ```
    Enter username: grubadm
    Enter password:
    ```

12. Repetí el bypass de la Parte A. Ahora debe fallar antes de que se abra el editor.

### Parte C — Endurecer la línea de comandos del kernel y el firmware

13. Agregá parámetros de kernel de defensa en profundidad. Medí el costo antes de adoptarlos en producción — `init_on_free` y `nosmt` conllevan penalizaciones de rendimiento reales:

    ```bash
    sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=1 vsyscall=none debugfs=off"/' /etc/default/grub
    grep GRUB_CMDLINE /etc/default/grub
    sudo update-grub
    ```

    En RHEL el equivalente, aplicado a cada kernel instalado:

    ```bash
    sudo grubby --update-kernel=ALL --args="slab_nomerge init_on_alloc=1 vsyscall=none debugfs=off"
    sudo grubby --info=ALL | grep args
    ```

14. Después de reiniciar, confirmá qué recibió realmente el kernel (nunca confíes en el archivo de configuración, confiá en el kernel):

    ```bash
    cat /proc/cmdline
    ```

    ```
    BOOT_IMAGE=/boot/vmlinuz-6.1.0-25-amd64 root=UUID=…\
     ro quiet slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=1 vsyscall=none debugfs=off
    ```

15. Registrá los controles a nivel de firmware que GRUB no puede proveer, y configuralos en tu hipervisor/BIOS: contraseña de supervisor, orden de arranque fijado al disco interno, arranque externo/USB/PXE deshabilitado, Secure Boot habilitado. Verificá el estado de Secure Boot desde Linux:

    ```bash
    mokutil --sb-state 2>/dev/null || bootctl status 2>/dev/null | grep -i 'secure boot'
    ```

    ```
    SecureBoot enabled
    ```

**Comprobá tu comprensión**

- **Q3.1** — Con `set superusers` definido pero `--unrestricted` **no** aplicado a las entradas de menú, ¿qué pasa en un reinicio desatendido después de un corte de energía?
- **Q3.2** — Un atacante tiene acceso físico y la máquina tiene una contraseña de superusuario de GRUB, una contraseña de BIOS y el orden de arranque bloqueado al disco interno. Nombrá el ataque que aún así tiene éxito, y el control de un objetivo *distinto* del 303 que lo detiene.
- **Q3.3** — ¿Por qué se prefiere `password_pbkdf2` sobre la directiva `password`, y qué significa el `10000` en la cadena del hash?
- **Q3.4** — Configuraste una contraseña de GRUB en RHEL con `grub2-setpassword`. ¿Qué nombre de usuario hay que tipear en el prompt, y dónde se guarda el hash?
- **Q3.5** — Después de actualizar el paquete del kernel en Debian, `update-grub` corre automáticamente. ¿Sobrevivirá tu contraseña de `40_custom`? ¿Sobrevivirá una edición a mano de `/boot/grub/grub.cfg`?

---

## Ejercicio 4 — Parámetros del kernel en tiempo de ejecución (`sysctl`)

### Pasos

1. Inspeccioná los valores actuales de los parámetros ajustables relevantes para la seguridad:

   ```bash
   sudo sysctl kernel.randomize_va_space kernel.kptr_restrict kernel.dmesg_restrict \
                kernel.yama.ptrace_scope kernel.sysrq kernel.perf_event_paranoid \
                fs.protected_symlinks fs.protected_hardlinks fs.suid_dumpable
   ```

   ```
   kernel.randomize_va_space = 2
   kernel.kptr_restrict = 0
   kernel.dmesg_restrict = 0
   kernel.yama.ptrace_scope = 1
   kernel.sysrq = 16
   kernel.perf_event_paranoid = 2
   fs.protected_symlinks = 1
   fs.protected_hardlinks = 1
   fs.suid_dumpable = 0
   ```

2. Demostrá qué filtra `kptr_restrict = 0` a un usuario sin privilegios:

   ```bash
   sudo sysctl -w kernel.kptr_restrict=0
   head -3 /proc/kallsyms                 # run as a NON-root user
   ```

   ```
   ffffffffb3e00000 T startup_64
   ffffffffb3e00060 T secondary_startup_64
   ffffffffb3e001d0 T __pfx_verify_cpu
   ```

   Esas son direcciones de texto del kernel en vivo — KASLR derrotado para cualquiera que pueda leer ese archivo.

3. Restringilo y volvé a leer como el mismo usuario sin privilegios:

   ```bash
   sudo sysctl -w kernel.kptr_restrict=2
   head -3 /proc/kallsyms
   ```

   ```
   0000000000000000 T startup_64
   0000000000000000 T secondary_startup_64
   0000000000000000 T __pfx_verify_cpu
   ```

4. Demostrá `ptrace_scope`. Como usuario normal, arrancá un `sleep` en segundo plano e intentá adjuntarte desde una shell *hermana* (no la padre):

   ```bash
   sudo sysctl -w kernel.yama.ptrace_scope=0
   sleep 600 &                            # note the PID
   # from a second terminal, same user:
   gdb -p <PID> -batch -ex 'info proc' 2>&1 | tail -3
   ```

   Después poné el ámbito en 1 y repetí:

   ```bash
   sudo sysctl -w kernel.yama.ptrace_scope=1
   gdb -p <PID> -batch -ex 'info proc' 2>&1 | tail -3
   ```

   ```
   ptrace: Operation not permitted.
   ```

5. Escribí un archivo de política persistente. Usá un prefijo numérico para que el orden sea explícito:

   ```bash
   sudo tee /etc/sysctl.d/60-hardening.conf >/dev/null <<'EOF'
   # Kernel information leaks
   kernel.kptr_restrict = 2
   kernel.dmesg_restrict = 1
   kernel.perf_event_paranoid = 2

   # Process introspection
   kernel.yama.ptrace_scope = 1

   # Memory layout
   kernel.randomize_va_space = 2
   vm.mmap_min_addr = 65536

   # Filesystem race hardening
   fs.protected_symlinks = 1
   fs.protected_hardlinks = 1
   fs.protected_fifos = 2
   fs.protected_regular = 2
   fs.suid_dumpable = 0

   # Magic SysRq: allow only the sync/remount-ro subset
   kernel.sysrq = 4

   # eBPF
   kernel.unprivileged_bpf_disabled = 1
   net.core.bpf_jit_harden = 2
   EOF
   ```

6. Aplicá y leé el orden que tu distribución usa realmente — **derivalo, no lo asumas**:

   ```bash
   sudo sysctl --system 2>&1 | grep '^\* Applying'
   ```

   ```
   * Applying /usr/lib/sysctl.d/50-default.conf ...
   * Applying /usr/lib/sysctl.d/50-pid-max.conf ...
   * Applying /etc/sysctl.d/60-hardening.conf ...
   * Applying /etc/sysctl.d/99-sysctl.conf ...
   * Applying /etc/sysctl.conf ...
   ```

7. Probá la regla de precedencia con un experimento. Creá un archivo en conflicto que ordene *más tarde* y confirmá qué valor gana:

   ```bash
   echo 'kernel.dmesg_restrict = 0' | sudo tee /etc/sysctl.d/90-conflict.conf
   sudo sysctl --system >/dev/null
   sysctl kernel.dmesg_restrict
   ```

   ```
   kernel.dmesg_restrict = 0
   ```

8. Ahora probá la regla de *ocultamiento* — un archivo en `/etc` enmascara a un archivo de `/usr/lib` **con el mismo nombre**:

   ```bash
   ls /usr/lib/sysctl.d/
   # Pick one, e.g. 50-pid-max.conf, and shadow it:
   sudo ln -sf /dev/null /etc/sysctl.d/50-pid-max.conf
   sudo sysctl --system 2>&1 | grep pid-max
   ```

9. Limpiá el conflicto deliberado y confirmá el estado final buscado:

   ```bash
   sudo rm /etc/sysctl.d/90-conflict.conf /etc/sysctl.d/50-pid-max.conf
   sudo sysctl --system >/dev/null
   sysctl kernel.dmesg_restrict kernel.kptr_restrict
   ```

10. Explorá los interruptores de **una sola vía**. Estos no pueden revertirse sin reiniciar — leé el valor, pero pensá antes de escribir:

    ```bash
    sysctl kernel.kexec_load_disabled kernel.modules_disabled
    ```

    ```
    kernel.kexec_load_disabled = 0
    kernel.modules_disabled = 0
    ```

    Probá la irreversibilidad en una máquina que estés dispuesto a reiniciar:

    ```bash
    sudo sysctl -w kernel.kexec_load_disabled=1
    sudo sysctl -w kernel.kexec_load_disabled=0
    ```

    ```
    sysctl: setting key "kernel.kexec_load_disabled": Operation not permitted
    ```

11. Reiniciá y verificá la persistencia — un valor en tiempo de ejecución que se desvanece al reiniciar no es un control:

    ```bash
    sudo reboot
    # after boot
    sudo sysctl -a --pattern 'kptr_restrict|dmesg_restrict|ptrace_scope|protected_' 2>/dev/null
    ```

**Comprobá tu comprensión**

- **Q4.1** — Pusiste `kernel.kptr_restrict = 2` en `/etc/sysctl.d/60-hardening.conf` y reiniciaste, pero el valor en ejecución es `1`. Dá dos explicaciones distintas y el comando que las distingue.
- **Q4.2** — ¿Cuál es la diferencia entre `kernel.kptr_restrict = 1` y `= 2`?
- **Q4.3** — ¿`kernel.modules_disabled = 1` rompe qué operaciones administrativas de rutina? ¿Por qué se recomienda igualmente en un appliance de función fija?
- **Q4.4** — Explicá la diferencia en el modelo de amenaza entre `fs.protected_symlinks` y `fs.protected_regular`.
- **Q4.5** — `kernel.yama.ptrace_scope` no tiene efecto en tu sistema y `sysctl` informa que la clave no existe. ¿Cuál es la causa?
- **Q4.6** — ¿Cuáles de estos pertenecen al objetivo **334.1 Endurecimiento de Red** en lugar de al 332.1: `net.ipv4.tcp_syncookies`, `kernel.dmesg_restrict`, `net.ipv4.conf.all.rp_filter`, `fs.suid_dumpable`?

---

## Ejercicio 5 — ASLR, NX/DEP y mitigaciones de explotación por binario

### Parte A — Observar ASLR

1. Confirmá la configuración a nivel de sistema y su significado:

   ```bash
   cat /proc/sys/kernel/randomize_va_space
   ```

   ```
   2
   ```

2. Observá la aleatorización directamente. Cada iteración es un proceso nuevo, así que cada uno obtiene una disposición fresca:

   ```bash
   for i in 1 2 3; do awk '/\[stack\]/{print "stack:", $1} /\[heap\]/{print "heap: ", $1}' /proc/self/maps; done
   ```

   ```
   stack: 7ffd3a1c9000-7ffd3a1ea000
   heap:  55a4c1f2e000-55a4c1f4f000
   stack: 7ffe8b04d000-7ffe8b06e000
   heap:  5601de7a1000-5601de7c2000
   stack: 7ffc2e9b1000-7ffc2e9d2000
   heap:  55f30ba46000-55f30ba67000
   ```

3. Deshabilitala a nivel de sistema, observá y restaurá:

   ```bash
   sudo sysctl -w kernel.randomize_va_space=0
   for i in 1 2 3; do awk '/\[stack\]/{print $1}' /proc/self/maps; done
   sudo sysctl -w kernel.randomize_va_space=2
   ```

   ```
   7ffffffde000-7ffffffff000
   7ffffffde000-7ffffffff000
   7ffffffde000-7ffffffff000
   ```

4. Ahora comparalo con la deshabilitación *por proceso*, disponible para cualquier usuario sin privilegios:

   ```bash
   for i in 1 2 3; do setarch "$(uname -m)" -R awk '/\[stack\]/{print $1}' /proc/self/maps; done
   sysctl kernel.randomize_va_space
   ```

   Notá que el valor a nivel de sistema sigue siendo `2` — la bandera de personalidad se aplicó solo a esos hijos.

5. Compará el modo `1` (conservador) contra el modo `2` (completo) mirando solamente el heap:

   ```bash
   for m in 1 2; do
     sudo sysctl -qw kernel.randomize_va_space=$m
     echo "--- mode $m ---"
     for i in 1 2 3; do awk '/\[heap\]/{print $1}' /proc/self/maps; done
   done
   sudo sysctl -qw kernel.randomize_va_space=2
   ```

### Parte B — Confirmar que NX/DEP está activo

6. Verificá la característica de la CPU y el uso que hace el kernel de ella:

   ```bash
   grep -o '\bnx\b' /proc/cpuinfo | head -1
   sudo dmesg | grep -i 'NX (Execute Disable)'
   ```

   ```
   nx
   [    0.000000] NX (Execute Disable) protection: active
   ```

7. Inspeccioná los permisos de pila de un binario real. `RW` es correcto; `RWE` significa pila ejecutable:

   ```bash
   readelf -lW /bin/ls | grep -E 'GNU_STACK|GNU_RELRO'
   ```

   ```
     GNU_RELRO      0x01f5f0 0x00000000000205f0 0x00000000000205f0 0x000a10 0x000a10 R   0x1
     GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10
   ```

### Parte C — Construir un binario débil y uno endurecido, y compararlos

8. Escribí el programa de prueba:

   ```bash
   cat > /tmp/probe.c <<'EOF'
   #include <stdio.h>
   #include <stdlib.h>
   #include <string.h>

   void copy(const char *src) {
       char buf[32];
       strcpy(buf, src);          /* deliberately unchecked */
       printf("buf @ %p = %s\n", (void *)buf, buf);
   }

   int main(int argc, char **argv) {
       printf("main   @ %p\n", (void *)main);
       printf("heap   @ %p\n", malloc(16));
       printf("printf @ %p\n", (void *)printf);
       if (argc > 1) copy(argv[1]);
       return 0;
   }
   EOF
   ```

9. Compilalo de dos maneras:

   ```bash
   gcc -O0 -fno-stack-protector -no-pie -z execstack -Wl,-z,norelro \
       -U_FORTIFY_SOURCE -o /tmp/weak /tmp/probe.c

   gcc -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -pie \
       -Wl,-z,relro,-z,now -Wl,-z,noexecstack -o /tmp/strong /tmp/probe.c
   ```

10. Compará el perfil de mitigaciones:

    ```bash
    checksec --file=/tmp/weak
    checksec --file=/tmp/strong
    ```

    ```
    RELRO         STACK CANARY    NX           PIE          RPATH    RUNPATH   FORTIFY  FILE
    No RELRO      No canary found NX disabled  No PIE       No RPATH No RUNPATH No      /tmp/weak
    Full RELRO    Canary found    NX enabled   PIE enabled  No RPATH No RUNPATH Yes     /tmp/strong
    ```

11. Derivá los mismos hechos usando solo `readelf` — `checksec` no está en el examen, `readelf` sí:

    ```bash
    for b in /tmp/weak /tmp/strong; do
      echo "== $b"
      readelf -hW  "$b" | awk '/^  Type:/{print "  Type       :", $2}'      # DYN = PIE, EXEC = fixed
      readelf -lW  "$b" | awk '/GNU_STACK/{print "  GNU_STACK  :", $(NF-1)}'
      readelf -lW  "$b" | grep -q GNU_RELRO && echo "  RELRO      : present" || echo "  RELRO      : absent"
      readelf -dW  "$b" | grep -q BIND_NOW  && echo "  BIND_NOW   : yes" || echo "  BIND_NOW   : no"
      readelf -sW  "$b" | grep -q __stack_chk_fail && echo "  Canary     : yes" || echo "  Canary     : no"
      readelf -sW  "$b" | grep -q '_chk@'   && echo "  FORTIFY    : yes" || echo "  FORTIFY    : no"
    done
    ```

    ```
    == /tmp/weak
      Type       : EXEC
      GNU_STACK  : RWE
      RELRO      : absent
      BIND_NOW   : no
      Canary     : no
      FORTIFY    : no
    == /tmp/strong
      Type       : DYN
      GNU_STACK  : RW
      RELRO      : present
      BIND_NOW   : yes
      Canary     : yes
      FORTIFY    : yes
    ```

12. Observá el canario disparándose. Desbordá el búfer de 32 bytes en cada binario:

    ```bash
    /tmp/weak   "$(python3 -c 'print("A"*200)')"; echo "weak exit=$?"
    /tmp/strong "$(python3 -c 'print("A"*200)')"; echo "strong exit=$?"
    ```

    ```
    ...
    Segmentation fault (core dumped)
    weak exit=139
    *** stack smashing detected ***: terminated
    Aborted (core dumped)
    strong exit=134
    ```

13. Observá que PIE mueve también el *código*, cosa que `no-pie` no hace:

    ```bash
    for i in 1 2; do /tmp/weak   | head -1; done
    for i in 1 2; do /tmp/strong | head -1; done
    ```

    ```
    main   @ 0x401136
    main   @ 0x401136
    main   @ 0x5581f3a01169
    main   @ 0x55d0e4e2a169
    ```

14. Auditá los binarios propios del sistema en busca de los eslabones más débiles:

    ```bash
    for f in $(find /usr/bin /usr/sbin -maxdepth 1 -type f -perm -4000 2>/dev/null); do
        s=$(readelf -lW "$f" 2>/dev/null | awk '/GNU_STACK/{print $(NF-1)}')
        t=$(readelf -hW "$f" 2>/dev/null | awk '/^  Type:/{print $2}')
        printf '%-32s type=%-5s stack=%s\n' "$f" "$t" "$s"
    done
    ```

15. Limpiá:

    ```bash
    rm -f /tmp/weak /tmp/strong /tmp/probe.c
    ```

**Comprobá tu comprensión**

- **Q5.1** — Explicá la diferencia entre los valores `0`, `1` y `2` de `randomize_va_space`, nombrando una región que solo el modo `2` aleatoriza.
- **Q5.2** — `setarch -R` no requiere privilegios. ¿Eso vuelve inútil a ASLR como control de seguridad? Argumentá ambos lados.
- **Q5.3** — NX/DEP es una característica de CPU + kernel, y sin embargo `/tmp/weak` tenía una pila ejecutable. Reconciliá esas dos afirmaciones.
- **Q5.4** — ¿Cuál es la diferencia entre *Partial RELRO* y *Full RELRO*, y qué bandera del enlazador produce la segunda?
- **Q5.5** — ¿Por qué un canario de pila produce `SIGABRT` (código de salida 134) en lugar de `SIGSEGV` (código de salida 139), y por qué esa distinción le importa a un defensor que lee logs?
- **Q5.6** — `_FORTIFY_SOURCE=2` requiere un nivel de optimización de al menos `-O1`. ¿Por qué?
- **Q5.7** — Un binario legado de 32 bits en tu servidor muestra `GNU_STACK: RWE`. No podés recompilarlo. ¿Cuáles son tus opciones, en orden de preferencia?

---

## Ejercicio 6 — Aislamiento (sandboxing) de unidades systemd

### Pasos

1. Puntuá un servicio real para ver dónde estás parado:

   ```bash
   systemd-analyze security sshd.service --no-pager | head -20
   ```

   ```
   NAME                                   DESCRIPTION                          EXPOSURE
   ✗ PrivateNetwork=                      Service has access to the host…            0.5
   ✗ User=/DynamicUser=                   Service runs as root                       0.4
   ✗ CapabilityBoundingSet=~CAP_SYS_ADMIN Service has administrator privileges       0.3
   ✗ ProtectHome=                         Service has full access to home dirs       0.2
   ✗ PrivateDevices=                      Service potentially has access to…         0.2
   …
   → Overall exposure level for sshd.service: 9.6 UNSAFE 😨
   ```

2. Construí un servicio objetivo pequeño y seguro para poder endurecer agresivamente sin romper nada real:

   ```bash
   sudo tee /usr/local/bin/lab-probe.sh >/dev/null <<'EOF'
   #!/bin/bash
   while true; do
     printf 'uid=%s tmp=%s root_writable=%s\n' \
            "$(id -u)" \
            "$(ls -d /tmp | xargs stat -c %i)" \
            "$(touch /etc/lab-probe-canary 2>/dev/null && echo YES || echo NO)"
     sleep 30
   done
   EOF
   sudo chmod 0755 /usr/local/bin/lab-probe.sh

   sudo tee /etc/systemd/system/lab-probe.service >/dev/null <<'EOF'
   [Unit]
   Description=Host hardening lab probe

   [Service]
   Type=simple
   ExecStart=/usr/local/bin/lab-probe.sh
   Restart=no

   [Install]
   WantedBy=multi-user.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl start lab-probe.service
   ```

3. Tomá la medición "antes" y el comportamiento "antes":

   ```bash
   systemd-analyze security lab-probe.service --no-pager | tail -1
   journalctl -u lab-probe.service -n 2 --no-pager
   ```

   ```
   → Overall exposure level for lab-probe.service: 9.6 UNSAFE 😨
   Aug 24 11:02:11 lab lab-probe.sh[2211]: uid=0 tmp=1 root_writable=YES
   ```

4. Agregá un sandbox como un **drop-in**, nunca editando la unidad del proveedor:

   ```bash
   sudo systemctl edit lab-probe.service
   ```

   Ingresá, en la región editable:

   ```ini
   [Service]
   # Identity and privilege
   DynamicUser=yes
   NoNewPrivileges=yes
   CapabilityBoundingSet=
   AmbientCapabilities=
   RestrictSUIDSGID=yes

   # Filesystem
   ProtectSystem=strict
   ProtectHome=yes
   PrivateTmp=yes
   ReadWritePaths=/var/lib/lab-probe
   StateDirectory=lab-probe
   UMask=0077

   # Kernel and host state
   ProtectKernelTunables=yes
   ProtectKernelModules=yes
   ProtectKernelLogs=yes
   ProtectControlGroups=yes
   ProtectClock=yes
   ProtectHostname=yes
   ProtectProc=invisible
   ProcSubset=pid
   PrivateDevices=yes

   # Namespaces, memory, syscalls
   RestrictNamespaces=yes
   RestrictRealtime=yes
   LockPersonality=yes
   MemoryDenyWriteExecute=yes
   SystemCallArchitectures=native
   SystemCallFilter=@system-service
   SystemCallErrorNumber=EPERM

   # Network
   RestrictAddressFamilies=AF_UNIX
   PrivateNetwork=yes
   IPAddressDeny=any
   ```

5. Confirmá dónde quedó el drop-in y cómo se ve ahora la unidad fusionada:

   ```bash
   ls -l /etc/systemd/system/lab-probe.service.d/
   systemctl cat lab-probe.service | head -40
   ```

   ```
   -rw-r--r-- 1 root root 812 Aug 24 11:09 override.conf
   ```

6. Reiniciá el servicio y medí el delta:

   ```bash
   sudo systemctl restart lab-probe.service
   systemd-analyze security lab-probe.service --no-pager | tail -1
   journalctl -u lab-probe.service -n 2 --no-pager
   ```

   ```
   → Overall exposure level for lab-probe.service: 1.2 OK 🙂
   Aug 24 11:10:41 lab lab-probe.sh[2390]: uid=63478 tmp=1179648 root_writable=NO
   ```

   El UID cambió (`DynamicUser`), `/tmp` es un inodo distinto (`PrivateTmp`), y la escritura en `/etc` falló (`ProtectSystem=strict`).

7. Inspeccioná el sandbox desde dentro del propio espacio de nombres del servicio:

   ```bash
   PID=$(systemctl show -p MainPID --value lab-probe.service)
   sudo ls -l /proc/$PID/ns/
   sudo nsenter -t "$PID" -m -p -n --  sh -c 'ls /tmp; ip -brief addr; cat /etc/hostname'
   ```

8. Probá que el filtro de llamadas al sistema realmente deniega algo. Agregá una sonda que llame a `mount(2)`:

   ```bash
   sudo systemd-run --unit=lab-mount-test \
        -p SystemCallFilter=@system-service -p SystemCallErrorNumber=EPERM \
        -p NoNewPrivileges=yes \
        /bin/mount -t tmpfs none /mnt
   journalctl -u lab-mount-test --no-pager -n 5
   ```

   ```
   mount: /mnt: permission denied.
   ```

9. Aprendé el modo de falla. Restringí de más deliberadamente y observá cómo se presenta:

   ```bash
   sudo systemd-run --unit=lab-jit-test -p MemoryDenyWriteExecute=yes \
        /usr/bin/python3 -c 'import ctypes; print("ok")'
   systemctl status lab-jit-test --no-pager
   ```

10. Compará la exposición de todo el sistema antes y después de tus cambios:

    ```bash
    systemd-analyze security --no-pager > /root/hardening-lab/06-security-after.txt
    diff /root/hardening-lab/06-security-baseline.txt /root/hardening-lab/06-security-after.txt
    ```

11. Aplicá un sandbox conservador y de bajo riesgo a un servicio *real* y verificá que sigue funcionando de punta a punta:

    ```bash
    sudo systemctl edit chronyd.service   # or systemd-timesyncd / ntpsec
    ```

    ```ini
    [Service]
    NoNewPrivileges=yes
    ProtectHome=yes
    ProtectKernelModules=yes
    ProtectControlGroups=yes
    RestrictRealtime=yes
    RestrictSUIDSGID=yes
    LockPersonality=yes
    ```

    ```bash
    sudo systemctl restart chronyd
    chronyc tracking | head -3
    systemd-analyze security chronyd.service --no-pager | tail -1
    ```

12. Desarmá las unidades del laboratorio:

    ```bash
    sudo systemctl stop lab-probe.service
    sudo systemctl disable lab-probe.service
    sudo rm -rf /etc/systemd/system/lab-probe.service.d /etc/systemd/system/lab-probe.service \
                /usr/local/bin/lab-probe.sh /etc/lab-probe-canary
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    ```

**Comprobá tu comprensión**

- **Q6.1** — ¿Cuál es la diferencia práctica entre `ProtectSystem=yes`, `=full` y `=strict`? ¿Cuál requiere `ReadWritePaths=` para ser usable por la mayoría de los demonios?
- **Q6.2** — ¿Por qué debe estar seteado `NoNewPrivileges=yes` para que `SystemCallFilter=` sea aplicable sin privilegios, y qué rompe si el servicio usa `su`, `sudo` o un ayudante SUID?
- **Q6.3** — Configuraste `PrivateTmp=yes` en un demonio que escribe un socket en `/tmp` para que un cliente se conecte. ¿Qué se rompe, y cuál es la corrección adecuada?
- **Q6.4** — Un colega argumenta que `systemd-analyze security` informando `1.2 OK` prueba que el servicio es seguro. Refutalo en dos oraciones.
- **Q6.5** — ¿Por qué se prefiere `systemctl edit` sobre editar `/usr/lib/systemd/system/foo.service` directamente? Nombrá la falla específica que causa la edición directa.
- **Q6.6** — `MemoryDenyWriteExecute=yes` es una de las directivas anti-explotación más fuertes disponibles. Nombrá tres clases de software legítimo que rompe.
- **Q6.7** — ¿Cuál es la diferencia entre `CapabilityBoundingSet=` (vacío) y `AmbientCapabilities=` (vacío)?

---

## Ejercicio 7 — Autorización con polkit

### Pasos

1. Determiná tu versión de polkit — el formato de las reglas cambió en la 0.106, y esta es una trampa clásica del examen:

   ```bash
   pkaction --version
   ```

   ```
   pkaction version 122
   ```

   Cualquier versión ≥ 0.106 usa reglas en JavaScript en `/etc/polkit-1/rules.d/`. Las versiones más viejas (y algunas compilaciones de SUSE/Ubuntu LTS con el backend local-authority) usan archivos INI `.pkla` bajo `/etc/polkit-1/localauthority/`.

2. Enumerá las acciones registradas en el sistema:

   ```bash
   pkaction | wc -l
   pkaction | grep systemd1
   ```

   ```
   183
   org.freedesktop.systemd1.manage-units
   org.freedesktop.systemd1.manage-unit-files
   org.freedesktop.systemd1.reload-daemon
   org.freedesktop.systemd1.set-environment
   ```

3. Leé los valores por defecto con los que viene una acción:

   ```bash
   pkaction --action-id org.freedesktop.systemd1.manage-units --verbose
   ```

   ```
   org.freedesktop.systemd1.manage-units:
     description:       Manage system services or other units
     message:           Authentication is required to manage system services or other units.
     vendor:            The systemd Project
     implicit any:      auth_admin
     implicit inactive: auth_admin
     implicit active:   auth_admin_keep
   ```

4. Encontrá el XML detrás de eso y leé el bloque `<defaults>`:

   ```bash
   grep -A8 'manage-units' /usr/share/polkit-1/actions/org.freedesktop.systemd1.policy | head -20
   ```

5. Probá una decisión de autorización sin ejecutar la acción:

   ```bash
   pkcheck --action-id org.freedesktop.systemd1.manage-units --process $$ ; echo "exit=$?"
   ```

   ```
   Error checking for authorization org.freedesktop.systemd1.manage-units: \
   Authorization requires authentication and -u wasn't passed.
   exit=3
   ```

   Leé `pkcheck(1)` en tu sistema y registrá el significado exacto de cada estado de salida — `0` es autorizado, y los valores distintos de cero distinguen "denegado" de "requiere autenticación".

6. Creá un grupo de delegación y un miembro:

   ```bash
   sudo groupadd -f webops
   sudo useradd -m -G webops -s /bin/bash alice
   sudo passwd alice
   id alice
   ```

7. Escribí una regla que le otorgue a `webops` la capacidad de administrar exactamente una unidad — y nada más:

   ```bash
   sudo tee /etc/polkit-1/rules.d/49-webops-nginx.rules >/dev/null <<'EOF'
   // Allow members of "webops" to start/stop/restart nginx.service only.
   // Every other unit falls through to the systemd defaults (auth_admin).
   polkit.addRule(function(action, subject) {
       if (action.id !== "org.freedesktop.systemd1.manage-units") {
           return polkit.Result.NOT_HANDLED;
       }
       if (!subject.isInGroup("webops")) {
           return polkit.Result.NOT_HANDLED;
       }

       var unit = action.lookup("unit");
       var verb = action.lookup("verb");

       if (unit === "nginx.service" &&
           ["start", "stop", "restart", "reload", "status"].indexOf(verb) >= 0) {
           polkit.log("webops grant: " + subject.user + " " + verb + " " + unit);
           return polkit.Result.YES;
       }
       return polkit.Result.NOT_HANDLED;
   });
   EOF
   sudo chmod 0644 /etc/polkit-1/rules.d/49-webops-nginx.rules
   ```

8. polkit recarga `rules.d` automáticamente ante un cambio. Confirmá que parseó limpiamente:

   ```bash
   sudo journalctl -u polkit -n 20 --no-pager
   ```

   ```
   polkitd[701]: Loading rules from directory /etc/polkit-1/rules.d
   polkitd[701]: Finished loading, compiling and executing 6 rules
   ```

   Un error de sintaxis aparece acá — y el resto de ese archivo se omite silenciosamente:

   ```
   polkitd[701]: Error compiling script /etc/polkit-1/rules.d/49-webops-nginx.rules
   ```

9. Probá como `alice`, desde una sesión de inicio de sesión (polkit necesita una sesión; `su -` por sí solo puede no darte una):

   ```bash
   sudo apt-get install -y nginx || sudo dnf install -y nginx
   ssh alice@localhost
   ```

   ```bash
   systemctl restart nginx.service          # allowed, no password
   echo "exit=$?"
   systemctl restart sshd.service           # denied / prompts for admin auth
   ```

   ```
   exit=0
   ==== AUTHENTICATING FOR org.freedesktop.systemd1.manage-units ====
   Authentication is required to manage system services or other units.
   Authenticating as: root
   Password:
   ```

10. Verificá la línea de log que emitió tu regla:

    ```bash
    sudo journalctl -u polkit --no-pager | grep 'webops grant'
    ```

    ```
    polkitd[701]: webops grant: alice restart nginx.service
    ```

11. Entendé el ordenamiento de las reglas. Los archivos se leen en orden lexicográfico y la **primera** regla que devuelve un valor distinto de `NOT_HANDLED` decide. Probalo:

    ```bash
    sudo tee /etc/polkit-1/rules.d/10-deny-all-manage.rules >/dev/null <<'EOF'
    polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.isInGroup("webops")) {
            return polkit.Result.NO;
        }
    });
    EOF
    # Retry the nginx restart as alice — it now fails outright.
    sudo rm /etc/polkit-1/rules.d/10-deny-all-manage.rules
    ```

12. Auditá `pkexec`, históricamente el objetivo de escalada de privilegios local de mayor valor en Linux (CVE-2021-4034 "PwnKit", CVE-2021-3560):

    ```bash
    ls -l "$(command -v pkexec)"
    ```

    ```
    -rwsr-xr-x 1 root root 31032 Aug  1 09:14 /usr/bin/pkexec
    ```

13. Si nada en el host lo requiere, quitá el bit setuid y hacé que el cambio sobreviva a las actualizaciones de paquetes:

    ```bash
    # Debian: statoverride so dpkg does not restore the bit
    sudo dpkg-statoverride --update --add root root 0755 /usr/bin/pkexec
    ls -l /usr/bin/pkexec

    # RHEL: file capability/permission change plus a check in your config management
    sudo chmod 0755 /usr/bin/pkexec
    ```

14. Verificá el efecto y confirmá que no rompiste nada de lo que dependés:

    ```bash
    pkexec id
    ```

    ```
    pkexec must be setuid root
    ```

    Revertilo si encontrás una dependencia:

    ```bash
    sudo dpkg-statoverride --remove /usr/bin/pkexec && sudo chmod 4755 /usr/bin/pkexec
    ```

**Comprobá tu comprensión**

- **Q7.1** — Distinguí `auth_self`, `auth_admin`, `auth_self_keep` y `auth_admin_keep` en un bloque `<defaults>`.
- **Q7.2** — Tu regla devuelve `polkit.Result.NO` en lugar de `polkit.Result.NOT_HANDLED` cuando el sujeto no está en `webops`. ¿Cuál es la consecuencia no deseada?
- **Q7.3** — ¿Por qué un archivo `.pkla` que escribiste en Debian 12 es ignorado silenciosamente, y cómo confirmás qué backend está en uso?
- **Q7.4** — Una regla de polkit le otorga a un usuario `manage-units` para *todas* las unidades. Explicá concretamente por qué esto equivale a otorgar root.
- **Q7.5** — ¿Cuál es la diferencia funcional entre `subject.isInGroup("webops")` y `subject.active`, y cuándo requerirías ambos?
- **Q7.6** — Quitar el bit setuid de `pkexec` mitiga PwnKit. Nombrá una cosa que *no* mitiga, y el control que sí lo hace.

---

## Ejercicio 8 — USBGuard: superficie de ataque a nivel de dispositivo

> **Advertencia de bloqueo.** Generá la política con tu teclado y mouse conectados, y mantené abierta una vía por consola/serie/SSH. En una laptop, una política incorrecta significa quedarse sin teclado en el prompt de inicio de sesión.

### Pasos

1. Enumerá los dispositivos que el kernel ve actualmente:

   ```bash
   lsusb
   usbguard list-devices
   ```

   ```
   1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6WzviqdJ5VSeTUY8PatCNBKead+ktYwvZ/aiKvo=" parent-hash "..." with-interface 09:00:00
   4: allow id 046d:c31c serial "" name "USB Keyboard" hash "kFEE2FpMHU2..." parent-hash "..." with-interface { 03:01:01 03:00:00 }
   6: block id 0781:5591 serial "4C531001..." name "Ultra USB 3.0" hash "d6a9Xz..." with-interface 08:06:50
   ```

2. Generá una lista de permitidos inicial a partir del hardware actualmente conectado:

   ```bash
   sudo usbguard generate-policy > /tmp/rules.conf
   sudo install -o root -g root -m 0600 /tmp/rules.conf /etc/usbguard/rules.conf
   sudo shred -u /tmp/rules.conf
   sudo cat /etc/usbguard/rules.conf
   ```

3. Leé la configuración del demonio y entendé cada perilla de política antes de arrancar el servicio:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/usbguard/usbguard-daemon.conf
   ```

   ```
   RuleFile=/etc/usbguard/rules.conf
   RuleFolder=/etc/usbguard/rules.d/
   ImplicitPolicyTarget=block
   PresentDevicePolicy=apply-policy
   PresentControllerPolicy=keep
   InsertedDevicePolicy=apply-policy
   RestoreControllerDeviceState=false
   DeviceManagerBackend=uevent
   IPCAllowedUsers=root
   IPCAllowedGroups=
   AuditFilePath=/var/log/usbguard/usbguard-audit.log
   ```

4. Confirmá las dos configuraciones que determinan si te dejás afuera a vos mismo:

   ```bash
   grep -E '^(PresentDevicePolicy|PresentControllerPolicy|ImplicitPolicyTarget)' /etc/usbguard/usbguard-daemon.conf
   ```

   `PresentControllerPolicy=keep` es lo que mantiene funcionales los hubs raíz integrados — y por lo tanto un teclado interno — sin importar la política.

5. Arrancá el demonio y confirmá el estado:

   ```bash
   sudo systemctl enable --now usbguard.service
   systemctl status usbguard --no-pager | head -5
   usbguard list-rules
   ```

6. Probá la vía de bloqueo. Insertá un dispositivo de almacenamiento masivo USB que **no** esté en la política:

   ```bash
   usbguard list-devices --blocked
   sudo journalctl -u usbguard -n 10 --no-pager
   ```

   ```
   9: block id 0781:5591 serial "..." name "Ultra USB 3.0" hash "..." with-interface 08:06:50
   usbguard-daemon[1120]: Device blocked: id=9 name="Ultra USB 3.0" rule="implicit"
   ```

   Confirmá que el kernel nunca vinculó un driver:

   ```bash
   lsblk | grep -c sdb || echo "no block device created"
   ```

7. Autorizalo solo para esta sesión, y después de forma permanente:

   ```bash
   sudo usbguard allow-device 9
   lsblk | tail -2

   sudo usbguard allow-device -p 9       # -p appends a persistent rule
   sudo usbguard list-rules | tail -1
   ```

8. Escribí una política dirigida por *clase de interfaz* en lugar de por dispositivo — esta es la forma duradera. La clase USB `08` es almacenamiento masivo, `03` es HID, `e0` es controlador inalámbrico:

   ```bash
   sudo tee -a /etc/usbguard/rules.conf >/dev/null <<'EOF'
   # Permit HID (keyboard/mouse) from any vendor, but reject anything that
   # additionally advertises a mass-storage or network interface (BadUSB pattern).
   allow with-interface equals { 03:*:* }

   # Block all USB mass storage outright.
   block with-interface one-of { 08:*:* }

   # Reject (logically detach) USB-to-Ethernet adapters, a common exfil path.
   reject with-interface one-of { e0:*:* 02:*:* }
   EOF
   sudo systemctl restart usbguard
   usbguard list-rules
   ```

9. Entendé `allow` vs `block` vs `reject` empíricamente. Insertá el dispositivo de almacenamiento masivo de nuevo bajo cada objetivo y observá:

   ```bash
   sudo journalctl -u usbguard -f
   # in another terminal: unplug/replug
   ```

10. Delegá visibilidad de solo lectura a un grupo de operadores sin darles el poder de autorizar dispositivos:

    ```bash
    sudo usbguard add-user -g wheel --devices=listen --policy=list --exceptions=listen
    sudo ls -l /etc/usbguard/IPCAccessControl.d/
    sudo systemctl restart usbguard
    ```

11. Confirmá que el rastro de auditoría existe y está protegido:

    ```bash
    sudo ls -l /var/log/usbguard/
    sudo tail -5 /var/log/usbguard/usbguard-audit.log
    ```

12. Practicá la recuperación que algún día vas a necesitar. Simulá un bloqueo y reparalo desde una consola:

    ```bash
    # Console-only recovery:
    sudo systemctl stop usbguard        # policy stops being enforced; devices are authorized by the kernel default
    # or, without stopping the daemon:
    sudo usbguard set-parameter ImplicitPolicyTarget allow 2>/dev/null || \
      sudo sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=allow/' /etc/usbguard/usbguard-daemon.conf
    sudo systemctl restart usbguard
    ```

**Comprobá tu comprensión**

- **Q8.1** — ¿Cuál es la diferencia entre los objetivos de regla `block` y `reject` en USBGuard, y cuál es visible para un usuario que mira `lsusb`?
- **Q8.2** — ¿Por qué `PresentControllerPolicy=keep` es la única configuración más importante a verificar antes de habilitar el demonio en una laptop?
- **Q8.3** — Una regla coincide por `hash`. ¿Qué cubre el hash, y por qué es más fuerte que coincidir por `id 046d:c31c`?
- **Q8.4** — Un atacante conecta un dispositivo que se presenta como teclado e inyecta pulsaciones de teclas (un "Rubber Ducky"). ¿`allow with-interface equals { 03:*:* }` lo detiene? ¿Qué lo haría?
- **Q8.5** — Explicá la diferencia entre `equals`, `one-of`, `none-of` y `all-of` en una cláusula `with-interface`.
- **Q8.6** — USBGuard está corriendo con una política estricta. Nombrá dos riesgos por USB que *no* aborda.

---

## Ejercicio 9 — Límites de recursos: PAM versus systemd

### Pasos

1. Leé tus límites actuales, soft y hard:

   ```bash
   ulimit -a
   ulimit -Sn; ulimit -Hn
   ```

   ```
   real-time non-blocking time  (microseconds, -R) unlimited
   core file size              (blocks, -c) 0
   max user processes          (-u) 15693
   open files                  (-n) 1024
   1024
   1048576
   ```

2. Leé los límites de un *proceso en ejecución* — este es el diagnóstico que zanja toda discusión sobre qué mecanismo ganó:

   ```bash
   sudo cat /proc/1/limits
   PID=$(pgrep -f sshd | head -1); sudo cat /proc/$PID/limits | grep -E 'Max open files|Max processes'
   ```

   ```
   Limit                     Soft Limit           Hard Limit           Units
   Max processes             15693                15693                processes
   Max open files            1024                 524288               files
   ```

3. Creá un usuario de prueba y un grupo para restringir:

   ```bash
   sudo groupadd -f labusers
   sudo useradd -m -G labusers -s /bin/bash bob
   sudo passwd bob
   ```

4. Aplicá límites basados en PAM en un archivo dedicado — nunca edites `limits.conf` en sí si existe un directorio `.d`:

   ```bash
   sudo tee /etc/security/limits.d/50-labusers.conf >/dev/null <<'EOF'
   # <domain>  <type>  <item>       <value>
   @labusers   soft    nproc        40
   @labusers   hard    nproc        60
   @labusers   soft    nofile       1024
   @labusers   hard    nofile       4096
   @labusers   hard    core         0
   @labusers   hard    memlock      64
   @labusers   -       maxlogins    3
   *           hard    core         0
   EOF
   ```

5. Confirmá que `pam_limits.so` esté realmente en las pilas que te importan — un archivo de límites sin módulo PAM es inerte:

   ```bash
   grep -rn 'pam_limits' /etc/pam.d/
   ```

   ```
   /etc/pam.d/common-session:25:session required        pam_limits.so      # Debian
   /etc/pam.d/system-auth:18:session     required      pam_limits.so       # RHEL
   /etc/pam.d/sshd:8:session    required     pam_limits.so
   ```

6. Verificá desde una *nueva sesión de inicio* (los límites se aplican al establecer la sesión; una shell existente conserva sus valores viejos):

   ```bash
   ssh bob@localhost 'ulimit -Su; ulimit -Hu; ulimit -Sn; ulimit -Hn'
   ```

   ```
   40
   60
   1024
   4096
   ```

7. Probá que el límite contiene un proceso desbocado. **Solo en la VM**, como `bob`:

   ```bash
   ssh bob@localhost
   ```

   ```bash
   ulimit -Su
   # A bounded stress test, not an unbounded fork bomb:
   for i in $(seq 1 200); do sleep 60 & done 2>&1 | tail -3
   ```

   ```
   -bash: fork: retry: Resource temporarily unavailable
   -bash: fork: retry: Resource temporarily unavailable
   -bash: fork: Resource temporarily unavailable
   ```

   Limpiá desde la sesión de *root*, no desde la de bob:

   ```bash
   sudo pkill -u bob
   ```

8. Ahora demostrá la brecha crucial: **los servicios de systemd no atraviesan PAM**. Creá un servicio que corra como `bob` y leé sus límites reales:

   ```bash
   sudo systemd-run --unit=lab-limits --uid=bob --remain-after-exit \
        /bin/sh -c 'sleep 300'
   PID=$(systemctl show -p MainPID --value lab-limits)
   sudo grep -E 'Max processes|Max open files' /proc/$PID/limits
   ```

   ```
   Max processes             15693                15693                processes
   Max open files            1024                 524288               files
   ```

   La regla `@labusers hard nproc 60` no tuvo efecto.

9. Aplicá el equivalente nativo de systemd:

   ```bash
   sudo systemctl stop lab-limits ; sudo systemctl reset-failed
   sudo systemd-run --unit=lab-limits --uid=bob --remain-after-exit \
        -p LimitNPROC=60 -p LimitNOFILE=4096:4096 -p TasksMax=50 -p MemoryMax=256M \
        /bin/sh -c 'sleep 300'
   PID=$(systemctl show -p MainPID --value lab-limits)
   sudo grep -E 'Max processes|Max open files' /proc/$PID/limits
   systemctl show lab-limits -p TasksMax -p TasksCurrent -p MemoryMax
   ```

   ```
   Max processes             60                   60                   processes
   Max open files            4096                 4096                 files
   TasksMax=50
   TasksCurrent=1
   MemoryMax=268435456
   ```

10. Restringí las sesiones de usuario *interactivas* al estilo systemd, vía el slice de usuario — esta es la capa que atrapa una fork bomb independientemente de PAM:

    ```bash
    sudo mkdir -p /etc/systemd/system/user-.slice.d
    sudo tee /etc/systemd/system/user-.slice.d/50-limits.conf >/dev/null <<'EOF'
    [Slice]
    TasksMax=200
    MemoryMax=2G
    CPUQuota=200%
    EOF
    sudo systemctl daemon-reload
    ```

    Verificá contra una sesión en vivo:

    ```bash
    UID_BOB=$(id -u bob)
    ssh -f bob@localhost 'sleep 120'
    systemctl show "user-${UID_BOB}.slice" -p TasksMax -p TasksCurrent -p MemoryMax
    systemd-cgls "/user.slice/user-${UID_BOB}.slice" | head
    ```

11. Establecé valores por defecto globales para todos los servicios y para el propio administrador:

    ```bash
    grep -E '^#?Default(LimitNOFILE|LimitNPROC|TasksMax)' /etc/systemd/system.conf
    sudo sed -i 's/^#\?DefaultLimitCORE=.*/DefaultLimitCORE=0:0/' /etc/systemd/system.conf
    sudo systemctl daemon-reexec
    systemctl show -p DefaultLimitCORE -p DefaultTasksMax
    ```

12. Deshabilitá los volcados de memoria por completo — filtran claves y credenciales desde la memoria. Se requieren las tres capas:

    ```bash
    # 1. sysctl
    echo 'fs.suid_dumpable = 0' | sudo tee /etc/sysctl.d/61-coredump.conf
    # 2. PAM/shell limit
    echo '* hard core 0' | sudo tee -a /etc/security/limits.d/50-labusers.conf
    # 3. systemd's coredump handler
    sudo mkdir -p /etc/systemd/coredump.conf.d
    printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' | sudo tee /etc/systemd/coredump.conf.d/disable.conf
    sudo sysctl --system >/dev/null && sudo systemctl daemon-reexec
    sysctl kernel.core_pattern fs.suid_dumpable
    ```

13. Limpiá:

    ```bash
    sudo systemctl stop lab-limits; sudo systemctl reset-failed
    sudo pkill -u bob; sudo userdel -r bob
    ```

**Comprobá tu comprensión**

- **Q9.1** — Agregaste `@labusers hard nproc 60` a `/etc/security/limits.d/`, pero un servicio de systemd propiedad de `bob` sigue obteniendo 15693. ¿Por qué, y cuáles son las dos correcciones posibles?
- **Q9.2** — ¿Cuál es la diferencia entre los tipos `soft`, `hard` y `-` en `limits.conf`, y cuál puede elevar un usuario no root?
- **Q9.3** — `nproc` se aplica por UID a través de *todas* las sesiones de ese usuario. Dá un incidente operativo concreto que esto causa y cómo evitarlo.
- **Q9.4** — Distinguí `LimitNPROC=` de `TasksMax=` en una unidad de systemd. ¿Cuál sobrevive a un cambio `setuid` dentro del servicio?
- **Q9.5** — ¿Por qué `ulimit -n 8192` falla para un usuario normal cuyo límite hard es 4096, y tiene éxito para root?
- **Q9.6** — Explicá por qué deshabilitar los volcados de memoria requiere tres cambios separados en lugar de uno.

---

## Ejercicio 10 — Cuentas, shells y la superficie SUID/capacidades

### Pasos

1. Listá cada cuenta que pueda obtener una shell interactiva:

   ```bash
   awk -F: '$7 !~ /(nologin|false|sync)$/ {printf "%-16s uid=%-6s shell=%s\n", $1, $3, $7}' /etc/passwd
   ```

2. Listá las cuentas de servicio que erróneamente tienen una:

   ```bash
   awk -F: '$3 >= 1 && $3 < 1000 && $7 !~ /(nologin|false)$/ {print $1, $3, $7}' /etc/passwd
   ```

3. Corregilas. Notá la diferencia de rutas entre familias:

   ```bash
   NOLOGIN=$( [ -x /usr/sbin/nologin ] && echo /usr/sbin/nologin || echo /sbin/nologin )
   sudo usermod -s "$NOLOGIN" games 2>/dev/null
   getent passwd games
   ```

4. Dale a `nologin` un mensaje y confirmá que se muestra:

   ```bash
   echo "This account is not available for interactive login. Contact secops@example.com" \
     | sudo tee /etc/nologin.txt
   sudo -u nobody -s "$NOLOGIN" 2>&1 || true
   ```

5. Entendé las tres maneras distintas en que una cuenta queda "deshabilitada", y qué detiene realmente cada una:

   ```bash
   sudo useradd -m carol; sudo passwd carol
   sudo -u carol ssh-keygen -q -N '' -f /home/carol/.ssh/id_ed25519
   sudo -u carol sh -c 'cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'

   # (a) lock the password only
   sudo passwd -l carol
   sudo passwd -S carol
   ```

   ```
   carol L 2026-08-24 0 99999 7 -1
   ```

   ```bash
   # SSH key login still works:
   sudo -u carol ssh -o BatchMode=yes -o StrictHostKeyChecking=no carol@localhost 'echo STILL_IN'
   ```

   ```
   STILL_IN
   ```

   ```bash
   # (b) expire the account — this blocks every authentication path
   sudo chage -E 0 carol
   sudo chage -l carol | head -3
   sudo -u carol ssh -o BatchMode=yes carol@localhost 'echo STILL_IN' ; echo "exit=$?"
   ```

   ```
   Account expired
   exit=254
   ```

   ```bash
   # (c) change the shell — blocks a shell, not scp/sftp/port-forwarding
   sudo usermod -s "$NOLOGIN" carol
   ```

6. Usá `/etc/nologin` para ventanas de mantenimiento y aprendé el detalle de su ciclo de vida:

   ```bash
   echo "Patching window until 18:00 UTC — logins disabled." | sudo tee /etc/nologin
   ssh carol@localhost ; echo "exit=$?"     # blocked by pam_nologin.so; root is exempt
   grep -rn pam_nologin /etc/pam.d/
   ```

   Ahora observá que systemd lo elimina por vos en el próximo arranque:

   ```bash
   systemctl cat systemd-user-sessions.service | grep -E 'ExecStart|Description'
   ```

   ```
   Description=Permit User Sessions
   ExecStart=/usr/lib/systemd/systemd-user-sessions start
   ```

   ```bash
   sudo rm -f /etc/nologin
   ```

7. Inventariá la superficie SUID/SGID — el inventario clásico de escalada de privilegios local:

   ```bash
   sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
        -printf '%M %u %g %10s %p\n' 2>/dev/null | sort -k5 > /root/hardening-lab/07-suid.txt
   wc -l /root/hardening-lab/07-suid.txt
   cat /root/hardening-lab/07-suid.txt
   ```

   ```
   -rwsr-xr-x root root    72000 /usr/bin/chfn
   -rwsr-xr-x root root    44808 /usr/bin/chsh
   -rwsr-xr-x root root    88464 /usr/bin/gpasswd
   -rwsr-xr-x root root    59704 /usr/bin/mount
   -rwsr-xr-x root root    31032 /usr/bin/pkexec
   -rwsr-xr-x root root    68208 /usr/bin/passwd
   -rwsr-xr-x root root   277936 /usr/bin/sudo
   -rwsr-xr-x root root    35192 /usr/bin/umount
   -rwsr-xr-x root root    55672 /usr/bin/su
   ```

8. Inventariá también las **capacidades de archivo** — un binario con `cap_setuid` es tan peligroso como uno SUID y es invisible para la búsqueda de arriba:

   ```bash
   sudo getcap -r / 2>/dev/null
   ```

   ```
   /usr/bin/ping cap_net_raw=ep
   /usr/bin/newgidmap cap_setgid=ep
   /usr/bin/newuidmap cap_setuid=ep
   ```

9. Quitá el bit setuid de un binario que nadie necesita, de una manera que las actualizaciones de paquetes no deshagan:

   ```bash
   # Debian
   sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chfn
   ls -l /usr/bin/chfn

   # RHEL — record it in your configuration management, dpkg-statoverride has no rpm equivalent
   sudo chmod u-s /usr/bin/chfn
   rpm -Va shadow-utils | grep chfn
   ```

   ```
   .M....... /usr/bin/chfn
   ```

   Esa `M` es exactamente cómo la verificación de integridad de paquetes (objetivo 332.2) va a reportar tu cambio deliberado — documentalo.

10. Volvé a ejecutar el inventario SUID y compará con la línea base. Cualquier diferencia futura es o bien tu cambio o bien una intrusión:

    ```bash
    sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %10s %p\n' 2>/dev/null \
      | sort -k5 > /root/hardening-lab/07-suid-after.txt
    diff /root/hardening-lab/07-suid.txt /root/hardening-lab/07-suid-after.txt
    ```

11. Limpiá:

    ```bash
    sudo userdel -r carol
    sudo dpkg-statoverride --remove /usr/bin/chfn 2>/dev/null && sudo chmod 4755 /usr/bin/chfn
    ```

**Comprobá tu comprensión**

- **Q10.1** — Ordená `passwd -l`, `usermod -s /usr/sbin/nologin` y `chage -E 0` según cuán completamente deshabilitan una cuenta, y explicá qué deja abierto cada uno.
- **Q10.2** — ¿Por qué `/etc/nologin` desaparece tras un reinicio en un host con systemd, y qué unidad es la responsable?
- **Q10.3** — ¿Por qué el inventario SUID usa `-xdev`, y qué te perderías sin eso? ¿Qué te perderías *con* eso?
- **Q10.4** — Un binario no tiene bit setuid pero lleva `cap_dac_read_search=ep`. ¿Qué puede leer su usuario, y por qué esto es discutiblemente peor que SUID root para un modelo de amenaza de confidencialidad de datos?
- **Q10.5** — En Debian, ¿por qué se usa `dpkg-statoverride` en lugar de un simple `chmod u-s`?

---

## Ejercicio 11 — Verificación: probar que el endurecimiento sobrevivió a un reinicio

Un control que no se verifica después de reiniciar es un control que *esperás* tener.

### Pasos

1. Escribí un script de verificación que compruebe cada cambio que hiciste:

   ```bash
   sudo tee /root/hardening-lab/verify.sh >/dev/null <<'EOF'
   #!/bin/bash
   # Post-reboot verification for LPIC-3 303 objective 332.1 lab.
   fail=0
   chk() {  # chk <description> <expected> <actual>
       if [ "$2" = "$3" ]; then
           printf '  [ OK ]  %-42s %s\n' "$1" "$3"
       else
           printf '  [FAIL]  %-42s expected=%s actual=%s\n' "$1" "$2" "$3"; fail=1
       fi
   }

   echo "== Kernel runtime parameters =="
   for kv in kernel.kptr_restrict=2 kernel.dmesg_restrict=1 kernel.yama.ptrace_scope=1 \
             kernel.randomize_va_space=2 fs.suid_dumpable=0 fs.protected_regular=2; do
       k=${kv%%=*}; want=${kv##*=}
       chk "$k" "$want" "$(sysctl -n "$k" 2>/dev/null)"
   done

   echo "== Boot loader =="
   cfg=$(ls /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null | head -1)
   chk "grub.cfg mode"        "600" "$(stat -c %a "$cfg" 2>/dev/null)"
   grep -qE 'password_pbkdf2|GRUB2_PASSWORD' "$cfg" /boot/grub2/user.cfg 2>/dev/null \
       && echo "  [ OK ]  grub superuser password present" \
       || { echo "  [FAIL]  grub superuser password absent"; fail=1; }

   echo "== Kernel command line =="
   for p in slab_nomerge init_on_alloc=1 vsyscall=none; do
       grep -qw -- "$p" /proc/cmdline \
           && echo "  [ OK ]  cmdline contains $p" \
           || { echo "  [FAIL]  cmdline missing $p"; fail=1; }
   done

   echo "== Services =="
   for u in cups.service avahi-daemon.service; do
       st=$(systemctl is-enabled "$u" 2>&1)
       case "$st" in
         masked|disabled|*"No such file"*) echo "  [ OK ]  $u -> $st" ;;
         *) echo "  [FAIL]  $u -> $st"; fail=1 ;;
       esac
   done

   echo "== USBGuard =="
   chk "usbguard active"       "active" "$(systemctl is-active usbguard 2>/dev/null)"
   chk "rules.conf mode"       "600"    "$(stat -c %a /etc/usbguard/rules.conf 2>/dev/null)"

   echo "== Core dumps =="
   chk "kernel.core_pattern"   "|/bin/false" "$(sysctl -n kernel.core_pattern 2>/dev/null)"

   echo
   [ "$fail" -eq 0 ] && echo "RESULT: all checks passed" || echo "RESULT: failures present"
   exit "$fail"
   EOF
   sudo chmod 0700 /root/hardening-lab/verify.sh
   ```

2. Ejecutalo antes de reiniciar, para atrapar errores de tipeo mientras todavía tenés una shell funcionando:

   ```bash
   sudo /root/hardening-lab/verify.sh
   ```

3. Reiniciá y ejecutalo de nuevo. Solo la segunda ejecución es evidencia:

   ```bash
   sudo reboot
   # after boot:
   sudo /root/hardening-lab/verify.sh; echo "exit=$?"
   ```

4. Confirmá que nada de lo que endureciste rompió un servicio:

   ```bash
   systemctl --failed --no-pager
   sudo journalctl -p err -b --no-pager | tail -30
   systemd-analyze security --no-pager | head -15
   ```

5. Producí el informe final de deltas contra la línea base del Ejercicio 1:

   ```bash
   cd /root/hardening-lab
   sudo ss -tulpnH | sort -k1,1 -k5,5 > 03-listeners-after.txt
   diff 03-listeners.txt 03-listeners-after.txt
   diff 06-security-baseline.txt 06-security-after.txt | head -20
   ```

**Comprobá tu comprensión**

- **Q11.1** — ¿Por qué la ejecución previa al reinicio de `verify.sh` es insuficiente como evidencia, incluso cuando todas las comprobaciones pasan?
- **Q11.2** — Tu script de verificación afirma `kernel.core_pattern = |/bin/false` pero en un host con systemd lee `|/usr/lib/systemd/systemd-coredump …`. ¿Eso es una falla? ¿Cuál es la afirmación correcta?
- **Q11.3** — `systemctl --failed` está vacío, pero un servicio aislado en sandbox está fallando silenciosamente en hacer su trabajo (escribe en una ruta que ya no puede alcanzar). ¿Cómo detectarías esto?
- **Q11.4** — Nombrá el único control de todo este laboratorio que más reduce el riesgo en un servidor expuesto a internet, y el que más lo reduce en un kiosco físicamente accesible. Justificá ambos.

---

<details>
<summary><strong>Respuestas — clic para desplegar</strong></summary>

### Ejercicio 1

**Q1.1 — Presente.** `cups.socket` es una unidad de activación por socket: systemd mismo mantiene el socket a la escucha, y la primera conexión hacia él arranca `cups.service` bajo demanda. Que el servicio "no esté corriendo" es una instantánea, no un estado. Este es el error de endurecimiento más común en hosts con systemd — deshabilitar `foo.service` y dejar `foo.socket`, `foo.path` o `foo.timer` habilitados. Enumerá siempre la familia completa con `systemctl list-unit-files | grep '^cups'`.

**Q1.2 —** `ss -tulpn` muestra solo lo que está *a la escucha ahora mismo sobre IP/UDP*. Se pierde las unidades activadas por socket que están ociosas, los sockets de dominio UNIX, los servicios activados por D-Bus, los trabajos de cron/timer, los módulos del kernel, los binarios SUID y cualquier cosa disparada por un evento de dispositivo. La lista de unidades habilitadas atrapa esas, pero a su vez se pierde el código que está *instalado pero no habilitado* — un binario SUID vulnerable, una biblioteca con un CVE, un ayudante que otro servicio puede invocar. La lista de paquetes es la medición más amplia, y por eso "eliminar el paquete" le gana a "deshabilitar el servicio" siempre que sea posible.

**Q1.3 —** La escala va de `0` (menos expuesto) a `10` (más expuesto); más alto es peor. El predicado textual se degrada aproximadamente `SAFE → GOOD → OK → MEDIUM → EXPOSED → UNSAFE` a medida que sube el número. Leé los umbrales exactos de tu versión de systemd en lugar de memorizar números.

**Q1.4 —** Dos cualesquiera de: sockets de dominio UNIX (`ss -xlp`); servicios activables por D-Bus (`busctl list`); unidades activadas por socket actualmente ociosas; binarios SUID/SGID y capacidades de archivo; interfaces del kernel como `/proc`, `/sys`, `io_uring`, eBPF; timers y trabajos de cron; manejadores de eventos USB/dispositivo (reglas de udev).

---

### Ejercicio 2

**Q2.1 —** `disable` elimina los enlaces simbólicos que la sección `[Install]` de la unidad creó — típicamente bajo `/etc/systemd/system/<target>.wants/`. El archivo de unidad queda intacto y todavía puede arrancarse manualmente o ser arrastrado como dependencia de otra cosa. `mask` crea un enlace simbólico desde `/etc/systemd/system/<unit>` (o `/run/systemd/system/<unit>` con `--runtime`) hacia `/dev/null`, lo que vuelve a la unidad completamente incargable: el arranque manual falla, y cualquier dependencia sobre ella falla también.

**Q2.2 —** La conexión es aceptada por systemd, que entonces intenta arrancar `cups.service` — y falla, porque está enmascarado. El socket permanece abierto (así que el puerto sigue siendo alcanzable y sigue siendo superficie de ataque para cualquier cosa que pueda dispararse antes de la activación), y los clientes obtienen una conexión que no va a ningún lado. Enmascará también el socket.

**Q2.3 —** *Deshabilitado* es trivialmente reversible por cualquiera con `manage-units` (`systemctl start` no necesita `enable`). *Enmascarado* no es reversible solo con `manage-units` — `unmask` mapea a `manage-unit-files`, que es una acción de polkit separada, y el enlace simbólico de la máscara vive en `/etc` y requiere root para eliminarse. *Purgado* no es reversible sin derechos de instalación de paquetes. Esta escalera es exactamente por qué "purgar > enmascarar > deshabilitar".

**Q2.4 —** Una unidad estática no tiene sección `[Install]`, así que nunca está en un directorio `.wants/` y no hay nada que `disable` pueda desenlazar — `systemctl disable` la reporta como estática y no hace nada. `mask` *sí* funciona sobre unidades estáticas y es la herramienta correcta ahí. (`mask` se niega solamente en unidades que ya son enlaces simbólicos apuntando a algo distinto de `/dev/null`, y en unidades en `/run` cuando existe una entrada en conflicto en `/etc`.)

---

### Ejercicio 3

**Q3.1 —** La máquina se detiene en el menú de GRUB y espera un nombre de usuario y una contraseña antes de arrancar nada. No va a volver a levantarse de forma desatendida. Por eso existe `--unrestricted`: separa *"puede arrancar la entrada por defecto"* (todos) de *"puede editar entradas o llegar a la shell de GRUB"* (solo superusuarios). Una cláusula `--users ""` en un `menuentry` logra lo mismo para una entrada individual.

**Q3.2 —** Sacar el disco y leerlo en otra máquina — o arrancar la máquina desde un medio removible si los controles de firmware alguna vez son sorteados o reseteados limpiando NVRAM/CMOS. La contraseña de GRUB protege el *menú de arranque*, no los *datos*. El control que lo detiene es el **cifrado de disco completo con LUKS**, objetivo **331.3 Sistemas de Archivos Cifrados**. Las contraseñas de GRUB y de firmware elevan el esfuerzo; solo el cifrado cambia el resultado.

**Q3.3 —** `password` guarda la contraseña en **texto plano** dentro de `grub.cfg`, que es legible por todo el mundo por defecto y se copia en backups e imágenes. `password_pbkdf2` guarda una derivación PBKDF2-HMAC-SHA512 con sal. El `10000` es el **conteo de iteraciones** de PBKDF2 — el factor de trabajo. Sigue siendo crackeable offline, y por eso el paso 10 también restringe el modo del archivo; un conteo de iteraciones bajo más una contraseña débil es un fin de semana de tiempo de GPU.

**Q3.4 —** El nombre de usuario es `root` (el `grub2-setpassword` de RHEL codifica el superusuario de GRUB como `root`; este es el root de *GRUB*, no relacionado con la contraseña de root de Unix). El hash se guarda en `/boot/grub2/user.cfg` como `GRUB2_PASSWORD=…`, que `grub.cfg` incluye. Mantenerlo en un archivo separado es lo que permite que `grub2-mkconfig` regenere `grub.cfg` sin destruir la contraseña.

**Q3.5 —** La contraseña de `40_custom` **sobrevive**, porque `update-grub`/`grub2-mkconfig` regenera `grub.cfg` *a partir de* los scripts de `/etc/grub.d/` y de `/etc/default/grub` — tus directivas son entradas, no salidas. Una edición a mano de `/boot/grub/grub.cfg` **no sobrevive**: ese archivo es salida generada y se sobrescribe por completo. Esta es la regla general para GRUB 2 y el punto más frecuentemente examinado al respecto.

---

### Ejercicio 4

**Q4.1 —** Dos explicaciones: **(a)** otro archivo que ordena más tarde — `/etc/sysctl.d/99-*.conf` o `/etc/sysctl.conf` — lo pone en `1` y gana por precedencia; **(b)** el valor está siendo establecido en tiempo de ejecución después del arranque por un servicio, un runtime de contenedores, o `systemd-sysctl` leyendo un archivo de `/usr/lib/sysctl.d` que oculta de forma distinta a la que asumiste. Distinguilas con `sudo sysctl --system 2>&1 | grep -i kptr` (imprime cada archivo aplicado, en orden, así que el último que toca la clave es el ganador) y `grep -rn kptr_restrict /etc/sysctl.conf /etc/sysctl.d/ /run/sysctl.d/ /usr/lib/sysctl.d/`.

**Q4.2 —** `1` reemplaza los punteros del kernel por ceros para usuarios que **carecen de `CAP_SYSLOG`** — root y los poseedores de `CAP_SYSLOG` siguen viendo direcciones reales. `2` los reemplaza por ceros para **todos**, sin importar la capacidad. Usá `2` en servidores; usá `1` si un agente de monitoreo necesita legítimamente direcciones de símbolos y corre con `CAP_SYSLOG`.

**Q4.3 —** Rompe la carga de *cualquier* módulo nuevo del kernel: conectar en caliente hardware que necesita un driver aún no cargado, `modprobe` para un tipo de sistema de archivos en el primer montaje, drivers de red para una NIC recién conectada, y algunas características de VPN/sistemas de archivos/contenedores. Se recomienda en un appliance de función fija porque el hardware y la carga de trabajo nunca cambian, así que nada legítimo necesita cargar un módulo después del arranque — y elimina la vía de inyección de código en el kernel más directa disponible para un proceso root comprometido. Es un **interruptor de una sola vía**: solo un reinicio lo restaura.

**Q4.4 —** `fs.protected_symlinks` defiende contra la clásica **condición de carrera de enlaces simbólicos en un directorio sticky escribible por todos** (`/tmp`): un proceso privilegiado sigue un enlace simbólico plantado por un atacante y escribe en un archivo que no pretendía. El kernel se niega a seguir enlaces simbólicos en directorios sticky escribibles por todos cuando el dueño del enlace difiere del dueño del directorio y del que lo sigue. `fs.protected_regular` defiende contra un ataque *distinto* en los mismos directorios: un proceso privilegiado **abre para escritura** un archivo regular precreado y propiedad de un atacante, permitiéndole al atacante leer o corromper los datos escritos en "su" archivo. Uno trata de la traversía, el otro de la propiedad del destino.

**Q4.5 —** El **LSM Yama no está compilado o no está habilitado en el kernel en ejecución**. Las claves `kernel.yama.*` solo existen cuando Yama está compilado (`CONFIG_SECURITY_YAMA=y`) y activo. Verificá con `cat /sys/kernel/security/lsm` — Yama debe aparecer en esa lista. Debian/Ubuntu lo habilitan por defecto; algunos kernels de RHEL y personalizados no, en cuyo caso hay que agregar `yama` a la línea de comandos del kernel en `lsm=`.

**Q4.6 —** `net.ipv4.tcp_syncookies` y `net.ipv4.conf.all.rp_filter` pertenecen a **334.1 Endurecimiento de Red**. `kernel.dmesg_restrict` y `fs.suid_dumpable` son endurecimiento del host (332.1). La distinción importa para el alcance de estudio: 332.1 trata del *host* — arranque, kernel, servicios, usuarios, dispositivos — mientras que el árbol `net.*` se examina bajo 334.

---

### Ejercicio 5

**Q5.1 —** `0` = ASLR apagado; cada proceso obtiene direcciones idénticas. `1` = *conservador*: la pila, las regiones mapeadas en memoria (bibliotecas compartidas, asignaciones `mmap`) y el VDSO se aleatorizan, pero el **heap (`brk`)** no, y los ejecutables no-PIE cargan en una dirección fija. `2` = *completo*: todo lo del modo 1, **más el heap `brk`**. La región exclusiva del modo 2 es el heap basado en `brk`.

**Q5.2 —** *Inútil:* un atacante local puede lanzar su objetivo con `setarch -R`, o simplemente hacer fuerza bruta sobre un espacio de direcciones de 32 bits, o usar una fuga de información — así que ASLR no es un límite de seguridad. *No inútil:* la bandera de personalidad solo afecta a los procesos que el atacante crea; no puede desaleatorizar un demonio ya en ejecución, un servicio expuesto a la red, o un binario setuid que no lanzó él. El verdadero trabajo de ASLR es obligar al atacante a encadenar una **fuga de información** con un fallo de corrupción de memoria, convirtiendo un exploit de un solo tiro en un requisito de dos bugs. Encuadre correcto: ASLR eleva el costo de explotación; no crea un límite de privilegios. Por eso también se lo empareja con `kptr_restrict`, PIE y RELRO en lugar de confiar en él solo.

**Q5.3 —** NX/DEP está *disponible* desde la CPU y es *gestionado* por el kernel, pero qué páginas se marcan como ejecutables se decide **por binario**, a partir de la cabecera de programa ELF `PT_GNU_STACK`. `-z execstack` le dice al enlazador que emita esa cabecera con `RWE`, y el kernel lo respeta mapeando la pila como ejecutable. Que NX esté "activo" significa que el mecanismo funciona; no significa que cada binario se adhiera. Por eso la auditoría por binario (`readelf -lW … GNU_STACK`) es un paso obligatorio y no es redundante con la verificación de `dmesg`.

**Q5.4 —** **Partial RELRO** (`-Wl,-z,relro`) mueve los metadatos ELF que pueden hacerse de solo lectura después de la relocalización — `.init_array`, `.fini_array`, `.got` — a un segmento marcado como solo lectura, pero la **GOT relacionada con la PLT (`.got.plt`) sigue siendo escribible** porque el enlace perezoso necesita parchearla en cada primera llamada. **Full RELRO** agrega `-Wl,-z,now` (`BIND_NOW`), que resuelve cada símbolo en tiempo de carga para que `.got.plt` también pueda hacerse de solo lectura. La bandera que produce Full RELRO es, por lo tanto, `-Wl,-z,relro,-z,now`. Full RELRO cierra la técnica clásica de "sobrescritura de la GOT" a costa de un arranque de proceso más lento.

**Q5.5 —** La verificación del canario es una condición *deliberada* y detectada: `__stack_chk_fail` llama a `__fortify_fail`, que invoca `abort()` → `SIGABRT` (128 + 6 = 134). Un `SIGSEGV` común (128 + 11 = 139) es un error de memoria *no detectado* que dio la casualidad de tocar una página no mapeada. La distinción le importa a un defensor porque `*** stack smashing detected ***` en el journal es una **señal de explotación de alta confianza**: la corrupción alcanzó la región de la dirección de retorno y fue atrapada. Un segfault pelado es mucho más a menudo un bug ordinario. Alertá sobre el primero, triageá el segundo.

**Q5.6 —** `_FORTIFY_SOURCE` reemplaza llamadas como `strcpy`/`memcpy`/`sprintf` por variantes estilo `__strcpy_chk` que reciben un tamaño de destino conocido en tiempo de compilación. Ese tamaño viene de `__builtin_object_size()`, que solo puede calcular una respuesta útil una vez que el optimizador ha corrido suficiente análisis para conocer la extensión del objeto. En `-O0` devuelve "desconocido" para casi todo, así que las variantes fortificadas degradan a las no fortificadas y la característica silenciosamente no hace nada. De ahí que GCC advierta y que la bandera sea efectivamente inocua sin al menos `-O1`.

**Q5.7 —** En orden de preferencia: **(1)** reemplazá o actualizá el software — una pila ejecutable en 2026 casi siempre significa un binario sin mantenimiento con otros problemas. **(2)** Aislalo: corrélo bajo una unidad de systemd con `MemoryDenyWriteExecute=yes` donde sea posible, un `SystemCallFilter` restrictivo, un `User=` sin privilegios dedicado, `PrivateNetwork=`/`IPAddressDeny=`, y confinamiento MAC (booleanos `execstack` de SELinux / un perfil de AppArmor — objetivo 333.2). **(3)** Parcheá la cabecera in situ con `execstack -c /path/to/binary` (o `patchelf`) y probá — esto funciona cuando la pila ejecutable fue un accidente del enlazador y no un requisito real, y falla ruidosamente si el programa realmente usa trampolines. **(4)** Aceptá y compensá: aislalo de la red y monitorealo. Nunca simplemente pongas `randomize_va_space=0` ni relajes la política MAC para hacerlo funcionar.

---

### Ejercicio 6

**Q6.1 —** `ProtectSystem=yes` monta `/usr` y `/boot` como solo lectura. `=full` agrega `/etc` como solo lectura. `=strict` monta **toda la jerarquía del sistema de archivos** como solo lectura excepto `/dev`, `/proc` y `/sys` (que tienen sus propias directivas). `=strict` es el que requiere `ReadWritePaths=` (o `StateDirectory=`/`LogsDirectory=`/`CacheDirectory=`/`RuntimeDirectory=`) para cualquier demonio que escriba estado, ya que de lo contrario `/var` también es de solo lectura.

**Q6.2 —** `SystemCallFilter=` está implementado con **seccomp-bpf**. El kernel solo le permite a un proceso sin privilegios instalar un filtro seccomp si tiene `CAP_SYS_ADMIN` *o* ha establecido `PR_SET_NO_NEW_PRIVS` — la garantía de que el filtro no puede eludirse ejecutando un binario setuid que gane privilegios que el autor del filtro nunca anticipó. Por eso systemd implica `NoNewPrivileges=yes` para estas directivas. Qué rompe: cualquier `execve` de un **binario setuid/setgid o un archivo con capacidades** deja de ganar esos privilegios, así que una llamada interna a `sudo`, `su`, `pkexec`, `ping`, `mount` o `newuidmap` dentro del servicio falla. Los servicios que delegan en ayudantes privilegiados deben rediseñarse o recibir la capacidad directamente vía `AmbientCapabilities=`.

**Q6.3 —** `PrivateTmp=yes` le da al servicio un **espacio de nombres de montaje privado** con un `tmpfs` fresco en `/tmp` y `/var/tmp`. El demonio crea su socket dentro de ese espacio de nombres, y ningún cliente afuera puede verlo — el cliente obtiene `ENOENT`. La corrección adecuada no es deshabilitar `PrivateTmp`; es mover el socket a un directorio de tiempo de ejecución apropiado con `RuntimeDirectory=myservice` (creando `/run/myservice`, que *no* está en un espacio de nombres separado) y apuntar tanto al demonio como a los clientes allí. `/tmp` nunca fue el lugar correcto para un socket de IPC.

**Q6.4 —** `systemd-analyze security` es una **lista de verificación estática y heurística** de las directivas presentes en el archivo de unidad; puntúa la *configuración*, no el código. Un servicio puede puntuar `1.2 OK` y aún así estar corriendo un demonio con una RCE remota sin autenticar, una credencial embebida, o un bug de traversía de rutas — nada de lo cual ninguna directiva de sandbox aborda. El puntaje te dice cuánto daño *podría* causar un compromiso, no cuán probable es un compromiso; tratalo como una métrica de exposición, nunca como una métrica de aseguramiento.

**Q6.5 —** `systemctl edit` escribe un drop-in en `/etc/systemd/system/<unit>.d/override.conf`, que se **fusiona sobre** la unidad del proveedor y vive en el árbol propiedad del administrador. Editar `/usr/lib/systemd/system/foo.service` directamente pone tu cambio en el árbol **propiedad del paquete**: la próxima actualización del paquete lo sobrescribe y tu endurecimiento desaparece silenciosamente — sin fallo, sin línea de log, y con un servicio que calladamente vuelve a correr sin confinar. (`systemctl edit --full` es la vía de escape cuando debés reemplazar la unidad completa; la copia a `/etc`, lo cual sigue siendo seguro.)

**Q6.6 —** Tres cualesquiera de: **compiladores JIT y runtimes** (Java/JVM, .NET, motores de JavaScript incluyendo cualquier cosa que embeba V8/SpiderMonkey, LuaJIT, PyPy); **runtimes de lenguajes que hacen generación dinámica de código** (callbacks de `ctypes` de Python, Ruby, Julia, algunos módulos nativos de Node); **pilas de gráficos/cómputo** que generan shaders en tiempo de ejecución (Mesa, CUDA/OpenCL, algunos drivers de GPU); **emuladores, herramientas de trazado y depuración** (QEMU TCG, Wine, `gdb`, JITs de espacio de usuario adyacentes a eBPF, Valgrind); **binarios de Go que usan cgo con ciertos trampolines**, y **bibliotecas FFI** como la asignación de closures de libffi. La directiva bloquea que `mmap`/`mprotect` produzcan mapeos simultáneamente escribibles+ejecutables, y todo lo anterior depende de esa transición.

**Q6.7 —** `CapabilityBoundingSet=` (vacío) limpia el **conjunto delimitador (bounding set)** — el techo de qué capacidades puede llegar a tener *cualquier* proceso de la unidad, incluso después de un `execve` de un archivo con capacidades de archivo. Es un límite duro que nunca puede elevarse durante la vida del servicio. `AmbientCapabilities=` (vacío) limpia el **conjunto ambiental** — las capacidades que se *otorgan automáticamente* a un proceso no root a través de `execve`. Vaciar el ambiental significa "no repartir nada extra"; vaciar el delimitador significa "nada puede adquirirse jamás". El delimitador es el control de seguridad; el ambiental es el mecanismo de concesión. Establecer `AmbientCapabilities=CAP_NET_BIND_SERVICE` mientras `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` es la forma idiomática de permitir que un demonio no root escuche en el puerto 443 y nada más.

---

### Ejercicio 7

**Q7.1 —** Los cuatro requieren autenticación exitosa antes de que la acción proceda; difieren en **de quién** son las credenciales y **por cuánto tiempo**. `auth_self` — la propia contraseña del usuario solicitante. `auth_admin` — la contraseña de un administrador (root, o un miembro del grupo de administración según se configure para el backend de polkit, típicamente `wheel`/`sudo`). Las variantes `_keep` (`auth_self_keep`, `auth_admin_keep`) cachean la autorización exitosa por un período corto acotado a la sesión, de modo que acciones repetidas no vuelvan a pedir credenciales. Usá `_keep` solo donde el pedido repetido lleve a los usuarios a deshabilitar el control por completo.

**Q7.2 —** Devolver `NO` es una **denegación explícita que termina la evaluación**. Como las reglas se evalúan en orden lexicográfico de nombre de archivo y el primer resultado distinto de `NOT_HANDLED` gana, un `NO` explícito para todo sujeto que no sea de `webops` significa que *ninguna regla en ningún archivo posterior, y ningún `<defaults>` en el XML `.policy` de la propia acción, se consulta jamás*. Root y los administradores quedarían denegados de `manage-units` de plano, rompiendo `systemctl` para todo el mundo. `NOT_HANDLED` es el valor correcto para "no tengo opinión"; reservá `NO` para una denegación deliberada y dirigida que pretendés que sea definitiva.

**Q7.3 —** Los archivos `.pkla` son leídos únicamente por el **backend local-authority**, que polkit ≥ 0.106 reemplazó por el motor de reglas JavaScript de `rules.d`. Debian 12 trae polkit ≥ 0.105-con-JS (y Debian 13 / RHEL 9 traen polkit 121+), así que los directorios `localauthority` están ausentes o son vestigiales y tu archivo nunca se parsea — silenciosamente, sin error. Confirmalo con `pkaction --version` (≥ 0.106 → JavaScript) y verificando si existe `/etc/polkit-1/rules.d/` y si `journalctl -u polkit` informa "Loading rules from directory". Si `/etc/polkit-1/localauthority/` está presente *y* la versión es < 0.106, entonces `.pkla` aplica.

**Q7.4 —** `org.freedesktop.systemd1.manage-units` permite arrancar una unidad arbitraria. Un usuario con ese derecho no puede crear nada nuevo, pero puede hacer `systemctl start` de cualquier unidad existente — y, combinado con `manage-unit-files` o un directorio de unidades escribible, definir una. Incluso sin derechos de escritura de archivos, systemd ofrece unidades transitorias al estilo `systemd-run` a través de la misma interfaz D-Bus: el usuario le pide al administrador (corriendo como PID 1, como root) que ejecute un comando como root. No hay ninguna brecha significativa entre "puede pedirle a PID 1 que corra unidades arbitrarias" y "es root". Por eso la regla del paso 7 filtra por `action.lookup("unit")` y `action.lookup("verb")` y devuelve `NOT_HANDLED` para todo lo demás.

**Q7.5 —** `subject.isInGroup("webops")` pregunta **quién** es el solicitante — una propiedad de identidad estática. `subject.active` pregunta **dónde está** — si su sesión de inicio es actualmente la sesión activa en un asiento local (físicamente frente a la consola), en contraste con una sesión inactiva o una sesión remota/SSH. Requerí ambos cuando una concesión deba aplicarse solo a alguien físicamente presente: por ejemplo, permitir suspender, montar medios removibles o cambiar la configuración de red desde la consola, mientras se deniega la misma acción a una sesión SSH. `subject.local` (sesión en un asiento local, activa o no) es la propiedad complementaria.

**Q7.6 —** Quitar el bit setuid impide que `pkexec` sea usable como objetivo de *escalada de privilegios* — PwnKit (CVE-2021-4034) necesitaba que pkexec fuera setuid-root para importar. **No** mitiga CVE-2021-3560, que es un bug en el propio `polkitd`: una condición de carrera en cómo el demonio resuelve el proceso solicitante permite que un llamante sin privilegios haga que su solicitud se evalúe como `uid=0`, sin `pkexec` involucrado. El control para eso es **parchear polkit**. Más en general, quitar el bit endurece una vía; mantener el paquete actualizado es lo que aborda el demonio, la superficie D-Bus y el motor de reglas.

---

### Ejercicio 8

**Q8.1 —** `block` significa "no autorizar este dispositivo" — el kernel se niega a vincular drivers, así que queda no funcional, pero **permanece enumerado y visible**: aparece en `lsusb` y en `usbguard list-devices` con un objetivo `block`. `reject` significa "eliminar este dispositivo del sistema por completo" — USBGuard le indica al kernel que lo desconecte lógicamente, así que **desaparece de `lsusb`** como si estuviera desenchufado. `block` es el mejor valor por defecto (es reversible en el lugar con `allow-device`, y preserva un registro de auditoría de qué se conectó); `reject` es apropiado para clases de dispositivos que nunca querés ver y de las que querés que el kernel deje de llevar registro.

**Q8.2 —** Porque el teclado interno y el trackpad de una laptop están conectados a **hubs raíz y controladores internos** USB. Si `PresentControllerPolicy` es cualquier cosa distinta de `keep` (por ejemplo `apply-policy` con un `ImplicitPolicyTarget=block`), arrancar el demonio puede bloquear los controladores mismos — llevándose el teclado con ellos. Quedás entonces en un prompt de inicio de sesión sin manera de tipear, y las únicas recuperaciones son una sesión serie/por red o arrancar un medio de rescate. `keep` preserva el estado de autorización que los controladores ya tenían al arrancar el demonio.

**Q8.3 —** El hash de dispositivo de USBGuard se calcula sobre el **conjunto de descriptores** del dispositivo — ID de fabricante, ID de producto, cadenas de nombre/fabricante del dispositivo, número de serie y los descriptores de interfaz — produciendo una huella de la identidad declarada del dispositivo. Es más fuerte que `id 046d:c31c` porque fabricante:producto identifica un *modelo*, no una *unidad*: cualquier dispositivo que declare esos IDs de 16 bits coincide, y un dispositivo USB programable (Rubber Ducky, Bash Bunny, un microcontrolador flasheado) puede declarar los IDs que se le antojen por unos centavos. El hash además vincula el número de serie y la disposición de interfaces, así que un dispositivo sustituido con distinto serial o una interfaz extra ya no coincide. Sigue siendo información autodeclarada — un atacante decidido que clone cada campo del descriptor va a coincidir — así que tratá al hash como algo que eleva el costo sustancialmente, no como una atestación criptográfica del dispositivo.

**Q8.4 —** **No.** Un dispositivo de inyección de pulsaciones *es* un teclado HID: presenta la clase de interfaz `03` y una regla que permite toda la clase `03` lo permite. Este es exactamente el modelo de amenaza BadUSB. Lo que ayuda: (a) permitir HID solo por **hash o número de serie** para los teclados específicos que poseés, en lugar de por clase; (b) hacer `reject` de cualquier dispositivo que presente una interfaz HID **combinada con** interfaces de almacenamiento/red (`with-interface all-of { 03:*:* 08:*:* }`); (c) políticas de bloqueo de pantalla más filtrado de entrada a nivel de sesión; (d) organizativamente, control físico de puertos. USBGuard es una capa de autorización de dispositivos; no puede distinguir un teclado legítimo de uno malicioso que es idéntico a nivel de descriptores.

**Q8.5 —** Estos son operadores de conjunto sobre la lista de descriptores de interfaz del dispositivo. `equals` — el conjunto de interfaces del dispositivo debe coincidir **exactamente** con el conjunto listado (ni más, ni menos). `one-of` — **al menos una** interfaz listada está presente. `none-of` — **ninguna** interfaz listada está presente. `all-of` — **todas** las interfaces listadas están presentes, y puede haber otras también. `equals` es el más estricto y la elección correcta para un dispositivo conocido; `one-of` es lo correcto para "bloquear cualquier cosa que tenga una interfaz de almacenamiento masivo"; `all-of` es lo correcto para detectar patrones de dispositivos compuestos como HID+almacenamiento.

**Q8.6 —** Dos cualesquiera de: (a) **un dispositivo autorizado que después se comporta mal** — USBGuard autoriza al momento de la conexión y no inspecciona el tráfico posterior; (b) **ataques de firmware contra el controlador USB o el propio firmware del dispositivo**, por debajo de la capa de descriptores; (c) **ataques DMA sobre Thunderbolt/USB4**, que son un problema de PCIe abordado por la IOMMU y la Kernel DMA Protection, no por la autorización de dispositivos USB; (d) **exfiltración de datos vía un dispositivo permitido** — un pendrive USB en la lista blanca todavía puede salir caminando del edificio, lo cual es un problema de cifrado y DLP; (e) **ataques eléctricos** ("USB Killer"), que ningún control de software aborda.

---

### Ejercicio 9

**Q9.1 —** Porque `/etc/security/limits.conf` lo lee el módulo PAM `pam_limits.so`, y **los servicios de systemd no pasan por una pila PAM**. systemd hace fork y ejecuta el servicio directamente desde PID 1, aplicando solo las directivas de recursos de la unidad; no hay fase `session` y por lo tanto no hay `pam_limits`. Dos correcciones: **(a) la correcta** — establecer los límites nativamente en la unidad: `LimitNPROC=60`, `LimitNOFILE=4096`, `TasksMax=50`, idealmente en un drop-in. **(b)** Agregar `PAMName=<stack>` a la unidad para que systemd sí abra una sesión PAM para ella — legítimo pero más pesado, y apropiado solo cuando querés específicamente la semántica completa de sesión PAM (es lo que hacen `systemd --user` y los servicios de inicio de sesión).

**Q9.2 —** `soft` es el valor actualmente aplicado; `hard` es el techo hasta el que puede elevarse el valor soft; `-` establece ambos a la vez al mismo valor, volviendo el límite no elevable. Un **usuario no root puede elevar su límite soft hasta su límite hard**, y puede bajar cualquiera de los dos — pero nunca puede elevar un límite hard. En consecuencia, un límite `soft` es una barandilla contra accidentes, mientras que un límite `hard` (o `-`) es el control de seguridad. Escribir `@labusers soft nproc 40` solo es casi carente de sentido si el límite hard sigue siendo 15693.

**Q9.3 —** `RLIMIT_NPROC` se cuenta **por UID real a lo largo de todo el sistema**, no por sesión ni por inicio de sesión. Así que un operador que ya está corriendo 55 procesos entre tres sesiones SSH y un trabajo de cron choca contra un `hard nproc 60` y **no puede abrir una sesión nueva en absoluto** — `sshd` falla al hacer fork de la shell, y el error parece un fallo de autenticación. La misma trampa muerde a las cuentas de servicio que corren muchos workers. Evitalo: dimensionando `nproc` a partir del pico observado más un margen generoso; nunca aplicando un `nproc` bajo a `root` ni a `*` (que incluye a root en muchas pilas); prefiriendo `TasksMax=` basado en cgroups sobre el slice de usuario, que se aplica a nivel de cgroup con semántica de fallo más clara; y probando siempre desde una sesión *nueva* mientras mantenés una sesión de root existente abierta.

**Q9.4 —** `LimitNPROC=` establece el rlimit POSIX `RLIMIT_NPROC`, que el kernel cuenta **por UID real** y que se hereda a través de `fork`/`exec`. `TasksMax=` establece el controlador **`pids.max` de cgroup v2** sobre el cgroup de la unidad, contando cada tarea de ese cgroup sin importar el UID. **`TasksMax=` sobrevive a un cambio setuid**: si el servicio baja de root a otro usuario, o lanza ayudantes bajo distintos UIDs, el límite del cgroup sigue aplicándose a la unidad entera, mientras que `RLIMIT_NPROC` empieza a contar contra la cuota separada de otro UID (y es célebre por no aplicarse a root en absoluto en algunos caminos). Para contención, `TasksMax=` es el confiable; usá `LimitNPROC=` para compatibilidad con software que lee sus propios rlimits.

**Q9.5 —** Elevar un límite **hard** requiere `CAP_SYS_RESOURCE`. Un usuario normal que llama a `ulimit -n 8192` cuando el límite hard es 4096 está pidiendo implícitamente exceder el techo, y `setrlimit(2)` devuelve `EPERM`. Root (o cualquier proceso con `CAP_SYS_RESOURCE`) puede elevar el límite hard libremente, así que el mismo comando tiene éxito. Notá la asimetría que hace de esto una puerta de una sola vía: cualquier proceso puede **bajar** su límite hard, y el descenso es irreversible para ese proceso y todos sus hijos — lo cual es en sí mismo una primitiva de endurecimiento útil.

**Q9.6 —** Porque tres subsistemas independientes pueden producir o permitir un volcado cada uno. **(1)** `fs.suid_dumpable` gobierna si el kernel volcará un proceso que cambió privilegios (setuid/setgid/capacidades) — los volcados de mayor valor, ya que su memoria contiene secretos privilegiados. **(2)** `RLIMIT_CORE` (vía `limits.conf` para sesiones de inicio, `LimitCORE=`/`DefaultLimitCORE=` para unidades de systemd) gobierna el tamaño máximo de core por proceso; un valor distinto de cero en cualquier lado vuelve a habilitar los volcados para ese contexto. **(3)** `kernel.core_pattern` decide *adónde* va el volcado — en un host con systemd lo canaliza a `systemd-coredump`, que tiene su propia política de almacenamiento en `coredump.conf`, y que alegremente almacenará volcados incluso cuando el `ulimit -c` de la shell sea 0, porque el manejador de la tubería recibe el volcado directamente. Configurá uno solo y los volcados igual aterrizan en algún lado. Esta estratificación — política del kernel, límite por proceso, manejador de recolección — es un buen modelo general para el endurecimiento del host: los controles se componen, y una sola perilla rara vez es el control completo.

---

### Ejercicio 10

**Q10.1 —** De más débil a más fuerte:
1. **`usermod -s /usr/sbin/nologin`** — bloquea únicamente una shell interactiva. La autenticación SSH por clave pública todavía *tiene éxito*; el usuario simplemente recibe el mensaje de nologin. Cualquier cosa que no necesite una shell sigue funcionando o funciona parcialmente: reenvío de puertos, en algunas configuraciones `scp`/`sftp` (si el subsistema se invoca sin la shell de inicio), trabajos de cron, `su - user -s /bin/bash` desde root, y cualquier demonio corriendo como ese UID.
2. **`passwd -l` (equivalente a `usermod -L`)** — antepone un `!` al hash de la contraseña, así que ninguna contraseña coincidirá jamás. La autenticación por contraseña está muerta. **Las claves SSH, GSSAPI/Kerberos, los módulos PAM que no consultan el hash, y `su` desde root siguen funcionando todos** — como se demostró en el paso 5(a). Bloquear la contraseña es el más sobrevalorado de los tres.
3. **`chage -E 0` (o `usermod --expiredate 1`)** — establece la expiración de la cuenta en el pasado. La fase de cuenta de `pam_unix` rechaza el inicio de sesión sin importar *cómo* se autenticó el usuario, así que SSH por clave, contraseña y Kerberos fallan todos. Esto es lo más parecido a un interruptor de apagado real sin llegar a `userdel`.
Una deshabilitación completa aplica los tres, más eliminar `authorized_keys`, matar las sesiones vivas (`pkill -u`), y revocar credenciales de Kerberos/LDAP y reglas de sudo.

**Q10.2 —** `/etc/nologin` es creado y eliminado por **`systemd-user-sessions.service`**: elimina el archivo cuando el sistema alcanza `multi-user.target` (permitiendo inicios de sesión) y lo crea durante el apagado (para detener nuevos inicios de sesión mientras los servicios se detienen). Así que un `/etc/nologin` creado a mano es una bandera de mantenimiento de *tiempo de ejecución* que **no** sobrevive a un reinicio. Si necesitás inicios de sesión bloqueados a través de un reinicio, tenés que detener o enmascarar la vía de inicio de sesión misma — por ejemplo `systemctl mask systemd-user-sessions.service` (lo cual bloquea inicios de sesión de forma persistente, y es un riesgo de quedarte afuera), o deshabilitar `sshd` y usar acceso por consola.

**Q10.3 —** `-xdev` mantiene a `find` en un único sistema de archivos. Se usa para evitar descender a `/proc`, `/sys`, `/run`, montajes de red (NFS/CIFS — potencialmente enormes y lentos, y sus bits SUID son problema del servidor remoto, no de este host), y montajes bind y capas de contenedores bajo `/var/lib/docker` que reportarían el mismo archivo muchas veces. Sin eso, el escaneo es lento, ruidoso y lleno de duplicados. **Con** eso te perdés cualquier cosa en un sistema de archivos local *montado por separado* — muy comúnmente `/home`, `/var`, `/tmp`, `/opt` y `/usr/local` en un servidor particionado, que es exactamente donde estaría un binario SUID plantado por un atacante. El patrón correcto es por lo tanto enumerar los puntos de montaje locales y correr el escaneo una vez por sistema de archivos — por ejemplo iterando sobre `findmnt -rno TARGET -t ext4,xfs,btrfs` — en lugar de confiar en una única pasada con `-xdev` desde `/`. Notá también que `nosuid` en un montaje derrota a SUID sin importar el bit, así que las opciones de montaje pertenecen a la misma auditoría.

**Q10.4 —** `cap_dac_read_search` evita **todas las verificaciones de permisos de lectura y búsqueda en directorios del sistema de archivos**. Su usuario puede leer *cada archivo del sistema*: `/etc/shadow`, cada clave privada, cada clave de certificado TLS, cada credencial de base de datos, cada directorio home de usuario, y el contenido de `/proc/<pid>/environ` de otros procesos. Es discutiblemente peor que SUID root *para un modelo de amenaza de confidencialidad* por dos razones: es **invisible para la auditoría estándar `find -perm -4000`** que la mayoría de los administradores y muchas listas de verificación ejecutan, y otorga acceso total de lectura sin ninguna señal acompañante de "esto es un binario privilegiado" en el modo del archivo — `ls -l` muestra un ejecutable ordinario. (Para un modelo de amenaza de *integridad* SUID root es peor, ya que también otorga escritura.) Emparejá siempre el inventario SUID con `getcap -r /`.

**Q10.5 —** Porque `dpkg` registra la propiedad y los permisos previstos de cada archivo que instala, y al actualizar los **restaura** — un simple `chmod u-s /usr/bin/chfn` se revierte silenciosamente la próxima vez que se actualice el paquete `passwd`/`shadow-utils`, sin error y sin entrada de log. `dpkg-statoverride` registra una excepción local en la base de datos de dpkg, así que el gestor de paquetes aplica *tu* modo en cada desempaquetado subsiguiente. La lección general aplica más allá de Debian: cualquier endurecimiento de permisos que pelee contra el gestor de paquetes debe registrarse en algún lugar donde el gestor de paquetes (o tu herramienta de gestión de configuración) lo vuelva a aplicar, o es temporal.

---

### Ejercicio 11

**Q11.1 —** Porque casi todo control de este laboratorio tiene dos estados distintos — *aplicado ahora en tiempo de ejecución* y *configurado para aplicarse al arrancar* — y solo el segundo es duradero. Los valores de `sysctl -w`, un `systemctl start`, un dispositivo USB autorizado manualmente y un `ulimit` en la shell actual pasan todos una verificación previa al reinicio siendo puro estado de tiempo de ejecución que se desvanece. Inversamente, un cambio escrito solo en un archivo de configuración (una directiva de GRUB que aún no pasó por `update-grub`, un parámetro de kernel agregado a `/etc/default/grub`) no pasa ninguna verificación de tiempo de ejecución. El reinicio es lo que colapsa "configurado" y "efectivo" en una sola observación. También atrapa la falla que más importa operativamente: un cambio de endurecimiento que hace que la máquina **no arranque** o **no acepte inicios de sesión** — algo que querés descubrir en una ventana de mantenimiento, no seis semanas después durante un evento de energía no relacionado.

**Q11.2 —** **No es una falla — la afirmación está mal.** En un host con systemd `kernel.core_pattern` normalmente es `|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h`, porque systemd instala su propio recolector; esa es la configuración esperada y soportada. Canalizar a `/bin/false` es una manera de suprimir volcados, pero pelea contra la plataforma y rompe herramientas legítimas de diagnóstico de fallos. La afirmación correcta es verificar la **política**, no el patrón: verificá `Storage=none` (y opcionalmente `ProcessSizeMax=0`) en el `coredump.conf` fusionado, junto con `fs.suid_dumpable=0` y `DefaultLimitCORE=0:0` — es decir, `systemd-analyze cat-config systemd/coredump.conf | grep -E '^(Storage|ProcessSizeMax)'`. Afirmá sobre el resultado buscado; no codifiques a mano una implementación particular de él.

**Q11.3 —** `systemctl --failed` solo atrapa unidades cuyo **proceso principal salió con código distinto de cero o fue matado**. Un demonio que captura su propio `EACCES`, registra una advertencia y sigue corriendo se ve perfectamente saludable. Detectalo: (a) leyendo el journal de la propia unidad para la ventana posterior al cambio — `journalctl -u <unit> --since "$(systemctl show -p ActiveEnterTimestamp --value <unit>)" -p warning`; (b) vigilando denegaciones `EPERM`/`EACCES` del sandbox mismo, que systemd registra, y muertes por seccomp — `journalctl -b | grep -Ei 'seccomp|Operation not permitted|Permission denied'` y registros `SECCOMP` basados en `auditctl`; (c) haciendo strace del proceso en ejecución contra el sandbox — `strace -f -e trace=file -p $(systemctl show -p MainPID --value <unit>)`; (d) de forma más confiable, una **prueba funcional de punta a punta** de lo que se supone que el servicio produce — ¿apareció el archivo de backup, llegó la métrica, mostró `chronyc tracking` una fuente sincronizada? Esta es la regla general para el trabajo de sandboxing: el puntaje de exposición te dice que el sandbox está apretado, solo una prueba funcional te dice que el servicio todavía funciona.

**Q11.4 —**
- **Servidor expuesto a internet: aislamiento (sandboxing) de unidades systemd (Ejercicio 6)**, aplicado a los demonios expuestos a la red. La vía de ataque realista es la ejecución remota de código en un servicio a la escucha, y las directivas de sandbox son las que deciden si esa RCE rinde una shell en un espacio de nombres sin capacidades, sin acceso de escritura fuera de un único directorio de estado, con un filtro de llamadas al sistema `@system-service` y sin salida de red — o root en el host. Las contraseñas de GRUB y USBGuard son irrelevantes para un atacante que nunca está físicamente presente. (Reducir la cantidad de servicios a la escucha en primer lugar, Ejercicio 2, es el segundo más cercano y es un prerrequisito: el sandbox más barato es un servicio que no está instalado.)
- **Kiosco físicamente accesible: cifrado de disco completo, con la cadena de arranque del Ejercicio 3 como su mecanismo de aplicación.** El ataque realista es alguien con las manos sobre la máquina: arrancar a una shell de root con `init=/bin/bash`, arrancar desde un pendrive USB, o llevarse el disco. Una contraseña de superusuario de GRUB más contraseña de firmware, orden de arranque bloqueado y Secure Boot cierran los dos primeros; solo LUKS (objetivo 331.3) cierra el tercero. USBGuard es el fuerte segundo control acá, ya que el mismo acceso físico habilita BadUSB y la exfiltración por almacenamiento masivo.
El punto de fondo es que "endurecimiento" no es una lista de verificación fija — el mismo catálogo de controles se ordena de forma distinta según la exposición del host, y poder justificar ese ordenamiento es lo que el objetivo está evaluando.

</details>

---

## Referencias

- LPI, *Exam 303-300 Objectives (LPIC-3 Security, version 3.0)* — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- GNU, *GRUB 2 Manual — Security* — <https://www.gnu.org/software/grub/manual/grub/grub.html#Security>
- The Linux Kernel Archives, *Documentation: sysctl/kernel.rst* — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html>
- The Linux Kernel Archives, *Documentation: sysctl/fs.rst* — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html>
- The Linux Kernel Archives, *Yama LSM* — <https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html>
- The Linux Kernel Archives, *Address space layout randomization / `personality(2)` semantics* — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html#randomize-va-space>
- freedesktop.org, *systemd.exec(5) — Sandboxing directives* — <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
- freedesktop.org, *systemd.resource-control(5)* — <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
- freedesktop.org, *systemd-analyze(1) — `security` verb* — <https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html>
- freedesktop.org, *sysctl.d(5)* — <https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html>
- freedesktop.org, *systemd-coredump(8) and coredump.conf(5)* — <https://www.freedesktop.org/software/systemd/man/latest/coredump.conf.html>
- freedesktop.org, *polkit — Reference Manual* — <https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html>
- freedesktop.org, *polkit — Writing polkit rules (`polkit.js`)* — <https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html#polkit-rules>
- USBGuard Project, *Documentation and rule language* — <https://usbguard.github.io/documentation/>
- man7.org, *`setrlimit(2)`*, *`pam_limits(8)`*, *`capabilities(7)`*, *`seccomp(2)`*, *`nologin(5)`*, *`personality(2)`* — <https://man7.org/linux/man-pages/>
- Red Hat, *Configuring GRUB and protecting boot entries (RHEL 9 Security hardening)* — <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/>
- Debian, *Securing Debian Manual* — <https://www.debian.org/doc/manuals/securing-debian-manual/>
- MITRE, *CVE-2021-4034 (PwnKit)* — <https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-4034>
- MITRE, *CVE-2021-3560 (polkit authentication bypass)* — <https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2021-3560>