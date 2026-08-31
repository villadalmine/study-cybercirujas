# 107.3 — Localisation and Internationalisation

**Certification:** LPIC-1 (101-500 / 102-500, v5.0) · **Objective 107.3** lives in exam **102-500** · **Weight: 3**

> **i18n** (internationalisation) is the engineering property of software that *can* adapt to a locale without recompilation. **l10n** (localisation) is the runtime data — charmaps, collation tables, message catalogues, timezone rules — that makes it actually adapt. On Linux, i18n is a glibc/musl API surface; l10n is a set of files on disk plus a handful of environment variables. This objective is about the second one, and about the fact that *those variables are process state, not machine state*.

**Key files, terms and utilities (LPI objective list):** `/etc/timezone`, `/etc/localtime`, `/usr/share/zoneinfo/`, `LC_*`, `LC_ALL`, `LANG`, `TZ`, `/usr/bin/locale`, `tzselect`, `timedatectl`, `date`, `iconv`, UTF-8, ISO-8859, ASCII, Unicode.

---

## 1. The production problem

Locale is the most under-specified piece of a Linux runtime environment, and the only one that silently changes the *semantics* of standard tools rather than failing loudly. Four real failure classes justify treating it as configuration-under-version-control:

**1.1 — Collation drift breaks data, not just display.**
`sort`, `[a-z]` bracket expressions, `ls` ordering, and database B-tree indexes are all defined by `LC_COLLATE`. glibc 2.28 (RHEL 8, Debian 10, Ubuntu 18.10) replaced its collation data with the ISO 14651 tables. Every PostgreSQL index built on a text column under `en_US.UTF-8` on a pre-2.28 host became *logically corrupt* after the upgrade — the index claims an ordering the comparison function no longer agrees with, so `WHERE name = 'x'` can return zero rows for a row that exists. The fix is `REINDEX`, and the detection is a version comparison, not a health check.

**1.2 — Numeric formatting corrupts machine-readable output.**
`LC_NUMERIC=de_DE.UTF-8` makes `printf '%.2f' 3.14` emit `3,14`. Any pipeline that generates a CSV, a Prometheus exposition line, or a JSON fragment with shell `printf` and inherits an operator's desktop locale over SSH produces syntactically valid garbage that the consumer accepts and misinterprets.

**1.3 — Character-set assumptions are a data-integrity boundary.**
A filename written by a process under `ISO-8859-1` and read by a process under `UTF-8` is not "displayed wrong" — it is an unrepresentable byte sequence. Backups, `rsync --delete`, object-store sync tools and Git all behave differently on invalid UTF-8. Mojibake in logs is cosmetic; mojibake in filenames is a restore that fails at 3 a.m.

**1.4 — Timezone is a scheduling correctness property.**
A cron entry at `02:30` in `Europe/Madrid` runs **twice** on the March DST fall-back day in the southern-hemisphere equivalent and **not at all** on the spring-forward day. A container without `tzdata` silently ignores `TZ` and runs in UTC. A Kubernetes `CronJob` without `.spec.timeZone` is evaluated in the *controller manager's* zone, not the pod's.

The architectural rule that follows: **the platform runs in `C.UTF-8` and UTC; localisation is a presentation-layer decision applied at the edge, never inherited.** Everything below is how you enforce and verify that.

---

## 2. Locale architecture in glibc

### 2.1 The categories

A locale is not one setting. It is a set of independent categories, each backed by a table in the locale definition. Every category is separately overridable.

