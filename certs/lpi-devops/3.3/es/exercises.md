# LPI DevOps Tools Engineer (Exam 701-100)
## Topic 703.3: System Image Creation (Weight: 3.33)

---

### Referencias oficiales
- **LPI DevOps Tools Engineer Overview & Objectives**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **HashiCorp Packer Documentation**: [https://developer.hashicorp.com/packer/docs](https://developer.hashicorp.com/packer/docs)
- **Packer HCL2 Language Specification**: [https://developer.hashicorp.com/packer/docs/templates/hcl_templates](https://developer.hashicorp.com/packer/docs/templates/hcl_templates)
- **Canonical Cloud-Init Documentation**: [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)

---

### Base técnica y arquitectónica profunda

#### 1. Paradigmas de infraestructura inmutable: Bake vs. Fry vs. Warm Bake
En la arquitectura de producción empresarial, la creación de imágenes del sistema es la primitiva fundamental de la **Infraestructura Inmutable** (**Immutable Infrastructure**). En lugar de mutar servidores en ejecución in situ mediante herramientas de gestión de configuración (lo que introduce deriva de configuración (*configuration drift*), estado no determinista y ventanas de despliegue prolongadas), la infraestructura inmutable trata las instancias en ejecución como nodos de ejecución desechables construidos a partir de imágenes estáticas y previamente validadas.

```
       [ Bake Strategy (Golden Image) ]             [ Fry Strategy (Runtime Provisioning) ]
       
 +------------------------------------------+     +------------------------------------------+
 | Build Time (CI/CD Pipeline):             |     | Build Time:                              |
 |   1. Boot Base OS VM/Container           |     |   - Generic OS Base Image Only           |
 |   2. Install OS Updates & Dependencies   |     | Boot Time (EC2 / Compute Startup):       |
 |   3. Bake Application Binaries & Assets  |     |   1. Boot Generic OS                     |
 |   4. Execute CIS Hardening & Sanitization|     |   2. Execute Apt/Yum Updates (Slow!)     |
 |   5. Snapshot Image Artifact (AMI/QCOW2) |     |   3. Run Configuration Management        |
 +------------------------------------------+     |   4. Fetch & Compile Binaries            |
                      |                           +------------------------------------------+
 Boot Time: < 30 seconds (Instant Scale)          Boot Time: 10–25 minutes (High Failure Rate)
```

- **Fully Baked (Golden Image)**: Todo el software, los kernels del sistema operativo, las dependencias, los agentes de seguridad y los assets estáticos se compilan en la imagen del sistema antes del despliegue en tiempo de ejecución. 
  - *Trade-offs*: Inicio/autoscaling rápido (< 30s), ejecución determinista, cero dependencia en tiempo de ejecución de repositorios de paquetes externos. Mayor huella de almacenamiento y tiempos de pipeline de build de imagen más largos.
- **Fried (Runtime Bootstrapping)**: Se despliega una imagen mínima del sistema operativo; el software y la configuración se obtienen en tiempo de ejecución a través de `cloud-init`, scripts de UserData o Ansible al iniciar.
  - *Trade-offs*: Pipeline de build de imagen rápido. Autoscaling lento (minutos), vulnerable a caídas de repositorios externos o timeouts de red durante eventos de escalado.
- **Warm Bake (Híbrido)**: Las dependencias centrales del runtime, las actualizaciones de seguridad del sistema operativo y el tooling común están pre-baked en una imagen base. El código de la aplicación y la configuración específica del entorno se inyectan a través de `cloud-init` o contenedores de configuración efímeros al iniciar.

---

#### 2. Arquitectura y mecánica interna de ejecución de HashiCorp Packer
Packer utiliza un motor declarativo (escrito en Go) para automatizar la creación de imágenes de máquina idénticas para múltiples plataformas a partir de una única especificación origen.

```
 +-----------------------------------------------------------------------------------+
 |                                   PACKER CORE                                     |
 |  +--------------------+   +-----------------------+   +------------------------+  |
 |  |  HCL2 Template     |   | Variable Evaluation   |   | Plugin RPC Orchestrator|  |
 |  +--------------------+   +-----------------------+   +------------------------+  |
 +----------------------------------------+------------------------------------------+
                                          |
                        +-----------------+-----------------+
                        |                                   |
              [ BUILDER PLUGINS ]                 [ PROVISIONER PLUGINS ]
      +----------------------------------+ +-----------------------------------+
      | - amazon-ebs / qemu / docker     | | - shell / file / ansible-local    |
      | - Manages instance lifecycle     | | - Communicates over SSH/WinRM    |
      | - Provisions temporary SSH keys  | | - Executes scripts in target host |
      +----------------------------------+ +-----------------------------------+
                        |                                   |
                        +-----------------+-----------------+
                                          |
                                [ POST-PROCESSOR PLUGINS ]
                        +---------------------------------------+
                        | - manifest / checksum / vagrant       |
                        | - Compresses, signs, indexes output   |
                        +---------------------------------------+
```

Packer ejecuta los builds a través de cuatro componentes estructurales distintos:

1. **Packer Core**: Lee configuraciones HCL2, analiza grafos de dependencias, gestiona builds concurrentes y establece canales de comunicación gRPC/RPC con plugins externos.
2. **Builders**: Plugins específicos de la plataforma que crean recursos de cómputo temporales, gestionan secuencias de arranque iniciales (por ejemplo, a través de VNC, montaje de ISO, APIs de proveedores de nube), establecen conexiones WinRM/SSH y capturan el estado final de la máquina en un artefacto de imagen (AMI, QCOW2, capa de Docker, VHD).
3. **Provisioners**: Módulos ejecutados después de que se establece el acceso inicial al sistema operativo a través de SSH/WinRM. Adaptan el estado de la máquina ejecutando comandos de shell, copiando archivos locales o ejecutando herramientas de gestión de configuración como Ansible, Puppet o Chef.
4. **Post-Processors**: Plugins de manipulación de artefactos ejecutados después de la generación de la imagen. Calculan checksums SHA-256, comprimen artefactos, generan archivos JSON de manifest, empaquetan imágenes en Vagrant boxes o envían imágenes de contenedores a registries.

---

### Ejercicios prácticos guiados

---

#### Lab 1: Imagen base inmutable de grado de producción con HCL2, Ansible y sanitización con Cloud-Init

##### Objetivo del ejercicio
Construir un proyecto modular de Packer HCL2 que cree una imagen de sistema Ubuntu *hardened* utilizando el builder `docker` (emulando el aislamiento de cómputo local), configure servicios del sistema a través del provisioner `ansible-local`, ejecute la sanitización de la imagen y genere un manifest de build auditado.

---

##### Paso 1: Inicializar la estructura de directorios y definir los requerimientos de plugins HCL2
Crear la estructura de directorios del espacio de trabajo y definir las fuentes de plugins requeridas y las restricciones de versión en `plugins.pkr.hcl`.

```bash
mkdir -p ~/packer-lab/{scripts,ansible}
cd ~/packer-lab
```

Escribir `plugins.pkr.hcl`:

```hcl
# plugins.pkr.hcl
packer {
  required_version = ">= 1.8.0"
  required_plugins {
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}
```

---

##### Paso 2: Configurar entradas de build declarativas en `variables.pkr.hcl`
Definir variables de entrada explícitas y validadas por tipo para metadatos de imagen, versionado de objetivos y etiquetado de entorno.

Escribir `variables.pkr.hcl`:

```hcl
# variables.pkr.hcl
variable "base_image" {
  type        = string
  description = "The upstream base container image tag."
  default     = "ubuntu:22.04"
}

variable "app_version" {
  type        = string
  description = "Application semver tag to bake into system metadata."
  default     = "2.4.0"
}

variable "build_environment" {
  type        = string
  description = "Deployment tier label."
  default     = "production"

  validation {
    condition     = contains(["staging", "production"], var.build_environment)
    error_message = "The build_environment variable must be either 'staging' or 'production'."
  }
}
```

---

##### Paso 3: Definir builders de origen y el pipeline de build en `build.pkr.hcl`
Crear el archivo primario de especificación de Packer que monta provisioners, ejecuta playbooks de Ansible, sanitiza la identidad de la máquina y registra los metadatos de los artefactos.

Escribir `build.pkr.hcl`:

```hcl
# build.pkr.hcl
source "docker" "ubuntu_base" {
  image      = var.base_image
  commit     = true
  changes    = [
    "ENV APP_VERSION=${var.app_version}",
    "ENV BUILD_ENV=${var.build_environment}",
    "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]",
    "WORKDIR /var/www/app"
  ]
}

build {
  name = "hardened-ubuntu-build"
  sources = [
    "source.docker.ubuntu_base"
  ]

  # Provisioner 1: Bootstrap minimal dependencies required for Ansible
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update && apt-get install -y --no-install-recommends software-properties-common curl git python3-pip ansible",
      "mkdir -p /var/www/app /etc/cloud"
    ]
  }

  # Provisioner 2: Run local Ansible Playbook for system configuration
  provisioner "ansible-local" {
    playbook_file = "ansible/site.yml"
  }

  # Provisioner 3: Image Sanitization Script (Sanitize machine-id, SSH host keys, logs)
  provisioner "shell" {
    script = "scripts/cleanup.sh"
  }

  # Post-Processor: Output artifact metadata manifest
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
```

---

##### Paso 4: Crear el playbook local de Ansible y el script de entrypoint
Crear el playbook de configuración del sistema y el script de entrypoint en tiempo de ejecución referenciados por la plantilla de Packer.

Escribir `ansible/site.yml`:

```yaml
---
- name: Hardened Base Image Provisioning
  hosts: localhost
  connection: local
  tasks:
    - name: Create app execution group
      ansible.builtin.group:
        name: appuser
        gid: 2000
        state: present

    - name: Create app execution user
      ansible.builtin.user:
        name: appuser
        uid: 2000
        group: appuser
        shell: /bin/bash
        home: /home/appuser

    - name: Deploy application environment release tag
      ansible.builtin.copy:
        dest: /etc/build_release
        content: |
          BUILD_DATE={{ ansible_date_time.iso8601 }}
          SYS_IMAGE_VERSION=2.4.0
        mode: '0644'
```

Escribir `scripts/cleanup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Executing System Image Sanitization ==="

# 1. Clear Apt Caches & Unused Packages
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Reset Systemd Machine ID (Forces regeneration on first boot)
if [ -f /etc/machine-id ]; then
    > /etc/machine-id
fi
if [ -f /var/lib/dbus/machine-id ]; then
    rm -f /var/lib/dbus/machine-id
fi

# 3. Purge SSH Host Keys (Prevents duplicate SSH host identity across instances)
rm -f /etc/ssh/ssh_host_*

# 4. Truncate system log files
find /var/log -type f -exec truncate -s 0 {} \;

# 5. Create entrypoint runtime script
cat << 'EOF' > /usr/local/bin/entrypoint.sh
#!/bin/bash
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    dpkg-reconfigure openssh-server 2>/dev/null || true
fi
exec "$@"
EOF
chmod +x /usr/local/bin/entrypoint.sh

echo "=== System Sanitization Complete ==="
```

Asegurarse de que `scripts/cleanup.sh` sea ejecutable:

```bash
chmod +x scripts/cleanup.sh
```

---

##### Paso 5: Inicializar plugins, validar la sintaxis de la plantilla y construir la imagen
Ejecutar `packer init` para descargar los binarios requeridos, validar la sintaxis de configuración, formatear el código y ejecutar el pipeline de build con salida stdout completa.

Ejecutar comando:
```bash
packer init .
packer fmt .
packer validate .
```

Salida esperada:
```text
The configuration is valid.
```

Ejecutar comando:
```bash
packer build .
```

Salida esperada:
```text
hardened-ubuntu-build.docker.ubuntu_base: output will be in this color.

==> hardened-ubuntu-build.docker.ubuntu_base: Creating img folder...
==> hardened-ubuntu-build.docker.ubuntu_base: Pulling Docker image: ubuntu:22.04
    hardened-ubuntu-build.docker.ubuntu_base: 22.04: Pulling from library/ubuntu
    hardened-ubuntu-build.docker.ubuntu_base: Digest: sha256:aab4c9cd...
    hardened-ubuntu-build.docker.ubuntu_base: Status: Image is up to date for ubuntu:22.04
==> hardened-ubuntu-build.docker.ubuntu_base: Starting container...
    hardened-ubuntu-build.docker.ubuntu_base: Container ID: a1b2c3d4e5f6
==> hardened-ubuntu-build.docker.ubuntu_base: Provisioning with shell script...
    hardened-ubuntu-build.docker.ubuntu_base: Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease
    hardened-ubuntu-build.docker.ubuntu_base: Setting up software-properties-common...
==> hardened-ubuntu-build.docker.ubuntu_base: Executing Ansible Locally...
    hardened-ubuntu-build.docker.ubuntu_base: PLAY [Hardened Base Image Provisioning] ********************************
    hardened-ubuntu-build.docker.ubuntu_base: TASK [Create app execution group] ***************************************
    hardened-ubuntu-build.docker.ubuntu_base: changed: [localhost]
    hardened-ubuntu-build.docker.ubuntu_base: TASK [Create app execution user] ****************************************
    hardened-ubuntu-build.docker.ubuntu_base: changed: [localhost]
    hardened-ubuntu-build.docker.ubuntu_base: TASK [Deploy application environment release tag] **********************
    hardened-ubuntu-build.docker.ubuntu_base: changed: [localhost]
==> hardened-ubuntu-build.docker.ubuntu_base: Provisioning with shell script: scripts/cleanup.sh
    hardened-ubuntu-build.docker.ubuntu_base: === Executing System Image Sanitization ===
    hardened-ubuntu-build.docker.ubuntu_base: === System Sanitization Complete ===
==> hardened-ubuntu-build.docker.ubuntu_base: Committing the container...
    hardened-ubuntu-build.docker.ubuntu_base: Image ID: sha256:8f9e0a1b2c3d4e5f...
==> hardened-ubuntu-build.docker.ubuntu_base: Killing the container: a1b2c3d4e5f6
==> hardened-ubuntu-build.docker.ubuntu_base: Running post-processor: manifest
Build 'hardened-ubuntu-build.docker.ubuntu_base' finished after 42 seconds.

==> Builds finished. The artifacts of successful builds are:
--> hardened-ubuntu-build.docker.ubuntu_base: Imported Docker image sha256:8f9e0a1b2c3d4e5f... with tags [hardened-ubuntu-build-1723018800]:latest
```

---

##### Paso 6: Verificar metadatos de artefactos de build y limpieza de la imagen
Inspeccionar el archivo `manifest.json` generado y verificar que los identificadores de seguridad del sistema local se hayan eliminado correctamente.

Ejecutar comando:
```bash
cat manifest.json
```

Salida esperada:
```json
{
  "builds": [
    {
      "name": "hardened-ubuntu-build",
      "builder_type": "docker",
      "build_time": 1723018800,
      "files": null,
      "artifact_id": "sha256:8f9e0a1b2c3d4e5f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f",
      "packets": null,
      "custom_data": null
    }
  ],
  "last_run_uuid": "e4d3c2b1-a098-4765-8321-fedcba987654"
}
```

Ejecutar el contenedor para verificar la sanitización del ID de la máquina:
```bash
docker run --rm sha256:8f9e0a1b2c3d4e5f cat /etc/build_release
```

Salida esperada:
```text
BUILD_DATE=2026-08-07T12:00:00Z
SYS_IMAGE_VERSION=2.4.0
```

---

#### Preguntas de verificación (Lab 1)

1. **¿Por qué es crítico truncar `/etc/machine-id` y eliminar `/etc/ssh/ssh_host_*` durante la etapa de sanitización de la imagen (`cleanup.sh`) antes de tomar un snapshot final de la VM o hacer commit de una imagen de contenedor golden?**
   - A) Para minimizar el tamaño total de la imagen de disco eliminando registros de caché temporales.
   - B) Para garantizar que cada instancia iniciada genere una identidad del sistema, UUID de D-Bus e identidad criptográfica SSH únicas, evitando vulnerabilidades de man-in-the-middle y colisiones de IP/DHCP en todo el clúster.
   - C) Porque el motor de build de Packer falla la validación si los archivos de configuración del sistema superan los 4KB.
   - D) Para permitir que `cloud-init` reinstale python3 y ansible en el próximo inicio del sistema.

