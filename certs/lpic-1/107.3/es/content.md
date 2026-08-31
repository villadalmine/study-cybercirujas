# 107.3 — Localización e internacionalización

**Certificación:** LPIC-1 (101-500 / 102-500, v5.0) · El **objetivo 107.3** pertenece al examen **102-500** · **Peso: 3**

> **i18n** (internacionalización) es la propiedad de ingeniería del software que *puede* adaptarse a un locale sin recompilar. **l10n** (localización) son los datos en tiempo de ejecución — charmaps, tablas de colación, catálogos de mensajes, reglas de zona horaria — que hacen que efectivamente se adapte. En Linux, i18n es una superficie de API de glibc/musl; l10n es un conjunto de archivos en disco más un puñado de variables de entorno. Este objetivo trata de lo segundo, y del hecho de que *esas variables son estado del proceso, no estado de la máquina*.

**Archivos, términos y utilidades clave (lista del objetivo LPI):** `/etc/timezone`, `/etc/localtime`, `/usr/share/zoneinfo/`, `LC_*`, `LC_ALL`, `LANG`, `TZ`, `/usr/bin/locale`, `tzselect`, `timedatectl`, `date`, `iconv`, UTF-8, ISO-8859, ASCII, Unicode.

---

## 1. El problema de producción

El locale es la pieza menos especificada de un entorno de ejecución Linux, y la única que cambia silenciosamente la *semántica* de las herramientas estándar en lugar de fallar ruidosamente. Cuatro clases reales de falla justifican tratarlo como configuración bajo control de versiones:

**1.1 — La deriva de colación rompe los datos, no solo la presentación.**
`sort`, las expresiones entre corchetes `[a-z]`, el orden de `ls` y los índices B-tree de las bases de datos están todos definidos por `LC_COLLATE`. glibc 2.28 (RHEL 8, Debian 10, Ubuntu 18.10) reemplazó sus datos de colación por las tablas ISO 14651. Todo índice de PostgreSQL construido sobre una columna de texto bajo `en_US.UTF-8` en un host anterior a 2.28 quedó *lógicamente corrupto* tras la actualización — el índice afirma un orden con el que la función de comparación ya no coincide, así que `WHERE name = 'x'` puede devolver cero filas para una fila que existe. El arreglo es `REINDEX`, y la detección es una comparación de versiones, no un health check.

**1.2 — El formato numérico corrompe la salida legible por máquina.**
`LC_NUMERIC=de_DE.UTF-8` hace que `printf '%.2f' 3.14` emita `3,14`. Cualquier pipeline que genere un CSV, una línea de exposición de Prometheus o un fragmento JSON con el `printf` del shell y herede el locale del escritorio de un operador por SSH produce basura sintácticamente válida que el consumidor acepta e interpreta mal.

**1.3 — Las suposiciones sobre el juego de caracteres son un límite de integridad de datos.**
Un nombre de archivo escrito por un proceso bajo `ISO-8859-1` y leído por un proceso bajo `UTF-8` no se "muestra mal" — es una secuencia de bytes irrepresentable. Los backups, `rsync --delete`, las herramientas de sincronización con object stores y Git se comportan todos de forma distinta ante UTF-8 inválido. El mojibake en los logs es cosmético; el mojibake en los nombres de archivo es una restauración que falla a las 3 de la mañana.

**1.4 — La zona horaria es una propiedad de corrección de la planificación.**
Una entrada de cron a las `02:30` en `Europe/Madrid` se ejecuta **dos veces** el día del retroceso de DST de marzo en el equivalente del hemisferio sur y **ninguna vez** el día del adelanto de primavera. Un contenedor sin `tzdata` ignora silenciosamente `TZ` y corre en UTC. Un `CronJob` de Kubernetes sin `.spec.timeZone` se evalúa en la zona del *controller manager*, no en la del pod.

La regla arquitectónica que se desprende: **la plataforma corre en `C.UTF-8` y UTC; la localización es una decisión de la capa de presentación aplicada en el borde, nunca heredada.** Todo lo que sigue es cómo se aplica y se verifica eso.

---

## 2. Arquitectura de locales en glibc

### 2.1 Las categorías

Un locale no es un solo ajuste. Es un conjunto de categorías independientes, cada una respaldada por una tabla en la definición del locale. Cada categoría se puede sobrescribir por separado.

| Categoría | Gobierna | Qué rompe concretamente cuando está mal |
|---|---|---|
| `LC_CTYPE` | Clasificación de caracteres, mapeo de mayúsculas/minúsculas, codificación multibyte | `tr`, `toupper()`, `grep -i`, ancho en terminal de CJK/emoji, `wc -m` |
| `LC_COLLATE` | Comparación de cadenas y orden de clasificación | `sort`, `ls`, rangos `[a-z]`, índices de BD, `join`, `comm` |
| `LC_NUMERIC` | Separador decimal, agrupación de miles | `printf '%f'`, `sort -n`, salida de `awk`, generación de CSV/JSON |
| `LC_TIME` | Orden de los campos de fecha/hora, nombres de mes y día, 12/24 h | `date`, `ls -l`, parsers de logs que dependen de las abreviaturas de mes `%b` |
| `LC_MONETARY` | Símbolo de moneda, posición del signo, dígitos decimales | Informes, facturas, `strfmon()` |
| `LC_MESSAGES` | Selección del catálogo de mensajes, expresiones sí/no | La stderr de toda herramienta → rompe la búsqueda de errores con `grep` en los scripts |
| `LC_PAPER` | Tamaño de papel por defecto (A4 vs Letter) | CUPS, `groff`, pipelines de PDF |
| `LC_NAME`, `LC_ADDRESS`, `LC_TELEPHONE` | Formatos de nombre personal, postal y telefónico | Formato a nivel de aplicación |
| `LC_MEASUREMENT` | Métrico vs imperial | Herramientas conscientes de `units` |
| `LC_IDENTIFICATION` | Metadatos sobre la propia definición del locale | Solo introspección |

### 2.2 Precedencia de resolución — el único orden que vale la pena memorizar

```
LC_ALL   →  overrides every category, unconditionally
LC_xxx   →  overrides LANG for that one category
LANG     →  default for every category not otherwise set
(builtin)→  "C" / "POSIX" if nothing is set at all
```

`LANGUAGE` es una **extensión GNU de gettext** y queda fuera de esta cadena: toma una lista de respaldo separada por dos puntos (`LANGUAGE=ca:es:en`) y afecta **solo** a la traducción de mensajes, y **solo** cuando `LC_MESSAGES` no es `C`/`POSIX`.

| Variable | Alcance | Sobrescribe | Uso legítimo típico |
|---|---|---|---|
| `LC_ALL` | Todas las categorías | Todo | **Scripts.** `export LC_ALL=C` al inicio de cualquier script cuya salida se parsee |
| `LANG` | Todas las categorías (como valor por defecto) | El valor por defecto interno | Valor por defecto del sistema/usuario en `/etc/locale.conf` |
| `LC_COLLATE` | Una categoría | `LANG` | Fijar el orden de clasificación en `C` manteniendo `LC_CTYPE` en UTF-8 |
| `LANGUAGE` | Solo catálogos de mensajes | `LC_MESSAGES` para la búsqueda de traducciones | Cadenas de respaldo multiidioma en escritorios |

**El idioma del determinismo.** Para cualquier script cuya stdout sea consumida por otro programa:

```bash
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C.UTF-8   # deterministic collation + numeric, still 8-bit clean
export TZ=UTC
```

Usá `LC_ALL=C` (no `C.UTF-8`) solo cuando además querés un `LC_CTYPE` orientado a bytes — p. ej. `grep`/`sed` sobre datos casi binarios, donde la validación UTF-8 haría que `grep` se salteara líneas.