| Category | Governs | Concretely breaks when wrong |
|---|---|---|
| `LC_CTYPE` | Character classification, case mapping, multibyte encoding | `tr`, `toupper()`, `grep -i`, terminal width of CJK/emoji, `wc -m` |
| `LC_COLLATE` | String comparison and sort order | `sort`, `ls`, `[a-z]` ranges, DB indexes, `join`, `comm` |
| `LC_NUMERIC` | Decimal point, thousands grouping | `printf '%f'`, `sort -n`, `awk` output, CSV/JSON generation |
| `LC_TIME` | Date/time field order, month & day names, 12/24 h | `date`, `ls -l`, log parsers keyed on `%b` month abbreviations |
| `LC_MONETARY` | Currency symbol, sign placement, fraction digits | Reports, invoices, `strfmon()` |
| `LC_MESSAGES` | Message catalogue selection, yes/no expressions | Every tool's stderr → breaks `grep`-based error matching in scripts |
| `LC_PAPER` | Default paper size (A4 vs Letter) | CUPS, `groff`, PDF pipelines |
| `LC_NAME`, `LC_ADDRESS`, `LC_TELEPHONE` | Personal-name, postal, phone formats | Application-level formatting |
| `LC_MEASUREMENT` | Metric vs imperial | `units`-aware tooling |
| `LC_IDENTIFICATION` | Metadata about the locale definition itself | Introspection only |

### 2.2 Resolution precedence — the only ordering worth memorising

```
LC_ALL   →  overrides every category, unconditionally
LC_xxx   →  overrides LANG for that one category
LANG     →  default for every category not otherwise set
(builtin)→  "C" / "POSIX" if nothing is set at all
```

`LANGUAGE` is a **GNU gettext extension** and sits outside this chain: it takes a colon-separated fallback list (`LANGUAGE=ca:es:en`) and affects **only** message translation, and **only** when `LC_MESSAGES` is not `C`/`POSIX`.

| Variable | Scope | Overrides | Typical legitimate use |
|---|---|---|---|
| `LC_ALL` | All categories | Everything | **Scripts.** `export LC_ALL=C` at the top of any script whose output is parsed |
| `LANG` | All categories (as default) | Built-in default | System/user default in `/etc/locale.conf` |
| `LC_COLLATE` | One category | `LANG` | Pin sort order to `C` while keeping UTF-8 `LC_CTYPE` |
| `LANGUAGE` | Message catalogues only | `LC_MESSAGES` for translation lookup | Multi-language fallback chains on desktops |

**The determinism idiom.** For any script whose stdout is consumed by another program:

```bash
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C.UTF-8   # deterministic collation + numeric, still 8-bit clean
export TZ=UTC
```

Use `LC_ALL=C` (not `C.UTF-8`) only when you additionally want byte-oriented `LC_CTYPE` — e.g. `grep`/`sed` over binary-ish data, where UTF-8 validation would otherwise make `grep` skip lines.

### 2.3 Where locale data physically lives

| Artefact | Path | Role |
|---|---|---|
| Locale source definitions | `/usr/share/i18n/locales/` | Human-readable category rules (`en_US`, `es_ES`, `i18n`, `iso14651_t1`) |
| Charmaps | `/usr/share/i18n/charmaps/` | Symbolic-name → byte-sequence mapping (`UTF-8.gz`, `ISO-8859-15.gz`) |
| Compiled locale archive | `/usr/lib/locale/locale-archive` | mmap-able binary blob of all compiled locales (glibc) |
| Compiled per-locale dirs | `/usr/lib/locale/<locale>/` | Alternative to the archive (`localedef --no-archive`) |
| Message catalogues | `/usr/share/locale/<lang>/LC_MESSAGES/*.mo` | gettext translations |
| Generation list (Debian) | `/etc/locale.gen` | Which `locale`+`charmap` pairs `locale-gen` compiles |
| System default (systemd) | `/etc/locale.conf` | Read by PID 1; exported to all services |
| System default (Debian legacy) | `/etc/default/locale` | Read by PAM (`pam_env`) for login sessions |

`localedef` is the compiler: it consumes a locale source plus a charmap and emits the binary form.

### 2.4 glibc vs musl — the container-image trap

