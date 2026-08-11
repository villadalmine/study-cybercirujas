# Tema 353.4 — Vagrant

**LPIC-3 305-300 (Versión de examen 3.0) · Peso del objetivo: 5**

> Áreas de conocimiento clave evaluadas: arquitectura y conceptos de Vagrant (box, provider, Vagrantfile); obtención de boxes desde Vagrant Cloud; gestión de un proyecto y su `Vagrantfile` (provisioning + networking); el ciclo de vida de la máquina; entornos multi-máquina. Utilidades: `Vagrantfile`, `vagrant` (`init`, `up`, `halt`, `destroy`, `suspend`, `resume`, `provision`, `reload`, `status`, `global-status`, `box`, `ssh`, `ssh-config`), Vagrant box, providers (**libvirt** y VirtualBox), provisioners (**file** y **shell**).

---

## 1. El problema de producción: la deriva de entornos como modo de fallo de primer orden

El fallo que aborda este objetivo no es "cómo arranco una VM" — es el **no-determinismo del entorno**. Tres incidentes concretos de producción se corresponden con él:

1. **Latencia de onboarding.** Un SRE nuevo pasa un día ensamblando a mano una réplica local de las dependencias de un servicio (un kernel específico, un bridge de `libvirt`, tres servicios de datos en IPs fijas). La réplica está sutilmente mal, así que el primer bug que reporta es un fantasma.
2. **"Funciona en mi máquina."** Un cambio pasa localmente y falla en CI porque el box local tenía un paquete que la imagen base no trae. El delta es invisible porque el entorno local nunca fue *descrito*, solo *acumulado*.
3. **Reproducibilidad de topologías de prueba.** Necesitás reproducir un split-brain de un clúster de 3 nodos. Hacerlo haciendo clic en la GUI de un hipervisor no es reproducible ni revisable.

La respuesta de Vagrant es hacer del **entorno de desarrollo/prueba un artefacto versionado**: un único `Vagrantfile` (un DSL en Ruby, pero normalmente leído de forma declarativa) que un **provider** de hipervisor materializa a partir de un **box** inmutable, y luego lleva a un estado conocido con **provisioners**. `git clone && vagrant up` reemplaza el día de ensamblado manual, y el diff de un `Vagrantfile` es una declaración revisable de "el entorno cambió".

### Dónde se sitúa Vagrant en el toolchain

Vagrant es una **capa de orquestación para máquinas virtuales efímeras, locales/CI**. Deliberadamente *no* es un constructor de imágenes de máquina, *no* es un provisionador de nube y *no* es un motor de configuración dentro del guest — delega cada una de esas tareas:

```
         author (Packer)                run/CI (Vagrant)              deploy (Terraform)
   ┌───────────────────────┐     ┌──────────────────────────┐   ┌──────────────────────┐
   │ golden image / box    │ ──► │ ephemeral dev/test VMs    │   │ long-lived cloud infra│
   │ metadata.json + img   │     │ Vagrantfile + provider    │   │ *.tf + state         │
   └───────────────────────┘     └──────────────────────────┘   └──────────────────────┘
                                          │ provisioner (shell/file/ansible)
                                          ▼
                                  cloud-init / Ansible / scripts (in-guest state)
```

**Modelo mental:** *Packer hornea, Vagrant ejecuta, Terraform despliega, cloud-init/Ansible convergen.* Packer (Objetivo 353.2) y Vagrant comparten el concepto de box desde extremos opuestos — Packer emite boxes, Vagrant los consume.

### Arquitectura: las cinco piezas móviles

| Componente | Qué es | Dónde vive |
|---|---|---|
| **Vagrantfile** | DSL de Ruby que describe el entorno; se encuentra recorriendo hacia arriba el árbol de directorios | raíz del proyecto |
| **Box** | Imagen base inmutable, específica del provider, + metadata, versionada | `~/.vagrant.d/boxes/` |
| **Provider** | Plugin que traduce la máquina abstracta en una llamada al hipervisor | `libvirt`, `virtualbox`, `docker`, … |
| **Provisioner** | Se ejecuta *después* del boot para converger el guest a un estado deseado | `shell`, `file`, `ansible`, … |
| **Synced folder** | Directorio compartido host↔guest (por defecto `.` → `/vagrant`) | NFS / rsync / virtiofs / 9p / VirtualBox |

