# 351.3 QEMU — Ejercicios guiados

> **Certificación:** LPIC-3 305 (examen 305-300, versión 3.0)
> **Tema:** 351.3 QEMU — *Comprender la arquitectura de QEMU, su interacción con KVM y libvirt, arrancar instancias desde la línea de comandos, manejar el QEMU Monitor y gestionar dispositivos virtuales/extraíbles.*
> **Formato:** Cada ejercicio es una secuencia de pasos numerados que ejecutás en un host Linux con virtualización por hardware, seguida de preguntas de comprensión. Las respuestas modelo están en la sección desplegable al final.

**Prerrequisitos para todo el laboratorio**

- Un host Linux x86-64 físico (o con virtualización anidada habilitada) con una CPU Intel VT-x o AMD-V.
- Paquetes: `qemu-system-x86` (o `qemu-kvm`), `qemu-utils`, `cpu-checker` (Debian/Ubuntu) o `qemu-img`/`qemu-kvm` (familia RHEL), y `libvirt-clients` para el último ejercicio.
- Tu usuario en el grupo `kvm` (cerrá y volvé a iniciar sesión tras agregarlo), o ejecutá los comandos de arranque con `sudo`.
- Un ISO de instalación pequeño para arrancar, por ejemplo `debian-12.5.0-amd64-netinst.iso` (~630 MiB). Adaptá el nombre del archivo a lo que hayas descargado.
- Aproximadamente 25 GiB de disco libre para las imágenes.

Trabajá en un directorio temporal:

```bash
mkdir -p ~/qemu-lab && cd ~/qemu-lab
```

---

## Exercise 1 — Confirm the KVM acceleration path

QEMU es un emulador puramente por software por defecto (TCG, el Tiny Code Generator). La velocidad casi nativa solo ocurre cuando QEMU delega la ejecución de la CPU del guest en la CPU del host a través de los módulos del kernel de KVM y `/dev/kvm`. Antes que nada, comprobá que ese camino existe en tu host.

1. Verificá que la CPU expone las extensiones de virtualización. `vmx` es Intel VT-x, `svm` es AMD-V:

   ```bash
   egrep -c '(vmx|svm)' /proc/cpuinfo
   ```

   Un número distinto de cero (normalmente igual a la cantidad de CPU lógicas) significa que las extensiones están presentes y habilitadas en el firmware.

2. Confirmá que los módulos de KVM están cargados:

   ```bash
   lsmod | grep kvm
   ```

   Esperado (host Intel):

   ```
   kvm_intel             376832  0
   kvm                  1146880  1 kvm_intel
   irqbypass              16384  1 kvm
   ```

   En AMD verías `kvm_amd` en lugar de `kvm_intel`. El módulo genérico `kvm` es el núcleo independiente de la arquitectura; `kvm-intel` / `kvm-amd` son los back-ends del fabricante.

3. Si no se carga nada, cargá el módulo del fabricante explícitamente (arrastra al núcleo `kvm`):

   ```bash
   sudo modprobe kvm_intel     # or: sudo modprobe kvm_amd
   ```

4. Inspeccioná el dispositivo de caracteres que el QEMU de espacio de usuario abre para hablar con el hipervisor:

   ```bash
   ls -l /dev/kvm
   ```

   Esperado:

   ```
   crw-rw----+ 1 root kvm 10, 232 Aug 11 09:14 /dev/kvm
   ```

   Fijate en el grupo `kvm` y el permiso `rw` de grupo — por esto tu usuario debe estar en el grupo `kvm`.

5. Ejecutá el verificador de conveniencia (paquete `cpu-checker` de Debian/Ubuntu):

   ```bash
   kvm-ok
   ```

   Esperado:

   ```
   INFO: /dev/kvm exists
   KVM acceleration can be used
   ```

6. Registrá la versión de QEMU y confirmá que el binario del emulador de sistema `x86_64` está instalado:

   ```bash
   qemu-system-x86_64 --version
   ```

   Esperado:

   ```
   QEMU emulator version 8.2.0 (Debian 1:8.2.0+ds-1)
   Copyright (c) 2003-2023 Fabrice Bellard and the QEMU Project developers
   ```

7. Listá los back-ends de aceleración con los que se compiló este binario:

   ```bash
   qemu-system-x86_64 -accel help
   ```

   Esperado (subconjunto):

   ```
   Accelerators supported in QEMU binary:
   tcg
   kvm
   ```

**Preguntas**

- 1a. ¿Cuál es la diferencia funcional entre el módulo `kvm` y el módulo `kvm-intel`/`kvm-amd`, y por qué se necesitan ambos?
- 1b. `/dev/kvm` está presente pero un usuario no root recibe `Could not access KVM kernel module: Permission denied` al lanzar QEMU. ¿Cuál es la causa más probable y la solución?
- 1c. En un host donde `egrep -c '(vmx|svm)' /proc/cpuinfo` devuelve `0`, nombrá dos razones distintas por las que esto puede pasar incluso en una CPU que soporta virtualización físicamente.
- 1d. Si lanzás QEMU sin `accel=kvm` en este host, ¿el guest igual va a correr? ¿Qué cambia?

