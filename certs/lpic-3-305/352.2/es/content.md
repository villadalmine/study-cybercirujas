# 352.2 — System Containers with LXC and LXD

> **Examen:** LPIC-3 305-300 (v3.0) · **Objetivo 352.2** · **Peso 10**
> **Alcance:** Arquitectura de LXC y LXD; gestión de contenedores basados en imágenes con LXD (networking + almacenamiento); límites de CPU/memoria/almacenamiento; características de seguridad incluyendo nesting. Versión cubierta: LXC/LXD **3.0 o posterior**.

---

## 1. Motivación y el problema de arquitectura en producción

Hay dos cosas fundamentalmente distintas que la industria llama «contenedor», y confundirlas es la causa raíz de la mayoría de las malas decisiones de arquitectura en este terreno.

- **Contenedores de aplicación** (Docker/OCI) ejecutan *un único árbol de procesos alrededor de una sola carga*. El contrato es «una imagen, un entrypoint, efímero, inmutable, orquestado». El estado se externaliza. El contenedor *es* el proceso.
- **Contenedores de sistema** (LXC/LXD) ejecutan *un sistema de init completo y un espacio de usuario que parece una máquina*: `systemd` como PID 1, `sshd`, `cron`, múltiples servicios, gestores de paquetes, sistemas de archivos persistentes, syslog. El contenedor se comporta como una VM liviana y de larga vida — pero comparte el kernel del host, así que no hay impuesto de hipervisor, no hay kernel invitado que parchear, y el tiempo de arranque se mide en cientos de milisegundos.

El problema de producción que LXC/LXD resuelve es la **carga de trabajo del tipo «necesito una máquina, no un proceso» a una densidad de VMs que KVM no puede alcanzar**:

- Runners de build/CI multi-tenant donde cada tenant necesita `apt`, montajes, un `/etc` real y sus propios daemons.
- Servicios legacy o con estado (directorios LDAP, stacks de correo, appliances de monitoreo, entornos de laboratorio universitarios) que asumen que son dueños de un SO y no pueden refactorizarse en aplicaciones 12-factor.
- Hosting denso: 200–400 contenedores de sistema en un host donde la misma máquina llega a su tope alrededor de 30–40 invitados KVM, porque no estás pagando por N kernels invitados, N copias de page-cache ni N conjuntos de dispositivos emulados.
- **«Instancias» migrables en vivo, con snapshots y modeladas en red** con una API declarativa — la ergonomía operativa de una nube (`lxc launch`, profiles, projects, clustering, REST) sin un hipervisor.

La trampa arquitectónica es usar contenedores de sistema como si fueran VMs con una frontera de *seguridad* equivalente a KVM. No lo son: un kernel compartido significa que la superficie de ataque del kernel es la frontera entre tenants. Toda la disciplina de seguridad de este objetivo — **contenedores unprivileged, idmaps de user-namespace, AppArmor, seccomp y nesting controlado** — existe para hacer defendible esa frontera de kernel compartido. Tratarla como una frontera fuerte sin esos controles es la causa #1 de incidentes en producción aquí.

```
                     Density  ↑
   ┌───────────────────────────────────────────────┐
   │  LXC/LXD system containers                     │  shared kernel,
   │  (full OS userspace, init, multi-service)      │  ~ms boot, high density
   ├───────────────────────────────────────────────┤
   │  Docker/OCI application containers             │  shared kernel,
   │  (single process, immutable, ephemeral)        │  one payload
   ├───────────────────────────────────────────────┤
   │  KVM / QEMU virtual machines                   │  guest kernel,
   │  (hardware-level isolation, own kernel)        │  strong boundary, heavier
   └───────────────────────────────────────────────┘
                   Isolation strength  ↑
```

---

## 2. Arquitectura de LXC y LXD

### 2.1 Las dos capas

LXC es un sistema **por capas**, y el examen espera que distingas las capas con precisión — incluyendo el hecho de que el cliente de LXD también se llama `lxc`, lo cual es una fuente notoria de confusión.

