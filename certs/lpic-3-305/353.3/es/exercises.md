# Ejercicios guiados — Tema 353.3: cloud-init

> **Certificación:** LPIC-3 Virtualization and Containerization — examen **305-300**, versión 3.0
> **Objetivo 353.3** (peso 5): usar cloud-init para configurar máquinas virtuales creadas a partir de imágenes estandarizadas. Entender features, módulos, imágenes estándar, configuración de hostname/users/SSH keys, y la diferencia entre **user data** y **vendor data**.
> **Términos evaluados:** `cloud-init`, cloud config files (`#cloud-config`), user data, meta data, vendor data, `/var/lib/cloud/`, cloud-init datasources, **NoCloud** datasource.

**Requisitos del laboratorio:** una VM Linux con `cloud-init` ≥ 22.x (Ubuntu 22.04/24.04, Debian 12, Fedora, openSUSE), un host con `libvirt`/`qemu-kvm` para los ejercicios de arranque, y los paquetes `cloud-image-utils` (aporta `cloud-localds`) y `genisoimage`/`xorriso`. Los comandos privilegiados usan `sudo`. Las salidas mostradas son ilustrativas: los tiempos y hashes variarán en tu equipo.

---

## Ejercicio 1 — Anatomía de una instancia ya inicializada: estado, stages y `/var/lib/cloud/`

**Objetivo:** leer el estado que cloud-init dejó tras el primer boot, mapear los cuatro servicios systemd a los stages, y recorrer el árbol de `/var/lib/cloud/` distinguiendo lo **per-instance** de lo **per-boot**.

1. Confirmá la versión y que cloud-init no está deshabilitado:

   ```bash
   cloud-init --version
   # /usr/bin/cloud-init 24.1.3-0ubuntu1~22.04.5
   test -f /etc/cloud/cloud-init.disabled && echo "DISABLED" || echo "enabled"
   # enabled
   ```

2. Consultá el estado consolidado del run completo:

   ```bash
   cloud-init status --long
   ```

   ```text
   status: done
   extended_status: done
   boot_status_code: enabled-by-generator
   last_update: Tue, 11 Aug 2026 14:02:11 +0000
   detail: DataSourceNoCloud [seed=/dev/sr0][dsmode=net]
   errors: []
   recoverable_errors: {}
   ```

3. Mapeá los **cuatro servicios systemd** a los stages de boot y mirá el orden:

   ```bash
   systemctl list-units --all 'cloud-*' --no-pager
   ```

   ```text
   cloud-init-local.service   loaded active exited  Initial cloud-init job (pre-networking)
   cloud-init.service         loaded active exited  Initial cloud-init job (metadata service crawler)
   cloud-config.service       loaded active exited  Apply the settings specified in cloud-config
   cloud-final.service        loaded active exited  Execute cloud user/final scripts
   cloud-init.target          loaded active active  Cloud-init target
   ```

4. Recorré el layout persistente. Fijate que `instance` es un symlink al directorio de la instancia actual:

   ```bash
   sudo ls -l /var/lib/cloud/
   sudo ls -l /var/lib/cloud/instance          # -> instances/iid-local01
   sudo ls /var/lib/cloud/instances/iid-local01/
   ```

   ```text
   boot-finished   cloud-config.txt   datasource   handlers   obj.pkl
   scripts   sem   user-data.txt   user-data.txt.i   vendor-data.txt   vendor-data.txt.i
   ```

5. Distinguí los **semáforos** (marcas que impiden re-ejecutar un módulo). Los per-instance viven bajo la instancia; los per-once, en la raíz de cloud:

   ```bash
   sudo ls /var/lib/cloud/instances/iid-local01/sem/   # per-instance
   sudo ls /var/lib/cloud/sem/                          # per-once (once ever)
   ```

   ```text
   config_scripts_user   config_set_hostname   config_ssh   config_users_groups   ...
   ```

6. Mirá los datos de plataforma que cloud-init cachea, incluida la identidad de la instancia:

   ```bash
   sudo cat /var/lib/cloud/data/instance-id
   # iid-local01
   sudo cat /var/lib/cloud/data/result.json
   ```

   ```json
   { "v1": { "datasource": "DataSourceNoCloud [seed=/dev/sr0][dsmode=net]", "errors": [] } }
   ```