El estado de runtime por proyecto (el provider de la máquina, su ID, la clave SSH generada) vive en `.vagrant/`, junto al `Vagrantfile`. Ese directorio es descartable y pertenece al `.gitignore`; el `Vagrantfile` es la fuente de verdad.

El ciclo de vida es una pequeña máquina de estados:

```
   not_created ──vagrant up──► running ──vagrant halt──► poweroff
        ▲                        │  ▲                        │
        │                  suspend│  │resume            up   │
        │                        ▼  │                        │
        └────vagrant destroy──── saved ◄────────────────────┘
                    (from any state)     vagrant reload = halt + up (re-reads Vagrantfile)
```

---

## 2. Arquitectura de providers: libvirt vs VirtualBox (los dos providers en los que se enfoca el examen)

Un **provider** es un plugin que expone un contrato uniforme (`create`, `up`, `halt`, `destroy`, info de SSH, cableado de synced-folder) de modo que el *mismo* `Vagrantfile` corre sobre distintos hipervisores. El examen nombra **libvirt** y **VirtualBox** específicamente; en una plataforma Linux estos son arquitectónicamente muy diferentes.

**VirtualBox** es un hipervisor de Tipo 2: proceso en espacio de usuario (`VBoxHeadless`) más módulos de kernel (`vboxdrv`), gestionado mediante la CLI `VBoxManage`. Es multiplataforma y el histórico default de Vagrant, pero es propietario, lento en relación a KVM e incómodo en Linux moderno con secure-boot (módulos sin firmar).

**libvirt** (vía `vagrant-libvirt`) maneja **QEMU/KVM** — virtualización acelerada por hardware, de estilo Tipo 1, a través de `/dev/kvm`. Es la opción de grado producción en Linux: rendimiento casi nativo, dispositivos paravirtualizados `virtio`, integración con el mismo stack de `libvirt` que usás en el Objetivo 351.4, y sin módulos de kernel de terceros. Su costo es ser solo-Linux y una configuración más pesada (compilación del plugin, grupo `libvirt`/polkit, networking).

### 2.1 Matriz de trade-offs entre providers

| Dimensión | **libvirt (KVM/QEMU)** | **VirtualBox** | **docker** | **vmware_desktop** |
|---|---|---|---|---|
| Tipo de hipervisor | Tipo-1-ish (KVM en el kernel) | Tipo-2 | Container (no una VM) | Tipo-2 |
| Rendimiento | Casi nativo, `virtio` | Moderado | Nativo (kernel compartido) | Alto |
| SO del host | Solo Linux | Linux/macOS/Windows | Linux (o vía VM) | Linux/macOS/Windows |
| Módulos de kernel | `kvm`, `kvm_intel/amd` (in-tree) | `vboxdrv` (out-of-tree, DKMS) | ninguno | propietarios |
| Nested virt | `cpu_mode=host-passthrough` + `nested=true` | limitado | n/a | soportado |
| Networking | libvirt networks, bridges, `virtio-net` | NAT + host-only | container nets | vmnet |
| Synced folder por defecto | NFS/rsync/virtiofs/9p (hay que elegir) | VirtualBox shared folders | bind mount | HGFS |
| Licenciamiento | Open source (LGPL/GPL) | Base GPLv3, Ext Pack propietario | Apache 2.0 | comercial |
| Costo de setup | Alto (build del plugin, polkit) | Bajo | Bajo | Licencia |
| Fidelidad de producción frente a KVM/cloud real | **Alta** | Baja | Media | Media |

**Regla práctica para esta certificación:** en una workstation SRE con Linux, usá **libvirt**; reservá VirtualBox para boxes multiplataforma o cuando un box solo trae un provider `virtualbox`.

### 2.2 Los boxes son específicos del provider

Un box se construye *para* un provider. `generic/ubuntu2204` trae imágenes tanto `libvirt` como `virtualbox`; `ubuntu/jammy64` (Canonical) trae **solo** `virtualbox`. Pedir un provider que un box no publica es el fallo más común del primer `up`:

```
$ vagrant up --provider=libvirt
==> default: Box 'ubuntu/jammy64' could not be found. Attempting to find and install...
The box you're attempting to add doesn't support the provider you requested.
Name: ubuntu/jammy64
Address: https://vagrantcloud.com/ubuntu/jammy64
Requested provider: ["libvirt"]
```

Para libvirt, preferí los boxes multi-provider `generic/*` (de *roboxes*, construidos con Packer) o los boxes oficiales `debian/*`. Para reutilizar bajo libvirt un box que solo es de VirtualBox, convertilo con el plugin `vagrant-mutate`.

---

## 3. Configuración del host para el provider libvirt (Debian/Ubuntu y Fedora)

El plugin `vagrant-libvirt` enlaza contra los headers de `libvirt`. En Linux, el camino *confiable* es el plugin **empaquetado por la distro**, porque el binario de HashiCorp trae su propio `curl`/OpenSSL empaquetado y frecuentemente colisiona con las bibliotecas del sistema al compilar gems nativas (los clásicos fallos `libcurl`/`Gem::Ext::BuildError`).

**Debian / Ubuntu — paquetes de la distro (recomendado):**

```bash
$ sudo apt update
$ sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
    virtinst dnsmasq-base ebtables nfs-kernel-server \
    vagrant vagrant-libvirt
$ sudo adduser "$USER" libvirt
$ sudo adduser "$USER" kvm
# log out/in (or: newgrp libvirt) so the group takes effect
```

**Fedora / RHEL:**

```bash
$ sudo dnf install -y @virtualization vagrant vagrant-libvirt \
    libvirt-devel ruby-devel gcc make nfs-utils
$ sudo systemctl enable --now libvirtd
$ sudo usermod -aG libvirt "$USER"
```

**Binario de HashiCorp + plugin gem (solo si no podés usar los paquetes de la distro):**

```bash
$ sudo apt install -y libvirt-dev ruby-dev gcc make pkg-config
$ vagrant plugin install vagrant-libvirt
Installing the 'vagrant-libvirt' plugin. This can take a few minutes...
Fetching vagrant-libvirt-0.12.2.gem
Installed the plugin 'vagrant-libvirt (0.12.2)'!
$ vagrant plugin list
vagrant-libvirt (0.12.2, global)
```

Verificá que la aceleración KVM esté realmente disponible (sin ella QEMU cae silenciosamente a emulación TCG — 10–50× más lento):

```bash
$ lscpu | grep -E 'vmx|svm' -o | head -1
vmx
$ ls -l /dev/kvm
crw-rw----+ 1 root kvm 10, 232 Aug 11 09:04 /dev/kvm
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if device /dev/kvm exists                                   : PASS
  QEMU: Checking if device /dev/kvm is accessible                            : PASS
  QEMU: Checking for cgroup 'cpu' controller support                         : PASS
  ...
```

---

## 4. Manifiestos completos (sin elisiones)

### 4.1 Mínimo, agnóstico del provider

```ruby
# Vagrantfile — the smallest useful environment
Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
end
```

`vagrant init generic/ubuntu2204` genera una versión comentada de esto. `"2"` es la versión del esquema de configuración (v1 es de la era Vagrant 1.0; usá siempre `"2"`).

### 4.2 Máquina única de grado producción sobre libvirt (totalmente ajustada)

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Single KVM/QEMU VM via vagrant-libvirt: pinned box version, virtio disks,
# host-passthrough CPU with nested virt, a private network on a fixed IP,
# an explicit rsync synced folder, and file + shell provisioning.

