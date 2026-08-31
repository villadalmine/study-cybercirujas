# 104.6 — Crear y cambiar enlaces duros y simbólicos

**Certificación:** LPIC-1 (Exámenes 101-500 + 102-500), versión 5.0
**Peso del tema:** 3.12
**Nivel:** Avanzado / SRE de producción — Arquitecto de plataforma

---

## 1. El problema arquitectónico

Todo layout de sistema de archivos en producción termina teniendo que responder una pregunta: **cuando dos rutas deben referirse a los mismos bytes, ¿cuál de las dos rutas es la dueña?**

La respuesta ingenua — copiar el archivo — falla en tres ejes simultáneamente:

1. **Consistencia.** Dos copias divergen. Un certificado TLS copiado en tres directorios de servicio son tres certificados en el instante en que una renovación tiene éxito y dos fallan.
2. **Espacio y tiempo.** Un backup de 40 GB que es 99,4% idéntico al de ayer son 40 GB de escrituras, 40 GB de disco y 40 GB de ancho de banda de lectura al restaurar.
3. **Atomicidad del cambio.** Sobrescribir un archivo vivo in situ no es atómico. Un lector puede observar una configuración escrita a medias. Un deploy que copia una release nueva sobre la que está corriendo tiene una ventana medida en segundos donde el directorio de la aplicación no es ni la release vieja ni la nueva.

Los enlaces son la respuesta del kernel. No son una característica de conveniencia: son la primitiva con la que los siguientes mecanismos de producción **están construidos**, no simplemente decorados:

| Mecanismo | Qué hace realmente el enlace |
|---|---|
| `systemctl enable foo.service` | Crea `/etc/systemd/system/multi-user.target.wants/foo.service` → el archivo de unidad. "Habilitado" *es* el symlink. |
| `update-alternatives` de Debian/Ubuntu | Indirección de symlinks en dos niveles: `/usr/bin/editor` → `/etc/alternatives/editor` → `/usr/bin/vim.basic` |
| Volúmenes de ConfigMap/Secret en Kubernetes | kubelet escribe un directorio con marca de tiempo e intercambia un symlink `..data` con `rename(2)`. Ese intercambio es la actualización atómica de la configuración. |
| `/var/log/containers/*.log` | Granja de symlinks que apunta a `/var/log/pods/`, que a su vez apunta a los archivos de log del container runtime. Todo log shipper del cluster depende de esta cadena. |
| Snapshots con `rsync --link-dest` | Los archivos sin cambios quedan **enlazados duro** al snapshot anterior. 30 snapshots diarios de un árbol de 40 GB pueden costar 41 GB en total. |
| `/etc/localtime` | Symlink a `/usr/share/zoneinfo/…`. La zona horaria de la máquina es el destino de un symlink. |
| Directorios de release blue/green | `current` → `releases/<id>`, intercambiado con `rename(2)`. El rollback es una sola syscall. |
| `/dev/stdout` en contenedores | `/dev/stdout` → `/proc/self/fd/1`. El log-a-stdout en una imagen se implementa enlazando simbólicamente el archivo de log. |
| Archivos borrados pero abiertos | Un archivo con link count 0 y un descriptor abierto sigue consumiendo disco. Esta es la causa más común de "`df` dice lleno, `du` dice vacío". |

Entender los enlaces no es, entonces, una habilidad de manipulación de archivos. Es cómo se razona sobre **el cambio atómico de configuración, la economía de los snapshots, los pipelines de logs y la contabilidad del espacio en disco**.

---

## 2. Mecánica: el inode, la entrada de directorio y la resolución de rutas

### 2.1 Un archivo no tiene nombre

En un sistema de archivos POSIX, un archivo es un **inode**: un registro numerado que contiene los bits de modo, la propiedad, las marcas de tiempo, el tamaño, el link count y los punteros a los bloques de datos. El inode no contiene **ningún nombre**.

Un **directorio** es un archivo cuyo contenido es una tabla de pares `(nombre → número de inode)`. Esos pares se llaman **entradas de directorio** (dentries, o *enlaces*).

```
directory /srv/data              inode 1442093
+---------------------------+    +------------------------------+
| "report.log"   -> 1442093 |--->| mode  -rw-r--r--             |
| "report.bak"   -> 1442093 |--->| uid/gid 1000/1000            |
| "report.link"  -> 1442097 |-+  | nlink 2                      |
+---------------------------+ |  | size  4096                   |
                              |  | blocks -> [ data ]           |
                              |  +------------------------------+
                              |
                              +->  inode 1442097
                                  +------------------------------+
                                  | mode  lrwxrwxrwx             |
                                  | size  10                     |
                                  | data  "report.log"           |
                                  +------------------------------+
```

- `report.log` y `report.bak` son **dos enlaces duros a un mismo inode**. Ninguno es "el original". `nlink` es 2.
- `report.link` es un **enlace simbólico**: un inode *distinto*, de tipo `S_IFLNK`, cuyos datos son la cadena literal `report.log`.

### 2.2 Qué significa realmente `unlink()`

`rm` no borra archivos. Llama a `unlink(2)`, que elimina una entrada de directorio y decrementa el link count del inode. El kernel libera los bloques de datos solo cuando se cumplen **ambas** condiciones:

```
nlink == 0   AND   no process holds an open file descriptor
```

Por eso `rm huge.log` sobre un archivo que `nginx` todavía tiene abierto libera exactamente cero bytes — y por eso existe `lsof +L1` (§6.5).

### 2.3 Resolución de rutas y seguimiento de symlinks

Cuando el VFS recorre una ruta y encuentra un componente que es un symlink, sustituye la cadena de destino del enlace y continúa. Consecuencias que importan en producción:

- **Los destinos relativos de un symlink se resuelven desde el directorio que contiene el enlace**, no desde el CWD del proceso. `ln -s ../conf/app.yaml /srv/app/current/app.yaml` resuelve contra `/srv/app/current/`, no contra el lugar desde el que ejecutaste el comando.
- La resolución está acotada. Linux limita el recorrido anidado de symlinks a **40** (`MAXSYMLINKS`); superarlo devuelve `ELOOP`.
- La resolución ocurre **en el mount namespace del proceso que hace la lectura**. Un symlink dentro de un contenedor que apunta a `/var/log/pods/...` queda colgado a menos que `/var/log/pods` también esté montado dentro de ese contenedor. Esta es la causa número 1 de log shippers vacíos en Kubernetes (§4.4).

### 2.4 Link counts de directorios

El `nlink` de un directorio es `2 + cantidad_de_subdirectorios`: uno por su propio nombre en el padre, uno por su `.`, y uno por el `..` de cada hijo.

```
$ stat -c '%h %n' /srv/app
5 /srv/app
$ ls -1d /srv/app/*/ | wc -l
3
```

`2 + 3 = 5`. Es una pregunta favorita de examen y una verificación de sanidad genuinamente útil sobre un sistema de archivos corrupto.

---

## 3. Enlaces duros vs enlaces simbólicos vs las alternativas modernas

### 3.1 La comparación central

