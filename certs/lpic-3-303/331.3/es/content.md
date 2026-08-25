# Sistemas de archivos cifrados

**LPIC-3 303-300 (Security), Tema 331.3 — Criptografía**
Público: arquitectos de plataforma y SRE que tienen que responder, en una revisión post-incidente, la pregunta *«el disco salió del datacenter — ¿qué obtuvo el atacante?»*

---

## 0. Mapa de objetivos

El conjunto oficial de objetivos lo publica LPI; la redacción de abajo es una paráfrasis para navegar el estudio, y el texto autoritativo vive en la URL de [§15](#15-referencias).

| Área de conocimiento | Dónde se cubre acá |
|---|---|
| Entender cifrado de dispositivo de bloque vs. de sistema de archivos | [§1](#1-el-problema-en-producción), [§2](#2-dónde-cifrar-las-cuatro-capas) |
| `dm-crypt` con LUKS1 y LUKS2 | [§3](#3-interioridades-de-dm-crypt), [§4](#4-el-formato-luks-en-disco), [§5](#5-runbook-operativo-de-cryptsetup) |
| `dm-crypt` plano (sin cabecera) | [§3.6](#36-dm-crypt-plano-el-modo-sin-cabecera) |
| Características de LUKS2: integridad, tokens, requisitos, recifrado en línea | [§5.9–5.11](#59-convertir-luks1--luks2), [§6](#6-integridad-dm-integrity-y-cifrado-autenticado) |
| `/etc/crypttab`, `systemd-cryptsetup`, `systemd-cryptenroll` | [§7](#7-desbloqueo-en-el-arranque-crypttab-systemd-y-el-initramfs) |
| eCryptfs, directorios home, integración con PAM | [§8](#8-ecryptfs-cifrado-apilado-por-archivo) |
| Conocimiento general de otras soluciones | [§9](#9-cifrado-nativo-del-sistema-de-archivos-conocimiento-general), [§10](#10-cifrado-apilado-en-espacio-de-usuario-y-cryptmount) |
| Términos: `cryptsetup`, `cryptmount`, `/etc/crypttab`, `ecryptfs-*`, `mount.ecryptfs`, `umount.ecryptfs`, `pam_ecryptfs`, `systemd-cryptenroll` | [§13 chuleta](#13-trampas-del-examen-y-chuleta-de-comandos) |

---

## 1. El problema en producción

### 1.1 El cifrado en reposo es un *modelo de amenaza*, no una casilla que marcar

Todo marco de cumplimiento pide «cifrado en reposo» y todo proveedor cloud responde «listo, ciframos todos los volúmenes». Ambas afirmaciones son ciertas y ambas son casi inútiles a menos que se nombre al adversario. El cifrado de disco defiende exactamente contra una clase de ataque: **un adversario que obtiene el medio de almacenamiento en un estado en el que la clave no está presente.**

| Amenaza | ¿Lo derrota el cifrado de disco completo (LUKS)? | Notas |
|---|---|---|
| NVMe dado de baja y vendido en eBay | **Sí** | El caso canónico. También derrota las devoluciones RMA de discos fallados. |
| Robo en el datacenter de un servidor apagado | **Sí** | El material de clave solo existe en RAM mientras está desbloqueado. |
| Robo en el datacenter de un servidor **en ejecución** | No | La clave maestra está en memoria del kernel; aplican ataques de cold-boot / DMA. `cryptsetup luksSuspend` reduce esta ventana. |
| Hipervisor / operador cloud leyendo tu almacenamiento de bloque | **Sí**, si ciframos *dentro* del guest | El cifrado del lado del proveedor (EBS/PD por defecto) es transparente para el proveedor. |
| Compromiso de root en el host en ejecución | No | El sistema de archivos está montado y en claro para cualquier proceso con las credenciales adecuadas. |
| Contenedor de otro tenant escapando hacia tu nodo | No | Misma alcanzabilidad de namespace de montaje; usá claves por carga de trabajo o criptografía a nivel de sistema de archivos. |
| Backend de almacenamiento malicioso invirtiendo bits en silencio | **No** con LUKS a secas (XTS es maleable) | Necesita `dm-integrity` / AEAD — [§6](#6-integridad-dm-integrity-y-cifrado-autenticado). |
| Cintas de backup / snapshots en object store | Solo si la ruta de backup también transporta texto cifrado | Los snapshots a nivel de bloque de un dispositivo *desbloqueado* están en claro. |
| Un usuario leyendo el `$HOME` de otro usuario | No con LUKS (una clave por dispositivo) | Este es el caso de uso de eCryptfs / fscrypt. |

La consecuencia arquitectónica: **la capa en la que ciframos determina cuáles de esas filas obtenemos.** Un único dispositivo LUKS «ciframos todo» te da las filas 1–4 y nada más. Eso suele ser el primer movimiento correcto y casi nunca la respuesta completa.

### 1.2 El problema real es la custodia de las claves

La criptografía está resuelta. Lo que se rompe en producción es el ciclo de vida de la clave:

- Un volumen LUKS que necesita una passphrase interactiva no puede sobrevivir a un reinicio desatendido a las 03:00. Una flota de 400 nodos no se puede cuidar a mano.
- Un keyfile guardado en el mismo `/boot` sin cifrar es teatro.
- Una clave sellada en TPM ligada al PCR 7 se negará a desellarse tras una actualización de firmware — convirtiendo un parcheo rutinario de BIOS en una caída de toda la flota.
- Una clave custodiada solo en la cabeza de dos SRE está a un bus-factor de ser datos irrecuperables.

Cada diseño de este material se juzga sobre los mismos tres ejes: **quién puede desbloquear (disponibilidad), quién no (confidencialidad), y qué pasa cuando la ruta de desbloqueo se rompe (recuperabilidad).**

### 1.3 El escenario de producción de referencia usado en todo el material

Un pool de workers de Kubernetes en bare-metal:

```
/dev/sda        480G  SATA SSD   — OS: /boot (plain), LUKS2 → LVM → /, swap
/dev/nvme0n1    3.5T  NVMe       — LUKS2 → XFS  — container runtime + local PVs
/dev/nvme1n1    3.5T  NVMe       — LUKS2 → XFS  — PostgreSQL data (integrity-protected)
```

Política de desbloqueo: clave sellada con TPM2 para el disco del sistema operativo (política PCR 7 + PCR 14), ligada a la red (Tang) para los discos de datos, claves de recuperación impresas en una caja fuerte, y un keyslot para la passphrase de guardia. Nada lo desbloquea nunca una persona en un arranque normal; toda ruta de desbloqueo tiene un fallback documentado.

---

## 2. Dónde cifrar: las cuatro capas

```
 ┌───────────────────────────────────────────────────────────────┐
 │ 4. Application     pgcrypto, age, restic, sops, client-side   │  per-record keys
 ├───────────────────────────────────────────────────────────────┤
 │ 3. Stacked FS      eCryptfs, gocryptfs/EncFS (FUSE)           │  per-file, per-user
 ├───────────────────────────────────────────────────────────────┤
 │ 2. Native FS       fscrypt (ext4/f2fs), ZFS native, UBIFS     │  per-directory
 ├───────────────────────────────────────────────────────────────┤
 │ 1. Block device    dm-crypt / LUKS, dm-integrity, SED/OPAL    │  whole volume
 ├───────────────────────────────────────────────────────────────┤
 │ 0. Hardware        self-encrypting drive firmware             │  opaque, untrusted
 └───────────────────────────────────────────────────────────────┘
```

### 2.1 Matriz de compromisos

| Propiedad | dm-crypt/LUKS (bloque) | fscrypt (FS nativo) | eCryptfs (apilado) | gocryptfs (FUSE) | Aplicación |
|---|---|---|---|---|---|
| Granularidad | Dispositivo de bloque completo | Árbol por directorio | Árbol por directorio | Árbol por directorio | Por campo / por objeto |
| Cifra el **contenido** de los archivos | Sí | Sí | Sí | Sí | Sí |
| Cifra los **nombres de archivo** | Sí (todo el FS es opaco) | Sí | Opcional (`ecryptfs_fnek_sig`) | Sí | n/a |
| Cifra los **metadatos** (tamaños, mtimes, estructura de directorios) | Sí | **No** | No (cabecera por archivo, el tamaño se filtra) | No | n/a |
| Cifra el **espacio libre / disposición del FS** | Sí | No | No | No | No |
| Múltiples claves independientes sobre un mismo FS | No (una clave maestra) | **Sí** | **Sí** (por usuario) | Sí | Sí |
| Funciona sobre almacenamiento de red/compartido (NFS, S3) | No (necesita un dispositivo de bloque) | No | Históricamente sí, frágil | **Sí** | Sí |
| En kernel o en espacio de usuario | Kernel (device-mapper) | Kernel (VFS) | Kernel (VFS apilado) | Espacio de usuario (FUSE) | Espacio de usuario |
| Costo típico de rendimiento | 2–8% con AES-NI | ~5% | 20–40% | 30–60% | Varía |
| Redimensionar / crecer en línea | Sí (`cryptsetup resize`) | Sigue al FS | Sigue al FS inferior | Sigue al FS inferior | n/a |
| Integridad / detección de manipulación | Opcional (`--integrity`) | No (solo contenido) | No | Sí (GCM por bloque) | Depende |
| Sobrevive al snapshot/replicación del texto cifrado | Sí | Sí | Sí | Sí | Sí |
| Historia de desbloqueo desatendido en el arranque | Madura (TPM2, Tang, tokens) | Manual / PAM | PAM | Manual | n/a |
| Relevancia para el examen (303-300) | **Primaria** | Conocimiento general | **Primaria** | Conocimiento general | Conocimiento general |

### 2.2 La regla práctica

> **Cifrá el dispositivo de bloque para la amenaza del «disco robado». Agregá una clave a nivel de sistema de archivos o de aplicación para la amenaza del «otro tenant / otro usuario / otro servicio». No son alternativas — los sistemas en producción corren ambas.**

La razón por la que la gente se equivoca acá es que el cifrado de bloque es *invisible*: una vez desbloqueado, `/srv/data` se ve exactamente igual que un `/srv/data` sin cifrar, lo que hace que se sienta como más protección de la que es. eCryptfs y fscrypt son visibles — los datos de cada usuario son ilegibles para los otros usuarios incluso en una máquina en ejecución — y por eso existen a pesar de ser estrictamente peores ocultando la disposición.

---

## 3. Interioridades de dm-crypt

### 3.1 Es un target de device-mapper, nada más

`dm-crypt` es un target de device-mapper del kernel que mapea un dispositivo de bloque virtual sobre uno físico, cifrando al escribir y descifrando al leer, **sector por sector, sin expansión**. El sector *n* del dispositivo en claro se mapea al sector *n + offset* del dispositivo cifrado, siempre del mismo tamaño. Esto es lo que lo hace transparente para todo sistema de archivos — y lo que prohíbe etiquetas de autenticación por sector sin una segunda capa ([§6](#6-integridad-dm-integrity-y-cifrado-autenticado)).

La tabla de mapeo es toda la interfaz:

```
$ sudo dmsetup table pgdata
0 7501344768 crypt aes-xts-plain64 :64:logon:cryptsetup:9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77-d0 0 259:1 32768 4 sector_size:4096 no_read_workqueue no_write_workqueue iv_large_sectors
```

Campo por campo:

| Campo | Valor | Significado |
|---|---|---|
| start / length | `0 7501344768` | Sectores lógicos del dispositivo mapeado (unidades de 512 bytes) |
| target | `crypt` | El target de dm |
| especificación de cifrado | `aes-xts-plain64` | `<cipher>-<chainmode>-<ivmode>` |
| clave | `:64:logon:cryptsetup:<uuid>-d0` | **Descripción de la clave en el keyring del kernel**, no la clave |
| iv offset | `0` | Valor sumado al número de sector antes de derivar el IV |
| dispositivo | `259:1` | major:minor de `/dev/nvme1n1` |
| offset | `32768` | Los datos empiezan a 32768×512 B = **16 MiB** dentro del dispositivo (cabecera LUKS2) |
| opts | `sector_size:4096 …` | Banderas de rendimiento/comportamiento |

Notá que la clave es una referencia al keyring (tipo `logon`). Kernels antiguos y `--disable-keyring` ponen la clave maestra en hexadecimal crudo en la tabla, donde `dmsetup table --showkeys` — y cualquier cosa que lea estado adyacente a `/proc` como root — podía leerla. El `cryptsetup` moderno la mantiene en el keyring del kernel:

```
$ sudo dmsetup table --showkeys pgdata | awk '{print $5}'
:64:logon:cryptsetup:9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77-d0
$ sudo keyctl search @u logon cryptsetup:9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77-d0
  # key exists but its payload is not readable from userspace
```

### 3.2 Anatomía de la especificación de cifrado

`aes-xts-plain64` se descompone como **cipher – modo de encadenamiento – modo de IV**:

- **`aes`** — el cifrador de bloque. Alternativas compiladas en la API criptográfica del kernel: `serpent`, `twofish`, `camellia`, y el cifrador de flujo `chacha20`. Cualquier cosa con AES-NI o las ARMv8 Crypto Extensions hace de AES el único default sensato; sin AES por hardware, `chacha20-poly1305` o `serpent` se vuelven genuinamente competitivos.
- **`xts`** — XTS-AES, estandarizado en NIST SP 800-38E, es un modo *tweakable de bloque angosto* diseñado exactamente para almacenamiento: no necesita almacenar un nonce por sector y es determinista por (clave, sector). Consume **dos claves**, así que `--key-size 512` significa AES-256-XTS, no AES-512. Esta es la lectura errónea más común de la salida de `cryptsetup`.
- **`plain64`** — cómo el número de sector se convierte en el tweak/IV: el número de sector de 64 bits en little-endian, rellenado con ceros.

| Modo de IV | Descripción | Uso |
|---|---|---|
| `plain` | Número de sector de 32 bits | Legado; se desborda a los 2 TiB → **nunca usar en volúmenes grandes** |
| `plain64` | Número de sector de 64 bits | **Default actual**, correcto para XTS |
| `plain64be` | Variante big-endian | Interoperabilidad con algunos appliances |
| `essiv:sha256` | IV = E(hash(clave), sector) — oculta el número de sector frente a ataques de watermarking en CBC | Solo tiene sentido con CBC; obsoleto con XTS |
| `benbi` | Conteo de bloques angostos en big-endian | Se usa con LRW |
| `null` | IV = 0 | Solo compatibilidad con Loop-AES |
| `random` | IV aleatorio almacenado por dm-integrity | Requerido para el modo AEAD `aes-gcm-random` |
| `eboiv`, `elephant` | Compatibilidad con BitLocker (`cryptsetup-bitlk`) | Leer volúmenes BitLocker |

**Por qué XTS y no CBC o GCM:** CBC sobre un sector permite watermarking y ataques de texto en claro controlado a menos que el IV sea impredecible (`essiv`), y propaga la corrupción. GCM no puede usarse *sin* almacenar un nonce y una etiqueta, lo que no cabe en un mapeo del mismo tamaño — de ahí [§6](#6-integridad-dm-integrity-y-cifrado-autenticado).

**Lo que XTS no te da:** es determinista y no autenticado. Un texto en claro idéntico escrito en el mismo sector produce siempre un texto cifrado idéntico, así que un atacante con dos snapshots del texto cifrado aprende exactamente qué sectores cambiaron. Y un atacante puede invertir bits del texto cifrado: el bloque de texto en claro correspondiente se convierte en basura, pero la escritura *tiene éxito* y el sistema de archivos puede actuar sobre esa basura. Confidencialidad sí; integridad no.

### 3.3 Tamaño de sector

La unidad de cifrado de dm-crypt es por defecto de 512 bytes. En discos 4Kn y en cualquier SSD moderno, `--sector-size 4096` reduce el número de operaciones criptográficas 8× por cada bloque de 4 KiB del sistema de archivos y mejora el rendimiento de forma medible.

| Tamaño de sector | Compatibilidad | Rendimiento | Restricción |
|---|---|---|---|
| 512 | Universal, en la práctica la única opción para LUKS1 | Línea base | — |
| 1024/2048 | Raro | Intermedio | — |
| **4096** | LUKS2, kernel ≥ 4.12 | +10–30% en NVMe | El tamaño de bloque lógico del dispositivo debe dividirlo; cambiarlo después exige recifrado |

Combinalo con `--integrity` y 4096 se vuelve efectivamente obligatorio, porque las etiquetas por cada 512 bytes desperdician muchísimo espacio.

### 3.4 El problema de las workqueues (una mejora real en producción)

Por defecto dm-crypt empuja cada E/S a través de workqueues del kernel por CPU (`kcryptd`). En discos rotacionales eso desacopla la criptografía del hilo que envía y ayuda. En NVMe es latencia añadida pura y un cuello de botella de planificación — Cloudflare documentó una recuperación de ~2× en rendimiento evitándolas, y las banderas llegaron a upstream en el kernel 5.9.

```
$ sudo cryptsetup --perf-no_read_workqueue --perf-no_write_workqueue \
    --persistent open /dev/nvme1n1 pgdata
```

| Bandera | Opción de crypttab | Efecto | Cuándo |
|---|---|---|---|
| `--perf-same_cpu_crypt` | `same-cpu-crypt` | Cifra en la CPU que envió la E/S | NUMA con muchos núcleos, localidad de caché |
| `--perf-submit_from_crypt_cpus` | `submit-from-crypt-cpus` | Evita un cambio de contexto al enviar | Con `same_cpu_crypt` |
| `--perf-no_read_workqueue` | `no-read-workqueue` | Descifra en línea en el contexto que envía | **NVMe / baja latencia** |
| `--perf-no_write_workqueue` | `no-write-workqueue` | Cifra en línea, envía de forma síncrona | **NVMe / baja latencia** |
| `--perf-high_priority` | `high-priority` | Workqueues de alta prioridad + nice del hilo de IO (cryptsetup ≥ 2.7) | Sensible a la latencia |
| `--allow-discards` | `discard` | Pasa TRIM al dispositivo subyacente | **Ver advertencia abajo** |

`--persistent` escribe esas banderas en la cabecera LUKS2 para que las aperturas posteriores las hereden — una característica exclusiva de LUKS2 y una de las mejores razones para convertir desde LUKS1.

**Advertencia sobre TRIM.** `--allow-discards` filtra el *patrón de bloques asignados* a cualquiera que pueda leer el dispositivo crudo — el mapa de usado/libre del sistema de archivos, en claro. También debilita la negabilidad en configuraciones sin cabecera. En SSD empresariales con sobreaprovisionamiento adecuado, dejarlo apagado cuesta poco; en NVMe de consumo baratos bajo carga de escritura sostenida, dejarlo apagado cuesta mucho. Decidí deliberadamente y registrá la decisión.

### 3.5 Adónde se va realmente la CPU

```
$ cryptsetup benchmark
# Tests are approximate using memory only (no storage IO).
PBKDF2-sha1      2071040 iterations per second for 256-bit key
PBKDF2-sha256    2551808 iterations per second for 256-bit key
PBKDF2-sha512    1069056 iterations per second for 256-bit key
PBKDF2-ripemd160  959488 iterations per second for 256-bit key
PBKDF2-whirlpool  703488 iterations per second for 256-bit key
argon2i       4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
argon2id      4 iterations, 1048576 memory, 4 parallel threads (CPUs) for 256-bit key (requested 2000 ms time)
#     Algorithm |       Key |      Encryption |      Decryption
        aes-cbc        128b      1017.5 MiB/s     3441.2 MiB/s
    serpent-cbc        128b        92.3 MiB/s      664.7 MiB/s
    twofish-cbc        128b       207.4 MiB/s      391.6 MiB/s
        aes-cbc        256b       780.4 MiB/s     2707.6 MiB/s
    serpent-cbc        256b        94.6 MiB/s      666.7 MiB/s
    twofish-cbc        256b       219.9 MiB/s      391.5 MiB/s
        aes-xts        256b      2733.6 MiB/s     2728.2 MiB/s
    serpent-xts        256b       621.4 MiB/s      616.3 MiB/s
    twofish-xts        256b       374.9 MiB/s      380.1 MiB/s
        aes-xts        512b      2288.9 MiB/s     2286.4 MiB/s
    serpent-xts        512b       631.9 MiB/s      617.2 MiB/s
    twofish-xts        512b       381.6 MiB/s      381.9 MiB/s
```

Leelo así: **AES-256-XTS cuesta alrededor de 2,3 GB/s por núcleo en esta máquina.** Un NVMe Gen4 de 7 GB/s saturará ~3 núcleos bajo carga secuencial. Confirmá que AES-NI está realmente en uso antes de creerle a los números:

```
$ grep -o -m1 -E 'aes|vaes' /proc/cpuinfo | sort -u
aes
vaes
$ grep -A4 'name *: *xts(aes)' /proc/crypto | head -12
name         : xts(aes)
driver       : xts-aes-aesni
module       : aesni_intel
priority     : 401
refcnt       : 3
```

Si `driver` muestra `xts(ecb(aes-generic))` estás corriendo AES por software y el rendimiento será aproximadamente 10× peor.

### 3.6 dm-crypt plano: el modo sin cabecera

El modo plano no almacena **nada** en disco: sin cabecera, sin salt, sin keyslots, sin UUID. La clave se deriva directamente de la passphrase mediante un hash simple (por defecto `ripemd160` históricamente, `sha256` en compilaciones modernas — especificalo siempre explícitamente).

```
$ sudo cryptsetup open --type plain \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --offset 0 --skip 0 \
    /dev/sdb1 plainvol
Enter passphrase for /dev/sdb1:
$ sudo cryptsetup status plainvol
/dev/mapper/plainvol is active.
  type:    PLAIN
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: dm-crypt
  device:  /dev/sdb1
  sector size:  512
  offset:  0 sectors
  size:    2097152 sectors
  mode:    read/write
```

| | dm-crypt plano | LUKS |
|---|---|---|
| Metadatos en disco | Ninguno — indistinguible de datos aleatorios | Cabecera de 16 MiB (LUKS2) |
| Cambio de passphrase | Imposible (habría que recifrar todo) | `luksChangeKey`, instantáneo |
| Múltiples passphrases | No | Hasta 8 (LUKS1) / 32 (LUKS2) |
| Estiramiento de clave | Un solo hash — **fuerza bruta viable** | PBKDF2 / Argon2id |
| Recuperación ante un parámetro equivocado | Basura silenciosa, sin error | "No key available with this passphrase." |
| Riesgo de pérdida de cabecera | Ninguno | Pérdida de cabecera = pérdida total de datos |
| Borrado antiforense de claves | n/a | Divisor AF |
| Caso de uso | Negabilidad, swap con clave aleatoria, embebidos | **Todo lo demás** |

El único uso inequívoco del modo plano en producción es el **swap con clave aleatoria**, donde la clave se regenera en cada arranque desde `/dev/urandom` y nadie necesita volver a desbloquearlo jamás ([§7.6](#76-swap-cifrado-y-la-trampa-de-la-hibernación)). Su otro uso — la negabilidad plausible — depende de acertar `--cipher`, `--key-size`, `--hash`, `--offset` y `--skip` exactamente de memoria, y una sola discrepancia produce basura en silencio en lugar de un error. Tratalo como un tiro en el pie, no como una característica.

---

## 4. El formato LUKS en disco

LUKS resuelve las dos cosas que el modo plano no puede: **gestión de claves** (múltiples passphrases, rotación, revocación) y **autodescripción** (los parámetros viven con los datos). Lo hace con una indirección: los datos se cifran con una **clave maestra** generada aleatoriamente, y cada passphrase simplemente desenvuelve una copia de esa clave maestra almacenada en un keyslot.

```
passphrase ──PBKDF(salt, cost)──► key encryption key ──decrypt──► keyslot ──AF-merge──► MASTER KEY
                                                                                          │
                                                                      dm-crypt table ◄────┘
```

Consecuencias que hay que interiorizar:

- Cambiar una passphrase nunca toca los datos. Reenvuelve un keyslot.
- Borrar un keyslot revoca esa passphrase, no los datos.
- **Cualquiera que alguna vez tuvo la clave maestra conserva el acceso para siempre**, sin importar los cambios de keyslot. La revocación real tras la exposición de la clave maestra exige recifrado ([§5.11](#511-rotación-de-la-clave-maestra-recifrado)).
- Perder la cabecera lo pierde todo, incluso con una passphrase correcta. Hacé backup de la cabecera.

### 4.1 Disposición de LUKS1

```
offset 0      ┌──────────────────────────────────────────────┐
              │ magic "LUKS\xba\xbe", version=1              │
              │ cipher-name, cipher-mode, hash-spec          │
              │ payload-offset, key-bytes                    │
              │ mk-digest, mk-digest-salt, mk-digest-iter    │
              │ uuid                                         │
              │ keyslot[0..7]: active, iterations, salt,     │
              │                key-material-offset, stripes  │
       592 B  ├──────────────────────────────────────────────┤
              │ key material area 0  (AF-split master key)   │
              │ key material area 1                          │
              │ ... 8 slots ...                              │
   ~2 MiB     ├──────────────────────────────────────────────┤
              │ ENCRYPTED PAYLOAD                            │
              └──────────────────────────────────────────────┘
```

Fijo, big-endian, 8 keyslots, solo PBKDF2, sin extensibilidad. Offset de payload por defecto de 4096 sectores (2 MiB).

### 4.2 Disposición de LUKS2

```
offset 0        ┌───────────────────────────────────────────┐
                │ binary header (primary)          4096 B   │
                │ JSON metadata area (primary)    12288 B   │
offset 16384    ├───────────────────────────────────────────┤
                │ binary header (secondary)        4096 B   │  ← redundant copy
                │ JSON metadata area (secondary)  12288 B   │
offset 32768    ├───────────────────────────────────────────┤
                │ keyslots binary area (AF-split keys)      │
offset 16 MiB   ├───────────────────────────────────────────┤
                │ ENCRYPTED PAYLOAD (data segment 0)        │
                └───────────────────────────────────────────┘
```

El área JSON describe cuatro colecciones de objetos:

| Objeto | Propósito |
|---|---|
| `keyslots` | Copias de la clave maestra envueltas con passphrase: parámetros de PBKDF, salt, franjas AF, offset del área |
| `tokens` | *Cómo obtener* una passphrase sin una persona — `systemd-tpm2`, `systemd-fido2`, `systemd-recovery`, `clevis`, o tokens arbitrarios de aplicación |
| `segments` | Las regiones cifradas: offset, tamaño, cifrador, tamaño de sector (varios durante el recifrado en línea) |
| `digests` | Digest de verificación de la clave maestra, que liga los keyslots a los segmentos |

Todo lleva checksum (SHA-256 sobre la cabecera), hay dos copias, y `cryptsetup repair` puede restaurar la primaria desde la secundaria. Esa redundancia por sí sola justifica LUKS2 para cualquier cosa que no puedas reaprovisionar.

### 4.3 El divisor antiforense (AF)

Una clave envuelta de 512 bits almacenada de forma ingenua ocupa 64 bytes. Sobrescribir 64 bytes en un SSD con nivelación de desgaste **no** los destruye de forma confiable — la FTL puede haber reubicado el bloque. Por eso LUKS expande cada clave a `franjas × tamaño-de-clave` bytes (por defecto 4000 franjas ≈ 256 KiB) mediante una función de difusión tal que **cada byte individual es necesario** para reconstruir la clave. Destruir un keyslot significa destruir 256 KiB, de los cuales cualquier fragmento superviviente es inútil. Por eso `luksKillSlot` tiene sentido y por eso las áreas de keyslot se ven grandes para lo que contienen.

### 4.4 Derivación de clave a partir de contraseña

| | PBKDF2 (LUKS1 / opcional en LUKS2) | Argon2i / **Argon2id** (default de LUKS2) |
|---|---|---|
| Estándar | RFC 8018 | RFC 9106 |
| Dimensiones de costo | Solo iteraciones | Iteraciones **× memoria × paralelismo** |
| Resistencia a GPU/ASIC | Pobre — trivialmente paralelo | **Fuerte** — duro en memoria |
| Costo por defecto | ~2 s de iteraciones | ~2 s, hasta 1 GiB de RAM, 4 hilos |
| Memoria necesaria al desbloquear | Despreciable | Hasta 1 GiB — **debe existir en el initramfs/bootloader** |
| Soporte de GRUB | Sí | **No** (GRUB 2.06/2.12 leen LUKS2 solo con PBKDF2) |

**La trampa en producción:** si `/boot` vive en el volumen LUKS y GRUB debe desbloquearlo, Argon2 no va a funcionar. O mantenés `/boot` sin cifrar (con Secure Boot + kernels firmados para mitigar), o creás un keyslot dedicado para GRUB con `--pbkdf pbkdf2`. Del mismo modo, un nodo con 2 GiB de RAM cuya cabecera exige 1 GiB de memoria Argon2 puede fallar al desbloquear en un initramfs mínimo — limitalo con `--pbkdf-memory`.

### 4.5 Tabla de decisión LUKS1 vs LUKS2

| Característica | LUKS1 | LUKS2 |
|---|---|---|
| Tamaño de cabecera / offset de datos | ~2 MiB | 16 MiB (configurable) |
| Redundancia de cabecera | Ninguna | Primaria + secundaria, con checksum |
| Keyslots | 8 | 32 |
| KDF | PBKDF2 | Argon2id (default), Argon2i, PBKDF2 |
| Tokens (TPM2/FIDO2/Tang/recuperación) | No | **Sí** |
| Banderas de rendimiento persistentes | No | **Sí** (`--persistent`) |
| Cifrado autenticado (`--integrity`) | No | **Sí** |
| Recifrado en línea | No | **Sí** (cryptsetup ≥ 2.4) |
| Cabecera separada | Sí | Sí |
| GRUB puede desbloquear | Sí | Solo con un keyslot PBKDF2 |
| Metadatos de etiqueta / subsistema | No | Sí |
| Tamaño de sector > 512 | No | Sí |
| Recomendado para despliegues nuevos | Solo legado/GRUB | **Default** |

---

## 5. Runbook operativo de cryptsetup

Primero verificá la versión — la disponibilidad de características difiere mucho entre 2.0 → 2.7:

```
$ cryptsetup --version
cryptsetup 2.7.5 flags: UDEV BLKID KEYRING KERNEL_CAPI HW_OPAL
```

`KEYRING` significa que las claves maestras quedan en el keyring del kernel; `HW_OPAL` significa que `--hw-opal` (descarga a SED) está disponible.

### 5.1 Formatear un volumen LUKS2

```
$ sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha256 \
    --pbkdf argon2id \
    --pbkdf-memory 1048576 \
    --pbkdf-parallel 4 \
    --iter-time 5000 \
    --sector-size 4096 \
    --label pgdata-01 \
    --subsystem prod-db \
    --use-random \
    --verify-passphrase \
    /dev/nvme1n1

WARNING!
========
This will overwrite data on /dev/nvme1n1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/nvme1n1:
Verify passphrase:
Key slot 0 created.
Command successful.
```

| Opción | Por qué está ahí |
|---|---|
| `--key-size 512` | AES-**256**-XTS (dos claves de 256 bits) |
| `--iter-time 5000` | 5 s de KDF en *esta* CPU. Un nodo lento produce una cabecera débil si lo dejás en 2000 y el atacante tiene una máquina rápida |
| `--sector-size 4096` | Bloque nativo de NVMe, menos operaciones criptográficas |
| `--use-random` | Clave maestra desde `/dev/random`; `--use-urandom` evita bloquearse por falta de entropía en VMs en el primer arranque |
| `--label` / `--subsystem` | Aparece en `lsblk -f` y `blkid` — invaluable en un chasis de 24 discos |

> **La calibración del costo debe hacerse en el hardware de destino.** `--iter-time` se mide, no se declara: la misma bandera produce 200k iteraciones de PBKDF2 en un Xeon y 30k en un nodo ARM de borde. Formateá en el nodo, o verificá después con `luksDump`.

Verificar la identificación:

```
$ lsblk -f /dev/nvme1n1
NAME        FSTYPE      FSVER LABEL     UUID                                 MOUNTPOINTS
nvme1n1     crypto_LUKS 2     pgdata-01 9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77
$ sudo blkid /dev/nvme1n1
/dev/nvme1n1: LABEL="pgdata-01" UUID="9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77" TYPE="crypto_LUKS"
```

### 5.2 Leer la cabecera

```
$ sudo cryptsetup luksDump /dev/nvme1n1
LUKS header information
Version:        2
Epoch:          6
Metadata area:  16384 [bytes]
Keyslots area:  16744448 [bytes]
UUID:           9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77
Label:          pgdata-01
Subsystem:      prod-db
Flags:          no-read-workqueue no-write-workqueue

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
        Time cost:  9
        Memory:     1048576
        Threads:    4
        Salt:       8b 21 ff 3c 7a 4d 90 e1 55 6c 02 b8 df 41 9a 33
                    c7 0e 6b 2f 18 ad 74 5e 93 c1 20 ef 8a 46 db 07
        AF stripes: 4000
        AF hash:    sha256
        Area offset:32768 [bytes]
        Area length:258048 [bytes]
        Digest ID:  0
  1: luks2
        Key:        512 bits
        Priority:   normal
        Cipher:     aes-xts-plain64
        Cipher key: 512 bits
        PBKDF:      pbkdf2
        Hash:       sha512
        Iterations: 1000
        Salt:       3d a9 74 12 ...
        AF stripes: 4000
        AF hash:    sha256
        Area offset:290816 [bytes]
        Area length:258048 [bytes]
        Digest ID:  0
Tokens:
  0: systemd-tpm2
  1: clevis
Digests:
  0: pbkdf2
        Hash:       sha256
        Iterations: 148824
        Salt:       f0 2c 8e ...
        Digest:     6a 91 c3 ...
```

Tres cosas que un revisor debería verificar de inmediato en este volcado:

1. **El keyslot 1 usa PBKDF2 con 1000 iteraciones.** Esa es la firma de un slot de *keyfile* agregado con `--pbkdf-force-iterations 1000` — legítimo para un keyfile aleatorio de 512 bytes (ya con entropía completa, estirarlo no tiene sentido), catastrófico si ese slot contiene una passphrase humana.
2. **Las banderas son persistentes**, así que cada `open` heredará el bypass de workqueues.
3. **Dos tokens** — TPM2 y Clevis — lo que significa que existen dos rutas de desbloqueo automatizado independientes.

### 5.3 Abrir, inspeccionar, cerrar

```
$ sudo cryptsetup open /dev/nvme1n1 pgdata
Enter passphrase for /dev/nvme1n1:

$ sudo cryptsetup status pgdata
/dev/mapper/pgdata is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: keyring
  integrity: (none)
  device:  /dev/nvme1n1
  sector size:  4096
  offset:  32768 sectors
  size:    7501344768 sectors
  mode:    read/write
  flags:   no_read_workqueue no_write_workqueue

$ sudo mkfs.xfs -L pgdata -f /dev/mapper/pgdata
meta-data=/dev/mapper/pgdata     isize=512    agcount=4, agsize=234417024 blks
         =                       sectsz=4096  attr=2, projid32bit=1
data     =                       bsize=4096   blocks=937668096, imaxpct=5
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=457846, version=2
         =                       sectsz=4096  sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0

$ sudo mount /dev/mapper/pgdata /srv/pgdata
$ sudo umount /srv/pgdata && sudo cryptsetup close pgdata
```

`cryptsetup close` falla con `Device pgdata is still in use.` si algo lo retiene — incluyendo un escaneo de PV de LVM obsoleto o un dm-snapshot. `lsof +D /srv/pgdata` y `dmsetup deps -o devname pgdata` encuentran a quien lo retiene.

### 5.4 Gestión de keyslots

```
$ sudo cryptsetup luksAddKey /dev/nvme1n1
Enter any existing passphrase:
Enter new passphrase for key slot:
Verify passphrase:

$ sudo cryptsetup luksAddKey --key-slot 5 --key-file /root/keys/pgdata.key /dev/nvme1n1
Enter any existing passphrase:

$ sudo cryptsetup luksChangeKey --key-slot 0 /dev/nvme1n1
Enter passphrase to be changed:
Enter new passphrase:
Verify passphrase:

$ sudo cryptsetup luksKillSlot /dev/nvme1n1 5
Enter any remaining passphrase:
$ sudo cryptsetup luksDump /dev/nvme1n1 | grep -c '^  [0-9]*: luks2'
2
```

Probar una passphrase sin abrir nada — la única forma segura de validar una credencial de recuperación:

```
$ sudo cryptsetup open --test-passphrase --key-slot 2 /dev/nvme1n1 && echo "slot 2 OK"
Enter passphrase for /dev/nvme1n1:
slot 2 OK
```

La prioridad de keyslot (LUKS2) controla el orden de desbloqueo — poné el slot de automatización primero y el humano último para que los arranques desatendidos no quemen 5 s de Argon2 en el slot equivocado:

```
$ sudo cryptsetup config --key-slot 1 --priority prefer /dev/nvme1n1
$ sudo cryptsetup config --key-slot 3 --priority ignore  /dev/nvme1n1   # only usable with --key-slot 3
```

La opción nuclear — irreversible, borra **todos** los keyslots:

```
$ sudo cryptsetup luksErase /dev/nvme1n1
WARNING!
========
This operation will erase all keyslots on device /dev/nvme1n1.
Device will become unusable after this operation.

Are you sure? (Type 'yes' in capital letters): YES
```

Este es el procedimiento correcto de baja para un disco que no podés destruir físicamente: sin ningún keyslot, la clave maestra es irrecuperable y los 3,5 TB de texto cifrado son ruido. Lleva menos de un segundo, frente a horas de `shred`. **El borrado criptográfico solo funciona si además destruís cada copia de la cabecera.**

### 5.5 Keyfiles

```
$ sudo install -d -m 0700 /etc/luks-keys
$ sudo dd if=/dev/urandom of=/etc/luks-keys/pgdata.key bs=512 count=8 status=none
$ sudo chmod 0400 /etc/luks-keys/pgdata.key
$ sudo cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    /dev/nvme1n1 /etc/luks-keys/pgdata.key
Enter any existing passphrase:
```

Un keyfile aleatorio de 4096 bits carga muchísima más entropía que cualquier passphrase, así que forzar el mínimo de iteraciones de PBKDF2 es seguro *y* ahorra segundos en cada arranque. Nunca hagas esto para un slot que contenga un secreto elegido por una persona.

Las lecturas parciales de keyfile importan cuando la clave está embebida en un blob más grande (un sector de cabecera, un volcado de un token de hardware):

```
$ sudo cryptsetup open --key-file /dev/sdc --keyfile-offset 4096 --keyfile-size 512 \
    /dev/nvme1n1 pgdata
```

Cuidado con los saltos de línea finales: `echo -n` vs `echo`, y `--keyfile-size` para acotar la lectura. Un keyfile generado con `echo "secret" > key` incluye `\n` y no coincidirá con un slot creado a partir de `printf 'secret'`.

### 5.6 Copia de la cabecera — el paso que todos se saltan

Dieciséis mebibytes separan la operación de la pérdida total.

```
$ sudo cryptsetup luksHeaderBackup /dev/nvme1n1 \
    --header-backup-file /root/luks-headers/pgdata-01.$(hostname -s).img
$ sudo chmod 0400 /root/luks-headers/pgdata-01.*.img
$ ls -l /root/luks-headers/
-r--------. 1 root root 16777216 Aug 20 09:14 pgdata-01.k8s-worker-07.img
```

La copia **contiene todos los keyslots tal como estaban al momento del backup.** Si revocás una passphrase y alguien todavía tiene la imagen vieja de la cabecera, puede restaurarla y recuperar el acceso. Por lo tanto, las copias de cabecera heredan la sensibilidad de las passphrases que codifican — cifralas, versionalas y rotalas junto con los cambios de clave.

Restaurar:

```
$ sudo cryptsetup luksHeaderRestore /dev/nvme1n1 \
    --header-backup-file /root/luks-headers/pgdata-01.k8s-worker-07.img

WARNING!
========
Device /dev/nvme1n1 already contains LUKS2 header. Replacing header will destroy existing keyslots.

Are you sure? (Type 'yes' in capital letters): YES
```

Las **cabeceras separadas** ponen la cabecera enteramente en otro medio — el dispositivo de datos entonces se ve como ruido aleatorio sin ninguna firma LUKS:

```
$ sudo cryptsetup luksFormat --type luks2 --header /root/hdr/vault.hdr /dev/sdb1
$ sudo cryptsetup open --header /root/hdr/vault.hdr /dev/sdb1 vault
```

Operativamente esto es una clave en dos partes: perder el archivo de cabecera es perder los datos. Se usa para negabilidad, para mantener cabeceras en una smartcard, y para volúmenes cuyo almacenamiento subyacente no es de confianza (una LUN iSCSI de otro equipo).

### 5.7 Suspender y reanudar

`luksSuspend` congela toda la E/S del mapeo y **borra la clave maestra de la memoria del kernel**, que es lo que querés antes de cerrar la tapa de un portátil o antes de que un técnico físico toque un rack en funcionamiento:

```
$ sudo cryptsetup luksSuspend pgdata
$ sudo cryptsetup status pgdata
/dev/mapper/pgdata is active and is suspended.
  type:    LUKS2
  ...
$ sudo cryptsetup luksResume pgdata
Enter passphrase for /dev/nvme1n1:
```

Cualquier proceso que toque el sistema de archivos se bloquea en sueño ininterrumpible hasta la reanudación. Nunca suspendas el volumen que contiene `/` desde una shell cuyos binarios viven en él — el propio `cryptsetup` debe estar ya en la caché de páginas o bloqueás la máquina por deadlock. Las distribuciones resuelven esto con un servicio de pre-suspensión dedicado que fija en memoria los binarios necesarios.

### 5.8 Redimensionar

Hacé crecer primero el dispositivo subyacente, después el mapeo, después el sistema de archivos:

```
$ sudo lvextend -L +500G /dev/vg0/data
  Size of logical volume vg0/data changed from 1.00 TiB (262144 extents) to 1.49 TiB (390144 extents).
  Logical volume vg0/data successfully resized.
$ sudo cryptsetup resize data
$ sudo cryptsetup status data | grep size
  sector size:  4096
  size:    3196059648 sectors
$ sudo xfs_growfs /srv/data
```

Con la clave maestra en el keyring del kernel, `cryptsetup resize` no necesita passphrase. Sin soporte de keyring (o con `--disable-keyring`), pregunta — lo cual es una sorpresa desagradable en un pipeline de expansión automatizado. Probá esa ruta.

### 5.9 Convertir LUKS1 → LUKS2

```
$ sudo cryptsetup convert --type luks2 /dev/sdb1
WARNING!
========
This operation will convert /dev/sdb1 to LUKS2 format.

Are you sure? (Type 'yes' in capital letters): YES
$ sudo cryptsetup luksConvertKey --pbkdf argon2id --key-slot 0 /dev/sdb1
Enter passphrase for keyslot to be converted:
```

La conversión es **in situ y solo de metadatos** — el offset de datos no cambia, así que la nueva cabecera LUKS2 debe caber en el espacio de la vieja cabecera LUKS1 (2 MiB). Eso significa que la cabecera resultante tiene un área de keyslots más chica que un formateo LUKS2 fresco. Convertí con el dispositivo cerrado, y hacé backup de la cabecera *antes* de convertir; la conversión no es atómica en un dispositivo que pierde energía a mitad de la escritura. Los keyslots siguen siendo PBKDF2 hasta que convertís cada uno.

### 5.10 Cifrado in situ de un sistema de archivos existente

LUKS2 puede cifrar un dispositivo poblado que nunca estuvo cifrado, encogiendo el área de datos para hacer lugar a la cabecera:

```
$ sudo umount /srv/archive
$ sudo e2fsck -f /dev/vg0/archive
$ sudo resize2fs /dev/vg0/archive 900G       # leave headroom
$ sudo cryptsetup reencrypt --encrypt --reduce-device-size 32M \
    --type luks2 --resilience checksum /dev/vg0/archive
Enter new passphrase:
Verify passphrase:
Finished, time 41m18s,  931 GiB written, speed 384.9 MiB/s
```

`--reduce-device-size 32M` sacrifica los últimos 32 MiB del dispositivo para la cabecera. La alternativa es `--header /path/to/detached.hdr`, que conserva el área de datos completa a costa de una cabecera separada.

`--resilience` selecciona la estrategia de recuperación ante caídas:

| Modo | Comportamiento | Costo |
|---|---|---|
| `checksum` (default) | Checksums por bloque en la cabecera; reanuda exactamente | Moderado |
| `journal` | Journal completo de la zona caliente | El más lento, el más seguro |
| `none` | Sin datos de recuperación | El más rápido, **pérdida de datos ante una caída** |
| `datashift` | Para `--encrypt`/`--decrypt` con desplazamiento del dispositivo | Automático |

Si el proceso se interrumpe, volver a ejecutar el mismo comando reanuda:

```
$ sudo cryptsetup reencrypt --resume-only /dev/vg0/archive
Enter passphrase for /dev/vg0/archive:
Finished, time 12m03s,  268 GiB written, speed 379.4 MiB/s
```

### 5.11 Rotación de la clave maestra (recifrado)

La única remediación verdadera tras una sospecha de exposición de la clave maestra:

```
$ sudo cryptsetup reencrypt /dev/nvme1n1
Enter passphrase for key slot 0:
Progress:  63.4%, ETA 00:22, 2.2 TiB written, speed 402.1 MiB/s
```

El recifrado en línea (LUKS2, cryptsetup ≥ 2.4) funciona sobre un dispositivo **montado y activo**:

```
$ sudo cryptsetup reencrypt --active-name pgdata --resilience checksum /dev/nvme1n1
```

El rendimiento de la carga de trabajo se degrada aproximadamente 30–50% mientras dura. Para un NVMe de 3,5 TB a ~400 MiB/s, presupuestá ~2,5 horas. Planificalo como ventana de mantenimiento; no lo «largues y ya». El recifrado **no está soportado en volúmenes con `--integrity`** — esos hay que recrearlos y restaurarlos desde backup.

---

## 6. Integridad: dm-integrity y cifrado autenticado

### 6.1 Por qué LUKS a secas no alcanza frente a un backend de almacenamiento hostil

XTS es maleable por bloque de 16 bytes. Invertí un bit del texto cifrado y el bloque de texto en claro correspondiente se vuelve basura pseudoaleatoria — pero la lectura *tiene éxito*. El sistema de archivos entonces interpreta la basura como metadatos. Para una base de datos sobre una SAN cuyo administrador no controlás del todo, o para un volumen replicado a través de una red que no controlás, esto es una superficie de ataque real: un adversario que no puede leer tus datos igual puede corromperlos de formas dirigidas y silenciosas.

`dm-integrity` se sitúa **por debajo** de dm-crypt y almacena una etiqueta de autenticación por sector en metadatos intercalados, convirtiendo la pila en cifrado autenticado.

```
    filesystem
        │
   /dev/mapper/vault          ← dm-crypt (aes-gcm-random or aes-xts + hmac)
        │
   /dev/mapper/vault_dif      ← dm-integrity (tag storage + journal)
        │
   /dev/nvme2n1
```

### 6.2 Crear un volumen LUKS2 protegido con integridad

Dos construcciones:

```
# A) AEAD: AES-GCM with random IVs stored by dm-integrity
$ sudo cryptsetup luksFormat --type luks2 \
    --cipher aes-gcm-random --integrity aead \
    --key-size 256 --sector-size 4096 /dev/nvme2n1

# B) Encrypt-then-MAC: XTS for confidentiality + HMAC-SHA256 for integrity
$ sudo cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --integrity hmac-sha256 \
    --key-size 512 --sector-size 4096 /dev/nvme2n1

WARNING!
========
This will overwrite data on /dev/nvme2n1 irrevocably.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/nvme2n1:
Verify passphrase:
Wiping device to initialize integrity checksum.
You can interrupt this by pressing CTRL+c (rest of not wiped device will contain invalid checksum).
Finished, time 28m41s, 3.4 TiB written, speed 2074.3 MiB/s
Key slot 0 created.
Command successful.
```

El borrado es obligatorio: cada sector debe llevar una etiqueta válida antes de poder leerse, si no la primera lectura de espacio nunca tocado devuelve un fallo de integridad. `--integrity-no-wipe` lo salta — solo apropiado si vas a sobrescribir el dispositivo entero de inmediato (por ejemplo, `mkfs` más una restauración completa), y producirá errores alarmantes mientras tanto.

```
$ sudo cryptsetup open /dev/nvme2n1 vault
$ sudo cryptsetup status vault
/dev/mapper/vault is active.
  type:    LUKS2
  cipher:  aes-gcm-random
  keysize: 256 bits
  key location: keyring
  integrity: aead
  integrity keysize: 0 bits
  device:  /dev/nvme2n1
  sector size:  4096
  offset:  0 sectors
  size:    6811648000 sectors
  mode:    read/write
$ lsblk /dev/nvme2n1
NAME             MAJ:MIN RM  SIZE RO TYPE  MOUNTPOINTS
nvme2n1          259:2    0  3.5T  0 disk
└─vault_dif      253:4    0  3.4T  0 crypt
  └─vault        253:5    0  3.4T  0 crypt
```

Notá los **dos** mapeos apilados y la capacidad útil reducida.

### 6.3 dm-integrity autónomo (sin cifrado)

Útil cuando la confidencialidad se maneja en otro lado pero querés detección de bit-rot bajo un sistema de archivos que carece de checksums:

```
$ sudo integritysetup format --integrity sha256 --tag-size 32 --sector-size 4096 /dev/sdd1
$ sudo integritysetup open --integrity sha256 /dev/sdd1 datadif
$ sudo integritysetup status datadif
/dev/mapper/datadif is active.
  type:    INTEGRITY
  tag size: 32 [bytes]
  integrity: sha256
  device:  /dev/sdd1
  sector size:  4096 [bytes]
  interleave sectors: 32768
  size:    1917186048 sectors
  mode:    read/write
  failures: 0
  journal size: 66584576 [bytes]
  journal watermark: 50%
  journal commit time: 10000 ms
```

`failures:` es el contador que hay que raspar hacia Prometheus.

### 6.4 El costo

| Configuración | Capacidad útil | IOPS de escritura aleatoria 4K (rel.) | Escritura secuencial (rel.) | Detecta manipulación |
|---|---|---|---|---|
| XFS a secas | 100% | 1.00 | 1.00 | No |
| LUKS2 aes-xts | ~100% | 0.94 | 0.96 | No |
| LUKS2 aes-xts + hmac-sha256, con journal | ~93% | **0.42** | 0.51 | Sí |
| LUKS2 aes-gcm-random (AEAD), con journal | ~94% | 0.48 | 0.55 | Sí |
| LUKS2 + integridad, `--integrity-no-journal` | ~94% | 0.78 | 0.86 | Sí (pero ver abajo) |

*(Cifras indicativas de un NVMe Gen4 con AES-NI; medí en tu propio hardware — las proporciones se mueven mucho con la profundidad de cola y el tamaño de sector.)*

El journal es lo que hace que la integridad sea **segura ante caídas**: la etiqueta y los datos deben actualizarse atómicamente, así que dm-integrity escribe ambos primero en un journal — cada escritura ocurre dos veces. `--integrity-no-journal` elimina eso y aproximadamente duplica el rendimiento de escritura, al precio de que un corte de energía a mitad de escritura puede dejar un sector cuyos datos y etiqueta no concuerdan, lo que luego se lee como manipulación. Usalo solo donde el dispositivo entero pueda reconstruirse desde una réplica.

**Restricciones que hay que tener en cuenta en el diseño:** sin recifrado, sin redimensionado, sin LUKS1, y la hibernación/`resume=` en un volumen con integridad no está soportada.

### 6.5 Cómo se ve un fallo de integridad real

```
$ sudo dd if=/dev/urandom of=/dev/nvme2n1 bs=4096 count=1 seek=2000000 conv=notrunc
$ sudo dd if=/dev/mapper/vault of=/dev/null bs=4096 count=1 skip=1999000
dd: error reading '/dev/mapper/vault': Input/output error
0+0 records in
0+0 records out

$ sudo dmesg | tail -4
[ 9481.220371] device-mapper: integrity: dm-4: Checksum failed at sector 0x1e8480
[ 9481.220389] blk_update_request: I/O error, dev dm-4, sector 15992832 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 0
[ 9481.220401] XFS (dm-5): metadata I/O error in "xfs_read_agf+0x9d/0x140" at daddr 0x1e8480 len 8 error 5
```

La propiedad crítica: la lectura **falla** en lugar de devolver basura. Ese es todo el punto.

---

## 7. Desbloqueo en el arranque: crypttab, systemd y el initramfs

### 7.1 Sintaxis de `/etc/crypttab`

Cuatro campos separados por espacios en blanco:

```
<target name>   <source device>   <key file>   <options>
```

| Campo | Reglas |
|---|---|
| nombre del target | Se convierte en `/dev/mapper/<name>`. Referenciado por `/etc/fstab`. |
| dispositivo origen | Usá `UUID=` o `/dev/disk/by-id/` — **nunca** `/dev/sdb1`, que no es estable entre arranques |
| archivo de clave | Ruta, o `none`/`-` para preguntar, o `/dev/urandom` para volúmenes con clave aleatoria |
| opciones | Separadas por comas; ver abajo |

Opciones clave (`crypttab(5)` de systemd):

| Opción | Significado |
|---|---|
| `luks` | Forzar LUKS (si no, se autodetecta) |
| `plain` | dm-crypt plano; entonces `cipher=`, `size=`, `hash=`, `offset=`, `skip=` son obligatorios |
| `swap` | Formatear como swap tras desbloquear. **Se niega a ejecutarse si el dispositivo tiene una firma de sistema de archivos** — una válvula de seguridad crítica |
| `tmp[=fstype]` | mkfs en cada arranque |
| `discard` | Pasar TRIM (ver la advertencia de [§3.4](#34-el-problema-de-las-workqueues-una-mejora-real-en-producción)) |
| `noauto` | No desbloquear en el arranque |
| `nofail` | El arranque continúa si el dispositivo falta |
| `timeout=`, `tries=` | Comportamiento del prompt de contraseña; `tries=0` = infinito |
| `keyfile-size=`, `keyfile-offset=` | Lectura parcial del keyfile |
| `header=` | Ruta de la cabecera separada |
| `key-slot=` | Probar solo este slot (arranque más rápido) |
| `tpm2-device=auto` | Desbloquear mediante token TPM2 |
| `tpm2-pcrs=`, `tpm2-pin=` | Ligadura de política TPM2 / exigir un PIN |
| `fido2-device=auto` | Desbloquear mediante token FIDO2 |
| `no-read-workqueue`, `no-write-workqueue`, `same-cpu-crypt`, `high-priority` | Banderas de rendimiento |
| `sector-size=` | Tamaño de sector en modo plano |
| `x-systemd.device-timeout=` | Cuánto esperar por el dispositivo subyacente |
| `initramfs` | **Específico de Debian**: incluir esta entrada en el initramfs |
| `keyscript=` | **Específico de Debian**: ejecutar un script para obtener la clave (ignorado por systemd) |

### 7.2 Un crypttab de producción completo

```
# /etc/crypttab
# <name>     <device>                                              <keyfile>            <options>

# Root volume: TPM2-sealed, PIN fallback, recovery key in the safe.
cryptroot    UUID=1c4a90f2-7ee1-4b3a-8b0f-6dd4a2c5c101              none                 luks,discard,tpm2-device=auto,tpm2-pcrs=7+14,tries=3,x-systemd.device-timeout=30s

# Container runtime scratch: keyfile on the (already unlocked) root FS.
cryptcontainerd UUID=a1b2c3d4-1111-4222-8333-444455556666           /etc/luks-keys/containerd.key  luks,discard,no-read-workqueue,no-write-workqueue,nofail,x-systemd.device-timeout=15s

# Database volume: network-bound (Clevis/Tang) via its own systemd unit; no boot prompt.
cryptpgdata  UUID=9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77              none                 luks,noauto,no-read-workqueue,no-write-workqueue,nofail

# Encrypted swap with an ephemeral random key. Hibernation is DISABLED on this fleet.
cryptswap    /dev/disk/by-id/nvme-SAMSUNG_MZQL23T8HCLS_S64GNE0T123456-part3  /dev/urandom  swap,cipher=aes-xts-plain64,size=512,sector-size=4096,hash=sha256
```

Y el `/etc/fstab` correspondiente:

```
# /etc/fstab
UUID=8e2a1b30-93b7-4e5b-9a1f-0d4c72f3a9b1  /            xfs   defaults,noatime                  0 1
UUID=f4c1-9A2B                             /boot/efi    vfat  umask=0077,shortname=winnt        0 2
UUID=3b7e2f11-64ac-4d9e-b0e4-77c1a2f5e8d0  /boot        ext4  defaults                          0 2
/dev/mapper/cryptcontainerd                /var/lib/containerd xfs defaults,noatime,nofail,x-systemd.requires=/dev/mapper/cryptcontainerd  0 2
/dev/mapper/cryptpgdata                    /srv/pgdata  xfs   defaults,noatime,noauto,x-systemd.requires=/dev/mapper/cryptpgdata           0 2
/dev/mapper/cryptswap                      none         swap  sw                                0 0
```

### 7.3 Cómo systemd convierte eso en units

`systemd-cryptsetup-generator` se ejecuta al inicio del arranque y sintetiza un `systemd-cryptsetup@<name>.service` por cada línea de crypttab:

```
$ systemctl list-units 'systemd-cryptsetup@*'
  UNIT                                LOAD   ACTIVE SUB    DESCRIPTION
  systemd-cryptsetup@cryptcontainerd.service loaded active exited Cryptography Setup for cryptcontainerd
  systemd-cryptsetup@cryptroot.service       loaded active exited Cryptography Setup for cryptroot
  systemd-cryptsetup@cryptswap.service       loaded active exited Cryptography Setup for cryptswap

$ systemctl cat systemd-cryptsetup@cryptcontainerd.service | head -20
# /run/systemd/generator/systemd-cryptsetup@cryptcontainerd.service
[Unit]
Description=Cryptography Setup for cryptcontainerd
Documentation=man:crypttab(5) man:systemd-cryptsetup-generator(8) man:systemd-cryptsetup@.service(8)
SourcePath=/etc/crypttab
DefaultDependencies=no
IgnoreOnIsolate=true
After=cryptsetup-pre.target systemd-udevd-kernel.socket
Before=blockdev@dev-mapper-cryptcontainerd.target
Wants=blockdev@dev-mapper-cryptcontainerd.target
Conflicts=umount.target
Before=cryptsetup.target umount.target
RequiresMountsFor=/etc/luks-keys/containerd.key
BindsTo=dev-disk-by\x2duuid-a1b2c3d4...device
After=dev-disk-by\x2duuid-a1b2c3d4...device

$ systemctl status systemd-cryptsetup@cryptroot.service --no-pager
● systemd-cryptsetup@cryptroot.service - Cryptography Setup for cryptroot
     Loaded: loaded (/etc/crypttab; generated)
     Active: active (exited) since Thu 2026-08-20 08:41:02 UTC; 3h 12min ago
   Main PID: 412 (code=exited, status=0/SUCCESS)
        CPU: 1.284s

Aug 20 08:41:01 k8s-worker-07 systemd-cryptsetup[412]: Set cipher aes, mode xts-plain64, key size 512 bits for device /dev/disk/by-uuid/1c4a90f2-...
Aug 20 08:41:02 k8s-worker-07 systemd-cryptsetup[412]: Unlocked volume cryptroot with TPM2 token.
```

Equivalentes en la línea de comandos del kernel (dracut/systemd), para los casos en que crypttab todavía no es legible — es decir, el propio dispositivo raíz:

```
rd.luks.uuid=luks-1c4a90f2-7ee1-4b3a-8b0f-6dd4a2c5c101
rd.luks.name=1c4a90f2-...=cryptroot
rd.luks.options=discard,tpm2-device=auto
rd.luks.key=/etc/luks-keys/root.key:UUID=abcd-1234
```

### 7.4 El initramfs

El código de desbloqueo del sistema de archivos raíz debe existir *antes* de que exista el sistema de archivos raíz.

```
# Debian/Ubuntu
$ sudo apt-get install -y cryptsetup-initramfs
$ sudo update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.8.0-45-generic
cryptsetup: WARNING: Resume target cryptswap uses a random key ...
$ lsinitramfs /boot/initrd.img-6.8.0-45-generic | grep -E 'cryptsetup|crypttab|dm-crypt'
cryptroot/crypttab
sbin/cryptsetup
usr/lib/modules/6.8.0-45-generic/kernel/drivers/md/dm-crypt.ko

# Fedora/RHEL
$ sudo dracut --force --verbose 2>&1 | grep -iE 'crypt|tpm'
dracut: *** Including module: crypt ***
dracut: *** Including module: tpm2-tss ***
$ sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'cryptsetup$|crypttab'
```

Si hay un keyfile embebido en el initramfs, el initramfs mismo se convierte en material secreto — en Debian, `UMASK=0077` en `/etc/initramfs-tools/initramfs.conf` es esencial, si no `/boot/initrd.img-*` es legible por todo el mundo y tu clave también.

### 7.5 `systemd-cryptenroll`: TPM2, FIDO2, claves de recuperación

Esta es la ruta moderna de desbloqueo desatendido, y está explícitamente en la lista de términos del examen.

```
# Enrol a TPM2-sealed key bound to Secure Boot state (PCR 7) and the initrd (PCR 14)
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=auto --tpm2-pcrs=7+14
🔐 Please enter current passphrase for disk /dev/nvme0n1p3:
New TPM2 token enrolled as key slot 2.

# Require a PIN in addition to the TPM measurement (defeats a stolen powered-off machine)
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes

# Enrol a hardware token
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --fido2-device=auto
Initializing FIDO2 credential on security token.
👆 (Hint: This might require confirmation of user presence on the security token.)
New FIDO2 token enrolled as key slot 3.

# Generate a printable recovery key — do this BEFORE you need it
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --recovery-key
🔐 Please enter current passphrase for disk /dev/nvme0n1p3:
A secret recovery key has been generated for this volume:

    dcefbg-hcvhue-lgjnkd-cnbtvr-eugvfj-hgtylk-nbvcxz-qwerty

Please save this secret recovery key at a secure location.
New recovery key enrolled as key slot 4.

# List and revoke
$ sudo systemd-cryptenroll /dev/nvme0n1p3
SLOT TYPE
   0 password
   2 tpm2
   3 fido2
   4 recovery
$ sudo systemd-cryptenroll /dev/nvme0n1p3 --wipe-slot=tpm2
```

Los tokens se almacenan en la cabecera JSON de LUKS2:

```
$ sudo cryptsetup luksDump /dev/nvme0n1p3 | sed -n '/^Tokens:/,/^Digests:/p'
Tokens:
  0: systemd-tpm2
        Keyslot:    2
  1: systemd-fido2
        Keyslot:    3
  2: systemd-recovery
        Keyslot:    4
Digests:
```

**La selección de PCR es una decisión de disponibilidad, no de seguridad.** Ligá demasiado ajustado y el mantenimiento rutinario deja inservible a toda la flota:

| PCR | Mide | Se rompe con |
|---|---|---|
| 0 | Código del firmware | **Cualquier actualización de BIOS/UEFI** |
| 1 | Configuración del firmware | Cualquier cambio de ajuste de BIOS, cambio de RAM |
| 4 | Bootloader / gestor de arranque | Actualización del bootloader |
| 7 | Estado y claves de Secure Boot | Enrolar/retirar claves SB, algunas actualizaciones de certificados del fabricante |
| 8–9 | Línea de comandos / archivos de GRUB | Cualquier cambio de parámetro del kernel |
| 11 | Mediciones de UKI (systemd-stub) | Actualización de kernel/initrd (salvo que se use una política firmada) |
| 14 | Certificados MOK/shim | Cambios de shim o MOK |

**La política de flota recomendada es PCR 7 (+14) más una clave de recuperación enrolada obligatoria**, y un paso documentado en el runbook: *antes de cualquier actualización de firmware, verificá que la clave de recuperación funciona; después de la actualización, volvé a enrolar el slot TPM2.* Ligar al PCR 0 en toda una flota de hardware ha dejado a más de un equipo de plataforma fuera de línea un día entero.

### 7.6 Swap cifrado y la trampa de la hibernación

El swap contiene páginas expulsadas de la RAM: claves de sesión, secretos descifrados, filas de base de datos en claro. Cifrarlo no es opcional.

El **swap con clave aleatoria** (del crypttab de arriba) es la opción más limpia — una clave fresca desde `/dev/urandom` en cada arranque, nada que gestionar, nada que filtrar:

```
$ sudo cryptsetup status cryptswap
/dev/mapper/cryptswap is active and is in use.
  type:    PLAIN
  cipher:  aes-xts-plain64
  keysize: 512 bits
  key location: dm-crypt
  device:  /dev/nvme0n1p3
  sector size:  4096
  offset:  0 sectors
  size:    134217728 sectors
  mode:    read/write
$ swapon --show
NAME                TYPE      SIZE USED PRIO
/dev/mapper/cryptswap partition  64G   0B   -2
```

**Destruye la hibernación.** Reanudar desde disco requiere leer de vuelta una imagen de swap escrita antes del reinicio; una clave que ya no existe lo hace imposible. Para portátiles que deben hibernar:

- Poné el swap dentro del grupo de volúmenes LVM cifrado con LUKS, junto al raíz.
- Configurá `resume=/dev/mapper/vg0-swap` en la línea de comandos del kernel y en `/etc/initramfs-tools/conf.d/resume` (Debian) o el módulo `resume` de dracut.
- Aceptá que la imagen de hibernación está protegida por la clave del volumen *raíz*.

La opción `swap` de crypttab incluye una verificación de seguridad: `systemd-cryptsetup` se niega a hacer `mkswap` sobre un dispositivo que tenga una firma de sistema de archivos o de tabla de particiones. Saltearla apuntando la entrada al `/dev/sdX` equivocado y forzarla es una de las formas más rápidas conocidas de destruir un volumen de producción — que es precisamente por lo que la entrada de crypttab de arriba usa `/dev/disk/by-id/`.

### 7.7 Cifrado de disco ligado a la red (Clevis + Tang)

TPM2 responde «¿es esta la misma máquina?»; Tang responde «¿está esta máquina en nuestra red?» — que es la mejor pregunta para un datacenter, porque un servidor robado y enchufado en otro lado sencillamente no va a desbloquearse.

```
$ sudo dnf install -y clevis clevis-luks clevis-dracut
$ sudo clevis luks bind -d /dev/nvme1n1 tang '{"url":"https://tang.infra.svc.cluster.local"}'
The advertisement contains the following signing keys:

    kWwirxc5PgOKB1cMlwZWRgOa1Aw

Do you wish to trust these keys? [ynYN] y
Enter existing LUKS password:
$ sudo clevis luks list -d /dev/nvme1n1
1: tang '{"url":"https://tang.infra.svc.cluster.local"}'
$ sudo systemctl enable clevis-luks-askpass.path
$ sudo dracut -f
```

Redundancia mediante Shamir Secret Sharing — desbloquea si responden 2 de 3 servidores cualesquiera, de modo que la caída de un Tang no sea la caída de la flota:

```
$ sudo clevis luks bind -d /dev/nvme1n1 sss '{
  "t": 2,
  "pins": {
    "tang": [
      {"url": "https://tang-a.infra.example.net"},
      {"url": "https://tang-b.infra.example.net"}
    ],
    "tpm2": {"pcr_bank":"sha256","pcr_ids":"7"}
  }
}'
```

---

## 8. eCryptfs: cifrado apilado por archivo

### 8.1 Arquitectura

eCryptfs es un **sistema de archivos criptográfico apilado**: se monta sobre un directorio existente en un sistema de archivos existente y cifra cada archivo individualmente, almacenando el texto cifrado como un archivo ordinario en el sistema de archivos inferior. Está implementado en el kernel (`fs/ecryptfs`) pero se conduce desde espacio de usuario a través del keyring del kernel.

Jerarquía de claves — esta es la parte que sondean los exámenes y las entrevistas:

```
passphrase ──(salt, 65536 SHA-512 iterations)──► FEKEK   (File Encryption Key Encryption Key)
                                                    │
                                                    │ wraps
                                                    ▼
per-file random FEK  ──stored, wrapped, in the file's own 8 KiB header──► file contents
                                                                          (AES-CBC, per-extent IV)

FNEK (FileName Encryption Key)  ──► encrypted, base64-ish file names prefixed ECRYPTFS_FNEK_ENCRYPTED.
```

Cada archivo obtiene su **propia** FEK aleatoria. Copiar un archivo cifrado a otro montaje eCryptfs con la misma FEKEK funciona; los metadatos viajan con el archivo. Esa es la ventaja arquitectónica genuina de eCryptfs sobre dm-crypt: la unidad de cifrado es el archivo, así que sobrevive a `rsync`, al backup a un destino no confiable, y a la separación de claves por usuario en almacenamiento compartido.

La cabecera cuesta 8 KiB por archivo. Un directorio de un millón de archivos de 1 KiB consume ~9 GB en vez de ~1 GB. eCryptfs encaja mal con cargas de trabajo tipo maildir.

### 8.2 Montaje manual

```
$ sudo mkdir -p /srv/secret.raw /srv/secret
$ sudo mount -t ecryptfs /srv/secret.raw /srv/secret
Select key type to use for newly created files:
 1) tspi
 2) passphrase
Selection: 2
Passphrase:
Select cipher:
 1) aes: blocksize = 16; min keysize = 16; max keysize = 32
 2) blowfish: blocksize = 8; min keysize = 16; max keysize = 56
 3) des3_ede: blocksize = 8; min keysize = 24; max keysize = 24
 4) twofish: blocksize = 16; min keysize = 16; max keysize = 32
 5) cast6: blocksize = 16; min keysize = 16; max keysize = 32
 6) cast5: blocksize = 8; min keysize = 5; max keysize = 16
Selection [aes]: 1
Select key bytes:
 1) 16
 2) 32
 3) 24
Selection [16]: 2
Enable plaintext passthrough (y/n) [n]: n
Enable filename encryption (y/n) [n]: y
Filename Encryption Key (FNEK) Signature [c9a3f21b7e4d5068]:
Attempting to mount with the following options:
  ecryptfs_unlink_sigs
  ecryptfs_fnek_sig=c9a3f21b7e4d5068
  ecryptfs_key_bytes=32
  ecryptfs_cipher=aes
  ecryptfs_sig=c9a3f21b7e4d5068
Mounted eCryptfs
```

Forma no interactiva, apta para automatización:

```
$ sudo mount -t ecryptfs /srv/secret.raw /srv/secret \
  -o key=passphrase:passphrase_passwd_file=/root/.ecryptfs.pw,\
ecryptfs_cipher=aes,\
ecryptfs_key_bytes=32,\
ecryptfs_passthrough=no,\
ecryptfs_enable_filename_crypto=yes,\
ecryptfs_fnek_sig=c9a3f21b7e4d5068,\
ecryptfs_sig=c9a3f21b7e4d5068,\
ecryptfs_unlink_sigs
```

Demostrar que el texto cifrado es real:

```
$ echo "postgres superuser password: hunter2" | sudo tee /srv/secret/creds.txt >/dev/null
$ ls -la /srv/secret.raw/
total 24
drwx------. 2 root root  4096 Aug 20 11:02 .
drwxr-xr-x. 4 root root  4096 Aug 20 10:58 ..
-rw-r--r--. 1 root root 12288 Aug 20 11:02 ECRYPTFS_FNEK_ENCRYPTED.FWa7RtT8u4kJq-2VbXcPl0ZmNhY1dGVzdA9nRE1zdlk6bA--

$ sudo xxd -l 32 '/srv/secret.raw/ECRYPTFS_FNEK_ENCRYPTED.FWa7RtT8u4kJq-2VbXcPl0ZmNhY1dGVzdA9nRE1zdlk6bA--'
00000000: 0000 0000 0000 0027 3c81 b7f5 0300 0000  .......'<.......
00000010: 0000 2000 0000 0000 0000 0000 0000 0000  .. .............
```

Los bytes 0–7 son el tamaño en claro (0x27 = 39 bytes), los bytes 8–11 son el marcador mágico de eCryptfs `0x3c81b7f5`, el byte 12 es la versión del formato. Notá que el tamaño del archivo se filtra en claro — una de las debilidades estructurales de eCryptfs.

```
$ sudo ecryptfs-stat '/srv/secret.raw/ECRYPTFS_FNEK_ENCRYPTED.FWa7RtT8u4kJq-2VbXcPl0ZmNhY1dGVzdA9nRE1zdlk6bA--'
Version: 3
Original filesize: 39
Number of header extents at front: 2
Block size: 4096
Number of extents per page: 1
Header extent size: 8192
Flags:
        SHA-2 512 metadata
        Encrypted with a passphrase
```

Estado del keyring — si la clave no está en el keyring, el montaje no puede funcionar:

```
$ keyctl list @u
2 keys in keyring:
 419237845: --alswrv     0     0 user: c9a3f21b7e4d5068
 731092447: --alswrv     0     0 user: 4e8b17d0a2c6f395
$ sudo umount /srv/secret
$ sudo keyctl clear @u     # ecryptfs_unlink_sigs does this at unmount
```

### 8.3 Directorios home cifrados y PAM

El despliegue canónico: `~/.Private` contiene el texto cifrado, `~/Private` (o todo el `$HOME`) es la vista en claro, y PAM desenvuelve la clave con la **contraseña de login** en el momento de la autenticación.

```
$ sudo apt-get install -y ecryptfs-utils
$ ecryptfs-setup-private
Enter your login passphrase [alice]:
Enter your mount passphrase [leave blank to generate one]:

************************************************************************
YOU SHOULD RECORD YOUR MOUNT PASSPHRASE AND STORE IT IN A SAFE LOCATION.
  ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase
THIS WILL BE REQUIRED IF YOU NEED TO RECOVER YOUR DATA AT A LATER TIME.
************************************************************************

Done configuring.
Testing mount/write/umount/read...
Testing succeeded.

$ ls -la ~/.ecryptfs/
-rw-------. 1 alice alice  17 Aug 20 11:20 auto-mount
-rw-------. 1 alice alice  17 Aug 20 11:20 auto-umount
lrwxrwxrwx. 1 alice alice  30 Aug 20 11:20 Private.mnt -> /home/alice/Private
lrwxrwxrwx. 1 alice alice  33 Aug 20 11:20 Private.sig
-rw-------. 1 alice alice  88 Aug 20 11:20 wrapped-passphrase
```

| Archivo | Rol |
|---|---|
| `wrapped-passphrase` | La passphrase de montaje (FEKEK), envuelta con la passphrase de **login** |
| `Private.sig` | Firmas de FEKEK y FNEK — dos líneas cuando el cifrado de nombres está activo |
| `Private.mnt` | Dónde montar la vista en claro |
| `auto-mount` / `auto-umount` | Banderas consumidas por `pam_ecryptfs` |

El envoltorio de dos capas es lo que hace posible la integración con PAM **y** lo que crea su peligro operativo central: cambiá la contraseña de login fuera de banda (`passwd` como root, un reseteo del lado LDAP, una sincronización de IdP) y la passphrase envuelta ya no se puede desenvolver. Los datos están intactos y son permanentemente inalcanzables a menos que se haya registrado la passphrase de *montaje*:

```
$ ecryptfs-unwrap-passphrase ~/.ecryptfs/wrapped-passphrase
Passphrase:
b3a91f7c4d2e8065a1c7f39e5b204d8c

$ ecryptfs-rewrap-passphrase ~/.ecryptfs/wrapped-passphrase
Old wrapping passphrase:
New wrapping passphrase:
Again:
```

Pila PAM (Debian `/etc/pam.d/common-auth` y `common-session`; el paquete `ecryptfs-utils` instala esto automáticamente):

```
# /etc/pam.d/common-auth
auth     required   pam_ecryptfs.so unwrap
auth     [success=1 default=ignore]  pam_unix.so nullok try_first_pass

# /etc/pam.d/common-session
session  optional   pam_ecryptfs.so unwrap

# /etc/pam.d/common-password  (keeps the wrapped passphrase in sync on password change)
password optional   pam_ecryptfs.so
```

El orden importa: `pam_ecryptfs.so unwrap` debe ejecutarse en un contexto donde la contraseña todavía esté disponible para PAM, por lo que se ubica *antes* de `pam_unix.so` en la pila de auth, con `try_first_pass` más abajo.

Control manual por usuario:

```
$ ecryptfs-mount-private
Enter your login passphrase:
INFO: Your private directory has been mounted.
INFO: To see this change in your current shell:
  cd /home/alice/Private
$ mount | grep ecryptfs
/home/alice/.Private on /home/alice/Private type ecryptfs (rw,nosuid,nodev,relatime,ecryptfs_fnek_sig=4e8b17d0a2c6f395,ecryptfs_sig=c9a3f21b7e4d5068,ecryptfs_cipher=aes,ecryptfs_key_bytes=16,ecryptfs_unlink_sigs)
$ ecryptfs-umount-private
```

Migrar un directorio home existente (destructivo — hacé un backup, y leé las advertencias que imprime):

```
$ sudo ecryptfs-migrate-home -u alice
INFO:  Checking disk space, this may take a few moments.  Please be patient.
INFO:  Checking for open files in /home/alice
Enter your login passphrase [alice]:
INFO:  Encrypted home has been set up, encrypting files now...this may take a while.
...
********************************************************************************
Some Important Notes!
 1. The file encryption appears to have completed successfully, however,
    alice MUST LOGIN IMMEDIATELY, _BEFORE_THE_NEXT_REBOOT_,
    TO COMPLETE THE MIGRATION!!!
 2. If alice can log in and read and write their files, then the migration is complete,
    and you should remove /home/alice.iCwWFO.
 3. alice should also run 'ecryptfs-unwrap-passphrase' and record the mount passphrase.
********************************************************************************
```

Recuperación administrativa cuando el usuario ya no está pero hay que recuperar los datos:

```
$ sudo ecryptfs-recover-private /home/.ecryptfs/alice/.Private
INFO: Found [/home/.ecryptfs/alice/.Private].
Try to recover this directory? [Y/n]: Y
INFO: Found your wrapped-passphrase
Do you know your LOGIN passphrase? [Y/n]: Y
INFO: Enter your LOGIN passphrase...
Passphrase:
Inserted auth tok with sig [c9a3f21b7e4d5068] into the user session keyring
INFO: Success!  Private data mounted at [/tmp/ecryptfs.7dK2xQ].
```

### 8.4 Referencia de opciones de montaje

| Opción | Significado |
|---|---|
| `ecryptfs_sig=<sig>` | Firma de la FEKEK (desde el keyring) |
| `ecryptfs_fnek_sig=<sig>` | Firma de la FNEK; habilita el cifrado de nombres de archivo |
| `ecryptfs_cipher=aes` | Cifrador del contenido |
| `ecryptfs_key_bytes=16\|24\|32` | Longitud de clave en bytes (16 = AES-128) |
| `ecryptfs_passthrough=y` | Permitir leer sin modificar los archivos no-eCryptfs del directorio inferior |
| `ecryptfs_encrypted_view` | Presentar el *texto cifrado* a través del montaje (para herramientas de backup) |
| `ecryptfs_xattr_metadata` | Guardar la cabecera por archivo en un xattr en vez de en línea |
| `ecryptfs_unlink_sigs` | Quitar las claves del keyring al desmontar |
| `no_sig_cache` | No preguntar por firmas desconocidas |
| `key=passphrase:passphrase_passwd_file=<f>` | Fuente de clave no interactiva |

### 8.5 Evaluación honesta para producción

| Aspecto | Veredicto |
|---|---|
| Separación de claves por usuario en almacenamiento compartido | Su razón de existir; nada en la capa de bloque puede hacer esto |
| Funciona sobre NFS | Históricamente el argumento de venta; en la práctica frágil con el caché de NFSv4 moderno |
| Longitud de nombres de archivo | Con cifrado de nombres, ~143 caracteres máximo en un FS de 255 bytes — los nombres largos de artefactos de compilación se rompen |
| Sobrecarga de espacio | Cabecera de 8 KiB por archivo, más el redondeo de extents de 4 KiB |
| Rendimiento | Penalización del 20–40%; malo con muchos archivos chicos |
| Fuga de metadatos | Tamaños, marcas de tiempo, estructura de directorios, cantidad de archivos |
| Estado de mantenimiento | Efectivamente sin mantenimiento upstream; Ubuntu quitó la opción del instalador en 18.04; **fscrypt es el sucesor** |
| Estado en el examen | **Explícitamente examinable** — conocé los comandos y la integración con PAM |

Para diseños nuevos, preferí `fscrypt` (nativo de ext4/f2fs) para el caso de uso de homes por usuario y dm-crypt/LUKS para el caso de uso de volúmenes. Aprendé eCryptfs porque está en los objetivos y porque lo vas a encontrar en sistemas heredados.

---

## 9. Cifrado nativo del sistema de archivos (conocimiento general)

### 9.1 fscrypt / cifrado de ext4

Cifrado implementado dentro del propio sistema de archivos: políticas por directorio, claves en el keyring del kernel, sin apilado, sin cabecera por archivo, sin FUSE.

```
$ sudo tune2fs -O encrypt /dev/vg0/home
tune2fs 1.47.0 (5-Feb-2023)
$ sudo fscrypt setup
Defaulting to policy_version 2 because kernel supports it.
Metadata directories created at "/.fscrypt".
$ sudo fscrypt setup /home
Metadata directories created at "/home/.fscrypt".
$ fscrypt encrypt /home/alice --user=alice
The following protector sources are available:
1 - Your login passphrase (pam_passphrase)
2 - A custom passphrase (custom_passphrase)
3 - A raw 256-bit key (raw_key)
Enter the source number for the new protector [2 - custom_passphrase]: 1
Enter login passphrase for alice:
"/home/alice" is now encrypted, unlocked, and ready for use.

$ fscrypt status /home
ext4 filesystem "/home" has 1 protector and 1 policy.

PROTECTOR         LINKED  DESCRIPTION
7c1f0b2d4e6a8931  No      login protector for alice

POLICY                            UNLOCKED  PROTECTORS
b93a17c4f0e25d8a6c31f0b74d2e9058  Yes       7c1f0b2d4e6a8931
```

| fscrypt vs eCryptfs | fscrypt |
|---|---|
| Cabecera por archivo | **Ninguna** — sin sobrecarga de espacio |
| Cifrado de nombres de archivo | Incorporado, sin una ceremonia de clave aparte |
| Rendimiento | Casi nativo; usa la misma ruta criptográfica del kernel |
| Requiere una bandera de característica del FS | Sí (`encrypt`), el tamaño de bloque debe igualar al de página |
| No puede cifrar un directorio existente in situ | Correcto — el directorio debe estar vacío |
| Metadatos (tamaños, mtimes) | Siguen en claro |

### 9.2 Cifrado nativo de ZFS

```
# zpool create -o ashift=12 tank mirror /dev/nvme3n1 /dev/nvme4n1
# zfs create -o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt tank/secure
Enter new passphrase:
Re-enter new passphrase:
# zfs get encryption,keystatus,encryptionroot tank/secure
NAME         PROPERTY        VALUE           SOURCE
tank/secure  encryption      aes-256-gcm     -
tank/secure  keystatus       available       -
tank/secure  encryptionroot  tank/secure     -
# zfs unload-key tank/secure && zfs load-key tank/secure
```

ZFS ofrece cifrado autenticado (GCM) más replicación cruda del texto cifrado con `zfs send -w` hacia un destino de backup no confiable — una capacidad que dm-crypt no puede igualar. Granularidad a nivel de dataset, integridad con checksums, claves por dataset.

---

## 10. Cifrado apilado en espacio de usuario y cryptmount

| Herramienta | Mecanismo | Estado | Uso |
|---|---|---|---|
| **EncFS** | FUSE, por archivo | Una auditoría de seguridad (2014) encontró debilidades serias; **evitar para trabajo nuevo** | Legado |
| **gocryptfs** | FUSE, AES-256-GCM por bloque, KDF scrypt | Mantenido activamente, auditado | Cifrar un directorio en almacenamiento cloud/objetos o NFS |
| **CryFS** | FUSE, bloques de tamaño fijo | Oculta tamaños de archivo y estructura de directorios | Sincronización cloud donde los metadatos importan |
| **fscrypt** | Kernel, nativo | Sucesor recomendado de eCryptfs | Homes por usuario |

```
$ gocryptfs -init /srv/vault.raw
Choose a password for protecting your files.
Password:
Repeat:
Your master key is:
    1a2b3c4d-5e6f7081-92a3b4c5-d6e7f809-1a2b3c4d-5e6f7081-92a3b4c5-d6e7f809
Filesystem created, mount with "gocryptfs /srv/vault.raw /srv/vault"
$ gocryptfs /srv/vault.raw /srv/vault
Password:
Decrypting master key
Filesystem mounted and ready.
```

**`cryptmount`** (en la lista de términos del examen) es una herramienta orientada a Debian que permite a *usuarios sin privilegios* montar sistemas de archivos cifrados — el helper setuid maneja las llamadas a dm-crypt y mount, conducido por `/etc/cryptmount/cmtab`:

```
# /etc/cryptmount/cmtab
opaque {
    dev=/dev/vg0/opaque
    dir=/mnt/opaque
    fstype=ext4
    fsoptions=defaults,noatime,nosuid,nodev
    cipher=aes-xts-plain64
    keyformat=luks
    keyfile=/dev/vg0/opaque
    supath=/sbin:/usr/sbin:/bin:/usr/bin
}

scratch {
    dev=/dev/vg0/scratch
    dir=/mnt/scratch
    fstype=ext4
    cipher=aes-xts-plain64
    keyformat=builtin
    keyfile=/etc/cryptmount/scratch.key
    keyhash=sha512
    keycipher=aes-xts-plain64
}
```

```
$ cryptmount-setup           # interactive first-time wizard
$ cryptmount opaque          # as a normal user
Enter password for target "opaque":
$ cryptmount -u opaque
$ cryptmount --change-password opaque
$ cryptmount --list
opaque:
  target-dir=/mnt/opaque
  device=/dev/vg0/opaque
```

`keyformat=luks` significa que la clave vive en la propia cabecera LUKS del dispositivo, así que `cryptmount` se vuelve un frontend de cara al usuario para un volumen LUKS ordinario.

---

## 11. Infraestructura de producción

Todo lo de abajo está completo y es desplegable tal cual está escrito.

### 11.1 Rol de Ansible: aprovisionar un volumen de datos cifrado

```yaml
# roles/luks_volume/defaults/main.yml
---
luks_volumes:
  - name: pgdata
    device: /dev/disk/by-id/nvme-SAMSUNG_MZQL23T8HCLS_S64GNE0T123456
    fstype: xfs
    mountpoint: /srv/pgdata
    label: pgdata-01
    integrity: false
    key_source: vault           # vault | keyfile | passphrase
    vault_path: secret/data/luks/{{ inventory_hostname }}/pgdata

luks_cipher: aes-xts-plain64
luks_key_size: 512
luks_sector_size: 4096
luks_pbkdf: argon2id
luks_pbkdf_memory: 1048576
luks_iter_time: 5000
luks_header_backup_dir: /root/luks-headers
luks_perf_flags: "--perf-no_read_workqueue --perf-no_write_workqueue --persistent"
```

```yaml
# roles/luks_volume/tasks/main.yml
---
- name: Ensure cryptsetup and tooling are present
  ansible.builtin.package:
    name:
      - cryptsetup
      - cryptsetup-initramfs   # Debian family; use dracut on RHEL family
    state: present
  when: ansible_os_family == 'Debian'

- name: Ensure cryptsetup is present (RHEL family)
  ansible.builtin.dnf:
    name:
      - cryptsetup
      - clevis-luks
      - clevis-dracut
    state: present
  when: ansible_os_family == 'RedHat'

- name: Ensure key and header directories exist with strict permissions
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: '0700'
  loop:
    - /etc/luks-keys
    - "{{ luks_header_backup_dir }}"

- name: Detect existing LUKS signature
  ansible.builtin.command:
    cmd: "blkid -p -o value -s TYPE {{ item.device }}"
  register: luks_probe
  changed_when: false
  failed_when: false
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Abort if the device holds unexpected data
  ansible.builtin.fail:
    msg: >-
      {{ item.item.device }} contains signature '{{ item.stdout }}'.
      Refusing to format. Wipe it deliberately if this is intended.
  when:
    - item.stdout | length > 0
    - item.stdout != 'crypto_LUKS'
  loop: "{{ luks_probe.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Fetch or generate the volume key
  ansible.builtin.set_fact:
    luks_keys: "{{ luks_keys | default({}) | combine({item.name: lookup('community.hashi_vault.hashi_vault', item.vault_path ~ ':key')}) }}"
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"
  when: item.key_source == 'vault'
  no_log: true

- name: Write keyfiles
  ansible.builtin.copy:
    content: "{{ luks_keys[item.name] }}"
    dest: "/etc/luks-keys/{{ item.name }}.key"
    owner: root
    group: root
    mode: '0400'
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"
  no_log: true

- name: Format LUKS2 volumes that are not yet formatted
  ansible.builtin.command:
    cmd: >-
      cryptsetup luksFormat --batch-mode --type luks2
      --cipher {{ luks_cipher }}
      --key-size {{ luks_key_size }}
      --sector-size {{ luks_sector_size }}
      --pbkdf {{ luks_pbkdf }}
      --pbkdf-memory {{ luks_pbkdf_memory }}
      --iter-time {{ luks_iter_time }}
      --label {{ item.item.label }}
      {% if item.item.integrity %}--integrity hmac-sha256{% endif %}
      --key-file /etc/luks-keys/{{ item.item.name }}.key
      {{ item.item.device }}
  when: item.stdout != 'crypto_LUKS'
  loop: "{{ luks_probe.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Read volume UUIDs
  ansible.builtin.command:
    cmd: "cryptsetup luksUUID {{ item.device }}"
  register: luks_uuids
  changed_when: false
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Render /etc/crypttab
  ansible.builtin.template:
    src: crypttab.j2
    dest: /etc/crypttab
    owner: root
    group: root
    mode: '0644'
    validate: 'grep -qE "^[^[:space:]#]+[[:space:]]" %s'
  notify:
    - Rebuild initramfs
    - Reload systemd

- name: Open the volumes
  ansible.builtin.command:
    cmd: >-
      cryptsetup open {{ item.item.device }} crypt{{ item.item.name }}
      --key-file /etc/luks-keys/{{ item.item.name }}.key
      {{ luks_perf_flags }}
    creates: "/dev/mapper/crypt{{ item.item.name }}"
  loop: "{{ luks_probe.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Create the filesystem
  community.general.filesystem:
    fstype: "{{ item.fstype }}"
    dev: "/dev/mapper/crypt{{ item.name }}"
    opts: "-L {{ item.label }}"
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Mount the filesystem
  ansible.posix.mount:
    path: "{{ item.mountpoint }}"
    src: "/dev/mapper/crypt{{ item.name }}"
    fstype: "{{ item.fstype }}"
    opts: "defaults,noatime,nofail,x-systemd.requires=/dev/mapper/crypt{{ item.name }}"
    state: mounted
  loop: "{{ luks_volumes }}"
  loop_control:
    label: "{{ item.name }}"

- name: Back up the LUKS headers
  ansible.builtin.command:
    cmd: >-
      cryptsetup luksHeaderBackup {{ item.item.device }}
      --header-backup-file {{ luks_header_backup_dir }}/{{ item.item.name }}-{{ item.stdout }}.img
    creates: "{{ luks_header_backup_dir }}/{{ item.item.name }}-{{ item.stdout }}.img"
  loop: "{{ luks_uuids.results }}"
  loop_control:
    label: "{{ item.item.name }}"

- name: Restrict header backup permissions
  ansible.builtin.file:
    path: "{{ luks_header_backup_dir }}"
    state: directory
    mode: '0700'
    recurse: true
    owner: root
    group: root

- name: Install the LUKS health exporter
  ansible.builtin.copy:
    src: luks-metrics.sh
    dest: /usr/local/bin/luks-metrics.sh
    mode: '0755'

- name: Install the exporter timer
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/systemd/system/{{ item }}"
    mode: '0644'
  loop:
    - luks-metrics.service
    - luks-metrics.timer
  notify: Reload systemd

- name: Enable the exporter timer
  ansible.builtin.systemd:
    name: luks-metrics.timer
    enabled: true
    state: started
    daemon_reload: true
```

```jinja
{# roles/luks_volume/templates/crypttab.j2 #}
# Managed by Ansible — do not edit by hand.
# <name>  <device>  <keyfile>  <options>
{% for vol in luks_volumes %}
{% set uuid = (luks_uuids.results | selectattr('item.name', 'equalto', vol.name) | first).stdout %}
crypt{{ vol.name }}  UUID={{ uuid }}  /etc/luks-keys/{{ vol.name }}.key  luks,discard,no-read-workqueue,no-write-workqueue,nofail,x-systemd.device-timeout=30s
{% endfor %}
```

```yaml
# roles/luks_volume/handlers/main.yml
---
- name: Rebuild initramfs
  ansible.builtin.command:
    cmd: "{{ 'update-initramfs -u -k all' if ansible_os_family == 'Debian' else 'dracut --force' }}"

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
```

### 11.2 cloud-init: cifrar el NVMe efímero en el primer arranque

```yaml
#cloud-config
# Encrypts instance-store NVMe with an ephemeral key generated at boot.
# The key never leaves RAM and never persists: an instance stop wipes the data by design.
package_update: true
packages:
  - cryptsetup
  - xfsprogs

write_files:
  - path: /usr/local/sbin/encrypt-ephemeral.sh
    permissions: '0700'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      TARGET_MOUNT=/var/lib/kubelet-ephemeral
      MAPPER=ephemeral0

      dev=$(lsblk -dpno NAME,MODEL \
            | awk '$2 ~ /Instance Storage|EphemeralDisk/ {print $1; exit}')
      [[ -n "${dev}" ]] || { echo "no ephemeral NVMe found"; exit 0; }

      if [[ -e "/dev/mapper/${MAPPER}" ]]; then
        echo "${MAPPER} already active"; exit 0
      fi

      # Ephemeral key: 64 random bytes held only in a tmpfs that is unmounted below.
      keydir=$(mktemp -d -p /dev/shm)
      chmod 700 "${keydir}"
      trap 'shred -u "${keydir}/key" 2>/dev/null || true; rmdir "${keydir}"' EXIT
      dd if=/dev/urandom of="${keydir}/key" bs=64 count=1 status=none

      cryptsetup luksFormat --batch-mode --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --label ephemeral-scratch \
        --key-file "${keydir}/key" "${dev}"

      cryptsetup open "${dev}" "${MAPPER}" \
        --key-file "${keydir}/key" \
        --perf-no_read_workqueue --perf-no_write_workqueue --allow-discards

      mkfs.xfs -f -L ephemeral "/dev/mapper/${MAPPER}"
      mkdir -p "${TARGET_MOUNT}"
      mount -o noatime,nodiratime "/dev/mapper/${MAPPER}" "${TARGET_MOUNT}"
      echo "encrypted ephemeral volume ready at ${TARGET_MOUNT}"

  - path: /etc/systemd/system/encrypt-ephemeral.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Encrypt and mount instance-store NVMe with an ephemeral key
      DefaultDependencies=no
      After=local-fs.target systemd-udev-settle.service
      Wants=systemd-udev-settle.service
      Before=kubelet.service containerd.service
      ConditionPathExists=!/dev/mapper/ephemeral0

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/sbin/encrypt-ephemeral.sh
      TimeoutStartSec=600

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, encrypt-ephemeral.service ]
```

### 11.3 Kubernetes: un servidor Tang de alta disponibilidad para NBDE

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: nbde
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tang-keys
  namespace: nbde
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ceph-rbd-retain
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tang
  namespace: nbde
  labels:
    app.kubernetes.io/name: tang
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tang
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tang
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: tang
      containers:
        - name: tang
          image: quay.io/sec-eng-special/tang-operator-tang:v1.0.1
          imagePullPolicy: IfNotPresent
          args: ["-l", "-p", "8080", "/var/db/tang"]
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /adv
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /adv
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 250m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: keys
              mountPath: /var/db/tang
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: keys
          persistentVolumeClaim:
            claimName: tang-keys
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
---
apiVersion: v1
kind: Service
metadata:
  name: tang
  namespace: nbde
spec:
  type: LoadBalancer
  loadBalancerIP: 10.42.0.53
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: tang
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tang-ingress
  namespace: nbde
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: tang
  policyTypes: ["Ingress"]
  ingress:
    # Tang's security model relies on network reachability. Restrict it to the
    # management CIDR: a disk that leaves this network cannot self-unlock.
    - from:
        - ipBlock:
            cidr: 10.42.0.0/16
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: tang
  namespace: nbde
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: tang
```

Verificá que el anuncio sea alcanzable desde un nodo antes de ligar nada a él:

```
$ curl -s http://10.42.0.53/adv | jq -r '.payload' | base64 -d | jq '.keys[].kid'
"kWwirxc5PgOKB1cMlwZWRgOa1Aw"
"n3sV5tUqIkO0dZ2GRc9LkQvHfBs"
```

### 11.4 Kubernetes: DaemonSet de verificación de cifrado a nivel de nodo

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: luks-audit
  namespace: kube-system
data:
  audit.sh: |
    #!/usr/bin/env bash
    # Verifies that every mountpoint listed in REQUIRED_ENCRYPTED_PATHS is backed
    # by a dm-crypt mapping, and exports the result as node labels + metrics.
    set -euo pipefail
    : "${REQUIRED_ENCRYPTED_PATHS:=/var/lib/kubelet /var/lib/containerd}"
    OUT=/host/var/lib/node-exporter/textfile/luks.prom
    tmp="${OUT}.$$"

    is_encrypted() {
      local path="$1" src
      src=$(chroot /host findmnt -no SOURCE --target "${path}" 2>/dev/null || true)
      [[ -n "${src}" ]] || return 1
      # Walk the device-mapper stack looking for a 'crypt' target.
      chroot /host lsblk -sno TYPE "${src}" 2>/dev/null | grep -q '^crypt$'
    }

    {
      echo "# HELP node_luks_path_encrypted Whether a required path is on a dm-crypt device."
      echo "# TYPE node_luks_path_encrypted gauge"
      for p in ${REQUIRED_ENCRYPTED_PATHS}; do
        if is_encrypted "${p}"; then v=1; else v=0; fi
        echo "node_luks_path_encrypted{path=\"${p}\"} ${v}"
      done

      echo "# HELP node_luks_keyslots_used Active keyslots per LUKS device."
      echo "# TYPE node_luks_keyslots_used gauge"
      while read -r dev; do
        [[ -n "${dev}" ]] || continue
        uuid=$(chroot /host cryptsetup luksUUID "${dev}" 2>/dev/null || echo unknown)
        slots=$(chroot /host cryptsetup luksDump "${dev}" 2>/dev/null \
                | awk '/^Keyslots:/{f=1;next} /^Tokens:/{f=0} f && /^  [0-9]+: luks/{c++} END{print c+0}')
        echo "node_luks_keyslots_used{device=\"${dev}\",uuid=\"${uuid}\"} ${slots}"
      done < <(chroot /host lsblk -pno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}')

      echo "# HELP node_dm_integrity_failures Integrity check failures reported by dm-integrity."
      echo "# TYPE node_dm_integrity_failures counter"
      while read -r name; do
        [[ -n "${name}" ]] || continue
        f=$(chroot /host integritysetup status "${name}" 2>/dev/null \
            | awk '/failures:/{print $2}')
        echo "node_dm_integrity_failures{mapping=\"${name}\"} ${f:-0}"
      done < <(chroot /host dmsetup ls --target integrity 2>/dev/null | awk '{print $1}')
    } > "${tmp}"
    mv "${tmp}" "${OUT}"
    cat "${OUT}"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: luks-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/name: luks-audit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: luks-audit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: luks-audit
    spec:
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      containers:
        - name: audit
          image: registry.access.redhat.com/ubi9/ubi-minimal:9.4
          command: ["/bin/bash", "-c"]
          args:
            - |
              while true; do
                /scripts/audit.sh || echo "audit failed" >&2
                sleep 300
              done
          env:
            - name: REQUIRED_ENCRYPTED_PATHS
              value: "/var/lib/kubelet /var/lib/containerd /srv/pgdata"
          securityContext:
            privileged: true      # required: chroot into the host and read device-mapper state
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: host
              mountPath: /host
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: host
          hostPath:
            path: /
            type: Directory
        - name: scripts
          configMap:
            name: luks-audit
            defaultMode: 0755
```

### 11.5 Alertas de Prometheus

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: disk-encryption
  namespace: monitoring
  labels:
    prometheus: platform
    role: alert-rules
spec:
  groups:
    - name: disk-encryption
      interval: 60s
      rules:
        - alert: NodePathNotEncrypted
          expr: node_luks_path_encrypted == 0
          for: 10m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "{{ $labels.path }} on {{ $labels.instance }} is not on an encrypted device"
            description: >-
              A path required to be encrypted at rest is backed by a plaintext block
              device. Cordon the node and investigate before scheduling stateful workloads.
            runbook_url: "https://runbooks.internal/platform/luks-not-encrypted"

        - alert: LUKSKeyslotCountAnomalous
          expr: node_luks_keyslots_used > 6 or node_luks_keyslots_used < 2
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.device }} on {{ $labels.instance }} has {{ $value }} keyslots"
            description: >-
              Expected between 2 and 6 keyslots (automation, recovery, break-glass).
              Fewer means no fallback path; more may indicate an unauthorised enrolment.

        - alert: DMIntegrityFailuresDetected
          expr: increase(node_dm_integrity_failures[15m]) > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "dm-integrity detected {{ $value }} failures on {{ $labels.mapping }}"
            description: >-
              Sectors failed authentication. This is either media failure or tampering.
              Fail the node out of the pool and preserve it for analysis.

        - alert: LUKSHeaderBackupStale
          expr: (time() - node_luks_header_backup_mtime_seconds) > 86400 * 30
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "LUKS header backup for {{ $labels.device }} is older than 30 days"
```

---

## 12. Verificación y diagnóstico

### 12.1 La escalera de verificación

Cada peldaño prueba estrictamente más que el de abajo. Sabé sobre qué peldaño se apoya cada afirmación.

| # | Afirmación | Comando | Costo |
|---|---|---|---|
| 1 | Existe un dispositivo LUKS | `blkid -p -s TYPE <dev>` → `crypto_LUKS` | gratis |
| 2 | Tiene los parámetros que pretendíamos | `cryptsetup luksDump <dev>` | gratis |
| 3 | El mapeo está activo con las banderas correctas | `cryptsetup status <name>`, `dmsetup table <name>` | gratis |
| 4 | La ruta montada está *realmente* sobre ese mapeo | `lsblk -s -o NAME,TYPE $(findmnt -no SOURCE --target /srv/pgdata)` | gratis |
| 5 | El texto cifrado realmente es texto cifrado | verificación de entropía sobre el dispositivo crudo (abajo) | gratis |
| 6 | Cada ruta de desbloqueo funciona **de forma independiente** | `cryptsetup open --test-passphrase --key-slot N` por cada slot | gratis |
| 7 | La copia de la cabecera restaura | Restaurar sobre un clon en un dispositivo loop y abrirlo | minutos |
| 8 | La ruta de arranque funciona desatendida | **Reiniciar el nodo** | un reinicio |
| 9 | La detección de manipulación funciona | Corromper un sector en un volumen de integridad de prueba y leerlo | destructivo, solo en pruebas |

Los peldaños 6–8 son los que los equipos se saltan, y son los que fallan a las 03:00. **Una ruta de desbloqueo que nunca se ejercitó no es una ruta de desbloqueo.**

El peldaño 4 en una línea — esta es la verificación que atrapa el «ciframos el disco equivocado»:

```
$ findmnt -no SOURCE --target /srv/pgdata | xargs lsblk -s -o NAME,TYPE,FSTYPE
NAME        TYPE  FSTYPE
pgdata      crypt xfs
└─nvme1n1   disk  crypto_LUKS
```

Peldaño 5 — el texto en claro tiene estructura, el cifrado no:

```
$ sudo dd if=/dev/nvme1n1 bs=1M skip=64 count=8 status=none | ent
Entropy = 7.999978 bits per byte.
Optimum compression would reduce the size of this 8388608 byte file by 0 percent.
Chi square distribution for 8388608 samples is 251.44, and randomly would exceed this value 55.12 percent of the time.
Arithmetic mean value of data bytes is 127.4989 (127.5 = random).
Monte Carlo value for Pi is 3.141472816 (error 0.00 percent).
Serial correlation coefficient is -0.000041 (totally uncorrelated = random).
```

Una entropía por debajo de ~7,9, o cualquier cadena reconocible, significa que estás mirando texto en claro:

```
$ sudo strings -n 12 /dev/nvme1n1 | head -5     # should produce nothing meaningful
```

### 12.2 Catálogo de fallos

| Síntoma | Causa raíz | Diagnóstico | Solución |
|---|---|---|---|
| `No key available with this passphrase.` | Passphrase incorrecta, o el slot fue eliminado, o un keyfile tiene un salto de línea final | `cryptsetup luksDump` (contar slots); `xxd -l 16 keyfile` | Usar otro slot; `--keyfile-size` para excluir `\n` |
| `Device /dev/X is not a valid LUKS device.` | Cabecera sobrescrita (un `mkfs` perdido, una reescritura de tabla de particiones, un `dd`) | `xxd -l 8 /dev/X` — esperar `4c55 4b53 baba` | `luksHeaderRestore` desde el backup. **Sin backup = sin datos** |
| `Requested header backup file already exists.` | Colisión de ruta de backup | `ls -l` | Versionar por UUID y fecha |
| El arranque se cuelga en `A start job is running for /dev/disk/by-uuid/…` | Dispositivo subyacente ausente o renombrado | `journalctl -b -u systemd-cryptsetup@*`; `blkid` desde la shell de emergencia | Corregir el UUID del crypttab; agregar `x-systemd.device-timeout` y `nofail` |
| El arranque cae a la shell de emergencia tras una actualización de firmware | La política de PCR de TPM2 ya no satisface el sellado | `journalctl -b \| grep -i tpm2`; `systemd-analyze pcrs` | Desbloquear con la clave de recuperación, luego volver a enrolar: `systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto` |
| El desellado de TPM falla de forma intermitente | `tpm2-abrmd` compitiendo, o el PCR 1 cambiando con la RAM/orden de arranque | `tpm2_pcrread sha256:0,1,4,7,14` a lo largo de varios arranques | Ligar solo al PCR 7; agregar una clave de recuperación |
| El volumen abre pero `mount` dice `wrong fs type, bad superblock` | Discrepancia de parámetros del modo plano — estás descifrando a basura | `blkid /dev/mapper/x` devuelve vacío; `xxd` muestra ruido | Volver a derivar el `--cipher/--hash/--key-size/--offset` exacto |
| Rendimiento NVMe terrible tras habilitar el cifrado | Workqueues, sectores de 512 B, o AES por software | `cryptsetup status` (banderas, tamaño de sector); `grep aes /proc/crypto` | `--perf-no_*_workqueue --persistent`; recifrar a 4096 B |
| `Device pgdata is still in use.` al cerrar | Un descriptor abierto, una capa LVM/dm apilada, o un montaje en otro namespace | `lsof +D /srv/pgdata`; `dmsetup deps -o devname pgdata`; `findmnt -A` | Desmontar todo lo que está por encima primero |
| `Input/output error` + `Checksum failed at sector` | dm-integrity detectó modificación o fallo de medio | `dmesg -T \| grep -i integrity`; `integritysetup status` | Sacar el nodo del pool; restaurar desde réplica |
| Errores de E/S en todo el dispositivo justo después de `--integrity-no-wipe` | Los sectores nunca recibieron etiquetas válidas | `dmesg` muestra fallos en regiones nunca tocadas | Reformatear con el borrado, o escribir el dispositivo entero |
| eCryptfs: `Error attempting to evaluate mount options` | FEKEK/FNEK no está en el keyring | `keyctl list @u` | `ecryptfs-add-passphrase --fnek` antes de montar |
| Home de eCryptfs vacío tras el login | Falta `pam_ecryptfs` en la pila de session, o la passphrase envuelta está desincronizada | `journalctl -b \| grep ecryptfs`; `mount \| grep ecryptfs` | Arreglar la pila PAM; `ecryptfs-rewrap-passphrase` |
| eCryptfs: `File name too long` | El cifrado de nombres infla los nombres; límite de ~143 caracteres | Reproducir con un nombre largo | Acortar nombres, o pasarse a fscrypt |
| `cryptsetup resize` pide una passphrase en la automatización | La clave maestra no está en el keyring del kernel | `cryptsetup status \| grep 'key location'` | Asegurar la bandera de compilación `KEYRING`; evitar `--disable-keyring` |
| GRUB no puede desbloquear un `/boot` LUKS2 | Keyslots Argon2 | `luksDump` muestra `PBKDF: argon2id` | Agregar un slot PBKDF2: `luksAddKey --pbkdf pbkdf2` |
| La hibernación no logra reanudar | Swap con clave aleatoria | `cryptsetup status cryptswap` muestra `type: PLAIN` | Mover el swap dentro del volumen LUKS, configurar `resume=` |

### 12.3 El conjunto de comandos de diagnóstico

```
# Layer identification, top to bottom
$ lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS,LABEL
$ findmnt --real
$ sudo dmsetup ls --tree -o devname
pgdata (253:5)
 └─ (259:1)
cryptroot (253:0)
 └─ (259:0)

# What the kernel thinks the mapping is
$ sudo dmsetup info -c
Name            Maj Min Stat Open Targ Event  UUID
pgdata          253   5 L--w    1    1      0 CRYPT-LUKS2-9f4e1c2a3b7d4a1e9c052f8a6d4b1e77-pgdata
cryptroot       253   0 L--w    2    1      0 CRYPT-LUKS2-1c4a90f27ee14b3a8b0f6dd4a2c5c101-cryptroot

# Crypto backend actually in use
$ grep -B1 -A6 'driver.*aesni' /proc/crypto | head -20

# Boot-time unlock evidence
$ journalctl -b -u 'systemd-cryptsetup@*' --no-pager
$ journalctl -b -g 'cryptsetup|dm-crypt|integrity|tpm2' --no-pager | tail -40

# TPM state
$ sudo tpm2_pcrread sha256:0,1,4,7,11,14
sha256:
  0 : 0x3D458CFE55CC03EA1F443F1562BEEC8DF51C75E14A9FCF9A7234A13F198E7969
  1 : 0xE7A4A2C21F0F6C1CB57ED6B9AF4AC03D2A8B0DAF95F0C6BCD0EE4E9E6B1E2A11
  4 : 0x4C1FE1C0B0E5DEDF9C0C4D6D4A0C0C4B7C1A0F1E9D8C7B6A5F4E3D2C1B0A9988
  7 : 0x5C5A8F0C8B0FA2C0D3A9E1B7C2D4F6A8B0C2D4E6F8A0B2C4D6E8F0A2B4C6D8E0
 11 : 0x0000000000000000000000000000000000000000000000000000000000000000
 14 : 0x9B7C5E3A1F0D2B4C6E8A0C2E4F6A8B0D2E4F6A8C0E2F4A6B8D0E2F4A6C8E0F2A

# Keyring (eCryptfs and dm-crypt)
$ keyctl show @u
$ sudo keyctl show @s

# Prove there is no plaintext leak on the raw device
$ sudo dd if=/dev/nvme1n1 bs=1M skip=100 count=4 status=none | gzip -c | wc -c
4194638      # ~incompressible → ciphertext
```

### 12.4 Emergencia: recuperar un volumen LUKS desde un entorno de rescate

```
$ sudo cryptsetup luksDump /dev/nvme1n1 || echo "header damaged"
$ sudo cryptsetup repair /dev/nvme1n1
Do you really want to repair the LUKS device header? (Type 'yes' in capital letters): YES
Only metadata area 1 is valid.
Header restored from secondary header.

# If repair fails, restore from the offline backup onto a clone first.
$ sudo dd if=/dev/nvme1n1 of=/mnt/rescue/pgdata.img bs=64M status=progress
$ sudo losetup -f --show /mnt/rescue/pgdata.img
/dev/loop0
$ sudo cryptsetup luksHeaderRestore /dev/loop0 --header-backup-file /mnt/rescue/pgdata-01.img
$ sudo cryptsetup open /dev/loop0 rescue
$ sudo mount -o ro /dev/mapper/rescue /mnt/recovered
```

Nunca restaures una cabecera sobre el dispositivo de producción hasta haberlo probado en un clon. Una cabecera equivocada sobre el disco real y sin backup termina mal el incidente.

Extracción de la clave maestra como último recurso, para un volumen que todavía podés abrir pero cuyas passphrases estás por perder — tratá la salida como las joyas de la corona:

```
$ sudo cryptsetup luksDump --dump-master-key /dev/nvme1n1

WARNING!
========
The header dump with volume key is sensitive information
that allows access to encrypted partition without a passphrase.
This dump should be stored encrypted in a safe place.

Are you sure? (Type 'yes' in capital letters): YES
Enter passphrase for /dev/nvme1n1:
LUKS header information for /dev/nvme1n1
Cipher name:    aes
Cipher mode:    xts-plain64
Payload offset: 32768
UUID:           9f4e1c2a-3b7d-4a1e-9c05-2f8a6d4b1e77
MK bits:        512
MK dump:        8f 3a c1 90 2e 74 bd 05 61 aa 3c 7f d2 18 96 e4
                0b 55 7d 21 c9 46 8e f3 1a 60 b2 4c 07 d9 35 8a
                ...
```

El volumen puede entonces reabrirse con `cryptsetup open --master-key-file` incluso con todos los keyslots destruidos. Lo que también significa: **quien tenga este volcado es dueño de los datos para siempre**, y ninguna rotación de keyslots lo revocará jamás. Solo un `cryptsetup reencrypt` completo lo hace.

---

## 13. Trampas del examen y chuleta de comandos

### 13.1 Las trampas

1. **`--key-size 512` es AES-256**, porque XTS usa dos claves. Esperá esto en una pregunta.
2. **LUKS1 tiene 8 keyslots, LUKS2 tiene 32.** LUKS1 es solo PBKDF2; LUKS2 usa Argon2id por defecto.
3. **`luksErase` no es `luksKillSlot`.** El primero destruye todos los keyslots; el segundo destruye uno.
4. **`cryptsetup luksFormat` destruye los datos existentes**; `cryptsetup reencrypt --encrypt` los preserva.
5. **dm-crypt plano no tiene cabecera** — sin `luksDump`, sin cambio de clave, sin segunda passphrase.
6. **El orden de campos de `/etc/crypttab` es `name device keyfile options`**, la imagen especular del `device mountpoint fstype options` de `/etc/fstab`.
7. **`keyscript=` es una extensión de `cryptsetup` de Debian**; `systemd-cryptsetup` la ignora. `initramfs` es igualmente solo de Debian.
8. **`swap` en crypttab reformatea el dispositivo en cada arranque** — con una verificación de seguridad para firmas existentes.
9. **eCryptfs tiene dos claves**: FEKEK para el contenido, FNEK para los nombres de archivo. Cada *archivo* tiene además su propia FEK aleatoria.
10. **`ecryptfs-setup-private` envuelve la passphrase de montaje con la passphrase de login.** Un `passwd` forzado por root rompe el desenvolvimiento; `ecryptfs-rewrap-passphrase` y la passphrase de montaje registrada son las vías de escape.
11. **`pam_ecryptfs.so` aparece en las pilas `auth`, `session` y `password`** — con trabajos distintos en cada una.
12. **`systemd-cryptenroll` escribe tokens LUKS2**, y los tokens son una característica exclusiva de LUKS2.
13. **Las copias de cabecera contienen keyslots.** Revocar una passphrase no la revoca de una copia vieja.

### 13.2 Chuleta de comandos

```
# ─── LUKS lifecycle ───────────────────────────────────────────────────────
cryptsetup benchmark
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 \
           --sector-size 4096 --pbkdf argon2id --iter-time 5000 DEV
cryptsetup open DEV NAME                     # was luksOpen
cryptsetup close NAME                        # was luksClose
cryptsetup status NAME
cryptsetup luksDump DEV
cryptsetup luksUUID DEV
cryptsetup isLuks DEV && echo yes

# ─── Keys ─────────────────────────────────────────────────────────────────
cryptsetup luksAddKey DEV [NEWKEYFILE]
cryptsetup luksChangeKey DEV --key-slot N
cryptsetup luksRemoveKey DEV [KEYFILE]       # by passphrase
cryptsetup luksKillSlot DEV N                # by slot number
cryptsetup luksErase DEV                     # ALL slots — irreversible
cryptsetup open --test-passphrase --key-slot N DEV
cryptsetup config --key-slot N --priority prefer|normal|ignore DEV

# ─── Header ───────────────────────────────────────────────────────────────
cryptsetup luksHeaderBackup DEV --header-backup-file FILE
cryptsetup luksHeaderRestore DEV --header-backup-file FILE
cryptsetup repair DEV
cryptsetup open --header FILE DEV NAME       # detached header

# ─── LUKS2 features ───────────────────────────────────────────────────────
cryptsetup convert --type luks2 DEV
cryptsetup luksConvertKey --pbkdf argon2id --key-slot N DEV
cryptsetup reencrypt DEV                         # rotate master key
cryptsetup reencrypt --encrypt --reduce-device-size 32M DEV
cryptsetup reencrypt --decrypt --header FILE DEV
cryptsetup reencrypt --resume-only DEV
cryptsetup resize NAME
cryptsetup luksSuspend NAME ; cryptsetup luksResume NAME
cryptsetup token add|remove|import|export DEV

# ─── Plain mode & integrity ───────────────────────────────────────────────
cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 \
           --hash sha512 --offset 0 --skip 0 DEV NAME
integritysetup format --integrity sha256 --tag-size 32 DEV
integritysetup open --integrity sha256 DEV NAME
integritysetup status NAME

# ─── Boot integration ─────────────────────────────────────────────────────
$EDITOR /etc/crypttab ; systemctl daemon-reload
systemd-cryptenroll DEV --tpm2-device=auto --tpm2-pcrs=7
systemd-cryptenroll DEV --fido2-device=auto
systemd-cryptenroll DEV --recovery-key
systemd-cryptenroll DEV --wipe-slot=tpm2|password|empty|N
update-initramfs -u -k all      # Debian
dracut --force                  # RHEL

# ─── eCryptfs ─────────────────────────────────────────────────────────────
mount -t ecryptfs LOWER UPPER -o ecryptfs_cipher=aes,ecryptfs_key_bytes=32,...
umount.ecryptfs UPPER
ecryptfs-setup-private
ecryptfs-mount-private ; ecryptfs-umount-private
ecryptfs-add-passphrase [--fnek]
ecryptfs-wrap-passphrase   FILE
ecryptfs-unwrap-passphrase FILE
ecryptfs-rewrap-passphrase FILE
ecryptfs-migrate-home -u USER
ecryptfs-recover-private [PATH]
ecryptfs-stat FILE
ecryptfs-manager
keyctl list @u

# ─── cryptmount ───────────────────────────────────────────────────────────
cryptmount-setup
cryptmount TARGET ; cryptmount -u TARGET
cryptmount --change-password TARGET
cryptmount --generate-key SIZE TARGET
```

---

## 14. Autoevaluación

1. Un volumen LUKS2 muestra `Cipher key: 512 bits` con `aes-xts-plain64`. ¿Qué longitud de clave AES está en uso, y por qué?
2. Rotás la passphrase de un volumen con `luksChangeKey`. Un atacante exfiltró la clave maestra hace tres meses. ¿Queda afuera? ¿Cuál es la única remediación?
3. ¿Por qué destruir un keyslot exige sobrescribir ~256 KiB en lugar de 64 bytes?
4. Un nodo con `/boot` sobre LUKS2 falla en el prompt de GRUB después de que convertís sus keyslots a Argon2id. Explicalo y dá dos soluciones.
5. Escribí la línea de `/etc/crypttab` para una partición de swap cifrada con una clave aleatoria fresca en cada arranque, usando un identificador de dispositivo estable. ¿Qué capacidad elimina esto?
6. Un `dd` del dispositivo crudo muestra entropía 7,9998 en una región y 5,2 en otra. ¿Cuáles son las explicaciones plausibles, y cuáles son benignas?
7. Distinguí FEK, FEKEK y FNEK en eCryptfs. ¿Cuál se almacena dónde?
8. Un administrador root resetea la contraseña de un usuario con `passwd`. El usuario inicia sesión y encuentra un directorio home vacío. ¿Qué pasó, y cuáles son las dos rutas de recuperación?
9. Tu flota usa `--tpm2-pcrs=0+7`. Un fabricante publica una actualización de firmware. Predecí el resultado y diseñá una política más segura.
10. Nombrá dos cosas contra las que `dm-integrity` protege y LUKS a secas no, y dos operaciones que vuelve imposibles.
11. ¿Cuándo elegirías fscrypt sobre dm-crypt? ¿Sobre eCryptfs? Dá un escenario donde correrías dm-crypt *y* fscrypt en la misma máquina.
12. `cryptsetup close vault` devuelve `Device vault is still in use.` después de que `umount` tuvo éxito. Enumerá tres comandos que identificarían a quien lo retiene.

---

## 15. Referencias

**Objetivos de certificación**
- LPI, *Exam 303: Security, Objectives (version 3.0)* — https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI, *LPIC-3 Security certification overview* — https://www.lpi.org/our-certifications/lpic-3-security-overview/

**cryptsetup / LUKS (upstream)**
- Proyecto cryptsetup — https://gitlab.com/cryptsetup/cryptsetup
- Wiki de cryptsetup (índice de documentación) — https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home
- FAQ de cryptsetup (la referencia operativa autoritativa) — https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions
- Especificación del formato en disco de LUKS2 — https://gitlab.com/cryptsetup/LUKS2-docs
- `cryptsetup(8)` — https://man7.org/linux/man-pages/man8/cryptsetup.8.html
- `cryptsetup-reencrypt(8)` — https://man7.org/linux/man-pages/man8/cryptsetup-reencrypt.8.html
- `integritysetup(8)` — https://man7.org/linux/man-pages/man8/integritysetup.8.html

**Documentación del kernel**
- `dm-crypt` — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-crypt.html
- `dm-integrity` — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-integrity.html
- Panorama de device-mapper — https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html
- Cifrado a nivel de sistema de archivos (fscrypt) — https://www.kernel.org/doc/html/latest/filesystems/fscrypt.html
- eCryptfs — https://www.kernel.org/doc/html/latest/filesystems/ecryptfs.html
- Keyring del kernel (`keyrings/core`) — https://www.kernel.org/doc/html/latest/security/keys/core.html

**systemd**
- `crypttab(5)` — https://www.freedesktop.org/software/systemd/man/latest/crypttab.html
- `systemd-cryptsetup@.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptsetup@.service.html
- `systemd-cryptsetup-generator(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptsetup-generator.html
- `systemd-cryptenroll(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html
- `systemd-pcrphase` / medición de PCR con TPM2 — https://www.freedesktop.org/software/systemd/man/latest/systemd-pcrphase.service.html

**eCryptfs y herramientas de espacio de usuario**
- Proyecto eCryptfs (ecryptfs-utils) — https://launchpad.net/ecryptfs
- `ecryptfs(7)` — https://man7.org/linux/man-pages/man7/ecryptfs.7.html
- `mount.ecryptfs(8)` — https://man7.org/linux/man-pages/man8/mount.ecryptfs.8.html
- `ecryptfs-setup-private(1)` — https://manpages.ubuntu.com/manpages/noble/en/man1/ecryptfs-setup-private.1.html
- `pam_ecryptfs(8)` — https://manpages.ubuntu.com/manpages/noble/en/man8/pam_ecryptfs.8.html
- Herramienta de espacio de usuario fscrypt — https://github.com/google/fscrypt
- cryptmount — https://cryptmount.sourceforge.net/
- gocryptfs — https://nuetzlich.net/gocryptfs/

**Cifrado de disco ligado a la red**
- Clevis — https://github.com/latchset/clevis
- Tang — https://github.com/latchset/tang
- Red Hat, *Configuring automated unlocking of encrypted volumes using policy-based decryption* — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/configuring-automated-unlocking-of-encrypted-volumes-using-policy-based-decryption_security-hardening

**Estándares**
- NIST SP 800-38E, *XTS-AES Mode for Confidentiality on Storage Devices* — https://csrc.nist.gov/pubs/sp/800/38/e/final
- RFC 9106, *Argon2 Memory-Hard Function for Password Hashing and Proof-of-Work* — https://www.rfc-editor.org/rfc/rfc9106.html
- RFC 8018, *PKCS #5: Password-Based Cryptography Specification v2.1* — https://www.rfc-editor.org/rfc/rfc8018.html
- NIST SP 800-88r1, *Guidelines for Media Sanitization* (borrado criptográfico) — https://csrc.nist.gov/pubs/sp/800/88/r1/final

**Guías de fabricantes y de la comunidad**
- Red Hat, *Encrypting block devices using LUKS* — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/encrypting-block-devices-using-luks_security-hardening
- Debian, *Disk encryption* — https://wiki.debian.org/DiskEncryption
- Wiki de Arch Linux, *dm-crypt* (referencia comunitaria, inusualmente exhaustiva) — https://wiki.archlinux.org/title/Dm-crypt
- Cloudflare, *Speeding up Linux disk encryption* (origen de las banderas de bypass de workqueues) — https://blog.cloudflare.com/speeding-up-linux-disk-encryption/
- OpenZFS, *Encryption* — https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html#encryption