# 353.2 Packer

> **LPIC-3 305 · Examen 305-300 (v3.0) · Tema 353.2 — Peso: 3.33**
> Perfil: Platform Architect / SRE — imagen-como-código para la flota de KVM/libvirt y contenedores.

---

## 1. Motivación: el problema arquitectónico que Packer resuelve

En un parque de virtualización en producción tenés dos maneras de pasar de "ISO pelado de la distro" a "una VM que ejecuta tu carga de trabajo":

1. **Configuración en tiempo de arranque (boot-time)** — levantás una imagen base genérica y dejás que `cloud-init`, Ansible o un agente de config-management la converjan en el primer arranque.
2. **Configuración en tiempo de horneado (imágenes inmutables / golden images)** — pre-construís *una sola vez* un artefacto totalmente aprovisionado, lo versionás, y arrancás N copias idénticas con un trabajo de convergencia casi nulo.

El primer camino es tentador porque no necesita pipeline de build, pero falla a escala de tres maneras concretas que un SRE siente todas las semanas:

- **Amplificación del boot-storm.** Si 200 VMs hacen cada una `apt-get update && apt-get install` en el arranque, multiplicás por 200 el volumen de descarga, la carga del mirror y el tiempo hasta estar listas. Un arranque que baja 400 MB de paquetes convierte un inicio de 15 segundos en uno de 4 minutos, y cada evento de autoscaling lo vuelve a pagar.
- **No-determinismo / drift.** Converger en el arranque significa que el artefacto es una *función del estado del repositorio upstream en el momento del arranque*. Dos VMs arrancadas con una hora de diferencia desde la "misma" plantilla pueden obtener versiones de paquetes distintas. El análisis de causa raíz se vuelve arqueología.
- **Sin rollback atómico.** Si aterriza un paquete malo, no podés "hacer rollback del script de arranque" — el daño ya se ejecutó en cada instancia. Con imágenes inmutables volvés a desplegar `image v41` y listo.

**Packer** (HashiCorp) es la herramienta que hace práctico el camino 2: es un único binario Go que automatiza la *creación de imágenes de máquina* a partir de una fuente, conduce una VM/contenedor temporal a través de una fase de aprovisionamiento, y emite uno o más artefactos (un `qcow2`, una AMI, una imagen Docker, un OVA, una Vagrant box). Es el paso de "compilación" de **imagen-como-código**: texto fuente que entra → artefacto binario versionado que sale.

El principio de diseño de Packer: **no gestiona máquinas en ejecución y no reemplaza a un provisioner.** Orquesta una máquina de build *descartable*, delega la configuración a nivel de SO a un provisioner (shell/Ansible), y luego congela el resultado. Esta separación es la razón por la que Packer compone limpiamente con Terraform (que consume la imagen) y con cloud-init (que maneja los datos por-instancia en el arranque). Base inmutable, *datos de instancia* mutables — ambos no están en conflicto.

```
  ┌────────────┐   builder    ┌──────────────┐  provisioner  ┌──────────────┐  post-processor  ┌───────────┐
  │  source    │ ───────────▶ │ temporary VM │ ────────────▶ │  configured  │ ───────────────▶ │  artifact │
  │ (ISO/image)│   boots &     │  or container│  shell/ansible│    machine   │  compress/tag/   │ qcow2/AMI/│
  └────────────┘   connects    └──────────────┘  copy files   └──────────────┘  push/box        │  image    │
                   via SSH/WinRM                                    │ shutdown & snapshot         └───────────┘
```

---

## 2. Arquitectura y el modelo de plugins

El runtime de Packer es un **core** más un conjunto de **plugins**. Desde Packer **1.7** los plugins que solían venir dentro del monolito (QEMU, VirtualBox, Docker, Amazon, vSphere…) viven en **binarios versionados separados** que declarás y descargás con `packer init`. Esta es la modernización más relevante para el examen: los builders mantenidos por la comunidad ya no vienen "incorporados".