7. Consultá metadata sin abrir los pickles a mano, con el query engine:

   ```bash
   cloud-init query -a | head -20                 # todo el árbol de instance-data
   cloud-init query ds.meta_data.instance_id      # iid-local01
   cloud-init query -f "{{ local_hostname }}"     # web-node-01
   ```

**Preguntas de comprensión — bloque 1**

1.1. ¿Cuáles son los cuatro servicios systemd y a qué stage de boot corresponde cada uno? ¿Cuál es el único que corre **antes** de que la red esté configurada, y por qué importa para el datasource NoCloud?

1.2. `cloud-init status` reporta `done`, pero querés bloquear un script hasta que cloud-init termine realmente. ¿Qué invocación usás y en qué se diferencia de leer `/var/lib/cloud/instance/boot-finished`?

1.3. ¿Por qué el símbolo de un módulo aparece en `instances/<iid>/sem/` en un caso y en `/var/lib/cloud/sem/` en otro? ¿Qué implica eso si cambiás el `instance-id`?

1.4. Sin desempaquetar `obj.pkl`, ¿cómo obtenés el `instance-id` que cloud-init está usando ahora mismo?

---

## Ejercicio 2 — Fabricar una imagen estándar: `cloud-init clean` e identidad de instancia

**Objetivo:** entender por qué una "golden image" debe borrar el estado de cloud-init y la identidad de la máquina, y ver cómo cloud-init decide re-ejecutar los módulos per-instance al detectar un `instance-id` nuevo.

1. Simulá que estás preparando la plantilla. Observá primero el estado actual (una instancia ya inicializada):

   ```bash
   cloud-init status
   # status: done
   sudo cat /var/lib/cloud/data/instance-id       # iid-local01
   cat /etc/machine-id                             # 3f2a...   (identidad D-Bus/systemd)
   ```

2. Limpiá el estado de cloud-init como si sellaras la imagen. `--logs` borra los logs, `--machine-id` deja `/etc/machine-id` vacío para que se regenere en el próximo boot:

   ```bash
   sudo cloud-init clean --logs --machine-id
   ```

3. Verificá qué desapareció y qué **no**. `clean` vacía `instances/` y los datos de plataforma, pero **preserva** `/var/lib/cloud/seed/` salvo que agregues `--seed`:

   ```bash
   sudo ls /var/lib/cloud/                 # ya no está el symlink 'instance'
   sudo ls /var/lib/cloud/instances/       # vacío
   test -s /etc/machine-id && echo "con id" || echo "vacío -> se regenera en boot"
   # vacío -> se regenera en boot
   ```

4. Entendé el disparador de re-ejecución. En el próximo arranque, si el datasource entrega un `instance-id` distinto del último cacheado, cloud-init trata la VM como **nueva** y vuelve a correr los módulos per-instance. Simulá manualmente cómo se compara:

   ```bash
   # cloud-init guarda el id anterior y lo compara con el que trae el datasource
   sudo cat /var/lib/cloud/data/previous-instance-id 2>/dev/null || echo "(sin previo tras clean)"
   ```

5. Para una plantilla realmente reutilizable, además de `cloud-init clean` se apaga la máquina y se convierte el disco en base. Por ejemplo, tras el clean:

   ```bash
   sudo truncate -s 0 /etc/machine-id       # refuerzo: id vacío
   sudo rm -f /etc/ssh/ssh_host_*           # que se regeneren host keys únicas por VM
   sudo shutdown -h now
   # en el host:  qemu-img convert -O qcow2 disco.qcow2 golden.qcow2
   ```

**Preguntas de comprensión — bloque 2**

2.1. Si clonás una VM **sin** ejecutar `cloud-init clean`, ¿por qué los módulos per-instance (crear usuarios, setear hostname) **no** vuelven a correr en el clon? ¿Qué archivo/valor es el que cloud-init compara para decidirlo?

2.2. ¿Qué preserva `cloud-init clean` por defecto y qué flag necesitás para borrar también el seed de NoCloud? ¿Por qué el default lo conserva?