---

## Exercise 2 — Provision disk images with `qemu-img`

`qemu-img` es la herramienta de imágenes offline: crea, inspecciona, convierte, redimensiona y toma snapshots de discos virtuales sin una VM corriendo. Vas a usar `qcow2`, el formato copy-on-write nativo de QEMU.

1. Creá una imagen `qcow2` de 20 GiB. Como `qcow2` es dispersa (sparse), esto consume solo unos cientos de KiB en disco inicialmente:

   ```bash
   qemu-img create -f qcow2 disk.qcow2 20G
   ```

   Esperado:

   ```
   Formatting 'disk.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=21474836480 lazy_refcounts=off refcount_bits=16
   ```

2. Inspeccionala. Compará el *virtual size* (lo que ve el guest) con el *disk size* (lo que realmente usa el sistema de archivos del host):

   ```bash
   qemu-img info disk.qcow2
   ```

   Esperado:

   ```
   image: disk.qcow2
   file format: qcow2
   virtual size: 20 GiB (21474836480 bytes)
   disk size: 196 KiB
   cluster_size: 65536
   Format specific information:
       compat: 1.1
       compression type: zlib
       lazy refcounts: false
       refcount bits: 16
       corrupt: false
       extended l2: false
   ```

3. Confirmá la dispersión del lado del host con una herramienta estándar. `-h` (aparente) vs `--apparent-size` muestra el contraste:

   ```bash
   du -h disk.qcow2
   du -h --apparent-size disk.qcow2
   ```

   Esperado: el primero reporta `~200K` (bloques reales), el segundo `~193K` — ambos muy por debajo de 20 GiB.

4. Creá un *overlay* fino que mantenga a `disk.qcow2` de solo lectura como su archivo de respaldo (backing file). Las escrituras caen solo en el overlay — esta es la base de las golden images y los clones enlazados (linked clones):

   ```bash
   qemu-img create -f qcow2 -b disk.qcow2 -F qcow2 overlay.qcow2
   qemu-img info overlay.qcow2
   ```

   Esperado (fijate en la línea del backing file):

   ```
   image: overlay.qcow2
   file format: qcow2
   virtual size: 20 GiB (21474836480 bytes)
   disk size: 196 KiB
   cluster_size: 65536
   backing file: disk.qcow2
   backing file format: qcow2
   ...
   ```

5. Verificá la consistencia de la imagen (seguro solo en una imagen detenida):

   ```bash
   qemu-img check disk.qcow2
   ```

   Esperado:

   ```
   No errors were found on the image.
   0/327680 = 0.00% allocated, 0.00% fragmented, 0.00% compressed clusters
   Image end offset: 262144
   ```

6. Demostrá una conversión de formato — producí una copia `raw` (vista lógica totalmente asignada) a partir de la imagen `qcow2`:

   ```bash
   qemu-img convert -f qcow2 -O raw disk.qcow2 disk.raw
   qemu-img info disk.raw
   ```

   Esperado `file format: raw`, `virtual size: 20 GiB`, y — porque `raw` en un sistema de archivos con soporte de sparse sigue siendo disperso — un `disk size` pequeño.

**Preguntas**

- 2a. Explicá la diferencia entre *virtual size* y *disk size* en `qemu-img info`, y cuál de los dos crece a medida que el guest escribe datos.
- 2b. En el paso 4 creaste `overlay.qcow2` sobre `disk.qcow2`. ¿Qué le pasa al guest en ejecución si modificás `disk.qcow2` directamente mientras el overlay está en uso? ¿Por qué es peligroso?
- 2c. Necesitás entregarle a un colega un disco de VM para importar en VMware. ¿Qué única invocación de `qemu-img convert` produce una imagen nativa de VMware, y qué controla la flag `-O`?
- 2d. ¿Por qué nunca deberías ejecutar `qemu-img check` o `qemu-img convert` contra una imagen que está actualmente conectada a una VM en ejecución?

---

## Exercise 3 — Boot a virtual machine from the command line

Ahora armá una invocación completa de `qemu-system-x86_64`. Cada flag mapea a una pieza de hardware virtual. Vas a arrancar el ISO del instalador contra el `disk.qcow2` vacío.

