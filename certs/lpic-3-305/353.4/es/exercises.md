# Tema 353.4: Vagrant — Ejercicios guiados

> **Contexto del examen** — LPIC-3 305 (examen 305-300, v3.0), objetivo **353.4 "Vagrant"**, peso **5**.
> Cobertura del objetivo: arquitectura de Vagrant (provider/provisioner), gestión de boxes incluido el registro público, construcción de entornos a partir de un `Vagrantfile`, configuración del entorno (redes, carpetas sincronizadas, ajustes específicos del provider) y aprovisionamiento (file y shell).
> Fuentes primarias: objetivos de LPI <https://www.lpi.org/our-certifications/exam-305-objectives/> · documentación de Vagrant <https://developer.hashicorp.com/vagrant/docs> · `vagrant-libvirt` <https://vagrant-libvirt.github.io/vagrant-libvirt/>

Estos labs están escritos para una estación de trabajo Linux usando el provider **libvirt/KVM** (el provider más relevante para LPIC-3 305), con contrastes hacia VirtualBox allí donde el examen espera que conozcas la diferencia. Todo es ejecutable; las salidas mostradas son representativas, no literales — las versiones y los hashes diferirán en tu host.

---

## Prerrequisitos

Necesitás un stack KVM/libvirt funcional y Vagrant. Ejecutá las comprobaciones de abajo antes de empezar; no continúes si algún comando falla.

```bash
# 1. CPU virtualization extensions present and enabled in firmware
grep -Eoc '(vmx|svm)' /proc/cpuinfo        # any number > 0 is fine

# 2. KVM kernel modules loaded
lsmod | grep -E 'kvm_(intel|amd)'

# 3. libvirt daemon running and you are in the libvirt group
systemctl is-active libvirtd
id -nG | tr ' ' '\n' | grep -x libvirt

# 4. Vagrant and the libvirt plugin
vagrant --version
vagrant plugin list | grep vagrant-libvirt || vagrant plugin install vagrant-libvirt
```

Forma esperada de la salida:

```
2
kvm_intel             487424  0
active
libvirt
Vagrant 2.4.1
vagrant-libvirt (0.12.2, global)
```

**Comprensión**

1. `vagrant up` falla de inmediato con `Call to virConnectOpen failed: ... Permission denied`. ¿Cuáles dos de las cuatro comprobaciones anteriores son las primeras que reexaminarías, y por qué?
2. ¿Por qué el plugin `vagrant-libvirt` tiene que instalarse *por instalación de Vagrant* en lugar de declararse dentro del `Vagrantfile`?

---

## Ejercicio 1 — Arquitectura: las cuatro piezas móviles en un solo `up`

**Objetivo:** ver cómo *box → provider → machine → provisioner* se componen durante un único ciclo de vida.

1. Creá y entrá en un directorio de proyecto limpio:

   ```bash
   mkdir -p ~/vagrant-labs/e1 && cd ~/vagrant-labs/e1
   ```

2. Generá un `Vagrantfile` mínimo ligado a un box específico:

   ```bash
   vagrant init --minimal generic/debian12
   ```

   Esto escribe un `Vagrantfile` de dos líneas. Inspeccionalo:

   ```bash
   cat Vagrantfile
   ```

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"
   end
   ```

3. Levantá la máquina sobre libvirt de forma explícita:

   ```bash
   vagrant up --provider=libvirt
   ```

   Salida representativa (recortada):

   ```
   Bringing machine 'default' up with 'libvirt' provider...
   ==> default: Box 'generic/debian12' could not be found. Attempting to find and install...
       default: Box Provider: libvirt
       default: Box Version: >= 0
   ==> default: Loading metadata for box 'generic/debian12'
       default: URL: https://vagrantcloud.com/api/v2/vagrant/generic/debian12
   ==> default: Adding box 'generic/debian12' (v4.3.12) for provider: libvirt
   ==> default: Creating image (snapshot of base box volume).
   ==> default: Creating domain with the following settings...
       default:  -- Name:              e1_default
       default:  -- Domain type:       kvm
       default:  -- Cpus:              1
       default:  -- Memory:            512M
   ==> default: Waiting for domain to get an IP address...
   ==> default: Machine booted and ready!
   ==> default: Rsyncing folder: /home/you/vagrant-labs/e1/ => /vagrant
   ```

4. Confirmá el estado de la máquina y los objetos libvirt que creó:

   ```bash
   vagrant status
   virsh --connect qemu:///system list
   virsh --connect qemu:///system vol-list default          # the storage pool
   ```

5. Abrí una shell dentro del guest, mirá alrededor y luego salí:

   ```bash
   vagrant ssh -c 'hostname; id; ls -la /vagrant'
   ```

**Comprensión**

3. En el paso 3, tres de las cuatro piezas arquitectónicas son visibles en el log y una está ausente. Nombrá cada pieza, citá la línea del log que prueba que se ejecutó, y decí qué pieza no apareció y por qué.
4. `vagrant status` reporta `running (libvirt)` mientras que `virsh list` muestra el domain como `running`. ¿Qué agrega el `(libvirt)` entre paréntesis que `virsh` no puede decirte, y dónde persiste Vagrant ese dato?
5. Nunca escribiste un nombre de usuario, contraseña ni IP, y sin embargo `vagrant ssh` se conectó. Rastreá cómo supo Vagrant *dónde* y *como quién* conectarse.

---

## Ejercicio 2 — Ajustes específicos del provider y portabilidad

**Objetivo:** dimensionar una máquina mediante bloques de provider y entender por qué el mismo `Vagrantfile` puede apuntar a dos providers.

1. Reemplazá el `Vagrantfile` en `~/vagrant-labs/e1` por:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"

     # Provider-agnostic hints (best-effort mapped by each provider)
     config.vm.provider "libvirt" do |lv|
       lv.memory = 2048
       lv.cpus   = 2
       lv.cpu_mode = "host-passthrough"
       lv.machine_virtual_size = 20   # GiB, grows the backing volume
     end

     # The same box, sized for VirtualBox — used only if you --provider=virtualbox
     config.vm.provider "virtualbox" do |vb|
       vb.memory = 2048
       vb.cpus   = 2
       vb.gui    = false
     end
   end
   ```

