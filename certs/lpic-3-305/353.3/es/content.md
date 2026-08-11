# Tema 353.3 — cloud-init

**Certificación:** LPIC-3 305 · **Examen:** 305-300 (versión 3.0) · **Peso:** 5.0
**Perfil:** Principal Platform Architect / SRE Senior — provisioning declarativo de VMs a partir de cloud images.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1. La tensión entre "golden image" y configuración tardía

Cuando operás flotas de cientos o miles de VMs efímeras (autoscaling groups, nodos de un cluster, runners de CI, VMs de laboratorio reprovisionadas cada noche), tenés dos maneras extremas de resolver la configuración de arranque, y ambas son malas si las llevás al límite:

- **Todo horneado en la imagen (Packer puro, tema 353.2):** cada variante de configuración (hostname, IP, claves SSH, rol, secretos) exige una imagen distinta. Con 3 entornos × 4 roles × 2 versiones ya tenés 24 imágenes que mantener, versionar y volver a hornear ante cualquier cambio trivial. La imagen deja de ser genérica.
- **Todo por configuration management post-boot (Ansible push):** la imagen es genérica, pero necesitás conectividad, inventario, credenciales y un plano de control externo *antes* de que la VM sea siquiera alcanzable. Hay un huevo-y-gallina: para configurar la red con Ansible necesitás red, y la red es justamente lo que falta configurar.

`cloud-init` ocupa el hueco exacto entre esos dos: es el **first-boot provisioner** que corre *dentro* de la VM, *antes* de que exista cualquier plano de control externo, y que consume su configuración de un **datasource** — un canal fuera de banda (disco adjunto, metadata HTTP del hypervisor/cloud, SMBIOS). Esto habilita el patrón que hoy es estándar de facto:

> **Una sola golden image genérica + late binding de la configuración por instancia.**

La imagen (construida con Packer) contiene el SO, el agente y `cloud-init`; la *identidad* de cada VM (red, hostname, usuarios, claves, paquetes, comandos) se inyecta en el momento del arranque vía `user-data`. Packer construye; cloud-init *especializa*. No compiten: se encadenan.

### 1.2. Por qué esto importa para SRE

- **Reproducibilidad e idempotencia:** el `user-data` es un artefacto declarativo versionable en Git. La misma cloud image + el mismo `user-data` producen la misma VM. cloud-init cachea el `instance-id` y **no vuelve a ejecutar** los módulos *once-per-instance* en reboots, evitando que un `runcmd` de "crear DB" corra dos veces.
- **Portabilidad multi-cloud:** el mismo `#cloud-config` funciona en EC2, OpenStack, Azure, GCE, libvirt/KVM (NoCloud) porque cloud-init abstrae el origen de los datos detrás del concepto de **datasource**. Cambiás de proveedor sin reescribir la lógica de provisioning.
- **Zero-touch:** ninguna intervención manual, ninguna conexión SSH interactiva de bootstrap. Requisito para autoscaling real.

### 1.3. El "cheat sheet" arquitectónico

```
                 BUILD TIME                      BOOT TIME (first boot)
   ┌───────────────────────────┐     ┌────────────────────────────────────┐
   │  Packer / distro cloudimg │     │  cloud-init                         │
   │  - SO base + agente       │ ──▶ │  lee datasource ──▶ aplica user-data│
   │  - cloud-init instalado   │     │  red, hostname, users, ssh, pkgs,   │
   │  - imagen GENÉRICA        │     │  write_files, runcmd, power_state   │
   └───────────────────────────┘     └────────────────────────────────────┘
        artefacto inmutable                identidad por-instancia
```

---

## 2. Comparativas técnicas (trade-offs)

### 2.1. cloud-init frente a las alternativas de first-boot provisioning