1. Lanzá la VM. Leé cada línea antes de ejecutarla:

   ```bash
   qemu-system-x86_64 \
     -name lab-vm \
     -machine q35,accel=kvm \
     -cpu host \
     -m 2048 \
     -smp cores=2,threads=1,sockets=1 \
     -drive file=disk.qcow2,if=virtio,format=qcow2 \
     -cdrom debian-12.5.0-amd64-netinst.iso \
     -boot order=d,menu=on \
     -netdev user,id=net0,hostfwd=tcp::2222-:22 \
     -device virtio-net-pci,netdev=net0 \
     -display gtk \
     -monitor stdio
   ```

   Qué hace cada opción:
   - `-machine q35,accel=kvm` — chipset PCIe moderno (`q35`) y fuerza la aceleración KVM; el lanzamiento falla ruidosamente si KVM no está disponible en vez de caer silenciosamente a TCG.
   - `-cpu host` — expone el conjunto de características de la CPU del host al guest (mejor rendimiento).
   - `-m 2048` — 2048 MiB de RAM para el guest.
   - `-smp cores=2,...` — 2 CPU virtuales.
   - `-drive ...,if=virtio` — conecta el disco al bus paravirtualizado `virtio-blk`.
   - `-cdrom` — conecta el ISO como una unidad óptica virtual (abreviatura de `-drive ...,media=cdrom`).
   - `-boot order=d,menu=on` — dispositivo de arranque `d` = primer CD-ROM; `menu=on` habilita el menú de arranque interactivo.
   - `-netdev user,...` + `-device virtio-net-pci` — un *back-end* de red (SLIRP en modo usuario) ligado a un *front-end* de red (una NIC virtio); `hostfwd` reenvía el puerto 2222 del host al puerto 22 del guest.
   - `-display gtk` — abre una ventana GTK; cambiá a la consola del monitor con **Ctrl+Alt+2**, y volvé al guest con **Ctrl+Alt+1**.
   - `-monitor stdio` — además expone el QEMU Monitor en la terminal desde la que lanzaste.

2. En la terminal de lanzamiento ahora tenés el prompt del monitor `(qemu)`. Confirmá que la VM está corriendo y que KVM está realmente activo:

   ```
   (qemu) info status
   ```
   ```
   VM status: running
   ```
   ```
   (qemu) info kvm
   ```
   ```
   kvm support: enabled
   ```

3. Verificá el tipo de máquina emulada y la cantidad de CPU desde el monitor:

   ```
   (qemu) info cpus
   ```

   Esperado (dos vCPU):

   ```
   * CPU #0 [running] thread_id=12841
     CPU #1 [running] thread_id=12842
   ```

4. Avanzá con (o simplemente iniciá) el instalador del guest en la ventana GTK para confirmar que se detectan el disco y la NIC. **No** necesitás terminar la instalación — llegar al particionador prueba que `virtio-blk` y el ISO están funcionando.

5. (Opcional, si el guest llega a tener un servidor SSH corriendo más adelante) Desde otra terminal del host, probá el reenvío de puerto:

   ```bash
   ssh -p 2222 user@127.0.0.1
   ```

**Preguntas**

- 3a. `-cdrom` y `-drive ...,if=virtio` conectan almacenamiento ambos. ¿Cuál es la consecuencia de `-boot order=d` sobre el orden de arranque, y cómo lo cambiarías para arrancar desde el disco duro en su lugar?
- 3b. Distinguí el *network back-end* (`-netdev`) del *device front-end* (`-device`). ¿Cuál es visible para el SO del guest como una NIC, y cuál determina cómo salen los paquetes del host?
- 3c. ¿Por qué `-machine ...,accel=kvm` se comporta distinto de `-enable-kvm` cuando falta KVM, y cuál es preferible en un pipeline automatizado?
- 3d. Diste `-m 2048` y `-smp cores=2`. En el *host*, ¿aproximadamente cuántos hilos genera este proceso de QEMU para la ejecución del guest, y qué revela `info cpus` sobre ellos?

---

## Exercise 4 — Drive the QEMU Monitor

El QEMU Monitor es el canal de control en vivo para una instancia en ejecución: consultá el estado, hacé hot-plug de dispositivos, intercambiá medios, pausá/reanudá y apagá limpiamente. Mantené corriendo la VM del Exercise 3.

1. Desde el prompt `(qemu)`, volcá la capa de bloques. Esto muestra cada unidad y cualquier medio insertado:

   ```
   (qemu) info block
   ```

   Esperado (abreviado):

   ```
   virtio0 (#block123): /home/you/qemu-lab/disk.qcow2 (qcow2)
       Attached to:      /machine/peripheral-anon/device[0]/virtio-backend
       Cache mode:       writeback
   ide1-cd0: /home/you/qemu-lab/debian-12.5.0-amd64-netinst.iso (raw, read-only)
       Attached to:      ide1-cd0
       Removable device: not locked, tray closed
   ```

2. Inspeccioná el estado de la red:

   ```
   (qemu) info network
   ```
   ```
   net0:
    index=0,type=nic,model=virtio-net-pci,macaddr=52:54:00:12:34:56
    \ net0: index=0,type=user,net=10.0.2.0,restrict=off
   ```

   Fijate en el prefijo MAC `52:54:00` — el OUI registrado de QEMU, una señal de que una NIC es virtual.

3. Expulsá el medio de instalación *en vivo* (como si sacaras un CD), luego confirmá que la bandeja está abierta:

   ```
   (qemu) eject ide1-cd0
   (qemu) info block
   ```

   La línea `ide1-cd0` ahora muestra una bandeja vacía.

