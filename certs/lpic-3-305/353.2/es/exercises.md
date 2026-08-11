# Ejercicios Guiados — Tema 353.2: Packer
### LPIC-3 305 (examen 305-300, versión 3.0) — Peso del objetivo: 3.33

Estos ejercicios te guían para construir imágenes de sistema con **HashiCorp Packer** tal como se hace en producción: plantillas HCL2, gestión de plugins, una construcción real con QEMU, provisioners, post-processors, variables y los puntos de interoperabilidad con Vagrant y Terraform que menciona el objetivo del examen.

**Prerrequisitos del laboratorio** — un host Linux con:
- KVM disponible (`ls -l /dev/kvm` devuelve un dispositivo de caracteres; tu usuario está en el grupo `kvm`)
- `qemu-system-x86_64`, `qemu-img`, `xorriso` (o `genisoimage`) instalados
- ~4 GB de disco libre y HTTPS saliente
- Packer 1.7 o posterior (este laboratorio está escrito contra `v1.12.0`)

A lo largo del ejercicio, ejecutá los comandos desde un directorio de trabajo limpio, por ejemplo `~/packer-lab`.

> Fuentes de referencia:
> - Objetivos del examen LPI 305 — https://www.lpi.org/our-certifications/exam-305-objectives/
> - Documentación de Packer — https://developer.hashicorp.com/packer/docs
> - Plugin del builder QEMU — https://developer.hashicorp.com/packer/integrations/hashicorp/qemu

---

## Part 1 — Install Packer and understand its architecture

**Pasos**

1. Instalá Packer desde el repositorio APT de HashiCorp (Debian/Ubuntu) y confirmá el binario:

   ```bash
   wget -O- https://apt.releases.hashicorp.com/gpg | \
     sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
     https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
     sudo tee /etc/apt/sources.list.d/hashicorp.list
   sudo apt-get update && sudo apt-get install -y packer
   packer version
   ```

   Esperado:

   ```
   Packer v1.12.0
   ```

2. Listá los subcomandos de nivel superior y fijate en los nombrados en el objetivo (`build`, `fmt`, `hcl2_upgrade`, `init`, `inspect`, `validate`):

   ```bash
   packer --help
   ```

   Salida abreviada:

   ```
   Usage: packer [--version] [--help] <command> [<args>]

   Available commands are:
       build           build image(s) from template
       console         creates a console for testing variable interpolation
       fix             fixes templates from old versions of packer
       fmt             Rewrites HCL2 config files to canonical format
       hcl2_upgrade    transform a JSON template into an HCL2 configuration
       init            Install missing plugins or upgrade plugins
       inspect         see components of a template
       plugins         Interact with Packer plugins and catalog
       validate        check that a template is valid
       version         Prints the Packer version
   ```

3. Listá qué plugins están instalados actualmente (ninguno aún, en una instalación nueva):

   ```bash
   packer plugins installed
   ```

   Esperado en una máquina limpia: sin salida (exit 0).

**Preguntas de comprensión**

- **Q1.** Nombrá los tres tipos de componentes que conforman una construcción de Packer e indicá, en una oración cada uno, de qué son responsables.
- **Q2.** Desde Packer 1.7, ¿dónde viven realmente los builders como QEMU, Amazon EBS o VMware, y qué significa eso para el binario `packer` que acabás de instalar?
- **Q3.** Packer produce *imágenes de máquina*. ¿Cuál es la diferencia fundamental entre lo que hace Packer y lo que hace una corrida de gestión de configuración (o Terraform) en el momento del despliegue?

---

## Part 2 — Write your first HCL2 template and validate it (no build yet)

Vas a describir una construcción para una **imagen cloud de Debian 12 (bookworm)** usando el builder de QEMU, y luego usar `init`, `fmt`, `validate` e `inspect` para trabajar con ella *sin* ejecutar la construcción.

**Pasos**