2. Validá la sintaxis *sin* arrancar nada:

   ```bash
   vagrant validate
   ```

   ```
   Vagrant validated the configuration successfully.
   ```

3. Aplicá el nuevo dimensionamiento a la máquina que ya está corriendo:

   ```bash
   vagrant reload
   ```

4. Confirmá que el guest ahora ve 2 vCPUs y ~2 GiB de RAM:

   ```bash
   vagrant ssh -c 'nproc; free -m | awk "/Mem:/ {print \$2\" MiB\"}"'
   ```

5. Mostrá que la elección del provider también puede fijarse por entorno en lugar de por flag:

   ```bash
   VAGRANT_DEFAULT_PROVIDER=libvirt vagrant up          # no --provider needed
   ```

**Comprensión**

6. El box `generic/debian12` incluye *imágenes separadas* para libvirt y VirtualBox bajo un mismo nombre. ¿Qué te dice esto sobre lo que realmente es un "box", y cómo elige Vagrant la imagen correcta en el momento del `up`?
7. `lv.cpu_mode = "host-passthrough"` mejora el rendimiento del guest pero reduce una capacidad operativa específica de la VM. ¿Cuál, y por qué importa para una flota que pensás migrar en vivo?
8. Cambiaste `lv.memory` pero ejecutaste `vagrant reload` en lugar de `vagrant provision`. ¿Por qué `reload` es el verbo correcto acá, y qué habría hecho `vagrant provision` en su lugar?

---

## Ejercicio 3 — Gestión de boxes y el registro público

**Objetivo:** gestionar la caché local de boxes y entender los boxes versionados del registro (antes "Vagrant Cloud").

1. Listá lo que hay en caché local y dónde:

   ```bash
   vagrant box list
   ```

   ```
   generic/debian12 (libvirt, 4.3.12)
   ```

2. Agregá un segundo box, con versión fijada, directamente desde el registro:

   ```bash
   vagrant box add almalinux/9 --provider libvirt --box-version 9.5.20241120
   ```

   ```
   ==> box: Loading metadata for box 'almalinux/9'
   ==> box: Adding box 'almalinux/9' (v9.5.20241120) for provider: libvirt
       box: Downloading: https://vagrantcloud.com/almalinux/boxes/9/versions/9.5.20241120/providers/libvirt/amd64/vagrant.box
   ==> box: Successfully added box 'almalinux/9' (v9.5.20241120) for 'libvirt'!
   ```

3. Comprobá si algún box en caché tiene una versión más nueva río arriba:

   ```bash
   vagrant box outdated --global
   ```

4. Inspeccioná los metadatos en disco del box que guarda Vagrant:

   ```bash
   ls ~/.vagrant.d/boxes/
   cat ~/.vagrant.d/boxes/almalinux-VAGRANTSLASH-9/metadata_url
   ```

5. Eliminá una versión específica y luego podá las versiones obsoletas de todos los boxes:

   ```bash
   vagrant box remove almalinux/9 --provider libvirt --box-version 9.5.20241120
   vagrant box prune --dry-run
   ```

**Comprensión**

