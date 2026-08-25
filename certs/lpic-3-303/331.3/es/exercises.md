# 331.3 — Sistemas de archivos cifrados
## Ejercicios guiados · LPIC-3 303 (examen 303-300, v3.0.0) · Peso del examen 5

> **Seguridad del laboratorio.** Todos los comandos de abajo operan sobre **loop devices respaldados por archivos sparse** dentro de una VM o un contenedor descartable con un kernel real. Nunca apuntes `cryptsetup luksFormat`, `tune2fs -O encrypt` o `dd` a una ruta de dispositivo que no hayas verificado antes con `lsblk` — `luksFormat` sobrescribe la cabecera incondicionalmente y no hay deshacer. Ejecutá todo el documento como `root` (o antepuesto con `sudo`) salvo que un paso indique lo contrario.

**Entorno de referencia usado para las salidas esperadas**

| Componente | Versión |
|---|---|
| Kernel | 6.6 (LTS) |
| `cryptsetup` | 2.6.1 |
| `ecryptfs-utils` | 111 |
| `fscrypt` | 0.3.4 |
| `clevis` / `tang` | 19 / 14 |
| `cryptmount` | 6.2.0 |

Los valores numéricos (UUIDs, salts, cantidades de iteraciones, MiB/s) **van a diferir en tu máquina**. Lo que tiene que coincidir es la *estructura* de la salida — eso es lo que evalúan las preguntas.

**Paquetes**

```bash
# Debian/Ubuntu
apt-get install -y cryptsetup cryptsetup-bin ecryptfs-utils fscrypt \
                   keyutils clevis clevis-luks clevis-systemd tang jose \
                   cryptmount gdisk

# RHEL/Fedora/openSUSE
dnf install -y cryptsetup ecryptfs-utils fscrypt keyutils \
               clevis clevis-luks clevis-dracut tang jose
```

**Fuentes de referencia**