4. Insertá un ISO distinto en la misma unidad virtual sin detener la VM:

   ```
   (qemu) change ide1-cd0 /path/to/another.iso
   ```

5. Pausá y reanudá la ejecución del guest. `stop` congela todas las vCPU; `cont` reanuda:

   ```
   (qemu) stop
   (qemu) info status
   ```
   ```
   VM status: paused
   ```
   ```
   (qemu) cont
   ```

6. Agregá en caliente (hot-add) un segundo disco virtio sin reiniciar. Primero creá la imagen en otra terminal:

   ```bash
   qemu-img create -f qcow2 data.qcow2 5G
   ```

   Luego, desde el monitor, agregá el back-end (`drive_add`) y el dispositivo front-end (`device_add`):

   ```
   (qemu) drive_add 0 file=/home/you/qemu-lab/data.qcow2,if=none,id=data0,format=qcow2
   (qemu) device_add virtio-blk-pci,drive=data0,id=vblk1
   ```

   Dentro del guest aparece un nuevo `/dev/vdb` (verificá con `lsblk`).

7. Quitalo de nuevo limpiamente:

   ```
   (qemu) device_del vblk1
   ```

8. Solicitá un apagado ACPI — este es el botón de encendido grácil, equivalente a presionar power en hardware físico. El SO del guest ejecuta su secuencia de apagado:

   ```
   (qemu) system_powerdown
   ```

   (`quit`, en cambio, mata el proceso de QEMU inmediatamente, como tirar del enchufe — el guest no es notificado.)

**Preguntas**

- 4a. Dá las dos formas estándar de llegar al QEMU Monitor de una sesión GTK/SDL, y una forma de exponerlo por red para hosts sin cabeza (headless).
- 4b. Contrastá `system_powerdown`, `stop` y `quit`. ¿Cuál arriesga la corrupción del sistema de archivos del guest y por qué?
- 4c. Hacer hot-plug de un disco en el paso 6 requirió dos comandos (`drive_add` y luego `device_add`). Explicá la división back-end/front-end que esto refleja y por qué `device_del` solo alcanza para quitarlo.
- 4d. ¿Qué único comando del monitor ejecutarías para confirmar que el disco virtual del guest se está sirviendo con modo de caché `writeback`, y por qué importa el modo de caché para la seguridad de los datos?

---

## Exercise 5 — VM state snapshots via the monitor

`qcow2` soporta snapshots *internos* que capturan el disco **y**, cuando se toman desde el monitor, el estado en vivo de CPU/RAM (`savevm`). Estos son distintos del comando offline `qemu-img snapshot`. Mantené una VM levantada (idealmente con una instalación terminada, pero cualquier guest en ejecución sirve).

1. Desde el monitor, guardá un snapshot completo de la VM llamado `clean`:

   ```
   (qemu) savevm clean
   ```

   El comando se bloquea brevemente mientras la RAM se escribe en la imagen, luego vuelve al prompt.

2. Listá los snapshots almacenados en la imagen:

   ```
   (qemu) info snapshots
   ```

   Esperado:

   ```
   List of snapshots present on all disks:
   ID        TAG          VM SIZE                DATE       VM CLOCK     ICOUNT
   1         clean       220 MiB 2026-08-11 10:32:11   00:04:12.325
   ```

   `VM SIZE` es distinto de cero — esa es la RAM capturada. Un snapshot puramente de disco mostraría `0 B` aquí.

3. Hacé un cambio visible dentro del guest (creá un archivo, instalá un paquete — cualquier cosa que altere el disco/RAM).

4. Revertí la máquina entera al snapshot. La ejecución y la memoria vuelven al instante exacto del guardado:

   ```
   (qemu) loadvm clean
   ```

   Verificá dentro del guest que tu cambio del paso 3 desapareció.

5. Cotejá los mismos snapshots desde la herramienta *offline* (funciona incluso con la VM apagada):

   ```bash
   qemu-img snapshot -l disk.qcow2
   ```

   Esperado:

   ```
   Snapshot list:
   ID        TAG          VM SIZE                DATE       VM CLOCK
   1         clean       220 MiB 2026-08-11 10:32:11   00:04:12.325
   ```

6. Eliminá el snapshot desde el monitor cuando termines:

   ```
   (qemu) delvm clean
   (qemu) info snapshots
   ```

   La lista ahora está vacía (`There is no snapshot available.`).

**Preguntas**

- 5a. ¿Qué datos extra captura un `savevm` del monitor que un `qemu-img snapshot -c` offline no captura, y cómo los distinguís en `info snapshots`?
- 5b. ¿Por qué los snapshots internos de `savevm` requieren que el disco esté en `qcow2` (u otro formato que los soporte) en lugar de `raw`?
- 5c. Tenés una VM cuyo disco usa una cadena de *backing files* externa. ¿Cuál es el riesgo de tomar un snapshot interno que también abarque esa imagen de respaldo compartida?
- 5d. `loadvm` revirtió la RAM y el disco atómicamente. ¿Por qué eso es más fuerte que restaurar un backup a nivel de sistema de archivos tomado mientras el guest estaba corriendo?