### 2.3 Dónde viven físicamente los datos de locale

| Artefacto | Ruta | Rol |
|---|---|---|
| Definiciones fuente de locale | `/usr/share/i18n/locales/` | Reglas de categoría legibles por humanos (`en_US`, `es_ES`, `i18n`, `iso14651_t1`) |
| Charmaps | `/usr/share/i18n/charmaps/` | Mapeo nombre simbólico → secuencia de bytes (`UTF-8.gz`, `ISO-8859-15.gz`) |
| Archivo compilado de locales | `/usr/lib/locale/locale-archive` | Blob binario mapeable en memoria con todos los locales compilados (glibc) |
| Directorios compilados por locale | `/usr/lib/locale/<locale>/` | Alternativa al archivo único (`localedef --no-archive`) |
| Catálogos de mensajes | `/usr/share/locale/<lang>/LC_MESSAGES/*.mo` | Traducciones de gettext |
| Lista de generación (Debian) | `/etc/locale.gen` | Qué pares `locale`+`charmap` compila `locale-gen` |
| Valor por defecto del sistema (systemd) | `/etc/locale.conf` | Leído por PID 1; exportado a todos los servicios |
| Valor por defecto del sistema (Debian legado) | `/etc/default/locale` | Leído por PAM (`pam_env`) para las sesiones de login |

`localedef` es el compilador: consume una fuente de locale más un charmap y emite la forma binaria.

### 2.4 glibc vs musl — la trampa de las imágenes de contenedor

| Propiedad | glibc (Debian, Ubuntu, RHEL) | musl (Alpine) |
|---|---|---|
| Locales soportados | Conjunto completo, compilado bajo demanda | Solo `C` / `C.UTF-8` (más los alias `*.UTF-8` tratados como UTF-8) |
| Comportamiento de `LC_CTYPE` | Charmap por locale | Siempre UTF-8 |
| `LC_COLLATE` | Colación ISO 14651 completa | Solo orden de bytes (equivalente a `C`) |
| `LC_MESSAGES` | Catálogos de gettext | Stub salvo que se instale `musl-locales` |
| Salida de `locale -a` | Lista larga | `C`, `C.UTF-8`, `POSIX` |
| Consecuencia práctica | El orden de clasificación es un comportamiento acoplado a la versión | El orden de clasificación es estable para siempre, pero no hay localización |

**La restricción de Alpine es una característica para SRE, no un bug**: en musl no podés heredar accidentalmente una colación dependiente del locale. Si tu estándar de plataforma es `C.UTF-8`, Alpine te lo impone gratis.

---

## 3. Codificaciones de caracteres

### 3.1 Comparación

| Codificación | Bytes/carácter | Repertorio | Compatible con ASCII | Autosincronizante | Endianness | Estado |
|---|---|---|---|---|---|---|
| **ASCII (US-ASCII)** | 1 (7 bits usados) | 128 code points | — (es ASCII) | sí | n/a | Sustrato de todo |
| **ISO-8859-1** (Latin-1) | 1 | 256 (Europa occidental) | sí | sí | n/a | Legado; sin `€` |
| **ISO-8859-15** (Latin-9) | 1 | 256; agrega `€ Š š Ž ž Œ œ Ÿ` | sí | sí | n/a | Sucesor legado de Latin-1 |
| **ISO-8859-2/5/7/9** | 1 | Europa central / cirílico / griego / turco | sí | sí | n/a | Legado |
| **UTF-8** | 1–4 | Unicode completo (U+0000–U+10FFFF) | **sí** | **sí** | ninguna | **Por defecto. La única elección correcta.** |
| **UTF-16** | 2 o 4 (pares subrogados) | Unicode completo | no | parcialmente | LE/BE + BOM | Internos de Windows/Java, cadenas de JS |
| **UCS-2** | 2 (fijo) | Solo BMP (U+0000–U+FFFF) | no | sí | LE/BE + BOM | **Obsoleto** — no puede codificar emoji ni ext. CJK. |
| **UTF-32 / UCS-4** | 4 (fijo) | Unicode completo | no | sí | LE/BE + BOM | `wchar_t` interno en Linux; derrochador en la red |

**Por qué UTF-8 gana en un sistema Unix**, en las tres propiedades que importan operativamente:

1. **Transparencia ASCII** — un byte `< 0x80` es siempre ese carácter ASCII y nunca parte de una secuencia multibyte. `/`, `\0`, `\n` conservan su significado, así que el manejo de rutas del kernel, la división de líneas basada en `read()` y todas las funciones de cadenas de C siguen funcionando sin modificaciones.
2. **Autosincronización** — los bytes iniciales son `0xxxxxxx` o `11xxxxxx`; los bytes de continuación son siempre `10xxxxxx`. Podés posicionarte en un desplazamiento aleatorio de un archivo de log y encontrar el siguiente límite de carácter en ≤3 bytes. UTF-16 no puede hacer esto.
3. **Sin BOM, sin endianness** — el orden de bytes está fijado por la codificación, así que no hay nada que negociar entre arquitecturas.

### 3.2 Mecánica de la codificación UTF-8

| Rango de code points | Bytes | Patrón de bits |
|---|---|---|
| U+0000 – U+007F | 1 | `0xxxxxxx` |
| U+0080 – U+07FF | 2 | `110xxxxx 10xxxxxx` |
| U+0800 – U+FFFF | 3 | `1110xxxx 10xxxxxx 10xxxxxx` |
| U+10000 – U+10FFFF | 4 | `11110xxx 10xxxxxx 10xxxxxx 10xxxxxx` |

```
$ printf 'año €\n' | hexdump -C
00000000  61 c3 b1 6f 20 e2 82 ac  0a                       |a..o ....|
00000009
```

`ñ` = U+00F1 → `C3 B1` (2 bytes). `€` = U+20AC → `E2 82 AC` (3 bytes). Notá que `LANG` no cambió el archivo — los *bytes* son la codificación; el locale solo le dice a los programas cómo interpretarlos.

### 3.3 Mojibake, descifrado

La misma `ñ` escrita como ISO-8859-1 es el único byte `F1`. Hacerle un round-trip incorrecto es determinista y por lo tanto diagnosticable:

```
$ printf 'a\xf1o\n' | hexdump -C
00000000  61 f1 6f 0a                                       |a.o.|
00000004

$ printf 'a\xf1o\n' | iconv -f UTF-8 -t UTF-8
a
iconv: illegal input sequence at position 1
```

| Síntoma en pantalla | Qué pasó realmente |
|---|---|
| `aÃ±o` | Bytes UTF-8 (`C3 B1`) renderizados como Latin-1 — la **visualización** está mal, los datos están bien |
| `a?o` / `a\xf1o` / `a<?>o` | Byte Latin-1 `F1` entregado a un decodificador UTF-8 — los **datos** están mal para ese consumidor |
| `aÃ¯Â¿Â½o` | Doble codificación: texto ya en UTF-8 pasado otra vez por `iconv -f latin1 -t utf8` |
| `a□o` (cuadrito) | UTF-8 correcto, pero a la **fuente tipográfica** le falta el glifo — ni los datos ni el locale están mal |

La última fila es la razón por la que "revisá la terminal antes de revisar el pipeline" pertenece al runbook.

---

## 4. Hora y zonas horarias

### 4.1 El modelo de tres capas

```
 hardware RTC  ──►  kernel CLOCK_REALTIME (always UTC internally)  ──►  userspace rendering
 (UTC or local)      seconds since 1970-01-01T00:00:00Z                  via TZ / /etc/localtime
```