| Property | glibc (Debian, Ubuntu, RHEL) | musl (Alpine) |
|---|---|---|
| Locales supported | Full set, compiled on demand | `C` / `C.UTF-8` only (plus `*.UTF-8` aliases treated as UTF-8) |
| `LC_CTYPE` behaviour | Per-locale charmap | Always UTF-8 |
| `LC_COLLATE` | Full ISO 14651 collation | Byte order only (equivalent to `C`) |
| `LC_MESSAGES` | gettext catalogues | Stub unless `musl-locales` is installed |
| `locale -a` output | Long list | `C`, `C.UTF-8`, `POSIX` |
| Practical consequence | Sort order is a version-coupled behaviour | Sort order is stable forever, but no localisation |

**Alpine's constraint is an SRE feature, not a bug**: on musl you cannot accidentally inherit locale-dependent collation. If your platform standard is `C.UTF-8`, Alpine enforces it for free.

---

## 3. Character encodings

### 3.1 Comparison

| Encoding | Bytes/char | Repertoire | ASCII-compatible | Self-synchronising | Endianness | Status |
|---|---|---|---|---|---|---|
| **ASCII (US-ASCII)** | 1 (7 bits used) | 128 code points | — (is ASCII) | yes | n/a | Substrate of everything |
| **ISO-8859-1** (Latin-1) | 1 | 256 (Western Europe) | yes | yes | n/a | Legacy; no `€` |
| **ISO-8859-15** (Latin-9) | 1 | 256; adds `€ Š š Ž ž Œ œ Ÿ` | yes | yes | n/a | Legacy Latin-1 successor |
| **ISO-8859-2/5/7/9** | 1 | Central Europe / Cyrillic / Greek / Turkish | yes | yes | n/a | Legacy |
| **UTF-8** | 1–4 | Full Unicode (U+0000–U+10FFFF) | **yes** | **yes** | none | **Default. Only correct choice.** |
| **UTF-16** | 2 or 4 (surrogate pairs) | Full Unicode | no | partly | LE/BE + BOM | Windows/Java internals, JS strings |
| **UCS-2** | 2 (fixed) | BMP only (U+0000–U+FFFF) | no | yes | LE/BE + BOM | **Obsolete** — cannot encode emoji, CJK ext. |
| **UTF-32 / UCS-4** | 4 (fixed) | Full Unicode | no | yes | LE/BE + BOM | Internal `wchar_t` on Linux; wasteful on the wire |

**Why UTF-8 wins on a Unix system**, in the three properties that matter operationally:

1. **ASCII transparency** — a byte `< 0x80` is always that ASCII character and never part of a multibyte sequence. `/`, `\0`, `\n` keep their meaning, so kernel path handling, `read()`-based line splitting and every C string function keep working unmodified.
2. **Self-synchronisation** — lead bytes are `0xxxxxxx` or `11xxxxxx`; continuation bytes are always `10xxxxxx`. You can seek to a random offset in a log file and find the next character boundary in ≤3 bytes. UTF-16 cannot do this.
3. **No BOM, no endianness** — byte order is fixed by the encoding, so there is nothing to negotiate between architectures.

### 3.2 UTF-8 encoding mechanics

| Code point range | Bytes | Bit pattern |
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

`ñ` = U+00F1 → `C3 B1` (2 bytes). `€` = U+20AC → `E2 82 AC` (3 bytes). Note that `LANG` did not change the file — the *bytes* are the encoding; the locale only tells programs how to interpret them.

### 3.3 Mojibake, decoded

The same `ñ` written as ISO-8859-1 is the single byte `F1`. Round-tripping it wrongly is deterministic and therefore diagnosable:

```
$ printf 'a\xf1o\n' | hexdump -C
00000000  61 f1 6f 0a                                       |a.o.|
00000004

$ printf 'a\xf1o\n' | iconv -f UTF-8 -t UTF-8
a
iconv: illegal input sequence at position 1
```

| Symptom on screen | What actually happened |
|---|---|
| `aÃ±o` | UTF-8 bytes (`C3 B1`) rendered as Latin-1 — **display** is wrong, data is fine |
| `a?o` / `a\xf1o` / `a<?>o` | Latin-1 byte `F1` fed to a UTF-8 decoder — **data** is wrong for that consumer |
| `aÃ¯Â¿Â½o` | Double encoding: already-UTF-8 text run through `iconv -f latin1 -t utf8` again |
| `a□o` (box) | Correct UTF-8, but the **font** lacks the glyph — neither data nor locale is wrong |