| Capa | Componente | Rol |
|---|---|---|
| Kernel | namespaces, cgroups, capabilities, seccomp, LSM (AppArmor/SELinux) | Las primitivas de aislamiento reales. LXC/LXD las *configuran*; no las implementan. |
| Espacio de usuario de bajo nivel | **liblxc** + herramientas `lxc-*` | El runtime del contenedor. Crea namespaces, aplica la configuración, lanza el init del contenedor. Imperativo, archivos de configuración por contenedor. |
| Plano de control de alto nivel | **LXD** (daemon `lxd` + cliente `lxc`) | Un daemon privilegiado que expone una **REST API** sobre un socket Unix (y opcionalmente HTTPS). Gestiona imágenes, storage pools, redes, profiles, projects, snapshots, remotes, clustering y migración en vivo. Usa liblxc por debajo. |

```
  Operator / automation
        │  (CLI, Terraform, Ansible)
        ▼
  ┌─────────────┐   HTTPS / REST (client cert auth)   ┌───────────────┐
  │ lxc client  │◀──────────────────────────────────▶│  Remote image │
  │ (LXD CLI)   │                                     │  servers      │
  └─────┬───────┘                                     └───────────────┘
        │ Unix socket /var/snap/lxd/common/lxd/unix.socket
        ▼
  ┌────────────────────────────────────────────────────────────────┐
  │                         lxd  (daemon)                           │
  │  REST API · auth (TLS/PKI/OIDC) · scheduler · DB (dqlite/Raft)  │
  │  ┌──────────┐ ┌───────────┐ ┌──────────┐ ┌───────────────────┐ │
  │  │ Images   │ │ Storage   │ │ Networks │ │ Profiles/Projects │ │
  │  └──────────┘ └────┬──────┘ └────┬─────┘ └───────────────────┘ │
  └────────────────────┼─────────────┼─────────────────────────────┘
                       │             │
                  ┌────▼────┐   ┌────▼────┐
                  │ liblxc  │   │ bridge/ │
                  │ (runtime)│   │ OVN/... │
                  └────┬─────┘   └─────────┘
                       ▼
        namespaces · cgroup v2 · seccomp · AppArmor · capabilities
                       ▼
                 host Linux kernel (shared)
```

**Hechos clave de arquitectura para el examen:**

- LXD es un **daemon con una REST API**; la CLI es un cliente liviano. Cualquier cosa que haga la CLI, la puede hacer una llamada HTTP — por eso LXD se integra limpiamente con Terraform/Ansible y con clusters.
- LXD almacena su estado en una base de datos **dqlite** embebida (replicada por Raft en un cluster). No hay una base de datos externa.
- **Remotes**: LXD habla con servidores de imágenes y con otros daemons de LXD de forma uniforme. `images:` es el servidor de imágenes de la comunidad LinuxContainers; `ubuntu:` es el servidor de cloud-images de Canonical; `local:` es el daemon local por defecto.
- **Clustering**: múltiples daemons de LXD forman un único plano de control distribuido que comparte una base de datos y una API; las instancias se planifican entre los miembros y pueden migrar en vivo entre ellos.

> **Nota de producción (panorama de forks).** LXD es mantenido por Canonical. En 2023 el proyecto LinuxContainers hizo un fork de LXD llamado **Incus**, que ahora es la continuación gobernada por la comunidad (CLI `incus`, socket `incus-admin`). `liblxc` y las herramientas `lxc-*` siguen bajo LinuxContainers. El objetivo 305-300 v3.0 está escrito en torno a **LXC/LXD 3.0+**, así que este material de estudio usa la terminología de LXD; en las distros modernas de la comunidad verás frecuentemente `incus` donde este texto muestra `lxc`. La superficie de comandos es casi idéntica (`incus launch images:...`), lo cual es deliberado.

### 2.2 Las primitivas del kernel, en concreto

LXC/LXD es «solamente» una composición curada de características del kernel:

- **Namespaces** (`man 7 namespaces`): `pid`, `net`, `mnt`, `uts`, `ipc`, `user`, `cgroup`, `time`. El **user namespace** es lo que hace posibles los contenedores *unprivileged*: el root del contenedor (uid 0) se mapea a un uid del host sin privilegios (p. ej. 100000).
- **cgroup v2**: contabilidad y límites jerárquicos de recursos (CPU, memoria, io, pids). LXD escribe en la jerarquía unificada bajo `/sys/fs/cgroup/`.
- **Capabilities**: porciones de grano fino de root. Los contenedores unprivileged descartan las peligrosas y, mediante el mapeo de user-ns, retienen capabilities que solo son válidas *dentro* del namespace del contenedor.
- **seccomp**: filtrado de syscalls. LXD trae un profile por defecto que bloquea/virtualiza syscalls peligrosas (p. ej. intercepta algunas para hacer los contenedores más seguros sin romperlos).
- **LSM — AppArmor** (Ubuntu/Debian) o **SELinux**: control de acceso obligatorio (mandatory access control) que confina cada contenedor a su propio profile.