9. En `vagrant box list`, cada entrada lleva un *provider* y una *versión*. ¿Por qué la terna `(name, provider, version)` — y no solo el nombre — es la verdadera identidad de un box en caché?
10. Un colega escribe `config.vm.box = "almalinux/9"` sin restricción de versión; vos escribís `config.vm.box_version = "~> 9.5"`. Seis meses después, tus dos ejecuciones de `up` producen guests distintos. Explicá el mecanismo y nombrá la directiva de configuración que hace reproducible la construcción.
11. ¿Cuál es la diferencia entre `vagrant box remove` y `vagrant box prune`, y cuál es seguro ejecutar en un host de CI compartido con muchos proyectos activos?

---

## Ejercicio 4 — Redes: puertos redirigidos, redes privadas y públicas

**Objetivo:** exponer un servicio del guest de tres maneras distintas y entender la alcanzabilidad de cada una.

1. Nuevo proyecto:

   ```bash
   mkdir -p ~/vagrant-labs/e4 && cd ~/vagrant-labs/e4
   ```

2. Escribí un `Vagrantfile` que corra un servidor web y cablee los tres tipos de red:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"
     config.vm.hostname = "web01"

     # (a) Port forwarding: host:8080 -> guest:80
     config.vm.network "forwarded_port", guest: 80, host: 8080,
                       host_ip: "127.0.0.1", id: "http"

     # (b) Private (host-only) network with a static address
     config.vm.network "private_network", ip: "192.168.121.50"

     # (c) Public (bridged) network onto the LAN
     config.vm.network "public_network", dev: "virbr0", type: "bridge"

     config.vm.provision "shell", inline: <<-SHELL
       apt-get update -qq
       apt-get install -y -qq nginx
       echo "served by $(hostname) at $(date)" > /var/www/html/index.html
     SHELL
   end
   ```

3. Arrancá y leé de vuelta el cableado de red que Vagrant aplicó:

   ```bash
   vagrant up
   vagrant port                 # show the actual forwarded-port table
   ```

   ```
   The forwarded ports for the machine are listed below. ...
        80 (guest) => 8080 (host)
        22 (guest) => 2222 (host)
   ```

4. Probá cada camino desde el **host**:

   ```bash
   curl -s http://127.0.0.1:8080/          # (a) via forwarded port
   curl -s http://192.168.121.50/          # (b) via private network
   ```

5. Desde dentro del guest, confirmá que las interfaces existen y anotá su orden:

   ```bash
   vagrant ssh -c 'ip -brief addr show'
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   eth0             UP             192.168.121.10/24 ...    # management/NAT
   eth1             UP             192.168.121.50/24 ...    # private_network
   eth2             UP             192.168.1.87/24 ...      # public_network (DHCP from LAN)
   ```

**Comprensión**

12. `curl http://127.0.0.1:8080` funciona desde el host, pero una laptop en la misma Wi‑Fi de oficina no puede alcanzarlo, mientras que *sí* puede alcanzar la dirección del estilo del paso 4(b) mediante bridging. Explicá la alcanzabilidad de cada uno de los tres tipos de red desde (i) el host, (ii) otro guest en la misma red privada, (iii) una máquina separada en la LAN.
13. En el paso 5, la *primera* interfaz `eth0` no es ninguna de las tres que declaraste. ¿Qué es, por qué todo box Vagrant de libvirt la obtiene, y qué se rompe si intentás reconfigurarla o eliminarla?
14. Dos proyectos solicitan ambos `config.vm.network "forwarded_port", guest: 80, host: 8080`. Hacés `vagrant up` del segundo mientras el primero está corriendo. ¿Qué hace Vagrant por defecto, y qué opción controla ese comportamiento?

---

## Ejercicio 5 — Carpetas sincronizadas y sus tipos de transporte

**Objetivo:** comparar los mecanismos de carpetas sincronizadas y ver el montaje por defecto `/vagrant`.

1. En `~/vagrant-labs/e4`, agregá un directorio de datos en el host:

   ```bash
   mkdir -p share && echo "host-authored" > share/note.txt
   ```

2. Extendé el `Vagrantfile` (mantené el bloque de red del Ejercicio 4) con tres declaraciones de carpetas sincronizadas:

   ```ruby
     # Default project share is /vagrant — make its transport explicit
     config.vm.synced_folder ".", "/vagrant", type: "rsync",
                             rsync__exclude: [".git/", "*.box"]

     # A 9p (libvirt-native) live share, read-write
     config.vm.synced_folder "./share", "/srv/share", type: "9p",
                             accessmode: "squash"

     # An NFS share, read-only
     config.vm.synced_folder "./share", "/srv/share-ro", type: "nfs",
                             mount_options: ["ro"]
   ```