- Objetivos de LPI 303-300 — <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Proyecto `cryptsetup` y especificación del formato en disco LUKS2 — <https://gitlab.com/cryptsetup/cryptsetup> · <https://gitlab.com/cryptsetup/LUKS2-docs>
- FAQ de `cryptsetup` (autoridad sobre modelo de amenaza y recuperación) — <https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions>
- `dm-crypt` del kernel — <https://docs.kernel.org/admin-guide/device-mapper/dm-crypt.html>
- `dm-integrity` del kernel — <https://docs.kernel.org/admin-guide/device-mapper/dm-integrity.html>
- `fscrypt` del kernel — <https://docs.kernel.org/filesystems/fscrypt.html>
- `eCryptfs` del kernel — <https://docs.kernel.org/filesystems/ecryptfs.html>
- `crypttab(5)` de `systemd` — <https://www.freedesktop.org/software/systemd/man/latest/crypttab.html>
- `systemd-cryptsetup-generator(8)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptsetup-generator.html>
- Clevis — <https://github.com/latchset/clevis> · Tang — <https://github.com/latchset/tang>
- `cryptmount` — <https://cryptmount.sourceforge.net/>

---

## Ejercicio 0 — Construir los dispositivos de bloque del laboratorio

### Pasos

1. Creá un directorio de trabajo y cuatro archivos sparse de respaldo.

    ```bash
    mkdir -p /root/cryptolab && cd /root/cryptolab
    for n in 1 2 3 4; do
        truncate -s 256M disk${n}.img
    done
    ls -lh
    du -sh --apparent-size disk1.img
    du -sh disk1.img
    ```

2. Confirmá que los archivos son sparse — tamaño aparente 256 MiB, tamaño asignado 0.

    ```
    256M	disk1.img      # --apparent-size
    0	disk1.img          # actually allocated
    ```

3. Asociá cada archivo a un loop device y listá el mapeo.

    ```bash
    for n in 1 2 3 4; do
        losetup --find --show /root/cryptolab/disk${n}.img
    done
    losetup -a
    ```

    ```
    /dev/loop0
    /dev/loop1
    /dev/loop2
    /dev/loop3
    /dev/loop0: [2049]:1179651 (/root/cryptolab/disk1.img)
    /dev/loop1: [2049]:1179652 (/root/cryptolab/disk2.img)
    /dev/loop2: [2049]:1179653 (/root/cryptolab/disk3.img)
    /dev/loop3: [2049]:1179654 (/root/cryptolab/disk4.img)
    ```

4. Verificá el stack criptográfico que el kernel realmente te ofrece.

    ```bash
    modprobe dm_crypt dm_integrity ecryptfs
    dmsetup targets
    grep -E 'name|driver|module' /proc/crypto | grep -A2 -i 'xts' | head -20
    ```

    ```
    integrity        v1.10.0
    crypt            v1.24.0
    striped          v1.6.0
    linear           v1.4.0
    ```

5. Tomá una línea base del rendimiento de KDF y cifrado de la máquina. Este es el número que decide tu ajuste de `--pbkdf-*` más adelante.

    ```bash
    cryptsetup benchmark
    ```

    ```
    # Tests are approximate using memory only (no storage IO).
    PBKDF2-sha1      1975431 iterations per second for 256-bit key
    PBKDF2-sha256    2612088 iterations per second for 256-bit key
    PBKDF2-sha512    1010774 iterations per second for 256-bit key
    PBKDF2-ripemd160  920330 iterations per second for 256-bit key
    PBKDF2-whirlpool  481902 iterations per second for 256-bit key
    argon2i       4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
    argon2id      4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
    #     Algorithm |       Key |      Encryption |      Decryption
            aes-cbc        128b      1012.4 MiB/s      3210.5 MiB/s
        serpent-cbc        128b        88.6 MiB/s       630.2 MiB/s
        twofish-cbc        128b       190.3 MiB/s       360.1 MiB/s
            aes-cbc        256b       760.2 MiB/s      2540.8 MiB/s
            aes-xts        256b      2810.3 MiB/s      2802.1 MiB/s
            aes-xts        512b      2350.6 MiB/s      2341.0 MiB/s
        serpent-xts        512b       582.1 MiB/s       571.3 MiB/s
        twofish-xts        512b       351.2 MiB/s       353.0 MiB/s
    ```

### Comprobá tu comprensión

- **P0.1** — ¿Por qué `cryptsetup benchmark` reporta el *descifrado* AES-CBC varias veces más rápido que el cifrado, mientras que AES-XTS es simétrico?
- **P0.2** — En la tabla del benchmark, `aes-xts 512b` significa AES-256, no AES-512. Explicá el factor de dos.
- **P0.3** — Un archivo de respaldo sparse plantea un punto de seguridad sutil en este laboratorio que no aplicaría a un disco real. ¿Cuál es?
- **P0.4** — `argon2id` reporta `1048576 memory`. ¿Qué unidad es esa, y qué clase de ataque apunta ese parámetro que las iteraciones de PBKDF2 no cubren?

---

## Ejercicio 1 — LUKS1 vs LUKS2: formatear los contenedores y leer las cabeceras

### Pasos

1. Formateá `/dev/loop0` como **LUKS1**, forzando cada parámetro explícitamente para que nada dependa del default de la distro.

    ```bash
    cryptsetup luksFormat \
        --type luks1 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --iter-time 2000 \
        --use-urandom \
        --batch-mode \
        /dev/loop0 <<< 'LabPass-LUKS1'
    ```

2. Formateá `/dev/loop1` como **LUKS2** con los defaults modernos más un sector de cifrado de 4096 bytes.

    ```bash
    cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --pbkdf argon2id \
        --sector-size 4096 \
        --label VAULT \
        --use-urandom \
        --batch-mode \
        /dev/loop1 <<< 'LabPass-LUKS2'
    ```

3. Volcá la cabecera LUKS1.

    ```bash
    cryptsetup luksDump /dev/loop0
    ```

    ```
    LUKS header information for /dev/loop0

    Version:       	1
    Cipher name:   	aes
    Cipher mode:   	xts-plain64
    Hash spec:     	sha256
    Payload offset:	4096
    MK bits:       	512
    MK digest:     	c1 9d 4f 0a 22 6e 3b 77 1a 84 d0 5c 9e 31 aa 62 08 b4 7f d3
    MK salt:       	3f 82 1c 55 a9 0e 6b 24 d7 90 4e 11 c8 3a 5f 6d
                   	e2 71 08 bb 94 3c 5a 17 f0 62 8d 49 21 ce 7b 30
    MK iterations: 	187500
    UUID:          	4b0f8a12-7c3e-4d55-9f21-6ab08e3c17d9

    Key Slot 0: ENABLED
    	Iterations:         	2998421
    	Salt:               	7a 41 d9 3e 08 c2 66 5b 1f 90 ad 74 32 e8 5c 0b
    	                      	95 d3 27 6a 4e 8f 11 c0 3b 72 de 59 a4 06 8c 1d
    	Key material offset:	8
    	AF stripes:            	4000
    Key Slot 1: DISABLED
    Key Slot 2: DISABLED
    Key Slot 3: DISABLED
    Key Slot 4: DISABLED
    Key Slot 5: DISABLED
    Key Slot 6: DISABLED
    Key Slot 7: DISABLED
    ```

4. Volcá la cabecera LUKS2 y después los metadatos JSON crudos.

    ```bash
    cryptsetup luksDump /dev/loop1
    ```

    ```
    LUKS header information
    Version:       	2
    Epoch:         	3
    Metadata area: 	16384 [bytes]
    Keyslots area: 	16744448 [bytes]
    UUID:          	9d2c71fa-05be-4e83-b6a7-c4180e29f5b1
    Label:         	VAULT
    Subsystem:     	(no subsystem)
    Flags:       	(no flags)

    Data segments:
      0: crypt
    	offset: 16777216 [bytes]
    	length: (whole device)
    	cipher: aes-xts-plain64
    	sector: 4096 [bytes]

    Keyslots:
      0: luks2
    	Key:        512 bits
    	Priority:   normal
    	Cipher:     aes-xts-plain64
    	Cipher key: 512 bits
    	PBKDF:      argon2id
    	Time cost:  7
    	Memory:     1048576
    	Threads:    4
    	Salt:       6e 03 b1 7d 4a 22 98 ef 55 c7 10 3b 8d 64 f9 02
    	            a1 5e 37 cb 80 12 6f d4 29 b3 7a 0c e6 41 95 8b
    	AF stripes: 4000
    	AF hash:    sha256
    	Area offset:32768 [bytes]
    	Area length:258048 [bytes]
    	Digest ID:  0
    Tokens:
    Digests:
      0: pbkdf2
    	Hash:       sha256
    	Iterations: 129774
    	Salt:       b7 2a 6c 91 03 de 48 f5 1c 87 30 a9 62 4b ff 15
    	            0d 93 71 e8 5a 24 c6 3f 8e b0 47 92 d1 6a 35 cc
    	Digest:     4f 81 a3 20 7b 9c 5e 16 d8 03 62 af 7d 41 e9 58
    	            30 cb 74 2a
    ```

    ```bash
    cryptsetup luksDump --dump-json-metadata /dev/loop1 | jq '.keyslots, .segments, .config'
    ```

    ```json
    {
      "0": {
        "type": "luks2",
        "key_size": 64,
        "af": { "type": "luks1", "stripes": 4000, "hash": "sha256" },
        "area": { "type": "raw", "offset": "32768", "size": "258048",
                  "encryption": "aes-xts-plain64", "key_size": 64 },
        "kdf": { "type": "argon2id", "time": 7, "memory": 1048576, "cpus": 4,
                 "salt": "bgOxfUoimO9Vxx..." }
      }
    }
    {
      "0": { "type": "crypt", "offset": "16777216", "size": "dynamic",
             "iv_tweak": "0", "encryption": "aes-xts-plain64", "sector_size": 4096 }
    }
    { "json_size": "12288", "keyslots_size": "16744448" }
    ```

5. Demostrá dónde arrancan realmente los datos en texto plano, en bytes, en cada contenedor.

    ```bash
    echo "LUKS1 payload offset: $(( 4096 * 512 )) bytes"
    cryptsetup luksDump /dev/loop1 | awk '/offset:/ {print "LUKS2 data offset: " $2 " bytes"; exit}'
    blkid /dev/loop0 /dev/loop1
    ```

    ```
    LUKS1 payload offset: 2097152 bytes
    LUKS2 data offset: 16777216 bytes
    /dev/loop0: UUID="4b0f8a12-7c3e-4d55-9f21-6ab08e3c17d9" TYPE="crypto_LUKS" VERSION="1"
    /dev/loop1: UUID="9d2c71fa-05be-4e83-b6a7-c4180e29f5b1" LABEL="VAULT" TYPE="crypto_LUKS" VERSION="2"
    ```

### Comprobá tu comprensión

- **P1.1** — LUKS1 reserva 2 MiB antes del payload; LUKS2 reserva 16 MiB. ¿A dónde van los 14 MiB extra, y qué característica de LUKS2 los hace necesarios?
- **P1.2** — El volcado de LUKS1 muestra tanto `MK iterations: 187500` como `Key Slot 0 → Iterations: 2998421`. ¿Por qué estos dos números difieren en un orden de magnitud, y qué protege cada uno?
- **P1.3** — `AF stripes: 4000` aparece en ambas cabeceras. Explicá el anti-forensic splitting y qué ataque concreto derrota.
- **P1.4** — El contenedor LUKS2 se creó con `--sector-size 4096`. Nombrá un beneficio de rendimiento y una restricción dura que esto impone sobre el dispositivo subyacente.
- **P1.5** — `blkid` imprime `TYPE="crypto_LUKS"` para ambos dispositivos. ¿Por qué `blkid` puede leer esto mientras el sistema de archivos interno sigue siendo ilegible?

---

## Ejercicio 2 — Key slots, ciclo de vida de la passphrase y archivos de clave

### Pasos

1. Abrí el contenedor LUKS2, ponele un sistema de archivos, escribí un archivo marcador e inspeccioná el mapeo activo.

    ```bash
    echo -n 'LabPass-LUKS2' | cryptsetup open /dev/loop1 vault -
    mkfs.ext4 -q -L vaultfs /dev/mapper/vault
    mkdir -p /mnt/vault && mount /dev/mapper/vault /mnt/vault
    echo "topic 331.3 marker $(date -u +%FT%TZ)" > /mnt/vault/marker.txt
    cryptsetup status vault
    ```

    ```
    /dev/mapper/vault is active and is in use.
      type:    LUKS2
      cipher:  aes-xts-plain64
      keysize: 512 bits
      key location: keyring
      device:  /dev/loop1
      loop:    /root/cryptolab/disk2.img
      sector size:  4096
      offset:  32768 sectors
      size:    491520 sectors
      mode:    read/write
    ```

2. Mirá la tabla del device-mapper. Notá que la clave maestra **no** se imprime.

    ```bash
    dmsetup table vault
    dmsetup table --showkeys vault
    ```

    ```
    0 491520 crypt aes-xts-plain64 :64:logon:cryptsetup:9d2c71fa-05be-4e83-b6a7-c4180e29f5b1-d0 0 7:1 32768 1 sector_size:4096
    0 491520 crypt aes-xts-plain64 :64:logon:cryptsetup:9d2c71fa-05be-4e83-b6a7-c4180e29f5b1-d0 0 7:1 32768 1 sector_size:4096
    ```

3. Generá un archivo de clave de alta entropía y agregalo a un slot **específico**.

    ```bash
    mkdir -p /etc/luks-keys && chmod 700 /etc/luks-keys
    dd if=/dev/urandom of=/etc/luks-keys/vault.key bs=512 count=8 status=none
    chmod 400 /etc/luks-keys/vault.key

    echo -n 'LabPass-LUKS2' | cryptsetup luksAddKey \
        --key-file=- \
        --key-slot 3 \
        /dev/loop1 /etc/luks-keys/vault.key
    ```

4. Agregá una segunda passphrase humana al slot 1, después listá el uso de slots de forma compacta.

    ```bash
    printf 'LabPass-LUKS2\nBackupPass-2026\nBackupPass-2026\n' | \
        cryptsetup luksAddKey --key-slot 1 /dev/loop1

    cryptsetup luksDump /dev/loop1 | sed -n '/^Keyslots:/,/^Tokens:/p' | grep -E '^\s+[0-9]+:'
    ```

    ```
      0: luks2
      1: luks2
      3: luks2
    ```

5. Probá cada credencial **sin** activar el dispositivo.

    ```bash
    echo -n 'LabPass-LUKS2'  | cryptsetup open --test-passphrase --key-file=- /dev/loop1 && echo "slot ok: primary"
    echo -n 'BackupPass-2026'| cryptsetup open --test-passphrase --key-file=- /dev/loop1 && echo "slot ok: backup"
    cryptsetup open --test-passphrase --key-file /etc/luks-keys/vault.key /dev/loop1 && echo "slot ok: keyfile"
    echo -n 'wrong' | cryptsetup open --test-passphrase --key-file=- /dev/loop1 ; echo "exit=$?"
    ```

    ```
    slot ok: primary
    slot ok: backup
    slot ok: keyfile
    No key available with this passphrase.
    exit=2
    ```

6. Determiná *cuál* slot abre una passphrase dada.

    ```bash
    echo -n 'BackupPass-2026' | cryptsetup open --test-passphrase --key-file=- --verbose /dev/loop1
    ```

    ```
    Key slot 1 unlocked.
    Command successful.
    ```

7. Rotá: cambiá la passphrase primaria en el lugar, después revocá el slot de la passphrase de respaldo.

    ```bash
    printf 'LabPass-LUKS2\nRotated-2026-Q3\nRotated-2026-Q3\n' | \
        cryptsetup luksChangeKey --key-slot 0 /dev/loop1

    echo -n 'Rotated-2026-Q3' | cryptsetup luksKillSlot --key-file=- /dev/loop1 1
    cryptsetup luksDump /dev/loop1 | grep -cE '^\s+[0-9]+: luks2'
    ```

    ```
    2
    ```

8. Configurá las prioridades de slot para que el archivo de clave se pruebe primero en el arranque y la passphrase de emergencia nunca lo sea, salvo que se pida.

    ```bash
    cryptsetup config --key-slot 3 --priority prefer /dev/loop1
    cryptsetup config --key-slot 0 --priority normal /dev/loop1
    cryptsetup luksDump /dev/loop1 | grep -A2 -E '^\s+[03]: luks2' | grep -E 'Priority|luks2'
    ```

    ```
      0: luks2
    	Priority:   normal
      3: luks2
    	Priority:   prefer
    ```

### Comprobá tu comprensión

- **P2.1** — `dmsetup table --showkeys` imprimió `:64:logon:cryptsetup:<uuid>-d0` en lugar de material de clave en hexadecimal, aun cuando pediste las claves. ¿Qué cambió en cryptsetup 2.x para causar esto, y cuál es la ganancia de seguridad?
- **P2.2** — Agregaste un archivo de clave en el slot 3 y eliminaste el slot 1. ¿Eliminar un slot recifra algún dato? Explicá qué pasa realmente en disco, en términos de la clave maestra.
- **P2.3** — `cryptsetup luksChangeKey --key-slot 0` versus `luksAddKey` seguido de `luksKillSlot 0`: nombrá la diferencia operativa que importa durante una rotación desatendida, y cuál deberías preferir.
- **P2.4** — El archivo de clave son 4096 bytes de `/dev/urandom`. LUKS lee el archivo completo por defecto. ¿Qué sale mal si un administrador después "limpia" ese archivo agregándole un salto de línea, y qué opción de `crypttab`/CLI es la defensa estándar?
- **P2.5** — Se estableció la prioridad de slot `prefer` en el slot del archivo de clave. ¿Qué cambia realmente `prefer` al momento de desbloquear — es un control de seguridad o un control de latencia?

---

## Ejercicio 3 — Backup de cabecera, destrucción de cabecera, cabeceras separadas

### Pasos

1. Respaldá la cabecera LUKS2 antes de romperla.

    ```bash
    cryptsetup luksHeaderBackup /dev/loop1 \
        --header-backup-file /root/cryptolab/vault-header-$(date -u +%Y%m%d).img
    ls -l /root/cryptolab/vault-header-*.img
    chmod 400 /root/cryptolab/vault-header-*.img
    ```

    ```
    -rw------- 1 root root 16777216 Aug 20 11:04 /root/cryptolab/vault-header-20260820.img
    ```

2. Desmontá, cerrá y destruí los primeros 4 MiB del contenedor — simulando un `dd` extraviado o un particionador escribiendo una GPT nueva.

    ```bash
    umount /mnt/vault
    cryptsetup close vault
    dd if=/dev/urandom of=/dev/loop1 bs=1M count=4 conv=notrunc status=none
    cryptsetup luksDump /dev/loop1 ; echo "exit=$?"
    ```

    ```
    Device /dev/loop1 is not a valid LUKS device.
    exit=1
    ```

3. Restaurá la cabecera y confirmá que los datos sobrevivieron intactos.

    ```bash
    cryptsetup luksHeaderRestore /dev/loop1 \
        --header-backup-file /root/cryptolab/vault-header-20260820.img --batch-mode
    echo -n 'Rotated-2026-Q3' | cryptsetup open --key-file=- /dev/loop1 vault
    mount /dev/mapper/vault /mnt/vault
    cat /mnt/vault/marker.txt
    ```

    ```
    topic 331.3 marker 2026-08-20T11:02:44Z
    ```

4. Construí un contenedor con **cabecera separada** (detached header) en `/dev/loop2`: la cabecera vive en un archivo aparte, el dispositivo de bloque no contiene nada más que texto cifrado.

    ```bash
    truncate -s 16M /root/cryptolab/hidden.hdr
    cryptsetup luksFormat --type luks2 \
        --header /root/cryptolab/hidden.hdr \
        --batch-mode /dev/loop2 <<< 'DetachedPass'

    blkid /dev/loop2 ; echo "blkid exit=$?"
    file /root/cryptolab/hidden.hdr
    ```

    ```
    blkid exit=2
    /root/cryptolab/hidden.hdr: LUKS encrypted file, ver 2 [aes, xts-plain64, sha256] UUID: 1c74e0b9-...
    ```

5. Abrilo, observá el offset de datos y cerralo.

    ```bash
    echo -n 'DetachedPass' | cryptsetup open --header /root/cryptolab/hidden.hdr \
        --key-file=- /dev/loop2 hidden
    cryptsetup status hidden | grep -E 'offset|device|type'
    cryptsetup close hidden
    ```

    ```
      type:    LUKS2
      device:  /dev/loop2
      offset:  0 sectors
    ```

6. Demostrá la operación irreversible: borrá todos los key slots en el (ahora sin uso) `/dev/loop3` después de formatearlo.

    ```bash
    cryptsetup luksFormat --type luks2 --batch-mode /dev/loop3 <<< 'Doomed'
    cryptsetup luksErase --batch-mode /dev/loop3
    cryptsetup luksDump /dev/loop3 | grep -A1 '^Keyslots:'
    echo -n 'Doomed' | cryptsetup open --test-passphrase --key-file=- /dev/loop3; echo "exit=$?"
    ```

    ```
    Keyslots:
    Digests:
    No usable keyslot is available.
    exit=1
    ```

### Comprobá tu comprensión

- **P3.1** — Después de `luksHeaderRestore`, la passphrase `BackupPass-2026` que eliminaste en el Ejercicio 2 volvería a funcionar si el backup es anterior a la eliminación. Enunciá la regla operativa que esto implica para los backups de cabecera.
- **P3.2** — Con una cabecera separada, `cryptsetup status` reporta `offset: 0 sectors`. ¿Por qué, y qué significa eso para la capacidad utilizable de `/dev/loop2` comparada con `/dev/loop1`?
- **P3.3** — A menudo se describe a las cabeceras separadas como algo que da "negación plausible". Dá una razón por la cual esa afirmación es más débil de lo que suena frente a un examinador forense competente.
- **P3.4** — `luksErase` terminó en milisegundos sobre un dispositivo de 256 MiB. Explicá por qué los *datos* son sin embargo irrecuperables, y nombrá la propiedad que esto explota (la misma que hace posible el "borrado instantáneo" de LUKS en un arreglo de 20 TB).
- **P3.5** — ¿Por qué un archivo de backup de cabecera es más sensible que el disco cifrado mismo, y qué tenés que hacer con un backup de cabecera cuando das de baja una passphrase?

---

## Ejercicio 4 — `/etc/crypttab`, `systemd-cryptsetup` y desbloqueo en el arranque

### Pasos

1. Recolectá los UUIDs que vas a referenciar. **Nunca** pongas `/dev/loopN` o `/dev/sdX` en `crypttab` en un sistema real.

    ```bash
    VAULT_UUID=$(cryptsetup luksUUID /dev/loop1)
    echo "$VAULT_UUID"
    ```

    ```
    9d2c71fa-05be-4e83-b6a7-c4180e29f5b1
    ```

2. Escribí un `crypttab` que cubra los cuatro casos canónicos: prompt de passphrase, archivo de clave, cabecera separada y swap con clave aleatoria.

    ```bash
    cat > /etc/crypttab <<EOF
    # <name>   <source device>                  <key file>                  <options>
    vault      UUID=${VAULT_UUID}               /etc/luks-keys/vault.key    luks,discard,nofail,x-systemd.device-timeout=10s
    archive    UUID=00000000-0000-0000-0000-000000000001  none              luks,tries=3,timeout=30s,noauto
    hidden     /dev/loop2                       none                        luks,header=/root/cryptolab/hidden.hdr,noauto
    cryptswap  /dev/vg0/swap                    /dev/urandom                swap,cipher=aes-xts-plain64,size=512,sector-size=4096,hash=sha256
    EOF
    ```

3. Pedile a systemd que traduzca `crypttab` a units e inspeccioná la unit generada.

    ```bash
    systemctl daemon-reload
    ls /run/systemd/generator/*.service | grep cryptsetup
    systemctl cat systemd-cryptsetup@vault.service | head -30
    ```

    ```
    /run/systemd/generator/systemd-cryptsetup@vault.service
    /run/systemd/generator/systemd-cryptsetup@archive.service
    /run/systemd/generator/systemd-cryptsetup@hidden.service
    /run/systemd/generator/systemd-cryptsetup@cryptswap.service

    # /run/systemd/generator/systemd-cryptsetup@vault.service
    [Unit]
    Description=Cryptography Setup for vault
    Documentation=man:crypttab(5) man:systemd-cryptsetup-generator(8) man:systemd-cryptsetup@.service(8)
    SourcePath=/etc/crypttab
    DefaultDependencies=no
    IgnoreOnIsolate=true
    After=cryptsetup-pre.target systemd-udevd-kernel.socket
    Before=blockdev@dev-mapper-vault.target
    Wants=blockdev@dev-mapper-vault.target
    BindsTo=dev-disk-by\x2duuid-9d2c71fa...device
    Before=umount.target cryptsetup.target
    Conflicts=umount.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    TimeoutSec=0
    ExecStart=/usr/lib/systemd/systemd-cryptsetup attach 'vault' '/dev/disk/by-uuid/9d2c71fa...' '/etc/luks-keys/vault.key' 'luks,discard,nofail,x-systemd.device-timeout=10s'
    ExecStop=/usr/lib/systemd/systemd-cryptsetup detach 'vault'
    ```

4. Ejercitá el camino de la unit manualmente.

    ```bash
    umount /mnt/vault 2>/dev/null
    cryptsetup close vault 2>/dev/null
    systemctl start systemd-cryptsetup@vault.service
    systemctl is-active systemd-cryptsetup@vault.service
    lsblk -o NAME,FSTYPE,MOUNTPOINT /dev/loop1
    ```

    ```
    active
    NAME    FSTYPE      MOUNTPOINT
    loop1   crypto_LUKS
    └─vault ext4
    ```

5. Agregá la línea correspondiente en `fstab` para que el sistema de archivos siga al mapeo.

    ```bash
    printf '/dev/mapper/vault  /mnt/vault  ext4  defaults,nofail,x-systemd.requires=systemd-cryptsetup@vault.service  0 2\n' >> /etc/fstab
    systemctl daemon-reload
    mount /mnt/vault
    findmnt /mnt/vault
    ```

    ```
    TARGET     SOURCE            FSTYPE OPTIONS
    /mnt/vault /dev/mapper/vault ext4   rw,relatime
    ```

6. Activá el pass-through de TRIM de forma persistente en la capa LUKS en lugar de vía `crypttab`.

    ```bash
    cryptsetup close vault && umount /mnt/vault 2>/dev/null
    cryptsetup --allow-discards --persistent open --key-file /etc/luks-keys/vault.key /dev/loop1 vault
    cryptsetup luksDump /dev/loop1 | grep -i flags
    ```

    ```
    Flags:       	allow-discards
    ```

### Comprobá tu comprensión

- **P4.1** — La línea `cryptswap` usa `/dev/urandom` como archivo de clave y omite `luks`. ¿Qué modo es ese, y por qué una clave aleatoria nueva por arranque es *correcta* para swap pero catastrófica para `/home`?
- **P4.2** — La entrada `archive` usa `none` como archivo de clave con `tries=3,timeout=30s`. ¿Dónde aparece el prompt durante el arranque, y qué componente de systemd recolecta la respuesta?
- **P4.3** — ¿Qué se rompe si escribís `/dev/mapper/vault /mnt/vault ext4 defaults 0 2` en `fstab` sin `nofail` ni `x-systemd.requires=`, y el archivo de clave está en un sistema de archivos que se monta más tarde?
- **P4.4** — `--persistent` escribió `allow-discards` en la cabecera LUKS2. Enunciá el compromiso de fuga de información al habilitar discards en un SSD cifrado, y por qué el flag no puede almacenarse de esta forma en LUKS1.
- **P4.5** — Para un volumen LUKS desbloqueado por red (Ejercicio 7), ¿qué única opción de `crypttab` es obligatoria, y qué pasaría sin ella?

---

## Ejercicio 5 — dm-crypt plain: sin cabecera, sin red de seguridad

### Pasos

1. Desasociá el loop device que borraste y reusalo para modo plain.

    ```bash
    cryptsetup close hidden 2>/dev/null
    wipefs -a /dev/loop3 >/dev/null 2>&1
    ```

2. Abrí `/dev/loop3` en modo **plain** con cada parámetro fijado. No hay paso de formateo — el modo plain no tiene nada que escribir.

    ```bash
    echo -n 'PlainSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --offset 0 \
        --skip 0 \
        --key-file=- \
        /dev/loop3 plainmap

    cryptsetup status plainmap
    ```

    ```
    /dev/mapper/plainmap is active.
      type:    PLAIN
      cipher:  aes-xts-plain64
      keysize: 512 bits
      key location: dm-crypt
      device:  /dev/loop3
      sector size:  512
      offset:  0 sectors
      size:    524288 sectors
      mode:    read/write
    ```

3. Creá un sistema de archivos, escribí un marcador, cerrá.

    ```bash
    mkfs.ext4 -q /dev/mapper/plainmap
    mkdir -p /mnt/plain && mount /dev/mapper/plainmap /mnt/plain
    echo 'plain-mode marker' > /mnt/plain/marker.txt
    umount /mnt/plain && cryptsetup close plainmap
    ```

4. Reabrí con la passphrase **incorrecta**. Observá que `cryptsetup` tiene éxito igual.

    ```bash
    echo -n 'WrongSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --key-file=- /dev/loop3 plainmap
    echo "cryptsetup exit=$?"
    mount /dev/mapper/plainmap /mnt/plain ; echo "mount exit=$?"
    ```

    ```
    cryptsetup exit=0
    mount: /mnt/plain: wrong fs type, bad option, bad superblock on /dev/mapper/plainmap, missing codepage or helper program, or other error.
    mount exit=32
    ```

5. Reabrí con la passphrase *correcta* pero un **hash distinto**, para mostrar que el hash es parte de la derivación de la clave.

    ```bash
    cryptsetup close plainmap
    echo -n 'PlainSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
        --key-file=- /dev/loop3 plainmap
    mount /dev/mapper/plainmap /mnt/plain ; echo "mount exit=$?"
    cryptsetup close plainmap
    ```

    ```
    mount: /mnt/plain: wrong fs type, bad option, bad superblock ...
    mount exit=32
    ```

6. Restaurá la combinación correcta y confirmá.

    ```bash
    echo -n 'PlainSecret' | cryptsetup open --type plain \
        --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
        --key-file=- /dev/loop3 plainmap
    mount /dev/mapper/plainmap /mnt/plain && cat /mnt/plain/marker.txt
    umount /mnt/plain && cryptsetup close plainmap
    ```

    ```
    plain-mode marker
    ```

7. Confirmá que el dispositivo es indistinguible de datos aleatorios.

    ```bash
    blkid /dev/loop3; echo "blkid exit=$?"
    hexdump -C -n 64 /dev/loop3
    ```

    ```
    blkid exit=2
    00000000  d1 5b 8a 3f 07 c2 96 44  ae 21 f0 6d 39 bb 5c 82  |.[.?...D.!.m9.\.|
    00000010  1e 74 c9 05 60 d3 47 aa  8f 12 3b e6 70 95 2c 4d  |.t..`.G...;.p.,M|
    ...
    ```

### Comprobá tu comprensión

- **P5.1** — En el paso 4, `cryptsetup` devolvió 0 con una passphrase incorrecta. Explicá con precisión por qué el modo plain no puede detectar esto, y qué estructura de LUKS provee la verificación que acá falta.
- **P5.2** — Los pasos 4 y 5 fallan ambos en `mount`. ¿Por qué *montar silenciosamente* un volumen plain con la clave incorrecta es el desenlace más peligroso, y qué pasaría si el volumen contuviera datos crudos sin superbloque (por ejemplo, un dispositivo raw de base de datos)?
- **P5.3** — El ejercicio fijó `--cipher`, `--key-size`, `--hash`, `--offset` y `--skip`. Históricamente, cryptsetup cambió sus defaults de modo plain (cifrado `aes-cbc-essiv:sha256` → `aes-xts-plain64`, hash `ripemd160` → `sha256`). ¿Qué regla operativa se deriva para quien use modo plain?
- **P5.4** — Nombrá dos usos legítimos en producción de dm-crypt plain donde la ausencia de cabecera es una ventaja y no un defecto.
- **P5.5** — El modo plain deriva la clave hasheando la passphrase una sola vez. Compará eso con el keyslot Argon2id de LUKS2 frente a un atacante de fuerza bruta offline.

---

## Ejercicio 6 — Características de LUKS2: cifrado autenticado, ajuste de PBKDF, recifrado, conversión

### Pasos

1. Liberá `/dev/loop3` y creá un volumen LUKS2 **autenticado** con dm-integrity por debajo. Esto limpia los tags de integridad de todo el dispositivo, así que tarda un momento.

    ```bash
    cryptsetup close plainmap 2>/dev/null
    cryptsetup luksFormat --type luks2 \
        --cipher aes-gcm-random \
        --integrity aead \
        --key-size 256 \
        --sector-size 4096 \
        --batch-mode /dev/loop3 <<< 'AeadPass'
    ```

    ```
    Wiping device to initialize integrity checksum.
    You can interrupt this by pressing CTRL+c (rest of not wiped device will contain invalid checksum).
    Finished, time 00m07s,  240 MiB written, speed  32.8 MiB/s
    ```

2. Abrilo y observá los dispositivos device-mapper **apilados**.

    ```bash
    echo -n 'AeadPass' | cryptsetup open --key-file=- /dev/loop3 sealed
    dmsetup ls --tree
    cryptsetup status sealed
    ```

    ```
    sealed (253:2)
     └─sealed_dif (253:1)
        └─ (7:3)

    /dev/mapper/sealed is active.
      type:    LUKS2
      cipher:  aes-gcm-random
      keysize: 256 bits
      integrity: aead
      integrity keysize: 0 bits
      device:  /dev/mapper/sealed_dif
      sector size:  4096
      offset:  0 sectors
      size:    465920 sectors
      mode:    read/write
    ```

3. Escribí datos, después corrompé un sector de texto cifrado directamente en el dispositivo de respaldo e intentá leerlo de vuelta.

    ```bash
    mkfs.ext4 -q /dev/mapper/sealed
    mkdir -p /mnt/sealed && mount /dev/mapper/sealed /mnt/sealed
    dd if=/dev/urandom of=/mnt/sealed/payload.bin bs=1M count=8 status=none
    sha256sum /mnt/sealed/payload.bin | tee /root/cryptolab/payload.sha
    sync; umount /mnt/sealed

    # flip bytes deep inside the data area
    dd if=/dev/urandom of=/dev/loop3 bs=4096 count=1 seek=20000 conv=notrunc status=none

    mount /dev/mapper/sealed /mnt/sealed
    sha256sum -c /root/cryptolab/payload.sha ; echo "exit=$?"
    dmesg | tail -4
    ```

    ```
    /mnt/sealed/payload.bin: FAILED open or read
    sha256sum: WARNING: 1 computed checksum did NOT match
    exit=1
    [  912.443100] device-mapper: crypt: sealed: INTEGRITY AEAD ERROR, sector 81920
    [  912.443118] Buffer I/O error on dev dm-2, logical block 10240, async page read
    ```

    > Comparación: repetí la misma corrupción en `/dev/mapper/vault` (AES-XTS simple, sin integridad) y la lectura **tiene éxito**, devolviendo 4096 bytes de basura sin ningún error en ningún lado.

4. Ajustá el KDF para un objetivo con memoria limitada (un router, un appliance embebido) — Argon2 con 1 GiB no es viable ahí.

    ```bash
    umount /mnt/sealed; cryptsetup close sealed
    printf 'AeadPass\nLowMem\nLowMem\n' | cryptsetup luksAddKey \
        --pbkdf argon2id --pbkdf-memory 65536 --pbkdf-parallel 1 --pbkdf-force-iterations 8 \
        --key-slot 5 /dev/loop3
    cryptsetup luksDump /dev/loop3 | grep -A6 '^  5: luks2'
    ```

    ```
      5: luks2
    	Key:        256 bits
    	Priority:   normal
    	Cipher:     aes-gcm-random
    	Cipher key: 256 bits
    	PBKDF:      argon2id
    	Time cost:  8
    	Memory:     65536
    ```

5. Rotá la **clave maestra** del volumen `vault` con recifrado en línea — los datos permanecen montados y legibles todo el tiempo.

    ```bash
    mount /dev/mapper/vault /mnt/vault 2>/dev/null
    cryptsetup luksDump /dev/loop1 | grep -A3 '^Digests:' | grep Digest:
    cryptsetup reencrypt --active-name vault --key-file /etc/luks-keys/vault.key /dev/loop1
    cryptsetup luksDump /dev/loop1 | grep -A3 '^Digests:' | grep Digest:
    cat /mnt/vault/marker.txt
    ```

    ```
    	Digest:     4f 81 a3 20 7b 9c 5e 16 d8 03 62 af 7d 41 e9 58 30 cb 74 2a
    Progress:  100,0%, ETA 00:00, 240 MiB written, speed  61,3 MiB/s
    Finished, time 00m03s,  240 MiB written, speed  61,3 MiB/s
    	Digest:     9c 27 e0 4b 15 8a 63 d1 fe 40 39 b7 2c 8e 05 7a 61 d4 93 08
    topic 331.3 marker 2026-08-20T11:02:44Z
    ```

6. Intentá convertir el vault LUKS2 a LUKS1 y leé el fallo con atención.

    ```bash
    cryptsetup convert --type luks1 /dev/loop1 ; echo "exit=$?"
    ```

    ```
    Cannot convert to LUKS1 format - keyslot 0 is not LUKS1 compatible.
    exit=1
    ```

7. Construí un volumen LUKS2 que *sí* sea convertible, y convertilo en ambos sentidos.

    ```bash
    cryptsetup close sealed 2>/dev/null
    truncate -s 64M /root/cryptolab/conv.img
    CONV=$(losetup --find --show /root/cryptolab/conv.img)
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --sector-size 512 \
        --luks2-metadata-size 16k --luks2-keyslots-size 2048k \
        --batch-mode "$CONV" <<< 'ConvPass'
    cryptsetup convert --type luks1 "$CONV" --batch-mode && cryptsetup luksDump "$CONV" | head -3
    cryptsetup convert --type luks2 "$CONV" --batch-mode && cryptsetup luksDump "$CONV" | head -3
    ```

    ```
    LUKS header information for /dev/loop4

    Version:       	1
    LUKS header information
    Version:       	2
    Epoch:         	5
    ```

8. Suspendé un volumen en vivo: las claves se borran de la memoria del kernel, la E/S se congela, el montaje permanece.

    ```bash
    cryptsetup luksSuspend vault
    cryptsetup status vault | grep -E 'is active|key location'
    timeout 3 cat /mnt/vault/marker.txt ; echo "read exit=$? (124 = blocked)"
    cryptsetup luksResume --key-file /etc/luks-keys/vault.key vault
    cat /mnt/vault/marker.txt
    ```

    ```
    /dev/mapper/vault is active and is in use.
    read exit=124 (124 = blocked)
    topic 331.3 marker 2026-08-20T11:02:44Z
    ```

### Comprobá tu comprensión

- **P6.1** — `dmsetup ls --tree` mostró `sealed` apilado sobre `sealed_dif`. Describí la responsabilidad de cada capa y dónde viven físicamente los tags de autenticación.
- **P6.2** — LUKS2 autenticado detectó la corrupción; AES-XTS simple no. Explicá por qué XTS por sí solo no puede detectar manipulación, y dá la propiedad de seguridad que XTS *sí* provee contra un atacante que reescribe sectores.
- **P6.3** — dm-integrity en LUKS2 usa escrituras con journal por defecto. ¿Cuál es el costo de rendimiento, y bajo qué circunstancia es `--integrity-no-journal` (o el modo bitmap) un compromiso aceptable?
- **P6.4** — En el paso 4 usaste `--pbkdf-force-iterations` en lugar de `--iter-time`. ¿Por qué `--iter-time` produce el resultado equivocado al aprovisionar una imagen en un servidor de build rápido para un objetivo lento?
- **P6.5** — `cryptsetup reencrypt` cambió el digest de la clave maestra. ¿Siguió funcionando después cada passphrase que configuraste antes? Explicá en términos de la indirección keyslot/clave maestra.
- **P6.6** — La conversión a LUKS1 falló para el volumen Argon2id pero tuvo éxito para el de PBKDF2. Listá las tres propiedades que una cabecera LUKS2 debe tener para ser convertible, y nombrá la razón del mundo real (relacionada con el bootloader) por la que alguien todavía querría LUKS1 o LUKS2 solo con PBKDF2 hoy.
- **P6.7** — `luksSuspend` dejó el dispositivo "active and in use" pero las lecturas se colgaron. ¿Contra qué ataque concreto defiende la suspensión, y por qué `luksSuspend` sobre el sistema de archivos *raíz* es una forma de dejarte afuera?

---

## Ejercicio 7 — Cifrado de disco ligado a la red (NBDE) con Clevis y Tang

### Pasos

1. Iniciá un servidor Tang en el host del laboratorio. Tang usa activación por socket y escucha en TCP/7500 por defecto.

    ```bash
    systemctl enable --now tangd.socket
    ss -lntp | grep 7500
    ls -l /var/db/tang/
    ```

    ```
    LISTEN 0  4096  *:7500  *:*  users:(("systemd",pid=1,fd=42))
    -rw-r--r-- 1 root root 354 Aug 20 11:20 8kEQ2Qk3xQ8Jw1n7NfR0lC5FnUk.jwk
    -rw-r--r-- 1 root root 178 Aug 20 11:20 pT9x0wKuVn3sYb2LdG7oQmHrEaI.jwk
    ```

2. Traé el advertisement y registrá el thumbprint de la clave que vas a fijar.

    ```bash
    curl -fsS http://127.0.0.1:7500/adv | jq -r '.payload' | head -c 80; echo
    tang-show-keys 7500
    ```

    ```
    eyJrZXlzIjpbeyJhbGciOiJFUzUxMiIsImNydiI6IlAtNTIxIiwia2V5X29wcyI6WyJ2ZXJpZnki...
    x8kQ2Qk3xQ8Jw1n7NfR0lC5FnUkYtHb9vZpQ3mR4sTc
    ```

3. Demostrá la primitiva de Clevis independientemente de LUKS.

    ```bash
    THP=$(tang-show-keys 7500)
    echo "the master key never leaves this host" | \
        clevis encrypt tang "{\"url\":\"http://127.0.0.1:7500\",\"thp\":\"${THP}\"}" > /tmp/secret.jwe
    wc -c /tmp/secret.jwe
    clevis decrypt < /tmp/secret.jwe
    ```

    ```
    892 /tmp/secret.jwe
    the master key never leaves this host
    ```

4. Vinculá el volumen LUKS2 `vault` a Tang. Clevis consume una passphrase existente, aprovisiona un keyslot **aleatorio nuevo** y guarda el JWE en un token LUKS2.

    ```bash
    clevis luks bind -d /dev/loop1 tang \
        "{\"url\":\"http://127.0.0.1:7500\",\"thp\":\"${THP}\"}" \
        -k /etc/luks-keys/vault.key
    ```

    ```
    Updating binding...
    Binding succeeded.
    ```

5. Inspeccioná qué cambió en la cabecera.

    ```bash
    clevis luks list -d /dev/loop1
    cryptsetup luksDump /dev/loop1 | sed -n '/^Tokens:/,/^Digests:/p'
    ```

    ```
    2: tang '{"url":"http://127.0.0.1:7500"}'

    Tokens:
      0: clevis
    	Keyslot:    2
    ```

6. Desbloqueá sin ninguna passphrase.

    ```bash
    umount /mnt/vault 2>/dev/null; cryptsetup close vault
    clevis luks unlock -d /dev/loop1 -n vault
    cryptsetup status vault | head -2
    ```

    ```
    /dev/mapper/vault is active.
      type:    LUKS2
    ```

7. Mostrá el modo de fallo: pará Tang e intentá de nuevo.

    ```bash
    cryptsetup close vault
    systemctl stop tangd.socket
    clevis luks unlock -d /dev/loop1 -n vault ; echo "exit=$?"
    systemctl start tangd.socket
    ```

    ```
    Error communicating with server http://127.0.0.1:7500
    /dev/loop1 could not be opened.
    exit=1
    ```

8. Construí una política resiliente con **Shamir Secret Sharing**: 1 de 2 servidores Tang, para que una caída no deje el arranque inservible.

    ```bash
    clevis luks bind -d /dev/loop1 sss \
      "{\"t\":1,\"pins\":{\"tang\":[
          {\"url\":\"http://127.0.0.1:7500\",\"thp\":\"${THP}\"},
          {\"url\":\"http://tang2.lab.example:7500\",\"thp\":\"PLACEHOLDER\"}
       ]}}" -k /etc/luks-keys/vault.key 2>&1 | tail -2
    clevis luks list -d /dev/loop1
    ```

    ```
    2: tang '{"url":"http://127.0.0.1:7500"}'
    4: sss '{"t":1,"pins":{"tang":[{"url":"http://127.0.0.1:7500"},{"url":"http://tang2.lab.example:7500"}]}}'
    ```

9. Configurá el desbloqueo automático en el arranque y marcá el volumen como dependiente de la red.

    ```bash
    systemctl enable clevis-luks-askpass.path
    sed -i 's|^vault\(.*\)luks,discard|vault\1luks,discard,_netdev|' /etc/crypttab
    grep '^vault' /etc/crypttab
    # initramfs: Debian/Ubuntu -> update-initramfs -u -k all ; RHEL/Fedora -> dracut -f
    ```

    ```
    vault      UUID=9d2c71fa-...  /etc/luks-keys/vault.key  luks,discard,_netdev,nofail,x-systemd.device-timeout=10s
    ```

10. Auditá y desvinculá.

    ```bash
    clevis luks report -d /dev/loop1 -s 2
    clevis luks unbind -d /dev/loop1 -s 4 -f
    clevis luks list -d /dev/loop1
    ```

    ```
    Keyslot 2 is bound to a Tang server with the current advertised key. No rebinding needed.
    2: tang '{"url":"http://127.0.0.1:7500"}'
    ```

### Comprobá tu comprensión

- **P7.1** — Durante `clevis luks bind`, el servidor Tang nunca aprende la clave LUKS. Esbozá el intercambio McCallum–Relyea en tres oraciones: qué genera el cliente, qué envía, qué descarta.
- **P7.2** — Pasaste `"thp"` (thumbprint) explícitamente. ¿Qué ataque se vuelve posible si vinculás sin él, en una sesión interactiva donde aceptás a ciegas la clave anunciada?
- **P7.3** — NBDE se resume a menudo como "el disco se desbloquea solo dentro del datacenter". ¿Precisamente qué amenaza aborda eso, y qué amenaza explícitamente *no* aborda?
- **P7.4** — El pin `sss` se creó con `"t":1` sobre dos servidores Tang. ¿Qué cambia operativamente con `"t":2`, y qué expresaría `{"t":2,"pins":{"tang":[...],"tpm2":[...]}}` como política de seguridad?
- **P7.5** — Después de rotar las claves en el servidor Tang (moviendo el `.jwk` viejo a un nombre de archivo que empiece con `.` y generando nuevas), ¿qué hay que ejecutar en cada cliente vinculado, y qué pasa si *borrás* las claves viejas en vez de ocultarlas?
- **P7.6** — ¿Por qué `_netdev` es insuficiente por sí solo para un sistema de archivos **raíz** vinculado a Tang, y qué artefacto adicional hay que regenerar?

---

## Ejercicio 8 — eCryptfs: cifrado apilado, por archivo y por usuario

### Pasos

1. Confirmá el módulo y creá un usuario de prueba.

    ```bash
    modprobe ecryptfs
    grep ecryptfs /proc/filesystems
    useradd -m -s /bin/bash alice
    echo 'alice:AlicePass123' | chpasswd
    ```

    ```
    	ecryptfs
    ```

2. Como `alice`, configurá el directorio privado cifrado.

    ```bash
    su - alice -c 'ecryptfs-setup-private --nopwcheck' <<'EOF'
    AlicePass123

    EOF
    ```

    ```
    Enter your login passphrase [alice]:
    Enter your mount passphrase [leave blank to generate one]:

    ************************************************************************
    YOU SHOULD RECORD YOUR MOUNT PASSPHRASE AND STORE IT IN A SAFE LOCATION.
      ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase > (some file)
    THIS WILL BE REQUIRED IF YOU NEED TO RECOVER YOUR DATA AT A LATER TIME.
    ************************************************************************

    Done configuring.
    ```

3. Inspeccioná los artefactos que creó eCryptfs.

    ```bash
    ls -la /home/alice/.ecryptfs/
    ls -la /home/alice/ | grep -E 'Private|\.Private'
    cat /home/alice/.ecryptfs/Private.sig
    cat /home/alice/.ecryptfs/Private.mnt
    ```

    ```
    -rw------- 1 alice alice   16 Aug 20 11:40 Private.mnt
    -rw------- 1 alice alice   33 Aug 20 11:40 Private.sig
    lrwxrwxrwx 1 alice alice   28 Aug 20 11:40 auto-mount -> /home/alice/.ecryptfs/...
    -rw------- 1 alice alice   84 Aug 20 11:40 wrapped-passphrase
    drwx------ 2 alice alice 4096 Aug 20 11:40 .Private
    drwx------ 2 alice alice 4096 Aug 20 11:40 Private

    d4f2a1c9e07b3856
    d4f2a1c9e07b3856
    /home/alice/Private
    ```

4. Montá el directorio privado, escribí un archivo y mirá ambas vistas.

    ```bash
    su - alice -c 'ecryptfs-mount-private' <<< 'AlicePass123'
    su - alice -c 'echo "salary: classified" > ~/Private/hr.txt; ls -l ~/Private/'
    ls -l /home/alice/.Private/
    ```

    ```
    -rw-rw-r-- 1 alice alice 19 Aug 20 11:42 hr.txt

    -rw-rw-r-- 1 alice alice 12288 Aug 20 11:42 ECRYPTFS_FNEK_ENCRYPTED.FWaHZ5xVQ7pKmT2nB8dLuXcS9eRvY0jgIoP3--
    ```

5. Confirmá que el texto cifrado es real y leé la cabecera por archivo.

    ```bash
    head -c 64 /home/alice/.Private/ECRYPTFS_FNEK_ENCRYPTED.* | hexdump -C | head -3
    ecryptfs-stat /home/alice/.Private/ECRYPTFS_FNEK_ENCRYPTED.*
    ```

    ```
    00000000  00 00 00 00 00 00 00 13  03 00 00 00 00 00 30 00  |..............0.|
    00000010  00 00 00 00 00 00 00 00  0f 3a 2c 00 00 00 00 00  |.........:,.....|
    00000020  01 62 b1 4d 8c 07 a3 5f  29 e6 10 74 db 3f 98 c5  |.b.M..._)..t.?..|

    Version: 0
    Header Extent Size: 8192
    Extent Size: 4096
    flags
    	SIG_IN_HEADER
    	ENCRYPTED
    	METADATA_IN_XATTR: 0
    Root IV:
    	1 62 b1 4d 8c 7 a3 5f 29 e6 10 74 db 3f 98 c5
    ```

6. Mirá las opciones de montaje realmente vigentes y las claves en el keyring.

    ```bash
    findmnt -t ecryptfs -o TARGET,SOURCE,OPTIONS
    su - alice -c 'keyctl list @u'
    ```

    ```
    TARGET               SOURCE                  OPTIONS
    /home/alice/Private  /home/alice/.Private    rw,nosuid,nodev,relatime,ecryptfs_fnek_sig=d4f2a1c9e07b3856,
                                                 ecryptfs_sig=d4f2a1c9e07b3856,ecryptfs_cipher=aes,
                                                 ecryptfs_key_bytes=16,ecryptfs_unlink_sigs

    2 keys in keyring:
     93847261: --alswrv  1001  1001 user: d4f2a1c9e07b3856
    418273649: --alswrv  1001  1001 user: 8e1b0c74a9d5f236
    ```

7. Desmontá y demostrá que la vista en texto plano desapareció.

    ```bash
    su - alice -c 'ecryptfs-umount-private'
    su - alice -c 'ls -la ~/Private/'
    ```

    ```
    total 8
    drwx------ 2 alice alice 4096 Aug 20 11:40 .
    drwxr-xr-x 8 alice alice 4096 Aug 20 11:42 ..
    ```

8. Recuperá la mount passphrase (el paso de recuperación ante desastres que toda implementación debe documentar).

    ```bash
    su - alice -c 'ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase' <<< 'AlicePass123'
    ```

    ```
    2f7c91a4e0b8d63510ac47f92be8d1c3
    ```

9. Montá un directorio arbitrario manualmente — sin los helpers de `ecryptfs-utils`, con todas las opciones explícitas.

    ```bash
    mkdir -p /srv/lower /srv/upper
    SIG=$(printf 'ManualPass' | ecryptfs-add-passphrase --fnek 2>/dev/null | \
          grep -oP '(?<=\[)[0-9a-f]{16}(?=\])' | head -1)
    echo "sig=$SIG"

    mount -t ecryptfs /srv/lower /srv/upper -o \
      key=passphrase:passphrase_passwd=ManualPass,\
    ecryptfs_cipher=aes,ecryptfs_key_bytes=32,\
    ecryptfs_enable_filename_crypto=y,ecryptfs_fnek_sig=${SIG},ecryptfs_sig=${SIG},\
    ecryptfs_passthrough=n,ecryptfs_unlink_sigs,no_sig_cache

    echo "manual mount works" > /srv/upper/proof.txt
    ls /srv/lower/
    umount /srv/upper
    ls /srv/lower/
    ```

    ```
    sig=8a3f0c71e92b45d6
    ECRYPTFS_FNEK_ENCRYPTED.FXbQ8mZvR4tKpL7nD2sYcW9eUhJgI0oPa3--
    ECRYPTFS_FNEK_ENCRYPTED.FXbQ8mZvR4tKpL7nD2sYcW9eUhJgI0oPa3--
    ```

10. Inspeccioná la integración con PAM que hace automático el desenvolvido en el login.

    ```bash
    grep -rn pam_ecryptfs /etc/pam.d/
    ```

    ```
    /etc/pam.d/common-auth:26:auth     optional  pam_ecryptfs.so unwrap
    /etc/pam.d/common-session:31:session optional pam_ecryptfs.so unwrap
    /etc/pam.d/common-password:29:password optional pam_ecryptfs.so
    ```

### Comprobá tu comprensión

- **P8.1** — Un texto plano de 19 bytes se convirtió en un archivo cifrado de 12288 bytes. Justificá el tamaño, y enunciá qué puede seguir infiriendo sobre `hr.txt` un atacante que solo tenga `.Private`.
- **P8.2** — Explicá el diseño de dos claves: FEK, FEKEK y FNEK. ¿Cuál se guarda dentro de cada archivo, cuál se deriva de la passphrase de login de alice, y dónde encaja la *wrapped passphrase*?
- **P8.3** — `pam_ecryptfs.so` aparece en `common-auth`, `common-session` **y** `common-password`. Enunciá la tarea de cada ocurrencia, y predecí la rotura exacta si se elimina la línea de `common-password`.
- **P8.4** — ¿Por qué `pam_ecryptfs` es fundamentalmente incapaz de desbloquear el directorio Private de alice cuando ella inicia sesión por SSH con clave pública en lugar de contraseña? Nombrá la mitigación estándar.
- **P8.5** — Compará eCryptfs y LUKS/dm-crypt en cuatro ejes: qué se oculta, granularidad de la clave, si el contenedor debe dimensionarse previamente, y comportamiento en backup con `rsync`.
- **P8.6** — Se estableció `ecryptfs_passthrough=n` explícitamente. ¿Qué permite `=y`, y por qué es un riesgo en un despliegue de directorios personales?
- **P8.7** — ¿Cuál es la única razón por la que la salida de `ecryptfs-unwrap-passphrase` debe guardarse offline antes de que el despliegue entre en producción?

---

## Ejercicio 9 — `fscrypt`: cifrado nativo a nivel de archivo en ext4

### Pasos

1. Preparate un sistema de archivos con la característica `encrypt`.

    ```bash
    truncate -s 256M /root/cryptolab/fscrypt.img
    FSD=$(losetup --find --show /root/cryptolab/fscrypt.img)
    mkfs.ext4 -q -O encrypt "$FSD"
    mkdir -p /mnt/fsc && mount "$FSD" /mnt/fsc
    tune2fs -l "$FSD" | grep -i 'features'
    ```

    ```
    Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                              extent 64bit flex_bg encrypt sparse_super large_file
                              huge_file dir_nlink extra_isize metadata_csum
    ```

    > En un sistema de archivos existente la característica se agrega offline: `umount`, `tune2fs -O encrypt /dev/sdX`, `e2fsck -f /dev/sdX`.

2. Inicializá `fscrypt` globalmente y en este punto de montaje.

    ```bash
    fscrypt setup --quiet
    fscrypt setup /mnt/fsc --quiet
    ls -la /mnt/fsc/.fscrypt/
    ```

    ```
    drwxr-xr-x 2 root root 4096 Aug 20 12:01 policies
    drwxr-xr-x 2 root root 4096 Aug 20 12:01 protectors
    ```

3. Cifrá un directorio **vacío** con un protector de passphrase personalizado.

    ```bash
    mkdir /mnt/fsc/confidential
    fscrypt encrypt /mnt/fsc/confidential \
        --source=custom_passphrase --name=lab-331-3 --quiet <<'EOF'
    FscryptPass!
    FscryptPass!
    EOF
    fscrypt status /mnt/fsc/confidential
    ```

    ```
    "/mnt/fsc/confidential" is encrypted with fscrypt.

    Policy:   7c1e0a95b3d62f48
    Options:  padding:32 contents:AES_256_XTS filenames:AES_256_CTS policy_version:2
    Unlocked: Yes

    Protected with 1 protector:
    PROTECTOR         LINKED  DESCRIPTION
    3f8b02d7ae51c964  No      custom protector "lab-331-3"
    ```

4. Escribí datos, bloqueá el directorio y observá la vista de nombres de archivo cifrados.

    ```bash
    echo 'board minutes 2026-Q3' > /mnt/fsc/confidential/minutes.txt
    ls -l /mnt/fsc/confidential/
    fscrypt lock /mnt/fsc/confidential
    ls -l /mnt/fsc/confidential/
    cat /mnt/fsc/confidential/* 2>&1 | head -2
    ```

    ```
    -rw-r--r-- 1 root root 22 Aug 20 12:03 minutes.txt

    -rw-r--r-- 1 root root 22 Aug 20 12:03 g3TQzP9xkR2mYbN7dLcSvW0eUhJI,A5o
    cat: /mnt/fsc/confidential/g3TQzP9xkR2mYbN7dLcSvW0eUhJI,A5o: Required key not available
    ```

5. Desbloqueá y confirmá.

    ```bash
    fscrypt unlock /mnt/fsc/confidential --quiet <<< 'FscryptPass!'
    cat /mnt/fsc/confidential/minutes.txt
    fscrypt status
    ```

    ```
    board minutes 2026-Q3

    filesystems supporting encryption: 1
    MOUNTPOINT  DEVICE     FILESYSTEM  ENCRYPTION     FSCRYPT
    /mnt/fsc    /dev/loop5  ext4        supported      Yes
    ```

6. Leé la política directamente del kernel, sin pasar por `fscrypt(1)`.

    ```bash
    fscryptctl get_policy /mnt/fsc/confidential
    ```

    ```
    Encryption policy for /mnt/fsc/confidential:
    	Policy version: 2
    	Master key identifier: 7c1e0a95b3d62f48a012cd8b4e6f7309
    	Contents encryption mode: AES-256-XTS
    	Filenames encryption mode: AES-256-CTS
    	Flags: PAD_32
    ```

7. Demostrá los metadatos que *no* están protegidos.

    ```bash
    fscrypt lock /mnt/fsc/confidential
    stat -c '%n size=%s mode=%a uid=%u mtime=%y' /mnt/fsc/confidential/*
    ```

    ```
    /mnt/fsc/confidential/g3TQzP9xkR2mYbN7dLcSvW0eUhJI,A5o size=22 mode=644 uid=0 mtime=2026-08-20 12:03:11
    ```

### Comprobá tu comprensión

- **P9.1** — En el paso 7, con la clave desalojada, `stat` seguía reportando tamaño, modo, uid y mtime exactos. Listá todo lo que fscrypt *no* cifra, y dá un escenario realista donde esa filtración importa.
- **P9.2** — `fscrypt encrypt` se niega a ejecutarse sobre un directorio no vacío. ¿Por qué es esa una restricción del kernel y no una limitación de la herramienta?
- **P9.3** — `padding:32` aparece en la política. ¿Qué se rellena, y qué ataque mitiga?
- **P9.4** — Contrastá las políticas fscrypt v1 y v2 respecto de *quién* puede desbloquear y dónde vive la clave (keyring de sesión `@s` vs. keyring del sistema de archivos).
- **P9.5** — En una laptop que necesita protección de disco completo incluyendo `/etc`, `/var` y swap, ¿alcanza con fscrypt? Justificá la respuesta y enunciá el apilamiento correcto.
- **P9.6** — fscrypt tampoco tiene protección de integridad. ¿Qué apilarías por debajo para obtener almacenamiento autenticado manteniendo las claves por directorio de fscrypt?

---

## Ejercicio 10 — `cryptmount`: contenedores cifrados montables por el usuario

### Pasos

1. Creá un archivo contenedor y un punto de montaje propiedad de un usuario normal.

    ```bash
    id alice
    mkdir -p /home/alice/vault && chown alice:alice /home/alice/vault
    truncate -s 128M /srv/alice-crypt.fs
    ```

2. Escribí la entrada de `cmtab` a mano (la alternativa interactiva es `cryptmount-setup`).

    ```bash
    cat > /etc/cryptmount/cmtab <<'EOF'
    alicevault {
        dev=/srv/alice-crypt.fs
        dir=/home/alice/vault
        fstype=ext4
        mountoptions=defaults,nosuid,nodev
        cipher=aes-xts-plain64
        keyformat=luks
        keyfile=/srv/alice-crypt.fs
        keymaxlen=32
        supath=/sbin:/bin:/usr/sbin:/usr/bin
    }
    EOF
    cryptmount -l
    ```

    ```
    alicevault  [to be mounted on /home/alice/vault]
    ```

3. Generá la clave y el sistema de archivos (root hace esto una vez).

    ```bash
    cryptmount --generate-key 32 alicevault <<'EOF'
    AliceVaultPass
    AliceVaultPass
    EOF

    cryptmount --prepare alicevault <<< 'AliceVaultPass'
    mkfs.ext4 -q /dev/disk/by-id/dm-name-alicevault
    cryptmount --release alicevault
    ```

4. Entregá la propiedad a alice y dejá que *ella* lo monte, sin privilegios.

    ```bash
    cryptmount -m alicevault <<< 'AliceVaultPass'
    chown alice:alice /home/alice/vault
    cryptmount -u alicevault

    su - alice -c 'cryptmount -m alicevault' <<< 'AliceVaultPass'
    su - alice -c 'touch ~/vault/mine.txt; ls -l ~/vault/'
    findmnt /home/alice/vault
    su - alice -c 'cryptmount -u alicevault'
    ```

    ```
    -rw-rw-r-- 1 alice alice 0 Aug 20 12:20 mine.txt

    TARGET             SOURCE                  FSTYPE OPTIONS
    /home/alice/vault  /dev/mapper/alicevault  ext4   rw,nosuid,nodev,relatime
    ```

5. Cambiá la contraseña del contenedor sin tocar los datos.

    ```bash
    cryptmount --change-password alicevault <<'EOF'
    AliceVaultPass
    NewVaultPass2026
    NewVaultPass2026
    EOF
    cryptmount --status alicevault
    ```

    ```
    Target "alicevault" is not mounted
      device: /srv/alice-crypt.fs
      key file: /srv/alice-crypt.fs (luks format)
    ```

### Comprobá tu comprensión

- **P10.1** — `cryptmount` permitió que un usuario no root ejecutara `cryptmount -m`. ¿Qué mecanismo sobre el binario `cryptmount` lo hace posible, y qué dos campos de `cmtab` son la frontera de seguridad que impide que alice monte el contenedor de otra persona?
- **P10.2** — `mountoptions=defaults,nosuid,nodev` — explicá por qué omitir `nosuid` en un contenedor montable por el usuario es un camino directo de escalada local de privilegios.
- **P10.3** — `keyformat=luks` con `keyfile` apuntando al contenedor mismo. ¿Qué se guarda dónde en ese arreglo, y qué cambiaría `keyformat=builtin` con un `keyfile` separado?
- **P10.4** — Compará `cryptmount` con `/etc/crypttab` + `systemd-cryptsetup`: ¿para cuál requisito único es `cryptmount` claramente la herramienta correcta?

---

## Ejercicio 11 — Diagnóstico: leer el fallo

### Pasos

1. Construí una tabla de referencia del stack criptográfico en vivo.

    ```bash
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT
    dmsetup ls --tree -o blkdevname
    dmsetup info -c -o name,major,minor,open,segments,tables_loaded
    ```

    ```
    NAME        SIZE FSTYPE      TYPE  MOUNTPOINT
    loop1       256M crypto_LUKS loop
    └─vault     240M ext4        crypt /mnt/vault
    loop3       256M crypto_LUKS loop
    └─sealed_dif      crypt
      └─sealed        ext4       crypt

    Name             Maj Min Open Seg  Tables
    vault            253   0    1   1  LIVE
    sealed_dif       253   1    1   1  LIVE
    sealed           253   2    0   1  LIVE
    ```

2. Reproducí y leé cada error clásico.

    ```bash
    # (a) device busy on close
    cryptsetup close vault ; echo "exit=$?"
    ```
    ```
    Device vault is still in use.
    exit=5
    ```

    ```bash
    # (b) source already mapped
    cryptsetup open --key-file /etc/luks-keys/vault.key /dev/loop1 vault2 ; echo "exit=$?"
    ```
    ```
    Cannot use device /dev/loop1, name is invalid or still in use.
    exit=5
    ```

    ```bash
    # (c) not a LUKS device
    cryptsetup luksDump /dev/loop3 --header /dev/null 2>&1 | head -1
    cryptsetup luksAddKey /dev/zero 2>&1 | head -1
    ```
    ```
    Device /dev/null is not a valid LUKS device.
    Device /dev/zero is not a valid LUKS device.
    ```

    ```bash
    # (d) all slots consumed
    for i in $(seq 1 40); do
      printf 'AeadPass\nfill%02d\nfill%02d\n' "$i" "$i" | cryptsetup luksAddKey /dev/loop3 2>&1 | tail -1
    done | sort -u | tail -2
    ```
    ```
    All key slots full.
    ```

    ```bash
    # (e) ecryptfs without the module
    rmmod ecryptfs 2>/dev/null
    mount -t ecryptfs /srv/lower /srv/upper -o key=passphrase 2>&1 | head -1
    modprobe ecryptfs
    ```
    ```
    mount: /srv/upper: unknown filesystem type 'ecryptfs'.
    ```

3. Activá salida verbose/debug cuando el mensaje no alcanza.

    ```bash
    cryptsetup --debug --verbose open --test-passphrase \
        --key-file /etc/luks-keys/vault.key /dev/loop1 2>&1 | grep -E 'Trying|Keyslot|Digest|Activating' | head -8
    ```

    ```
    # Trying to open and read device /dev/loop1 with direct-io.
    # Reading LUKS header of size 16384 from device /dev/loop1
    # Trying to open key slot 3 [ACTIVE_LAST].
    # Reading key slot 3 area.
    # Verifying key digest 0.
    Key slot 3 unlocked.
    ```

4. Confirmá la vista completa del stack para auditoría.

    ```bash
    for d in /dev/loop1 /dev/loop3; do
      printf '== %s\n' "$d"
      cryptsetup isLuks "$d" && echo "  isLuks: yes (v$(cryptsetup luksDump "$d" | awk '/^Version/{print $2}'))"
      cryptsetup luksUUID "$d"
      cryptsetup luksDump "$d" | grep -cE '^\s+[0-9]+: luks[12]?' | xargs printf '  active keyslots: %s\n'
    done
    ```

### Comprobá tu comprensión

- **P11.1** — El error (a) devolvió exit 5 con `Device vault is still in use`. Dá la secuencia de dos comandos que lo resuelve, y nombrá la herramienta que identifica *qué* proceso lo retiene.
- **P11.2** — En (d), LUKS2 se quedó sin slots mucho antes de 40. ¿Qué limita la cantidad de keyslots LUKS2, y en qué difiere ese límite de los 8 fijos de LUKS1?
- **P11.3** — La traza de `--debug` muestra `Trying to open key slot 3 [ACTIVE_LAST]` primero. Relacioná esto con la prioridad de slot que configuraste en el Ejercicio 2, y explicá el costo de *no* configurar prioridades en un volumen con muchos slots y un KDF Argon2 lento.
- **P11.4** — Un colega reporta "LUKS pide una contraseña pero siempre la rechaza después de una actualización de kernel". Con las herramientas de este documento, listá — en orden — las tres verificaciones que ejecutarías antes de concluir que la cabecera está dañada.
- **P11.5** — `dmsetup ls --tree` mostró `sealed` sobre `sealed_dif`. Si `sealed` se eliminara con `dmsetup remove` pero `sealed_dif` quedara, ¿qué reportaría `cryptsetup open` en el siguiente intento, y cómo se limpia?

---

## Ejercicio 12 — Desarme

### Pasos

1. Desmontá y cerrá todo, en orden inverso de dependencias.

    ```bash
    umount /mnt/vault /mnt/sealed /mnt/fsc /mnt/plain /srv/upper 2>/dev/null
    su - alice -c 'ecryptfs-umount-private' 2>/dev/null
    cryptmount -u alicevault 2>/dev/null

    for m in vault sealed plainmap hidden alicevault; do
        cryptsetup close "$m" 2>/dev/null
    done
    dmsetup ls
    ```

    ```
    No devices found
    ```

2. Desasociá los loop devices y eliminá el laboratorio, incluidas las líneas de `crypttab`/`fstab` que agregaste.

    ```bash
    losetup -D
    sed -i '/cryptolab\|alicevault\|^vault \|^archive \|^hidden \|^cryptswap /d' /etc/fstab /etc/crypttab
    systemctl daemon-reload
    rm -rf /root/cryptolab /srv/lower /srv/upper /srv/alice-crypt.fs /etc/luks-keys /etc/cryptmount/cmtab
    userdel -r alice 2>/dev/null
    systemctl disable --now tangd.socket
    ```

### Comprobá tu comprensión

- **P12.1** — Borraste `/etc/luks-keys/vault.key` en el desarme. En un sistema de producción, ¿qué tenés que verificar *antes* de borrar un archivo de clave LUKS, y cuál es la posición de recuperación si te equivocás?
- **P12.2** — El orden importa en el paso 1: `umount` → `cryptsetup close` → `losetup -D`. Explicá qué falla, y con qué error, si invertís los dos primeros.

---

<details>
<summary><strong>Respuestas</strong> — expandí solo después de intentar todas las preguntas</summary>

### Ejercicio 0

**R0.1** — El descifrado AES-CBC es paralelizable entre bloques (cada bloque de texto cifrado solo necesita a su predecesor, que ya se conoce), así que la CPU lo canaliza y AES-NI procesa múltiples bloques por ciclo. El *cifrado* CBC es inherentemente serial: el bloque *n* no puede empezar hasta que exista el texto cifrado del bloque *n−1*. XTS no tiene encadenamiento entre bloques en ninguna dirección — cada bloque de 16 bytes recibe un tweak independiente derivado del número de sector y del índice de bloque — así que ambas direcciones paralelizan igual y los números coinciden. Esta es una de las razones por las que XTS, y no CBC, es el default para cifrado de disco.

**R0.2** — XTS divide la clave suministrada en dos mitades: una para el cifrado de datos y otra para el cifrado del tweak. Una clave XTS de 512 bits es por lo tanto AES-256 para datos más AES-256 para el tweak. `aes-xts 256b` es AES-128 dos veces. `--key-size 512` de `cryptsetup` con `aes-xts-plain64` significa AES-256-XTS, y `--key-size 256` significa AES-128-XTS — una fuente frecuente de degradaciones accidentales de la fuerza de la clave.

**R0.3** — Un archivo sparse solo asigna los bloques que efectivamente se escribieron. Como los rangos no asignados se leen como ceros en lugar de datos aleatorios preexistentes, el *mapa de asignación mismo* revela qué regiones del "disco" contienen datos — los patrones de uso se filtran aunque el contenido no. En un dispositivo de bloque real, un volumen LUKS correctamente inicializado (o un pre-borrado con `dd if=/dev/urandom`) hace que el espacio libre sea indistinguible del usado. Exactamente por esto la FAQ recomienda limpiar un disco con datos aleatorios antes de `luksFormat` si te importa ocultar cuántos datos guardás.

**R0.4** — La unidad es kibibytes, así que 1048576 KiB = 1 GiB de memoria por intento de derivación. Argon2 es un KDF *memory-hard*: el parámetro apunta a atacantes que paralelizan la adivinación de contraseñas en GPUs y ASICs, donde el cómputo es barato pero la memoria de alto ancho de banda por núcleo no lo es. Las iteraciones de PBKDF2 solo elevan el costo aritmético, que las GPUs absorben casi gratis; esa es la razón concreta por la que LUKS2 migró a Argon2id.

### Ejercicio 1

**R1.1** — LUKS2 guarda dos copias redundantes de la cabecera binaria más dos áreas de metadatos JSON (16 KiB por defecto cada una, con descriptores de keyslots, digests, segmentos, tokens y config), y después un **área de keyslots** mucho mayor (~16 MiB) para que hasta 32 keyslots, cada uno conteniendo una división anti-forense de 4000 stripes de una clave de 512 bits, entren con espacio para crecer. La redundancia es el punto clave: LUKS2 puede recuperarse de una cabecera primaria corrupta usando la copia secundaria, algo que LUKS1 no puede. El área más grande también deja margen para tokens (JWE de Clevis, systemd-tpm2, systemd-fido2) y para la contabilidad del recifrado.

**R1.2** — `MK iterations` es la cantidad de iteraciones PBKDF2 usada para derivar el *digest de la clave maestra* — la suma de verificación que confirma "la clave maestra que acabo de recuperar es la correcta". `Key Slot 0 → Iterations` es la cantidad de iteraciones PBKDF2 usada para derivar la *clave del slot* a partir de tu passphrase. El valor del slot tiene que ser grande porque una passphrase es de baja entropía y directamente atacable por fuerza bruta; el valor del digest puede ser menor porque opera sobre una clave maestra aleatoria de 512 bits que no es adivinable en absoluto. Atacar el digest no tiene sentido; atacar el slot es la amenaza real, y ahí es donde va el factor de trabajo.

**R1.3** — La división anti-forense expande la clave maestra a `stripes × longitud_de_clave` bytes (4000 × 64 = 256000 bytes) usando una función de difusión, y se requiere *todo* para reconstruir la clave — perder cualquier parte la destruye. Su propósito es derrotar la remanencia de datos en medios magnéticos y flash: cuando se borra un keyslot, un atacante que recupere unos pocos sectores sobrevivientes del área vieja del keyslot desde páginas flash sin borrar o residuos magnéticos igual no obtiene nada, porque el material AF parcial es inútil. Sin ella, recuperar un solo fragmento de 64 bytes recuperaría la clave.

**R1.4** — Beneficio: con un sector de cifrado de 4096 bytes, dm-crypt realiza una operación criptográfica por cada 4 KiB en lugar de ocho por cada 4 KiB, recortando notablemente la sobrecarga por E/S en NVMe modernos y en sistemas de archivos que ya usan bloques de 4 KiB; además es requisito para que los modos autenticados sean eficientes. Restricción: cada E/S debe estar alineada a y ser múltiplo de 4096 bytes, así que tanto el tamaño de bloque lógico del dispositivo subyacente como el offset de datos deben ser compatibles; un dispositivo con lógico de 512 bytes y una partición que empiece desalineada rechazará el formateo, y las herramientas antiguas que emiten E/S de 512 bytes directamente al mapeo se rompen.

**R1.5** — `blkid` lee solamente la *cabecera LUKS no cifrada*, que es deliberadamente texto plano: cadena mágica `LUKS\xba\xbe`, versión, UUID, etiqueta, especificación de cifrado y metadatos de keyslots. Nada de eso revela la clave maestra ni el payload. El diseño es intencional — la cabecera debe ser autodescriptiva para que cualquier máquina pueda identificar el volumen y saber cómo pedir una passphrase, sin que la cabecera misma sea un secreto. Su consecuencia es que LUKS **no** provee ocultamiento: un examinador sabe de inmediato que hay un volumen cifrado presente.

### Ejercicio 2

**R2.1** — Desde cryptsetup 2.0, la clave de volumen se carga en el **keyring del kernel** (como una clave de tipo `logon`, que no es legible desde espacio de usuario ni siquiera por root) y a dm-crypt se le da una referencia al keyring de la forma `:<size>:logon:cryptsetup:<uuid>-d<n>` en lugar de la clave hexadecimal cruda. La ganancia es que la clave ya no aparece en la tabla del device-mapper, así que no puede extraerse por ningún proceso que lea ioctls de `/dev/mapper`, no termina en la salida de `dmsetup table` pegada en un ticket de soporte, y no queda expuesta en un volcado de memoria de espacio de usuario. También significa que `--showkeys` ahora no hace nada para esos mapeos.

**R2.2** — No se recifra ningún dato. LUKS está construido sobre una indirección de dos niveles: la *clave maestra* (también llamada clave de volumen) cifra los datos y nunca cambia; cada *keyslot* guarda una copia de esa clave maestra dividida con AF y cifrada con la passphrase. Eliminar un slot borra el área de ese slot — la copia cifrada de la clave maestra — de modo que esa passphrase ya no puede *recuperar* la clave maestra. La clave maestra, y por lo tanto todos los datos en disco, quedan intactos. Por eso un backup de cabecera robado tomado antes de la eliminación sigue funcionando, y por eso solo `cryptsetup reencrypt` rota genuinamente la clave maestra.

**R2.3** — `luksChangeKey --key-slot 0` borra el slot viejo y escribe el nuevo; hay una ventana en la que el slot 0 no contiene ni el material viejo ni el nuevo, así que una interrupción (corte de energía, proceso terminado) puede dejarte sin poder abrir el volumen con ese slot. `luksAddKey` en un slot *libre*, verificar la credencial nueva con `--test-passphrase`, y después `luksKillSlot` sobre el viejo es estrictamente más seguro porque nunca hay un momento con cero credenciales usables. Preferí agregar-verificar-eliminar para todo lo desatendido; `luksChangeKey` es aceptable solo de forma interactiva y cuando existe otro slot funcionando.

**R2.4** — LUKS usa el *contenido completo* del archivo de clave como passphrase por defecto. Agregar un salto de línea cambia la cadena de bytes, así que la clave de slot derivada cambia y la passphrase deja de funcionar silenciosamente — con el completamente inútil `No key available with this passphrase`. La defensa estándar es fijar la longitud explícitamente: `--keyfile-size 4096` en la CLI y `keyfile-size=4096` en `/etc/crypttab`, para que solo se lean los primeros 4096 bytes y las ediciones al final se ignoren. (`--keyfile-offset` / `keyfile-offset=` fijan de forma análoga el inicio cuando la clave está embebida en un blob mayor.)

**R2.5** — Es un control de latencia/UX, no un control de seguridad. Al desbloquear, cryptsetup prueba los slots por orden de prioridad: primero los `prefer`, después los `normal`, y los `ignore` se saltean por completo salvo que el slot se nombre explícitamente con `--key-slot`. Con un KDF Argon2id costoso, probar cinco slots incorrectos antes del correcto cuesta cinco derivaciones completas — potencialmente muchos segundos en el arranque. Poner `prefer` en el slot que el proceso de arranque efectivamente usa elimina eso. `ignore` es genuinamente útil para slots de emergencia/recuperación que nunca querés que se prueben automáticamente, pero no los hace más débiles ni más fuertes.

### Ejercicio 3

**R3.1** — Un backup de cabecera LUKS es una **instantánea completa y permanente de todas las credenciales que existían al momento del backup**. Restaurarlo resucita passphrases revocadas, porque los keyslots que contiene siguen descifrando la misma clave maestra sin cambios. Regla operativa: un backup de cabecera debe tratarse como equivalente a *todas* las passphrases que contiene, retenerse bajo los mismos controles que las passphrases mismas, y **destruirse de forma segura en el momento en que cualquier credencial que contenga sea revocada** — y después tomarse un backup fresco. Si se sospecha compromiso de una credencial, revocar el slot no alcanza; hay que hacer `cryptsetup reencrypt` para cambiar la clave maestra, lo que invalida todos los backups de cabecera viejos de una vez.

**R3.2** — `offset: 0 sectors` porque la cabecera no está en el dispositivo, así que el payload de texto cifrado empieza en el byte 0 de `/dev/loop2`. Los 256 MiB completos son utilizables, contra 240 MiB en `/dev/loop1` donde 16 MiB los consume la cabecera LUKS2. El compromiso es severo: si perdés o corrompés el archivo de cabecera separado, los datos son irrecuperables, sin copia en disco y sin cabecera secundaria a la cual recurrir. Las cabeceras separadas exigen una disciplina de backup al menos tan rigurosa como la de la passphrase misma.

**R3.3** — El dispositivo contiene datos de alta entropía sin firma de sistema de archivos, y eso en sí mismo es anómalo: una región de disco que no es ni ceros, ni un sistema de archivos reconocible, ni un tipo de partición conocido es un indicador estadístico fuerte de cifrado. Además, rutinariamente sobreviven otros rastros en otras partes: `/etc/crypttab` o el historial del shell referenciando `--header`, el mtime y la ruta del archivo de cabecera, entradas de `journalctl` de `systemd-cryptsetup`, metadatos del sistema de archivos sobre el archivo de cabecera, y el punto de montaje en `/etc/fstab`. La negación plausible requiere eliminar todo eso de forma consistente, lo que es mucho más difícil que crear la cabecera separada. LUKS está diseñado para confidencialidad, no para ocultamiento.

**R3.4** — No se tocó nada del payload. `luksErase` sobrescribe solo las áreas de keyslots — unos pocos cientos de kibibytes — destruyendo cada copia cifrada de la clave maestra. Como la clave maestra es un valor aleatorio de 512 bits que existe *solo* dentro de esos keyslots (y, transitoriamente, en la memoria del kernel), destruirlos destruye el único camino hacia ella, y el texto cifrado se vuelve computacionalmente indistinguible de ruido aleatorio. La propiedad explotada es la **indirección de la clave maestra**: destruir de forma segura una clave de tamaño fijo destruye cantidades arbitrariamente grandes de datos. Este es el mecanismo estándar para el crypto-shredding instantáneo de un arreglo de múltiples terabytes, y la razón por la que la FAQ insiste en que no se puede "des-borrar" un volumen LUKS.

**R3.5** — El disco está protegido por la fuerza de la passphrase que elegiste; el backup de cabecera es una copia *separada* de los mismos keyslots que un atacante puede atacar por fuerza bruta **offline**, a máxima velocidad, sin tocar la máquina, y sin ninguna limitación de tasa ni evidencia de manipulación. Además sobrevive después de que hayas borrado el disco. Al dar de baja una passphrase tenés que destruir cada backup de cabecera que contenga ese slot (`shred`/`wipefs` sobre el archivo más su eliminación de cualquier sistema externo/de backup) y generar un backup nuevo desde la cabecera actual — de lo contrario la revocación es cosmética.

### Ejercicio 4

**R4.1** — Omitir `luks` y dar `/dev/urandom` como archivo de clave selecciona **dm-crypt plain** con una clave aleatoria nueva generada en cada arranque; la opción `swap` le dice a `systemd-cryptsetup` que ejecute `mkswap` sobre el mapeo resultante después de la activación. Para swap esto es exactamente correcto: el contenido del swap son datos temporales por arranque, y una clave que existe solo en memoria del kernel y nunca se persiste significa que cualquier cosa paginada a disco — incluyendo claves en texto plano, tokens de sesión y buffers de documentos descifrados — es irrecuperable tras un ciclo de energía, sin ninguna carga de gestión de claves. Para `/home` es catastrófico: una clave aleatoria nueva en cada arranque significa que los datos del arranque previo son permanentemente indescifrables, y `mkswap`/`mkfs` los destruiría igual. Notá el corolario: **la hibernación es incompatible** con swap de clave aleatoria, porque reanudar necesita la clave del arranque anterior.

**R4.2** — El prompt se emite a través del framework de agentes de contraseña de systemd: `systemd-cryptsetup` llama a `systemd-ask-password`, que escribe un pedido en `/run/systemd/ask-password/` y cualquier agente registrado (el agente de consola `systemd-ask-password-console.service`, agentes de plasma/gnome, o un agente remoto vía `systemd-tty-ask-password-agent`) puede responderlo. `tries=3` limita los intentos antes de que la unit falle; `timeout=30s` limita cuánto espera una respuesta. `noauto` en el ejemplo significa que ni siquiera se intenta en el arranque — se activa bajo demanda con `systemctl start systemd-cryptsetup@archive.service` o por una dependencia `x-systemd.requires=`.

**R4.3** — Sin `x-systemd.requires=systemd-cryptsetup@vault.service`, systemd solo sabe que el montaje depende de que exista `/dev/mapper/vault`; el ordenamiento se descubre vía udev, y la unit de montaje puede programarse antes de que la unit de cifrado haya terminado — o, peor, `local-fs.target` falla y el arranque cae en modo de emergencia. Sin `nofail`, ese fallo es fatal: un volumen faltante o que no se puede abrir impide un arranque exitoso, requiriendo acceso a consola para recuperarse. En un servidor sin cabecera, esa combinación convierte un disco degradado en una caída de servicio. El patrón correcto es `nofail` más un `x-systemd.requires=` explícito (o `_netdev` para volúmenes desbloqueados por red, que arrastra el ordenamiento de red automáticamente).

**R4.4** — Con discards habilitados, los comandos TRIM/UNMAP pasan desde el sistema de archivos a través de dm-crypt hasta el SSD, así que la unidad aprende *qué LBAs no contienen datos vivos*. Eso revela el patrón usado/libre del sistema de archivos y su evolución en el tiempo — cuán lleno está el volumen, aproximadamente dónde están los datos, y que ciertas regiones fueron borradas — nada de lo cual debería ser visible en un dispositivo cifrado. También puede debilitar la negación de un contenedor oculto y, en el peor caso, exponer estructura a nivel del sistema de archivos. El beneficio es el nivelado de desgaste del SSD y el rendimiento sostenido de escritura. La cabecera de LUKS1 no tiene un campo de flags de propósito general — los flags de activación persistentes (`allow-discards`, `no-journal`, `no-read-workqueue`, `no-write-workqueue`, `same-cpu-crypt`) son una característica exclusiva de LUKS2 guardada en `config.flags` del JSON; en LUKS1 hay que pasar `--allow-discards` en cada `open`, o poner `discard` en `crypttab`.

**R4.5** — `_netdev`. Marca el volumen como dependiente de la red, lo que hace que systemd ordene la unit después de `network-online.target` y `remote-fs-pre.target` y coloque el montaje correspondiente bajo `remote-fs.target` en lugar de `local-fs.target`. Sin ella, `systemd-cryptsetup` corre antes de que la red esté levantada, Clevis no puede alcanzar el servidor Tang, la unit falla, y el arranque cae al prompt interactivo de passphrase o al modo de emergencia.

### Ejercicio 5

**R5.1** — El modo plain **no tiene cabecera alguna** — no guarda nada en disco. La clave se deriva de tu passphrase con un solo hash (acá SHA-512) y se entrega directo a dm-crypt, que con gusto establecerá un mapeo con *cualquier* clave porque no hay nada contra qué comparar. LUKS provee la verificación faltante mediante el **digest de la clave maestra**: un hash PBKDF2 de la clave maestra guardado en la cabecera. Después de desenvolver un keyslot, cryptsetup hashea la clave maestra recuperada y la compara con el digest guardado; una discrepancia produce `No key available with this passphrase`. Sin digest, no hay verificación.

**R5.2** — `mount` falló solo porque el número mágico del superbloque de ext4 no se descifró a un valor válido — un accidente de que el sistema de archivos tenga una cabecera reconocible. En un dispositivo crudo sin superbloque (un disco de Oracle ASM, un PV de LVM crudo, un dispositivo raw de base de datos, una partición de swap, una cabecera LVM en un offset inesperado), nada objetaría. Las escrituras hechas bajo la clave incorrecta se cifran con esa clave incorrecta y aterrizan sobre los datos reales; cada una de esas escrituras **destruye permanentemente** el texto plano subyacente, y el daño es silencioso e irreversible. Este es el mayor riesgo operativo del modo plain y la razón por la que LUKS debería ser el default para cualquier cosa donde una persona tipee una passphrase.

**R5.3** — Los parámetros del modo plain **no se registran en ningún lado**, así que son parte de la clave. Si dependés de los defaults, una actualización de `cryptsetup`, una distribución distinta, o un ISO de rescate con un build diferente derivará una clave distinta de la misma passphrase y tus datos se vuelven ilegibles — sin mensaje de error que explique por qué. La regla: para dm-crypt plain, especificá siempre `--cipher`, `--key-size`, `--hash`, `--offset`, `--skip` (y `--sector-size` donde corresponda) explícitamente, en cada invocación, y registrá esa línea de comandos exacta con el mismo cuidado que le das a la passphrase. Es efectivamente parte de la credencial.

**R5.4** — (i) **Swap cifrado y otros volúmenes efímeros** con clave desde `/dev/urandom` en cada arranque: sin cabecera que gestionar, sin clave que proteger, y la ausencia de persistencia es precisamente la propiedad deseada. (ii) **Volúmenes ocultos/negables y disposiciones esteganográficas**, donde el requisito es que el dispositivo sea byte a byte indistinguible de datos aleatorios — una cabecera LUKS se anunciaría sola. (iii) Interoperabilidad con disposiciones legadas o no-LUKS donde un sistema externo dicta el formato en disco (por ejemplo, abrir un volumen creado por otro SO, o un mapeo de offset fijo dentro de un contenedor mayor). (iv) Volúmenes de scratch tipo tmpfs en instancias cloud efímeras que se reformatean en cada arranque.

**R5.5** — El modo plain aplica **una** iteración de hash, así que un atacante que prueba passphrases candidatas paga esencialmente el costo de un SHA-512 por intento — miles de millones por segundo en una GPU. El keyslot Argon2id de LUKS2 aplica una derivación ajustable y memory-hard (en este laboratorio: 7 pasadas sobre 1 GiB con 4 hilos, ~2 s por intento en la CPU objetivo), así que el mismo atacante paga segundos y gigabytes de memoria de alto ancho de banda por intento, lo que no paraleliza barato en GPUs ni ASICs. La diferencia práctica frente a una passphrase de baja entropía es de muchos órdenes de magnitud. El modo plain solo es defendible cuando la "passphrase" es en sí misma una clave de entropía completa (por ejemplo, de `/dev/urandom`), donde el fortalecimiento del KDF es irrelevante.

### Ejercicio 6

**R6.1** — `sealed_dif` es la capa **dm-integrity** que se asienta directamente sobre `/dev/loop3`. Divide el dispositivo en sectores de datos más espacio de *tags* intercalado (y, por defecto, un journal), exponiendo un dispositivo virtual cuyos sectores llevan cada uno un tag de autenticación extra. `sealed` es la capa **dm-crypt** encima, corriendo un cifrado AEAD (`aes-gcm-random`): por cada sector produce texto cifrado más un tag de autenticación, escribe el texto cifrado en el área de datos y le entrega el tag a dm-integrity, que lo guarda en el área de tags. Al leer, dm-crypt le pide el tag a dm-integrity, lo verifica, y devuelve `-EILSEQ` (que aparece como un error de E/S y el mensaje de kernel `INTEGRITY AEAD ERROR`) si no coincide. Físicamente los tags viven en regiones de tags dedicadas intercaladas con los datos en el mismo dispositivo de respaldo, y por eso el tamaño utilizable bajó de 240 MiB a ~227 MiB.

**R6.2** — XTS es un modo *que preserva la longitud y no autentica*: cada sector de 512 o 4096 bytes se mapea exactamente a la misma cantidad de texto cifrado, sin espacio para un MAC. Cualquier texto cifrado, por lo tanto, "descifra" a *algún* texto plano, así que un atacante puede invertir bits, reemplazar o reproducir sectores y la capa superior recibe basura de apariencia plausible sin ningún error. Lo que XTS *sí* garantiza es que el atacante no tiene control sobre el texto plano resultante (el tweak hace que la transformación de cada bloque dependa de la posición, así que una modificación aleatoriza todo el bloque de 16 bytes) y que texto plano idéntico en offsets distintos produce texto cifrado distinto. Defiende la confidencialidad frente a un atacante pasivo; no ofrece nada contra un atacante **activo** que puede escribir en el disco — el clásico escenario de evil-maid parcheando el bootloader o invirtiendo bits en un archivo de configuración. El cifrado autenticado es lo que cierra eso.

**R6.3** — El journal significa que cada escritura se escribe **dos veces**: una al journal de integridad (datos o tags, según el modo) y otra a su ubicación final, reduciendo aproximadamente a la mitad el throughput secuencial de escritura y agregando latencia, más flushes extra. Existe para que una caída no pueda dejar un sector cuyos datos y tag no concuerden, lo que produciría un error de integridad permanente e irrecuperable en un sector por lo demás sano. `--integrity-no-journal` (o `--integrity-bitmap-mode`, que rastrea regiones sucias en vez de usar journal) es aceptable cuando una discrepancia inducida por caída es tolerable y se repara barato: en un dispositivo que se reescribe por completo tras cada apagado sucio, detrás de una caché de escritura respaldada por batería o capacitor que hace imposibles las escrituras rotas, o donde una capa superior (una base de datos replicada, un OSD de Ceph, un RAID con su propio mecanismo de consistencia) va a resincronizar los extents afectados igual. El modo bitmap es el término medio habitual.

**R6.4** — `--iter-time` es un *benchmark en la máquina que ejecuta el comando*: cryptsetup mide cuántas iteraciones (o cuánto trabajo Argon2) entran en el tiempo de reloj pedido **en esa CPU**, y registra los parámetros resultantes. Aprovisionar una imagen dorada en un servidor de build rápido de 32 núcleos con `--iter-time 2000` produce parámetros que tardan 2 s ahí pero podrían tardar 30–60 s en un appliance ARM de bajo consumo — convirtiendo el arranque en un timeout. Peor todavía, si el objetivo tiene menos RAM que el costo de memoria Argon2 registrado, el desbloqueo falla directamente con un error de falta de memoria. `--pbkdf-force-iterations` (con `--pbkdf-memory` y `--pbkdf-parallel`) fija los parámetros exactos independientemente de la máquina que construye, así que el costo es determinista en el objetivo. El mismo razonamiento aplica a la inversa: nunca dejes que una máquina lenta fije los parámetros para una flota rápida, o vas a subproteger la passphrase.

**R6.5** — Sí, todas las passphrases siguen funcionando. `cryptsetup reencrypt` genera una **clave maestra nueva**, reescribe toda el área de datos de texto cifrado con la clave vieja a texto cifrado con la nueva, y *re-envuelve esa nueva clave maestra dentro de cada keyslot activo existente* — así que cada passphrase, archivo de clave y token de Clevis sigue desbloqueando, pero ahora desenvuelve la clave maestra nueva. Esto es precisamente la indirección keyslot/clave maestra en acción: las credenciales están desacopladas de la clave de datos, así que la clave de datos puede rotarse sin tocar las credenciales. La evidencia visible es que cambió el digest de la clave maestra, que es también por qué todo backup de cabecera tomado antes del recifrado ahora es inútil — la respuesta más efectiva ante una sospecha de compromiso de la clave maestra o de un backup de cabecera.

**R6.6** — Una cabecera LUKS2 es convertible a LUKS1 solo si: (i) cada keyslot activo usa **PBKDF2**, no Argon2i/Argon2id (LUKS1 no soporta Argon2); (ii) **no hay tokens, ni segmento de integridad/AEAD, ni múltiples segmentos de datos, ni un recifrado en curso**, y no hay más de 8 keyslots — LUKS1 tiene exactamente 8 slots fijos; (iii) el **offset de datos y el tamaño de metadatos son compatibles**, es decir, la cabecera LUKS1 (típicamente 2 MiB de payload offset) debe entrar en el espacio disponible y la alineación resultante debe ser válida; un tamaño de sector de 4096 bytes también bloquea la conversión, ya que LUKS1 está fijado en 512. La motivación del mundo real es la **compatibilidad con el bootloader**: GRUB2 ganó soporte de LUKS2 en 2.06 pero solo para keyslots que usan PBKDF2 — el soporte de Argon2 llegó más tarde (2.12). Un `/boot` sobre LUKS por lo tanto requería históricamente LUKS1, y todavía hoy requiere o LUKS1 o LUKS2-con-PBKDF2 en cualquier sistema cuyo GRUB sea anterior a 2.12. La misma restricción aplica a algunos firmwares y entornos de rescate.

**R6.7** — `luksSuspend` congela toda la E/S al mapeo y **borra la clave de volumen de la memoria del kernel**, dejando en su lugar el dispositivo device-mapper y todos los montajes. Defiende contra ataques que leen la RAM de una máquina encendida pero desatendida: ataques DMA por Thunderbolt/PCIe/FireWire, extracción de memoria en frío (cold-boot), y adquisición forense de una laptop suspendida a RAM — en todos los cuales la clave estaría de otro modo residiendo en memoria del kernel. Sobre el sistema de archivos **raíz** es un bloqueo autoinfligido: `cryptsetup luksResume` necesita leer binarios, bibliotecas y posiblemente el archivo de clave del mismísimo sistema de archivos cuya E/S está congelada, así que el comando de reanudación se cuelga para siempre. El enfoque correcto es ejecutar el par suspender/reanudar desde un contexto completamente precargado y residente en memoria (un shell de initramfs, un binario enlazado estáticamente con todo bajo `mlock`, o la propia integración de suspensión de `systemd-cryptsetup` usada para suspend-then-hibernate), que es exactamente lo que hacen las distribuciones cuando borran claves al suspender.

### Ejercicio 7

**R7.1** — Tang publica un advertisement firmado que contiene una clave pública ECDH `S = sS·G`. Durante el bind, el **cliente** genera un par de claves efímero `(eC, EC = eC·G)`, computa el punto compartido `K = eC·S`, deriva de `K` la passphrase del keyslot LUKS, y después **descarta `eC` y `K`**, guardando solo `EC` (almacenado en el JWE dentro del token LUKS2). Tang nunca recibe `eC`, `K` ni la passphrase — solo vio que se le pedía su propia clave pública. Para recuperar, el cliente genera un `eR` efímero *fresco*, envía `EC + eR·G` a Tang, que multiplica por su `sS` privado y devuelve el resultado; el cliente resta `eR·S` (computable a partir del advertisement público) y recupera `K` exactamente. Tang ve solo un punto cegado y no aprende nada sobre `K` — este es el intercambio McCallum–Relyea, y es por eso que un servidor Tang no necesita estado por cliente, ni base de datos, ni confidencialidad de sus claves almacenadas más allá de la propia clave privada de firma/intercambio.

**R7.2** — Sin un thumbprint fijado, el cliente confía en el advertisement que reciba por HTTP plano. Un atacante capaz de interceptar, falsificar DNS o envenenar ARP en el camino al servidor Tang puede servir **su propio** advertisement; el cliente entonces vincula el keyslot a la clave del atacante. Más adelante, ese atacante puede descifrar el JWE a voluntad — es decir, puede desbloquear el disco desde cualquier lugar donde pueda presentar esa clave, y la vinculación es invisible en la operación normal porque todo parece funcionar. El thumbprint (`thp`) es el ancla de confianza que debe obtenerse fuera de banda — típicamente vía `tang-show-keys` ejecutado en el propio servidor Tang por SSH, y después incorporado a la gestión de configuración. Notá que HTTPS por sí solo no es la respuesta en la que se apoya Clevis; el thumbprint es el mecanismo diseñado, y protege incluso contra un transporte comprometido.

**R7.3** — NBDE ata la capacidad de descifrado a la **ubicación de red**: el disco se desbloquea solo donde puede alcanzar al servidor Tang. Por lo tanto aborda el **robo del medio físico** — una laptop robada, un disco sacado de un servidor dado de baja, una unidad devuelta por RMA, un chasis entero retirado del rack — porque fuera de la red el keyslot no puede recuperarse y no hay passphrase que sacarle a nadie por coerción. Explícitamente **no** aborda a un atacante que tenga alguna presencia en esa red o en el host: un host comprometido puede desbloquear su propio disco cuando quiera; cualquiera que pueda arrancar la máquina en la LAN confiable obtiene un disco descifrado; un insider malicioso con acceso al rack y a la red tiene capacidad completa; y no provee protección alguna mientras el sistema está corriendo. NBDE trata sobre reinicios desatendidos de máquinas *físicamente* protegidas, no sobre defender un host vivo.

**R7.4** — `"t":1` significa que **uno** cualquiera de los pins listados alcanza (un umbral 1 de 2), así que cualquiera de los servidores Tang por sí solo puede desbloquear — la configuración orientada a la disponibilidad, tolerando la caída de un servidor. `"t":2` requiere **ambos**, convirtiendo la política de redundancia a conjunción: eleva la barrera para un atacante (ambos servidores deben ser alcanzables y honestos) pero ahora cualquier caída individual bloquea el arranque por completo. `{"t":2,"pins":{"tang":[...],"tpm2":[...]}}` expresa "desbloqueá solo si la máquina está **tanto** en la red confiable **como** corriendo con el estado de PCR esperado del TPM" — es decir, ubicación correcta *y* cadena de arranque sin modificar. Esa combinación derrota tanto el robo de disco (sin red) como la manipulación evil-maid de firmware/bootloader (PCR distinto), a costa de no arrancar tras cualquier actualización legítima de firmware o bootloader hasta que el pin TPM se re-vincule con `clevis luks regen`.

**R7.5** — Cada cliente vinculado debe ejecutar `clevis luks report -d <dev> -s <slot>`, que detecta que el keyslot está vinculado a una clave que ya no se anuncia y ofrece re-vincular (`clevis luks regen -d <dev> -s <slot>` lo hace de forma no interactiva). El procedimiento de rotación es deliberadamente de dos fases: se *ocultan* las claves viejas renombrándolas a nombres de archivo que empiecen con `.` en `/var/db/tang` (por ejemplo, `mv /var/db/tang/OLD.jwk /var/db/tang/.OLD.jwk`) y se generan nuevas. Las claves ocultas **ya no se anuncian** para nuevas vinculaciones pero **siguen siendo usables para recuperación**, así que los clientes existentes continúan arrancando mientras los vas migrando. Si en cambio *borrás* las claves viejas, cada cliente todavía vinculado a ellas queda inmediata y permanentemente sin poder desbloquear vía Tang — caen a cualquier keyslot de passphrase que quede, y si no existe ninguno, los datos están perdidos. Borrá las claves viejas solo después de que `clevis luks report` confirme que todos los clientes se re-vincularon.

**R7.6** — `_netdev` es una directiva de ordenamiento de **systemd**, y systemd desde el sistema de archivos raíz todavía no está corriendo cuando el sistema de archivos raíz necesita ser desbloqueado. El desbloqueo de la raíz ocurre en el **initramfs**, que por lo tanto debe contener los binarios de Clevis, la biblioteca `jose`, un stack de red y una configuración de red DHCP/estática — más el hook `clevis-luks-askpass` que responde el prompt de contraseña del initramfs a partir de la vinculación con Tang. Eso significa regenerar el initramfs después de instalar los paquetes de integración de Clevis: `dracut -fv --regenerate-all` en RHEL/Fedora (con `clevis-dracut` instalado) o `update-initramfs -u -k all` en Debian/Ubuntu (con `clevis-initramfs`), y configurar el initramfs para levantar red (`ip=dhcp` en la línea de comandos del kernel, o `rd.neednet=1` para dracut). `_netdev` en `crypttab` sigue siendo correcto y necesario para volúmenes *no raíz* desbloqueados por red.

### Ejercicio 8

**R8.1** — eCryptfs escribe una **cabecera de 8192 bytes** (dos extents de 4096 bytes por defecto) al inicio de cada archivo, que contiene el marcador de formato, los flags, el tamaño original del archivo, el IV raíz, y la **FEK cifrada** envuelta por la FEKEK. El contenido después se cifra en extents de 4096 bytes, así que un archivo de 19 bytes pasa a ser 8192 (cabecera) + 4096 (un extent con padding) = 12288 bytes. Un atacante que solo tenga `.Private` igual aprende: la **cantidad de archivos y directorios**, la **estructura del árbol de directorios**, el **tamaño de cada archivo redondeado hacia arriba a la granularidad del extent** (que para archivos grandes es casi exacto), todas las **marcas de tiempo**, la **propiedad y los permisos**, los **patrones de acceso en el tiempo**, y la **longitud aproximada de cada nombre de archivo** (la longitud del nombre cifrado es una función determinista de la longitud del nombre en texto plano). Solo el contenido de los archivos y los caracteres de los nombres están protegidos.

**R8.2** — Tres claves, dos niveles de envoltura:
 - **FEK** (File Encryption Key) — una clave simétrica *aleatoria* generada por archivo, usada para cifrar el contenido de ese archivo. Se guarda, cifrada, dentro de la cabecera de 8 KiB de ese mismo archivo. Las claves por archivo son por qué los archivos de eCryptfs son individualmente portables y por qué hacer `rsync` de un solo archivo cifrado tiene sentido.
 - **FEKEK** (File Encryption Key Encryption Key) — la *mount passphrase*, derivada una vez e insertada en el keyring del usuario; envuelve cada FEK. Su firma de 8 dígitos hexadecimales es lo que aparece en `Private.sig` y en la opción de montaje `ecryptfs_sig=`.
 - **FNEK** (FileName Encryption Key) — usada para cifrar los nombres de archivo, produciendo el prefijo `ECRYPTFS_FNEK_ENCRYPTED.`; identificada por `ecryptfs_fnek_sig=`. Por defecto `ecryptfs-setup-private` usa la misma passphrase para ambas, de ahí las firmas idénticas en la salida del laboratorio.

 La **wrapped passphrase** (`~/.ecryptfs/wrapped-passphrase`) es la FEKEK cifrada con la passphrase de *login* del usuario. Ese es todo el punto del diseño: la passphrase de login no es en sí misma la FEKEK, así que cambiar la passphrase de login solo requiere re-envolver (barato) en lugar de recifrar cada archivo (imposible). `pam_ecryptfs` la desenvuelve en el login e inserta la FEKEK en el keyring de sesión.

**R8.3** —
 - `auth ... pam_ecryptfs.so unwrap` — captura la passphrase de login en texto plano durante la autenticación (el único momento en que está disponible) y la usa para desenvolver `wrapped-passphrase`, insertando la FEKEK en el keyring del kernel.
 - `session ... pam_ecryptfs.so unwrap` — al iniciar la sesión, realiza el `mount.ecryptfs_private` real de `~/.Private` sobre `~/Private` usando la clave puesta en el keyring; al cerrar la sesión desmonta y desaloja la clave.
 - `password ... pam_ecryptfs.so` — al **cambiar la passphrase**, re-envuelve la FEKEK con la *nueva* passphrase de login.

 Sacá la línea de `common-password` y los cambios de contraseña dejan de re-envolver: la FEKEK queda cifrada bajo la passphrase de login *vieja*. El usuario cambia su contraseña con éxito, cierra sesión, vuelve a entrar con la contraseña nueva — y `auth` falla al desenvolver, así que `~/Private` se monta vacío silenciosamente (o no se monta). Los datos siguen ahí y siguen siendo recuperables, pero **solo** con la passphrase de login vieja o con la mount passphrase registrada. Este es el incidente de pérdida de datos más común de eCryptfs.

**R8.4** — `pam_ecryptfs` necesita la **passphrase de login en texto plano** para desenvolver `wrapped-passphrase`, y la autenticación SSH por clave pública nunca la transmite ni la revela — `pam_sm_authenticate` de `pam_unix` queda completamente sorteado por `PubkeyAuthentication`, así que no hay nada que capturar. La sesión por lo tanto arranca con un keyring vacío y `~/Private` queda bloqueado (típicamente mostrando solo el stub `Access-Your-Private-Data.desktop`). Mitigaciones estándar: (i) que el usuario ejecute `ecryptfs-mount-private` manualmente después del login e ingrese la passphrase de forma interactiva; (ii) usar `ssh` con autenticación por contraseña o keyboard-interactive para las cuentas que necesitan el montaje automático; (iii) abandonar eCryptfs por usuario y pasar a **LUKS de disco completo**, que es exactamente la transición que hizo Ubuntu cuando deprecó el home cifrado en 18.04 — siendo el caso de clave SSH uno de los fallos que la motivaron.

**R8.5** —
 | Eje | eCryptfs | LUKS / dm-crypt |
 |---|---|---|
 | **Qué se oculta** | Solo el *contenido* de los archivos y los *nombres de archivo*. La estructura de directorios, la cantidad de archivos, los tamaños (a granularidad de extent), las marcas de tiempo, la propiedad y los permisos están todos a la vista. | Todo lo que está por encima de la capa de bloques: el sistema de archivos entero, incluyendo todos los metadatos, la estructura, la disposición del espacio libre y la cantidad de archivos. Solo la cabecera LUKS es texto plano. |
 | **Granularidad de la clave** | FEK por archivo, envuelta por una FEKEK por usuario. Usuarios distintos en la misma máquina tienen claves genuinamente independientes; un archivo puede compartirse junto con su clave. | Una clave maestra por volumen. Múltiples passphrases desbloquean la *misma* clave maestra — son credenciales, no claves separadas. Sin separación por usuario ni por archivo. |
 | **Dimensionamiento previo** | Ninguno. Se apila sobre un sistema de archivos existente y crece con él; no hay contenedor que dimensionar, ni redimensionamiento, ni espacio desperdiciado. | El contenedor es un dispositivo de bloque de tamaño fijo. Agrandarlo implica agrandar el dispositivo/partición/LV subyacente *y* `cryptsetup resize` *y* el sistema de archivos. |
 | **Backup con `rsync`** | Los archivos cifrados en `.Private` son sincronizables y restaurables individualmente — el backup incremental funciona naturalmente, y el destino del backup nunca ve texto plano. Cada archivo lleva su propia FEK envuelta, así que restaurar un solo archivo tiene sentido. | El mapeo debe estar *abierto* para respaldar archivo por archivo, lo que significa que el backup ve texto plano. Respaldar el contenedor cerrado implica copiar el dispositivo de bloque entero (o usar snapshots LVM + herramientas a nivel de bloque); los incrementales son gruesos y un solo byte cambiado ensucia un extent completo. |

 Resumen práctico: eCryptfs encaja en máquinas compartidas multiusuario, cifrado de homes por usuario, y escenarios de sincronización en la nube (cifrar localmente, sincronizar texto cifrado). LUKS encaja en protección de disco completo, robo de laptop, baja de equipos, y cualquier cosa donde la fuga de metadatos sea inaceptable. Se componen — LUKS abajo para los metadatos, eCryptfs o fscrypt arriba para separación de claves por usuario.

**R8.6** — `ecryptfs_passthrough=y` permite que **archivos sin cifrar sean leídos y escritos a través del montaje eCryptfs**: los archivos del directorio inferior que carecen de la cabecera de eCryptfs se pasan textualmente en lugar de producir un error. Existe para migración — montar un directorio existente e ir cifrando los archivos gradualmente. En un despliegue de directorios personales es un riesgo porque elimina la garantía de que todo bajo `~/Private` está cifrado: cualquier archivo escrito por un proceso que sortee el montaje superior, o cualquier archivo restaurado de un backup viejo, queda silenciosamente legible en el directorio inferior para siempre, sin advertencia y sin diferencia visible desde el lado del usuario. `ecryptfs-setup-private` por eso pone `=n`, para que el invariante "todo en `.Private` es texto cifrado" efectivamente se cumpla.

**R8.7** — Porque la **wrapped passphrase es la única copia de la FEKEK**, y está protegida por la passphrase de login del usuario. Si la passphrase de login se olvida, si `/etc/shadow` se restaura desde un backup inconsistente, si se saca la línea PAM de `password` y un cambio de contraseña desincroniza la envoltura (ver R8.3), o si `~/.ecryptfs/wrapped-passphrase` se pierde o se corrompe, entonces **cada archivo es irrecuperable** — no hay escrow de clave maestra, ni slot de recuperación, ni equivalente a un segundo keyslot LUKS. La mount passphrase cruda que imprime `ecryptfs-unwrap-passphrase` sortea todo eso: con ella, `ecryptfs-recover-private` puede montar `.Private` desde un entorno de rescate sin importar el estado de la cuenta. Registrarla offline antes de la puesta en producción es el único escrow que ofrece eCryptfs.

### Ejercicio 9

**R9.1** — fscrypt cifra el **contenido de los archivos** y los **nombres de archivo**, y nada más. Quedan a la vista: los **tamaños** de archivo (exactos, sin padding), las **marcas de tiempo** (atime/mtime/ctime/crtime), la **propiedad** (uid/gid), los **permisos y ACLs**, los **contadores de enlaces y números de inodo**, la **estructura de directorios y la cantidad de entradas**, los **atributos extendidos**, y el **mapa de asignación de bloques del sistema de archivos**. Escenario de fuga realista: un directorio cifrado de documentos médicos o legales donde el tamaño exacto en bytes de cada archivo, combinado con un corpus público de tamaños conocidos, permite identificar los documentos — el clásico ataque de correlación de tamaños. Otro: los patrones de mtime en un spool de correo cifrado revelan el momento y volumen de la comunicación, que para muchos modelos de amenaza es la parte interesante. Un tercero: la cantidad y distribución de tamaños de archivos de un árbol de trabajo `git` identifica el repositorio.

**R9.2** — La política de cifrado se guarda en el **inodo del directorio** y la heredan todos los archivos y subdirectorios creados adentro — se aplica al momento de crear el archivo, cuando se deriva la clave por archivo y se disponen los extents. El kernel no tiene mecanismo para cifrar retroactivamente extents ya escritos: hacerlo implicaría reescribir los datos de cada archivo y renombrar cada entrada bajo una clave nueva manteniendo la consistencia, que es una operación de reescritura a nivel de sistema de archivos que ext4 simplemente no implementa. `FS_IOC_SET_ENCRYPTION_POLICY` por lo tanto devuelve `ENOTEMPTY` en un directorio no vacío. La migración correcta es: crear un directorio cifrado nuevo y vacío, hacer `mv`/`cp` de los datos adentro, y después borrar de forma segura el original (lo que en un SSD significa que deberías haber cifrado a nivel de bloque desde el principio — los extents viejos en texto plano pueden sobrevivir en páginas flash no mapeadas).

**R9.3** — `padding:32` rellena los **nombres de archivo cifrados** hasta un múltiplo de 32 bytes antes de cifrar. El cifrado de nombres de archivo revela la longitud por naturaleza — AES-CTS preserva la longitud — así que sin padding el nombre cifrado divulga la longitud exacta del nombre en texto plano. Eso mitiga un ataque real: las longitudes de nombres en una disposición de directorio conocida (un árbol de fuentes, un Maildir de correo, el directorio de datos de una aplicación) actúan como una huella que identifica el contenido. El padding a 32 colapsa muchas longitudes distintas en el mismo bucket, a costa de nombres más largos en disco. Las opciones son 4, 8, 16 y 32; 32 es la más fuerte y el default de fscrypt.

**R9.4** —
 - **Las políticas v1** identifican la clave maestra por un *descriptor* de 8 bytes y la buscan en el **keyring de sesión** del proceso llamador (`@s`), con clave de tipo `logon` `fscrypt:<descriptor>`. Consecuencias: la clave es por keyring de proceso, así que todo proceso que quiera acceso debe tenerla en su propio keyring; no hay forma confiable de *sacar* la clave de todos los usuarios de una vez (`fscrypt lock` en v1 es un mejor esfuerzo y necesita `root` más purgar cachés); y cualquier usuario que pueda adivinar u obtener el descriptor e inyectar una clave puede atacar la política. v1 no tiene control de acceso real ni prueba de que la clave suministrada sea la correcta — una clave incorrecta produce basura en lugar de un error.
 - **Las políticas v2** identifican la clave maestra por un **identificador de 16 bytes que es un hash criptográfico de la clave misma**, y la clave se agrega a un keyring por **sistema de archivos** vía el ioctl `FS_IOC_ADD_ENCRYPTION_KEY`. Consecuencias: agregar una clave incorrecta se *detecta* (el identificador no va a coincidir); la clave es propiedad del sistema de archivos, no de un proceso, así que `FS_IOC_REMOVE_ENCRYPTION_KEY` la desaloja genuinamente e invalida todos los inodos cacheados de una vez; usuarios sin privilegios pueden agregar claves para su propio uso y el kernel lleva cuenta de los reclamos por usuario, así que la eliminación de un usuario no rompe la de otro; y las claves por archivo usan HKDF-SHA512 con un nonce por archivo en lugar de la derivación más débil de v1. v2 requiere kernel 5.4+ y es el default de `fscrypt(1)` hoy. **Usá v2** salvo que tengas que interoperar con un kernel más viejo.

**R9.5** — No, fscrypt solo no alcanza. Cifra únicamente *archivos dentro de directorios que marcaste explícitamente*, en sistemas de archivos que lo soportan. No puede cifrar: los metadatos y el journal del propio sistema de archivos, `/etc` y `/var` en el caso general (los directorios del sistema deben ser legibles en el arranque antes de que exista ninguna clave, y muchos contienen archivos creados por el instalador), la partición de **swap** (que ni siquiera es un sistema de archivos), las imágenes de hibernación, el kernel y el initramfs en `/boot`, ni ningún tipo de sistema de archivos sin soporte nativo de cifrado. Además filtra todos los metadatos listados en R9.1. El apilamiento correcto es **LUKS/dm-crypt por debajo para confidencialidad del dispositivo completo**, proveyendo la protección de metadatos y cubriendo swap y `/`, con **fscrypt encima** solo donde además necesitás separación de claves por usuario o por directorio — por ejemplo, directorios personales multiusuario donde querés que los datos de un usuario sigan bloqueados mientras otro está logueado, o un servidor compartido donde querés bloquear un directorio de proyecto sin desmontar nada. LUKS resuelve el robo del medio; fscrypt resuelve la separación entre usuarios en un sistema corriendo. Resuelven problemas distintos.

**R9.6** — Poné **LUKS2 con `--integrity`** (dm-integrity, como en el Ejercicio 6) por debajo del sistema de archivos ext4 que aloja las políticas de fscrypt. dm-integrity autentica cada sector del dispositivo de bloque, así que cualquier manipulación de los metadatos de ext4, de los xattrs de política de fscrypt, o de los extents cifrados de los archivos, se detecta y se reporta como un error de E/S — cerrando exactamente la brecha que fscrypt deja abierta. fscrypt sigue proveyendo claves por directorio y bloqueo por usuario por encima. Las alternativas son `dm-verity` (solo lectura, así que sirve para una imagen de sistema inmutable pero no para datos de usuario) o un sistema de archivos con checksums y autenticación nativos (los checksums de btrfs/ZFS detectan corrupción pero no manipulación *autenticada*, ya que un atacante que reescribe datos puede reescribir el checksum también — hace falta un MAC con clave, que es lo que provee dm-integrity en modo AEAD).

### Ejercicio 10

**R10.1** — El binario `cryptmount` se instala **setuid root**, y baja privilegios después de hacer solamente el trabajo específico que los requiere (crear el nodo device-mapper y llamar a `mount(2)`). La frontera de seguridad la impone el `cmtab`, que es propiedad de root y no escribible por el usuario: el campo `dir=` fija el punto de montaje y `dev=` fija el contenedor, así que alice solo puede montar el target exacto para el que fue nombrada en la ruta exacta que eligió el administrador. La compuerta adicional es la **propiedad del directorio de punto de montaje** — `cryptmount` requiere que el usuario que invoca sea dueño de `dir` (y, para `--change-password`, que conozca la contraseña existente), así que alice no puede montar el target de `bob` ni siquiera nombrándolo. Campos opcionales de `cmtab` ajustan esto todavía más: `passwdretries`, `supath` (el PATH usado mientras se está con privilegios), y restricciones por target. Como con cualquier binario setuid, el `cmtab` nunca debe ser escribible por no-root — eso sería una escalada directa a root.

**R10.2** — Sin `nosuid`, el kernel respeta el bit setuid en los ejecutables dentro del sistema de archivos montado. Alice controla el *contenido* de su contenedor por completo: puede crearlo, poner adentro un shell setuid-root propiedad de root (conseguir uno es fácil — copiar `/bin/bash` adentro, y después usar cualquier acceso breve a root, una imagen de contenedor, o simplemente fabricar la imagen ext4 offline con `debugfs`/`e2tools` y fijar los bits de modo y propietario directamente), después montarlo con `cryptmount -m` y ejecutarlo. Eso es un shell root local inmediato e incondicional. `nodev` cierra el agujero análogo con los nodos de dispositivo: un `/dev/sda` creado con `mknod` dentro de la imagen daría acceso crudo al disco. Todo sistema de archivos montable por el usuario debe llevar `nosuid,nodev` — y `noexec` también donde la carga de trabajo lo permita. Esta es la misma razón por la que `mount(8)` fuerza `nosuid,nodev` para las entradas `user`/`users` de `fstab`.

**R10.3** — Con `keyformat=luks` y `keyfile` apuntando al archivo contenedor mismo, el arreglo es exactamente un volumen LUKS estándar: la **cabecera LUKS (con sus keyslots) vive al principio del contenedor**, y `cryptmount` simplemente maneja el camino LUKS de `cryptsetup` — la passphrase desenvuelve un keyslot, que produce la clave maestra, que descifra el payload después de la cabecera. Todo está autocontenido en un archivo, lo que es portable y puede abrirse igualmente con `cryptsetup open` a secas. Con `keyformat=builtin` (u `openssl`/`openssl-compat`/`raw`) y un `keyfile=` *separado*, la clave maestra cifrada se guarda **fuera** del contenedor en el formato propio de archivo de clave de cryptmount, y el contenedor no contiene más que texto cifrado. Eso es efectivamente una cabecera separada: el contenedor se vuelve indistinguible de datos aleatorios (sin firma LUKS), y podés mantener el archivo de clave en un medio removible de modo que el contenedor sea inerte sin él — a costa de que perder el archivo de clave pierde los datos, y de que ya no podés abrir el volumen con `cryptsetup` de fábrica.

**R10.4** — Cuando **usuarios sin privilegios deben montar y desmontar sus propios contenedores cifrados bajo demanda**, sin `sudo`, sin una regla de polkit, y sin una sesión de systemd corriendo. `crypttab` + `systemd-cryptsetup` es fundamentalmente una facilidad del *sistema*: las entradas las define el administrador, la activación requiere privilegios de root, y está orientada a volúmenes de arranque y del ciclo de vida del sistema. `cryptmount` se escribió precisamente para el caso del servidor shell multiusuario — el administrador aprovisiona el target una vez en `cmtab`, y a partir de ahí el usuario gestiona el ciclo de vida por su cuenta. También funciona en sistemas sin systemd, y maneja el montaje y la criptografía en un único comando atómico de cara al usuario. Para cualquier cosa que deba levantar en el arranque, ser gestionada por gestión de configuración, o participar del grafo de dependencias de systemd, `crypttab` es la herramienta correcta.

### Ejercicio 11

**R11.1** — `umount /mnt/vault && cryptsetup close vault`. El mapeo no puede desarmarse mientras algo mantenga una referencia a él — un montaje, un descriptor de archivo abierto, una activación de swap, un PV de LVM, o un target device-mapper apilado. Para encontrar al que lo retiene: `lsof /mnt/vault` o `fuser -vm /mnt/vault` para procesos; `dmsetup info -c -o name,open` para ver la cuenta de aperturas sobre el mapeo mismo; `dmsetup ls --tree` para detectar un dispositivo apilado encima; y `lsblk /dev/mapper/vault` para ver montajes y holders. Si un proceso se niega a liberarlo, `umount -l` (lazy) desprende el árbol de inmediato y se completa cuando se cierra el último descriptor — pero notá que el mapeo sigue ocupado hasta entonces, así que `cryptsetup close` va a fallar igual justo después de un desmontaje lazy.

**R11.2** — Los keyslots de LUKS2 están limitados por el **tamaño del área de keyslots** en lugar de por una cantidad fija: cada slot debe alojar una copia de la clave maestra dividida con AF (stripes × longitud de clave, acá 4000 × 64 = 250 KiB, redondeado a los 258048 bytes de longitud de área que se ven en el volcado), así que el área de keyslots default de ~16 MiB acomoda **32 slots** con una clave de 512 bits — y menos si aumentás el tamaño de clave o la cantidad de stripes. La cantidad también está limitada a 32 por la especificación de LUKS2 sin importar el espacio disponible. LUKS1, en cambio, tiene exactamente **8 slots** cableados en una cabecera binaria de disposición fija con offsets de material de clave fijos; no hay forma de agregar un noveno. Las consecuencias prácticas: LUKS2 te da lugar para passphrases por administrador, varios archivos de clave, y slots de token de Clevis/TPM/FIDO2 en el mismo volumen; y en LUKS2 podés agrandar el área de keyslots al formatear con `--luks2-keyslots-size`.

**R11.3** — `[ACTIVE_LAST]` acá refleja el ordenamiento por prioridad: el slot 3 fue marcado `prefer` en el Ejercicio 2, así que cryptsetup lo intenta antes que los slots `normal`. Sin prioridades, cryptsetup prueba los slots en orden de índice hasta que uno tenga éxito. En un volumen con, digamos, seis slots Argon2id que cuestan ~2 s y 1 GiB de RAM cada uno, desbloquear con la credencial del slot 5 significa cinco derivaciones fallidas primero — aproximadamente **10 segundos de puro desperdicio** en cada arranque, más 1 GiB de presión de memoria por intento (lo que en un initramfs chico puede fallar de por sí). Poner `prefer` en el slot de la credencial de arranque e `ignore` en los slots de emergencia/recuperación elimina ambas cosas. Importa más exactamente donde más duele: reinicios desatendidos de appliances con memoria limitada.

**R11.4** — En orden:
 1. **¿Está la cabecera intacta y legible?** `cryptsetup isLuks -v /dev/sdX` y `cryptsetup luksDump /dev/sdX`. Si el volcado imprime una versión, UUID, cifrado y al menos un keyslot activo razonables, la cabecera está estructuralmente bien y el problema está en otro lado — pasá al paso 2. Si falla, verificá si la ruta del dispositivo es siquiera correcta (`lsblk`, `blkid`) antes de concluir que hay daño.
 2. **¿La credencial misma sigue verificando?** `cryptsetup open --test-passphrase --verbose /dev/sdX` (agregá `--key-file` para archivos de clave). Esto separa "credencial incorrecta" de "no se puede activar". Si hay un archivo de clave involucrado, acá es donde aparece la trampa de R2.4 — compará el `sha256sum` del archivo de clave contra un valor conocido bueno y confirmá que `keyfile-size`/`keyfile-offset` coincidan con lo que especifica `crypttab`. `Key slot N unlocked` acá significa que la criptografía está bien y el fallo está en la activación.
 3. **¿Puede el kernel proveer el cifrado?** `cryptsetup --debug open ...` y fijate dónde se detiene; `dmsetup targets` para confirmar que `crypt` está presente; `modprobe dm_crypt` más los módulos de cifrado específicos; `cat /proc/crypto | grep -A2 xts`; y `journalctl -k | grep -i crypt`. Una actualización de kernel que dejó afuera un módulo (o un kernel en modo FIPS rechazando un cifrado no aprobado, o un `aes_generic`/`xts`/`sha256` faltante en un initramfs recortado) produce exactamente el síntoma reportado — la passphrase se acepta, después la activación falla y la herramienta vuelve a preguntar. Verificá también si el *initramfs* se regeneró después de la actualización, que es la causa raíz más común.

 Recién después de los tres pasás al backup de cabecera.

**R11.5** — `cryptsetup open` sobre `/dev/loop3` fallaría con `Cannot use device /dev/loop3, name is invalid or still in use` (o `Device or resource busy`), porque el mapeo de integridad huérfano `sealed_dif` todavía mantiene un reclamo exclusivo sobre el dispositivo de respaldo — cryptsetup abre la fuente con `O_EXCL` y el reclamo sigue vivo aunque el dispositivo crypt de nivel superior ya no esté. Limpialo eliminando el remanente explícitamente: `dmsetup remove sealed_dif` (o `cryptsetup close sealed_dif`), verificá con `dmsetup ls --tree` que no quede nada, y después reabrí normalmente. La lección general es que **los dispositivos device-mapper apilados deben desarmarse de arriba hacia abajo**; `cryptsetup close` en un volumen LUKS2 protegido con integridad elimina ambas capas por vos, que es exactamente por qué deberías usarlo en lugar de `dmsetup remove` sobre los targets individuales.

### Ejercicio 12

**R12.1** — Verificá que **al menos otra credencial sea conocida-buena y esté probada** en ese volumen antes de borrar el archivo de clave — ejecutá `cryptsetup open --test-passphrase /dev/sdX` con la passphrase interactiva (o con un segundo archivo de clave) y confirmá que devuelve éxito, y chequeá que `cryptsetup luksDump` muestre más de un keyslot activo. Confirmá también que nada automatizado (una entrada de `crypttab`, un rol de Ansible, un job de backup) siga apuntando al archivo que estás por eliminar. Si te equivocás y ese archivo de clave era la **única** credencial de un keyslot activo: mientras el volumen siga **abierto**, podés recuperarte por completo — `cryptsetup luksDump --dump-volume-key /dev/sdX` no está disponible sin una credencial, pero `cryptsetup luksHeaderBackup` más, críticamente, extraer la clave de volumen del mapeo en ejecución (`dmsetup table --showkeys` si la clave no está en el keyring, o `cryptsetup luksDump --dump-master-key` con cualquier credencial que funcione) te permite volver a agregar un keyslot con `cryptsetup luksAddKey --master-key-file`. Una vez que el volumen está **cerrado**, sin ningún keyslot recuperable, los datos se perdieron — no hay camino de recuperación, que es la misma propiedad de crypto-shredding de R3.4 trabajando en tu contra. En producción, borrá material de clave solo después de un respaldo verificado, y mantené una passphrase de emergencia offline en un slot marcado con `--priority ignore`.

**R12.2** — Llamar a `cryptsetup close vault` mientras `/mnt/vault` sigue montado falla con `Device vault is still in use` y estado de salida 5, porque el sistema de archivos montado mantiene una referencia abierta sobre `/dev/mapper/vault` (`dmsetup info -c -o open` mostraría `1`). No se daña nada — el mapeo permanece activo y los datos consistentes — pero el script de desarme deja estado atrás silenciosamente, y el `losetup -D` siguiente también falla (o, peor, en algunos kernels desasociar un loop device todavía reclamado por un mapeo activo deja un target device-mapper colgando cuyo almacenamiento de respaldo desapareció, produciendo errores de E/S y un mapeo que no se puede eliminar limpiamente). La regla es que el stack se desarma en orden inverso a como se construyó: **sistema de archivos → device-mapper → loop/dispositivo de respaldo**, y cada paso debería verificarse (`findmnt`, `dmsetup ls`, `losetup -a`) en lugar de darse por sentado.

</details>