Existen cuatro tipos de componentes de plugin:

| Componente | Rol | Ejemplos |
|---|---|---|
| **Builder** | Crea la máquina descartable y el artefacto base. Uno por fuente. | `qemu`, `virtualbox-iso`, `vmware-iso`, `docker`, `amazon-ebs`, `vsphere-iso`, `lxc`, `proxmox` |
| **Provisioner** | Se ejecuta *dentro* de la máquina para configurar el SO. | `shell`, `file`, `ansible`, `ansible-local`, `powershell`, `breakpoint` |
| **Post-processor** | Transforma/envía el artefacto terminado. Se ejecuta *después* del build. | `docker-tag`, `docker-push`, `compress`, `vagrant`, `manifest`, `shell-local`, `checksum` |
| **Data source** | Obtiene datos externos en tiempo de parseo (solo HCL2). | `amazon-ami`, `git-commit`, `http` |

### Lenguajes de configuración: HCL2 vs JSON

Packer acepta dos formatos de plantilla. **HCL2 es el formato actual y recomendado** (Packer ≥ 1.7); JSON es el formato legacy que se mantiene por retrocompatibilidad. El examen espera que sepas leer ambos.

| Dimensión | HCL2 (`.pkr.hcl`) | JSON (`.json`) — legacy |
|---|---|---|
| Estado | Recomendado, en desarrollo activo | Mantenido solo por compatibilidad |
| Comentarios | `#`, `//`, `/* */` | Ninguno (JSON no tiene comentarios) |
| Variables | Bloques `variable`/`local`, tipadas, validadas | Mapa `variables`, solo strings |
| Expresiones/funciones | Funciones HCL completas (`templatefile`, `env`, `regex`…) | Motor de plantillas limitado `{{ }}` |
| Múltiples fuentes por build | `build { sources = [...] }` — builds paralelos de primera clase | Array `builders` | 
| `required_plugins` / `packer init` | Sí | **No** — no puede fijar plugins de forma declarativa |
| Bucles / condicionales | Bloques `dynamic`, expresiones `for` | Ninguno |

**Resumen del trade-off:** JSON solo es correcto cuando tenés que mantener una plantilla existente que precede a la 1.7 y no se puede migrar (`packer hcl2_upgrade` la convierte). Para cualquier cosa nueva, HCL2 — porque `required_plugins` + `packer init` es el mecanismo de reproducibilidad, y JSON literalmente no puede expresarlo.

### Bake-time vs boot-time (la decisión que precede a Packer)

| Criterio | Golden image (Packer) | Configuración en boot (cloud-init/Ansible-pull) |
|---|---|---|
| Tiempo hasta estar listo | Rápido (el trabajo ya está hecho) | Lento (converge en cada arranque) |
| Determinismo | Alto (congelado en el build) | Bajo (depende del estado del repo en el arranque) |
| Rollback | Atómico (redesplegar la imagen anterior) | Difícil (el script ya se ejecutó) |
| Costo de almacenamiento | Mayor (muchas imágenes completas) | Menor (una base delgada) |
| Necesita pipeline de build | Sí | No |
| Mejor para | Flotas autoescaladas, builds regulados/repetibles | Hosts que rara vez arrancan o muy heterogéneos |

La respuesta madura es **ambos**: Packer hornea la base (kernel, paquetes, hardening, agente), cloud-init inyecta los datos por-instancia (hostname, claves SSH, secretos) en el arranque. Nunca hornees secretos ni identidad por-instancia dentro de la imagen.

---

## 3. Plantillas completas, sin abreviar

### 3.1 Golden image QEMU/KVM — Debian 12, HCL2

Este es el escenario canónico de LPIC-3 305: construir un `qcow2` para la flota libvirt/KVM. Usa un **autoinstall/preseed servido a través del servidor HTTP incorporado de Packer**, arranca headless, aprovisiona por SSH y comprime el resultado.