El kernel mantiene UTC. **La zona horaria la aplica libc, por proceso, al momento de formatear** (`tzset(3)` → `localtime(3)`). Nada en el kernel está "en Europe/Madrid".

### 4.2 Mecanismos

| Mecanismo | Ruta / forma | Alcance | Precedencia | Notas |
|---|---|---|---|---|
| Variable de entorno `TZ` | `TZ=Europe/Madrid` | Un solo proceso + sus hijos | **La más alta** | Forma preferida: nombre IANA |
| `TZ` como ruta explícita | `TZ=:/usr/share/zoneinfo/Asia/Tokyo` | Proceso | La más alta | El `:` inicial = "esto es una ruta de archivo" |
| Cadena de regla POSIX en `TZ` | `TZ=CET-1CEST,M3.5.0/2,M10.5.0/3` | Proceso | La más alta | Sin datos históricos; reglas de DST hardcodeadas → **evitar** |
| `/etc/localtime` | Enlace simbólico → `/usr/share/zoneinfo/<Area>/<City>` | Valor por defecto de todo el sistema | Se usa cuando `TZ` no está definida | Canónico en systemd; también puede ser una copia del archivo |
| `/etc/timezone` | Texto plano, una línea: `Europe/Madrid` | Registro contable de Debian/Ubuntu | Informativo | Leído por el postinst de `tzdata` y algunas herramientas; **no** por libc |
| `/usr/share/zoneinfo/` | Base de datos binaria TZif (IANA tzdata) | Fuente de datos | — | `Etc/UTC`, `Etc/GMT+5` (el signo está invertido, al estilo POSIX) |
| `timedatectl set-timezone` | API de systemd | Reescribe `/etc/localtime` | — | La vía de escritura correcta en hosts con systemd |
| `.spec.timeZone` de CronJob | Kubernetes ≥1.27 (estable) | Evaluación de la programación | — | Independiente del `TZ` del pod |

**La precedencia en una frase:** gana `TZ` (si está definida y es válida); si no, libc lee `/etc/localtime`; si eso falta, todo es UTC.

### 4.3 RTC en UTC vs hora local

```
$ timedatectl status
               Local time: Thu 2026-08-27 16:03:11 CEST
           Universal time: Thu 2026-08-27 14:03:11 UTC
                 RTC time: Thu 2026-08-27 14:03:11
                Time zone: Europe/Madrid (CEST, +0200)
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```

`RTC in local TZ: no` es la única respuesta correcta en un servidor. Ponerlo en `yes` (`timedatectl set-local-rtc 1`, necesario para algunos escritorios con arranque dual con Windows) vuelve ambigua la transición de DST en el arranque y systemd lo desaconseja explícitamente.

### 4.4 tzdata es una dependencia móvil

Los gobiernos cambian las reglas de DST con semanas de aviso. Las publicaciones de `tzdata` (p. ej. `2026a`) traen esos cambios. Una imagen de contenedor de larga vida fija la tzdata con la que fue construida; un pod arrancado desde una imagen de dos años calculará la *hora local equivocada* después de un cambio de reglas aunque el nodo esté correcto. **Tratá a `tzdata` como una dependencia de clase seguridad en la política de reconstrucción de imágenes.**

---

## 5. Matriz de configuración por distribución

| Tarea | Debian / Ubuntu | RHEL / Fedora / Rocky | systemd genérico | Alpine |
|---|---|---|---|---|
| Listar locales disponibles | `locale -a` | `locale -a` | `localectl list-locales` | `locale -a` (3 entradas) |
| Hacer disponible un locale | Editar `/etc/locale.gen`, ejecutar `locale-gen` | `dnf install glibc-langpack-es` | — | n/a |
| Compilar uno ad hoc | `localedef -i es_ES -f UTF-8 es_ES.UTF-8` | igual | igual | no soportado |
| Archivo de valor por defecto del sistema | `/etc/default/locale` **y** `/etc/locale.conf` | `/etc/locale.conf` | `/etc/locale.conf` | `/etc/profile.d/locale.sh` |
| Fijar el valor por defecto del sistema | `update-locale LANG=en_US.UTF-8` | `localectl set-locale LANG=en_US.UTF-8` | `localectl set-locale …` | editar el script de profile |
| Paquete de zona horaria | `tzdata` | `tzdata` | `tzdata` | `apk add tzdata` |
| Fijar la zona horaria | `timedatectl set-timezone …` (o `dpkg-reconfigure tzdata`) | `timedatectl set-timezone …` | `timedatectl set-timezone …` | `cp /usr/share/zoneinfo/X /etc/localtime` |
| Mapa de teclado de consola | `/etc/default/keyboard` | `localectl set-keymap` | `localectl set-keymap` | `setup-keymap` |

**Dónde se lee realmente cada archivo** — esta es la parte que produce el "lo configuré y no se aplicó":

| Archivo | Leído por | Se aplica a |
|---|---|---|
| `/etc/locale.conf` | systemd PID 1 | **Todos los servicios** arrancados por systemd, y las sesiones de login vía `pam_systemd` |
| `/etc/default/locale` | `pam_env` (Debian) | Logins interactivos (SSH, consola, `su -`) |
| `/etc/environment` | `pam_env` | Solo logins interactivos — **no** los servicios |
| `~/.bashrc`, `/etc/profile.d/*.sh` | bash | Solo shells interactivas — **nunca** los servicios, **nunca** un `sh -c` desde cron |
| `Environment=` en una unit | systemd | Ese único servicio |

Un servicio de `systemd` **no** ve el locale de tu `~/.bashrc`. Ese es el bug de locale más común del tipo "funciona en mi shell, se rompe en producción".

---

## 6. Manifiestos de infraestructura

### 6.1 Configuración base del SO (rol de Ansible, completo)

```yaml
---
# roles/locale_baseline/defaults/main.yml
locale_baseline_system_lang: "C.UTF-8"
locale_baseline_timezone: "Etc/UTC"
locale_baseline_extra_locales:
  - "en_US.UTF-8 UTF-8"
  - "es_ES.UTF-8 UTF-8"
locale_baseline_rtc_local: false
```

```yaml
---
# roles/locale_baseline/tasks/main.yml
- name: Ensure tzdata and locale tooling are present
  ansible.builtin.package:
    name: "{{ locale_pkgs }}"
    state: present
  vars:
    locale_pkgs: >-
      {{ ['tzdata', 'locales'] if ansible_facts['os_family'] == 'Debian'
         else ['tzdata', 'glibc-langpack-en', 'glibc-langpack-es'] }}

- name: Declare the locales to compile (Debian family)
  ansible.builtin.lineinfile:
    path: /etc/locale.gen
    regexp: "^#?\\s*{{ item | regex_escape() }}$"
    line: "{{ item }}"
    state: present
    create: true
    owner: root
    group: root
    mode: "0644"
  loop: "{{ locale_baseline_extra_locales }}"
  when: ansible_facts['os_family'] == 'Debian'
  notify: run locale-gen

- name: Enforce the system locale (systemd manager environment)
  ansible.builtin.copy:
    dest: /etc/locale.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible - role locale_baseline
      # Platform standard: byte-deterministic collation, UTF-8 clean.
      LANG={{ locale_baseline_system_lang }}
      LC_COLLATE=C
      LC_NUMERIC=C

- name: Enforce the same defaults for PAM login sessions (Debian)
  ansible.builtin.copy:
    dest: /etc/default/locale
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible - role locale_baseline
      LANG={{ locale_baseline_system_lang }}
      LC_COLLATE=C
      LC_NUMERIC=C
  when: ansible_facts['os_family'] == 'Debian'

- name: Set the system timezone
  community.general.timezone:
    name: "{{ locale_baseline_timezone }}"
    hwclock: "{{ 'local' if locale_baseline_rtc_local else 'UTC' }}"

- name: Refuse to accept client locale variables over SSH
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^\s*#?\s*AcceptEnv'
    line: "AcceptEnv LANG LC_ALL_DISABLED"
    validate: "/usr/sbin/sshd -t -f %s"
  notify: reload sshd

- name: Verify the resulting locale is actually usable
  ansible.builtin.command:
    cmd: locale
  environment:
    LC_ALL: "{{ locale_baseline_system_lang }}"
  register: locale_check
  changed_when: false
  failed_when: "'Cannot set LC_ALL' in locale_check.stderr"
```