| Dimensión | **cloud-init** | **Ignition** (FCOS/RHCOS/Flatcar) | **Config mgmt push** (Ansible) | **Baked-in** (Packer solo) |
|---|---|---|---|---|
| Momento de ejecución | Boot (multi-etapa, puede repetir por-boot) | Una sola vez, en el **initramfs**, antes del pivot_root | Post-boot, requiere red y control plane | Build time |
| Modelo | Mayormente imperativo + módulos declarativos | Estrictamente declarativo (JSON), atómico | Imperativo (playbooks) | N/A |
| Reintentos / re-run | Sí (frecuencias per-boot / per-instance / once) | No: si falla, la máquina no bootea (fail-safe by design) | Sí (idempotencia de módulos) | N/A |
| Dependencia de red externa | No (datasource local posible) | No | **Sí** (huevo-y-gallina) | No |
| Portabilidad multi-cloud | **Alta** (datasources) | Media (necesita Afterburn para metadata) | Alta | Baja (imagen por variante) |
| Superficie / peso | Grande, Python, muchos módulos | Mínima, Go, un binario | Externo a la VM | Cero en runtime |
| Distros objetivo | Ubuntu, Debian, RHEL/Rocky/Alma, SUSE, Amazon Linux… | Solo distros CoreOS-like | Cualquiera | Cualquiera |
| Falla de configuración | VM arranca "a medias", diagnosticable en vivo | VM **no arranca** (más seguro, menos flexible) | VM arranca genérica | N/A |

**Lectura de arquitecto:** Ignition es más seguro (falla cerrado) pero rígido y acotado a CoreOS; cloud-init es más flexible y universal a costa de fallar "abierto" (podés terminar con una VM medio configurada que hay que diagnosticar). Para el examen y para el 90% de las flotas Linux tradicionales, cloud-init es la respuesta.

### 2.2. Datasources principales

El datasource es *de dónde* cloud-init obtiene `meta-data`, `user-data`, `vendor-data` y `network-config`.

| Datasource | Entorno típico | Canal de transporte | Detección |
|---|---|---|---|
| **NoCloud** | KVM/libvirt, bare-metal, labs, VirtualBox | Disco/ISO con label `cidata`/`CIDATA`, `ds=nocloud` en cmdline, SMBIOS serial, `seedfrom` HTTP | `ds-identify` por label o cmdline |
| **ConfigDrive** | OpenStack (sin metadata service) | Disco con label `config-2` | Por label |
| **OpenStack** | OpenStack | HTTP `169.254.169.254` + ConfigDrive | Por chassis/DMI |
| **EC2** | AWS y compatibles | IMDS `http://169.254.169.254/latest/` | DMI / metadata |
| **Azure** | Azure | IMDS + agente / OVF en CD-ROM | DMI |
| **GCE** | Google Cloud | Metadata server con header `Metadata-Flavor: Google` | DMI |
| **OVF** | VMware / vSphere | Propiedades OVF en el guestinfo/CD | DMI |
| **None** | Fallback | — | Última opción, no hace nada útil |

**NoCloud** es el datasource que el examen exige dominar a fondo porque es el único totalmente offline y controlable en un lab (KVM/QEMU/VirtualBox). Es el objeto de estudio central de la sección 5 de este material.

### 2.3. Formatos de `user-data`

cloud-init inspecciona la **primera línea** del `user-data` para decidir cómo procesarlo:

| Cabecera / magic | Tipo MIME | Uso |
|---|---|---|
| `#cloud-config` | `text/cloud-config` | YAML declarativo con módulos (el 95% de los casos) |
| `#!/bin/sh`, `#!/usr/bin/env python3` | `text/x-shellscript` | Script ejecutado en la etapa **final** (una vez por instancia) |
| `#cloud-boothook` | `text/cloud-boothook` | Script ejecutado **muy temprano y en cada boot** |
| `#include` | `text/x-include-url` | Lista de URLs, cada una es a su vez user-data |
| `#part-handler` | `text/part-handler` | Handler Python custom para tipos MIME propios |
| `Content-Type: multipart/mixed` | MIME multipart | Combina varios de los anteriores en un solo payload |
| `\x1f\x8b` (gzip) | binario | Cualquiera de los anteriores comprimido (payload grande) |

