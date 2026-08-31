# LPIC-1 103.8 — Edición básica de archivos

> **Examen:** 101-500 (LPIC-1, versión 5.0) · **Tema:** 103.8 · **Peso:** 4.69
>
> **Descripción oficial del objetivo:** *Candidates are required to be able to edit text files using `vi`. This objective includes `vi` navigation, basic `vi` modes, inserting, editing, deleting, copying and finding text. It also includes awareness of other common editors and setting the default editor.*
>
> **Áreas de conocimiento clave:** navegar por un documento usando `vi` · comprender y usar los modos de `vi` · insertar, editar, borrar, copiar y buscar texto en `vi` · conocimiento de Emacs, nano y vim · configurar el editor estándar.
>
> **Términos y utilidades:** `vi` · `/` · `?` · `h,j,k,l` · `i` · `o` · `a` · `c` · `d` · `p` · `y` · `dd` · `yy` · `ZZ` · `:w!` · `:q!` · `:e!` · `EDITOR`

---

## 1. Motivación: el problema arquitectónico

### 1.1 El editor es la última herramienta que queda en pie

Toda abstracción que construyas — Terraform, Ansible, Helm, controladores GitOps — termina fallando de alguna manera que te deja frente a una consola con una shell y un sistema de archivos. En ese estado, frecuentemente **no están disponibles**: tus dotfiles, tu gestor de paquetes, la red, el completado de `bash` y cualquier editor que te guste personalmente.

Situaciones concretas de producción donde `vi` no es una preferencia sino la única interfaz:

| Situación | Por qué no hay nada más disponible |
|---|---|
| El nodo no arranca; caés en una shell de emergencia de `dracut`/`initramfs` | El sistema de archivos raíz no está montado; solo existen los binarios del initramfs (`vi` de BusyBox, a veces nada) |
| Consola serie/IPMI/iDRAC después de una edición errónea de `/etc/fstab` | Sin red, sin SSH, sin `scp`, 9600 baudios, sin scrollback |
| Arranque de rescate de una VM en la nube (`systemd.unit=rescue.target`) | Con chroot dentro de la raíz rota; solo está presente la imagen base |
| Imagen de contenedor mínima (`alpine`, `busybox`, `debian:slim`) | Está el `vi` de BusyBox; `nano`, `less`, `git` no |
| Un host endurecido donde la instalación de paquetes está bloqueada por política | No podés hacer `apt install nano` en un nodo dentro del alcance PCI |
| `sudoedit`, `visudo`, `vipw`, `crontab -e`, `systemctl edit`, `kubectl edit`, `git commit`, `git rebase -i` | Estas herramientas **lanzan un editor por vos**; si `$EDITOR` no está definida, te toca `vi` te guste o no |

La última fila es la que agarra desprevenidos a los que "nunca usan vi": una gran cantidad de herramientas estándar de Linux está arquitecturada como *"serializar el estado a un archivo temporal → invocar `$EDITOR` → validar → confirmar"*. Si no sabés manejar `vi`, no sabés manejar `visudo`, y una sesión de `visudo` chapuceada puede terminar con el acceso privilegiado a toda una flota.

### 1.2 Qué es realmente "editar un archivo"

Un editor no es una mutación mágica de bytes en el lugar. Entender el modelo a nivel de llamadas al sistema es lo que separa "guardé el archivo" de "guardé el archivo y el servicio en ejecución realmente lo ve".

Existen exactamente dos estrategias de escritura, y sus consecuencias operativas son completamente distintas:

```
Strategy A — "copy" (in-place truncate + rewrite)
  open(path, O_WRONLY|O_TRUNC)  →  write(...)  →  close()
  inode:      UNCHANGED
  hardlinks:  preserved
  bind mounts: still valid
  ACL/xattr/SELinux label: preserved
  atomicity:  NONE — a crash mid-write leaves a truncated file
  disk need:  transiently 2x if a backup copy is kept

Strategy B — "rename" (write new + atomic replace)
  open(path.tmp, O_CREAT|O_WRONLY) → write(...) → fsync() → rename(path.tmp, path)
  inode:      NEW
  hardlinks:  BROKEN (the other link still points at the old inode)
  bind mounts: STALE (a file bind mount follows the old inode forever)
  ACL/xattr/SELinux label: recreated from defaults unless explicitly copied
  atomicity:  full — readers see either the old file or the new file
  disk need:  transiently 2x
```

Vim implementa ambas y elige entre ellas con la opción `'backupcopy'` (`yes` = estrategia A, `no` = estrategia B, `auto` = decidir por archivo). Esta sola opción es responsable de toda una clase de incidentes del tipo "edité la configuración pero no cambió nada":

- Un archivo bind-mounteado dentro de un contenedor (`-v /etc/app/app.conf:/etc/app.conf`) está ligado al **inodo**. Editalo con la estrategia B en el host y el contenedor seguirá leyendo los bytes viejos para siempre, hasta que se recree el contenedor.
- `tail -f` (no `tail -F`) sigue el inodo viejo. Tu sidecar de envío de logs puede hacer lo mismo.
- Los observadores de `inotify` registrados con `IN_MODIFY` sobre la ruta no ven nada; los observadores necesitan `IN_MOVE_SELF`/`IN_DELETE_SELF` y volver a registrarse. Por eso `PathChanged=` de `systemd` y muchos bucles de recarga de configuración se comportan de forma inconsistente según el editor.
- Un proceso que ya tiene el archivo abierto (por ejemplo, ¿`sshd` manteniendo `/etc/ssh/sshd_config`? no lo hace — pero `rsyslogd`, `haproxy` en algunos modos, y cualquier cosa con un archivo mapeado con mmap sí) conserva el contenido viejo hasta que lo reabra.

### 1.3 La regla que debe sobrevivir al examen

> **Editar a mano un archivo en un nodo de producción es siempre un incidente, nunca un flujo de trabajo.**

El pipeline declarativo (git → CI → gestión de configuración → nodo) es el *único* camino soportado para el cambio. El editor existe para tres propósitos legítimos:

1. **Autoría** de la fuente de verdad en el repositorio, en tu estación de trabajo.
2. **Break-glass**: restaurar el servicio cuando el propio pipeline es lo que está roto.
3. **Ediciones mediadas** donde una herramienta envuelve al editor con bloqueo y validación (`visudo`, `vipw`, `crontab -e`, `systemctl edit`, `sudoedit`, `kubectl edit`).

Cualquier otra cosa es deriva de configuración que será silenciosamente revertida por la siguiente convergencia — o, peor, *no* será revertida y se convertirá en un copo de nieve indocumentado.

---

## 2. Panorama de editores y sus compromisos

### 2.1 El linaje de `vi`

```
ed (1969, Ken Thompson)              line editor, POSIX-mandated, works on a teletype
 └── ex (1976, Bill Joy)             ed + more powerful line commands
      └── vi (1976)                  "visual mode" of ex — a full-screen front end
           ├── nvi     (BSD, the "real" vi reimplementation)
           ├── elvis   (used by some minimal distros)
           ├── vim     (Vi IMproved, Bram Moolenaar, 1991) — the de facto vi on Linux
           │    ├── vim.tiny / vim-minimal   (what /usr/bin/vi usually is)
           │    └── neovim (fork, 2014)
           ├── busybox vi   (~2000 lines of C, embedded/initramfs/containers)
           └── toybox vi    (Android, minimal)
```

**Todo lo que está en el objetivo de LPI es funcionalidad núcleo de `ex`/`vi` presente en todos y cada uno de estos.** Es deliberado: el examen evalúa la intersección, no el superconjunto de vim.

### 2.2 Comparación de editores — compromisos

| Propiedad | `ed` | `vi` POSIX / `nvi` | `busybox vi` | `vim` (huge) | GNU `nano` | GNU Emacs |
|---|---|---|---|---|---|---|
| Tamaño típico en disco | ~60 KB | ~400 KB | parte del blob de busybox de ~1 MB | ~3.5 MB + ~30 MB de runtime | ~250 KB + ~1 MB | ~40 MB+ |
| Presente en un contenedor mínimo | rara vez | rara vez | **sí** (alpine/busybox) | no | no | no |
| Presente en initramfs / rescate | a veces | a veces | **sí** | no | no | no |
| Necesita una entrada `terminfo` funcional | **no** | sí | sí | sí | sí | sí |
| Usable sobre una terminal rota/tonta | **sí** | no | no | no | no | no |
| Modal | n/a (orientado a líneas) | sí | sí | sí | **no** | no |
| Deshacer multinivel | no | no (un solo `u`, `U` por línea) | no (un solo `u`) | **sí** (`u` / `Ctrl-r`, deshacer persistente) | sí (`M-u`/`M-e`) | sí |
| Resaltado de sintaxis | no | no | no | **sí** | sí (con `.nanorc`) | sí |
| Interfaz descubrible (pistas de teclas en pantalla) | no | no | no | no | **sí** | parcialmente |
| Programable de forma no interactiva | **sí** (script por stdin) | sí (modo `ex`, `-c`) | limitado | sí (`-es -c`) | no | sí (`--batch`) |
| Recuperación tras un cierre abrupto | no | sí (`-r`) | no | **sí** (`.swp`, `-r`) | sí (archivo de emergencia `.save`) | sí (autoguardado `#file#`) |
| Escribe archivos de swap/backup junto al fuente (riesgo de fuga de datos) | no | sí | no | **sí** | solo al caer | sí |
| Costo de aprendizaje | alto | alto | alto | alto | **muy bajo** | muy alto |
| Garantizado en cualquier sistema relevante para LPI | requerido por POSIX | **requerido por POSIX** | no | no | no | no |

**Lectura arquitectónica de esta tabla:** `nano` optimiza los *primeros* cinco minutos de la carrera de una persona; `vi` optimiza los *peores* cinco minutos de la vida de un sistema. Estandarizá en `nano` para las personas si querés — pero el runbook de recuperación debe asumir `vi`, porque no está garantizado que `nano` exista en la máquina que estás intentando salvar.

### 2.3 Edición interactiva vs. mutación no interactiva

Saber cuándo *no* abrir un editor es una habilidad senior. Para cambios en toda la flota o repetibles, el editor es la herramienta equivocada:

| Método | Idempotente | Auditable | Escritura atómica | Valida | Usar cuando |
|---|---|---|---|---|---|
| `vi` a mano | ❌ | ❌ (solo historial de shell) | depende de `backupcopy` | ❌ | Break-glass, un solo host, una vez |
| `sed -i` | ❌ (la regex puede coincidir 0 o N veces) | parcialmente | ⚠️ `sed -i` **reemplaza el inodo** | ❌ | Cirugía de texto puntual; nunca en un bucle de convergencia |
| Script `ex`/`vim -es -c` | ❌ | parcialmente | igual que vim | ❌ | Ediciones programadas que necesitan la gramática de movimientos de vi |
| `ansible.builtin.lineinfile` | ✅ | ✅ (playbook en git) | ✅ (escribe temporal + `atomic_move`) | vía `validate:` | Cambio de flota en una *línea* |
| `ansible.builtin.template` / `copy` | ✅ | ✅ | ✅ | vía `validate:` | Cambio de flota en un *archivo* — la opción por defecto |
| `kubectl apply -f` | ✅ | ✅ | del lado del servidor | ✅ (esquema + admisión) | Objetos de Kubernetes — la opción por defecto |
| `kubectl edit` | ❌ | ✅ (el log de auditoría registra el PATCH) | del lado del servidor | ✅ | Break-glass sobre un objeto vivo |
| `kubectl patch` | ✅ | ✅ | del lado del servidor | ✅ | Cambio programado de un solo campo |

> **`sed -i` no es in-place.** Escribe un archivo temporal y lo renombra. Por lo tanto tiene exactamente las consecuencias de hardlink/bind-mount/inodo de la estrategia B de la §1.2, y además descarta silenciosamente el contexto SELinux original en algunos sistemas. Usá `sed -i` sobre archivos que te pertenecen, no sobre archivos de `/etc` que otros subsistemas rastrean.

### 2.4 ¿Qué binario es `/usr/bin/vi`, en realidad?

Esto importa, porque `vim.tiny` carece silenciosamente de funciones en las que podés estar confiando (sin deshacer multinivel, sin modo visual, sin resaltado de sintaxis).

```
$ readlink -f "$(command -v vi)"
/usr/bin/vim.tiny

$ vi --version | head -n 5
VIM - Vi IMproved 9.1 (2024 Jan 02, compiled Jan 15 2026 09:12:41)
Included patches: 1-16
Modified by team+vim@tracker.debian.org
Compiled by team+vim@tracker.debian.org
Small version without GUI.  Features included (+) or excluded (-):

$ vi --version | grep -oE '[+-]multi_byte|[+-]persistent_undo|[+-]syntax|[+-]visual'
-persistent_undo
-syntax
+visual
```

En sistemas de la familia Red Hat, `/usr/bin/vi` viene de `vim-minimal` y `/usr/bin/vim` de `vim-enhanced`:

```
$ rpm -qf /usr/bin/vi /usr/bin/vim
vim-minimal-9.1.083-1.el9.x86_64
vim-enhanced-9.1.083-1.el9.x86_64
```

En los sistemas de la familia Debian la elección está mediada por el sistema de alternativas:

```
$ update-alternatives --display editor
editor - auto mode
  link best version is /usr/bin/vim.basic
  link currently points to /usr/bin/vim.basic
  link editor is /usr/bin/editor
  slave editor.1.gz is /usr/share/man/man1/editor.1.gz
/bin/nano - priority 40
  slave editor.1.gz: /usr/share/man/man1/nano.1.gz
/usr/bin/vim.basic - priority 30
  slave editor.1.gz: /usr/share/man/man1/vim.1.gz
/usr/bin/vim.tiny - priority 15
  slave editor.1.gz: /usr/share/man/man1/vim.1.gz
```

Fijate en la trampa: `nano` tiene **prioridad 40**, mayor que el 30 de `vim.basic`. En un Debian de fábrica con `nano` instalado, `/usr/bin/editor` — y por lo tanto el fallback de muchas herramientas — es `nano`, no `vi`. Establecer el valor por defecto a nivel de sistema se cubre en la §6.

### 2.5 `ed`: el que siempre funciona

Cuando `TERM` está mal, falta la base de datos terminfo (extremadamente común en contenedores desde cero), o la consola es un dispositivo de línea genuino, los editores de pantalla completa abortan. `ed` no usa terminfo en absoluto.

```
$ TERM=unknown vim /etc/hosts
E558: Terminal entry not found in terminfo
'unknown' not known. Available builtin terminals are:
    builtin_riscos
    builtin_ansi
    builtin_dumb
    builtin_debug
defaulting to 'ansi'

$ TERM=unknown ed /etc/hosts
221
p
127.0.0.1	localhost
,n
1	127.0.0.1	localhost
2	::1	localhost ip6-localhost ip6-loopback
3	10.20.0.11	node-01.internal node-01
2a
10.20.0.12	node-02.internal node-02
.
w
267
q
```

`ed` es silencioso por defecto (`?` es todo su vocabulario de errores — `H` activa los errores detallados). Es desagradable, y es la diferencia entre arreglar una máquina y reinstalarle la imagen.

---

## 3. Arquitectura de `vi`: la máquina de estados modal

### 3.1 Modos

El único salto conceptual de `vi` es que **el teclado es un lenguaje de comandos, y escribir texto es un submodo temporal de ese lenguaje**. Cada tecla tiene un significado que depende del modo actual.

```
                        ┌──────────────────────────────────────────┐
                        │            COMMAND MODE                  │
                        │        (a.k.a. "normal mode")            │
        Esc  ──────────►│  keys are operators, motions and counts  │◄────── Esc
         │              │  this is where vi STARTS                 │        │
         │              └───┬───────────────┬──────────────────┬───┘        │
         │      i I a A o O │               │ :                │ v V ^V     │
         │      c s S R     │               │                  │ (vim only) │
         │                  ▼               ▼                  ▼            │
   ┌─────┴────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
   │ REPLACE MODE │  │ INSERT MODE  │  │ EX / LAST-   │  │ VISUAL MODE  │───┘
   │  (R)         │  │ typed keys   │  │ LINE MODE    │  │ select a     │
   │              │  │ enter the    │  │ :w :q :s     │  │ region, then
   │              │  │ buffer       │  │ Enter runs it│  │ apply an
   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │ operator
          │  Esc            │  Esc            │ Enter/Esc└──────────────┘
          └─────────────────┴─────────────────┘
```

Consecuencias operativas que vale la pena internalizar:

- **`Esc` es idempotente y siempre seguro.** Cuando estés perdido, presioná `Esc` dos veces. En modo comando un `Esc` perdido no hace nada (las terminales viejas pitan). Esta es la primitiva de recuperación.
- **`vi` arranca en modo comando.** El texto tecleado por alguien que asume lo contrario se ejecuta como comandos. `dd` borra una línea, `ZZ` guarda y sale, `:q!` sale — una persona "solo escribiendo" dentro de una sesión de `visudo` puede corromper `/etc/sudoers`, y lo hará.
- **El modo visual no existe en el `vi` POSIX.** Es una extensión de vim. El examen no lo requiere; la ergonomía de producción sí.

### 3.2 Búfer, archivo, swap, deshacer — cuatro objetos distintos

```
   ~/.vimrc / /etc/vim/vimrc            ┌───────────────────────────┐
   VIMINIT / EXINIT / .exrc  ──────────►│  vim process              │
                                        │                           │
   /etc/ssh/sshd_config  ──── read ────►│   BUFFER  (RAM)           │
        ^        ^                      │      │                    │
        │        │                      │      ├── every keystroke ─┼──► /etc/ssh/.sshd_config.swp
        │        │  :w  (write path,    │      │   (crash recovery, │      created at open,
        │        │      see §3.3)       │      │    fsync'd on idle)│      deleted on clean exit
        │        └──────────────────────┼──────┘                    │
        │                               │      └── undo tree ───────┼──► ~/.vim/undodir/... (vim only,
        │                               │                           │      if 'undofile' is on)
        └── :e!  (discard buffer, ──────┤   ~/.viminfo  ◄───────────┤      command history, registers,
             re-read from disk)         └───────────────────────────┘      marks, last search, and the
                                                                            first lines of yanked text
```

**Consecuencia de seguridad, y es real:** abrí `/etc/shadow` en vim y aparece un archivo llamado `/etc/.shadow.swp`, que contiene hashes, con los permisos que resulten del comportamiento por defecto de la umask del *directorio*. Matá la sesión (SIGKILL, OOM, SSH caído) y ahí se queda. `~/.viminfo` de forma similar persiste el texto copiado — una clave privada copiada termina en un archivo con modo 0600 en tu directorio home, que después se respalda, se sincroniza y se incluye en la siguiente imagen.

El hábito correcto para los secretos:

```
$ vim -n -i NONE /etc/shadow     # -n = no swapfile, -i NONE = no viminfo
```

O hacelo estructural (mirá el `vimrc` endurecido de la §7.1).

### 3.3 La ruta de escritura en detalle

```
$ stat -c 'inode=%i links=%h perms=%a owner=%U:%G' /etc/haproxy/haproxy.cfg
inode=1179842 links=1 perms=644 owner=root:root

$ sudo vim -c 'set backupcopy=no' -c 'normal Go# touched' -c 'wq' /etc/haproxy/haproxy.cfg

$ stat -c 'inode=%i links=%h perms=%a owner=%U:%G' /etc/haproxy/haproxy.cfg
inode=1179971 links=1 perms=644 owner=root:root      <-- INODE CHANGED
```

Con `backupcopy=yes` el inodo es estable:

```
$ sudo vim -c 'set backupcopy=yes' -c 'normal Go# touched again' -c 'wq' /etc/haproxy/haproxy.cfg

$ stat -c 'inode=%i links=%h' /etc/haproxy/haproxy.cfg
inode=1179971 links=1                                 <-- INODE PRESERVED
```

| Valor de `backupcopy` | Mecanismo | Inodo | Hardlinks | El bind mount sobrevive | Atómico | Usar para |
|---|---|---|---|---|---|---|
| `yes` | truncar el original, reescribir | preservado | preservados | ✅ | ❌ | Archivos bind-mounteados, archivos con hardlinks, archivos con ACL/xattrs/semántica cercana a immutable |
| `no` | escribir nuevo, `rename(2)` encima | **nuevo** | **rotos** | ❌ | ✅ | Archivos grandes en discos lentos; cuando los lectores nunca deben ver un archivo parcial |
| `auto` (por defecto) | vim elige; se inclina a `no` cuando puede preservar propiedad/permisos | normalmente nuevo | normalmente rotos | ⚠️ | normalmente | Autoría general en una estación de trabajo |

**Regla práctica para nodos:** poné `set backupcopy=yes` en el `vimrc` del sistema de cualquier host que haga bind-mount de archivos de configuración dentro de contenedores o use árboles de configuración con hardlinks. La atomicidad perdida es un riesgo menor que el no-op silencioso.

### 3.4 La gramática operador–movimiento

`vi` no es una lista de atajos para memorizar; es un lenguaje diminuto. Casi todo comando de edición es:

```
   [count]  operator  [count]  motion
      3        d         2        w        →  delete 6 words  (3 × 2)
                d                 $        →  delete to end of line
      5        y                 y         →  operator doubled = act on 5 whole lines
                c                 /ERROR⏎  →  change from cursor up to the next match of "ERROR"
                d                 G        →  delete from cursor to end of file
                >                 }        →  indent to end of paragraph  (vim/nvi)
```

| Componente | Valores (relevantes para el examen) |
|---|---|
| **Operadores** | `d` borrar · `c` cambiar (borrar + entrar en inserción) · `y` copiar (yank) · `>` `<` indentar · `!` filtrar a través de un comando externo · `=` reindentar (vim) |
| **Movimientos** | `h j k l` · `w W b B e E` · `0 ^ $` · `G gg` · `{ }` · `( )` · `f F t T` · `/ ?` · `%` |
| **Duplicación** | `dd` `yy` `cc` `>>` — aplican el operador a líneas enteras |
| **Contadores** | cualquier dígito antes del operador, antes del movimiento, o ambos (se multiplican) |

Aprender la gramática significa que `d3w`, `y}`, `c/timeout⏎` y `!}sort` vienen gratis una vez que conocés `d`, `y`, `c` y `!`. Memorizar una lista de fichas no escala; la gramática sí.

---

## 4. La referencia de comandos que evalúa el examen

### 4.1 Iniciar y salir

| Comando | Efecto |
|---|---|
| `vi file` | Abre `file` (lo crea en el búfer si no existe; no se escribe nada hasta `:w`) |
| `vi +25 file` | Abre en la línea 25 |
| `vi +/pattern file` | Abre en la primera línea que coincida con `pattern` |
| `vi -R file` / `view file` | Abre en solo lectura (el búfer sigue siendo modificable; `:w!` puede forzar una escritura) |
| `vim -M file` | Abre como no modificable (solo lectura estricta) |
| `vi -r` | Lista los archivos de swap recuperables |
| `vi -r file` | Recupera `file` desde su archivo de swap |
| `vim -n file` | Sin archivo de swap |
| `vim -i NONE file` | Sin lectura/escritura de `viminfo` |
| `vi file1 file2 file3` | Abre varios archivos; `:n` siguiente, `:N`/`:prev` anterior, `:rew` el primero, `:args` lista |

### 4.2 Navegación (modo comando)

| Tecla | Movimiento | Tecla | Movimiento |
|---|---|---|---|
| `h` | un carácter a la **izquierda** | `0` | columna 0 — inicio de línea |
| `j` | una línea **abajo** | `^` | primer carácter no blanco de la línea |
| `k` | una línea **arriba** | `$` | fin de línea |
| `l` | un carácter a la **derecha** | `G` | última línea del archivo |
| `w` | inicio de la palabra siguiente (la puntuación es una palabra) | `1G` o `gg` | primera línea del archivo |
| `W` | inicio de la PALABRA siguiente (delimitada solo por espacios) | `nG` o `:n` | ir a la línea `n` |
| `b` / `B` | atrás una palabra / PALABRA | `H` `M` `L` | línea **H**igh (alta) / **M**iddle (media) / **L**ow (baja) de la pantalla |
| `e` / `E` | fin de palabra / PALABRA | `Ctrl-f` / `Ctrl-b` | página adelante (**f**orward) / atrás (**b**ackward) |
| `f<c>` / `F<c>` | saltar **a** el siguiente/anterior `<c>` de la línea | `Ctrl-d` / `Ctrl-u` | media página abajo (**d**own) / arriba (**u**p) |
| `t<c>` / `T<c>` | saltar **hasta** justo antes/después de `<c>` | `%` | saltar al `( ) [ ] { }` que empareja |
| `;` / `,` | repetir / invertir el último `f F t T` | `` `` `` | volver a la posición anterior |
| `{` / `}` | párrafo anterior / siguiente delimitado por líneas en blanco | `Ctrl-g` | muestra nombre de archivo, número de línea, indicador de modificado |

> **¿Por qué `hjkl`?** Bill Joy escribió `vi` en una terminal ADM-3A cuyo teclado tenía los glifos de flecha impresos en esas cuatro teclas, y que no tenía teclas de cursor dedicadas. Las flechas funcionan en vim hoy, pero `hjkl` es la única forma garantizada de funcionar sobre una terminal destrozada, en `busybox vi`, y dentro de `screen`/`tmux` con un `TERM` roto. Aprendé `hjkl`.

**Posicionamiento de pantalla (vim/nvi):** `zt` línea actual arriba, `zz` al centro, `zb` abajo. Invaluable al revisar un fragmento de configuración en una consola de 24 líneas.

### 4.3 Entrar en modo inserción