```yaml
---
# roles/locale_baseline/handlers/main.yml
- name: run locale-gen
  ansible.builtin.command:
    cmd: locale-gen
  changed_when: true

- name: reload sshd
  ansible.builtin.service:
    name: sshd
    state: reloaded
```

### 6.2 Unit de systemd y drop-in

```ini
# /etc/systemd/system/report-exporter.service
[Unit]
Description=Nightly billing report exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=exporter
Group=exporter

# Services do NOT inherit an operator's shell locale. Pin it explicitly.
Environment=LC_ALL=C.UTF-8
Environment=TZ=UTC
Environment=PYTHONUTF8=1

ExecStart=/usr/local/bin/export-report --out /var/lib/exporter/report.csv

PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/exporter
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/report-exporter.service.d/10-presentation-locale.conf
# Drop-in used ONLY on the reporting host, where output is human-facing.
# LC_COLLATE stays at C so the CSV row order remains reproducible.
[Service]
Environment=LC_TIME=es_ES.UTF-8
Environment=LC_MONETARY=es_ES.UTF-8
Environment=LC_COLLATE=C
Environment=LC_NUMERIC=C
Environment=TZ=Europe/Madrid
```

```ini
# /etc/systemd/system/report-exporter.timer
[Unit]
Description=Run the billing report exporter nightly

[Timer]
# systemd timers evaluate OnCalendar in the system timezone unless told otherwise.
# Pin it so a host-level timezone change cannot shift the business schedule.
OnCalendar=*-*-* 02:30:00 Europe/Madrid
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

### 6.3 Imágenes de contenedor

```dockerfile
# Dockerfile — Debian base, full locale support
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      locales \
      tzdata \
      ca-certificates \
 && sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && sed -i 's/^# *\(es_ES\.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

# LANG/LC_ALL must be baked in: an image has no PAM, no login shell,
# and no /etc/locale.conf consumer, so nothing else will export them.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# Prove at build time that the locale resolves. Fails the build, not the pod.
RUN locale >/dev/null && [ "$(date +%Z)" = "UTC" ]

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

```dockerfile
# Dockerfile — Alpine base. musl gives C.UTF-8 only; tzdata is NOT installed by default,
# which means the TZ environment variable is silently ignored without this apk add.
FROM alpine:3.20

RUN apk add --no-cache tzdata ca-certificates

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

RUN [ -f /usr/share/zoneinfo/Europe/Madrid ] || (echo "tzdata missing" && exit 1)
```

> **Advertencia sobre distroless / `FROM scratch`.** Estas imágenes no tienen `/usr/share/zoneinfo`. Poner `TZ=Europe/Madrid` no hace nada y el proceso corre en UTC. O copiás el árbol de zoneinfo desde una etapa de construcción, o — para binarios de Go — usás `import _ "time/tzdata"` para embeber la base de datos en el ejecutable.

### 6.4 Kubernetes

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-locale
  namespace: billing
  labels:
    app.kubernetes.io/part-of: billing
data:
  # Platform standard. Referenced by envFrom so every workload gets the same
  # baseline and drift is a single-object diff.
  LANG: "C.UTF-8"
  LC_ALL: "C.UTF-8"
  TZ: "UTC"
  PYTHONUTF8: "1"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: invoice-renderer
  namespace: billing
  labels:
    app.kubernetes.io/name: invoice-renderer
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: invoice-renderer
  template:
    metadata:
      labels:
        app.kubernetes.io/name: invoice-renderer
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: renderer
          image: registry.example.com/billing/invoice-renderer:1.14.2
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef:
                name: platform-locale
          env:
            # Presentation-layer override: invoices are rendered for ES customers.
            # Collation and numeric parsing stay at C so internal CSV output and
            # sort order remain byte-reproducible across replicas.
            - name: LC_ALL
              value: ""
            - name: LANG
              value: "es_ES.UTF-8"
            - name: LC_COLLATE
              value: "C"
            - name: LC_NUMERIC
              value: "C"
            - name: LC_MONETARY
              value: "es_ES.UTF-8"
            - name: LC_TIME
              value: "es_ES.UTF-8"
            - name: TZ
              value: "Europe/Madrid"
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: "100m"
              memory: "192Mi"
            limits:
              memory: "512Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          startupProbe:
            exec:
              # Fail fast and loudly if the image lacks the compiled locale:
              # glibc falls back to C and the invoice silently loses its accents.
              command:
                - /bin/sh
                - -c
                - 'locale 2>&1 | grep -q "Cannot set" && exit 1; [ "$(date +%Z)" = "CET" ] || [ "$(date +%Z)" = "CEST" ]'
            failureThreshold: 3
            periodSeconds: 5
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-close
  namespace: billing
spec:
  # REQUIRED for business schedules. Without .spec.timeZone the schedule is
  # evaluated in the kube-controller-manager's timezone (usually UTC), NOT in
  # the pod's TZ. Stable since Kubernetes v1.27.
  timeZone: "Europe/Madrid"
  schedule: "30 2 * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: close
              image: registry.example.com/billing/close:1.14.2
              envFrom:
                - configMapRef:
                    name: platform-locale
              command: ["/usr/local/bin/close-books"]
              resources:
                requests:
                  cpu: "500m"
                  memory: "512Mi"
                limits:
                  memory: "1Gi"
---
# Anti-pattern kept deliberately, for the comparison in §7.
# Mounting the node's clock configuration couples the pod to node state:
# a node in a different region renders different timestamps for the same
# Deployment, and the mount fails outright on distroless images that have
# no /etc/localtime to be overmounted.
apiVersion: v1
kind: Pod
metadata:
  name: legacy-tz-via-hostpath
  namespace: billing
spec:
  containers:
    - name: app
      image: registry.example.com/billing/legacy:0.9.1
      volumeMounts:
        - name: tz
          mountPath: /etc/localtime
          readOnly: true
  volumes:
    - name: tz
      hostPath:
        path: /usr/share/zoneinfo/Europe/Madrid
        type: File
```

| Estrategia de zona horaria en contenedores | Portabilidad | Acoplamiento al nodo | Funciona en distroless | Veredicto |
|---|---|---|---|---|
| Variable `TZ` + `tzdata` en la imagen | Alta | Ninguno | No (no hay zoneinfo) | **Preferida** |
| Montaje `hostPath` de `/etc/localtime` | Baja | Total | No | Solo legado |
| ConfigMap que contiene un archivo TZif | Media | Ninguno | Sí | Aceptable para distroless |
| tzdata embebida (Go `time/tzdata`) | Alta | Ninguno | Sí | La mejor para imágenes scratch |
| No hacer nada, correr en UTC, formatear en el borde | La más alta | Ninguno | Sí | **El valor por defecto correcto** |

### 6.5 cloud-init

```yaml
#cloud-config
# Applied at first boot; makes the locale/timezone contract part of instance identity.
locale: C.UTF-8
locale_configfile: /etc/default/locale
timezone: Etc/UTC