2. **En Packer HCL2, ¿cuál es la distinción funcional exacta entre un bloque `source` y un bloque `build`?**
   - A) Los bloques `source` definen configuraciones de builder reutilizables (driver de infraestructura, imagen base, credenciales); los bloques `build` combinan sources con provisioners y post-processors para ejecutar el pipeline de build.
   - B) Los bloques `source` ejecutan provisioners de shell; los bloques `build` ejecutan solo post-processors.
   - C) Los bloques `source` compilan HCL a JSON; los bloques `build` ejecutan solicitudes API contra proveedores de nube.
   - D) Los bloques `source` se requieren solo para builds locales de Docker; los cloud builders (AWS AMI, QEMU) solo requieren bloques `build`.

---

#### Lab 2: Matriz de imágenes multi-objetivo, auditoría de seguridad y resolución avanzada de problemas de diagnóstico

##### Objetivo del ejercicio
Implementar un pipeline de build multi-objetivo combinando objetivos de imagen concurrentes (base de Docker y objetivos de QEMU/VM en la nube), integrar auditoría automatizada de cumplimiento de seguridad y ejecutar flujos de trabajo de depuración reales utilizando las herramientas de inspección del motor de Packer (`PACKER_LOG`, `-debug` y `packer console`).

---

##### Paso 1: Construir una plantilla de build multi-origen en paralelo
Crear `multi-build.pkr.hcl` para definir múltiples objetivos de ejecución que construyan de forma concurrente a partir de una línea base de provisioners unificada.