| Tecla | Dónde comienza la inserción |
|---|---|
| `i` | **antes** del cursor |
| `I` | antes del primer carácter no blanco de la línea |
| `a` | **después** del cursor (append) |
| `A` | al final de la línea |
| `o` | **abre** (open) una nueva línea **debajo** de la actual |
| `O` | abre una nueva línea **encima** de la actual |
| `s` | borra el carácter bajo el cursor, luego inserta |
| `S` o `cc` | borra la línea entera, luego inserta |
| `C` o `c$` | borra hasta el fin de línea, luego inserta |
| `R` | modo reemplazo — sobrescribe caracteres hasta `Esc` |

Volvé al modo comando con `Esc` (o `Ctrl-[`, que es el mismo byte, `0x1b` — útil en teclados donde `Esc` está lejos o en una línea serie que se lo come).

### 4.4 Borrar, cambiar, copiar, pegar

| Tecla(s) | Efecto |
|---|---|
| `x` | borra el carácter **bajo** el cursor |
| `X` | borra el carácter **anterior** al cursor |
| `3x` | borra 3 caracteres |
| `dw` | borra desde el cursor hasta el inicio de la palabra siguiente |
| `d$` o `D` | borra desde el cursor hasta el fin de línea |
| `d0` | borra desde el cursor hacia atrás hasta el inicio de línea |
| **`dd`** | **borra la línea actual completa** |
| `5dd` | borra 5 líneas |
| `dG` | borra desde la línea actual hasta el fin del archivo |
| `dgg` | borra desde la línea actual hasta el inicio del archivo |
| `d/ERROR⏎` | borra desde el cursor hasta la siguiente coincidencia de `ERROR` |
| `cw` | cambia una palabra (la borra y entra en modo inserción) |
| `cc` | cambia la línea entera |
| `r<c>` | reemplaza el único carácter bajo el cursor por `<c>` — se queda en modo comando |
| **`yy`** o `Y` | **copia (yank) la línea actual** |
| `3yy` | copia 3 líneas |
| `yw` / `y$` | copia una palabra / hasta el fin de línea |
| **`p`** | **pega (put) después** del cursor — debajo de la línea para copias por líneas |
| `P` | pega **antes** del cursor — encima de la línea para copias por líneas |
| `J` | une la línea siguiente con la actual |
| `~` | alterna mayúscula/minúscula del carácter bajo el cursor |
| `.` | **repite el último cambio** — la tecla de mayor apalancamiento de `vi` |

**Registros.** Cada borrado y cada copia van al registro sin nombre `""`. Los registros con nombre `"a` … `"z` son explícitos; `"A` … `"Z` *añaden*. Los borrados además llenan el anillo numerado `"1` … `"9`.

```
"ayy      yank the current line into register a
"Ayy      APPEND the current line to register a
"ap       put register a
"1p       put the most recent deletion  (then u and "2p for the one before, etc.)
"+yy      yank into the X11 clipboard   (vim compiled with +clipboard only)
```

> **La trampa clásica:** `dd`, después moverse, después `dd` y después `p` pega el *segundo* borrado, porque el segundo `dd` sobrescribió el registro sin nombre. El primer borrado no se perdió — está en `"1`. `"2p` recupera el anterior a ese.

### 4.5 Buscar y reemplazar

| Tecla(s) | Efecto |
|---|---|
| **`/pattern⏎`** | busca **hacia adelante** `pattern` (una expresión regular) |
| **`?pattern⏎`** | busca **hacia atrás** `pattern` |
| `n` | repite la búsqueda **en la misma dirección** que la original |
| `N` | repite la búsqueda en la dirección **opuesta** |
| `/⏎` | repite la última búsqueda hacia adelante |
| `*` / `#` | busca hacia adelante/atrás la palabra bajo el cursor (vim) |
| `:set ic` / `:set noic` | búsqueda insensible / sensible a mayúsculas (`ignorecase`) |
| `/pattern\c` | insensible a mayúsculas solo para esta búsqueda (vim) |
| `:set hls` / `:noh` | resalta todas las coincidencias / limpia el resaltado (vim) |

Las búsquedas dan la vuelta al final del archivo por defecto (`:set nowrapscan` para evitarlo) e informan:

```
search hit BOTTOM, continuing at TOP
```

**Sustitución** — un comando de `ex`, y la razón por la que `vi` le gana a un mouse para el trabajo de configuración:

| Comando | Efecto |
|---|---|
| `:s/old/new/` | reemplaza la **primera** aparición en la línea **actual** |
| `:s/old/new/g` | reemplaza **todas** las apariciones en la línea actual |
| `:%s/old/new/g` | reemplaza todas las apariciones en **todo el archivo** |
| `:%s/old/new/gc` | …pidiendo **c**onfirmación en cada una (`y`/`n`/`a`/`q`/`l`) |
| `:1,20s/old/new/g` | restringe a las líneas 1–20 |
| `:.,$s/old/new/g` | desde la línea actual (`.`) hasta la última línea (`$`) |
| `:g/^#/d` | **g**lobal: borra cada línea que empiece con `#` |
| `:g!/^#/d` o `:v/^#/d` | borra cada línea que **no** empiece con `#` |
| `:%s#/var/log#/srv/log#g` | cualquier carácter puede ser el delimitador — usá `#` o `,` cuando el patrón contenga `/` |

```
:%s/PermitRootLogin yes/PermitRootLogin no/g
2 substitutions on 2 lines
```

### 4.6 Guardar y salir — los términos literales del examen

| Comando | Efecto |
|---|---|
| `:w` | escribe (**w**rite) el búfer al archivo actual |
| `:w newfile` | escribe el búfer en `newfile` (el búfer sigue asociado al original) |
| `:w >> other` | añade el búfer a `other` |
| **`:w!`** | **fuerza** la escritura — intenta escribir incluso cuando el búfer está marcado como solo lectura, o cuando el archivo es de solo lectura pero *los permisos del archivo y del directorio todavía permiten escribir a root/al propietario*. **No** te otorga permisos que no tenés. |
| `:q` | sale (**q**uit) — se niega si el búfer tiene cambios sin guardar (`E37: No write since last change`) |
| **`:q!`** | **sale, descartando todos los cambios sin guardar** |
| `:wq` | escribe y sale (escribe aunque no haya modificaciones — actualiza el mtime) |
| `:x` | escribe **solo si fue modificado**, luego sale (no toca el mtime innecesariamente) |
| **`ZZ`** | equivalente en modo comando de `:x` — escribe si fue modificado, luego sale |
| `ZQ` | equivalente en modo comando de `:q!` |
| `:qa!` / `:wqa` | sale / escribe todos los búferes abiertos |
| **`:e!`** | **re-edita** — descarta cada cambio sin guardar y recarga el archivo desde el disco |
| `:e otherfile` | edita un archivo distinto en esta sesión |
| `:r otherfile` | lee (**r**ead) `otherfile` debajo del cursor |
| `:r !command` | lee la **salida de un comando de shell** debajo del cursor |
| `:!command` | ejecuta un comando de shell, muestra la salida, vuelve |
| `:sh` / `Ctrl-z` | baja a una shell / suspende el editor (`fg` para volver) |

> **`:x` vs `:wq`.** `:wq` siempre escribe, por lo que siempre actualiza el mtime, por lo que dispara cada observador de `inotify`, cada `make`, cada handler de "el archivo cambió" de la gestión de configuración — aun cuando no cambiaste nada. `:x` (y `ZZ`) escribe solo cuando el búfer está sucio. En un nodo que corre un observador de recarga-al-cambiar, `:wq` sobre un archivo sin modificar provoca una recarga gratuita del servicio. Preferí `ZZ`/`:x`.

### 4.7 Deshacer

| Tecla | `vi` POSIX / `vim.tiny` | `vim` (completo) |
|---|---|---|
| `u` | deshace el **último cambio**; presionarla de nuevo lo **rehace** (alterna) | deshace un paso; repetible a lo largo de todo el historial de deshacer |
| `U` | restaura la línea actual a su estado antes de que empezaras a cambiarla | igual |
| `Ctrl-r` | — | **rehacer** |
| `:earlier 10m` / `:later 5m` | — | moverse por el **árbol** de deshacer por tiempo (vim) |

Esta diferencia muerde en una emergencia: en una consola de rescate con `vim.tiny` o `busybox vi`, `u` es un *interruptor*, no un historial. No hay forma de retroceder más allá de un cambio. `:e!` (recargar desde disco) es tu verdadero deshacer.

### 4.8 Modo visual y edición por bloques (vim — no está en el examen, esencial en la práctica)

| Tecla | Efecto |
|---|---|
| `v` | selección por caracteres |
| `V` | selección por líneas |
| `Ctrl-v` | selección por **bloque** (columna) |
| tras seleccionar: `d` `y` `c` `>` `<` `=` `u` `U` | aplica el operador a la selección |

La receta de producción más útil de todas — indentar un bloque YAML dos espacios:

```
Ctrl-v      start block selection
j j j j     extend down over the lines
I           insert at the start of the block
<space><space>
Esc         the insertion is replicated to every selected line
```

Y su inversa, comentar un bloque:

```
Ctrl-v  jjjj  I  #  Esc
```

---

## 5. `nano` — nivel de conocimiento general

`nano` no es modal: las teclas se escriben a sí mismas, los comandos son combinaciones con `Ctrl` (`^`) y `Alt` (`M-`), y las dos líneas inferiores muestran las combinaciones. El objetivo requiere *conocimiento general*, y la producción requiere conocer el par de escribir/salir porque ahí es donde la gente pierde trabajo.

| Combinación | Efecto |
|---|---|
| `^G` | ayuda |
| **`^O`** | **W**rite **O**ut (guardar) — pide el nombre de archivo, `⏎` para confirmar |
| **`^X`** | e**X**it (salir) — pregunta `Save modified buffer?` → `Y`/`N`/`^C` |
| `^K` | corta la línea actual (al cutbuffer) |
| `^U` | descorta / pega el cutbuffer |
| `^W` | **W**here is — buscar |
| `^\` | reemplazar |
| `^_` o `M-G` | ir a línea/columna |
| `^C` | muestra la posición actual |
| `^6` o `M-A` | marca (inicia una selección) |
| `M-U` / `M-E` | deshacer / rehacer |
| `M-#` | alterna los números de línea |
| `M-$` | alterna el ajuste suave de línea |
| `^R` | inserta otro archivo en este búfer |
| `^T` | invoca el corrector/linter (configurable) |

```
$ nano -w /etc/hosts
```

`-w` deshabilita el ajuste duro de línea. **Usá siempre `-w` al editar archivos de configuración** — nano históricamente cortaba las líneas largas al ancho de la terminal e insertaba físicamente un salto de línea, lo cual corromperá silenciosamente una línea larga `AllowUsers` de `sshd_config` o un arreglo `command:` de Kubernetes. El nano moderno viene por defecto sin ajuste duro, pero el flag es gratis y el modo de falla es caro.

La configuración persistente vive en `/etc/nanorc` (sistema) y `~/.nanorc` (usuario) — mirá la §7.2.

**Emacs, nivel de conocimiento general:** no modal, `Ctrl-x Ctrl-s` guarda, `Ctrl-x Ctrl-c` sale, `Ctrl-g` cancela el comando actual. Es un entorno Lisp con un editor adosado; no está presente en servidores por defecto y no es una herramienta de recuperación realista.

---

## 6. Configurar el editor estándar

### 6.1 `EDITOR` y `VISUAL`

La convención viene de los teletipos: `EDITOR` nombra un **editor de líneas** usable en cualquier terminal; `VISUAL` nombra un **editor de pantalla completa** que requiere una terminal capaz. Los programas que necesitan un editor de pantalla completa prefieren `VISUAL` y recurren a `EDITOR`; los programas que solo necesitan un editor de líneas usan `EDITOR`.

En la práctica, en Linux moderno, poné **ambas** con el mismo valor:

```bash
export VISUAL=vim
export EDITOR=vim
```

**El orden de resolución es específico de cada programa.** No memorices un orden universal — no existe. Memorizá el *método* para determinarlo (§6.2). Los casos comunes:

| Herramienta | Orden de búsqueda |
|---|---|
| `sudoedit` / `sudo -e` | `SUDO_EDITOR` → `VISUAL` → `EDITOR` → el ajuste `editor` en `sudoers` |
| `visudo` | el ajuste `editor` en `sudoers` (por defecto `/usr/bin/vi`); el entorno se consulta **solo** si `env_editor` está habilitado en `sudoers` |
| `crontab -e` | `VISUAL` / `EDITOR` (el orden varía según la implementación de cron) → valor por defecto compilado (`/usr/bin/editor` en Debian, `/usr/bin/vi` en RHEL) |
| `git commit`, `git rebase -i` | `GIT_EDITOR` → `core.editor` → `VISUAL` → `EDITOR` → `vi` |
| `systemctl edit` | `SYSTEMD_EDITOR` → `EDITOR` → `VISUAL` → `editor`/`nano`/`vim`/`vi` |
| `kubectl edit` | `KUBE_EDITOR` → `EDITOR` → `vi` |
| `virsh edit` | `VISUAL` → `EDITOR` → `vi` |
| `vipw` / `vigr` | `VISUAL` → `EDITOR` → `vi` |
| `less` (tecla `v`) | `VISUAL` → `EDITOR` |
| `/usr/bin/editor` de Debian | el enlace de `update-alternatives`, independiente del entorno |

