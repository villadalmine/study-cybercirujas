# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
## Topic 3.1: Virtual Machine Deployment (Weight: 6.67)

### Official References
- **LPI DevOps Tools Engineer Overview & Objectives**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- **Vagrant Official Documentation**: [https://developer.hashicorp.com/vagrant/docs](https://developer.hashicorp.com/vagrant/docs)
- **Cloud-init Official Documentation**: [https://cloudinit.readthedocs.io/en/latest/](https://cloudinit.readthedocs.io/en/latest/)

---

### Architectural Background & Internal Mechanics

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                     HOST MACHINE                                       │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                  Vagrant CLI                                     │  │
│  │   Reads Vagrantfile ──► Resolves Box Cache ──► Generates SSH & Network Specs     │  │
│  └────────────────────────┬──────────────────────────────────┬──────────────────────┘  │
│                           │                                  │                         │
│                           ▼                                  ▼                         │
│  ┌─────────────────────────────────┐               ┌────────────────────────────────┐  │
│  │  Hypervisor Provider (VirtualBox│               │   Virtual Storage Engine       │  │
│  │  / KVM-Libvirt / VMware)        │               │   Box Base Image (.vmdk / .qcow2)  │  │
│  └────────────────┬────────────────┘               └────────────────┬───────────────┘  │
└───────────────────┼─────────────────────────────────────────────────┼──────────────────┘
                    │                                                 │
                    ▼                                                 ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 GUEST VIRTUAL MACHINE                                  │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                          Early Boot & Kernel Initialization                      │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │                                            │
│                                           ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         Cloud-init Execution Stages (systemd)                    │  │
│  │                                                                                  │  │
│  │  1. cloud-init-local.service (Generator: Reads NoCloud / ConfigDrive metadata)   │  │
│  │  2. cloud-init.service       (Network: Applies network config & fetches remote) │  │
│  │  3. cloud-config.service     (Config: Processes write_files, users, bootcmd)    │  │
│  │  4. cloud-final.service      (Final: Executes packages, runcmd, user scripts)    │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │                                            │
│                                           ▼                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                      Vagrant Provisioners (Post Boot Layer)                      │  │
│  │       Shell Scripts ──► File Uploads ──► Ansible / Docker Configurations         │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Key Architecture Trade-Offs
1. **Estrategias de sincronización de carpetas en Vagrant**:
   - **VirtualBox Shared Folders (vboxfs)**: Por defecto, no requiere configuración en el host, pero tiene bajo rendimiento de I/O y carece de capacidades de file locking de alto rendimiento.
   - **NFS (Network File System)**: Alto rendimiento, ideal para bases de código grandes. Requiere acceso a root en el host (modificación de `sudoers`) y la ejecución de un daemon a nivel del host.
   - **Rsync**: Máxima velocidad de lectura y cero sobrecarga de daemons en ejecución en el host/guest. Desventaja: Sincronización unidireccional manual o por eventos (`vagrant rsync-auto`), no es un binding bidireccional en tiempo real.

2. **Etapas de arranque de Cloud-init vs. Provisionamiento de Vagrant**:
   - **Cloud-init**: Se ejecuta de forma nativa dentro del OS guest durante el arranque inicial a través de `systemd`. Ideal para el bootstrapping a nivel del OS (interfaces de red, crecimiento de particiones de disco, cuentas de usuario base, propiedades iniciales del sistema).
   - **Vagrant Provisioners**: Se ejecutan externamente sobre SSH/WinRM después de que la pila de red de la VM y el daemon SSH están activos. Ideal para la personalización del entorno, flujos de trabajo de despliegue y orquestación del estado entre nodos.

---

### Exercise 1: Multi-Machine Vagrant Topology with Advanced Synchronization & Provisioning

#### Step 1: Create a Multi-Machine Infrastructure Manifest
Crea un directorio de trabajo y define un `Vagrantfile` multi-máquina que despliegue un load balancer (`lb01`) y dos servidores web (`app01`, `app02`) con red privada aislada, límites explícitos de recursos, opciones personalizadas de rsync y provisionadores multietapa.

Ejecutá los siguientes comandos en tu shell:

```bash
mkdir -p ~/sre-lab/vagrant-multi
cd ~/sre-lab/vagrant-multi
cat <<'EOF' > Vagrantfile
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.box_check_update = false

  # Global Provider Customization
  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.linked_clone = true
  end

  # Web Application Nodes
  (1..2).each do |i|
    config.vm.define "app0#{i}" do |app|
      app.vm.hostname = "app0#{i}.production.internal"
      app.vm.network "private_network", ip: "192.168.56.1#{i}"
      
      app.vm.provider "virtualbox" do |vb|
        vb.memory = 1024
        vb.cpus = 1
        vb.name = "prod-app0#{i}"
      end

      # High-performance rsync folder sync configuration
      app.vm.synced_folder "./app", "/var/www/html", type: "rsync",
        rsync__args: ["--verbose", "--archive", "--delete", "-z"],
        rsync__exclude: [".git/", "node_modules/"]

      # Inline Shell Provisioner
      app.vm.provision "shell", inline: <<-SHELL
        set -euo pipefail
        apt-get update -qq
        apt-get install -y -qq nginx html2text
        echo "<h1>Node app0#{i} - Host: $(hostname)</h1>" > /var/www/html/index.html
        systemctl restart nginx
      SHELL
    end
  end

  # Load Balancer Node
  config.vm.define "lb01" do |lb|
    lb.vm.hostname = "lb01.production.internal"
    lb.vm.network "private_network", ip: "192.168.56.10"
    lb.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true

    lb.vm.provider "virtualbox" do |vb|
      vb.memory = 512
      vb.cpus = 1
      vb.name = "prod-lb01"
    end

    lb.vm.provision "shell", inline: <<-SHELL
      set -euo pipefail
      apt-get update -qq
      apt-get install -y -qq haproxy
      cat <<HAEXPR > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 2000
    user haproxy
    group haproxy

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    retries 3
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend http-in
    bind *:80
    default_backend web-backend

backend web-backend
    balance roundrobin
    server app01 192.168.56.11:80 check
    server app02 192.168.56.12:80 check
HAEXPR
      systemctl restart haproxy
    SHELL
  end
end
EOF
mkdir -p app
echo "<div>Base Application Code</div>" > app/index.html
```

#### Step 2: Provision the Multi-Machine Topology
Iniciá el entorno y verificá los pasos de provisionamiento en todas las máquinas de forma concurrente.

Ejecutá:
```bash
vagrant up
```

Salida esperada:
```text
Bringing machine 'app01' up with 'virtualbox' provider...
Bringing machine 'app02' up with 'virtualbox' provider...
Bringing machine 'lb01' up with 'virtualbox' provider...
==> app01: Importing base box 'ubuntu/focal64'...
==> app01: Matching MAC address for light network approval...
==> app01: Setting the name of the VM: prod-app01
==> app01: Clearing any previously set network interfaces...
==> app01: Preparing network interfaces based on configuration...
    app01: Adapter 1: nat
    app01: Adapter 2: hostonly
==> app01: Forwarding ports...
==> app01: Booting VM...
==> app01: Waiting for machine to boot. This may take a few minutes...
==> app01: Machine booted and ready!
==> app01: Setting hostname...
==> app01: Configuring and enabling network interfaces...
==> app01: Rsyncing folder: /home/student/sre-lab/vagrant-multi/app/ => /var/www/html
==> app01: Running provisioner: shell...
    app01: Running: inline script
...
==> lb01: Machine booted and ready!
==> lb01: Setting hostname...
==> lb01: Forwarding ports...
    lb01: 80 (guest) => 8080 (host) (adapter 1)
==> lb01: Running provisioner: shell...
    lb01: Running: inline script
```

#### Step 3: Inspect Cluster State, Port Mappings, and SSH Configurations
Ejecutá diagnósticos para verificar los parámetros en tiempo de ejecución y extraer la configuración SSH precisa utilizada por Vagrant para integraciones con herramientas automatizadas (por ejemplo, Ansible/Terraform).

Ejecutá:
```bash
vagrant status
vagrant port lb01
vagrant ssh-config app01
```

Salida esperada:
```text
Current machine states:

app01                     running (virtualbox)
app02                     running (virtualbox)
lb01                      running (virtualbox)

The VMs are running. To stop this VM, you can run `vagrant halt` to
shut it down, or you can run `vagrant destroy` to delete it.

The forwarded ports for this VM are listed below. In the description column,
you can see the machine identifier and the provider identifier.

Forwarded ports list for 'lb01':
Port 80 (guest) => Port 8080 (host)

Host app01
  HostName 127.0.0.1
  User vagrant
  Port 2222
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile /home/student/sre-lab/vagrant-multi/.vagrant/machines/app01/virtualbox/private_key
  IdentitiesOnly yes
  LogLevel FATAL
```

#### Step 4: Verify End-to-End Load Balancing and Execute Triggered Synchronization
Validá la distribución del tráfico HTTP a través de `lb01` y verificá el comportamiento de la carpeta rsync.

Ejecutá:
```bash
curl -s http://localhost:8080
curl -s http://localhost:8080
echo "<h1>Production v2.0</h1>" > app/index.html
vagrant rsync app01
vagrant ssh app01 -c "cat /var/www/html/index.html"
```

Salida esperada:
```text
<h1>Node app01 - Host: app01.production.internal</h1>
<h1>Node app02 - Host: app02.production.internal</h1>
==> app01: Rsyncing folder: /home/student/sre-lab/vagrant-multi/app/ => /var/www/html
<h1>Production v2.0</h1>
```

---

#### Verification Questions (Block 1)

1. **Pregunta 1.1**: Si ejecutás `vagrant rsync-auto` en una terminal y luego actualizás `app/index.html`, ¿qué mecanismo interno del kernel en el host Linux le permite a Vagrant detectar las modificaciones de archivos, y cómo contrasta esto con VirtualBox Shared Folders (`vboxfs`)?
2. **Pregunta 1.2**: Al inspeccionar `vagrant ssh-config app01` se muestra `HostName 127.0.0.1` y `Port 2222` en lugar de `192.168.56.11` y `Port 22`. ¿Por qué Vagrant se comunica por defecto con el guest a través de puertos reenviados en localhost en lugar de la IP de la red privada?
3. **Pregunta 1.3**: En el `Vagrantfile`, se configura `config.vm.provider "virtualbox" do |vb| vb.linked_clone = true end`. ¿Cuál es el impacto en el almacenamiento de disco y el rendimiento al usar clones vinculados (linked clones) en lugar de clones completos (full clones) al instanciar 10 nodos idénticos?

---

### Exercise 2: Cloud-Init Boot Stage Analysis & Production User-Data Provisioning

#### Step 1: Design a Production `#cloud-config` User-Data Manifest
Crea un archivo de inicialización de cloud-init que ejecute la configuración inicial de arranque, provisione cuentas de sistema seguras, escriba archivos de configuración drop-in de systemd, administre puntos de montaje de disco y ejecute scripts finales de posinstalación.

Ejecutá:
```bash
mkdir -p ~/sre-lab/cloud-init-lab
cd ~/sre-lab/cloud-init-lab

cat <<'EOF' > user-data.yaml
#cloud-config
version: v1
hostname: telemetry-node-01
fqdn: telemetry-node-01.infra.internal
manage_etc_hosts: true

# Early boot commands executed before packages or network initialization
bootcmd:
  - echo "bootcmd execution timestamp: $(date -u +%s)" >> /var/log/bootcmd-marker.log

# System Users Provisioning
users:
  - name: sysadmin
    gecos: System Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, adm]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplePublicKeyForLPI701DevOpsEng sysadmin@infra

# File Creation via write_files module
write_files:
  - path: /etc/systemd/system/node-exporter-health.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=Node Exporter Healthcheck Service
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'echo "Node Exporter status: Active" > /tmp/exporter-health.log'

      [Install]
      WantedBy=multi-user.target

  - path: /etc/sysctl.d/99-custom-networking.conf
    permissions: '0644'
    owner: root:root
    content: |
      net.core.somaxconn = 4096
      net.ipv4.tcp_tw_reuse = 1

# Package Installation
packages:
  - curl
  - jq
  - prometheus-node-exporter

# System Command Execution in cloud-final stage
runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now node-exporter-health.service
  - systemctl restart prometheus-node-exporter
  - [ sh, -c, 'echo "cloud-init completed at $(date)" > /etc/cloud-init-finished' ]
EOF
```

#### Step 2: Validate Cloud-Init Schema Syntax
Antes de inyectar user-data en una máquina virtual o instancia Cloud, validá su sintaxis contra el motor oficial de JSON schema integrado en `cloud-init`.

Ejecutá:
```bash
cloud-init schema --config-file user-data.yaml
```

Salida esperada:
```text
Valid cloud-config file user-data.yaml
```

#### Step 3: Simulate Cloud-Init Datasource Integration with Vagrant NoCloud Driver
Integrá el manifiesto `user-data.yaml` en un entorno de Vagrant utilizando una estructura de unidad local `NoCloud` (simulando user-data de AWS EC2 o ISOs de metadatos de Cloud-Init en KVM).

Ejecutá:
```bash
cat <<'EOF' > Vagrantfile
# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.hostname = "telemetry-node-01"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 1024
    vb.cpus = 1
  end

  # Inject cloud-init user-data using custom trigger and raw disk/file placement
  config.vm.provision "file", source: "user-data.yaml", destination: "/tmp/user-data.yaml"
  
  config.vm.provision "shell", inline: <<-SHELL
    set -euo pipefail
    mkdir -p /var/lib/cloud/seed/nocloud-net
    cp /tmp/user-data.yaml /var/lib/cloud/seed/nocloud-net/user-data
    echo "instance-id: i-local-lab-01" > /var/lib/cloud/seed/nocloud-net/meta-data
    
    # Force cloud-init re-initialization to simulate first-boot stages
    cloud-init clean --logs
    cloud-init init --local
    cloud-init init
    cloud-init modules --mode config
    cloud-init modules --mode final
  SHELL
end
EOF

vagrant up
```

Salida esperada:
```text
==> default: Running provisioner: shell...
    default: Running: inline script
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'init-local' at Fri, 07 Aug 2026 04:50:00 +0000. Up 12.34 seconds.
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'init' at Fri, 07 Aug 2026 04:50:02 +0000. Up 14.56 seconds.
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'modules:config' at Fri, 07 Aug 2026 04:50:05 +0000. Up 17.89 seconds.
    default: Cloud-init v. 22.2-0ubuntu1~20.04.1 running 'modules:final' at Fri, 07 Aug 2026 04:50:10 +0000. Up 22.11 seconds.
```

#### Step 4: Advanced Boot Stage Analysis and Execution Profiling
Inspeccioná la secuencia interna de ejecución de etapas, consultá los targets de systemd de `cloud-init` y evaluá las marcas de tiempo de ejecución para cada etapa.

Ejecutá:
```bash
vagrant ssh -c "cloud-init status --long"
vagrant ssh -c "cloud-init analyze boot"
vagrant ssh -c "cloud-init analyze show"
```

Salida esperada:
```text
status: done
extended_status: done
boot_status_code: enabled
last_update: Fri, 07 Aug 2026 04:50:10 +0000
detail: DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud-net/][identified=true]

-- Boot Record --
  Stage 1: cloud-init-local.service started at 04:50:00 (duration: 0.85s)
  Stage 2: cloud-init.service started at 04:50:02 (duration: 2.10s)
  Stage 3: cloud-config.service started at 04:50:05 (duration: 3.24s)
  Stage 4: cloud-final.service started at 04:50:10 (duration: 5.40s)
Total time elapsed: 11.59s

-- Detail Analysis --
00:00.0000s - Generator read datasource NoCloud
00:00.8500s - Applied networking configuration
00:02.9500s - Wrote file /etc/systemd/system/node-exporter-health.service
00:03.1000s - Wrote file /etc/sysctl.d/99-custom-networking.conf
00:05.3400s - Installed packages: prometheus-node-exporter, jq, curl
00:10.7400s - Ran command: sysctl --system
00:11.5900s - Ran command: systemctl enable --now node-exporter-health.service
```

---

#### Verification Questions (Block 2)

1. **Pregunta 2.1**: Explicá la diferencia funcional exacta y el tiempo de ejecución entre `bootcmd` y `runcmd` dentro del ciclo de vida de 4 etapas de cloud-init (`cloud-init-local.service` vs `cloud-final.service`).
2. **Pregunta 2.2**: Si un desarrollador ubica un comando de instalación de paquetes (`apt-get install -y nginx`) dentro de `bootcmd` en lugar de usar la clave nativa `packages:` o `runcmd:`, ¿por qué fallará esta operación en una imagen cloud estándar?
3. **Pregunta 2.3**: ¿Qué archivos de artefactos de diagnóstico en `/var/log/` distinguen los logs de ejecución estándar del stdout/stderr emitidos por scripts especificados bajo `runcmd`?

---

### Exercise 3: Advanced Diagnostic Workflows & Hybrid System Provisioning

#### Step 1: Simulate and Debug a Cloud-Init & Vagrant Provisioning Failure
Crea un escenario de falla intencional que involucre errores de sintaxis en YAML, dependencias faltantes de systemd y rutas de provisionadores inválidas para dominar las herramientas de diagnóstico.

Ejecutá:
```bash
cd ~/sre-lab/cloud-init-lab

cat <<'EOF' > broken-user-data.yaml
#cloud-config
version: v1
write_files:
  - path: /etc/broken.conf
    permissions: 0644
    owner: root:root
    content: |
      key=value
  # TAB character intentionally inserted below for syntax error failure
	bad_indentation: true
runcmd:
  - systemctl start non-existent-service.service
EOF
```

Ejecutá la validación de esquema para capturar errores de sintaxis antes del despliegue:

Ejecutá:
```bash
cloud-init schema --config-file broken-user-data.yaml
```

Salida esperada:
```text
Error: Cloud config schema errors: write_files.0.permissions: 644 is not of type 'string'
Line 9 Column 1: Found bad character '\t' (TAB) in indentation.
Invalid cloud-config file broken-user-data.yaml
```

#### Step 2: Fix Syntax and Debug Stage Errors via System Logs
Corregí la sangría del YAML y luego ejecutá el comando de systemd con errores para analizar el manejo de errores a nivel del sistema en los logs de cloud-init.

Ejecutá:
```bash
cat <<'EOF' > user-data-runtime-error.yaml
#cloud-config
version: v1
runcmd:
  - systemctl start non-existent-daemon.service
EOF

# Simulate execution inside vagrant VM
vagrant ssh -c "sudo cloud-init clean --logs"
vagrant ssh -c "sudo cp /tmp/user-data.yaml /var/lib/cloud/seed/nocloud-net/user-data"
vagrant ssh -c "sudo cloud-init single --name runcmd"
```

Salida esperada:
```text
...
Failed to start non-existent-daemon.service: Unit non-existent-daemon.service not found.
Unexpected error occurred handling section runcmd
```

#### Step 3: Execute Full Log Trace Extraction
Extraé los detalles de diagnóstico de `/var/log/cloud-init.log` y `/var/log/cloud-init-output.log` usando `grep` y logs del sistema.

Ejecutá:
```bash
vagrant ssh -c "sudo grep -C 3 'non-existent-daemon' /var/log/cloud-init.log"
vagrant ssh -c "sudo tail -n 20 /var/log/cloud-init-output.log"
```

Salida esperada:
```text
2026-08-07 04:52:15,123 - subp.py[DEBUG]: Running command ['systemctl', 'start', 'non-existent-daemon.service'] with allowed return codes [0]
2026-08-07 04:52:15,130 - subp.py[WARNING]: Unexpected error occurred handling section runcmd: Failed running command ['systemctl', 'start', 'non-existent-daemon.service'] exit code(5)
2026-08-07 04:52:15,135 - util.py[WARNING]: Failed to run module runcmd (scripts-user in final stage)
...
Failed to start non-existent-daemon.service: Unit non-existent-daemon.service not found.
```

#### Step 4: Environment Cleanup
Destruí las máquinas virtuales del laboratorio y eliminá los directorios temporales.

Ejecutá:
```bash
cd ~/sre-lab/vagrant-multi && vagrant destroy -f
cd ~/sre-lab/cloud-init-lab && vagrant destroy -f
rm -rf ~/sre-lab
```

Salida esperada:
```text
==> app01: Forcing shutdown of VM...
==> app01: Destroying VM and associated drives...
==> app02: Forcing shutdown of VM...
==> app02: Destroying VM and associated drives...
==> lb01: Forcing shutdown of VM...
==> lb01: Destroying VM and associated drives...
==> default: Forcing shutdown of VM...
==> default: Destroying VM and associated drives...
```

---

#### Verification Questions (Block 3)

1. **Pregunta 3.1**: Al depurar problemas en el ciclo de vida de Vagrant durante la instanciación de una VM (como un timeout en el handshake de SSH o un cuelgue en la inicialización del provider), ¿qué variable de entorno debe configurarse y cómo filtrás la salida para observar la interacción subyacente de Vagrant con VirtualBox/KVM?
2. **Pregunta 3.2**: ¿Cuál es la diferencia entre `/var/log/cloud-init.log` y `/var/log/cloud-init-output.log`?
3. **Pregunta 3.3**: ¿Cómo garantiza cloud-init que los módulos de `user-data` (como `packages` o `runcmd`) se ejecuten **solo una vez** en el primer arranque de la instancia, y qué comando exacto limpia este estado para forzar su reejecución?

---

<details>
<summary>Answers & Deep-Dive Explanations</summary>

### Block 1 Answers

- **Respuesta 1.1**:
  - `vagrant rsync-auto` se apoya en las APIs de monitoreo del sistema de archivos del kernel del host (**`inotify`** en Linux, `fsevents` en macOS o `ReadDirectoryChangesW` en Windows). El proceso en el host abre un rastreo (watch) de `inotify` sobre la estructura de carpetas local (`./app`). Cuando ocurre una mutación en un descriptor de archivo, `inotify` dispara un evento hacia Vagrant, el cual invoca el binario de `rsync` para sincronizar los cambios sobre SSH hacia el guest.
  - En contraste, VirtualBox Shared Folders (`vboxfs`) utiliza un módulo driver del kernel (`vboxsf`) cargado en el kernel del OS guest. El kernel del guest enruta las operaciones VFS directamente al proceso del hipervisor de VirtualBox a través de llamadas a dispositivos PCI de VirtualBox Guest Additions (`/dev/vboxguest`). `vboxfs` opera en tiempo real sin comandos de sincronización explícitos, pero incurre en una alta sobrecarga de cambio de contexto a través del límite de memoria del hipervisor durante operaciones intensivas de I/O de lectura/escritura.

- **Respuesta 1.2**:
  - Vagrant utiliza reenvió de puertos local (`127.0.0.1:2222 -> Guest:22`) sobre el adaptador de red NAT del host (Adaptador 1 en VirtualBox) porque se garantiza que NAT funcione en todos los sistemas operativos host sin requerir privilegios elevados en el host (`sudo`), adaptadores de red personalizados en el host ni puentes de red preexistentes.
  - Las redes privadas (interfaces Host-Only) son interfaces secundarias configuradas más adelante en la secuencia de arranque. Depender de redes host-only para la conectividad SSH inicial puede fallar si los adaptadores host-only están mal configurados, bloqueados por firewalls del host o entran en conflicto con rutas IP existentes. El reenvío de puertos por NAT garantiza una gestión de bootstrap por defecto confiable.

- **Respuesta 1.3**:
  - **Impacto en almacenamiento**: Un clon completo (full clone) duplica el snapshot del disco base del OS (por ejemplo, disco de box base de 2 GB $\times$ 10 VMs = 20 GB de uso de disco en el host). Un clon vinculado (linked clone) crea una imagen diferencial base de solo lectura (disco de la VM Master) compartida entre todas las instancias, creando únicamente pequeños archivos delta copy-on-write (CoW) (`.vdi` o `.qcow2`) para cada nodo. El requerimiento de almacenamiento se reduce de 20 GB a ~2 GB + los cambios delta por nodo.
  - **Impacto en rendimiento**: Los clones vinculados reducen significativamente el tiempo de provisionamiento en disco (`vagrant up` se completa en segundos en lugar de minutos porque se elimina la duplicación de discos). Sin embargo, los 10 nodos compiten por la misma caché de almacenamiento de lectura base compartida en la controladora de disco del host durante operaciones de lectura concurrente intensivas.

---

### Block 2 Answers

- **Respuesta 2.1**:
  - **`bootcmd`**: Se ejecuta en la Etapa 1 (`cloud-init-local.service`) o a principios de la Etapa 2 (`cloud-init.service`). Se ejecuta extremadamente temprano en el ciclo de vida de arranque antes de que se configure la red, antes de que ocurra la expansión de disco y antes de que se obtengan los índices de paquetes.
  - **`runcmd`**: Se ejecuta en la Etapa 4 (`cloud-final.service`), la cual se ejecuta al final de la inicialización del sistema después de que todas las interfaces de red están en línea, se crean los usuarios del sistema, los archivos escritos mediante `write_files` se vuelcan al disco y los paquetes definidos bajo `packages:` han sido instalados.

- **Respuesta 2.2**:
  - Ejecutar `apt-get install -y nginx` dentro de `bootcmd` falla por dos razones:
    1. **No disponibilidad de red**: La Etapa 1 (`cloud-init-local.service`) se ejecuta antes de que la pila de red sea inicializada por `systemd-networkd` o `Netplan`, impidiendo el acceso a repositorios de paquetes externos.
    2. **Almacenamiento/Montajes no configurados**: Es posible que los sistemas de archivos o particiones de disco efímeras definidas en la configuración de cloud-init aún no estén montados.

- **Respuesta 2.3**:
  - **`/var/log/cloud-init.log`**: Contiene la salida estructurada de los logs internos en python de cloud-init, tiempos de ejecución de módulos, detalles de resolución de datasources y transiciones de la máquina de estados interna.
  - **`/var/log/cloud-init-output.log`**: Captura los flujos de stdout y stderr emitidos por procesos creados por módulos de cloud-init (por ejemplo, la salida estándar de consola de `apt-get`, la salida de comandos shell bajo `runcmd` y la salida personalizada de scripts).

---

### Block 3 Answers

- **Respuesta 3.1**:
  - Configurá la variable de entorno `VAGRANT_LOG=debug` (por ejemplo, `VAGRANT_LOG=debug vagrant up`).
  - Filtrá las llamadas de interacción de bajo nivel del provider de VirtualBox o KVM redirigiendo la salida a través de `grep`:
    ```bash
    VAGRANT_LOG=debug vagrant up 2>&1 | grep -i "VBoxManage"
    ```
  - Esto revela las llamadas directas a la CLI del hipervisor (`VBoxManage modifyvm`, `VBoxManage hostonlyif`), mostrando flags exactos de hardware, archivos de bloqueo o fallas de binding de red en la VM.

- **Respuesta 3.2**:
  - `/var/log/cloud-init.log` es el log principal de traza de diagnóstico que detalla *qué* intentó ejecutar cloud-init, qué módulos tuvieron éxito o fallaron e información de traceback del sistema.
  - `/var/log/cloud-init-output.log` es la consola cruda que captura *qué sucedió durante la ejecución* de scripts externos (capturando la salida estándar/error emitida a `/dev/console` durante las etapas de arranque).

- **Respuesta 3.3**:
  - Cloud-init rastrea la ejecución de estado mediante flags de archivos semáforo almacenados en `/var/lib/cloud/instance/sem/` y `/var/lib/cloud/instances/<instance-id>/`. Una vez que un módulo (por ejemplo, `config-runcmd`) finaliza con éxito, se escribe un archivo semáforo. En arranques posteriores, cloud-init detecta estos flags y omite los módulos de ejecución única.
  - Para forzar a cloud-init a purgar su historial de ejecución, limpiar metadatos en caché, eliminar logs y reiniciar todos los semáforos para su reejecución en el próximo arranque, ejecutá:
    ```bash
    sudo cloud-init clean --logs
    ```

</details>