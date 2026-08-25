# 332.1 — Endurecimiento del host (Host Hardening)

**LPIC-3 303-300 (Security), v3.0.0 · Tema 332: Seguridad del host · Peso 5/60 ≈ 8,33 %**

---

## 1. El problema en producción

Un host Linux en producción no es un único límite de confianza: es una pila de límites, y cada uno falla de forma independiente:

```
┌─────────────────────────────────────────────────────────────────┐
│ Application / workload                                          │
├─────────────────────────────────────────────────────────────────┤
│ Service sandbox      systemd unit directives, seccomp, caps     │  ← 332.1
├─────────────────────────────────────────────────────────────────┤
│ MAC layer            SELinux / AppArmor                         │  ← 333.2
├─────────────────────────────────────────────────────────────────┤
│ DAC layer            uid/gid, ACLs, file capabilities, SUID     │  ← 333.1
├─────────────────────────────────────────────────────────────────┤
│ Kernel               sysctl, ASLR/NX, lockdown, module policy   │  ← 332.1
├─────────────────────────────────────────────────────────────────┤
│ Firmware / boot      UEFI Secure Boot, GRUB 2 password, TPM     │  ← 332.1
├─────────────────────────────────────────────────────────────────┤
│ Physical             USB ports, DMA, chassis, console           │  ← 332.1
└─────────────────────────────────────────────────────────────────┘
```

El endurecimiento del host es la disciplina de hacer que cada una de esas capas le cueste algo al atacante, bajo el supuesto de que la capa superior *ya* falló. Ese supuesto no es pesimismo, es aritmética: una flota de 500 nodos que corre 40 paquetes cada uno está corriendo 20 000 piezas de código de terceros, y la probabilidad de que todas estén libres de ejecución remota de código en una ventana de cinco años es cero.

### 1.1 Los tres modos de fallo que el endurecimiento realmente atiende

| Modo de fallo | Lo que el atacante ya tiene | Lo que el endurecimiento debe negar |
|---|---|---|
| **Escalada posterior a la explotación** | Ejecución de código como una cuenta de servicio sin privilegios (`www-data`, `nobody`, un uid de contenedor) | Primitivas de exploit del kernel, rutas SUID, `/etc` escribible, `ptrace` de otros usuarios, `kexec`, carga de módulos |
| **Movimiento lateral / persistencia** | Una shell válida de bajo privilegio | Material de credenciales legible, servicios a la escucha innecesarios, egreso sin restricciones, puntos de persistencia en cron/systemd |
| **Físico / evil-maid** | Consola o acceso presencial durante unos minutos | Arranque en modo monousuario, edición de la línea de comandos del kernel, inyección USB HID, DMA, disco sin cifrar |

### 1.2 Por qué "endurecer el host" es la unidad de trabajo equivocada

El error arquitectónico más común es tratar el endurecimiento como un *evento* (una lista de verificación ejecutada una vez durante el aprovisionamiento) en lugar de una *propiedad* (un estado afirmado de forma continua). Tres consecuencias:

1. **La deriva es invisible sin una línea base.** Un `sysctl` escrito en `/etc/sysctl.d/99-hardening.conf` en 2024 y silenciosamente ensombrecido en 2026 por un CNI de Kubernetes que deja caer `/etc/sysctl.d/99-zzz-calico.conf` produce un host que *pasa la auditoría en el momento del aprovisionamiento* y queda mal para siempre. El orden de carga importa y es lexicográfico — ver §7.2.
2. **El endurecimiento que no es reversible es un generador de caídas.** `kernel.modules_disabled=1`, `kernel.kexec_load_disabled=1` y `kernel.unprivileged_bpf_disabled=1` son interruptores de un solo sentido hasta el reinicio. USBGuard con una política mala te deja afuera de tu propio teclado. Una contraseña de GRUB en un host sin consola fuera de banda vuelve la máquina irrecuperable tras una actualización de kernel fallida.
3. **El endurecimiento no medido es teatro.** `systemd-analyze security`, `checksec`, `oscap` y `/sys/devices/system/cpu/vulnerabilities/` emiten estado legible por máquina. Si tu endurecimiento no está afirmado por una prueba que corre en CI y sobre la flota viva, no conocés su estado.

La regla de diseño para el resto de este material: **cada control tiene un mecanismo, un compromiso, un comando de verificación y un modo de fallo documentado.**

---

## 2. La cadena de arranque: firmware, Secure Boot, GRUB 2

### 2.1 Mecánica de la amenaza

Un atacante en la consola física con un menú de GRUB 2 sin protección no necesita exploit ni contraseña:

```
# At the GRUB menu, press 'e', append to the linux line:
linux /vmlinuz-6.1.0-18-amd64 root=/dev/mapper/vg0-root ro init=/bin/bash
# Ctrl-X
```

El kernel arranca, el `PID 1` es `/bin/bash` corriendo como `uid 0` sin PAM, sin autenticación, sin auditoría. `mount -o remount,rw /` y el host es suyo. Variantes: `systemd.unit=rescue.target`, `rd.break` (dracut, cae a una shell en el initramfs *antes* del pivote del sistema de archivos raíz), `single`, `1`.

Por eso la contraseña de GRUB no es un "sería lindo tenerlo" para nada que esté en una jaula de colocación, una oficina sucursal, un rack de laboratorio o una laptop.

**Qué te compra y qué no te compra una contraseña de GRUB:**

| Control | Impide editar la cmdline | Impide arrancar otro medio | Impide leer el disco offline | Impide un implante a nivel firmware |
|---|---|---|---|---|
| Contraseña de superusuario de GRUB 2 | ✅ | ❌ | ❌ | ❌ |
| Contraseña de administrador UEFI/BIOS + bloqueo del orden de arranque | ✅ (indirectamente) | ✅ | ❌ | ❌ |
| UEFI Secure Boot + kernel firmado + `module.sig_enforce=1` | parcial (se rechazan kernels sin firmar) | ✅ para cargadores sin firmar | ❌ | parcial |
| Cifrado de disco completo LUKS (Tema 331.3) | ❌ | ❌ | ✅ | ❌ |
| Arranque medido con TPM 2.0 + clave LUKS sellada a PCR | ❌ | ❌ | ✅ | ✅ (detecta) |

Las capas **no** son sustitutas unas de otras. Una contraseña de GRUB sobre un disco sin cifrar te compra unos noventa segundos de tiempo del atacante: en su lugar arranca una imagen live por USB. La línea base física completa es: contraseña de firmware → orden de arranque restringido al disco interno → Secure Boot en modo enforcing → contraseña de superusuario de GRUB → LUKS con sellado TPM.

### 2.2 Generar el hash de la contraseña

GRUB 2 guarda un hash PBKDF2-SHA512, nunca una contraseña en texto claro.

```console
$ grub-mkpasswd-pbkdf2 --iteration-count=210000 --salt=32
Enter password:
Reenter password:
PBKDF2 hash of your password is grub.pbkdf2.sha512.210000.C1E5C0A9F3E0A4D6B7C8391A2B4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F.9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B
```

En RHEL/Fedora el binario es `grub2-mkpasswd-pbkdf2`. El conteo de iteraciones por defecto es 10000, que es bajo para los estándares de 2026 tratándose de un hash crackeable offline; subilo. La cadena del hash puede almacenarse con seguridad en la gestión de configuración — no es un secreto en el sentido en que lo es una clave privada, pero tratala como tal de todos modos (§2.6).

### 2.3 Implementación en Debian / Ubuntu

La configuración de GRUB es generada; **nunca edites `/boot/grub/grub.cfg` directamente** — la sobrescribe la siguiente actualización del paquete del kernel.

`/etc/grub.d/40_custom`:

```bash
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.

set superusers="grubadmin"
password_pbkdf2 grubadmin grub.pbkdf2.sha512.210000.C1E5C0A9F3E0A4D6B7C8391A2B4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F.9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B7C6D5E4F3A2B1C0D9E8F7A6B5C4D3E2F1A0B9C8D7E6F5A4B3C2D1E0F9A8B
```

Por defecto, declarar `superusers` bloquea **todas** las entradas del menú: la máquina no arrancará sin atención. Eso casi nunca es lo que querés en un servidor. Permití que las entradas normales arranquen sin contraseña pero seguí exigiéndola para *editarlas*, agregando `--unrestricted` a las entradas de menú generadas:

`/etc/default/grub`:

```bash
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=integrity module.sig_enforce=1 mitigations=auto"

# Do not offer a recovery (single-user) entry at all.
GRUB_DISABLE_RECOVERY="true"

# Boot the default entries without a password; still require one to edit them.
GRUB_DISABLE_SUBMENU=y
```

El `/etc/grub.d/10_linux` de Debian construye la clase de la entrada a partir de `$CLASS`. La manera soportada de agregar `--unrestricted` sin parchear el script de la distribución es un pequeño generador propio que corra *antes* de él:

`/etc/grub.d/09_unrestricted`:

```bash
#!/bin/sh
# Mark generated Linux menu entries as --unrestricted so that a superuser
# password is required to EDIT an entry but not to BOOT the default one.
# Without this, `set superusers` makes every boot interactive.
cat <<'EOF'
# 09_unrestricted: applied by 10_linux via CLASS
EOF
```

En la práctica, en Debian el enfoque pragmático y ampliamente usado es un `sed` de guardia aplicado por la gestión de configuración sobre `/etc/grub.d/10_linux`:

```console
$ sudo sed -i 's/^CLASS="\(.*\)"$/CLASS="\1 --unrestricted"/' /etc/grub.d/10_linux
$ grep ^CLASS= /etc/grub.d/10_linux
CLASS="--class gnu-linux --class gnu --class os --unrestricted"
```

Regenerá y verificá:

```console
$ sudo update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.1.0-18-amd64
Found initrd image: /boot/initrd.img-6.1.0-18-amd64
Found linux image: /boot/vmlinuz-6.1.0-17-amd64
Found initrd image: /boot/initrd.img-6.1.0-17-amd64
Warning: os-prober will not be executed to detect other bootable partitions.
done

$ sudo grep -nE 'superusers|password_pbkdf2|--unrestricted' /boot/grub/grub.cfg | head
188:set superusers="grubadmin"
189:password_pbkdf2 grubadmin grub.pbkdf2.sha512.210000.C1E5C0A9...
201:menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class gnu --class os --unrestricted $menuentry_id_option 'gnulinux-simple-...' {
```

### 2.4 Implementación en RHEL / Fedora / Rocky

RHEL 8+ trae un ayudante hecho a medida. Escribe el hash en `/boot/grub2/user.cfg`, que es cargado por `/etc/grub.d/01_users`; `superusers` queda fijado en `root`.

```console
$ sudo grub2-setpassword
Enter password:
Confirm password:

$ sudo cat /boot/grub2/user.cfg
GRUB2_PASSWORD=grub.pbkdf2.sha512.10000.9F1B2C3D...E7A8B9C0

$ sudo ls -l /boot/grub2/user.cfg
-rw-------. 1 root root 199 Aug 24 09:12 /boot/grub2/user.cfg
```

RHEL 9 usa entradas BootLoader Spec (BLS) bajo `/boot/loader/entries/`, así que los cambios en la línea de comandos del kernel pasan por `grubby`, no por editar un `grub.cfg` generado:

```console
$ sudo grubby --update-kernel=ALL --args="slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=integrity"

$ sudo grubby --info=DEFAULT
index=0
kernel="/boot/vmlinuz-5.14.0-427.13.1.el9_4.x86_64"
args="ro crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M rd.lvm.lv=rl/root rd.lvm.lv=rl/swap slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=integrity"
root="/dev/mapper/rl-root"
initrd="/boot/initramfs-5.14.0-427.13.1.el9_4.x86_64.img"
title="Rocky Linux (5.14.0-427.13.1.el9_4.x86_64) 9.4 (Blue Onyx)"
id="a1b2c3d4e5f60718293a4b5c6d7e8f90-5.14.0-427.13.1.el9_4.x86_64"
```

Actualizá también el `GRUB_CMDLINE_LINUX` de `/etc/default/grub` para que los kernels *futuros* hereden los argumentos, y luego `grub2-mkconfig -o /boot/grub2/grub.cfg`.

### 2.5 Parámetros de endurecimiento de la línea de comandos del kernel

| Parámetro | Efecto | Costo / riesgo |
|---|---|---|
| `slab_nomerge` | Deshabilita la fusión de cachés SLAB/SLUB; elimina una clase grande de exploits cross-cache basados en heap grooming | ~1–3 % más de memoria de slab |
| `init_on_alloc=1 init_on_free=1` | Pone en cero las páginas del heap al asignar y liberar; neutraliza la mayoría de las fugas de información por use-after-free | 1–5 % de CPU en cargas con muchas asignaciones |
| `page_alloc.shuffle=1` | Aleatoriza el orden de la lista de libres en el asignador de páginas | Insignificante; leve pérdida de localidad de caché |
| `randomize_kstack_offset=on` | Aleatorización por syscall del desplazamiento de la pila del kernel | <1 % |
| `vsyscall=none` | Elimina la página `vsyscall` heredada de dirección fija (un ancla clásica de ROP) | Solo rompe binarios estáticos anteriores a 2013 |
| `debugfs=off` | `debugfs` no se monta ni se puebla | Rompe algunas herramientas de trazado y depuración de GPU |
| `lockdown=integrity` | Bloquea `/dev/mem`, módulos sin firmar, `kexec` de imágenes sin firmar, escrituras crudas a MSR/PCI | Rompe DKMS con módulos sin firmar, `perf` en algunas rutas, algunas herramientas de hipervisor |
| `module.sig_enforce=1` | Rechaza módulos del kernel sin firmar | Rompe de plano los módulos fuera del árbol que no hayas firmado |
| `mitigations=auto,nosmt` | Habilita todas las mitigaciones de vulnerabilidades de CPU y deshabilita SMT | 15–40 % de pérdida de rendimiento; ver §8 |
| `pti=on` | Fuerza el aislamiento de tablas de páginas independientemente de lo que reporte la CPU | 5–30 % en cargas con muchas syscalls |

`lockdown=integrity` y `module.sig_enforce=1` son los dos que más seguido causan una caída después del reinicio. Escalonalos: metelos primero en un grupo canario, confirmá que todos los módulos en `lsmod` están firmados (`modinfo <mod> | grep -i sig`), y recién después aplicalos a toda la flota.

### 2.6 Verificación y diagnóstico de fallos — cadena de arranque

```console
$ sudo stat -c '%a %U:%G %n' /boot/grub/grub.cfg /etc/grub.d/40_custom
600 root:root /boot/grub/grub.cfg
700 root:root /etc/grub.d/40_custom

$ mokutil --sb-state
SecureBoot enabled

$ sudo cat /sys/kernel/security/lockdown
none [integrity] confidentiality

$ sudo dmesg | grep -i 'kernel supported'
[    0.000000] Kernel is locked down from command line; see man kernel_lockdown.7
```

**La verificación del modo de emergencia que casi todo el mundo pasa por alto.** `emergency.service` y `rescue.service` de systemd ejecutan `sulogin`, que pide la contraseña de root. Si la cuenta root está bloqueada (`!` en `/etc/shadow`, el valor por defecto de las imágenes cloud de Debian/Ubuntu) *y* la unidad define `SYSTEMD_SULOGIN_FORCE=1`, systemd entrega una **shell de root sin autenticar**. Verificalo antes de suponer que tu contraseña de GRUB importa:

```console
$ systemctl cat emergency.service | grep -iE 'sulogin|Environment'
Environment=HOME=/root
ExecStart=-/usr/lib/systemd/systemd-sulogin-shell emergency

$ sudo passwd -S root
root L 2026-01-14 0 99999 7 -1
```

`L` significa bloqueada. O bien definís una contraseña de root fuerte (guardada en tu gestor de secretos), o enmascarás la ruta de emergencia y confiás en la recuperación por consola fuera de banda. Documentá cuál elegiste: un host con contraseña de GRUB, root bloqueado y sin iDRAC/iLO es un host que no vas a poder arreglar a las 03:00.