---

## Exercise 6 — Networking: user-mode vs bridged/TAP

QEMU separa *cómo ve la NIC el guest* (device front-end) de *cómo llegan los paquetes al mundo* (network back-end). Ya usaste el back-end más simple (`user`/SLIRP). Ahora entendé sus límites y la alternativa TAP.

1. Arrancá un guest descartable con una red en modo usuario explícita y un reenvío SSH, headless:

   ```bash
   qemu-system-x86_64 \
     -machine q35,accel=kvm -cpu host -m 1024 -smp 1 \
     -drive file=overlay.qcow2,if=virtio,format=qcow2 \
     -netdev user,id=n0,hostfwd=tcp::2222-:22 \
     -device virtio-net-pci,netdev=n0,mac=52:54:00:ab:cd:01 \
     -nographic
   ```

   `-nographic` envía la consola serie del guest a tu terminal y *multiplexa* el monitor sobre ella — cambiá al monitor con **Ctrl+a c**, y recordá que **Ctrl+a x** mata QEMU.

2. Una vez que el guest está levantado, examiná las direcciones que recibió de SLIRP. Dentro del guest:

   ```bash
   ip -4 addr show
   ip route
   cat /etc/resolv.conf
   ```

   Vas a ver al guest en `10.0.2.15/24`, gateway por defecto `10.0.2.2`, DNS `10.0.2.3`. Estas son convenciones fijas de SLIRP: `.2` es el gateway del lado del host, `.3` el proxy DNS.

3. Probá que la salida funciona pero que el host no puede alcanzar *hacia adentro* libremente. Desde el guest, `ping 10.0.2.2` (el gateway) tiene éxito; notá que ICMP hacia el internet amplio a través de SLIRP suele ser poco fiable, pero TCP (por ejemplo `curl https://www.qemu.org`) funciona.

4. Demostrá la limitación de entrada y su solución. Desde el *host*, una conexión directa a la IP del guest falla (la red `10.0.2.0/24` es privada de esta VM), pero el `hostfwd` que configuraste funciona:

   ```bash
   ssh -p 2222 user@127.0.0.1
   ```

5. Entendé la alternativa TAP (la configuración requiere root y un bridge en el host; leelo y razonalo en vez de necesariamente ejecutarlo). Un back-end TAP enchufa el guest a un bridge de capa 2 real del host de modo que se vuelve un nodo de primera clase en la LAN física:

   ```bash
   # Host-side, one-time bridge (illustrative):
   #   ip link add br0 type bridge
   #   ip link set eth0 master br0
   #
   qemu-system-x86_64 \
     -machine q35,accel=kvm -cpu host -m 1024 -smp 1 \
     -drive file=overlay.qcow2,if=virtio,format=qcow2 \
     -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
     -device virtio-net-pci,netdev=n0,mac=52:54:00:ab:cd:02 \
     -nographic
   ```

   Con TAP + bridge el guest obtiene una dirección del DHCP de la LAN y es alcanzable por cualquier host de la red — sin necesidad de reenvío de puertos.

**Preguntas**

- 6a. En la red en modo usuario (SLIRP), ¿qué son las direcciones `10.0.2.2` y `10.0.2.3`, y por qué dos guests en modo usuario corriendo simultáneamente pueden usar ambos `10.0.2.15` sin conflicto?
- 6b. Un estudiante se queja: "mi guest de QEMU puede navegar la web pero no puedo hacer SSH hacia él desde mi laptop". Explicá la causa raíz y dá las dos formas distintas de solucionarlo (una por tipo de back-end).
- 6c. ¿Por qué `hostfwd` es innecesario con un back-end TAP/bridge?
- 6d. Ambas invocaciones fijan `mac=52:54:00:...`. ¿Por qué es buena práctica fijar una MAC explícita, y cuál es la significancia del prefijo `52:54:00`?

---

## Exercise 7 — Where libvirt fits over QEMU

En producción rara vez tipeás estas líneas de comando largas. `libvirt` (el driver `qemu:///system`) almacena cada VM como XML y construye la línea de comando de QEMU por vos. Este ejercicio muestra el límite entre las dos capas.

1. Si existe un guest gestionado por libvirt (o creá uno trivial con `virt-install`/`virsh define`), listalo:

   ```bash
   virsh -c qemu:///system list --all
   ```

   Esperado:

   ```
    Id   Name      State
   ---------------------------
    3    lab-vm    running
   ```

2. Revelá la línea de comando *real* de QEMU que libvirt generó para un dominio definido — esto conecta todo lo que hiciste a mano de vuelta con la capa gestionada:

   ```bash
   virsh -c qemu:///system domxml-to-native qemu-argv --domain lab-vm
   ```

   La salida es una cadena larga `qemu-system-x86_64 ... -machine ... -accel kvm ... -drive ... -netdev ... -device ...` — los mismos bloques de construcción de los Exercises 3 y 6, generados por máquina.