Escribir `multi-build.pkr.hcl`:

```hcl
# multi-build.pkr.hcl
packer {
  required_plugins {
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
  }
}

source "docker" "ubuntu_x86" {
  image  = "ubuntu:22.04"
  commit = true
}

source "docker" "alpine_edge" {
  image  = "alpine:latest"
  commit = true
}

build {
  name = "multi-arch-matrix"
  sources = [
    "source.docker.ubuntu_x86",
    "source.docker.alpine_edge"
  ]

  # Dynamic Provisioner execution targeting specific sources using source.type / source.name conditionals
  provisioner "shell" {
    only = ["docker.ubuntu_x86"]
    inline = [
      "apt-get update && apt-get install -y curl security-checks",
      "echo 'Ubuntu target verified' > /etc/target_marker"
    ]
  }

  provisioner "shell" {
    only = ["docker.alpine_edge"]
    inline = [
      "apk add --no-cache curl bash",
      "echo 'Alpine target verified' > /etc/target_marker"
    ]
  }

  # Shared Provisioner executed across ALL sources in the build matrix
  provisioner "shell" {
    inline = [
      "echo 'Executing common security assertion baseline'",
      "test -s /etc/target_marker"
    ]
  }

  post-processor "manifest" {
    output     = "matrix-manifest.json"
    strip_path = true
  }
}
```