| Síntoma | Causa probable | Diagnóstico |
|---|---|---|
| El arranque se detiene en un prompt de usuario `grubadmin` | `superusers` definido sin `--unrestricted` en las entradas | Arrancar con medio de rescate, `grep -c -- --unrestricted /boot/grub/grub.cfg` |
| La contraseña de GRUB deja de funcionar tras actualizar el kernel | Se editó `grub.cfg` directamente en lugar de `/etc/grub.d/` | `grep superusers /etc/grub.d/*` — tiene que estar ahí, no solo en `grub.cfg` |
| `error: file '/boot/grub/i386-pc/normal.mod' not found` | Nunca se volvió a ejecutar `grub-install` tras un cambio de disco | `grub-install /dev/sda && update-grub` desde rescate |
| Un kernel firmado se niega a arrancar | Secure Boot activo, desajuste de shim/MOK | `mokutil --list-enrolled`, `dmesg \| grep -i 'Lockdown\|secure boot'` |
| Un módulo DKMS sin firmar falla tras `module.sig_enforce=1` | Módulo no registrado con una clave MOK | `modinfo <mod> \| grep sig`, `mokutil --import` |

---

## 3. Reducir la superficie de servicios

Cada socket a la escucha es un punto de entrada sin autenticar hasta que se demuestre lo contrario. Cada unidad habilitada es código que corre como root en el arranque.

### 3.1 Primero, el inventario

```console
$ systemctl list-units --type=service --state=running --no-pager
  UNIT                        LOAD   ACTIVE SUB     DESCRIPTION
  auditd.service              loaded active running Security Auditing Service
  chronyd.service             loaded active running NTP client/server
  cups.service                loaded active running CUPS Scheduler
  dbus-broker.service         loaded active running D-Bus System Message Bus
  nginx.service               loaded active running The nginx HTTP and reverse proxy server
  rpcbind.service             loaded active running RPC Bind
  sshd.service                loaded active running OpenSSH server daemon
  systemd-journald.service    loaded active running Journal Service
  systemd-logind.service      loaded active running User Login Management
  systemd-udevd.service       loaded active running Rule-based Manager for Device Events and Files

10 loaded units listed.
```

Cruzalo con lo que realmente es alcanzable:

```console
$ sudo ss -tulpen
Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process
udp    UNCONN  0       0              0.0.0.0:111          0.0.0.0:*      users:(("rpcbind",pid=712,fd=5))  uid:0 ino:20114 sk:1
udp    UNCONN  0       0            127.0.0.1:323          0.0.0.0:*      users:(("chronyd",pid=901,fd:5))  uid:993 ino:21455 sk:2
udp    UNCONN  0       0              0.0.0.0:631          0.0.0.0:*      users:(("cups-browsed",pid=944,fd=7)) uid:0 ino:21990 sk:3
tcp    LISTEN  0       4096           0.0.0.0:111          0.0.0.0:*      users:(("rpcbind",pid=712,fd=4))  uid:0 ino:20110 sk:4
tcp    LISTEN  0       511            0.0.0.0:80           0.0.0.0:*      users:(("nginx",pid=1204,fd=6))   uid:0 ino:23881 sk:5
tcp    LISTEN  0       128            0.0.0.0:22           0.0.0.0:*      users:(("sshd",pid=1010,fd=3))    uid:0 ino:22503 sk:6
tcp    LISTEN  0       128          127.0.0.1:631          0.0.0.0:*      users:(("cupsd",pid=943,fd=8))    uid:0 ino:21988 sk:7
```

`rpcbind` en `0.0.0.0:111` y `cups-browsed` en `0.0.0.0:631` en un servidor web son pasivo puro: ninguno se usa, ambos tienen historial de CVE, ambos son alcanzables desde la red.

### 3.2 stop vs disable vs mask vs purge

| Acción | Detiene ahora | Sobrevive al reinicio | Sobrevive a un `systemctl start` de otra unidad/administrador | Sobrevive a la reinstalación del paquete | Elimina el código del disco |
|---|---|---|---|---|---|
| `systemctl stop foo` | ✅ | ❌ | ❌ | ❌ | ❌ |
| `systemctl disable foo` | ❌ | ✅ | ❌ | ⚠️ (el preset puede rehabilitarlo) | ❌ |
| `systemctl disable --now foo` | ✅ | ✅ | ❌ | ⚠️ | ❌ |
| `systemctl mask foo` | ❌ | ✅ | ✅ (`Unit is masked`) | ✅ | ❌ |
| `systemctl mask --now foo` | ✅ | ✅ | ✅ | ✅ | ❌ |
| `apt purge` / `dnf remove` | ✅ | ✅ | ✅ | n/a | ✅ |

Dos trampas:

- **Activación por socket.** `systemctl disable cups.service` no hace nada si `cups.socket` está habilitado: la primera conexión arranca el servicio. Deshabilitá el socket *y* las unidades path/timer: `systemctl disable --now cups.socket cups.path cups.service`.
- **Presets.** `/usr/lib/systemd/system-preset/*.preset` rehabilita servicios al reinstalar el paquete. `mask` es el único estado que una actualización de paquete no puede deshacer en silencio.

```console
$ sudo systemctl mask --now cups.service cups.socket cups.path cups-browsed.service
Created symlink /etc/systemd/system/cups.service → /dev/null.
Created symlink /etc/systemd/system/cups.socket → /dev/null.
Created symlink /etc/systemd/system/cups.path → /dev/null.
Created symlink /etc/systemd/system/cups-browsed.service → /dev/null.

$ sudo systemctl start cups.service
Failed to start cups.service: Unit cups.service is masked.
```

Eliminar sigue siendo mejor que enmascarar donde la carga de trabajo lo permita: el código enmascarado es código que un futuro administrador puede desenmascarar, y código cuyas CVE siguen apareciendo en tu escáner:

```console
$ sudo apt purge -y cups cups-daemon cups-browsed rpcbind nfs-common
Reading package lists... Done
Building dependency tree... Done
The following packages will be REMOVED:
  cups* cups-browsed* cups-client* cups-common* cups-core-drivers* cups-daemon*
  cups-filters* cups-ppdc* cups-server-common* nfs-common* rpcbind*
0 upgraded, 0 newly installed, 11 to remove and 0 not upgraded.
After this operation, 27.4 MB disk space will be freed.
```

### 3.3 Superficie en el arranque

```console
$ systemd-analyze blame --no-pager | head -12
7.412s NetworkManager-wait-online.service
2.208s dracut-initqueue.service
1.884s systemd-udev-settle.service
 812ms lvm2-monitor.service
 640ms sssd.service
 401ms auditd.service
 388ms systemd-journal-flush.service
 233ms nginx.service
 190ms chronyd.service
 118ms sshd.service

$ systemctl list-unit-files --state=enabled --no-pager | wc -l
47
```

Cuarenta y siete unidades habilitadas en un nodo web de propósito único es el número a atacar. Cada una se evalúa contra una única pregunta: *si este binario tuviera mañana una RCE sin autenticar, ¿quedaría comprometido este host?* Si la respuesta es sí y el servicio no es necesario, se va.

---

## 4. Sandboxing de servicios con systemd

El sandboxing de servicios es el control de mayor apalancamiento de este objetivo: es por servicio, no requiere cambios en la aplicación, es completamente declarativo y está *puntuado* por una herramienta que viene con el sistema operativo.

### 4.1 Medir la línea base

```console
$ systemd-analyze security nginx.service --no-pager
  NAME                                                        DESCRIPTION                                                             EXPOSURE
✗ PrivateNetwork=                                             Service has access to the host's network                                     0.5
✗ User=/DynamicUser=                                          Service runs as root, option does not apply                                  0.4
✗ CapabilityBoundingSet=~CAP_SYS_ADMIN                        Service has administrator privileges                                         0.3
✗ CapabilityBoundingSet=~CAP_SYS_PTRACE                       Service has ptrace() debugging abilities                                     0.3
✗ RestrictAddressFamilies=~AF_PACKET                          Service may allocate packet sockets                                          0.2
✗ SystemCallFilter=~@debug                                    Service does not filter system calls                                         0.2
✗ ProtectKernelTunables=                                      Service may alter kernel tunables                                            0.2
✗ ProtectKernelModules=                                       Service may load kernel modules                                              0.2
✗ ProtectSystem=                                              Service has full access to the OS file hierarchy                             0.2
✗ ProtectHome=                                                Service has full access to home directories                                  0.2
✗ NoNewPrivileges=                                            Service processes may acquire new privileges                                 0.2
✗ PrivateDevices=                                             Service potentially has access to hardware devices                           0.2
✗ RestrictNamespaces=~CLONE_NEWUSER                           Service may create user namespaces                                           0.3
✗ MemoryDenyWriteExecute=                                     Service may create writable executable memory mappings                       0.1

→ Overall exposure level for nginx.service: 9.6 UNSAFE 😨
```

El puntaje es una heurística, no una prueba, pero pasar de 9,6 a 1,5 es pasar de "root con todo el sistema de archivos" a "un proceso sin privilegios que puede abrir dos rutas y una familia de sockets".

### 4.2 El catálogo de directivas

| Directiva | Mecanismo | Niega | Rotura común |
|---|---|---|---|
| `NoNewPrivileges=yes` | `PR_SET_NO_NEW_PRIVS` | Escalada por SUID/`setcap` desde dentro del servicio | Servicios que legítimamente llaman a `sudo`/`su` (p. ej. algunos agentes de respaldo) |
| `User=` / `DynamicUser=yes` | Cambio de uid/gid, uid transitorio | Correr como root en absoluto | Necesita `AmbientCapabilities` para puertos <1024; `DynamicUser` necesita `StateDirectory=` |
| `CapabilityBoundingSet=` | Conjunto acotante de capacidades | Todo lo no listado, de forma permanente | Quitar `CAP_NET_BIND_SERVICE` en un servicio a la escucha en :80 |
| `AmbientCapabilities=` | Conjunto ambiente | — (otorga) | Requiere que la capacidad también esté en el conjunto acotante |
| `ProtectSystem=strict` | Bind mount de solo lectura de toda la jerarquía | Escrituras en cualquier lado salvo `/dev`, `/proc`, `/sys` y `ReadWritePaths=` | Cualquier demonio que escriba logs/estado fuera de las rutas declaradas |
| `ProtectHome=yes` | `/home`, `/root`, `/run/user` vacíos | Leer datos de usuario / claves SSH | Servicios que legítimamente sirven `~/public_html` |
| `PrivateTmp=yes` | Espacio de nombres de montaje privado para `/tmp`, `/var/tmp` | Carreras de enlaces simbólicos en `/tmp`, espionaje de tmp entre servicios | Dos unidades que esperan un socket *compartido* en `/tmp` |
| `PrivateDevices=yes` | `/dev` privado solo con pseudodispositivos | Disco crudo, `/dev/mem`, `/dev/kmem`, hardware | Cualquier cosa que toque hardware real (agentes de respaldo, GPU) |
| `PrivateUsers=yes` | Espacio de nombres de usuario, root del host sin mapear | Privilegio de uid del host incluso tras una fuga | Necesita `user.max_user_namespaces>0` (ver §7.3) |
| `ProtectKernelTunables=yes` | `/proc/sys`, `/sys` en solo lectura | Escrituras de `sysctl` desde el servicio | Servicios que ajustan la pila de red al arrancar |
| `ProtectKernelModules=yes` | Bloquea `init_module`/`finit_module`, `delete_module` | Carga de rootkits | Nada legítimo en un servidor |
| `ProtectKernelLogs=yes` | Bloquea `syslog(2)`, `/dev/kmsg` | Lectura de punteros/fugas del kernel | Recolectores de logs que leen `/dev/kmsg` |
| `ProtectControlGroups=yes` | `/sys/fs/cgroup` en solo lectura | Fuga por cgroup-release-agent | Runtimes de contenedores, gestores de cgroups |
| `ProtectProc=invisible` + `ProcSubset=pid` | `hidepid`/`subset` de procfs | Enumerar procesos de otros usuarios y la mayor parte de `/proc/*` | Agentes de monitoreo (`node_exporter`, herramientas estilo `top`) |
| `RestrictNamespaces=yes` | Bloquea las banderas de espacios de nombres de `unshare`/`clone` | Cadenas de LPE del kernel basadas en user-ns | Runtimes de contenedores, Podman rootless |
| `RestrictSUIDSGID=yes` | Bloquea fijar S_ISUID/S_ISGID | Dejar una puerta trasera SUID | Gestores de paquetes, herramientas estilo `mkfs` |
| `RestrictRealtime=yes` | Bloquea `SCHED_FIFO`/`SCHED_RR` | DoS por prioridad de tiempo real | Audio, trading de baja latencia, algunas bases de datos |
| `RestrictAddressFamilies=` | seccomp sobre `socket(2)` | `AF_PACKET`, `AF_NETLINK`, `AF_BLUETOOTH`, … | `AF_NETLINK` se necesita más seguido de lo esperado (NSS de glibc, `getifaddrs`) |
| `LockPersonality=yes` | Bloquea `personality(2)` | Trucos de exploit que desactivan ASLR o usan ABI heredada | Capas de compatibilidad de 32 bits |
| `MemoryDenyWriteExecute=yes` | seccomp sobre `mmap`/`mprotect` W\|X | Inyectar shellcode en un proceso existente | **Rompe todo JIT**: JVM, V8/Node, LuaJIT, PyPy, .NET |
| `SystemCallFilter=@system-service` | Lista de permitidos seccomp-bpf | ~60 % de la tabla de syscalls, incl. `@mount`, `@reboot`, `@swap`, `@module` | Cualquier cosa que use una syscall fuera del conjunto |
| `SystemCallArchitectures=native` | Filtro de arquitectura de seccomp | Entrada de syscalls de 32 bits en x86_64 (una clase histórica de bypass) | Binarios de 32 bits |
| `SystemCallErrorNumber=EPERM` | Acción de seccomp | — (convierte el kill en `EPERM`) | Hace la depuración mucho más fácil que `SIGSYS` |
| `IPAddressDeny=any` + `IPAddressAllow=` | Filtro eBPF de sockets a nivel cgroup | Egreso hacia C2 / movimiento lateral | Fallos silenciosos de conexión; DNS necesita sus resolvedores permitidos |
| `DevicePolicy=closed` + `DeviceAllow=` | Controlador de dispositivos de cgroup | Todos los nodos de dispositivo salvo los listados | Cualquier cosa con un dispositivo real |
| `UMask=0077` | umask del proceso | Archivos legibles por todo el mundo creados por el servicio | Directorios de depósito multiusuario |

### 4.3 Un drop-in endurecido completo

Nunca edites la unidad del proveedor; usá un drop-in para que las actualizaciones del paquete sigan funcionando.

```console
$ sudo systemctl edit nginx.service
```

`/etc/systemd/system/nginx.service.d/10-hardening.conf`:

```ini
# Hardening drop-in for nginx.service
# Baseline: systemd-analyze security nginx.service  ->  1.4 OK
#
# Rationale for every relaxation is inline. Do not remove a comment when
# removing a directive: the next engineer needs to know why it was safe.

[Service]
# ---- Identity and privilege --------------------------------------------
User=nginx
Group=nginx
NoNewPrivileges=yes
# nginx binds :80 and :443. CAP_NET_BIND_SERVICE must be in BOTH the
# bounding set and the ambient set, otherwise the master process
# cannot bind and exits with "bind() to 0.0.0.0:80 failed (13: Permission denied)".
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# ---- Filesystem --------------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectProc=invisible
ProcSubset=pid
UMask=0077

# Everything nginx must be able to write to, enumerated explicitly.
# /var/log/nginx  : access and error logs
# /var/lib/nginx  : proxy/fastcgi/client body temp paths
# /run            : nginx.pid and unix sockets
RuntimeDirectory=nginx
RuntimeDirectoryMode=0750
LogsDirectory=nginx
LogsDirectoryMode=0750
StateDirectory=nginx
StateDirectoryMode=0750
ReadWritePaths=/var/log/nginx /var/lib/nginx /run

# ---- Kernel interfaces -------------------------------------------------
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes

# ---- Namespaces and execution ------------------------------------------
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
# nginx has no JIT; safe. Would break a service embedding LuaJIT (OpenResty).
MemoryDenyWriteExecute=yes
RemoveIPC=yes

# ---- Syscalls ----------------------------------------------------------
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
# EPERM instead of SIGSYS: a denied syscall shows up as an errno in the
# service log rather than a bare "killed by signal 31".
SystemCallErrorNumber=EPERM

# ---- Network -----------------------------------------------------------
# AF_UNIX is required for the master<->worker channel and for syslog.
# AF_NETLINK is required by glibc's getifaddrs()/NSS on some builds.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

# Egress allowlist: loopback, the upstream app tier, and the resolvers.
# Comment this block out and re-test if upstreams start timing out.
IPAddressDeny=any
IPAddressAllow=localhost
IPAddressAllow=10.42.0.0/16
IPAddressAllow=10.10.0.53/32
IPAddressAllow=10.10.1.53/32

# ---- Resource ceilings (see also 332.3) --------------------------------
LimitNOFILE=65535
LimitNPROC=512
LimitCORE=0
TasksMax=1024
MemoryMax=2G
```

Aplicá y volvé a medir:

```console
$ sudo systemctl daemon-reload
$ sudo systemctl restart nginx.service
$ systemd-analyze security nginx.service --no-pager | tail -3
✗ RestrictAddressFamilies=~AF_NETLINK                         Service may allocate netlink sockets                                         0.1

→ Overall exposure level for nginx.service: 1.4 OK 🙂
```

### 4.4 Probar un sandbox antes de ponerlo en producción

`systemd-run` aplica las mismas directivas a una unidad ad hoc, así que podés bisecar un sandbox roto sin tocar el servicio real:

```console
$ sudo systemd-run --pty --same-dir --wait --collect \
    -p ProtectSystem=strict -p PrivateDevices=yes -p SystemCallFilter=@system-service \
    /usr/sbin/nginx -t
Running as unit: run-u512.service; invocation ID: 4f2b...
Press ^] three times within 1s to disconnect TTY.
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

### 4.5 Diagnosticar un fallo de sandbox

La firma de una muerte por seccomp es `SIGSYS` (señal 31) o, con `SystemCallErrorNumber=EPERM`, un `Operation not permitted` sin explicación.

```console
$ sudo systemctl status nginx.service --no-pager -l
× nginx.service - The nginx HTTP and reverse proxy server
     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)
    Drop-In: /etc/systemd/system/nginx.service.d
             └─10-hardening.conf
     Active: failed (Result: signal) since Mon 2026-08-24 11:04:17 UTC; 3s ago
    Process: 4471 ExecStart=/usr/sbin/nginx (code=killed, signal=SYS)

Aug 24 11:04:17 web01 systemd[1]: nginx.service: Main process exited, code=killed, status=31/SYS
```

Determiná la syscall exacta desde el log de auditoría:

```console
$ sudo ausearch -m SECCOMP -ts recent -i | tail -4
type=SECCOMP msg=audit(2026-08-24 11:04:17.882:2291) : auid=unset uid=nginx gid=nginx ses=unset subj=system_u:system_r:httpd_t:s0 pid=4471 comm=nginx exe=/usr/sbin/nginx sig=SIGSYS arch=x86_64 syscall=io_uring_setup compat=0 ip=0x7f2c1d0a3b4d code=kill_process

$ ausyscall x86_64 425
io_uring_setup
```

`io_uring_setup` no está en `@system-service` (está en `@io-uring`, excluido por defecto desde systemd 250 con buenas razones). O bien quitás la bandera de compilación de `io_uring` de nginx o, si aceptás el riesgo, agregás `SystemCallFilter=@io-uring` explícitamente y registrás por qué.

Otros fallos de sandbox de alta frecuencia:

| Línea de log | Causa | Solución |
|---|---|---|
| `Read-only file system` en una ruta que no está en `ReadWritePaths=` | `ProtectSystem=strict` | Agregar la ruta, o usar `StateDirectory=`/`LogsDirectory=` |
| `bind(): Permission denied` en un puerto <1024 | Capacidad en el conjunto acotante pero no en el ambiente | Agregar `AmbientCapabilities=CAP_NET_BIND_SERVICE` |
| `getaddrinfo: Temporary failure in name resolution` | `AF_NETLINK` bloqueado o `IPAddressDeny=any` sin los resolvedores | Permitir `AF_NETLINK`; agregar las IP de los resolvedores a `IPAddressAllow=` |
| JVM/Node aborta al iniciar con `mprotect failed` | `MemoryDenyWriteExecute=yes` | Quitarlo para cargas con JIT; no existe una versión parcial |
| `node_exporter` reporta cero procesos | `ProtectProc=invisible` / `ProcSubset=pid` | No poner estas directivas en agentes de monitoreo |
| El servicio funciona y falla horas después | `IPAddressDeny=any` bloqueando un upstream de uso poco frecuente | `journalctl -u <svc> \| grep -i 'connect'`, ampliar la lista de permitidos |

---

## 5. Mitigaciones de exploits en espacio de usuario: ASLR, NX/DEP, PIE

### 5.1 Qué detiene realmente cada mitigación

| Mitigación | Capa | Clase de ataque derrotada | Se elude con |
|---|---|---|---|
| **NX / DEP** (bit `XD`, bandera `NX` de página) | CPU + tablas de páginas del kernel | Ejecutar shellcode inyectado desde la pila/heap | ROP / JOP / ret2libc |
| **ASLR** | Disposición de la VM del kernel | Direcciones fijas de gadgets y de libc | Fugas de información, poca entropía en 32 bits, binarios sin PIE, fuerza bruta en servidores que hacen fork |
| **PIE** (`-fPIE -pie`) | ELF de tipo `ET_DYN` | Dirección de carga fija del *ejecutable principal* — sin PIE, ASLR no aleatoriza el `.text` propio del binario | Fuga de información de la base del binario |
| **Canario de pila** (`-fstack-protector-strong`) | Compilador | Desbordamiento lineal de búfer en pila que sobrescribe la dirección de retorno guardada | Escrituras no lineales/indexadas, fuga del canario, sobrescribir un puntero antes del canario |
| **RELRO** (`-Wl,-z,relro,-z,now`) | Enlazador | Sobrescritura de la GOT → ejecución arbitraria de código | Sobrescritura de punteros a función fuera de la GOT |
| **FORTIFY_SOURCE** (`-D_FORTIFY_SOURCE=2/3`) | Compilador + glibc | Desbordamientos de `memcpy`/`sprintf`/`strcpy` con tamaños conocidos en tiempo de compilación o ejecución | Tamaños no derivables estática ni dinámicamente |
| **CET / IBT + Shadow Stack** (`-fcf-protection=full`) | CPU (Intel Tiger Lake+) | ROP (shadow stack), JOP (seguimiento de saltos indirectos) | Ataques solo de datos |
| **BTI + PAC** (`-mbranch-protection=standard`) | CPU (ARMv8.3+/8.5+) | ROP/JOP en aarch64 | Abuso de gadgets de firma |

### 5.2 ASLR: mecánica y control

`/proc/sys/kernel/randomize_va_space`:

| Valor | Aleatorizado | Notas |
|---|---|---|
| `0` | Nada | ASLR completamente deshabilitado. Solo para depuración; nunca en producción. |
| `1` | Pila, base de `mmap`, VDSO, bibliotecas compartidas | "Conservador" — el heap (`brk`) sigue adyacente al ejecutable |
| `2` | Lo anterior **más** `brk`/heap | Valor por defecto en toda distribución moderna. Este es el valor exigido. |

```console
$ cat /proc/sys/kernel/randomize_va_space
2

$ for i in 1 2 3; do grep -m1 '\[stack\]' /proc/self/maps; done
7ffd1a3c9000-7ffd1a3ea000 rw-p 00000000 00:00 0                          [stack]
7ffc884e5000-7ffc88506000 rw-p 00000000 00:00 0                          [stack]
7ffe4b71c000-7ffe4b73d000 rw-p 00000000 00:00 0                          [stack]
```

Tres bases de pila distintas en tres ejecuciones: ASLR está activo. Ahora el detalle crucial: **cualquier usuario sin privilegios puede deshabilitar ASLR para su propio proceso** mediante la personalidad `ADDR_NO_RANDOMIZE`:

```console
$ setarch $(uname -m) -R /bin/sh -c 'grep -m1 "\[stack\]" /proc/self/maps'
7ffffffde000-7ffffffff000 rw-p 00000000 00:00 0                          [stack]
$ setarch $(uname -m) -R /bin/sh -c 'grep -m1 "\[stack\]" /proc/self/maps'
7ffffffde000-7ffffffff000 rw-p 00000000 00:00 0                          [stack]
```

Direcciones idénticas. Esto es *por diseño* (`personality(2)` no es privilegiada) y es exactamente por eso que existe `LockPersonality=yes` en el sandbox de systemd: impide que un atacante con ejecución de código dentro de un servicio apague ASLR antes de lanzar un exploit de segunda etapa.

La entropía es ajustable:

```console
$ sysctl vm.mmap_rnd_bits vm.mmap_rnd_compat_bits
vm.mmap_rnd_bits = 28
vm.mmap_rnd_compat_bits = 8

$ sudo sysctl -w vm.mmap_rnd_bits=32
vm.mmap_rnd_bits = 32
```

28 bits es el valor por defecto en x86_64; 32 es el máximo y no cuesta nada más que una fragmentación levemente mayor del espacio de direcciones. El valor `compat` (32 bits) de 8 bits es trivialmente atacable por fuerza bruta — un argumento más para no tener binarios de 32 bits en el host, algo que `SystemCallArchitectures=native` refuerza.

### 5.3 NX / DEP

```console
$ grep -o ' nx ' /proc/cpuinfo | head -1
 nx