1. Creá `debian.pkr.hcl`:

   ```hcl
   packer {
     required_plugins {
       qemu = {
         version = ">= 1.1.0"
         source  = "github.com/hashicorp/qemu"
       }
     }
   }

   variable "iso_url" {
     type    = string
     default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
   }

   variable "disk_size" {
     type    = string
     default = "10G"
   }

   source "qemu" "debian" {
     # Build FROM an existing qcow2 disk image rather than an installer ISO.
     iso_url      = var.iso_url
     iso_checksum = "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
     disk_image   = true

     output_directory = "output-debian"
     vm_name          = "debian-12.qcow2"
     format           = "qcow2"
     disk_size        = var.disk_size
     disk_interface   = "virtio"
     net_device       = "virtio-net"

     accelerator = "kvm"
     memory      = 1024
     cpus        = 2
     headless    = true

     # NoCloud seed: cloud-init creates the 'packer' login Packer will SSH into.
     cd_label = "cidata"
     cd_content = {
       "meta-data" = ""
       "user-data" = <<-EOF
         #cloud-config
         ssh_pwauth: true
         users:
           - name: packer
             groups: [sudo]
             shell: /bin/bash
             sudo: "ALL=(ALL) NOPASSWD:ALL"
             lock_passwd: false
             # Password is 'packer' (mkpasswd -m sha-512). Lab-only credential.
             passwd: "$6$rounds=4096$saltsalt$0Xq0i/EXAMPLEHASHREPLACEME."
       EOF
     }

     ssh_username = "packer"
     ssh_password = "packer"
     ssh_timeout  = "10m"

     shutdown_command = "echo 'packer' | sudo -S shutdown -P now"
   }

   build {
     name    = "debian-cloud"
     sources = ["source.qemu.debian"]
   }
   ```

   > Para un laboratorio funcional, reemplazá el hash de `passwd` por el tuyo propio: `mkpasswd -m sha-512 packer`.

2. Instalá el plugin declarado en `required_plugins`:

   ```bash
   packer init .
   ```

   Esperado:

   ```
   Installed plugin github.com/hashicorp/qemu v1.1.0 in ".../plugins/github.com/hashicorp/qemu/packer-plugin-qemu_v1.1.0_x5.0_linux_amd64"
   ```

3. Desformateá el archivo a propósito (agregá espacios al comienzo / desalineá los `=`), luego dejá que Packer lo canonicalice:

   ```bash
   packer fmt -diff .
   ```

   Esperado — se imprime el nombre del archivo modificado, precedido por un diff unificado de las correcciones:

   ```
   debian.pkr.hcl
   ```

   Ahora verificá que no queda nada por corregir (útil en CI):

   ```bash
   packer fmt -check -diff .
   echo "exit: $?"
   ```

   Esperado: no se imprimen nombres de archivo, `exit: 0`. (Cuando *sí* hacen falta cambios, `-check` sale con código distinto de cero e imprime los archivos infractores.)

4. Validá la configuración y la sintaxis sin construir:

   ```bash
   packer validate .
   ```

   Esperado:

   ```
   The configuration is valid.
   ```

5. Inspeccioná los componentes y variables de la plantilla:

   ```bash
   packer inspect .
   ```

   Salida abreviada:

   ```
   Packer Inspect: HCL2 mode

   > input-variables:

   var.disk_size: "10G"
   var.iso_url: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

   > builds:

     > debian-cloud:

       sources:
         source.qemu.debian
   ```

**Preguntas de comprensión**

- **Q4.** ¿Qué lee `packer init` para decidir qué instalar, y por qué ejecutarlo es un prerrequisito para `validate` y `build`?
- **Q5.** En CI querés que el pipeline *falle* si una plantilla no está formateada canónicamente, sin modificar archivos. ¿Qué comando exacto logra eso, y cómo detecta el pipeline la falla?
- **Q6.** `packer validate` devolvió "valid", pero la construcción todavía podría fallar en tiempo de ejecución. Dá dos clases de falla que `validate` no puede detectar.
- **Q7.** En la plantilla, ¿cuál es el rol del bloque `cd_content` / `cd_label = "cidata"`, y por qué es necesario al construir *desde un qcow2 cloud* en lugar de desde un ISO de instalación?

---

## Part 3 — Add provisioners and run the build

Los provisioners personalizan la máquina en ejecución después de que arranca y antes de que el disco sea capturado.

**Pasos**