The last row is why "check the terminal before checking the pipeline" belongs in the runbook.

---

## 4. Time and time zones

### 4.1 The three-layer model

```
 hardware RTC  ──►  kernel CLOCK_REALTIME (always UTC internally)  ──►  userspace rendering
 (UTC or local)      seconds since 1970-01-01T00:00:00Z                  via TZ / /etc/localtime
```

The kernel keeps UTC. **Timezone is applied by libc, per process, at format time** (`tzset(3)` → `localtime(3)`). Nothing in the kernel is "in Europe/Madrid".

### 4.2 Mechanisms

| Mechanism | Path / form | Scope | Precedence | Notes |
|---|---|---|---|---|
| `TZ` env var | `TZ=Europe/Madrid` | Single process + children | **Highest** | Preferred form: IANA name |
| `TZ` as explicit path | `TZ=:/usr/share/zoneinfo/Asia/Tokyo` | Process | Highest | Leading `:` = "this is a file path" |
| `TZ` POSIX rule string | `TZ=CET-1CEST,M3.5.0/2,M10.5.0/3` | Process | Highest | No historical data; DST rules hard-coded → **avoid** |
| `/etc/localtime` | Symlink → `/usr/share/zoneinfo/<Area>/<City>` | System-wide default | Used when `TZ` unset | Canonical on systemd; may also be a copy of the file |
| `/etc/timezone` | Plain text, one line: `Europe/Madrid` | Debian/Ubuntu bookkeeping | Informational | Read by `tzdata` postinst & some tools; **not** by libc |
| `/usr/share/zoneinfo/` | TZif binary database (IANA tzdata) | Data source | — | `Etc/UTC`, `Etc/GMT+5` (sign is inverted, POSIX-style) |
| `timedatectl set-timezone` | systemd API | Rewrites `/etc/localtime` | — | The correct write path on systemd hosts |
| CronJob `.spec.timeZone` | Kubernetes ≥1.27 (stable) | Schedule evaluation | — | Independent of the pod's `TZ` |

**Precedence in one sentence:** `TZ` (if set and valid) wins; otherwise libc reads `/etc/localtime`; if that is missing, everything is UTC.

### 4.3 RTC in UTC vs local time

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

`RTC in local TZ: no` is the only correct answer on a server. Setting it to `yes` (`timedatectl set-local-rtc 1`, needed for some Windows dual-boot desktops) makes the DST transition ambiguous at boot and is explicitly warned against by systemd.

### 4.4 tzdata is a moving dependency

Governments change DST rules with weeks of notice. `tzdata` releases (e.g. `2026a`) ship those changes. A long-lived container image pins the tzdata it was built with; a pod started from a two-year-old image will compute the *wrong local time* after a rule change even though the node is correct. **Treat `tzdata` as a security-class dependency in image rebuild policy.**

---

## 5. Distribution configuration matrix

| Task | Debian / Ubuntu | RHEL / Fedora / Rocky | systemd-generic | Alpine |
|---|---|---|---|---|
| List available locales | `locale -a` | `locale -a` | `localectl list-locales` | `locale -a` (3 entries) |
| Make a locale available | Edit `/etc/locale.gen`, run `locale-gen` | `dnf install glibc-langpack-es` | — | n/a |
| Compile one ad-hoc | `localedef -i es_ES -f UTF-8 es_ES.UTF-8` | same | same | unsupported |
| System default file | `/etc/default/locale` **and** `/etc/locale.conf` | `/etc/locale.conf` | `/etc/locale.conf` | `/etc/profile.d/locale.sh` |
| Set system default | `update-locale LANG=en_US.UTF-8` | `localectl set-locale LANG=en_US.UTF-8` | `localectl set-locale …` | edit profile script |
| Timezone package | `tzdata` | `tzdata` | `tzdata` | `apk add tzdata` |
| Set timezone | `timedatectl set-timezone …` (or `dpkg-reconfigure tzdata`) | `timedatectl set-timezone …` | `timedatectl set-timezone …` | `cp /usr/share/zoneinfo/X /etc/localtime` |
| Console keymap | `/etc/default/keyboard` | `localectl set-keymap` | `localectl set-keymap` | `setup-keymap` |