$ dmesg | grep -i 'NX (Execute Disable)'
[    0.000000] NX (Execute Disable) protection: active
```

NX se aplica por página. Verificá que un proceso real tenga una pila y un heap no ejecutables:

```console
$ grep -E '\[stack\]|\[heap\]' /proc/$(pgrep -n nginx)/maps
55d3a8f00000-55d3a8f21000 rw-p 00000000 00:00 0                          [heap]
7ffd3b6e1000-7ffd3b702000 rw-p 00000000 00:00 0                          [stack]
```

`rw-p` — lectura, escritura, **sin `x`**. Si alguna vez ves `rwxp` en el mapa de un proceso en producción, o bien el binario se enlazó con `-z execstack` o el proceso es un JIT. Encontralos:

```console
$ sudo awk '/rwxp/ {print FILENAME": "$0}' /proc/*/maps 2>/dev/null | head
$ 
```

La salida vacía es la respuesta correcta. Verificá directamente la bandera del ELF:

```console
$ readelf -lW /usr/sbin/nginx | grep -A1 GNU_STACK
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10
```

`RW` (no `RWE`) significa que se solicitó una pila no ejecutable en el momento del enlazado.

### 5.4 Auditar el endurecimiento del compilador en toda la flota

```console
$ checksec --file=/usr/sbin/sshd
RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH      Symbols         FORTIFY Fortified  Fortifiable  FILE
Full RELRO      Canary found      NX enabled    PIE enabled     No RPATH   No RUNPATH   No Symbols        Yes     9         25           /usr/sbin/sshd

$ checksec --file=/opt/vendor/bin/agentd
RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH      Symbols         FORTIFY Fortified  Fortifiable  FILE
Partial RELRO   No canary found   NX enabled    No PIE          No RPATH   RUNPATH      82 Symbols        No      0         14           /opt/vendor/bin/agentd
```

La segunda línea es lo que suele parecer un binario provisto por un proveedor, y es el hallazgo que importa: sin PIE, ASLR no aleatoriza su `.text`; sin canario, todo desbordamiento de pila es directamente explotable; RELRO parcial significa que la GOT es escribible; y un `RUNPATH` pone el secuestro de bibliotecas sobre la mesa. Ese binario pertenece a un sandbox de systemd bien ajustado, o fuera del host.

Barré todo el sistema:

```console
$ checksec --dir=/usr/bin --output=csv 2>/dev/null | awk -F, '$4=="No PIE"' | head -5
/usr/bin/legacytool,Partial RELRO,No canary found,No PIE,No RPATH,No RUNPATH,54 Symbols,No,0,3

$ hardening-check /usr/sbin/nginx
/usr/sbin/nginx:
 Position Independent Executable: yes
 Stack protected: yes
 Fortify Source functions: yes (some protected functions found)
 Read-only relocations: yes
 Immediate binding: yes
 Stack clash protection: yes
 Control flow integrity: yes
```

Para el código que compilás vos mismo, el conjunto de banderas de producción:

```makefile
# Distribution-grade hardening flags (glibc >= 2.35, GCC >= 12)
CFLAGS  += -O2 -fstack-protector-strong -fstack-clash-protection \
           -D_FORTIFY_SOURCE=3 -fPIE -fcf-protection=full \
           -Wformat -Wformat-security -Werror=format-security
LDFLAGS += -pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code
```

`-D_FORTIFY_SOURCE=3` (GCC 12+/glibc 2.35+) extiende la fortificación a objetos de tamaño dinámico mediante `__builtin_dynamic_object_size`; es estrictamente mejor que `=2` y cuesta ~1 % de tamaño de código. `-fstack-clash-protection` cierra la clase de saltos sobre la página de guarda de la pila que `-fstack-protector` no cubre.

---

## 6. Superficie de sistema de archivos y de privilegios

### 6.1 Inventario de SUID/SGID

Cada binario SUID-root es una candidata escalada local de privilegios. Enumerá y *justificá cada uno*:

```console
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' 2>/dev/null | sort -k3
-rwsr-xr-x root:root /usr/bin/chfn
-rwsr-xr-x root:root /usr/bin/chsh
-rwsr-xr-x root:root /usr/bin/gpasswd
-rwsr-xr-x root:root /usr/bin/mount
-rwsr-xr-x root:root /usr/bin/newgrp
-rwsr-xr-x root:root /usr/bin/passwd
-rwsr-xr-x root:root /usr/bin/su
-rwsr-xr-x root:root /usr/bin/sudo
-rwsr-xr-x root:root /usr/bin/umount
-rwxr-sr-x root:shadow /usr/bin/expiry
-rwxr-sr-x root:tty   /usr/bin/wall
-rwxr-sr-x root:crontab /usr/bin/crontab
-rwsr-xr-- root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper
-rwsr-xr-x root:root /usr/lib/openssh/ssh-keysign
```

En un servidor desatendido, `chfn`, `chsh`, `newgrp`, `wall` y `ssh-keysign` suelen ser todos removibles:

```console
$ sudo chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp
$ sudo chmod g-s /usr/bin/wall
$ sudo dpkg-statoverride --update --add root root 0755 /usr/bin/chsh
```

`dpkg-statoverride` (Debian) es esencial: un `chmod` simple lo revierte la siguiente actualización del paquete. El equivalente en RHEL es registrar el cambio en tu gestión de configuración y volver a afirmarlo, ya que RPM restaura los modos en `dnf reinstall`.

### 6.2 Capacidades de archivo — el SUID que te olvidás de mirar

```console
$ sudo getcap -r / 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/mtr-packet cap_net_raw=ep
/usr/lib/x86_64-linux-gnu/gstreamer1.0/gstreamer-1.0/gst-ptp-helper cap_net_bind_service,cap_net_admin=ep
/usr/bin/systemd-detect-virt cap_dac_override,cap_sys_ptrace=ep
```

Una capacidad de archivo `cap_dac_override` o `cap_sys_admin` en cualquier lugar fuera de una ruta gestionada por paquetes es una señal de alarma: es un mecanismo de persistencia que ningún escaneo de SUID encuentra.

```console
$ sudo setcap -r /usr/bin/mtr-packet
$ sudo getcap /usr/bin/mtr-packet
$
```

### 6.3 Opciones de montaje

```
# /etc/fstab — hardened mount options
# <device>                  <mount>     <fs>   <options>                                   <dump> <pass>
UUID=1a2b3c4d-...           /           ext4   defaults                                    0 1
UUID=5e6f7a8b-...           /boot       ext4   defaults,nodev,nosuid,noexec                0 2
UUID=9c0d1e2f-...           /boot/efi   vfat   umask=0077,shortname=winnt,nodev,nosuid,noexec 0 2
UUID=3a4b5c6d-...           /home       ext4   defaults,nodev,nosuid                       0 2
UUID=7e8f9a0b-...           /var        ext4   defaults,nodev                              0 2
UUID=1c2d3e4f-...           /var/log    ext4   defaults,nodev,nosuid,noexec                0 2
UUID=5a6b7c8d-...           /var/log/audit ext4 defaults,nodev,nosuid,noexec               0 2
UUID=9e0f1a2b-...           /var/tmp    ext4   defaults,nodev,nosuid,noexec                0 2
tmpfs                       /tmp        tmpfs  defaults,rw,nosuid,nodev,noexec,mode=1777,size=2G 0 0
tmpfs                       /dev/shm    tmpfs  defaults,rw,nosuid,nodev,noexec,mode=1777   0 0
proc                        /proc       proc   defaults,hidepid=invisible,gid=4            0 0
```

| Opción | Bloquea | Rotura común |
|---|---|---|
| `nosuid` | Que se respeten los bits SUID/SGID en ese sistema de archivos | Sandboxes SUID escribibles por el usuario; normalmente nada en `/tmp`, `/var`, `/home` |
| `nodev` | Que se interpreten los nodos de dispositivo | Backends de almacenamiento de contenedores que crean dispositivos bajo `/var/lib` |
| `noexec` | `execve` de archivos en ese sistema de archivos | **Scripts de posinstalación de paquetes que extraen a `/tmp`**, compilaciones DKMS, el `remote_tmp` de Ansible, algunos instaladores Java, compilaciones de `pip` |
| `hidepid=invisible,gid=4` (`proc`) | Que usuarios no root vean `/proc/<pid>` de otros usuarios | Agentes de monitoreo (`node_exporter`, `zabbix-agent`) — agregá su uid al grupo de `gid=` |

`noexec` en `/tmp` es la medida de endurecimiento que más se revierte, porque rompe los scripts de posinstalación de `apt`/`dnf`. La solución correcta no es quitarla sino redirigir la herramienta:

```console
$ sudo tee /etc/apt/apt.conf.d/50noexec-tmp >/dev/null <<'EOF'
DPkg::Pre-Invoke  {"mount -o remount,exec /tmp";};
DPkg::Post-Invoke {"mount -o remount,noexec /tmp";};
EOF
```

y para Ansible, definí `remote_tmp = /var/lib/ansible/tmp` en `ansible.cfg` sobre un sistema de archivos que permita ejecución.

Verificación de `hidepid`:

```console
$ sudo mount -o remount,hidepid=invisible,gid=4 /proc
$ ps -u nginx -o pid,comm            # as root: visible
    PID COMMAND
   1204 nginx
   1205 nginx

$ sudo -u nobody ps -ef | wc -l      # as an unprivileged user: only own processes
      4
```

Notá que `hidepid=2` es la grafía heredada; los kernels 5.8+ aceptan `hidepid=invisible` y agregan `hidepid=ptraceable`. `ProtectProc=invisible` de systemd da el mismo efecto por servicio sin un remontaje global, y es la herramienta preferible cuando solo lo necesitás para un demonio.

### 6.4 Política de módulos del kernel

```console
$ cat /etc/modprobe.d/99-hardening.conf
# Filesystems no server here mounts. `install ... /bin/true` prevents
# autoloading even when a mount(8) call would trigger it, which a plain
# `blacklist` does not.
install cramfs      /bin/true
install freevxfs    /bin/true
install jffs2       /bin/true
install hfs         /bin/true
install hfsplus     /bin/true
install squashfs    /bin/true
install udf         /bin/true

# Legacy / rarely used network protocols with a poor CVE record.
install dccp        /bin/true
install sctp        /bin/true
install rds         /bin/true
install tipc        /bin/true

# Wireless and Bluetooth on a datacentre node.
install bluetooth   /bin/true
install btusb       /bin/true

# Firewire and Thunderbolt: DMA attack surface.
install firewire-core /bin/true
install firewire-ohci /bin/true
install thunderbolt   /bin/true

# USB mass storage. Keep HID working (see USBGuard, section 9) but deny
# data exfiltration via a plugged-in disk.
install usb-storage /bin/true
install uas         /bin/true
```

`blacklist foo` solo evita la carga automática *basada en alias*; un `modprobe foo` directo sigue funcionando. `install foo /bin/true` derrota ambas. Ninguna de las dos sobrevive a un atacante con `CAP_SYS_MODULE` y un `finit_module(2)` directo — para eso necesitás la exigencia de firma de módulos o el interruptor de un solo sentido:

```console
$ sudo sysctl -w kernel.modules_disabled=1
kernel.modules_disabled = 1

$ sudo modprobe dummy
modprobe: ERROR: could not insert 'dummy': Operation not permitted

$ sudo sysctl -w kernel.modules_disabled=0
sysctl: setting key "kernel.modules_disabled": Operation not permitted
```

**De un solo sentido hasta el reinicio.** Ponelo al *final* del arranque, después de que se hayan cargado todos los módulos necesarios: una unidad de `systemd` ordenada `After=multi-user.target` con un retardo, o la última tarea de tu ejecución de aprovisionamiento. Ponerlo solo en `/etc/sysctl.d/` no alcanza, porque `systemd-sysctl` corre temprano, antes de que se carguen la mayoría de los módulos, y romperá la red, el almacenamiento o el subsistema de auditoría en el siguiente arranque.

---

## 7. Parámetros ajustables del kernel: sysctl

### 7.1 Mecánica

`sysctl` es una capa fina sobre `/proc/sys`. Cada perilla es un archivo:

```console
$ sysctl kernel.kptr_restrict
kernel.kptr_restrict = 1

$ cat /proc/sys/kernel/kptr_restrict
1

$ echo 2 | sudo tee /proc/sys/kernel/kptr_restrict
2
```

Las escrituras en tiempo de ejecución no persisten. La persistencia se logra con archivos drop-in, aplicados en el arranque por `systemd-sysctl.service`.

### 7.2 Orden de carga — la trampa de la deriva

`sysctl --system` lee, en este orden, con **los archivos posteriores anulando a los anteriores**, y dentro del conjunto completo los archivos se fusionan por *nombre base* en orden lexicográfico (un archivo en un directorio de mayor prioridad ensombrece a otro con el mismo nombre base en uno de menor prioridad):

```
/etc/sysctl.d/*.conf      ← highest precedence directory for same basename
/run/sysctl.d/*.conf
/usr/local/lib/sysctl.d/*.conf
/usr/lib/sysctl.d/*.conf
/lib/sysctl.d/*.conf
/etc/sysctl.conf          ← applied last of all (legacy, wins on conflict)
```

```console
$ sudo sysctl --system
* Applying /usr/lib/sysctl.d/10-default-yama-scope.conf ...
* Applying /usr/lib/sysctl.d/50-coredump.conf ...
* Applying /usr/lib/sysctl.d/50-default.conf ...
* Applying /usr/lib/sysctl.d/50-pid-max.conf ...
* Applying /etc/sysctl.d/99-hardening.conf ...
* Applying /etc/sysctl.d/99-zzz-calico.conf ...
* Applying /etc/sysctl.conf ...
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
net.ipv4.conf.all.rp_filter = 0
...
```

Fijate en `net.ipv4.conf.all.rp_filter = 0` en la salida final a pesar de que el archivo de endurecimiento define `1`: `99-zzz-calico.conf` ordena *después* de `99-hardening.conf` y gana. Este es exactamente el escenario de deriva de §1.2. **Siempre afirmá valores efectivos en tiempo de ejecución, nunca el contenido de los archivos.**

### 7.3 El drop-in de endurecimiento, anotado

`/etc/sysctl.d/99-hardening.conf`:

```ini
# ============================================================================
#  Host hardening baseline — kernel and network tunables
#  Applied by systemd-sysctl.service at boot; assert with scripts/verify-sysctl.
#  Every entry carries a breakage note. Do not copy blindly onto a node whose
#  role is not documented here (this file targets: bare application servers).
# ============================================================================

# ---------------------------------------------------------------------------
#  Kernel information leaks
# ---------------------------------------------------------------------------
# Hide kernel pointers from /proc and other interfaces (%pK format specifier).
# 1 = hidden from unprivileged, 2 = hidden from everyone including root reads.
# Breakage: some profiling tools (perf, systemtap) and crash analysis need 0/1.
kernel.kptr_restrict = 2

# Only root may read the kernel ring buffer. Blocks leaking of KASLR offsets
# and driver addresses via dmesg after a crash.
# Breakage: unprivileged log shippers reading dmesg; use journald instead.
kernel.dmesg_restrict = 1

# Restrict perf_event_open(2). 2 = no kernel or raw tracepoint access for
# unprivileged users. 3 (Debian/Ubuntu patch only) = deny entirely.
# Breakage: unprivileged profiling; CI perf tests. Set 2 if you profile.
kernel.perf_event_paranoid = 3
kernel.perf_event_max_sample_rate = 1

# ---------------------------------------------------------------------------
#  Process isolation
# ---------------------------------------------------------------------------
# Yama ptrace scope. 1 = only a direct parent may ptrace a child (blocks
# credential scraping across processes of the same uid), 2 = admin only,
# 3 = nobody, ever (not reversible without reboot).
# Breakage: gdb attaching to a running PID, strace -p, some APM agents.
kernel.yama.ptrace_scope = 1

# Full ASLR including the heap. Never lower this.
kernel.randomize_va_space = 2

# Maximum mmap entropy on 64-bit.
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16

# Refuse mapping below 64 KiB. Defeats the whole NULL-pointer-dereference
# kernel exploit class that maps a payload at address 0.
vm.mmap_min_addr = 65536

# ---------------------------------------------------------------------------
#  Privileged interfaces
# ---------------------------------------------------------------------------
# Disable kexec_load(2): stops loading a replacement kernel at runtime, a
# clean rootkit persistence path that survives a "reboot".
# ONE-WAY until the next boot. Breakage: kdump crash-dump capture.
kernel.kexec_load_disabled = 1

# Deny eBPF to unprivileged users; harden the JIT against spray attacks.
# 1 = disabled and locked; 2 = disabled but still changeable.
# Breakage: unprivileged seccomp-bpf is unaffected; rootless BPF tooling is not.
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2

# Magic SysRq: 0 disables entirely; 4 permits keyboard control only;
# 176 (128+32+16) permits reboot/remount-ro/sync for emergency recovery.
# Breakage: 0 removes your ability to do an emergency sync+remount+reboot
# from the console during a hung host. Choose deliberately.
kernel.sysrq = 0

# User namespaces: the single largest source of unprivileged kernel LPEs.
# 0 disables them completely.
# Breakage: rootless Podman/Docker, Flatpak, Chrome's sandbox, bubblewrap,
# `unshare -r`. Set 0 ONLY on nodes that run no rootless containers.
user.max_user_namespaces = 0

# ---------------------------------------------------------------------------
#  Core dumps and SUID
# ---------------------------------------------------------------------------
# Never dump core from a SUID/privileged process — dumps contain secrets.
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false

# ---------------------------------------------------------------------------
#  Filesystem race protections
# ---------------------------------------------------------------------------
# Block the classic /tmp symlink and hardlink attacks in sticky world-writable
# directories, plus FIFO and regular-file variants.
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# ---------------------------------------------------------------------------
#  TTY
# ---------------------------------------------------------------------------
# Stop autoloading line disciplines (a repeated LPE source: n_hdlc, slip...).
dev.tty.ldisc_autoload = 0

# ---------------------------------------------------------------------------
#  Network stack — IPv4
# ---------------------------------------------------------------------------
# This host does not route. Set to 1 ONLY on Kubernetes nodes, NAT gateways
# and routers — and if you do, revisit rp_filter and accept_redirects below.
net.ipv4.ip_forward = 0
net.ipv4.conf.all.forwarding = 0

# Reverse-path filtering: 1 = strict (RFC 3704), 2 = loose.
# Strict breaks asymmetric routing and multi-homed hosts; use 2 there.
# NOTE: the effective value is max(conf.all, conf.<iface>), not the interface
# value alone — see the "all vs default vs iface" table below.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Never accept ICMP redirects: they rewrite the routing table from the wire.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Source routing lets the sender pick the return path — reject it.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log packets with impossible source addresses (early signal for spoofing).
# Breakage: log volume on a noisy segment; rate-limited by icmp_ratelimit.
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# SYN flood mitigation. Costs TCP options (window scaling, SACK) only for
# connections established while the backlog is full.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2

# Do not participate in smurf amplification.
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Ignore gratuitous ARP; require the target IP to be on the receiving iface.
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2

# TIME-WAIT assassination protection.
net.ipv4.tcp_rfc1337 = 1

# ---------------------------------------------------------------------------
#  Network stack — IPv6
# ---------------------------------------------------------------------------
# Router advertisements are unauthenticated: an attacker on-link can become
# your default gateway. Disable RA on a statically addressed server.
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.forwarding = 0

# If IPv6 is genuinely unused, disable it here AND remove any AAAA records —
# a half-disabled IPv6 stack is worse than an enabled, filtered one because
# your firewall rules stop being evaluated for a live protocol.
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
```

### 7.4 `all` vs `default` vs `<iface>` — la semántica que nadie documenta en su runbook

Esta es la pieza de conocimiento de `sysctl` de mayor valor tanto para el examen como para producción:

| Clave | Cómo se combinan `all` y `<iface>` | Consecuencia |
|---|---|---|
| `rp_filter` | **max(all, iface)** | Definir `all.rp_filter=1` fuerza RPF estricto en cada interfaz incluso donde el valor por interfaz sea `0`. Los CNI de Kubernetes que necesitan `0` lo definen en `all` por esa razón. |
| `accept_redirects` | **AND(all, iface)** | Definir `all=0` alcanza para deshabilitarlo en todas partes. |
| `log_martians`, `arp_filter`, `proxy_arp`, `forwarding` | **OR(all, iface)** | Definir `all=1` lo habilita en todas partes; no podés exceptuar una interfaz poniéndola en `0`. |
| `default.*` | **Plantilla, aplicada solo al crear la interfaz** | Cambiar `default.*` **no** afecta a las interfaces existentes. |

La consecuencia práctica: **las interfaces creadas después de que corre `systemd-sysctl` no heredan el endurecimiento que solo escribiste en `all.*`.** Cada `veth`, `docker0`, `cni0`, `tun0`, `wg0` y subinterfaz VLAN creada después recibe los valores de `default.*`. Por eso el archivo de arriba define *ambos*, `all.*` y `default.*`, para cada clave de red, y por eso el paso de verificación (§7.5) enumera interfaces reales en lugar de confiar en `all`.

### 7.5 Verificación y diagnóstico

```console
$ sudo sysctl --system >/dev/null && echo applied
applied

$ sysctl -a --pattern 'kernel.(kptr|dmesg|yama|randomize|modules|kexec|sysrq)' 2>/dev/null
kernel.dmesg_restrict = 1
kernel.kexec_load_disabled = 1
kernel.kptr_restrict = 2
kernel.modules_disabled = 0
kernel.randomize_va_space = 2
kernel.sysrq = 0
kernel.yama.ptrace_scope = 1
```

Afirmación por interfaz — la comprobación que atrapa el punto ciego de `veth`:

```console
$ for i in $(ls /proc/sys/net/ipv4/conf/); do
>   printf '%-12s rp_filter=%s accept_redirects=%s send_redirects=%s\n' "$i" \
>     "$(cat /proc/sys/net/ipv4/conf/$i/rp_filter)" \
>     "$(cat /proc/sys/net/ipv4/conf/$i/accept_redirects)" \
>     "$(cat /proc/sys/net/ipv4/conf/$i/send_redirects)"
> done
all          rp_filter=1 accept_redirects=0 send_redirects=0
default      rp_filter=1 accept_redirects=0 send_redirects=0
eth0         rp_filter=1 accept_redirects=0 send_redirects=0
lo           rp_filter=1 accept_redirects=0 send_redirects=0
docker0      rp_filter=1 accept_redirects=0 send_redirects=1
veth3f2a1c   rp_filter=1 accept_redirects=0 send_redirects=1
```

`docker0` y la `veth` se crearon después del arranque y llevan `send_redirects=1`. O arreglás el drop-in de sysctl del runtime de contenedores o agregás un hook de udev/networkd. Un script de afirmación con fallo duro:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-sysctl — assert effective runtime values, exit 1 on drift.
set -euo pipefail

declare -A EXPECTED=(
  [kernel.kptr_restrict]=2
  [kernel.dmesg_restrict]=1
  [kernel.yama.ptrace_scope]=1
  [kernel.randomize_va_space]=2
  [kernel.kexec_load_disabled]=1
  [kernel.unprivileged_bpf_disabled]=1
  [fs.protected_hardlinks]=1
  [fs.protected_symlinks]=1
  [fs.suid_dumpable]=0
  [net.ipv4.tcp_syncookies]=1
  [net.ipv4.conf.all.accept_source_route]=0
)

rc=0
for key in "${!EXPECTED[@]}"; do
  want="${EXPECTED[$key]}"
  got="$(sysctl -n "$key" 2>/dev/null || echo MISSING)"
  if [[ "$got" != "$want" ]]; then
    printf 'DRIFT  %-42s want=%-6s got=%s\n' "$key" "$want" "$got"
    rc=1
  fi
done

# Per-interface keys must hold on EVERY interface, not just conf.all.
for iface_path in /proc/sys/net/ipv4/conf/*; do
  iface="$(basename "$iface_path")"
  for key in accept_redirects accept_source_route send_redirects; do
    got="$(cat "$iface_path/$key")"
    if [[ "$got" != "0" ]]; then
      printf 'DRIFT  net.ipv4.conf.%s.%s want=0 got=%s\n' "$iface" "$key" "$got"
      rc=1
    fi
  done
done

[[ $rc -eq 0 ]] && echo "OK: sysctl baseline holds"
exit $rc
```

```console
$ sudo /usr/local/sbin/verify-sysctl
DRIFT  net.ipv4.conf.docker0.send_redirects want=0 got=1
DRIFT  net.ipv4.conf.veth3f2a1c.send_redirects want=0 got=1
$ echo $?
1
```

| Síntoma | Causa | Diagnóstico |
|---|---|---|
| El valor se revierte tras el reinicio | Un drop-in de mayor precedencia lo anula | `sudo sysctl --system 2>&1 \| grep Applying`, luego `grep -r '<key>' /etc/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf` |
| `sysctl: cannot stat /proc/sys/...: No such file` | El módulo que provee la perilla no está cargado (p. ej. `net.netfilter.*` necesita `nf_conntrack`) | `modprobe nf_conntrack`, o mover el ajuste a una unidad ordenada respecto de `modprobe` |
| Podman rootless: `cannot clone: Operation not permitted` | `user.max_user_namespaces = 0` | `sysctl user.max_user_namespaces` — subilo o mové la carga de trabajo |
| `kdump` ya no captura | `kernel.kexec_load_disabled = 1` | Elegí: volcados de fallos o endurecimiento de kexec. No podés tener ambos. |
| Los pods pierden red en un nodo de k8s | `net.ipv4.ip_forward = 0` o `all.rp_filter = 1` | `sysctl net.ipv4.ip_forward`; los nodos de k8s necesitan forwarding y normalmente RPF laxo |
| `gdb -p <pid>` falla con `ptrace: Operation not permitted` | `kernel.yama.ptrace_scope >= 1` | Temporalmente `sysctl -w kernel.yama.ptrace_scope=0`, restaurar después |
| El enrutamiento asimétrico descarta tráfico | `rp_filter=1` (estricto) | `sysctl -w net.ipv4.conf.all.rp_filter=2` (laxo) y vigilar `log_martians` |

---

## 8. Vulnerabilidades de hardware de la CPU y sus mitigaciones

Los fallos de ejecución especulativa son únicos en este objetivo: la mitigación vive en el microcódigo y en el kernel, el costo se mide en porcentajes de dos dígitos del rendimiento, y el ajuste correcto depende enteramente del modelo de confianza de la carga de trabajo.

### 8.1 Leer el estado actual

```console
$ grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null
/sys/devices/system/cpu/vulnerabilities/gather_data_sampling:Not affected
/sys/devices/system/cpu/vulnerabilities/itlb_multihit:KVM: Mitigation: VMX disabled
/sys/devices/system/cpu/vulnerabilities/l1tf:Mitigation: PTE Inversion; VMX: conditional cache flushes, SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/mds:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/meltdown:Mitigation: PTI
/sys/devices/system/cpu/vulnerabilities/mmio_stale_data:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/reg_file_data_sampling:Not affected
/sys/devices/system/cpu/vulnerabilities/retbleed:Mitigation: IBRS
/sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow:Not affected
/sys/devices/system/cpu/vulnerabilities/spec_store_bypass:Mitigation: Speculative Store Bypass disabled via prctl
/sys/devices/system/cpu/vulnerabilities/spectre_v1:Mitigation: usercopy/swapgs barriers and __user pointer sanitization
/sys/devices/system/cpu/vulnerabilities/spectre_v2:Mitigation: IBRS, IBPB: conditional, STIBP: conditional, RSB filling, PBRSB-eIBRS: Not affected
/sys/devices/system/cpu/vulnerabilities/srbds:Not affected
/sys/devices/system/cpu/vulnerabilities/tsx_async_abort:Not affected
```

Las tres palabras que importan en esa salida son **`SMT vulnerable`**. Aparecen en `l1tf`, `mds` y `mmio_stale_data` y significan: la mitigación está activa, pero un hilo hermano puede seguir leyendo datos de los búferes del otro hilo. En un host de un solo inquilino eso es aceptable. En un hipervisor multiinquilino o un runner de CI compartido, no.

```console
$ lscpu | sed -n '/Vulnerabilit/,$p'
Vulnerabilities:
  Gather data sampling:   Not affected
  Itlb multihit:          KVM: Mitigation: VMX disabled
  L1tf:                   Mitigation; PTE Inversion; VMX: conditional cache flushes, SMT vulnerable
  Mds:                    Mitigation; Clear CPU buffers; SMT vulnerable
  Meltdown:               Mitigation; PTI
  Spectre v1:             Mitigation; usercopy/swapgs barriers and __user pointer sanitization
  Spectre v2:             Mitigation; IBRS, IBPB: conditional, STIBP: conditional, RSB filling
```

### 8.2 Matriz de compromisos

| Vulnerabilidad | Límite cruzado | Mitigación | Costo típico | Control por cmdline |
|---|---|---|---|---|
| Meltdown (CVE-2017-5754) | Usuario → memoria del kernel | KPTI (aislamiento de tablas de páginas) | 5–30 % en cargas con muchas syscalls | `pti=on\|off\|auto` |
| Spectre v1 (CVE-2017-5753) | Comprobación de límites dentro del proceso | Barreras `array_index_nospec` en el kernel | <1 % | — (compilado adentro) |
| Spectre v2 (CVE-2017-5715) | Predictor de saltos entre procesos/VM | retpoline / eIBRS / IBPB / STIBP | 3–15 % | `spectre_v2=`, `spectre_v2_user=` |
| L1TF (Foreshadow) | Invitado → caché L1 del anfitrión | Inversión de PTE + vaciado de L1D al entrar a la VM | Alto en virtualización; casi nulo en bare metal | `l1tf=flush\|full\|off` |
| MDS / TAA / MMIO stale data | Búferes de CPU entre hilos | Limpieza de búferes con `VERW` en las transiciones | 2–10 % | `mds=`, `tsx_async_abort=`, `mmio_stale_data=` |
| Retbleed | Pila de retornos a través de privilegios | IBRS / seguimiento de profundidad de llamadas | 10–30 % en AMD Zen1/2, Intel anteriores a Ice Lake | `retbleed=auto\|ibpb\|off` |
| SRSO (Inception) | Pila de retornos de AMD | Safe-RET / IBPB | 5–25 % | `spec_rstack_overflow=` |

### 8.3 La decisión, no el valor por defecto

```console
# Multi-tenant: shared hypervisor, shared CI runners, untrusted code
GRUB_CMDLINE_LINUX="... mitigations=auto,nosmt"

# Single-tenant, dedicated, no untrusted local code, network-isolated
GRUB_CMDLINE_LINUX="... mitigations=auto"

# HPC / batch on an air-gapped fabric where you have accepted the risk
# IN WRITING and the node runs exactly one trusted workload:
GRUB_CMDLINE_LINUX="... mitigations=off"
```

`nosmt` reduce a la mitad tu cantidad de núcleos lógicos. Eso es una decisión de capacidad con un presupuesto asociado, y pertenece a la revisión de arquitectura, no a un script de endurecimiento. Lo que *no* es negociable es que la decisión sea explícita y quede registrada: un `mitigations=off` heredado de una línea de comandos de kernel copiada en una plantilla de Packer es la forma en que una flota termina silenciosamente vulnerable.

```console
$ sudo grubby --update-kernel=ALL --args="mitigations=auto,nosmt"
$ sudo reboot
...
$ cat /sys/devices/system/cpu/vulnerabilities/mds
Mitigation: Clear CPU buffers; SMT disabled
$ lscpu | grep -E 'Thread|^CPU\(s\)'
CPU(s):                  32
Thread(s) per core:      1
```

`SMT vulnerable` pasó a `SMT disabled`, y 64 CPU lógicas pasaron a ser 32. Ambos hechos ahora son ciertos y ambos son visibles.

El microcódigo es un prerrequisito para varias de estas: una mitigación del kernel con microcódigo desactualizado se degrada en silencio.

```console
$ sudo dnf install -y microcode_ctl        # RHEL family
$ sudo apt install -y intel-microcode amd64-microcode   # Debian family
$ journalctl -k | grep -i microcode
Aug 24 09:41:02 web01 kernel: microcode: updated early: 0x2b000603 -> 0x2b000620, date = 2026-02-18
```

---

## 9. USBGuard: controlar el bus físico

### 9.1 Mecánica de la amenaza

Un dispositivo USB declara su propia clase. Un dispositivo que parece un cargador de teléfono puede enumerarse como un teclado HID (`03:01:01`) y escribir. Carga útil del ataque: se enchufa, espera dos segundos, inyecta `Ctrl-Alt-F2`, `curl … | sh`. Sin exploit, sin CVE, sin contraseña. Variantes: almacenamiento masivo para exfiltración, un adaptador Ethernet (`02:06:00`) que se vuelve una puerta de enlace por defecto de mayor prioridad y roba el DHCP, y —en Thunderbolt— DMA directo a la memoria física.

USBGuard implementa una **lista de dispositivos permitidos aplicada en la enumeración**, antes de que el kernel enlace un controlador.

### 9.2 Arquitectura

```
 USB device inserted
        │
        ▼
 kernel USB core enumerates → descriptors read
        │
        ▼  uevent (netlink)
 usbguard-daemon  ── evaluates rules.conf top-to-bottom, first match wins
        │                    │
        │ allow              │ block / reject
        ▼                    ▼
 echo 1 > /sys/bus/usb/    echo 0 > .../authorized
 devices/<dev>/authorized  (reject = also detach)
        │
        ▼
 driver binds, device usable
```

La primitiva del kernel es `/sys/bus/usb/devices/*/authorized` y `/sys/bus/usb/devices/usbN/authorized_default`. USBGuard es un motor de políticas encima de eso; la aplicación está en el kernel y se mantiene aunque se mate al demonio (los dispositivos ya decididos conservan su estado).

**Objetivos de las reglas:** `allow` (autorizar), `block` (no autorizar ahora — reconectar vuelve a evaluar), `reject` (autorización denegada *y* eliminación lógica del dispositivo).

### 9.3 Configuración completa

`/etc/usbguard/usbguard-daemon.conf`:

```ini
# ============================================================================
#  usbguard-daemon.conf — USB device authorization policy engine
#  DANGER: a wrong policy here locks you out of your own keyboard.
#  Always generate the initial policy WITH the keyboard attached (see below),
#  and always keep a second access path (SSH, IPMI SoL) open during rollout.
# ============================================================================