Disposición de directorios:

```
debian-qemu/
├── debian.pkr.hcl
├── variables.pkr.hcl
├── http/
│   └── preseed.cfg
└── scripts/
    └── provision.sh
```

`variables.pkr.hcl`:

```hcl
variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
  description = "Location of the Debian netinst ISO (local path or URL)."
}

variable "iso_checksum" {
  type        = string
  default     = "file:https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
  description = "Checksum or a checksum-file URL; Packer refuses to boot on mismatch."
}

variable "ssh_username" {
  type    = string
  default = "packer"
}

variable "ssh_password" {
  type      = string
  default   = "packer"
  sensitive = true
}

variable "disk_size" {
  type    = string
  default = "10240M"
}

variable "headless" {
  type        = bool
  default     = true
  description = "Set false to watch the install over the SDL/GTK console during debugging."
}
```

`debian.pkr.hcl`:

```hcl
packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.0.10"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "debian" {
  # --- Source media ---
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # --- Machine shape ---
  accelerator  = "kvm"        # falls back to "tcg" (software) if /dev/kvm is absent
  cpus         = 2
  memory       = 2048
  disk_size    = var.disk_size
  disk_interface = "virtio"
  net_device   = "virtio-net"
  format       = "qcow2"

  # --- Boot & unattended install ---
  http_directory = "http"     # served at http://{{ .HTTPIP }}:{{ .HTTPPort }}/
  boot_wait      = "5s"
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "hostname=debian domain=local ",
    "interface=auto ",
    "<enter>"
  ]

  # --- Connection back into the guest ---
  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"        # generous: covers the whole preseed install

  # --- Shutdown & output ---
  headless         = var.headless
  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  output_directory = "output-debian"
  vm_name          = "debian-12-golden.qcow2"

  # --- Post-install disk optimization ---
  disk_compression = true
  qemuargs = [
    ["-display", "none"]
  ]
}

build {
  name    = "debian-golden"
  sources = ["source.qemu.debian"]

  # 1) Copy a systemd unit into the image
  provisioner "file" {
    source      = "files/node-agent.service"
    destination = "/tmp/node-agent.service"
  }

  # 2) Run the hardening/package script with elevated privileges
  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    expect_disconnect = true                      # a kernel upgrade may drop SSH
    scripts           = ["scripts/provision.sh"]
    environment_vars  = ["DEBIAN_FRONTEND=noninteractive"]
  }

  # 3) Inline cleanup: shrink the image before it is frozen
  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E bash -eux -c '{{ .Path }}'"
    inline = [
      "apt-get -y autoremove --purge",
      "apt-get -y clean",
      "rm -rf /var/lib/apt/lists/*",
      "cloud-init clean --logs || true",
      "truncate -s 0 /etc/machine-id",            # regenerated per boot -> unique DHCP/identity
      "rm -f /var/lib/dbus/machine-id",
      "dd if=/dev/zero of=/EMPTY bs=1M || true",   # zero free space so compression is effective
      "rm -f /EMPTY",
      "sync"
    ]
  }

  # 4) Emit a build manifest and a compressed artifact
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      distro = "debian-12"
      role   = "base"
    }
  }

  post-processor "compress" {
    output = "output-debian/debian-12-golden.qcow2.gz"
  }
}
```

`http/preseed.cfg` (archivo de respuestas del instalador de Debian — servido en memoria por HTTP, nunca persistido dentro de la imagen):

```
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string local

d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i passwd/root-login boolean false
d-i passwd/user-fullname string Packer
d-i passwd/username string packer
d-i passwd/user-password password packer
d-i passwd/user-password-again password packer

d-i clock-setup/utc boolean true
d-i time/zone string UTC

d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i pkgsel/include string openssh-server sudo qemu-guest-agent cloud-init
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

# Give packer's user passwordless sudo so the shell provisioner works
d-i preseed/late_command string \
    in-target sh -c 'echo "packer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/packer'; \
    in-target chmod 440 /etc/sudoers.d/packer

d-i finish-install/reboot_in_progress note
```