1. Agregá un provisioner `file` y un provisioner `shell` al bloque `build` (insertalos dentro de `build { ... }`, después de `sources`):

   ```hcl
     provisioner "file" {
       content     = "Built by Packer on ${timestamp()}\n"
       destination = "/tmp/build-stamp.txt"
     }

     provisioner "shell" {
       # Ensure cloud-init has finished before we touch the system.
       inline = [
         "cloud-init status --wait || true",
         "sudo install -m 0644 /tmp/build-stamp.txt /etc/build-stamp",
         "sudo apt-get update",
         "sudo apt-get install -y --no-install-recommends qemu-guest-agent",
         "sudo systemctl enable qemu-guest-agent",
         "sudo cloud-init clean --logs",
         "sudo rm -f /etc/machine-id && sudo touch /etc/machine-id",
       ]
     }
   ```

2. Volvé a validar, luego construí:

   ```bash
   packer validate .
   packer build .
   ```

   Log de construcción abreviado:

   ```
   debian-cloud.qemu.debian: output will be in this color.

   ==> debian-cloud.qemu.debian: Retrieving ISO
   ==> debian-cloud.qemu.debian: Trying https://cloud.debian.org/.../debian-12-genericcloud-amd64.qcow2
   ==> debian-cloud.qemu.debian: Creating required virtual machine disks
   ==> debian-cloud.qemu.debian: Starting VM, booting disk image
   ==> debian-cloud.qemu.debian: Waiting 10s for boot...
   ==> debian-cloud.qemu.debian: Connecting to VM via SSH (127.0.0.1:2222)
   ==> debian-cloud.qemu.debian: Connected to SSH!
   ==> debian-cloud.qemu.debian: Uploading a file to /tmp/build-stamp.txt
   ==> debian-cloud.qemu.debian: Provisioning with shell script: /tmp/packer-shell1234
       debian-cloud.qemu.debian: status: done
       debian-cloud.qemu.debian: Reading package lists...
   ==> debian-cloud.qemu.debian: Gracefully halting virtual machine...
   ==> debian-cloud.qemu.debian: Converting hard drive...
   Build 'debian-cloud.qemu.debian' finished after 4 minutes 12 seconds.

   ==> Wait completed after 4 minutes 12 seconds

   ==> Builds finished. The artifacts of successful builds are:
   --> debian-cloud.qemu.debian: VM files in directory: output-debian
   ```

3. Confirmá el artefacto:

   ```bash
   ls -lh output-debian/
   qemu-img info output-debian/debian-12.qcow2
   ```

   Esperado (abreviado):

   ```
   image: output-debian/debian-12.qcow2
   file format: qcow2
   virtual size: 10 GiB (10737418240 bytes)
   ```

4. Si una construcción falla mientras estás iterando, mantené la VM viva para poder entrar por SSH y depurar en lugar de destruirla:

   ```bash
   packer build -on-error=ask .
   ```

**Preguntas de comprensión**

- **Q8.** ¿En qué orden se ejecutan los provisioners `file` y `shell`, y qué determina ese orden?
- **Q9.** ¿Por qué el provisioner shell ejecuta `cloud-init clean` y reinicia `/etc/machine-id` cerca del final? ¿Qué problema de producción causa saltearse esto?
- **Q10.** Durante la iteración, un script de un provisioner falla. Compará `-on-error=ask` con el comportamiento por defecto y explicá por qué el primero acorta el ciclo de depuración.
- **Q11.** Necesitás ejecutar *el mismo* provisioner shell a través de varios bloques `source` distintos (QEMU y, más adelante, una AMI). ¿Cómo te permite el bloque `build` evitar duplicar el provisioner?

---

## Part 4 — Post-processors: package a Vagrant box and a manifest

Los post-processors toman el artefacto de la construcción y lo transforman, suben o reempaquetan. Este es además el punto de interoperabilidad **Packer ↔ Vagrant** del objetivo.

**Pasos**

1. Agregá una cadena de post-processors al bloque `build` (después de los provisioners):

   ```hcl
     post-processor "vagrant" {
       # QEMU artifacts map to the libvirt Vagrant provider.
       output               = "debian-12.{{.Provider}}.box"
       compression_level    = 9
       keep_input_artifact  = true
     }

     post-processor "manifest" {
       output     = "manifest.json"
       strip_path = true
     }
   ```