### 2.4. `user-data` vs `vendor-data` vs `meta-data`

| Archivo | Quién lo provee | Contenido | Precedencia |
|---|---|---|---|
| `meta-data` | Plataforma / operador | `instance-id`, `local-hostname`, red opcional | Identidad de la instancia |
| `user-data` | **El usuario final** | `#cloud-config`, scripts | Gana ante conflicto |
| `vendor-data` | **El proveedor de la nube** | Configuración por defecto del proveedor (agentes, mirrors) | Se ejecuta *antes* que user-data; el usuario puede deshabilitarla |
| `network-config` | Plataforma / operador | v1 o v2 (netplan-like) | Aplicada en etapa local |

---

## 3. El proceso de arranque de cloud-init (mecánica interna)

cloud-init se descompone en **cinco fases**, orquestadas por systemd. Entender el ordering es lo que separa aprobar de reprobar el objetivo, y diagnosticar de adivinar.

### 3.1. Fases y unidades systemd

| # | Fase | Unidad systemd | Comando subyacente | Ordering clave | Qué hace |
|---|---|---|---|---|---|
| 0 | **Generator** | `cloud-init-generator` (generator, no service) | — | Antes de todo | Decide si cloud-init debe correr; crea/borra el symlink que activa el target |
| 1 | **Local** | `cloud-init-local.service` | `cloud-init init --local` | `Before=network-pre.target`, `DefaultDependencies=no` | Detecta datasource local (NoCloud/ConfigDrive), aplica **network-config** *antes* de levantar la red |
| 2 | **Network** | `cloud-init.service` | `cloud-init init` | `After=` red base, `Before=network-online.target` | Datasources de red, mounts, `disk_setup`, `growpart`, `users`, `ssh`, `bootcmd` (`cloud_init_modules`) |
| 3 | **Config** | `cloud-config.service` | `cloud-init modules --mode=config` | Tras Network | Módulos de `cloud_config_modules`: `packages`, `set_passwords`, `runcmd` (*escribe* el script) |
| 4 | **Final** | `cloud-final.service` | `cloud-init modules --mode=final` | Casi al final del boot | `cloud_final_modules`: `scripts-user` (ejecuta `runcmd`), `phone_home`, `power_state`, `final_message` |

**Punto crítico de timing:** la etapa **Local** corre *antes* de `network-pre.target` justamente para poder escribir la configuración de red que la red va a usar. Si tu datasource solo se detecta por HTTP (metadata service), la configuración de red debe venir de otro lado (DHCP efímero), porque en la etapa Local todavía no hay red. Este es el motivo por el que NoCloud con `network-config` es tan robusto: todo es local.

### 3.2. Semántica de frecuencia de módulos

Cada módulo se ejecuta con una de tres frecuencias, controlada por **semáforos** en `/var/lib/cloud/instance/sem/` y `/var/lib/cloud/sem/`:

| Frecuencia (config key) | Semáforo | Cuándo corre | Ejemplo |
|---|---|---|---|
| `once-per-instance` (default) | `/var/lib/cloud/instance/sem/config_<mod>` | Una vez por `instance-id`; **reboot no lo repite** | `runcmd`, `users`, `packages` |
| `always` | ninguno (corre siempre) | **Cada boot** | `bootcmd`, `scripts-per-boot`, `mounts` |
| `once` | `/var/lib/cloud/sem/config_<mod>` | Una sola vez en la vida de la VM (no por-instancia) | `scripts-per-once` |

**Consecuencia operativa clave:** cloud-init identifica una "instancia nueva" por el `instance-id` del `meta-data`. Si clonás una VM o cambiás el `user-data` pero *no* cambiás el `instance-id`, cloud-init cree que ya está provisionada y **no reaplica** los módulos once-per-instance. Para forzar re-ejecución hay dos caminos: cambiar el `instance-id`, o `cloud-init clean` (sección 6).