2.3. Dos VMs clonadas de la misma golden image terminan con el **mismo** `/etc/machine-id` y las **mismas** SSH host keys. ¿Qué dos acciones del ejercicio evitan cada uno de esos problemas y por qué son independientes de cloud-init-clean?

---

## Ejercicio 3 — Datasource NoCloud: arrancar una VM con seed local (meta-data + user-data)

**Objetivo:** proveer configuración sin ningún cloud provider, usando el datasource **NoCloud** con un disco seed etiquetado `cidata`. Este es el corazón del objetivo: configurar una VM estándar desde cero.

1. Descargá una imagen cloud oficial (traen cloud-init preinstalado y el datasource NoCloud habilitado):

   ```bash
   wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O base.img
   qemu-img create -f qcow2 -F qcow2 -b base.img -o backing_fmt=qcow2 node.qcow2 10G
   ```

2. Escribí el archivo **meta-data**. NoCloud exige como mínimo `instance-id`; `local-hostname` es habitual:

   ```bash
   cat > meta-data <<'EOF'
   instance-id: iid-web-01
   local-hostname: web-node-01
   EOF
   ```

3. Escribí el **user-data** como cloud-config (la primera línea `#cloud-config` es obligatoria y es un marcador de formato, no un comentario):

   ```bash
   cat > user-data <<'EOF'
   #cloud-config
   users:
     - name: sreadmin
       groups: [sudo]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       shell: /bin/bash
       lock_passwd: true
       ssh_authorized_keys:
         - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIObtErrjEXAMPLEKEY sreadmin@bastion
   packages:
     - qemu-guest-agent
   runcmd:
     - [ systemctl, enable, --now, qemu-guest-agent ]
   EOF
   ```

4. Empaquetá el seed. `cloud-localds` (de `cloud-image-utils`) crea un ISO con label `cidata` conteniendo ambos archivos:

   ```bash
   cloud-localds seed.img user-data meta-data
   # comprobá el label que NoCloud busca:
   blkid seed.img
   # seed.img: LABEL="cidata" TYPE="iso9660"
   ```

   Alternativa manual sin `cloud-localds` (el label **debe** ser `cidata`):

   ```bash
   genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data
   ```

5. Arrancá la VM adjuntando ambos discos (el sistema + el seed como CD-ROM):

   ```bash
   virt-install --name web-node-01 --memory 2048 --vcpus 2 --import \
     --disk path="$PWD/node.qcow2",format=qcow2,bus=virtio \
     --disk path="$PWD/seed.img",device=cdrom \
     --os-variant ubuntu22.04 --network network=default --noautoconsole
   ```

6. Dentro de la VM, verificá que NoCloud fue el datasource elegido y que la config se aplicó:

   ```bash
   cloud-init status --long
   # detail: DataSourceNoCloud [seed=/dev/sr0][dsmode=net]
   hostname                    # web-node-01
   id sreadmin                 # uid=1001(sreadmin) groups=1001(sreadmin),27(sudo)
   ```

7. Entendé las tres vías por las que NoCloud encuentra el seed (además del disco `cidata`): un directorio local sembrado, o la línea de comandos del kernel:

   ```bash
   # a) directorio sembrado dentro de la imagen:
   #    /var/lib/cloud/seed/nocloud-net/{meta-data,user-data,network-config}
   # b) kernel cmdline apuntando a una ruta/URL:
   #    ds=nocloud;s=/path/to/seed/     (local)
   #    ds=nocloud-net;s=http://10.0.0.1/seed/   (por red)
   cat /proc/cmdline
   ```

**Preguntas de comprensión — bloque 3**

3.1. ¿Cuál es el campo mínimo obligatorio que debe contener `meta-data` para que NoCloud considere válido el seed? ¿Qué pasa si el disco seed no tiene el label correcto?

3.2. Nombrá las tres formas en que el datasource NoCloud puede recibir su seed. ¿Cuál es la diferencia de comportamiento entre `nocloud` y `nocloud-net` (`dsmode`)?

3.3. En el `detail` del status ves `[dsmode=net]`. ¿En qué stage de boot (local vs network) se aplica entonces la configuración, y por qué NoCloud podría diferir el trabajo hasta que la red esté arriba?