3. Recargá para aplicar los montajes:

   ```bash
   vagrant reload
   ```

4. Inspeccioná los montajes y probá la direccionalidad de cada tipo:

   ```bash
   vagrant ssh -c 'mount | grep -E "/vagrant|/srv/share"'
   vagrant ssh -c 'cat /srv/share/note.txt'                 # host -> guest
   vagrant ssh -c 'echo guest-authored >> /srv/share/note.txt'
   cat share/note.txt                                        # guest -> host (9p is live, rw)
   ```

5. Dispará una re-sincronización manual para la carpeta rsync después de editar un archivo del host:

   ```bash
   echo "changed on host" >> share/note.txt
   vagrant rsync                                             # push rsync folders now
   ```

**Comprensión**

15. `/vagrant` existe en el guest incluso si nunca lo declarás. ¿Qué se monta ahí por defecto, y da una razón concreta por la que un script de aprovisionamiento depende de ello?
16. Escribiste un cambio en el host *después* de `vagrant up` y **no** apareció en el guest bajo la carpeta `rsync` hasta que ejecutaste `vagrant rsync`, y sin embargo la misma edición apareció al instante bajo la carpeta `9p`. Explicá la diferencia fundamental entre una carpeta sincronizada con rsync y una carpeta sincronizada con 9p/NFS.
17. El share NFS requirió privilegios de `sudo` en el **host** la primera vez que levantaste la máquina (una edición de `/etc/exports`). ¿Por qué NFS, pero no 9p, necesita root del lado del host, y cuál es el compromiso de seguridad de `accessmode: "squash"`?

---

## Ejercicio 6 — Aprovisionamiento: shell (inline + script) y provisioner de file

**Objetivo:** distinguir los dos provisioners que nombra el objetivo y controlar *cuándo* se ejecutan.

1. Nuevo proyecto con un script auxiliar y un archivo de configuración para enviar:

   ```bash
   mkdir -p ~/vagrant-labs/e6 && cd ~/vagrant-labs/e6
   vagrant init --minimal generic/debian12

   cat > bootstrap.sh <<'EOF'
   #!/usr/bin/env bash
   set -euo pipefail
   apt-get update -qq
   apt-get install -y -qq redis-server
   cp /tmp/redis-overlay.conf /etc/redis/redis.conf.d/overlay.conf 2>/dev/null || true
   systemctl restart redis-server
   redis-cli ping
   EOF

   cat > redis-overlay.conf <<'EOF'
   maxmemory 128mb
   maxmemory-policy allkeys-lru
   EOF
   ```

2. Cableá tres provisioners con orden explícito y política de ejecución:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"

     # (1) file provisioner: copy config into the guest first
     config.vm.provision "ship-conf", type: "file",
                         source: "redis-overlay.conf",
                         destination: "/tmp/redis-overlay.conf"

     # (2) shell provisioner from a script: install & configure
     config.vm.provision "install", type: "shell", path: "bootstrap.sh"

     # (3) inline shell that runs on EVERY up/reload, not just the first
     config.vm.provision "healthcheck", type: "shell",
                         run: "always",
                         inline: "systemctl is-active redis-server"
   end
   ```

3. El primer arranque ejecuta todos los provisioners en el orden declarado:

   ```bash
   vagrant up
   ```

   ```
   ==> default: Running provisioner: ship-conf (file)...
   ==> default: Running provisioner: install (shell)...
       default: PONG
   ==> default: Running provisioner: healthcheck (shell)...
       default: active
   ```

4. Reiniciá y observá qué provisioners se vuelven a ejecutar:

   ```bash
   vagrant reload
   ```

5. Forzá que *todos* los provisioners se ejecuten de nuevo en una máquina ya aprovisionada:

   ```bash
   vagrant provision
   # or, during a reload:  vagrant reload --provision
   ```

**Comprensión**

18. En el `vagrant reload` simple del paso 4, exactamente uno de los tres provisioners se volvió a ejecutar. ¿Cuál, y enunciá la regla general que usa Vagrant para decidir si un provisioner corre?
19. ¿Por qué es siquiera posible reordenar incorrectamente el provisioner de file declarado *antes* del script de shell — es decir, qué pasaría en el primer `up` si `install` estuviera listado antes de `ship-conf`?
20. El provisioner de file copia como el usuario *sin privilegios* `vagrant`, así que no puede escribir en `/etc` directamente — por eso el ejemplo lo deposita en `/tmp` y el script de shell hace el `cp`. Contrastá esto con cómo corre por defecto el provisioner **shell** respecto de los privilegios, y nombrá la opción que lo cambia.
21. Necesitás un secreto traído desde el host en tiempo de aprovisionamiento pero que nunca debe quedar horneado en el box. ¿Qué combinación de provisioner-más-carpeta te da datos del lado del host dentro del guest sin persistirlos en la imagen, y por qué importa `run: "always"` para un secreto que rota?

---

## Ejercicio 7 — Entornos multi-máquina

**Objetivo:** definir más de una VM en un solo `Vagrantfile` y dirigir comandos a máquinas nombradas.

1. Nuevo proyecto:

   ```bash
   mkdir -p ~/vagrant-labs/e7 && cd ~/vagrant-labs/e7
   ```

2. Definí un entorno de dos nodos (un nodo web y un nodo db) sobre una red privada compartida:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"

     config.vm.define "db" do |db|
       db.vm.hostname = "db01"
       db.vm.network "private_network", ip: "192.168.121.20"
       db.vm.provider "libvirt" { |lv| lv.memory = 1024 }
     end

     config.vm.define "web", primary: true do |web|
       web.vm.hostname = "web01"
       web.vm.network "private_network", ip: "192.168.121.10"
       web.vm.provision "shell", inline: "apt-get install -y -qq curl"
     end
   end
   ```