### 3.3. Layout del filesystem

```
/etc/cloud/
├── cloud.cfg                 # config principal: datasource_list, listas de módulos, system_info
├── cloud.cfg.d/              # drop-ins (ganan sobre cloud.cfg)
│   ├── 05_logging.cfg
│   ├── 90_dpkg.cfg           # p.ej. datasource_list: [ NoCloud, ConfigDrive, None ]
│   └── 99-installer.cfg
└── templates/                # plantillas: hosts.debian.tmpl, resolv.conf.tmpl, etc.

/var/lib/cloud/               # estado PERSISTENTE
├── data/
│   ├── instance-id           # instance-id actual
│   ├── previous-instance-id
│   ├── result.json           # {"errors": [], "datasource": "..."}
│   └── status.json
├── instance -> instances/iid-local01   # symlink a la instancia activa
├── instances/<instance-id>/
│   ├── user-data.txt         # user-data crudo
│   ├── user-data.txt.i       # user-data procesado (MIME normalizado)
│   ├── vendor-data.txt
│   ├── cloud-config.txt      # cloud-config renderizado y mergeado
│   ├── obj.pkl               # datasource cacheado (pickle)
│   ├── sem/                  # semáforos once-per-instance
│   └── scripts/              # runcmd, etc.
├── scripts/{per-boot,per-instance,per-once,vendor}/
├── seed/                     # datos "sembrados" para datasources (NoCloud)
└── sem/                      # semáforos "once" (por-máquina)

/run/cloud-init/              # estado VOLÁTIL (se pierde en reboot)
├── ds-identify.log
├── instance-data.json        # metadata renderizada (lo que lee `cloud-init query`)
├── instance-data-sensitive.json
├── result.json
└── status.json

/var/log/
├── cloud-init.log            # log interno detallado (DEBUG)
└── cloud-init-output.log     # stdout/stderr de runcmd, bootcmd, package install
```

---

## 4. Manifiestos completos (sin recortar)

### 4.1. `meta-data` (NoCloud)

```yaml
instance-id: iid-web01-20260811
local-hostname: web01
```

> El `instance-id` es el que gobierna la idempotencia. Cambialo (`iid-web01-20260812`) para forzar re-provisioning completo en la próxima etapa Local.

### 4.2. `user-data` — `#cloud-config` de producción completo