Vagrant.configure("2") do |config|
  config.vm.box         = "generic/ubuntu2204"
  config.vm.box_version = "4.3.12"          # pin: never let a box float in CI
  config.vm.hostname    = "web01"

  # --- Networking ---------------------------------------------------------
  # A dedicated libvirt network; vagrant-libvirt also always attaches a
  # management NIC on 192.168.121.0/24 for SSH.
  config.vm.network "private_network", ip: "192.168.50.10"

  # --- Synced folders -----------------------------------------------------
  # libvirt does NOT support VirtualBox shared folders. Disable the default
  # /vagrant NFS share and use rsync (zero host daemons, one-way host->guest).
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.synced_folder "./app", "/srv/app",
    type: "rsync",
    rsync__exclude: [".git/", "node_modules/"],
    rsync__args: ["--verbose", "--archive", "--delete", "-z"]

  # --- Provider tuning ----------------------------------------------------
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver             = "kvm"
    libvirt.memory             = 4096
    libvirt.cpus               = 2
    libvirt.cpu_mode           = "host-passthrough"  # expose real CPU flags
    libvirt.nested             = true                # allow nested KVM
    libvirt.machine_virtual_size = 40                # grow root disk to 40G
    libvirt.disk_bus           = "virtio"
    libvirt.nic_model_type     = "virtio"
    libvirt.volume_cache       = "none"              # safe + fast for dev
    libvirt.storage_pool_name  = "default"
    libvirt.default_prefix     = "web"               # domain name = web_web01
    libvirt.graphics_type      = "none"              # headless
    # Extra data disk (qcow2, virtio):
    libvirt.storage :file, size: "20G", type: "qcow2", bus: "virtio"
  end

  # --- Provisioning: file first, then shell ------------------------------
  # 1) file provisioner: copy an artifact into the guest (as the vagrant user)
  config.vm.provision "config-file", type: "file",
    source: "./files/nginx.conf",
    destination: "/tmp/nginx.conf"

  # 2) shell provisioner: idempotent inline bootstrap
  config.vm.provision "bootstrap", type: "shell", privileged: true,
    inline: <<-SHELL
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq nginx
      install -m 0644 /tmp/nginx.conf /etc/nginx/nginx.conf
      systemctl enable --now nginx
      echo "web01 provisioned on $(date -u +%FT%TZ)"
    SHELL

  # 3) shell provisioner from an external script, with arguments
  config.vm.provision "app", type: "shell",
    path: "./scripts/deploy.sh",
    args: ["v1.4.0", "production"]
end
```

Semántica clave de libvirt que un SRE debe conocer:
- `cpu_mode = "host-passthrough"` pasa el modelo físico de CPU directo — requerido para virtualización anidada y para reproducir comportamiento dependiente de flags de CPU; hace que el box no sea portable entre hosts distintos.
- `volume_cache = "none"` usa `O_DIRECT`, evitando el doble caché en el page cache del host; `writeback` es más rápido pero inseguro ante un crash del host.
- El primer synced folder se deshabilita y reemplaza, porque para libvirt el share por defecto `/vagrant` intenta **NFS**, que necesita `nfs-kernel-server` + firewall abierto en el host — un frecuente cuelgue silencioso del `up`.

### 4.3 Clúster multi-máquina (1 control + 2 workers)

Esta es el área de conocimiento "multi-máquina". Un único `Vagrantfile` define varias máquinas nombradas; un loop de Ruby lo mantiene DRY. Vagrant aplica las operaciones en orden de definición (y en orden inverso en `destroy`/`halt`).

```ruby
# Vagrantfile — reproducible 3-node lab on libvirt
#   control : 192.168.60.10  (2 vCPU / 2G)
#   worker1 : 192.168.60.21  (1 vCPU / 1G)
#   worker2 : 192.168.60.22  (1 vCPU / 1G)

WORKERS       = 2
BOX           = "generic/debian12"
NET_PREFIX    = "192.168.60"
DOMAIN        = "lab.local"

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  # Shared provider defaults (overridable per machine below)
  config.vm.provider :libvirt do |v|
    v.cpu_mode     = "host-passthrough"
    v.graphics_type = "none"
    v.default_prefix = "lab"
  end

  # Push a common /etc/hosts to every node so names resolve cluster-wide
  hosts_entries = "#{NET_PREFIX}.10 control.#{DOMAIN} control\n"
  (1..WORKERS).each do |i|
    hosts_entries += "#{NET_PREFIX}.#{20 + i} worker#{i}.#{DOMAIN} worker#{i}\n"
  end

  # ---- control node ----
  config.vm.define "control", primary: true do |node|
    node.vm.hostname = "control"
    node.vm.network "private_network", ip: "#{NET_PREFIX}.10"
    node.vm.provider :libvirt do |v|
      v.memory = 2048
      v.cpus   = 2
    end
    node.vm.provision "hosts", type: "shell",
      inline: "grep -q lab.local /etc/hosts || printf '%s' \"#{hosts_entries}\" >> /etc/hosts"
    node.vm.provision "role", type: "shell",
      inline: "echo 'control-plane bootstrap here'"
  end

  # ---- worker nodes ----
  (1..WORKERS).each do |i|
    config.vm.define "worker#{i}" do |node|
      node.vm.hostname = "worker#{i}"
      node.vm.network "private_network", ip: "#{NET_PREFIX}.#{20 + i}"
      node.vm.provider :libvirt do |v|
        v.memory = 1024
        v.cpus   = 1
      end
      node.vm.provision "hosts", type: "shell",
        inline: "grep -q lab.local /etc/hosts || printf '%s' \"#{hosts_entries}\" >> /etc/hosts"
      node.vm.provision "role", type: "shell",
        inline: "echo 'joining worker#{i} to control'"
    end
  end