`scripts/provision.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> Updating base and installing fleet baseline"
apt-get update
apt-get -y install --no-install-recommends \
    chrony curl gnupg jq unattended-upgrades

echo "==> Installing the node agent unit"
install -m 0644 /tmp/node-agent.service /etc/systemd/system/node-agent.service
systemctl enable node-agent.service || true

echo "==> Minimal hardening"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

echo "==> Done"
```

### 3.2 Imagen Docker construida con Packer, HCL2

Relevante para la mitad de containerización de LPIC-3 305. Packer *no* es un reemplazo de Dockerfile, pero te permite aprovisionar un contenedor con el **mismo código shell/Ansible** usado para VMs y luego commitearlo + pushearlo — una única fuente de verdad de aprovisionamiento para ambos mundos.

```hcl
packer {
  required_plugins {
    docker = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "registry" {
  type    = string
  default = "registry.example.com/platform"
}

source "docker" "ubuntu" {
  image  = "ubuntu:24.04"
  commit = true                    # commit the container to an image (vs. export to tar)
  changes = [
    "USER app",
    "WORKDIR /srv",
    "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]",
    "EXPOSE 8080"
  ]
}

build {
  name    = "app-container"
  sources = ["source.docker.ubuntu"]

  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update",
      "apt-get -y install --no-install-recommends ca-certificates curl",
      "useradd -r -u 10001 -m -d /srv app",
      "rm -rf /var/lib/apt/lists/*"
    ]
  }

  provisioner "file" {
    source      = "entrypoint.sh"
    destination = "/usr/local/bin/entrypoint.sh"
  }

  # Chained post-processors: tag, then push. Note the nested block form.
  post-processors {
    post-processor "docker-tag" {
      repository = "${var.registry}/app"
      tags       = ["latest", "1.4.0"]
    }
    post-processor "docker-push" {
      # credentials come from the docker CLI's credential store / login
    }
  }
}
```

> **Detalle de sintaxis clave:** un **único `post-processor`** se ejecuta sobre el artefacto de build original. Un bloque **`post-processors { … }`** (en plural) define una *cadena* donde cada post-processor consume la salida del anterior — obligatorio cuando tenés que taggear *antes* de pushear.

### 3.3 Equivalente JSON legacy (para comprensión de lectura)

El examen puede mostrar JSON. El mismo build QEMU, en estilo pre-1.7 — notá que **no hay** `required_plugins`:

```json
{
  "builders": [
    {
      "type": "qemu",
      "iso_url": "debian-12.5.0-amd64-netinst.iso",
      "iso_checksum": "sha256:013f5b44670d81280b5b1bc02455842b250df2f0c6763398feb69af1a805a14f",
      "accelerator": "kvm",
      "disk_size": "10240M",
      "format": "qcow2",
      "headless": true,
      "http_directory": "http",
      "boot_command": ["<esc><wait>auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg<enter>"],
      "ssh_username": "packer",
      "ssh_password": "packer",
      "ssh_timeout": "30m",
      "shutdown_command": "echo packer | sudo -S shutdown -P now",
      "output_directory": "output-debian"
    }
  ],
  "provisioners": [
    { "type": "shell", "scripts": ["scripts/provision.sh"] }
  ],
  "post-processors": [
    { "type": "compress", "output": "output-debian/debian.qcow2.gz" }
  ]
}
```

Convertir JSON → HCL2:

```
$ packer hcl2_upgrade -output-file debian.pkr.hcl debian.json
Successfully created debian.pkr.hcl
```

---

## 4. Flujo de trabajo de la CLI con salida real de terminal