```yaml
#cloud-config
# =====================================================================
#  web01 — nodo web de producción · NoCloud/libvirt
#  Autoría: material LPIC-3 305 · objetivo 353.3
# =====================================================================

hostname: web01
fqdn: web01.corp.example.com
prefer_fqdn_over_hostname: true
manage_etc_hosts: true

# --- Zona horaria y locale ------------------------------------------
timezone: America/Argentina/Buenos_Aires
locale: es_AR.UTF-8

# --- Usuarios y claves ----------------------------------------------
users:
  - default                       # conserva el usuario por defecto de la distro
  - name: sre
    gecos: SRE Operations
    primary_group: sre
    groups: [sudo, adm, systemd-journal]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true             # sin login por password, solo por clave
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIByExampleKeyReplaceMe sre@bastion

groups:
  - sre: [sre]

# --- Password / SSH auth --------------------------------------------
ssh_pwauth: false                 # deshabilita autenticación por password en sshd
chpasswd:
  expire: false
disable_root: true

# Regenerar host keys en primer boot (evita keys duplicadas de la imagen)
ssh_deletekeys: true
ssh:
  emit_keys_to_console: false

# --- Repos y paquetes -----------------------------------------------
package_update: true
package_upgrade: true
packages:
  - nginx
  - jq
  - curl
  - htop
  - chrony
  - unattended-upgrades

# --- NTP -------------------------------------------------------------
ntp:
  enabled: true
  ntp_client: chrony
  servers:
    - 0.ar.pool.ntp.org
    - 1.ar.pool.ntp.org

# --- Comandos tempranos (cada boot, antes que la red) ---------------
bootcmd:
  - [ cloud-init-per, once, disable-thp, sh, -c, "echo never > /sys/kernel/mm/transparent_hugepage/enabled" ]

# --- Archivos escritos declarativamente -----------------------------
write_files:
  - path: /etc/sysctl.d/60-network-tuning.conf
    owner: root:root
    permissions: '0644'
    content: |
      net.core.somaxconn = 4096
      net.ipv4.tcp_tw_reuse = 1
      net.ipv4.ip_local_port_range = 1024 65535

  - path: /etc/nginx/conf.d/health.conf
    permissions: '0644'
    content: |
      server {
          listen 8080;
          location = /healthz { return 200 "ok\n"; add_header Content-Type text/plain; }
      }

  # Contenido binario/comprimido via base64
  - path: /opt/motd.b64.gz
    encoding: gz+b64
    content: H4sIAAAAAAAAA0vLz1cozy/KSVFIzs8rSc0rAQCFEUoNDwAAAA==
    permissions: '0644'

  # Escrito en la etapa FINAL (defer) porque depende de paquetes ya instalados
  - path: /etc/profile.d/99-banner.sh
    defer: true
    permissions: '0755'
    content: |
      #!/bin/sh
      echo "Nodo provisionado por cloud-init $(cloud-init --version 2>/dev/null | awk '{print $2}')"

# --- Comandos finales (una vez por instancia, red ya arriba) --------
runcmd:
  - [ sysctl, --system ]
  - [ systemctl, enable, --now, nginx ]
  - [ nginx, -t ]
  - "curl -fsS http://127.0.0.1:8080/healthz || echo 'HEALTHCHECK FAILED' >&2"

# --- Callback de provisioning al control plane ----------------------
phone_home:
  url: https://provisioning.corp.example.com/callback/$INSTANCE_ID/
  post:
    - instance_id
    - hostname
    - fqdn
    - pub_key_ed25519
  tries: 5

# --- Mensaje final y política de energía ----------------------------
final_message: "cloud-init OK · $INSTANCE_ID · uptime $UPTIME s · versión $VERSION"

power_state:
  mode: reboot
  message: "Reboot post-provisioning para aplicar sysctl/THP"
  timeout: 30
  condition: true
```

### 4.3. `network-config` — formato v2 (netplan-like, recomendado)

```yaml
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:12:34:56"
    set-name: eth0
    dhcp4: false
    dhcp6: false
    addresses:
      - 192.168.122.10/24
      - "fd00:122::10/64"
    routes:
      - to: default
        via: 192.168.122.1
    nameservers:
      addresses: [1.1.1.1, 9.9.9.9]
      search: [corp.example.com]
```

### 4.4. `network-config` — formato v1 (equivalente, más verboso)

```yaml
version: 1
config:
  - type: physical
    name: eth0
    mac_address: "52:54:00:12:34:56"
    subnets:
      - type: static
        address: 192.168.122.10/24
        gateway: 192.168.122.1
        dns_nameservers: [1.1.1.1, 9.9.9.9]
        dns_search: [corp.example.com]
  - type: nameserver
    address: [1.1.1.1]
    search: [corp.example.com]
```

| | **v1** | **v2** |
|---|---|---|
| Estilo | Lista de objetos tipados (`type: physical`) | Mapa por tipo de device (`ethernets:`, `bonds:`, `vlans:`) |
| Compatibilidad | Universal, cualquier renderer | Nativo netplan; se traduce a eni/NM |
| Matching | Por `name`/`mac_address` | `match:` por mac, driver, name + `set-name` |
| Recomendación | Legacy / máxima portabilidad | **Preferido** en distros con netplan (Ubuntu) |

### 4.5. `user-data` MIME multipart (cloud-config + script en un solo payload)

