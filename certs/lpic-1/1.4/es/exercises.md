# Ejercicios Pr\u00e1cticos: 1.4 Devices, Linux Filesystems, Filesystem Hierarchy Standard

Estos ejercicios simulan un entorno de mantenimiento y resoluci\u00f3n de problemas sobre sistemas de archivos y dispositivos de bloque, tareas cotidianas para asegurar la confiabilidad del almacenamiento (storage reliability).

## Ejercicio 1: Identificaci\u00f3n y Montaje de Dispositivos por UUID

Trabajar con `/dev/sdb1` en el archivo `/etc/fstab` es un antipatr\u00f3n en producci\u00f3n porque el orden de los discos puede cambiar al reiniciar. Cambiaremos esto usando UUIDs estables.

### Pasos

1. Lista todos los dispositivos de bloque actuales con su jerarqu\u00eda y sus File System Types (FSTYPE):
   ```bash
   lsblk -f
   ```
2. Escanea un bloque espec\u00edfico (supongamos `/dev/sda1` o el que tenga montado `/`) para obtener su UUID preciso y otras propiedades (como TYPE y PARTUUID):
   ```bash
   sudo blkid /dev/sda1
   ```
3. *(Simulaci\u00f3n Mental o en VM)* Si fueras a montar ese disco persistentemente, \u00bfc\u00f3mo escribir\u00edas la entrada en `/etc/fstab`? Imagina que el UUID es `1234-ABCD` y el tipo es `ext4`. Escribe el comando para ver el archivo `fstab` actual y comp\u00e1ralo con tu respuesta:
   ```bash
   cat /etc/fstab
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** \u00bfPor qu\u00e9 es arquitect\u00f3nicamente inseguro usar nomenclaturas como `/dev/sda1` o `/dev/nvme0n1p1` directamente en el `/etc/fstab` de un servidor f\u00edsico?

---

## Ejercicio 2: Monitoreo y Saturaci\u00f3n de Inodes

Un desarrollador reporta que la aplicaci\u00f3n falla al escribir logs con el mensaje `No space left on device`, pero el sistema de monitoreo muestra que el disco est\u00e1 al 50% de su capacidad.

### Pasos

1. Verifica el uso tradicional del espacio en disco en particiones legibles por humanos:
   ```bash
   df -Th
   ```
2. Ahora, verifica el uso de la tabla de Inodes (el \u00edndice que el sistema de archivos utiliza para rastrear los metadatos de los archivos):
   ```bash
   df -ih
   ```
3. Si descubrieras que el directorio `/var` est\u00e1 al 100% de uso de Inodes, utilizar\u00edas este comando (no destructivo, pero intensivo) para encontrar qu\u00e9 subdirectorio tiene demasiados archivos peque\u00f1os. Ejec\u00fatalo en tu `/var` (puede tardar un momento):
   ```bash
   sudo find /var/ -xdev -type f | cut -d "/" -f 2,3 | sort | uniq -c | sort -n | tail -n 5
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** Seg\u00fan tu an\u00e1lisis, \u00bfqu\u00e9 es un Inode y por qu\u00e9 un sistema de archivos `ext4` puede quedarse sin espacio para guardar nuevos archivos aunque tenga 100 GB de espacio libre (data blocks)?

---

## Ejercicio 3: Mantenimiento de Filesystems (fsck y tune2fs)

Un servidor sufri\u00f3 un corte abrupto de energ\u00eda y ahora el sistema principal est\u00e1 montado en Read-Only (Solo Lectura) como mecanismo de protecci\u00f3n.

### Pasos

1. Examina las \u00faltimas l\u00edneas del anillo de mensajes del kernel buscando advertencias (Warnings o Errors) del sistema de archivos `ext4`:
   ```bash
   dmesg -T | grep -i ext4
   ```
2. Imagina que vas a forzar una revisi\u00f3n del sistema de archivos `/dev/sdb1` (si no lo tienes, solo lee el comando). Para hacerlo de forma segura, el volumen **debe** estar desmontado. El comando ser\u00eda:
   ```bash
   # sudo umount /dev/sdb1
   # sudo fsck.ext4 -fy /dev/sdb1
   ```
3. Como paso proactivo, inspecciona la configuraci\u00f3n interna del superblock de tu partici\u00f3n principal (`/`) usando `tune2fs` (reemplaza `/dev/sda2` por tu partici\u00f3n real identificada en el Ejercicio 1):
   ```bash
   sudo tune2fs -l /dev/sda2 | grep -i "reserved block count"
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** El comando `tune2fs -l` muestra el "Reserved block count", que por defecto en `ext4` es el 5% del tama\u00f1o total del disco, reservado para el usuario `root`. En un disco de 10 Terabytes destinado exclusivamente a almacenar datos de una base de datos PostgreSQL, \u00bfpor qu\u00e9 dejar este valor por defecto es una mala pr\u00e1ctica SRE y qu\u00e9 comando usar\u00edas para ajustarlo?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** Porque en sistemas bare-metal (y a veces en hipervisores), el orden en el que el bus PCI/SATA/NVMe enumera los dispositivos durante el boot puede cambiar. Si a\u00f1ades un disco nuevo, el antiguo `/dev/sdb` podr\u00eda convertirse en `/dev/sdc`. Usar el UUID garantiza que el kernel monte el sistema de archivos correcto independientemente de en qu\u00e9 puerto f\u00edsico o virtual est\u00e9 conectado.

**Respuesta 2.1:** Un Inode (Index Node) es una estructura de datos que almacena los metadatos de un archivo (permisos, propietario, timestamps, y punteros a los bloques de datos f\u00edsicos), pero no el nombre del archivo ni su contenido. En `ext4`, la cantidad total de inodes se define est\u00e1ticamente al momento de formatear (con `mkfs`). Si una aplicaci\u00f3n crea millones de archivos de 1 byte, agotar\u00e1 todos los Inodes disponibles antes de llenar los bloques de datos libres, impidiendo la creaci\u00f3n de cualquier archivo nuevo.

**Respuesta 3.1:** Dejar un 5% reservado en un volumen de 10 TB significa desperdiciar 500 GB de almacenamiento costoso (que PostgreSQL no podr\u00e1 usar, ya que corre como usuario `postgres`, no `root`). Este 5% est\u00e1 dise\u00f1ado originalmente para la partici\u00f3n ra\u00edz (`/`) para asegurar que si un usuario llena el disco, el usuario `root` y los demonios del sistema sigan pudiendo escribir logs y operar. En un disco de datos, el SRE debe reducir este porcentaje al 0% o 1% utilizando: `sudo tune2fs -m 0 /dev/sdb1`.

</details>