### 2.3 Privileged vs unprivileged (el concepto de seguridad central)

| | **Unprivileged (por defecto, recomendado)** | **Privileged** |
|---|---|---|
| El `root` del contenedor (uid 0) se mapea a | Un uid del **host** sin privilegios (p. ej. 100000) vía user namespace | **uid 0** real del host |
| Visión del kernel ante una fuga del contenedor | El atacante aterriza como un usuario sin privilegios del host | El atacante aterriza como **root** del host |
| Clave de configuración | (por defecto) o `security.privileged: false` | `security.privileged: true` |
| Requiere | rangos de idmap en `/etc/subuid` + `/etc/subgid` | — |
| Usar cuando | Casi siempre | Solo cuando una carga de trabajo genuinamente necesita semántica de root-real sobre recursos del host y aceptás el riesgo |

El idmap se declara en `/etc/subuid` / `/etc/subgid`. El mapa propio de LXD (para su daemon con dueño root) es típicamente:

```
$ cat /etc/subuid
lxd:1000000:1000000000
root:1000000:1000000000
$ cat /etc/subgid
lxd:1000000:1000000000
root:1000000:1000000000
```

Cada contenedor unprivileged obtiene entonces un sub-rango de ese pool, así que un archivo que pertenece a `root` dentro del contenedor pertenece a `1000000` en el sistema de archivos del host.

---

## 3. Comparativas técnicas y tablas de trade-offs

### 3.1 Runtimes

| Dimensión | **liblxc / `lxc-*`** | **LXD (cliente `lxc`)** | **Docker/OCI** | **KVM (libvirt)** |
|---|---|---|---|---|
| Modelo de contenedor | Sistema (init completo) | Sistema (init completo) | Aplicación (1 proceso) | VM completa |
| Kernel | Compartido | Compartido | Compartido | Kernel invitado propio |
| Plano de control | Ninguno (archivos de config) | REST API + daemon + DB | REST API + daemon | libvirtd + REST/RPC |
| Ecosistema de imágenes | Plantilla `download` | Servidores de imágenes + publish/export | Registries (OCI) | Cloud images / ISOs |
| Abstracción de almacenamiento | Manual (fstab/montajes) | **Storage pools** (zfs/btrfs/lvm/ceph/dir) | Volumes/overlay2 | Imágenes de disco (qcow2/LVM/RBD) |
| Abstracción de networking | Manual | **Redes gestionadas** (bridge/OVN/macvlan) | CNI/bridge | Bridges gestionados/OVN |
| Migración en vivo | Limitada (CRIU) | Sí (CRIU / stateful) | No (por diseño) | Sí |
| Clustering incorporado | No | **Sí (dqlite/Raft)** | Necesita Swarm/K8s | Necesita oVirt/OpenStack |
| Mejor para | Embeber, huella mínima, aprender las primitivas | Flota de instancias tipo-VM con ergonomía de nube | Entrega inmutable de aplicaciones | Aislamiento multi-tenant fuerte |

**Regla práctica:** usá **liblxc** cuando querés la primitiva y controlar todo vos mismo (o embeberla); usá **LXD** para una flota gestionada; recurrí a **KVM** cuando la frontera entre tenants debe sobrevivir a un bug del kernel.

### 3.2 Backends de almacenamiento de LXD