El orden canónico es **`init` → `fmt` → `validate` → `build`**. Nunca saltees `init`/`validate` en un pipeline — son gratis y atrapan la mayoría de las fallas antes de quemar una instalación de 20 minutos.

### 4.1 Instalar los plugins declarados

```
$ packer version
Packer v1.11.2

$ packer init .
Installed plugin github.com/hashicorp/qemu v1.1.0 in "/home/sre/.config/packer/plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.0_x5.0_linux_amd64"

$ packer plugins installed
/home/sre/.config/packer/plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.0_x5.0_linux_amd64
```

`packer init` es idempotente — una segunda ejecución con las restricciones satisfechas no imprime nada y sale con 0. Los plugins también se pueden instalar explícitamente:

```
$ packer plugins install github.com/hashicorp/docker
Installed plugin github.com/hashicorp/docker v1.1.0 ...
```

### 4.2 Formatear y validar

```
$ packer fmt -check -diff .
debian.pkr.hcl
--- old/debian.pkr.hcl
+++ new/debian.pkr.hcl
@@ -12,7 +12,7 @@
-  cpus         =2
+  cpus         = 2

$ packer fmt .
debian.pkr.hcl

$ packer validate .
The configuration is valid.
```

Una falla de validación es explícita y apunta a la línea:

```
$ packer validate .
Error: Unsupported argument

  on debian.pkr.hcl line 18:
  18:   memroy       = 2048

An argument named "memroy" is not expected here. Did you mean "memory"?
```

### 4.3 Inspeccionar la plantilla parseada

```
$ packer inspect .
Packer Inspect: HCL2 mode

> input-variables:
var.disk_size: "10240M"
var.headless: "true"
var.iso_url: "https://cdimage.debian.org/.../debian-12.5.0-amd64-netinst.iso"
var.ssh_password: "packer"
var.ssh_username: "packer"

> builds:
  > <unnamed build 0>:
    sources:
      source.qemu.debian
    provisioners:
      file
      shell
      shell
    post-processors:
      <no post-processor group 0>:
        manifest
      <no post-processor group 1>:
        compress
```

### 4.4 Build

```
$ packer build -var 'headless=true' .
debian-golden.qemu.debian: output will be in this color.

==> debian-golden.qemu.debian: Retrieving ISO
==> debian-golden.qemu.debian: Trying https://cdimage.debian.org/.../debian-12.5.0-amd64-netinst.iso
==> debian-golden.qemu.debian: Verifying checksum
==> debian-golden.qemu.debian: Starting HTTP server on port 8341
==> debian-golden.qemu.debian: Found port for communicator (SSH): 3213.
==> debian-golden.qemu.debian: Starting VM, booting disk image
==> debian-golden.qemu.debian: Waiting 5s for boot...
==> debian-golden.qemu.debian: Typing the boot command over VNC...
==> debian-golden.qemu.debian: Waiting for SSH to become available...
==> debian-golden.qemu.debian: Connected to SSH!
==> debian-golden.qemu.debian: Uploading files/node-agent.service => /tmp/node-agent.service
==> debian-golden.qemu.debian: Provisioning with shell script: scripts/provision.sh
    debian-golden.qemu.debian: ==> Updating base and installing fleet baseline
    debian-golden.qemu.debian: ==> Done
==> debian-golden.qemu.debian: Gracefully halting virtual machine...
==> debian-golden.qemu.debian: Converting hard drive...
==> debian-golden.qemu.debian: Running post-processor: manifest
==> debian-golden.qemu.debian: Running post-processor: compress
Build 'debian-golden.qemu.debian' finished after 11 minutes 42 seconds.

==> Wait completed after 11 minutes 42 seconds

==> Builds finished. The artifacts of successful builds are:
--> debian-golden.qemu.debian: VM files in directory: output-debian
--> debian-golden.qemu.debian: compressed artifacts in: output-debian/debian-12-golden.qcow2.gz
```

Flags útiles en tiempo de build:

| Flag | Efecto |
|---|---|
| `-only='qemu.debian'` | Ejecutar solo la(s) fuente(s) que coincidan en un build multi-fuente |
| `-except='docker.*'` | Ejecutar todo *excepto* las fuentes que coincidan |
| `-var 'k=v'` / `-var-file=prod.pkrvars.hcl` | Sobrescribir variables |
| `-on-error=ask` | Ante una falla, pausar para que puedas hacer SSH a la VM de build aún en ejecución |
| `-on-error=abort` | Dejar la máquina como está (no limpiar) para análisis forense |
| `-parallel-builds=1` | Serializar las fuentes (el default es paralelo) |
| `-debug` | Avanzar por cada etapa con una tecla; imprime la ruta de la clave SSH temporal |
| `-force` | Sobrescribir un artefacto/directorio de salida preexistente |
| `-timestamp-ui` | Prefijar cada línea de log con un timestamp (amigable para pipelines) |

---

## 5. Verificación y diagnóstico de fallas

### 5.1 La escalera de diagnóstico

```
$ PACKER_LOG=1 PACKER_LOG_PATH=./packer.log packer build .
```

`PACKER_LOG=1` activa el logging de debug del core + plugins; `PACKER_LOG_PATH` lo envía a un archivo para que la UI coloreada quede legible. Dentro del log ves la invocación exacta de `qemu-system-x86_64`, el tipeo por VNC y cada intento de handshake SSH — acá es donde se depura el 90 % de los builds de QEMU en la práctica.

Para análisis forense interactivo de un build atascado:

```
$ packer build -debug -on-error=ask .
...
==> Pausing after run of step 'StepTypeBootCommand'. Press enter to continue.
==> Waiting for SSH to become available...
==> Build paused. Press enter to continue, or type 'exit' to abort.
```

`-debug` también escribe la clave privada SSH descartable en el directorio de trabajo (`qemu.debian.pem`, etc.), así podés hacer `ssh -i` a la VM de build mientras está pausada e inspeccionar el estado a mano.

### 5.2 Fallas comunes → causa raíz → solución

| Síntoma en la salida | Causa raíz | Solución |
|---|---|---|
| `Bad checksum ... expected X got Y` | `iso_checksum` incorrecto/desactualizado, o una descarga truncada | Usar `iso_checksum = "file:.../SHA256SUMS"` para que Packer lea las sumas oficiales; volver a descargar |
| `Waiting for SSH to become available...` y luego timeout | El preseed/autoinstall nunca completó, o no se creó el usuario/sudo | Arrancar con `headless=false` y observar el instalador; verificar que `preseed/late_command` cree el archivo sudoers; subir `ssh_timeout` |
| `install plugin ... could not be found` en `build` | No se corrió `packer init`, o hay un desajuste de `source` en `required_plugins` | Ejecutar `packer init .`; confirmar que el string `source` coincida con `github.com/hashicorp/<name>` |
| El boot command tipea basura en el instalador | Timing del teclado del host; faltan tokens `<wait>` | Agregar `<wait>`/`<waitNs>` entre pulsaciones; aumentar `boot_wait` |
| `Error launching VM: ... /dev/kvm permission denied` | Usuario no está en el grupo `kvm` / virtualización anidada desactivada | `usermod -aG kvm $USER`; habilitar KVM; de lo contrario Packer recae en el lento TCG |
| `sudo: no tty present and no askpass program` | El provisioner ejecuta sudo pero no hay NOPASSWD | Agregar sudo sin contraseña en el preseed, o usar el `execute_command` con `echo pass | sudo -S` mostrado arriba |
| Post-processor `docker-push` → `denied` | No se inició sesión en el registry | `docker login registry.example.com` antes de `packer build`; Packer reutiliza el credential store de la CLI |
| Imagen enorme después del build | El espacio libre no se puso en cero antes del snapshot | Agregar el paso `dd if=/dev/zero … && rm` + `disk_compression = true` |