3. Levantá primero solo el nodo de base de datos, luego todo el entorno:

   ```bash
   vagrant up db
   vagrant status
   vagrant up                    # brings up the remaining 'web'
   ```

   ```
   Current machine states:

   db                        running (libvirt)
   web                       running (libvirt)
   ```

4. Dirigí comandos a una máquina por su nombre:

   ```bash
   vagrant ssh web -c 'ping -c1 192.168.121.20'    # web -> db over private net
   vagrant halt db
   ```

5. Mirá cada entorno Vagrant en el host, a lo largo de todos los directorios de proyecto:

   ```bash
   vagrant global-status --prune
   ```

   ```
   id       name    provider state   directory
   -------------------------------------------------------------------
   9f3a1c2  db      libvirt  poweroff /home/you/vagrant-labs/e7
   1b7d5e0  web     libvirt  running  /home/you/vagrant-labs/e7
   ```

**Comprensión**

22. `vagrant ssh` sin nombre de máquina en este proyecto se conecta a `web`, no a `db`. ¿Qué directiva causa eso, y qué les pasa a comandos escuetos como `vagrant ssh` si la quitás?
23. Explicá la diferencia entre `vagrant status` y `vagrant global-status`, y por qué este último necesita `--prune`.
24. Querés que `web` alcance a `db` por hostname, no por IP. Dado el entorno de arriba, ¿cuál es la forma mínima basada en provisioner de lograrlo sin DNS externo, y por qué el orden (`vagrant up db` antes que `web`) *no* alcanza por sí solo?

---

## Ejercicio 8 — Ciclo de vida, introspección y desmontaje

**Objetivo:** consolidar los verbos de la máquina de estados y los comandos de diagnóstico.

1. Volvé a `~/vagrant-labs/e7` y recorré la máquina de estados completa sobre `web`:

   ```bash
   vagrant up web
   vagrant suspend web && vagrant status web       # -> saved
   vagrant resume  web && vagrant status web       # -> running
   vagrant halt    web && vagrant status web       # -> poweroff
   ```

2. Emití un bloque de configuración compatible con OpenSSH para acceso directo por `ssh`:

   ```bash
   vagrant up web
   vagrant ssh-config web
   ```

   ```
   Host web
     HostName 192.168.121.10
     User vagrant
     Port 22
     IdentityFile /home/you/vagrant-labs/e7/.vagrant/machines/web/libvirt/private_key
     IdentitiesOnly yes
     StrictHostKeyChecking no
   ```

3. Usá ese bloque para conectarte sin Vagrant en el medio:

   ```bash
   vagrant ssh-config web > /tmp/web.ssh
   ssh -F /tmp/web.ssh web hostname
   ```

4. Tomá y restaurá un snapshot (libvirt/VirtualBox lo soportan ambos):

   ```bash
   vagrant snapshot save web clean
   vagrant ssh web -c 'sudo rm -rf /etc/nginx'      # break something
   vagrant snapshot restore web clean
   ```

5. Desmontá todo el entorno y confirmá que no queda nada:

   ```bash
   vagrant destroy -f
   vagrant global-status --prune
   virsh --connect qemu:///system list --all | grep e7_ || echo "no residual domains"
   ```

**Comprensión**

25. Distinguí `vagrant halt`, `vagrant suspend` y `vagrant destroy` en términos de qué le pasa a (i) la RAM del guest, (ii) la imagen de disco, y (iii) cuánto tarda el siguiente `up`.
26. `vagrant ssh-config` incrusta `StrictHostKeyChecking no` y una `private_key` por máquina. ¿Por qué ambos son apropiados para VMs de desarrollo efímeras pero una señal de alarma si se copian a un `~/.ssh/config` de producción?
27. Después de `vagrant destroy`, `vagrant box list` todavía muestra `generic/debian12`. ¿Es un bug? Explicá la relación entre una *máquina destruida* y su *box*, y qué comando realmente recupera el espacio en disco del box.