| Driver | Snapshots | Clones copy-on-write | Cuotas (root `size=`) | Notas / cuándo usar |
|---|---|---|---|---|
| `dir` | No (copia completa) | No | No | El más simple, portable, lento; solo dev/test |
| `btrfs` | Sí | Sí (reflink) | Sí | Buen default en un solo disco; un subvolumen por instancia |
| **`zfs`** | Sí | Sí | Sí | **Default de producción**: clones CoW rápidos, caché ARC, `send/recv` para migración, compresión |
| `lvm` | Sí (thin) | Sí (thin) | Sí | A nivel de bloque; combina bien con LVM/thinpools existentes |
| `ceph` (RBD) | Sí | Sí | Sí | Almacenamiento distribuido/HA para clusters; respaldo compartido entre miembros |
| `cephfs` / `cephobject` | — | — | — | Para volúmenes de almacenamiento custom / objeto, no para el root de instancia |

### 3.3 Modos de red de LXD

| Tipo | Aislamiento | Alcanzable desde la LAN directamente | Uso típico |
|---|---|---|---|
| `bridge` (`lxdbr0`) | Subred privada con NAT + DNS (dnsmasq) | No (SNAT/DNAT) | Por defecto; host autocontenido |
| NIC `macvlan` | El contenedor obtiene una MAC en la LAN física | Sí | Contenedores como hosts de primera clase en la LAN |
| NIC `bridged` a un bridge existente del host (`br0`) | L2 en el bridge del host | Sí | Integrar con el bridge/VLANs propios del host |
| `ovn` | Overlay (Geneve), routers virtuales, ACLs | Vía uplink | SDN multi-tenant a nivel de cluster con security groups |
| NIC `sriov` | VF de hardware | Sí | NFV de baja latencia/alto throughput |
| `physical` / `ipvlan` | Directo/basado en parent | Sí | Propósito especial |

---

## 4. Manifiestos completos e infraestructura (sin abreviar)

### 4.1 Bootstrap no interactivo de LXD (`lxd init --preseed`)

Alimentá esto por stdin para inicializar un host de forma declarativa — la alternativa de producción al asistente interactivo. Esto crea un pool ZFS, un bridge con NAT, expone la HTTPS API y define el profile `default`.

```yaml
# lxd-preseed.yaml — apply with:  cat lxd-preseed.yaml | lxd init --preseed
config:
  core.https_address: '[::]:8443'      # expose REST API on all interfaces, port 8443
  images.auto_update_interval: "6"      # hours between image auto-updates
networks:
  - name: lxdbr0
    type: bridge
    config:
      ipv4.address: 10.152.1.1/24
      ipv4.nat: "true"
      ipv4.dhcp: "true"
      ipv6.address: none                # keep it simple; disable IPv6 on this bridge
      dns.domain: lab.internal
storage_pools:
  - name: default
    driver: zfs
    config:
      source: tank/lxd                  # use an existing ZFS dataset; omit for a loop file
profiles:
  - name: default
    description: Default LXD profile (root on ZFS, NIC on lxdbr0)
    devices:
      root:
        path: /
        pool: default
        type: disk
      eth0:
        name: eth0
        network: lxdbr0
        type: nic
# 'projects' and 'cluster' keys can also appear here for multi-tenant / clustered bootstraps.
```

### 4.2 Un profile endurecido y con límite de recursos

Los profiles son la unidad declarativa que LXD aplica a las instancias (una instancia puede apilar varios). Este impone límites, prohíbe la escalada de privilegios y confina el contenedor.

```yaml
# apply with:  lxc profile create webtier ; lxc profile edit webtier < webtier.yaml
name: webtier
description: Unprivileged web tier — 2 vCPU, 2 GiB RAM, 10 GiB disk, confined
config:
  limits.cpu: "2"                       # 2 logical CPUs
  limits.cpu.allowance: 50%             # ...but throttled to 50% of that (1 CPU-equivalent)
  limits.memory: 2GiB
  limits.memory.enforce: hard           # OOM-kill inside the container, don't spill to host
  limits.memory.swap: "false"
  limits.processes: "512"               # pids cgroup cap
  security.privileged: "false"          # explicit: unprivileged
  security.nesting: "false"             # no nested containers here
  security.syscalls.intercept.mknod: "false"
  boot.autostart: "true"
  boot.autostart.priority: "10"
  user.team: platform                   # free-form metadata (user.* keys)
devices:
  root:
    path: /
    pool: default
    type: disk
    size: 10GiB                         # per-instance disk quota (needs zfs/btrfs/lvm)
  eth0:
    name: eth0
    network: lxdbr0
    type: nic
```

### 4.3 user-data de cloud-init vía un profile