### 6.2 Probalo en vez de adivinar

Nunca asumas qué variable honra una herramienta. Instrumentala con un shim — esta técnica funciona con cualquier herramienta dirigida por `$EDITOR` y lleva quince segundos:

```
$ cat > /tmp/which-editor <<'EOF'
#!/bin/sh
echo "INVOKED AS: $0" >&2
echo "ARGV:       $*" >&2
echo "SUDO_EDITOR=${SUDO_EDITOR-<unset>}" >&2
echo "VISUAL=${VISUAL-<unset>}" >&2
echo "EDITOR=${EDITOR-<unset>}" >&2
exit 1
EOF
$ chmod +x /tmp/which-editor

$ VISUAL=/tmp/which-editor EDITOR=/bin/false crontab -e
INVOKED AS: /tmp/which-editor
ARGV:       /tmp/crontab.5vXn2q
SUDO_EDITOR=<unset>
VISUAL=/tmp/which-editor
EDITOR=/bin/false
crontab: "/tmp/which-editor" exited with status 1
crontab: edits left in /tmp/crontab.5vXn2q
```

Esa salida zanja la cuestión en *este* sistema y en *esta* versión, que es la única respuesta que importa durante un incidente. Fijate también en la última línea: `crontab` preservó tu trabajo en un archivo temporal en vez de descartarlo — lo mismo vale para `visudo` y `kubectl edit`.

Una sonda equivalente, de menor tecnología:

```
$ strace -f -e trace=execve -qq crontab -e 2>&1 | grep -m1 execve
execve("/usr/bin/editor", ["/usr/bin/editor", "/tmp/crontab.9KqLpM"], 0x7ffd... /* 24 vars */) = 0
```

### 6.3 Configurarlo: usuario, sistema y flota

**Por usuario** — `~/.bashrc` está mal para esto; los archivos de shell de login son lo correcto, porque `sudo` y `cron` no leen `~/.bashrc`:

```
$ printf '\nexport VISUAL=vim\nexport EDITOR=vim\n' >> ~/.profile
$ . ~/.profile
$ echo "$EDITOR"
vim
```

**A nivel de sistema** — un drop-in, nunca una edición de `/etc/profile` en sí (que las actualizaciones de paquetes sobrescribirán):

```
$ sudo tee /etc/profile.d/99-editor.sh >/dev/null <<'EOF'
# Standard editor for interactive login shells (LPIC-1 103.8).
# Set both: VISUAL for full-screen-capable tools, EDITOR as the fallback.
export VISUAL=vim
export EDITOR=vim
EOF
$ sudo chmod 0644 /etc/profile.d/99-editor.sh
```

> `/etc/profile.d/*.sh` solo es leído por las shells de **login**. No afecta a los trabajos de `cron`, a los servicios de `systemd`, ni a la ejecución de comandos SSH sin login (`ssh host 'crontab -e'`). Para esos, definí la variable en la unidad (`Environment=`) o en el propio crontab (`EDITOR=/usr/bin/vim` como línea de asignación del crontab).

**Alternativas de Debian** — cambia `/usr/bin/editor` para todos, haya entorno o no:

```
$ sudo update-alternatives --set editor /usr/bin/vim.basic
update-alternatives: using /usr/bin/vim.basic to provide /usr/bin/editor (editor) in manual mode

$ sudo update-alternatives --config editor
There are 4 choices for the alternative editor (providing /usr/bin/editor).

  Selection    Path                Priority   Status
------------------------------------------------------------
  0            /usr/bin/vim.basic   30        auto mode
  1            /bin/ed             -100       manual mode
  2            /bin/nano            40        manual mode
* 3            /usr/bin/vim.basic   30        manual mode
  4            /usr/bin/vim.tiny    15        manual mode

Press <enter> to keep the current choice[*], or type selection number:
```

**Familia Red Hat** — el comando `alternatives` es la misma herramienta; pero notá que en RHEL, `/usr/bin/vi` es un archivo real de `vim-minimal` y no es una alternativa. Definí `VISUAL`/`EDITOR` en su lugar.

### 6.4 Los editores mediados — bloqueo y validación

Estos envoltorios son la *razón* por la que existe la indirección de `$EDITOR`. Nunca los saltees.

| Envoltorio | Protege | Bloqueo | Validación al guardar |
|---|---|---|---|
| `visudo` | `/etc/sudoers`, `/etc/sudoers.d/*` | archivo de bloqueo `.tmp`; rechaza ediciones concurrentes | parseo completo; se niega a instalar un archivo roto |
| `visudo -c` | — | — | valida sin editar (usalo en CI) |
| `visudo -f /etc/sudoers.d/90-ops` | un drop-in | sí | sí |
| `vipw` / `vipw -s` | `/etc/passwd` / `/etc/shadow` | `/etc/passwd.lock` | pregunta de consistencia |
| `vigr` / `vigr -s` | `/etc/group` / `/etc/gshadow` | `/etc/group.lock` | pregunta de consistencia |
| `crontab -e` | `/var/spool/cron/crontabs/$USER` | sí | sintaxis de campos; se niega a instalar |
| `systemctl edit UNIT` | `/etc/systemd/system/UNIT.d/override.conf` | archivo temporal | ejecuta `daemon-reload` tras una edición exitosa |
| `kubectl edit` | un objeto vivo de la API | concurrencia optimista (`resourceVersion`) | esquema + webhooks de admisión del lado del servidor |
| `sudoedit file` | **cualquier archivo propiedad de root** | copia temporal | ninguna — pero el editor nunca corre como root |

**Por qué `sudoedit` y no `sudo vi`:** `sudo vi /etc/hosts` ejecuta el *editor entero* como root. Desde adentro, `:!bash`, `:sh` o `:r !cmd` dan una shell interactiva de root — lo que anula una regla de `sudoers` que pretendía otorgar solo la edición de archivos. `sudoedit` copia el archivo a una ubicación temporal, ejecuta el editor **como el usuario invocante** y lo copia de vuelta como root. En `sudoers`, otorgá `sudoedit`, nunca `vi`:

```
# /etc/sudoers.d/90-ops  — installed with: visudo -f /etc/sudoers.d/90-ops
# WRONG: gives a full root shell via :!bash
# %ops ALL=(root) NOPASSWD: /usr/bin/vi /etc/haproxy/haproxy.cfg
#
# RIGHT: the editor runs unprivileged; only the file copy-back is privileged.
%ops ALL=(root) NOPASSWD: sudoedit /etc/haproxy/haproxy.cfg
Defaults!sudoedit  env_keep += "SUDO_EDITOR"
```

```
$ sudo -l | tail -n 2
User alice may run the following commands on node-01:
    (root) NOPASSWD: sudoedit /etc/haproxy/haproxy.cfg

$ sudoedit /etc/haproxy/haproxy.cfg
sudoedit: /etc/haproxy/haproxy.cfg unchanged
```

---

## 7. Infraestructura: manifiestos completos y desplegables

### 7.1 `vimrc` de sistema endurecido

Ruta: `/etc/vim/vimrc.local` (Debian/Ubuntu) o `/etc/vimrc` (RHEL/SUSE). Archivo completo, sin elisiones.

```vim
" ============================================================================
"  /etc/vim/vimrc.local  -- system-wide vim policy for production nodes
"  Managed by configuration management. Local edits will be reverted.
"
"  Design goals, in priority order:
"    1. Never silently corrupt a config file (indentation, line endings, EOL).
"    2. Never leak secrets to disk outside the file being edited.
"    3. Never break bind mounts, hardlinks or inode-based watchers.
"    4. Only then: ergonomics.
" ============================================================================

set nocompatible                " enable vim behaviour even when invoked as 'vi'

" ---------------------------------------------------------------------------
" 1. SAFE WRITES
" ---------------------------------------------------------------------------
" Preserve the inode on write. Required on any host that bind-mounts config
" files into containers, uses hardlinked config trees, or relies on inotify
" IN_MODIFY watchers. Costs atomicity; gains correctness. See :help backupcopy
set backupcopy=yes

set nobackup                    " no 'file~' litter in /etc
set nowritebackup               " do not create a temporary backup on write
set fileformats=unix,dos        " detect CRLF, but never CREATE it
set nofixendofline              " do not silently add a trailing newline to a
                                " file that legitimately lacks one (some
                                " binary-adjacent and checksummed files care)

" ---------------------------------------------------------------------------
" 2. SECRET HYGIENE
" ---------------------------------------------------------------------------
" Keep swap, undo and viminfo state out of the directory being edited, so that
" opening /etc/shadow does not create /etc/.shadow.swp.
set directory=/var/tmp/vim-swap//   " '//' = encode the full path in the name
set undodir=/var/tmp/vim-undo//
set viminfofile=NONE               " no ~/.viminfo at all on servers

" Belt and braces: no swap, no undo file, no viminfo for known-sensitive paths.
augroup secret_files
  autocmd!
  autocmd BufNewFile,BufReadPre
        \ /etc/shadow,/etc/gshadow,/etc/sudoers,/etc/sudoers.d/*,
        \*/secrets/*,*.key,*.pem,*id_rsa*,*id_ed25519*,*.kubeconfig,
        \*/.aws/credentials,*/.docker/config.json
        \ setlocal noswapfile noundofile nobackup nowritebackup viminfo=
augroup END

" ---------------------------------------------------------------------------
" 3. FILETYPE-CORRECT INDENTATION
" ---------------------------------------------------------------------------
syntax on
filetype plugin indent on

set expandtab                   " spaces, not tabs, by default
set tabstop=8                   " a literal TAB still renders as 8 columns
set softtabstop=2
set shiftwidth=2
set autoindent
set nosmartindent               " smartindent mangles YAML comments; off.

augroup filetype_indent
  autocmd!
  " YAML and JSON: 2 spaces, tabs are a syntax error in YAML.
  autocmd FileType yaml,yml,json,helm
        \ setlocal expandtab shiftwidth=2 softtabstop=2 indentkeys-=0# indentkeys-=<:>
  " Makefiles and crontabs REQUIRE literal tabs. Never expand them.
  autocmd FileType make,crontab setlocal noexpandtab shiftwidth=8 softtabstop=0
  autocmd BufRead,BufNewFile /tmp/crontab.* setlocal filetype=crontab noexpandtab
  " Go uses tabs.
  autocmd FileType go setlocal noexpandtab shiftwidth=8
  " Shell.
  autocmd FileType sh,bash setlocal expandtab shiftwidth=2 softtabstop=2
augroup END

" ---------------------------------------------------------------------------
" 4. MAKE INVISIBLE DAMAGE VISIBLE
" ---------------------------------------------------------------------------
set list
set listchars=tab:»·,trail:·,nbsp:␣,extends:›,precedes:‹
" Highlight trailing whitespace and hard tabs in YAML in red.
highlight default link ExtraWhitespace Error
augroup show_bad_whitespace
  autocmd!
  autocmd BufWinEnter * match ExtraWhitespace /\s\+$/
  autocmd FileType yaml,yml match ExtraWhitespace /\t\|\s\+$/
augroup END

set number
set ruler
set showcmd                     " show the pending operator/count in the corner
set laststatus=2
set statusline=%f\ %m%r%h%w\ [%{&ff}]\ [%Y]\ %=L%l/%L\ C%c\ %p%%

" ---------------------------------------------------------------------------
" 5. SEARCH
" ---------------------------------------------------------------------------
set incsearch
set hlsearch
set ignorecase
set smartcase                   " case-sensitive as soon as you type a capital

" ---------------------------------------------------------------------------
" 6. PASTE SAFETY
" ---------------------------------------------------------------------------
" Bracketed paste (vim >= 8.0 with a capable terminal) prevents autoindent
" from cascading a pasted YAML block into a staircase. F2 is the manual escape
" hatch for terminals that do not support it.
set pastetoggle=<F2>

" ---------------------------------------------------------------------------
" 7. MISC
" ---------------------------------------------------------------------------
set history=1000
set backspace=indent,eol,start
set mouse=                      " mouse OFF: it hijacks terminal text selection
set modeline                    " honour modelines...
set modelines=1                 " ...but only one, and see 'modelineexpr' off
set nomodelineexpr              " never evaluate expressions from a file
set encoding=utf-8
set scrolloff=3
set wildmenu
set wildmode=longest:full,full

" Write a root-owned file opened without privileges: :W
command! W execute 'w !sudo tee % > /dev/null' <bar> edit!
```

Creá los directorios de estado que el archivo referencia — vim caerá de vuelta al directorio actual (anulando el propósito) si no existen:

```
$ sudo install -d -m 1777 /var/tmp/vim-swap /var/tmp/vim-undo
$ ls -ld /var/tmp/vim-swap
drwxrwxrwt. 2 root root 4096 Aug 26 09:41 /var/tmp/vim-swap
```