end
```

Apuntar a máquinas individuales se hace por nombre (o por una regex): `vagrant up control`, `vagrant provision worker2`, `vagrant ssh worker1`, `vagrant destroy -f /worker[12]/`.

### 4.4 Construir y distribuir un box

Los boxes de **VirtualBox** se pueden capturar desde una máquina en ejecución:

```bash
$ vagrant package --output web01.box
==> web01: Attempting to graceful shutdown VM...
==> web01: Exporting VM...
==> web01: Compressing package to: /home/sre/web01.box
$ vagrant box add mycompany/web01 ./web01.box
```

**libvirt** no tiene un `package` de un solo comando; ensamblás el tarball del box vos mismo a partir de un qcow2 sysprepeado más un `metadata.json`:

```bash
$ sudo cp /var/lib/libvirt/images/web01.img box.img
$ sudo virt-sysprep -a box.img            # strip machine-id, SSH host keys, logs
$ qemu-img info box.img | grep 'virtual size'
virtual size: 40 GiB (42949672960 bytes)
```

```json
// metadata.json for a libvirt box
{
  "provider": "libvirt",
  "format": "qcow2",
  "virtual_size": 40
}
```

```bash
$ tar czf web01-libvirt.box ./metadata.json ./Vagrantfile ./box.img
$ vagrant box add mycompany/web01 ./web01-libvirt.box --provider libvirt
```

Para una producción de boxes repetible, generalo con **Packer** (builder `qemu` + post-processor `vagrant`) en lugar de a mano — ese es el handoff previsto Packer↔Vagrant.

---

## 5. El ciclo de vida en la CLI (invocaciones y salidas reales)

### 5.1 Levantado (bring-up)

```bash
$ vagrant init generic/ubuntu2204
A `Vagrantfile` has been placed in this directory. You are now
ready to `vagrant up` your first virtual environment!

$ vagrant up --provider=libvirt
Bringing machine 'default' up with 'libvirt' provider...
==> default: Checking if box 'generic/ubuntu2204' version '4.3.12' is up to date...
==> default: Creating image (snapshot of base box volume).
==> default: Creating domain with the following settings...
==> default:  -- Name:              demo_default
==> default:  -- Domain type:       kvm
==> default:  -- Cpus:              2
==> default:  -- Memory:            4096M
==> default:  -- Base box:          generic/ubuntu2204
==> default:  -- Storage pool:      default
==> default:  -- Image(vda):        /var/lib/libvirt/images/demo_default.img, virtio, 40G
==> default:  -- Graphics Type:     none
==> default:  -- Management MAC:
==> default:  -- Boot device:       hd
==> default: Starting domain.
==> default: Waiting for domain to get an IP address...
==> default: Waiting for SSH to become available...
    default:
    default: Vagrant insecure key detected. Vagrant will automatically replace
    default: this with a newly generated keypair for better security.
    default: Inserting generated public key within guest...
    default: Removing insecure key from the guest if it's present...
    default: Key inserted! Disconnecting and reconnecting using new SSH key...
==> default: Setting hostname...
==> default: Configuring and enabling network interfaces...
==> default: Rsyncing folder: /home/sre/demo/app/ => /srv/app
==> default: Running provisioner: config-file (file)...
==> default: Running provisioner: bootstrap (shell)...
    default: web01 provisioned on 2026-08-11T12:31:07Z