Las imágenes de LXD de `images:`/`ubuntu:` soportan cloud-init. Entregá la configuración de primer arranque de forma declarativa — así es como se aprovisionan contenedores de sistema a escala sin golden images.

```yaml
# provisioning profile carrying cloud-init
name: provisioned
description: cloud-init bootstrap (packages, user, nginx)
config:
  user.user-data: |
    #cloud-config
    package_update: true
    packages:
      - nginx
      - htop
    users:
      - name: deploy
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... deploy@bastion
    write_files:
      - path: /var/www/html/index.html
        content: "<h1>Provisioned by cloud-init inside LXD</h1>\n"
    runcmd:
      - systemctl enable --now nginx
devices: {}
```

### 4.4 Configuración de contenedor unprivileged de bajo nivel con liblxc

Cuando bajás por debajo de LXD hacia liblxc puro, el contenedor se define mediante un archivo de configuración plano. Los contenedores unprivileged (rootless) viven bajo `~/.local/share/lxc/<name>/config`:

```ini
# ~/.local/share/lxc/web1/config  (unprivileged, run as a normal user)
lxc.uts.name = web1

# --- User-namespace idmap: container 0..65535 -> host 100000..165535 ---
lxc.idmap = u 0 100000 65536
lxc.idmap = g 0 100000 65536

# --- Root filesystem ---
lxc.rootfs.path = dir:/home/dev/.local/share/lxc/web1/rootfs

# --- Networking: veth into the host's lxcbr0 ---
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx

# --- Confinement ---
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 0
lxc.seccomp.profile = /usr/share/lxc/config/common.seccomp

# --- Common includes shipped by the distro ---
lxc.include = /usr/share/lxc/config/common.conf
lxc.include = /usr/share/lxc/config/userns.conf

# --- cgroup limits (cgroup v2 keys) ---
lxc.cgroup2.memory.max = 536870912          # 512 MiB
lxc.cgroup2.pids.max = 256
```

La concesión correspondiente en `/etc/subuid` / `/etc/subgid` para el usuario `dev` debe existir:

```
$ grep dev /etc/subuid /etc/subgid
/etc/subuid:dev:100000:65536
/etc/subgid:dev:100000:65536
```

---

## 5. Comandos reales de la CLI y salida de terminal

### 5.1 Instalar e inicializar LXD

```bash
$ sudo snap install lxd
lxd 5.21/stable installed
$ sudo usermod -aG lxd "$USER"    # log out/in so group membership applies
$ newgrp lxd
$ lxd init --minimal              # quick default: dir pool + lxdbr0 + default profile
```

Verificá el daemon y su visión del mundo:

```bash
$ lxc version
Client version: 5.21
Server version: 5.21
$ lxc info | head -n 12
config:
  core.https_address: '[::]:8443'
api_extensions:
- storage_zfs_remove_snapshots
- container_host_shutdown_timeout
...
environment:
  addresses:
  - 10.152.1.1:8443
  kernel: Linux
  kernel_version: 6.8.0-40-generic
  server: lxd
  server_version: "5.21"
```

### 5.2 Remotes e imágenes

```bash
$ lxc remote list
+-----------------+------------------------------------------+---------------+-------------+--------+--------+
|      NAME       |                   URL                    |   PROTOCOL    |  AUTH TYPE  | PUBLIC | STATIC |
+-----------------+------------------------------------------+---------------+-------------+--------+--------+
| images          | https://images.linuxcontainers.org       | simplestreams | none        | YES    | NO     |
| local (current) | unix://                                  | lxd           | file access | NO     | YES    |
| ubuntu          | https://cloud-images.ubuntu.com/releases | simplestreams | none        | YES    | YES    |
+-----------------+------------------------------------------+---------------+-------------+--------+--------+

$ lxc image list images: ubuntu/22.04 amd64 | head
+-------------------------------+--------------+--------+-------------------------------+--------------+-----------+----------+
|             ALIAS             | FINGERPRINT  | PUBLIC |          DESCRIPTION           | ARCHITECTURE |   TYPE    |   SIZE   |
+-------------------------------+--------------+--------+-------------------------------+--------------+-----------+----------+
| ubuntu/22.04 (7 more)         | c9f6f3a4d1e2 | yes    | Ubuntu jammy amd64 (2026...)  | x86_64       | CONTAINER | 118.44MB |
+-------------------------------+--------------+--------+-------------------------------+--------------+-----------+----------+
```