### 7.2 `nanorc`

Ruta: `/etc/nanorc` (sistema) o `~/.nanorc` (usuario). Archivo completo.

```
## /etc/nanorc -- system-wide nano policy for production nodes
## Managed by configuration management.

## --- Never corrupt a config file ------------------------------------------
unset breaklonglines      # do NOT hard-wrap long lines (the classic corruptor)
set nonewlines            # do not add a missing final newline
set tabstospaces          # spaces by default...
set tabsize 2

## --- Visibility -----------------------------------------------------------
set linenumbers
set constantshow          # always show the cursor position
set indicator             # scrollbar-like position indicator
set whitespace "»·"       # render tabs and trailing spaces
set titlecolor bold,white,blue
set statuscolor bold,white,green
set errorcolor bold,white,red

## --- Behaviour ------------------------------------------------------------
set autoindent
set smarthome             # Home toggles between column 0 and first non-blank
set zap                   # a keystroke replaces the marked region
set positionlog           # reopen files at the last cursor position
set backupdir /var/tmp/nano-backup
set historylog

## --- Do not leak state for sensitive files --------------------------------
## nano has no per-file exclusion; edit secrets with:  nano -I -P /etc/shadow
##   -I : ignore nanorc,  -P : no position log

## --- Syntax highlighting --------------------------------------------------
include "/usr/share/nano/*.nanorc"
include "/usr/share/nano/extra/*.nanorc"
```

### 7.3 Playbook de Ansible — completo, con validación

```yaml
---
# editors.yml — establish the standard editor and its policy on every node.
#
#   ansible-playbook -i inventory/prod editors.yml --check --diff
#   ansible-playbook -i inventory/prod editors.yml
#
# This playbook is the counterpart to the rule in section 1.3: the editor
# configuration itself is delivered declaratively, never hand-edited.
- name: Standard editor policy
  hosts: all
  become: true
  gather_facts: true

  vars:
    editor_binary: /usr/bin/vim
    vim_state_dirs:
      - /var/tmp/vim-swap
      - /var/tmp/vim-undo
    vimrc_path: >-
      {{ '/etc/vim/vimrc.local'
         if ansible_facts['os_family'] == 'Debian'
         else '/etc/vimrc' }}

  tasks:
    - name: Install the editor and its runtime
      ansible.builtin.package:
        name: "{{ editor_packages }}"
        state: present
      vars:
        editor_packages: >-
          {{ ['vim', 'nano']
             if ansible_facts['os_family'] == 'Debian'
             else ['vim-enhanced', 'nano'] }}

    - name: Create vim state directories outside the edited tree
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: root
        group: root
        mode: '1777'
      loop: "{{ vim_state_dirs }}"

    - name: Deploy the hardened system vimrc
      ansible.builtin.copy:
        src: files/vimrc.local
        dest: "{{ vimrc_path }}"
        owner: root
        group: root
        mode: '0644'
        backup: true
        # 'validate' runs BEFORE the file is moved into place. If vim cannot
        # source the candidate file, the task fails and the old file survives.
        validate: 'vim -u NONE -N -e -s -c "source %" -c "qa!"'

    - name: Deploy the hardened system nanorc
      ansible.builtin.copy:
        src: files/nanorc
        dest: /etc/nanorc
        owner: root
        group: root
        mode: '0644'
        backup: true

    - name: Export VISUAL and EDITOR for login shells
      ansible.builtin.copy:
        dest: /etc/profile.d/99-editor.sh
        owner: root
        group: root
        mode: '0644'
        content: |
          # Managed by Ansible (editors.yml). Do not edit by hand.
          export VISUAL={{ editor_binary }}
          export EDITOR={{ editor_binary }}

    - name: Point the Debian alternatives 'editor' link at vim
      community.general.alternatives:
        name: editor
        path: /usr/bin/vim.basic
      when: ansible_facts['os_family'] == 'Debian'

    - name: Force sudoedit/visudo to use vim, and forbid env_editor
      ansible.builtin.copy:
        dest: /etc/sudoers.d/10-editor
        owner: root
        group: root
        mode: '0440'
        content: |
          # Managed by Ansible (editors.yml). Do not edit by hand.
          # env_editor=off means visudo IGNORES $EDITOR from the environment,
          # so a user cannot make visudo run an arbitrary program as root.
          Defaults        editor = /usr/bin/vim
          Defaults        !env_editor
        # Never install a sudoers file without parsing it first. A broken
        # sudoers file locks every administrator out of the host.
        validate: 'visudo -cf %s'

    - name: Verify the environment actually resolves as intended
      ansible.builtin.shell:
        cmd: |
          set -euo pipefail
          . /etc/profile.d/99-editor.sh
          test "$EDITOR" = "{{ editor_binary }}"
          test "$VISUAL" = "{{ editor_binary }}"
          command -v "$EDITOR" >/dev/null
      changed_when: false
      args:
        executable: /bin/bash

    - name: Verify sudoers is parseable after our drop-in
      ansible.builtin.command:
        cmd: visudo -c
      changed_when: false
      register: sudoers_check

    - name: Show sudoers verification result
      ansible.builtin.debug:
        var: sudoers_check.stdout_lines
```

Ejecución y salida esperada:

```
$ ansible-playbook -i inventory/prod editors.yml

PLAY [Standard editor policy] **************************************************

TASK [Gathering Facts] *********************************************************
ok: [node-01.internal]
ok: [node-02.internal]

TASK [Install the editor and its runtime] **************************************
ok: [node-01.internal]
changed: [node-02.internal]

TASK [Create vim state directories outside the edited tree] ********************
changed: [node-01.internal] => (item=/var/tmp/vim-swap)
changed: [node-01.internal] => (item=/var/tmp/vim-undo)
changed: [node-02.internal] => (item=/var/tmp/vim-swap)
changed: [node-02.internal] => (item=/var/tmp/vim-undo)

TASK [Deploy the hardened system vimrc] ****************************************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Deploy the hardened system nanorc] ***************************************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Export VISUAL and EDITOR for login shells] *******************************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Point the Debian alternatives 'editor' link at vim] **********************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Force sudoedit/visudo to use vim, and forbid env_editor] *****************
changed: [node-01.internal]
changed: [node-02.internal]

TASK [Verify the environment actually resolves as intended] ********************
ok: [node-01.internal]
ok: [node-02.internal]

TASK [Verify sudoers is parseable after our drop-in] ***************************
ok: [node-01.internal]
ok: [node-02.internal]

TASK [Show sudoers verification result] ****************************************
ok: [node-01.internal] => {
    "sudoers_check.stdout_lines": [
        "/etc/sudoers: parsed OK",
        "/etc/sudoers.d/10-editor: parsed OK",
        "/etc/sudoers.d/90-ops: parsed OK"
    ]
}

PLAY RECAP *********************************************************************
node-01.internal : ok=11   changed=6    unreachable=0    failed=0    skipped=0
node-02.internal : ok=11   changed=7    unreachable=0    failed=0    skipped=0
```

### 7.4 cloud-init — hornear la política en el primer arranque

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Establishes the standard editor before any human can log in and drift.

package_update: true
packages:
  - vim
  - nano

write_files:
  - path: /etc/profile.d/99-editor.sh
    owner: root:root
    permissions: '0644'
    content: |
      # Managed by cloud-init. Do not edit by hand.
      export VISUAL=/usr/bin/vim
      export EDITOR=/usr/bin/vim

  - path: /etc/vim/vimrc.local
    owner: root:root
    permissions: '0644'
    content: |
      set nocompatible
      set backupcopy=yes
      set nobackup
      set nowritebackup
      set directory=/var/tmp/vim-swap//
      set undodir=/var/tmp/vim-undo//
      set viminfofile=NONE
      syntax on
      filetype plugin indent on
      set expandtab tabstop=8 softtabstop=2 shiftwidth=2 autoindent
      autocmd FileType make,crontab setlocal noexpandtab shiftwidth=8 softtabstop=0
      autocmd FileType yaml,yml setlocal expandtab shiftwidth=2 softtabstop=2
      set list listchars=tab:»·,trail:·,nbsp:␣
      set number ruler showcmd laststatus=2
      set incsearch hlsearch ignorecase smartcase
      set mouse=
      set pastetoggle=<F2>

  - path: /etc/sudoers.d/10-editor
    owner: root:root
    permissions: '0440'
    content: |
      Defaults        editor = /usr/bin/vim
      Defaults        !env_editor

runcmd:
  - [install, -d, -m, '1777', /var/tmp/vim-swap, /var/tmp/vim-undo]
  - [sh, -c, 'command -v update-alternatives >/dev/null && update-alternatives --set editor /usr/bin/vim.basic || true']
  # Fail the boot loudly rather than ship a host with a broken sudoers file.
  - [visudo, -c]
```

### 7.5 Kubernetes: un editor en un clúster que no tiene ninguno

Las imágenes de producción no deberían contener ningún editor. Cuando tengas que editar dentro de un Pod en ejecución, adjuntá un contenedor de depuración en vez de instalar herramientas en la imagen de la carga de trabajo.

```yaml
---
# 01-vimrc-configmap.yaml
# The editor policy, shipped as a ConfigMap so the debug toolbox is
# identical to the one on the nodes.
apiVersion: v1
kind: ConfigMap
metadata:
  name: toolbox-vimrc
  namespace: platform-debug
  labels:
    app.kubernetes.io/name: toolbox
    app.kubernetes.io/component: editor-policy
data:
  vimrc: |
    set nocompatible
    " Inside a container, config files are frequently bind-mounted from a
    " volume by inode. Preserving the inode is not optional here.
    set backupcopy=yes
    set nobackup nowritebackup
    set directory=/tmp//
    set undodir=/tmp//
    set viminfofile=NONE
    syntax on
    filetype plugin indent on
    set expandtab tabstop=8 softtabstop=2 shiftwidth=2 autoindent
    autocmd FileType yaml,yml setlocal expandtab shiftwidth=2 softtabstop=2
    autocmd FileType make,crontab setlocal noexpandtab shiftwidth=8 softtabstop=0
    set list listchars=tab:»·,trail:·,nbsp:␣
    set number ruler showcmd laststatus=2
    set incsearch hlsearch ignorecase smartcase
    set mouse=
    set pastetoggle=<F2>
---
# 02-toolbox-pod.yaml
# A long-lived debug Pod. Note the deliberate constraints: it is not
# privileged, it has no service account token, and it cannot schedule
# onto a node it was not sent to.
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  namespace: platform-debug
  labels:
    app.kubernetes.io/name: toolbox
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: toolbox
      image: debian:12-slim
      command: ["/bin/sleep", "infinity"]
      env:
        - name: EDITOR
          value: /usr/bin/vim
        - name: VISUAL
          value: /usr/bin/vim
        - name: KUBE_EDITOR
          value: /usr/bin/vim
        # Without a TERM the editor cannot start. See section 9.1.
        - name: TERM
          value: xterm-256color
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 500m
          memory: 256Mi
      volumeMounts:
        - name: vimrc
          mountPath: /etc/vim/vimrc.local
          subPath: vimrc
          readOnly: true
        - name: tmp
          mountPath: /tmp
        - name: work
          mountPath: /work
  volumes:
    - name: vimrc
      configMap:
        name: toolbox-vimrc
        items:
          - key: vimrc
            path: vimrc
    # A writable /tmp is mandatory: with readOnlyRootFilesystem the editor
    # has nowhere to place its swap file and will refuse to open a buffer.
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
    - name: work
      emptyDir:
        sizeLimit: 256Mi
---
# 03-netpol.yaml
# The toolbox can reach the API server and DNS. Nothing else, and nothing
# reaches it. A debug Pod is a lateral-movement asset if left unconstrained.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: toolbox-egress-only
  namespace: platform-debug
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: toolbox
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - ipBlock:
            cidr: 10.96.0.1/32     # kubernetes.default.svc ClusterIP
      ports:
        - protocol: TCP
          port: 443
```

> **La trampa de `subPath`, que es exactamente el problema del inodo de la §1.2 en forma de Kubernetes:** un volumen `configMap` montado con `subPath` se bind-montea **por inodo**. Cuando el ConfigMap se actualiza, el kubelet intercambia atómicamente el symlink del directorio proyectado — y el montaje `subPath` sigue apuntando al inodo viejo. El archivo dentro del contenedor **nunca** se actualiza. Montá el directorio completo (sin `subPath`) si necesitás actualizaciones en vivo, o rotá el Pod. Es la misma falla que editar un archivo bind-mounteado con `backupcopy=no`.

Construir la imagen del toolbox, si preferís una hecha a medida:

```dockerfile
# Dockerfile — platform debug toolbox.
# Deliberately NOT based on the application image: the application image
# must never contain an editor, a shell debugger or a packet capture tool.
FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        vim-nox \
        nano \
        ed \
        less \
        ncurses-base \
        ncurses-term \
        ca-certificates \
        procps \
        iproute2 \
        dnsutils \
        curl \
        jq \
        yamllint; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ncurses-term supplies the terminfo entries. Without it, TERM=xterm-256color