# Primary rule file, written by `usbguard generate-policy > ...`.
RuleFile=/etc/usbguard/rules.conf

# Additional rule fragments, merged in lexicographic order BEFORE RuleFile.
# Use this for config-management-owned fragments so the machine-local
# rules.conf stays editable by hand.
RuleFolder=/etc/usbguard/rules.d/

# What to do with a device matching no rule at all. `block` is the whole point
# of running USBGuard; `allow` turns it into an audit-only deployment, which is
# the correct FIRST stage of a rollout.
ImplicitPolicyTarget=block

# Devices already connected when the daemon starts.
#   keep          - leave the current authorization state untouched
#   apply-policy  - evaluate them against the rules like any other device
#   block/reject  - deny regardless of policy
# `apply-policy` is correct steady state; use `keep` during the first rollout
# so a bad policy cannot detach the console keyboard on daemon restart.
PresentDevicePolicy=apply-policy

# USB controllers (hubs/root hubs) present at daemon start. `keep` avoids
# tearing down the entire bus if a controller is not in the policy.
PresentControllerPolicy=keep

# Devices inserted while the daemon is running.
InsertedDevicePolicy=apply-policy

# On daemon shutdown, restore the pre-USBGuard authorization state.
# false = devices stay as the policy left them (fail closed). Keep false.
RestoreControllerDeviceState=false

# Device enumeration backend. `uevent` is the netlink-based default;
# `umockdev` exists for testing only.
DeviceManagerBackend=uevent

# --- IPC access control -----------------------------------------------------
# Who may talk to the daemon over its Unix socket. An unrestricted IPC socket
# is equivalent to giving away the policy: any listed user can `allow-device`.
IPCAllowedUsers=root
IPCAllowedGroups=wheel
IPCAccessControlFiles=/etc/usbguard/IPCAccessControl.d/

# --- Policy generation behaviour -------------------------------------------
# Include the physical port (via-port) in generated rules. false is usually
# right: with true, moving a keyboard to another port blocks it.
DeviceRulesWithPort=false

# --- Audit ------------------------------------------------------------------
# LinuxAudit sends events to auditd (integrates with 332.2); FileAudit writes
# a dedicated log. LinuxAudit is preferred where auditd is already deployed.
AuditBackend=LinuxAudit
AuditFilePath=/var/log/usbguard/usbguard-audit.log

# Redact serial numbers and hashes from logs on shared/regulated systems.
HidePII=false
```

Generá la política inicial a partir del hardware conocido y confiable que está conectado en ese momento:

```console
$ sudo usbguard generate-policy -X -t reject > /etc/usbguard/rules.conf
$ sudo chmod 0600 /etc/usbguard/rules.conf
$ sudo cat /etc/usbguard/rules.conf
allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6WzviqdJ5VSeTUY8PatCNBKeaREvo2OqdplND/o=" parent-hash "" with-interface 09:00:00 with-connect-type ""
allow id 1d6b:0003 serial "0000:00:14.0" name "xHCI Host Controller" hash "kL8/2XzvKqdN9VSeTUY8PatCNBKeaREvo2OqdplND/x=" parent-hash "" with-interface 09:00:00 with-connect-type ""
allow id 8087:0026 serial "" name "" hash "9Mv3nT7pQrS2uV4wX6yZ8aB0cD1eF2gH3iJ4kL5mN6o=" parent-hash "jEP/6WzviqdJ5VSeTUY8PatCNBKeaREvo2OqdplND/o=" with-interface { e0:01:01 e0:01:01 } with-connect-type "hardwired"
allow id 413c:2113 serial "" name "Dell KB216 Wired Keyboard" hash "7Qw9eR2tY5uI8oP1aS4dF7gH0jK3lZ6xC9vB2nM5qW8=" parent-hash "jEP/6WzviqdJ5VSeTUY8PatCNBKeaREvo2OqdplND/o=" with-interface { 03:01:01 03:00:00 } with-connect-type "hotplug"