3.4. `local-hostname` va en **meta-data**, pero también podrías poner `hostname:` en el **user-data** cloud-config. ¿Cuál gana y qué distinción conceptual entre meta-data y user-data ilustra eso?

---

## Ejercicio 4 — Un `#cloud-config` de producción y su validación con `cloud-init schema`

**Objetivo:** escribir un cloud-config completo (hostname, users, SSH keys, paquetes, `write_files`, `runcmd`) y validarlo **antes** de arrancar, para no descubrir un error de YAML en el primer boot de 200 nodos.

1. Escribí un cloud-config más rico. Prestá atención a la indentación YAML y a las comillas en `permissions`:

   ```bash
   cat > user-data <<'EOF'
   #cloud-config
   hostname: web-node-01
   fqdn: web-node-01.lab.example.com
   manage_etc_hosts: true

   users:
     - name: sreadmin
       gecos: SRE Admin
       groups: [sudo, adm]
       sudo: "ALL=(ALL) NOPASSWD:ALL"
       shell: /bin/bash
       lock_passwd: true
       ssh_authorized_keys:
         - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIObtErrjEXAMPLEKEY sreadmin@bastion

   package_update: true
   package_upgrade: false
   packages:
     - nginx
     - jq

   write_files:
     - path: /etc/nginx/conf.d/lab.conf
       owner: root:root
       permissions: '0644'
       content: |
         server {
           listen 8080;
           location /healthz { return 200 "ok\n"; }
         }

   runcmd:
     - [ systemctl, enable, --now, nginx ]
     - [ nginx, -t ]

   final_message: "cloud-init done at $TIMESTAMP after $UPTIME s"
   EOF
   ```

2. Validá la **sintaxis y el esquema** sin arrancar nada. Esto usa el JSON Schema que trae cloud-init:

   ```bash
   cloud-init schema --config-file user-data --annotate
   ```

   ```text
   Valid schema user-data
   ```

3. Provocá un error a propósito para ver el diagnóstico (borrá las comillas de `permissions`, que YAML interpretaría como octal → cloud-init exige string):

   ```bash
   sed -i "s/permissions: '0644'/permissions: 0644/" user-data
   cloud-init schema --config-file user-data --annotate
   ```

   ```text
   Invalid cloud-config user-data
   Errors: ------------
   E1: Cloud config schema errors: write_files.0.permissions: 0644 is not of type 'string'
   ```

   Restaurá las comillas antes de continuar:

   ```bash
   sed -i "s/permissions: 0644/permissions: '0644'/" user-data
   ```

4. En una VM que **ya** corrió cloud-init, validá el user-data que efectivamente recibió del datasource:

   ```bash
   sudo cloud-init schema --system --annotate
   ```

5. Verificá el resultado dentro de la VM tras aplicar este cloud-config (los módulos que lo materializan son `cc_set_hostname`, `cc_users_groups`, `cc_ssh`, `cc_write_files`, `cc_package_update_upgrade_install`, `cc_runcmd`):

   ```bash
   hostnamectl --static             # web-node-01
   sudo -n -u sreadmin id           # confirma sudo NOPASSWD
   cat /etc/nginx/conf.d/lab.conf   # el write_files
   systemctl is-active nginx        # active
   ```

**Preguntas de comprensión — bloque 4**

4.1. ¿Por qué `permissions: '0644'` debe ir entre comillas? ¿Qué haría el parser YAML si escribís `0644` sin comillas y por qué cloud-init lo rechaza en el schema?

4.2. `runcmd` no ejecuta los comandos en el momento en que cloud-init lee el módulo. ¿Cuándo y por qué medio se ejecutan realmente, y en qué stage/módulo final ocurre?

4.3. Escribiste `packages:` **y** `runcmd:` que arranca nginx. ¿Por qué el orden importa y qué garantiza que nginx ya esté instalado cuando `runcmd` corre `systemctl enable --now nginx`?

4.4. ¿Qué diferencia hay entre `cloud-init schema --config-file archivo` y `cloud-init schema --system`? ¿Cuál usarías en CI antes de publicar la imagen y cuál dentro de la VM ya arrancada?

---