write_files:
  - path: /etc/locale.conf
    owner: root:root
    permissions: "0644"
    content: |
      LANG=C.UTF-8
      LC_COLLATE=C
      LC_NUMERIC=C
  - path: /etc/profile.d/00-platform-locale.sh
    owner: root:root
    permissions: "0644"
    content: |
      # Interactive shells only. Services get this from /etc/locale.conf.
      export LANG=C.UTF-8
      export LC_COLLATE=C
      export LC_NUMERIC=C

runcmd:
  - [ timedatectl, set-timezone, "Etc/UTC" ]
  - [ timedatectl, set-local-rtc, "0" ]
  - [ sh, -c, "locale >/dev/null || (echo 'locale unusable' >&2; exit 1)" ]
```

---

## 7. Referencia de CLI — comandos reales, salidas reales

### 7.1 Inspeccionar el locale actual

```
$ locale
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="en_US.UTF-8"
LC_NUMERIC="en_US.UTF-8"
LC_TIME="en_US.UTF-8"
LC_COLLATE="en_US.UTF-8"
LC_MONETARY="en_US.UTF-8"
LC_MESSAGES="en_US.UTF-8"
LC_PAPER="en_US.UTF-8"
LC_NAME="en_US.UTF-8"
LC_ADDRESS="en_US.UTF-8"
LC_TELEPHONE="en_US.UTF-8"
LC_MEASUREMENT="en_US.UTF-8"
LC_IDENTIFICATION="en_US.UTF-8"
LC_ALL=
```

> **Leé las comillas.** Un valor entre `"comillas dobles"` es *derivado* de `LANG`. Un valor sin comillas fue definido explícitamente en el entorno. Esta distinción te dice, de un vistazo, qué variable cambiar.

```
$ export LC_TIME=es_ES.UTF-8
$ locale | grep -E '^(LANG|LC_TIME|LC_COLLATE)='
LANG=en_US.UTF-8
LC_COLLATE="en_US.UTF-8"
LC_TIME=es_ES.UTF-8
```

`LC_TIME` ahora aparece sin comillas — es un override explícito.

```
$ locale -a | head -8
C
C.utf8
POSIX
en_US.utf8
es_ES.utf8
es_ES.utf8@euro
en_GB.utf8
de_DE.utf8

$ locale -a | wc -l
14

$ locale charmap
UTF-8

$ locale -m | grep -i -E 'utf|8859-1[59]?$'
ISO-8859-1
ISO-8859-15
UTF-8
```

Consultar palabras clave individuales — útil cuando escribís un parser y necesitás saber qué va a producir el locale *destino*:

```
$ LC_ALL=es_ES.UTF-8 locale -k LC_NUMERIC
decimal_point=","
thousands_sep="."
grouping=3;3
numeric-decimal-point-wc=44
numeric-thousands-sep-wc=46
numeric-codeset="UTF-8"

$ LC_ALL=es_ES.UTF-8 locale -k LC_TIME | head -4
abday="dom";"lun";"mar";"mié";"jue";"vie";"sáb"
day="domingo";"lunes";"martes";"miércoles";"jueves";"viernes";"sábado"
abmon="ene";"feb";"mar";"abr";"may";"jun";"jul";"ago";"sep";"oct";"nov";"dic"
mon="enero";"febrero";"marzo";"abril";"mayo";"junio";"julio";"agosto";"septiembre";"octubre";"noviembre";"diciembre"

$ locale -k LC_MESSAGES
yesexpr="^[+1yY]"
noexpr="^[-0nN]"
yesstr="yes"
nostr="no"
```

### 7.2 Generar y compilar locales

```
$ grep -c '^[^#]' /etc/locale.gen
2

$ sudo sed -i 's/^# *\(es_ES\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
$ sudo locale-gen
Generating locales (this might take a while)...
  en_US.UTF-8... done
  es_ES.UTF-8... done
Generation complete.
```

Compilación ad hoc sin tocar `/etc/locale.gen` — `localedef -i <source> -f <charmap> <name>`:

```
$ sudo localedef -i pt_BR -f UTF-8 pt_BR.UTF-8
$ locale -a | grep pt_BR
pt_BR.utf8

$ localedef --list-archive | head -5
C.utf8
de_DE.utf8
en_GB.utf8
en_US.utf8
es_ES.utf8
```

En sistemas de la familia RHEL lo mismo es un paquete:

```
$ sudo dnf install -y glibc-langpack-pt
$ localectl list-locales | grep '^pt_BR'
pt_BR.UTF-8
```

### 7.3 Fijar el locale del sistema con systemd

```
$ localectl status
   System Locale: LANG=en_US.UTF-8
       VC Keymap: us
      X11 Layout: us

$ sudo localectl set-locale LANG=C.UTF-8 LC_COLLATE=C LC_NUMERIC=C
$ localectl status
   System Locale: LANG=C.UTF-8
                  LC_COLLATE=C
                  LC_NUMERIC=C
       VC Keymap: us
      X11 Layout: us

$ cat /etc/locale.conf
LANG=C.UTF-8
LC_COLLATE=C
LC_NUMERIC=C
```

El cambio se aplica a los servicios recién arrancados y a las nuevas sesiones de login. Los procesos ya en ejecución conservan el entorno con el que fueron lanzados — el locale se *hereda en el momento del exec*, nunca se vuelve a leer.

### 7.4 Demostrar por qué `LC_ALL=C` pertenece a los scripts

Colación:

```
$ printf 'Banana\napple\nCherry\n' | LC_ALL=C sort
Banana
Cherry
apple

$ printf 'Banana\napple\nCherry\n' | LC_ALL=en_US.UTF-8 sort
apple
Banana
Cherry
```

`C` ordena por valor de byte (`B`=0x42 < `C`=0x43 < `a`=0x61). `en_US.UTF-8` ordena sin distinguir mayúsculas en el nivel primario de colación. Dos órdenes distintos, ambos "correctos", ambos no intercambiables — y solo uno de ellos es estable a través de una actualización de glibc.

Formato numérico:

```
$ LC_ALL=C printf '%.2f\n' 3.14159
3.14

$ LC_ALL=de_DE.UTF-8 printf '%.2f\n' 3.14159
3,14
```

Esa coma va a crear silenciosamente un campo CSV de dos columnas.

Coincidencia de mensajes:

```
$ LC_ALL=C ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory

$ LC_ALL=es_ES.UTF-8 ls /nonexistent
ls: no se puede acceder a '/nonexistent': No existe el fichero o el directorio
```

Cualquier script que haga `2>&1 | grep -q "No such file"` acaba de romperse. **Nunca parsees el texto de stderr; verificá los códigos de salida.** Si tenés que parsear, forzá `LC_ALL=C` primero.

Semántica de los rangos entre corchetes — POSIX define las expresiones de rango en términos de la *secuencia de colación*, no de los code points:

```
$ echo 'B' | LC_ALL=C grep -q '[a-z]' && echo match || echo no-match
no-match

$ echo 'B' | LC_ALL=en_US.UTF-8 grep -q '[a-z]' && echo match || echo no-match
match
```

> El segundo resultado varía según la versión de glibc y la definición del locale — **esa variabilidad es exactamente el problema.** Usá `[[:lower:]]` (una clase de caracteres POSIX, definida por `LC_CTYPE`) o forzá `LC_ALL=C`; nunca confíes en que `[a-z]` signifique 26 letras ASCII salvo que el locale sea `C`.

### 7.5 Operaciones con zonas horarias

```
$ timedatectl list-timezones | grep -i madrid
Europe/Madrid

$ sudo timedatectl set-timezone Europe/Madrid
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug 27 16:11 /etc/localtime -> ../usr/share/zoneinfo/Europe/Madrid