2. Volvé a ejecutar la construcción:

   ```bash
   packer build .
   ```

   Nueva cola del log:

   ```
   ==> debian-cloud.qemu.debian: Running post-processor: (type vagrant)
   ==> debian-cloud.qemu.debian (vagrant): Creating Vagrant box for 'libvirt' provider
       debian-cloud.qemu.debian (vagrant): Compressing: debian-12.qcow2
   ==> debian-cloud.qemu.debian: Running post-processor: (type manifest)

   ==> Builds finished. The artifacts of successful builds are:
   --> debian-cloud.qemu.debian: VM files in directory: output-debian
   --> debian-cloud.qemu.debian: 'libvirt' provider box: debian-12.libvirt.box
   --> debian-cloud.qemu.debian: 1 files were created:
   manifest.json
   ```

3. Inspeccioná el manifiesto (el registro legible por máquina que consumen otras herramientas):

   ```bash
   cat manifest.json
   ```

   Forma esperada:

   ```json
   {
     "builds": [
       {
         "name": "debian",
         "builder_type": "qemu",
         "files": [
           { "name": "debian-12.libvirt.box", "size": 512344123 }
         ],
         "artifact_id": "VM",
         "packer_run_uuid": "e2b0...",
         "custom_data": null
       }
     ],
     "last_run_uuid": "e2b0..."
   }
   ```

4. Consumí la box con Vagrant para probar la interoperabilidad:

   ```bash
   vagrant box add debian-12-lab debian-12.libvirt.box
   vagrant box list | grep debian-12-lab
   ```

   Esperado:

   ```
   debian-12-lab (libvirt, 0)
   ```

**Preguntas de comprensión**

- **Q12.** Contrastá un **provisioner** con un **post-processor** en términos de *dónde* y *cuándo* se ejecuta cada uno.
- **Q13.** El post-processor `vagrant` emitió una box para el provider `libvirt` sin que vos nombraras un provider. ¿Cómo lo decidió, y a qué se interpola `{{.Provider}}`?
- **Q14.** ¿Qué controla `keep_input_artifact`, y qué le pasa al qcow2 crudo si lo dejás en su valor por defecto?
- **Q15.** Los post-processors pueden *encadenarse* (anidarse) para que uno alimente al siguiente, versus listarse *en secuencia* para que cada uno consuma el artefacto de la construcción. En la plantilla de arriba, ¿`vagrant` y `manifest` están encadenados o en secuencia — y cómo escribirías una cadena?

---

## Part 5 — Variables, variable files, and environment variables

**Pasos**

1. Sobreescribí una variable en la línea de comandos:

   ```bash
   packer build -var 'disk_size=20G' .
   ```

2. Poné las sobreescrituras en un archivo de variables y pasalo explícitamente:

   ```bash
   cat > lab.pkrvars.hcl <<'EOF'
   iso_url   = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
   disk_size = "16G"
   EOF

   packer build -var-file=lab.pkrvars.hcl .
   ```

   > Un archivo llamado `*.auto.pkrvars.hcl` (o `variables.pkrvars.hcl`) se carga **automáticamente**, sin el flag `-var-file`.

3. Establecé la *misma* variable a través del entorno usando el prefijo `PKR_VAR_`:

   ```bash
   export PKR_VAR_disk_size="24G"
   packer validate .        # picks up 24G with no flags
   ```

4. Confirmá la precedencia de Packer combinando fuentes e imprimiendo el valor efectivo con `packer console`:

   ```bash
   PKR_VAR_disk_size="24G" packer console -var 'disk_size=32G' .
   ```

   En el prompt:

   ```
   > var.disk_size
   32G
   ```

5. Activá el logging detallado a un archivo (depuración de grado operacional):

   ```bash
   PACKER_LOG=1 PACKER_LOG_PATH=packer-debug.log packer build .
   tail -n 5 packer-debug.log
   ```

6. Apuntá la caché de descargas de Packer a otro lado (útil en runners compartidos):

   ```bash
   PACKER_CACHE_DIR=/var/cache/packer packer build .
   ```

**Preguntas de comprensión**

- **Q16.** Listá la precedencia de variables de Packer de **menor** a **mayor**, dados: `default`, `-var`, `PKR_VAR_*`, y un `*.auto.pkrvars.hcl` cargado automáticamente.
- **Q17.** Tenés que inyectar una contraseña de registry sin escribirla en ningún archivo `.hcl` ni en los flags del historial de shell. ¿Qué mecanismo de esta parte encaja, y cómo declarás la variable para que no se imprima en los logs?
- **Q18.** ¿Qué hacen `PACKER_LOG` y `PACKER_LOG_PATH`, y por qué dirigir el log a un archivo es preferible a leer stdout durante una construcción larga?
- **Q19.** Distinguí `PKR_VAR_disk_size` (una *variable de entrada*) de `PACKER_CACHE_DIR` (una variable de entorno de *configuración* de Packer). ¿Ambas se consumen de la misma manera?