## Ejercicio 5 — user data vs vendor data: precedencia, merge y desactivación

**Objetivo:** distinguir con precisión los tres canales (**meta-data**, **user-data**, **vendor-data**), ver cómo cloud-init los combina y comprobar quién gana ante un conflicto. Este es un punto explícito del objetivo.

1. Fijá el modelo mental antes de tocar nada:
   - **meta-data**: identidad y hechos de la plataforma (instance-id, hostname, keys públicas, red). Lo provee el datasource; **no** es config arbitraria del usuario.
   - **user-data**: la configuración que vos, el operador, querés aplicar (el `#cloud-config`).
   - **vendor-data**: configuración por defecto que aporta el **proveedor de la nube/plataforma** por el mismo canal que user-data. Se aplica salvo que el usuario la desactive; en conflicto, **user-data prevalece**.

2. Con NoCloud podés simular al "vendor" agregando un archivo `vendor-data` al seed. Creá uno que instale un agente por defecto:

   ```bash
   cat > vendor-data <<'EOF'
   #cloud-config
   packages:
     - htop
   runcmd:
     - [ sh, -c, "echo 'provisto por vendor-data' > /etc/lab-vendor.txt" ]
   EOF
   # regenerá el seed incluyendo los tres archivos:
   cloud-localds --vendor-data vendor-data seed.img user-data meta-data
   ```

3. Tras arrancar, verificá que cloud-init cacheó **ambos** payloads por separado:

   ```bash
   sudo cat /var/lib/cloud/instance/vendor-data.txt   # el que puso el vendor
   sudo cat /var/lib/cloud/instance/user-data.txt     # el tuyo
   ls -l /etc/lab-vendor.txt                           # existe -> vendor-data corrió
   dpkg -l htop | grep ^ii                             # instalado por vendor-data
   ```

4. Comprobá la **precedencia**. Poné una clave en conflicto en ambos (por ejemplo `final_message`) y observá cuál se aplica:

   ```bash
   # user-data:   final_message: "USER wins"
   # vendor-data: final_message: "VENDOR default"
   grep -h final_message /var/lib/cloud/instance/user-data.txt \
                          /var/lib/cloud/instance/vendor-data.txt
   sudo tail -1 /var/log/cloud-init-output.log
   # ... USER wins
   ```

5. Desactivá vendor-data desde el user-data del operador (política común en entornos hardened) y confirmá que el paquete del vendor ya **no** se instala en una instancia nueva:

   ```bash
   cat >> user-data <<'EOF'

   vendor_data:
     enabled: false
   EOF
   # nuevo instance-id -> instancia nueva -> re-run
   sed -i 's/^instance-id:.*/instance-id: iid-web-02/' meta-data
   cloud-localds --vendor-data vendor-data seed.img user-data meta-data
   # tras re-arrancar/limpiar:  htop ya NO estará instalado
   ```

**Preguntas de comprensión — bloque 5**

5.1. En una frase, ¿cuál es la diferencia fundamental de **origen** y **propósito** entre user-data y vendor-data, si ambos se escriben como `#cloud-config`?

5.2. Ante un conflicto entre una directiva de user-data y la misma directiva en vendor-data, ¿cuál se aplica? ¿Cómo desactiva por completo el operador el vendor-data?

5.3. ¿Por qué `local-hostname` es **meta-data** y no vendor-data ni user-data? ¿Qué característica de la meta-data la separa de los otros dos canales?

5.4. Un compañero dice "pongo las SSH keys de los usuarios en meta-data". ¿En qué caso eso es correcto y en qué se diferencia de las `ssh_authorized_keys` dentro de un usuario en el cloud-config user-data?

---

## Ejercicio 6 — Diagnóstico y re-ejecución: `analyze`, logs y `cloud-init single`

**Objetivo:** cronometrar el arranque de cloud-init, encontrar el módulo lento o fallido en los logs, y re-ejecutar un único módulo sin re-arrancar la VM.

1. Cronometrá qué módulos consumieron el tiempo de boot:

   ```bash
   cloud-init analyze blame | head -8
   ```

   ```text
   -- Boot Record 01 --
        08.703s (modules-final/config-package-update-upgrade-install)
        01.120s (init-network/config-growpart)
        00.402s (modules-config/config-ssh)
        00.061s (init-local/search-NoCloud)
   ```