### 5.3 Verificar el artefacto después del build

Que el build termine con éxito prueba que Packer *se ejecutó*, no que la imagen sea *correcta*. Verificá de forma independiente:

```
$ qemu-img info output-debian/debian-12-golden.qcow2
image: output-debian/debian-12-golden.qcow2
file format: qcow2
virtual size: 10 GiB (10737418240 bytes)
disk size: 1.42 GiB
cluster_size: 65536

$ qemu-img check output-debian/debian-12-golden.qcow2
No errors were found on the image.

$ jq '.builds[0] | {name, artifact_id, packer_run_uuid}' manifest.json
{
  "name": "debian-golden",
  "artifact_id": "output-debian/debian-12-golden.qcow2",
  "packer_run_uuid": "6d3c1e0a-..."
}
```

Hacé un smoke-boot de la golden image en una red aislada y confirmá el baseline horneado:

```
$ qemu-system-x86_64 -enable-kvm -m 2048 -nographic \
    -drive file=output-debian/debian-12-golden.qcow2,if=virtio \
    -netdev user,id=n0 -device virtio-net,netdev=n0
...
debian login: packer
$ systemctl is-enabled node-agent.service
enabled
$ dpkg -l | grep -c qemu-guest-agent
1
$ cat /etc/machine-id        # should be EMPTY in the image -> regenerated on first boot
$
```

Un `/etc/machine-id` vacío en la imagen congelada es la señal de que de-duplicaste correctamente la identidad de instancia — cada clon obtiene un ID nuevo (y por lo tanto una concesión DHCP/identidad de máquina systemd distinta) en el primer arranque.

### 5.4 Compuerta de CI

El patrón de pipeline digno del examen — fallar rápido, primero los chequeos baratos:

```bash
#!/usr/bin/env bash
set -euo pipefail
packer init .                       # pin/fetch plugins
packer fmt -check -diff .           # style gate (fails if unformatted)
packer validate .                   # semantic gate
packer build -timestamp-ui \
             -var-file=prod.pkrvars.hcl .
qemu-img check output-debian/*.qcow2 # artifact integrity gate
```

`fmt -check` devuelve un valor distinto de cero cuando los archivos están sin formatear, y `validate` devuelve distinto de cero ante cualquier error semántico, así que ambos funcionan directamente como compuertas de CI sin necesidad de parseo adicional.

---

## 6. Referencias

- LPI — Objetivos del Examen 305-300 (353.2 Packer): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Documentación de Packer (HashiCorp Developer): <https://developer.hashicorp.com/packer/docs>
- Plantillas de Packer — sintaxis y bloques HCL2: <https://developer.hashicorp.com/packer/docs/templates/hcl_templates>
- `required_plugins` y `packer init` de Packer: <https://developer.hashicorp.com/packer/docs/plugins>
- Referencia del plugin builder de QEMU: <https://developer.hashicorp.com/packer/integrations/hashicorp/qemu>
- Referencia del plugin builder de Docker: <https://developer.hashicorp.com/packer/integrations/hashicorp/docker>
- Provisioners (shell, file, ansible): <https://developer.hashicorp.com/packer/docs/provisioners>
- Post-processors (compress, manifest, docker-tag/push, vagrant): <https://developer.hashicorp.com/packer/docs/post-processors>
- Comandos de la CLI de Packer (`init`, `fmt`, `validate`, `inspect`, `build`, `hcl2_upgrade`): <https://developer.hashicorp.com/packer/docs/commands>
- Depuración de builds de Packer y variables de entorno (`PACKER_LOG`): <https://developer.hashicorp.com/packer/docs/debugging>
- Referencia de preseed del Instalador de Debian: <https://www.debian.org/releases/stable/amd64/apb.en.html>
- Utilidad de imágenes de disco de QEMU (`qemu-img`): <https://www.qemu.org/docs/master/tools/qemu-img.html>