```
Content-Type: multipart/mixed; boundary="===============BOUNDARY=="
MIME-Version: 1.0

--===============BOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0

#cloud-config
packages: [git, make]

--===============BOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0

#!/bin/bash
set -euo pipefail
git clone https://git.corp.example.com/ops/bootstrap.git /opt/bootstrap
/opt/bootstrap/install.sh

--===============BOUNDARY==--
```

Generado con la herramienta oficial (no lo armes a mano en producción):

```bash
$ cloud-init devel make-mime \
    -a cloud-config.yaml:cloud-config \
    -a bootstrap.sh:x-shellscript \
    > user-data
```

---

## 5. Comandos CLI reales y salidas de terminal

### 5.1. Construcción del seed NoCloud y arranque de la VM (KVM/QEMU)

**Opción A — `cloud-localds`** (paquete `cloud-image-utils`, la más simple):

```bash
$ cloud-localds --network-config=network-config.yaml seed.img user-data meta-data
$ file seed.img
seed.img: DOS/MBR boot sector, code offset 0x58+2, ... FAT (12 bit), label: "cidata"
```

**Opción B — `genisoimage`** (portátil; el volid DEBE ser `cidata`):

```bash
$ genisoimage -output seed.iso -volid cidata -joliet -rock \
      user-data meta-data network-config
I: -input-charset not specified, using utf-8 (detected in locale settings)
Total translation table size: 0
Total rockridge attributes bytes: 1618
Total directory bytes: 0
Path table size(bytes): 10
Max brk space used 0
183 extents written (0 MB)
```

**Descarga de la cloud image y creación de un disco con backing file** (no mutar la base):

```bash
$ wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
$ qemu-img create -F qcow2 -b jammy-server-cloudimg-amd64.img -f qcow2 web01.qcow2 20G
Formatting 'web01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off
  compression_type=zlib size=21474836480 backing_file=jammy-server-cloudimg-amd64.img
  backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
```

**Arranque adjuntando el seed como segundo disco** (NoCloud lo detecta por el label `cidata`):

```bash
$ qemu-system-x86_64 \
    -machine accel=kvm,type=q35 -cpu host -m 2048 -smp 2 \
    -nographic \
    -drive if=virtio,format=qcow2,file=web01.qcow2 \
    -drive if=virtio,format=raw,file=seed.img \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56
```

> Alternativa sin disco: sembrar por SMBIOS →
> `-smbios type=1,serial=ds=nocloud;s=http://10.0.0.1:8000/seed/`
> o por kernel cmdline → `ds=nocloud-net;s=http://10.0.0.1:8000/seed/`.

### 5.2. Estado y health

```bash
$ cloud-init status --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Tue, 11 Aug 2026 14:22:31 +0000
detail: DataSourceNoCloud [seed=/dev/vdb][dsmode=net]
errors: []
recoverable_errors: {}
```

En scripts de orquestación, **bloqueá hasta que termine** en vez de dormir a ciegas:

```bash
$ cloud-init status --wait; echo "rc=$?"
....
rc=0
```

Códigos de retorno de `status`: `0` done · `1` error · `2` degraded (recoverable errors) · el `--wait` imprime puntos mientras corre.

### 5.3. Análisis de tiempos de boot (blame)

```bash
$ cloud-init analyze blame
-- Boot Record 01 --
     08.12100s (init-network/config-growpart)
     06.83400s (modules-config/config-apt-configure)
     05.20900s (modules-final/config-package-update-upgrade-install)
     01.44300s (init-network/config-users-groups)
     00.61200s (init-local/search-NoCloud)
     00.08900s (modules-final/config-runcmd)
     00.00700s (modules-final/config-final-message)

1 boot records analyzed
```

```bash
$ cloud-init analyze show | head -n 12
-- Boot Record 01 --
The total time elapsed since completing an event is printed after the "@" character.
The time the event takes is printed after the "+" character.

Starting stage: init-local
|`->no cache found @00.34000s +00.00100s
|`->found local data from DataSourceNoCloud @00.61000s +00.61200s
Finished stage: (init-local) 00.98700 seconds

Starting stage: init-network
|`->restored from cache with run check: DataSourceNoCloud [seed=/dev/vdb] @01.10s +0.05s
```

Correlación con systemd:

```bash
$ systemd-analyze critical-chain cloud-final.service
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