---

<details>
<summary><strong>Respuestas</strong> (clic para expandir)</summary>

**Prerrequisitos**

1. Comprobaciones **3** y **adyacente-a-4**: `Permission denied` en `virConnectOpen` es un problema de autorización, no una funcionalidad faltante. Reexaminá (3) — específicamente tu **membresía de grupo**: debés estar en el grupo `libvirt` *y* haberte reautenticado para que el grupo esté activo en tu sesión actual (`id -nG`); y confirmá que `libvirtd`/`virtqemud` esté efectivamente activo. Las comprobaciones de CPU/módulos-KVM (1–2) producirían un error distinto (la creación del domain fallando con "KVM not available"), no un fallo de autenticación en el momento de la conexión.
2. El plugin es una extensión de Ruby que se engancha en la API de *provider* de Vagrant dentro del propio runtime de Vagrant; debe estar presente antes de que cualquier `Vagrantfile` sea siquiera evaluado, y aplica a todo proyecto ejecutado por esa instalación de Vagrant. El `Vagrantfile` puede *requerir* un plugin (`config.vagrant.plugins`) pero no puede *proveerlo* — la instalación es un acto sobre el host, no una propiedad de un único entorno.

**Ejercicio 1**

3. **Box** — `Adding box 'generic/debian12' (v4.3.12) for provider: libvirt`; **Provider** — `Creating domain with the following settings... Domain type: kvm`; **Machine** — `Machine booted and ready!`. El **provisioner** no apareció en el log porque este `Vagrantfile` mínimo no declara ninguno (la única línea parecida a una sincronización es la carpeta automática `/vagrant`, que es una carpeta sincronizada, no un provisioner).
4. `(libvirt)` nombra el **provider** que es dueño de la máquina — el estado de Vagrant combina "el domain está corriendo" con "y está gestionado por el provider libvirt en este proyecto". `virsh` solo conoce el domain de libvirt; no tiene noción del proyecto de Vagrant ni de la abstracción de provider. Vagrant persiste esto en el directorio `.vagrant/machines/default/libvirt/` del proyecto (archivo de id, marcador de provider, clave privada).
5. En el primer `up`, libvirt reporta la IP asignada por DHCP del domain; Vagrant inyecta un par de claves generado (la clave `insecure` del box se reemplaza en el primer arranque) y registra la clave privada bajo `.vagrant/machines/default/libvirt/private_key`. El usuario por defecto del box es `vagrant`. `vagrant ssh` lee la IP + clave + usuario almacenados (los mismos datos que imprime `vagrant ssh-config`) y llama a `ssh` por vos.

**Ejercicio 2**

6. Un "box" es una **imagen empaquetada específica del provider más metadatos**, no un único archivo. `generic/debian12` es un *nombre* de box cuyos metadatos del registro listan múltiples providers, cada uno con su propia imagen (un qcow2 para libvirt, un VMDK/OVF para VirtualBox). En el momento del `up`, Vagrant resuelve `name → version → provider` y descarga solo la imagen que coincide con el provider activo; por eso `vagrant box list` indexa por `(name, provider, version)`.
7. Pierde **portabilidad del modelo de CPU / migrabilidad en vivo**. `host-passthrough` expone la CPU exacta del host al guest, así que el guest solo puede migrarse a un destino con una CPU idéntica (o superconjunto). Para una flota que pensás migrar en vivo, en su lugar fijarías un modelo base nombrado (`custom`/`cpu_mode` nombrado con un modelo explícito) para que cada host presente la misma CPU virtual.
8. El dimensionamiento de memoria/CPU es *definición del domain*, aplicado cuando la VM se (re)crea y arranca — `reload` detiene y vuelve a hacer `up` de la máquina, releyendo el `Vagrantfile` y redefiniendo el domain con el nuevo tamaño. `vagrant provision` solo vuelve a ejecutar los provisioners contra la máquina *ya en ejecución*; nunca redefine el hardware, así que la nueva memoria no tendría efecto.

**Ejercicio 3**