# makes vim abort with E558 inside the container. See section 9.1.
ENV TERM=xterm-256color \
    EDITOR=/usr/bin/vim \
    VISUAL=/usr/bin/vim \
    KUBE_EDITOR=/usr/bin/vim \
    LANG=C.UTF-8

COPY vimrc.local /etc/vim/vimrc.local

RUN install -d -m 1777 /var/tmp/vim-swap /var/tmp/vim-undo \
 && useradd --uid 65532 --create-home --shell /bin/bash toolbox

USER 65532:65532
WORKDIR /work
ENTRYPOINT ["/bin/sleep"]
CMD ["infinity"]
```

Desplegar y usar:

```
$ kubectl apply -f 01-vimrc-configmap.yaml -f 02-toolbox-pod.yaml -f 03-netpol.yaml
configmap/toolbox-vimrc created
pod/toolbox created
networkpolicy.networking.k8s.io/toolbox-egress-only created

$ kubectl -n platform-debug wait --for=condition=Ready pod/toolbox --timeout=60s
pod/toolbox condition met

$ kubectl -n platform-debug exec -it toolbox -- bash
toolbox@toolbox:/work$ echo "$TERM $EDITOR"
xterm-256color /usr/bin/vim
toolbox@toolbox:/work$ vim -c 'set backupcopy?' -c 'q'
  backupcopy=yes
```

Para un Pod que *ya* está corriendo y no tiene editor, adjuntá uno sin reiniciarlo:

```
$ kubectl -n prod debug -it web-6f8d9c7b4-x2klm \
      --image=debian:12-slim \
      --target=web \
      --profile=general \
      -- bash
Targeting container "web". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-7wq4p.
If you don't see a command prompt, try pressing enter.
root@web-6f8d9c7b4-x2klm:/# ls /proc/1/root/etc/nginx/
conf.d  nginx.conf  mime.types
```

`--target` pone al contenedor de depuración en el espacio de nombres de PID del objetivo, así que `/proc/1/root/` es el sistema de archivos del contenedor de la aplicación — podés leer y, si es escribible, editar sus archivos con un editor que nunca estuvo en su imagen.

### 7.6 systemd: la forma correcta de cambiar una unidad

Nunca edites un archivo de unidad del proveedor bajo `/usr/lib/systemd/system/` — la siguiente actualización del paquete lo sobrescribe, y tu cambio desaparece en el peor momento posible.

```
$ sudo SYSTEMD_EDITOR=vim systemctl edit nginx.service
```

`systemctl` abre un override vacío, y al guardar lo escribe y recarga:

```
$ sudo systemctl cat nginx.service | head -n 30
# /usr/lib/systemd/system/nginx.service
[Unit]
Description=A high performance web server and a reverse proxy server
After=network.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target

# /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=65535
Restart=on-failure
RestartSec=5s
```

El archivo de override completo que produjo `systemctl edit`:

```ini
# /etc/systemd/system/nginx.service.d/override.conf
# Managed by configuration management; created via `systemctl edit nginx.service`.
[Service]
# The vendor unit does not raise the descriptor limit; at 20k concurrent
# connections nginx logs "worker_connections are not enough".
LimitNOFILE=65535
Restart=on-failure
RestartSec=5s
```

Verificar sin adivinar:

```
$ systemd-analyze verify nginx.service && echo "unit OK"
unit OK

$ systemctl show nginx.service -p LimitNOFILE
LimitNOFILE=65535
```

### 7.7 CI: validar cada archivo editado a mano antes de que llegue a un nodo

```makefile
# Makefile — run in CI on every change to the config repository.
# The editor is allowed to produce anything; the pipeline is what decides
# whether it reaches a node.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := verify

YAML_FILES  := $(shell git ls-files '*.yml' '*.yaml')
SUDO_FILES  := $(shell git ls-files 'sudoers.d/*')
NGINX_FILES := $(shell git ls-files 'nginx/*.conf')
UNIT_FILES  := $(shell git ls-files 'systemd/*.service' 'systemd/*.timer')

.PHONY: verify
verify: whitespace lineendings yaml sudoers nginx sshd units
	@echo "ALL CHECKS PASSED"

.PHONY: whitespace
whitespace:
	@echo "==> hard tabs and trailing whitespace in YAML"
	@! grep -nP '\t' $(YAML_FILES) || { echo "FAIL: literal tab in YAML"; exit 1; }
	@! grep -nP ' +$$' $(YAML_FILES) || { echo "FAIL: trailing whitespace"; exit 1; }

.PHONY: lineendings
lineendings:
	@echo "==> CRLF line endings"
	@! grep -rlP '\r$$' $(YAML_FILES) $(NGINX_FILES) $(UNIT_FILES) \
		|| { echo "FAIL: CRLF found — run: sed -i 's/\r$$//' <file>"; exit 1; }

.PHONY: yaml
yaml:
	@echo "==> yamllint"
	@yamllint -s $(YAML_FILES)

.PHONY: sudoers
sudoers:
	@echo "==> visudo -c on every sudoers drop-in"
	@for f in $(SUDO_FILES); do \
		echo "    $$f"; \
		visudo -cqf "$$f" || exit 1; \
	done

.PHONY: nginx
nginx:
	@echo "==> nginx -t"
	@nginx -t -c $(CURDIR)/nginx/nginx.conf -p $(CURDIR)/nginx

.PHONY: sshd
sshd:
	@echo "==> sshd -t"
	@sshd -t -f $(CURDIR)/ssh/sshd_config

.PHONY: units
units:
	@echo "==> systemd-analyze verify"
	@systemd-analyze verify $(UNIT_FILES)
```

```
$ make verify
==> hard tabs and trailing whitespace in YAML
==> CRLF line endings
==> yamllint
==> visudo -c on every sudoers drop-in
    sudoers.d/10-editor
    sudoers.d/90-ops
==> nginx -t
nginx: the configuration file /srv/cfg/nginx/nginx.conf syntax is ok
nginx: configuration file /srv/cfg/nginx/nginx.conf test is successful
==> sshd -t
==> systemd-analyze verify
ALL CHECKS PASSED
```

---

## 8. Recorridos por la terminal

### 8.1 Los primeros noventa segundos en `vi`

```
$ vi /srv/cfg/app/settings.conf
```

```
~
~
~
~
"/srv/cfg/app/settings.conf" [New] 0 lines, 0 characters
```

Los caracteres `~` marcan líneas que no existen. `[New]` significa que todavía no se escribió nada al disco. Ahora la secuencia de teclas clave del examen, anotada:

| Presionás | Modo después | Qué pasa |
|---|---|---|
| `i` | INSERCIÓN | aparece `-- INSERT --` en la última línea |
| `listen_port = 8080⏎timeout = 30s` | INSERCIÓN | dos líneas entran al búfer |
| `Esc` | COMANDO | `-- INSERT --` desaparece; el cursor se mueve una columna a la izquierda |
| `gg` | COMANDO | cursor a la línea 1 |
| `yy` | COMANDO | la línea 1 se copia al registro sin nombre |
| `p` | COMANDO | la copia se pega **debajo** de la línea actual |
| `dd` | COMANDO | ese duplicado se borra de nuevo |
| `/timeout⏎` | COMANDO | el cursor salta a la línea de `timeout` |
| `cw` | INSERCIÓN | la palabra `timeout` se borra y se entra en modo inserción |
| `read_timeout` `Esc` | COMANDO | la palabra queda reemplazada |
| `o` | INSERCIÓN | se **abre** una nueva línea debajo y se entra en modo inserción |
| `max_conns = 512` `Esc` | COMANDO | se agrega la tercera línea |
| `:w` | COMANDO | escrito al disco |
| `ZZ` | — | escrito (ya estaba limpio) y salida |

```
$ cat /srv/cfg/app/settings.conf
listen_port = 8080
read_timeout = 30s
max_conns = 512
```

### 8.2 Editar `sshd_config` sin dejarte afuera

La edición a mano más trascendente en un host Linux. El procedimiento de abajo es el que no termina en un ticket de soporte.

```
$ ssh alice@node-01.internal

# 1. Keep the current session open. Never close it until the new one works.

$ sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%F-%H%M)
$ ls -l /etc/ssh/sshd_config*
-rw-r--r--. 1 root root 3908 Jul 14 11:02 /etc/ssh/sshd_config
-rw-r--r--. 1 root root 3908 Jul 14 11:02 /etc/ssh/sshd_config.2026-08-26-0947

# 2. Edit through sudoedit so the editor itself never runs as root.
$ sudoedit /etc/ssh/sshd_config
```

Dentro del editor:

```
/PermitRootLogin⏎          jump to the directive
0                          go to column 0
:s/yes/no/⏎                substitute on this line only
1 substitution on 1 line
/PasswordAuthentication⏎
:s/yes/no/⏎
1 substitution on 1 line
Go⏎                        append a new line at the end of the file
ClientAliveInterval 60
ClientAliveCountMax 3
Esc
ZZ
```

```
sudoedit: /etc/ssh/sshd_config unchanged     <-- would appear only if nothing changed

# 3. Validate the syntax BEFORE restarting anything.
$ sudo sshd -t && echo "sshd config OK"
sshd config OK

# A broken file looks like this instead:
$ sudo sshd -t
/etc/ssh/sshd_config line 34: Unsupported option "PermitRootLogn"

# 4. Diff against the backup so you know exactly what changed.
$ sudo diff -u /etc/ssh/sshd_config.2026-08-26-0947 /etc/ssh/sshd_config
--- /etc/ssh/sshd_config.2026-08-26-0947	2026-07-14 11:02:41.000000000 +0000
+++ /etc/ssh/sshd_config	2026-08-26 09:52:18.412773901 +0000
@@ -31,10 +31,10 @@
 #LoginGraceTime 2m
-PermitRootLogin yes
+PermitRootLogin no
 #StrictModes yes
@@ -57,7 +57,7 @@
-PasswordAuthentication yes
+PasswordAuthentication no
@@ -119,3 +119,5 @@
 # override default of no subsystems
 Subsystem	sftp	/usr/lib/openssh/sftp-server
+
+ClientAliveInterval 60
+ClientAliveCountMax 3

# 5. Reload (not restart) — reload does not drop existing connections.
$ sudo systemctl reload sshd
$ systemctl is-active sshd
active

# 6. From ANOTHER terminal, prove a new login works.
$ ssh -o BatchMode=no alice@node-01.internal 'echo NEW SESSION OK'
NEW SESSION OK

# 7. Only now close the original session.
```

Si el paso 6 falla, todavía tenés la sesión del paso 1 y podés hacer `sudo cp -a` del respaldo de vuelta. Ese orden — validar, diferenciar, recargar, comprobar y *recién ahí* soltar el salvavidas — es toda la disciplina.

### 8.3 Ida y vuelta de `kubectl edit`, incluyendo la ruta de falla

```
$ export KUBE_EDITOR=vim
$ kubectl -n prod edit deployment/web
```

El editor se abre con el objeto vivo más una cabecera:

```yaml
# Please edit the object below. Lines beginning with a '#' will be ignored,
# and an empty file will abort the edit. If an error occurs while saving this file will be
# reopened with the relevant failures.
#
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "7"
  creationTimestamp: "2026-06-02T08:14:51Z"
  generation: 7
  name: web
  namespace: prod
  resourceVersion: "48192376"
  uid: 3f2a1c88-9b41-4f0e-9e0e-2b0e5c6a7d19
spec:
  replicas: 3
  ...
```

Cambiá `replicas: 3` por `replicas: 5` (`/replicas⏎`, `f3`, `r5`, `ZZ`) y:

```
deployment.apps/web edited
```

Ahora la ruta de falla — introducí un error de indentación de YAML (que es lo que pasa cuando pegás en un editor con `autoindent` activo y sin bracketed paste):

```
$ kubectl -n prod edit deployment/web
error: unable to parse "/tmp/kubectl-edit-3142817649.yaml": error converting YAML to JSON: yaml: line 41: did not find expected key
Edit cancelled, no valid changes were saved.
```

Y un cambio semánticamente válido pero inválido para la API:

```
$ kubectl -n prod edit deployment/web
The Deployment "web" is invalid: spec.template.spec.containers[0].resources.limits[memory]: Invalid value: "512": must be a quantity with a valid suffix
error: the server rejected our request due to an error in our request
A copy of your changes has been stored to "/tmp/kubectl-edit-2270441853.yaml"
error: Edit cancelled, no valid changes were saved.

$ vim /tmp/kubectl-edit-2270441853.yaml      # fix it, then:
$ kubectl -n prod apply -f /tmp/kubectl-edit-2270441853.yaml
deployment.apps/web configured
```

Notá que `kubectl edit` usa concurrencia optimista: si el objeto cambió en el servidor mientras tu editor estaba abierto, la escritura se rechaza con un conflicto de `resourceVersion` y tu trabajo se preserva en `/tmp`. La lentitud del editor es por lo tanto una *característica* del modelo de seguridad, no un defecto.

```
$ kubectl -n prod edit deployment/web
Error from server (Conflict): Operation cannot be fulfilled on deployments.apps "web": the object has been modified; please apply your changes to the latest version and try again
```

### 8.4 Recuperar una edición interrumpida

Tu sesión SSH se muere en medio de una edición. La próxima persona que abra el archivo ve:

```
$ sudo vim /etc/haproxy/haproxy.cfg