```

Fijate en la **rotación de la clave insegura**: los boxes traen un keypair bien conocido (`vagrant.pub`); en el primer boot Vagrant lo reemplaza con una clave por máquina almacenada en `.vagrant/machines/<name>/<provider>/private_key`.

### 5.2 Inspección

```bash
$ vagrant status
Current machine states:

default                   running (libvirt)

The Libvirt domain is running. To stop this machine, you can run
`vagrant halt`. To destroy the machine, you can run `vagrant destroy`.

$ vagrant global-status
id       name    provider state   directory
------------------------------------------------------------------------
a1b2c3d  default libvirt running /home/sre/demo

The above shows information about all known Vagrant environments
on this machine. This data is cached and may not be completely
up-to-date. Use "vagrant global-status --prune" to remove stale entries.
```

Contrastá directamente contra libvirt — este es el hábito de verificación que atrapa el estado que el caché de Vagrant perdió:

```bash
$ virsh -c qemu:///system list
 Id   Name           State
------------------------------
 4    demo_default   running

$ virsh -c qemu:///system net-list
 Name                State    Autostart   Persistent
-------------------------------------------------------
 vagrant-libvirt     active   no          yes
 vagrant-private     active   no          yes
```

### 5.3 Acceso por SSH

```bash
$ vagrant ssh
Welcome to Ubuntu 22.04.4 LTS (GNU/Linux 5.15.0-101-generic x86_64)
vagrant@web01:~$ ip -brief addr
lo               UNKNOWN        127.0.0.1/8
eth0             UP             192.168.121.34/24
eth1             UP             192.168.50.10/24
vagrant@web01:~$ logout

$ vagrant ssh-config
Host default
  HostName 192.168.121.34
  User vagrant
  Port 22
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile /home/sre/demo/.vagrant/machines/default/libvirt/private_key
  IdentitiesOnly yes
  LogLevel FATAL
```

`ssh-config` es lo que le pasás a herramientas externas (`ssh` crudo, `scp`, Ansible, un IDE remoto):

```bash
$ vagrant ssh-config > .ssh-config
$ ssh -F .ssh-config default 'uname -r'
5.15.0-101-generic
$ ansible all -i "192.168.50.10," --private-key \
    .vagrant/machines/default/libvirt/private_key -u vagrant -m ping
192.168.50.10 | SUCCESS => { "ping": "pong" }
```

### 5.4 Re-provisioning, reload y estados de apagado

```bash
# Re-run only provisioners (guest stays up)
$ vagrant provision
==> default: Running provisioner: bootstrap (shell)...

# Re-read the Vagrantfile: halt + up, re-applies config changes
$ vagrant reload --provision
==> default: Attempting graceful shutdown of VM...
==> default: Starting domain.
...

# Graceful power off (disk preserved)
$ vagrant halt
==> default: Attempting graceful shutdown of VM...

# Suspend = save RAM state to disk (fast resume, consumes disk)
$ vagrant suspend
==> default: Saving VM state and suspending execution...
$ vagrant resume
==> default: Resuming suspended VM...
==> default: Waiting for domain to get an IP address...

# Tear down completely
$ vagrant destroy -f
==> default: Removing domain...
==> default: Deleting the machine folder
```

**`halt` vs `suspend` vs `destroy`** — la distinción se evalúa:

| Comando | Proceso del guest | Disco | Estado de RAM | Costo de re-`up` | ¿Re-provisiona? |
|---|---|---|---|---|---|
| `halt` | detenido (ACPI shutdown) | conservado | descartado | boot completo | no (salvo `--provision`) |
| `suspend` | congelado | conservado | guardado en disco del host | resume rápido | no |
| `destroy` | eliminado | **borrado** | descartado | create + provision completo | sí (máquina fresca) |
| `reload` | halt + up | conservado | descartado | boot completo, re-lee el Vagrantfile | solo con `--provision` |

### 5.5 Gestión de boxes y Vagrant Cloud

```bash
$ vagrant box list
generic/debian12   (libvirt, 4.3.12)
generic/ubuntu2204 (libvirt, 4.3.12)