---

##### Paso 2: Depuración de fallos de build a través de `PACKER_LOG` y rastreo de entorno
Cuando los provisioners se cuelgan, las claves SSH fallan al negociar o las APIs de proveedores de nube devuelven errores HTTP 40x/50x, la salida estándar de la CLI de Packer es insuficiente. Establezca `PACKER_LOG=1` y redirija stderr/stdout para aislar la comunicación interna gRPC del plugin.

Ejecutar un dry-run a nivel de depuración con rastreo detallado del motor:

Ejecutar comando:
```bash
PACKER_LOG=1 PACKER_LOG_PATH="packer-debug.log" packer build multi-build.pkr.hcl
```

Inspeccionar la salida del log para el envío de llamadas gRPC y las negociaciones de claves SSH:

Ejecutar comando:
```bash
head -n 25 packer-debug.log
```

Fragmento de salida de log esperada:
```text
2026/08/07 12:15:00 [INFO] Packer version: 1.10.0
2026/08/07 12:15:00 Checking plugin github.com/hashicorp/docker v1.0.8...
2026/08/07 12:15:00 Starting plugin /home/dalmine/.packer.d/plugins/github.com/hashicorp/docker/packer-plugin-docker_v1.0.8_x5.0_linux_amd64
2026/08/07 12:15:00 Waiting for RPC server to start...
2026/08/07 12:15:00 plugin address: /tmp/packer-plugin-3928104810
2026/08/07 12:15:00 ui: ==> multi-arch-matrix.docker.ubuntu_x86: Preparing build environment...
2026/08/07 12:15:01 [DEBUG] Docker client initialized with API version 1.41
2026/08/07 12:15:01 Executing provisioner: shell
2026/08/07 12:15:01 [DEBUG] Opening communicator stream over stdin/stdout...
```

