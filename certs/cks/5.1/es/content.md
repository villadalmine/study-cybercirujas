# 5.1 Minimizar la superficie del SO anfitrión (reducir la superficie de ataque)

> **CKS v1.34 — Dominio: System Hardening — Peso 2.5**
> Lectura previa: componentes del nodo (kubelet, container runtime, kube-proxy), namespaces/cgroups de Linux, modelo de unidades de systemd.
> Temas adyacentes: 5.2 (minimizar roles IAM), 5.3 (minimizar el acceso externo a la red), 5.4 (AppArmor/seccomp), 6.x (detección en runtime).

---

## 1. El problema arquitectónico

### 1.1 El nodo es el último límite de aislamiento, y es compartido

Un nodo worker de Kubernetes no es "un servidor que casualmente ejecuta contenedores". Es un **kernel multi-tenant** donde cada workload planificado sobre él comparte un mismo árbol de `struct task_struct`, una misma page cache, un mismo stack de red, un mismo conjunto de puntos de entrada de syscalls y un mismo conjunto de módulos de kernel cargados. Los namespaces y los cgroups particionan *vistas* de ese kernel; no particionan el kernel en sí.

Eso tiene una consecuencia que gobierna todo este tema: **cualquier cosa alcanzable desde dentro de un contenedor que viva fuera de los namespaces del contenedor es superficie de ataque del host**, y cualquier cosa que un atacante pueda alcanzar después de un escape de contenedor es superficie de ataque del *nodo*. Reducir la superficie del SO anfitrión no es higiene de distribución: es la diferencia entre "un pod comprometido" y "un clúster comprometido".

### 1.2 Qué obtiene realmente un atacante a partir de un nodo

Enumerá el radio de impacto con precisión, porque es lo que justifica el costo del trabajo:

| Activo presente en un nodo worker de fábrica | Ruta | Qué habilita |
|---|---|---|
| Certificado cliente del kubelet | `/var/lib/kubelet/pki/kubelet-client-current.pem` | Identidad `system:node:<name>` en el grupo `system:nodes`. Con `NodeRestriction` + Node authorizer: leer **cada Secret, ConfigMap, PVC y token de SA referenciado por los pods planificados en ese nodo**. |
| Bootstrap/kubeconfig del kubelet | `/etc/kubernetes/kubelet.conf`, `/etc/kubernetes/bootstrap-kubelet.conf` | Lo mismo, más autoemisión de CSR si el bootstrap token sigue siendo válido. |
| Tokens de SA proyectados de *cada* pod del nodo | `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~projected/.../token` | La unión del RBAC de todos los workloads co-tenant. Suele ser el botín más gordo de la máquina. |
| Socket del container runtime | `/run/containerd/containerd.sock` | Arrancar un contenedor privilegiado con `/` montado por bind → root completo, evitando todo el admission control. |
| Credenciales de instancia de nube | `169.254.169.254` (IMDS) | El rol IAM del node group: a menudo lectura `ec2:*`, pull de ECR, a veces S3 o Secrets Manager. |
| Directorio de static pods (control plane) | `/etc/kubernetes/manifests/` | Acceso de escritura = pod privilegiado arbitrario ejecutado por el kubelet, sin API server de por medio, sin evento de auditoría por su creación. |
| Datos de etcd (control plane) | `/var/lib/etcd` | El clúster entero, en texto plano salvo que esté configurado el cifrado en reposo. |

### 1.3 Por qué "simplemente parchealo" es el modelo equivocado

Una imagen de servidor de propósito general viene optimizada para el problema de *otra persona*: administración interactiva, workloads arbitrarios, soporte amplio de hardware, retrocompatibilidad. En un nodo de Kubernetes prácticamente nada de eso hace falta, y sin embargo heredás todo el pasivo:

- **Superficie de paquetes.** Cada paquete instalado es un feed de CVEs al que te suscribiste y una actualización que tenés que planificar. Una imagen cloud de Ubuntu Server de fábrica tiene ~600 paquetes; un nodo necesita quizás 150 de ellos.
- **Primitivas de escalada de privilegios.** `pkexec` (CVE-2021-4034, root instantáneo desde cualquier shell local), `polkit`, `snapd` (CVE-2019-7304 "dirty_sock"), `at`, `chsh`. Ninguna es necesaria para ejecutar contenedores, todas son SUID-root o daemons root alcanzables *después* de un escape — y un escape que te deja como UID 0 dentro de un user namespace todavía necesita una escalada local para convertirse en root real en algunas configuraciones.
- **Superficie del kernel.** Un kernel genérico autocarga módulos bajo demanda. Los `CONFIG_*` de DCCP, SCTP, TIPC, RDS, AX.25 y una docena de sistemas de archivos heredados vienen habilitados; un único `socket(AF_TIPC, ...)` desde un contenedor sin privilegios autocarga código que nunca fue revisado para entradas hostiles (CVE-2021-43267, TIPC, root remoto; CVE-2022-0435, TIPC otra vez; CVE-2021-3715, `sch_route`).
- **Tiempo hasta el parche.** Los nodos mutables derivan. El nodo #47 se construyó en marzo, se parcheó en mayo y tiene un paquete de depuración instalado a mano que nadie recuerda. La gestión de configuración converge *parte* del estado; la imagen del host converge *todo*.

La respuesta de producción no es entonces un ciclo de parcheo más largo sino **un nodo más chico, inmutable y reconstruible**:

```
mutable node model:      build once → drift → patch → drift → patch → forensic mystery
immutable node model:    build image (signed, versioned) → boot → drain → replace → repeat
```