$ vagrant box add generic/rocky9 --provider libvirt
==> box: Loading metadata for box 'generic/rocky9'
    box: URL: https://vagrantcloud.com/api/v2/vagrant/generic/rocky9
==> box: Adding box 'generic/rocky9' (v4.3.12) for provider: libvirt
    box: Downloading: https://vagrantcloud.com/generic/boxes/rocky9/.../libvirt.box
    box: Calculating and comparing box checksum...

$ vagrant box outdated --global
* 'generic/ubuntu2204' for 'libvirt' is outdated! Current: 4.3.12. Latest: 4.3.14
$ vagrant box update
$ vagrant box prune            # drop old versions no environment references
```

Los boxes se obtienen desde **Vagrant Cloud** (`app.vagrantup.com` / `vagrantcloud.com`, antes *Atlas*). La forma corta `owner/box` resuelve contra ese catálogo; los boxes están versionados, y `--box-version` / `config.vm.box_version` los fijan. También podés apuntar `config.vm.box_url` a un `.box` autoalojado o a un catálogo privado para entornos air-gapped.

---

## 6. Verificación y diagnóstico de fallos

La herramienta más valiosa es el log de debug; todo diagnóstico real empieza aquí:

```bash
$ VAGRANT_LOG=debug vagrant up 2>&1 | tee vagrant-debug.log
```

### 6.1 Matriz de diagnóstico

| Síntoma (salida observada) | Causa raíz | Remedio |
|---|---|---|
| `Call to virConnectOpen failed: authentication failed` / `Failed to connect socket to '/var/run/libvirt/libvirt-sock'` | usuario no está en el grupo `libvirt` / polkit deniega | `sudo usermod -aG libvirt $USER` luego `newgrp libvirt`; confirmá `systemctl status libvirtd` |
| `The box ... doesn't support the provider you requested` | el box no tiene imagen para ese provider | elegí un box `generic/*`, o `vagrant plugin install vagrant-mutate` |
| `Timed out while waiting for the machine to boot` (colgado en *Waiting for SSH*) | clave SSH incorrecta/faltante, sin lease DHCP, sin aceleración KVM (TCG demasiado lento) | `virsh console <domain>` para observar el boot; verificá `/dev/kvm`; revisá el lease de la red de management |
| Cuelgue en *Waiting for domain to get an IP address* | red de management inactiva o firewall descarta DHCP | `virsh net-list --all`; `virsh net-start vagrant-libvirt`; permitir `dnsmasq` |
| `mount.nfs: Connection timed out` / `exportfs: ... does not support NFS export` | `nfs-kernel-server` del host faltante o con firewall | instalar/iniciar NFS, abrir puertos; o cambiar a `type: "rsync"` |
| `Error while creating domain: ... Permission denied` sobre la imagen | etiqueta SELinux/AppArmor del qcow2 o permisos del pool | revisá `storage_pool_name`; `restorecon` / AppArmor; verificá la propiedad del directorio del pool |
| `uncaught throw :port_check` / puerto ya en uso | `forwarded_port` colisiona en el host | cambiá el puerto del host o usá `auto_correct: true` |
| KVM ausente, la VM va a rastras | virtualización deshabilitada en el firmware, o nested KVM apagado en el host | habilitar VT-x/AMD-V en el BIOS; `modprobe kvm_intel nested=1` |
| `default: Warning: Authentication failure. Retrying...` en loop | clave insegura obsoleta vs clave rotada | `vagrant destroy -f && vagrant up`, o eliminar la clave obsoleta del guest |
| `global-status` lista una máquina que ya no existe | caché de metadata obsoleto | `vagrant global-status --prune` |

### 6.2 Fallo resuelto #1 — timeout del synced-folder por NFS

```bash
$ vagrant up
...
==> default: Exporting NFS shared folders...
==> default: Preparing to edit /etc/exports. Administrator privileges will be required...
==> default: Mounting NFS shared folders...
The following SSH command responded with a non-zero exit status.
mount -o vers=3,udp 192.168.121.1:/home/sre/demo /vagrant
Stdout: mount.nfs: Connection timed out
```

Diagnosticá desde el host, luego decidí entre arreglar NFS o eliminarlo:

```bash
$ systemctl is-active nfs-server
inactive
$ sudo systemctl enable --now nfs-server
$ exportfs -v                       # confirm the share was actually exported
/home/sre/demo  192.168.121.0/24(rw,sync,no_subtree_check,...)
# Firewall must allow the NFS/mountd/rpcbind ports on the libvirt subnet.
```

Arreglo de producción preferido — eliminar por completo la dependencia del daemon:

```ruby
config.vm.synced_folder ".", "/vagrant", type: "rsync"
# then:  vagrant reload
```

### 6.3 Fallo resuelto #2 — timeout de boot por SSH sin aceleración

```bash
$ vagrant up
==> default: Waiting for SSH to become available...
Timed out while waiting for the machine to boot.
```

```bash
$ virsh -c qemu:///system list
 Id   Name           State
------------------------------
 5    demo_default   running
$ virsh -c qemu:///system domstats demo_default | grep -i cpu
  cpu.time=482300000000     # climbing painfully slowly → software emulation
$ virt-host-validate qemu | grep -i kvm
  QEMU: Checking if device /dev/kvm exists : FAIL (Check that CPU and firmware support virtualization and it is enabled in the BIOS)
```

Causa raíz: KVM no disponible, así que QEMU corrió bajo TCG y el guest nunca alcanzó SSH a tiempo. Arreglá a nivel firmware/módulo, luego fijá `driver = "kvm"` para que una caída silenciosa falle de forma ruidosa en lugar de silenciosa. Observá el boot real para confirmarlo:

```bash
$ virsh -c qemu:///system console demo_default
Connected to domain 'demo_default'
Escape character is ^]
[  OK  ] Reached target Multi-User System.
web01 login:
```

### 6.4 Checklist de verificación estándar después de `up`

```bash
$ vagrant status                       # Vagrant's view
$ virsh -c qemu:///system list         # hypervisor's view (must agree)
$ vagrant ssh -c 'hostname -f; ip -brief addr; systemctl is-system-running'
$ vagrant ssh -c 'ls -la /srv/app'     # synced folder present + populated
$ vagrant provision                    # provisioners are idempotent (re-run is clean)
```

El principio: **nunca confíes solo en el `status` cacheado de Vagrant** — reconcilialo contra `virsh` (o `VBoxManage list runningvms`). La divergencia entre el estado del orquestador y el estado del hipervisor es la fuente de la mayoría de los bugs "fantasma" de Vagrant.

---

## Referencias

- Vagrant — Documentation (concepts, provisioning, multi-machine, networking): https://developer.hashicorp.com/vagrant/docs
- Vagrant — CLI command reference (`up`, `halt`, `destroy`, `suspend`, `resume`, `provision`, `reload`, `status`, `global-status`, `ssh`, `ssh-config`, `box`): https://developer.hashicorp.com/vagrant/docs/cli
- Vagrant — Boxes and box format: https://developer.hashicorp.com/vagrant/docs/boxes and https://developer.hashicorp.com/vagrant/docs/boxes/format
- Vagrant — Providers overview: https://developer.hashicorp.com/vagrant/docs/providers
- Vagrant — Provisioning (shell and file provisioners): https://developer.hashicorp.com/vagrant/docs/provisioning/shell and https://developer.hashicorp.com/vagrant/docs/provisioning/file
- Vagrant — Multi-Machine environments: https://developer.hashicorp.com/vagrant/docs/multi-machine
- Vagrant — Synced folders (NFS, rsync): https://developer.hashicorp.com/vagrant/docs/synced-folders
- Vagrant Cloud (box catalog, formerly Atlas): https://developer.hashicorp.com/vagrant/vagrant-cloud and https://app.vagrantup.com/boxes/search
- vagrant-libvirt provider (configuration, networking, storage, synced folders): https://vagrant-libvirt.github.io/vagrant-libvirt/ and https://github.com/vagrant-libvirt/vagrant-libvirt
- libvirt / QEMU / KVM reference: https://libvirt.org/docs.html
- LPI — Exam 305-300 Objectives (LPIC-3 Virtualization and Containerization, v3.0): https://www.lpi.org/our-certifications/exam-305-objectives/