# Deny everything that did not match above. `reject` also detaches.
reject
```

La bandera `-t reject` agrega el catch-all explícito; `-X` omite el hash de… (ejecutá `usbguard generate-policy --help` en tu compilación para confirmar la semántica de las banderas — lo importante es que la última línea sea un catch-all deliberado y que las reglas estén ancladas por hash, de modo que clonar un VID:PID no alcance para ser permitido).

Un fragmento de política escrito a mano para una regla basada en clases:

`/etc/usbguard/rules.d/10-classes.conf`:

```
# Allow only hubs, HID keyboards and the internal Bluetooth radio.
# Explicitly reject mass storage and network gadgets regardless of vendor.

# Hubs (class 09) are needed for the bus to work at all.
allow with-interface equals { 09:00:* }

# HID keyboards (03:01:01) but NOT composite devices that ALSO expose
# storage or network — `equals` is an exact multiset match on the interface
# list, which is what defeats a BadUSB composite descriptor.
allow with-interface equals { 03:01:01 03:00:00 }

# Reject mass storage (08:*), network (02:*), and vendor-specific serial
# adapters (ff:*) outright, with a message in the audit log.
reject with-interface one-of { 08:*:* }
reject with-interface one-of { 02:*:* }
reject with-interface one-of { ff:*:* }
```

La distinción entre `equals`, `one-of`, `none-of` y `all-of` es donde vive de verdad la seguridad. `allow with-interface one-of { 03:01:01 }` permitiría un dispositivo que presenta un teclado **y** una interfaz de almacenamiento masivo — precisamente la forma de un BadUSB. `equals` exige que el conjunto de interfaces coincida exactamente.

### 9.4 Despliegue sin dejarte afuera

```console
# Stage 1: audit only. ImplicitPolicyTarget=allow, watch what appears.
$ sudo sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=allow/' /etc/usbguard/usbguard-daemon.conf
$ sudo systemctl enable --now usbguard.service
$ sudo usbguard watch
[device] present: id=1 target=allow device_rule='allow id 1d6b:0002 ...'
[device] inserted: id=7 target=allow device_rule='allow id 0781:5583 serial "4C530001..." name "Ultra Fit" hash "..." with-interface { 08:06:50 }'

# Stage 2: flip to block, keep present devices untouched.
$ sudo sed -i 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=block/' /etc/usbguard/usbguard-daemon.conf
$ sudo sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=keep/' /etc/usbguard/usbguard-daemon.conf
$ sudo systemctl restart usbguard.service

# Stage 3, only after a successful reboot test with the console keyboard:
$ sudo sed -i 's/^PresentDevicePolicy=.*/PresentDevicePolicy=apply-policy/' /etc/usbguard/usbguard-daemon.conf
$ sudo systemctl restart usbguard.service
```

Operación en tiempo de ejecución:

```console
$ sudo usbguard list-devices
1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "jEP/6Wzviq..." parent-hash "" via-port "usb1" with-interface 09:00:00 with-connect-type ""
4: allow id 413c:2113 serial "" name "Dell KB216 Wired Keyboard" hash "7Qw9eR2tY5..." parent-hash "jEP/6Wzviq..." via-port "1-3" with-interface { 03:01:01 03:00:00 } with-connect-type "hotplug"
7: block id 0781:5583 serial "4C530001280621119131" name "Ultra Fit" hash "aB3cD4eF5g..." parent-hash "jEP/6Wzviq..." via-port "1-4" with-interface { 08:06:50 } with-connect-type "hotplug"

$ sudo usbguard list-devices --blocked
7: block id 0781:5583 serial "4C530001280621119131" name "Ultra Fit" hash "aB3cD4eF5g..." ...

# Temporary, non-persistent authorization for a known device:
$ sudo usbguard allow-device 7

# Permanent, appended to rules.conf:
$ sudo usbguard allow-device 7 -p

$ sudo usbguard list-rules
1: allow id 1d6b:0002 serial "0000:00:14.0" ...
4: allow id 413c:2113 serial "" name "Dell KB216 Wired Keyboard" ...
5: allow id 0781:5583 serial "4C530001280621119131" name "Ultra Fit" hash "aB3cD4eF5g..."
6: reject
```

### 9.5 Las alternativas solo con el kernel

| Control | Granularidad | Sobrevive a la muerte del demonio | Complejidad | Cuándo usarlo |
|---|---|---|---|---|
| USBGuard | Por dispositivo, anclado por hash, consciente de la clase de interfaz | Sí (el estado está en sysfs) | Alta | Estaciones de trabajo, hosts de salto, cualquier cosa con teclado y un modelo de amenaza |
| `authorized_default=0` en los hubs raíz | Todo o nada por controlador | Sí | Baja | Servidores sin cabeza sin ningún requisito de USB |
| `install usb-storage /bin/true` | Bloquea solo el controlador de almacenamiento | Sí | Trivial | Victoria parcial barata; no hace nada contra la inyección HID |
| `nousb` / desenlazar `xhci_hcd` | Bus entero muerto | Sí | Trivial | Servidores bare-metal con consola IPMI/serie y sin consola USB |
| "Deshabilitar puertos USB" en la BIOS | Por puerto o global, previo al SO | Sí | Trivial | Lo mejor cuando realmente no necesitás ninguno — pero también bloquea el medio de recuperación |

```console
# The blunt instrument, for a headless server with no USB requirement:
$ for hub in /sys/bus/usb/devices/usb*; do echo 0 | sudo tee $hub/authorized_default; done
0
0
$ cat /sys/bus/usb/devices/usb1/authorized_default
0
```

### 9.6 Verificación y diagnóstico

```console
$ systemctl is-active usbguard
active

$ sudo ausearch -m USER_DEVICE -ts recent -i | tail -3
type=USER_DEVICE msg=audit(2026-08-24 12:18:44.201:3391) : pid=1187 uid=root auid=unset ses=unset msg='usbguard: type=Policy.DeviceRule device_rule="reject id 0781:5583 serial 4C530001280621119131 name Ultra Fit hash aB3cD4eF5g..." target=reject exe=/usr/sbin/usbguard-daemon res=success'

$ cat /sys/bus/usb/devices/1-4/authorized
0

$ journalctl -u usbguard -n 5 --no-pager
Aug 24 12:18:44 ws01 usbguard-daemon[1187]: Device inserted: id=7 ... target=reject
```

| Síntoma | Causa | Recuperación |
|---|---|---|
| Teclado de consola muerto tras habilitar USBGuard | El teclado no está en la política, o `PresentDevicePolicy=apply-policy` en el primer arranque | Arrancar con `systemd.mask=usbguard.service` desde GRUB; o entrar por SSH y `usbguard allow-device <id> -p` |
| El teclado funciona en un puerto y no en otro | `DeviceRulesWithPort=true` fijó `via-port` | Poner `DeviceRulesWithPort=false`, regenerar la política |
| `usbguard: IPC connection error` como usuario no root | Usuario no está en `IPCAllowedUsers`/`IPCAllowedGroups` | `usbguard add-user <user> --devices=listmodify --policy=list` |
| Política perdida tras una actualización | `rules.conf` no está bajo gestión de configuración | Distribuir fragmentos de `rules.d/` desde la gestión de configuración; tratar `rules.conf` como generado |
| Dispositivo permitido pero igual no funciona | Controlador en lista negra en `modprobe.d` | `dmesg \| tail`, `lsmod \| grep usb_storage` |

**Escotilla de escape siempre con `mask`:** agregar `systemd.mask=usbguard.service` en el prompt de GRUB recupera un host bloqueado — que es precisamente por qué la contraseña de GRUB de §2 y la política de USBGuard protegen cosas *distintas* y ambas son necesarias.

---

## 10. Directorios poliinstanciados (`pam_namespace`)

### 10.1 El problema

`/tmp` es escribible por todo el mundo y compartido. Consecuencias en un host multiusuario: carreras de enlaces simbólicos y duros contra procesos privilegiados, ataques con nombres de archivo predecibles y simple espionaje — el usuario A puede listar los archivos temporales del usuario B y a menudo leerlos. `fs.protected_symlinks` (§7.3) cierra la clase de las carreras; no cierra la clase de la *visibilidad*.

La **poliinstanciación** le da a cada usuario (o a cada nivel/contexto de SELinux) un `/tmp` privado, montado en el espacio de nombres de montaje propio de su sesión al iniciar sesión. Dos usuarios ven ambos `/tmp`; son dos directorios distintos.

### 10.2 Configuración

`/etc/security/namespace.conf`:

```
# ============================================================================
#  pam_namespace configuration — polyinstantiated directories
#
#  Format:
#    <polydir>  <instance_prefix>  <method>  <uid_exclusion_list>  [flags]
#
#  method:
#    user    - one instance per user (instance dir suffixed with the username)
#    level   - one instance per SELinux MLS level (falls back to user without
#              SELinux MLS)
#    context - one instance per SELinux context
#    both    - per context AND per user
#    tmpfs   - a fresh empty tmpfs per session (no persistence between logins)
#    tmpdir  - a fresh empty directory per session, removed on logout
#
#  uid_exclusion_list: comma-separated users who are NOT polyinstantiated.
#  Always exclude root and your admin/monitoring accounts, otherwise a broken
#  instance directory locks administrators out of a working /tmp.
# ============================================================================

# Per-user /tmp. Instances live under /tmp-inst, which must be mode 000 and
# owned by root so that no user can traverse into another user's instance.
/tmp        /tmp-inst/              level      root,adm,monitoring

# Per-user /var/tmp, same construction.
/var/tmp    /var/tmp/tmp-inst/      level      root,adm,monitoring

# Per-user home instance, for shared bastion/jump hosts where users must not
# see each other's home directories at all. Requires the parent to exist.
# $HOME    /home/inst/             user       root,adm
```

Creá los padres de las instancias con los permisos exactos que `pam_namespace` requiere — se niega a funcionar si están mal:

```console
$ sudo mkdir -p /tmp-inst /var/tmp/tmp-inst
$ sudo chmod 000 /tmp-inst /var/tmp/tmp-inst
$ sudo chown root:root /tmp-inst /var/tmp/tmp-inst
$ ls -ld /tmp-inst
d---------. 2 root root 6 Aug 24 13:02 /tmp-inst
```

Habilitá el módulo en las pilas PAM que crean sesiones:

```console
$ grep -n pam_namespace /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/runuser-l
/etc/pam.d/sshd:9:session    required     pam_namespace.so
/etc/pam.d/login:12:session  required     pam_namespace.so
```

En la familia RHEL esto normalmente se hace agregando la línea a `/etc/pam.d/postlogin` o habilitándolo mediante `authselect`:

```console
$ sudo authselect enable-feature with-pam-namespace
$ sudo authselect apply-changes
```

La inicialización opcional por instancia (copiar archivos esqueleto, fijar contextos de SELinux) va en `/etc/security/namespace.init`, que recibe como argumentos el polydir, el directorio de instancia, una bandera de "instancia nueva" y el nombre de usuario:

```bash
#!/bin/sh -p
# /etc/security/namespace.init — run once when a new instance dir is created.
# $1 polydir  $2 instance dir  $3 new (1) or existing (0)  $4 user
if [ "$3" = "1" ]; then
    # Restore the SELinux context the polydir would normally carry.
    [ -x /sbin/restorecon ] && /sbin/restorecon "$2"
fi
exit 0
```

### 10.3 Verificación

```console
# Session 1, as alice:
alice@bastion:~$ echo secret-alice > /tmp/mydata
alice@bastion:~$ ls -l /tmp/
total 4
-rw-------. 1 alice alice 13 Aug 24 13:11 mydata

# Session 2, as bob, at the same time:
bob@bastion:~$ ls -l /tmp/
total 0
bob@bastion:~$ cat /tmp/mydata
cat: /tmp/mydata: No such file or directory

# As root, the shared /tmp is visible and both instances are on disk:
$ sudo ls -l /tmp-inst/
total 0
drwx------. 2 alice alice 60 Aug 24 13:11 tmp.inst-alice
drwx------. 2 bob   bob   40 Aug 24 13:12 tmp.inst-bob

$ sudo findmnt -T /tmp -o TARGET,SOURCE,FSTYPE,OPTIONS
TARGET SOURCE                                       FSTYPE OPTIONS
/tmp   /dev/mapper/vg0-root[/tmp-inst/tmp.inst-alice] xfs   rw,relatime,seclabel,attr2,inode64

$ sudo grep ' /tmp ' /proc/$(pgrep -u alice -n bash)/mountinfo
912 887 253:0 /tmp-inst/tmp.inst-alice /tmp rw,relatime shared:1 - xfs /dev/mapper/vg0-root rw,seclabel,attr2,inode64,logbufs=8
```

El `mountinfo` de la shell de alice muestra que el origen del bind es la instancia por usuario — esa es la prueba, no la salida de `ls`.

### 10.4 `pam_namespace` vs `PrivateTmp=`

| | `pam_namespace` | `PrivateTmp=yes` de systemd |
|---|---|---|
| Alcance | Por sesión de inicio (usuarios interactivos) | Por unidad de servicio |
| Granularidad | Por usuario / nivel SELinux / contexto | Por unidad |
| Persistencia entre sesiones | Sí con `level`/`user`; no con `tmpfs`/`tmpdir` | No — se destruye con la unidad |
| Se aplica a trabajos de `cron`/`at` | Solo si la pila PAM lo incluye | n/a |
| Superficie de configuración | `namespace.conf` + pilas PAM + directorios de instancia | Una directiva |
| Modo de fallo | Directorio de instancia roto → el usuario no puede iniciar sesión | El servicio no puede ver el `/tmp` del host |

Son complementarios, no alternativos: `PrivateTmp=` cubre demonios, `pam_namespace` cubre humanos. En un host bastión querés ambos.

| Síntoma | Causa | Diagnóstico |
|---|---|---|
| El inicio de sesión falla justo después de habilitar `pam_namespace` | El padre de la instancia tiene modo/propietario incorrectos | `ls -ld /tmp-inst` debe dar `d--------- root root`; revisar `journalctl -t sshd \| grep namespace` |
| El `/tmp` de root también se volvió privado | Falta `root` en la lista de exclusión | Agregar `root` a la columna 4, volver a iniciar sesión |
| X11/DBus rompen la sesión | `/tmp/.X11-unix` ahora es por instancia | Excluir al usuario del gestor de pantalla, o usar el método `tmpfs` con un `iscript` que recree los sockets |
| `scp`/`sftp` se comporta distinto de `ssh` | `pam_namespace` solo en `/etc/pam.d/sshd`, no en la ruta del subsistema | Verificar con `findmnt` dentro del proceso de una sesión `sftp` |

---

## 11. La línea base como código

El endurecimiento que existe solo en una página de wiki no es endurecimiento. Abajo está el rol completo de Ansible que implementa todo lo anterior, más la suite de verificación.

`roles/host_hardening/defaults/main.yml`:

```yaml
---
# Host hardening role defaults.
# Every switch defaults to the SAFE value; a node opts in to the aggressive
# ones through group_vars, so a new node cannot be bricked by inheritance.

hardening_grub_enable_password: true
hardening_grub_superuser: grubadmin
# Generate with: grub-mkpasswd-pbkdf2 --iteration-count=210000 --salt=32
# Store in Ansible Vault; never in plain group_vars.
hardening_grub_password_pbkdf2: "{{ vault_grub_password_pbkdf2 }}"