| Propiedad | Enlace duro | Enlace simbólico |
|---|---|---|
| Tipo de objeto | Otra entrada de directorio para un inode existente | Un inode nuevo de tipo `S_IFLNK` que contiene una cadena de ruta |
| Número de inode | **Idéntico** al del destino | Propio y distinto |
| Carácter de tipo en `ls -l` | `-` (indistinguible de cualquier otro nombre) | `l` |
| Entre sistemas de archivos | **No** — `EXDEV` | Sí |
| Puede apuntar a un directorio | **No** — `EPERM` (solo el kernel crea `.`/`..`) | Sí |
| Puede quedar colgado | No, por construcción | **Sí** — el destino es solo una cadena |
| Sobrevive al renombrado/movimiento del destino | **Sí** — *es* el archivo | **No** — la cadena ya no resuelve |
| Sobrevive al borrado del destino | Sí (los datos viven mientras `nlink > 0`) | No — queda como enlace roto |
| Costo en disco | Una entrada de directorio (~decenas de bytes) | Un inode; la cadena de destino va inline si mide < 60 bytes en ext4 ("fast symlink"), si no, un bloque de datos |
| Efecto de `chmod`/`chown` | Afecta a **todos** los nombres — hay un solo inode | Afecta al *destino* salvo que se use `-h`/`--no-dereference` |
| Permisos del enlace en sí | N/A — son los permisos del inode | Siempre `lrwxrwxrwx`, Linux los ignora (pero **la propiedad importa**, ver `fs.protected_symlinks`) |
| Tamaño que reporta `ls -l` | El tamaño del archivo | La longitud en bytes de la cadena de destino |
| Contabilidad de `du` | Se cuenta **una vez** por inode y por recorrido | Se cuenta como el inode del enlace (normalmente 0 bloques) |
| Creación sin privilegios | Restringida por `fs.protected_hardlinks` | Sin restricciones |
| Cantidad máxima | ext4: 65 000; XFS: 2³²−1 | Sin límite |
| Semántica de backup | `tar`/`rsync -H` deben detectarlos y volver a enlazarlos | Se almacena literalmente como una cadena |
| Modo de fallo cuando se usa mal | Divergencia silenciosa de "copias" que son un único archivo | `ENOENT` sobre una ruta que `ls` muestra como existente |

### 3.2 El espectro completo de compartición — entre qué elige realmente un arquitecto

Los enlaces duros y los symlinks son dos de las cuatro maneras de hacer que un mismo conjunto de bytes sea alcanzable desde dos rutas. Elegir el equivocado es un defecto de diseño, no un error de tipeo.

| | Enlace duro | Enlace simbólico | Reflink (copia CoW) | Bind mount |
|---|---|---|---|---|
| Comando | `ln a b` | `ln -s a b` | `cp --reflink=always a b` | `mount --bind a b` |
| Sistemas de archivos | ext4, XFS, btrfs, … | todos | XFS (reflink=1), btrfs, bcachefs | todos |
| Entre sistemas de archivos | no | sí | no | sí |
| Comparte un inode | **sí** | no | **no** — inodes separados, extents compartidos | no (muestra el mismo inode a través de un segundo mount) |
| Escribir en una ruta afecta a la otra | **sí** — mismos datos | sí (las escrituras van al destino) | **no** — el copy-on-write rompe la compartición por bloque | sí |
| Espacio al crearlo | ~0 | ~0 | ~0 | ~0 |
| Sobrevive al reinicio | sí | sí | sí | **no** — necesita `/etc/fstab` o una unidad `.mount` |
| Funciona sobre directorios | no | sí | `cp -a --reflink` recurre | **sí**, de forma nativa |
| Uso típico | snapshots con dedup, payloads de paquetes | punteros a una versión elegida | clones escribibles baratos de datasets grandes | exponer una ruta dentro de un namespace/contenedor |

**La regla arquitectónica:** si las dos rutas deben divergir al escribir, un enlace duro está mal y un reflink está bien. Si una ruta debe permanecer como *puntero a la versión que sea la actual*, un symlink está bien y un enlace duro directamente no puede expresarlo. Si la compartición debe cruzar un sistema de archivos o un mount namespace, solo califican los symlinks y los bind mounts.

### 3.3 `ln` — la superficie completa de flags

| Flag | Forma larga | Efecto |
|---|---|---|
| *(ninguno)* | | Crea un enlace duro |
| `-s` | `--symbolic` | Crea un enlace simbólico |
| `-f` | `--force` | Elimina primero un destino existente |
| `-i` | `--interactive` | Pregunta antes de eliminar un destino existente |
| `-n` | `--no-dereference` | Si el destino es un **symlink a un directorio**, lo trata como un archivo normal en lugar de descender dentro de él |
| `-T` | `--no-target-directory` | El destino es siempre el nombre del enlace, nunca un directorio dentro del cual colocarlo |
| `-t DIR` | `--target-directory=DIR` | Coloca todos los enlaces en `DIR` (útil con `xargs`/`find -exec`) |
| `-r` | `--relative` | Calcula el destino del symlink en forma relativa al directorio del propio enlace |
| `-b` | `--backup[=CONTROL]` | Respalda un destino existente en lugar de perderlo |
| `-v` | `--verbose` | Imprime cada enlace creado |
| `-L` | `--logical` | Al enlazar duro un symlink, enlaza a su **referente** |
| `-P` | `--physical` | Al enlazar duro un symlink, enlaza al **inode del symlink en sí** (el valor por defecto en Linux) |
| `-d`, `-F` | `--directory` | Intenta un enlace duro a un directorio; devuelve `EPERM` en Linux incluso para root |

`-n` y `-T` son los dos flags que separan un script de deploy que funciona de una caída. Sin ellos, `ln -sf releases/new /srv/app/current` — donde `current` ya es un symlink a un directorio — crea `/srv/app/current/new` y deja producción apuntando a la release vieja, sin ningún error.

---

## 4. Patrones de producción, con infraestructura completa

### 4.1 El puntero atómico de release

La razón por la que `current` es un symlink y no un directorio es que **`rename(2)` es atómico y `cp -r` no lo es**. Un lector ve o bien el destino viejo o bien el nuevo, nunca un estado parcial.

`/usr/local/sbin/release.sh`:

```bash
#!/usr/bin/env bash
#
# Atomically repoint /srv/app/current at a prepared release directory.
# The only atomic replace primitive on POSIX is rename(2); `ln -sf` is
# implemented as unlink-then-symlink, which leaves a window in which the
# path does not exist at all and every in-flight open() returns ENOENT.
set -euo pipefail

APP_ROOT=/srv/app
RELEASE_ID=${1:?usage: release.sh <release-id>}
NEW_RELEASE="${APP_ROOT}/releases/${RELEASE_ID}"
CURRENT="${APP_ROOT}/current"
STAGING="${APP_ROOT}/.current.staging.$$"

[[ -d ${NEW_RELEASE} ]] || { echo "release ${RELEASE_ID} not found" >&2; exit 1; }

cleanup() { rm -f -- "${STAGING}"; }
trap cleanup EXIT

# 1. Build the new pointer under a name nobody reads.
#    -T guarantees the destination is the link name and never a directory
#    to place the link inside. No -f and no -n are needed precisely because
#    ${STAGING} is a fresh name: the footguns only exist when you overwrite.
#
#    The target is RELATIVE. An absolute target ("/srv/app/releases/...")
#    breaks the moment this tree is bind-mounted, chrooted, or rsynced into
#    a container image at a different prefix.
ln -sT "releases/${RELEASE_ID}" "${STAGING}"

# 2. rename(2) over the live pointer. Atomic. If ${CURRENT} was mistakenly
#    created as a real directory, this fails loudly with EISDIR instead of
#    silently nesting a link inside it.
mv -T "${STAGING}" "${CURRENT}"
trap - EXIT

# 3. Processes that already resolved the old path keep their open file
#    descriptors on the old inode until they reopen. The reload is what
#    makes the swap visible to a long-running server.
systemctl reload edge-proxy.service

# 4. Retention: keep the four newest releases plus the live one. Never
#    delete the resolved target, whatever its mtime says.
resolved=$(readlink -f -- "${CURRENT}")
find "${APP_ROOT}/releases" -mindepth 1 -maxdepth 1 -type d \
     ! -path "${resolved}" -printf '%T@ %p\n' \
  | sort -rn | tail -n +5 | cut -d' ' -f2- \
  | xargs -r -d '\n' rm -rf --

echo "current -> $(readlink -- "${CURRENT}")"
```

Verificación:

```
$ sudo /usr/local/sbin/release.sh 2026-08-26T09-30-00Z
current -> releases/2026-08-26T09-30-00Z

$ ls -l /srv/app/current
lrwxrwxrwx 1 deploy deploy 29 Aug 26 09:30 /srv/app/current -> releases/2026-08-26T09-30-00Z

$ namei -l /srv/app/current/bin/edge-proxy
f: /srv/app/current/bin/edge-proxy
 drwxr-xr-x root   root   /
 drwxr-xr-x root   root   srv
 drwxr-xr-x deploy deploy app
 lrwxrwxrwx deploy deploy current -> releases/2026-08-26T09-30-00Z
 drwxr-xr-x deploy deploy releases
 drwxr-xr-x deploy deploy 2026-08-26T09-30-00Z
 drwxr-xr-x deploy deploy bin
 -rwxr-xr-x deploy deploy edge-proxy
```

`namei -l` (util-linux) recorre cada componente e imprime su tipo y sus permisos. Es la mejor herramienta que existe para "esta ruta existe pero me da `ENOENT`".

El rollback es el mismo script con el ID de la release anterior — un `rename(2)`, submilisegundo, sin movimiento de datos.

### 4.2 Declarar los enlaces como infraestructura

**`/etc/tmpfiles.d/edge-proxy.conf`** — systemd-tmpfiles los crea en el arranque y con `systemd-tmpfiles --create`, lo que hace que el layout de enlaces sea reproducible en un nodo recién aprovisionado:

```
#  Type  Path                                  Mode  User    Group   Age  Argument
   d     /srv/app                              0755  deploy  deploy  -    -
   d     /srv/app/releases                     0755  deploy  deploy  -    -
   d     /srv/app/shared                       0750  deploy  deploy  -    -
   d     /srv/app/shared/log                   0750  deploy  deploy  -    -

#  L  creates a symlink only if the path does not already exist.
#  L+ removes whatever is there first (file, directory, or wrong symlink)
#     and then creates the link. Use L+ for links you must own absolutely,
#     L for links an operator is allowed to override.
   L+    /srv/app/shared/config/upstream.conf  -     -       -       -    /etc/edge-proxy/upstream.conf
   L     /var/log/edge-proxy                   -     -       -       -    /srv/app/shared/log
```

```
$ sudo systemd-tmpfiles --create /etc/tmpfiles.d/edge-proxy.conf
$ ls -l /var/log/edge-proxy
lrwxrwxrwx 1 root root 20 Aug 26 09:31 /var/log/edge-proxy -> /srv/app/shared/log
```

**Ansible** — el mismo layout, convergido en lugar de creado:

```yaml
---
- name: Provision the release layout and its links
  hosts: edge_proxies
  become: true
  vars:
    app_root: /srv/app
    release_id: "2026-08-26T09-30-00Z"

  tasks:
    - name: Create the directory skeleton
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: deploy
        group: deploy
        mode: "0755"
      loop:
        - "{{ app_root }}"
        - "{{ app_root }}/releases/{{ release_id }}"
        - "{{ app_root }}/shared/config"

    # state: link is `ln -s`.
    #   force: true   == -f  (replace an existing destination)
    #   follow: false == -n  (do NOT descend into an existing dir-symlink)
    # Omitting follow: false is the Ansible spelling of the classic
    # `ln -sf` footgun: it creates app_root/current/<release_id>.
    - name: Point `current` at the release
      ansible.builtin.file:
        src: "releases/{{ release_id }}"
        dest: "{{ app_root }}/current"
        state: link
        force: true
        follow: false
        owner: deploy
        group: deploy
      notify: reload edge-proxy

    # state: hard requires an ABSOLUTE src, and both paths must live on the
    # same filesystem — Ansible surfaces EXDEV as a task failure, which is
    # the correct behaviour: a silent copy here would break the audit trail.
    - name: Keep the audit copy of the licence as a hard link, not a copy
      ansible.builtin.file:
        src: "{{ app_root }}/releases/{{ release_id }}/LICENCE"
        dest: "{{ app_root }}/shared/LICENCE"
        state: hard
        force: true

    # lineinfile/replace/blockinfile rewrite via a temporary file plus
    # rename(2). On a symlinked path that REPLACES the symlink with a
    # regular file unless follow: true is set. Same class of bug as `sed -i`.
    - name: Tune the worker count in the (symlinked) config
      ansible.builtin.lineinfile:
        path: "{{ app_root }}/shared/config/upstream.conf"
        regexp: '^worker_processes '
        line: 'worker_processes auto;'
        follow: true
      notify: reload edge-proxy

  handlers:
    - name: reload edge-proxy
      ansible.builtin.systemd_service:
        name: edge-proxy.service
        state: reloaded
```

### 4.3 Snapshots con enlaces duros: `rsync --link-dest`

Este es el uso de enlaces duros con mayor apalancamiento en producción, y el que tiene el filo más afilado.

`/usr/local/sbin/snapshot.sh`:

```bash
#!/usr/bin/env bash
#
# Hard-linked snapshot rotation. Files unchanged since the previous
# snapshot become additional directory entries for the SAME inode, so a
# snapshot costs only the changed data plus one dentry per unchanged file.
#
# HARD REQUIREMENT: nothing may ever modify a snapshot file in place.
# A hard link is not a copy. An in-place write into today's snapshot
# rewrites the bytes that every previous snapshot also points at.
# rsync is safe here because it writes to a temporary file and rename(2)s
# it into place, which creates a NEW inode and leaves the old links intact.
set -euo pipefail

SRC=/srv/app/shared/
DEST_ROOT=/backup/edge-proxy
STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
LATEST="${DEST_ROOT}/latest"

mkdir -p "${DEST_ROOT}"

link_dest=()
[[ -d ${LATEST} ]] && link_dest=(--link-dest="$(readlink -f -- "${LATEST}")")

rsync -aH --numeric-ids --delete \
      --info=stats2 \
      "${link_dest[@]}" \
      "${SRC}" "${DEST_ROOT}/${STAMP}/"

# Repoint `latest` atomically, exactly as in release.sh.
staging="${DEST_ROOT}/.latest.staging.$$"
ln -sT "${STAMP}" "${staging}"
mv -T "${staging}" "${LATEST}"

# Prune snapshots older than 30 days. rm only removes directory entries;
# the data survives as long as any other snapshot still links it.
find "${DEST_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +30 \
  -exec rm -rf -- {} +
```

`/etc/systemd/system/snapshot.service`:

```ini
[Unit]
Description=Hard-linked snapshot of /srv/app/shared
Documentation=man:rsync(1)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/snapshot.sh
Nice=10
IOSchedulingClass=idle
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/backup/edge-proxy
```

`/etc/systemd/system/snapshot.timer`:

```ini
[Unit]
Description=Daily hard-linked snapshot

[Timer]
OnCalendar=*-*-* 03:15:00 UTC
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
```

Habilitarlo es, en sí mismo, un symlink:

```
$ sudo systemctl enable --now snapshot.timer
Created symlink /etc/systemd/system/timers.target.wants/snapshot.timer → /etc/systemd/system/snapshot.timer.
```

La economía, medida:

```
$ sudo du -sh /backup/edge-proxy/2026-08-24T03-15-00Z
39G     /backup/edge-proxy/2026-08-24T03-15-00Z

$ sudo du -sh /backup/edge-proxy/2026-08-25T03-15-00Z
612M    /backup/edge-proxy/2026-08-25T03-15-00Z

$ sudo du -sh /backup/edge-proxy
40G     /backup/edge-proxy
```

El segundo snapshot parece ocupar 612 MB porque **`du` cuenta cada inode una sola vez por recorrido**, y solo los archivos cambiados son inodes nuevos. `du -s` sobre la raíz completa da la ocupación real: 40 GB para dos snapshots completos. Para ver en cambio el tamaño *aparente*:

```
$ sudo du -sh --count-links /backup/edge-proxy/2026-08-25T03-15-00Z
39G     /backup/edge-proxy/2026-08-25T03-15-00Z
```

El link count es la prueba de que la compartición está ocurriendo:

```
$ stat -c 'nlink=%h  inode=%i  %n' /backup/edge-proxy/*/config/upstream.conf
nlink=2  inode=2621501  /backup/edge-proxy/2026-08-24T03-15-00Z/config/upstream.conf
nlink=2  inode=2621501  /backup/edge-proxy/2026-08-25T03-15-00Z/config/upstream.conf
```