### 5.3 Lanzar, listar, inspeccionar, exec

```bash
$ lxc launch images:ubuntu/22.04 web1
Creating web1
Starting web1

$ lxc list
+------+---------+---------------------+------------------------------------------------+-----------+-----------+
| NAME |  STATE  |         IPV4        |                     IPV6                       |   TYPE    | SNAPSHOTS |
+------+---------+---------------------+------------------------------------------------+-----------+-----------+
| web1 | RUNNING | 10.152.1.113 (eth0) | fd42:...:1:216:3eff:fe8a:1c2d (eth0)           | CONTAINER | 0         |
+------+---------+---------------------+------------------------------------------------+-----------+-----------+

$ lxc info web1 | head -n 14
Name: web1
Status: RUNNING
Type: container
Architecture: x86_64
PID: 24817
Created: 2026/08/11 14:03 UTC
Last Used: 2026/08/11 14:03 UTC
Resources:
  Processes: 21
  CPU usage:
    CPU usage (in seconds): 3
  Memory usage:
    Memory (current): 78.44MiB
  Network usage: ...

$ lxc exec web1 -- bash
root@web1:~# ps -p 1 -o comm=
systemd                       # PID 1 is a full init — this is a *system* container
root@web1:~# exit

$ lxc exec web1 -- systemctl is-system-running
running
```

### 5.4 Archivos, config, snapshots, imágenes

```bash
$ echo "hello" > note.txt
$ lxc file push note.txt web1/root/note.txt
$ lxc file pull web1/etc/hostname -
web1

$ lxc config set web1 limits.memory 1GiB
$ lxc config device override web1 root size=8GiB     # per-instance disk quota
$ lxc config show web1 | sed -n '1,18p'
architecture: x86_64
config:
  image.description: Ubuntu jammy amd64
  limits.memory: 1GiB
  volatile.eth0.hwaddr: 00:16:3e:8a:1c:2d
devices:
  root:
    path: /
    pool: default
    size: 8GiB
    type: disk
ephemeral: false
profiles:
- default

$ lxc snapshot web1 pre-upgrade
$ lxc info web1 | grep -A3 Snapshots
Snapshots:
  pre-upgrade (taken at 2026/08/11 14:07 UTC) (stateless)

$ lxc restore web1 pre-upgrade            # roll back
$ lxc publish web1/pre-upgrade --alias web-golden
Publishing instance: Instance published with fingerprint: 3b1f...e07a
$ lxc launch web-golden web2              # clone from your own image
```

### 5.5 Aplicar profiles y límites de recursos

```bash
$ lxc profile create webtier
$ lxc profile edit webtier < webtier.yaml       # (§4.2)
$ lxc profile add web1 webtier                   # stack it on top of default
$ lxc profile assign web1 default,webtier        # or set the exact ordered list

# Verify limits actually landed in the cgroup:
$ lxc exec web1 -- cat /sys/fs/cgroup/memory.max
1073741824
$ lxc exec web1 -- nproc
2
```

### 5.6 Gestión de networking y almacenamiento

```bash
$ lxc network list
+--------+----------+---------+----------------+------+-------------+---------+
|  NAME  |   TYPE   | MANAGED |      IPV4       | ...  | DESCRIPTION | USED BY |
+--------+----------+---------+----------------+------+-------------+---------+
| eth0   | physical | NO      |                |      |             | 0       |
| lxdbr0 | bridge   | YES     | 10.152.1.1/24  |      |             | 2       |
+--------+----------+---------+----------------+------+-------------+---------+

# Give a container a real LAN presence via macvlan (overrides the profile NIC):
$ lxc config device add web1 eth0 nic nictype=macvlan parent=eth0
$ lxc restart web1

$ lxc storage list
+---------+--------+--------------------------------------+-------------+---------+---------+
|  NAME   | DRIVER |               SOURCE                 | DESCRIPTION | USED BY |  STATE  |
+---------+--------+--------------------------------------+-------------+---------+---------+
| default | zfs    | tank/lxd                             |             | 4       | CREATED |
+---------+--------+--------------------------------------+-------------+---------+---------+

$ lxc storage create fast btrfs source=/dev/nvme1n1
$ lxc launch images:alpine/3.20 cache1 --storage fast
```