3. Confirmá que libvirt maneja el mismísimo binario `qemu-system-x86_64` encontrando el proceso en vivo:

   ```bash
   pgrep -a qemu-system
   ```

   Vas a ver una línea larga `qemu-system-x86_64` por cada dominio en ejecución, lanzada por libvirt con `-accel kvm` y un monitor por socket Unix (`-mon ...,mode=control`).

4. Observá que libvirt habla con el monitor de cada guest sobre el socket QMP en lugar de `stdio` — ese socket es cómo `virsh` implementa comandos como `virsh shutdown` (que emite el apagado ACPI que viste como `system_powerdown`).

**Preguntas**

- 7a. En una oración cada uno, indicá qué provee QEMU y qué agrega libvirt por encima.
- 7b. `virsh shutdown lab-vm` y el comando del monitor `system_powerdown` producen el mismo efecto en el guest. ¿Qué te dice esto sobre cómo libvirt controla una instancia de QEMU en ejecución?
- 7c. ¿Por qué libvirt usa un socket de control QMP (`-mon ...,mode=control`) en lugar del `-monitor stdio` legible por humanos que usaste en el laboratorio?

---

## Cleanup

```bash
# Stop any running QEMU windows (or 'quit' from each monitor), then:
cd ~ && rm -rf ~/qemu-lab
```

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

### Exercise 1

**1a.** El módulo genérico `kvm` es el núcleo independiente de la arquitectura del hipervisor KVM: expone `/dev/kvm` y la interfaz de ioctl que el espacio de usuario (QEMU) usa. `kvm-intel` y `kvm-amd` son los back-ends específicos del fabricante que programan las extensiones de virtualización por hardware reales (Intel VT-x / VMX o AMD-V / SVM). Necesitás el núcleo para la interfaz y exactamente un módulo de fabricante para tu CPU; cargar el módulo del fabricante auto-carga el núcleo como dependencia (visto en `lsmod` como `kvm ... 1 kvm_intel`).

**1b.** `/dev/kvm` es propiedad de `root:kvm` con `rw` solo para el dueño y el grupo. El usuario no está en el grupo `kvm`. Solución: `sudo usermod -aG kvm <user>` y reiniciar sesión (la pertenencia al grupo se evalúa al inicio de la sesión), o ejecutar QEMU con `sudo`. Verificá con `id` que `kvm` aparece en la lista de grupos.

**1c.** Dos cualesquiera de: (1) la virtualización está deshabilitada en el firmware BIOS/UEFI (interruptor Intel VT-x / AMD SVM apagado); (2) estás dentro de una VM/instancia de nube donde la virtualización anidada no fue habilitada por el host; (3) las flags de la CPU están ocultas por un modelo `-cpu` del hipervisor que no pasa `vmx`/`svm`; (4) una característica de seguridad (por ejemplo algunos modos "secure"/DEP del firmware) está enmascarando las extensiones.

**1d.** Sí — QEMU cae al emulador por software TCG, así que el guest igual arranca y corre correctamente, pero cada instrucción del guest es traducida dinámicamente por QEMU sobre la CPU del host en vez de ejecutarse nativamente. El resultado es aproximadamente un orden de magnitud más lento y un uso de CPU del host mucho más alto. La funcionalidad es la misma; el rendimiento no.

### Exercise 2

**2a.** El *virtual size* es la capacidad que ve el SO del guest (por ejemplo 20 GiB) — la geometría anunciada al guest. El *disk size* es la cantidad de bytes del host que el archivo de imagen ocupa actualmente. Para una imagen dispersa/`qcow2`, el disk size arranca cerca de cero y **crece a medida que el guest escribe**, hasta (pero limitado por) el virtual size. El virtual size es fijo hasta que hacés `qemu-img resize`.

**2b.** Un backing file debe tratarse como de solo lectura durante toda la vida de cualquier overlay que dependa de él. `overlay.qcow2` almacena solo las *diferencias* contra `disk.qcow2` por cluster; si modificás `disk.qcow2` directamente, los clusters no modificados del overlay ahora apuntan a datos que ya no coinciden con lo que el guest espera, corrompiendo silenciosamente la vista que el guest tiene del disco. Nunca escribas en un backing file mientras un overlay está en vivo.

**2c.** `qemu-img convert -f qcow2 -O vmdk disk.qcow2 disk.vmdk`. La flag `-O` fija el formato de *salida* (`-f` fija el formato de entrada). El formato nativo de VMware es `vmdk`; `qemu-img` también puede producir `vpc` (VHD de Hyper-V), `vhdx`, `raw`, `qcow2`, etc.