Mismo inode, dos nombres.

**La tabla de compromisos para la deduplicación de snapshots:**

| Enfoque | Espacio | Costo de restauración | Peligro de escritura in situ | Requisito del sistema de archivos |
|---|---|---|---|---|
| Copias completas | O(n × tamaño) | trivial | ninguno | cualquiera |
| `rsync --link-dest` (enlaces duros) | O(tamaño + n × delta) | trivial (cada snapshot es un árbol completo) | **severo** — una escritura in situ corrompe todos los snapshots que comparten el inode | cualquier fs POSIX, mismo fs para src y link-dest |
| Copias con reflink (`cp --reflink`) | O(tamaño + n × delta) | trivial | **ninguno** — CoW rompe la compartición al escribir | XFS con `reflink=1`, btrfs, bcachefs |
| Snapshots del sistema de archivos (LVM, btrfs, ZFS) | O(tamaño + delta) | requiere un paso de mount/clone | ninguno | LVM thin, btrfs, ZFS |
| Almacén direccionado por contenido (restic, borg) | O(tamaño + delta deduplicado) | requiere la herramienta para reensamblar | ninguno | cualquiera |

Si el sistema de archivos soporta reflinks, preferilos: compran el mismo ahorro de espacio sin el peligro del inode compartido. Los snapshots con enlaces duros siguen siendo la respuesta correcta sobre ext4 plano, donde son la única opción.

### 4.4 Kubernetes: los symlinks son el mecanismo de actualización de configuración

**`edge-proxy.yaml`** — manifiesto completo:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: edge-proxy-config
  namespace: prod