$ cat /etc/timezone
Europe/Madrid
```

Override por proceso — sin root, sin persistencia, la forma correcta de responder "¿qué hora es allá?":

```
$ date
Thu Aug 27 04:11:52 PM CEST 2026

$ TZ=UTC date
Thu Aug 27 02:11:52 PM UTC 2026

$ TZ=Asia/Tokyo date -Is
2026-08-27T23:11:52+09:00

$ TZ=America/Argentina/Buenos_Aires date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)'
2026-08-27 11:11:52 -03 (UTC-0300)
```

`tzselect` es un **asistente interactivo que solo imprime** el valor correcto de `TZ` — no cambia nada:

```
$ tzselect
Please identify a location so that time zone rules can be set correctly.
Please select a continent, ocean, "coord", "TZ", "Etc" or "quit".
 1) Africa
 2) Americas
 3) Antarctica
 4) Asia
 5) Atlantic Ocean
 6) Australia
 7) Europe
 8) Indian Ocean
 9) Pacific Ocean
10) coord - I want to use geographical coordinates.
11) TZ - I want to specify the timezone using the POSIX TZ format.
12) Etc - I want to specify a UTC offset.
13) quit
#? 7
Please select a country whose clocks agree with yours.
...
#? 42
The following information has been given:
        Spain (mainland)
Therefore TZ='Europe/Madrid' will be used.
Selected time is now:   Thu Aug 27 16:11:52 CEST 2026.
Universal Time is now:  Thu Aug 27 14:11:52 UTC 2026.
Is the above information OK?
1) Yes
2) No
#? 1

You can make this change permanent for yourself by appending the line
        TZ='Europe/Madrid'; export TZ
to the file '.profile' in your home directory; then log out and log in again.

Here is that TZ value again, this time on standard output so that you
can use the /usr/bin/tzselect command in shell scripts:
Europe/Madrid
```

Inspeccionar la tabla de transiciones de DST — la manera autoritativa de responder "¿cuándo salta el reloj?":

```
$ zdump -v -c 2026,2027 Europe/Madrid
Europe/Madrid  -9223372036854775808 = NULL
Europe/Madrid  -9223372036854689408 = NULL
Europe/Madrid  Sun Mar 29 00:59:59 2026 UT = Sun Mar 29 01:59:59 2026 CET isdst=0 gmtoff=3600
Europe/Madrid  Sun Mar 29 01:00:00 2026 UT = Sun Mar 29 03:00:00 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 00:59:59 2026 UT = Sun Oct 25 02:59:59 2026 CEST isdst=1 gmtoff=7200
Europe/Madrid  Sun Oct 25 01:00:00 2026 UT = Sun Oct 25 02:00:00 2026 CET isdst=0 gmtoff=3600
Europe/Madrid  9223372036854689407 = NULL
Europe/Madrid  9223372036854775807 = NULL
```

Leé las filas 3–4: la hora local salta de 01:59:59 → 03:00:00. **Las 02:30 no existen el 2026-03-29.** Leé las filas 5–6: la hora local 02:00–02:59 ocurre dos veces el 2026-10-25. Una entrada de cron a las `02:30` se dispara cero veces en marzo y dos veces en octubre. Este es el único comando que convierte una discusión sobre planificación en un hecho.

```
$ date -d '2026-03-29 02:30:00' 2>&1
date: invalid date ‘2026-03-29 02:30:00’
```

glibc se niega a construir la hora local inexistente. Esa negativa es el reporte de bug.

### 7.6 Conversión de juegos de caracteres con `iconv`

```
$ iconv -l | wc -l
1173

$ iconv -l | grep -E '^(ISO-8859-(1|15)|UTF-8|UTF-16|WINDOWS-1252)//$'
ISO-8859-1//
ISO-8859-15//
UTF-8//
UTF-16//
WINDOWS-1252//
```

Conversión directa (`-f` desde, `-t` hacia):

```
$ printf 'a\xf1o 2026\n' > latin1.txt
$ file latin1.txt
latin1.txt: ISO-8859 text

$ iconv -f ISO-8859-1 -t UTF-8 latin1.txt -o utf8.txt
$ file utf8.txt
utf8.txt: Unicode text, UTF-8 text

$ hexdump -C utf8.txt
00000000  61 c3 b1 6f 20 32 30 32  36 0a                    |a..o 2026.|
0000000a
```

Modos de falla y las dos salidas de emergencia:

```
$ printf '10 \u20ac\n' | iconv -f UTF-8 -t ISO-8859-1
10 iconv: cannot convert

$ printf '10 \u20ac\n' | iconv -f UTF-8 -t ISO-8859-1//TRANSLIT
10 EUR

$ printf '10 \u20ac\n' | iconv -f UTF-8 -t ISO-8859-1//IGNORE
10 
iconv: illegal input sequence at position 8

$ printf '10 \u20ac\n' | iconv -f UTF-8 -t ISO-8859-15 | hexdump -C
00000000  31 30 20 a4 0a                                    |10 ..|
00000005
```

`€` es irrepresentable en Latin-1, se translitera a `EUR`, lo descarta `//IGNORE` (que igual devuelve un diagnóstico no del todo limpio), y es el único byte `A4` en Latin-**9**. Esto es precisamente por lo que existe ISO-8859-15.

| Sufijo de `iconv` | Comportamiento ante un carácter irrepresentable | Pérdida de datos | Usar cuando |
|---|---|---|---|
| *(ninguno)* | Aborta con error | Ninguna (falla cerrado) | **Por defecto** — querés enterarte |
| `//TRANSLIT` | Aproxima (`€`→`EUR`, `é`→`e`) | Con pérdida pero legible | Un destino legado que no acepta UTF-8 |
| `//IGNORE` | Descarta el carácter silenciosamente | Pérdida silenciosa | Casi nunca |

Validar que un archivo *es* UTF-8 — el truco del round-trip:

```
$ iconv -f UTF-8 -t UTF-8 utf8.txt >/dev/null && echo "valid UTF-8"
valid UTF-8

$ iconv -f UTF-8 -t UTF-8 latin1.txt >/dev/null || echo "NOT valid UTF-8"
iconv: illegal input sequence at position 1
NOT valid UTF-8
```

Encontrar las líneas ofensivas en un archivo grande:

```
$ grep -axv '.*' mixed.log
2026-08-27T14:03:11Z user=jos<E9> action=login
```

`grep -a -x -v '.*'` imprime las líneas donde `.*` no logra coincidir con la línea entera — lo cual, en un locale UTF-8, solo pasa con secuencias de bytes inválidas.

Renombrar archivos cuyos *nombres* están en la codificación equivocada (`iconv` maneja el contenido; `convmv` maneja los nombres):

```
$ convmv -f ISO-8859-1 -t UTF-8 --notest -r /srv/uploads/
Starting a dry run without changes...
mv "/srv/uploads/informe_a\xf1o.pdf" "/srv/uploads/informe_año.pdf"
Ready!
```

### 7.7 Locale sobre SSH — la falla remota clásica

```
$ ssh appserver01 locale
locale: Cannot set LC_CTYPE to default locale: No such file or directory
locale: Cannot set LC_MESSAGES to default locale: No such file or directory
locale: Cannot set LC_ALL to default locale: No such file or directory
LANG=en_US.UTF-8
LANGUAGE=
LC_CTYPE="en_US.UTF-8"
...
```

El cliente envió las `LC_*` vía `SendEnv`; `sshd` las aceptó vía `AcceptEnv LANG LC_*`; el servidor no tiene compilado `en_US.UTF-8`. La misma causa raíz produce el célebre cartel de Perl durante las corridas de `apt`:

```
perl: warning: Setting locale failed.
perl: warning: Please check that your locale settings:
	LANGUAGE = (unset),
	LC_ALL = (unset),
	LC_CTYPE = "en_US.UTF-8",
	LANG = "en_US.UTF-8"
    are supported and installed on your system.
perl: warning: Falling back to the standard locale ("C").
```

| Arreglo | Dónde | Efecto | Recomendado |
|---|---|---|---|
| Compilar el locale en el servidor | servidor | Respeta la intención del cliente | Sí, si se quiere localización |
| `AcceptEnv` acotado / eliminado | `/etc/ssh/sshd_config` | El locale del servidor siempre gana | **Sí para servidores de flota** |
| `SendEnv -LC_*` | `~/.ssh/config` del cliente | Detiene la fuga en el origen | Sí |
| `ssh -o SendEnv=` puntual | cliente | Ad hoc | Depuración |

```
# ~/.ssh/config on the operator workstation
Host *.prod.example.com
    SendEnv -LC_*
    SendEnv -LANG
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 La escalera de verificación

Ejecutá estos pasos en orden; cada peldaño es barato y cada uno responde una pregunta distinta.

```bash
#!/usr/bin/env bash
# /usr/local/bin/verify-locale — platform locale/time conformance probe.
# Exit 0 = conformant. Non-zero = drift, with the reason on stderr.
set -uo pipefail
export LC_ALL=C

EXPECTED_LANG="${EXPECTED_LANG:-C.UTF-8}"
EXPECTED_TZ="${EXPECTED_TZ:-Etc/UTC}"
rc=0
fail() { printf 'FAIL: %s\n' "$*" >&2; rc=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

# 1. Does the configured locale actually resolve?
if locale 2>&1 >/dev/null | grep -q 'Cannot set'; then
    fail "configured locale does not resolve; glibc has fallen back to C"
else
    ok "locale resolves"
fi

# 2. Is the character map UTF-8?
cm=$(locale charmap)
[ "$cm" = "UTF-8" ] || fail "charmap is $cm, expected UTF-8"
[ "$cm" = "UTF-8" ] && ok "charmap=UTF-8"

# 3. Is collation deterministic (byte order)?
order=$(printf 'Banana\napple\n' | sort | head -1)
[ "$order" = "Banana" ] || fail "LC_COLLATE is not byte-ordered (got '$order' first)"
[ "$order" = "Banana" ] && ok "collation is byte-ordered"

# 4. Is the decimal separator a period?
dp=$(printf '%.1f' 1.5)
[ "$dp" = "1.5" ] || fail "LC_NUMERIC decimal point is not '.' (printf gave '$dp')"
[ "$dp" = "1.5" ] && ok "decimal point='.'"

# 5. Is the timezone what we declared?
if command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value)
else
    tz=$(readlink -f /etc/localtime | sed 's#.*/zoneinfo/##')
fi
[ "$tz" = "$EXPECTED_TZ" ] || fail "timezone is $tz, expected $EXPECTED_TZ"
[ "$tz" = "$EXPECTED_TZ" ] && ok "timezone=$tz"

# 6. Is the RTC in UTC?
if command -v timedatectl >/dev/null 2>&1; then
    if [ "$(timedatectl show -p LocalRTC --value)" = "yes" ]; then
        fail "RTC is in local time; DST transitions become ambiguous at boot"
    else
        ok "RTC in UTC"
    fi
fi

# 7. Is tzdata present and recent enough to have current DST rules?
if [ -d /usr/share/zoneinfo ]; then
    ok "zoneinfo present ($(find /usr/share/zoneinfo -name '*' -type f | wc -l) files)"
else
    fail "/usr/share/zoneinfo missing: TZ will be silently ignored"
fi

exit "$rc"
```

```
$ EXPECTED_TZ=Etc/UTC verify-locale
ok:   locale resolves
ok:   charmap=UTF-8
ok:   collation is byte-ordered
ok:   decimal point='.'
ok:   timezone=Etc/UTC
ok:   RTC in UTC
ok:   zoneinfo present (1789 files)

$ echo $?
0
```

### 8.2 Síntoma → causa → comando

| Síntoma | Causa más probable | Comando de diagnóstico |
|---|---|---|
| `Cannot set LC_CTYPE to default locale` | Locale referenciado pero no compilado | `locale -a \| grep -i <name>` y luego `locale-gen` / `localedef` |
| La salida de `sort` cambió tras actualizar el SO | Cambio de colación en glibc ≥2.28 | `ldd --version`; fijar con `LC_ALL=C` |
| Una consulta a la BD no encuentra filas existentes tras la actualización | Índice construido con la colación anterior | `SELECT collversion FROM pg_collation`; `REINDEX DATABASE` |
| El CSV tiene `3,14` en vez de `3.14` | `LC_NUMERIC` heredado del operador | `locale \| grep NUMERIC`; exportar `LC_NUMERIC=C` |
| El `grep "No such file"` del script dejó de coincidir | `LC_MESSAGES` traducido | `LC_ALL=C <cmd>`; dejar de parsear stderr |
| Los caracteres acentuados aparecen como `Ã±` | UTF-8 correcto renderizado como Latin-1 | Codificación de la terminal, no de los datos — revisá el emulador |
| Los caracteres acentuados aparecen como `?` / `<E9>` | Bytes Latin-1 decodificados como UTF-8 | `file -i f`; `iconv -f UTF-8 -t UTF-8 f >/dev/null` |
| Los emoji/CJK desalinean las columnas | `LC_CTYPE` no es UTF-8, wcwidth incorrecto | `locale charmap`; debe ser `UTF-8` |
| Los logs del contenedor están en UTC pese a `TZ=` | Falta `tzdata` en la imagen | `ls /usr/share/zoneinfo` dentro del contenedor |
| `date` bien en la shell, mal en el servicio | El servicio no lee `~/.bashrc` | `systemctl show -p Environment <unit>` |
| El CronJob se dispara a la hora equivocada | `.spec.timeZone` sin definir → TZ del controlador | `kubectl get cronjob X -o jsonpath='{.spec.timeZone}'` |
| Un job se saltea o se duplica una vez al año | Transición de DST | `zdump -v -c YYYY,YYYY+1 <Zone>` |
| El reloj salta exactamente el desfase UTC en el arranque | RTC en hora local | `timedatectl \| grep 'RTC in local TZ'` |
| El orden de `ls` difiere entre dos hosts "idénticos" | Distinto `LC_COLLATE` | `ssh h1 locale; ssh h2 locale` |

### 8.3 Reproducir una falla sin tocar el host

Todo bug de locale se reproduce con una sola línea, porque el locale tiene alcance de proceso:

```
$ LC_ALL=de_DE.UTF-8 ./generate-report.sh | head -3
metric,value
requests_total,1.234.567
latency_p99_seconds,0,412

$ LC_ALL=C ./generate-report.sh | head -3
metric,value
requests_total,1234567
latency_p99_seconds,0.412
```

Dos corridas, sin cambios de configuración, causa raíz demostrada. Agregá exactamente esto como control de CI:

```yaml
# .gitlab-ci.yml (or equivalent) — locale-hostility test
locale-hostility:
  stage: test
  image: registry.example.com/ci/debian-locales:12
  parallel:
    matrix:
      - PROBE_LOCALE: ["C", "C.UTF-8", "en_US.UTF-8", "de_DE.UTF-8", "tr_TR.UTF-8"]
  script:
    # tr_TR is the adversarial case: dotless i. toupper('i') == 'İ' (U+0130),
    # so any case-insensitive comparison in the codebase breaks here and nowhere else.
    - export LC_ALL="$PROBE_LOCALE"
    - ./generate-report.sh > "out.$PROBE_LOCALE.csv"
    - diff <(LC_ALL=C ./generate-report.sh) "out.$PROBE_LOCALE.csv"
  artifacts:
    when: on_failure
    paths: ["out.*.csv"]