**Where each file is actually read** — this is the part that produces "I set it and it didn't apply":

| File | Read by | Applies to |
|---|---|---|
| `/etc/locale.conf` | systemd PID 1 | **All services** started by systemd, and login sessions via `pam_systemd` |
| `/etc/default/locale` | `pam_env` (Debian) | Interactive logins (SSH, console, `su -`) |
| `/etc/environment` | `pam_env` | Interactive logins only — **not** services |
| `~/.bashrc`, `/etc/profile.d/*.sh` | bash | Interactive shells only — **never** services, **never** `sh -c` from cron |
| `Environment=` in a unit | systemd | That one service |

A `systemd` service does **not** see your `~/.bashrc` locale. That is the single most common "works in my shell, breaks in prod" locale bug.

---

## 6. Infrastructure manifests

### 6.1 Baseline OS configuration (Ansible role, complete)

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

### 6.2 systemd unit and drop-in

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

### 6.3 Container images

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

> **Distroless / `FROM scratch` warning.** These images have no `/usr/share/zoneinfo`. Setting `TZ=Europe/Madrid` is a no-op and the process runs in UTC. Either copy the zoneinfo tree in from a builder stage, or — for Go binaries — `import _ "time/tzdata"` to embed the database in the executable.

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

| Timezone strategy in containers | Portability | Node coupling | Works on distroless | Verdict |
|---|---|---|---|---|
| `TZ` env + `tzdata` in image | High | None | No (no zoneinfo) | **Preferred** |
| `hostPath` mount of `/etc/localtime` | Low | Total | No | Legacy only |
| ConfigMap containing a TZif file | Medium | None | Yes | Acceptable for distroless |
| Embedded tzdata (Go `time/tzdata`) | High | None | Yes | Best for scratch images |
| Do nothing, run UTC, format at the edge | Highest | None | Yes | **Correct default** |

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

## 7. CLI reference — real commands, real output

### 7.1 Inspecting the current locale

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

> **Read the quotes.** A value in `"double quotes"` is *derived* from `LANG`. An unquoted value was set explicitly in the environment. This distinction tells you, in one glance, which variable to change.

```
$ export LC_TIME=es_ES.UTF-8
$ locale | grep -E '^(LANG|LC_TIME|LC_COLLATE)='
LANG=en_US.UTF-8
LC_COLLATE="en_US.UTF-8"
LC_TIME=es_ES.UTF-8
```

`LC_TIME` is now unquoted — it is an explicit override.

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

Querying individual keywords — useful when writing a parser and you need to know what the *target* locale will produce:

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

### 7.2 Generating and compiling locales

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

Ad-hoc compilation without touching `/etc/locale.gen` — `localedef -i <source> -f <charmap> <name>`:

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

On RHEL-family systems the same thing is a package:

```
$ sudo dnf install -y glibc-langpack-pt
$ localectl list-locales | grep '^pt_BR'
pt_BR.UTF-8
```

### 7.3 Setting the system locale with systemd

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

The change applies to newly started services and new login sessions. Already-running processes keep the environment they were launched with — locale is *inherited at exec time*, never re-read.

### 7.4 Demonstrating why `LC_ALL=C` belongs in scripts

Collation:

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

`C` sorts by byte value (`B`=0x42 < `C`=0x43 < `a`=0x61). `en_US.UTF-8` sorts case-insensitively at the primary collation level. Two different, both "correct", both non-interchangeable orderings — and only one of them is stable across a glibc upgrade.

Numeric formatting:

```
$ LC_ALL=C printf '%.2f\n' 3.14159
3.14

$ LC_ALL=de_DE.UTF-8 printf '%.2f\n' 3.14159
3,14
```

That comma will silently create a two-column CSV field.

Message matching:

```
$ LC_ALL=C ls /nonexistent
ls: cannot access '/nonexistent': No such file or directory

$ LC_ALL=es_ES.UTF-8 ls /nonexistent
ls: no se puede acceder a '/nonexistent': No existe el fichero o el directorio
```

Any script doing `2>&1 | grep -q "No such file"` is now broken. **Never parse stderr text; check exit codes.** If you must parse, force `LC_ALL=C` first.

Bracket-range semantics — POSIX defines range expressions in terms of the *collating sequence*, not code points:

```
$ echo 'B' | LC_ALL=C grep -q '[a-z]' && echo match || echo no-match
no-match

$ echo 'B' | LC_ALL=en_US.UTF-8 grep -q '[a-z]' && echo match || echo no-match
match
```

> The second result varies by glibc version and locale definition — **that variance is exactly the problem.** Use `[[:lower:]]` (a POSIX character class, defined by `LC_CTYPE`) or force `LC_ALL=C`; never rely on `[a-z]` meaning 26 ASCII letters unless the locale is `C`.

### 7.5 Timezone operations

```
$ timedatectl list-timezones | grep -i madrid
Europe/Madrid

$ sudo timedatectl set-timezone Europe/Madrid
$ ls -l /etc/localtime
lrwxrwxrwx 1 root root 33 Aug 27 16:11 /etc/localtime -> ../usr/share/zoneinfo/Europe/Madrid

$ cat /etc/timezone
Europe/Madrid
```

Per-process override — no root, no persistence, the correct way to answer "what time is it there?":

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

`tzselect` is an **interactive helper that only prints** the correct `TZ` value — it changes nothing:

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

Inspecting the DST transition table — the authoritative way to answer "when does the clock jump?":

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

Read row 3–4: local time jumps 01:59:59 → 03:00:00. **02:30 does not exist on 2026-03-29.** Read row 5–6: local 02:00–02:59 occurs twice on 2026-10-25. A `02:30` cron entry fires zero times in March and twice in October. This is the single command that turns a scheduling argument into a fact.

```
$ date -d '2026-03-29 02:30:00' 2>&1
date: invalid date ‘2026-03-29 02:30:00’
```

glibc refuses to construct the nonexistent local time. That refusal is the bug report.

### 7.6 Character-set conversion with `iconv`

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

Straight conversion (`-f` from, `-t` to):

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

Failure modes and the two escape hatches:

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

`€` is unrepresentable in Latin-1, transliterates to `EUR`, is dropped by `//IGNORE` (which still returns a non-zero-ish diagnostic), and is a single byte `A4` in Latin-**9**. This is precisely why ISO-8859-15 exists.

| `iconv` suffix | Behaviour on unrepresentable char | Data loss | Use when |
|---|---|---|---|
| *(none)* | Abort with error | None (fails closed) | **Default** — you want to know |
| `//TRANSLIT` | Approximate (`€`→`EUR`, `é`→`e`) | Lossy but readable | Legacy sink that cannot take UTF-8 |
| `//IGNORE` | Silently drop the character | Silent loss | Almost never |

Validating a file *is* UTF-8 — the round-trip trick:

```
$ iconv -f UTF-8 -t UTF-8 utf8.txt >/dev/null && echo "valid UTF-8"
valid UTF-8

$ iconv -f UTF-8 -t UTF-8 latin1.txt >/dev/null || echo "NOT valid UTF-8"
iconv: illegal input sequence at position 1
NOT valid UTF-8
```

Finding the offending lines in a large file:

```
$ grep -axv '.*' mixed.log
2026-08-27T14:03:11Z user=jos<E9> action=login
```

`grep -a -x -v '.*'` prints lines where `.*` fails to match the whole line — which, in a UTF-8 locale, only happens on invalid byte sequences.

Renaming files whose *names* are in the wrong encoding (`iconv` handles content; `convmv` handles names):