---

## Part 6 — Interoperability: JSON→HCL2, Terraform, and QEMU

El objetivo prueba explícitamente la interacción de Packer con **Vagrant, Terraform y QEMU**, y el conocimiento de ambos formatos de plantilla **JSON y HCL2**.

**Pasos**

1. Heredás una plantilla JSON heredada. Convertila a HCL2:

   ```bash
   cat > old-template.json <<'EOF'
   {
     "builders": [
       {
         "type": "qemu",
         "iso_url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2",
         "iso_checksum": "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS",
         "disk_image": true,
         "output_directory": "output-legacy",
         "accelerator": "kvm",
         "ssh_username": "packer",
         "ssh_password": "packer",
         "shutdown_command": "echo packer | sudo -S shutdown -P now"
       }
     ],
     "provisioners": [
       { "type": "shell", "inline": ["echo hello from legacy"] }
     ]
   }
   EOF

   packer hcl2_upgrade old-template.json
   ls old-template.json.pkr.hcl
   ```

   Esperado:

   ```
   Successfully created old-template.json.pkr.hcl
   old-template.json.pkr.hcl
   ```

2. Registrá el artefacto construido para que Terraform pueda consumirlo. El `manifest.json` de la Part 4 ya te da un identificador legible por máquina. En un stack de Terraform lo leerías:

   ```hcl
   # main.tf — Terraform consumes what Packer produced
   locals {
     packer_manifest = jsondecode(file("${path.module}/manifest.json"))
     image_path      = one([
       for b in local.packer_manifest.builds :
       b.files[0].name if b.builder_type == "qemu"
     ])
   }

   resource "libvirt_volume" "debian" {
     name   = "debian-base"
     source = local.image_path   # the qcow2/box Packer built
   }
   ```

   Validá el cableado (sin necesidad de apply):

   ```bash
   terraform init && terraform validate
   ```

   Esperado:

   ```
   Success! The configuration is valid.
   ```

3. Confirmá que la construcción QEMU corrió a través de virtualización real observando el huésped durante una construcción en otra terminal:

   ```bash
   pgrep -a qemu-system-x86_64
   ```

   Esperado (abreviado) durante una construcción activa:

   ```
   34211 qemu-system-x86_64 -accel kvm -m 1024M ... -drive file=output-debian/debian-12.qcow2 ...
   ```

**Preguntas de comprensión**

- **Q20.** Packer y Terraform son ambas herramientas de HashiCorp que leen HCL, sin embargo ocupan etapas diferentes del ciclo de vida. Enunciá la división del trabajo en una oración y nombrá el artefacto que se pasa de una a la otra.
- **Q21.** Después de ejecutar `hcl2_upgrade`, ¿qué mapeo le ocurrió a los arreglos JSON `"builders"` y `"provisioners"` en la salida HCL2, y qué bloque de nivel superior de HCL2 vincula un source con sus provisioners?
- **Q22.** El builder QEMU estableció `accelerator = "kvm"`. ¿Qué se pierde si bajás a la emulación por software por defecto (`tcg`), y qué característica del host debe estar presente para que `kvm` funcione?
- **Q23.** Para los traspasos Packer→Vagrant y Packer→Terraform, ¿qué único archivo generado es el contrato fiable y legible por máquina entre las etapas, y qué post-processor lo produce?

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** (1) Los **Builders** crean y arrancan una máquina en una plataforma (QEMU, AWS, VMware, Docker, …) y, al final, la capturan como imagen. (2) Los **Provisioners** se ejecutan dentro de la máquina arrancada para instalar y configurar software (shell, file, Ansible, …). (3) Los **Post-processors** actúan sobre el artefacto terminado — reempaquetándolo (Vagrant box), comprimiéndolo, subiéndolo o escribiendo un manifiesto.

**Q2.** Desde 1.7 los builders, provisioners y la mayoría de los post-processors se distribuyen como **plugins externos** (binarios multicomponente como `packer-plugin-qemu`), no dentro del binario central. El binario `packer` es pequeño y genérico; la capacidad de QEMU llega solo después de que `packer init` instala `github.com/hashicorp/qemu`. Por eso una instalación nueva no muestra plugins.