**2d.** Esos comandos asumen que la imagen está en reposo (quiescent). Una VM en ejecución está mutando el archivo activamente, así que `qemu-img check` puede reportar corrupción falsa y `qemu-img convert` va a leer una imagen inconsistente y desgarrada (torn) — y cualquier escritura que haga compite con las de QEMU. Ambas operaciones requieren la VM detenida (o debés usar el monitor/QMP para operaciones en vivo). En línea, usá los comandos de snapshot de blockdev/QMP en su lugar.

### Exercise 3

**3a.** `-boot order=d` hace del primer CD-ROM el dispositivo de arranque primario, así que la VM arranca el instalador del ISO. Una vez que el SO está instalado querés arrancar el disco: cambiá a `-boot order=c` (primer disco duro), o quitá el `-cdrom`/poné `menu=on` y elegí manualmente. Letras: `a`/`b` = disquete, `c` = primer disco duro, `d` = primer CD-ROM, `n` = red/PXE.

**3b.** El back-end `-netdev` define cómo entran/salen realmente los paquetes del host (SLIRP en modo usuario, TAP/bridge, socket, etc.) — es invisible para el guest. El front-end `-device` (por ejemplo `virtio-net-pci`, `e1000`) es la NIC emulada que el SO del guest ve y para la cual carga un driver. Se ligan haciendo coincidir el `id`. El guest ve el *front-end*; el *back-end* decide el destino de los paquetes.

**3c.** `-machine ...,accel=kvm` (y `-accel kvm`) hace de KVM un requisito estricto: si KVM no está disponible, QEMU **no arranca** con un error. `-enable-kvm` históricamente se comportaba igual pero la forma moderna, explícita y componible es `-accel kvm`; el patrón riesgoso es `-machine accel=kvm:tcg`, que cae *silenciosamente* a TCG lento. En un pipeline querés la forma que falla de manera estricta para que un host roto se detecte en vez de enviar una VM lenta emulada por accidente.

**3d.** QEMU corre un hilo del host por CPU virtual (aquí 2 hilos de vCPU), más el hilo principal de E/S/bucle de eventos y hilos auxiliares. `info cpus` lista cada vCPU con un `thread_id` del host, permitiéndote mapear las CPU del guest a hilos del host (útil para pinning/`taskset` y diagnosticar una única vCPU caliente).

### Exercise 4

**4a.** (1) Cambiá de consola dentro de la ventana GTK/SDL con **Ctrl+Alt+2** (monitor) / **Ctrl+Alt+1** (guest). (2) Redirigilo a tu terminal de lanzamiento con `-monitor stdio` (o multiplexalo sobre la consola serie bajo `-nographic` vía **Ctrl+a c**). Para acceso headless/por red, exponelo como socket: `-monitor telnet:127.0.0.1:5555,server,nowait` y conectate con `telnet 127.0.0.1 5555` (o usá QMP: `-qmp`).

**4b.** `system_powerdown` envía un evento de encendido ACPI para que el SO del guest se apague limpiamente (vuelca cachés y desmonta). `stop` simplemente congela las vCPU (el guest sigue residente, reanudá con `cont`). `quit` termina el proceso de QEMU instantáneamente sin aviso al guest — el equivalente de tirar del cable de alimentación, lo que **arriesga la corrupción del sistema de archivos** porque las escrituras en vuelo y las cachés sucias se pierden.

**4c.** QEMU divide el almacenamiento en un back-end (`drive_add` / el archivo del lado del host y la ruta de E/S, `if=none`) y un dispositivo front-end en un bus del guest (`device_add virtio-blk-pci`). `drive_add` registra el medio; `device_add` lo presenta al guest. `device_del` quita el dispositivo visible para el guest (disparando un unplug ACPI), lo cual es suficiente para desconectarlo del guest; el back-end ahora huérfano puede liberarse después. Esto refleja la misma división front-end/back-end que la red.

**4d.** `info block`. Muestra la línea `Cache mode:` por unidad. El modo de caché importa porque `writeback` deja que la caché de páginas del host confirme las escrituras antes de que lleguen al almacenamiento estable — rápido, pero un crash/corte de energía del host puede perder datos del guest recientemente "escritos". `writethrough`/`none`+`O_DIRECT`/`directsync` intercambian rendimiento por garantías de durabilidad más fuertes.

### Exercise 5

**5a.** Un `savevm` del monitor captura el **estado en vivo de la VM — registros de CPU y RAM — más el disco**, así que `loadvm` reanuda la ejecución a mitad de vuelo. `qemu-img snapshot -c` (offline) captura solo el disco. Los distinguís por la columna `VM SIZE` en `info snapshots` / `qemu-img snapshot -l`: un `VM SIZE` distinto de cero (por ejemplo `220 MiB`) significa RAM guardada; `0 B` significa un snapshot solo de disco.

**5b.** Los snapshots internos almacenan múltiples versiones puntuales de clusters más el blob de estado de la VM dentro del propio archivo de imagen, lo que requiere metadatos de formato que lo soporten (`qcow2`, `qed`, etc.). `raw` no tiene capa de metadatos — es solo los bytes lineales del disco — así que no puede contener snapshots; QEMU rechaza `savevm` en una VM solo-raw.