El valor de seguridad de la inmutabilidad no es que el disco sea de solo lectura. Es que **la persistencia se vuelve difícil** (no hay dónde escribir un rootkit que sobreviva), **la deriva se vuelve imposible** (el nodo #47 es idéntico byte a byte al nodo #1) y **parchear se vuelve un deploy** (el mismo pipeline probado y revisable que ya usás para las aplicaciones).

### 1.4 Las cuatro superficies, y el orden en que atacarlas

| Superficie | Pregunta | Control principal | Rédito |
|---|---|---|---|
| **Alcanzable por red** | ¿Qué acepta bytes desde fuera de la máquina? | Inventario de puertos + firewall de host + bind-address | El más alto — pre-autenticación remota |
| **Escalada local** | ¿Qué convierte "shell como nobody tras un escape" en root? | Purga de SUID/SGID, política de sudo, sin usuarios interactivos | Alto — es lo que convierte un escape en propiedad del nodo |
| **API del kernel** | ¿Qué código de kernel puede alcanzar un contenedor sin privilegios? | Lista negra de módulos, `sysctl`, lockdown, seccomp por defecto | Alto — los escapes de contenedor son casi siempre bugs de kernel |
| **Persistencia/cadena de suministro** | ¿Qué sobrevive a un reinicio, y quién lo puso ahí? | rootfs inmutable, dm-verity, Secure Boot, imágenes firmadas | Medio ahora, decisivo durante la respuesta a incidentes |

Trabajá de arriba hacia abajo. No empieces afinando `sysctl` mientras `sshd` acepta contraseñas desde internet.

---

## 2. Línea base: medir antes de cortar

No podés minimizar lo que no inventariaste. Ejecutá esto en un nodo representativo **antes** de cualquier cambio y guardá la salida como artefacto: es tu base de comparación y tu evidencia para el auditor.

```bash
$ cat /etc/os-release | head -2
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"

$ uname -r
6.8.0-79-generic

$ dpkg-query -f '${binary:Package}\n' -W | wc -l
612

$ systemctl list-units --type=service --state=running --no-legend --no-pager | wc -l
27

$ systemctl list-units --type=service --state=running --no-legend --no-pager
  containerd.service       loaded active running containerd container runtime
  cron.service             loaded active running Regular background program processing daemon
  dbus.service             loaded active running D-Bus System Message Bus
  getty@tty1.service       loaded active running Getty on tty1
  irqbalance.service       loaded active running irqbalance daemon
  kubelet.service          loaded active running kubelet: The Kubernetes Node Agent
  ModemManager.service     loaded active running Modem Manager
  multipathd.service       loaded active running Device-Mapper Multipath Device Controller
  networkd-dispatcher.se.. loaded active running Dispatcher daemon for systemd-networkd
  polkit.service           loaded active running Authorization Manager
  rsyslog.service          loaded active running System Logging Service
  snapd.service            loaded active running Snap Daemon
  ssh.service              loaded active running OpenBSD Secure Shell server
  systemd-journald.service loaded active running Journal Service
  systemd-logind.service   loaded active running User Login Management
  systemd-networkd.service loaded active running Network Configuration
  systemd-resolved.service loaded active running Network Name Resolution
  systemd-timesyncd.serv.. loaded active running Network Time Synchronization
  systemd-udevd.service    loaded active running Rule-based Manager for Device Events and Files
  udisks2.service          loaded active running Disk Manager
  unattended-upgrades.ser. loaded active running Unattended Upgrades Shutdown
  ...
```

`ModemManager`, `udisks2`, `multipathd` (si no hay multipath FC/iSCSI), `snapd` y `polkit` en un nodo de Kubernetes sin monitor en 2026 son puro pasivo.

**Sockets en escucha** — el único inventario que importa para la superficie remota:

```bash
$ ss -tulpnH | column -t
udp  UNCONN  0  0  127.0.0.54:53      0.0.0.0:*  users:(("systemd-resolve",pid=712,fd=17))
udp  UNCONN  0  0  127.0.0.53%lo:53   0.0.0.0:*  users:(("systemd-resolve",pid=712,fd=15))
udp  UNCONN  0  0  0.0.0.0:8472       0.0.0.0:*
tcp  LISTEN  0  4096  127.0.0.1:10248 0.0.0.0:*  users:(("kubelet",pid=1544,fd=25))
tcp  LISTEN  0  4096  127.0.0.1:10249 0.0.0.0:*  users:(("kube-proxy",pid=2210,fd=14))
tcp  LISTEN  0  4096  0.0.0.0:10250   0.0.0.0:*  users:(("kubelet",pid=1544,fd=27))
tcp  LISTEN  0  4096  0.0.0.0:10255   0.0.0.0:*  users:(("kubelet",pid=1544,fd=26))
tcp  LISTEN  0  4096  0.0.0.0:10256   0.0.0.0:*  users:(("kube-proxy",pid=2210,fd=16))
tcp  LISTEN  0  128   0.0.0.0:22      0.0.0.0:*  users:(("sshd",pid=1102,fd=3))
tcp  LISTEN  0  4096  127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=712,fd=16))
```

`0.0.0.0:10255` es el **puerto de solo lectura** del kubelet: sin autenticación, y un `GET /pods` sobre él devuelve la spec de cada pod del nodo, incluidas variables de entorno y los nombres de cada Secret montado. Esa única línea es el hallazgo real más común en una primera auditoría de nodo al estilo CKS.

**Inventario de SUID/SGID:**

```bash
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
    -printf '%04m %u:%g %p\n' 2>/dev/null | sort
2755 root:shadow /usr/bin/chage
2755 root:crontab /usr/bin/crontab
2755 root:shadow /usr/bin/expiry
4755 root:root /usr/bin/chfn
4755 root:root /usr/bin/chsh
4755 root:root /usr/bin/fusermount3
4755 root:root /usr/bin/gpasswd
4755 root:root /usr/bin/mount
4755 root:root /usr/bin/newgrp
4755 root:root /usr/bin/passwd
4755 root:root /usr/bin/su
4755 root:root /usr/bin/umount
4755 root:root /usr/lib/openssh/ssh-keysign
4755 root:root /usr/lib/polkit-1/polkit-agent-helper-1
4755 root:root /usr/bin/pkexec
4755 root:root /usr/bin/sudo
2755 root:tty /usr/bin/wall
2755 root:tty /usr/bin/write
...
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l
26
```

**Módulos cargados y capacidad de autocarga:**

```bash
$ lsmod | wc -l
119

$ cat /proc/sys/kernel/modules_disabled
0

$ cat /sys/kernel/security/lockdown
[none] integrity confidentiality
```

**Puntuación de exposición de systemd** — una lista rápida y ordenada de "qué debería aislar o borrar":

```bash
$ systemd-analyze security --no-pager | head -20
UNIT                                  EXPOSURE PREDICATE HAPPY
containerd.service                         9.6 UNSAFE    😨
kubelet.service                            9.6 UNSAFE    😨
snapd.service                              9.5 UNSAFE    😨
ssh.service                                9.6 UNSAFE    😨
udisks2.service                            9.4 UNSAFE    😨
ModemManager.service                       8.3 EXPOSED   🙁
polkit.service                             8.2 EXPOSED   🙁
rsyslog.service                            8.0 EXPOSED   🙁
irqbalance.service                         6.6 MEDIUM    😐
systemd-journald.service                   4.9 OK        🙂
systemd-udevd.service                      3.9 OK        🙂
systemd-resolved.service                   2.2 OK        🙂
```

Leé esto correctamente: `kubelet` y `containerd` puntúan 9.6 **y eso es inevitable** — tienen que montar sistemas de archivos, entrar en namespaces, escribir cgroups y gestionar dispositivos. No los arreglás con `ProtectSystem=strict`; los arreglás *no agregando un 27º servicio al lado de ellos*. La puntuación es accionable para los daemons accesorios, no para el runtime.

### 2.1 Comparación de huella de referencia

Los números de abajo corresponden a una build de referencia de cada caso (imágenes de nodo construidas en 2026-07, x86-64, kubelet 1.34, containerd 2.x), medidos con los comandos anteriores. Tomalos como órdenes de magnitud, no como constantes.

| Imagen de nodo | Paquetes / unidades instaladas | Servicios en ejecución | Puertos en escucha `0.0.0.0` | Archivos SUID/SGID | Root FS escribible | Gestor de paquetes en la máquina |
|---|---|---|---|---|---|---|
| Ubuntu 24.04 Server (imagen cloud de fábrica) | ~612 | 27 | 22, 10250, 10255, 10256, 8472 | 26 | sí | apt + snap |
| Ubuntu 24.04 minimizado (este documento) | ~430 | 12 | 10250, 10256, 8472 | 6 | sí | apt (offline) |
| Flatcar Container Linux | n/a (basado en imagen) | 11 | 22, 10250, 10256 | 5 | `/usr` de solo lectura, `/etc` escribible | ninguno |
| Bottlerocket | n/a (basado en imagen) | 9 | 10250 | 0 (sin userland general) | dm-verity, RO | ninguno |
| Talos Linux | n/a (squashfs único) | n/a (sin systemd, sin shell) | 50000/tcp (apid), 10250 | 0 | RO, sin `/bin/sh` | ninguno |

El paso de la columna 2 a la columna 3 es una *migración*; el paso de la columna 1 a la columna 2 es un *fin de semana*. Ambos valen la pena; hacé primero el segundo.

---

## 3. Elegir el SO anfitrión: compromisos

| Criterio | Propósito general (Ubuntu/RHEL/Debian) | Flatcar Container Linux | Bottlerocket | Talos Linux | RHCOS (OpenShift) |
|---|---|---|---|---|---|
| Modelo de actualización | paquete por paquete, in situ | partición A/B, atómica, reinicio automático vía `locksmithd`/Kured | partición A/B, atómica, `apiclient update` | imagen A/B, atómica, `talosctl upgrade` | rpm-ostree, atómica |
| Sistema de archivos raíz | lectura-escritura | `/usr` de solo lectura, `/etc` escribible | protegido con dm-verity, solo lectura | squashfs de solo lectura | solo lectura, ostree |
| Shell en el nodo | completa | completa (usuario `core`, SSH) | **ninguna por defecto**; host-container `admin` solo si se habilita | **ninguna, nunca** — sin `/bin/sh`, sin SSH | completa (`core`, SSH) |
| Gestor de paquetes | sí (pasivo enorme) | no | no | no | solo rpm-ostree |
| Interfaz de configuración | cualquiera (Ansible, cloud-init, manual) | Ignition (solo en el arranque) | API TOML (`apiclient set`) | machine config YAML vía API gRPC | Ignition + MachineConfig operator |
| Control de módulos de kernel | completo, manual | completo, vía Ignition | conjunto curado | curado + extensiones declarativas | completo |
| Depurabilidad | trivial | fácil | `enter-admin-container` | solo subcomandos de `talosctl` (`logs`, `dmesg`, `read`) | fácil |
| Binarios SUID | ~26 | ~5 | no aplica | ninguno | ~20 |
| Radio de impacto de un escape | root en una máquina Linux completa | root en una máquina sin compilador, `/usr` RO | root dentro de un contenedor; el host no tiene herramientas | el atacante no tiene shell donde ejecutar | root en una máquina completa |
| Fricción con el ecosistema | ninguna | baja | centrado en AWS/EKS (también bare metal vía `bottlerocket-bootstrap`) | alta: nada de DaemonSets de agente de nodo que esperen `nsenter`+shell | solo OpenShift |
| Encaje | brownfield, heterogeneidad on-prem | buen inmutable de propósito general | flotas AWS-first | greenfield, máxima garantía | ya compraste OpenShift |

**Guía arquitectónica.** Si podés elegir, elegí un SO basado en imagen; la ganancia de seguridad es estructural y no depende de la configuración. Si no podés — los entornos regulados con agentes obligatorios (EDR, escáneres de vulnerabilidades, backup) frecuentemente descartan Talos y Bottlerocket, porque esos agentes asumen una shell y un gestor de paquetes — entonces comprometete con el programa de minimización de §4–§11 *y* hacelo cumplir construyendo la imagen del nodo en CI (Packer / `kubernetes-sigs/image-builder`) en lugar de converger el nodo con gestión de configuración en tiempo de ejecución.

La partida de costo más subestimada: **Talos y Bottlerocket rompen todo DaemonSet que hace shell dentro del host**. Auditá tus DaemonSets con `hostPID: true` + `nsenter` antes de comprometerte.

---

## 4. Eliminar servicios: `disable` vs `mask` vs `purge`

### 4.1 Los tres niveles

| Acción | Comando | Efecto | ¿Puede volver? |
|---|---|---|---|
| Detener | `systemctl stop X` | Se mata la instancia en ejecución | Sí — al reiniciar, por activación por socket, por un `Wants=` de cualquier otra unidad |
| Deshabilitar | `systemctl disable --now X` | Elimina los symlinks de `[Install]` | **Sí** — una dependencia (`Wants=`/`Requires=`) de otra unidad la sigue arrastrando, y la activación por D-Bus/socket la sigue arrancando |
| Enmascarar | `systemctl mask --now X` | Enlaza la unidad a `/dev/null` | No — los intentos de arranque fallan duro, incluidas las dependencias que la arrastran |
| Purgar | `apt-get purge X` / no está en la imagen | El código no está en disco | No |

**Preferí `purge` en tiempo de construcción de imagen y `mask` en tiempo de ejecución.** `disable` a secas es el arreglo incompleto clásico: `ModemManager` y `udisks2` se activan por D-Bus y se van a reiniciar solos; `snapd` se activa por socket vía `snapd.socket`.

```bash
# WRONG — snapd comes back on the next snap-related D-Bus/socket event
$ sudo systemctl disable --now snapd.service
Removed "/etc/systemd/system/multi-user.target.wants/snapd.service".
$ sudo systemctl is-active snapd.socket
active

# RIGHT
$ sudo systemctl mask --now snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service
Created symlink /etc/systemd/system/snapd.service → /dev/null.
Created symlink /etc/systemd/system/snapd.socket → /dev/null.
Created symlink /etc/systemd/system/snapd.seeded.service → /dev/null.
Created symlink /etc/systemd/system/snapd.apparmor.service → /dev/null.
```

### 4.2 Qué eliminar en un nodo de Kubernetes

| Unidad / paquete | Por qué existe | ¿Seguro de eliminar en un nodo? | Salvedad |
|---|---|---|---|
| `ModemManager` | Módems celulares | **Sí** | — |
| `udisks2` | Automontaje de medios extraíbles de escritorio | **Sí** | — |
| `snapd` (+ `snapd.socket`) | Snaps de Ubuntu | **Sí**, salvo que un agente de nube sea un snap | `amazon-ssm-agent`, `google-guest-agent` vienen como snaps en algunas imágenes cloud de Ubuntu — verificá primero |
| `polkit` + `pkexec` | Intermediación de privilegios de escritorio | **Sí** | Elimina una primitiva de root local comprobada (CVE-2021-4034) |
| `cups*`, `avahi-daemon`, `bluetooth` | Impresión, mDNS, BT | **Sí** | Avahi abre UDP/5353 hacia la LAN |
| `rpcbind`, `nfs-common` | Cliente NFS | Solo si no hay CSI de NFS ni volúmenes `nfs` | `rpcbind` escucha en 111/tcp+udp |
| `multipathd` | Multipath FC/iSCSI | Sí si no hay ese tipo de almacenamiento | Requerido por varios drivers CSI de bloque — verificá |
| `whoopsie`, `apport` | Reporte de fallos al proveedor | **Sí** | `apport` además reescribe `kernel.core_pattern`; ver §7.4 |
| `unattended-upgrades` | Parcheo automático | **Depende** | En nodos mutables: mantenelo, solo con el pocket de seguridad. En nodos inmutables/construidos por imagen: **enmascaralo** — el parcheo ocurre reemplazando el nodo, y los reinicios sorpresa in situ de `containerd` causan incidentes a nivel de nodo |
| `cron` / `atd` | Trabajos programados | Enmascarar `atd`; mantener `cron` solo si algo lo usa | `at` es una primitiva de persistencia SUID |
| `getty@tty*`, `serial-getty@*` | Login por consola | Mantené **una** para acceso de emergencia en bare metal; enmascarala en VMs de nube donde el acceso por consola es fuera de banda | Perder todas las consolas en bare metal implica ir físicamente |
| `rsyslog` | Syslog local | Normalmente **sí** — `journald` + un DaemonSet que envíe logs alcanza | Si tu SIEM extrae syslog del host, mantenelo |
| `sshd` | Administración | **Idealmente sí** en flotas inmutables; si no, endurecelo fuerte (§9.3) | Eliminarlo antes de tener acceso fuera de banda es la forma de perder una flota |

```bash
$ sudo systemctl mask --now \
    ModemManager.service udisks2.service \
    avahi-daemon.service avahi-daemon.socket \
    bluetooth.service cups.service cups.socket \
    atd.service whoopsie.service apport.service \
    rpcbind.service rpcbind.socket
Created symlink /etc/systemd/system/ModemManager.service → /dev/null.
Created symlink /etc/systemd/system/udisks2.service → /dev/null.
...

$ sudo apt-get purge -y --autoremove \
    policykit-1 pkexec snapd modemmanager udisks2 \
    avahi-daemon bluez cups-common apport whoopsie \
    telnet ftp rsh-client talk finger \
    gcc g++ make binutils cpp perl-modules-5.38
Reading package lists... Done
The following packages will be REMOVED:
  apport* avahi-daemon* binutils* bluez* cpp* g++* gcc* make* modemmanager*
  pkexec* policykit-1* snapd* udisks2* whoopsie* ...
0 upgraded, 0 newly installed, 214 to remove and 0 not upgraded.
After this operation, 486 MB disk space will be freed.
```

> **La regla del compilador.** Un nodo con `gcc`, `make` y las cabeceras del kernel es un nodo donde un exploit de kernel puede compilarse *en el lugar* contra el kernel exacto que está corriendo. Construí los módulos DKMS (drivers de GPU, NICs ausentes del árbol) en el pipeline de imagen, nunca en el nodo.

### 4.3 Endurecer los servicios que sí tenés que conservar

Para los pocos daemons no pertenecientes al runtime que quedan, usá el sandboxing de systemd en lugar de confianza. Ejemplo para un `node_exporter` de host (el arquetipo de "daemon chico que tiene que quedarse"):

```ini
# /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --no-collector.wifi \
  --no-collector.hwmon \
  --collector.filesystem.mount-points-exclude='^/(dev|proc|sys|var/lib/kubelet/.+|run/containerd/.+)($|/)'

# --- identity -------------------------------------------------------------
DynamicUser=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=

# --- filesystem -----------------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=/
InaccessiblePaths=/etc/kubernetes /var/lib/kubelet /var/lib/etcd /root
ProtectProc=invisible
ProcSubset=pid

# --- kernel ---------------------------------------------------------------
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @mount @debug

[Install]
WantedBy=multi-user.target
```

```bash
$ sudo systemctl daemon-reload && sudo systemctl restart node_exporter
$ systemd-analyze security node_exporter.service --no-pager | tail -3
→ Overall exposure level for node_exporter.service: 1.4 OK 🙂
```

> **No intentes esto con `kubelet.service` ni `containerd.service`.** `ProtectKernelModules=yes` impide `modprobe`; `RestrictNamespaces=` rompe la creación de contenedores; `ProtectKernelTunables=yes` rompe la reconciliación de `--protect-kernel-defaults` y las escrituras de sysctl del CNI; `MountFlags=`/`ProtectSystem=` rompen la propagación de montajes compartidos que el kubelet necesita para CSI. Las únicas directivas de sandboxing consistentemente seguras en el kubelet son `ProtectHome=read-only` y `OOMScoreAdjust=-999` (esta última por disponibilidad, no por seguridad).

---

## 5. Minimización de paquetes e imagen

### 5.1 Runtime, no administración interactiva

Conjunto objetivo para un nodo worker: kernel + init + container runtime + kubelet + binarios de CNI + un stack de red + un enganche de agente de logs. Explícitamente *no*: compiladores, intérpretes más allá de lo que init necesita, `tcpdump`/`strace`/`gdb` (en su lugar despachalos en un contenedor efímero de depuración — ver §12.3), agentes de transporte de correo, bibliotecas de X, documentación.

```bash
# Biggest offenders, by installed size — a good place to look for surprises
$ dpkg-query -W -f='${Installed-Size}\t${binary:Package}\n' | sort -rn | head -12
187432  linux-image-6.8.0-79-generic
 92140  linux-modules-6.8.0-79-generic
 43188  containerd.io
 41022  kubelet
 28104  snapd
 21556  perl-modules-5.38
 18744  git
 12882  python3.12
 11930  linux-firmware
  9840  gcc-13
  ...
```

`linux-firmware` en una VM de nube es ~1 GB de blobs de firmware para hardware que no existe; `linux-modules-extra-*` igual. En bare metal, podá con cuidado — te vas a topar con una NIC que necesita exactamente el blob que borraste.

### 5.2 Evitar que los recommends vuelvan a inflar la imagen

```conf
# /etc/apt/apt.conf.d/99-minimal
APT::Install-Recommends "false";
APT::Install-Suggests   "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant   "false";
Acquire::Languages "none";
```

```conf
# /etc/dpkg/dpkg.cfg.d/01-nodoc  — no man pages, no docs, no locales
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/man/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*
```

### 5.3 Fijá las versiones que importan, y después dejá de derivar

```bash
$ sudo apt-mark hold kubelet kubeadm kubectl containerd.io
kubelet set on hold.
kubeadm set on hold.
kubectl set on hold.
containerd.io set on hold.

$ apt-mark showhold
containerd.io
kubeadm
kubectl
kubelet
```

Si mantenés `unattended-upgrades` en nodos mutables, restringilo al pocket de seguridad y prohibí los reinicios:

```conf
# /etc/apt/apt.conf.d/52-node-unattended
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "kubelet"; "kubeadm"; "kubectl"; "containerd.io"; "runc"; "linux-image-.*";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MinimalSteps "true";
```

Las actualizaciones de kernel y de runtime deben pasar por drain → reemplazo, nunca por una transacción `apt` sorpresa a las 06:00 en 300 nodos.

---

## 6. Disposición del sistema de archivos y opciones de montaje

Los montajes separados existen por dos razones: **aislamiento de capacidad** (una inundación de logs no debe llenar `/`) y **cumplimiento de `nodev,nosuid,noexec`**.

```
# /etc/fstab  — worker node reference layout
# <device>                                  <mount>          <fs>    <options>                                   <dump> <pass>
UUID=6a1a0e0e-6bd1-4b19-9f10-2c9f0e1f2b30   /                ext4    defaults,relatime                            0      1
UUID=8b2c1c14-b5b6-4a09-a2fd-4d8d2e3a11aa   /boot            ext4    defaults,nodev,nosuid,noexec,relatime        0      2
UUID=1f7d90a0-3f60-4f18-bb2d-91c1a2f4d012   /boot/efi        vfat    defaults,nodev,nosuid,noexec,umask=0077      0      2
UUID=9c33ab2d-2a51-4a7f-9a1c-7c2b8d5f5a41   /home            ext4    defaults,nodev,nosuid,relatime               0      2
UUID=b0f1e5c9-8f7c-4b76-9c3a-2f5d2a7b9c02   /var             ext4    defaults,relatime                            0      2
UUID=c7e2d1b8-1a44-4dbb-8e2e-6f0a1c4b3d55   /var/log         ext4    defaults,nodev,nosuid,noexec,relatime        0      2
UUID=d81a6c33-52ef-4a1e-9c98-51f0a2f5c7b6   /var/log/audit   ext4    defaults,nodev,nosuid,noexec,relatime        0      2
UUID=e4b0f2a7-77ad-4a4d-b0b6-9f0d3c1e7a88   /var/tmp         ext4    defaults,nodev,nosuid,noexec,relatime        0      2
tmpfs                                       /tmp             tmpfs   defaults,nodev,nosuid,noexec,size=2G,mode=1777 0    0
tmpfs                                       /dev/shm         tmpfs   defaults,nodev,nosuid,noexec,size=1G          0    0
```

> ### La trampa de `/var` — leelo dos veces
>
> **`/var` tiene que conservar `exec` y `suid`.** Los sistemas de archivos raíz de los contenedores son montajes `overlayfs` cuyos directorios lower/upper viven bajo `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/`. Los flags `noexec`/`nosuid` del montaje *subyacente* se propagan al overlay. Montá `/var` con `noexec` y **todos los contenedores del nodo fallan al arrancar**; montalo con `nosuid` y cualquier imagen que dependa de un binario setuid se rompe de maneras confusas.
>
> Lo mismo aplica a `/var/lib/kubelet` si lo separás (los drivers CSI colocan ejecutables debajo) y a `/run` (sockets de los shims de containerd y algunos helpers del runtime).
>
> Poné los flags restrictivos en `/tmp`, `/var/tmp`, `/var/log`, `/dev/shm`, `/home`, `/boot` — nunca en `/var` ni en `/var/lib/containerd`.

Verificá lo que está realmente en efecto (no lo que dice `fstab`):

```bash
$ findmnt -no TARGET,OPTIONS /tmp /var /var/log /dev/shm /var/lib/containerd
/tmp             rw,nosuid,nodev,noexec,relatime,size=2097152k,mode=755
/var             rw,relatime
/var/log         rw,nosuid,nodev,noexec,relatime
/dev/shm         rw,nosuid,nodev,noexec
/var/lib/containerd  rw,relatime            # inherits /var — correct
```

Comprobación de sanidad de que los contenedores siguen ejecutando después de cualquier cambio de montaje:

```bash
$ sudo ctr -n k8s.io run --rm docker.io/library/busybox:1.36 mounttest /bin/echo ok
ok
```

---

## 7. Reducción de la superficie del kernel

### 7.1 Lista negra de módulos — el cambio de mayor valor y mayor riesgo

La autocarga es el mecanismo: un proceso sin privilegios que llama a `socket(AF_TIPC, SOCK_STREAM, 0)` hace que el kernel ejecute `request_module("net-pf-30")` y cargue TIPC. La lista negra sola **no alcanza** — `blacklist` solo detiene la autocarga *basada en alias* para ese nombre en algunos caminos; el patrón confiable es `install <mod> /bin/false`.

```conf
# /etc/modprobe.d/99-cks-hardening.conf
# Rationale: none of these are used by the container runtime, the CNI, or the
# CSI drivers deployed in this cluster. Each has a history of memory-safety CVEs
# reachable from an unprivileged local process via module autoload.
# Verify against your CSI/CNI before rolling out — see the KEEP list below.

# --- legacy / rarely used filesystems ------------------------------------
install cramfs    /bin/false
install freevxfs  /bin/false
install jffs2     /bin/false
install hfs       /bin/false
install hfsplus   /bin/false
install udf       /bin/false
install gfs2      /bin/false
install ksmbd     /bin/false

# --- exotic network protocols (all have had remote/local root CVEs) ------
install dccp      /bin/false
install sctp      /bin/false
install rds       /bin/false
install tipc      /bin/false
install n-hdlc    /bin/false
install ax25      /bin/false
install netrom    /bin/false
install x25       /bin/false
install rose      /bin/false
install decnet    /bin/false
install econet    /bin/false
install af_802154 /bin/false
install ipx       /bin/false
install appletalk /bin/false
install psnap     /bin/false
install p8023     /bin/false
install p8022     /bin/false
install can       /bin/false
install atm       /bin/false

# --- physical interfaces that do not exist on a server -------------------
install usb-storage   /bin/false
install firewire-core /bin/false
install thunderbolt   /bin/false
install floppy        /bin/false
install bluetooth     /bin/false
install btusb         /bin/false
install uvcvideo      /bin/false
install vivid         /bin/false          # CVE-2019-18683, test driver, never needed
install joydev        /bin/false
install pcspkr        /bin/false

# --- keep as blacklist-only: needed by snapd/CSI on some fleets ----------
# squashfs: REQUIRED by snapd and by several CSI drivers that ship squashfs
#           images. Do NOT `install ... /bin/false` on Ubuntu with snaps.
# blacklist squashfs
```

**La lista de CONSERVAR — poner cualquiera de estos en lista negra rompe el clúster:**

| Módulo | Necesario para | Síntoma si se bloquea |
|---|---|---|
| `overlay` | snapshotter overlayfs de containerd | containerd cae a un fallback o falla: `skip plugin "io.containerd.snapshotter.v1.overlayfs"` y todos los pods quedan en `ContainerCreating` |
| `br_netfilter` | kube-proxy iptables/ipvs, Calico, Flannel | `sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory`; el tráfico de Service de pod a pod en el mismo nodo se descarta en silencio |
| `nf_conntrack`, `nf_nat`, `iptable_nat`, `iptable_filter`, `xt_*` | kube-proxy | `iptables-restore: line N failed`; NodePort/ClusterIP muertos |
| `ip_vs`, `ip_vs_rr`, `ip_vs_wrr`, `ip_vs_sh` | kube-proxy en modo IPVS | kube-proxy en CrashLoop: `can't use the IPVS proxier: IPVS proxier will not be used because the following required kernel modules are not loaded` |
| `vxlan` | Flannel VXLAN, Calico VXLAN, Cilium VXLAN | Tráfico de pods entre nodos muerto |
| `wireguard` | Cifrado de Cilium/Calico | El overlay cifrado no llega a levantar |
| `dm_mod`, `dm_thin_pool`, `nbd`, `rbd`, `iscsi_tcp`, `nfsv4` | Drivers CSI de bloque/archivo | El attach de volumen se cuelga, pod trabado en `ContainerCreating` |
| `configs`, `ebtables` | algunos plugins de CNI, kube-router | Varía |

Declará el conjunto requerido explícitamente para que la autocarga nunca esté en el camino crítico:

```conf
# /etc/modules-load.d/kubernetes.conf
overlay
br_netfilter
nf_conntrack
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
vxlan
```

Aplicar y verificar:

```bash
$ sudo systemctl restart systemd-modules-load.service
$ sudo depmod -a && sudo update-initramfs -u
update-initramfs: Generating /boot/initrd.img-6.8.0-79-generic

$ modprobe -n -v tipc
install /bin/false

$ sudo modprobe tipc; echo "exit=$?"
exit=1

$ lsmod | grep -E '^(overlay|br_netfilter|vxlan)'
overlay               212992  59
br_netfilter           32768  0
vxlan                 143360  0
```

### 7.2 Sellar por completo la carga de módulos (avanzado, condicionado)

```bash
$ sudo sysctl -w kernel.modules_disabled=1
kernel.modules_disabled = 1
```

Esto es una **puerta de un solo sentido hasta el reinicio**: nunca más se podrá cargar ningún módulo. Es el control anti-rootkit individual más fuerte disponible en un nodo mutable, y también la forma más rápida de romper un clúster.

- kube-proxy en modo `iptables` autocarga módulos `xt_*` la primera vez que aparece un nuevo tipo de match en una regla; si `modules_disabled=1` se fijó antes de que eso ocurriera, `iptables-restore` falla y los Services dejan de programarse.
- Los drivers CSI autocargan `iscsi_tcp`/`rbd`/`nfsv4` en el primer attach de volumen.
- Algunos CNIs cargan módulos al cambiar la configuración, no al arrancar.

Desplegalo solo en nodos cuyo conjunto de módulos esté completamente caracterizado, y solo *después* de que el runtime, el CNI y el CSI hayan convergido:

```ini
# /etc/systemd/system/seal-modules.service
[Unit]
Description=Seal kernel module loading after the node is Ready
# Order after everything that autoloads modules.
After=kubelet.service containerd.service systemd-modules-load.service
Requires=kubelet.service
ConditionPathExists=/etc/kubernetes/kubelet.conf

[Service]
Type=oneshot
RemainAfterExit=yes
# Give CNI/CSI DaemonSets time to land and load their modules.
ExecStartPre=/bin/sleep 300
ExecStartPre=/usr/local/sbin/verify-required-modules.sh
ExecStart=/sbin/sysctl -w kernel.modules_disabled=1

[Install]
WantedBy=multi-user.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-required-modules.sh
# Refuse to seal the kernel unless every module this node needs is already loaded.
set -euo pipefail

REQUIRED=(overlay br_netfilter nf_conntrack vxlan ip_tables iptable_nat iptable_filter)
missing=()

for m in "${REQUIRED[@]}"; do
    lsmod | awk '{print $1}' | grep -qx "${m//-/_}" || missing+=("$m")
done

if ((${#missing[@]})); then
    echo "refusing to seal module loading; missing: ${missing[*]}" >&2
    exit 1
fi
echo "all ${#REQUIRED[@]} required modules present; sealing"
```

> **Recomendación.** En flotas mutables, desplegá la lista negra de módulos (§7.1) pero dejá `modules_disabled=0`, y detectá cargas inesperadas de módulos con herramientas de seguridad en runtime (dominio 6). Reservá `modules_disabled=1` para imágenes inmutables donde controlás todo el conjunto de módulos. Talos y Bottlerocket te dan la garantía equivalente gratis.

### 7.3 Kernel lockdown y Secure Boot

```bash
$ cat /sys/kernel/security/lockdown
[none] integrity confidentiality

$ mokutil --sb-state
SecureBoot enabled
```

| Modo | Bloquea | Rompe |
|---|---|---|
| `none` | nada | nada |
| `integrity` | carga de módulos sin firmar, `/dev/mem`, `kexec` de imágenes sin firmar, acceso directo a PCI/puertos de E/S, hibernación, actualización de firmware sin firmar | módulos fuera del árbol sin firmar (NVIDIA/DKMS salvo que los firmes), herramientas de reinicio rápido basadas en `kexec` |
| `confidentiality` | todo lo de `integrity` **más** la lectura de memoria del kernel: `kprobes`, `bpf_probe_read_kernel`, muestras de `perf` del kernel, `/proc/kcore` | **herramientas de observabilidad y seguridad basadas en eBPF** — las funciones de Cilium que leen memoria del kernel, la sonda modern-eBPF de Falco, Pixie, `bpftrace`, `perf top` |

Habilitar mediante la línea de comandos del kernel:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="lockdown=integrity module.sig_enforce=1 init_on_alloc=1 init_on_free=1 slab_nomerge pti=on vsyscall=none randomize_kstack_offset=on"
```

```bash
$ sudo update-grub && sudo reboot
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
done

# after reboot
$ cat /sys/kernel/security/lockdown
none [integrity] confidentiality
```

> **Compromiso que hay que declarar explícitamente en tu documento de diseño:** `lockdown=confidentiality` y "corremos Falco/Cilium/Tetragon para detección en runtime" (dominio 6) son en gran medida mutuamente excluyentes. En la práctica, la mayoría de las flotas eligen `integrity` + Secure Boot + módulos firmados, y conservan la detección basada en eBPF. Elegir `confidentiality` significa aceptar que perdés el sensor que te diría que ocurrió un escape.

### 7.4 Endurecimiento de `sysctl`

```conf
# /etc/sysctl.d/99-cks-hardening.conf
# ---------------------------------------------------------------------------
# Kernel information leaks and privesc primitives
# ---------------------------------------------------------------------------
kernel.dmesg_restrict           = 1     # non-root cannot read the ring buffer (KASLR leaks)
kernel.kptr_restrict            = 2     # hide kernel pointers from /proc even for root
kernel.perf_event_paranoid      = 3     # no unprivileged perf; set to 2 if you need profiling
kernel.kexec_load_disabled      = 1     # no live kernel replacement (one-way until reboot)
kernel.sysrq                    = 0     # no magic SysRq from a compromised console
kernel.unprivileged_bpf_disabled = 1    # only CAP_BPF/root may load BPF; Cilium is root, so OK
net.core.bpf_jit_harden         = 2     # blind JIT constants (small perf cost on high-pps nodes)
kernel.yama.ptrace_scope        = 1     # only parents may ptrace; 2 = admin-only, 3 = never
kernel.randomize_va_space       = 2
fs.suid_dumpable                = 0
kernel.core_pattern             = |/bin/false   # see note below — escape primitive
kernel.panic_on_oops            = 1
kernel.panic                    = 10

# ---------------------------------------------------------------------------
# Filesystem link/FIFO hardening (classic /tmp race exploits)
# ---------------------------------------------------------------------------
fs.protected_hardlinks          = 1
fs.protected_symlinks           = 1
fs.protected_fifos              = 2
fs.protected_regular            = 2

# ---------------------------------------------------------------------------
# Network — DO NOT disable ip_forward, Kubernetes requires it
# ---------------------------------------------------------------------------
net.ipv4.ip_forward                     = 1
net.bridge.bridge-nf-call-iptables      = 1
net.bridge.bridge-nf-call-ip6tables     = 1
net.ipv4.conf.all.accept_redirects      = 0
net.ipv4.conf.default.accept_redirects  = 0
net.ipv4.conf.all.secure_redirects      = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.default.send_redirects    = 0
net.ipv4.conf.all.accept_source_route   = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians          = 1
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                 = 1
net.ipv6.conf.all.accept_redirects      = 0
net.ipv6.conf.all.accept_ra             = 0
net.ipv6.conf.all.accept_source_route   = 0

# ---------------------------------------------------------------------------
# Values the kubelet expects when --protect-kernel-defaults=true.
# Omitting these makes the kubelet refuse to start. See §11.2.
# ---------------------------------------------------------------------------
vm.overcommit_memory     = 1
vm.panic_on_oom          = 0
kernel.keys.root_maxbytes = 25000000
kernel.keys.root_maxkeys  = 1000000

# ---------------------------------------------------------------------------
# Capacity — a busy node exhausts these long before it exhausts CPU
# ---------------------------------------------------------------------------
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 524288
fs.file-max                   = 2097152
net.netfilter.nf_conntrack_max = 1048576
```

```bash
$ sudo sysctl --system 2>&1 | tail -8
* Applying /etc/sysctl.d/99-cks-hardening.conf ...
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
...
* Applying /etc/sysctl.conf ...

$ sysctl kernel.dmesg_restrict kernel.kptr_restrict net.ipv4.ip_forward
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
net.ipv4.ip_forward = 1
```

Tres compromisos que tenés que decidir conscientemente, no copiar:

| Ajuste | Valor agresivo | Costo |
|---|---|---|
| `kernel.yama.ptrace_scope` | `2` o `3` | `3` rompe `gdb`, `strace`, `delve` y cualquier sidecar de depuración — incluidos los contenedores efímeros de depuración apuntados a un proceso. `1` es el valor por defecto sensato. |
| `net.ipv4.conf.all.rp_filter` | `1` (estricto) | **Rompe varios datapaths de CNI** (Cilium y algunos modos de Calico necesitan `0` o el laxo `2` en interfaces específicas). No pongas `1` globalmente sin probar el egress de pods y los caminos de retorno de Service. |
| `user.max_user_namespaces` | `0` | Históricamente recomendado (los user namespaces son una superficie grande de escalada de privilegios). **Pero** los user namespaces a nivel de pod de Kubernetes (`spec.hostUsers: false`) requieren user namespaces sin privilegios, y esa funcionalidad es una de las mitigaciones de escape de contenedor más fuertes disponibles. Mantenelos habilitados (p. ej. `16384`) y usalos. |

> **`kernel.core_pattern` es una primitiva de escape de contenedor.** Es un ajuste *global* del kernel, no está en namespaces. Un proceso con `CAP_SYS_ADMIN` dentro de un contenedor que pueda escribir `/proc/sys/kernel/core_pattern` lo fija a `|/path/to/payload`, y después provoca deliberadamente un segfault — y el kernel ejecuta el payload **en el host, como root, fuera de todos los namespaces**. Dos defensas: nunca otorgar `CAP_SYS_ADMIN` con un `/proc/sys` escribible (dominio 4), y fijar acá un patrón que no sea una tubería para que una escritura accidental del lado del host sea inerte.

---

## 8. Exposición de red

### 8.1 Inventario de puertos

| Puerto | Proto | Componente | Auth | Quién se conecta legítimamente |
|---|---|---|---|---|
| 6443 | TCP | kube-apiserver | mTLS/OIDC/token | todo |
| 2379–2380 | TCP | etcd cliente/peer | mTLS | apiserver, peers de etcd |
| 10250 | TCP | API del kubelet (HTTPS) | mTLS + webhook authz | apiserver (`exec`, `logs`, `portforward`), metrics-server |
| **10255** | TCP | kubelet **solo lectura** | **NINGUNA** | nada — **deshabilitar** |
| 10248 | TCP | healthz del kubelet | ninguna | solo localhost (bind `127.0.0.1`) |
| 10256 | TCP | healthz de kube-proxy | ninguna | health checks del LB de nube |
| 10249 | TCP | métricas de kube-proxy | ninguna | localhost / Prometheus |
| 10257 | TCP | kube-controller-manager | mTLS | localhost (kubeadm hace bind en `127.0.0.1`) |
| 10259 | TCP | kube-scheduler | mTLS | localhost (kubeadm hace bind en `127.0.0.1`) |
| 30000–32767 | TCP/UDP | rango NodePort | definido por el workload | LB / clientes |
| 8472 | UDP | VXLAN de Flannel/Cilium | ninguna (cifrar por separado) | otros nodos |
| 4789 | UDP | VXLAN de Calico | ninguna | otros nodos |
| 179 | TCP | BGP de Calico/kube-router | MD5 opcional | otros nodos / ToR |
| 51820/51871 | UDP | WireGuard (Calico/Cilium) | cripto | otros nodos |
| 9153 | TCP | métricas de CoreDNS | ninguna | Prometheus |

### 8.2 Firewall de host con nftables

> ### La catástrofe de `flush ruleset`
>
> En las distribuciones modernas `iptables` es `iptables-nft`: las reglas de kube-proxy **viven en el ruleset de nftables** (tablas `ip filter`, `ip nat`, `ip mangle`), y kube-proxy en modo proxy `nftables` usa `ip kube-proxy` / `ip6 kube-proxy`. Cilium y Calico también agregan sus propias tablas.
>
> Un script de firewall que empieza con `flush ruleset` — que es lo que muestra casi cualquier tutorial de nftables — **borra todas las reglas de kube-proxy y del CNI**. Los Services dejan de funcionar al instante; kube-proxy resincroniza en su período (por defecto 30 s para `iptablesSyncPeriod`), así que obtenés una caída intermitente, que se auto-repara, enloquecedora, y que parece un problema de red. El datapath BPF de Cilium no resincroniza desde netfilter en absoluto, así que partes de él no vuelven hasta que el agente se reinicia.
>
> Usá el patrón idempotente crear-luego-borrar-luego-definir de abajo. Nunca hagas `flush ruleset` en un nodo de Kubernetes.

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf — host firewall for a Kubernetes worker node.
#
# NOTE: no `flush ruleset`. We only ever touch our own table.
# The two lines below are the idempotent pattern: `table` creates it if absent,
# `delete table` then removes it cleanly, and the definition recreates it.

table inet k8s_host
delete table inet k8s_host

table inet k8s_host {

    # ---- inventory -------------------------------------------------------
    set nodes_v4 {
        type ipv4_addr
        flags interval
        comment "every node in the cluster (control plane + workers)"
        elements = { 10.20.0.0/22 }
    }

    set pods_v4 {
        type ipv4_addr
        flags interval
        comment "cluster podCIDR"
        elements = { 10.244.0.0/16 }
    }

    set admin_v4 {
        type ipv4_addr
        flags interval
        comment "bastion / jump hosts only — never 0.0.0.0/0"
        elements = { 10.20.250.10/32, 10.20.250.11/32 }
    }

    set lb_v4 {
        type ipv4_addr
        flags interval
        comment "load balancer / health-check sources for NodePort"
        elements = { 10.20.240.0/24 }
    }

    set overlay_ifaces {
        type ifname
        elements = { "cni0", "flannel.1", "cilium_host", "cilium_net", "cilium_vxlan" }
    }

    # ---- INPUT -----------------------------------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        ct state vmap { established : accept, related : accept, invalid : drop }

        iif "lo" accept comment "loopback: kubelet healthz, kube-proxy metrics, CM/scheduler"

        # Pod and overlay traffic terminating on the host (kube-proxy hairpin,
        # hostNetwork services, CNI health checks).
        iifname @overlay_ifaces accept
        iifname "lxc*" accept comment "Cilium veth host side"
        iifname "cali*" accept comment "Calico veth host side"
        ip saddr @pods_v4 accept

        # ICMP: keep PMTU discovery working or you will chase phantom TCP hangs.
        ip  protocol icmp   icmp  type { destination-unreachable, time-exceeded, parameter-problem } accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
        icmp type echo-request limit rate 10/second accept

        # --- administration ---
        ip saddr @admin_v4 tcp dport 22 accept comment "SSH from bastions only"

        # --- Kubernetes control-plane-to-node ---
        ip saddr @nodes_v4 tcp dport 10250 accept comment "kubelet API: exec/logs/metrics"

        # --- CNI (adjust to the CNI actually deployed) ---
        ip saddr @nodes_v4 udp dport 8472  accept comment "VXLAN (Flannel/Cilium)"
        ip saddr @nodes_v4 udp dport 4789  accept comment "VXLAN (Calico)"
        ip saddr @nodes_v4 tcp dport 179   accept comment "BGP (Calico/kube-router)"
        ip saddr @nodes_v4 udp dport 51871 accept comment "WireGuard (Cilium)"
        ip saddr @nodes_v4 tcp dport 4240  accept comment "Cilium health checks"

        # --- load balancer ---
        ip saddr @lb_v4 tcp dport 10256          accept comment "kube-proxy healthz"
        ip saddr @lb_v4 tcp dport 30000-32767    accept comment "NodePort"
        ip saddr @lb_v4 udp dport 30000-32767    accept

        # Everything else is dropped by policy. Log a sample for forensics.
        limit rate 5/minute burst 10 packets \
            log prefix "nft-input-drop " level warn flags all
        counter comment "input drops"
    }

    # ---- FORWARD ---------------------------------------------------------
    # Deliberately policy accept: kube-proxy and the CNI program pod-to-pod and
    # Service forwarding in the `ip filter`/`ip kube-proxy` tables. A `drop`
    # policy here blackholes all pod traffic even though those rules accept it,
    # because a drop in ANY chain at this hook is final.
    chain forward {
        type filter hook forward priority filter; policy accept;
        counter comment "forward — governed by kube-proxy/CNI, not here"
    }

    # ---- OUTPUT ----------------------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;

        # Egress filtering on a node breaks image pulls, IMDS, DNS and the
        # apiserver connection in non-obvious ways. Do it at the cloud SG /
        # network layer, not here. Kept as an explicit design decision.
        counter comment "output"
    }
}
```

Desplegalo de la forma que no te deja afuera:

```bash
# 1. Syntax check without applying
$ sudo nft -c -f /etc/nftables.conf && echo "syntax ok"
syntax ok

# 2. Arm a rollback BEFORE applying — 5 minutes to prove you still have access
$ sudo systemd-run --on-active=5min --unit=fw-rollback \
    /usr/sbin/nft delete table inet k8s_host
Running timer as unit: fw-rollback.timer
Will run service as unit: fw-rollback.service

# 3. Apply
$ sudo nft -f /etc/nftables.conf

# 4. Prove the cluster still works from a SECOND terminal, then cancel rollback
$ kubectl get --raw='/readyz'
ok
$ kubectl -n kube-system get pods --field-selector spec.nodeName=worker-03 -o name | head -3
pod/cilium-9x4kq
pod/kube-proxy-7m2vd
pod/node-exporter-lp8rn
$ sudo systemctl stop fw-rollback.timer

# 5. Persist
$ sudo systemctl enable --now nftables.service
Created symlink /etc/systemd/system/multi-user.target.wants/nftables.service → /usr/lib/systemd/system/nftables.service.
```

Verificá las reglas y — algo crítico — que las tablas de kube-proxy hayan sobrevivido:

```bash
$ sudo nft list tables
table ip nat
table ip filter
table ip mangle
table ip kube-proxy
table ip6 kube-proxy
table inet k8s_host
table ip cilium_post_nat_node        # (present only with Cilium's netfilter integration)

$ sudo nft list chain inet k8s_host input | head -12
table inet k8s_host {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state vmap { established : accept, related : accept, invalid : drop }
		iif "lo" accept comment "loopback: kubelet healthz, kube-proxy metrics, CM/scheduler"
		iifname @overlay_ifaces accept
		iifname "lxc*" accept comment "Cilium veth host side"
		ip saddr @pods_v4 accept
		...

$ sudo nft list counters table inet k8s_host
table inet k8s_host {
	counter  {
		packets 143 bytes 8964
		comment "input drops"
	}
}
```

### 8.3 Defensa en profundidad: el firewall en el que deberías confiar más

Los firewalls de host en nodos de Kubernetes son frágiles — cada actualización del CNI puede cambiar los nombres de las interfaces, y una regla mala provoca un incidente en todo el clúster. En entornos de nube, el security group / NSG / política de firewall se aplica *fuera* del host comprometido y no puede ser vaciado por un atacante con root en el nodo. Preferí:

1. **SG de nube / ACL física** como límite principal (el atacante en el nodo no puede editarla).
2. **nftables de host** como segunda capa, mantenida deliberadamente simple.
3. **NetworkPolicy / CiliumNetworkPolicy** para la segmentación a nivel de pod (tema 5.3).

Bloquear el servicio de metadatos de la instancia desde los pods pertenece a 5.3, pero vale nombrarlo acá porque es el camino de escalada adyacente al nodo más común:

```bash
# Block pod CIDR → IMDS at the host, so a compromised pod cannot steal the node's IAM role
$ sudo nft add table inet imds_guard
$ sudo nft add chain inet imds_guard fwd '{ type filter hook forward priority -10 ; }'
$ sudo nft add rule inet imds_guard fwd ip saddr 10.244.0.0/16 ip daddr 169.254.169.254 \
    counter log prefix "imds-block " drop
```

---

## 9. Usuarios, SUID y escalada local de privilegios

### 9.1 Cuentas

```bash
# Interactive accounts (UID >= 1000 with a real shell)
$ awk -F: '($3>=1000)&&($3!=65534)&&($7!~/(nologin|false|sync)$/){print $1" uid="$3" shell="$7}' /etc/passwd
ubuntu uid=1000 shell=/bin/bash

# Accounts with an empty password field — must be zero
$ sudo awk -F: '($2==""){print "EMPTY PASSWORD: "$1}' /etc/shadow

# Non-root UID 0 accounts — must be exactly one line
$ awk -F: '($3==0){print $1}' /etc/passwd
root

# Lock the root password entirely; access is via SSH key to a sudo account,
# or via cloud console. `!` in field 2 = locked.
$ sudo passwd -l root
passwd: password expiry information changed.
$ sudo awk -F: '$1=="root"{print $2}' /etc/shadow
!*
```

En una flota inmutable, el número correcto de cuentas interactivas es **cero**; los nodos se reemplazan, no se arreglan. En una flota mutable, exactamente una cuenta de emergencia con una clave SSH guardada en un gestor de secretos y auditada al usarse.

### 9.2 Reducción de SUID/SGID

| Binario | Propósito | ¿El nodo lo necesita? | Acción |
|---|---|---|---|
| `pkexec` | escalada de privilegios de polkit | No | **Purgar** (`policykit-1`) — CVE-2021-4034 |
| `at` | trabajos de una sola vez | No | Purgar |
| `chfn`, `chsh`, `newgrp`, `gpasswd`, `expiry`, `chage` | metadatos de cuenta para usuarios interactivos | No | `chmod u-s,g-s` o purgar |
| `wall`, `write` | mensajería de terminal | No | `chmod g-s` |
| `mount`, `umount` | montaje sin privilegios | No (el kubelet es root) | `chmod u-s` — **verificá que no haya CSI basado en fuse en el nodo** |
| `ping` | ICMP | Conveniente | Reemplazar SUID por `cap_net_raw`: `setcap cap_net_raw+ep /usr/bin/ping` |
| `su` | cambiar de usuario | Emergencia | Mantener, restringir al grupo `wheel`/`sudo` vía PAM |
| `sudo` | delegación de privilegios | Sí, si hay humanos que inician sesión | Mantener, restringir (§9.4) |
| `passwd` | cambio de contraseña | Solo con cuentas locales | Mantener si existe alguna contraseña local |
| `ssh-keysign` | autenticación SSH basada en host | No | `chmod u-s` |
| `fusermount3` | FUSE | Solo con CSI FUSE (p. ej. `s3fs`, `gcsfuse`, `rclone`) | Verificar antes de eliminarlo |

```bash
$ sudo chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp /usr/bin/umount /usr/bin/mount /usr/lib/openssh/ssh-keysign
$ sudo chmod g-s /usr/bin/wall /usr/bin/write /usr/bin/expiry /usr/bin/chage
$ sudo setcap cap_net_raw+ep /usr/bin/ping && sudo chmod u-s /usr/bin/ping

$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null | sort
2755 /usr/bin/crontab
4755 /usr/bin/passwd
4755 /usr/bin/su
4755 /usr/bin/sudo
4755 /usr/bin/fusermount3
4755 /usr/lib/dbus-1.0/dbus-daemon-launch-helper

$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l
6
```

De 26 a 6. Persistí esta lista como archivo de línea base y alertá ante cualquier diferencia — un binario SUID nuevo apareciendo en un nodo es un indicador de compromiso de alta señal.

```bash
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null \
    | sort | sudo tee /var/lib/node-baseline/suid.txt >/dev/null
```

### 9.3 SSH

```conf
# /etc/ssh/sshd_config.d/10-hardening.conf   (drop-in wins over the main file)
Port 22
AddressFamily inet
ListenAddress 10.20.1.13

# --- authentication -------------------------------------------------------
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30

# --- who -----------------------------------------------------------------
AllowGroups node-admins

# --- reduce feature surface ----------------------------------------------
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
GatewayPorts no
Compression no

# --- session hygiene ------------------------------------------------------
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
LogLevel VERBOSE
Banner /etc/issue.net

# --- crypto ---------------------------------------------------------------
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512
```

```bash
$ sudo sshd -t && echo "config ok"
config ok
$ sudo systemctl reload ssh
$ sudo ss -tlpn 'sport = :22'
State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
LISTEN 0      128       10.20.1.13:22          0.0.0.0:*     users:(("sshd",pid=1102,fd=3))
```

Fijate en `AllowTcpForwarding no`: sin eso, un atacante con capacidad de SSH tuneliza directo hacia `127.0.0.1:10248`, `127.0.0.1:10257` y el socket del container runtime, evitando el firewall de host por completo.

### 9.4 `sudo`

```conf
# /etc/sudoers.d/10-node-admins   (install with visudo -c -f, mode 0440)
Defaults    use_pty
Defaults    logfile="/var/log/sudo.log"
Defaults    log_input, log_output
Defaults    iolog_dir="/var/log/sudo-io/%{user}"
Defaults    timestamp_timeout=5
Defaults    passwd_timeout=1
Defaults    requiretty
Defaults    !visiblepw
Defaults    env_reset
Defaults    secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

%node-admins ALL=(ALL:ALL) ALL
```

```bash
$ sudo visudo -c -f /etc/sudoers.d/10-node-admins
/etc/sudoers.d/10-node-admins: parsed OK

# NOPASSWD ALL is equivalent to handing out root; find it before an auditor does
$ sudo grep -rE 'NOPASSWD|!authenticate' /etc/sudoers /etc/sudoers.d/ ; echo "exit=$?"
exit=1
```

---

## 10. Superficie del host específica de Kubernetes

### 10.1 Permisos de archivos (los chequeos de la sección 4 de CIS, y por qué)

| Ruta | Modo | Propietario | Por qué |
|---|---|---|---|
| `/etc/kubernetes/manifests/*.yaml` | `600` | `root:root` | Escritura = pod privilegiado arbitrario, sin API server, sin admission control |
| `/etc/kubernetes/pki/*.key` | `600` | `root:root` | Claves privadas de la CA del clúster — leerlas = acuñar cualquier identidad |
| `/etc/kubernetes/pki/*.crt` | `644` | `root:root` | Público |
| `/etc/kubernetes/pki/etcd` (dir) | `700` | `root:root` | CA de etcd |
| `/etc/kubernetes/admin.conf` | `600` | `root:root` | `cluster-admin`. No debería existir en workers en absoluto |
| `/etc/kubernetes/kubelet.conf` | `600` | `root:root` | Identidad del nodo |
| `/var/lib/kubelet/config.yaml` | `600` | `root:root` | Escritura = deshabilitar la autenticación del kubelet |
| `/var/lib/kubelet/pki` (dir) | `700` | `root:root` | Certificado cliente del nodo |
| `/var/lib/etcd` | `700` | `etcd`/`root` | Todo el estado del clúster |
| `/etc/containerd/config.toml` | `600` | `root:root` | Escritura = cambiar el runtime, deshabilitar el seccomp por defecto |
| `/run/containerd/containerd.sock` | `660` | `root:root` | Equivalente directo a root |
| `/etc/systemd/system/kubelet.service.d/*.conf` | `600` | `root:root` | Flags del kubelet |
| `/opt/cni/bin/*` | `755` | `root:root` | Ejecutado como root por el kubelet en cada sandbox de pod |

```bash
$ sudo stat -c '%a %U:%G %n' \
    /etc/kubernetes/manifests/*.yaml \
    /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
    /var/lib/kubelet/config.yaml /etc/containerd/config.toml \
    /var/lib/etcd /var/lib/kubelet/pki 2>/dev/null
644 root:root /etc/kubernetes/manifests/etcd.yaml
644 root:root /etc/kubernetes/manifests/kube-apiserver.yaml
644 root:root /etc/kubernetes/manifests/kube-controller-manager.yaml
644 root:root /etc/kubernetes/manifests/kube-scheduler.yaml
600 root:root /etc/kubernetes/admin.conf
600 root:root /etc/kubernetes/kubelet.conf
600 root:root /var/lib/kubelet/config.yaml
664 root:root /etc/containerd/config.toml
700 root:root /var/lib/etcd
700 root:root /var/lib/kubelet/pki

$ sudo chmod 600 /etc/kubernetes/manifests/*.yaml /etc/containerd/config.toml
$ sudo chown -R root:root /etc/kubernetes /var/lib/kubelet
$ sudo find /etc/kubernetes/pki -name '*.key' -exec chmod 600 {} +
$ sudo find /etc/kubernetes/pki -name '*.crt' -exec chmod 644 {} +
$ sudo chmod 700 /etc/kubernetes/pki/etcd

$ sudo stat -c '%a %U:%G %n' /etc/kubernetes/manifests/*.yaml
600 root:root /etc/kubernetes/manifests/etcd.yaml
600 root:root /etc/kubernetes/manifests/kube-apiserver.yaml
600 root:root /etc/kubernetes/manifests/kube-controller-manager.yaml
600 root:root /etc/kubernetes/manifests/kube-scheduler.yaml
```

### 10.2 `KubeletConfiguration` endurecida

```yaml
# /var/lib/kubelet/config.yaml   (mode 0600, root:root)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# --- identity / transport -------------------------------------------------
tlsCertFile: /var/lib/kubelet/pki/kubelet.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet.key
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
tlsMinVersion: VersionTLS12

# --- authentication: no anonymous, no unauthenticated read-only port ------
authentication:
  anonymous:
    enabled: false                 # CIS 4.2.1
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # CIS 4.2.3
authorization:
  mode: Webhook                    # CIS 4.2.2 — never AlwaysAllow
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

readOnlyPort: 0                    # CIS 4.2.4 — kills the unauthenticated :10255
healthzBindAddress: 127.0.0.1
healthzPort: 10248

# --- certificate lifecycle ------------------------------------------------
rotateCertificates: true                    # CIS 4.2.11
serverTLSBootstrap: true                    # CIS 4.2.12 — requires CSR approval

# --- host hardening -------------------------------------------------------
protectKernelDefaults: true                 # kubelet refuses to start on sysctl drift
makeIPTablesUtilChains: true                # CIS 4.2.6
seccompDefault: true                        # RuntimeDefault seccomp for every pod
streamingConnectionIdleTimeout: 5m0s        # CIS 4.2.5 — never 0
eventRecordQPS: 5
podPidsLimit: 4096                          # fork-bomb containment
failSwapOn: true

# --- what the kubelet is allowed to run -----------------------------------
staticPodPath: ""                           # workers: no static pods at all
allowedUnsafeSysctls: []                    # do not widen without a written case
featureGates: {}

# --- resource protection --------------------------------------------------
cgroupDriver: systemd
enforceNodeAllocatable: ["pods", "kube-reserved", "system-reserved"]
kubeReserved:
  cpu: "200m"
  memory: "512Mi"
  ephemeral-storage: "2Gi"
systemReserved:
  cpu: "200m"
  memory: "512Mi"
  ephemeral-storage: "2Gi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"

# --- cluster wiring -------------------------------------------------------
clusterDomain: cluster.local
clusterDNS:
  - 10.96.0.10
runtimeRequestTimeout: 2m0s
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
```

Fijate en `staticPodPath: ""` en los workers. Un worker con directorio de static pods es un worker donde el acceso de escritura al sistema de archivos equivale a la ejecución de un pod privilegiado sin auditar.

### 10.3 Superficie de containerd

```toml
# /etc/containerd/config.toml   (mode 0600, root:root) — containerd 2.x
version = 3

[plugins.'io.containerd.cri.v1.runtime']
  # Do not let a pod ask for a host-level userns/PID share it should not have.
  enable_selinux = false
  disable_apparmor = false
  restrict_oom_score_adj = true
  # Never enable: allows arbitrary host paths as volumes without validation.
  # device_ownership_from_security_context = false

  [plugins.'io.containerd.cri.v1.runtime'.containerd]
    default_runtime_name = 'runc'
    # Uncomment once gVisor/Kata is deployed for untrusted tenants (domain 4).
    # default_runtime_name = 'runsc'

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
      runtime_type = 'io.containerd.runc.v2'
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
        SystemdCgroup = true

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'

[plugins.'io.containerd.cri.v1.images']
  # Force credential checks on every pull; prevents a pod on this node from
  # using an image another tenant already pulled without proving entitlement.
  [plugins.'io.containerd.cri.v1.images'.pinned_images]
    sandbox = 'registry.k8s.io/pause:3.10'
```

Eliminá los restos de Docker si el nodo alguna vez migró desde dockershim:

```bash
$ sudo apt-get purge -y docker-ce docker-ce-cli docker.io containerd 2>/dev/null
$ ls -l /var/run/docker.sock 2>&1
ls: cannot access '/var/run/docker.sock': No such file or directory
$ command -v docker || echo "docker CLI absent — good"
docker CLI absent — good
```

Un grupo `docker` en un nodo es un grupo equivalente a root. `getent group docker` no debe devolver nada.

### 10.4 Swap

```bash
$ swapon --show
$ free -h | awk '/Swap/{print}'
Swap:            0B          0B          0B

$ sudo swapoff -a
$ sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
$ sudo systemctl mask swap.target
```

El soporte de swap en el kubelet lleva varias versiones en beta con el comportamiento `LimitedSwap`, y `failSwapOn: true` sigue siendo el valor por defecto del kubelet. Desde el punto de vista del endurecimiento el cálculo no cambia: **el swap escribe memoria en disco**, y la memoria de los pods contiene Secrets, claves privadas TLS y tokens de SA. Si tenés que correr con swap por razones de sobrecompromiso de memoria, ponelo en un dispositivo cifrado:

```bash
$ sudo cryptsetup open --type plain --key-file /dev/urandom /dev/nvme0n1p3 cryptswap
$ sudo mkswap /dev/mapper/cryptswap && sudo swapon /dev/mapper/cryptswap
```

---

## 11. Arranque completo de un nodo: manifiestos de infraestructura

### 11.1 cloud-init para un nodo Ubuntu minimizado

```yaml
#cloud-config
# user-data for a hardened Kubernetes worker (Ubuntu 24.04).
# Everything here is also expressible in the image build; keeping it in
# cloud-init makes the intent reviewable in the Terraform/Pulumi diff.

hostname: worker-03
fqdn: worker-03.prod.internal
manage_etc_hosts: true

ssh_pwauth: false
disable_root: true

users:
  - name: nodeadmin
    groups: [node-admins]
    shell: /bin/bash
    sudo: "ALL=(ALL:ALL) ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0Q0m9k9m8nJk0f1c2R3t4Y5u6I7o8P9a0S1d2F3g4H bastion@prod

groups:
  - node-admins

write_files:
  - path: /etc/modules-load.d/kubernetes.conf
    permissions: "0644"
    content: |
      overlay
      br_netfilter
      nf_conntrack
      vxlan

  - path: /etc/modprobe.d/99-cks-hardening.conf
    permissions: "0644"
    content: |
      install cramfs /bin/false
      install freevxfs /bin/false
      install jffs2 /bin/false
      install hfs /bin/false
      install hfsplus /bin/false
      install udf /bin/false
      install dccp /bin/false
      install sctp /bin/false
      install rds /bin/false
      install tipc /bin/false
      install n-hdlc /bin/false
      install ax25 /bin/false
      install netrom /bin/false
      install x25 /bin/false
      install rose /bin/false
      install decnet /bin/false
      install econet /bin/false
      install af_802154 /bin/false
      install ipx /bin/false
      install appletalk /bin/false
      install psnap /bin/false
      install p8023 /bin/false
      install p8022 /bin/false
      install can /bin/false
      install atm /bin/false
      install usb-storage /bin/false
      install firewire-core /bin/false
      install thunderbolt /bin/false
      install floppy /bin/false
      install bluetooth /bin/false
      install uvcvideo /bin/false
      install vivid /bin/false
      install joydev /bin/false

  - path: /etc/sysctl.d/99-cks-hardening.conf
    permissions: "0644"
    content: |
      kernel.dmesg_restrict = 1
      kernel.kptr_restrict = 2
      kernel.perf_event_paranoid = 3
      kernel.kexec_load_disabled = 1
      kernel.sysrq = 0
      kernel.unprivileged_bpf_disabled = 1
      kernel.yama.ptrace_scope = 1
      kernel.randomize_va_space = 2
      kernel.core_pattern = |/bin/false
      kernel.panic_on_oops = 1
      kernel.panic = 10
      net.core.bpf_jit_harden = 2
      fs.suid_dumpable = 0
      fs.protected_hardlinks = 1
      fs.protected_symlinks = 1
      fs.protected_fifos = 2
      fs.protected_regular = 2
      net.ipv4.ip_forward = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.conf.all.send_redirects = 0
      net.ipv4.conf.all.accept_source_route = 0
      net.ipv4.conf.all.log_martians = 1
      net.ipv4.tcp_syncookies = 1
      net.ipv6.conf.all.accept_redirects = 0
      net.ipv6.conf.all.accept_ra = 0
      vm.overcommit_memory = 1
      vm.panic_on_oom = 0
      kernel.keys.root_maxbytes = 25000000
      kernel.keys.root_maxkeys = 1000000
      fs.inotify.max_user_instances = 8192
      fs.inotify.max_user_watches = 524288
      net.netfilter.nf_conntrack_max = 1048576

  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0600"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AuthenticationMethods publickey
      AllowGroups node-admins
      AllowTcpForwarding no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTunnel no
      MaxAuthTries 3
      LoginGraceTime 30
      ClientAliveInterval 300
      ClientAliveCountMax 2
      LogLevel VERBOSE

  - path: /etc/apt/apt.conf.d/99-minimal
    permissions: "0644"
    content: |
      APT::Install-Recommends "false";
      APT::Install-Suggests "false";
      Acquire::Languages "none";

  - path: /etc/issue.net
    permissions: "0644"
    content: |
      Authorized access only. All sessions are logged and monitored.

bootcmd:
  - [ cloud-init-per, once, swapoff, swapoff, -a ]

runcmd:
  # --- service surface ---
  - systemctl mask --now snapd.service snapd.socket snapd.seeded.service
  - systemctl mask --now ModemManager.service udisks2.service avahi-daemon.service
      avahi-daemon.socket bluetooth.service atd.service whoopsie.service apport.service
      rpcbind.service rpcbind.socket
  - DEBIAN_FRONTEND=noninteractive apt-get purge -y --autoremove
      policykit-1 snapd modemmanager udisks2 avahi-daemon bluez apport whoopsie
      telnet ftp rsh-client talk finger gcc g++ make binutils
  # --- SUID surface ---
  - chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp /usr/bin/mount /usr/bin/umount /usr/lib/openssh/ssh-keysign
  - chmod g-s /usr/bin/wall /usr/bin/write /usr/bin/chage /usr/bin/expiry
  - setcap cap_net_raw+ep /usr/bin/ping && chmod u-s /usr/bin/ping
  # --- swap ---
  - sed -i '/\sswap\s/s/^/#/' /etc/fstab
  - systemctl mask swap.target
  # --- apply ---
  - systemctl restart systemd-modules-load.service
  - sysctl --system
  - depmod -a && update-initramfs -u
  - passwd -l root
  - sshd -t && systemctl reload ssh
  # --- baseline snapshot for drift detection ---
  - mkdir -p /var/lib/node-baseline
  - sh -c "find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null | sort > /var/lib/node-baseline/suid.txt"
  - sh -c "ss -tulpnH | awk '{print \$1, \$5}' | sort > /var/lib/node-baseline/listen.txt"
  - sh -c "dpkg-query -f '\${binary:Package}\n' -W | sort > /var/lib/node-baseline/packages.txt"

package_update: true
package_upgrade: true

power_state:
  mode: reboot
  message: "rebooting to apply kernel cmdline and module changes"
  condition: true
```

### 11.2 Flatcar (Butane → Ignition)

```yaml
variant: flatcar
version: 1.1.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0Q0m9k9m8nJk0f1c2R3t4Y5u6I7o8P9a0S1d2F3g4H bastion@prod

storage:
  files:
    - path: /etc/sysctl.d/99-cks-hardening.conf
      mode: 0644
      contents:
        inline: |
          kernel.dmesg_restrict = 1
          kernel.kptr_restrict = 2
          kernel.kexec_load_disabled = 1
          kernel.sysrq = 0
          kernel.unprivileged_bpf_disabled = 1
          kernel.yama.ptrace_scope = 1
          kernel.core_pattern = |/bin/false
          fs.protected_hardlinks = 1
          fs.protected_symlinks = 1
          fs.suid_dumpable = 0
          net.ipv4.ip_forward = 1
          net.bridge.bridge-nf-call-iptables = 1

    - path: /etc/modprobe.d/99-cks-hardening.conf
      mode: 0644
      contents:
        inline: |
          install dccp /bin/false
          install sctp /bin/false
          install rds /bin/false
          install tipc /bin/false
          install usb-storage /bin/false
          install firewire-core /bin/false
          install cramfs /bin/false
          install udf /bin/false

    - path: /etc/ssh/sshd_config.d/10-hardening.conf
      mode: 0600
      contents:
        inline: |
          PermitRootLogin no
          PasswordAuthentication no
          AuthenticationMethods publickey
          AllowTcpForwarding no
          X11Forwarding no
          MaxAuthTries 3

  directories:
    - path: /var/lib/node-baseline
      mode: 0700

systemd:
  units:
    # Flatcar auto-updates: keep them, but coordinate reboots through Kured so
    # nodes drain first. Uncomment the mask only if an external controller
    # (e.g. FluxCD + node image bump) owns the lifecycle instead.
    - name: locksmithd.service
      mask: false
      enabled: true
      dropins:
        - name: 10-reboot-strategy.conf
          contents: |
            [Service]
            Environment=REBOOT_STRATEGY=off

    - name: kubelet.service
      enabled: true
      contents: |
        [Unit]
        Description=kubelet
        After=containerd.service
        Requires=containerd.service

        [Service]
        ExecStart=/opt/bin/kubelet --config=/var/lib/kubelet/config.yaml \
          --kubeconfig=/etc/kubernetes/kubelet.conf \
          --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
          --container-runtime-endpoint=unix:///run/containerd/containerd.sock
        Restart=always
        RestartSec=5
        ProtectHome=read-only
        OOMScoreAdjust=-999

        [Install]
        WantedBy=multi-user.target
```

```bash
$ butane --strict --files-dir . node.bu -o node.ign
$ ignition-validate node.ign && echo "ignition ok"
ignition ok
```

### 11.3 Bottlerocket (user data en TOML)

```toml
[settings.kubernetes]
cluster-name = "prod-eu-1"
api-server = "https://api.prod-eu-1.internal:6443"
cluster-dns-ip = "10.96.0.10"
cluster-certificate = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t..."
authentication-mode = "tls"
seccomp-default = true                       # RuntimeDefault for every pod
allowed-unsafe-sysctls = []
pod-pids-limit = 4096
server-tls-bootstrap = true

[settings.kubernetes.node-labels]
"node.kubernetes.io/instance-type" = "m6i.4xlarge"

[settings.kernel]
lockdown = "integrity"                       # "confidentiality" breaks eBPF tooling

[settings.kernel.sysctl]
"kernel.dmesg_restrict"           = "1"
"kernel.kptr_restrict"            = "2"
"kernel.unprivileged_bpf_disabled" = "1"
"net.core.bpf_jit_harden"         = "2"
"user.max_user_namespaces"        = "16384"  # keep pod userns available
"fs.inotify.max_user_watches"     = "524288"

# The admin container is a full shell on the host. Off by default; keep it off.
[settings.host-containers.admin]
enabled = false

# The control container exposes only the Bottlerocket API over SSM.
[settings.host-containers.control]
enabled = true

[settings.oci-defaults.capabilities]
sys-module = false
net-admin  = false
```

### 11.4 Talos (machine config)

```yaml
version: v1alpha1
debug: false
persist: true
machine:
  type: worker
  token: 9dh1q2.9k4hs8dj3ks92kd7
  ca:
    crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
  certSANs: []

  kubelet:
    image: ghcr.io/siderolabs/kubelet:v1.34.0
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true          # no static pods on workers
    extraConfig:
      readOnlyPort: 0
      protectKernelDefaults: true
      streamingConnectionIdleTimeout: 5m
      podPidsLimit: 4096
      serverTLSBootstrap: true

  install:
    disk: /dev/nvme0n1
    image: ghcr.io/siderolabs/installer:v1.11.0
    wipe: false
    extraKernelArgs:
      - lockdown=integrity
      - init_on_alloc=1
      - init_on_free=1
      - slab_nomerge
      - randomize_kstack_offset=on
      - vsyscall=none

  sysctls:
    kernel.dmesg_restrict: "1"
    kernel.kptr_restrict: "2"
    kernel.unprivileged_bpf_disabled: "1"
    net.core.bpf_jit_harden: "2"

  features:
    rbac: true
    stableHostname: true
    apidCheckExtKeyUsage: true
    kubePrism:
      enabled: true
      port: 7445

  # Talos has no shell, no SSH and no package manager. There is nothing to
  # minimize — the footprint is the design. Administration is talosctl only.
  network:
    interfaces:
      - interface: eth0
        dhcp: true
```

---

## 12. Verificación y diagnóstico de fallos

### 12.1 Benchmarking automatizado del nodo con `kube-bench`

```yaml
# kube-bench-node.yaml — runs the CIS section-4 (worker node) checks on every node
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-node
  namespace: security
spec:
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      restartPolicy: Never
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:v0.11.2
          args: ["run", "--targets", "node", "--benchmark", "cis-1.11"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsUser: 0
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      volumes:
        - name: var-lib-kubelet
          hostPath: { path: /var/lib/kubelet }
        - name: etc-systemd
          hostPath: { path: /etc/systemd }
        - name: etc-kubernetes
          hostPath: { path: /etc/kubernetes }
        - name: usr-bin
          hostPath: { path: /usr/bin }
```

```bash
$ kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -
namespace/security created
$ kubectl apply -f kube-bench-node.yaml
job.batch/kube-bench-node created

$ kubectl -n security wait --for=condition=complete job/kube-bench-node --timeout=120s
job.batch/kube-bench-node condition met

$ kubectl -n security logs job/kube-bench-node | sed -n '1,40p'
[INFO] 4 Worker Node Security Configuration
[INFO] 4.1 Worker Node Configuration Files
[PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive
[PASS] 4.1.2 Ensure that the kubelet service file ownership is set to root:root
[PASS] 4.1.3 If proxy kubeconfig file exists ensure permissions are set to 600 or more restrictive
[PASS] 4.1.4 If proxy kubeconfig file exists ensure ownership is set to root:root
[PASS] 4.1.5 Ensure that the --kubeconfig kubelet.conf file permissions are set to 600 or more restrictive
[PASS] 4.1.6 Ensure that the --kubeconfig kubelet.conf file ownership is set to root:root
[PASS] 4.1.7 Ensure that the certificate authorities file permissions are set to 600 or more restrictive
[PASS] 4.1.8 Ensure that the client certificate authorities file ownership is set to root:root
[PASS] 4.1.9 If the kubelet config.yaml configuration file is being used validate permissions set to 600
[PASS] 4.1.10 If the kubelet config.yaml configuration file is being used validate file ownership set to root:root
[INFO] 4.2 Kubelet
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[PASS] 4.2.3 Ensure that the --client-ca-file argument is set as appropriate
[PASS] 4.2.4 Verify that the --read-only-port argument is set to 0
[PASS] 4.2.5 Ensure that the --streaming-connection-idle-timeout argument is not set to 0
[PASS] 4.2.6 Ensure that the --make-iptables-util-chains argument is set to true
[PASS] 4.2.7 Ensure that the --hostname-override argument is not set
[WARN] 4.2.8 Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture
[PASS] 4.2.9 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set as appropriate
[PASS] 4.2.10 Ensure that the --rotate-certificates argument is not set to false
[PASS] 4.2.11 Verify that the RotateKubeletServerCertificate argument is set to true
[PASS] 4.2.12 Ensure that the Kubelet only makes use of Strong Cryptographic Ciphers
[PASS] 4.2.13 Ensure that a limit is set on pod PIDs

== Summary node ==
23 checks PASS
0 checks FAIL
1 checks WARN
0 checks INFO
```

### 12.2 Benchmarking a nivel de host

```bash
$ sudo lynis audit system --quick --quiet 2>&1 | tail -22
  Hardening
  ------------------------------------
  - Installed compiler(s)                                     [ NOT FOUND ]
  - Installed malware scanner                                 [ NOT FOUND ]
  - Non-native binary formats                                 [ NOT FOUND ]

  Lynis security scan details:

  Hardening index : 78 [###############     ]
  Tests performed : 254
  Plugins enabled : 0

  Components:
  - Firewall               [V]
  - Malware scanner        [X]

  Suggestions (7):
  ----------------------------
  - Consider hardening system services [BOOT-5264]
  - Install a file integrity tool to monitor changes [FINT-4350]
  - Harden compilers like restricting access to root user only [HRDN-7222]
  ...

# Compare a node against its own build-time baseline — this is the drift check
# that actually catches an intruder, not the benchmark score.
$ diff <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null | sort) \
       /var/lib/node-baseline/suid.txt
> 4755 /usr/bin/sudo
< 4755 /usr/bin/sudo
< 4755 /tmp/.cache/systemd-helper        # <-- investigate immediately
```

### 12.3 Depurar sin reinstalar herramientas en el nodo

El reflejo de "déjame hacer `apt install tcpdump` en el nodo" deshace todo el trabajo. Usá en cambio un contenedor efímero de depuración dentro de los namespaces del host — las herramientas viven en una imagen, se eliminan cuando el proceso termina y dejan un rastro de auditoría:

```bash
$ kubectl debug node/worker-03 -it --image=nicolaka/netshoot:v0.13 --profile=sysadmin -- bash
Creating debugging pod node-debugger-worker-03-6xk2p with container debugger on node worker-03.
If you don't see a command prompt, try pressing enter.

worker-03:~# nsenter -t 1 -n -- ss -tulpn | head -5
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp   LISTEN 0      4096   127.0.0.1:10248    0.0.0.0:*
tcp   LISTEN 0      4096   0.0.0.0:10250      0.0.0.0:*

worker-03:~# exit
$ kubectl delete pod node-debugger-worker-03-6xk2p
pod "node-debugger-worker-03-6xk2p" deleted
```

### 12.4 Catálogo de fallos

Cada entrada de abajo es una consecuencia real de alguno de los cambios de este documento.

| Síntoma | Diagnóstico | Causa raíz | Solución |
|---|---|---|---|
| el kubelet falla al arrancar: `Failed to start ContainerManager invalid kernel flag: vm/overcommit_memory, expected value: 1, actual value: 0` | `journalctl -u kubelet -p err -n 30`; `sysctl vm.overcommit_memory` | `protectKernelDefaults: true` con sysctls que no coinciden con lo que espera el kubelet | Poner `vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`, `kernel.keys.root_maxkeys=1000000`, `kernel.keys.root_maxbytes=25000000` en `/etc/sysctl.d/`, luego `sysctl --system` |
| kubelet: `running with swap on is not supported, please disable swap` | `swapon --show` | `failSwapOn: true` (por defecto) con swap activo | `swapoff -a` + comentar la entrada de `fstab` |
| Todos los pods trabados en `ContainerCreating`; log de containerd: `skip plugin "io.containerd.snapshotter.v1.overlayfs"` | `journalctl -u containerd -n 50`; `lsmod \| grep overlay` | módulo `overlay` en lista negra o no disponible | Sacarlo de la lista negra, `modprobe overlay`, agregarlo a `/etc/modules-load.d/` |
| Los pods llegan a otros pods, pero nunca a las ClusterIP de Service en el mismo nodo | `sysctl net.bridge.bridge-nf-call-iptables` → `cannot stat` | `br_netfilter` no cargado / en lista negra | `modprobe br_netfilter` + `/etc/modules-load.d/kubernetes.conf` + volver a aplicar sysctl |
| kube-proxy en CrashLoopBackOff: `can't use the IPVS proxier ... required kernel modules are not loaded` | `kubectl -n kube-system logs ds/kube-proxy` | `ip_vs*` en lista negra o ausente | Cargar `ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack` |
| Todos los contenedores salen al instante: `exec /usr/local/bin/app: permission denied` | `findmnt -no OPTIONS /var` muestra `noexec` | `noexec` aplicado a `/var` (o `/var/lib/containerd`) | Remontar sin `noexec`; corregir `fstab`. **Nunca** `noexec` en `/var` |
| Dentro de los contenedores: `sudo: effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid' option set?` | `findmnt -no OPTIONS /var` | `nosuid` en el almacén de respaldo del snapshotter | Igual que arriba — sacar `nosuid` de `/var` |
| Los Services se rompen de forma intermitente y se recuperan solos ~30 s después | `nft list tables` muestra que falta `ip kube-proxy` justo después de que corre el firewall | El script de firewall usó `flush ruleset`, borrando las tablas nftables de kube-proxy | Eliminar `flush ruleset`; usar `table X` + `delete table X` + redefinir |
| NodePort inalcanzable desde el LB; pod a pod anda bien | `nft list counters table inet k8s_host`; `nft monitor trace` | Política `drop` en la cadena input sin un accept de NodePort, o cadena `forward` puesta en `drop` | Agregar la regla de `30000-32767`; poner la política `accept` en `forward` |
| El DNS del clúster da timeout después de aplicar sysctls de "endurecimiento" | `sysctl net.ipv4.conf.all.rp_filter`; `dmesg \| grep martian` | El filtrado estricto de ruta inversa (`rp_filter=1`) rompe el camino de retorno asimétrico del CNI | Usar `0` o el laxo `2` según la documentación del CNI |
| kube-proxy: `iptables-restore: line 12 failed`, no se programan Services nuevos | `dmesg \| grep 'Operation not permitted'`; `sysctl kernel.modules_disabled` | `kernel.modules_disabled=1` fijado antes de que kube-proxy autocargara un módulo `xt_*` | Reiniciar; precargar todos los módulos necesarios vía `/etc/modules-load.d/` y sellar solo después de que pase el script de verificación |
| Falco/Cilium/Tetragon: `bpf: Operation not permitted`, la sonda no carga | `cat /sys/kernel/security/lockdown` muestra `[confidentiality]` | El lockdown confidentiality bloquea las lecturas de memoria del kernel que usan las sondas eBPF | Bajar a `lockdown=integrity`, o aceptar la pérdida del sensor de runtime |
| El nodo reinicia y nunca vuelve; la consola muestra `mount: unknown filesystem type 'squashfs'` | Consola serie | `squashfs` en lista negra mientras `snapd` monta snaps en el arranque | No poner `install squashfs /bin/false` en Ubuntu con snaps; eliminar snapd en su lugar |
| El agente de nube (SSM/guest-agent) deja de reportar tras la minimización | `systemctl status amazon-ssm-agent` → `Unit not found` | El agente venía como snap y se eliminó junto con `snapd` | Reinstalar el agente como `.deb`/`.rpm`, o mantener `snapd` para esa flota |
| Quedaste afuera de todos los nodos tras un cambio de SSH o firewall | — | No había rollback armado | Siempre armá un `systemd-run --on-active=5min` con la reversión antes de aplicar; validá desde una *segunda* sesión antes de cancelarlo |
| El attach de volumen se cuelga, pod en `ContainerCreating` por minutos | `kubectl describe pod`; `dmesg \| grep -i iscsi`; `journalctl -u kubelet \| grep -i mount` | Un módulo de almacenamiento (`iscsi_tcp`, `rbd`, `nfsv4`, `dm_*`) quedó en lista negra o `modules_disabled=1` | Permitir y precargar el conjunto de módulos del driver CSI |

### 12.5 Un único script de verificación

```bash
#!/usr/bin/env bash
# /usr/local/sbin/node-hardening-check.sh
# Non-destructive posture check. Exit 0 = all assertions hold.
set -uo pipefail
fail=0

check() {  # check <description> <command...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        printf '[ PASS ] %s\n' "$desc"
    else
        printf '[ FAIL ] %s\n' "$desc"; fail=1
    fi
}

echo "== network surface =="
check "kubelet read-only port 10255 closed" \
    bash -c '! ss -tlnH | grep -q ":10255 "'
check "no unexpected 0.0.0.0 listeners" \
    bash -c '! ss -tlnH | awk "{print \$4}" | grep -E "^0\.0\.0\.0:" | grep -vE ":(10250|10256|22)$" | grep -q .'
check "nftables k8s_host table present" \
    nft list table inet k8s_host
check "kube-proxy nftables/iptables tables intact" \
    bash -c 'nft list tables | grep -qE "kube-proxy|^table ip filter"'

echo "== kernel surface =="
check "dmesg restricted"          bash -c '[ "$(sysctl -n kernel.dmesg_restrict)" = 1 ]'
check "kptr restricted"           bash -c '[ "$(sysctl -n kernel.kptr_restrict)" = 2 ]'
check "kexec disabled"            bash -c '[ "$(sysctl -n kernel.kexec_load_disabled)" = 1 ]'
check "core_pattern is not a pipe" bash -c '! grep -q "^|" /proc/sys/kernel/core_pattern || [ "$(cat /proc/sys/kernel/core_pattern)" = "|/bin/false" ]'
check "tipc autoload blocked"     bash -c 'modprobe -n -v tipc 2>&1 | grep -q "/bin/false"'
check "dccp autoload blocked"     bash -c 'modprobe -n -v dccp 2>&1 | grep -q "/bin/false"'
check "ip_forward enabled (k8s requirement)" bash -c '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
check "br_netfilter loaded"       bash -c 'lsmod | grep -q "^br_netfilter"'
check "overlay loaded"            bash -c 'lsmod | grep -q "^overlay"'

echo "== local privesc surface =="
check "pkexec absent"             bash -c '[ ! -e /usr/bin/pkexec ]'
check "no compiler on node"       bash -c '! command -v gcc && ! command -v cc'
check "SUID count <= 8"           bash -c '[ "$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l)" -le 8 ]'
check "SUID set matches baseline" bash -c 'diff -q <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf "%04m %p\n" 2>/dev/null | sort) /var/lib/node-baseline/suid.txt'
check "root password locked"      bash -c 'awk -F: "\$1==\"root\"{print \$2}" /etc/shadow | grep -q "^[!*]"'
check "no NOPASSWD sudo rules"    bash -c '! grep -rq NOPASSWD /etc/sudoers /etc/sudoers.d/'
check "no empty passwords"        bash -c '! awk -F: "(\$2==\"\")" /etc/shadow | grep -q .'
check "no docker group"           bash -c '! getent group docker'

echo "== filesystem =="
check "/tmp nodev,nosuid,noexec"  bash -c 'findmnt -no OPTIONS /tmp | grep -q nodev && findmnt -no OPTIONS /tmp | grep -q nosuid && findmnt -no OPTIONS /tmp | grep -q noexec'
check "/var IS exec (containers need it)" bash -c '! findmnt -no OPTIONS /var | grep -q noexec'
check "swap off"                  bash -c '[ -z "$(swapon --show --noheadings)" ]'

echo "== kubernetes files =="
check "kubelet config 600"        bash -c '[ "$(stat -c %a /var/lib/kubelet/config.yaml)" = 600 ]'
check "kubelet.conf 600"          bash -c '[ "$(stat -c %a /etc/kubernetes/kubelet.conf)" = 600 ]'
check "no admin.conf on worker"   bash -c '[ ! -e /etc/kubernetes/admin.conf ] || [ -d /etc/kubernetes/manifests ]'
check "containerd config 600"     bash -c '[ "$(stat -c %a /etc/containerd/config.toml)" = 600 ]'
check "kubelet anonymous auth off" bash -c 'grep -A2 "^authentication:" /var/lib/kubelet/config.yaml | grep -A1 anonymous | grep -q "enabled: false"'
check "kubelet authz webhook"     bash -c 'grep -A1 "^authorization:" /var/lib/kubelet/config.yaml | grep -q "mode: Webhook"'
check "seccompDefault on"         bash -c 'grep -q "seccompDefault: true" /var/lib/kubelet/config.yaml'

echo
[ $fail -eq 0 ] && echo "RESULT: node hardening baseline OK" || echo "RESULT: FAILURES PRESENT"
exit $fail
```

```bash
$ sudo /usr/local/sbin/node-hardening-check.sh
== network surface ==
[ PASS ] kubelet read-only port 10255 closed
[ PASS ] no unexpected 0.0.0.0 listeners
[ PASS ] nftables k8s_host table present
[ PASS ] kube-proxy nftables/iptables tables intact
== kernel surface ==
[ PASS ] dmesg restricted
[ PASS ] kptr restricted
[ PASS ] kexec disabled
[ PASS ] core_pattern is not a pipe
[ PASS ] tipc autoload blocked
[ PASS ] dccp autoload blocked
[ PASS ] ip_forward enabled (k8s requirement)
[ PASS ] br_netfilter loaded
[ PASS ] overlay loaded
== local privesc surface ==
[ PASS ] pkexec absent
[ PASS ] no compiler on node
[ PASS ] SUID count <= 8
[ PASS ] SUID set matches baseline
[ PASS ] root password locked
[ PASS ] no NOPASSWD sudo rules
[ PASS ] no empty passwords
[ PASS ] no docker group
== filesystem ==
[ PASS ] /tmp nodev,nosuid,noexec
[ PASS ] /var IS exec (containers need it)
[ PASS ] swap off
== kubernetes files ==
[ PASS ] kubelet config 600
[ PASS ] kubelet.conf 600
[ PASS ] no admin.conf on worker
[ PASS ] containerd config 600
[ PASS ] kubelet anonymous auth off
[ PASS ] kubelet authz webhook
[ PASS ] seccompDefault on

RESULT: node hardening baseline OK
```

---

## 13. Estrategia de despliegue

El endurecimiento de nodos es un cambio de *flota* con radio de impacto en todo el clúster. Tratalo como una migración de esquema:

1. **Establecé la línea base de cada nodo** y commiteá los artefactos (`suid.txt`, `listen.txt`, `packages.txt`) al repositorio de infraestructura.
2. **Cambiá la imagen, no el nodo.** Cada ítem de §4–§11 pertenece a la plantilla de Packer/`image-builder`. La gestión de configuración en tiempo de ejecución es el recurso de reserva para brownfield, no el diseño.
3. **Hacé canary en un nodo por dominio de fallo**, acordonado, ejecutando un workload sintético que ejercite exec, volúmenes, DNS, NodePort y pull de imágenes.
4. **Dejalo horneando un ciclo de negocio completo** — 24 h como mínimo. Las listas negras de módulos se rompen en el *primer attach de CSI* o en el *primer tipo de Service nuevo*, que pueden ocurrir horas después del arranque.
5. **Desplegá por node group**, respetando los `PodDisruptionBudget` y con un rollback automatizado a la AMI/imagen anterior ante una regresión de la condición Ready.
6. **Hacelo cumplir de forma continua.** `kube-bench` como `CronJob`, el script de §12.5 como textfile collector de node-exporter, y una alerta ante cualquier diferencia contra `/var/lib/node-baseline/`.

### Notas para el examen CKS

Bajo presión de tiempo, las acciones de mayor rédito en una tarea de nodo son, en orden:

1. `grep -E 'readOnlyPort|anonymous|authorization|protectKernelDefaults|seccompDefault' /var/lib/kubelet/config.yaml` — la mayoría de las preguntas de nodo están acá.
2. `systemctl list-units --type=service --state=running` → `systemctl mask --now <service>` para cualquier cosa obviamente innecesaria. **Usá `mask`, no `disable`** — los correctores verifican que no pueda reiniciarse.
3. `ss -tulpn` → cerrá lo que no debería estar escuchando.
4. `find / -xdev -perm -4000 -type f` → `chmod u-s` a los obviamente innecesarios.
5. `systemctl restart kubelet && systemctl is-active kubelet` — **verificá siempre que el nodo vuelva a Ready**; un nodo endurecido que no ejecuta pods puntúa cero.

---

## Referencias

- CNCF — *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — *Ports and Protocols*: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubernetes — *Kubelet Configuration (v1beta1) reference*: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes — *Set Kubelet Parameters Via A Configuration File*: https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/
- Kubernetes — *Securing a Cluster*: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubernetes — *Kubelet authentication/authorization*: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes — *Using Node Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes — *Swap memory management on nodes*: https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory
- Kubernetes — *User Namespaces*: https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
- Kubernetes — *Restrict a Container's Syscalls with seccomp*: https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes — *Debugging with an ephemeral debug container / `kubectl debug node`*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- CIS — *Kubernetes Benchmark*: https://www.cisecurity.org/benchmark/kubernetes
- Aqua Security — *kube-bench*: https://github.com/aquasecurity/kube-bench
- Kubernetes SIGs — *image-builder*: https://github.com/kubernetes-sigs/image-builder
- systemd — *`systemd-analyze security`*: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- systemd — *`systemd.exec` sandboxing directives*: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — *`modules-load.d`*: https://www.freedesktop.org/software/systemd/man/latest/modules-load.d.html
- Linux kernel — *`kernel_lockdown(7)`*: https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- Linux kernel — *sysctl `/proc/sys/kernel` documentation*: https://docs.kernel.org/admin-guide/sysctl/kernel.html
- Linux kernel — *sysctl `/proc/sys/net` documentation*: https://docs.kernel.org/admin-guide/sysctl/net.html
- Linux kernel — *Yama LSM (`ptrace_scope`)*: https://docs.kernel.org/admin-guide/LSM/Yama.html
- `modprobe.d(5)` manual page: https://man7.org/linux/man-pages/man5/modprobe.d.5.html
- netfilter — *nftables wiki*: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- OpenSSH — *`sshd_config(5)`*: https://man.openbsd.org/sshd_config
- CISOfy — *Lynis*: https://cisofy.com/lynis/
- OpenSCAP — *ComplianceAsCode security guides*: https://github.com/ComplianceAsCode/content
- Flatcar Container Linux — *Documentation*: https://www.flatcar.org/docs/latest/
- Butane / Ignition — *Configuration specification*: https://coreos.github.io/butane/specs/
- Bottlerocket OS — *Settings reference*: https://bottlerocket.dev/en/os/latest/#/api/settings/
- Bottlerocket OS — *Security features*: https://github.com/bottlerocket-os/bottlerocket/blob/develop/SECURITY_FEATURES.md
- Talos Linux — *Documentation*: https://www.talos.dev/latest/
- Talos Linux — *Machine configuration reference*: https://www.talos.dev/latest/reference/configuration/
- containerd — *CRI plugin configuration*: https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- NIST — *SP 800-190, Application Container Security Guide*: https://csrc.nist.gov/pubs/sp/800/190/final
- CVE-2021-4034 (`pkexec` local root, "PwnKit"): https://nvd.nist.gov/vuln/detail/CVE-2021-4034
- CVE-2021-43267 (TIPC remote heap overflow): https://nvd.nist.gov/vuln/detail/CVE-2021-43267
- CVE-2019-18683 (`vivid` driver local root): https://nvd.nist.gov/vuln/detail/CVE-2019-18683