```
$ convmv -f ISO-8859-1 -t UTF-8 --notest -r /srv/uploads/
Starting a dry run without changes...
mv "/srv/uploads/informe_a\xf1o.pdf" "/srv/uploads/informe_año.pdf"
Ready!
```

### 7.7 Locale over SSH — the classic remote failure

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

The client sent `LC_*` via `SendEnv`; `sshd` accepted them via `AcceptEnv LANG LC_*`; the server has no compiled `en_US.UTF-8`. The same root cause produces the notorious Perl banner during `apt` runs:

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

| Fix | Where | Effect | Recommended |
|---|---|---|---|
| Compile the locale on the server | server | Honours the client's intent | Yes, if localisation is wanted |
| `AcceptEnv` narrowed / removed | `/etc/ssh/sshd_config` | Server locale always wins | **Yes for fleet servers** |
| `SendEnv -LC_*` | client `~/.ssh/config` | Stops the leak at source | Yes |
| `ssh -o SendEnv=` one-off | client | Ad-hoc | Debugging |

```
# ~/.ssh/config on the operator workstation
Host *.prod.example.com
    SendEnv -LC_*
    SendEnv -LANG
```

---

## 8. Verification and failure diagnostics

### 8.1 The verification ladder

Run these in order; each rung is cheap and each answers a different question.

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

### 8.2 Symptom → cause → command

| Symptom | Most likely cause | Diagnostic command |
|---|---|---|
| `Cannot set LC_CTYPE to default locale` | Locale referenced but not compiled | `locale -a \| grep -i <name>` then `locale-gen` / `localedef` |
| `sort` output changed after an OS upgrade | glibc ≥2.28 collation change | `ldd --version`; pin with `LC_ALL=C` |
| DB query misses existing rows post-upgrade | Index built under old collation | `SELECT collversion FROM pg_collation`; `REINDEX DATABASE` |
| CSV has `3,14` instead of `3.14` | `LC_NUMERIC` inherited from operator | `locale \| grep NUMERIC`; export `LC_NUMERIC=C` |
| Script's `grep "No such file"` stopped matching | `LC_MESSAGES` translated | `LC_ALL=C <cmd>`; stop parsing stderr |
| Accented chars show as `Ã±` | Correct UTF-8 rendered as Latin-1 | Terminal encoding, not the data — check emulator |
| Accented chars show as `?` / `<E9>` | Latin-1 bytes decoded as UTF-8 | `file -i f`; `iconv -f UTF-8 -t UTF-8 f >/dev/null` |
| Emoji/CJK misaligns column output | `LC_CTYPE` not UTF-8, wcwidth wrong | `locale charmap`; must be `UTF-8` |
| Container logs in UTC despite `TZ=` | No `tzdata` in image | `ls /usr/share/zoneinfo` inside the container |
| `date` right in shell, wrong in service | Service doesn't read `~/.bashrc` | `systemctl show -p Environment <unit>` |
| CronJob fires at the wrong hour | `.spec.timeZone` unset → controller's TZ | `kubectl get cronjob X -o jsonpath='{.spec.timeZone}'` |
| Job skipped/duplicated once a year | DST transition | `zdump -v -c YYYY,YYYY+1 <Zone>` |
| Clock jumps by exactly the UTC offset at boot | RTC in local time | `timedatectl \| grep 'RTC in local TZ'` |
| `ls` order differs between two "identical" hosts | Different `LC_COLLATE` | `ssh h1 locale; ssh h2 locale` |

### 8.3 Reproducing a failure without touching the host

Every locale bug is a one-liner to reproduce, because locale is process-scoped:

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

Two runs, no configuration change, root cause proven. Add exactly this as a CI gate:

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

> **The Turkish-i test is the highest-value single probe in this entire objective.** In `tr_TR.UTF-8`, `toupper('i')` is `İ` and `tolower('I')` is `ı`. Code that does `if [ "${x,,}" = "yes" ]`, `grep -i`, or a case-insensitive hostname comparison produces a different answer in Turkey than anywhere else on Earth. Running your test suite once under `LC_ALL=tr_TR.UTF-8` finds locale-dependent case handling that no other locale exposes.