data:
  upstream.conf: |
    upstream api {
        server api-a.prod.svc.cluster.local:8080 max_fails=3 fail_timeout=5s;
        server api-b.prod.svc.cluster.local:8080 max_fails=3 fail_timeout=5s;
        keepalive 32;
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-proxy
  namespace: prod
  labels:
    app.kubernetes.io/name: edge-proxy
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: edge-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: edge-proxy
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        fsGroup: 101
      containers:
        - name: edge-proxy
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            # CORRECT: mount the DIRECTORY.
            #
            # kubelet materialises the ConfigMap as:
            #   ..2026_08_26_09_20_11.418327755/   <- real files, timestamped dir
            #   ..data -> ..2026_08_26_09_20_11.418327755
            #   upstream.conf -> ..data/upstream.conf
            #
            # On update it writes a NEW timestamped directory and swaps the
            # ..data symlink with rename(2). Because the swap is atomic, the
            # container never observes a partially written config, and the
            # per-key symlinks need no changes at all.
            - name: config
              mountPath: /etc/edge
              readOnly: true

            # WRONG — kept as the counter-example. subPath resolves the path
            # ONCE, at mount time, and bind-mounts the resulting inode into
            # the container. kubelet later swaps ..data; the bind mount still
            # references the old timestamped inode. The container keeps the
            # stale config forever, with no error anywhere.
            #
            # - name: config
            #   mountPath: /etc/edge/upstream.conf
            #   subPath: upstream.conf

          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 128Mi
      volumes:
        - name: config
          configMap:
            name: edge-proxy-config
            defaultMode: 0444
```

El layout, observado desde dentro del pod:

```
$ kubectl -n prod exec deploy/edge-proxy -- ls -la /etc/edge
total 0
drwxrwxrwt 3 root root 100 Aug 26 09:20 .
drwxr-xr-x 1 root root  30 Aug 26 09:19 ..
drwxr-xr-x 2 root root  60 Aug 26 09:20 ..2026_08_26_09_20_11.418327755
lrwxrwxrwx 1 root root  31 Aug 26 09:20 ..data -> ..2026_08_26_09_20_11.418327755
lrwxrwxrwx 1 root root  20 Aug 26 09:20 upstream.conf -> ..data/upstream.conf
```

Después de un `kubectl apply` de un ConfigMap modificado, el intercambio es visible como un nuevo directorio con marca de tiempo y un `..data` reescrito:

```
$ kubectl -n prod exec deploy/edge-proxy -- ls -la /etc/edge
total 0
drwxrwxrwt 3 root root 100 Aug 26 10:04 .
drwxr-xr-x 1 root root  30 Aug 26 09:19 ..
drwxr-xr-x 2 root root  60 Aug 26 10:04 ..2026_08_26_10_04_52.913004118
lrwxrwxrwx 1 root root  31 Aug 26 10:04 ..data -> ..2026_08_26_10_04_52.913004118
lrwxrwxrwx 1 root root  20 Aug 26 09:20 upstream.conf -> ..data/upstream.conf
```

Notá que `upstream.conf` en sí nunca fue tocado — su mtime no cambió. **Una aplicación que vigila `upstream.conf` con `inotify` no ve nada.** Para detectar la actualización hay que vigilar el directorio en busca del rename de `..data`, no el archivo. Es una consecuencia directa y práctica de §2.3, y agarra desprevenidos a ingenieros con experiencia.

**La cadena de symlinks del log shipper.** En cada nodo:

```
$ ls -l /var/log/containers/ | head -2
total 0
lrwxrwxrwx 1 root root 100 Aug 26 08:03 edge-proxy-7d9c5b6f4c-2xk8n_prod_edge-proxy-3f2a.log -> /var/log/pods/prod_edge-proxy-7d9c5b6f4c-2xk8n_1f4b0a52-9c3d-4a11-8e77-2b6f1a9d0c3e/edge-proxy/0.log
```

Un colector que monta únicamente `/var/log/containers` ve un directorio lleno de **symlinks colgados**, porque `/var/log/pods` no existe en su mount namespace. No reporta ningún error y no envía ningún log. El manifiesto debe montar cada salto:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-shipper
  namespace: observability
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: log-shipper
  template:
    metadata:
      labels:
        app.kubernetes.io/name: log-shipper
    spec:
      serviceAccountName: log-shipper
      tolerations:
        - operator: Exists
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          securityContext:
            readOnlyRootFilesystem: true
          volumeMounts:
            # Hop 1: the symlink farm itself.
            - name: varlog-containers
              mountPath: /var/log/containers
              readOnly: true
            # Hop 2: what those symlinks point at. Omitting this mount is
            # the classic "collector runs, ships nothing" outage — symlink
            # resolution happens in the READER's mount namespace.
            - name: varlog-pods
              mountPath: /var/log/pods
              readOnly: true
            # Hop 3: on nodes where /var/log/pods/... is itself a symlink
            # into the runtime's own log store.
            - name: containerd-logs
              mountPath: /var/lib/containerd
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc
              readOnly: true
            # Offsets must survive a restart, so they go on the host.
            - name: shipper-state
              mountPath: /var/lib/fluent-bit
          resources:
            requests:
              cpu: 50m
              memory: 96Mi
            limits:
              memory: 256Mi
      volumes:
        - name: varlog-containers
          hostPath:
            path: /var/log/containers
            type: Directory
        - name: varlog-pods
          hostPath:
            path: /var/log/pods
            type: Directory
        - name: containerd-logs
          hostPath:
            path: /var/lib/containerd
            type: DirectoryOrCreate
        - name: shipper-state
          hostPath:
            path: /var/lib/fluent-bit
            type: DirectoryOrCreate
        - name: config
          configMap:
            name: log-shipper-config
```

Diagnóstico desde dentro del colector — este único comando te dice inmediatamente si la cadena está intacta:

```
$ kubectl -n observability exec ds/log-shipper -- \
    find /var/log/containers -xtype l | head -3
```

Salida vacía significa que todos los symlinks resuelven. Cualquier salida es la caída.

### 4.5 Logs de contenedores: `/dev/stdout` es un symlink

```dockerfile
FROM nginx:1.27-alpine

# A container's logs must reach the runtime's stdout/stderr, not a file in
# the writable layer (which nothing collects and nothing rotates). These
# two symlinks ARE the entire mechanism: nginx open()s the log path, the
# kernel resolves it to /dev/stdout -> /proc/self/fd/1 -> the runtime pipe.
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 8080
USER 101
```

```
$ docker run --rm nginx:1.27-alpine ls -l /dev/stdout /proc/self/fd/1
lrwxrwxrwx 1 root root 15 Aug 26 09:44 /dev/stdout -> /proc/self/fd/1
lrwxrwxrwx 1 root root 64 Aug 26 09:44 /proc/self/fd/1 -> pipe:[41822]
```

`/proc/<pid>/fd/*` son **symlinks mágicos**: el kernel los sintetiza, y `readlink` sobre ellos devuelve el objeto al que se refiere el descriptor, incluyendo `pipe:[…]`, `socket:[…]`, o una ruta con un `(deleted)` al final.

### 4.6 `update-alternatives`: la indirección de dos niveles como API

```
$ ls -l /usr/bin/editor /etc/alternatives/editor
lrwxrwxrwx 1 root root 24 Aug  1 11:02 /usr/bin/editor -> /etc/alternatives/editor
lrwxrwxrwx 1 root root 18 Aug  1 11:02 /etc/alternatives/editor -> /usr/bin/vim.basic

$ sudo update-alternatives --set editor /usr/bin/nano
update-alternatives: using /usr/bin/nano to provide /usr/bin/editor (editor) in manual mode

$ readlink -f /usr/bin/editor
/usr/bin/nano
```

Dos niveles y no uno, porque el **gestor de paquetes** es dueño de `/usr/bin/editor` (debe poder recrearlo) mientras que la **elección del administrador** vive en `/etc/alternatives/`, que es configuración y sobrevive a las actualizaciones. Es un diseño reutilizable: una ruta pública estable, una capa de política intercambiable y la implementación. `/etc/localtime` sigue el mismo patrón:

```
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 52 Aug 20 10:11 /etc/localtime -> ../usr/share/zoneinfo/America/Argentina/Buenos_Aires
```

---

## 5. Referencia de comandos con salida real

### 5.1 Crear e inspeccionar

```
$ cd /srv/data
$ printf 'checksum=ok\n' > report.log

$ ln report.log report.bak            # hard link
$ ln -s report.log report.symlink     # symbolic link

$ ls -li
total 8
1442093 -rw-r--r-- 2 sre sre 12 Aug 26 09:14 report.bak
1442093 -rw-r--r-- 2 sre sre 12 Aug 26 09:14 report.log
1442097 lrwxrwxrwx 1 sre sre 10 Aug 26 09:16 report.symlink -> report.log
```

Leé las columnas: `report.bak` y `report.log` comparten el inode `1442093` y ambos muestran link count **2**. El symlink tiene su propio inode, link count 1, y tamaño **10** — la longitud en bytes de la cadena `report.log`.

```
$ stat report.log
  File: report.log
  Size: 12              Blocks: 8          IO Block: 4096   regular file
Device: 253,0   Inode: 1442093     Links: 2
Access: (0644/-rw-r--r--)  Uid: ( 1000/     sre)   Gid: ( 1000/     sre)
Access: 2026-08-26 09:14:02.113445120 +0000
Modify: 2026-08-26 09:14:02.113445120 +0000
Change: 2026-08-26 09:15:47.885120044 +0000
 Birth: 2026-08-26 09:12:11.004112000 +0000
```

Crear el enlace duro actualizó el **ctime** (el inode cambió: `nlink` pasó de 1 a 2) pero no el mtime — los *datos* quedaron intactos. Esta distinción es material de examen y material forense a la vez.

`stat` sobre un symlink necesita `-L` para alcanzar el destino:

```
$ stat -c '%F %i %s' report.symlink
symbolic link 1442097 10
$ stat -L -c '%F %i %s' report.symlink
regular file 1442093 12
```

### 5.2 Demostrar identidad y encontrar todos los nombres de un inode

```
$ find /srv/data -samefile report.log
/srv/data/report.log
/srv/data/report.bak

$ find /srv -xdev -inum 1442093
/srv/data/report.log
/srv/data/report.bak
```

`-samefile` es la herramienta correcta: resuelve por vos la pregunta de "en qué sistema de archivos". `-inum` solo tiene sentido dentro de un mismo sistema de archivos, de ahí el `-xdev`. En ext4 también podés preguntarle directamente al sistema de archivos, sin recorrer el árbol:

```
$ sudo debugfs -R "ncheck 1442093" /dev/mapper/vg0-srv 2>/dev/null
Inode   Pathname
1442093 /data/report.log
1442093 /data/report.bak
```

Auditar todos los archivos regulares con múltiples enlaces en un sistema de archivos:

```
$ sudo find / -xdev -type f -links +1 -printf '%n %i %p\n' | sort -rn | head -5
3 2621501 /backup/edge-proxy/2026-08-24T03-15-00Z/config/upstream.conf
3 2621501 /backup/edge-proxy/2026-08-25T03-15-00Z/config/upstream.conf
3 2621501 /backup/edge-proxy/2026-08-26T03-15-00Z/config/upstream.conf
2 1442093 /srv/data/report.bak
2 1442093 /srv/data/report.log
```

### 5.3 Resolver: `readlink` vs `realpath`

```
$ readlink report.symlink
report.log

$ readlink -f report.symlink
/srv/data/report.log

$ readlink -f /srv/app/current/bin/edge-proxy
/srv/app/releases/2026-08-26T09-30-00Z/bin/edge-proxy

$ realpath --relative-to=/srv/app /srv/app/releases/2026-08-26T09-30-00Z/bin
releases/2026-08-26T09-30-00Z/bin
```

| Opción | Comportamiento de `readlink` / `realpath` |
|---|---|
| *(`readlink` sin flags)* | Imprime la cadena de destino, un solo nivel, sin canonicalizar. Falla sobre algo que no es un symlink. |
| `-f` / `--canonicalize` | Sigue cada enlace recursivamente; **todos menos el último** componente deben existir |
| `-e` / `--canonicalize-existing` | Sigue recursivamente; **todos** los componentes deben existir |
| `-m` / `--canonicalize-missing` | Sigue recursivamente; **ningún** componente necesita existir |

Usá `readlink -e` en scripts cuando un destino faltante deba ser un error, y `readlink -f` cuando estés calculando la ruta de algo que estás por crear.

### 5.4 El footgun de `-n` / `-T`, demostrado

```
$ ls -l /srv/app/current
lrwxrwxrwx 1 deploy deploy 29 Aug 26 09:30 /srv/app/current -> releases/2026-08-26T09-30-00Z

$ cd /srv/app
$ sudo ln -sf releases/2026-08-26T11-00-00Z current      # WRONG
$ ls -l current/
lrwxrwxrwx 1 root root 29 Aug 26 11:02 2026-08-26T11-00-00Z -> releases/2026-08-26T11-00-00Z
...
$ readlink current
releases/2026-08-26T09-30-00Z
```

`ln -sf` **dereferenció** `current`, encontró un directorio y depositó el nuevo enlace *dentro* de él. Producción sigue en la release vieja, `ln` salió con código 0, y el pipeline de deploy reportó éxito. Con `-n`:

```
$ sudo ln -sfn releases/2026-08-26T11-00-00Z current
$ readlink current
releases/2026-08-26T11-00-00Z
```

`-T` es todavía más estricto y es lo que corresponde en un script: rechaza por completo la interpretación de directorio en lugar de depender de lo que el destino resulte ser en ese momento.

### 5.5 Destinos de symlink relativos vs absolutos

```
$ ln -s /srv/app/shared/config/upstream.conf /srv/app/current/upstream.conf   # absolute
$ ln -sr /srv/app/shared/config/upstream.conf /srv/app/current/upstream.conf  # relative
$ readlink /srv/app/current/upstream.conf
../shared/config/upstream.conf
```

| | Destino absoluto | Destino relativo |
|---|---|---|
| Sobrevive al mover el árbol completo | **no** | **sí** |
| Sobrevive a `chroot` / bind-mount de contenedor con otro prefijo | **no** | **sí** |
| Sobrevive al mover solo el enlace | sí | no |
| Correcto dentro de la construcción de una imagen / árbol pasado por `rsync` | rara vez | usualmente |
| Correcto para una referencia a nivel de sistema (`/etc/localtime`) | usualmente — pero notá que Debian usa `../usr/share/...` | |

**Regla:** los destinos *dentro* del mismo árbol gestionado son relativos (`ln -sr`); los destinos que cruzan a un dominio administrativo distinto son absolutos.

### 5.6 Enlazar duro un symlink: `-L` vs `-P`

```
$ ln report.symlink hard-to-link            # default = -P on Linux
$ ls -li report.symlink hard-to-link
1442097 lrwxrwxrwx 2 sre sre 10 Aug 26 09:16 hard-to-link -> report.log
1442097 lrwxrwxrwx 2 sre sre 10 Aug 26 09:16 report.symlink -> report.log

$ ln -L report.symlink hard-to-target
$ ls -li hard-to-target
1442093 -rw-r--r-- 3 sre sre 12 Aug 26 09:14 hard-to-target
```

`-P` (el valor por defecto en Linux) enlaza duro el **inode del symlink**: obtenés un segundo nombre para el puntero. `-L` lo sigue y enlaza duro el **referente**. POSIX deja el comportamiento por defecto definido por la implementación, así que confirmá siempre con `ls -li` en lugar de confiar en la plataforma.

### 5.7 Copiar: qué hacen `cp`, `tar` y `rsync` con los enlaces

```
$ cp report.symlink copy-followed          # default: dereferences
$ cp -d report.symlink copy-preserved      # -d == --no-dereference --preserve=links
$ ls -li copy-followed copy-preserved
1442310 -rw-r--r-- 1 sre sre 12 Aug 26 09:50 copy-followed
1442311 lrwxrwxrwx 1 sre sre 10 Aug 26 09:50 copy-preserved -> report.log
```

| Herramienta / flag | Enlaces simbólicos | Enlaces duros |
|---|---|---|
| `cp SRC DST` | **dereferenciados** — obtenés una copia del destino | se rompen en copias independientes |
| `cp -d` | se preservan como enlaces | se preservan (`--preserve=links`) |
| `cp -a` | se preservan (implica `-dR --preserve=all`) | se preservan |
| `cp -L` | dereferenciar explícitamente | — |
| `cp -P` | no dereferenciar nunca, explícitamente | — |
| `cp -l` | — | crea enlaces duros en lugar de copiar |
| `cp -s` | crea symlinks en lugar de copiar (rutas absolutas) | — |
| `cp --reflink=always` | — | clon CoW; **inode separado**, extents compartidos |
| `tar -cf` | se almacenan como enlaces | se detectan y se almacenan como enlaces |
| `tar -h` / `--dereference` | se almacena el contenido del destino | — |
| `tar --hard-dereference` | — | se almacenan como copias completas independientes |
| `rsync -a` | se preservan (`-l` implícito) | **se rompen en copias** salvo que uses `-H` |
| `rsync -H` | — | se preservan, a costa de un mapa de inodes en memoria |
| `rsync -L` | se transforman en el archivo referente | — |
| `rsync --safe-links` | descarta los enlaces que apuntan fuera del árbol | — |

La fila de `rsync -a` es la sorpresa cara: `-a` **no** implica `-H`. Espejar un almacén de snapshots con enlaces duros sin `-H` lo expande a su tamaño aparente completo — el almacén de 40 GB de §4.3 pasa a ser 39 GB × la cantidad de snapshots.

### 5.8 Los límites

```
$ stat -f -c '%T' /srv/data
ext2/ext3
$ stat -c '%h' base
65000
$ ln base link.extra
ln: failed to create hard link 'link.extra' => 'base': Too many links
```

| Sistema de archivos | Máximo de enlaces duros por inode | Notas |
|---|---|---|
| ext4 | 65 000 | `EXT4_LINK_MAX`; la característica `dir_nlink` levanta el límite solo para directorios |
| XFS | 2³²−1 | efectivamente sin límite para cargas de trabajo prácticas |
| Btrfs | muy grande, pero acotado por directorio | la característica `extended_iref` eleva el techo histórico de ~200 por directorio |
| tmpfs | muy grande | |
| FAT / exFAT / NTFS-3g (por defecto) | **ninguno** — sin enlaces duros | la creación del enlace devuelve `EPERM`/`EOPNOTSUPP` |
| NFS | depende del servidor | el unlink de un archivo abierto dispara el *silly rename* a `.nfsXXXX` |

Los intentos entre dispositivos fallan sin ambigüedad:

```
$ ln /srv/data/report.log /tmp/report.log
ln: failed to create hard link '/tmp/report.log' => '/srv/data/report.log': Invalid cross-device link

$ stat -c '%d %n' /srv/data/report.log /tmp
64768 /srv/data/report.log
27 /tmp
```

Números de dispositivo distintos, por lo tanto sistemas de archivos distintos, por lo tanto `EXDEV`. Un symlink es la única opción.

### 5.9 Propiedad y permisos

```
$ chmod 600 report.bak
$ ls -l report.log report.bak
-rw------- 2 sre sre 12 Aug 26 09:14 report.bak
-rw------- 2 sre sre 12 Aug 26 09:14 report.log
```

Un inode, un modo. `chmod` a través de *cualquier* enlace duro cambia el archivo para *todos* los nombres. No existe tal cosa como permisos por nombre.

```
$ sudo chown root:root report.symlink        # follows the link!
$ ls -l report.log report.symlink
-rw------- 2 root root 12 Aug 26 09:14 report.log
lrwxrwxrwx 1  sre  sre 10 Aug 26 09:16 report.symlink -> report.log

$ sudo chown -h root:root report.symlink     # changes the LINK
$ ls -l report.symlink
lrwxrwxrwx 1 root root 10 Aug 26 09:16 report.symlink -> report.log
```

Los bits de permiso de un symlink son siempre `lrwxrwxrwx` y Linux los ignora por completo. La **propiedad** del symlink, en cambio, es determinante: es lo que verifica `fs.protected_symlinks` (§7).

---

## 6. Verificación y diagnóstico de fallos

### 6.1 La tabla de triage

| Síntoma / error | Causa raíz | Primer comando |
|---|---|---|
| `Invalid cross-device link` (`EXDEV`) | Enlace duro entre sistemas de archivos | `stat -c '%d %n' src dst_dir` |
| `Operation not permitted` (`EPERM`) en `ln` | Enlace duro a un directorio, o `fs.protected_hardlinks` lo denegó | `sysctl fs.protected_hardlinks`; `stat -c %F target` |
| `Too many links` (`EMLINK`) | Link count del inode en el máximo del sistema de archivos | `stat -c %h target` |
| `Too many levels of symbolic links` (`ELOOP`) | Ciclo de symlinks, o > 40 saltos anidados | `namei -l PATH` |
| `No such file or directory` en una ruta que `ls` muestra claramente | Symlink colgado, o un destino relativo resuelto desde el directorio del enlace | `namei -l PATH`; `find DIR -xtype l` |
| `Is a directory` / `Not a directory` desde `mv -T` | El "symlink" es en realidad un directorio | `stat -c %F PATH` |
| `df` reporta lleno, `du` reporta mucho menos | Archivos borrados que siguen abiertos | `lsof +L1` |
| `du` reporta mucho menos de lo esperado | Enlaces duros contados una vez por recorrido | `du --count-links` |
| Una edición de configuración "no tuvo efecto" | `sed -i` reemplazó el symlink por un archivo regular | `ls -l /path/to/config` |
| El cambio de ConfigMap nunca llega al pod | El mount con `subPath` evita el symlink `..data` | `kubectl exec -- ls -la MOUNTPATH` |
| El log shipper corre y no envía nada | Cadena de symlinks irresoluble en el mount namespace del colector | `kubectl exec -- find /var/log/containers -xtype l` |
| Un backup viejo "cambió solo" | Escritura in situ dentro de un snapshot con enlaces duros | `stat -c %h FILE` a través de los snapshots |
| Editar un archivo rompió su enlace duro | El editor lo reescribió vía archivo temporal + rename | `stat -c '%h %i' FILE` antes/después |

### 6.2 Encontrar symlinks rotos

```
$ find /srv/app -xtype l -printf '%p -> %l\n'
/srv/app/shared/config/tls.pem -> /etc/letsencrypt/live/edge.example.net/fullchain.pem
```

`-xtype l` bajo la política por defecto `-P` coincide exactamente con los symlinks que no logran resolver. El equivalente portable, cuando `-xtype` no está disponible:

```
$ find /srv/app -type l ! -exec test -e {} \; -print
```

A nivel de cluster, como chequeo programado:

```
$ sudo find / -xdev -xtype l -printf '%p -> %l\n' 2>/dev/null | tee /var/log/dangling-links.txt | wc -l
7
```

Cuidado con el falso positivo: un symlink cuyo destino vive en un sistema de archivos no montado al momento del escaneo se reporta como roto y no lo está.

### 6.3 Diagnosticar `ELOOP`

```
$ ln -s a b
$ ln -s b a
$ cat a
cat: a: Too many levels of symbolic links

$ namei -l a
f: a
lrwxrwxrwx sre sre   a -> b
lrwxrwxrwx sre sre   b -> a
           ...       a -> b
namei: too many levels of symbolic links: a
```

También lo produce una ruta autorreferencial como `ln -s . loop` recorrida como `loop/loop/loop/...`, y las cadenas de más de 40 saltos que no contienen ningún ciclo real.

### 6.4 `df` vs `du`, resuelto correctamente

```
$ df -h /var/log
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg0-varlog     20G   19G  158M  99% /var/log

$ sudo du -sh /var/log
1.9G    /var/log
```

Una brecha de 17 GB. Dos causas candidatas, y un comando las distingue:

```
$ sudo lsof +L1
COMMAND    PID     USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
nginx    14122 www-data    5w   REG  253,3 16106127360     0 1442311 /var/log/nginx/access.log (deleted)
```

`NLINK 0` con un descriptor abierto: el archivo fue borrado con `rm` (o rotado con `create` mientras nginx lo tenía abierto) y el kernel está reteniendo 16 GB hasta que se cierre el descriptor. El arreglo es hacer que el proceso libere el descriptor, no borrar nada más:

```
$ sudo systemctl reload nginx        # nginx reopens its logs on SIGUSR1/HUP
$ df -h /var/log
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/vg0-varlog     20G  2.0G   17G  11% /var/log
```

Si `lsof +L1` viene vacío, la explicación restante son los enlaces duros: `du` cuenta cada inode una vez, así que un árbol lleno de snapshots enlazados duro legítimamente reporta menos que `df`. Confirmalo con `du -s --count-links`.

Truncar el descriptor es la válvula de emergencia cuando un reload no es posible:

```
$ sudo truncate -s 0 /proc/14122/fd/5
```

`/proc/<pid>/fd/5` es un symlink mágico al inode borrado; escribir a través de él alcanza el archivo que no tiene nombre.

### 6.5 El peligro de `sed -i` / los editores

`sed -i`, `perl -i`, `vim` con el `backupcopy` por defecto, `ansible.builtin.lineinfile` y la mayoría de las herramientas de "editar in situ" **no** editan in situ. Escriben un archivo temporal y hacen `rename(2)` sobre el destino. Eso crea un **inode nuevo**, lo que:

- **reemplaza un symlink por un archivo regular**, y
- **rompe un enlace duro**, desprendiendo silenciosamente el archivo de sus otros nombres.

```
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Aug 20 10:11 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf

$ sudo sed -i 's/^nameserver .*/nameserver 10.0.0.53/' /etc/resolv.conf

$ ls -l /etc/resolv.conf
-rw-r--r-- 1 root root 78 Aug 26 09:41 /etc/resolv.conf
```

El symlink desapareció. `systemd-resolved` ahora mantiene un archivo que nadie lee, y la próxima corrida de `systemd-tmpfiles`/del paquete puede o no restaurar el enlace. La invocación correcta:

```
$ sudo sed --follow-symlinks -i 's/^nameserver .*/nameserver 10.0.0.53/' /etc/resolv.conf
$ ls -l /etc/resolv.conf
lrwxrwxrwx 1 root root 39 Aug 20 10:11 /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
```

Para los enlaces duros, la prueba equivalente:

```
$ stat -c '%h %i' /srv/data/report.log
2 1442093
$ sed -i 's/ok/degraded/' /srv/data/report.log
$ stat -c '%h %i' /srv/data/report.log /srv/data/report.bak
1 1442401 /srv/data/report.log
1 1442093 /srv/data/report.bak
```

Inodes distintos, ambos con `nlink` 1 — el enlace está roto y `report.bak` todavía tiene el contenido viejo. En `vim`, `:set backupcopy=yes` fuerza el truncar-y-reescribir del inode original, preservando tanto los symlinks como los enlaces duros, a costa de una ventana en la que el archivo queda truncado.

### 6.6 La checklist de verificación

Ejecutá esto después de cualquier cambio que involucre enlaces, antes de declarar el cambio terminado:

```bash
# 1. The link points where you think it points, through every hop.
namei -l /srv/app/current/bin/edge-proxy

# 2. Nothing in the managed tree dangles.
find /srv/app -xtype l -printf 'DANGLING: %p -> %l\n'

# 3. The intended sharing exists (hard links) or does not (independent copies).
stat -c 'nlink=%h inode=%i %n' /srv/app/shared/LICENCE /srv/app/releases/*/LICENCE

# 4. The path a service will actually open resolves, as that service's user.
sudo -u deploy readlink -e /srv/app/current/bin/edge-proxy || echo 'UNRESOLVABLE'

# 5. Space accounting is what you expect.
du -sh --count-links /backup/edge-proxy/latest   # apparent
du -sh              /backup/edge-proxy           # actual

# 6. No deleted-but-open files are hiding capacity.
sudo lsof +L1 | awk 'NR==1 || $NF ~ /deleted/'

# 7. The link survives a reboot (it is declared, not hand-made).
systemd-analyze verify /etc/systemd/system/snapshot.timer
sudo systemd-tmpfiles --create --dry-run /etc/tmpfiles.d/edge-proxy.conf
```

---

## 7. Seguridad: los enlaces son una superficie de escalada de privilegios

Dos formas clásicas de ataque, y los dos sysctls que las cierran.

**Ataque de symlink (TOCTOU).** Se induce a un proceso privilegiado a escribir en `/tmp/nombre-predecible`, que un atacante creó previamente como un symlink a `/etc/shadow`. La escritura privilegiada sigue el enlace.

**Ataque de enlace duro.** Un atacante enlaza duro un archivo que no puede leer (digamos `/etc/shadow`) dentro de un directorio que controla. Más tarde, un proceso privilegiado — un job de backup, un `chmod -R`, un script de limpieza — opera sobre el directorio del atacante y cambia el modo o la propiedad de ese inode. Como un enlace duro *es* el archivo, el cambio aterriza en `/etc/shadow`.

```
$ sysctl fs.protected_symlinks fs.protected_hardlinks fs.protected_regular fs.protected_fifos
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 1
```

| Sysctl | Efecto cuando vale 1 | Error cuando se deniega |
|---|---|---|
| `fs.protected_symlinks` | En directorios **sticky** de escritura universal (`/tmp`, `/var/tmp`, `/dev/shm`), un symlink se sigue solo cuando quien lo sigue es el dueño del symlink o el dueño del directorio | `EACCES` |
| `fs.protected_hardlinks` | Un enlace duro a un archivo solo puede crearlo su dueño, o un usuario con acceso de lectura **y** escritura sobre él, y solo para archivos regulares no setuid/setgid (`CAP_FOWNER` está exento) | `EPERM` |
| `fs.protected_regular` | Se rechazan las aperturas con `O_CREAT` de archivos regulares existentes en directorios sticky de escritura universal cuando el archivo pertenece a otra persona | `EACCES` |
| `fs.protected_fifos` | La misma protección para FIFOs | `EACCES` |

Rechazo observado:

```
$ ln /etc/shadow /tmp/s
ln: failed to create hard link '/tmp/s' => '/etc/shadow': Operation not permitted
```

Persistí la configuración — esta es la forma declarativa correcta:

`/etc/sysctl.d/60-fs-hardening.conf`:

```
# Mitigate symlink/hardlink TOCTOU escalation in world-writable directories.
# See Documentation/admin-guide/sysctl/fs.rst in the kernel tree.
fs.protected_symlinks  = 1
fs.protected_hardlinks = 1
fs.protected_regular   = 2
fs.protected_fifos     = 1
```

```
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-fs-hardening.conf ...
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 1
```

Dos consecuencias operativas que vale la pena planificar:

- `fs.protected_hardlinks=1` rompe los jobs de backup con enlaces duros que corren como usuario no root sobre archivos propiedad de servicios. Ejecutá el job de snapshot con `CAP_FOWNER`/root, o poné el origen y el destino bajo una misma propiedad.
- Los symlinks que se escapan del contexto de construcción de un contenedor quedan colgados dentro de la imagen resultante. Auditalos con `find / -xdev -xtype l` como paso final de la construcción de la imagen.

---

## 8. Resumen enfocado al examen

**Los comandos que nombra el objetivo:** `ln`, `ln -s`, más `ls`, `find`, `cp`, `rm`, `mv`, `stat`, `readlink`.

**Los hechos que más se evalúan:**

1. Un enlace duro y su destino son **el mismo archivo**; `ls -li` muestra el mismo número de inode y un link count ≥ 2.
2. Los enlaces duros **no pueden cruzar sistemas de archivos** y **no pueden apuntar a directorios**.
3. Un enlace simbólico es un **archivo aparte** cuyo contenido es una ruta; `ls -l` muestra el tipo `l`, el sufijo `-> target` y un tamaño igual a la longitud de la cadena de destino.
4. Borrar el destino de un symlink deja un **enlace roto**; borrar un enlace duro deja los datos intactos mientras quede cualquier otro enlace.
5. El link count de un directorio es **2 + la cantidad de subdirectorios**.
6. `ln target linkname` — el destino primero, siempre. Con un solo argumento, el enlace se crea en el directorio actual con el basename del destino.
7. `ln -s` con un destino **relativo** resuelve desde el directorio del **enlace**, no desde el CWD del shell.
8. `cp` sigue los symlinks por defecto; `cp -d`/`-a`/`-P` los preservan.
9. `chmod`/`chown` sobre un symlink afectan al **destino**; `-h` (`chown -h`, `chmod` no tiene esa opción) afecta al enlace.
10. `rm` sobre un symlink elimina el enlace, nunca el destino. Una barra final (`rm dirlink/`) es la manera clásica de equivocarse en esto.

**Los cinco comandos que hay que tener en la memoria muscular:**

```bash
ln target linkname               # hard link
ln -s target linkname            # symbolic link
ln -sfn newtarget existinglink   # safely repoint an existing directory symlink
ls -li                           # inode number + link count + link target
find DIR -xtype l                # every broken symlink beneath DIR
```

**Trampas que hay que esperar:**

- `ln -sf newtarget existing_dir_symlink` **sin** `-n` crea el enlace *dentro* del directorio y sale con código 0.
- `du` sub-reporta los árboles con enlaces duros; `df` no.
- `rsync -a` **no** preserva los enlaces duros; `-H` sí.
- `sed -i` sobre una configuración enlazada simbólicamente reemplaza el symlink.
- La columna del link count en `ls -l` es el **segundo** campo, no el primero.

---

## 9. Referencias

**LPI — objetivos de certificación**

- LPIC-1 Exam 101 objectives (version 5.0), objetivo 104.6 — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPIC-1 certification overview — <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Linux man-pages project — syscalls y semántica de archivos**

- `link(2)` — <https://man7.org/linux/man-pages/man2/link.2.html>
- `symlink(2)` — <https://man7.org/linux/man-pages/man2/symlink.2.html>
- `unlink(2)` — <https://man7.org/linux/man-pages/man2/unlink.2.html>
- `rename(2)` (reemplazo atómico) — <https://man7.org/linux/man-pages/man2/rename.2.html>
- `readlink(2)` — <https://man7.org/linux/man-pages/man2/readlink.2.html>
- `stat(2)` (`st_nlink`, `st_ino`, `st_dev`) — <https://man7.org/linux/man-pages/man2/stat.2.html>
- `symlink(7)` — manejo de symlinks y semántica de seguimiento — <https://man7.org/linux/man-pages/man7/symlink.7.html>
- `path_resolution(7)` — <https://man7.org/linux/man-pages/man7/path_resolution.7.html>
- `inode(7)` — <https://man7.org/linux/man-pages/man7/inode.7.html>
- `proc(5)` — symlinks mágicos de `/proc/[pid]/fd` — <https://man7.org/linux/man-pages/man5/proc.5.html>
- `namei(1)` — <https://man7.org/linux/man-pages/man1/namei.1.html>

**GNU coreutils — las herramientas en sí**

- `ln` invocation — <https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html>
- `cp` invocation (`-a`, `-d`, `-l`, `-s`, `--reflink`, `--preserve=links`) — <https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html>
- `du` invocation (`--count-links`) — <https://www.gnu.org/software/coreutils/manual/html_node/du-invocation.html>
- `readlink` invocation — <https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html>
- `realpath` invocation — <https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html>

**Documentación del kernel**

- Referencia de sysctls `fs` — `protected_symlinks`, `protected_hardlinks`, `protected_regular`, `protected_fifos` — <https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html>
- Documentación del sistema de archivos ext4 — <https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html>
- Overlay filesystem — <https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html>

**POSIX / The Open Group Base Specifications, Issue 8**

- Utilidad `ln` — <https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html>
- `link()` — <https://pubs.opengroup.org/onlinepubs/9799919799/functions/link.html>
- `symlink()` — <https://pubs.opengroup.org/onlinepubs/9799919799/functions/symlink.html>

**Estándares y herramientas del sistema**

- Filesystem Hierarchy Standard 3.0 — <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html>
- `systemd.unit(5)` — habilitación de unidades vía symlinks — <https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html>
- `tmpfiles.d(5)` — los tipos de línea `L` y `L+` — <https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html>
- `update-alternatives(1)`, Debian — <https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html>
- `rsync(1)` — `-H`, `-L`, `--link-dest`, `--safe-links` — <https://download.samba.org/pub/rsync/rsync.1>
- Manual de GNU `tar` — manejo de enlaces duros y dereferencia — <https://www.gnu.org/software/tar/manual/html_node/dereference.html>
- Manual de GNU `sed` — `--follow-symlinks` — <https://www.gnu.org/software/sed/manual/sed.html>
- `lsof(8)` — `+L` para selección por link count — <https://man7.org/linux/man-pages/man8/lsof.8.html>

**Kubernetes y contenedores**

- ConfigMaps — semántica de actualización de volúmenes montados — <https://kubernetes.io/docs/concepts/configuration/configmap/>
- Volumes — `subPath` y la ausencia de actualizaciones automáticas — <https://kubernetes.io/docs/concepts/storage/volumes/>
- Arquitectura de logging del sistema y de contenedores — <https://kubernetes.io/docs/concepts/cluster-administration/logging/>
- Referencia de Dockerfile — `COPY` y manejo de enlaces — <https://docs.docker.com/reference/dockerfile/>

**Ansible**

- `ansible.builtin.file` — `state: link`, `state: hard`, `follow`, `force` — <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html>
- `ansible.builtin.lineinfile` — el parámetro `follow` — <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/lineinfile_module.html>