### 5.7 Nesting (ejecutar contenedores dentro de contenedores)

El nesting está explícitamente en el examen. Es necesario para ejecutar Docker o un LXD/systemd-en-contenedor anidado que a su vez crea namespaces.

```bash
$ lxc launch images:ubuntu/22.04 ci-runner -c security.nesting=true
Creating ci-runner
Starting ci-runner

$ lxc exec ci-runner -- bash -c '
    apt-get update -qq && apt-get install -y -qq docker.io >/dev/null
    systemctl start docker
    docker run --rm hello-world | grep "Hello from Docker"'
Hello from Docker!
```

Sin `security.nesting=true`, el runtime interno no puede crear namespaces de user/mount y falla. Combinalo con `security.syscalls.intercept.mknod=true` / `security.syscalls.intercept.mount=*` para cargas de trabajo internas específicas que necesitan nodos de dispositivo o montajes.

### 5.8 Ciclo de vida de bajo nivel con liblxc (sin LXD)

```bash
$ lxc-create -n legacy -t download -- -d debian -r bookworm -a amd64
Using image from local cache
Unpacking the rootfs
...
$ lxc-start -n legacy -d
$ lxc-ls -f
NAME   STATE   AUTOSTART GROUPS IPV4        IPV6 UNPRIVILEGED
legacy RUNNING 0         -      10.0.3.42   -    true
$ lxc-info -n legacy
Name:           legacy
State:          RUNNING
PID:            30122
IP:             10.0.3.42
CPU use:        0.44 seconds
Memory use:     22.10 MiB
$ lxc-attach -n legacy -- cat /etc/debian_version
12.6
$ lxc-stop -n legacy && lxc-destroy -n legacy
```

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Triage de primera línea: el log del contenedor

`lxc info --show-log` es el comando más valioso cuando una instancia no arranca o muere inmediatamente. Expone el log de liblxc que el daemon capturó.

```bash
$ lxc start web1
Error: Failed to run: ... : exit status 1
Try `lxc info --show-log web1` for more info

$ lxc info --show-log web1
Name: web1
Status: STOPPED
...
Log:
lxc web1 ERROR    conf - conf.c:lxc_map_ids: newuidmap failed to write mapping
lxc web1 ERROR    start - start.c:lxc_spawn: failed to set up id mapping
```

Esa firma significa que el **idmap está roto** → revisá en `/etc/subuid` y `/etc/subgid` los rangos de `root`/`lxd` y que `newuidmap`/`newgidmap` estén instalados setuid (paquete `uidmap`).

### 6.2 Flujo de eventos en vivo y de errores de la API

```bash
$ lxc monitor --type=lifecycle,logging
metadata:
  action: instance-started
  source: /1.0/instances/web1
timestamp: "2026-08-11T14:31:07Z"
type: lifecycle
```

Subí la verbosidad del daemon cuando la propia capa REST es sospechosa:

```bash
$ sudo snap set lxd daemon.debug=true && sudo systemctl reload snap.lxd.daemon
$ sudo journalctl -u snap.lxd.daemon -f --no-hostname
```

### 6.3 Checklist de diagnóstico por síntoma

| Síntoma | Primeras comprobaciones | Causa probable / solución |
|---|---|---|
| El contenedor no arranca, `newuidmap failed` | `cat /etc/subuid /etc/subgid`; `dpkg -l uidmap` | Rango de idmap faltante/demasiado chico; instalá `uidmap`; asegurá que esté presente `root:1000000:...` |
| El contenedor unprivileged arranca pero los archivos aparecen «owned by nobody/65534» | `lxc config get c1 raw.idmap`; `ls -n` en el rootfs en el host | Desajuste de idmap entre la propiedad del FS del host y el mapa del contenedor; alineá `raw.idmap` |
| El Docker/LXD anidado falla dentro de un contenedor | `lxc config get c1 security.nesting` | Poné `security.nesting=true`; puede que también necesites `security.syscalls.intercept.*` |
| El límite de memoria «se ignora», OOM en el host en su lugar | `lxc exec c1 -- cat /sys/fs/cgroup/memory.max`; `limits.memory.enforce` | cgroup v1 vs v2; poné `limits.memory.enforce=hard`; confirmá que el host esté en cgroup v2 |
| Sin IPv4 en el contenedor | `lxc network show lxdbr0`; `lxc exec c1 -- ip a` | dnsmasq/DHCP apagado o `ipv4.dhcp=false`; NIC no conectada; firewall del host en conflicto |
| La cuota de disco `size=` es rechazada | `lxc storage show default` | Las cuotas necesitan zfs/btrfs/lvm; el pool `dir` no puede imponer tamaño |
| El contenedor no tiene alcance a la LAN pero tiene IP | NAT de bridge vs macvlan | El bridge tiene NAT (esperado); cambiá a `macvlan`/`bridged` para presencia L2 en la LAN |