cloud-final.service +5.402s
└─cloud-config.service @18.221s +7.010s
  └─cloud-init.service @9.930s +8.256s
    └─cloud-init-local.service @1.204s +0.985s
      └─systemd-remount-fs.service @0.890s +0.210s
```

### 5.4. Consultar la metadata renderizada (`query`)

```bash
$ cloud-init query --all | jq '{ds: .v1.cloud_name, iid: .v1.instance_id, region: .v1.region, hostname: .v1.local_hostname}'
{
  "ds": "nocloud",
  "iid": "iid-web01-20260811",
  "region": null,
  "hostname": "web01"
}

$ cloud-init query ds.meta_data.instance-id
iid-web01-20260811

$ cloud-init query userdata          # requiere permisos; datos posiblemente sensibles
#cloud-config
hostname: web01
...
```

### 5.5. Validación de esquema *antes* de desplegar (shift-left)

```bash
$ cloud-init schema --config-file user-data --annotate
Valid schema user-data
```

Con un error deliberado (`packages` como string en vez de lista):

```bash
$ cloud-init schema --config-file broken.yaml --annotate
#cloud-config
packages: nginx		# E1
runcmd:
  - echo hi

# Errors: -------------
# E1: 'nginx' is not of type 'array'

Error: Invalid schema: user-data
```

---

## 6. Verificación y diagnóstico de fallas

### 6.1. Ladder de diagnóstico (de barato a caro)

```bash
# 1) ¿Terminó? ¿con errores?
$ cloud-init status --long

# 2) ¿Qué datasource eligió ds-identify y por qué?
$ cat /run/cloud-init/ds-identify.log
$ cloud-init query --all | jq .v1.datasource

# 3) Errores estructurados de la corrida
$ cat /var/lib/cloud/data/result.json
{"v1": {"datasource": "DataSourceNoCloud [seed=/dev/vdb][dsmode=net]", "errors": []}}

# 4) Log interno (nivel DEBUG)
$ grep -iE 'warn|error|traceback' /var/log/cloud-init.log | tail

# 5) Salida real de runcmd/bootcmd/package install
$ tail -n 40 /var/log/cloud-init-output.log
```

### 6.2. Matriz de fallas de producción

| Síntoma | Causa raíz | Diagnóstico | Remediación |
|---|---|---|---|
| "Corrió una vez, no vuelve a aplicar mi nuevo user-data" | `instance-id` sin cambiar → módulos once-per-instance ya marcados en `sem/` | `cloud-init query ds.meta_data.instance-id` compara con `/var/lib/cloud/data/instance-id` | Cambiar `instance-id` **o** `cloud-init clean` |
| "No aplica nada, datasource `None`" | `cidata`/label mal, cmdline sin `ds=`, `datasource_list` restringido | `cat /run/cloud-init/ds-identify.log`; `blkid -t LABEL=cidata` | Corregir volid a `cidata`; agregar el DS a `datasource_list` en `/etc/cloud/cloud.cfg.d/` |
| "El YAML no hace efecto, sin error visible" | `#cloud-config` mal indentado o falta la cabecera mágica en la 1ª línea | `cloud-init schema --config-file` | Validar y corregir; la 1ª línea debe ser exactamente `#cloud-config` |
| "La red no queda como pedí" | network-config aplicado por renderer distinto (eni vs netplan vs NM), o llegó tarde (etapa Network en vez de Local) | `cloud-init query network-config`; `journalctl -u systemd-networkd` | Proveer `network-config` en el seed para que se aplique en etapa **Local** |
| "`runcmd` falló pero status=done" | `runcmd` no aborta el boot; errores van a `-output.log` | `grep -A3 runcmd /var/log/cloud-init-output.log` | Usar `set -euo pipefail` en scripts; chequear rc; considerar `bootcmd` para pre-red |
| "write_files falla porque el dir no existe / paquete no instalado" | orden de etapas: `write_files` corre antes que `packages` | — | `defer: true` para escribir en la etapa **Final** |
| "VM cuelga esperando red / metadata HTTP" | DS de red sin conectividad, timeouts largos | `cloud-init analyze blame` muestra el `search-<DS>` largo | Restringir `datasource_list`; NoCloud local en labs |