---

##### Paso 3: Resolución interactiva de problemas con `packer build -debug`
Al configurar instancias de nube complejas (por ejemplo, AWS EC2, QEMU, OpenStack), los fallos de scripts terminan la VM de build inmediatamente de forma predeterminada, destruyendo toda la evidencia forense. El uso de `-debug` pausa la ejecución antes de cada paso, lo que permite a los ingenieros inspeccionar la máquina objetivo en vivo a través de SSH.

Demostrar el pausado interactivo paso a paso:

Ejecutar comando:
```bash
packer build -debug multi-build.pkr.hcl
```

Salida esperada:
```text
==> multi-arch-matrix.docker.ubuntu_x86: Pausing at required step: Starting container.
==> multi-arch-matrix.docker.ubuntu_x86: Press enter to continue.
```

En este prompt, en una sesión de terminal separada, inspeccione directamente el contenedor de build temporal:

Ejecutar comando (en terminal secundaria):
```bash
docker ps --filter "ancestor=ubuntu:22.04"
```

Salida esperada:
```text
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS         PORTS     NAMES
c9e8d7f6a5b4   ubuntu:22.04   "packer-builder-docker"  15 seconds ago   Up 14 seconds            pedantic_hawking
```

Ingresar a la instancia de build de VM/contenedor en ejecución para depurar en vivo:
```bash
docker exec -it c9e8d7f6a5b4 /bin/bash
```