hardening_kernel_cmdline_args:
  - slab_nomerge
  - init_on_alloc=1
  - init_on_free=1
  - page_alloc.shuffle=1
  - randomize_kstack_offset=on
  - vsyscall=none
  - debugfs=off

# Opt-in: these have caused outages. Enable per group after a canary.
hardening_kernel_lockdown: false          # lockdown=integrity
hardening_module_sig_enforce: false       # module.sig_enforce=1
hardening_disable_smt: false              # mitigations=auto,nosmt

hardening_services_masked:
  - cups.service
  - cups.socket
  - cups.path
  - cups-browsed.service
  - rpcbind.service
  - rpcbind.socket
  - avahi-daemon.service
  - avahi-daemon.socket
  - bluetooth.service
  - debug-shell.service
  - kdump.service

hardening_packages_absent:
  - telnet
  - rsh-client
  - ypbind
  - tftp
  - talk
  - xinetd

# Set false on Kubernetes nodes, NAT gateways and routers.
hardening_ip_forward: false
# Set 2 (loose) on multi-homed hosts with asymmetric routing.
hardening_rp_filter: 1
# Set >0 on nodes running rootless containers (Podman, Flatpak, Chrome).
hardening_max_user_namespaces: 0
# Set 0 to keep kdump working.
hardening_kexec_load_disabled: 1

hardening_blacklisted_modules:
  - cramfs
  - freevxfs
  - jffs2
  - hfs
  - hfsplus
  - squashfs
  - udf
  - dccp
  - sctp
  - rds
  - tipc
  - firewire-core
  - firewire-ohci
  - thunderbolt
  - usb-storage
  - uas

hardening_suid_strip:
  - /usr/bin/chfn
  - /usr/bin/chsh
  - /usr/bin/newgrp

hardening_usbguard_enabled: false          # opt-in; see rollout in section 9.4
hardening_usbguard_implicit_target: block
hardening_usbguard_present_policy: keep

hardening_pam_namespace_enabled: false     # bastion hosts only
```

`roles/host_hardening/tasks/main.yml`:

```yaml
---
- name: Assert the role is running on a supported OS family
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] in ['Debian', 'RedHat']
    fail_msg: "host_hardening supports Debian and RedHat families only"

- name: Include OS-family specific variables
  ansible.builtin.include_vars: "{{ ansible_facts['os_family'] }}.yml"

# ---------------------------------------------------------------------------
#  Boot chain
# ---------------------------------------------------------------------------
- name: Install the GRUB superuser stanza
  ansible.builtin.template:
    src: 40_custom.j2
    dest: /etc/grub.d/40_custom
    owner: root
    group: root
    mode: '0700'
  when:
    - hardening_grub_enable_password | bool
    - ansible_facts['os_family'] == 'Debian'
  notify: regenerate grub config

- name: Mark generated menu entries --unrestricted so unattended boot works
  ansible.builtin.replace:
    path: /etc/grub.d/10_linux
    regexp: '^CLASS="(?!.*--unrestricted)(.*)"$'
    replace: 'CLASS="\1 --unrestricted"'
  when:
    - hardening_grub_enable_password | bool
    - ansible_facts['os_family'] == 'Debian'
  notify: regenerate grub config

- name: Set the GRUB password on the RedHat family
  ansible.builtin.copy:
    content: "GRUB2_PASSWORD={{ hardening_grub_password_pbkdf2 }}\n"
    dest: /boot/grub2/user.cfg
    owner: root
    group: root
    mode: '0600'
  when:
    - hardening_grub_enable_password | bool
    - ansible_facts['os_family'] == 'RedHat'
  notify: regenerate grub config

- name: Compose the hardened kernel command line
  ansible.builtin.set_fact:
    _hardening_cmdline: >-
      {{ (hardening_kernel_cmdline_args
          + (['lockdown=integrity'] if hardening_kernel_lockdown else [])
          + (['module.sig_enforce=1'] if hardening_module_sig_enforce else [])
          + (['mitigations=auto,nosmt'] if hardening_disable_smt else ['mitigations=auto'])
         ) | join(' ') }}

- name: Apply the kernel command line (Debian family)
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX='
    line: 'GRUB_CMDLINE_LINUX="{{ _hardening_cmdline }}"'
    create: false
  when: ansible_facts['os_family'] == 'Debian'
  notify: regenerate grub config

- name: Apply the kernel command line (RedHat family, BLS entries)
  ansible.builtin.command:
    cmd: grubby --update-kernel=ALL --args="{{ _hardening_cmdline }}"
  register: _grubby
  changed_when: _grubby.rc == 0
  when: ansible_facts['os_family'] == 'RedHat'

- name: Never offer a recovery entry
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^#?GRUB_DISABLE_RECOVERY='
    line: 'GRUB_DISABLE_RECOVERY="true"'
  notify: regenerate grub config

- name: Restrict permissions on the generated bootloader config
  ansible.builtin.file:
    path: "{{ hardening_grub_cfg_path }}"
    owner: root
    group: root
    mode: '0600'

# ---------------------------------------------------------------------------
#  Service surface
# ---------------------------------------------------------------------------
- name: Remove insecure legacy packages
  ansible.builtin.package:
    name: "{{ hardening_packages_absent }}"
    state: absent

- name: Mask unnecessary units
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    masked: true
    enabled: false
    state: stopped
  loop: "{{ hardening_services_masked }}"
  failed_when: false          # a unit that does not exist is not an error here

# ---------------------------------------------------------------------------
#  Kernel tunables
# ---------------------------------------------------------------------------
- name: Deploy the sysctl hardening baseline
  ansible.builtin.template:
    src: 99-hardening.conf.j2
    dest: /etc/sysctl.d/99-hardening.conf
    owner: root
    group: root
    mode: '0644'
    validate: 'sysctl -p %s -n'
  notify: reload sysctl

- name: Blacklist unused kernel modules
  ansible.builtin.template:
    src: 99-hardening-modules.conf.j2
    dest: /etc/modprobe.d/99-hardening.conf
    owner: root
    group: root
    mode: '0644'

- name: Unload any blacklisted module that is currently loaded
  community.general.modprobe:
    name: "{{ item }}"
    state: absent
  loop: "{{ hardening_blacklisted_modules }}"
  failed_when: false

# ---------------------------------------------------------------------------
#  Filesystem and privilege surface
# ---------------------------------------------------------------------------
- name: Harden shared-memory and temporary filesystems
  ansible.posix.mount:
    path: "{{ item.path }}"
    src: "{{ item.src }}"
    fstype: tmpfs
    opts: "{{ item.opts }}"
    state: mounted
  loop:
    - { path: /dev/shm, src: tmpfs, opts: 'rw,nosuid,nodev,noexec,mode=1777' }
    - { path: /tmp,     src: tmpfs, opts: 'rw,nosuid,nodev,noexec,mode=1777,size=2G' }

- name: Keep package managers working with noexec /tmp
  ansible.builtin.copy:
    content: |
      DPkg::Pre-Invoke  {"mount -o remount,exec /tmp";};
      DPkg::Post-Invoke {"mount -o remount,noexec /tmp";};
    dest: /etc/apt/apt.conf.d/50noexec-tmp
    owner: root
    group: root
    mode: '0644'
  when: ansible_facts['os_family'] == 'Debian'

- name: Strip SUID from binaries no unattended server needs
  ansible.builtin.file:
    path: "{{ item }}"
    mode: 'u-s'
  loop: "{{ hardening_suid_strip }}"
  failed_when: false

- name: Persist the mode change against package upgrades (Debian)
  ansible.builtin.command:
    cmd: "dpkg-statoverride --force-statoverride-add --update --add root root 0755 {{ item }}"
  loop: "{{ hardening_suid_strip }}"
  register: _statoverride
  changed_when: "'already exists' not in (_statoverride.stderr | default(''))"
  failed_when: false
  when: ansible_facts['os_family'] == 'Debian'

- name: Inventory SUID/SGID binaries for the compliance record
  ansible.builtin.shell:
    cmd: >-
      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f
      -printf '%M %u:%g %p\n' 2>/dev/null | sort -k3
  register: _suid_inventory
  changed_when: false

- name: Fail if an unexpected SUID binary appeared
  ansible.builtin.assert:
    that:
      - (_suid_inventory.stdout_lines | map('regex_replace', '^\\S+ \\S+ ', '') | list
         | difference(hardening_suid_allowlist)) | length == 0
    fail_msg: >-
      Unexpected SUID/SGID binaries:
      {{ _suid_inventory.stdout_lines | map('regex_replace', '^\S+ \S+ ', '')
         | list | difference(hardening_suid_allowlist) }}

# ---------------------------------------------------------------------------
#  Optional subsystems
# ---------------------------------------------------------------------------
- name: Configure USBGuard
  when: hardening_usbguard_enabled | bool
  block:
    - name: Install usbguard
      ansible.builtin.package:
        name: usbguard
        state: present

    - name: Deploy the usbguard daemon configuration
      ansible.builtin.template:
        src: usbguard-daemon.conf.j2
        dest: /etc/usbguard/usbguard-daemon.conf
        owner: root
        group: root
        mode: '0600'
      notify: restart usbguard

    - name: Deploy config-management-owned rule fragments
      ansible.builtin.copy:
        src: usbguard-rules.d/
        dest: /etc/usbguard/rules.d/
        owner: root
        group: root
        mode: '0600'
      notify: restart usbguard

    - name: Generate the machine-local policy if none exists
      ansible.builtin.shell:
        cmd: usbguard generate-policy -t reject > /etc/usbguard/rules.conf
        creates: /etc/usbguard/rules.conf

    - name: Enable usbguard
      ansible.builtin.systemd_service:
        name: usbguard
        enabled: true
        state: started

- name: Configure polyinstantiated directories
  when: hardening_pam_namespace_enabled | bool
  block:
    - name: Create the instance parent directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: root
        group: root
        mode: '0000'
      loop:
        - /tmp-inst
        - /var/tmp/tmp-inst

    - name: Deploy namespace.conf
      ansible.builtin.template:
        src: namespace.conf.j2
        dest: /etc/security/namespace.conf
        owner: root
        group: root
        mode: '0644'

    - name: Enable pam_namespace in the sshd and login stacks
      ansible.builtin.lineinfile:
        path: "/etc/pam.d/{{ item }}"
        line: 'session    required     pam_namespace.so'
        insertafter: '^session'
        state: present
      loop:
        - sshd
        - login
```

`roles/host_hardening/handlers/main.yml`:

```yaml
---
- name: regenerate grub config
  ansible.builtin.command:
    cmd: "{{ hardening_grub_mkconfig_cmd }}"
  changed_when: true

- name: reload sysctl
  ansible.builtin.command:
    cmd: sysctl --system
  changed_when: true

- name: restart usbguard
  ansible.builtin.systemd_service:
    name: usbguard
    state: restarted
```

`roles/host_hardening/vars/Debian.yml`:

```yaml
---
hardening_grub_cfg_path: /boot/grub/grub.cfg
hardening_grub_mkconfig_cmd: "grub-mkconfig -o /boot/grub/grub.cfg"
hardening_suid_allowlist:
  - /usr/bin/mount
  - /usr/bin/umount
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/gpasswd
  - /usr/bin/crontab
  - /usr/bin/expiry
  - /usr/lib/dbus-1.0/dbus-daemon-launch-helper
  - /usr/lib/openssh/ssh-keysign
```

`roles/host_hardening/vars/RedHat.yml`:

```yaml
---
hardening_grub_cfg_path: /boot/grub2/grub.cfg
hardening_grub_mkconfig_cmd: "grub2-mkconfig -o /boot/grub2/grub.cfg"
hardening_suid_allowlist:
  - /usr/bin/mount
  - /usr/bin/umount
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/gpasswd
  - /usr/bin/crontab
  - /usr/bin/at
  - /usr/sbin/pam_timestamp_check
  - /usr/sbin/unix_chkpwd
  - /usr/libexec/dbus-1/dbus-daemon-launch-helper
```

### 11.1 Afirmación continua con `goss`

`/etc/goss/hardening.yaml`:

```yaml
---
# goss test suite: asserts the RUNTIME state of the hardening baseline.
# Run from cron/systemd timer and ship the JSON result to your metrics store.
# `goss validate --format json` exits non-zero on any failure.

kernel-param:
  kernel.randomize_va_space:
    value: "2"
  kernel.kptr_restrict:
    value: "2"
  kernel.dmesg_restrict:
    value: "1"
  kernel.yama.ptrace_scope:
    value: "1"
  kernel.kexec_load_disabled:
    value: "1"
  kernel.unprivileged_bpf_disabled:
    value: "1"
  fs.protected_hardlinks:
    value: "1"
  fs.protected_symlinks:
    value: "1"
  fs.suid_dumpable:
    value: "0"
  net.ipv4.conf.all.accept_source_route:
    value: "0"
  net.ipv4.conf.all.accept_redirects:
    value: "0"
  net.ipv4.tcp_syncookies:
    value: "1"
  net.ipv6.conf.all.accept_ra:
    value: "0"

file:
  /boot/grub/grub.cfg:
    exists: true
    mode: "0600"
    owner: root
    group: root
    contains:
      - "set superusers="
      - "password_pbkdf2"
      - "--unrestricted"
  /etc/modprobe.d/99-hardening.conf:
    exists: true
    mode: "0644"
    contains:
      - "install usb-storage /bin/true"
      - "install thunderbolt /bin/true"
  /sys/kernel/security/lockdown:
    exists: true
    contains:
      - "[integrity]"
  /sys/devices/system/cpu/vulnerabilities/meltdown:
    exists: true
    contains:
      - "Mitigation"
  /proc/sys/kernel/randomize_va_space:
    exists: true
    contains:
      - "2"

mount:
  /dev/shm:
    exists: true
    opts:
      - nosuid
      - nodev
      - noexec
  /tmp:
    exists: true
    opts:
      - nosuid
      - nodev
      - noexec

service:
  cups:
    enabled: false
    running: false
  rpcbind:
    enabled: false
    running: false
  auditd:
    enabled: true
    running: true
  sshd:
    enabled: true
    running: true

package:
  telnet:
    installed: false
  rsh-client:
    installed: false
  auditd:
    installed: true

port:
  tcp:111:
    listening: false
  tcp:631:
    listening: false
  tcp:22:
    listening: true
    ip:
      - 0.0.0.0

command:
  systemd-analyze-security-nginx:
    exec: "systemd-analyze security nginx.service --no-pager | tail -1"
    exit-status: 0
    stdout:
      - "/exposure level for nginx.service: [0-2]\\./"
  no-writable-executable-mappings:
    exec: "awk '/rwxp/ {c++} END {print c+0}' /proc/*/maps 2>/dev/null"
    exit-status: 0
    stdout:
      - "0"
  no-unexpected-file-capabilities:
    exec: "getcap -r /usr /opt /srv 2>/dev/null | grep -c cap_sys_admin || true"
    exit-status: 0
    stdout:
      - "0"
```

```console
$ sudo goss -g /etc/goss/hardening.yaml validate --format documentation
Kernel Param: kernel.randomize_va_space: value: matches expectation: ["2"]
Kernel Param: kernel.kptr_restrict: value: matches expectation: ["2"]
Kernel Param: kernel.yama.ptrace_scope: value: matches expectation: ["1"]
File: /boot/grub/grub.cfg: mode: matches expectation: ["0600"]
File: /boot/grub/grub.cfg: contains: matches expectation: ["set superusers=", "password_pbkdf2", "--unrestricted"]
Mount: /dev/shm: opts: matches expectation: ["nosuid", "nodev", "noexec"]
Service: cups: running: matches expectation: [false]
Port: tcp:111: listening: matches expectation: [false]
Command: systemd-analyze-security-nginx: exit-status: matches expectation: [0]

Total Duration: 0.412s
Count: 41, Failed: 0, Skipped: 0
```

### 11.2 Escaneo de cumplimiento con OpenSCAP

```console
$ sudo dnf install -y openscap-scanner scap-security-guide