### 6.4 Verificar que el aislamiento y los límites son reales (no solo configurados)

```bash
# cgroup v2 must be the host's hierarchy for modern limit keys:
$ stat -fc %T /sys/fs/cgroup
cgroup2fs

# Prove the memory cap is enforced in-kernel, not just declared:
$ lxc config get web1 limits.memory
1GiB
$ lxc exec web1 -- cat /sys/fs/cgroup/memory.max
1073741824

# Prove unprivileged mapping: container root is an unprivileged host uid:
$ lxc exec web1 -- id -u          # inside: 0
0
$ ps -o uid,pid,comm -p $(lxc info web1 | awk '/PID:/{print $2}')
  UID     PID COMMAND
1000000  24817 systemd            # on the host: mapped, unprivileged

# Confirm AppArmor confinement is active for the instance:
$ sudo aa-status | grep lxd | head
   lxd-web1_</var/snap/lxd/common/lxd> (enforce)
```

### 6.5 Comprobaciones cruzadas de almacenamiento y red

```bash
$ lxc storage info default
info:
  description: ""
  driver: zfs
  name: default
  space used: 1.84GiB
  total space: 30.00GiB
used by:
  instances:
  - web1
  - web2

$ lxc network show lxdbr0 | sed -n '1,10p'
config:
  ipv4.address: 10.152.1.1/24
  ipv4.nat: "true"
  ipv6.address: none
name: lxdbr0
type: bridge
used_by:
- /1.0/instances/web1
```

Si la resolución DNS entre contenedores falla, confirmá que el dnsmasq del bridge gestionado esté sirviendo el `dns.domain` y que `resolv.conf` dentro del contenedor apunte al gateway del bridge (`10.152.1.1`).

---

## 7. Referencias

- LPI — Objetivos del examen 305-300 (Tema 352.2 LXC): https://www.lpi.org/our-certifications/exam-305-objectives/
- LinuxContainers — Documentación de LXC (liblxc, herramientas `lxc-*`, configuración): https://linuxcontainers.org/lxc/documentation/
- LinuxContainers — Referencia de configuración de contenedores LXC (`lxc.container.conf`): https://linuxcontainers.org/lxc/manpages/man5/lxc.container.conf.5.html
- Canonical — Documentación de LXD (arquitectura, REST API, instancias): https://documentation.ubuntu.com/lxd/
- Canonical LXD — Configuración de instancias y límites (`limits.cpu`, `limits.memory`, devices): https://documentation.ubuntu.com/lxd/en/latest/reference/instance_options/
- Canonical LXD — Seguridad, contenedores unprivileged, idmaps y nesting: https://documentation.ubuntu.com/lxd/en/latest/explanation/security/
- Canonical LXD — Storage pools y drivers: https://documentation.ubuntu.com/lxd/en/latest/explanation/storage/
- Canonical LXD — Networking y redes gestionadas: https://documentation.ubuntu.com/lxd/en/latest/explanation/networks/
- LinuxContainers — Documentación de Incus (fork comunitario de LXD): https://linuxcontainers.org/incus/docs/main/
- Kernel de Linux — panorama de namespaces: https://man7.org/linux/man-pages/man7/namespaces.7.html
- Kernel de Linux — cgroups v2: https://docs.kernel.org/admin-guide/cgroup-v2.html
- `subuid(5)` / `subgid(5)` — rangos subordinados de uid/gid: https://man7.org/linux/man-pages/man5/subuid.5.html