### 8.4 Post-upgrade collation audit

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

The durable fix is to stop depending on glibc for ordering at all: create the database with `--locale-provider=icu` (ICU versions its collation explicitly) or with `LC_COLLATE=C` and apply presentation ordering with an explicit `COLLATE` clause in the query.

---

## 9. Exam quick reference

| Question | Answer |
|---|---|
| Which variable overrides all others? | `LC_ALL` |
| Which variable is the fallback default? | `LANG` |
| Which affects only translated messages, with a fallback list? | `LANGUAGE` |
| Which command lists available locales? | `locale -a` |
| Which lists available charmaps? | `locale -m` |
| Which compiles a locale from source + charmap? | `localedef -i <src> -f <charmap> <name>` |
| Which file lists locales to generate on Debian? | `/etc/locale.gen` (then `locale-gen`) |
| Which file holds the systemd system locale? | `/etc/locale.conf` |
| Where is the timezone database? | `/usr/share/zoneinfo/` |
| What is `/etc/localtime`? | Symlink (or copy) of the active TZif file |
| What is `/etc/timezone`? | Debian text file naming the zone; not read by libc |
| Which command only *prints* a `TZ` value? | `tzselect` |
| Which command sets the system timezone? | `timedatectl set-timezone <Zone>` |
| Which converts file content between charsets? | `iconv -f <from> -t <to>` |
| How many bytes per character in UTF-8? | 1 to 4 |
| Is UTF-8 ASCII-compatible? | Yes |
| Is UTF-16 ASCII-compatible? | No |
| Which fixed-width encoding covers only the BMP? | UCS-2 (obsolete) |
| Which ISO-8859 variant adds the euro sign? | ISO-8859-15 (Latin-9) |
| How many characters in ASCII? | 128 (7-bit) |

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
- POSIX.1-2018 — Environment Variables (locale precedence) — https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html
- POSIX.1-2018 — Locale definition — https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap07.html

**Time and time zones**
- IANA Time Zone Database — https://www.iana.org/time-zones
- `tzset(3)` — https://man7.org/linux/man-pages/man3/tzset.3.html
- `tzfile(5)` (TZif format) — https://man7.org/linux/man-pages/man5/tzfile.5.html
- `tzselect(8)` — https://man7.org/linux/man-pages/man8/tzselect.8.html
- `zdump(8)` — https://man7.org/linux/man-pages/man8/zdump.8.html
- `localtime(5)` — https://www.freedesktop.org/software/systemd/man/latest/localtime.html
- `timedatectl(1)` — https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
- `hwclock(8)` — https://man7.org/linux/man-pages/man8/hwclock.8.html

**Character encodings**
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
- `systemd.time(7)` — calendar events and timezone handling — https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html

**Distribution documentation**
- Debian Wiki — Locale — https://wiki.debian.org/Locale
- Ubuntu Server — Locale configuration — https://documentation.ubuntu.com/server/explanation/intro/locale/
- Red Hat Enterprise Linux 9 — Configuring the date and time — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/assembly_configuring-the-date-and-time_configuring-basic-system-settings
- Arch Wiki — Locale — https://wiki.archlinux.org/title/Locale
- Alpine Linux Wiki — Locale — https://wiki.alpinelinux.org/wiki/Alpine_Linux:FAQ#Is_there_a_way_to_use_locales.3F
- musl libc — Functional differences from glibc — https://wiki.musl-libc.org/functional-differences-from-glibc.html

**Production impact**
- PostgreSQL — Collation support and version mismatches — https://www.postgresql.org/docs/current/collation.html
- Kubernetes — CronJob `.spec.timeZone` — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes API reference — CronJobSpec — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/cron-job-v1/
- Go standard library — `time/tzdata` (embedded timezone database) — https://pkg.go.dev/time/tzdata