**5c.** Un snapshot interno vive dentro de la imagen específica. Si la maquinaria de snapshot toca un *backing file compartido*, o hacés snapshot solo del overlay mientras la imagen de respaldo se modifica/reemplaza después, el snapshot puede referenciar clusters que ya no significan lo que significaban — estado inconsistente o irrecuperable. Mantené los backing files inmutables y preferí hacer snapshot de la imagen completa y autocontenida.

**5d.** `loadvm` restaura la CPU, la RAM y el disco al *mismo instante* atómicamente, así que el guest reanuda desde un punto totalmente consistente — sin estado desgarrado. Un backup a nivel de sistema de archivos tomado desde dentro de un guest en ejecución captura el disco en un momento en que la RAM tenía datos sin volcar y los archivos estaban a mitad de escritura, así que restaurarlo puede producir un sistema de archivos inconsistente que necesita fsck/recuperación del journal, sin un estado de memoria coincidente.

### Exercise 6

**6a.** En SLIRP, `10.0.2.2` es el gateway virtual (también el host tal como lo ve el guest) y `10.0.2.3` es el reenviador DNS incorporado. Cada guest en modo usuario obtiene su propia red NAT `10.0.2.0/24` privada y aislada, emulada enteramente dentro de su propio proceso de QEMU, así que dos guests pueden ser ambos `10.0.2.15` sin conflicto — las redes nunca se tocan entre sí ni con la LAN a nivel de capa 2.

**6b.** SLIRP en modo usuario es solo NAT de salida: el guest alcanza el internet, pero su dirección privada `10.0.2.0/24` es inalcanzable desde afuera de ese proceso de QEMU. Soluciones: (1) con modo usuario, agregá un `hostfwd` (por ejemplo `hostfwd=tcp::2222-:22`) y hacé SSH al puerto 2222 del host; (2) cambiá el back-end a TAP sobre un bridge para que el guest obtenga una dirección de LAN real alcanzable directamente.

**6c.** Con TAP + un bridge del host el guest es un nodo de primera clase en capa 2 sobre la LAN física, con su propia dirección enrutable (típicamente vía el DHCP de la LAN). No hay frontera de NAT que atravesar, así que cualquier host de la red lo alcanza directamente — el reenvío de puertos solo existe para perforar el NAT de SLIRP que TAP no tiene.

**6d.** Fijar una MAC hace que la identidad del guest sea estable a través de reinicios y relanzamientos, así que las reservas de DHCP, los enlaces de licencia y las reglas de firewall siguen funcionando (una MAC generada aleatoriamente en cada arranque las rompería). `52:54:00` es el prefijo OUI registrado de QEMU/KVM — ver esto en una red es una señal fuerte de que la interfaz pertenece a una máquina virtual QEMU.

### Exercise 7

**7a.** QEMU provee la emulación/virtualización de máquina real: crea el hardware virtual y, vía KVM, ejecuta el guest. libvirt agrega una capa de gestión por encima — definiciones de dominio XML persistentes, una API/CLI estable (`virsh`), ciclo de vida y autostart, pools de almacenamiento/red, y control de acceso — mientras delega el trabajo real a QEMU.

**7b.** libvirt no reimplementa el control del guest; maneja la *misma* instancia de QEMU a través del socket de control monitor/QMP de esa instancia. `virsh shutdown` simplemente emite la solicitud de apagado ACPI sobre QMP — exactamente lo que hace `system_powerdown` en el monitor. Las rutas gestionada y manual convergen en un único proceso `qemu-system-x86_64` en ejecución.

**7c.** QMP es un protocolo JSON estructurado y parseable por máquina, diseñado para control programático, con comandos, respuestas y eventos asíncronos bien definidos — robusto para que lo consuma software. La interfaz humana `-monitor stdio` es texto de forma libre pensado para tipear interactivamente y puede cambiar de formato entre versiones, lo que la hace poco fiable de parsear. Por eso libvirt usa el socket de control QMP (`mode=control`) para automatización determinista.

</details>

---

### Reference sources

- LPI — Exam 305 Objectives (305-300, v3.0): https://www.lpi.org/our-certifications/exam-305-objectives/
- QEMU — Invocation / command-line options: https://www.qemu.org/docs/master/system/invocation.html
- QEMU — QEMU Monitor: https://www.qemu.org/docs/master/system/monitor.html
- QEMU — `qemu-img` reference: https://www.qemu.org/docs/master/tools/qemu-img.html
- QEMU — Disk images & snapshots: https://www.qemu.org/docs/master/system/images.html
- QEMU — Network emulation (user/TAP back-ends): https://www.qemu.org/docs/master/system/devices/net.html
- Linux KVM project: https://www.linux-kvm.org/page/Main_Page
- Kernel.org — KVM documentation: https://docs.kernel.org/virt/kvm/index.html
- libvirt — QEMU/KVM hypervisor driver: https://libvirt.org/drvqemu.html