2. Reconstruí la línea de tiempo completa por stage (init-local → init-network → config → final):

   ```bash
   cloud-init analyze show | sed -n '1,20p'
   cloud-init analyze dump | jq '.[0]'      # eventos crudos en JSON para tooling
   ```

3. Cuando algo falla, los dos logs a leer son distintos: uno es el log interno de cloud-init, el otro captura **stdout/stderr** de los scripts (`runcmd`, `bootcmd`):

   ```bash
   sudo grep -Ei 'warn|error|traceback' /var/log/cloud-init.log | tail
   sudo tail -30 /var/log/cloud-init-output.log      # aquí se ve el fallo de un runcmd
   ```

4. Reproducí un fallo: un `runcmd` que apunta a un paquete inexistente deja `status: error`. Diagnosticá:

   ```bash
   cloud-init status --long
   # status: error
   # errors: - "Failed to run module package_update_upgrade_install ..."
   ```

5. Corregí el user-data y re-ejecutá **solo ese módulo**, sin re-arrancar, forzando la frecuencia `always` (que ignora el semáforo):

   ```bash
   sudo cloud-init single --name write_files --frequency always
   sudo cloud-init single --name runcmd --frequency always
   ```

6. Cuando querés una prueba limpia de todo el flujo desde cero en la misma VM (test iterativo de la golden image), combiná clean + reboot:

   ```bash
   sudo cloud-init clean --logs --reboot
   # al volver:
   cloud-init status --wait && echo "run limpio OK"
   ```

**Preguntas de comprensión — bloque 6**

6.1. ¿Qué diferencia hay entre `/var/log/cloud-init.log` y `/var/log/cloud-init-output.log`? Si un `runcmd` imprime un error, ¿en cuál lo buscás primero?

6.2. ¿Qué hacen respectivamente `cloud-init analyze blame` y `cloud-init analyze show`? ¿Cuál usarías para responder "¿qué módulo tarda 8 segundos?"?

6.3. Ejecutás `cloud-init single --name runcmd` **sin** `--frequency always` y no pasa nada. ¿Por qué el semáforo lo bloquea, y qué valor de frecuencia lo fuerza a correr de nuevo?

6.4. ¿Cuándo elegís `cloud-init single` en lugar de `cloud-init clean --reboot`? Nombrá una ventaja de cada uno para depurar un módulo.

---

## Respuestas

<details>
<summary>Mostrar / ocultar respuestas</summary>

### Bloque 1

**1.1.** Los cuatro servicios y sus stages: `cloud-init-local.service` → stage **Local** (`cloud-init init --local`); `cloud-init.service` → stage **Network** (`cloud-init init`); `cloud-config.service` → stage **Config** (`cloud-init modules --mode=config`); `cloud-final.service` → stage **Final** (`cloud-init modules --mode=final`). El único que corre **antes** de la red es `cloud-init-local.service`; ordena `Before=network-pre.target` y bloquea la subida de la red. Importa para NoCloud porque un seed **local** (disco `cidata` o directorio sembrado) puede detectarse y hasta configurar la red en el stage Local, sin depender de que la red ya esté arriba.

**1.2.** `cloud-init status --wait` bloquea hasta que el run finaliza (imprime puntos y sale con código 0 si `done`, no-cero si `error`). Es programático y refleja el estado real, incluyendo error. Leer `/var/lib/cloud/instance/boot-finished` solo te dice que el stage final tocó ese archivo, no distingue éxito de error y requiere que el symlink `instance` ya exista.

**1.3.** El directorio del semáforo depende de la **frecuencia** del módulo. Frecuencia per-instance (`once-per-instance`) → símbolo en `instances/<iid>/sem/`, porque está atado a esa instancia. Frecuencia per-once (`once` ever) → `/var/lib/cloud/sem/`, global a la máquina. Si cambiás el `instance-id`, el directorio `instances/<nuevo-iid>/sem/` está vacío, así que los módulos per-instance **vuelven a correr**; los per-once no, porque su semáforo global sobrevive.