$ sudo oscap info /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml | grep -A12 Profiles
Profiles:
  Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
    Id: xccdf_org.ssgproject.content_profile_cis_server_l1
  Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 2 - Server
    Id: xccdf_org.ssgproject.content_profile_cis
  Title: DISA STIG for Red Hat Enterprise Linux 9
    Id: xccdf_org.ssgproject.content_profile_stig
  Title: PCI-DSS v4.0 Control Baseline
    Id: xccdf_org.ssgproject.content_profile_pci-dss

$ sudo oscap xccdf eval \
    --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --results-arf /var/log/oscap/arf-$(hostname)-2026-08-24.xml \
    --report /var/log/oscap/report-$(hostname)-2026-08-24.html \
    /usr/share/xml/scap/ssg/content/ssg-rl9-ds.xml
Title   Ensure ASLR is enabled
Rule    xccdf_org.ssgproject.content_rule_sysctl_kernel_randomize_va_space
Ident   CCE-83700-7
Result  pass

Title   Disable Core Dumps for SUID programs
Rule    xccdf_org.ssgproject.content_rule_sysctl_fs_suid_dumpable
Ident   CCE-80953-5
Result  pass

Title   Set Boot Loader Password in grub2
Rule    xccdf_org.ssgproject.content_rule_grub2_password
Ident   CCE-80828-9
Result  pass

Title   Disable Kernel Support for USB via Bootloader Configuration
Rule    xccdf_org.ssgproject.content_rule_grub2_nousb_argument
Ident   CCE-90853-4
Result  fail

Title   Uninstall rsync-daemon Package
Rule    xccdf_org.ssgproject.content_rule_package_rsyncd_removed
Ident   CCE-89757-0
Result  pass
```

| Línea base | Fortaleza | Debilidad | Cuándo usarla |
|---|---|---|---|
| **CIS Nivel 1** | Amplia, bajo riesgo de rotura, bien conocida por los auditores | Conservadora; se pierde las mitigaciones modernas (lockdown, sandboxing) | Línea base por defecto de la flota |
| **CIS Nivel 2** | Agrega particionado, auditoría, montajes más estrictos | Riesgo real de rotura; asume particiones dedicadas | Hosts regulados / de alto valor |
| **DISA STIG** | El más prescriptivo; mapea a un catálogo formal de controles | Pesado; muchas reglas irrelevantes para cargas en la nube | Contratos de gobierno / defensa |
| **PCI-DSS** | Acotada a entornos de datos de titulares de tarjetas | Estrecha; no es una línea base de endurecimiento general | Solo hosts del CDE |
| **Personalizada (este rol)** | Coincide con tu modelo de amenaza y tu carga de trabajo reales | Vos sos dueño del mantenimiento y del relato de auditoría | En todas partes — superpuesta *encima de* una línea base reconocida |

La posición honesta: ejecutá un perfil reconocido para el relato de auditoría, y ejecutá tu propia suite de `goss` para los controles que el perfil no cubre (puntajes de exposición del sandbox de systemd, estado `SMT vulnerable`, integridad de la política de USBGuard, valores de sysctl por interfaz). El perfil satisface al auditor; la suite de `goss` satisface al modelo de amenaza.

---

## 12. Manual de diagnóstico de fallos

### 12.1 Síntoma → causa → comando

| Síntoma | Causa más probable | Primer comando |
|---|---|---|
| El host arranca a un prompt de usuario de GRUB | `superusers` sin `--unrestricted` | Medio de rescate → `grep -c -- --unrestricted /boot/grub/grub.cfg` |
| El host arranca, la red está muerta | `sysctl` con `ip_forward=0` en un router/nodo de k8s, o módulo de NIC en lista negra | `ip -br a`, `sysctl net.ipv4.ip_forward`, `dmesg \| grep -i firmware` |
| El servicio muere con `status=31/SYS` | Denegación de seccomp por `SystemCallFilter` | `ausearch -m SECCOMP -ts recent -i` |
| El servicio muere con `Read-only file system` | `ProtectSystem=strict` sin `ReadWritePaths=` | `systemctl show -p ReadWritePaths,ProtectSystem <unit>` |
| Un contenedor rootless no arranca | `user.max_user_namespaces=0` o `RestrictNamespaces=yes` | `sysctl user.max_user_namespaces` |
| JVM/Node aborta inmediatamente tras un despliegue de endurecimiento | `MemoryDenyWriteExecute=yes` | `systemctl show -p MemoryDenyWriteExecute <unit>` |
| Un script de posinstalación de `apt`/`dnf` falla con `Permission denied` | `noexec` en `/tmp` | `findmnt /tmp -o OPTIONS` |
| El monitoreo muestra cero procesos | `hidepid` o `ProtectProc=invisible` | `findmnt /proc -o OPTIONS`; `id <agent-user>` contra `gid=` |
| Teclado de consola muerto | Política de USBGuard | GRUB → `systemd.mask=usbguard.service` |
| `gdb -p` / `strace -p` rechazados | `kernel.yama.ptrace_scope >= 1` | `sysctl kernel.yama.ptrace_scope` |
| La compilación de DKMS falla tras el reinicio | `lockdown=integrity` + `module.sig_enforce=1` | `cat /sys/kernel/security/lockdown`; `modinfo <mod> \| grep sig` |
| `kdump` no produce vmcore | `kernel.kexec_load_disabled=1` | `sysctl kernel.kexec_load_disabled` |
| El rendimiento cayó 30 % tras actualizar el kernel | Nueva mitigación de CPU habilitada por defecto | `grep -r . /sys/devices/system/cpu/vulnerabilities/` |
| Los usuarios no pueden iniciar sesión por SSH tras un cambio | Permisos del directorio de instancia de `pam_namespace` | `journalctl -t sshd \| grep -i namespace`; `ls -ld /tmp-inst` |

### 12.2 La lista de verificación previa al reinicio

Cada uno de los controles de este material puede producir un host que arranca pero es inutilizable, o que directamente no arranca. Antes de cualquier reinicio que aplique nuevo endurecimiento:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/pre-reboot-hardening-check
# Run BEFORE rebooting a host with newly applied hardening. Exit 1 = do not reboot.
set -uo pipefail
rc=0
say() { printf '%-8s %s\n' "$1" "$2"; }

# 1. Is there a way back in that does not need the console?
if ! systemctl is-enabled --quiet sshd 2>/dev/null; then
  say FAIL "sshd is not enabled — no remote path back in"; rc=1
else
  say OK "sshd enabled"
fi

# 2. Does the GRUB config still parse, and can the default entry boot unattended?
if grep -q 'set superusers=' "${GRUB_CFG:-/boot/grub/grub.cfg}" 2>/dev/null; then
  if grep -q -- '--unrestricted' "${GRUB_CFG:-/boot/grub/grub.cfg}"; then
    say OK "GRUB password set, default entries unrestricted"
  else
    say FAIL "GRUB superuser set but NO --unrestricted entry: boot will block"; rc=1
  fi
fi

# 3. Will every currently loaded module still load under sig_enforce?
if grep -qw 'module.sig_enforce=1' /proc/cmdline /etc/default/grub 2>/dev/null; then
  unsigned=$(lsmod | tail -n +2 | awk '{print $1}' \
    | while read -r m; do modinfo "$m" 2>/dev/null | grep -q '^sig_id' || echo "$m"; done)
  if [[ -n "$unsigned" ]]; then
    say FAIL "unsigned modules present with sig_enforce pending: $unsigned"; rc=1
  else
    say OK "all loaded modules are signed"
  fi
fi

# 4. Is the root account recoverable from the console?
if [[ "$(passwd -S root | awk '{print $2}')" == "L" ]] \
   && ! systemctl cat emergency.service 2>/dev/null | grep -q SULOGIN_FORCE; then
  say WARN "root is locked and emergency shell requires a password — console recovery impossible"
fi

# 5. Do the sysctl drop-ins still parse?
if ! sysctl -p /etc/sysctl.d/99-hardening.conf -n >/dev/null 2>&1; then
  say FAIL "/etc/sysctl.d/99-hardening.conf does not parse"; rc=1
else
  say OK "sysctl drop-in parses"
fi

# 6. USBGuard: is a keyboard in the policy?
if systemctl is-enabled --quiet usbguard 2>/dev/null; then
  if usbguard list-devices 2>/dev/null | grep -q 'allow.*03:01:01'; then
    say OK "a HID keyboard is allowed by the USBGuard policy"
  else
    say WARN "USBGuard enabled with no allowed HID keyboard — console lockout risk"
  fi
fi

exit $rc
```

```console
$ sudo /usr/local/sbin/pre-reboot-hardening-check
OK       sshd enabled
FAIL     GRUB superuser set but NO --unrestricted entry: boot will block
OK       all loaded modules are signed
WARN     root is locked and emergency shell requires a password — console recovery impossible
OK       sysctl drop-in parses
OK       a HID keyboard is allowed by the USBGuard policy
$ echo $?
1
```

### 12.3 Rutas de recuperación, ordenadas

1. **SSH todavía funciona** — se arregla en el lugar, esto no es un incidente.
2. **Consola fuera de banda (iDRAC/iLO/IPMI SoL/consola serie en la nube)** — editar la entrada de GRUB (requiere la contraseña de superusuario, que es por lo que pertenece a tu gestor de secretos y no a la cabeza de una persona del equipo), agregar `systemd.unit=rescue.target`, `systemd.mask=<unit>` o `mitigations=off`.
3. **Consola física** — igual que arriba; bloqueada por una contraseña de firmware si la definiste, que es el intercambio que aceptaste.
4. **Medio de rescate/live** — bloqueado por el bloqueo del orden de arranque y Secure Boot; requiere la contraseña de firmware. Hacer chroot, revertir, `grub-mkconfig`.
5. **Reaprovisionar** — la razón por la cual las imágenes doradas inmutables junto con una tubería de reconstrucción rápida son en sí mismas un control de endurecimiento: un host que podés recrear en cuatro minutos es un host que te podés permitir bloquear agresivamente.

La conclusión arquitectónica: **la agresividad de tu endurecimiento debería ser proporcional a la velocidad de tu ruta de recuperación.** Un servidor mascota sin acceso fuera de banda recibe una línea base conservadora. Un nodo ganado detrás de un grupo de autoescalado y una imagen de Packer recibe `lockdown=integrity`, `module.sig_enforce=1`, `mitigations=auto,nosmt`, `kernel.modules_disabled=1` y un servicio completamente encapsulado — porque el peor caso es una instancia terminada, no un viaje de 200 km hasta un rack.

---

## Referencias

- LPI — Objetivos del examen 303-300 (LPIC-3 Security, v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- Manual de GNU GRUB — Seguridad y `password_pbkdf2`: https://www.gnu.org/software/grub/manual/grub/grub.html#Security
- Invocación de `grub-mkpasswd-pbkdf2`: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dmkpasswd_002dpbkdf2
- Red Hat — Gestión, monitoreo y actualización del kernel (GRUB, `grubby`, BLS): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/index
- Wiki de Debian — Protección con contraseña de GRUB 2: https://wiki.debian.org/Grub2
- Kernel de Linux — Kernel Lockdown (`kernel_lockdown.7`): https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- Kernel de Linux — Parámetros de la línea de comandos del kernel: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Kernel de Linux — Vulnerabilidades de hardware (Meltdown, Spectre, MDS, L1TF, Retbleed, SRSO): https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/index.html
- Kernel de Linux — Documentación de `/proc/sys/kernel/` (`randomize_va_space`, `kptr_restrict`, `dmesg_restrict`, `modules_disabled`, `kexec_load_disabled`, `perf_event_paranoid`, `sysrq`, `yama`): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
- Kernel de Linux — Referencia de `/proc/sys/net/` y sysctl de IP (`rp_filter`, `accept_redirects`, `log_martians`, semántica de `all` vs `default`): https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
- Kernel de Linux — `/proc/sys/fs/` (`protected_symlinks`, `protected_hardlinks`, `protected_fifos`, `protected_regular`, `suid_dumpable`): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html
- Kernel de Linux — LSM Yama (`ptrace_scope`): https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html
- Kernel de Linux — Autorización de dispositivos USB (`authorized`, `authorized_default`): https://www.kernel.org/doc/html/latest/driver-api/usb/authorization.html
- Kernel de Linux — `proc(5)`, opciones de montaje incluidas `hidepid` y `subset`: https://man7.org/linux/man-pages/man5/proc.5.html
- Kernel Self Protection Project — configuración recomendada: https://kernsec.org/wiki/index.php/Kernel_Self_Protection_Project/Recommended_Settings
- systemd — `systemd.exec(5)`, directivas de sandboxing: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — `systemd.resource-control(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- systemd — `systemd-analyze(1)`, verbo `security`: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- systemd — `systemd-sysctl.service(8)` y orden de carga de `sysctl.d(5)`: https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html
- systemd — `systemctl(1)` (`mask`, `disable`, `list-unit-files`): https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- USBGuard — documentación oficial: https://usbguard.github.io/documentation/
- USBGuard — referencia del lenguaje de reglas (`usbguard-rules.conf(5)`): https://usbguard.github.io/documentation/rule-language.html
- USBGuard — configuración del demonio (`usbguard-daemon.conf(5)`): https://github.com/USBGuard/usbguard/blob/main/doc/usbguard-daemon.conf.5.md
- Linux-PAM — `pam_namespace(8)`: https://man7.org/linux/man-pages/man8/pam_namespace.8.html
- Linux-PAM — `namespace.conf(5)`: https://man7.org/linux/man-pages/man5/namespace.conf.5.html
- Linux-PAM — Guía del administrador: https://github.com/linux-pam/linux-pam/blob/master/doc/sag/pam.md
- `capabilities(7)` — conjuntos de capacidades, capacidades de archivo, conjunto ambiente: https://man7.org/linux/man-pages/man7/capabilities.html
- `personality(2)` — `ADDR_NO_RANDOMIZE` y `LockPersonality=`: https://man7.org/linux/man-pages/man2/personality.html
- `seccomp(2)` y filtrado seccomp-bpf: https://man7.org/linux/man-pages/man2/seccomp.html
- `prctl(2)` — `PR_SET_NO_NEW_PRIVS`: https://man7.org/linux/man-pages/man2/prctl.html
- `modprobe.d(5)` — `blacklist` vs `install`: https://man7.org/linux/man-pages/man5/modprobe.d.html
- `mount(8)` — `nodev`, `nosuid`, `noexec`: https://man7.org/linux/man-pages/man8/mount.8.html
- GCC — Opciones de instrumentación y endurecimiento (`-fstack-protector-strong`, `-fstack-clash-protection`, `-fcf-protection`): https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html
- glibc — `_FORTIFY_SOURCE` (niveles 1, 2 y 3): https://www.gnu.org/software/libc/manual/html_node/Source-Fortification.html
- OpenSSF — Guía de endurecimiento de opciones del compilador para C y C++: https://best.openssf.org/Compiler-Hardening-Guides/Compiler-Options-Hardening-Guide-for-C-and-C++.html
- Wiki de Debian — Endurecimiento y `hardening-check`: https://wiki.debian.org/Hardening
- `checksec` — página del proyecto: https://github.com/slimm609/checksec.sh
- OpenSCAP — manual de usuario y `oscap(8)`: https://www.open-scap.org/tools/openscap-base/
- SCAP Security Guide — perfiles y reglas: https://complianceascode.readthedocs.io/en/latest/
- CIS Benchmarks — Linux: https://www.cisecurity.org/cis-benchmarks
- DISA STIGs — Red Hat Enterprise Linux: https://public.cyber.mil/stigs/downloads/
- NIST SP 800-123 — Guía de seguridad general de servidores: https://csrc.nist.gov/pubs/sp/800/123/final
- UEFI Secure Boot en Linux — `mokutil(1)` y shim: https://github.com/rhboot/shim/blob/main/README.md
- Ansible — Colecciones `ansible.posix` y `community.general`: https://docs.ansible.com/ansible/latest/collections/index.html
- goss — validación de servidores: https://github.com/goss-org/goss