Dentro del objetivo de build:
```bash
cat /etc/os-release
exit
```

Regrese a la terminal primaria y presione `Enter` para permitir que Packer complete los pasos del build.

---

##### Paso 4: Evaluar expresiones mediante `packer console`
`packer console` inicia un entorno REPL interactivo para probar variables, funciones y evaluaciones de datos dinámicos de HCL2 antes de ejecutar pipelines de imágenes de larga duración.

Ejecutar comando:
```bash
packer console multi-build.pkr.hcl
```

Sesiones REPL interactivas:

```text
> var.base_image
"ubuntu:22.04"
> legacy_isotime("2006-01-02-150405")
"2026-08-07-122000"
> upper(var.build_environment)
"PRODUCTION"
> exit
```

---

#### Preguntas de verificación (Lab 2)

1. **Al resolver problemas de un fallo intermitente de un script de provisioner durante un build de Packer dirigido a AWS EC2 o QEMU, ¿qué flag de ejecución impide que Packer termine inmediatamente la instancia de VM temporal tras un error?**
   - A) `--force`
   - B) `-debug`
   - C) `-on-error=ask` or `-debug`
   - D) `PACKER_LOG=0`

2. **En una definición de build multi-origen de Packer HCL2 que contiene 4 builders de origen distintos, ¿cómo puede un SRE restringir un bloque de provisioner de auditoría de seguridad específico para que se ejecute SOLO en el origen de builder RHEL llamado `source.qemu.rhel_8`?**
   - A) By adding `except = ["qemu.rhel_8"]` to the provisioner block.
   - B) By setting `only = ["source.qemu.rhel_8"]` inside the provisioner block.
   - C) By creating a separate `packer.hcl` file for every OS builder.
   - D) Provisioners cannot be conditionally filtered across sources within the same `build` block.

3. **¿Cuál es el rol estructural del post-processor `manifest` en un pipeline de build de imágenes del sistema en producción?**
   - A) It dynamically writes cloud-init UserData to the target image filesystem prior to system shutdown.
   - B) It generates a structured JSON file detailing built artifacts, builder types, completion timestamps, and artifact IDs (AMI IDs, image SHAs) for downstream deployment consumption.
   - C) It converts container layers into ISO 9660 bootable disk files.
   - D) It verifies GPG signatures of upstream Debian apt package mirrors.

---

### <details><summary>Respuestas y explicaciones detalladas</summary>

#### Respuestas del Lab 1

##### Pregunta 1
- **Respuesta correcta**: **B**
- **Explicación técnica profunda**:
  Cuando un sistema operativo Linux arranca, `systemd` lee `/etc/machine-id` (o genera uno si no existe o está vacío) para identificar de forma única la instalación del SO para registros (journald), comunicación IPC D-Bus e identificadores de la pila de red (DHCP Client ID). De manera similar, los demonios de SSH utilizan pares de claves de host almacenados en `/etc/ssh/ssh_host_*` para autenticar el servidor ante los clientes que se conectan.
  
  Si se captura una imagen de sistema golden *sin* purgar estos archivos:
  1. Cada instancia iniciada desde esa imagen golden comparte el **mismo machine-id exacto**. Esto causa anomalías de red graves, como que los servidores DHCP asignen direcciones IP idénticas a múltiples VMs debido a identificadores de cliente coincidentes.
  2. Cada instancia comparte las **mismas claves privadas de host SSH exactas**. Un atacante que comprometa o intercepte una VM puede realizar un descifrado de tipo man-in-the-middle (MITM) contra el tráfico enrutado a cualquier otra VM iniciada desde la misma imagen base.
  
  Truncar `/etc/machine-id` (estableciéndolo en 0 bytes) y eliminar `/etc/ssh/ssh_host_*` fuerza a `systemd` y `openssh-server` a regenerar machine IDs y pares de claves criptográficas de host únicos durante la secuencia de arranque inicial de las instancias recién provisionadas.