**1.4.** `cloud-init query ds.meta_data.instance_id`, o directamente `cat /var/lib/cloud/data/instance-id`. Ambos evitan tocar `obj.pkl`.

### Bloque 2

**2.1.** Sin `clean`, el clon conserva `/var/lib/cloud/instances/<iid>/` y su cache `/var/lib/cloud/data/instance-id`. Al bootear, el datasource entrega el **mismo** `instance-id` que el cacheado, cloud-init concluye "misma instancia, ya inicializada" y **no** re-corre los módulos per-instance. El valor comparado es el `instance-id` (datasource actual vs. `previous-instance-id`/cache).

**2.2.** Por defecto `clean` borra `/var/lib/cloud/instances/*` y los datos de plataforma, pero **preserva** `/var/lib/cloud/seed/`. Para borrar el seed hace falta `--seed`. El default lo conserva porque el seed suele ser la fuente de config que querés reaplicar; borrarlo dejaría a la VM sin datasource local al re-arrancar.

**2.3.** El `machine-id` idéntico se evita vaciando `/etc/machine-id` (`--machine-id` de clean o `truncate -s 0`), que fuerza a systemd a regenerarlo en el próximo boot. Las SSH host keys idénticas se evitan borrando `/etc/ssh/ssh_host_*`, que hace que `sshd`/cloud-init las regenere por VM. Son independientes de cloud-init-clean porque son identidades de systemd y de OpenSSH, no estado de cloud-init; `clean` no las toca salvo el flag específico de machine-id.

### Bloque 3

**3.1.** El campo mínimo es `instance-id`. Si el disco seed no tiene el label `cidata` (case-insensitive), NoCloud no lo reconoce como seed y no lo monta como datasource; la VM queda sin configuración (o cae a otro datasource de la lista).

**3.2.** Tres vías: (a) un sistema de archivos con label `cidata` (el disco/ISO seed); (b) un directorio sembrado dentro de la imagen, `/var/lib/cloud/seed/nocloud[-net]/`; (c) la línea de comandos del kernel, `ds=nocloud;s=<ruta>` o `ds=nocloud-net;s=<url>`. Diferencia de `dsmode`: `nocloud` (dsmode=local) aplica todo en el stage **Local**, antes de la red; `nocloud-net` (dsmode=net) difiere la aplicación al stage **Network**, útil cuando el seed o parte de la config depende de la red.

**3.3.** Con `dsmode=net`, la configuración se aplica en el stage **Network** (`cloud-init.service`). NoCloud puede diferirlo porque el seed indica que la data (o recursos referenciados, como `#include` de URLs o metadata por red) requiere que la red esté operativa; en `local` no podría alcanzarlos.

**3.4.** Si ambos están presentes, **`hostname:` del user-data prevalece** sobre `local-hostname` de meta-data (el módulo de hostname prioriza cloud-config). Ilustra la distinción: meta-data es el **hecho por defecto que aporta la plataforma** (identidad), y user-data es la **intención explícita del operador**, que puede sobreescribir esos defaults.

### Bloque 4

**4.1.** Sin comillas, YAML interpreta `0644` como un entero (y con `0` inicial, incluso como octal según la versión del parser), no como string. El schema de cloud-init declara `write_files[].permissions` como `string`, de modo que un entero falla la validación. Las comillas fuerzan el tipo string `'0644'`, que es lo que cloud-init espera para pasarlo tal cual a `chmod`.

**4.2.** `runcmd` **no** ejecuta en el momento de la lectura: el módulo `cc_runcmd` solo **escribe** los comandos a un script (`/var/lib/cloud/instance/scripts/runcmd`). Ese script se ejecuta después, en el stage **Final** (`cloud-final.service`, vía `cc_scripts_user`). Por eso `runcmd` corre tarde, cuando paquetes y archivos ya están puestos.

**4.3.** El orden importa porque `packages:` lo materializa `cc_package_update_upgrade_install` en el stage **Final**, y `runcmd` (también Final, vía scripts-user) corre **después** de la instalación de paquetes dentro de ese mismo stage. Así, cuando `runcmd` hace `systemctl enable --now nginx`, el paquete `nginx` ya fue instalado por el módulo de paquetes, que se ejecuta antes en el orden de módulos finales.