```

> **La prueba de la i turca es la sonda individual de mayor valor de todo este objetivo.** En `tr_TR.UTF-8`, `toupper('i')` es `İ` y `tolower('I')` es `ı`. El código que hace `if [ "${x,,}" = "yes" ]`, `grep -i`, o una comparación de nombres de host sin distinguir mayúsculas produce una respuesta distinta en Turquía que en cualquier otro lugar del planeta. Correr tu suite de tests una vez bajo `LC_ALL=tr_TR.UTF-8` encuentra el manejo de mayúsculas dependiente del locale que ningún otro locale expone.

### 8.4 Auditoría de colación posterior a una actualización

```
$ ldd --version | head -1
ldd (Debian GLIBC 2.36-9+deb12u7) 2.36
```

```sql
-- PostgreSQL: which collations no longer match the OS provider's version?
SELECT datname, datcollate, datctype, datcollversion
FROM pg_database;

-- After a glibc major upgrade, this is mandatory for any glibc-provider collation:
REINDEX DATABASE billing;
ALTER DATABASE billing REFRESH COLLATION VERSION;
```

El arreglo duradero es dejar de depender de glibc para el orden: creá la base de datos con `--locale-provider=icu` (ICU versiona su colación explícitamente) o con `LC_COLLATE=C` y aplicá el orden de presentación con una cláusula `COLLATE` explícita en la consulta.

---

## 9. Referencia rápida para el examen

| Pregunta | Respuesta |
|---|---|
| ¿Qué variable sobrescribe a todas las demás? | `LC_ALL` |
| ¿Qué variable es el valor por defecto de respaldo? | `LANG` |
| ¿Cuál afecta solo a los mensajes traducidos, con una lista de respaldo? | `LANGUAGE` |
| ¿Qué comando lista los locales disponibles? | `locale -a` |
| ¿Cuál lista los charmaps disponibles? | `locale -m` |
| ¿Cuál compila un locale a partir de la fuente + charmap? | `localedef -i <src> -f <charmap> <name>` |
| ¿Qué archivo lista los locales a generar en Debian? | `/etc/locale.gen` (y luego `locale-gen`) |
| ¿Qué archivo guarda el locale del sistema en systemd? | `/etc/locale.conf` |
| ¿Dónde está la base de datos de zonas horarias? | `/usr/share/zoneinfo/` |
| ¿Qué es `/etc/localtime`? | Enlace simbólico (o copia) del archivo TZif activo |
| ¿Qué es `/etc/timezone`? | Archivo de texto de Debian que nombra la zona; libc no lo lee |
| ¿Qué comando solo *imprime* un valor de `TZ`? | `tzselect` |
| ¿Qué comando fija la zona horaria del sistema? | `timedatectl set-timezone <Zone>` |
| ¿Cuál convierte el contenido de un archivo entre juegos de caracteres? | `iconv -f <from> -t <to>` |
| ¿Cuántos bytes por carácter tiene UTF-8? | De 1 a 4 |
| ¿UTF-8 es compatible con ASCII? | Sí |
| ¿UTF-16 es compatible con ASCII? | No |
| ¿Qué codificación de ancho fijo cubre solo el BMP? | UCS-2 (obsoleta) |
| ¿Qué variante de ISO-8859 agrega el símbolo del euro? | ISO-8859-15 (Latin-9) |
| ¿Cuántos caracteres tiene ASCII? | 128 (7 bits) |

---

## 10. Referencias

**LPI — objetivos oficiales**
- LPIC-1 Exam 101 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102 objectives (contiene 107.3) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**glibc / locale**
- GNU C Library Manual — Locales and Internationalization — https://www.gnu.org/software/libc/manual/html_node/Locales.html
- GNU C Library Manual — Locale Categories — https://www.gnu.org/software/libc/manual/html_node/Locale-Categories.html
- GNU C Library Manual — Locale Names — https://www.gnu.org/software/libc/manual/html_node/Locale-Names.html
- `locale(1)` — https://man7.org/linux/man-pages/man1/locale.1.html
- `locale(5)` — https://man7.org/linux/man-pages/man5/locale.5.html
- `locale(7)` — https://man7.org/linux/man-pages/man7/locale.7.html
- `localedef(1)` — https://man7.org/linux/man-pages/man1/localedef.1.html
- `locale.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/locale.conf.html
- `charsets(7)` — https://man7.org/linux/man-pages/man7/charsets.7.html

**POSIX**
- POSIX.1-2018 — Environment Variables (precedencia de locale) — https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html
- POSIX.1-2018 — Locale definition — https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap07.html

**Hora y zonas horarias**
- IANA Time Zone Database — https://www.iana.org/time-zones
- `tzset(3)` — https://man7.org/linux/man-pages/man3/tzset.3.html
- `tzfile(5)` (formato TZif) — https://man7.org/linux/man-pages/man5/tzfile.5.html
- `tzselect(8)` — https://man7.org/linux/man-pages/man8/tzselect.8.html
- `zdump(8)` — https://man7.org/linux/man-pages/man8/zdump.8.html
- `localtime(5)` — https://www.freedesktop.org/software/systemd/man/latest/localtime.html
- `timedatectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `hwclock(8)` — https://man7.org/linux/man-pages/man8/hwclock.8.html

**Codificaciones de caracteres**
- The Unicode Consortium — https://home.unicode.org/
- Unicode Standard, Chapter 2 (General Structure) — https://www.unicode.org/versions/latest/ch02.pdf
- RFC 3629 — UTF-8, a transformation format of ISO 10646 — https://www.rfc-editor.org/rfc/rfc3629
- RFC 2781 — UTF-16, an encoding of ISO 10646 — https://www.rfc-editor.org/rfc/rfc2781
- ISO/IEC 8859-1:1998 — https://www.iso.org/standard/28245.html
- ISO/IEC 8859-15:1999 — https://www.iso.org/standard/29505.html
- `iconv(1)` — https://man7.org/linux/man-pages/man1/iconv.1.html
- GNU libiconv — https://www.gnu.org/software/libiconv/
- UTF-8 and Unicode FAQ for Unix/Linux (Markus Kuhn) — https://www.cl.cam.ac.uk/~mgk25/unicode.html

**systemd**
- `localectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/localectl.html
- `systemd.exec(5)` — Environment — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.time(7)` — eventos de calendario y manejo de zonas horarias — https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html

**Documentación de las distribuciones**
- Debian Wiki — Locale — https://wiki.debian.org/Locale
- Ubuntu Server — Locale configuration — https://documentation.ubuntu.com/server/explanation/intro/locale/
- Red Hat Enterprise Linux 9 — Configuring the date and time — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/assembly_configuring-the-date-and-time_configuring-basic-system-settings
- Arch Wiki — Locale — https://wiki.archlinux.org/title/Locale
- Alpine Linux Wiki — Locale — https://wiki.alpinelinux.org/wiki/Alpine_Linux:FAQ#Is_there_a_way_to_use_locales.3F
- musl libc — Functional differences from glibc — https://wiki.musl-libc.org/functional-differences-from-glibc.html

**Impacto en producción**
- PostgreSQL — Collation support and version mismatches — https://www.postgresql.org/docs/current/collation.html
- Kubernetes — CronJob `.spec.timeZone` — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes API reference — CronJobSpec — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/cron-job-v1/
- Go standard library — `time/tzdata` (base de datos de zonas horarias embebida) — https://pkg.go.dev/time/tzdata