9. Dos boxes pueden compartir un nombre pero diferir por provider (imagen libvirt vs virtualbox) y por versión (reconstrucciones semanales). Un `Vagrantfile` que pide `generic/debian12` bajo el provider libvirt debe resolver a una imagen específica; solo la terna identifica de forma única el artefacto en caché, por eso Vagrant almacena y lista los boxes por los tres.
10. Sin restricción, cada `up` sobre una máquina que aún no tiene box resuelve a la versión *más reciente* del registro; ustedes agregaron el box en momentos distintos, así que cachearon versiones distintas. `~> 9.5` es una restricción pesimista que aún flota dentro de la línea 9.5.x. La directiva que fija una construcción exacta y reproducible es **`config.vm.box_version = "9.5.20241120"`** (una versión exacta), opcionalmente combinada con un checksum vía `config.vm.box_download_checksum`.
11. `vagrant box remove` elimina de la caché una `(name, version, provider)` nombrada explícitamente. `vagrant box prune` elimina *todas* las versiones de box que son más viejas que la más nueva en caché **y no están en uso** por ningún entorno conocido. En un host de CI compartido, `prune` (idealmente `--dry-run` primero) es el seguro porque no eliminará una versión que un proyecto activo aún referencia; un `remove` a ciegas de una versión podría romper un build en ejecución.

**Ejercicio 4**

12. (a) **forwarded_port** — un listener del lado del host (acá ligado a `127.0.0.1:8080`) que hace DNAT hacia el guest; alcanzable solo desde el host (y solo vía loopback ya que pusiste `host_ip: 127.0.0.1`), invisible para otros guests y para la LAN. (b) **private_network** — una red libvirt host-only/NAT (`virbr*`); alcanzable desde el host y desde otros guests en la *misma* red privada, pero no desde la LAN más amplia. (c) **public_network** — puenteada sobre un segmento de LAN físico/`virbr0`; el guest obtiene una dirección enrutable en la LAN y es alcanzable desde cualquier máquina de la LAN (sujeto al firewalling de la LAN), igual que un host físico.
13. `eth0` es la **interfaz de gestión** — la red NAT que libvirt crea para que Vagrant pueda alcanzar el guest para SSH, carpetas sincronizadas y aprovisionamiento antes de que exista cualquier red declarada por el usuario. Todo box de libvirt la obtiene porque Vagrant necesita una vía de control fuera de banda. Eliminarla o renumerarla corta el canal de control de Vagrant: `ssh`, `rsync`, `provision` y el estado, todos se rompen. Las redes de usuario siempre se *agregan* como `eth1`, `eth2`, …
14. Por defecto Vagrant detecta la colisión de puerto del host y la **autocorrige**, remapeando el puerto del host de la segunda máquina a uno libre (p. ej. 8081) e imprimiendo un mensaje "Fixed port collision". El comportamiento se controla con `auto_correct: true/false` en la entrada `forwarded_port`; con `auto_correct: false` el segundo `up` falla en lugar de remapear.

**Ejercicio 5**

15. El **directorio del proyecto se sincroniza a `/vagrant`** por defecto (la carpeta que contiene el `Vagrantfile`). Los scripts de aprovisionamiento dependen de él para alcanzar archivos que viven junto al `Vagrantfile` — p. ej. un provisioner de shell puede `bash /vagrant/setup.sh` o leer activos de `/vagrant/...` sin un paso de copia separado.
16. Una carpeta sincronizada con **rsync** es un **empuje único y unidireccional** (host → guest) realizado en `up`/`reload`/`vagrant rsync` (o de forma continua solo si ejecutás `vagrant rsync-auto`); el guest obtiene una copia local plana, así que las ediciones posteriores del host son invisibles hasta la próxima sincronización. **9p** y **NFS** son **sistemas de archivos de red en vivo**: el guest monta el directorio del host, así que lecturas y escrituras pasan en tiempo real en ambas direcciones (sujeto a las banderas rw/ro del montaje).
17. NFS es servido por el **daemon NFS del kernel del host**, así que Vagrant debe editar `/etc/exports` y (re)iniciar el export — una operación privilegiada del host. 9p es servido por **QEMU en espacio de usuario** como parte del propio modelo de dispositivos de la VM, sin necesitar tabla de exports del host, de ahí que no necesite root del host. `accessmode: "squash"` mapea todo acceso a archivos del guest al usuario del host que invoca (como el `root_squash` de NFS): impide que el guest escriba archivos propiedad de UIDs arbitrarios del host, pero también significa que cada escritura del guest aterriza como tu usuario del host, borrando las distinciones de propiedad dentro del guest — conveniente, pero no una verdadera frontera de permisos multiusuario.

**Ejercicio 6**