### 6.3. Reset limpio para re-testear provisioning (idempotencia forzada)

```bash
$ sudo cloud-init clean --logs --machine-id
$ ls /var/lib/cloud/instances/
$          # vacío: se borró el estado por-instancia y los logs

# Re-ejecutar sin reboot completo (útil en dev, no reproduce el boot real):
$ sudo cloud-init init --local && sudo cloud-init init \
    && sudo cloud-init modules --mode=config \
    && sudo cloud-init modules --mode=final

# O directamente reprovisionar en el próximo arranque:
$ sudo cloud-init clean --logs --reboot
```

- `--logs` borra `/var/log/cloud-init*.log`.
- `--machine-id` limpia el machine-id (evita duplicados en clones).
- `--seed` borra también `/var/lib/cloud/seed`.

### 6.4. Ejecutar un solo módulo (aislamiento de fallas)

```bash
$ sudo cloud-init single --name write_files --frequency always
Cloud-init v. 24.x running 'single' module write_files ...
```

### 6.5. Recolección de logs para soporte / postmortem

```bash
$ sudo cloud-init collect-logs
Wrote /home/sre/cloud-init.tar.gz
$ tar tzf cloud-init.tar.gz | head
cloud-init-logs-2026-08-11/
cloud-init-logs-2026-08-11/cloud-init.log
cloud-init-logs-2026-08-11/cloud-init-output.log
cloud-init-logs-2026-08-11/dmesg.txt
cloud-init-logs-2026-08-11/journal.txt
cloud-init-logs-2026-08-11/run/
cloud-init-logs-2026-08-11/version
```

### 6.6. Deshabilitar cloud-init deliberadamente

Tres mecanismos, evaluados por el **Generator** en la etapa 0:

```bash
# a) archivo centinela
$ sudo touch /etc/cloud/cloud-init.disabled

# b) kernel cmdline
#   ... cloud-init=disabled

# c) systemd mask (más agresivo)
$ sudo systemctl mask cloud-init.service cloud-init-local.service \
    cloud-config.service cloud-final.service
```

---

## Referencias

- Objetivos oficiales del examen LPI 305-300 (versión 3.0): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Documentación oficial de cloud-init (proyecto Canonical/upstream): <https://cloudinit.readthedocs.io/en/latest/>
- Referencia de módulos de cloud-config: <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>
- Ejemplos de cloud-config: <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>
- Formatos de user-data: <https://cloudinit.readthedocs.io/en/latest/explanation/format.html>
- Etapas del boot (boot stages): <https://cloudinit.readthedocs.io/en/latest/explanation/boot.html>
- Datasources (índice general): <https://cloudinit.readthedocs.io/en/latest/reference/datasources.html>
- Datasource NoCloud: <https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html>
- Formato de network-config v1: <https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v1.html>
- Formato de network-config v2: <https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html>
- CLI de cloud-init (`status`, `analyze`, `query`, `schema`, `clean`): <https://cloudinit.readthedocs.io/en/latest/reference/cli.html>
- Directorios y archivos de instancia (`/var/lib/cloud`): <https://cloudinit.readthedocs.io/en/latest/reference/directory_layout.html>
- Ubuntu cloud images (imágenes base para labs NoCloud): <https://cloud-images.ubuntu.com/>
- `cloud-localds` / cloud-image-utils: <https://manpages.ubuntu.com/manpages/noble/man1/cloud-localds.1.html>