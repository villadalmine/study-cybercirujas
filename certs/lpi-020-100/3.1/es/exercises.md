# Guía de Estudio para la Certificación: LPI Security Essentials (Examen 020-100, Versión 1.0)
## Tema 3.1: Seguridad de Nodos, Dispositivos y Almacenamiento
**Ponderación del examen:** 20  
**Referencia oficial:** [LPI Security Essentials Overview](https://www.lpi.org/our-certifications/security-essentials-overview/)

---

### Descripción General de la Arquitectura y Competencias Objetivo

En la infraestructura de producción —ya sea en nodos de Kubernetes bare-metal, máquinas virtuales en la nube o dispositivos edge— proteger el nodo host, las interfaces periféricas y los subsistemas de almacenamiento constituye la base del modelo de defensa en profundidad. Las vulnerabilidades en la capa de hardware o de almacenamiento de bloques evaden los controles de las capas superiores (tales como firewalls de red o runtimes de contenedores).

Esta guía proporciona ejercicios prácticos detallados y de nivel de producción que abarcan cuatro áreas de dominio esenciales:
1. **Seguridad de Hardware y Firmware**: TPM 2.0, Unified Extensible Firmware Interface (UEFI) Secure Boot, bindings de PCR y protección de interfaces periféricas mediante `usbguard`.
2. **Seguridad de Almacenamiento de Datos en Reposo**: Cifrado de dispositivos de bloques mediante `LUKS2`/`dm-crypt`, derivación de claves Argon2id, desellado de claves TPM2 a través de `systemd-cryptenroll` y puntos de montaje fortalecidos.
3. **Aplicación de Integridad del Sistema y Almacenamiento**: Parámetros de protección del kernel (`sysctl`), dispositivos de bloques firmados criptográficamente (`dm-verity`) e Integrity Measurement Architecture (`IMA`).
4. **Disponibilidad y Resiliencia de Datos**: Verificación de redundancia de almacenamiento, depuración (scrubbing) automatizada de integridad y estrategias de respaldo append-only e inmutables.

---

### Módulo 1: Arquitectura de Seguridad de Nodos y Hardware (TPM 2.0, Secure Boot y USBGuard)

#### Concepto Técnico Profundo
La seguridad del hardware se basa en establecer una **Cadena de Confianza** (Chain of Trust) que comienza desde una raíz de confianza inmutable basada en hardware: el **Trusted Platform Module (TPM 2.0)** y **UEFI Secure Boot**. 

- **Platform Configuration Registers (PCRs)**: El TPM contiene registros criptográficos que no se pueden sobrescribir directamente; solo se pueden *extender* con hashes de binarios de firmware, bootloaders, imágenes del kernel y políticas de seguridad.
  - **PCR 0**: Core System Firmware (código ejecutable de BIOS/UEFI).
  - **PCR 4**: Código del Boot Manager y Boot Configuration Data.
  - **PCR 7**: Estado de Secure Boot y firmas de políticas PK/KEK/db.
- **Fortalecimiento de Periféricos**: Los dispositivos USB representan vectores de ataque físico (por ejemplo, inyección de pulsaciones de teclas con BadUSB, acceso directo a memoria o DMA no autorizado). `usbguard` utiliza eventos de `udev` del kernel de Linux y sockets netlink para bloquear descriptores de dispositivos USB no aprobados basándose en la clase, subclase y números de serie.

Referencias oficiales:
- [Trusted Computing Group TPM 2.0 Library Specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/)
- [USBGuard Documentation](https://usbguard.github.io/)

---

#### Ejercicio 1.1: Auditoría de Registros PCR de TPM 2.0 y Estado de Confianza del Hardware

##### Paso 1: Verificar la Disponibilidad del Controlador de Dispositivo TPM 2.0
Inspeccioná los mensajes del kernel ring y los dispositivos de caracteres para asegurarte de que el chip TPM 2.0 sea reconocido por el kernel de Linux.

```bash
ls -l /dev/tpm*
dmesg | grep -i tpm
```

*Resultado esperado:*
```text
crw-rw---- 1 root tss 253, 0 Aug 07 00:00 /dev/tpm0
crw-rw---- 1 root tss 253, 65536 Aug 07 00:00 /dev/tpmrm0
[    1.204512] tpm_tis 00:01: 2.0 TPM (device-id 0x1B, rev-id 16)
[    1.218901] tpm tpm0: A TPM 2.0 chip is detected (scanned 1 DTPM)
```

##### Paso 2: Leer los Platform Configuration Registers (PCRs)
Usá `tpm2_pcrread` para mostrar el estado actual en SHA-256 de las mediciones de arranque de la plataforma.

```bash
tpm2_pcrread sha256:0,4,7
```

*Resultado esperado:*
```text
sha256:
  0 : 0xDF23A16F8C8B564E9C12A09B2B471C5DE67D980F123C890AB76D1E89F0A2B11C
  4 : 0x7E12BC9A4310EE987F09D1B2C34E5F678901ABCD2345EF678901234567890ABC
  7 : 0x3F890ABCD1234567890EF1234567890ABC1234567890DEF1234567890ABCDEF1
```

---

#### Ejercicio 1.2: Aplicación del Control de Periféricos a través de USBGuard

##### Paso 1: Generar una Política Inicial de USBGuard
Creá un conjunto de reglas base que permita los descriptores de autorización USB actualmente conectados mientras bloquea dispositivos desconocidos futuros.

```bash
sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf
```

*Resultado esperado:*
```text
allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" hash "..." parent-hash "..." via-port "usb1" with-interface 09:00:00
allow id 046d:c52b serial "" name "USB Receiver" hash "..." parent-hash "..." via-port "1-1" with-interface { 03:01:01 03:01:02 03:00:00 }
```

##### Paso 2: Configurar la Política del Demonio de USBGuard
Inspeccioná `/etc/usbguard/usbguard-daemon.conf` para aplicar denegación implícita a dispositivos no autorizados y registrar eventos de auditoría en syslog.

```bash
sudo cat << 'EOF' | sudo tee /etc/usbguard/usbguard-daemon.conf
RuleFile=/etc/usbguard/rules.conf
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=false
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=wheel
AuditBackend=syslog
EOF
```

##### Paso 3: Habilitar y Verificar el Estado de USBGuard
Iniciá el servicio `usbguard` y verificá la aplicación de la política activa.

```bash
sudo systemctl restart usbguard
sudo systemctl status usbguard
sudo usbguard list-devices
```

*Resultado esperado:*
```text
● usbguard.service - USBGuard daemon
     Loaded: loaded (/lib/systemd/system/usbguard.service; enabled; vendor preset: enabled)
     Active: active (running) since Fri 2026-08-07 00:05:00 UTC; 10s ago
   Main PID: 14205 (usbguard-daemon)
...
1: allow id 1d6b:0002 serial "0000:00:14.0" name "xHCI Host Controller" ...
2: allow id 046d:c52b serial "" name "USB Receiver" ...
```

---

#### Preguntas de Verificación (Módulo 1)

1. ¿Qué sucede con una clave sellada dentro de un TPM 2.0 vinculada a PCR 0 y PCR 7 si un atacante graba (flashea) una imagen de firmware UEFI modificada y no autenticada en la placa madre?
2. En `usbguard`, ¿cuál es la diferencia clave entre configurar `ImplicitPolicyTarget` en `block` frente a `reject`?

---

### Módulo 2: Seguridad del Almacenamiento y Cifrado en Reposo (LUKS2, dm-crypt y Fortalecimiento de Montajes)

#### Concepto Técnico Profundo
La protección de datos en reposo se basa en el cifrado de dispositivos de bloques a través de `dm-crypt` y la especificación de encabezado `LUKS2` (Linux Unified Key Setup v2).

```
+-----------------------------------------------------------------------------------+
|                                  User Space                                       |
|                  Application / POSIX System Calls (read/write)                    |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                              Filesystem (ext4 / xfs)                              |
|                    Mount Options: nodev, noexec, nosuid, ro                       |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                        Kernel Device Mapper Subsystem                             |
|                 dm-crypt (AES-256-XTS cipher / Argon2id KDF)                     |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
|                       Physical / Virtual Block Device                             |
|                    /dev/nvme0n1p2 or /dev/sdb1 (LUKS2 Header)                     |
+-----------------------------------------------------------------------------------+
```

- **Primitivas Criptográficas**: LUKS2 estándar utiliza `aes-xts-plain64` con un tamaño de clave de 512 bits y la función de derivación de claves (KDF) `Argon2id` para prevenir ataques de fuerza bruta acelerados por GPU contra las frases de paso del volumen.
- **Desellado Automático de TPM2**: `systemd-cryptenroll` vincula las ranuras de clave de LUKS2 directamente a los PCRs de TPM 2.0, permitiendo el descifrado automatizado durante el arranque **solo si** el estado de integridad del sistema (Secure Boot + Firmware) permanece inalterado.
- **Flags de Seguridad para el Montaje de Archivos**:
  - `nodev`: Previene la interpretación de dispositivos especiales de caracteres o bloques en el sistema de archivos.
  - `nosuid`: Bloquea la efectividad de los bits set-user-identifier (`SUID`) o set-group-identifier (`SGID`).
  - `noexec`: Deshabilita la ejecución de cualquier binario en el sistema de archivos montado.

Referencias oficiales:
- [Linux Kernel dm-crypt Documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html)
- [freedesktop.org systemd-cryptenroll Documentation](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)

---

#### Ejercicio 2.1: Aprovisionamiento de un Volumen de Almacenamiento Cifrado LUKS2 con Argon2id

##### Paso 1: Formatear un Dispositivo de Bloques Secundario con LUKS2
Formateá `/dev/sdb1` (o un dispositivo loopback `/dev/loop0`) con parámetros criptográficos explícitos.

```bash
# Create a dummy 1GB raw backing storage file if testing on a sandbox
dd if=/dev/zero of=/var/tmp/secure_storage.img bs=1M count=1024
sudo losetup /dev/loop0 /var/tmp/secure_storage.img

# Format block device with LUKS2
echo -n "ProductionPassphrase123!" | sudo cryptsetup luksFormat /dev/loop0 \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --pbkdf argon2id \
  --hash sha512 \
  --label "SECURE_DATA" \
  --key-file -
```

*Resultado esperado:*
```text
WARNING!
========
This will overwrite data on /dev/loop0 irrevocably.

Command successful.
```

##### Paso 2: Volcar y Verificar los Metadatos de LUKS2
Inspeccioná el encabezado de LUKS2 para verificar el cifrado, el algoritmo PBKDF y la asignación de ranuras de clave.

```bash
sudo cryptsetup luksDump /dev/loop0
```

*Resultado esperado:*
```text
LUKS header information
Version:        2
Epoch:          3
Metadata area:  16384 bytes
Keyslots area:  16744448 bytes
UUID:           a1b2c3d4-e5f6-7890-abcd-1234567890ab
Label:          SECURE_DATA

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	cipher: aes-xts-plain64
	sector: 512 [bytes]

Keyslots:
  0: luks2
	Cipher:        aes-xts-plain64
	PBKDF:         argon2id
	Hash:          sha512
	Time cost:     4
	Memory cost:   1048576
	Threads:       4
```

##### Paso 3: Abrir el Mapeo Cifrado y Formatear el Sistema de Archivos
Mapeá el dispositivo de bloques cifrado a `/dev/mapper/secure_vault` y formatealo con `ext4`.

```bash
echo -n "ProductionPassphrase123!" | sudo cryptsetup open /dev/loop0 secure_vault --key-file -
sudo mkfs.ext4 -L "VAULT" /dev/mapper/secure_vault
```

*Resultado esperado:*
```text
Opening /dev/loop0 as secure_vault...
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 258048 4k blocks and 64512 inodes
Filesystem UUID: f890abcd-1234-5678-90ab-cdef12345678
Allocating group tables: done                            
Writing inode tables: done                            
Creating journal (4096 blocks): done
Writing superblocks and filesystem accounting information: done
```

---

#### Ejercicio 2.2: Fortalecimiento de Montajes de Sistemas de Archivos en `/etc/fstab`

##### Paso 1: Crear un Punto de Montaje Destino Seguro
Creá el directorio `/mnt/secure_vault` con permisos restrictivos.

```bash
sudo mkdir -p /mnt/secure_vault
sudo chmod 700 /mnt/secure_vault
```

##### Paso 2: Configurar `/etc/fstab` con Flags de Aplicación de Seguridad
Anexá una entrada en `/etc/fstab` utilizando la coincidencia por UUID y opciones de montaje estrictas (`defaults`, `nodev`, `nosuid`, `noexec`).

```bash
VAULT_UUID=$(sudo blkid -s UUID -o value /dev/mapper/secure_vault)
echo "UUID=${VAULT_UUID} /mnt/secure_vault ext4 defaults,nodev,nosuid,noexec 0 2" | sudo tee -a /etc/fstab
sudo mount -a
```

##### Paso 3: Auditar la Aplicación de Opciones de Montaje
Verificá mediante `findmnt` que los flags `nodev`, `nosuid` y `noexec` estén activos en `/mnt/secure_vault`.

```bash
findmnt -M /mnt/secure_vault -o TARGET,FSTYPE,OPTIONS
```

*Resultado esperado:*
```text
TARGET            FSTYPE OPTIONS
/mnt/secure_vault ext4   rw,nosuid,nodev,noexec,relatime
```

##### Paso 4: Validar la Mecánica de Aplicación de `noexec`
Intentá ejecutar un binario dentro de la partición montada para asegurarte de que la ejecución sea bloqueada por el kernel.

```bash
sudo cp /bin/echo /mnt/secure_vault/test_echo
sudo chmod +x /mnt/secure_vault/test_echo
/mnt/secure_vault/test_echo "Hello World"
```

*Resultado esperado:*
```text
bash: /mnt/secure_vault/test_echo: Permission denied
```

---

#### Ejercicio 2.3: Vinculación de la Clave de Volumen LUKS2 a TPM 2.0 a través de `systemd-cryptenroll`

##### Paso 1: Registrar TPM 2.0 en la Ranura de Clave de LUKS2
Vinculá el descifrado de `/dev/loop0` a los PCR 0 (Firmware) y PCR 7 (Estado de Secure Boot) del TPM2.

```bash
echo -n "ProductionPassphrase123!" | sudo systemd-cryptenroll \
  --tpm2-device=auto \
  --tpm2-pcrs=0+7 \
  /dev/loop0
```

*Resultado esperado:*
```text
Enrolling TPM2 token...
New TPM2 token enrolled as key slot 1.
```

##### Paso 2: Validar los Tokens de LUKS2 Registrados
Verificá que el volcado de LUKS muestre el token systemd-tpm2 recién registrado.

```bash
sudo cryptsetup luksDump /dev/loop0 | grep -A 8 "Tokens:"
```

*Resultado esperado:*
```text
Tokens:
  0: systemd-tpm2
	Keyslot: 1
	tpm2-pcr-bank: sha256
	tpm2-pcrs: 0,7
```

---

#### Preguntas de Verificación (Módulo 2)

1. Si un nodo aloja una partición de datos compartida en `/mnt/data` con las opciones `defaults,nosuid,nodev`, ¿puede un usuario crear un archivo ejecutable funcional, compilar código o ejecutar scripts de bash en ese directorio? Explicá por qué sí o por qué no.
2. ¿Contra qué vector de ataque diferenciado protege la KDF `Argon2id` en comparación con el `pbkdf2` heredado en los encabezados de LUKS1?

---

### Módulo 3: Aplicación de Integridad del Sistema y Almacenamiento (Parámetros del Kernel, dm-verity e IMA)

#### Concepto Técnico Profundo

Prevenir la manipulación en tiempo de ejecución y las modificaciones de datos fuera de línea requiere mecanismos sólidos de aplicación en el kernel:

```
                  +---------------------------------------+
                  |  Read Request for File / Block Data   |
                  +---------------------------------------+
                                      |
                                      v
                  +---------------------------------------+
                  |       Integrity Engine Check          |
                  +---------------------------------------+
                                 /         \
                                /           \
              dm-verity (Block Level)      IMA / EVM (File Level)
              Calculates sector hash       Measures file execution hash
              Compares vs Merkle Tree      Compares vs Kernel Policy/TPM
                                \           /
                                 \         /
                                  v       v
                        +-------------------+
                        | Integrity Match?  |
                        +-------------------+
                           /             \
                   YES    /               \    NO
                         v                 v
               [ Allow IO Access ]   [ Block IO / I/O Error ]
```

- **Fortalecimiento del Kernel (`sysctl`)**: Deshabilitar el acceso BPF no privilegiado, aplicar restricciones strictly de enlaces duros (hardlinks)/simbólicos (symlinks), restringir la exposición de punteros del kernel (`kptr_restrict`) y aplicar restricciones a dmesg previene la escalación de privilegios local (LPE).
- **dm-verity**: Proporciona una verificación de integridad transparente de solo lectura para dispositivos de bloques mediante un árbol de hashes criptográficos (**Merkle Tree**). Si un solo bit en el disco es manipulado fuera de línea, `dm-verity` detecta una discrepancia de hash y genera un error de I/O o desencadena un kernel panic inmediato.
- **Integrity Measurement Architecture (IMA)**: Mide el hash criptográfico de los archivos antes de que sean ejecutados o leídos por el kernel, anexando estas mediciones al PCR 10 del TPM.

Referencias oficiales:
- [Linux Kernel dm-verity Documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-verity.html)
- [Linux Kernel IMA Subsystem Documentation](https://www.kernel.org/doc/html/latest/security/IMA-subsystem.html)

---

#### Ejercicio 3.1: Aplicación de Parámetros de Seguridad del Kernel en Producción (`sysctl`)

##### Paso 1: Crear una Configuración del Kernel Fortalecida para Producción
Escribí las reglas de fortalecimiento del sistema en `/etc/sysctl.d/99-node-security.conf`.

```bash
sudo cat << 'EOF' | sudo tee /etc/sysctl.d/99-node-security.conf
# Restrict kernel pointer addresses in /proc and dmesg
kernel.kptr_restrict = 2

# Restrict dmesg access to CAP_SYSLOG
kernel.dmesg_restrict = 1

# Disable unprivileged eBPF execution
kernel.unprivileged_bpf_disabled = 1

# Enable JIT hardening for eBPF
net.core.bpf_jit_harden = 2

# Protect against hardlink/symlink TOCTOU attacks
fs.protected_hardlinks = 1
fs.protected_symlinks = 1

# Protect FIFO and regular files in world-writable sticky directories
fs.protected_fifos = 2
fs.protected_regular = 2

# Disable kexec system call to prevent loading unverified kernel runtime
kernel.kexec_load_disabled = 1
EOF
```

##### Paso 2: Aplicar y Validar los Parámetros de Seguridad
Cargá las configuraciones dinámicamente y auditá las claves de sysctl activas.

```bash
sudo sysctl --system
sudo sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled fs.protected_hardlinks
```

*Resultado esperado:*
```text
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
fs.protected_hardlinks = 1
```

---

#### Ejercicio 3.2: Configuración de la Verificación de Integridad de Root de Solo Lectura a través de `dm-verity`

##### Paso 1: Preparar los Dispositivos de Almacenamiento de Datos en Bruto y Hashes
Creá dos dispositivos loop que representen una partición root de solo lectura (`/dev/loop1`) y un dispositivo de hashes de metadatos (`/dev/loop2`).

```bash
# Create data block file (100MB) and hash metadata file (20MB)
dd if=/dev/zero of=/var/tmp/ro_data.img bs=1M count=100
dd if=/dev/zero of=/var/tmp/ro_hash.img bs=1M count=20

sudo losetup /dev/loop1 /var/tmp/ro_data.img
sudo losetup /dev/loop2 /var/tmp/ro_hash.img

# Format loop1 with ext4 filesystem containing sample files
sudo mkfs.ext4 /dev/loop1
sudo mkdir -p /mnt/verity_test
sudo mount /dev/loop1 /mnt/verity_test
echo "Root filesystem immutable data v1.0" | sudo tee /mnt/verity_test/integrity_check.txt
sudo umount /mnt/verity_test
```

##### Paso 2: Formatear el Dispositivo de Bloques con `veritysetup`
Generá el Merkle Tree criptográfico en el dispositivo de hashes y mostrá el **Root Hash**.

```bash
sudo veritysetup format /dev/loop1 /dev/loop2 | tee /var/tmp/verity_format.log
```

*Resultado esperado:*
```text
VERITY header information
Version:        1
Hash algorithm: sha256
Data block size: 4096
Hash block size: 4096
Data blocks:     25600
Salt:           a1b2c3d4e5f678901234567890abcdef1234567890abcdef1234567890abcdef
Root hash:      e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

##### Paso 3: Crear el Mapeo Verificado
Adjuntá el dispositivo verity utilizando el Root Hash generado.

```bash
ROOT_HASH=$(grep "Root hash:" /var/tmp/verity_format.log | awk '{print $3}')
sudo veritysetup open /dev/loop1 verity_protected /dev/loop2 "$ROOT_HASH"
```

##### Paso 4: Validar el Acceso de Lectura y la Protección contra Manipulaciones
Montá el dispositivo mapeado con verity e intentá una modificación directa de bloques en bruto para simular la manipulación por parte de un rootkit.

```bash
# Mount verity device
sudo mkdir -p /mnt/verity_protected
sudo mount -o ro /dev/mapper/verity_protected /mnt/verity_protected
cat /mnt/verity_protected/integrity_check.txt

# Simulate low-level offline block corruption directly on backing data device
sudo umount /mnt/verity_protected
sudo veritysetup close verity_protected

# Corrupt sector data directly via dd
echo "MALICIOUS_CORRUPTION" | sudo dd of=/dev/loop1 bs=512 seek=2000 count=1 conv=notrunc

# Re-open verity mapping and trigger I/O read across corrupted block
sudo veritysetup open /dev/loop1 verity_protected /dev/loop2 "$ROOT_HASH"
sudo mount -o ro /dev/mapper/verity_protected /mnt/verity_protected
sudo cat /mnt/verity_protected/integrity_check.txt
```

*Resultado esperado:*
```text
Root filesystem immutable data v1.0
...
cat: /mnt/verity_protected/integrity_check.txt: Input/output error
```
*(El kernel registra un error explícito `device-mapper: verity: 7:1: data block 250 is corrupted` y deniega la lectura).*

---

#### Preguntas de Verificación (Módulo 3)

1. ¿Cómo detecta `dm-verity` si un atacante altera un solo byte en el dispositivo físico de almacenamiento de bloques? ¿Por qué el atacante no puede simplemente actualizar el hash correspondiente en el dispositivo de hashes?
2. ¿Qué vector de vulnerabilidad se elimina al configurar `kernel.kexec_load_disabled = 1` en un host en ejecución?

---

### Módulo 4: Disponibilidad de Datos, Redundancia de Almacenamiento y Estrategias de Respaldo Inmutables

#### Concepto Técnico Profundo

Security Essentials exige que la **Disponibilidad de Datos** se preserve frente a fallas de hardware, encriptadores de ransomware y errores administrativos.

- **Depuración (Scrubbing) de RAID / Almacenamiento**: Los arreglos de discos (por ejemplo, Software RAID `mdadm`, ZFS, Btrfs) pueden sufrir corrupción silenciosa de datos ("bit rot"). La depuración (scrubbing) periódica fuerza verificaciones de lectura en las unidades redundantes, utilizando bloques de paridad para reparar automáticamente los sectores defectuosos.
- **Respaldos Inmutables y Append-Only**: Proteger los respaldos contra compromisos requiere desacoplar a los escritores de respaldos de las capacidades de eliminación. 
  - **S3 Object Lock (Compliance Mode)** / **Inmutabilidad del Sistema de Archivos (`chattr +i`)**: Previene la modificación o eliminación de artefactos de respaldo incluso por parte del usuario `root` durante una ventana de retención definida.
  - **Bloqueo de Repositorios**: Utilizar herramientas modernas de respaldo (`restic`, `borg`) combinadas con controles de acceso append-only garantiza que los nodos comprometidos no puedan emitir un comando `prune` o `forget` para purgar respaldos remotos.

---

#### Ejercicio 4.1: Depuración de Integridad en Redundancia de Almacenamiento (`mdadm`)

##### Paso 1: Inspeccionar el Estado de Integridad del Arreglo RAID
Inspeccioná `/proc/mdstat` y emití un comando de depuración de integridad en segundo plano para calcular la paridad checksum de sectores en dispositivos Software RAID.

```bash
cat /proc/mdstat
```

*Resultado esperado:*
```text
Personalities : [raid1] [raid6] [raid5] [raid4] 
md0 : active raid1 sdb1[1] sda1[0]
      1047552 blocks super 1.2 [2/2] [UU]
```

##### Paso 2: Desencadenar la Depuración de Datos del Arreglo
Iniciá una operación de verificación en el dispositivo RAID para detectar y reparar automáticamente las discrepancias de paridad.

```bash
echo "check" | sudo tee /sys/block/md0/md/sync_action
cat /sys/block/md0/md/mismatch_cnt
```

*Resultado esperado:*
```text
check
0
```

---

#### Ejercicio 4.2: Implementación de Respaldos Inmutables Resistentes a Ransomware

##### Paso 1: Crear un Repositorio de Respaldo Local Cifrado usando Restic
Inicializá un repositorio cifrado utilizando `restic`.

```bash
# Install restic if missing
sudo apt-get install -y restic || sudo yum install -y restic

# Set repository location and password environment variable
export RESTIC_REPOSITORY="/var/backups/production_repo"
export RESTIC_PASSWORD="BackupEncryptionKey987!"

# Initialize backup repository
sudo -E restic init
```

*Resultado esperado:*
```text
created restic repository 8f90abcd12 at /var/backups/production_repo

Please note that knowledge of your password is required to access
the repository. Losing your password means total loss of data.
```

##### Paso 2: Realizar una Captura (Snapshot) Inicial
Realizá un respaldo de los directorios de configuración del host objetivo `/etc` y `/etc/sysctl.d`.

```bash
sudo -E restic backup /etc/sysctl.d /etc/usbguard
```

*Resultado esperado:*
```text
Files:           3 new,     0 changed,     0 unmodified
Dirs:            3 new,     0 changed,     0 unmodified
Added to the repository: 4.120 KiB

processed 3 files, 1.230 KiB in 0:00
snapshot 1a2b3c4d saved
```

##### Paso 3: Aplicar Inmutabilidad a Nivel del Sistema de Archivos en Repositorios de Respaldo
Establecé el atributo inmutable (`+i`) en el índice y blobs de datos del repositorio para bloquear acciones de escritura/eliminación/truncado, incluso por parte de `root`.

```bash
# Apply immutable flag recursively to repository data blocks
sudo chattr -R +i /var/backups/production_repo/data
sudo lsattr -d /var/backups/production_repo/data
```

*Resultado esperado:*
```text
----i---------e------- /var/backups/production_repo/data
```

##### Paso 4: Validar la Protección de Inmutabilidad contra la Eliminación
Intentá eliminar o modificar un archivo dentro del repositorio protegido como `root`.

```bash
sudo rm -rf /var/backups/production_repo/data/*
```

*Resultado esperado:*
```text
rm: cannot remove '/var/backups/production_repo/data/...': Operation not permitted
```

---

#### Preguntas de Verificación (Módulo 4)

1. Si un servidor de producción es comprometido por ransomware con privilegios completos de `root`, ¿cómo evita la aplicación del modo **S3 Object Lock Compliance Mode** en buckets de respaldo fuera del sitio (offsite) que el ransomware destruya los respaldos?
2. ¿Cuál es la diferencia entre una acción `check` de RAID y una acción `repair` de RAID en `mdadm`?

---

### Clave de Soluciones y Explicaciones Técnicas Detalladas

<details>
<summary><strong>Hacé clic aquí para desplegar las respuestas y explicaciones detalladas</strong></summary>

#### Respuestas del Módulo 1

1. **Mecanismo de Vinculación de PCR en TPM 2.0**:
   - **Respuesta**: El chip TPM 2.0 fallará al desellar la clave criptográfica almacenada, lo que provocará la interrupción del proceso automatizado de arranque/descifrado.
   - **Explicación Técnica Detallada**: Cuando un secreto está sellado a los PCRs de TPM 2.0 (por ejemplo, PCR 0 para firmware y PCR 7 para el estado de Secure Boot), el TPM evalúa el resumen (digest) criptográfico actual almacenado en esos registros antes de liberar la clave. Si un atacante graba un firmware modificado o deshabilita Secure Boot, las mediciones de hash extendidas en PCR 0 o PCR 7 cambian. Cuando `systemd-cryptenroll` o `tpm2_unseal` solicitan el desellado de la clave, el TPM compara el estado actual de los PCRs con el resumen de política creado durante el registro de la clave. Dado que los hashes no coinciden, el motor de políticas de hardware del TPM deniega el acceso al secreto, dejando los datos en el disco cifrados.

2. **Objetivos de Política de USBGuard (`block` vs `reject`)**:
   - **Respuesta**: `block` descarta silenciosamente la interfaz USB en la capa del kernel, mientras que `reject` reinicia o desconecta explícitamente el descriptor del dispositivo.
   - **Explicación Técnica Detallada**: `ImplicitPolicyTarget=block` le indica a `usbguard-daemon` que establezca el estado de autorización del dispositivo del kernel en `0` sin enviar comentarios de error explícitos al controlador del dispositivo. El dispositivo físico recibe energía, pero no se adjuntan controladores de interfaz ni endpoints en el espacio del subsistema. `reject` va un paso más allá al instruir al controlador del dispositivo que desautorice explícitamente y realice el desmantelamiento lógico del descriptor de periféricos. En entornos de alta seguridad, se prefiere `block` para evitar que las herramientas de fuzzing de USB o dispositivos maliciosos obtengan telemetría sobre el comportamiento de aplicación de políticas.

---

#### Respuestas del Módulo 2

1. **Derechos de Ejecución bajo Opciones de Montaje `nosuid,nodev`**:
   - **Respuesta**: Sí, los usuarios aún pueden crear archivos ejecutables y ejecutar scripts a menos que se especifique explícitamente `noexec`.
   - **Explicación Técnica Detallada**: 
     - `nosuid` solo deshabilita el manejo por parte del kernel de los bits de modo de archivo `SUID` y `SGID` (previniendo la escalación de privilegios a través de binarios como setuid root).
     - `nodev` previene que el kernel trate a los archivos en el sistema de archivos como dispositivos especiales de bloques o caracteres (por ejemplo, creando un nodo `/dev/sda` malicioso mediante `mknod`).
     - Ninguna de las opciones restringe los permisos de archivo estándar (`chmod +x`) ni las llamadas de ejecución (`execve`). Un usuario puede ejecutar binarios compilados o ejecutar scripts (a través de `bash script.sh` o ejecución directa) a menos que se aplique el flag **`noexec`** a la entrada de montaje en `/etc/fstab`.

2. **LUKS2 Argon2id vs LUKS1 PBKDF2**:
   - **Respuesta**: Argon2id protege contra ataques de fuerza bruta fuera de línea acelerados por hardware (utilizando GPUs, ASICs o FPGAs) al imponer una complejidad computacional intensiva en memoria (memory-hard).
   - **Explicación Técnica Detallada**: El `PBKDF2` estándar está limitado por el cómputo (compute-bound), basándose principalmente en iteraciones de SHA-1/SHA-256. Los atacantes que usan ASICs personalizados o clústeres de GPUs en paralelo pueden ejecutar miles de millones de cálculos PBKDF2 por segundo a bajo costo. `Argon2id` (la función de derivación de claves utilizada en LUKS2) es tanto **memory-hard** como **time-hard**. Requiere una asignación masiva de memoria (por ejemplo, 1 GB de RAM por intento) y utiliza patrones de acceso a la memoria independientes y dependientes de los datos. Esto hace que la paralelización en GPU/ASIC sea prohibitivamente costosa debido a los límites de ancho de banda de la memoria.

---

#### Respuestas del Módulo 3

1. **Merkle Tree Criptográfico de dm-verity**:
   - **Respuesta**: `dm-verity` utiliza una estructura jerárquica de Merkle tree anclada por un único Root Hash inmutable. La modificación de bloques de datos invalida los hashes de los nodos padre hasta llegar al Root Hash.
   - **Explicación Técnica Detallada**: En `dm-verity`, el volumen de almacenamiento se divide en bloques de datos de tamaño fijo (por ejemplo, 4096 bytes). Cada bloque se procesa con un hash. Esos hashes se agrupan en bloques y se vuelven a procesar con hash, formando una jerarquía de árbol. La parte superior del árbol es un único **Root Hash**, que se pasa de forma segura al kernel durante el arranque (a menudo firmado por una clave de kernel de confianza o integrado en un initramfs autenticado por Secure Boot). Si un atacante altera un solo byte en el disco, el hash del bloque cambia, rompiendo el hash del nodo padre, lo que a su vez rompe la capa superior, invalidando la coincidencia del Root Hash. Un atacante no puede simplemente reescribir el dispositivo de hashes porque alterar los hashes superiores cambiaría el Root Hash requerido, el cual está bloqueado en la memoria del kernel.

2. **Prevención del Reemplazo del Kernel en Tiempo de Ejecución a través de `kexec_load_disabled`**:
   - **Respuesta**: Evita que una cuenta `root` comprometida ejecute `kexec` para arrancar un kernel malicioso no verificado directamente en la memoria sin pasar por UEFI Secure Boot.
   - **Explicación Técnica Detallada**: La llamada al sistema `kexec` permite que un kernel en ejecución cargue y salte directamente a otro binario de kernel sin realizar un reinicio de hardware o un reinicio de BIOS/UEFI. Si un actor de amenaza obtiene acceso de `root` en un host activo, podría usar `kexec` para arrancar un kernel personalizado parcheado con rootkits, pasando por alto por completo la validación de firmas de UEFI Secure Boot (que solo se ejecuta durante reinicios físicos fríos/calientes). Configurar `kernel.kexec_load_disabled = 1` inhabilita permanentemente las llamadas al sistema `kexec_load` y `kexec_file_load` hasta el próximo reinicio completo del sistema.

---

#### Respuestas del Módulo 4

1. **Inmunidad del Modo S3 Object Lock Compliance Mode**:
   - **Respuesta**: El modo Compliance Mode impone períodos de retención estrictos e inmutables en la capa de la API de almacenamiento en la nube que no pueden ser eludidos, alterados ni eliminados por ningún usuario, incluidas las cuentas root o los propietarios de las cuentas.
   - **Explicación Técnica Detallada**: En S3 Object Lock, el modo **Governance Mode** permite a los usuarios con permisos IAM especiales (`s3:BypassGovernanceRetention`) alterar las configuraciones de retención o eliminar objetos. Sin embargo, el modo **Compliance Mode** bloquea por completo las reglas del ciclo de vida de los objetos. Ni las credenciales IAM del servidor comprometido, ni el usuario root de la cuenta de AWS, ni el soporte de AWS pueden sobrescribir o eliminar objetos bloqueados en Compliance Mode antes de que expire el período de retención. Incluso si el ransomware roba credenciales administrativas completas en la nube, la API subyacente de S3 rechaza todas las solicitudes de `DeleteObject` y `PutObjectRetention` para objetos bloqueados.

2. **Acciones de Sincronización de `mdadm` (`check` vs `repair`)**:
   - **Respuesta**: `check` realiza una auditoría no destructiva de la paridad del arreglo y registra las discrepancias, mientras que `repair` reescribe activamente los bloques de paridad basándose en la primera unidad espejo operativa.
   - **Explicación Técnica Detallada**: 
     - Escribir `check` en `/sys/block/mdX/md/sync_action` lee todos los bloques a través de las divisiones/espejos de RAID, calcula la paridad esperada e incrementa `/sys/block/mdX/md/mismatch_cnt` cada vez que se detecta una discrepancia (corrupción silenciosa). **No modifica los datos del disco**.
     - Escribir `repair` le indica a `mdadm` que recalcule la paridad al detectar una discrepancia y **sobrescriba** el bloque inconsistente en la unidad de paridad/secundaria con los datos leídos de la unidad primaria. `check` es lo más seguro para el monitoreo de rutina, permitiendo a los SRE investigar la salud del hardware del disco antes de autorizar escrituras de reparación potencialmente destructivas.

</details>