E325: ATTENTION
Found a swap file by the name "/etc/haproxy/.haproxy.cfg.swp"
          owned by: root   dated: Tue Aug 26 09:31:04 2026
         file name: /etc/haproxy/haproxy.cfg
          modified: YES
         user name: root   host name: node-01
        process ID: 4711
While opening file "/etc/haproxy/haproxy.cfg"
             dated: Tue Aug 26 08:12:55 2026

(1) Another program may be editing the same file.  If this is the case,
    be careful not to end up with two different instances of the same
    file when making changes.  Quit, or continue with caution.
(2) An edit session for this file crashed.
    If this is the case, use ":recover" or "vim -r /etc/haproxy/haproxy.cfg"
    to recover the changes (see ":help recovery").
    If you did this already, delete the swap file "/etc/haproxy/.haproxy.cfg.swp"
    to avoid this message.

Swap file "/etc/haproxy/.haproxy.cfg.swp" already exists!
[O]pen Read-Only, (E)dit anyway, (R)ecover, (D)elete it, (Q)uit, (A)bort:
```

**Leé primero la línea "process ID".** Si dice `(STILL RUNNING)`, un colega está editando en este momento — presioná `O` (solo lectura) o `A` y andá a hablar con esa persona. Si no lo dice, la sesión se cayó y `R` es lo correcto.

El procedimiento de recuperación seguro nunca escribe sobre el original:

```
$ sudo vim -r /etc/haproxy/haproxy.cfg
Using swap file "/etc/haproxy/.haproxy.cfg.swp"
Original file "/etc/haproxy/haproxy.cfg"
Recovery completed. Buffer contents equals file contents.
You may want to delete the .swp file now.

Press ENTER or type command to continue
```

Dentro del búfer recuperado, escribí a un nombre *nuevo* y compará:

```
:w /tmp/haproxy.cfg.recovered
"/tmp/haproxy.cfg.recovered" [New] 214L, 6883C written
:q!
```

```
$ sudo diff -u /etc/haproxy/haproxy.cfg /tmp/haproxy.cfg.recovered
--- /etc/haproxy/haproxy.cfg	2026-08-26 08:12:55.000000000 +0000
+++ /tmp/haproxy.cfg.recovered	2026-08-26 09:58:33.102918440 +0000
@@ -188,6 +188,7 @@
 backend be_api
     balance roundrobin
     option httpchk GET /healthz
+    timeout server 45s
     server api-1 10.20.1.11:8080 check inter 2s fall 3 rise 2
     server api-2 10.20.1.12:8080 check inter 2s fall 3 rise 2

$ sudo haproxy -c -f /tmp/haproxy.cfg.recovered
Configuration file is valid

$ sudo cp -a /tmp/haproxy.cfg.recovered /etc/haproxy/haproxy.cfg
$ sudo rm -f /etc/haproxy/.haproxy.cfg.swp
$ sudo systemctl reload haproxy
```

Listar cada archivo de swap huérfano en un host — vale la pena hacerlo después de cualquier caída masiva o evento OOM, tanto para recuperar trabajo como para encontrar secretos filtrados:

```
$ sudo vim -r
Swap files found:
   In current directory:
   -- none --
   In directory ~/tmp:
   -- none --
   In directory /var/tmp:
   -- none --
   In directory /tmp:
1.    /tmp/.settings.conf.swp
          owned by: alice   dated: Tue Aug 26 09:31:04 2026
         file name: /srv/cfg/app/settings.conf
          modified: YES
         user name: alice   host name: node-01
        process ID: 5210
```

```
$ sudo find /etc /srv /root /home -name '.*.sw[a-p]' -printf '%TY-%Tm-%Td %u %p\n' 2>/dev/null
2026-08-26 root /etc/haproxy/.haproxy.cfg.swp
2026-08-24 root /etc/.shadow.swp          <-- a leak; investigate and shred
```

### 8.5 "Lo abrí sin sudo y ahora `:w` falla"

```
$ vim /etc/hosts
```

```
:w
E45: 'readonly' option is set (add ! to override)

:w!
"/etc/hosts" E212: Can't open file for writing
```

`:w!` anuló la bandera `readonly` propia de vim pero no pudo anular los *permisos del sistema de archivos*. Dos salidas correctas:

```
" A. Write through sudo without leaving the editor (the :W command from §7.1):
:w !sudo tee % > /dev/null
[sudo] password for alice:
Press ENTER or type command to continue

W12: Warning: File "/etc/hosts" has changed and the buffer was changed in Vim as well
See ":help W12" for more info.
[O]K, (L)oad File:
```

Respondé `L`: el archivo en disco ya es correcto, así que recargarlo no descarta nada. O usá `:e!` después. Si respondés `O`, tu búfer queda marcado como modificado y un `:w` posterior podría sobrescribir con contenido desactualizado.

```
" B. Save elsewhere, quit, install with sudo — slower but unambiguous:
:w /tmp/hosts.new
:q!
```

```
$ sudo install -m 0644 -o root -g root /tmp/hosts.new /etc/hosts
$ getent hosts node-02.internal
10.20.0.12      node-02.internal node-02
```

La opción B es la que hay que usar en un archivo con contexto SELinux, porque `install` no preserva nada y `restorecon` después arregla la etiqueta de forma determinista:

```
$ ls -Z /etc/hosts
system_u:object_r:net_conf_t:s0 /etc/hosts
$ sudo restorecon -v /etc/hosts
```

### 8.6 El desastre de pegar YAML y su arreglo

Pegá un bloque YAML anidado en `vi` con `autoindent` activo y sin bracketed paste, y cada línea acumula la indentación de la anterior:

```yaml
spec:
  containers:
    - name: web
        image: nginx:1.27
          ports:
            - containerPort: 80
              resources:
                  limits:
                        cpu: 500m
```

```
$ yamllint -s pod.yaml
pod.yaml
  4:9       error    syntax error: mapping values are not allowed here (syntax)
```

**Prevención:** `:set paste` antes de pegar, `:set nopaste` después (o `F2` con el `pastetoggle` de la §7.1). El vim moderno en una terminal con soporte de bracketed paste maneja esto automáticamente; `vim.tiny`, `busybox vi` y `nvi` no.

**Reparación, sin volver a tipear**, usando el modo visual por bloques para quitar el exceso de indentación:

```
:set paste                 " stop the bleeding for the next paste
gg                         " to the top
V G                        " visual-select the whole file
=                          " reindent (only useful with a filetype indent plugin)

" Or, deterministically, filter the block through an external formatter:
:%!yq -P 'sort_keys(..)' -
```

```
$ yamllint -s pod.yaml && kubectl apply --dry-run=server -f pod.yaml
pod/web created (server dry run)
```

La lección generaliza: **`vi` puede pasar un búfer o un rango a través de cualquier comando externo** (`:%!cmd`, `:1,20!sort`, `!}fmt`). Eso convierte a cada formateador, linter y herramienta de texto de la máquina en un comando de `vi`.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Síntoma → causa → comando

| Síntoma | Causa más probable | Diagnóstico / arreglo |
|---|---|---|
| `E558: Terminal entry not found in terminfo` | `TERM` nombra una terminal sin entrada en terminfo — endémico en contenedores mínimos | `echo $TERM`; `infocmp $TERM >/dev/null`; instalá `ncurses-term`, o `TERM=vt100 vi file` |
| `Error opening terminal: xterm-256color.` (nano) | lo mismo | lo mismo; `TERM=vt100 nano file` |
| El editor abre pero las flechas insertan `A B C D` | desajuste de terminfo, o estás en modo inserción en el `vi` POSIX (que no maneja teclas de flecha en modo inserción) | usá `hjkl` en modo comando; arreglá `TERM` |
| La pantalla está congelada; las teclas no hacen nada, nada se cayó | presionaste `Ctrl-s` — control de flujo por software XOFF | presioná `Ctrl-q` para reanudar. Prevención: `stty -ixon` en `~/.bashrc` |
| La terminal queda ilegible después de un editor caído | el editor murió sin restaurar los modos de la terminal | `reset`, o `stty sane` y después `Ctrl-j` (puede que la terminal no esté haciendo eco de `⏎`) |
| `E37: No write since last change (add ! to override)` | intentaste `:q` con cambios sin guardar | `:w` para guardar, o `:q!` para descartar |
| `E45: 'readonly' option is set (add ! to override)` | la bandera de solo lectura propia de vim (abierto con `-R`/`view`, o el archivo no es escribible por vos) | `:w!` — esto anula la *bandera*, no los permisos |
| `E212: Can't open file for writing` | genuinamente no tenés permiso de escritura sobre el archivo **o el directorio** | §8.5. Chequeá `ls -ld $(dirname file)` — una escritura estilo rename necesita permiso de escritura sobre el **directorio** |
| `E514: write error (file system full?)` | disco o inodos agotados; el búfer **no** se perdió | `df -h .` y `df -i .`; liberá espacio, después `:w` de nuevo. **No** salgas. |
| El editor sale al instante con `E138: All .../.viminfo* files exist, cannot write viminfo file!` | archivos `.viminfo.tmp` obsoletos, normalmente después de una caída | `rm -f ~/.viminfo.tmp*`, o `set viminfofile=NONE` |
| `E325: ATTENTION ... swap file already exists` | sesión caída, o un editor concurrente | §8.4. Leé la línea `process ID` antes de elegir |
| Guardaste el archivo, pero el servicio sigue usando la configuración vieja | no recargaste el servicio | `systemctl reload <unit>`; confirmá con `systemctl show <unit> -p ExecMainStartTimestamp` |
| Guardaste el archivo, recargaste, y el servicio *sigue* viendo contenido viejo — dentro de un contenedor | inodo reemplazado por una escritura estilo rename; el bind mount del archivo quedó obsoleto | `stat -c %i` en el host y en el contenedor; `set backupcopy=yes`; recreá el contenedor |
| Guardaste el archivo y `tail -f` no muestra nada nuevo | `tail -f` sigue el inodo viejo | usá `tail -F` (`--follow=name --retry`) |
| El observador de recarga de configuración nunca dispara | watch de `inotify` sobre la ruta, inodo reemplazado | igual que arriba; o aumentá `fs.inotify.max_user_watches` si el observador llegó al límite: `sysctl fs.inotify.max_user_watches` |
| El archivo muestra `^M` al final de cada línea, o `[dos]` en la línea de estado | finales de línea CRLF de un editor de Windows o de un copiar-pegar | `:set ff=unix` y después `:w`; o `sed -i 's/\r$//' file`; verificá con `file` |
| Un script de shell falla con `bad interpreter: /bin/bash^M` | el mismo problema de CRLF en el shebang | `file script.sh`; `dos2unix script.sh` |
| La indentación se rompió después de pegar | cascada de `autoindent` | §8.6; `:set paste` |
| `Makefile:12: *** missing separator.  Stop.` | tu editor expandió el TAB inicial obligatorio en espacios | `cat -A Makefile \| sed -n 12p` — un tab real se muestra como `^I`; `:set noexpandtab` |
| `crontab: errors in crontab file, can't install.` | campo de cron inválido | mirá la §9.2 |
| `visudo` reporta un error de sintaxis | directiva de sudoers inválida | mirá la §9.2 — elegí **siempre** `e` para volver a editar, nunca `Q` |
| Las ediciones de un colega desaparecieron | ambos editaron el mismo archivo; gana la última escritura | usá los envoltorios con bloqueo (`visudo`, `vipw`, `crontab -e`); poné las configuraciones en git |
| Existe `/etc/.shadow.swp` | alguien abrió `/etc/shadow` en vim | hacele `shred -u`; desplegá el `vimrc` de la §7.1; auditá también `~/.viminfo` |

### 9.2 Los editores mediados fallando de forma segura

`crontab -e` con una programación errónea:

```
$ crontab -e
crontab: installing new crontab
"/tmp/crontab.9KqLpM":3: bad minute
errors in crontab file, can't install.
Do you want to retry the same edit? (y/n) y
```

Responder `y` reabre el editor con tu texto intacto. Responder `n` imprime dónde quedó tu trabajo:

```
Do you want to retry the same edit? (y/n) n
crontab: edits left in /tmp/crontab.9KqLpM
```

`visudo` con un error de sintaxis — el prompt que jamás debe responderse con `Q`:

```
$ sudo visudo -f /etc/sudoers.d/90-ops
>>> /etc/sudoers.d/90-ops: syntax error near line 4 <<<
What now?
Options are:
  (e)dit sudoers file again
  (x) exit without saving changes to sudoers file
  (Q) quit and save changes to sudoers file (DANGER!)

What now? e
```