**Q3.** Packer realiza trabajo de **tiempo de horneado de la imagen (image bake time)**: produce una imagen inmutable, pre-horneada, una sola vez, por adelantado. La gestión de configuración y Terraform actúan en **tiempo de despliegue/ejecución (deploy/run time)** — configuran o levantan infraestructura repetidamente a partir de esa imagen. Packer responde "qué hay en la imagen", Terraform/CM responden "cuántas, dónde y conectadas a qué".

**Q4.** `packer init` lee el/los bloque(s) `packer { required_plugins { … } }` e instala/actualiza los binarios de plugin correspondientes en el directorio de plugins. `validate` y `build` necesitan el código real del plugin para interpretar `source "qemu"`, así que fallan con "unknown source/plugin" hasta que se haya ejecutado `init`.

**Q5.** `packer fmt -check -diff .`. Con `-check`, Packer **no** reescribe archivos; imprime las rutas que no están formateadas canónicamente y **sale con código distinto de cero** (código de salida 3). CI trata ese código de salida distinto de cero como un paso fallido.

**Q6.** Todo lo que dependa del **estado en tiempo de ejecución**, por ejemplo: (a) un script shell de un provisioner que falla a mitad de la construcción (paquete `apt` incorrecto, timeout de red); (b) un `iso_url` inalcanzable/incorrecto o un checksum que no coincide; (c) SSH que nunca levanta porque cloud-init no creó el usuario; (d) recursos insuficientes en el host (sin `/dev/kvm`). `validate` solo verifica configuración/sintaxis y disponibilidad de plugins.

**Q7.** `cd_content` escribe en memoria un **ISO seed NoCloud (cidata)** que contiene el `user-data`/`meta-data` de cloud-init, y `cd_label = "cidata"` es la etiqueta de volumen que cloud-init busca. Un qcow2 cloud de fábrica **no tiene instalador interactivo ni login preestablecido** — espera una fuente de datos de cloud-init que cree usuarios y habilite SSH. Sin el seed, Packer arrancaría la imagen pero nunca podría entrar por SSH. (Un ISO de instalación, en cambio, usa un preseed/kickstart entregado vía boot commands, así que no necesita cidata.)

**Q8.** Se ejecutan **de arriba hacia abajo en el orden escrito en el bloque `build`**: el provisioner `file` sube primero, luego se ejecuta el provisioner `shell` — que es por lo que el paso shell puede `install`ar el archivo que se acaba de subir. El ordenamiento es puramente léxico dentro del bloque.

**Q9.** Las imágenes cloud capturan identidad por instancia durante el primer arranque. Dejar el estado en caché de cloud-init y un `/etc/machine-id` poblado en la imagen significa que **cada VM clonada a partir de ella comparte el mismo machine-id y el estado "ya corrió" de cloud-init** — causando arriendos DHCP/IPs duplicados, identidades de journald de systemd duplicadas, y que cloud-init no vuelva a correr en instancias nuevas. `cloud-init clean` + truncar `machine-id` fuerza la regeneración en el primer arranque de cada clon.

**Q10.** Por defecto un provisioner fallido hace que Packer **limpie y destruya la VM**, así que el estado que falla desaparece. `-on-error=ask` **pausa y deja la VM en ejecución**, ofreciendo reintentar, limpiar o abortar — podés entrar por SSH a la máquina viva, reproducir el comando que falla y arreglar el script sin volver a correr toda la construcción desde cero. (`-on-error=abort` la deja sin preguntar.)

**Q11.** El bloque `build` lista **múltiples `sources`** y aplica las mismas cláusulas de provisioner/post-processor a todos ellos: `sources = ["source.qemu.debian", "source.amazon-ebs.debian"]`. Los provisioners se escriben una vez y se ejecutan contra cada source, así que no hay duplicación.

**Q12.** Un **provisioner** se ejecuta **dentro de la máquina temporal mientras está arrancada**, antes de que se capture la imagen (instala paquetes, edita archivos). Un **post-processor** se ejecuta **en el host, después de que el artefacto existe** — nunca toca el huésped en ejecución; transforma/sube/registra la imagen terminada.