##### Pregunta 2
- **Respuesta correcta**: **A**
- **Explicación técnica profunda**:
  En la arquitectura de sintaxis de Packer HCL2:
  - El bloque `source` define **cómo crear instancias de cómputo** en un proveedor de virtualización o motor de contenedores específico. Incluye configuración a nivel de hipervisor, tamaños de máquina, credenciales, parámetros de red y especificaciones de imagen base.
  - El bloque `build` define **qué hacer con esas instancias de cómputo**. Importa uno o más bloques `source`, define el pipeline de ejecución secuencial de bloques `provisioner` (que mutan el estado del SO) y configura bloques `post-processor` (que manejan el empaquetado e indexación de artefactos).
  
  Este desacoplamiento permite a los ingenieros reutilizar un único bloque de aprovisionamiento estandarizado (por ejemplo, un script de *CIS Hardening*) a través de múltiples fuentes de hipervisor (por ejemplo, AWS EBS, Azure Managed Disk, QEMU KVM, Docker) simultáneamente.

---

#### Respuestas del Lab 2

##### Pregunta 1
- **Respuesta correcta**: **C**
- **Explicación técnica profunda**:
  De forma predeterminada, si cualquier comando dentro de un provisioner devuelve un código de salida diferente de cero, Packer aborta inmediatamente la ejecución, envía llamadas API para destruir la instancia de cómputo temporal (VM de EC2, instancia de QEMU) y limpia los recursos. Esto evita incurrir en costos de facturación en la nube innecesarios, pero hace imposible la depuración forense.
  
  - Pasar `-debug` fuerza a Packer a pausar la ejecución después de *cada paso* y esperar la confirmación manual del usuario (tecla Enter). Mientras está pausado, el usuario puede inspeccionar en vivo la instancia de build en ejecución, leer archivos de log dentro de `/var/log` o inspeccionar el estado del sistema mediante SSH.
  - Pasar `-on-error=ask` configura Packer para que se ejecute normalmente hasta que ocurra un error. Cuando falla un provisioner, detiene la limpieza y le pregunta al operador de forma interactiva si desea reintentar el paso, limpiar inmediatamente o conservar la instancia para una investigación interactiva a través de SSH.

##### Pregunta 2
- **Respuesta correcta**: **B**
- **Explicación técnica profunda**:
  Dentro de un bloque `build` de Packer HCL2, los provisioners se ejecutan de forma predeterminada en todas las fuentes (`sources`) declaradas. Para ejecutar o omitir selectivamente provisioners según el builder objetivo:
  - El meta-argumento `only` toma un arreglo de etiquetas de origen (con formato `["source.type.name"]` o `["builder_type.source_name"]`). El provisioner se ejecuta **únicamente** cuando el objetivo coincide con uno de los elementos declarados.
  - Por el contrario, el meta-argumento `except` excluye las fuentes declaradas.
  
  `except = ["qemu.rhel_8"]` ejecutaría el provisioner en *todo excepto* RHEL 8, lo cual es exactamente lo inverso a lo requerido en la pregunta.

##### Pregunta 3
- **Respuesta correcta**: **B**
- **Explicación técnica profunda**:
  El post-processor `manifest` actúa como puente entre la creación de imágenes (Packer) y el despliegue de infraestructura (Terraform, Ansible, pipelines de GitOps). 
  
  Cuando Packer termina de construir imágenes en objetivos de la nube multirregionales (por ejemplo, creando las AMIs `ami-0a1b2c3d4e5f6` en `us-east-1` y `ami-0f9e8d7c6b5a4` en `eu-west-1`), el post-processor `manifest` escribe estos identificadores de artefactos generados, marcas de tiempo de build y checksums SHA-256 en un archivo determinista `manifest.json`. Los pipelines de automatización de CI/CD analizan este archivo JSON (usando herramientas como `jq`) para inyectar las IDs de AMI recién baked directamente en los archivos de variables de Terraform o manifests de despliegue de Kubernetes.

</details>