18. El provisioner **`healthcheck`** se volvió a ejecutar, porque está declarado `run: "always"`. Regla general: un provisioner corre en el **primer `up`/creación exitoso**, y a partir de entonces solo cuando lo pedís explícitamente (`vagrant provision`, `vagrant up --provision`, `vagrant reload --provision`) — *a menos que* esté marcado `run: "always"`, lo que lo ejecuta en cada `up`/`reload` sin importar nada.
19. En el primer `up` todos los provisioners corren una vez en el orden declarado. Si `install` corriera antes que `ship-conf`, el `cp /tmp/redis-overlay.conf ...` del script no encontraría archivo (todavía no fue enviado). El ejemplo lo protege con `|| true`, así que la copia silenciosamente no haría nada y Redis levantaría **sin** la configuración overlay — un resultado sutil de "aprovisionado pero mal configurado", no un fallo duro. El orden declarado es el contrato; el provisioner de file debe ir primero.
20. El **provisioner de shell corre como root por defecto** (se ejecuta con privilegios elevados en el guest), por eso `bootstrap.sh` puede hacer `apt-get install` y escribir `/etc`. Para ejecutarlo sin privilegios ponés `privileged: false` en el provisioner de shell (entonces corre como el usuario `vagrant`). El provisioner de file es lo opuesto — siempre el usuario de SSH (`vagrant`), sin opción de privilegios — de ahí el idioma de depositar-en-`/tmp`-y-luego-`cp`.
21. Poné el secreto en un directorio del host y exponelo con una **carpeta sincronizada en vivo** (9p/NFS) o envialo con el **provisioner de file**, luego hacé que un **provisioner de shell `run: "always"`** lo lea/aplique. Como los datos viven en el host y solo se montan/copian en tiempo de ejecución, nunca quedan capturados en la imagen del box ni en un snapshot. `run: "always"` importa porque un secreto rotado cambia entre arranques; un provisioner de una sola vez aplicaría el valor obsoleto del primer `up` y nunca recogería el nuevo.

**Ejercicio 7**

22. `config.vm.define "web", primary: true` marca a `web` como la **máquina primaria**, así que los comandos sin máquina (`vagrant ssh`, `vagrant provision`) recaen por defecto en ella. Quitá `primary: true` y un `vagrant ssh` escueto en un entorno multi-máquina da error, exigiendo que nombres una máquina, porque no hay destino por defecto.
23. `vagrant status` reporta solo las máquinas definidas por el `Vagrantfile` del **proyecto actual**. `vagrant global-status` lista **todos** los entornos Vagrant conocidos en el host, a lo largo de todos los directorios, desde un índice global. Ese índice puede desincronizarse cuando un directorio de proyecto se borra sin `vagrant destroy`; `--prune` elimina esas entradas obsoletas/inválidas para que el listado refleje la realidad.
24. Agregá un **provisioner de shell** (o un provisioner de file que escriba `/etc/hosts`) en `web` que agregue `192.168.121.20  db01`. El orden por sí solo es insuficiente porque levantar `db` primero solo garantiza que *existe y tiene una IP*; no hace nada para enseñarle al resolver de `web` que `db01` mapea a `192.168.121.20`. Sin DNS del lado del host debés inyectar el mapeo en el guest (`/etc/hosts`) vía aprovisionamiento.

**Ejercicio 8**

25. **`halt`** — apagado ordenado del guest: la RAM se descarta, la imagen de disco se preserva, el siguiente `up` es un **arranque en frío** (el más lento, arranque completo del SO). **`suspend`** — el estado de la RAM de la máquina en ejecución se escribe a disco (`managedsave` de libvirt): el disco se preserva, el siguiente `up`/`resume` restaura al instante exactamente donde lo dejaste (rápido). **`destroy`** — el domain y su overlay de disco por máquina se eliminan: la RAM se va, el disco se va; el siguiente `up` recrea la máquina desde el box y vuelve a ejecutar los provisioners (el más lento en total, una construcción desde cero).
26. Para VMs de desarrollo efímeras la clave del host se regenera en cada reconstrucción y la máquina es descartable, así que `StrictHostKeyChecking no` y un `IdentityFile` con alcance de proyecto solo evitan el vaivén de known-hosts y mantienen la clave junto al proyecto. En producción, deshabilitar la verificación de la clave del host elimina tu única defensa contra un ataque man-in-the-middle/host suplantado, y una clave privada compartida/laxa con `IdentitiesOnly` apuntando a un archivo adyacente al repo invita a la fuga de claves — ambos son exactamente los controles que querés *apretados* en infraestructura real.
27. No es un bug. **Destruir una máquina** elimina esa instancia de VM (su domain y overlay de disco); el **box** es la imagen base reutilizable cacheada bajo `~/.vagrant.d/boxes/`, compartida por cada proyecto que la referencia, y se deja intencionalmente en su lugar para que el siguiente `up` no necesite volver a descargarla. Para efectivamente recuperar el espacio en disco del box ejecutás **`vagrant box remove generic/debian12 --provider libvirt`** (o `vagrant box prune`).

</details>