**Q13.** El post-processor `vagrant` **infiere el provider de Vagrant a partir del tipo de builder**: un artefacto QEMU mapea al provider `libvirt`. `{{.Provider}}` es una variable de plantilla que se interpola a ese nombre de provider, así que `output = "debian-12.{{.Provider}}.box"` se convierte en `debian-12.libvirt.box`.

**Q14.** `keep_input_artifact` controla si la **entrada al post-processor (el qcow2 crudo en `output-debian/`)** se preserva después de haber sido consumida. Dejado en su valor por defecto (`false` para el post-processor vagrant), el qcow2 crudo se borraría una vez construida la box; establecerlo en `true` mantiene ambos.

**Q15.** Tal como están escritos son **secuenciales**: cada uno es un bloque `post-processor` separado, y ambos consumen el artefacto de la *construcción* de forma independiente (el manifiesto registra la box). Una **cadena** se escribe como un único bloque `post-processors` (en plural) que contiene bloques anidados, donde cada uno alimenta al siguiente:
```hcl
post-processors {
  post-processor "vagrant" { … }
  post-processor "shell-local" { … }   # receives the .box from vagrant
}
```

**Q16.** De menor → mayor: **`default`** (en el bloque `variable`) → variables de entorno **`PKR_VAR_*`** → archivos **`*.auto.pkrvars.hcl` cargados automáticamente** → **`-var` / `-var-file` en la línea de comandos** (gana el último entre estos, evaluados de izquierda a derecha). Por eso la `console` en el paso 4 imprimió `32G` (el `-var`) por sobre `24G` (el `PKR_VAR_`).

**Q17.** Usá una variable de entorno **`PKR_VAR_`** (nunca aparece en un archivo ni como un flag visible). Declará la variable con **`sensitive = true`**:
```hcl
variable "registry_password" { type = string, sensitive = true }
```
para que Packer la censure en la salida de la construcción y en los logs.

**Q18.** `PACKER_LOG=1` habilita el logging de depuración interno verboso; `PACKER_LOG_PATH=<file>` envía ese log a un archivo en lugar de a stderr. Dirigirlo a un archivo mantiene el progreso de construcción legible y coloreado en tu terminal, preserva la traza completa para una construcción de varios minutos, y te da algo para grepear/adjuntar a un ticket después.

**Q19.** No — se consumen de forma diferente. `PKR_VAR_disk_size` es una **variable de entrada** ligada a una `variable "disk_size"` declarada y usable como `var.disk_size` dentro de la plantilla. `PACKER_CACHE_DIR` es una **variable de configuración/comportamiento de Packer** leída por la herramienta central en sí (dónde cachear los ISOs); *no* está expuesta como `var.*` ni corresponde a ningún bloque `variable`.

**Q20.** **Packer construye la imagen inmutable; Terraform aprovisiona infraestructura a partir de esa imagen.** El artefacto de traspaso es la **imagen construida/su identificador** (un id de AMI, una ruta de qcow2/box) — comúnmente expuesto vía `manifest.json` (o, en el ecosistema de HashiCorp, el registro HCP Packer consumido por las fuentes de datos `hcp_packer_*` de Terraform).

**Q21.** Cada elemento del arreglo JSON `"builders"` se convirtió en un bloque de nivel superior **`source "<type>" "<name>"`**; el arreglo `"provisioners"` se convirtió en bloques **`provisioner`**. Un bloque **`build { sources = [...]  provisioner {...} }`** generado vincula el/los source(s) con los provisioners — la pieza que JSON expresaba implícitamente ahora es explícita.

**Q22.** Bajar a `tcg` usa **emulación de CPU puramente por software**, que es dramáticamente más lenta (una construcción que tarda minutos con KVM puede tardar muchas veces más) y no puede usar las extensiones de virtualización por hardware. Para `accelerator = "kvm"` el host debe tener **virtualización por hardware (Intel VT-x / AMD-V) habilitada y el módulo del kernel KVM cargado**, exponiendo `/dev/kvm`.

**Q23.** **`manifest.json`**, producido por el post-processor **`manifest`**. Es el registro estable y legible por máquina de lo que se construyó (ids de artefactos, nombres de archivo, tamaños, tipo de builder, UUID de la corrida), de modo que los pipelines de Vagrant/Terraform puedan localizar el artefacto exacto sin escrapear los logs de construcción.

</details>