> `Q` escribe un archivo que `sudo` no puede parsear. En la siguiente invocación de `sudo` cada administrador del host pierde la escalada de privilegios, y si el login de `root` está deshabilitado y no hay consola, el host es irrecuperable sin un arranque de rescate. Esta es la pulsación de tecla más cara de toda esta página.

Verificación independiente después, siempre, desde una **segunda** sesión que ya sea root:

```
$ sudo visudo -c
/etc/sudoers: parsed OK
/etc/sudoers.d/10-editor: parsed OK
/etc/sudoers.d/90-ops: parsed OK

$ sudo -l -U alice | tail -n 3
User alice may run the following commands on node-01:
    (root) NOPASSWD: sudoedit /etc/haproxy/haproxy.cfg
    (root) /usr/bin/systemctl reload nginx.service
```

### 9.3 Verificar que una edición realmente surtió efecto

Nunca confíes en "lo guardé". Probalo en cuatro niveles — el archivo, la sintaxis, el proceso, el comportamiento:

```
# 1. FILE: did the bytes change, and is the inode the one everyone else uses?
$ stat -c 'inode=%i links=%h size=%s mtime=%y perms=%a %U:%G' /etc/nginx/nginx.conf
inode=2621451 links=1 size=2247 mtime=2026-08-26 10:14:03.882014210 +0000 perms=644 root:root

$ sudo diff -u /etc/nginx/nginx.conf.2026-08-26-1010 /etc/nginx/nginx.conf
--- /etc/nginx/nginx.conf.2026-08-26-1010	2026-08-26 10:10:11.000000000 +0000
+++ /etc/nginx/nginx.conf	2026-08-26 10:14:03.882014210 +0000
@@ -14,6 +14,7 @@
 events {
-    worker_connections 768;
+    worker_connections 8192;
 }

$ sudo md5sum /etc/nginx/nginx.conf
7c0a2f1a5e2b8d4c9f0e1a3b5c7d9e11  /etc/nginx/nginx.conf

# 2. SYNTAX: does the consumer accept the file?
$ sudo nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful

# 3. PROCESS: is the running process using this inode, and did it reload?
$ sudo lsof -p "$(cat /run/nginx.pid)" 2>/dev/null | grep nginx.conf
nginx   1842 root    9r   REG  253,0    2247  2621451 /etc/nginx/nginx.conf

$ sudo systemctl reload nginx
$ systemctl show nginx -p ActiveState -p ExecMainStartTimestamp
ActiveState=active
ExecMainStartTimestamp=Tue 2026-08-26 10:14:41 UTC

# 4. BEHAVIOUR: does the system now do the thing you edited it to do?
$ sudo cat /proc/"$(cat /run/nginx.pid)"/limits | grep 'open files'
Max open files            65535                65535                files

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/healthz
200
```

El nivel 4 es el único que significa algo para un usuario. Los niveles 1–3 son cómo averiguás *por qué* falló el nivel 4.

La comprobación de una línea para la clase de bug del inodo, host vs. contenedor:

```
$ stat -c %i /srv/app/config/app.conf
2621789
$ docker exec app stat -c %i /etc/app.conf
2621451                              <-- MISMATCH: the bind mount is stale
```

```
$ docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{"\n"}}{{end}}' app
/srv/app/config/app.conf -> /etc/app.conf (bind)
```

Arreglo: editar con `backupcopy=yes` (o in-place sin `sed` mediante `cat > file`), y recrear el contenedor para restablecer el montaje.

### 9.4 Ejercicios guiados

Trabajá estos en una VM o contenedor descartable. Cada uno tiene un resultado comprobable.

**Ejercicio 1 — modos y las teclas del examen.** Creá un archivo de 20 líneas con `seq 20 > /tmp/d1.txt`. Usando solo `vi /tmp/d1.txt` y solo teclas de modo comando: (a) andá a la línea 12 con `12G`; (b) copiá tres líneas con `3yy`; (c) pegalas al final con `G` y después `p`; (d) borrá las líneas 5–7 con `5G` y después `3dd`; (e) cambiá la palabra de la línea 1 con `cw`; (f) guardá y salí con `ZZ`. Verificación: `wc -l /tmp/d1.txt` debe imprimir `20` (23 − 3).

**Ejercicio 2 — buscar y sustituir.** `cp /etc/services /tmp/d2.txt`. En `vi`: encontrá la primera aparición de `tcp` con `/tcp⏎`; recorré con `n`; buscá hacia atrás con `?udp⏎`; reemplazá cada `udp` por `UDP` en las líneas 1–100 con `:1,100s/udp/UDP/g`; después descartá todo con `:e!` y confirmá que el archivo no cambió con `diff /etc/services /tmp/d2.txt`.

**Ejercicio 3 — el muro de los permisos de escritura.** Como usuario no root, `vi /etc/hosts`, agregá una línea, e intentá `:w`, después `:w!`. Observá `E45` y después `E212`. Recuperate con `:w !sudo tee % > /dev/null` y después `:e!`. Verificá con `getent hosts <name>`.

**Ejercicio 4 — recuperación desde swap.** Abrí `/tmp/d1.txt` en `vim`, hacé un cambio, **no** guardes, y matá el proceso desde otra terminal con `pkill -9 vim`. Reabrí el archivo, leé el cartel `E325`, y recuperá con `vim -r`. Verificá el contenido recuperado con `diff`.

**Ejercicio 5 — la trampa del inodo.** `touch /tmp/bind-src; sudo mount --bind /tmp/bind-src /tmp/bind-dst` (creá `/tmp/bind-dst` primero). Editá `/tmp/bind-src` con `vim -c 'set backupcopy=no'` y observá que `/tmp/bind-dst` no cambia. Repetí con `backupcopy=yes` y observá que sí cambia. Limpiá con `sudo umount /tmp/bind-dst`.

**Ejercicio 6 — resolución de `$EDITOR`.** Usando el shim de la §6.2, determiná en tu sistema qué variable honran `crontab -e`, `git commit`, `systemctl edit` y `sudoedit`. Anotá las respuestas; son específicas de cada distribución.

**Ejercicio 7 — el casi accidente con sudoers.** En una VM **descartable**, `sudo visudo -f /etc/sudoers.d/99-test`, ingresá `%test ALL=(ALL) NOPASSWDD: ALL` (fijate en el error tipográfico), guardá, y practicá responder `e` en el prompt `What now?`. Después corregilo y confirmá con `visudo -c`. Nunca hagas este ejercicio en un host que te importe.

---

## 10. Repaso rápido para el examen

La lista literal de términos del objetivo, con la respuesta de una línea que cada uno exige:

| Término | Respuesta |
|---|---|
| `vi` | El editor visual exigido por POSIX; en Linux, casi siempre una compilación de `vim`. Arranca en **modo comando**. |
| `/` | Busca **hacia adelante** un patrón. |
| `?` | Busca **hacia atrás** un patrón. |
| `h` `j` `k` `l` | Izquierda, abajo, arriba, derecha — un carácter/línea por vez, en modo comando. |
| `i` | Insertar **antes** del cursor. (`a` = después, `o` = abrir línea debajo.) |
| `o` | **Abrir** (open) una nueva línea **debajo** de la actual y entrar en modo inserción. (`O` = encima.) |
| `a` | **Append** — insertar **después** del cursor. (`A` = al final de la línea.) |
| `c` | Operador **change** (cambiar): borra la región que cubre un movimiento y entra en modo inserción. `cw`, `cc`, `c$`. |
| `d` | Operador **delete** (borrar): `dw`, `d$`, `dG`. |
| `p` | **Put** (pegar) el registro **después** del cursor / **debajo** de la línea. (`P` = antes/encima.) |
| `y` | Operador **yank** (copiar): `yw`, `y$`. |
| `dd` | Borra la **línea actual completa**. `5dd` borra cinco. |
| `yy` | Copia la **línea actual completa**. `3yy` copia tres. |
| `ZZ` | Escribe **si fue modificado** y sale (igual que `:x`). `ZQ` = `:q!`. |
| `:w!` | Fuerza la escritura, anulando la bandera de solo lectura de vim — **no** los permisos del sistema de archivos. |
| `:q!` | Sale, **descartando** todos los cambios sin guardar. |
| `:e!` | Re-editar: descarta todos los cambios sin guardar y **recarga el archivo desde el disco**. |
| `EDITOR` | La variable de entorno que nombra el editor por defecto; `VISUAL` es su contraparte de pantalla completa y normalmente tiene precedencia. Debian además expone `/usr/bin/editor` mediante `update-alternatives`. |

Tres distinciones que se preguntan con distintas palabras cada vez:

1. **`:w!` no te convierte en root.** Anula el marcador de solo lectura del propio editor. El permiso lo impone el kernel.
2. **`:q!` descarta el búfer; `:e!` descarta el búfer y recarga.** Después de `:q!` volviste a la shell; después de `:e!` seguís editando.
3. **`ZZ` escribe solo si hubo modificaciones; `:wq` siempre escribe.** En un host con automatización disparada por cambios, esa diferencia es una recarga espuria del servicio.

---

## Referencias

**Objetivo de la certificación**

- LPI — Exam 101-500 Objectives (Topic 103.8, *Basic file editing*): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — LPIC-1 certification overview: <https://www.lpi.org/our-certifications/lpic-1-overview/>

**Estándares**

- The Open Group — POSIX.1-2017, `vi`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html>
- The Open Group — POSIX.1-2017, `ex`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ex.html>
- The Open Group — POSIX.1-2017, `ed`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ed.html>

**Editores**

- Vim — sitio oficial e índice de documentación: <https://www.vim.org/docs.php>
- Vim — manual del usuario (`usr_toc`), la representación HTML canónica de `:help`: <https://vimhelp.org/usr_toc.txt.html>
- Vim — `:help backupcopy` (estrategia de escritura y semántica de inodos): <https://vimhelp.org/options.txt.html#%27backupcopy%27>
- Vim — `:help recovery` (archivos de swap, `-r`, `:recover`): <https://vimhelp.org/recover.txt.html>
- Vim — página de manual `vim(1)` (Debian): <https://manpages.debian.org/stable/vim/vim.1.en.html>
- GNU nano — índice de documentación: <https://www.nano-editor.org/docs.php>
- GNU nano — `nano(1)`: <https://www.nano-editor.org/dist/latest/nano.html>
- GNU nano — `nanorc(5)`: <https://www.nano-editor.org/dist/latest/nanorc.5.html>
- GNU Emacs — manuales de referencia: <https://www.gnu.org/software/emacs/manual/>
- BusyBox — referencia de comandos (incluye `vi`): <https://busybox.net/downloads/BusyBox.html>

**Edición mediada, bloqueo y validación**

- Sudo — `sudo(8)` / `sudoedit`: <https://www.sudo.ws/docs/man/sudo.man/>
- Sudo — `visudo(8)`: <https://www.sudo.ws/docs/man/visudo.man/>
- Sudo — `sudoers(5)` (`editor`, `env_editor`, `SUDO_EDITOR`): <https://www.sudo.ws/docs/man/sudoers.man/>
- `vipw(8)` / `vigr(8)`: <https://man7.org/linux/man-pages/man8/vipw.8.html>
- `crontab(1)`: <https://man7.org/linux/man-pages/man1/crontab.1.html>
- systemd — `systemctl(1)`, verbo `edit`: <https://www.freedesktop.org/software/systemd/man/latest/systemctl.html>
- systemd — variables de entorno, incluida `$SYSTEMD_EDITOR`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.html>
- Debian — `update-alternatives(1)`: <https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html>

**Interfaces del sistema referenciadas en el análisis de la ruta de escritura**

- `rename(2)` — semántica de reemplazo atómico: <https://man7.org/linux/man-pages/man2/rename.2.html>
- `inotify(7)` — por qué los observadores se pierden el reemplazo de inodo: <https://man7.org/linux/man-pages/man7/inotify.7.html>
- `terminfo(5)` — base de datos de capacidades de terminal: <https://man7.org/linux/man-pages/man5/terminfo.5.html>
- GNU coreutils — invocación de `stty` (`-ixon`, `sane`): <https://www.gnu.org/software/coreutils/manual/html_node/stty-invocation.html>
- OpenSSH — `sshd(8)`, incluido el test de configuración `-t`: <https://man.openbsd.org/sshd.8>

**Herramientas de infraestructura usadas en los manifiestos**

- Kubernetes — `kubectl edit`: <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_edit/>
- Kubernetes — depurar un Pod en ejecución con contenedores efímeros: <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/>
- Kubernetes — ConfigMaps, incluido el comportamiento de actualización con `subPath`: <https://kubernetes.io/docs/concepts/configuration/configmap/>
- Ansible — `ansible.builtin.copy` (`validate`, movimiento atómico): <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/copy_module.html>
- Ansible — `ansible.builtin.lineinfile`: <https://docs.ansible.com/ansible/latest/collections/ansible/builtin/lineinfile_module.html>
- cloud-init — referencia de módulos y ejemplos: <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>
- yamllint — configuración y reglas: <https://yamllint.readthedocs.io/>