**4.4.** `--config-file archivo` valida un YAML arbitrario **sin arrancar** ni tener datasource — ideal en CI antes de publicar la imagen. `--system` valida el user-data que la instancia **realmente recibió** del datasource (lee `/var/lib/cloud/instance/`) — se usa dentro de la VM ya arrancada para confirmar qué llegó.

### Bloque 5

**5.1.** **user-data** lo provee el **operador/usuario** para expresar la configuración que quiere; **vendor-data** lo provee el **proveedor de la plataforma/nube** como configuración por defecto. Mismo formato (`#cloud-config`), distinto origen y autoridad.

**5.2.** En conflicto, **user-data prevalece** sobre vendor-data. El operador desactiva vendor-data por completo con `vendor_data: {enabled: false}` en su user-data (o config equivalente en `/etc/cloud/cloud.cfg.d/`).

**5.3.** `local-hostname` es meta-data porque es un **hecho de identidad que aporta la plataforma** sobre la instancia, no una preferencia de configuración escrita como cloud-config. La meta-data se distingue de user/vendor-data en que no es un payload de módulos cloud-config: es información estructurada de la plataforma (instance-id, hostname, keys públicas, red) que cloud-init consume como datos, no como directivas de configuración.

**5.4.** Es correcto cuando la **plataforma/datasource** inyecta claves públicas de acceso a la instancia: NoCloud/otros datasources exponen `public-keys` en meta-data y cloud-init las agrega al usuario por defecto (`cc_ssh`). Se diferencia de `ssh_authorized_keys` dentro de un usuario del cloud-config en que estas últimas las define **el operador explícitamente por usuario** en user-data, mientras que las de meta-data son las que **entrega la plataforma** (típicamente para el usuario default de la imagen).

### Bloque 6

**6.1.** `/var/log/cloud-init.log` es el log **interno** de cloud-init (qué módulo corrió, decisiones, tracebacks de Python). `/var/log/cloud-init-output.log` captura el **stdout/stderr** de los comandos que cloud-init lanza (`bootcmd`, `runcmd`, instalación de paquetes). Si un `runcmd` imprime un error, lo buscás primero en `cloud-init-output.log`.

**6.2.** `analyze blame` ordena los módulos por **tiempo consumido** (el más lento arriba) — es el que responde "¿qué módulo tarda 8 s?". `analyze show` reconstruye la **línea de tiempo por stage y evento** (init-local → init-network → config → final), útil para ver el flujo completo y dónde se ubica cada evento.

**6.3.** Cada módulo per-instance deja un **semáforo** en `instances/<iid>/sem/`; `cloud-init single` respeta ese semáforo y salta el módulo si ya corrió para esa instancia. `--frequency always` (per-boot) ignora/anula el semáforo persistente y fuerza la re-ejecución.

**6.4.** `cloud-init single` re-ejecuta **un solo módulo** en caliente, sin reboot: rápido para iterar sobre un `write_files`/`runcmd` puntual, preservando el resto del estado. `cloud-init clean --reboot` da una prueba **desde cero** de todo el flujo (los cuatro stages, todos los módulos, detección de datasource): es la validación fiel de una golden image, a costa de un arranque completo.

</details>

---

### Fuentes

- LPI — Exam 305 Objectives (objetivo 353.3): https://www.lpi.org/our-certifications/exam-305-objectives/
- cloud-init — Boot stages: https://cloudinit.readthedocs.io/en/latest/explanation/boot.html
- cloud-init — NoCloud datasource: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
- cloud-init — User data formats: https://cloudinit.readthedocs.io/en/latest/explanation/format.html
- cloud-init — Vendor data: https://cloudinit.readthedocs.io/en/latest/explanation/vendordata.html
- cloud-init — Cloud config examples: https://cloudinit.readthedocs.io/en/latest/reference/examples.html
- cloud-init — Modules: https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- cloud-init — CLI (`status`, `schema`, `query`, `single`, `analyze`, `clean`): https://cloudinit.readthedocs.io/en/latest/reference/cli.html
- cloud-init — Directory layout (`/var/lib/cloud/`): https://cloudinit.readthedocs.io/en/latest/reference/directory_layout.html